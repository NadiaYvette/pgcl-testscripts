---
name: rmap-debug-toolkit-byproduct
description: The
metadata: 
  node_type: memory
  type: project
  originSessionId: 443a8d37-2901-482f-b7cd-76625947368f
---

The in-kernel rmap mapcount/refcount race-debugging infrastructure built during
the [[pgcl143-rmap-underflow-hunt]] — plus its userspace reproducers and the
CPU-isolated A/B harness — is a **valuable reusable byproduct**, not PGCL-specific.
Rmap accounting imbalance (underflow / freed-while-mapped / dangling PTE,
especially cross-mm/racy) is a recurring hard mm-bug class, and this kit targets it.

**Manifest:** `/home/nyc/src/pgcl/RMAP-DEBUG-TOOLKIT.md` (catalogues the kernel
tracer/detectors/attributor, the userspace reproducers `userspace/file_*_repro.c`,
the `rmap-ab/` harness, the methodology, and the productization plan).
**Kernel snapshot (uncommitted debug):** `rmap-ab/tree-backup/rmap-trace-snapshot-*.diff`.

Key reusable pieces: (1) **non-perturbing per-pfn mapcount-event tracer** —
per-pfn buckets, per-CPU, NO global gen-hook (a shared per-free atomic SUPPRESSES
the race); use the per-event `rc` to mark free/reuse boundaries instead of a gen
counter; (2) underflow / freed-while-mapped / remove-on-freed detectors; (3)
cross-CPU concurrent-op attributor; (4) the A/B oracle (smp1-clean vs smp8-corrupt)
as a crisp fix accept/reject; (5) the methodology (static-audit→split-ptl cross-mm
proof→non-perturbing race-catch).

**2026-06-21 additions (keepers, per Nadia — both for the framework AND as standing
A/B fix-validation instrumentation):** (6) **vaddr+mm install attributor**
(`pgcl_va_dump`/`pgcl_va_buckets`, manifest A5) — cluster-vaddr-keyed bucket of
install ADDs tagged with owning `mm`; survives pfn free+reuse (keyed by vaddr not
pfn) and the `mm` field kills the fork-shared-vaddr confound (flags
`(same-mm)`/`(other-mm)`, `>>>` = same-mm victim-pfn install = creator of the
dangling PTE); (7) **file-PTE install logging** (`S` tag at `set_pte_range`,
manifest A6) — file installs otherwise carry no vaddr, so without it a dangling
*file* PTE reads as "no install retained"; (8) **lean on the kernel's own checks**
(A7) — `bad_page "nonzero mapcount"` + `BUG: Bad page map` already fire with the
freer/zapper backtrace (this is what nailed #143's file-reclaim dangling PTE).
**Enriched A/B accept criteria:** a real fix must zero `bad_page`/`Bad page map`
hits, `#143wp` underflows, AND `>>>` culprit lines (+ balanced install/remove
timeline) across the smp8 batch — not merely drop the panic rate (else it's hiding
the race). See [[pgcl143-rmap-underflow-hunt]] for the #143 application.

**Why:** **How to apply:** PRESERVE — don't let it be lost when the #143 debug is
reverted (snapshot is saved). PRODUCTIZE **after #143 is fixed** (tracer then
stable): Kconfig-gate the tracer (`CONFIG_DEBUG_RMAP_TRACE` dep `DEBUG_VM`, drop
the `#if PAGE_MMUSHIFT` guards where generic), reproducers → selftests/mm, harness
→ a documented smp-race A/B rig, methodology → Documentation/mm or a writeup.
Potentially upstreamable independently of PGCL and a value-add for the PGCL series.

**Coalescing technique for the future set_ptes install-tracer (Nadia's profile.c lineage, 2003).** The pgcl4pc per-pfn ring thrashed because it was a large (16MB/CPU vmalloc) RANDOMLY-accessed working set, one random bucket per rmap op. Nadia's kernel/profile.c design (per-CPU PAIR of page-sized hashtables that coalesce hits locally until overflow, then batch-retire to a global buffer and swap the dueling tables) keeps the hot working set L1/L2-resident — the correct fix for the thrash. Does NOT fit a TIMELINE need (coalescing discards order + per-event timestamps; we needed the ordered map->remove sequence). DOES fit a future PTE-INSTALL tracer: set_ptes is a hot, high-key-repetition path (same callers/clusters) = the profile.c sweet spot; key a per-CPU page-sized hashtable by caller-PC, count installs vs rmap-adds, batch-retire. Queue this for productizing the toolkit's "install-balance" probe; do NOT use a flat/random ring on any hot path.
