# [RFC PATCH 00/28] mm: page clustering (PAGE_MMUSHIFT)

*Draft cover letter for the linux-mm posting. Patch count, shortlog and diffstat
are filled in mechanically from the final `pgcl-series` branch at assembly time
(see "Assembly checklist" at the bottom). Keep the prose; refresh the numbers.*

---

Subject: [RFC PATCH 00/28] mm: page clustering — decouple kernel allocation
granularity from MMU page size

This series forward-ports and modernises *page clustering* ("larpage"),
originally written by Hugh Dickins in 2001, onto current mainline. Page
clustering lets the kernel manage memory in units larger than the hardware MMU
page while keeping the userspace-visible page size unchanged.

## TL;DR

A new config knob, `CONFIG_PAGE_MMUSHIFT` (default 0 = today's behaviour),
makes the kernel's `PAGE_SIZE` a power-of-two multiple of the hardware MMU page:

```
    PAGE_SIZE  = MMUPAGE_SIZE << PAGE_MMUSHIFT
    PAGE_SHIFT = MMUPAGE_SHIFT + PAGE_MMUSHIFT
```

`MMUPAGE_SIZE` is the architecture's real hardware page (what the MMU and
userspace see; e.g. 4 KiB on x86). `PAGE_SIZE` becomes the kernel's *allocation
and bookkeeping* granularity — one `struct page`, one folio entry, one buddy
unit per cluster. The kernel maps a cluster to userspace as `PAGE_MMUCOUNT =
1 << PAGE_MMUSHIFT` consecutive hardware PTEs, so the userspace ABI (mmap
granularity, `getpagesize()`, `AT_PAGESZ`) is unchanged at the MMU page size.

At `PAGE_MMUSHIFT == 0` every change in this series is a compile-time no-op:
`MMUPAGE_* == PAGE_*`, `PAGE_MMUCOUNT == 1`, and the tree is byte-for-byte
equivalent to mainline behaviour. The knob is opt-in and per-arch.

## Why

Page clustering is a *software* technique, distinct from (and complementary to)
hardware superpages/THP:

- **Superpages/THP** install large hardware TLB entries — a hardware
  optimisation that reduces TLB misses but is constrained by MMU-supported
  sizes (e.g. x86's 4 KiB → 2 MiB gap, a factor of 512).
- **Page clustering** raises the *kernel's* allocation/management granularity
  above the MMU page — a software optimisation. Userspace still sees the small
  hardware page.

The two compose, and the composition is the point. Page clustering shrinks per-page
management overhead (one `struct page` per cluster rather than per hardware page,
shorter LRU/rmap walks, less buddy/slab churn, a memmap smaller by
`PAGE_MMUCOUNT`). More fundamentally, raising the allocation quantum changes the
*reliability* of superpage formation — and how it changes depends on the
hardware's superpage-size spectrum:

- **Dense spectra** (arm64's 4 KiB → 64 KiB contiguous-PTE → 2 MiB; mips's TLB
  ladder): every superpage size at or below `PAGE_SIZE` is contained within one
  allocation unit and so succeeds *by construction* — external fragmentation can
  no longer starve it, only true exhaustion can. THP/mTHP alone cannot offer
  this guarantee.
- **Sparse spectra** (x86's 4 KiB → 2 MiB, a factor of 512): the first hardware
  superpage is far above any sane allocation unit, so there is no guarantee — but
  raising the base order collapses the *assembly ratio* (contiguous aligned
  pieces needed to build the larger page) from 512 to 8 at a 256 KiB unit,
  sharply improving the odds the buddy allocator can form the 2 MiB page at all.

So the allocation unit is best understood not as "bigger pages" but as the
control on the internal-vs-external fragmentation frontier: it spends a bounded
amount of internal fragmentation to buy down external fragmentation, and in the
dense-spectrum case that purchase is a hard superpage-success guarantee — a
property no amount of 4 KiB-page optimisation can provide. The internal
fragmentation is itself a managed, reclaimable cost (small-file page-cache tail
packing; incremental/adaptive anonymous population; background zeroing of large
clusters — partly implemented, partly roadmap), not an unpriced overhead. It is
also a useful vehicle for large-page experimentation on architectures whose only
"big page" is far larger than is convenient to demand-fault.

This is an RFC: the goal is to get the design and the core-mm conventions in
front of linux-mm before polishing for merge. Concrete questions are at the end.

## Design

The central invariant: **one `struct page` per kernel `PAGE_SIZE`, never per
hardware page.** There are no sub-pages in the memmap.

- `PFN = phys >> PAGE_SHIFT`. `pte_pfn()` drops the intra-cluster bits;
  `pte_page()` returns the *same* `struct page` for all `PAGE_MMUCOUNT` PTEs of
  a cluster; `page_folio()` therefore needs no special-casing.
- A populated cluster installs `PAGE_MMUCOUNT` hardware PTEs that differ only in
  their sub-page physical offset. PTE sub-page arithmetic goes through
  `__phys_to_pte_val()`/`__pte_val_to_phys()` (identity on most arches; defined
  where the PTE PFN field does not start at `MMUPAGE_SHIFT`, e.g. riscv, mips).
- **Userspace-facing units are MMUPAGE-granular**: `vm_pgoff`, `total_vm`/
  `locked_vm`/`data_vm`, rlimit→page conversions, and the mmap/mremap/mprotect/
  mincore/madvise/mlock/msync syscall layers all count in hardware pages.
- **rmap / PVMW convention**: the page-table walker yields one kernel page per
  step (a run of same-cluster present PTEs, or same-encoded migration entries);
  PTE-level operations (cache+TLB flush, get/clear/set_ptes, RSS, ref/mapcount)
  consume the run, and there is exactly **one** rmap event per yield. This keeps
  folio mapcount/refcount semantics intact at cluster granularity.
- Fault paths (`do_anonymous_page`, `wp_page_copy`, swap-in, file fault) install
  the whole cluster and seed the arch MMU cache per sub-PTE.

The bulk of the work is making each `PAGE_SIZE`-vs-`MMUPAGE_SIZE` decision
explicitly throughout mm/, the arch page-table/asm layers, and the boot-path
drivers/filesystems — choosing kernel-page units for allocation/bookkeeping and
hardware-page units for anything the MMU or userspace observes.

## What this series is *not*

- Not a change to the userspace ABI: page size as seen by applications is
  unchanged (it is the hardware MMU page).
- Not THP and not a TLB optimisation by itself; it is orthogonal and
  complementary.
- Not enabled by default anywhere: `PAGE_MMUSHIFT` defaults to 0.

## Patch organisation

The series is built so that at `PAGE_MMUSHIFT == 0` it is bisectable and a
no-op at every step, and so that at `PAGE_MMUSHIFT > 0` the story is
incrementally correct — all generic code an arch's page-clustered boot exercises
(core mm, plumbing, boot drivers, rootfs filesystems) lands *before* the
per-arch commit that turns the knob on for that arch.

```
  A.  Core mm foundation
      - PAGE_MMUSHIFT Kconfig + MMUPAGE_* definitions (page.h, vdso, mm.h)
      - generic MMUPAGE pte/pgoff/fixmap helpers
      - folio_pte_batch_flags() classified-batch return + callers
      - fault / COW / PTE-install page clustering (+ pte_cluster.h)
      - fork copy + zap page clustering
      - swap-in page clustering
      - rmap: one-kernel-page-per-PVMW-step convention
      - THP split + PMD accounting under page clustering
      - filemap MMUPAGE file fault + fault-around clamp
      - mmap-family syscalls MMUPAGE-aligned (mincore/madvise/mmap/mremap/
        mprotect/mlock/msync/vma)
      - gup/shmem/swap/util MMUPAGE helpers
      - vmalloc/ioremap/page_table_check/mm_init/pagewalk
      - kernel/ (fork, futex, uprobes, perf ring_buffer) + lib/iov_iter
      - misc mm (vmscan, mempolicy, ksm, nommu, hmm, migrate_device, msync)
  (B. generic arch plumbing — folded into A's final foundation patch:
      asm-generic tlb stride, vmlinux.lds helpers, shmparam, blk_types,
      percpu-defs, lib/vdso, zlib)
  D.  Drivers: drm/i915 MMUPAGE audit, drm GEM/TTM, fbdev, misc generic drivers
  E.  fs / misc: 9p, exec, fat, slub oo cap
  C.  Per-arch enablement — one self-contained "<arch>: support page
      page clustering (PAGE_MMUSHIFT)" patch per arch:
        x86, arm64, arm, s390, powerpc, sparc, mips, loongarch, riscv,
        parisc, alpha, microblaze, m68k, arc, csky, sh, xtensa
      (each no-op at PAGE_MMUSHIFT==0; arch-coupled drivers — parisc IOMMU,
       s390 sclp, sbus — travel with their arch patch)
  F.  selftests/mm + Documentation/mm
```

A handful of strictly-independent pre-fixes (upstream-API and pre-existing-bug
fixes surfaced during the port — riscv ptrace CFI regset, microblaze/alpha
entry.S save-area, parisc PDC result buffer) lead the series and stand on their
own.

The series as posted (branch `pgcl-rfc-v1`) and the full development tree it was
distilled from (branch `nadia.chambers/page-clustering-001`; all architectures,
complete history, and the `PAGE_MMUSHIFT` matrix configuration) are at:

- SourceHut — https://git.sr.ht/~nadiayvette/linux-pgcl
- GitHub — https://github.com/NadiaYvette/linux

## Testing

Validated with a per-arch QEMU matrix (`PAGE_MMUSHIFT` ∈ {0, 2, 4, 6}) running,
per arch: a page clustering unit test, a page clustering stress test, the kernel
`selftests/mm` suite, and the LTP mm suite. Highlights:

- **16 architectures boot and pass at `PAGE_MMUSHIFT = 4`** (64 KiB kernel page
  on a 4 KiB MMU; 16 hardware PTEs per cluster), with full LTP mm runs and zero
  page clustering-specific failures: x86_64, arm64, arm(+lpae), riscv(32/64), s390x,
  ppc64, sparc64, mips64, loongarch64, alpha, parisc(32/64), m68k, microblaze.
- **Four further architectures boot and pass the page clustering smoke test at
  `PAGE_MMUSHIFT = 4`** (anonymous mmap + per-MMUPAGE touch over a cluster,
  fork + COW; userspace page size confirmed unchanged at the 4–8 KiB hardware
  page): **sh4, csky, openrisc (or1k), and xtensa** (the last verified with
  highmem both disabled and active). Full LTP for these four awaits libc
  cross-toolchains; they are exercised today with a nolibc page clustering smoke test.
  **arc** is build-tested only — no system emulator (`qemu-system-arc`) exists.
- **`PAGE_MMUSHIFT = 6`** (256 KiB kernel page; 1 MiB on 16 KiB-MMU loongarch)
  additionally verified on x86_64, aarch64, parisc(32/64), s390x, arm-lpae,
  mips64, m68k, loongarch64, alpha — including full PTE-table sub-page packing
  on mips.
- **`PAGE_MMUSHIFT = 2`** (e.g. 32 KiB page on sparc64's 8 KiB MMU) exercised on
  sparc64 to validate small-cluster TLB-refill corner cases.
- `PAGE_MMUSHIFT = 0` boots and passes on all arches and is equivalent to
  mainline (the series tree is identical to the development branch; see the
  regression gate below).

The few residual selftest/LTP deltas are architecture-specific and reproduce at
`PAGE_MMUSHIFT == 0` / on mainline (HW SHMLBA, musl libc stubs, missing optional
Kconfig); they are not introduced by page clustering. (Per-arch result tables to be
appended.)

The complete test harness — the per-architecture QEMU matrix driver, the
boot/run configurations, the page clustering unit and stress tests, the nolibc smoke
test, and the result logs — is maintained in a companion repository:

- https://git.disroot.org/NadiaYvette/pgcl-testscripts (Disroot, NL)
- https://framagit.org/NadiaYvette/pgcl-testscripts (Framagit, FR)
- https://git.sr.ht/~nadiayvette/pgcl-testscripts (SourceHut)
- https://github.com/NadiaYvette/pgcl-testscripts (GitHub)

(All four are identical mirrors; the non-US mirrors are listed first for expected
durability, and the paths are parallel, so any URL can be derived from another —
the *tessera* repository below lives on the same four hosts.)

Separately, an early formal-verification effort — *tessera* — is under way: a
Lean 4 formalisation of the core page clustering algorithms (the cluster/MMUPAGE
coordinate model and the sharing and atomicity properties that the rmap and
refcount accounting rely on), accompanied by concurrency litmus tests, and
intended in time to span elements of the Linux C API surface for page clustering. It
is work in progress and not a dependency of this series.

- https://git.disroot.org/NadiaYvette/tessera — and its Framagit / SourceHut /
  GitHub mirrors (same path scheme as the test harness above).

## Known issues / RFC questions

1. **Core-mm conventions** — does the "one `struct page` per kernel page + one
   rmap event per PVMW yield + MMUPAGE-granular userspace units" split match how
   maintainers would want page clustering expressed? This is the crux of the RFC.
2. **`folio_pte_batch_flags()` returning a classified struct** (`{nr, kind}`) —
   acceptable, or preferred as an out-param / separate helper?
3. **Per-arch surface** — each arch needs a small, mechanical set of MMUPAGE
   conversions (page table asm, syscall offset/coloring, lds alignment). Is the
   per-arch-patch-per-arch shape the right granularity for review?
4. **PTE-table sub-page packing** (sparc32/m68k/mips) requires disabling
   `SPLIT_PTE_PTLOCKS` (sub-tables sharing a ptdesc share a ptlock). Is the
   `PACK_PTE_PTLOCKS` per-sub-table-ptlock approach the right long-term answer?
5. Naming: `MMUPAGE` vs alternatives (`HWPAGE`, `BASEPAGE`) — bikeshed welcome
   now rather than after merge.

## Lineage and prior art

Page clustering has a long pedigree, and the core idea — decoupling the kernel's
allocation unit from the MMU page — has been independently rediscovered several
times, including in the last two years. The through-line, for the record:

- **Academic roots.** Page clustering descends from Babaoğlu and Joy's paging work
  (SOSP 1981, doi:10.1145/800217.806663); its use as a substrate for *superpage
  promotion* follows Navarro, Iyer, Druschel and Cox, "Practical, transparent
  operating system support for superpages" (OSDI 2002).
- **Linux origin, 2001.** Hugh Dickins proposed a larger kernel `PAGE_SIZE`
  decoupled from the MMU page in "Large PAGE_SIZE" on linux-mm [1]. That thread
  already carries this series' core formula — *"2\*\*N adjacent subpages may be
  clustered to make up one kernel page; PAGE_SHIFT = PAGE_SUBSHIFT +
  SUBPAGE_SHIFT"* — and its ABI invariant: *"one subpage … corresponds to one
  page at the user process level: its size is the same as EXEC_PAGESIZE (for
  getpagesize(2) and mmap(2))."* Linus Torvalds' reply states the userspace
  contract the series still rests on: *"you should never care about PAGE_SHIFT,
  except in the case of an mmap()."*
- **The 2.4/2.5 forward-port.** I forward-ported and extended Hugh's larpage
  through the 2.4/2.5 era, including booting Linux on a 64 GiB NUMA-Q on 32-bit
  x86 (PAE) in 2003 — to my knowledge the first verified, publicly-disclosed
  account of Linux running *non-pathologically* at that scale. Large-memory 32-bit
  itself was not new — that same NUMA-Q hardware ran 64 GiB under Sequent's
  DYNIX/ptx, and unverified reports of Linux reaching such sizes via a 2:2
  address-space split circulated but were never substantiated — but "running well"
  is the distinction. The `struct page` size reductions I had landed earlier
  helped, yet on their own the memmap nearly exhausted lowmem, leaving scarcely
  enough kernel virtual address space to run `init`; the address-space-split
  alternative only deferred its ABI cost, which stayed beneath notice until a
  workload actually wanted ~3 GiB of user virtual space (an Oracle or a DB2). Page
  clustering — one `struct page` per cluster — is what turned 64 GiB from marginal
  into comfortable, and it was chosen over kernel/user address-space switching (the
  XKVA approach, from the DYNIX/ptx and AIX lineage I came from) because raising
  the allocation unit carries forward to 64-bit, and, as it turned out, to
  superpages. The signed patch series
  and the boot logs themselves are still archived [2]. (That work was published
  under my former byline; it is cited here as historical attribution.)
- **Software PAGE_SIZE, 2007.** Andrea Arcangeli's "CONFIG_PAGE_SHIFT (aka
  software PAGE_SIZE)" thread [3] revisited the same decoupling; the discussion
  there already anticipated the small-file page-cache tail-packing used to bound
  internal fragmentation.

## Relationship to current upstream work

The same decoupling is being rediscovered, one architecture at a time, right now:

- Kirill A. Shutemov's "64k (or 16k) base page size on x86" (LSF/MM 2026) splits
  `PAGE_SIZE` into a hardware `PTE_SIZE` and a kernel `PG_SIZE` with a sub-page
  offset on the PTE accessors — the split this series calls
  `MMUPAGE_SIZE`/`PAGE_SIZE` and `pte_mksub()`.
- Xu Lu's "riscv: Introduce 64K base page" (RFC, 2024) makes `pte_t` an array of
  16 contiguous hardware PTEs — the same cluster-of-PTEs representation. (Hugh's
  2001 thread was noted there as prior art.)
- Ryan Roberts and Dev Jain's per-process page size (LSF/MM 2026) takes the
  alternative route of varying the page size per process behind an ABI adaptor.

These converge on the design implemented here, but each is tied to one
architecture and stops short of the full userspace-ABI surface (e.g.
`/proc/<pid>/pagemap`, the syscall granularity layer). What this series adds is
the *generic, all-architecture, ABI-complete* form, with a `PAGE_MMUSHIFT == 0`
identity guarantee that makes it safe to carry in-tree disabled. One shared
mechanism seems better than N per-arch ones, and folding these efforts together
would be welcome.

[1] https://lore.kernel.org/linux-mm/Pine.LNX.4.21.0107051737340.1577-100000@localhost.localdomain/
[2] "64GB NUMA-Q after pgcl" / "64GB NUMA-Q before pgcl", linux-kernel,
    28 Mar 2003:
    https://lore.kernel.org/all/20030328040038.GO1350@holomorphy.com/
    https://lore.kernel.org/all/20030328040036.GA13178@holomorphy.com/
    Code and boot logs: https://www.kernel.org/pub/linux/kernel/people/wli/vm/pgcl/
    (signed pgcl-2.5.54 … pgcl-2.5.60; dmesg.64G.32K = 64 GiB x86-32 PAE boot at a
    32 KiB clustered page, Linux 2.5.66; dmesg.64G.4K the stock-4 KiB baseline on
    the same NUMA-Q)
[3] https://lore.kernel.org/all/20070717193308.GD25301@v2.random/ (CONFIG_PAGE_SHIFT thread)

## A note on AI assistance

This series was prepared with substantial assistance from an AI coding assistant
(Anthropic's Claude). I take responsibility for the patches and have reviewed
them; I disclose this both because kernel practice increasingly expects it and
because the connection is, here, substantive rather than incidental. The central
move of this work — drawing a new distinction between the kernel's allocation unit
and the hardware's minimum TLB/MMU mapping granularity — is a conceptual cut not
present in the existing vocabulary, and I had long assumed it was exactly the kind
of thing a language model would handle poorly: such a model's notion of meaning is
something like a set of nearby directions in a vector space, inferred rather than
anchored to a referent, and a genuinely new distinction has no such neighbourhood
to inherit. For some months I cited this very problem as an example of what these
models would find hard. Then I tried it, and it held — well enough that a project
I had shelved as one I never secured the team-lead role or the headcount to
finish became, instead, this submission.

That assistance extended to the writing itself, this cover letter included. The
prose began from the assistant's preliminary draft — which I judged a better
armature than my own first attempt — and I worked my own voice into it, rather
than the reverse, hand-writing the bulk and correcting toward it. I note it
because the disclosure should cover the words as much as the code: the choices of
what to claim, what to cite, and what to stand behind are mine, but the
composition is substantially collaborative.

---

## Assembly checklist (internal — strip before sending)

Run from the `pgcl-series` worktree once bucket C is complete and pushed:

1. Confirm the series reproduces the work branch exactly:
   `git diff nadia.chambers/pgcl-series..nadia.chambers/page-clustering-001`
   MUST be empty.
2. Fill `NN` = `git rev-list --count <base>..pgcl-series`.
3. Insert `git shortlog <base>..pgcl-series` and
   `git diff --stat <base>..pgcl-series | tail -1` under the relevant sections.
4. Strip any `(cherry picked from ...)` provenance lines from the lead
   independent-fix commits (added with `-x` for WIP traceability).
5. Append the per-arch LTP/selftest result tables from MEMORY.md.
6. `git format-patch --cover-letter -o <outdir> <base>..pgcl-series`, then
   replace the generated `0000-cover-letter` body with the prose above.
