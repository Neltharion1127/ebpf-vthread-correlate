# First-mount attribution blind spot — findings

- **Date:** 2026-07-03
- **Run:** single shot, `JDK=../jdk21u/build/linux-aarch64-server-release/images/jdk ./repro/blindspot/run-blindspot.sh`
- **Raw logs:** `blindspot-20260703-211159.log` (bpftrace), `blindspot-20260703-211159-java.log` (Java)
- **Reproducer:** `repro/blindspot/` (BlindSpotRepro.java + blindspot.bt, mapping semantics identical to `bpf/correlate.bt`: insert on thaw, delete on freeze with result <= 1)

## Hypothesis

A virtual thread's first mount enters via `Continuation.enterSpecial` (fresh entry), not the thaw path, so a syscall issued **before its first park** cannot be attributed — the carrier→vthread map (built on `vthread__thaw`) has no entry yet.

## Results

Java side printed `VTHREAD_ID=20`. Single carrier, tid=57906 (parallelism=1).

| Check | Result |
|---|---|
| PHASE_A: 101-byte write (before first park) | **UNMAPPED** |
| PHASE_B: 103-byte write (after first thaw) | **vthread_id=20** — matches Java-side threadId |
| freeze events | 1 total, result=0 (ok); `@freeze_unmatched=1` (expected: first unmount has no prior thaw) |
| thaw events | **12 total**: 1× kind=0 (top), 11× kind=1 (return_barrier) |
| pinned (`result` 2–4) | none (`@pinned_total=0`) |

## Full event sequence (verbatim from bpftrace log)

```
[write]  carrier tid=57906   comm=ForkJoinPool-1-  count=101  -> UNMAPPED
[freeze] carrier tid=57906   vthread_id=20  result=0
[thaw]   carrier tid=57906   vthread_id=20  kind=0
[thaw]   carrier tid=57906   vthread_id=20  kind=1   (×5 before PHASE_B)
[write]  carrier tid=57906   comm=ForkJoinPool-1-  count=103  -> vthread_id=20
[thaw]   carrier tid=57906   vthread_id=20  kind=1   (×6 after PHASE_B)
```

## Notes on the thaw multiplicity

Thaw fired 12 times for one logical wakeup: after the initial kind=0 (top) thaw, the remaining frames are thawed lazily via the return barrier (kind=1) as the stack unwinds — including 6 more return-barrier thaws *after* the PHASE_B write. This does not affect attribution here (all re-insert the same `vthread_id=20` on the same carrier), but any per-thaw accounting must expect kind=1 to dominate.

## Conclusion

**Blind spot confirmed.** The 101-byte write issued before the first park is UNMAPPED (no `vthread__thaw` had fired for this vthread, so no carrier→vthread entry existed); the 103-byte write after `Thread.sleep(200)` is correctly attributed to vthread_id=20. The freeze even precedes the first thaw in the event stream, confirming the first mount does not pass through the thaw path.

---

# Silent misattribution via stale carrier mapping — findings

- **Date:** 2026-07-03
- **Run:** single shot, `JDK=/home/jie/csc8499/jdk21u/build/linux-aarch64-server-release/images/jdk ./repro/blindspot/run-blindspot.sh MisattributionRepro`
- **Raw logs:** `blindspot-MisattributionRepro-20260703-212532.log` (bpftrace), `blindspot-MisattributionRepro-20260703-212532-java.log` (Java)
- **Reproducer:** `repro/blindspot/MisattributionRepro.java`; `blindspot.bt` unchanged except the write filter now also passes count==107 (mapping semantics untouched, still identical to `bpf/correlate.bt`)

## Hypothesis

A vthread's final termination does not go through freeze (the continuation runs to completion and returns — confirmed by the first run, which ended with return-barrier thaws and no trailing freeze). The carrier therefore keeps a stale carrier→vthread map entry forever. When the next fresh vthread lands on the same carrier and writes before its first park, the write is not UNMAPPED — it is **silently attributed to the previous, terminated vthread**.

## Results

Java side printed `VT1_ID=20`, `VT2_ID=24` (distinct, as required).

| Check | Result |
|---|---|
| VT1 lifecycle (101B / 103B) | identical to the verified first repro: 101B → UNMAPPED, 103B → vthread_id=20 |
| Carrier of VT2's 107B write | tid=65970 — **same carrier** VT1 used |
| Freeze between VT1's last thaw and VT2's write | **none** (`@freeze_total=1`, the single freeze is VT1's sleep) |
| 107B write attribution | **vthread_id=20 = VT1_ID** → outcome (a): silent misattribution **confirmed** |

## Full event sequence (verbatim from bpftrace log)

```
[write]  carrier tid=65942   comm=bpftrace         count=107  -> UNMAPPED   (†)
[write]  carrier tid=65970   comm=ForkJoinPool-1-  count=101  -> UNMAPPED
[freeze] carrier tid=65970   vthread_id=20  result=0
[thaw]   carrier tid=65970   vthread_id=20  kind=0
[thaw]   carrier tid=65970   vthread_id=20  kind=1   (×5)
[write]  carrier tid=65970   comm=ForkJoinPool-1-  count=103  -> vthread_id=20
[thaw]   carrier tid=65970   vthread_id=20  kind=1   (×6)
                              <-- VT1 terminates here: NO freeze fires -->
[write]  carrier tid=65970   comm=ForkJoinPool-1-  count=107  -> vthread_id=20   (should be VT2=24)
```

(†) Coincidental noise: bpftrace's own startup output happens to issue one
107-byte write(2); `comm=bpftrace` identifies it as unrelated to the JVM.
This is why the events print `comm`.

Counters: `@freeze_total=1`, `@thaw_total=12` (1× kind=0, 11× kind=1), `@pinned_total=0` — VT2 contributed **zero** freeze/thaw events, exactly as designed (first-mount only, never parks).

## Conclusion

**Silent misattribution confirmed.** VT2's (id=24) 107-byte write was attributed to the terminated VT1 (id=20): VT1's termination emits no freeze, leaving a stale mapping on carrier tid=65970; VT2's first mount emits no thaw either, so the lookup hits the stale entry.

The two failure modes differ in nature:

- **First mount alone** (no stale carrier state) → **missing attribution**: UNMAPPED, an honest failure that is visible and countable by the consumer.
- **First mount following the previous vthread's freeze-less termination** (same carrier) → **silent misattribution**: the data appears complete, with no anomaly signal, but is attached to the wrong vthread. The second failure mode is strictly more severe because the consumer cannot detect it.

## Regression

The no-arg run (`./run-blindspot.sh`, BlindSpotRepro) was re-run after the changes and reproduced the original findings byte-for-byte in structure: 101B → UNMAPPED, 103B → vthread_id=20, freeze ×1 (result=0), thaw ×12 (1× kind=0 + 11× kind=1), no pinned. Log: `blindspot-BlindSpotRepro-20260703-212609.log`.

## Misattribution window and soundness/completeness framing

**Window boundary.** The map is keyed by carrier, and a fresh vthread's first
freeze deletes whatever entry the carrier holds — a stale entry from the
previous occupant is deleted as if it were a matched thaw (the mechanism
described as finding B2 in `THAW-COUNT-AUDIT.md`). The misattribution window is
therefore `[new vthread's first mount, its first freeze)`. For a vthread that
eventually parks, the window is finite. For a short task that never parks —
the typical request-per-vthread shape — the window covers its **entire
lifetime**, and its own freeze-less termination leaves a fresh stale entry
behind, so misattribution chains from vthread to vthread along the same
carrier indefinitely.

**Formal framing.** A correlation built from freeze/thaw alone is neither
**complete** nor **sound**:

- *Not complete*: the first-mount blind spot drops attribution (UNMAPPED — an
  honest, consumer-visible failure).
- *Not sound*: freeze-less termination plus the first-mount gap produces
  silent misattribution (data looks fully attributed but is assigned to the
  wrong vthread — invisible to the consumer).

Restoring completeness requires a per-lifetime **start** event (mapping exists
before the first syscall); restoring soundness requires a per-lifetime **end**
event (stale mappings are cleared at termination). Both are O(1) per vthread
lifetime, unlike the per-transition freeze/thaw events.

**Evidence.** Blind spot (incompleteness): `blindspot-20260703-211159.log`
(and regression `blindspot-BlindSpotRepro-20260703-212609.log`).
Silent misattribution (unsoundness):
`blindspot-MisattributionRepro-20260703-212532.log`.

---

# Fix verification: lifecycle probes

- **Date:** 2026-07-04
- **JDK:** jdk21u branch `vthread-lifecycle-probes`, commit `55ca8535411`,
  images at `build/linux-aarch64-server-release/images/jdk`. Adds two O(1)
  per-lifetime USDT probes, layouts verified with `readelf -n`:
  `vthread__start(uintptr_t vthread_id, uintptr_t trace_buffer_addr)`
  (`8@x20 8@x0`) and `vthread__end(uintptr_t vthread_id)` (`8@x0`).
- **Consumer:** `repro/blindspot/blindspot-fixed.bt` (this branch;
  `blindspot.bt` is unchanged as the defect baseline). Cache protocol:
  start/thaw(kind==0) insert, freeze(result<=1) delete, end deletes
  unconditionally; kind==1 (return-barrier) thaws count only — they fire
  after `end` on the termination path and must not resurrect the mapping.
- **Runs:** all with `-Dvthread.trace.jvmAlloc=true` (jvmalloc allocation
  path) except run E, which uses the JVMTI agent allocation path instead.

| Run | Reproducer | Consumer | Log (`result/blindspot/`) |
|---|---|---|---|
| A | BlindSpotRepro | blindspot.bt (old) | `blindspot-BlindSpotRepro-blindspot-20260704-043424.log` |
| B | BlindSpotRepro | blindspot-fixed.bt | `blindspot-BlindSpotRepro-blindspot-fixed-20260704-043550.log` |
| C | MisattributionRepro | blindspot.bt (old) | `blindspot-MisattributionRepro-blindspot-20260704-043603.log` |
| D | MisattributionRepro | blindspot-fixed.bt | `blindspot-MisattributionRepro-blindspot-fixed-20260704-043628.log` |
| E | MisattributionRepro | blindspot-fixed.bt + `-agentpath:libvthread_trace_agent.so` (no jvmAlloc) | `blindspot-MisattributionRepro-blindspot-fixed-20260704-043705.log` |
| F | BlindSpotRepro, `TRACE_FLAG=off` | blindspot-fixed.bt | `blindspot-BlindSpotRepro-blindspot-fixed-20260704-043721.log` |

## Before/after — same reproducers, same workload

| Check | Old semantics (A/C, matches 2026-07-03 findings) | New semantics (B/D) |
|---|---|---|
| 101B write (before first park) | **UNMAPPED** (blind spot) | **vthread_id=20** — correct (start inserted the mapping) |
| 103B write (after first thaw) | vthread_id=20 — correct | vthread_id=20 — correct |
| 107B write (VT2 first-mount, same carrier) | **vthread_id=20 = VT1** — silent misattribution | **vthread_id=24 = VT2** — correct (VT1's end cleared the stale entry, VT2's start inserted its own) |

**Run B is the regression evidence for the completeness fix** (first-mount
blind spot closed: 101B attributed, `@start_total=1`, `@end_total=1`,
`@end_unmatched=0`). **Run D is the regression evidence for the soundness
fix** (stale-entry misattribution killed: 107B attributed to VT2,
`@start_total=2`, `@end_total=2`, `@end_unmatched=0`). Run A/C confirm the
old consumer reproduces the 2026-07-03 defect records byte-for-byte in
structure on the new JDK — the added probes are transparent to consumers
that do not attach them.

## Buffer address on vthread__start

Non-zero in every flagged run, as required for correlation from the very
first syscall:

- jvmalloc path: B `buf=0xffffa01842e0`; D VT1 `buf=0xffff8c184610`,
  VT2 `buf=0xffff8c186620`.
- JVMTI agent path (E): VT1 `buf=0xffff2c0012d0`, VT2 `buf=0xffff2c0012d0`
  (same address — the agent frees VT1's buffer in its VirtualThreadEnd
  callback and malloc reuses the block for VT2; distinct lifetimes, not a
  stale pointer). 107B write → vthread_id=24, correct: the JDK-side probe
  ordering (start after `notifyJvmtiStart()`, end before `notifyJvmtiEnd()`)
  delivers a populated address and an end-before-free window on the
  jvmtipublish variant end-to-end.

## Diagnostics (B/D/E identical)

`@post_end_freeze=0` (no freeze ever follows end on a carrier before the
next insert), `@post_end_thaw=3`, all `kind==1` — exactly the
termination-path return-barrier thaws that motivated the kind==1 no-insert
rule; with unconditional thaw-insert they would have resurrected the
mapping end just cleared. `@freeze_unmatched=0` under the new protocol
(the old value of 1 was the first freeze finding no thaw-built entry —
start now precedes it).

## Flag-off regression (F)

Without `-XX:+VThreadTraceProbes`: all four probe counters zero
(`@start_total=@end_total=@freeze_total=@thaw_total=0`), every JVM write
UNMAPPED — no probes, no mappings. The "flag off = zero cost, zero events"
convention extends to the new probes.

Noise notes: the `comm=bpftrace`/`comm=scon` UNMAPPED writes in the logs are
non-JVM processes that happen to hit the 101/107-byte filter (same class of
coincidence as the (†) note above); `comm` identifies them as unrelated.
