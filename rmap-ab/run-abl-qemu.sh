#!/bin/bash
# #143 minimal ablatable QEMU repro (no Fedora, no sudo): static init+repro in an
# initramfs, btrfs(/dev/vda)+swap(/dev/vdb), bzImage-vanfix.
# Oracle = kill-init panic (PID1 corrupted) OR PGCL143wp OR bad-page.
# panic=1 => crashed VM reboots => -no-reboot exits fast (QEMU only, NOT laptop).
# usage: [MEM=2G] run-abl-qemu.sh <full|nofork|nocow|nohog|nofadv> [N]
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl; A=$D/abl-initramfs
BZ=${BZ:-$D/bzImage-vanfix}
ABL=${1:-full}; N=${2:-6}; MEM=${MEM:-2G}
case "$ABL" in
  full)   TOK="" ;;
  nofork) TOK="rr_nofork" ;;
  nocow)  TOK="rr_nocow" ;;
  nohog)  TOK="rr_nohog" ;;
  nofadv) TOK="rr_nofadv" ;;
  minimal) TOK="rr_nofork rr_nocow" ;;
  minnofadv) TOK="rr_nofork rr_nocow rr_nofadv" ;;
  *) echo "unknown ablation $ABL"; exit 1 ;;
esac
cc -O2 -static -o "$A/init"  "$A/init.c"                               || { echo "init build FAIL"; exit 2; }
cc -O2 -static -o "$A/repro" "$P/userspace/file_reclaim_race_repro_abl.c" || { echo "repro build FAIL"; exit 2; }
ST=$A/stage; rm -rf "$ST"; mkdir -p "$ST"/dev "$ST"/proc "$ST"/sys "$ST"/mnt
cp "$A/init" "$ST/init"; cp "$A/repro" "$ST/repro"
( cd "$ST" && find . | cpio -o -H newc 2>/dev/null | gzip > "$A/initramfs.cpio.gz" )
tag=abl-$ABL-$MEM
echo "=== [$tag] x$N smp8 m$MEM token='$TOK' initramfs=$(du -h "$A/initramfs.cpio.gz"|cut -f1) $(date +%H:%M:%S) ==="
corrupt=0
for r in $(seq 1 "$N"); do
  L=$D/$tag-$r.log
  bash "$D/iso" timeout 220 qemu-system-x86_64 -enable-kvm -cpu host -smp 8 -m "$MEM" -kernel "$BZ" \
    -initrd "$A/initramfs.cpio.gz" \
    -append "console=ttyS0 nokaslr ignore_loglevel panic=1 $TOK" \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  wp=$(grep -ac 'PGCL143wp #' "$L")
  ki=$(grep -ac 'Attempted to kill init' "$L")
  bp=$(grep -acE 'BUG: Bad page|Bad rss-counter|kernel BUG at|VM_BUG_ON|refcount_t:' "$L")
  dangle=$(grep -ac 'PGCL143dangle: FREED' "$L")
  ran=$(grep -ac 'RRABL start' "$L"); done_=$(grep -ac 'RRABL DONE' "$L")
  bad=$([ "$wp" -gt 0 -o "$ki" -gt 0 -o "$bp" -gt 0 ] && echo 1 || echo 0)
  [ "$bad" = 1 ] && corrupt=$((corrupt+1))
  echo "$tag-$r: wp=$wp killinit=$ki badpage=$bp dangle=$dangle ran=$ran done=$done_ => $([ "$bad" = 1 ] && echo CORRUPT || echo clean) $(date +%H:%M:%S)"
done
echo "=== [$tag]: $corrupt/$N corrupt $(date +%H:%M:%S) ==="
