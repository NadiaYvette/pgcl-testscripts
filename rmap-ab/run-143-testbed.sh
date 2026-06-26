#!/bin/bash
# #143 named catches: Fedora testbed (systemd + repro) on swap-fixed+VMA-namer
# kernel. Swap quirk fixed => wp catches isolate the COW/file mapcount underflow.
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl; BZ=$D/bzImage-vanswap
MEM=${MEM:-3G}; N=${N:-4}
echo "=== [#143 testbed] bzImage-vanswap m$MEM smp8 x$N $(date +%H:%M:%S) ==="
for r in $(seq 1 "$N"); do
  L=$D/t143-$r.log
  bash "$D/iso" timeout 260 qemu-system-x86_64 -enable-kvm -cpu host -smp 8 -m "$MEM" -kernel "$BZ" \
    -append "root=/dev/vda rw rootfstype=ext4 console=ttyS0 nokaslr ignore_loglevel selinux=1 enforcing=0 page_owner=on" \
    -drive file="$P/pgcl4-testbed/rootfs.ext4",format=raw,if=virtio \
    -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  wp=$(grep -ac 'PGCL143wp #' "$L"); bp=$(grep -ac 'Bad page map' "$L")
  ki=$(grep -ac 'Attempted to kill init' "$L"); login=$(grep -acE 'login:|RR DONE|Reached target' "$L")
  echo "t143-$r: wp=$wp badmap=$bp killinit=$ki bootok=$login $(date +%H:%M:%S)"
done
echo "=== #143 wp catches: remover comm + file (which mapping holds the dangler) ==="
grep -haE 'remover comm=' $D/t143-*.log 2>/dev/null | sed -E 's/^.*kernel: //; s/pid=[0-9]+/pid=N/; s/vma=0x[0-9a-f]+/vma=X/; s/mapping=[0-9a-f]+/mapping=X/; s/pfn=[0-9a-f]+/pfn=X/; s/index=[0-9a-f]+/index=X/' | sort | uniq -c | sort -rn | head
