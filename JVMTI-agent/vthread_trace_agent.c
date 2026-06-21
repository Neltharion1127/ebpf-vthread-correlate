/*
 * vthread_trace_agent.c  (v2)
 *
 * JVMTI agent that owns per-virtual-thread trace buffer lifecycle, and
 * OPTIONALLY publishes the mounted vthread's buffer address on every
 * mount/unmount via the JVMTI VirtualThreadMount/Unmount extension events.
 *
 *   VirtualThreadStart -> calloc(64) + write threadId at offset 0
 *                       + SetLongField(traceBufferAddress, buf)
 *   VirtualThreadEnd   -> GetLongField + free
 *
 *   [publish=jvmti]  VirtualThreadMount   -> read vthread.traceBufferAddress,
 *                                            write it to a carrier __thread slot
 *                    VirtualThreadUnmount -> clear the carrier __thread slot
 *
 * Two publish mechanisms can now be compared on the same buffer:
 *   - USDT  (JVM modification): vthread__freeze/thaw probes in the JVM push the
 *           address into the eBPF map. Agent runs WITHOUT publish=jvmti.
 *   - JVMTI (this agent):       mount/unmount callbacks write carrier-resident
 *           TLS, the Elastic-style approach. Agent runs WITH publish=jvmti.
 *
 * The JVM exposes only:
 *   - traceBufferAddress field on VirtualThread (volatile, default 0)
 *   - USDT probes vthread__freeze / vthread__thaw broadcasting that address
 *
 * Without this agent loaded, the buffer is never allocated, the field stays 0,
 * the USDT probe fires with arg2=0, BufferSyncContextStorage falls back to its
 * platform-thread ThreadLocal path, and bpftrace's null-guard skips the read.
 * Result: zero residual overhead on the JVM when nobody is observing.
 *
 * Buffer layout (matches existing convention):
 *   [0-15]  OTel traceId   (written by BufferSyncContextStorage)
 *   [16-23] OTel spanId    (written by BufferSyncContextStorage)
 *   [24] valid
 *   [25] _reserved
 *   [26-27] attrs-data-size
 *   [28-63] attrs-data
 */

#include <jvmti.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <stdint.h>

#define BUFFER_SIZE 64

/* Globals resolved once at VM init, then read-only. */
static jvmtiEnv *g_jvmti              = NULL;
static jclass    g_vthread_class      = NULL;   /* GlobalRef */
static jfieldID  g_trace_buf_field    = NULL;   /* VirtualThread.traceBufferAddress */
static jmethodID g_thread_id_method   = NULL;   /* Thread.threadId() */
// log on/off
static int g_verbose = 0;
/* NEW: publish=jvmti mode — register mount/unmount and publish to carrier TLS. */
static int g_publish_jvmti = 0;

/* NEW: carrier-resident publish target. Written ON the carrier thread when a
 * vthread mounts; an external reader (eBPF) would read this per-carrier TLS
 * slot. For the overhead benchmark, the write itself is the cost measured —
 * eBPF actually reading a process __thread is a separate (hard) problem and is
 * exactly the friction Elastic documents; it is not needed for the cost number. */
static __thread volatile jlong t_carrier_vtbuf = 0;

static void log_msg(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    fprintf(stderr, "[vthread-trace-agent] ");
    vfprintf(stderr, fmt, args);
    fprintf(stderr, "\n");
    va_end(args);
}

/* ---- Event callbacks ---- */

static void JNICALL
on_vthread_start(jvmtiEnv *jvmti, JNIEnv *jni, jthread vthread) {
    (void)jvmti;
    // allocate memory only
    void *buf = calloc(1, BUFFER_SIZE);
    if (buf == NULL) {
        /* Out of memory. Leave field at 0; both BufferSyncContextStorage and
         * correlate.bt are required to handle addr==0 gracefully. */
        log_msg("calloc failed for vthread %p; field left at 0", (void *)vthread);
        return;
    }

    (*jni)->SetLongField(jni, vthread, g_trace_buf_field,(jlong)(intptr_t)buf);

    if(g_verbose){
        jlong readback = (*jni)->GetLongField(jni, vthread, g_trace_buf_field);
        log_msg("VT start: vthread_obj=%p buf=%p readback=0x%lx",
            (void *)vthread, buf, (long)readback);
    }

}

static void JNICALL
on_vthread_end(jvmtiEnv *jvmti, JNIEnv *jni, jthread vthread) {
    (void)jvmti;
    jlong addr = (*jni)->GetLongField(jni, vthread, g_trace_buf_field);
    if(g_verbose){
        log_msg("VT end: vthread_obj=%p addr=0x%lx", (void *)vthread, (long)addr);
    }
    if (addr != 0) {
        free((void *)(intptr_t)addr);
        /* Zero the field so any racing read (shouldn't happen, but defensive)
         * sees a definitively freed state rather than a dangling pointer. */
        (*jni)->SetLongField(jni, vthread, g_trace_buf_field, 0);
    }
}

/* ---- NEW: mount/unmount publish (extension-event callbacks) ----
 *
 * These run on the CARRIER thread. The mount callback reads the mounting
 * vthread's buffer address (one JNI field read) and stores it in carrier TLS;
 * the unmount callback clears it. This is the JVMTI-side equivalent of what the
 * USDT freeze/thaw probe does in the JVM.
 *
 * Caveat worth noting in the write-up: doing a JNI GetLongField on the
 * mount/unmount hot path is both a cost and a fragility point (field access
 * during a VTMS transition). That cost vs. the USDT probe is the whole point.
 */
static void JNICALL
on_vthread_mount(jvmtiEnv *jvmti, JNIEnv *jni, jthread vthread) {
    (void)jvmti;
    jlong buf = (*jni)->GetLongField(jni, vthread, g_trace_buf_field);
    t_carrier_vtbuf = buf;
    __atomic_thread_fence(__ATOMIC_RELEASE);
}

static void JNICALL
on_vthread_unmount(jvmtiEnv *jvmti, JNIEnv *jni, jthread vthread) {
    (void)jvmti; (void)jni; (void)vthread;
    t_carrier_vtbuf = 0;
    __atomic_thread_fence(__ATOMIC_RELEASE);
}

/* NEW: discover and register the VirtualThreadMount/Unmount extension events.
 * Matches by id substring rather than a hardcoded full id, so it survives a
 * different vendor prefix. */
static jvmtiError
register_vthread_transition_callbacks(jvmtiEnv *jvmti) {
    jint count = 0;
    jvmtiExtensionEventInfo *events = NULL;
    jvmtiError err = (*jvmti)->GetExtensionEvents(jvmti, &count, &events);
    if (err != JVMTI_ERROR_NONE) {
        log_msg("GetExtensionEvents failed: %d", err);
        return err;
    }

    jint mount_index = -1, unmount_index = -1;
    for (jint i = 0; i < count; i++) {
        const char *id = events[i].id;
        if (id == NULL) continue;
        if (strstr(id, "VirtualThreadMount") != NULL) {
            mount_index = events[i].extension_event_index;
            log_msg("found mount ext event: id=%s index=%d", id, mount_index);
        } else if (strstr(id, "VirtualThreadUnmount") != NULL) {
            unmount_index = events[i].extension_event_index;
            log_msg("found unmount ext event: id=%s index=%d", id, unmount_index);
        }
    }

    /* Free the descriptor table (id, short_description, param names, params, array). */
    for (jint i = 0; i < count; i++) {
        (*jvmti)->Deallocate(jvmti, (unsigned char *)events[i].id);
        (*jvmti)->Deallocate(jvmti, (unsigned char *)events[i].short_description);
        for (jint p = 0; p < events[i].param_count; p++) {
            (*jvmti)->Deallocate(jvmti, (unsigned char *)events[i].params[p].name);
        }
        (*jvmti)->Deallocate(jvmti, (unsigned char *)events[i].params);
    }
    (*jvmti)->Deallocate(jvmti, (unsigned char *)events);

    if (mount_index < 0 || unmount_index < 0) {
        log_msg("VirtualThreadMount/Unmount extension events not found "
                "(mount=%d unmount=%d); JDK 21+ Loom JVMTI required",
                mount_index, unmount_index);
        return JVMTI_ERROR_NOT_AVAILABLE;
    }

    /* SetExtensionEventCallback with a non-NULL callback also ENABLES the event. */
    err = (*jvmti)->SetExtensionEventCallback(jvmti, mount_index,
            (jvmtiExtensionEvent)on_vthread_mount);
    if (err != JVMTI_ERROR_NONE) {
        log_msg("SetExtensionEventCallback(mount) failed: %d", err);
        return err;
    }
    err = (*jvmti)->SetExtensionEventCallback(jvmti, unmount_index,
            (jvmtiExtensionEvent)on_vthread_unmount);
    if (err != JVMTI_ERROR_NONE) {
        log_msg("SetExtensionEventCallback(unmount) failed: %d", err);
        return err;
    }

    log_msg("JVMTI mount/unmount publish enabled (carrier-resident TLS)");
    return JVMTI_ERROR_NONE;
}

static void JNICALL
on_vm_init(jvmtiEnv *jvmti, JNIEnv *jni, jthread thread) {
    (void)thread;

    /* Resolve VirtualThread class and cache as GlobalRef. */
    jclass cls = (*jni)->FindClass(jni, "java/lang/VirtualThread");
    if (cls == NULL) {
        log_msg("FindClass(java/lang/VirtualThread) failed");
        return;
    }
    g_vthread_class = (*jni)->NewGlobalRef(jni, cls);
    (*jni)->DeleteLocalRef(jni, cls);

    g_trace_buf_field = (*jni)->GetFieldID(jni, g_vthread_class,
                                            "traceBufferAddress", "J");
    if (g_trace_buf_field == NULL) {
        log_msg("GetFieldID(VirtualThread.traceBufferAddress) failed; "
                "did you rebuild the JDK after editing VirtualThread.java?");
        return;
    }

    /* Resolve Thread.threadId() — lives on the Thread superclass, available
     * on every VirtualThread instance. */
    jclass thread_cls = (*jni)->FindClass(jni, "java/lang/Thread");
    if (thread_cls == NULL) {
        log_msg("FindClass(java/lang/Thread) failed");
        return;
    }
    g_thread_id_method = (*jni)->GetMethodID(jni, thread_cls,
                                              "threadId", "()J");
    (*jni)->DeleteLocalRef(jni, thread_cls);
    if (g_thread_id_method == NULL) {
        log_msg("GetMethodID(Thread.threadId) failed");
        return;
    }

    /* Now enable vthread events. */
    jvmtiError err;
    err = (*jvmti)->SetEventNotificationMode(jvmti, JVMTI_ENABLE,
            JVMTI_EVENT_VIRTUAL_THREAD_START, NULL);
    if (err != JVMTI_ERROR_NONE) {
        log_msg("enable VIRTUAL_THREAD_START failed: %d", err);
        return;
    }
    err = (*jvmti)->SetEventNotificationMode(jvmti, JVMTI_ENABLE,
            JVMTI_EVENT_VIRTUAL_THREAD_END, NULL);
    if (err != JVMTI_ERROR_NONE) {
        log_msg("enable VIRTUAL_THREAD_END failed: %d", err);
        return;
    }

    /* NEW: optionally wire up the JVMTI per-transition publish. */
    if (g_publish_jvmti) {
        err = register_vthread_transition_callbacks(jvmti);
        if (err != JVMTI_ERROR_NONE) {
            log_msg("publish=jvmti requested but registration failed: %d", err);
            /* Non-fatal: buffer lifecycle still works; publish just absent. */
        }
    }

    log_msg("ready (fieldID=%p methodID=%p publish_jvmti=%d)",
            (void *)g_trace_buf_field, (void *)g_thread_id_method, g_publish_jvmti);
}

/* ---- Agent entry ---- */

JNIEXPORT jint JNICALL
Agent_OnLoad(JavaVM *vm, char *options, void *reserved) {
    (void)reserved;

    if (options != NULL && strstr(options, "verbose") != NULL) {
        g_verbose = 1;
    }
    /* NEW: opt-in to the JVMTI mount/unmount publish path. */
    if (options != NULL && strstr(options, "publish=jvmti") != NULL) {
        g_publish_jvmti = 1;
    }

    log_msg("loading, options=%s", options ? options : "(none)");

    jint rc = (*vm)->GetEnv(vm, (void **)&g_jvmti, JVMTI_VERSION_21);
    if (rc != JNI_OK || g_jvmti == NULL) {
        log_msg("GetEnv(JVMTI_VERSION_21) failed: %d", rc);
        return JNI_ERR;
    }

    /* Request vthread support. JEP 444 designed this capability so it does
     * NOT force vthread to pin or take slow paths. */
    jvmtiCapabilities caps;
    memset(&caps, 0, sizeof(caps));
    caps.can_support_virtual_threads = 1;
    jvmtiError err = (*g_jvmti)->AddCapabilities(g_jvmti, &caps);
    if (err != JVMTI_ERROR_NONE) {
        log_msg("AddCapabilities failed: %d", err);
        return JNI_ERR;
    }

    /* Register callbacks. */
    jvmtiEventCallbacks cbs;
    memset(&cbs, 0, sizeof(cbs));
    cbs.VMInit             = on_vm_init;
    cbs.VirtualThreadStart = on_vthread_start;
    cbs.VirtualThreadEnd   = on_vthread_end;
    err = (*g_jvmti)->SetEventCallbacks(g_jvmti, &cbs, sizeof(cbs));
    if (err != JVMTI_ERROR_NONE) {
        log_msg("SetEventCallbacks failed: %d", err);
        return JNI_ERR;
    }

    /* Enable VM_INIT only here; vthread events get enabled inside on_vm_init
     * after field/method IDs are resolved. This prevents the (rare but real)
     * race where a vthread start callback fires before we've cached IDs. */
    err = (*g_jvmti)->SetEventNotificationMode(g_jvmti, JVMTI_ENABLE,
            JVMTI_EVENT_VM_INIT, NULL);
    if (err != JVMTI_ERROR_NONE) {
        log_msg("enable VM_INIT failed: %d", err);
        return JNI_ERR;
    }

    log_msg("loaded");
    return JNI_OK;
}

JNIEXPORT void JNICALL
Agent_OnUnload(JavaVM *vm) {
    (void)vm;
    log_msg("unloading");
}