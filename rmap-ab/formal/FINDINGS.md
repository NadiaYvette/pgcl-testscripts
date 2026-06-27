# PGCL #143 — model-checking the free-while-mapped race (CBMC + Tessera plan)

Date: 2026-06-27. A Loom-for-C style concurrency model of the abstracted #143
bug, a model-checker counterexample, and a plan to dovetail it into Tessera.
No Linux kernel file was modified; nothing committed.

Artifacts in `/home/nyc/src/pgcl/rmap-ab/formal/`:
- `pgcl_cluster.c`         — main model (bug present).
- `pgcl_cluster_atomic.c`  — atomic refcount; STILL buggy (key finding).
- `pgcl_cluster_tryget.c`  — folio_try_get (inc-unless-zero) discipline; SAFE.
- `pgcl_cluster_locked.c`  — single-PTL variant (didactic; see note 5).
- `run.sh`                 — one-shot reproducer.
- `cbmc_trace.log`         — captured counterexample trace.

## 1. Checkers available; chosen
CBMC 6.8.0 at ~/.kani/kani-0.67.0/bin/cbmc (inside Kani, the ~48GB job); full
CPROVER toolchain (cbmc, goto-cc, goto-instrument, goto-analyzer, kissat) +
`--mm {sc,tso,...}`. genmc/nidhugg/rcmc/cppmem/esbmc: NOT installed. herd7 7.58
(-variant vmsa) + coqc 8.20.1 + coq-iris present (Tessera Property 2). CHOSEN:
CBMC (only C model checker on box; task's safe default). genMC/Nidhugg would also
fit (stateless DPOR/weak memory) but absent; the model is tiny so CBMC suffices.

GOTCHA: this CBMC's pthread_create builtin is broken for verification — the
__spawned_thread wrapper does an unresolved function-pointer call on the thread
start routine, prints "pointer handling for concurrency is unsound" and EXITS WITH
NO VERDICT (even a 3-line lost-update test). Fix: use CBMC's native
`__CPROVER_ASYNC_n:` thread labels (works perfectly, and is MORE faithful: every
statement in an async block is an interleaving point — exactly the PTL gap).

## 2. The model (pgcl_cluster.c)
A cluster (folio/KAU) backs N sub-PTEs (model N=3; real PAGE_MMUCOUNT=16). State:
  refcount  (freed at 0; atomic_dec_and_test in kernel)
  mapcount[N] (per-sub-PTE rmap, PGCL "Option A")
  pte[N]    (per-sub-PTE present = a live HW mapping)
  freed     (sticky flag set when refcount hits 0)
Ops: fault/add(i) = mapcount[i]++; refcount++; pte[i]=1  (one PTL section, safe order).
     zap/remove(i) = pte[i]=0; mapcount[i]-- (under PTL) THEN, SEPARATELY, the
       DEFERRED refcount--; if 0 free. The split is the crux: kernel clears the PTE
       + drops rmap under the PTL, but the refcount drop / folio_put is tlb-batch
       DEFERRED to tlb_finish_mmu (a later, lockless section). Matches the hunt's
       conclusion: every static path balances; the deferred put is the
       separately-interleavable step; emergent race, not a miscount.
Invariant: !(freed && pte[i]) for all i — never free while any sub-PTE maps it.
Scenario: two __CPROVER_ASYNC threads fault-then-zap the SAME shared sub-PTE of the
SAME cluster (the fork parent+child the QEMU TLB-scan caught). N=3, 2 threads,
bounded straight-line ops -> terminates in <1s.

## 3. Result — CBMC finds the race
`cbmc pgcl_cluster.c --unwind 2` -> VERIFICATION FAILED: !(freed && pte[0])
violated. Identical under --mm sc and --mm tso. The final-state assertion SUCCEEDS
(the bad state is a transient window — as in the kernel: the dangling PTE persists
only until the racing thread also finishes, but the frame is exposed for reuse).

EXACT counterexample interleaving (A=ASYNC_1, B=ASYNC_2; from cbmc_trace.log):
 1. A faults the shared sub-PTE: refcount 0->1, mapcount[0] 0->1, pte[0]=1.
 2. B begins its fault and is preempted mid-way: B runs mapcount[0]++ but is
    interrupted BEFORE its refcount++ (rmap bump and ref bump not atomic w.r.t.
    A's teardown).
 3. A zaps and frees: pte[0]=0, mapcount[0]--, then the DEFERRED put runs:
    refcount 1->0 so A sets freed=1 (A held the last ref by its accounting).
 4. B resumes into the freed cluster: deferred refcount++ then pte[0]=1 — installs
    a present PTE into an ALREADY-FREED cluster.
 At step 4: freed==1 && pte[0]==1 = FREE-WHILE-MAPPED. This is #143 exactly — two
 mappers of one shared cluster, ref accounting not atomic with the PTE install, put
 deferred, so one mapper frees while the other is mid-fault.

DECISIVE refinement (the fix), all in run.sh:
 (1) Naive non-atomic           -> FAILED (above).
 (2) pgcl_cluster_atomic.c: atomic refcount++ / atomic dec-and-test -> STILL FAILED.
     Atomicity is NOT enough. Surviving schedule: A's atomic put returns 0 (commits
     to free), B's atomic refcount++ RESURRECTS 0->1, A sets freed=1, B installs its
     PTE. Hazard = acquiring a ref to a folio whose refcount already reached 0
     (use-after-free of the refcount itself).
 (3) pgcl_cluster_tryget.c: folio_try_get = atomic INCREMENT-UNLESS-ZERO + a stable
     "existence" ref (allocation/pagecache ref held across both threads, dropped
     last) -> VERIFICATION SUCCESSFUL (0 failures).
So the model finds the bug AND discriminates the fix = the kernel's real discipline:
a mapper that finds the folio must folio_try_get (FAIL the get if count==0 ->
retry/get a fresh folio), and a stable existence ref must dominate the per-mapping
refs so the folio can't be freed under an in-progress fault. Squares with
"every static path balances yet it corrupts": the defect is emergent in the
interleaving; atomic counters alone do not close it.

## 4. Dovetailing into Tessera (/home/nyc/src/tessera)
Tessera models the SEQUENTIAL refcount discipline and the CONCURRENT TLB-shootdown,
but NOT the concurrent refcount discipline — exactly where this race lives.
- proof/Tessera/Sharing.lean (Rung 2, Backing): WF b := mapcount = sites.length,
  with add_wf/remove_wf/free_iff_unmapped proven SEQUENTIALLY. proof-obligations.md
  calls Rung 2 "the cheapest model that sees the central bug (pgcl #1/#5)." My result
  shows that very discipline is NOT preserved under concurrency — the sequential
  theorems are right, but concurrent composition breaks free => unmapped. New theorem.
- proof/Tessera/PtShare.lean (Rung 3): concrete (aspace,vaddr) sites + PtNode
  refcounts; same sequential WF, same gap.
- doc/proof-obligations.md category G (refcount, "count changes by true delta") =
  done SEQUENTIALLY; category (I) "Tolerate concurrency — race vs a fault/teardown on
  another core" = DEFERRED = this. formalization-status.md line 55: "Property 2
  (concurrent observation) — DEFERRED."
- property2/coq/tlb_shootdown.v already has the right machinery: Iris/HeapLang, |||
  parallel composition, an invariant, an exclusive token — proving the shootdown
  re-establishes TLB ⊆ mapping, and FAILING if you drop the flush (concurrent
  analogue of unmap_without_flush_breaks_coherence). This race is the refcount sibling.

CONCRETE PLAN (smallest-first):
 Step A (cheap, no Iris): proof/Tessera/SharingRace.lean — a tiny 2-thread
   interleaving semantics over one shared Backing with the deferred put as its own
   step; state Coherent := freed -> fully-unmapped at EVERY step; PROVE a
   counterexample step-list exists (just like Sharing.lean already proves
   add_wrong_delta_breaks_wf / asymmetric_add_remove_drifts are provable errors).
   This is the Lean transcription of the CBMC counterexample.
 Step B (the real proof, mirroring tlb_shootdown.v): property2/coq/refcount_race.v —
   HeapLang refs refcount, pte[sub], existence ref; fault = try_incr_unless_zero ;;
   pte<-true; zap = pte<-false ;; let last=FAA(refcount,-1)==1 in if last then free.
   Iris invariant: (pte=true ∨ any per-mapping ref held) ⟹ refcount>0, and
   freed ⟹ refcount=0 ∧ ∀sub, pte sub=false. Prove (fault ||| zap) preserves it
   IFF fault uses try-incr-unless-zero. Drop the guard -> proof fails with the |||
   schedule reaching freed ∧ pte (concurrent counterpart of
   unmap_without_flush_breaks_coherence; the formal "atomic counter alone is
   insufficient" = CBMC variant 2 vs 3).
 Step C (optional frontier): follow property2/coq/weak/ SC-then-weak pacing. No
   herd7 counterpart is natural (this is a heap/refcount race, not a VMSA/TLB shape);
   the race's "litmus" is the Step-A Lean witness.
PROPERTY (one line): under concurrent fault/zap on a shared cluster, the refcount
 discipline preserves "freed ⟹ fully-unmapped" IFF acquisition is
 increment-unless-zero AND a stable existence reference dominates the per-mapping
 references. Tessera proves the ⟹ sequentially today; this adds the concurrent iff
 and exhibits the violating schedule when the discipline is dropped.
HOW LITMUS TESTS RELATE: the *.litmus files (bbm-tlbi, shootdown-*) are Property-2
 TLB-shootdown shapes vs the Arm VMSA model (flush/barrier maintenance necessary).
 This race is the refcount sibling — same "concurrent maintenance is necessary,
 omitting it is a provable error" pattern, same Iris ||| style — but the maintenance
 is the unless-zero acquire + existence ref, not the TLBI. It belongs in the
 Property-2 track beside the shootdown proof, not in the litmus set.

## 5. Faithfulness — captured vs abstracted
CAPTURED (load-bearing): one refcounted object backing N per-sub-PTE map bits (PGCL
cluster shape); the non-atomic split between PTE-clear+rmap-drop (PTL) and the
DEFERRED refcount put (tlb-batched, lockless) — the documented PVMW/PTL-gap +
deferred folio_put; two mappers of the SAME shared cluster (fork parent+child)
tearing down independently; the free-while-mapped invariant; and the discrimination
that atomic counters are insufficient while try_get-unless-zero + existence ref is
sufficient (= kernel's real folio_try_get/try_get_folio).
ABSTRACTED (and why / what to add for a residual):
 1. N=3 not 16: race is per-shared-sub-PTE, independent of N; 16 changes magnitudes
    only. Re-run N=16 only if a count-threshold effect is suspected (none is).
 2. The LOOKUP that re-finds the folio is implicit. Real safety also rests on the
    lookup path (pagecache xa_lock / i_mmap_lock / anon rwsem / the finding PTL)
    serialising "find" vs "free". The model collapses "B faults the same cluster"
    into a direct shared touch; the tryget existence ref stands in for "the lookup
    structure still holds a ref." IF the real bug is a lookup-vs-free ORDERING (e.g.
    PGCL adds a sub-PTE in set_pte_range/filemap_set_ptes_cluster keyed by a
    coordinate the reclaim walk computes differently — the #140 family), it lives in
    the find step this model omits; add an explicit lookup->tryget with a separately
    racing free to test it. *** This is the #1 detail to promote next. ***
 3. No TLB: stale-TLB-after-clear (a strand the notes mostly refute via the full
    arch_tlbbatch_flush) is Tlb.lean / Property-2 shootdown territory, not duplicated.
    This is the refcount/free strand.
 4. No weak memory of the PT writes themselves: checked --mm tso; the bug is an
    interleaving not a reordering artifact, so SC suffices (x86 is TSO; the
    deferred-put ordering is the operative effect, already modeled).
 5. Single shared sub-PTE, fault-then-zap once/thread: enough to expose the window.
    Multi-round / multi-sub-PTE / a 3rd reclaim thread broaden coverage but cannot
    remove a reachable violation. pgcl_cluster_locked.c caveat: a single shared PTL
    around each thread's whole add+zap does NOT fix it — correctly, because fork
    parent and child have SEPARATE page-table locks, so a per-mm PTL never serialises
    the two mappers (two of its four "failures" are spurious spin-loop unwinding
    assertions; the remedy is the refcount discipline, per variant 3).
BOTTOM LINE: a faithful abstraction of the refcount/free-while-mapped strand of
#143 — reproduces the race from the deferred non-atomic put on a fork-shared
cluster, and shows the fix is folio_try_get-unless-zero plus a dominating existence
ref (not merely atomic counters, not a per-mm lock). The real-kernel detail most
worth promoting next is the lookup-vs-free ordering (item 2).
