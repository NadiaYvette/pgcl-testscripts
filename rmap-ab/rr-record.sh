#!/bin/bash
# rr-record.sh [N] [timeout] — record up to N deterministic QEMU icount runs of
# the #143 pgcl4 repro, KEEPING the rrfile from any run where the bug fires
# (kill init) so it can be replayed and reverse-debugged (replay-rr.sh +
# rev-debug.gdb).
#
# KEY FINDING that makes this work: #143 reproduces at -smp 1 (~2/3 of runs),
# so it is a single-CPU scheduling-sensitive interleaving (faulting task vs
# kswapd/reclaim across context switches), NOT a parallel cross-CPU race.  That
# matters because QEMU record/replay supports -smp 1 ONLY ("Record/replay is
# not supported with multiple CPUs") — a genuinely parallel race could not be
# captured this way.
#
# Setup notes (learned the hard way):
#  * Fresh qcow2 overlay per run over the read-only base images => every run's
#    start state is byte-identical, so NO rrsnapshot is needed (rrsnapshot wrote
#    duplicate snapshots that diverged on replay).  replay-rr.sh recreates the
#    same clean overlay, so the replay matches the record bit-for-bit.
#  * blkreplay wraps each virtio-blk drive so block I/O completion order is
#    recorded/replayed deterministically.
#  * -accel tcg (round-robin), -smp 1, -cpu max,la57=off — same CPU model as the
#    thread=multi repro so the bug is unchanged.
#  * Never run two QEMU against the same RAW image at once (write-lock error);
#    the overlays make concurrent runs safe (base opened read-only).
set -u
P=/home/nyc/src/pgcl; D=$P/rmap-ab; A=$D/abl-initramfs; QB=/home/nyc/src/qemu/build
N="${1:-6}"; TMO="${2:-400}"
crashbin=""
for i in $(seq 1 "$N"); do
  rm -f "$D"/rrx-btrfs.qcow2 "$D"/rrx-swap.qcow2
  qemu-img create -f qcow2 -b "$D/btrfs.img"            -F raw "$D"/rrx-btrfs.qcow2 >/dev/null
  qemu-img create -f qcow2 -b "$P/pgcl4-testbed/swap.raw" -F raw "$D"/rrx-swap.qcow2 >/dev/null
  L=$D/rrcrash-$i.log; BIN=$D/rrcrash-$i.bin; rm -f "$BIN"
  timeout "$TMO" "$QB/qemu-system-x86_64" -icount shift=auto,rr=record,rrfile="$BIN" \
    -accel tcg -cpu max,la57=off -smp 1 -m 2G -kernel "$D/bzImage-vandangle" \
    -initrd "$A/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
    -drive file="$D"/rrx-btrfs.qcow2,if=none,id=disk0 \
    -drive driver=blkreplay,if=none,image=disk0,id=disk0-rr -device virtio-blk-pci,drive=disk0-rr \
    -drive file="$D"/rrx-swap.qcow2,if=none,id=disk1 \
    -drive driver=blkreplay,if=none,image=disk1,id=disk1-rr -device virtio-blk-pci,drive=disk1-rr \
    -nographic -no-reboot > "$L" 2>&1
  ki=$(grep -ac 'kill init\|segfault at 0 ip 0000000000000000' "$L")
  echo "rec-$i: killinit=$ki  rrfile=$(ls -la "$BIN" 2>/dev/null | awk '{print $5}')  log=$L"
  if [ "$ki" -gt 0 ]; then
    crashbin="$BIN"
    echo ">>> CRASH CAUGHT: $BIN"
    echo ">>> reverse-debug it with:  ./replay-rr.sh $BIN 1234   (then: gdb \$O/vmlinux -x rev-debug.gdb)"
    break
  fi
  rm -f "$BIN"        # keep only crashing recordings
done
[ -n "$crashbin" ] || echo "no crash in $N runs (rate ~2/3; just retry)"
