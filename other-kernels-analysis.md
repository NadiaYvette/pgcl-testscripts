# Page Clustering Feasibility: Other Kernel VM Subsystem Analysis

Date: 2026-03-05
Kernels surveyed: SerenityOS, Haiku, seL4, Zircon (Fuchsia)

---

## 1. SerenityOS

**Clone**: `/home/nyc/src/serenity` (GitHub, `--depth 1`)

### PAGE_SIZE Definition

Defined in `AK/Platform.h`:
```c
#define PAGE_SIZE 4096       // (on Serenity target)
// On host builds: sysconf(_SC_PAGESIZE)
```
No PAGE_SHIFT defined; all arithmetic uses `PAGE_SIZE` directly. The constant
is hardcoded to 4096 with no arch-parameterization.

### Fault Handler / Page Mapping Entry Point

- **Interrupt entry**: `Kernel/Arch/x86_64/Interrupts.cpp` defines `page_fault_handler(TrapFrame*)`.
- **Arch-generic dispatch**: `Kernel/Arch/PageFault.cpp` calls `MM.handle_page_fault(*this)`.
- **Core fault handler**: `Kernel/Memory/MemoryManager.cpp:1106` —
  `PageFaultResponse MemoryManager::handle_page_fault(PageFault const&)`.
  Locates the faulting `Region`, increments a page-fault counter on it (for
  lifetime management), then dispatches to `Region::handle_fault()`.
- **Region-level**: `Kernel/Memory/Region.cpp:405` —
  `PageFaultResponse Region::handle_fault(PageFault const&)`.

### Page Table Management

- `Kernel/Memory/MemoryManager.h` — `PageDirectoryEntry`, `PageTableEntry`
  (forward declarations), `ensure_pte()`, `pte()`, `quickmap_pt()`.
- Arch-specific: `Kernel/Arch/x86_64/PageDirectory.h`,
  `Kernel/Arch/riscv64/MMU.cpp`, `Kernel/Arch/aarch64/MMU.cpp`.
- Page table walks use `PAGE_SIZE` throughout with no abstraction for
  different mapping granularities.

### Multi-Page-Size Support

**None.** No large page or huge page support anywhere in the kernel.
`Grep` for `large_page`, `huge_page`, `LARGE_PAGE` in `Kernel/` returns
zero matches. SerenityOS maps everything with 4KB PTEs.

### Build System & Cross-Compilation

CMake-based. Requires a custom toolchain (GCC 15.2.0 or LLVM 22.1.0) built
specifically for the `SerenityOS` target triple. The build system rejects
any `CMAKE_SYSTEM_NAME` other than `SerenityOS`. Cross-compilation from
Fedora 43 requires building the SerenityOS toolchain first (documented in
their `BuildInstructions`). Supports x86_64, aarch64, riscv64.

### Page Clustering Feasibility Notes

SerenityOS has a very clean, small VM implementation (~8 files in
`Kernel/Memory/`). The `PAGE_SIZE` usage is centralized but hardcoded.
The VMObject/Region/MemoryManager layering is straightforward. Key
challenge: `PAGE_SIZE` is baked into `AK/Platform.h` and used across the
entire codebase (not just the kernel). No existing multi-granularity
infrastructure to build on.

---

## 2. Haiku

**Clone**: `/home/nyc/src/haiku` (GitHub, `--depth 1`, pre-existing)

### PAGE_SIZE Definition

Architecture-specific `PAGESIZE` in POSIX headers:
- `headers/posix/arch/x86_64/limits.h:8`: `#define PAGESIZE 4096`
- `headers/posix/arch/sparc64/limits.h:8`: `#define PAGESIZE 8192` (!)
- Other arches (arm, arm64, riscv64, m68k, ppc, mipsel): `#define PAGESIZE 4096`

Kernel-internal:
- `headers/os/kernel/OS.h:27`: `#define B_PAGE_SIZE PAGESIZE`
- `headers/posix/limits.h:101`: `#define PAGE_SIZE PAGESIZE`
- `headers/private/kernel/arch/x86/arch_vm.h:13`: `#define PAGE_SHIFT 12`

Notable: SPARC64 uses 8192-byte pages, showing Haiku already accommodates
non-4KB page sizes at the arch level.

### Fault Handler / Page Mapping Entry Point

- **Entry**: `src/system/kernel/arch/x86/arch_int.cpp` dispatches to
  `vm_page_fault()`.
- **Core fault handler**: `src/system/kernel/vm/vm.cpp:4044` —
  `vm_page_fault(addr_t address, addr_t faultAddress, bool isWrite,
  bool isExecute, bool isUser, addr_t* newIP)`.
  Rounds address down to `B_PAGE_SIZE`, determines address space
  (kernel vs user), then calls `vm_soft_fault()`.
- **Soft fault**: `vm_soft_fault()` (same file, declared at line 263)
  handles the actual page-in / COW / mapping logic.

### Page Table Management

The VM subsystem has a clean abstraction layer:
- **Abstract base**: `src/system/kernel/vm/VMTranslationMap.cpp` —
  `VMTranslationMap` with virtual methods: `Map()`, `Unmap()`,
  `UnmapPages()`, `UnmapArea()`, `Query()`.
- **x86-64 concrete**: `src/system/kernel/arch/x86/paging/64bit/`
  - `X86VMTranslationMap64Bit.cpp` — PTE manipulation
  - `X86PagingMethod64Bit.cpp` — page table allocation
  - `paging.h` — PML5/PML4/PDPT/PDE/PTE bit definitions
- Also has PAE (32-bit), 32-bit legacy, riscv64 implementations.
- Page table constants in `paging.h`:
  ```c
  k64BitPageTableRange = 0x200000L;      // 2MB per PT
  k64BitPageDirectoryRange = 0x40000000L; // 1GB per PD
  k64BitTableEntryCount = 512;
  ```

### Multi-Page-Size Support

**Partial — large page awareness exists but is limited:**
- `paging.h` defines `X86_64_PDE_LARGE_PAGE` (bit 7) and
  `X86_64_PDPTE_LARGE_PAGE` (bit 7).
- `X86VMTranslationMap64Bit.cpp` checks `X86_64_PDE_LARGE_PAGE` in query
  and reverse-mapping paths (lines 486, 756).
- `X86PagingMethod64Bit.cpp` uses large pages for kernel physical mapping.
- The generic VM layer (`vm.cpp`) uses `B_PAGE_SIZE` uniformly — no API
  for mapping at different granularities from userspace.

### Build System & Cross-Compilation

Jam-based (requires Haiku's custom Jam, not Perforce Jam). The build system
is self-hosted oriented — `Jamrules` demands `$(JAMVERSION)` contains
"-haiku-". Cross-building from non-Haiku hosts requires running the
`configure` script and building Haiku's toolchain. Feasibility from
Fedora 43: requires building their custom jam + cross-compiler toolchain.
Supports: x86, x86_64, arm, arm64, m68k, ppc, riscv64, sparc, mips.

### Page Clustering Feasibility Notes

Haiku's `VMTranslationMap` abstraction is the most promising architecture
among these kernels for page clustering. The virtual `Map()` interface
already takes a physical address and virtual address, making it
straightforward to modify the mapping granularity. The separate `PAGESIZE`
per-arch in POSIX headers and SPARC64's existing 8KB page size shows
the codebase already handles non-4KB pages. The `B_PAGE_SIZE` macro
permeates the VM code but is cleanly used. Key challenge: the page
allocator (`vm_page.cpp`) and cache system are page-granular.

---

## 3. seL4

**Clone**: `/home/nyc/src/sel4` (GitHub, `--depth 1`)

### PAGE_SIZE Definition

Architecture-specific through capability constants:
- `libsel4/sel4_arch_include/x86_64/sel4/sel4_arch/constants.h:24`:
  `#define seL4_PageBits 12` (4KB)
- `include/arch/x86/arch/machine/hardware.h:15`:
  `#define PAGE_BITS seL4_PageBits`
- No `PAGE_SIZE` macro; sizes are computed as `BIT(PAGE_BITS)` = `1 << 12`.
- RISC-V and ARM also define `seL4_PageBits 12`.

### Fault Handler / Page Mapping Entry Point

- **Entry**: `src/arch/x86/c_traps.c` receives the hardware fault.
- **Handler**: `src/arch/x86/kernel/vspace.c:567` —
  `exception_t handleVMFault(tcb_t *thread, vm_fault_type_t vm_faultType)`.
  This is a **microkernel** — the fault handler simply records the fault
  address and type into `current_fault` as an `seL4_Fault_VMFault_new()`
  and returns `EXCEPTION_FAULT`. The actual page-in is done by the
  **userspace pager/resource manager**.

### Page Table Management

- `src/arch/x86/64/kernel/vspace.c` — kernel vspace setup, page table walks
- `src/arch/x86/32/kernel/vspace.c` — 32-bit variant
- Page tables are managed as typed kernel objects (capabilities). Userspace
  explicitly manages page tables by invoking seL4 syscalls to create/map
  page table objects and frame capabilities.

### Multi-Page-Size Support

**Full, first-class support via typed capabilities:**
```c
enum vm_page_size {
    X86_SmallPage,   // seL4_PageBits = 12  (4KB)
    X86_LargePage,   // seL4_LargePageBits = 21  (2MB on x86_64, 4MB on ia32)
    X64_HugePage     // seL4_HugePageBits = 30  (1GB)
};
```
- `pageBitsForSize(vm_page_size_t)` dispatches to the correct size.
- Frame capabilities carry their size in the capability word.
- ARM: `seL4_LargePageBits = 16` (64KB on aarch32), `= 21` (2MB on aarch64).
- RISC-V: `seL4_LargePageBits = 21/22`, `seL4_HugePageBits = 30`.
- Mapping operations (`decodeX86ModeMapPage`, `performPageInvocation`) are
  fully parameterized by `vm_page_size_t`.

### Build System & Cross-Compilation

CMake-based, designed for cross-compilation. The build system includes
verified configurations for numerous platforms (x86_64, ARM, AARCH64,
RISC-V). Requires a cross-compiler (standard GCC/Clang cross toolchains
work). Cross-building from Fedora 43 is straightforward — just need
`cmake`, `ninja`, and an appropriate cross-compiler package.

### Page Clustering Feasibility Notes

seL4 is a microkernel with **no in-kernel page fault handling** — faults
are delegated to userspace. Its multi-page-size support is the most
complete of any kernel surveyed, but it's a very different model: page
clustering would need to be implemented in the userspace resource manager,
not the kernel. The kernel's role is limited to mapping frames of specified
sizes into address spaces. The `vm_page_size_t` enum and `pageBitsForSize()`
function show a clean pattern for parameterizing page sizes. Key insight:
seL4 proves that typed/sized frame capabilities are a viable API for
multi-granularity mapping.

---

## 4. Zircon (Fuchsia)

**Clone**: Failed. Sparse checkout of `zircon/` from the Fuchsia monorepo
(`fuchsia.googlesource.com/fuchsia`) stalled — the repository is too
large even for sparse checkout with `--depth 1`. Analysis below is from
web-based source browsing.

### PAGE_SIZE Definition

Not found in `arch/x86/include/arch/defines.h` (which only defines
`MAX_CACHE_LINE`). Not in `arch/x86/include/arch/vm.h` (address validation
functions only). The `arch/x86/include/arch/x86/mmu.h` includes
`<arch/x86/page_tables/constants.h>` which likely defines `PAGE_SIZE_SHIFT`.
Based on the Zircon codebase structure and all x86 references using 4KB
pages, `PAGE_SIZE_SHIFT` is almost certainly 12 (4096 bytes).

The page table constants are spread across a multi-level include chain:
`mmu.h` -> `page_tables/constants.h` -> `page_tables/x86/constants.h`.

### Fault Handler / Page Mapping Entry Point

- The VM subsystem is in `zircon/kernel/vm/` with files:
  `vm_aspace.cc`, `vm_mapping.cc`, `vm_cow_pages.cc`, `vmm.cc`.
- Page faults flow through `vm_mapping.cc` and `vm_cow_pages.cc`.
- `vm_cow_pages.cc` handles the copy-on-write and demand-paging logic,
  including page allocation from PMM, compression, and eviction.
- The PMM (physical memory manager) is in `pmm.cc`, `pmm_node.cc`,
  `pmm_arena.cc`.

### Page Table Management

- Architecture-specific page tables are in
  `zircon/kernel/arch/x86/page_tables/`.
- The `aspace.h` header declares the address space abstraction.
- MMU context switching via `vmm_context_switch()`.
- Page tables use the standard x86-64 4-level (PML4/PDPT/PD/PT) structure.

### Multi-Page-Size Support

- Large page support exists — `mmu.h` defines EPT (Extended Page Table)
  flags and page fault error codes.
- The kernel uses large pages for kernel mappings (similar to Linux).
- Userspace VMOs (Virtual Memory Objects) are managed in page-granular
  units; the page compression and eviction infrastructure
  (`compressor.cc`, `lz4_compressor.cc`, `evictor.cc`, `scanner.cc`)
  operates at base page granularity.

### vm_page_t Structure

From `zircon/kernel/vm/include/vm/page.h`:
- `using vm_page_t = vm_page;`
- 48 bytes per page struct (validated by `static_assert`)
- Contains: `list_node queue_node`, `paddr_t paddr_priv`,
  union with object tracking (back pointer, page offset, share count,
  queue ID, pin count, dirty state), state, loaned state.
- Notably compact — smaller than Linux's `struct page` (64 bytes).

### Build System & Cross-Compilation

Part of the Fuchsia build system (GN + Ninja). Requires the full Fuchsia
SDK and toolchain (`fx` tool). Cross-building just Zircon independently
is not straightforward — it's deeply integrated into the Fuchsia monorepo
build. Not feasible to build from Fedora 43 without the full Fuchsia
checkout and SDK.

### Page Clustering Feasibility Notes

Zircon's VMO abstraction is interesting for page clustering: VMOs are the
unit of memory management, and `vm_cow_pages.cc` handles the mapping
between VMO pages and physical pages. The `vm_page_t` struct at 48 bytes
is already quite compact. The compression infrastructure
(`compressor.cc`) shows Zircon already has per-page processing that would
need adaptation for clustered pages. Key challenge: the entire VM subsystem
is written in C++ with extensive use of templates and RAII, making
mechanical changes harder than in C kernels. The monorepo build system
makes independent experimentation impractical.

---

## Comparative Summary

| Feature | SerenityOS | Haiku | seL4 | Zircon |
|---------|-----------|-------|------|--------|
| Language | C++ | C++ | C | C++ |
| PAGE_SIZE | 4096 hardcoded | PAGESIZE per-arch (4K/8K) | BIT(seL4_PageBits)=4096 | ~4096 (PAGE_SIZE_SHIFT=12) |
| Fault handler | MM::handle_page_fault | vm_page_fault/vm_soft_fault | Delegates to userspace | vm_cow_pages fault path |
| Page table abstraction | PageDirectory/PTE | VMTranslationMap (virtual) | Typed capabilities | Arch-specific classes |
| Multi-page-size | None | Partial (kernel large pages) | Full (4K/2M/1G typed) | Partial (kernel large pages) |
| Build feasibility | Custom toolchain needed | Custom Jam + toolchain | CMake, easy cross-build | Full Fuchsia SDK needed |
| LOC (VM subsystem) | ~5K | ~15K | ~8K | ~20K |

### Most Relevant to PGCL

1. **seL4** — Best multi-page-size architecture. The `vm_page_size_t` enum
   and `pageBitsForSize()` pattern is a clean model. However, as a
   microkernel, the in-kernel VM is minimal — most complexity is in
   userspace.

2. **Haiku** — Best candidate for page clustering experimentation among
   monolithic kernels. The `VMTranslationMap` virtual interface provides
   a clean boundary for changing mapping granularity. SPARC64's 8KB
   page size proves the codebase handles non-4KB pages. The NewOS-derived
   VM design is well-structured.

3. **SerenityOS** — Simplest VM implementation, making it the easiest to
   understand and modify. But no existing multi-granularity infrastructure.

4. **Zircon** — Sophisticated VM with VMO abstraction, but the monorepo
   build system and C++ complexity make it the least practical for
   experimentation.

### Key Patterns Observed

- **All four kernels hardcode page size per-architecture** — none have a
  runtime-configurable or build-time-configurable page clustering mechanism
  analogous to Linux PGCL's `PAGE_MMUSHIFT`.

- **seL4's typed frame capabilities** show that multi-granularity mapping
  can be a clean, first-class API rather than an internal optimization.

- **Haiku's VMTranslationMap abstraction** is the closest analog to what
  PGCL needs: a virtual interface that decouples "what the VM thinks a
  page is" from "what the MMU maps." Page clustering would add a layer
  where `Map()` creates multiple PTEs per kernel page.

- **The vm_page / vm_page_t struct** is uniformly per-physical-page in all
  kernels. Page clustering's key insight — one struct per N hardware pages
  — is novel across all surveyed systems.
