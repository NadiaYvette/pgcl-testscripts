#!/bin/bash
set -u
cd /home/nyc/src
if [ ! -d qemu/.git ]; then
  echo "=== clone qemu v10.1.4 (shallow) $(date +%H:%M:%S) ==="
  git clone --depth 1 --branch v10.1.4 https://gitlab.com/qemu-project/qemu.git qemu 2>&1 | tail -3 || { echo CLONE-FAIL; exit 1; }
fi
cd qemu
if [ ! -f build/build.ninja ]; then
  echo "=== configure (x86_64-softmmu, tcg) $(date +%H:%M:%S) ==="
  ./configure --target-list=x86_64-softmmu --disable-docs --disable-werror \
    --disable-tools --disable-gtk --disable-sdl --disable-vnc --disable-curses \
    > /home/nyc/src/pgcl/qemu-configure.log 2>&1 || { echo CONFIGURE-FAIL; tail -20 /home/nyc/src/pgcl/qemu-configure.log; exit 1; }
fi
echo "=== build $(date +%H:%M:%S) ==="
taskset -c 12-19 ninja -C build qemu-system-x86_64 > /home/nyc/src/pgcl/qemu-build.log 2>&1
rc=$?; echo "build rc=$rc $(date +%H:%M:%S)"
[ "$rc" = 0 ] || { tail -25 /home/nyc/src/pgcl/qemu-build.log; exit 1; }
ls -la build/qemu-system-x86_64 | awk '{print "  "$5" "$9}'
echo "=== verify MY build reproduces minimal #143 under TCG $(date +%H:%M:%S) ==="
D=/home/nyc/src/pgcl/rmap-ab; P=/home/nyc/src/pgcl
for r in 1 2; do
  L=$D/myqemu-min-$r.log
  bash "$D/iso" timeout 600 build/qemu-system-x86_64 -accel tcg,thread=multi -cpu max -smp 8 -m 2G \
    -kernel "$D/bzImage-vanfix" -initrd "$D/abl-initramfs/initramfs.cpio.gz" \
    -append "console=ttyS0 nokaslr ignore_loglevel panic=1 rr_nofork rr_nocow" \
    -drive file="$D/btrfs.img",format=raw,if=virtio \
    -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
    -nographic -no-reboot > "$L" 2>&1
  ki=$(grep -ac 'Attempted to kill init' "$L")
  echo "myqemu-min-$r: killinit=$ki => $([ "$ki" -gt 0 ] && echo CRASH-REPRODUCES || echo clean) $(date +%H:%M:%S)"
done
