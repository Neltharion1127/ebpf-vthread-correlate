/*
 * vthread_trace_agent.c
 *
 * JVMTI agent that owns per-virtual-thread trace buffer lifecycle.
 *
 *   VirtualThreadStart -> calloc(64) + write threadId at offset 0
 *                       + SetLongField(traceBufferAddress, buf)
 *   VirtualThreadEnd   -> GetLongField + free
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
 * Buffer layout (matches existing convention:
 *   [0-15]  OTel traceId   (written by BufferSyncContextStorage)
 *   [16-23] OTel spanId    (written by BufferSyncContextStorage)
 *   [24] valid
 *   reversed for future
 *   [25] _reserved
 *   [26-27] attrs-data-size
 *   [28-33] attrs-data      
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
        log_msg("VT start: vthread_obj=%p buf=%p readback=0x%lx %s",
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

    log_msg("ready (fieldID=%p methodID=%p)",
            (void *)g_trace_buf_field, (void *)g_thread_id_method);
}

/* ---- Agent entry ---- */

JNIEXPORT jint JNICALL
Agent_OnLoad(JavaVM *vm, char *options, void *reserved) {
    (void)reserved;

    if (options != NULL && strstr(options, "verbose") != NULL) {
        g_verbose = 1;
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