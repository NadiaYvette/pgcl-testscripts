#!/bin/bash
# run-smp8-live.sh [N] [TMO] — live near-native -smp 8 KVM reproduction of #143.
#
# WHY: icount rr=record (rr-record.sh) serializes to one deterministic vCPU and
# SUPPRESSES the race (0/6 kill-init, 2026-06-27).  The bug needs true cross-CPU
# concurrency, so we reproduce under -enable-kvm -smp 8 at native timing.  This
# forfeits reverse-execution but gives (a) a reliable repro rate to use as the
# A/B fix oracle, and (b) a frozen all-CPU snapshot at the catch when paired with
# gdb (-s) + live-snapshot.gdb.
#
# Fresh qcow2 overlays per run over the read-only base images => identical start
# state, safe to loop.  Pinned to the pgcl cores (12-19) so Telix is untouched.
set -u
P=/home/nyc/src/pgcl; D=$P/rmap-ab; A=$D/abl-initramfs; QB=/home/nyc/src/qemu/build
N="${1:-4}"; TMO="${2:-300}"; CORES="${CORES:-12-19}"
hits=0
for i in $(seq 1 "$N"); do
  rm -f "$D"/live-btrfs-$i.qcow2 "$D"/live-swap-$i.qcow2
  qemu-img create -f qcow2 -b "$D/btrfs.img"              -F raw "$D"/live-btrfs-$i.qcow2 >/dev/null
  qemu-img create -f qcow2 -b "$P/pgcl4-testbed/swap.raw" -F raw "$D"/live-swap-$i.qcow2 >/dev/null
  L=$D/live-$i.log
  taskset -c "$CORES" timeout "$TMO" "$QB/qemu-system-x86_64" \
    -enable-kvm -cpu host -smp 8 -m 2G -kernel "$D/bzImage-vandangle" \
    -initrd "$A/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
    -drive file="$D"/live-btrfs-$i.qcow2,if=none,id=d0 -device virtio-blk-pci,drive=d0 \
    -drive file="$D"/live-swap-$i.qcow2,if=none,id=d1 -device virtio-blk-pci,drive=d1 \
    -nographic -no-reboot > "$L" 2>&1
  ki=$(grep -acE 'kill init|Attempted to kill init|Run /init.*as init.*exited|segfault at 0 ip 0+ ' "$L")
  bp=$(grep -ac 'Bad page map' "$L")
  rss=$(grep -ac 'Bad rss-counter' "$L")
  gt=$(grep -aoE '^\[[ 0-9.]+\]' "$L" | tail -1)
  done=$(grep -ac 'repro done\|powering off' "$L")
  echo "live-$i: killinit=$ki badpte=$bp badrss=$rss clean_poweroff=$done guest=$gt log=$L"
  [ "$((ki+bp+rss))" -gt 0 ] && hits=$((hits+1))
  rm -f "$D"/live-btrfs-$i.qcow2 "$D"/live-swap-$i.qcow2
done
echo "RESULT: $hits/$N runs showed #143 corruption (live -smp8 KVM)"
