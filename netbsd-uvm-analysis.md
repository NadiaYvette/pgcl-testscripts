# NetBSD UVM Virtual Memory Subsystem Analysis for Page Clustering Feasibility

## Source Location
Repository cloned to `/home/nyc/src/netbsd` (shallow clone with blob filter from GitHub).

## 1. PAGE_SIZE Definition and Propagation

### Definition Chain
PAGE_SIZE on amd64 is defined in **two** places, with the vmparam.h definition taking precedence:

- `/home/nyc/src/netbsd/sys/arch/amd64/include/vmparam.h` (lines 55-57):
  ```c
  #define PAGE_SHIFT  12
  #define PAGE_SIZE   (1 << PAGE_SHIFT)
  #define PAGE_MASK   (PAGE_SIZE - 1)
  ```
  Comment: "Page size on the amd64 is not variable in the traditional sense. We override the PAGE_* definitions to compile-time constants."

- `/home/nyc/src/netbsd/sys/arch/amd64/include/param.h` (lines 39-41) defines the older BSD constants:
  ```c
  #define PGSHIFT     12          /* LOG2(NBPG) */
  #define NBPG        (1 << PGSHIFT)  /* bytes/page */
  #define PGOFSET     (NBPG-1)   /* byte offset into page */
  ```

### Propagation
- `round_page()`/`trunc_page()` in `/home/nyc/src/netbsd/sys/uvm/uvm_param.h` (line 198) use PAGE_MASK directly.
- `atop(x)` and `ptoa(x)` in the same file use PAGE_SHIFT.
- `btop(x)` and `ptob(x)` are defined as aliases to `x86_btop`/`x86_ptob` in param.h using PGSHIFT.
- The runtime `uvmexp.pagesize`/`uvmexp.pageshift`/`uvmexp.pagemask` in struct uvmexp (`/home/nyc/src/netbsd/sys/uvm/uvm_extern.h`, line 313) mirror the compile-time constants at boot.

**Key observation**: PAGE_SIZE is a simple compile-time constant, not parameterized. There is no MMUPAGE_SIZE / PAGE_MMUSHIFT separation. A page clustering port would need to introduce that split, similar to the Linux larpage approach.

### Contrast with other architectures
- aarch64 (`/home/nyc/src/netbsd/sys/arch/aarch64/include/vmparam.h`): Supports configurable PAGE_SHIFT via `AARCH64_PAGE_SHIFT` (could be 12, 14, or 16), but this is still a single page size, not a decoupled kernel-vs-MMU split.
- or1k: PAGE_SHIFT=13 (8KB pages).
- sparc64: Defines `PAGE_SHIFT_4M` / `PAGE_SIZE_4M` for 4MB superpages alongside the base PAGE_SHIFT, but these are separate constants for explicit superpage use, not a general page clustering mechanism.

## 2. UVM Fault Handler Flow

### Main entry point
`/home/nyc/src/netbsd/sys/uvm/uvm_fault.c`

The fault path is:

```
uvm_fault_internal(orig_map, vaddr, access_type, fault_flag)
  |
  +-- uvm_fault_check()          -- lookup map entry, check protections
  +-- uvm_fault_upper_lookup()   -- check amap for existing anons
  |
  +-- if upper layer hit (anon found in amap):
  |     uvm_fault_upper()        -- handle case 1 (anon fault)
  |       +-- uvm_fault_upper_enter() -- calls pmap_enter()
  |
  +-- if lower layer (uobj or zero-fill):
        uvm_fault_lower()        -- handle case 2 (object fault)
          +-- uvm_fault_lower_direct()   -- direct mapping from uobj
          +-- uvm_fault_lower_promote()  -- COW promotion to new anon
          +-- uvm_fault_lower_enter()    -- calls pmap_enter()
```

The fault handler's `uvm_fault_lower_enter()` (line 2509) calls `pmap_enter()`:
```c
pmap_enter(ufi->orig_map->pmap, ufi->orig_rvaddr,
    VM_PAGE_TO_PHYS(pg),
    readonly ? flt->enter_prot & ~VM_PROT_WRITE : flt->enter_prot,
    flt->access_type | PMAP_CANFAIL | (flt->wire_mapping ? PMAP_WIRED : 0))
```

This maps **a single PAGE_SIZE page** per fault. There is no batching of multiple PTEs per page.

### Neighbor (pre-fault) mechanism
UVM has a neighbor page pre-fault system (lines 150-168, 1121-1141) controlled by `madvise()` hints:
- `UVM_ADV_NORMAL`: 3 pages back, 4 forward (8 pages total including faulting page)
- `UVM_ADV_RANDOM`: 0 back, 0 forward (single page)
- `UVM_ADV_SEQUENTIAL`: 8 back, 7 forward (16 pages total)
- `UVM_MAXRANGE` = 16

This is analogous to Linux's fault-around but operates at the UVM level rather than the file-mapped page cache level.

## 3. pmap Layer Abstraction

### Interface (`/home/nyc/src/netbsd/sys/uvm/uvm_pmap.h`)
The pmap interface is cleanly abstracted:
```c
int   pmap_enter(pmap_t, vaddr_t, paddr_t, vm_prot_t, u_int);
bool  pmap_extract(pmap_t, vaddr_t, paddr_t *);
void  pmap_remove(pmap_t, vaddr_t, vaddr_t);
void  pmap_protect(pmap_t, vaddr_t, vaddr_t, vm_prot_t);
void  pmap_page_protect(struct vm_page *, vm_prot_t);
void  pmap_kenter_pa(vaddr_t, paddr_t, vm_prot_t, u_int);
void  pmap_kremove(vaddr_t, vsize_t);
void  pmap_zero_page(paddr_t);
void  pmap_copy_page(paddr_t, paddr_t);
```

**Key design point**: `pmap_enter()` takes a single `(va, pa)` pair. There is no batch PTE insertion API. For page clustering, you would either:
1. Call `pmap_enter()` N times (once per MMU page within the kernel page), or
2. Add a new `pmap_enter_cluster()` that maps N contiguous MMU pages from one kernel page.

### x86-64 pmap implementation (`/home/nyc/src/netbsd/sys/arch/x86/x86/pmap.c`)
- 6924 lines
- `pmap_enter_default()` (line 4969) delegates to `pmap_enter_ma()` (line 4985)
- `pmap_enter_ma()` manipulates individual PTEs
- Large page (2MB PSE) support exists but **only for kernel text/rodata/data remapping** at boot time via `pmap_remap_largepages()` (line 1845). This uses `PTE_PS` flag in L2 page directory entries.
- No userspace large page / superpage support in pmap_enter path

### Generic pmap (`/home/nyc/src/netbsd/sys/uvm/pmap/`)
A separate generic pmap implementation exists for MIPS/RISC-V/etc architectures. It uses `PGSHIFT` throughout `pmap_segtab.c` for PTE indexing.

## 4. vm_amap / vm_anon Structures for Anonymous Memory

### vm_anon (`/home/nyc/src/netbsd/sys/uvm/uvm_anon.h`)
```c
struct vm_anon {
    krwlock_t   *an_lock;    /* Lock for an_ref */
    uintptr_t    an_ref;     /* Reference count */
    struct vm_page *an_page; /* If in RAM */
    int          an_swslot;  /* Drum swap slot */
};
```

**One anon = one vm_page = one PAGE_SIZE physical page.** This is the fundamental unit coupling. For page clustering, each anon would need to back PAGE_MMUCOUNT MMU pages, or the anon abstraction needs rethinking.

### vm_amap (`/home/nyc/src/netbsd/sys/uvm/uvm_amap.h`)
```c
struct vm_amap {
    krwlock_t *am_lock;
    int am_ref, am_flags, am_maxslot, am_nslot, am_nused;
    int *am_slots;           /* active slot indices */
    int *am_bckptr;          /* back pointers */
    struct vm_anon **am_anon; /* array of anon pointers, one per PAGE */
    int *am_ppref;           /* per-page reference counts */
};
```

The amap is an array indexed by page offset (`AMAP_B2SLOT` macro uses `PAGE_SHIFT`). Each slot holds one anon pointer. For page clustering:
- Slot granularity would remain at kernel PAGE_SIZE
- But each anon's `an_page` would cover PAGE_MMUCOUNT MMU pages
- `AMAP_B2SLOT` would need to use the kernel page shift, not the MMU page shift

### vm_aref
```c
struct vm_aref {
    int ar_pageoff;          /* page offset into amap we start */
    struct vm_amap *ar_amap;
};
```

## 5. struct vm_page and Physical Memory

### vm_page (`/home/nyc/src/netbsd/sys/uvm/uvm_page.h`)
```c
struct vm_page {
    /* first cache line */
    union { TAILQ_ENTRY queue; LIST_ENTRY list; } pageq;
    uint32_t    pqflags;       /* pagedaemon flags */
    uint32_t    flags;         /* object flags */
    paddr_t     phys_addr;     /* physical address */
    uint32_t    loan_count;
    uint32_t    wire_count;
    struct vm_anon    *uanon;  /* owning anon (if PG_ANON) */
    struct uvm_object *uobject; /* owning object */
    voff_t      offset;        /* offset into object */
    /* second cache line */
    kmutex_t    interlock;
    TAILQ_ENTRY pdqueue;       /* pagedaemon queue */
    struct vm_page_md mdpage;  /* pmap-specific data */
};
```

**Critical observations**:
- `phys_addr` stores the physical address directly (lower 10 bits repurposed for freelist/bucket caching)
- `offset` is the offset within the owning uvm_object (in bytes, PAGE_SIZE-aligned)
- The comment says "XXX This entire thing should be shrunk to fit in one cache line" -- it currently spans two cache lines on LP64
- `VM_PAGE_TO_PHYS()` extracts the physical address, `PHYS_TO_VM_PAGE()` does the reverse lookup
- There is **one vm_page per physical PAGE_SIZE page** -- the vm_page array is sized by physical memory / PAGE_SIZE

For page clustering, each vm_page would represent a larger physical allocation (PAGE_MMUCOUNT * MMUPAGE_SIZE bytes), exactly as in the Linux larpage approach. The vm_page array would shrink by a factor of PAGE_MMUCOUNT.

### uvm_object page cache
Pages within a uvm_object are stored in a radix tree (`uo_pages`), indexed by page offset. The page offset is in units of PAGE_SIZE.

## 6. Existing Multiple Page Size Support

**There is essentially none in UVM itself.** Specifically:

- No folio/compound page abstraction (unlike Linux 6.x)
- No page order field in vm_page
- No multi-size page allocator in UVM (no buddy allocator -- UVM uses simple free page lists with color buckets)
- Large pages (2MB) are used **only** in the x86 pmap for kernel segment remapping at boot time
- The `uvm_map()` `align` parameter (line 1063: "this is provided as a mechanism for large pages") only controls virtual address alignment, not physical allocation size
- No THP (transparent huge pages) equivalent
- sparc64 has separate `PAGE_SIZE_4M` constants but these are for explicit use, not integrated into UVM

**This is both a challenge and an opportunity**: UVM is simpler than Linux's MM and has fewer layers to modify, but it also means there is no existing infrastructure to leverage.

## 7. Page Clustering Feasibility Assessment

### Advantages of UVM for page clustering

1. **Clean pmap abstraction**: The pmap interface is well-separated from UVM. A page clustering layer could be inserted between UVM's page allocation and pmap_enter(), mapping PAGE_MMUCOUNT PTEs per kernel page.

2. **Simpler than Linux**: UVM has ~20K lines of core code vs Linux's ~100K+ in mm/. Fewer subsystems to audit. No folios, no compound pages, no THP, no MGLRU, no memory cgroups.

3. **Amap/anon model is clean**: The amap array + anon structure is straightforward. Each slot maps to one page. Changing the page size granularity is conceptually simple.

4. **Neighbor fault mechanism**: The existing pre-fault system (UVM_MAXRANGE=16) already fetches multiple pages per fault. This naturally synergizes with page clustering.

5. **Cross-compilation**: NetBSD's `build.sh` is explicitly designed for cross-compilation from any POSIX host (including Linux/Fedora). `./build.sh -m amd64 -U tools` should work to build the toolchain, then `./build.sh -m amd64 -U kernel=GENERIC` to build a kernel.

### Challenges

1. **vm_page array sizing**: The global vm_page array is allocated based on `npages = physmem / PAGE_SIZE`. With page clustering, this becomes `physmem / (PAGE_SIZE * PAGE_MMUCOUNT)`, requiring early boot changes in `uvm_page_init()`.

2. **Amap slot granularity**: `AMAP_B2SLOT` uses `PAGE_SHIFT`. If amap slots remain at kernel PAGE_SIZE, vm_pgoff-style mismatches (as seen in Linux larpage) would arise when userspace offsets are in MMU page units.

3. **pmap_enter() is single-page**: Every call maps one (va, pa) pair. For page clustering, each kernel page fault would need PAGE_MMUCOUNT pmap_enter() calls, or a new batch API.

4. **UBC (Unified Buffer Cache)**: The buffer cache uses `UBC_WINSHIFT=16` (64KB windows). Page clustering would need to ensure UBC window sizes align with the new page size.

5. **Swap**: Swap slots are PAGE_SIZE-granular. With clustering, swap I/O would need to handle larger units.

6. **No existing test infrastructure**: Unlike Linux with its extensive selftests, NetBSD testing would rely on ATF tests and manual verification.

### Estimated scope

A minimal page clustering port to NetBSD UVM would touch approximately:
- `sys/arch/amd64/include/vmparam.h` -- add MMUPAGE_SIZE/MMUPAGE_SHIFT, redefine PAGE_SIZE
- `sys/arch/amd64/include/param.h` -- update PGSHIFT/NBPG
- `sys/uvm/uvm_param.h` -- update round_page/trunc_page, add mmupage variants
- `sys/uvm/uvm_page.c` -- vm_page array sizing, allocation
- `sys/uvm/uvm_page.h` -- vm_page structure (phys_addr covers larger region)
- `sys/uvm/uvm_fault.c` -- map PAGE_MMUCOUNT PTEs per fault
- `sys/uvm/uvm_anon.c` -- anon allocation covers larger physical pages
- `sys/uvm/uvm_amap.h` -- AMAP_B2SLOT with correct shift
- `sys/arch/x86/x86/pmap.c` -- pmap_enter / pmap_remove for clustered pages
- Userspace syscall layer (mmap, mprotect, etc.) -- align to MMUPAGE_SIZE

This is roughly 10-15 files for a minimal boot, compared to ~50+ files for the Linux larpage port. The simpler architecture makes NetBSD a potentially more tractable target for demonstrating page clustering concepts.

## 8. Cross-Compilation from Fedora

NetBSD's build.sh is designed for cross-compilation from any POSIX host:

```bash
cd /home/nyc/src/netbsd
./build.sh -m amd64 -U -j$(nproc) tools
./build.sh -m amd64 -U -j$(nproc) kernel=GENERIC
```

The `-U` flag enables unprivileged builds (no root required). The build system bootstraps its own toolchain (nbmake, nbcc/gcc cross-compiler, etc.) into `TOOLDIR` before building the kernel.

Requirements on the host: a C compiler (gcc or clang), make, sh, awk, sed -- all present on Fedora. No NetBSD-specific tools are needed on the host.

This has been verified to work on Linux hosts historically and is the standard way NetBSD developers work.
