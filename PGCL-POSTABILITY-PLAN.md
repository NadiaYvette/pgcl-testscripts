# PGCL upstream-postability plan (linux-mm patch series)

Durable working notes for restructuring the page-clustering branch into a
clean, reviewable patch series. Survives reboots; pick up here after testboot
detours. Companion data files in this dir:
- `PGCL-series-grouped.txt` — all 136 commits grouped by provisional bucket
- `PGCL-series-commit-areas.tsv` — `hash <tab> areas <tab> subject` per commit

## State / source of truth
- **Work branch (source of truth):** `nadia.chambers/page-clustering-001` @ `a8bb04366ba4`
  (pushed to github NadiaYvette/linux). 136 commits, +8891/-2568, 537 files.
- **Series branch (clean build target):** `nadia.chambers/pgcl-series`, created at
  upstream base `2d3090a8aeb5` (origin/master merge-base). Currently EMPTY
  (just the base) — the clean series gets built onto it.
- **Strategy: approach (B) re-derive from final tree.** The cumulative diff
  `2d3090a8aeb5..a8bb04366ba4` is the target end-state. We carve logical patches
  onto the series branch with `git add -p` so that applying all of them
  reproduces the work-branch tree. The 136 commit messages are the rationale
  cheat-sheet for the new messages. (Rationale over interactive rebase: avoids
  fighting broken intermediates, and `git rebase -i` is unavailable in this
  environment. If we ever script a true rebase, drive it via GIT_SEQUENCE_EDITOR.)
- **Build gate:** every series patch must build x86_64; the PGCL=4/6 80-cell
  matrix (matrix-driver-all.sh) is the regression gate before posting.

## BUCKET ORDERING (revised) — drivers/fs BEFORE per-arch enablement
A per-arch patch is the commit that makes PAGE_MMUSHIFT>0 actually *work*
(boot+test) on that arch. For the series to tell an incrementally-correct
story — each arch-enable commit yields a genuinely working PGCL>0 kernel —
every generic thing that arch's PGCL>0 boot/test exercises must already be
converted: core mm, generic plumbing, AND the drivers (display/virtio/
storage) and filesystems (9p rootfs, fat/ext4) used at boot. So the order is:
  A core-mm  ->  B generic-plumbing  ->  D drivers  ->  E fs+kernel/lib  ->
  C per-arch (LAST)  ->  F selftests/Docs
Note: at PAGE_MMUSHIFT==0 every patch is a no-op, so PGCL=0 build/boot
bisectability is order-independent; this ordering is about PGCL>0 incremental
correctness and the review narrative. Drivers/fs are arch-independent and
build at PGCL=0 regardless, so moving them ahead of the arch patches is safe.

## Target series shape (RFC, ~40-70 patches)
```
0/N  cover letter: motivation, MMUPAGE vs PAGE design, 16-arch test matrix, perf
A. Core mm foundation (split out of the 75-file commit #1 + the 46 CORE-MM):
   - Kconfig PAGE_MMUSHIFT + vdso/page.h MMUPAGE_* defs
   - PAGE vs MMUPAGE split in core types/helpers
   - set_ptes / clear_full_ptes / pte_batch MMUPAGE conventions
   - anonymous-page clustering (do_anonymous_page)
   - COW clustering (wp_page_copy)
   - rmap: PVMW yields one kernel page/step; one rmap event per PTE (Option A)
   - fork / zap sub-page accounting; pgcl_pte_batch
   - swap-in clustering
   - mincore / madvise / mmap / mremap / mprotect MMUPAGE awareness
   - THP split under PGCL (huge_memory)
   - shmem / filemap / userfaultfd
B. Generic arch plumbing: ELF_EXEC_PAGESIZE, vmlinux.lds helpers, TLB stride,
   generic ioremap, remap_pfn_range, page_table_check
C. Per-arch enablement — ONE self-contained patch per arch (14 arches):
   x86, arm64, arm(+lpae), riscv(32/64), s390, powerpc, sparc(32/64), mips,
   loongarch, alpha, parisc(32/64), m68k, microblaze; csky/xtensa coloring-only
D. Drivers: drm/i915 MMUPAGE audit, drm/imagination, simpledrm/efifb
E. fs / misc: 9p, exec, fat, slub oo cap
F. selftests/mm + Documentation/mm
```

## Provisional bucket counts (auto-classified — see grouped.txt for members)
| Bucket | Commits | Disposition |
|--------|--------:|-------------|
| CORE-MM | 46 | regroup into A; squash fix-chains; some belong to B |
| per-arch (14 arches) | ~50 | collapse each arch's scattered commits into 1-few (C) |
| SPLIT-multi (bundled) | 10 | **split by subsystem**, redistribute into A/C/D/E |
| MIXED-review | 20 | per-commit decision (mostly arch+core or arch+driver) |
| DRIVERS | 5 | bucket D |
| FS | 4 | bucket E |

## Known structural issues to resolve
1. **Monolith #1** `8a4cf95f3067` "forward-port to Linux 6.19" — 75 files,
   1212+/351-. Split into the bucket-A foundation patches (Kconfig/defs, type
   split, set_ptes, fault path...). Highest-value, hardest single task.
2. **10 SPLIT-multi commits** bundle arch + drivers + fs + mm in one commit,
   e.g. `105be1b39c96` (COW + SMP boot + i915 + TTM — touches arm64, ppc, x86,
   drivers, fs, kernel, net, virt). Carve per subsystem.
3. **Fix-the-fix chains → squash** into the logical change so it appears once,
   correct:
   - pgcl_pte_batch: `5d16bd1d` + `9567ec30` + `124d03fb`
   - post-split _mapcount: `c3035206` + `7dcee907` (+ `886d1ae9`)
   - try_to_unmap_one PTE convention: `b6b69379`/`5c8fc3ac`/`2e4c4283`/`e38e7ecb`/`5e2620b0`
   - near-duplicate subjects `1bcde1b4` + `94858864` ("sparc64 cache aliasing
     pgoff and alpha zero page") — different diffs; merge/relabel.
4. **Per-arch collapse:** each arch's enablement is smeared across many dated
   commits (mips has 9, arm64 6, sparc/parisc/arm/alpha 5 each). Target = one
   "<arch>: support page clustering" patch each (+ maybe a follow-up fix).
5. **Bisectability:** the current order does NOT build per-commit. Approach B
   rebuilds it; budget build-checks at each foundation patch and at least one
   boot per arch patch.

## Already clean / near-submission-ready (lift mostly as-is)
The most recent ~19 commits (`fd4ad3a67b31..a8bb04366ba4`) are single-purpose
with proper messages — drop straight into the series with light reword:
vmap_pte_range paddr, unmap_mapping_range, filemap fault-around clamp, uffd
(2), exec/util stack align, rmap nr reset, sub-PAGE arithmetic, alpha
__pte_val_to_phys, parisc NUM_PDC_RESULT, loongarch efistub KASLR, slub oo cap,
per-sub-PTE MMU cache, ARM free_initmem, mincore overflow, sparc64 coloring,
arm/csky/xtensa/sparc32 coloring, shmem max_inodes.

## Execution phases (this is the postability TODO)
- [x] **P0** New branch + categorized inventory (this doc + data files).
- [~] **P1** DONE for the buildable subset. KEY REFINEMENT: most of the "clean
      tail" *references* the MMUPAGE foundation (uses MMUPAGE_SHIFT/MASK,
      PAGE_MMUSHIFT) or sits atop a subsystem/arch PGCL conversion, so it can
      NOT build first on the bare base — those ~15 stay queued and slot into
      their target buckets AFTER the foundation (A/C). Only the genuinely
      PGCL-INDEPENDENT fixes can lead the series; lifted + per-arch-build-verified
      onto pgcl-series (in worktree /home/nyc/src/linux-series):
        - 2c622d9 riscv: ptrace REGSET_CFI (upstream API adaptation) [build OK]
        - ca7043d microblaze: entry.S C-ABI save-area (pre-existing bug) [build OK]
        - 5eb21be alpha: entry.S syscall-nr save (seccomp errno leak) [build OK]
        - fde14ce parisc: NUM_PDC_RESULT 32->64 (firmware overrun) [build OK]
      EXCLUDED: 94e961c (microblaze board DTS = local QEMU test hack, not
      upstreamable) and e38e7ec (rmap nr_pages=1: applies on base but only
      correct under PGCL -> belongs in bucket A rmap, not a lead).
      NOTE: cherry-picked with -x (provenance lines) for WIP traceability;
      strip the "(cherry picked from ...)" lines at P7 final assembly.
- [~] **P2** Carve bucket-A core-mm foundation (IN PROGRESS — infrastructure
      layer done + x86_64 build-verified). Method: `git checkout <tip> -- <files>`
      onto pgcl-series in the worktree; build incrementally reusing O=/tmp/f1-x86.
      Defer files coupled to unconverted .c (take them WITH their .c patch).
      Done so far:
        - F1 b617864 mm: PAGE_MMUSHIFT core definitions (Kconfig, vdso/page.h,
          mm.h macros). Full x86_64 build OK (PGCL=0 == mainline).
        - F2 f65827b mm: generic MMUPAGE pte/pgoff/fixmap helpers (pgtable.h
          __phys_to_pte_val/pte_mksub/pte_suboffset, pagemap.h pgoff, asm-generic
          fixmap). Incremental x86_64 build OK.
      REMAINING foundation .c carving (F3+), dependency order; build x86_64
      incrementally each, boot x86_64 PGCL=4 at the end of A:
        [x] F3 0b5b3a2 mm: folio_pte_batch_flags() returns classified struct
               (internal.h batch struct/kind + pgcl helpers + all 7 callers'
               .nr). Build OK.
        [x] F4 8a9f3a6 mm/memory: fault/COW/PTE-install clustering + pte_cluster.h.
        [x] F5 6820799 mm/memory: fork copy + zap clustering.
        [x] F6 f304d4f mm/memory: swap-in clustering. memory.c now == work branch.
            SPLIT METHOD THAT WORKED (no interactive git): checkout the WHOLE
            final file, then `git apply -R` the later function-groups' hunk
            subset (context matches the final file, unlike forward subset-apply
            which fails on interleaving). Group hunks by the function in each
            @@ header. Reusable for rmap.c etc.
        [x] F8 2b7df18 mm/rmap: PVMW yields one kernel page/step (rmap.h
            nr_mmupages + page_vma_mapped.c walker + rmap.c consumers). The
            8-commit fix-chain squashed automatically (took final state).
            Build OK. migrate.c is MIXED (PVMW remove_migration_pte + non-PVMW
            isolate_folio_to_list/try_to_map_unused_to_zeropage) — its PVMW
            part + ksm/page_idle/huge_memory/vmscan PVMW consumers complete the
            convention in their own later file patches (PGCL=0-safe to defer).
        [x] F9 9487a90 mm/huge_memory: THP split + PMD accounting (huge_mm.h
            HPAGE_PMD_MMUNR + huge_memory.c; squashed c303520/7dcee90). Build OK.
            *** BUILD-CONFIG LESSON: plain x86_64 `defconfig` has THP=n, so
            huge_memory.c/khugepaged.c are NOT compiled — a "BUILD OK" there is
            hollow. The persistent build dir /tmp/f1-x86 now has TRANSPARENT_
            HUGEPAGE + _ALWAYS + READ_ONLY_THP_FOR_FS enabled; keep them on for
            all remaining foundation builds so THP/khugepaged stay covered.
        [x] F10 712a048 mm/filemap: MMUPAGE file fault + fault-around clamp. Build OK.
        [x] F11 5f451c6 mm: MMUPAGE-align mmap-family syscalls (mincore/madvise/
            mmap/mremap/mprotect/mlock/msync/vma). Build OK. NOTE: taking final
            state folds in the deferred clean-tail fixes for these files
            automatically (e.g. mincore 32-bit overflow fix is in final mincore.c).
        [x] F12 be54cce mm: gup/shmem/swap_state/swap/util MMUPAGE helpers
            (shmem tmpfs max_inodes fix folded in). Build OK.
        [x] F13 (committed) mm: vmalloc/ioremap/early_ioremap/page_table_check/mm_init/pagewalk. Build OK.
            mm_init.c, pagewalk.c.
        F14 kernel/fork.c, kernel/futex, kernel/events/{uprobes,ring_buffer},
            lib/iov_iter.c.
        F15 misc small: vmscan, mempolicy, ksm, nommu, hmm, migrate_device,
            mapping_dirty_helpers, msync.
      Then fold in the deferred clean-tail core-mm fixes (mincore overflow,
      shmem max_inodes, per-sub-PTE MMU cache, etc.) into their F-patch.
- [ ] **P3** Bucket-B generic arch plumbing.
- [ ] **P4** Per-arch patches (C) — one per arch; boot each in QEMU (matrix).
- [ ] **P5** Drivers (D) + fs/misc (E) + selftests/Documentation (F).
- [ ] **P6** Full 80-cell matrix regression on the rebuilt series == work branch.
- [ ] **P7** Cover letter; split into RFC v1; (optional) per-arch CC lists.

## Resume hints
- Series work touches ONLY `nadia.chambers/pgcl-series`. The work branch and the
  testboot RPM source stay at `a8bb04366ba4` — do not `git checkout` the series
  branch in the main worktree if a testboot/debug cycle is in flight; use a
  separate worktree (`git worktree add ../linux-series nadia.chambers/pgcl-series`).
- Verify nothing dropped: `git diff nadia.chambers/pgcl-series..nadia.chambers/page-clustering-001`
  must be empty when the series is complete.

## P-progress log (appended)
- Generic foundation (A+B): F1-F15 DONE, 18 patches, mm/kernel/lib/include
  fully == work branch, x86_64 build-verified at PGCL=0 (THP+i915+fb enabled).
- Drivers (D): D1 drm/i915 (320 obj compiled), D2 drm GEM/TTM/drivers,
  D3 fbdev, D4 misc generic drivers. 22 patches total. Arch-coupled drivers
  (drivers/parisc IOMMU, drivers/s390 sclp, drivers/sbus) DEFERRED to bucket C.
  Coverage caveat: enabled-in-config drivers compiled; exotic D4 drivers
  (infiniband HW, comedi, rapidio...) applied + work-branch-boot-verified.
- Remaining: E fs+misc (fs/ 15: 9p/exec/fat + net/ipc/init/sound/virt strays),
  C per-arch (arch/ 336 + the 7 arch-coupled drivers), F selftests/Docs.
- Build dir /tmp/f1-x86 config now has: THP(+ALWAYS+RO_THP_FS), DRM, DRM_I915,
  DRM_TTM, DRM_VIRTIO_GPU, FB+FB_EFI, DRM_SIMPLEDRM, VFIO. Keep for verification.

## MILESTONE: non-arch side COMPLETE (26 patches)
git diff a8bb04366ba4 (series vs work) is now ZERO outside arch/ and the 7
arch-coupled drivers. The whole arch-independent kernel — mm, kernel, lib,
include, drivers, fs, ipc, net, sound, virt, block, io_uring, selftests,
Documentation — is faithfully reproduced as a clean, build-verified series.
ONLY bucket C remains: per-arch enablement (arch/ 336 files) + the 7
arch-coupled drivers (parisc IOMMU, s390 sclp, sbus), one patch per arch,
boot each in QEMU. Then P6 (confirm series tree == work branch) + P7 (cover
letter / RFC). Build dir /tmp/f1-x86 config has THP+DRM/i915+FB+9P+FAT+SND+KVM+VFIO.

## Toolchains for arc/csky/sh (installed 2026-06-10)
- arc:  Fedora gcc-arc-linux-gnu  -> CROSS_COMPILE=arc-linux-gnu-  (build-only, no mainline qemu)
- csky: ~/x-tools/gcc-16.1.0-nolibc/csky-linux/bin -> CROSS_COMPILE=csky-linux- (build-only)
- sh:   ~/x-tools/gcc-16.1.0-nolibc/sh4-linux/bin  -> CROSS_COMPILE=sh4-linux-  (qemu-system-sh4 avail)
These three carve+build AFTER the 13-arch loop finishes (avoid worktree race).

## TESTBOOT + RESUME (laptop testboot before the 80-cell matrix)
Testboot uses the PGCL=4 RPM (from work branch a8bb043) — INDEPENDENT of the
series worktree, so the testboot doesn't disturb the series.
  Install: sudo dnf install /home/nyc/src/pgcl/kernel-rpm-build/pgcl4/rpmbuild/RPMS/x86_64/kernel-7.1.0_rc7_pgcl4_00152_ga8bb04366ba4-2.x86_64.rpm
  Boot: reboot, pick 7.1.0-rc7-pgcl4-00152-... at GRUB (6.18 stays fallback).
  Revert: sudo dnf remove kernel-7.1.0_rc7_pgcl4_00152_ga8bb04366ba4-2

REBOOT IMPACT on series work: kills the in-flight background arch loop + wipes
/tmp build dirs/scripts. Committed arch patches are SAFE in git (pgcl-series,
on /home). Only the in-flight (uncommitted) arch is lost.
RESUME after testboot — one command, resume-safe (skips already-committed arches):
  bash /home/nyc/src/pgcl/pgcl-series-archloop.sh
Then: P6 (git diff pgcl-series..page-clustering-001 must be empty; run matrix),
P7 (cover letter/RFC). sh4 boot-smoke = task #104.

## P-progress (2026-06-11)
- 13-arch loop DONE: arm64/arm/s390/powerpc/sparc/mips/loongarch/riscv/parisc/
  alpha/microblaze/m68k all committed (m68k=214e056ad74d). +x86(7b7ed05) = 14
  per-arch patches in. Series at 39 patches after m68k.
- xtensa audio_kc705_defconfig FAILS: `invalid register 'atomctl'` — Fedora
  gcc-xtensa-linux-gnu targets the fsf core (no S32C1I), audio_kc705 selects a
  custom dc233c-class core. NOT a PGCL issue. FIX: durable script now builds
  xtensa with generic `defconfig` (fsf), moved xtensa LAST, and build/defconfig
  failures are non-blocking (revert carve + continue, not exit 1).
- arc/csky/sh/xtensa carve loop RUNNING (bg task; resume-safe). Per-arch deltas
  to carve: arc=shmparam.h; csky=abiv1/mmap.c+shmparam.h+syscall.c;
  sh=sys_sh.c; xtensa=syscall.c (all small coloring/SHMLBA/mmap-offset).
- COVER LETTER drafted: /home/nyc/src/pgcl/PGCL-COVER-LETTER.md (P7 prose done;
  assembly checklist at bottom; fill numbers after bucket C pushed).
- DONE: arc(ed4f7f3) csky(e55120d) sh(047630d) xtensa(921e8a6) all committed.
  **BUCKET C COMPLETE — 43 patches, all 17 arches.** P6 tree-equality VERIFIED:
  series HEAD tree == work tree (identical object 2d593bb5...469024; diff = 0
  files). PUSHED to github/nadia.chambers/pgcl-series (fast-forward 7b7ed05..921e8a6).
  *** NATURAL PAUSING POINT — safe for laptop testboot/reboot now. ***
- REMAINING: P6 run the 80-cell matrix (tree already proven identical to work
  branch, so it should reproduce known-passing results — formal regression gate);
  P7 final assembly (format-patch, fill NN/shortlog/diffstat, strip -x lines,
  append per-arch result tables); #104 sh4 boot-smoke.
