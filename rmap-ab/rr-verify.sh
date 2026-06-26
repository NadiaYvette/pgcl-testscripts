#!/bin/bash
# rr-verify.sh <rrfile> [record-log] — prove a recording replays bit-exactly.
# Replays <rrfile> on a fresh clean overlay and (if given the matching record
# log) diffs the kernel console line-for-line.  Identical output (including the
# [   t.tttttt] printk timestamps, which are deterministic under icount) means
# the record/replay is faithful and a reverse-debug session can be trusted.
set -u
P=/home/nyc/src/pgcl; D=$P/rmap-ab; A=$D/abl-initramfs; QB=/home/nyc/src/qemu/build
BIN="${1:?usage: rr-verify.sh <rrfile> [record-log]}"; RECLOG="${2:-}"
rm -f "$D"/rrv-btrfs.qcow2 "$D"/rrv-swap.qcow2
qemu-img create -f qcow2 -b "$D/btrfs.img"            -F raw "$D"/rrv-btrfs.qcow2 >/dev/null
qemu-img create -f qcow2 -b "$P/pgcl4-testbed/swap.raw" -F raw "$D"/rrv-swap.qcow2 >/dev/null
L=$D/rrverify.log
timeout 600 "$QB/qemu-system-x86_64" -icount shift=auto,rr=replay,rrfile="$BIN" \
  -accel tcg -cpu max,la57=off -smp 1 -m 2G -kernel "$D/bzImage-vandangle" \
  -initrd "$A/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
  -drive file="$D"/rrv-btrfs.qcow2,if=none,id=disk0 \
  -drive driver=blkreplay,if=none,image=disk0,id=disk0-rr -device virtio-blk-pci,drive=disk0-rr \
  -drive file="$D"/rrv-swap.qcow2,if=none,id=disk1 \
  -drive driver=blkreplay,if=none,image=disk1,id=disk1-rr -device virtio-blk-pci,drive=disk1-rr \
  -nographic -no-reboot > "$L" 2>&1
echo "replay: killinit=$(grep -ac 'kill init\|segfault at 0' "$L")  kernel-lines=$(grep -ac '^\[' "$L")  log=$L"
if [ -n "$RECLOG" ] && [ -f "$RECLOG" ]; then
  if diff -q <(grep -a '^\[' "$RECLOG") <(grep -a '^\[' "$L") >/dev/null; then
    echo "DETERMINISTIC: replay kernel console is byte-identical to $RECLOG"
  else
    echo "DIVERGED from $RECLOG:"; diff <(grep -a '^\[' "$RECLOG") <(grep -a '^\[' "$L") | head -8
  fi
fi
