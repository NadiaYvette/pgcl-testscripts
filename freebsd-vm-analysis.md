# FreeBSD VM Subsystem Analysis for Page Clustering Feasibility

Source tree: `/home/nyc/src/freebsd` (FreeBSD 12.4 `sys/` subtree)
Analysis date: 2026-03-05

## 1. PAGE_SIZE Definition and Propagation

### Definition Chain

PAGE_SIZE is defined per-architecture in `<machine/param.h>`. For amd64:

**File: `/home/nyc/src/freebsd/amd64/include/param.h` lines 100-102**
```c
#define PAGE_SHIFT      12              /* LOG2(PAGE_SIZE) */
#define PAGE_SIZE       (1<<PAGE_SHIFT) /* bytes/page */
#define PAGE_MASK       (PAGE_SIZE-1)
```

Derived macros in the same file:
```c
#define NPTEPG          (PAGE_SIZE/(sizeof (pt_entry_t)))   /* PTEs per page */
#define NPDEPG          (PAGE_SIZE/(sizeof (pd_entry_t)))   /* PDEs per page */
#define round_page(x)   ((((unsigned long)(x)) + PAGE_MASK) & ~(PAGE_MASK))
#define trunc_page(x)    ((unsigned long)(x) & ~(PAGE_MASK))
#define atop(x)          ((unsigned long)(x) >> PAGE_SHIFT)
#define ptoa(x)          ((unsigned long)(x) << PAGE_SHIFT)
#define pgtok(x)         ((unsigned long)(x) * (PAGE_SIZE / 1024))
```

**Key difference from Linux**: FreeBSD defines PAGE_SIZE/PAGE_SHIFT in the
arch-specific `<machine/param.h>` rather than in Kconfig. The value is hardcoded
at compile time, not configurable. Every architecture provides its own definition.

### How PAGE_SIZE Flows

- `<sys/param.h>` includes `<machine/param.h>`, making PAGE_SIZE available
  globally via `#include <sys/param.h>`.
- The VM subsystem uses `atop()`/`ptoa()` for page-frame/byte conversions.
- `round_page()`/`trunc_page()` for alignment.
- `vm_pindex_t` is the page index type (offset within a vm_object, in PAGE_SIZE units).

## 2. Fault Handler: vm_fault()

**File: `/home/nyc/src/freebsd/vm/vm_fault.c` line 682**

Entry point: `vm_fault(vm_map_t map, vm_offset_t vaddr, vm_prot_t fault_type, int fault_flags, vm_page_t *m_hold)`

### Fault Flow Summary

1. **Map lookup**: `vm_map_lookup()` finds the `vm_map_entry` and the backing
   `vm_object` + `pindex` for the faulting address.

2. **Soft fast path** (`vm_fault_soft_fast()`, line 284): If the page already
   exists in the top-level object with all bits valid, it can be mapped without
   taking a write lock. This path includes **superpage promotion** -- if a
   reservation's superpage is fully populated, `pmap_enter()` is called with
   `psind > 0` to install a 2MB mapping.

3. **Hard fault path** (main body of `vm_fault()`, line 682+): Walks the
   shadow object chain looking for the page. If not found, allocates a new page
   and calls `vm_pager_get_pages()` to fill it. COW is handled by copying the
   page from the backing object to the top-level object.

4. **Page installation** (line 1441):
   ```c
   pmap_enter(fs.map->pmap, vaddr, fs.m, prot,
       fault_type | (wired ? PMAP_ENTER_WIRED : 0), 0);
   ```
   Note: the hard fault path always passes `psind=0` (base page). Superpage
   mappings are only created via the soft fast path or the populate path.

5. **Prefault** (`vm_fault_prefault()`, line 1574): After a fault, neighboring
   pages are speculatively mapped via `pmap_enter_quick()`.

### Populate Path (vm_fault_populate, line 399)

For pagers that implement `populate()` (e.g., device pagers), the pager can
return multiple pages at once. The fault handler iterates over them, checking
each page's `psind` field to decide whether to create a superpage mapping or
individual base-page mappings.

## 3. The pmap Layer Interface

**File: `/home/nyc/src/freebsd/vm/pmap.h`**

The pmap layer provides the machine-independent interface to the MMU. Key functions:

| Function | Purpose |
|----------|---------|
| `pmap_enter(pmap, va, m, prot, flags, psind)` | Map page `m` at virtual address `va`. `psind` selects page size. |
| `pmap_enter_object(pmap, start, end, m_start, prot)` | Map a range of pages from an object |
| `pmap_enter_quick(pmap, va, m, prot)` | Quick map for prefault (no sleep) |
| `pmap_remove(pmap, sva, eva)` | Remove mappings in range |
| `pmap_remove_all(m)` | Remove all mappings of page `m` |
| `pmap_protect(pmap, sva, eva, prot)` | Change protection |
| `pmap_extract(pmap, va)` | Get physical address for VA |
| `pmap_zero_page(m)` | Zero a page |
| `pmap_copy_page(src, dst)` | Copy page contents |
| `pmap_align_superpage(obj, offset, addr, size)` | Align address for superpage |
| `pmap_is_modified(m)` / `pmap_is_referenced(m)` | Query dirty/referenced bits |

**Critical observation**: `pmap_enter()` takes an explicit `int8_t psind` parameter
that indexes into the `pagesizes[]` array. This is the hook for multi-size page
support. When `psind=0`, a base 4KB PTE is installed. When `psind=1`, a 2MB PDE
with PG_PS is installed.

## 4. Existing Multi-Page-Size (Superpage) Support

FreeBSD has **mature, production superpage support** via the reservation system.
This is substantially more advanced than Linux's THP.

### Architecture

#### pagesizes[] Array

Declared in `<sys/systm.h>`:
```c
extern u_long pagesizes[];      /* supported page sizes */
```

`MAXPAGESIZES` is defined per-architecture. For amd64:
```c
#define MAXPAGESIZES    3       /* 4KB, 2MB, 1GB */
```

Initialized in `pmap_init()` (`amd64/amd64/pmap.c` line 1955):
```c
pagesizes[1] = NBPDR;          /* 2MB = 1 << 21 */
```
(pagesizes[0] = PAGE_SIZE is set elsewhere; pagesizes[2] would be 1GB if supported.)

#### vm_page.psind Field

Every `vm_page` has an `int8_t psind` field (line 212 of `vm/vm_page.h`):
```c
int8_t psind;   /* pagesizes[] index (O) */
```

When a page is the head of a fully-populated reservation (superpage), its
`psind` is set to the reservation level (e.g., 1 for 2MB). The fault handler
checks this to decide whether to create a superpage mapping.

#### Reservation System (vm_reserv)

**File: `/home/nyc/src/freebsd/vm/vm_reserv.c`**

The reservation system (`VM_NRESERVLEVEL > 0`) speculatively allocates
physically contiguous groups of pages aligned to superpage boundaries. For
amd64:

```c
#define VM_NRESERVLEVEL     1       /* one level of superpages */
#define VM_LEVEL_0_ORDER    9       /* 512 pages = 2MB */
#define VM_LEVEL_0_NPAGES   (1 << VM_LEVEL_0_ORDER)  /* 512 */
#define VM_LEVEL_0_SHIFT    (VM_LEVEL_0_ORDER + PAGE_SHIFT)  /* 21 */
#define VM_LEVEL_0_SIZE     (1 << VM_LEVEL_0_SHIFT)  /* 2MB */
```

Each `vm_object` has a list of reservations (`LIST_HEAD(, vm_reserv) rvq`).
A reservation tracks which of its 512 constituent pages are populated via
a population bitmap (`popmap_t`). When fully populated, `vm_reserv_to_superpage()`
returns the head page with `psind=1`, enabling the fault handler to create
a 2MB mapping.

Key reservation functions:
- `vm_reserv_alloc_page()` - Allocate a page within an existing or new reservation
- `vm_reserv_to_superpage()` - Check if page belongs to a fully populated reservation
- `vm_reserv_break_all()` - Break all reservations for an object (e.g., on COW)
- `vm_reserv_reclaim_contig()` - Reclaim reservation pages for contiguous allocation

#### Superpage Promotion/Demotion in pmap

In `amd64/amd64/pmap.c`:
- `pmap_promote_pde()` (line 5590): Promotes 512 individual PTEs to a single
  2MB PDE with PG_PS, if all PTEs are compatible.
- `pmap_demote_pde()`: Demotes a 2MB PDE back to 512 PTEs (e.g., for
  partial protection changes).
- `pmap_enter_pde()`: Directly enters a 2MB page directory entry.
- `pmap_ps_enabled()`: Checks if superpages are enabled for a given pmap.

### Summary of Superpage Architecture

```
vm_fault_soft_fast()
    |
    v
vm_reserv_to_superpage(m) -- returns head page if reservation fully populated
    |
    v
pmap_enter(pmap, va, m_super, prot, flags, psind=1)
    |
    v
pmap_enter_pde() -- installs 2MB PDE with PG_PS bit
```

## 5. vm_page and vm_object Relationship

### vm_page Structure (`/home/nyc/src/freebsd/vm/vm_page.h` line 188)

```c
struct vm_page {
    /* queue/freelist linkage */
    union { TAILQ_ENTRY(vm_page) q; ... } plinks;
    TAILQ_ENTRY(vm_page) listq;    /* pages in same object */
    vm_object_t object;             /* which object am I in */
    vm_pindex_t pindex;             /* offset into object */
    vm_paddr_t phys_addr;           /* physical address (immutable) */
    struct md_page md;              /* machine-dependent (PV lists) */
    u_int wire_count;               /* wired maps refs */
    volatile u_int busy_lock;       /* busy owners lock */
    uint16_t hold_count;
    uint16_t flags;                 /* PG_* flags */
    uint8_t aflags;                 /* atomic flags */
    uint8_t oflags;                 /* object flags (VPO_*) */
    uint8_t queue;                  /* page queue index */
    int8_t psind;                   /* pagesizes[] index */
    int8_t segind;                  /* vm_phys segment index */
    uint8_t order;                  /* buddy queue index */
    uint8_t pool;                   /* vm_phys freepool index */
    u_char act_count;               /* page usage count */
    vm_page_bits_t valid;           /* valid DEV_BSIZE chunks */
    vm_page_bits_t dirty;           /* dirty DEV_BSIZE chunks */
};
```

**Key points for page clustering**:
- One `vm_page` per hardware page (4KB on amd64). There is a flat array
  `vm_page_array[]` with one entry per physical page frame.
- `pindex` is in PAGE_SIZE units within the object.
- `valid`/`dirty` are bitmaps tracking sub-page validity at DEV_BSIZE (512-byte)
  granularity. The type varies with PAGE_SIZE (uint8_t for 4KB, uint16_t for
  8KB, uint32_t for 16KB, uint64_t for 32KB).
- `PHYS_TO_VM_PAGE(pa)` converts a physical address to a vm_page pointer.

### vm_object Structure (`/home/nyc/src/freebsd/vm/vm_object.h` line 98)

```c
struct vm_object {
    struct rwlock lock;
    TAILQ_ENTRY(vm_object) object_list;
    LIST_HEAD(, vm_object) shadow_head;     /* shadow chain */
    LIST_ENTRY(vm_object) shadow_list;
    struct pglist memq;                      /* list of resident pages */
    struct vm_radix rtree;                   /* radix trie for page lookup */
    vm_pindex_t size;                        /* object size in pages */
    int ref_count;
    int shadow_count;
    objtype_t type;                          /* OBJT_DEFAULT, OBJT_VNODE, etc. */
    struct vm_object *backing_object;        /* COW parent */
    vm_ooffset_t backing_object_offset;
    LIST_HEAD(, vm_reserv) rvq;              /* superpage reservations */
    /* ... pager-specific union ... */
};
```

**Object-page relationship**:
- Pages are looked up by `(object, pindex)` via the radix trie (`vm_page_lookup()`).
- Pages are also linked into the object's `memq` list.
- Shadow objects form a chain for COW: `backing_object` points to the parent.
- The `rvq` list links superpage reservations belonging to this object.

## 6. Feasibility Assessment for Page Clustering

### Structural Comparison with Linux

| Aspect | Linux | FreeBSD |
|--------|-------|---------|
| Page structure | `struct page` (64 bytes, overloaded) | `struct vm_page` (~128 bytes, clean) |
| Page cache index | `folio->index` in PAGE_SIZE units | `pindex` in PAGE_SIZE units |
| VMA offset | `vm_pgoff` in PAGE_SIZE units | `vm_map_entry->offset` in bytes |
| pmap/MMU abstraction | None (inline PTEs) | Clean `pmap_enter(psind)` interface |
| Superpage support | THP (transparent huge pages), ad hoc | Reservation system with `psind` |
| Page size compile-time | `PAGE_SHIFT` in Kconfig | `PAGE_SHIFT` in `<machine/param.h>` |

### Advantages for Page Clustering in FreeBSD

1. **Clean pmap abstraction**: The `pmap_enter(psind)` interface already
   supports multiple page sizes. Adding a new page size between 4KB and 2MB
   (e.g., 16KB or 64KB) could be expressed naturally via `pagesizes[1]` with
   the existing 2MB support moved to `pagesizes[2]`.

2. **No vm_pgoff unit mismatch**: FreeBSD uses byte offsets in `vm_map_entry->offset`
   rather than page-index offsets. This avoids the Linux problem where `vm_pgoff`
   is in one unit while the page cache uses another.

3. **psind field on vm_page**: The `psind` field already tags pages with their
   effective mapping size. A page clustering scheme could set `psind` to indicate
   the cluster size.

4. **Reservation system as foundation**: The `vm_reserv` system already manages
   contiguous physical page groups. A page clustering approach could reduce
   `VM_LEVEL_0_ORDER` (currently 9 for 512 pages = 2MB) to smaller values
   (e.g., 2 for 4 pages = 16KB) to guarantee smaller superpages.

5. **valid/dirty bitmaps scale with PAGE_SIZE**: The `vm_page_bits_t` type
   already adapts to PAGE_SIZE (see `vm_page.h` lines 174-186), suggesting
   the codebase has been designed to accommodate different page sizes.

### Challenges for Page Clustering in FreeBSD

1. **One vm_page per physical page**: The flat `vm_page_array[]` has one entry
   per 4KB page. Page clustering (kernel pages > MMU pages) would either need
   to keep this array (wasting entries for pages within a cluster) or restructure
   it to track clusters instead.

2. **pindex units**: `vm_pindex_t` is in PAGE_SIZE units throughout. Changing
   PAGE_SIZE would change the meaning of all pindex values, affecting the
   object/page lookup, the radix trie, and every consumer.

3. **COW at page granularity**: Copy-on-write operates on individual `vm_page`
   structures. With page clustering, COW would need to operate on clusters,
   requiring cluster-level splitting (similar to Linux folio splitting).

4. **atop()/ptoa() pervasive**: These macros use PAGE_SHIFT and appear hundreds
   of times. A decoupled MMUPAGE_SHIFT would require auditing every use.

5. **No build-time configurability**: Unlike Linux's Kconfig, FreeBSD's
   PAGE_SHIFT is a hardcoded constant. Adding a CONFIG_PAGE_MMUSHIFT-style
   mechanism would require build system changes.

### Approach Options

**Option A: Change PAGE_SIZE directly** (analogous to ARM64 FreeBSD with 16KB pages)
- Simplest conceptually: set `PAGE_SHIFT=14` for 16KB pages
- All `vm_page` structures become 16KB granularity
- Breaks userspace ABI (mmap alignment, etc.)
- ARM64 FreeBSD already supports PAGE_SIZE=16384, proving feasibility

**Option B: Larpage-style decoupling** (PAGE_SIZE != MMUPAGE_SIZE)
- More complex: introduce MMUPAGE_SHIFT alongside PAGE_SHIFT
- Keeps userspace seeing 4KB pages while kernel allocates in clusters
- Requires the same kind of audit as the Linux PGCL work
- The clean pmap interface makes the MMU side easier than Linux

**Option C: Leverage the reservation system**
- Use reservations at smaller granularities (e.g., 16KB instead of 2MB)
- No kernel-wide PAGE_SIZE change needed
- Superpages of 16KB guaranteed by the reservation system
- Most conservative approach, but limited to physically contiguous optimization

## 7. Cross-Compilation from Fedora 43

### Compiler

```
clang version 21.1.8 (Fedora 21.1.8-4.fc43)
Target: x86_64-redhat-linux-gnu
```

Clang supports x86_64 target and FreeBSD uses clang as its system compiler.
Cross-compilation is feasible with `--target=x86_64-unknown-freebsd14` (or
similar). However:

- FreeBSD headers and libraries are needed (sysroot)
- The build system (`make buildworld`/`make buildkernel`) expects a FreeBSD
  host environment
- Kernel-only cross-compilation is more tractable than full world builds

### Build Commands

FreeBSD kernel build (native):
```bash
cd /usr/src
make buildkernel KERNCONF=GENERIC
```

Cross-compilation (from Linux):
```bash
# Requires FreeBSD sysroot with headers
make buildkernel KERNCONF=GENERIC \
    TARGET=amd64 TARGET_ARCH=amd64 \
    CROSS_TOOLCHAIN=llvm \
    SYSROOT=/path/to/freebsd-sysroot
```

### Practical Recommendation

Cross-compiling a FreeBSD kernel from Linux is possible but non-trivial. The
most practical approach would be:
1. Build in a FreeBSD VM or jail
2. Use `qemu-system-x86_64` with a FreeBSD image for testing
3. Alternatively, use the FreeBSD CI infrastructure

The source tree at `/home/nyc/src/freebsd` appears to be only the `sys/`
subtree (kernel source), not a full source tree. A full `make buildkernel`
requires the complete source tree including `share/mk/` (the build system
makefiles), `tools/`, and `contrib/`.

## 8. Key Findings Summary

1. **FreeBSD already has production superpage support** via the reservation
   system and `pmap_enter(psind)` interface, handling 2MB and potentially 1GB
   pages on amd64.

2. **The pmap abstraction is cleaner than Linux** for multi-size page support.
   The explicit `psind` parameter to `pmap_enter()` is a natural extension
   point for additional page sizes.

3. **vm_map_entry uses byte offsets** (not page offsets), avoiding the unit
   mismatch problem that plagues the Linux PGCL port.

4. **The vm_page_bits_t type already scales with PAGE_SIZE**, suggesting the
   codebase was designed with variable page sizes in mind.

5. **Page clustering at the reservation level (Option C)** would be the least
   invasive approach, leveraging the existing `vm_reserv` infrastructure to
   guarantee small superpages without changing `PAGE_SIZE`.

6. **A full Larpage-style port (Option B)** is feasible but would require
   a similar audit effort to the Linux PGCL work, with the advantage that
   FreeBSD's VM is more cleanly layered.
