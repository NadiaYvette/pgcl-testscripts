#!/bin/bash
set -u
D=/home/nyc/src/pgcl; LX=/home/nyc/src/linux; US=$D/userspace
KB=$D/sh4-pgcl4-build; OUT=$D/sh4-cell-out; RD="$US/initramfs/sh4-root"
TC=/home/nyc/x-tools/sh-sh4--musl--stable-2025.08-1
export PATH="$TC/bin:/usr/bin:$PATH"
# run pgcl-test directly as PID1 (no busybox/shell needed) — it prints results then
# returns -> PID1 exit -> panic (expected/harmless); we capture the output first.
cp "$US/build/pgcl-test-sh4" "$RD/init"
chmod +x "$RD/init"
cd "$LX"
echo "=== rebuild (re-embed pgcl-test-as-init) @ $(date +%T) ==="
make ARCH=sh CROSS_COMPILE=sh4-linux- O="$KB" -j8 zImage >>"$OUT/kbuild4.log" 2>&1
[ -f "$KB/arch/sh/boot/zImage" ] || { echo BUILDFAIL; tail -5 "$OUT/kbuild4.log"; exit 2; }
echo "=== boot pgcl-test directly @ $(date +%T) ==="
timeout 180 qemu-system-sh4 -M r2d -serial null -serial stdio -no-reboot -kernel "$KB/arch/sh/boot/zImage" > "$OUT/boot-direct.log" 2>&1
echo "  qemu rc=$?"
echo "================ sh4 PGCL=4 pgcl-test (direct) ================"
awk '/Run \/init/{f=1} f' "$OUT/boot-direct.log" | grep -vE 'Call trace|^ \[<|vpanic|panic\+|arch_local|do_exit|do_page|do_group|sys_exit|syscall_call|Rebooting|^5[ef]|^Stack' | head -40
echo "rmap/mapcount issues: $(grep -ciE 'rmap.h:|Bad page|nonzero.*mapcount|does not match folio' "$OUT/boot-direct.log")"
echo "DONE @ $(date +%T)"
