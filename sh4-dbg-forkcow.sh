#!/bin/bash
set -u
D=/home/nyc/src/pgcl; LX=/home/nyc/src/linux; KB=$D/sh4-pgcl4-dbg; OUT=$D/sh4-cell-out; RD="$D/userspace/initramfs/sh4-root"
TC=/home/nyc/x-tools/sh-sh4--musl--stable-2025.08-1
export PATH="$TC/bin:/usr/bin:$PATH"
cd "$LX"
echo "=== configure sh4 PGCL=4 + DEBUG_VM @ $(date +%T) ==="
rm -rf "$KB"; mkdir -p "$KB"; cp "$D/sh4-pgcl4-build/.config" "$KB/.config"
scripts/config --file "$KB/.config" --enable DEBUG_VM --enable DEBUG_VM_PGTABLE --enable DEBUG_INFO_DWARF5 --enable FRAME_POINTER
make ARCH=sh CROSS_COMPILE=sh4-linux- O="$KB" olddefconfig >"$OUT/dbg.kb" 2>&1
make ARCH=sh CROSS_COMPILE=sh4-linux- O="$KB" -j8 zImage >>"$OUT/dbg.kb" 2>&1
[ -f "$KB/arch/sh/boot/zImage" ] || { echo BUILDFAIL; tail -6 "$OUT/dbg.kb"; exit 2; }
echo "=== boot diag3 on DEBUG_VM kernel @ $(date +%T) ==="
timeout 150 qemu-system-sh4 -M r2d -serial null -serial stdio -no-reboot \
  -kernel "$KB/arch/sh/boot/zImage" -append "console=ttySC1,115200 noiotrap ignore_loglevel" > "$OUT/dbg.boot" 2>&1
echo "================ DEBUG_VM diag3 ================"
awk '/cow-write i=0/{f=1} f' "$OUT/dbg.boot" 2>/dev/null | head -40
echo "---- crash markers ----"
grep -nE 'BUG|VM_BUG|Oops|Unable to handle|PC is at|panic|WARNING|kill init' "$OUT/dbg.boot" 2>/dev/null | head
echo "DONE @ $(date +%T)"
