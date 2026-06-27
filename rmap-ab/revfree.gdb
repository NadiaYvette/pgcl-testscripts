# revfree.gdb — INTERACTIVE reverse-debug of the #143 premature-free.
#
#   terminal 1:  cd ~/src/pgcl/rmap-ab && ./replay-rr.sh rrcr-1.bin 1234
#   terminal 2:  gdb ~/src/pgcl/kernel-rpm-build/pgcl4-debug/vmlinux -x revfree.gdb
#
# Must be run from an INTERACTIVE terminal: in batch/non-interactive gdb the
# QEMU-replay gdbstub makes `continue` non-blocking ("Cannot execute ... target
# is running").  A real TTY runs `continue` in the foreground and blocks.
#
# This script sources up to the fatal addr-0 segfault, walks repro's page table
# to the STALE pfn the dangling PTE still points at (= the victim cluster),
# prints its struct page state, and sets a watchpoint on its _refcount.  Then it
# drops you at the prompt to:
#       reverse-continue      # walk backward to the previous _refcount write
#       bt                    # the path that wrote it
# repeat until you reach the premature drop-to-0 while the cluster was still
# mapped -- that backtrace is the bug.
#
# PGCL pgcl4: PAGE_SHIFT=16, MMUPAGE_SHIFT=12; one struct page per cluster;
# struct page=64B, _mapcount@+48, _refcount@+52. pt_regs: ip@+128, sp@+152.

set pagination off
set confirm off
set debuginfod enabled off
set architecture i386:x86-64
target remote :1234

printf "[revfree] continue to the first bad-address fault (the kill-init segfault)...\n"
break __bad_area_nosemaphore
continue

printf "\n[revfree] __bad_area_nosemaphore: fault address=0x%lx  (want 0)\n", $rdx
printf "[revfree]   if address != 0 this is an earlier benign fault: just type 'continue' again\n"
set $po = *(unsigned long *)&page_offset_base
set $vm = *(unsigned long *)&vmemmap_base
set $regs = $rdi
set $uip = *(unsigned long *)($regs + 128)
set $usp = *(unsigned long *)($regs + 152)
printf "[revfree] user RIP=0x%lx  user RSP=0x%lx\n", $uip, $usp
# the bad return address was popped from [RSP-8]
set $va = $usp - 8
printf "[revfree] victim stack slot VA=0x%lx  content=0x%lx  (want 0)\n", $va, *(unsigned long *)$va
# walk current cr3 (kernel pgd maps user space too) for $va -> 4K PTE -> phys
set $cr3 = $cr3 & 0x000ffffffffff000
set $pgd = $po + $cr3
set $e1 = *(unsigned long *)($pgd + (($va >> 39) & 0x1ff) * 8)
set $pud = $po + ($e1 & 0x000ffffffffff000)
set $e2 = *(unsigned long *)($pud + (($va >> 30) & 0x1ff) * 8)
set $pmd = $po + ($e2 & 0x000ffffffffff000)
set $e3 = *(unsigned long *)($pmd + (($va >> 21) & 0x1ff) * 8)
set $ptetab = $po + ($e3 & 0x000ffffffffff000)
set $pte = *(unsigned long *)($ptetab + (($va >> 12) & 0x1ff) * 8)
printf "[revfree] walk: pgd_e=0x%lx pud_e=0x%lx pmd_e=0x%lx PTE=0x%lx\n", $e1, $e2, $e3, $pte
set $phys = $pte & 0x000ffffffffff000
set $cpfn = $phys >> 16
set $pg = $vm + $cpfn * 64
printf "[revfree] victim phys=0x%lx  cluster_pfn=0x%lx  struct page=0x%lx\n", $phys, $cpfn, $pg
printf "[revfree] victim: flags=0x%lx  _mapcount=%d  _refcount=%d\n", *(unsigned long *)$pg, *(int *)($pg+48), *(int *)($pg+52)
printf "[revfree] (sanity-cross-check with: monitor gva2gpa 0x%lx )\n", $va

watch *(int *)($pg + 52)
printf "\n[revfree] watchpoint armed on victim _refcount @ 0x%lx (now=%d).\n", (unsigned long)($pg+52), *(int *)($pg+52)
printf "[revfree] NOW DRIVE:  reverse-continue ; bt    (repeat)\n"
printf "[revfree] look for _refcount dropping to 0 (free) while a sub-PTE still maps it.\n"
printf "[revfree] also useful:  watch -l *(int*)($pg+48)   (mapcount)   and   reverse-stepi\n"
