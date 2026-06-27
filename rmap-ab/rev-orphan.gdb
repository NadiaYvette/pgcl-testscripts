# rev-orphan.gdb — reverse-debug #143 targeting the DERIVED signature
# (2026-06-27 refcount re-audit):
#
#   Every deterministic map/unmap/COW path balances refcount+mapcount in matching
#   MMUPAGE units, AND reclaim's freeze (__remove_mapping: expected = 1 +
#   folio_nr_pages) FAILS SAFE — a leftover mapped ref makes actual > expected so
#   the folio is KEPT.  Therefore "file/anon cluster freed with a live sub-PTE"
#   REQUIRES a mapping ref/rmap to have been dropped WITHOUT clearing its sub-PTE.
#   That makes the freeze's expected count match while a PTE still points in →
#   premature free → dangling sub-PTE → pfn reused/zeroed → RIP=0 → kill init.
#
# So besides watching _refcount (revfree.gdb), this WATCHES THE ORPHAN PTE itself
# and offers chkmap: the smoking gun is a sub-PTE that is physically PRESENT while
# the cluster _mapcount already reads "unmapped" (< 0) — i.e. rmap-removed but the
# PTE was never cleared.  The reverse-continue that lands on THAT transition (bt)
# is the buggy unmap/reclaim path.
#
#   terminal 1:  cd ~/src/pgcl/rmap-ab && ./replay-rr.sh rrcrash-N.bin 1234
#   terminal 2:  gdb ~/src/pgcl/kernel-rpm-build/pgcl4-debug/vmlinux -x rev-orphan.gdb
#   (batch:      ./rr-revdebug.sh rrcrash-N.bin rev-orphan.gdb   — runs `hunt` for you)
#
# pgcl4: PAGE_SHIFT=16 (64K), MMUPAGE_SHIFT=12 (4K), PAGE_MMUCOUNT=16; one struct
# page per CLUSTER; struct page=64B, _mapcount@+48, _refcount@+52; pt_regs ip@+128
# sp@+152 (empirical for this build, matches revfree.gdb).

set pagination off
set confirm off
set debuginfod enabled off
set architecture i386:x86-64
# force synchronous (all-stop) mode so `continue`/`reverse-continue` BLOCK in batch
# gdb — otherwise the QEMU gdbstub runs them async ("Cannot execute ... target is
# running") and a non-interactive script races ahead. (revfree.gdb needed a TTY for
# exactly this reason; target-async off removes that requirement.)
set target-async off
set non-stop off
target remote :1234

define loadbases
  set $po = *(unsigned long *)&page_offset_base
  set $vm = *(unsigned long *)&vmemmap_base
  printf "page_offset_base=0x%lx vmemmap_base=0x%lx\n", $po, $vm
end

# walk current cr3 for a user VA. sets $pteaddr (direct-map addr of the pte_t, so
# it stays mapped across context switches and is reverse-watchable), $pteval,
# $cpfn (cluster pfn = phys>>16), $pg (struct page).
define walkva
  set $va = (unsigned long)$arg0
  set $cr3v = $cr3 & 0x000ffffffffff000
  set $pgd = $po + $cr3v
  set $e1 = *(unsigned long *)($pgd + (($va >> 39) & 0x1ff) * 8)
  set $pud = $po + ($e1 & 0x000ffffffffff000)
  set $e2 = *(unsigned long *)($pud + (($va >> 30) & 0x1ff) * 8)
  set $pmd = $po + ($e2 & 0x000ffffffffff000)
  set $e3 = *(unsigned long *)($pmd + (($va >> 21) & 0x1ff) * 8)
  set $ptetab = $po + ($e3 & 0x000ffffffffff000)
  set $pteaddr = $ptetab + (($va >> 12) & 0x1ff) * 8
  set $pteval = *(unsigned long *)$pteaddr
  set $cpfn = ($pteval & 0x000ffffffffff000) >> 16
  set $pg = $vm + $cpfn * 64
  printf "va=0x%lx  pte@0x%lx = 0x%lx  present=%d  cpfn=0x%lx  page=0x%lx\n", \
    $va, $pteaddr, $pteval, ($pteval & 1), $cpfn, $pg
end

# smoking-gun test: orphan sub-PTE present while cluster mapcount says unmapped
define chkmap
  set $pv = *(unsigned long *)$pteaddr
  set $mc = *(int *)($pg+48)
  set $rc = *(int *)($pg+52)
  printf "  pte@0x%lx=0x%lx present=%d | cluster mapcount=%d refcount=%d\n", \
    $pteaddr, $pv, ($pv & 1), $mc, $rc
  if (($pv & 1) && ($mc < 0))
    printf "  *** SMOKING GUN: sub-PTE PRESENT but mapcount<0 -> rmap dropped without PTE clear ***\n"
  end
  if (($rc == 0) && ($pv & 1))
    printf "  *** PREMATURE FREE: refcount==0 (freed) while sub-PTE still present ***\n"
  end
end

define watchmc
  watch *(int *)($pg+48)
  printf "watching mapcount @0x%lx (now=%d)\n", (unsigned long)($pg+48), *(int*)($pg+48)
end

# bounded reverse walk for batch capture: dump bt+chkmap at each prior write to
# the watched locations.  Interactive users can ignore this and drive by hand.
define hunt
  set $n = 0
  while $n < 8
    printf "\n========== reverse round %d ==========\n", $n
    reverse-continue
    chkmap
    bt 8
    set $n = $n + 1
  end
end

printf "\n[rev-orphan] continue to the fatal jump-to-NULL fault (addr 0)...\n"
# conditional: only stop at the fatal address-0 fault (skip benign bad-area faults
# automatically — batch gdb can't interactively retry).  Symbols come from vmlinux
# so the breakpoint resolves before boot; loadbases reads guest memory and must run
# AFTER the kernel is up (i.e. after we hit the fault), not at the reset vector.
break __bad_area_nosemaphore if $rdx == 0
continue

loadbases
printf "[rev-orphan] fault address=0x%lx (0 = the fatal jump-to-NULL)\n", $rdx
set $regs = $rdi
set $uip = *(unsigned long *)($regs + 128)
set $usp = *(unsigned long *)($regs + 152)
printf "[rev-orphan] user RIP=0x%lx RSP=0x%lx\n", $uip, $usp
walkva ($usp - 8)
printf "[rev-orphan] victim cluster: flags=0x%lx mapcount=%d refcount=%d\n", \
  *(unsigned long*)$pg, *(int*)($pg+48), *(int*)($pg+52)
chkmap

# arm HW watchpoints: orphan PTE memory (DR0) + cluster refcount (DR1)
watch *(unsigned long *)$pteaddr
watch *(int *)($pg + 52)
printf "\n[rev-orphan] armed WP1=orphan-PTE @0x%lx  WP2=refcount @0x%lx\n", $pteaddr, (unsigned long)($pg+52)
printf "[rev-orphan] RECIPE (interactive): reverse-continue ; chkmap ; bt   (repeat)\n"
printf "[rev-orphan]   - refcount->0 write while chkmap shows PTE present == the premature FREE\n"
printf "[rev-orphan]   - keep reversing to the mapcount-drop for this sub-PTE that left the PTE set == THE BUG\n"
printf "[rev-orphan]   - helpers: walkva <va> ; chkmap ; watchmc ; hunt (auto N rounds, for batch)\n"
printf "[rev-orphan] running hunt now:\n"
hunt
printf "[rev-orphan] hunt done.\n"
quit
