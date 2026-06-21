#!/bin/bash
# verify-anon-mmupage.sh — build x86_64 pgcl6 (DEBUG_VM) with the anon MMUPAGE
# rmap-walk conversion and run the anon-stress (THP split → unmap_folio walk)
# + leak-probe (file-side regression) repros under KVM.
#
# PASS criteria: no "Bad page"/"still mapped"/"nonzero (large_)mapcount"/
# "page does not match folio" in dmesg, and the userspace markers report PASS.
set -u
LINUX=/home/nyc/src/linux
D=/home/nyc/src/pgcl
B=$D/x86-pgcl6-mmupage
US=$D/userspace
OUT=$D/anon-mmupage-out
mkdir -p "$OUT"

echo "=== [1/5] configure x86_64 pgcl6 (DEBUG_VM) @ $(date +%T) ==="
cd "$LINUX" || exit 3
if [ ! -f "$B/.config" ]; then
  make ARCH=x86 O="$B" x86_64_defconfig >/dev/null 2>&1 || { echo CONFIG_FAIL; exit 4; }
  scripts/config --file "$B/.config" \
    --set-val PAGE_MMUSHIFT 6 \
    --enable DEBUG_VM --enable DEBUG_VM_PGFLAGS \
    --enable TRANSPARENT_HUGEPAGE --enable TRANSPARENT_HUGEPAGE_MADVISE \
    --enable EXT4_FS --enable EXT4_USE_FOR_EXT2 \
    --enable VIRTIO --enable VIRTIO_PCI --enable VIRTIO_BLK --enable PCI \
    --enable BLK_DEV --enable SERIAL_8250 --enable SERIAL_8250_CONSOLE
  make ARCH=x86 O="$B" olddefconfig >/dev/null 2>&1
fi
grep -E 'CONFIG_(PAGE_MMUSHIFT|DEBUG_VM|EXT4_FS|VIRTIO_BLK)=' "$B/.config"

echo "=== [2/5] build bzImage -j10 @ $(date +%T) ==="
make ARCH=x86 O="$B" -j10 bzImage 2>&1 | tail -4
BZ="$B/arch/x86/boot/bzImage"
[ -f "$BZ" ] || { echo "BUILD FAIL: no bzImage"; exit 5; }
ls -la "$BZ"

echo "=== [3/5] compile init binaries (static) @ $(date +%T) ==="
cd "$US" || exit 6
for t in init-anon-stress init-leak-probe; do
  gcc -O2 -static -include stdarg.h -o "$t" "$t.c" || { echo "CC FAIL $t"; exit 7; }
done

build_img() {  # $1=binary $2=img
  local bin="$1" img="$2" rd
  rd=$(mktemp -d -p "$D/tmp")
  mkdir -p "$rd/dev" "$rd/proc" "$rd/sys"
  cp "$bin" "$rd/init"
  truncate -s 1G "$img"
  mke2fs -F -q -t ext4 -b 4096 -d "$rd" "$img" 2>/dev/null || return 1
  # device node for init's stdio, no sudo needed (debugfs edits the image)
  debugfs -w -R "mknod /dev/console c 5 1" "$img" >/dev/null 2>&1
  rm -rf "$rd"
}

echo "=== [4/5] build ext4 rootfs images @ $(date +%T) ==="
mkdir -p "$D/tmp"
build_img "$US/init-anon-stress" "$OUT/anon.img" || { echo IMG_FAIL anon; exit 8; }
build_img "$US/init-leak-probe"  "$OUT/leak.img" || { echo IMG_FAIL leak; exit 8; }

run() {  # $1=tag $2=img
  local tag="$1" img="$2" log="$OUT/$1.log"
  echo "--- boot $tag @ $(date +%T) ---"
  timeout 420 qemu-system-x86_64 -enable-kvm -cpu host -m 8G -smp 8 -nographic -no-reboot \
    -kernel "$BZ" -drive file="$img",if=virtio,format=raw \
    -append "root=/dev/vda rootfstype=ext4 rootwait rw console=ttyS0 init=/init ignore_loglevel nokaslr" \
    > "$log" 2>&1
  echo "  rc=$? log=$log"
}

echo "=== [5/5] run repros @ $(date +%T) ==="
run anon "$OUT/anon.img"
run leak "$OUT/leak.img"

echo "=== VERDICT @ $(date +%T) ==="
for tag in anon leak; do
  log="$OUT/$tag.log"
  bad=$(grep -ciE 'bad page|still mapped|nonzero.*mapcount|does not match folio|BUG: Bad|VM_BUG|WARNING' "$log" 2>/dev/null)
  mark=$(grep -hoE 'PGCL-[A-Z]+: (PASS|FAIL)|CORRUPT|bad=-?[0-9]+|dumps=[0-9]+|halting' "$log" 2>/dev/null | tr '\n' ' ')
  echo "[$tag] kernel-bad-lines=$bad  markers: $mark"
done
echo "done."
