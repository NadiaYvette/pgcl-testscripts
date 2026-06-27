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

# PGCL #143 — PART II: modeling the ORPHAN PTE (the structural three-way model)

Date: 2026-06-27 (later session). The Part-I models above track ONLY the
refcount and "proved" a folio_try_get fix class. Since then, on the live -smp8
reproducer, FOUR count-based fix hypotheses were **A/B-REFUTED** (reclaim
TTU_SYNC skip; producer installs a PTE at refcount 0; mis-set PageAnonExclusive;
migrate mapcount/refcount imbalance) and a **freeze-while-mapped tripwire came
back a CLEAN NEGATIVE** (`__remove_mapping` never frees a folio with
`folio_mapped()` true). They all refute for one structural reason:

  **#143 is an ORPHAN PTE** — a sub-PTE that stays PRESENT in some mm's page
  table *after* that mapping's rmap entry AND its refcount contribution were
  already removed. The orphan is INVISIBLE to refcount/mapcount invariants: the
  leftover PTE is UNCOUNTED (its rmap is gone) and the freed cluster's refcount
  reached 0 *normally* (every static path balances — the whole hunt confirms it).

So Part II builds a model whose state is EXPLICIT and THREE-WAY per (mm,sub-PTE):
`pte_present[mm][i]` (the page-table bit), `rmap_sub[mm][i]`/`rmap_mmupage[mm]`
(the rmap), and a shared `refcount`. Two mms share the cluster (fork parent +
child — the sd-parse-elf children share file/anon pages), each with its OWN
per-pte-table page-table lock (PTL).

## II.0 Artifacts (formal/)
- `pgcl_orphan_pte.c`        — the §4 STRADDLE PTL-drop model, faithful locking.
- `pgcl_orphan_pte_witness.c`— minimal readable corroboration of the same.
- `pgcl_orphan_pte_v2.c`     — variant (b): a concurrent fault re-adds a mapping.
- `pgcl_orphan_pte_v3.c`     — variant (c): UNIT-MISMATCH teardown. **Exposes the orphan.**
- `run-orphan.sh`           — one-shot reproducer for all of the above.

## II.1 Kernel grounding (read-only, /home/nyc/src/linux; nothing modified)
The model is built against the actual PGCL paths:
- `mm/page_vma_mapped.c` `page_vma_mapped_walk()`: under PGCL the walker yields
  one cluster's worth of consecutive same-PFN sub-PTEs per PTL section
  (`pvmw->nr_mmupages`, lines ~316-369). At `next_pte` (lines ~374-388) when the
  address crosses a pte-table (PMD) boundary it does
  `spin_unlock(pvmw->ptl); pte_unmap(); flags |= PVMW_PGTABLE_CROSSED; goto restart;`
  — i.e. it **DROPS the PTL mid-cluster** when a cluster STRADDLES a pte-table,
  re-acquiring a fresh PTL for the next table. This is the §4 leading hypothesis.
- `mm/rmap.c` `try_to_unmap_one()` (~2164-2551): per PVMW yield, UNDER the PTL,
  `get_and_clear_ptes(nr)` → `folio_remove_rmap_subptes(nr)` → `folio_put_refs(nr)`
  (the put can reach 0 and free, INSIDE the per-yield PTL section). The `nr` is
  `pvmw.nr_mmupages` (MMUPAGE units).
- `mm/memory.c` `zap_present_folio_ptes()` (~1843): `clear_full_ptes(nr)` →
  `folio_remove_rmap_ptes(nr)` (under the mm's PTL), then `__tlb_remove_folio_pages`
  **DEFERS** the `folio_put` to `tlb_finish_mmu` (lockless, after the PTL).
- `mm/memory.c` `do_swap_page()` (~5650-5695) fault order: `folio_ref_add(nr)` →
  `folio_add_anon_rmap_ptes` → `set_ptes(nr)` (PTE installed LAST), all under the
  faulting PTL.
- `mm/vmscan.c` `__remove_mapping()` (~729): `folio_ref_freeze(folio, 1+nr_pages)`
  — freezes/frees iff actual == expected; a fault that bumped refcount makes
  actual > expected → freeze fails SAFE.

CBMC faithfulness: per yield/batch the PTE-clear + rmap-drop run under that
section's PTL, so they commit ATOMICALLY w.r.t. other actors — modeled with
`__CPROVER_atomic`. The PTLs are modeled PER pte-table (not per-mm-global) so the
"drop the PTL at a pte-table boundary mid-cluster" window is real. The two mms
have SEPARATE PTLs (fork parent vs child), so no single PTL serialises them.

## II.2 RESULT — the §4 PTL-drop hypothesis, ALONE, does NOT orphan
`pgcl_orphan_pte.c`: straddle PVMW walk over mm0 (two yields, PTL dropped between)
|| deferred zap of mm1. Assertion: NO_FREE_WHILE_MAPPED checked at the EXACT
instant the cluster is freed (inside `put_refs`, when refcount hits 0 — the moment
the frame returns to the allocator), plus a final-state NO_ORPHAN.

  `cbmc pgcl_orphan_pte.c --unwind 8 --unwinding-assertions` → **VERIFICATION
  SUCCESSFUL** (0 of 33; exhaustive within bounds — all loop-unwinding
  assertions pass). `pgcl_orphan_pte_witness.c` corroborates (SUCCESSFUL).

WHY it is safe (the structural reason, decisive for the hunt): in BOTH
`try_to_unmap_one` and `zap_present_ptes` the `folio_put` for a yield/batch is
sequenced AFTER that yield's PTEs are cleared. So the refcount cannot reach 0
while any *contributing actor* still holds a present PTE — the last put is always
preceded by its own clear. Dropping the PTL mid-cluster, and deferring the put,
re-orders WHEN refs/PTEs are dropped but preserves the per-actor "clear-then-put"
order. **An arbitrary observer can see a brief mid-teardown transient, but never a
free-while-mapped.** This matches the live evidence: the freeze tripwire (a real
"observer at free") fired 0/4 while corruption fired 4/4.

## II.3 Variant (b) — a concurrent FAULT re-add is ALSO insufficient
`pgcl_orphan_pte_v2.c`: a `do_swap_page`-faithful fault (ref;rmap;set_ptes, PTE
last, under mm1's PTL) re-installs a sub-PTE of mm1 while mm0's straddle walk
tears down, with a stable pagecache/swapcache existence ref present.

  GUARD=1 (folio_try_get) → **SUCCESSFUL**;  GUARD=0 (plain folio_get) →
  **SUCCESSFUL** (both `--unwind {6,8,12} --no-unwinding-assertions`, stable).

Notable: even WITHOUT folio_try_get the fault cannot orphan here, because the
fault holds the PTL across its install and the existence ref dominates so the
refcount never hits 0 mid-fault. This SHARPENS Part I: the bug is not a bare
fault-vs-teardown ref race. (Soundness note: v2 has a contended spinlock between
W and F on mm1's lock whose *termination* CBMC cannot prove — the known spurious
spin-loop unwinding artifact, same as `pgcl_cluster_locked.c`. The SAFETY result
is sound; only the loop-termination claim is not. The safety verdict is stable
across unwind bounds, so it does not rest on cutting the spin short.)

## II.4 Variant (c) — UNIT-MISMATCH teardown EXPOSES the orphan  ★
`pgcl_orphan_pte_v3.c`: two teardown paths that DISAGREE on the counting unit for
the SAME cluster — one in MMUPAGE units (PAGE_MMUCOUNT sub-PTEs/cluster), the
other in CLUSTER units (1/cluster). All `--unwind 8 --unwinding-assertions`
(fully sound — every loop unwinds within the bound):

  MISMATCH=0 (both MMUPAGE-uniform = the intended live contract) → **SUCCESSFUL**.
  MISMATCH=1 (clear ALL PTEs but drop only 1 ref+rmap/cluster = UNDER-remove)
     → **FAILED**: `freed` never true (a LEFTOVER ref of PAGE_MMUCOUNT-1 stays
       STUCK; the folio is never freed when it should be) and rmap drifts positive
       (`rmap != present-PTE count`). = the "net +1 stuck mapping" signature.
  MISMATCH=2 (clear only 1 PTE but drop PAGE_MMUCOUNT refs = OVER-drop)
     → **FAILED**: `!ANY_PTE_PRESENT()` violated at the freeing instant —
       refcount hits 0 and the cluster is FREED while PAGE_MMUCOUNT-1 sub-PTEs are
       STILL PRESENT. = the ORPHAN PTE / free-while-mapped → `print_bad_pte`.

THE ORPHAN SCHEDULE (MISMATCH=2, from run-orphan.sh; NSUB = PAGE_MMUCOUNT = 4 in
the model; A = mm0 walk = thread1, B = mm1 zap = thread2):
  1. start: both mms map the cluster; refcount = 8 (4 sub-PTE refs each, MMUPAGE).
  2. B (mm1): clears all 4 PTEs + drops rmap, deferred put -8... no:
     B's deferred put drops NSUB=4 refs:        refcount 8 -> 4.
  3. A (mm0): clears exactly ONE PTE (cluster-unit clear): pte_present[0][0]=0;
     the other three (pte_present[0][1..3]) REMAIN PRESENT.
  4. A drops 1 rmap (cluster-unit):             rmap_mmupage[0] 4 -> 3.
  5. A's deferred put drops PAGE_MMUCOUNT=4 refs (MMUPAGE-unit ref drop, the
     mismatch):                                 refcount 4 -> 0  => freed = 1.
  6. AT THE FREE INSTANT: pte_present[0][1], [0][2], [0][3] are STILL 1.
     -> three ORPHAN PTEs into a just-freed cluster. Next reuse of that frame =
     "BUG: Bad page map ... mapcount:-1" / PID1 SIGSEGV.
  The books look locally fine: refcount reached 0 (not negative, no resurrection),
  rmap was decremented — exactly why count-based invariants and folio_try_get
  cannot see it.

## II.5 The structural invariant that breaks, and the concrete kernel mapping
INVARIANT BROKEN: **the PTE-clear unit and the ref/rmap-drop unit for one cluster
must be IDENTICAL** (both MMUPAGE, or — equivalently — every dropped ref must
correspond to exactly one cleared sub-PTE). When they diverge, refcount reaches 0
out of step with the present-PTE set → free-while-mapped (over-drop) or a stuck
ref + permanent rmap drift (under-drop). This is a relation between the page-table
and the counts that NO purely-count invariant expresses.

CANDIDATE KERNEL SITES where a unit divergence for a SHARED, possibly
table-straddling cluster could arise (audit targets, in priority order):
  (1) `mm/page_vma_mapped.c` `page_vma_mapped_walk()` `nr_mmupages` batching vs the
      `next_pte` PMD-boundary PTL-drop: a cluster STRADDLING a pte-table is
      yielded as TWO batches. Each `try_to_unmap_one`/`try_to_migrate_one` yield
      then clears `nr_mmupages` PTEs and drops `folio_remove_rmap_subptes(nr)` +
      `folio_put_refs(nr)` for THAT batch — self-consistent IF and ONLY IF the
      batch's PTE count, rmap count, and ref count are the same `nr`. The hazard
      is any path that computes one of the three from `folio_nr_pages`/cluster
      units while the others use the per-yield `nr_mmupages` (e.g. a "this yield
      finished the whole folio" shortcut at `nr_pages == folio_nr_pages*PAGE_MMUCOUNT`
      that fires on a PARTIAL straddle yield, or an rmap/`folio_put` issued ONCE
      per folio instead of once per yield).
  (2) `mm/migrate.c` `remove_migration_pte()` vs `try_to_migrate_one()`: the
      add-side must restore the SAME unit the tear-down removed. The #140/contract
      history is exactly an i_mmap / rmap-walk query in the wrong unit; a migration
      that re-adds in cluster units what was removed in MMUPAGE units (or v.v.)
      across a straddling/ gapped cluster reproduces MISMATCH=1/2.
  (3) `mm/rmap.c` `folio_referenced_one()` and any other PVMW consumer that
      decrements `pra->mapcount -= pvmw.nr_mmupages` (rmap.c:939) — these must use
      the SAME `nr_mmupages` the clear side used; a `PVMW_PGTABLE_CROSSED` early-out
      (rmap.c:952) on a straddling cluster can leave the far table's sub-PTEs
      unaccounted.
  (4) Residual non-MMUPAGE-converted remove site (the memory's "a ref dropped
      WITHOUT clearing its PTE" — exactly MISMATCH=2 with the extreme that the PTE
      clear count is 0 for some sub-PTEs).

## II.6 The precise fix this implies
The model says the fix is NOT a refcount discipline (try_get) and NOT a lock
(per-mm PTL can't serialise the two mms; even the right lock doesn't fix a unit
bug). The fix is a UNIT INVARIANT, enforced where teardown happens:

  **Every cluster teardown must drop exactly as many refs and as much rmap as the
  number of sub-PTEs it actually cleared, per PTL section** — i.e. clear, rmap-
  drop and ref-drop are driven by the SAME `nr` (`pvmw.nr_mmupages` for the PVMW
  walk; the batch `nr` for zap), with NO cluster-unit shortcut and NO per-folio
  once-only rmap/put on a path that can see a partial (table-straddling or gapped)
  cluster. Concretely: in `try_to_unmap_one`/`try_to_migrate_one` keep
  `get_and_clear_ptes(nr)`, `folio_remove_rmap_subptes(nr)` and `folio_put_refs(nr)`
  all keyed off the SAME per-yield `nr_mmupages`, and make the "whole-folio done"
  early-out (`nr_pages == folio_nr_pages*PAGE_MMUCOUNT`) impossible to reach on a
  partial yield; and ensure `remove_migration_pte` re-adds with the identical unit.
  An auditable phrasing: **a present sub-PTE and its (rmap, ref) contributions are
  created and destroyed as a single indivisible triple — never split across units
  or across an unsynchronised PTL gap with a different count on each side.**

A cheap in-kernel TRIPWIRE the model motivates (catches the unit bug directly,
unlike the mapcount-only freeze probe that came back negative): at every cluster
`folio_put`/`folio_put_refs` that takes the count to 0, walk the cluster's rmap
and assert the cluster has NO present PTE in any mm (the MISMATCH=2 condition) —
and at every `folio_remove_rmap_subptes(nr)` assert `nr` equals the number of
sub-PTEs cleared in the same critical section (the MISMATCH=1 condition). This is
the structural check; the existing mapcount/refcount balance probes are blind to
it by construction.

## II.7 CBMC bounds & exhaustiveness (Part II)
- Threads: 2 teardown actors (W,Z / A,B) modeled as `__CPROVER_ASYNC` blocks
  (every statement is an interleaving point — strictly MORE interleavings than
  pthreads, and faithful to the PTL gap); v2 adds a fault actor. SC and the model
  is interleaving-based, so weak memory adds nothing here (Part I checked --mm tso).
- State: NMM=2 mms, NSUB=4 sub-PTEs/cluster (= PAGE_MMUCOUNT in the model; real
  PAGE_MMUCOUNT=16). The unit-mismatch is a RATIO bug (MMUPAGE vs cluster), so
  NSUB=4 vs 16 changes only magnitudes (refcount 8->0 vs 32->0; 3 orphans vs 15);
  the reachable violation is unchanged. The straddle is BND=2 (two groups of two).
- `pgcl_orphan_pte.c` and `pgcl_orphan_pte_v3.c` (all 3 MISMATCH modes): run with
  `--unwind 8 --unwinding-assertions` and ALL loop-unwinding assertions PASS ⇒ the
  result is **EXHAUSTIVE within the bound** (no reachable interleaving omitted).
- `pgcl_orphan_pte_v2.c`: SAFETY (the data assertions) verified SUCCESSFUL and
  STABLE across `--unwind {6,8,12}`; its contended-spinlock TERMINATION cannot be
  proven by CBMC (spurious spin-loop artifact). The orphan/no-orphan conclusion
  does not depend on this.

## II.8 Relationship to Part I and to Tessera
Part I (refcount strand) is not wrong — it correctly shows that IF a cluster ref
is acquired with a plain increment that can race a concurrent free, try_get +
existence ref is required. But the live A/B refutations show that strand is not
the laptop bug. **Part II is the STRUCTURAL strand: #143 is a unit-mismatch
between the page-table and the (rmap, refcount) books, producing a present PTE
over a freed cluster — an orphan invisible to both counts.** For Tessera, this is
a new obligation BELOW the refcount race: the Rung-2/3 `WF b := mapcount =
sites.length` and the refcount discipline must be stated in a SINGLE unit, and the
teardown step must be proven to change (pte-set, mapcount, refcount) by the same
delta atomically — a `UnitCoherent` invariant that, dropped, yields exactly the
MISMATCH=2 step-list (the Lean transcription of the §II.4 schedule). The
lookup-vs-free item flagged in Part I (#140 family) is the same root: a coordinate
computed in the wrong unit.

BOTTOM LINE (Part II): a three-way (pte_present, rmap, refcount) model that can
SEE the orphan shows the §4 PTL-drop-mid-cluster hypothesis is, by itself,
INSUFFICIENT to produce #143 (VERIFICATION SUCCESSFUL), as is a concurrent fault
re-add. The orphan REQUIRES a unit-mismatch between the PTE-clear and the
ref/rmap-drop for a shared, table-straddling/gapped cluster — `pgcl_orphan_pte_v3.c`
exhibits the exact free-while-mapped schedule. The implied fix is a UNIT
INVARIANT (clear / rmap-drop / ref-drop driven by one identical per-PTL-section
`nr`, no cluster-unit shortcut, no per-folio once-only put on a partial-yield
path), enforced in `try_to_unmap_one` / `try_to_migrate_one` / `remove_migration_pte`
and guarded by the structural tripwire of §II.6 — not a refcount-discipline or a
lock change.
