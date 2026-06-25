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

**Latest full snapshot (2026-06-22): `rmap-ab/tree-backup/rmap143-debug-snapshot-0aceb3e9864a-mmva-tombstone.diff`** (1034 lines, 7 files: rmap.c/memory.c/migrate.c/swap.c/truncate.c/vmscan.c/internal.h). Adds, on top of A1–A7 below: the **deep large-folio-only per-pfn ring** (`pgcl_lev`, head-pfn-keyed, retains a folio's full per-sub-PTE add/remove history under flood); the **(mm,va)-EXACT trackers** — a cluster-keyed add/remove bucket with net-classification `pgcl_va_dump` (under- vs over-remove verdict) and a per-`(mm,va)` **tombstone** hash `pgcl_svtab` (add-set / first-remove-tombstone / second-remove = double-remove dump) that survives pfn reuse and names install vs first-remove paths; **caller-tagged removes** (`pgcl_rm_caller`: `z`=zap/munmap/truncate, `w`=rmap-walk reclaim/migrate) so a remove's *path* is recorded; the `S`(set_pte_range file install) and `M`(migration restore) add tags. These are what drove the #143 narrowing to "shared FILE folio, aggregate/cross-mm over-decrement" — see [[pgcl143-rmap-underflow-hunt]] for the result trail.

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

### A5. vaddr+mm install attributor  *(generic; keeper)*
`pgcl_va_dump()` / `pgcl_va_buckets[]` — a second hash keyed by the **cluster
virtual address** (`vaddr >> PAGE_SHIFT`, so all sub-PTEs of a cluster collide)
holding the recent vaddr-bearing install ADDs, **each tagged with its owning
`mm`**. The pfn-bucket (A1) loses a dangling PTE's *creating* add once the pfn is
freed+reused; this bucket survives that (keyed by vaddr, not pfn). On a catch,
`pgcl_va_dump(rm_va, rm_mm, victim_pfn)` prints the cluster's installs and flags
`>>>` the **same-mm install of the victim pfn** = the add that created the
dangling PTE. The **`mm` field is essential**: the repro forks, children inherit
parent vaddrs, so a vaddr-only bucket conflates processes — `(same-mm)` vs
`(other-mm)` annotation removes that confound. Remove paths stash their `mm` in a
per-CPU slot (`pgcl_rm_mm`, set in `pgcl_ev2_log` on every remove) so the catch
can mm-match.

### A6. file-PTE install logging  *(generic; keeper)*
The file fault install path (`set_pte_range` → `folio_add_file_rmap_ptes`, the
`a`/`A` rmap tags) carries **no vaddr**, so a dangling *file* PTE shows up as "no
install retained" in A5. The `S` tag logs file installs **with their vaddr+mm**
(diagnostic only, no mapcount mutation; `delta` = sub-PTE count installed). Lets
A5 attribute file dangling PTEs and lets the A1 timeline compare **install count
vs reclaim-remove count** for a folio — the gap is the orphaned sub-PTE(s).

> A5+A6 are kept beyond #143: rmap dangling-PTE / freed-while-mapped bugs are a
> recurring class, and "which mm+vaddr installed this, file or anon" is the
> attribution any such hunt needs. They are also **A/B fix-validation
> instrumentation** (see the oracle below) — leave them ON when testing fix
> candidates.

### A7. lean on the kernel's own checks  *(free, always-on)*
`free_pages_prepare` (`bad_page "nonzero mapcount"`) and `vm_normal_page`
(`BUG: Bad page map`) already fire when a freed page is still mapped / a PTE
points at a freed page — with the **freer/zapper backtrace + page state**. Grep
the serial log for these *before* reaching for custom probes; #143's smoking gun
(`Bad page map ... ext4 file vma ... pfn refcount:0 mapcount:-1`) came from here.

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

**Mechanistic accept criteria (richer than symptom-gone).** With A5/A6/A7 left
ON during fix-candidate A/B runs, a *real* fix must zero ALL of these across the
smp8 batch — not just the panic count:
- `bad_page` / `Bad page map` hits → 0 (no freed page still mapped / no PTE on a
  freed page),
- `wp_check` order-0 underflow (`#143wp`) → 0,
- `pgcl_va_dump` `>>>` culprit lines (same-mm victim-pfn install) → 0,
- the A1 timeline shows **install count == remove count** per folio (no orphaned
  sub-PTE).
A candidate that drops the panic rate but still logs `Bad page map` is hiding the
race, not fixing it. (#143's catch is ~1/8 runs and inversely correlated with the
panic manifestation, so average over a multi-run loop-until-caught batch, e.g.
`rmap-ab/run-va-batch.sh`.)

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

---

## F. QEMU-side instrumentation (the non-perturbing breakthrough, 2026-06-25)
In-kernel probes hit a **perturbation wall** (printk/ledger change the race
timing and hide tight rmap/TLB races). Moving the probes OUTSIDE the guest, into
QEMU TCG, sidesteps this: QEMU-side work does not change the guest's logical
execution, so the race outcome is preserved.

**Saved:** `rmap-ab/tree-backup/qemu-143-debug-instrumentation.patch` (+ companion
`QEMU-143-DEBUG-README.md`). Base: qemu.git v10.1.4 (384ba786). `git apply` then
`ninja -C build qemu-system-x86_64`.

**Channel:** guest kernel `mm/page_alloc.c pgcl143_qsig()` emits cpuid leaf
`0x5143000{1,0}` on every page free/alloc (ebx=guest-4K-frame base, ecx=#frames).
No-op without QEMU. (Kernel patch saved separately.)

**Probes (env-armed, composable):**
- **TLB-scan** (`PGCL_TLBSCAN`, accel/tcg/cputlb.c): per-4K-frame reverse map of
  the last USER (cpu,vaddr) filled at tlb_set_page_full; at FREE/ALLOC verifies
  the softmmu-TLB entry still maps the freed/reused frame
  (FREE-WHILE-USER-MAPPED / ALLOC-INTO-STALE-MAPPED), distinguishing stale-TLB
  vs present-dangler. + PGCL_OVERFLUSH (escalate page/range flush → full) as a
  range-vs-cpumask discriminator.
- **dangle/rmap-walk** (`PGCL_DANGLE`, target/i386/tcg/system/excp_helper.c +
  helper.c CR3 hook): tracks all guest pgds (every CR3 write), periodically
  full-scans every pgd's user page tables into a frame→(cr3,va) reverse map
  (incl. COLD mappings a TLB/access probe misses), and at FREE walks all pgds at
  the recorded va → FREE-WHILE-MAPPED = the premature-free/dangling-PTE the
  in-kernel mapcount/bad_page checks structurally cannot see. **Caveats:** 4-level
  walker → run guest `-cpu max,la57=off`; reads bounded to RAM size (PGCL_RAMLIMIT)
  to avoid MMIO core-dumps. (WIP as of snapshot.)
- **stack dump** (target/i386/cpu.c): on any catch, dumps the guest kernel stack
  (PGCL143freepath / PGCL143allocpath, kernel-text-filtered) — names the
  free/alloc path from outside the kernel.

**Proven results (this rig):** ruled out TLB-flush coverage and swap-exclusivity
as the #143 cause; PGCL=0 control = 0 catches vs PGCL=4 (real, PGCL-specific);
characterized the victim as long-lived fork-shared pages reclaimed-under-process
(ip=0). See memory `pgcl143-rmap-underflow-hunt.md`.

### F.1 struct-page reader (layer inversion, 2026-06-25)
QEMU reads the guest kernel's OWN `struct page._refcount/_mapcount` from the
vmemmap (validated: 12/12 READER-OK = refcount 0 / mapcount -1 at free).
`pgcl_kwalk` (kernel-va walk, huge-page aware) + `pgcl_read_page(cluster_pfn)` +
`pgcl_uf_scan` (periodic authoritative underflow scan with per-cluster (rc,mc)
history rings). Layout via pahole (pgcl4-dbginfo vmlinux): struct page=64,
off _mapcount=48, _refcount=52; vmemmap_base 0xffffea0000000000 (nokaslr 4-level,
run -cpu max,la57=off). offset 48 is a union (page_type=PGTY_buddy=0xf0000000 on
free pages) — read as mapcount only when refcount>0. NEXT: cross-check kernel
_mapcount vs actual present sub-PTE count (pgd walk) per cluster — the
PTE-vs-struct-page discrepancy is the accounting bug directly.
