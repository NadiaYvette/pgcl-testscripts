#!/bin/bash
set -u
D=/home/nyc/src/pgcl; LX=/home/nyc/src/linux; US=$D/userspace
TC=/home/nyc/x-tools/sh-sh4--musl--stable-2025.08-1
export PATH="$TC/bin:/usr/bin:$PATH"
OUT=$D/sh4-cell-out; RD="$US/initramfs/sh4-root"
echo "=== build diag (static sh4) @ $(date +%T) ==="
sh4-linux-gcc -O2 -static -include stdarg.h -o "$RD/init" "$US/fork_cow_diag.c" || { echo CC-FAIL; exit 1; }
file "$RD/init" | cut -d, -f1-2

boot_one() {  # $1=label $2=objdir $3=mmushift
  local lbl=$1 KB="$D/$2" sh=$3
  echo "=== [$lbl] build sh4 PGCL=$sh @ $(date +%T) ==="
  cd "$LX"
  # reuse the WORKING pgcl4 embed config; only flip PAGE_MMUSHIFT
  cp "$D/sh4-pgcl4-build/.config" "$KB/.config" 2>/dev/null || true
  [ -d "$KB" ] || mkdir -p "$KB"
  cp "$D/sh4-pgcl4-build/.config" "$KB/.config"
  scripts/config --file "$KB/.config" --set-val PAGE_MMUSHIFT "$sh"
  make ARCH=sh CROSS_COMPILE=sh4-linux- O="$KB" olddefconfig >"$OUT/${lbl}.kb" 2>&1
  make ARCH=sh CROSS_COMPILE=sh4-linux- O="$KB" -j6 zImage >>"$OUT/${lbl}.kb" 2>&1
  [ -f "$KB/arch/sh/boot/zImage" ] || { echo "  [$lbl] BUILD FAIL"; tail -4 "$OUT/${lbl}.kb"; return 1; }
  echo "=== [$lbl] boot @ $(date +%T) ==="
  timeout 150 qemu-system-sh4 -M r2d -serial null -serial stdio -no-reboot \
    -kernel "$KB/arch/sh/boot/zImage" > "$OUT/${lbl}.boot" 2>&1
  echo "---- [$lbl] DIAG OUTPUT ----"
  grep -hE 'DIAG|CHILD|PARENT-PREFORK' "$OUT/${lbl}.boot" 2>/dev/null
}

boot_one diag4 sh4-pgcl4-build 4
boot_one diag0 sh4-pgcl0-build 0
echo "=== A/B SUMMARY @ $(date +%T) ==="
echo "PGCL=4: $(grep -hE 'CHILD: ' "$OUT/diag4.boot" 2>/dev/null | tail -1)"
echo "PGCL=0: $(grep -hE 'CHILD: ' "$OUT/diag0.boot" 2>/dev/null | tail -1)"
