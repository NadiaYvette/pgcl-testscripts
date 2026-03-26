# Redox OS Kernel Memory Management Analysis

**Kernel version**: 0.5.12 (cloned 2026-03-05)
**Repository**: https://gitlab.redox-os.org/redox-os/kernel.git (GitHub mirror available)
**Architectures**: x86_64, x86 (i586), aarch64, riscv64

## 1. PAGE_SIZE Definition

PAGE_SIZE is defined at:
- `/home/nyc/src/redox/src/arch/x86_shared/paging/mod.rs:29`:
  ```rust
  pub const PAGE_SIZE: usize = RmmA::PAGE_SIZE;
  ```
- Similarly for aarch64 (`src/arch/aarch64/paging/mod.rs:15`) and riscv64 (`src/arch/riscv64/paging/mod.rs:16`).

`RmmA` is a type alias for the architecture-specific RMM (Redox Memory Manager) arch trait
implementation, defined in the `rmm` crate (a git submodule at `/home/nyc/src/redox/rmm/`,
dependency in Cargo.toml: `rmm = { path = "rmm", default-features = false }`). For x86_64,
`RmmA::PAGE_SIZE` is 4096.

There is also:
- `PAGE_MASK: usize = RmmA::PAGE_OFFSET_MASK` (0xFFF for 4k pages)
- `ENTRY_COUNT: usize = RmmA::PAGE_ENTRIES` (512 for x86_64)

The kernel has **no concept of MMUPAGE_SIZE vs PAGE_SIZE**. There is a single PAGE_SIZE
constant used throughout, derived from the hardware MMU page size via the `rmm` crate.

## 2. Page Fault Handling

### Entry point (x86)
`/home/nyc/src/redox/src/arch/x86_shared/interrupt/exception.rs:179-226`

The `page` interrupt handler:
1. Reads CR2 for the faulting address.
2. Converts x86 `PageFaultError` bitflags into generic `GenericPfFlags`.
3. Calls `crate::memory::page_fault_handler(stack, generic_flags, cr2)`.

### Generic handler
`/home/nyc/src/redox/src/memory/mod.rs:1002-1052`

`page_fault_handler()`:
1. Classifies the fault: user vs kernel, read vs write vs instruction-fetch, usercopy region check.
2. If the faulting address is in userspace and the fault was caused by userspace (or by a kernel usercopy), calls `context::memory::try_correcting_page_tables()`.
3. If correction fails with Segv, and it was a kernel usercopy, performs EFAULT recovery (rewrites instruction pointer to error-return path).
4. Otherwise returns `Err(Segv)` which sends a signal to the process.

### Page table correction (demand paging + COW)
`/home/nyc/src/redox/src/context/memory.rs:2417-2433` and `correct_inner()` at line 2434.

`try_correcting_page_tables()`:
1. Gets the current address space (`AddrSpace::current()`).
2. Calls `correct_inner()` which acquires a write lock on the address space.

`correct_inner()`:
1. Looks up the faulting page in the grant map (`grants.contains(faulting_page)`).
2. Checks whether the access mode is permitted by the grant's flags.
3. Translates the faulting page in the current page table to see if a frame is already mapped.
4. Dispatches by `Provider` type:
   - **Allocated / AllocatedShared + Write**: If a frame exists and `allows_writable()`, done. If CoW (refcount > 1, not shared), calls `cow()` to copy the frame. If no frame mapped at all, calls `map_zeroed()`.
   - **Allocated / AllocatedShared + Read**: If frame exists, just re-map it (possibly stale TLB). If no frame, `map_zeroed()` with a shared zeroed frame (demand zero).
   - **PhysBorrowed**: Direct physical address calculation, no CoW.
   - **External**: Borrows from another address space. Recursively resolves the source page (up to 16 levels of recursion), then adds a shared reference.
   - **FmapBorrowed**: Invokes the scheme's fmap handler to resolve the page from a userspace scheme.

### COW implementation
`/home/nyc/src/redox/src/context/memory.rs:2342-2383`

The `cow()` function:
- If refcount is One (exclusively owned), no copy needed, just upgrade refcount if needed.
- Otherwise, allocates a new frame, copies the old frame's contents (PAGE_SIZE bytes), and returns both old and new frames (caller must handle TLB shootdown for the old frame).

### Demand zero
`map_zeroed()` at line 2385: Allocates a fresh zeroed frame, maps it, returns it.

For lazy allocation, `Grant::zeroed()` (line 1292) maps only the first 16 pages eagerly, all pointing to a global "the_zeroed_frame" with CoW refcount. Remaining pages are unmapped and will be demand-faulted.

## 3. Page Table Management

### Structure
Page tables are managed through the `rmm` crate's `PageMapper<RmmA, TheFrameAllocator>` type.

Key operations:
- `mapper.map_phys(virt, phys, flags)` - Maps a virtual address to a physical frame.
- `mapper.translate(virt)` - Returns `Option<(PhysicalAddress, PageFlags)>`.
- `PageMapper::current(TableKind, allocator)` - Gets the current page table.

### TLB management
`/home/nyc/src/redox/src/arch/x86_shared/paging/mapper.rs`

Uses `PageFlush` and `PageFlushAll` from the `rmm` crate. The `InactiveFlusher` sends TLB
shootdown IPIs to other CPUs. The `Flusher` type (in `context/memory.rs`) batches TLB
invalidations and sends IPIs with CPU set tracking.

### Kernel page table
`/home/nyc/src/redox/src/memory/kernel_mapper.rs`

`KernelMapper` is a reentrant spinlock protecting the upper half (kernel) address space.
The kernel uses a single shared page table for the upper half, and per-address-space user
page tables for the lower half. Context switches swap the user portion (lower 256 PML4
entries on x86_64).

### Virtual address layout (x86_64)
`/home/nyc/src/redox/src/arch/x86_64/consts.rs`
- Lower half (PML4 entries 0-255, 128 TiB): userspace.
- `PHYS_OFFSET = 0xFFFF_8000_0000_0000`: linear mapping of all physical memory.
- `KERNEL_HEAP_OFFSET`: just below kernel image.
- `KERNEL_OFFSET = -2GiB` (top of address space): kernel image.
- `USER_END_OFFSET = 256 * PML4_SIZE`: end of user address space.

## 4. Memory Model

### Address spaces
Each process has an `AddrSpace` (`/home/nyc/src/redox/src/context/memory.rs:143`):
```rust
pub struct AddrSpace {
    pub table: Table,          // Contains the PageMapper (utable)
    pub grants: UserGrants,    // BTreeMap<Page, GrantInfo> + holes
    pub used_by: LogicalCpuSet,
    pub mmap_min: usize,       // Default: PAGE_SIZE
}
```

Wrapped in `AddrSpaceWrapper` with an `RwLock`, atomic TLB ack counter, and CPU set for shootdowns.

### Grant system
Memory regions are tracked as "grants" (`Grant`):
```rust
pub struct Grant {
    pub base: Page,
    pub info: GrantInfo,
}
pub struct GrantInfo {
    page_count: usize,
    flags: PageFlags<RmmA>,
    mapped: bool,
    pub provider: Provider,
}
```

Grant providers:
- **Allocated**: Owned, possibly CoW. Supports lazy population and CoW file references for mmap-from-scheme.
- **AllocatedShared**: Owned, shared (MAP_SHARED anonymous). Remains shared across fork.
- **PhysBorrowed**: Direct physical memory mapping (MMIO, device memory). Not allocator-managed.
- **External**: Borrowed from another address space (cross-process shared memory).
- **FmapBorrowed**: MAP_SHARED from a scheme (file-backed shared mapping).

### COW and fork
`AddrSpaceWrapper::try_clone()` (line 155) clones the address space:
- **Allocated** grants: Uses `copy_mappings()` which makes both parent and child mappings read-only and sets CoW refcounts.
- **AllocatedShared** grants: Also `copy_mappings()` but in Borrowed mode (shared, not CoW).
- **PhysBorrowed**: Creates a new physmap (identity copy).
- **External**: Creates another borrow of the same source address space.
- **FmapBorrowed** and pinned grants: Skipped (not preserved across fork).

### Demand paging
- `Grant::zeroed()` eagerly maps only up to 16 pages to the global zeroed frame (CoW).
- Remaining pages fault in via `correct_inner()` which allocates fresh zeroed frames on demand.
- Schemes can provide file-backed pages lazily via the fmap mechanism.

### mmap support
`MemoryScheme::fmap_anonymous()` handles anonymous mmap via `Grant::zeroed()` or `Grant::zeroed_phys_contiguous()`.
`MemoryScheme::physmap()` handles physical memory mapping.
The mremap equivalent is `AddrSpaceWrapper::r#move()`.
Mprotect: `AddrSpaceWrapper::mprotect()`.
Munmap: `AddrSpaceWrapper::munmap()`.

### Physical frame allocator
`/home/nyc/src/redox/src/memory/mod.rs`

A buddy allocator with 11 orders (0..10, so max 2^10 = 1024 contiguous pages = 4 MiB blocks).
Each frame has a `PageInfo` with:
- Atomic refcount (with bits for used/free, shared/CoW flags).
- Atomic next pointer (doubly-linked free list per order).

Sections track contiguous physical memory regions, each with an array of PageInfo structs.

## 5. Process Address Space Setup

Process creation (`/home/nyc/src/redox/src/syscall/process.rs`):
1. `AddrSpace::new()` creates a fresh address space with `setup_new_utable()`.
2. Kernel metadata is mapped at `PAGE_SIZE` (one page above null).
3. Bootstrap/initfs is mapped as a user-readable region.
4. The ELF loader (in userspace, not kernel) sets up text/data/bss/stack via mmap syscalls.

The Redox microkernel delegates most process setup to userspace; the kernel only provides
the memory mapping primitives (mmap/munmap/mprotect/mremap via schemes).

## 6. Build Requirements

### Rust toolchain
`/home/nyc/src/redox/rust-toolchain.toml`:
```toml
[toolchain]
channel = "nightly-2025-10-03"
components = ["rust-src"]
```

Requires Rust **nightly-2025-10-03** with `rust-src` component. The build uses:
- `-Z build-std=core,alloc` (builds std library from source)
- `-Zbuild-std-features=compiler-builtins-mem`
- Custom target spec: `targets/x86_64-unknown-kernel.json`

### Target spec highlights
- `llvm-target`: `x86_64-unknown-none`
- Soft-float (no SSE/AVX in kernel mode)
- Static linking with `rust-lld`
- No redzone
- `panic = "abort"`

### Can it be built on Fedora 43?
In principle yes, with caveats:
1. Install the specific nightly: `rustup toolchain install nightly-2025-10-03`
2. Add rust-src: `rustup component add rust-src --toolchain nightly-2025-10-03`
3. The `rmm` submodule must be populated: `git submodule update --init` (our shallow clone left it empty).
4. Cross-compilation toolchain for `x86_64-unknown-redox` is needed for `objcopy` step (the `GNU_TARGET` variable in the Makefile). Alternatively, `llvm-objcopy` could be substituted.
5. Rust edition 2024 requires a sufficiently recent nightly, which nightly-2025-10-03 satisfies.

The kernel build itself (before objcopy) should work with just `rustup` and the nightly toolchain. The full `make` requires the Redox cross toolchain for the final objcopy step, but `cargo build` alone should succeed.

## 7. Page Clustering Feasibility Assessment

### Architecture observations

**Single PAGE_SIZE constant**: The kernel uses one `PAGE_SIZE` derived from `RmmA::PAGE_SIZE` (the hardware MMU page size). There is no separation between kernel allocation granularity and MMU page size. Every page table entry maps exactly one PAGE_SIZE region.

**Clean abstraction layer**: The `rmm` crate provides a clean architecture abstraction for page table operations. PAGE_SIZE flows from `rmm::Arch::PAGE_SIZE` into the kernel. Modifying `rmm` to expose both an `MMUPAGE_SIZE` and a larger `PAGE_SIZE` would be the natural starting point.

**Grant-based VM**: Unlike Linux's VMA+page-cache model, Redox tracks memory regions as "Grants" in a BTreeMap. Each Grant has a page count in PAGE_SIZE units. The Grant system is relatively simple compared to Linux's mm subsystem.

**PageInfo per frame**: The `PageInfo` struct is allocated per physical frame (one per PAGE_SIZE). With page clustering, each PAGE_SIZE allocation would span multiple MMU pages, requiring either:
- One PageInfo per clustered page (and the frame allocator tracks clustered-page-sized units), or
- Multiple PageInfos per clustered page (wasteful but avoids allocator changes).

**CoW granularity**: CoW operates at PAGE_SIZE granularity. With clustering, the CoW unit would increase (copying PAGE_MMUCOUNT * MMUPAGE_SIZE bytes per CoW fault), which is acceptable and reduces per-page overhead.

### Key changes needed for page clustering

1. **rmm crate**: Add `MMUPAGE_SIZE` / `MMUPAGE_SHIFT` constants. `PAGE_SIZE` becomes the cluster size. Page table operations internally use `MMUPAGE_SIZE`.

2. **Page table mapping**: `mapper.map_phys()` would need to create `PAGE_MMUCOUNT` PTE entries per "page" mapping. The `rmm` crate's `PageMapper` would need modification.

3. **Frame allocator**: Allocate in units of `PAGE_SIZE` (clustered pages). The buddy allocator already works with PAGE_SIZE-aligned frames, so this is mostly transparent.

4. **Userspace interface**: Syscalls (mmap, mprotect, munmap) currently align to PAGE_SIZE. With clustering, userspace should still see MMUPAGE_SIZE alignment (same as Linux PGCL), but the kernel internally rounds up to PAGE_SIZE for grant management.

5. **physmap/MMIO**: Physical memory mappings need MMUPAGE_SIZE granularity since hardware devices may have MMIO regions not aligned to the cluster size.

### Advantages over Linux PGCL

- **Much smaller codebase**: ~15K lines of Rust vs millions of lines of C. The surface area for PAGE_SIZE assumptions is dramatically smaller.
- **No page cache complexity**: Redox's microkernel has no in-kernel filesystem page cache. The Linux PGCL `vm_pgoff` unit mismatch problem does not exist here.
- **Type safety**: Rust's type system can enforce the distinction between Page (clustered) and MmuPage at compile time, catching unit confusion bugs that are runtime-only in C.
- **Grant model is simpler**: The Grant-based VM is far simpler than Linux's VMA+rmap+page-cache model. Fewer places where page size assumptions are embedded.
- **Clean arch abstraction**: The `rmm` crate provides a single point where the PAGE_SIZE/MMUPAGE_SIZE split can be introduced.

### Estimated difficulty
Moderate. The kernel is small and well-structured. The main challenge is the `rmm` crate (which manages page table walks and needs to understand the multi-PTE-per-page mapping). The rest of the kernel has ~80 uses of PAGE_SIZE that would need auditing, compared to thousands in Linux.
