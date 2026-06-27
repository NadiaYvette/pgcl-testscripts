# surf-pagecache — CBMC findings: page-cache (xarray) ref lifecycle for a FILE folio under PGCL (#143)

**Scope.** The *page-cache ref lifecycle* of a **file** folio and its interaction
with **reclaim**, **truncation/invalidation**, and **faulting** under PGCL
(kernel page = cluster of `PAGE_MMUCOUNT` hardware MMUPAGEs). Twin of the
rmap-teardown surface in `../pgcl_orphan_faithful.c` (owned by another agent);
that file and `../FINDINGS.md` were NOT touched.

For a file folio the xarray holds ONE ref for the whole folio; that ref is what
prevents aggregate refcount==0 while mapped. So a file folio is freed-while-mapped
only if the page-cache ref is dropped while a sub-PTE is still present. Two droppers:
- Reclaim: `__remove_mapping()` (`mm/vmscan.c:686`), from `shrink_folio_list()`.
- Truncate/invalidate/splice: `__filemap_remove_folio()` (`mm/filemap.c:222`),
  from `truncate_inode_folio` / `delete_from_page_cache_batch` / `folio_unmap_invalidate`.

Question: can either drop the page-cache ref (folio freed) while a sub-PTE maps the cluster?

## Verdict: NO faithful interleave frees a mapped file folio, within bounds.

| # | race | closed by | result |
|---|------|-----------|--------|
| 1 | orphan (PTE present, rmap gone) fools `folio_mapped()` gate | gate robust to a per-mm orphan window (another mm keeps mapcount>0); faithful teardown never orphans the LAST mapping (proven on rmap surface) | `pc_orphan_gate.c` SUCCESSFUL |
| 2 | truncate vs fault re-install | folio LOCK held across both fault install and every pc removal serializes them | `pc_remove_gate.c` SUCCESSFUL |
| 3 | PGCL PAGE-vs-MMUPAGE unit mismatch in a truncate/pagecache range | truncate works in PAGE/cluster units consistently; folio removal always co-occurs with a whole-folio (all-MMUPAGE) zap; MMUPAGE conversion done correctly in the ZAP layer (`unmap_mapping_range_tree`, the #140-class fix) | `pc_truncate_units.c` MODE=0 SUCCESSFUL |

One secondary BENIGN, non-PGCL observation under #3 (beyond-EOF lingering
mapped-but-zeroed tail on the RETAINED partial folio) — not free-while-mapped (§4).

Consistent with #143 being an rmap-teardown bug, not a page-cache-ref bug: the
pc-ref machinery never drops the ref under a live mapping. IF #143 routes through
the page cache, it needs an orphan created upstream by the rmap teardown to fool
the `folio_mapped()` gate — that orphan's creation is the other model's job; this
model proves the gate is otherwise sound.

## Faithful facts encoded (read-only, /home/nyc/src/linux)

### page-cache ref and the two gates
- `folio_mapped()` is MAPCOUNT-based: `folio_mapcount(folio) >= 1` (`mm.h:1951`);
  blind to a present PTE whose rmap is gone.
- Reclaim gate (`vmscan.c` `shrink_folio_list`+`__remove_mapping`):
  `if(folio_mapped()) try_to_unmap; if(folio_mapped()) keep;` then
  `expected = 1 + folio_nr_pages(folio)` (CLUSTER units), `folio_ref_freeze(expected)`
  frees iff actual==expected (`:728-735`). Stray mapping ref -> freeze FAILS
  (cannot_free); stray orphan PTE (rmap gone) -> no ref, no mapcount -> invisible to BOTH gates.
- Truncate gate: `truncate_cleanup_folio` (`truncate.c:154`)
  `if(folio_mapped()) unmap_mapping_folio;` then `filemap_unaccount_folio`
  `VM_BUG_ON_FOLIO(folio_mapped())` (`filemap.c:155`) before `page_cache_delete` drops the ref.

Safety of both droppers hinges on NO ORPHAN at the gate.

### folio-lock serialization (load-bearing)
- Every pc-ref drop holds the folio lock: `__remove_mapping`
  `BUG_ON(!folio_test_locked)` (`vmscan.c:693`); `page_cache_delete`
  `VM_BUG_ON_FOLIO(!folio_test_locked)` (`filemap.c:140`). Audited all callers
  (truncate, shmem, readahead, memfd, huge_memory split, memory-failure) — all on a LOCKED folio.
- Every fault holds the folio lock ACROSS the install: `next_uptodate_folio`
  `folio_try_get`+`folio_trylock` (`filemap.c:3729,3738`); PTEs+rmap installed and
  lookup ref absorbed (`folio_ref_add`, `filemap.c:3886`/`memory.c:6628`) BEFORE
  unlock (`do_read_fault` `:6776`; `filemap_map_folio_range` `:4138`). Contract:
  "Locked folios cannot get truncated" (`filemap.c:3952,4004`).
=> fault-install and pc-removal are mutually exclusive at the dangerous point.

### PGCL units (where present, where correctly absent)
- xarray indexes folios in PAGE/cluster units; `vm_pgoff`/PTEs in MMUPAGE units.
  `pgoff_page_to_mmu`/`pgoff_mmu_to_page` (`mm.h:806,812`; identity at MMUSHIFT==0).
- `mm/truncate.c` has NO PGCL unit code, correctly — it works on folio (cluster)
  indices and the xarray, inherently PAGE-unit.
- MMUPAGE conversion is in the ZAP layer: `unmap_mapping_range_tree`
  (`memory.c:4822-4854`) converts first/last (PAGE) to MMUPAGE via `pgoff_page_to_mmu`,
  byte math with `MMUPAGE_SHIFT` — the #140-class fix (explicit comment `:4831-4836`).
  `unmap_mapping_folio` (`:4867`) passes the WHOLE folio PAGE span -> zaps ALL
  PAGE_MMUCOUNT sub-PTEs. `single_folio` is consulted only for THP-PMD (`:2286`),
  NOT per-PTE — targeting is purely by address range from the folio index span.

## Models (cooperative single-step scheduler, faithful to -smp1; NSUB=4 models PAGE_MMUCOUNT)

1) `pc_remove_gate.c` — ref/lock interleave (races #1+#2). Actors F(fault), R(reclaim),
   T(truncate). Invariants NO_FREE_WHILE_MAPPED + NO_PC_DROP_WHILE_MAPPED (both mapcount
   AND PTE forms). SCENARIO 1/2/3 SUCCESSFUL; SCENARIO=4 all-three (NSTEPS=14) SUCCESSFUL.
   NEGATIVE CONTROL (truncate ignores folio lock) FAILED on all four assertions => teeth.

2) `pc_truncate_units.c` — PAGE-vs-MMUPAGE arithmetic (race #3). Sweeps an ARBITRARY
   sub-cluster ftruncate offset. Encodes `start_cluster=ceil(newsize/PAGE_SIZE)`
   (`truncate.c:387`), batch removes whole clusters each co-unmapping the whole folio,
   `holebegin=round_up(newsize,PAGE_SIZE)` (`:786`), partial cluster zeroed+split not
   removed (`:217-294`). MODE=0 faithful SUCCESSFUL; MODE=1 (remove boundary cluster w/o
   unmapping survivors) FAILED; MODE=2 (under-unmap a removed cluster) FAILED.

3) `pc_orphan_gate.c` — can a faithful run CREATE an orphan the gate frees? (race #1).
   Faithful U(try_to_unmap_one straddle PVMW), Z(deferred-tlb zap), F(fault), P(pc dropper).
   SCENARIO 1/2/3 SUCCESSFUL. Sanity (orphan present AT the gate) FAILED => gate assertion
   has teeth. Gate-robustness finding: even forcing Z to drop rmap BEFORE the PTE (injected
   orphan window) stays SUCCESSFUL because a 2nd mm keeps mapcount>0; exposure needs the
   LAST mapping orphaned = the other model's domain.

## §4 Secondary BENIGN, non-PGCL observation under #3
`pc_truncate_units.c` MODE=0 -DCHECK_SIGBUS=1 FAILS — on a DATA/SIGBUS check, not safety.
Witness (MMUC=4, NCLUST=3): newsize_mmu=6 (inside cluster 1). start_cluster=ceil(6/4)=2
-> cluster 2 removed+unmapped; holebegin=round_up(6,4)=8 -> sub-PTEs>=8 unmapped; cluster 1
RETAINED (xslot=1), sub-PTEs 6,7 in [newsize=6, holebegin=8) stay PRESENT.
SAFE / not #143: (a) folio ref held, not freed — free-while-mapped invariant intact;
(b) `truncate_inode_partial_folio` ZEROES the tail (`folio_zero_range(...,2,2)`, `:246`) so
reads return zeros not stale data; (c) future faults i_size-gated (`finish_fault` `:6517-6527`);
(d) IDENTICAL at PAGE_MMUSHIFT==0 (standard partial-page truncate keeps the partial page
mapped+zeroed). Out of scope for #143.

## Bounds (explicit)
- NSUB/MMUC=4 model PAGE_MMUCOUNT (real 16@MMUSHIFT=4, 64@=6). Properties are
  structural/uniform in the sub-PTE count (every per-cluster op treats all PAGE_MMUCOUNT
  sub-PTEs uniformly; nothing branches on the value), so 4 exercises the same structure as
  larger values. `pc_truncate_units.c` additionally sweeps an ARBITRARY newsize_mmu (all
  sub-cluster alignments).
- NMM=2 mms; orphan-gate robustness needs >=2 (one keeps mapcount>0); 2 is minimal witness.
  Single-mm last-mapping orphan reduces to the rmap surface (`../pgcl_orphan_faithful.c`).
- NCLUST=3: removed range + retained partial boundary + fully-retained cluster.
- NSTEPS sized so every actor completes; non-vacuity confirmed by a coverage probe (final
  assert -> assert(0) gives FAILED => a complete interleave & the assume are reachable).
  --unwind >= NSTEPS+1 for the scheduler loop.
- BOUNDED proofs (no orphan/free-while-mapped within these sizes); not unbounded, but the
  uniform structure + arbitrary truncate-offset sweep make a larger-size escape implausible
  for this surface.

## Reproduce
    cd /home/nyc/src/pgcl/rmap-ab/formal/surf-pagecache && ./run.sh

## If a free-while-mapped bug surfaces on this path, the model says it is one of:
(a) a missing folio lock on some pc-removal or fault-install caller (breaks serialization —
    caught by pc_remove_gate.c negative control); (b) a PAGE/MMUPAGE unit error in a
    truncate/unmap range so removal and unmap disagree on which sub-PTEs (caught by
    pc_truncate_units.c MODE=1/2); or (c) an ORPHAN delivered from the rmap teardown (the
    other surface) reaching the gate as the LAST mapping. (a),(b) negative within bounds here;
    (c) is ../pgcl_orphan_faithful.c's domain.
