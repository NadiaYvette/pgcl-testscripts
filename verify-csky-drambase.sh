#!/bin/bash
# verify-csky-drambase.sh — test the #133 csky PGCL=4 boot-blocker hypothesis:
# the qemu-cskyv2 virt machine hardcodes the FDT blob at phys 0x0f000000 (inside
# RAM); the larger PGCL=4 image is suspected to clobber it -> silent hang.
# Hypothesis (scoping agent option 2): set CONFIG_DRAM_BASE above the blob so the
# kernel links/loads above 0x0f000000.  A/B: DRAM_BASE=0x10000000 (fix) vs 0x0
# (control). Standalone — does NOT touch the matrix harness.
set -u
SRC=/home/nyc/src/linux-btrfs-bigpage          # free worktree w/ PGCL base (csky unchanged)
D=/home/nyc/src/pgcl
OUT=$D/csky-drambase-out
INITRAMFS="$D/userspace/initramfs/initramfs-csky.cpio.gz"
mkdir -p "$OUT"
export PATH="/usr/bin:$HOME/x-tools/gcc-16.1.0-nolibc/csky-linux/bin:$HOME/src/csky-qemu-build/bin:$PATH"
command -v csky-linux-gcc >/dev/null || { echo "NO csky-linux- toolchain on PATH"; exit 2; }
command -v qemu-system-cskyv2 >/dev/null || { echo "NO qemu-system-cskyv2 on PATH"; exit 2; }

build_and_boot() {  # $1=tag  $2=DRAM_BASE
  local tag="$1" dram="$2" B="$D/csky-test-$1" log="$OUT/$1.log"
  echo "=== [$tag] build csky PGCL=4 DRAM_BASE=$dram @ $(date +%T) ==="
  rm -rf "$B"; mkdir -p "$B"
  ( cd "$SRC" || exit 3
    make ARCH=csky CROSS_COMPILE=csky-linux- O="$B" defconfig >/dev/null 2>&1
    scripts/config --file "$B/.config" \
      --set-val PAGE_MMUSHIFT 4 \
      --set-val DRAM_BASE "$dram" \
      --enable BLK_DEV_INITRD --set-str INITRAMFS_SOURCE "$INITRAMFS"
    make ARCH=csky CROSS_COMPILE=csky-linux- O="$B" olddefconfig >/dev/null 2>&1
    make ARCH=csky CROSS_COMPILE=csky-linux- O="$B" -j6 vmlinux >/dev/null 2>"$OUT/$tag-build.err" )
  if [ ! -f "$B/vmlinux" ]; then echo "  [$tag] BUILD FAIL"; tail -3 "$OUT/$tag-build.err"; return 1; fi
  echo "  [$tag] built; DRAM_BASE=$(grep -oE 'CONFIG_DRAM_BASE=.*' "$B/.config") booting @ $(date +%T)"
  timeout 120 qemu-system-cskyv2 -M virt -cpu c807 -nographic -no-reboot \
     -kernel "$B/vmlinux" > "$log" 2>&1
  echo "  [$tag] qemu rc=$? log=$log"
  # success = reached userspace; failure = no init / panic / hang
  if grep -qiE 'Run /init|Freeing unused kernel|PGCL|nolibc|reached userspace|init started' "$log"; then
    echo "  [$tag] >>> REACHED USERSPACE"
  else
    echo "  [$tag] >>> did NOT reach userspace (last line: $(tail -1 "$log" 2>/dev/null | head -c 80))"
  fi
  rm -rf "$B"
}

build_and_boot fix 0x10000000
build_and_boot ctrl 0x0
echo "=== DONE @ $(date +%T) ==="
