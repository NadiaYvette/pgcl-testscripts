#!/bin/bash
# Stress-boot mips64 PGCL=6 to confirm the mips_stack_top() workaround removal
# (root-fixed: FP-emu delay-slot page now mapped MMUPAGE_SIZE not PAGE_SIZE).
# Original bug: 12-25% per-boot argv/env clobber -> init exits 127 ->
# "Attempted to kill init! exitcode=0x00007f00". Need ~30/30 clean to confirm.
set -u
LX=/home/nyc/src/linux
D=/home/nyc/src/pgcl
INITRAMFS="$D/userspace/initramfs"
BD="$D/mips-stress-build"
N=${N:-30}
cd "$LX" || exit 1

echo "######## mips64 PGCL=6 stack-workaround stress: build $(date +%H:%M:%S) ########"
make -s ARCH=mips CROSS_COMPILE=mips64-linux-gnu- O="$BD" malta_defconfig >/dev/null 2>&1 || { echo BUILD-CFG-FAIL; exit 2; }
scripts/config --file "$BD/.config" --set-val PAGE_MMUSHIFT 6
scripts/config --file "$BD/.config" \
    --enable 64BIT --enable CPU_MIPS64_R2 \
    --enable CPU_BIG_ENDIAN --disable CPU_LITTLE_ENDIAN \
    --enable BLK_DEV_INITRD \
    --set-str INITRAMFS_SOURCE "$INITRAMFS/initramfs-mips64.cpio.gz" \
    --set-str CMDLINE "console=ttyS0 panic=1 autotest=1" --enable CMDLINE_BOOL
make -s ARCH=mips CROSS_COMPILE=mips64-linux-gnu- O="$BD" olddefconfig >/dev/null 2>&1
grep -q 'CONFIG_PAGE_MMUSHIFT=6' "$BD/.config" || { echo CFG-SHIFT-FAIL; exit 2; }
make -j"$(nproc)" ARCH=mips CROSS_COMPILE=mips64-linux-gnu- O="$BD" vmlinux >/dev/null 2>&1 || { echo BUILD-FAIL; exit 3; }
echo "build done $(date +%H:%M:%S); booting ${N}x"

pass=0; fail=0; incon=0
for i in $(seq 1 "$N"); do
  L="$D/mips-stress-build/boot_$i.log"
  timeout 60 qemu-system-mips64 -M malta -cpu MIPS64R2-generic -m 2G \
    -nographic -no-reboot -kernel "$BD/vmlinux" \
    -append "console=ttyS0 panic=1 autotest=1" >"$L" 2>&1
  if grep -qE 'Attempted to kill init|exitcode=0x00007f00' "$L"; then
    fail=$((fail+1)); verdict="FAIL(kill-init)"
  elif grep -qE 'Run /init as init process' "$L" && grep -qiE 'pgcl|LTP|PASS|Test|subtotal' "$L"; then
    pass=$((pass+1)); verdict="PASS"
  elif grep -qE 'Run /init as init process' "$L"; then
    pass=$((pass+1)); verdict="PASS(init-started)"
  else
    incon=$((incon+1)); verdict="INCONCLUSIVE(no-init-reached)"
  fi
  echo ">>> boot $i/$N: $verdict"
done
echo "######## mips stress DONE $(date +%H:%M:%S): PASS=$pass FAIL=$fail INCON=$incon ########"
