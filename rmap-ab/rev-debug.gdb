# rev-debug.gdb — reverse-debug recipe for #143 (premature cluster free ->
# dangling sub-PTE -> page reused/zeroed -> userspace RIP=0 -> kill init).
#
# Usage:
#   terminal 1:  ./replay-rr.sh rrcrash-N.bin 1234         # frozen gdbstub
#   terminal 2:  gdb $O/vmlinux -x rev-debug.gdb           # $O = pgcl4-debug build
# where the vmlinux MUST be the not-stripped image whose bzImage is byte-
# identical to rmap-ab/bzImage-vandangle (kernel-rpm-build/pgcl4-debug/vmlinux).
#
# This QEMU build advertises ReverseStep+/ReverseContinue+, so reverse-continue
# and reverse-stepi walk backward through the deterministic replay to the write
# that caused the symptom — the one thing 100+ runs of forward logging could not
# pin down, because the bug is a single-CPU scheduling-sensitive interleaving
# (it reproduces at -smp 1) rather than a parallel race.
#
# PGCL coordinate model (pgcl4): PAGE_SHIFT=16 (64 KiB), MMUPAGE_SHIFT=12 (4 KiB),
# PAGE_MMUCOUNT=16.  One struct page per CLUSTER; refcount/mapcount are summed
# over the 16 sub-MMUPAGEs.  page_to_pfn() yields the CLUSTER pfn = phys>>16.

set pagination off
set confirm off
set architecture i386:x86-64
target remote :1234

# vmemmap base (nokaslr default is 0xffffea0000000000; read the live value)
define vmemmap
  set $vmemmap = *(unsigned long *)&vmemmap_base
  printf "vmemmap_base = 0x%lx\n", $vmemmap
end

# show a CLUSTER's struct page (refcount @ +52, mapcount @ +48 — empirical for
# this config; sanity-check the values look like small counts)
define pg
  set $pg = $vmemmap + ((unsigned long)$arg0)*64
  printf "cpfn 0x%lx -> page 0x%lx  flags=0x%lx mapcount=%d refcount=%d\n", \
    (unsigned long)$arg0, $pg, *(unsigned long*)$pg, *(int*)($pg+48), *(int*)($pg+52)
end

# hardware watchpoint on a cluster's _refcount via its kernel-linear (vmemmap)
# address, which stays mapped across guest context switches (unlike a userspace
# VA), so reverse-continue can chase it through the whole timeline
define watchrc
  set $a = $vmemmap + ((unsigned long)$arg0)*64 + 52
  printf "watching refcount of cpfn 0x%lx at 0x%lx (now=%d)\n", (unsigned long)$arg0, $a, *(int*)$a
  watch *(int*)$a
end

# convert a guest-physical address to its cluster pfn (pgcl4: >>16)
define gpa2cpfn
  printf "gpa 0x%lx -> cpfn 0x%lx\n", (unsigned long)$arg0, ((unsigned long)$arg0)>>16
end

printf "\n=== rev-debug.gdb loaded ===\n"
printf "Recipe:\n"
printf " 1. vmemmap\n"
printf " 2. continue                 # run replay forward to the fatal fault (RIP=0)\n"
printf " 3. reverse-stepi            # step back to the bad 'ret'/indirect branch\n"
printf "    info registers rsp rip   # the 0 came from [rsp] (the return slot)\n"
printf " 4. (qemu) monitor gva2gpa <stackVA>   # translate that stack VA -> gpa\n"
printf "    gpa2cpfn <gpa>           # -> victim CLUSTER pfn\n"
printf " 5. vmemmap ; pg <cpfn>      # confirm refcount==0 (freed) while still mapped\n"
printf " 6. watchrc <cpfn>\n"
printf " 7. reverse-continue         # stops AT the write that drove refcount to 0\n"
printf " 8. bt                       # the buggy unref path == root cause\n\n"
