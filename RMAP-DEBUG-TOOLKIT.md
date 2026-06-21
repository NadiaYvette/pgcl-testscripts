# Rmap mapcount/refcount race-debugging toolkit

A reusable kit for the recurring, hard class of mm bug: **folio
mapcount/refcount imbalance** — underflow, over-remove, freed-while-mapped,
dangling PTEs — especially the cross-mm / racy variety that static review and
ordinary tracing miss.

Born out of the PGCL #143 hunt (order-0 file+anon rmap underflow under
COW-vs-reclaim), but the kernel tracer and the methodology are **not
PGCL-specific** — they apply to any folio whose `_mapcount` / refcount goes
wrong. The PGCL-only bits are clearly marked.

Status: the kernel pieces currently live as **uncommitted debug** in the linux
work tree (snapshotted under `rmap-ab/tree-backup/rmap-trace-snapshot-*.diff`).
This doc is the manifest for turning them into a clean, Kconfig-gated,
reusable feature once #143 is closed and the tracer is final.

---

## A. Kernel-side (mm/rmap.c, mm/memory.c, mm/swap.c, mm/internal.h)

### A1. Non-perturbing per-pfn mapcount-event tracer  *(generic)*
`pgcl_ev2_log()` / `pgcl_ev2_dump()` + `pgcl_buckets2[]`.

- **Storage**: a hash of **per-pfn buckets** (`pfn & (NB-1)`), each with split
  `add[]` / `rem[]` rings (so a teardown's removes can't evict the adds) and a
  per-bucket atomic head. Records `(ts, pfn, vaddr, delta, mapcount, refcount,
  tag, cpu)` at every mapcount-mutation site.
- **Tags**: `a` __folio_add_rmap, `A` folio_add_rmap_subptes, `n`
  folio_add_new_anon_rmap, `c` COW-extra, `e` eager-anon, `f` anon fork-dup,
  `F` file fork-dup, `r` __folio_remove_rmap, `R` folio_remove_rmap_subptes.
- **Dump**: on a corruption catch, gather the victim pfn's events across all
  CPUs and sort by `local_clock` ts → the **cross-CPU add/remove timeline** for
  that one cluster.
- **Remove vaddrs**: removers stash their vaddr in a per-CPU slot
  (`pgcl_ev2_rm_va()`, set at zap / try_to_unmap_one / try_to_migrate_one) so
  REMOVE events record *where* the torn-down PTE was → identifies a dangling
  PTE (a remove whose vaddr belongs to an old incarnation of a reused pfn).

**The two design lessons that make it work** (both cost us many cycles):
1. **No shared-atomic hot-path state.** Earlier rings used a global
   per-free "generation" `atomic_inc` to defeat pfn-reuse pollution — that
   single bouncing cacheline *suppressed the very race* (0 catches). Per-pfn /
   per-CPU storage with no global atomic does not perturb the timing.
2. **Use the per-event `refcount` to mark free/reuse boundaries** instead of a
   generation counter. `rc==0` on an event = the folio was freed; a later add
   at the same pfn = a reused incarnation. This breaks the catch-22 (clean
   per-incarnation history *needed* gen, but gen suppressed the bug).

### A2. Corruption detectors  *(generic)*
- `pgcl143_wp_check()` — order-0 `_mapcount < -1` underflow, at the remove
  sites; prints state + dumps the timeline.
- `pgcl143_freed_mapped()` — `folio_mapped()` true at `__folio_put()` (folio
  freed while still counted-mapped); the backtrace names the ref-dropper.
- remove-on-freed — a remove landing on a `refcount==0` folio (the
  dangling-PTE aftermath).

### A3. Cross-CPU concurrent-op attributor  *(generic)*
`pgcl_wp_publish()` / the scan in `pgcl143_wp_check()`: each candidate path
publishes "which folio pfn am I mid-operating-on" into a per-CPU slot; at the
catch we scan the other CPUs → names the concurrently-racing CPU and path.
(Used to refute `wp_page_copy` as the racing party.)

### A4. NMI all-CPU backtrace + optional freeze  *(generic, from earlier rings)*
`trigger_all_cpu_backtrace()` at the catch to snapshot every CPU's stack
before residual execution mutates state.

---

## B. Userspace reproducers (userspace/)
Race/edge triggers; candidates for mm selftests.

- **file_reclaim_race_repro.c** — the #143 trigger: keep a btrfs file mapped
  MAP_PRIVATE, COW it continuously, fork so parent+child COW at once, while a
  memory hog forces reclaim to try_to_unmap the same folios concurrently.
- **file_rmap_repro.c** — dlopen/dlclose-shaped: private file map at sub-cluster
  offsets, mixed prots, COW (file→anon), RELRO-style mprotect VMA splits, fork,
  partial munmap, exit-zap. + a SHARED+writeback variant.
- **file_fork_repro.c**, **file_largefolio_repro.c**, **file_collapse_repro.c**,
  **file_dlopen_repro.c** — narrower variants (fork, large-folio mmap, THP
  collapse, dlopen).
- **mm_stress_pgcl.c**, **init-anon-stress.c** — broad anon/mm stressors.

## C. Harness (rmap-ab/)
- **run-rr.sh** — boot a testbed in QEMU (ext4 root + swap + btrfs vdc) with a
  given bzImage, capture the serial log. The reproducer autoruns from the
  testbed init.
- **run-tldiag.sh** (and siblings) — build (`taskset` to the build CPUs) +
  N-run A/B pipeline + per-run grep summary.
- **iso** — stateless CPU-confinement wrapper (`taskset` to the work cores).
  STATELESS by design: re-applied per process, so it survives session/API
  interruptions (unlike a cgroup partition, whose management state is lost on
  interruption). See the CPU-isolation note below.
- **setup-cpu-partitions.{sh,wrap}** — cgroup-v2 *isolated* cpuset partitions
  (setuid wrapper, since the kernel ignores setuid on scripts). DORMANT: a hard
  partition for our cores alongside another agent's would starve the OS, and
  taskset within the root-effective set is the robust choice. Kept for the
  case where hard scheduler-exclusion is actually wanted.

### The A/B oracle
The strongest validation signal we found: **`-smp 1` boots clean, `-smp 8`
(2× oversubscribed on a small core set) reproduces**. A real fix must take the
smp8 column from "dies N/8" to "0/8" while smp1 stays clean — a crisp,
noise-resistant accept/reject for any candidate fix, far better than eyeballing
one run.

---

## D. Methodology (the arc, as a template for hard mm race bugs)
1. **Reproduce in QEMU** with a focused userspace trigger + the A/B oracle.
2. **Static-audit every add/remove path** for unit/count correctness. When they
   all balance *in isolation*, that itself is the finding: it's a race.
3. **Prove cross-mm vs same-mm** cheaply: disable `SPLIT_PTE_PTLOCKS` (collapse
   to one mm-wide lock). If the bug survives, the racing parties are in
   different mms — no per-mm lock can gate them; the sync must be at
   folio/anon_vma granularity.
4. **Catch the race without suppressing it** with the A1 tracer (per-pfn,
   per-CPU, no shared atomics). Read the cross-CPU timeline to see the
   *creating* event, not just the *consequence*.
5. **Validate the fix** against the A/B oracle.

Recurring traps documented the hard way: shared-atomic probes suppress tight
races; KCSAN perturbs heavily and misses pure atomic-ordering; a ring must
retain per-pfn history (a flat ring rolls the adds out under load); the
consequence (teardown underflow) is often far in time and space from the cause
(the dropped/uncounted mapping).

---

## E. Productization plan (after #143 is fixed)
1. **Kconfig-gate the tracer** as `CONFIG_DEBUG_RMAP_TRACE` (depends on
   `DEBUG_VM`), zero overhead when off. Drop the PGCL-specific `#if
   PAGE_MMUSHIFT` guards where the logic is generic (the order-0 `_mapcount`
   path is mainline; only the sub-PTE `A`/`R` tags are PGCL).
2. **Reproducers → tools/testing/selftests/mm/** (or a local test suite),
   generalized off btrfs/PGCL where possible.
3. **Harness → a documented rig**: `run-rr.sh` + `iso` + the A/B oracle as a
   small "smp race A/B" harness, with the CPU-isolation note.
4. **This methodology doc** as `Documentation/mm/` material or a blog/LWN-style
   writeup — the cross-mm-proof + non-perturbing-tracer recipe is broadly useful.
