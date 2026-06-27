#!/bin/bash
# run-smp8-trip.sh [N] [TMO] — run the #143 light-tripwire kernel (bzImage-tripwire)
# against the live -smp8 KVM oracle.  The tripwire (pgcl143_trip in __remove_mapping)
# fires once at the premature free and dumps every CPU (trigger_all_cpu_backtrace),
# so a fired run's log holds the in-flagrante racing path.  Logs are KEPT.
set -u
P=/home/nyc/src/pgcl; D=$P/rmap-ab; A=$D/abl-initramfs; QB=/home/nyc/src/qemu/build
N="${1:-4}"; TMO="${2:-300}"; CORES="${CORES:-12-19}"
BZ="${BZ:-$D/bzImage-tripwire}"
[ -f "$BZ" ] || { echo "no $BZ (build it first: ./build-tripwire.sh)"; exit 1; }
trips=0; hits=0
for i in $(seq 1 "$N"); do
  rm -f "$D"/trip-btrfs-$i.qcow2 "$D"/trip-swap-$i.qcow2
  qemu-img create -f qcow2 -b "$D/btrfs.img"              -F raw "$D"/trip-btrfs-$i.qcow2 >/dev/null
  qemu-img create -f qcow2 -b "$P/pgcl4-testbed/swap.raw" -F raw "$D"/trip-swap-$i.qcow2 >/dev/null
  L=$D/trip-$i.log
  taskset -c "$CORES" timeout "$TMO" "$QB/qemu-system-x86_64" \
    -enable-kvm -cpu host -smp 8 -m 2G -kernel "$BZ" \
    -initrd "$A/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
    -drive file="$D"/trip-btrfs-$i.qcow2,if=none,id=d0 -device virtio-blk-pci,drive=d0 \
    -drive file="$D"/trip-swap-$i.qcow2,if=none,id=d1 -device virtio-blk-pci,drive=d1 \
    -nographic -no-reboot > "$L" 2>&1
  tr=$(grep -ac 'PGCL143-TRIP' "$L")
  ki=$(grep -acE 'kill init|Attempted to kill init' "$L")
  bp=$(grep -ac 'Bad page map' "$L")
  gt=$(grep -aoE '^\[[ 0-9.]+\]' "$L" | tail -1)
  echo "trip-$i: TRIPWIRE=$tr killinit=$ki badpte=$bp guest=$gt log=$L"
  [ "$tr" -gt 0 ] && trips=$((trips+1))
  [ "$((ki+bp))" -gt 0 ] && hits=$((hits+1))
  rm -f "$D"/trip-btrfs-$i.qcow2 "$D"/trip-swap-$i.qcow2
done
echo "RESULT: tripwire fired in $trips/$N runs; corruption in $hits/$N (live -smp8 KVM)"
