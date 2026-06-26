#!/bin/bash
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl; BZ=$D/bzImage-vanswap
run() {  # $1=smp $2=timeout $3=tag
  local L=$D/swv-$3.log
  bash "$D/iso" timeout "$2" qemu-system-x86_64 -enable-kvm -cpu host -smp "$1" -m 2G -kernel "$BZ" \
    -initrd "$D/abl-initramfs/initramfs.cpio.gz" \
    -append "console=ttyS0 nokaslr ignore_loglevel panic=1 rr_nofork rr_nocow" \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  local done_=$(grep -ac 'RRABL DONE' "$L"); local ki=$(grep -ac 'Attempted to kill init' "$L")
  local zj=$(grep -acE 'segfault at 0 ip 0000000000000000|ip 000000000000038c' "$L")
  echo "$3 (smp$1,to$2): DONE=$done_ killinit=$ki zerojump=$zj => $([ "$ki" -gt 0 ] && echo CRASH || ([ "$done_" -gt 0 ] && echo CLEAN-DONE || echo timeout/slow)) $(date +%H:%M:%S)"
}
echo "=== swap-fix re-validate (disambiguate slow vs hang) $(date +%H:%M:%S) ==="
run 4 400 a-smp4
run 4 400 b-smp4
run 8 600 c-smp8
