---
name: pgcl-mmupage-rmap-contract
description: pgcl4/6 file-mmap data-corruption root cause (large-folio mapcount unit mismatch) + the VERIFIED corruption fix + the decision to unify the whole-kernel rmap mapcount contract to MMUPAGE units. The real laptop "userspace fails to start" bug.
metadata:
  type: project
  originSessionId: 443a8d37-2901-482f-b7cd-76625947368f
---

**The real pgcl laptop "userspace services fail to start / grind to a halt" bug — REPRODUCED + (corruption) FIXED in QEMU 2026-06-18.** Distinct from (and on top of) the btrfs<=64K ceiling [[pgcl-btrfs-pagesize-ceiling]] — this one bites **both pgcl4 and pgcl6** (the user confirmed pgcl4 failed too), on **ext4**, so it's not fs-specific.

## Root cause (large-folio file mmap → mapcount underflow → corruption)
`set_pte_range()`/`finish_fault()` added a large **file** folio's mapcount in
**kernel-page units** (Contract A: `folio_add_file_rmap_ptes(folio,page,nr)`,
+1 per cluster) but `zap_present_ptes()` removed it in **MMUPAGE/PTE units**
(`folio_remove_rmap_ptes(folio,page,nr_ptes)`) via the upstream batch path —
file folios were excluded from the PGCL cluster-site zap (gated `folio_test_anon`).
Asymmetry → `_large_mapcount`/`_mapcount`/`_nr_pages_mapped` **underflow** →
"BUG: Bad page map" + the mmap read returns wrong data (`mmap memcmp` mismatch).
Repro: order-2 folio (1M@pgcl6 / 256K=order-2 @pgcl4) → "bad page map", all 8
io workers `CORRUPT sz=1048576 rc=-10`. Detection site: `munmap → zap_present_ptes`.
refcount + rss were already MMUPAGE-correct; only **mapcount** was mismatched.

## Verified corruption fix (5 edits, all mm/memory.c, on /home/nyc/src/linux work tree)
1. zap upstream gate: `!(PAGE_MMUSHIFT && (folio_test_anon||folio_test_large))` (let large FILE folios skip the upstream per-PTE batch)
2. zap PGCL gate: `folio_test_large(folio) || (folio_test_anon && max_nr>1)` (admit large file to cluster-site path)
3. zap: `rss[MM_ANONPAGES]` -> `rss[mm_counter(folio)]`
4. set_pte_range: first-present-sub-PTE add for nr==1 large file (interim)
5. zap large-folio: straddle (base_idx<0 || base_idx+PAGE_MMUCOUNT>PTRS_PER_PTE) -> per-sub-PTE; else last-present
**Result: basic init-btrfs-io repro pgcl6 ext4 = PASS, 0 CORRUPT (was 8/8 CORRUPT).** Corruption fixed.

## Residual + the contract decision (Nadia, 2026-06-18)
Edits 4/5 are INTERIM. Leak-probe (per-size) showed dumps 520->9: sub-PMD large
**file** folios (order-1/2 = 512K/1M) placed CROSSING a PTE-table(PMD) boundary at
non-cluster-aligned offsets still leak +1 cluster ("still mapped when deleted" ->
`bad=-7` on reuse). Root: kernel can't cluster-align sub-PMD file mmaps (folios
form post-mmap; `thp_get_unmapped_area` only PMD-aligns >=2M), so Contract A's
"one rmap event per cluster anchored in one PTE table" is fundamentally fragile
for table-straddling file clusters. Anon never hits it (pgoff=0 => cluster-aligned,
+ order-fallback instead of nr==1).

**DECISION: move the WHOLE-KERNEL rmap mapcount contract to MMUPAGE units** (not
dual anon=Contract-A / file=Option-A — that leaves latent bugs at every anon<->file
transition: COW-faulting files, tmpfs/shmem folio switching, khugepaged collapse,
migration). Uniform MMUPAGE makes those transitions no-ops for the accounting.

## Progress (branch `nadia.chambers/pgcl-mmupage-mapcount`, off the corruption fix; pushed to github)
- `3e660b7f` corruption fix (ALSO on page-clustering-001, pushed) — interim 5-edit add/remove symmetry.
- `5fcce15c` MMUPAGE rmap count-helpers (step 1) — compile-verified.
- `703e74d` **FILE side -> MMUPAGE + VMA-bounds clamp (steps 2/3/5 for file) — DONE + verified**:
  set_pte_range file-add via folio_add_rmap_subptes (deleted first-present scan); zap file path via
  folio_remove_rmap_subptes (anon kept on cluster-site for now); finish_fault nr>1 eager addr now
  bounds-checked against [vm_start,vm_end) and falls back to nr==1 if the cluster-aligned span spills
  out (a pre-existing placement bug the MMUPAGE conversion exposed: addr=(vaddr&PAGE_MASK)-idx*PAGE_SIZE
  rounds below a non-cluster-aligned vm_start -> sub-PTEs outside the VMA -> leak+corruption).
  VERIFIED pgcl6 ext4: leak-probe 0 dumps (was 520), init-btrfs-io 8/8 PASS 0 CORRUPT, init-mmap-boundary 4/4 PASS.
- **ANON conversion: memory.c WIP re-applied + THP-split path CONVERTED 2026-06-18 (build+test in flight).**
  memory.c (WIP, uncommitted on work tree): map_anon_folio_pte_nopf + do_swap_page (after the
  folio_add_new_anon_rmap/folio_add_anon_rmap_ptes Contract-A base, `for c: folio_add_rmap_subptes(folio,
  folio_page(folio,c)/page+c, PAGE_MMUCOUNT-1)`); fork copy_present_ptes do_share; wp_page_copy old-folio
  neighbor loop (dropped !folio_test_large guard -> per-sub-PTE remove); zap merged (ALL large ->
  folio_remove_rmap_subptes). order-0 anon already MMUPAGE (atomic_add(rss-1)).
- **THE -64 UNDERFLOW ROOT-CAUSED + FIXED (this session): the rmap WALK + PMD-split were still Contract-A.**
  Symmetry break: fault/zap were MMUPAGE (PAGE_MMUCOUNT/cluster) but `unmap_folio`'s walk
  (try_to_migrate_one) removed only 1/cluster (Contract-A), so the THP split saw a not-fully-unmapped
  folio; its phantom-reset to -1 + Contract-A remap left _mapcount=0, then the MMUPAGE zap removed
  PAGE_MMUCOUNT -> -PAGE_MMUCOUNT (= -64 @pgcl6). FIX = convert the walk to remove/add `nr_pages`
  (pvmw.nr_mmupages) sub-PTEs/yield via the helpers; the helper's per-page -1 sentinel handles
  first/last `_nr_pages_mapped` across partial/gapped yields, so the `pgcl_rmap_fire_kpage_event`
  last-present scan is no longer needed for these:
  - `mm/rmap.c` try_to_unmap_one + try_to_migrate_one large-folio branch: `folio_remove_rmap_subptes(folio, subpage, nr_pages, vma)` (replaced the kpage_event/psub Contract-A fire).
  - `mm/migrate.c` remove_migration_pte: anon large -> `first_frag` does folio_add_anon_rmap_pte once (sets the per-cluster PageAnonExclusive flag + 1 sub-PTE) then `folio_add_rmap_subptes(nr_pages-1)`; file large -> `folio_add_rmap_subptes(nr_pages)`. Dropped the non-PGCL `first_frag=true` decl (now PGCL-only).
  - `mm/huge_memory.c` __split_huge_pmd_locked BOTH !freeze branches (device-private ~3202 + normal anon ~3288, the do_huge_pmd_wp_page COW path): after folio_add_anon_rmap_ptes(HPAGE_PMD_NR) add `for c<HPAGE_PMD_NR: folio_add_rmap_subptes(folio, page+c, PAGE_MMUCOUNT-1, vma)`.
  - `__split_folio_to_order` phantom-resets (huge_memory.c ~3647/3749) now become harmless no-ops under MMUPAGE (folio is genuinely -1 after the converted unmap) — LEFT in place, gated.
  PITFALL (cost me a restore): do NOT bulk-edit huge_memory.c with a Python `re.S` `.*?` comment match — `[ \t]*/\*.*?phrase` anchors on the FIRST `/*` in the file and nukes thousands of lines. Use the Edit tool with exact strings. `git checkout -- mm/huge_memory.c` restored it (it was unmodified at HEAD).
- **VERIFIED x86_64 pgcl6 (DEBUG_VM) 2026-06-18: anon-stress PGCL-ANON PASS (4 workers/0 fail, COW
  isolation good), leak-probe bad=0 x16 (file unregressed), ZERO rmap warnings, -64 underflow GONE.**
  The rmap.h:148 `__folio_large_mapcount_sanity_checks` `diff > folio_large_nr_pages` WARN that the
  PMD-split first tripped is fixed by scaling that bound (and the line-149 MM_ID_MAPCOUNT_MAX one) by
  PAGE_MMUCOUNT (=1 @PGCL0). Remaining gates before commit: PGCL=0 Newton build + 20-arch PGCL=6 matrix.
- VERIFY harness: `/home/nyc/src/pgcl/verify-anon-mmupage.sh` builds x86_64 pgcl6 (DEBUG_VM) objtree
  `x86-pgcl6-mmupage`, ext4 images (mke2fs -d + `debugfs -R "mknod /dev/console c 5 1"` for init stdio),
  boots init-anon-stress + init-leak-probe under KVM, greps dmesg for bad-page/underflow. NOTE: create the
  out dir BEFORE the nohup `> out/run.log` redirect or the launch dies silently.
- SWAP audit RESOLVED (read-only, 2026-06-18): swap is per-sub-PTE-consistent under MMUPAGE, NOT a bug.
  do_swap_page order-0: nr_ptes=1 (memory.c ~5702 `(PAGE_MMUSHIFT && nr_pages>1) ? nr_pages*PAGE_MMUCOUNT
  : nr_pages`), so set_ptes installs ONE sub-PTE + folio_add_anon_rmap_ptes(.,1)=+1 + folio_ref_add(0) —
  symmetric (a swap minor-fault restores one MMUPAGE). Large-folio swap-in (nr_pages>1) gets the
  +PAGE_MMUCOUNT-1/cluster follow-up. swapfile.c:2330 unuse_pte is per-PTE in the swapoff scan -> +1
  each (sums right). So the only genuinely-unconverted anon rmap site is KSM (ksm.c:1427/1456, order-0,
  KSM merges 4K but PGCL clusters are PAGE_SIZE — its own problem; not default/matrix) + migrate_device.c
  (rare) + khugepaged collapse (task #121).
- NEWTON PGCL=0 x86_64 build: PASS (2026-06-18). 20-arch PGCL=6 matrix: RUNNING (matrix-col6-20260618-092057,
  PAR=4). After matrix clean -> commit the anon+walk+split MMUPAGE conversion (4 files: memory.c rmap.c
  migrate.c huge_memory.c + rmap.h sanity bound).
  WIP patch (older, memory.c-only): /home/nyc/src/pgcl/anon-mmupage-wip.patch (committed pgcl 7a774d6).
  Branch HEAD stays at file-conversion 703e74d; helpers 5fcce15c. work tree now: memory.c+rmap.c+migrate.c+huge_memory.c dirty.

## MMUPAGE-uniform plan (remaining; matrix-gated — touches working anon paths on all 20 arches)
Semantics: mapcount counts hardware (MMUPAGE) PTEs. per-page `_mapcount[cluster]`=
sub-PTEs mapping it; `_large_mapcount`=total sub-PTEs; `_nr_pages_mapped`=clusters
mapped (derived FREE by the rmap core's per-page atomic_inc_and_test/add_negative
first/last detection); refcount+rss already MMUPAGE.
1. rmap.c: add `folio_{add,remove}_rmap_subptes(folio,page,count,vma)` — apply +/-count
   mappings to ONE cluster page (mirror PTE-level core: atomic_fetch_add(count,&page->_mapcount),
   first/last from pre-value, +/-count to _large_mapcount, +/-1 to _nr_pages_mapped,
   __folio_mod_stat). NR_*_MAPPED stat -> sub-PTE units (match the existing order-0 anon
   `lruvec_stat_mod_folio(NR_ANON_MAPPED, rss-1)` convention in do_anonymous_page).
2. Fault add -> MMUPAGE per cluster: set_pte_range (file), map_anon_folio_pte_nopf +
   do_swap_page (anon large); fold do_anonymous_page order-0 atomic_add(rss-1) onto the helper.
3. zap -> per-sub-PTE: DELETE cluster-site last-present scan + straddle handling + edits 4/5.
4. fork copy_page_range, migrate (try_to_migrate_one/remove_migration_pte), do_wp_page COW: MMUPAGE units.
5. Verify: leak-probe 0 dumps + basic repro PASS + boundary stressor PASS, THEN full 20-arch matrix.

## QEMU repro recipe (fast, deterministic; no laptop needed)
Kernels: `kernel-rpm-build/pgcl{4,6}` objtrees, build `make O=... -j10 bzImage`.
ext4 image (no sudo): `truncate -s 4G img; mke2fs -F -t ext4 -b 4096 -d <rootdir-with-/init> img`.
Boot: `qemu-system-x86_64 -enable-kvm -cpu host -m 8G -smp 8 -nographic -no-reboot -kernel .../bzImage -drive file=img,if=virtio,format=raw -append "root=/dev/vda rootfstype=ext4 rootwait rw console=ttyS0 init=/init ignore_loglevel nokaslr"`.
Userspace stressors in `userspace/`: `init-btrfs-io.c` (io+mmap-verify, the corruption repro),
`init-leak-probe.c` (per-size, pinpoints leaking folio order/size), `init-mmap-boundary.c`
(unaligned sub-range mmap, partial munmap splitting clusters, MAP_FIXED nr==1/straddle).
Build static: `gcc -O2 -static -include stdarg.h -o init-X init-X.c`.
Leak shows as kernel "still mapped when deleted"/"nonzero (large_)mapcount"; corruption as
worker `CORRUPT ... rc=-10` (mmap memcmp) or probe `bad=-7`.
