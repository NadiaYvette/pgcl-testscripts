#!/bin/bash
# #143 (COW/file mapcount underflow) — FULL repro (fork+COW+hog) on the swap-fixed
# + VMA-namer kernel. Swap quirk now fixed => wp catches isolate #143 cleanly.
set -u
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl; BZ=$D/bzImage-vanswap
MEM=${MEM:-2G}; N=${N:-4}
echo "=== [#143 full repro] bzImage-vanswap m$MEM smp8 x$N $(date +%H:%M:%S) ==="
for r in $(seq 1 "$N"); do
  L=$D/c143-$r.log
  bash "$D/iso" timeout 160 qemu-system-x86_64 -enable-kvm -cpu host -smp 8 -m "$MEM" -kernel "$BZ" \
    -initrd "$D/abl-initramfs/initramfs.cpio.gz" \
    -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  wp=$(grep -ac 'PGCL143wp #' "$L"); bp=$(grep -ac 'Bad page map' "$L")
  ki=$(grep -ac 'Attempted to kill init' "$L"); zj=$(grep -acE 'segfault at 0 ip 0000000000000000' "$L")
  echo "c143-$r: wp=$wp badmap=$bp killinit=$ki zerojump=$zj $(date +%H:%M:%S)"
done
echo "=== #143 catches: remover comm + file + flags (which mapping holds the dangler) ==="
grep -haE 'PGCL143wp #|remover comm=' $D/c143-*.log 2>/dev/null | sed -E 's/^.*kernel: //' | grep -E 'remover comm=' \
  | sed -E 's/pid=[0-9]+/pid=N/; s/vma=0x[0-9a-f]+/vma=X/; s/mapping=[0-9a-f]+/mapping=X/' | sort | uniq -c | sort -rn | head -20
echo "=== over-remove stack sites ==="
grep -haE 'folio_remove_rmap|zap_present_ptes.*\+0x|tlb_flush_rmap|wp_page_copy.*\+0x|try_to_unmap' $D/c143-*.log 2>/dev/null | sed -E 's/^.*kernel: //; s/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -oE '[a-z_]+(\.[a-z]+)?(\.constprop\.0)?\+0x[0-9a-f]+' | sort | uniq -c | sort -rn | head
