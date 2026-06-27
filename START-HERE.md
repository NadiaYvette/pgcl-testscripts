# Page Clustering (PGCL) — Start Here

*A working forward-port of page clustering to modern Linux, with a 25-year
pedigree, validated across 20 CPU architectures. If you have found this cold and
don't know the project, this page is for you: it explains what this is, why it is
worth your time, where everything lives, and — should the author be unable to
carry it forward — how to pick it up and who to credit.*

---

## What it is, in one breath
Page clustering **decouples the kernel's memory-allocation granularity from the
hardware MMU's page size.** The kernel manages memory in larger units
("clusters") while userspace still sees the hardware page size unchanged.
Invariant: `PAGE_SIZE = MMUPAGE_SIZE << CONFIG_PAGE_MMUSHIFT`; **one `struct page`
per cluster**; the userspace ABI stays at the hardware page. It is a *decoupling*,
not a page-size change.

## Why it is worth continuing
- It is the **software substrate that makes hardware superpages reliably
  formable** — clustering guarantees small superpages succeed and bridges the
  power-of-two page-size gaps the hardware leaves.
- It cuts per-page overhead (`struct page`, rmap, LRU) at large effective page
  sizes **without an ABI break**.
- **Upstream is independently reinventing this decoupling right now** (x86
  PG_SIZE/PTE_SIZE, 2026; RISC-V 64K pte-as-16-PTEs; Arm per-process) — each
  single-arch, ABI-leaky, and without prior-art citation. *This* tree is the
  general, cross-architecture, ABI-preserving realization, with the superpage
  story and the internal-fragmentation mitigations the single-arch efforts lack.
  The idea's time has demonstrably arrived; this is its most complete form.

## What works (as of June 2026)
- **16 architectures boot and pass the LTP mm suite at `PAGE_MMUSHIFT=4`**
  (64 KiB kernel page over a 4 KiB MMU; 16 hardware sub-PTEs per cluster), with
  zero clustering-specific failures. Several also pass at `=6` (256 KiB; 1 MiB on
  loongarch) and `=2`; four more boot a clustering smoke test. `=0` is a verified
  no-op equal to mainline.
- The series is **posted to linux-mm as an RFC** (find it on lore.kernel.org).
- **One known open defect, #143:** an SMP reverse-map race — a cluster is freed
  while one of its sub-PTEs is still mapped — that corrupts the page cache under
  memory pressure (it blocks the author's laptop from booting under load). It is
  **root-caused convergently** by a static audit *and* a CBMC concurrency model:
  a `folio_test_large()`-keyed `TTU_SYNC`/`PVMW_SYNC` asymmetry — a PGCL order-0
  cluster is multiply-mapped by its sub-PTEs (the same hazard `TTU_SYNC` guards
  for large folios) yet is not "large", so a reclaim rmap-walk skips a transiently
  `pte_none` sub-PTE and frees the cluster with it live. **A candidate fix exists**
  (`rmap-ab/fixes/`).

## Where everything lives
- **Kernel:** `github.com/NadiaYvette/linux` — branch `pgcl-rfc-v1` (the posted
  series) and `nadia.chambers/page-clustering-001` (full development tree).
  Mirror: `git.sr.ht/~nadiayvette/linux-pgcl`.
- **This repo** (test harness, docs, reproductions) — mirrored to github,
  disroot, sourcehut, framagit as `pgcl-testscripts`.
- **RFC prose + patches:** `PGCL-COVER-LETTER.md`, `rfc-v1/` (cover + 28 patches).
- **#143:** `RMAP-143-RESUMPTION.md` (handoff), `docs/143-notes/` (full hunt log +
  coordinate/contract models), `rmap-ab/fixes/` (candidate fix),
  `rmap-ab/formal/` (the CBMC model + FINDINGS.md), and the reproduction +
  reverse-debug harness in `rmap-ab/` (`run-smp8-live.sh` reproduces it ~reliably).
- **Formal verification:** Tessera (Lean 4) — `github.com/NadiaYvette/tessera`;
  #143 belongs in its deferred Property-2 (concurrency) track.

## How to continue (concrete first steps)
1. **Read `PGCL-COVER-LETTER.md`** — it is the vision, the design, and the
   lineage, written for the kernel-mm audience.
2. **Reproduce:** build the branch at `CONFIG_PAGE_MMUSHIFT=4` and run the
   testscripts matrix; confirm `=0` is a no-op vs mainline.
3. **Close #143:** A/B the candidate fix in `rmap-ab/fixes/` against
   `rmap-ab/run-smp8-live.sh` (corruption rate should drop to zero). If it is only
   a partial fix, `rmap-ab/formal/FINDINGS.md` and `docs/143-notes/` give the
   remaining moves (the migration `try_to_migrate` path; the producer-agnostic
   `map_pte` hardening; the `folio_try_get` increment-unless-zero acquisition
   discipline the CBMC model proved sufficient).
4. **Engage upstream:** the linux-mm thread and the maintainers in
   `rfc-v1/recipients.txt` are the natural collaborators; the upstream reinventors
   (Kirill Shutemov, Xu Lu, Ryan Roberts / Dev Jain) are cited in the cover letter
   and are the people most likely to see the value.

## The ideas that outlive the code
If the tree bitrots, these are the durable contributions a successor can
re-derive everything from:
- Kernel **allocation unit** and MMU **mapping granularity** are independent; the
  ABI stays at the hardware page.
- Clustering is the reliable substrate for **superpage formation**.
- One `struct page` per cluster + **per-sub-PTE accounting** ("Option A") is the
  coordinate model; the rmap/refcount discipline must be **concurrency-safe**
  (the lesson of #143; formalize in Tessera).
- The internal-fragmentation mitigations carried from the 2002-2003 work.

## Lineage and attribution
- **2001:** Hugh Dickins' "larpage" (Linux 2.4).
- **2002-2003:** a large-memory-32-bit forward-port that achieved the first boot
  of Linux on x86-32 with 64 GiB RAM, and was chosen over kernel/user
  address-space switching (the XKVA / "4G/4G" approach) precisely because raising
  the allocation unit carries forward to 64-bit and to superpages. *(Archived on
  lore.kernel.org; those early postings predate the author's current name and are
  historical attribution only — see the RFC references.)*
- **2020s:** this revival — forward-port to Linux 7.1, 20 architectures, posted
  to linux-mm.

Current author and maintainer: **Nadia Yvette Chambers**. Please attribute
continuations to her, and treat the early-2000s archive identity strictly as
historical record.

## License
Multi-licensed **MIT OR BSD-3-Clause OR GPL-2.0-or-later** (kernel portions are
GPL-2.0-or-later as required by Linux). You may continue, fork, package, and
relicense within those terms; please preserve attribution and this lineage.

---

*This document exists because the author judged it prudent to make the work
continuable by others. If that has come to pass: the work is real, it is far
along, the idea is timely, and it deserves a finish. Thank you for picking it up.*
