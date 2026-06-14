#!/bin/bash
# Resume-safe per-arch (bucket C) carve+build+commit for pgcl-series.
# Idempotent: skips any arch already committed == work branch. Safe to re-run
# after a reboot. Build dirs are in /tmp (recreated per arch).
set -u
cd /home/nyc/src/linux-series || exit 1
tip=a8bb04366ba4
git reset --hard HEAD >/dev/null 2>&1   # drop any uncommitted in-flight carve
CSKY_BIN=$HOME/x-tools/gcc-16.1.0-nolibc/csky-linux/bin
SH_BIN=$HOME/x-tools/gcc-16.1.0-nolibc/sh4-linux/bin
SPECS=(
"x86|x86_64|||"
"arm64|arm64|aarch64-linux-gnu-|defconfig||"
"arm|arm|arm-linux-gnu-|multi_v7_defconfig||"
"s390|s390|s390x-linux-gnu-|defconfig|drivers/s390|"
"powerpc|powerpc|powerpc64le-linux-gnu-|ppc64_defconfig||"
"sparc|sparc|sparc64-linux-gnu-|sparc64_defconfig|drivers/sbus|"
"mips|mips|mips64-linux-gnu-|malta_defconfig||"
"loongarch|loongarch|loongarch64-linux-gnu-|defconfig||"
"riscv|riscv|riscv64-linux-gnu-|defconfig||"
"parisc|parisc|hppa-linux-gnu-|generic-32bit_defconfig|drivers/parisc|"
"alpha|alpha|alpha-linux-gnu-|defconfig||"
"microblaze|microblaze|microblaze-linux-gnu-|defconfig||"
"m68k|m68k|m68k-linux-gnu-|multi_defconfig||"
"arc|arc|arc-linux-gnu-|haps_hs_smp_defconfig||"
"csky|csky|csky-linux-|defconfig||$CSKY_BIN"
"sh|sh|sh4-linux-|rts7751r2dplus_defconfig||$SH_BIN"
"xtensa|xtensa|xtensa-linux-gnu-|defconfig||"
)
# NOTE: xtensa uses the generic (fsf-variant) defconfig, not audio_kc705_defconfig:
# the Fedora xtensa-linux-gnu binutils targets the fsf core, whose assembler lacks
# the 'atomctl' register that dc233c/custom cores (audio_kc705) need. PGCL-independent.
for spec in "${SPECS[@]}"; do
  IFS='|' read -r dir A CC DC COUP XP <<<"$spec"
  if git diff --quiet HEAD "$tip" -- "arch/$dir/" $COUP; then
    echo "$dir: already done (skip)"; continue
  fi
  [ -n "$XP" ] && export PATH="$XP:$PATH"
  echo "=== $dir ($A ${DC:-native}) ==="
  git checkout "$tip" -- "arch/$dir/" $COUP
  b=/tmp/c-$dir; rm -rf "$b"; mkdir -p "$b"
  make O="$b" ARCH=$A ${CC:+CROSS_COMPILE=$CC} "$DC" >/tmp/c-$dir.log 2>&1 \
    || { echo "$dir DEFCONFIG FAIL (skip, not committed)"; tail -6 /tmp/c-$dir.log; git checkout HEAD -- "arch/$dir/" $COUP 2>/dev/null; continue; }
  make O="$b" ARCH=$A ${CC:+CROSS_COMPILE=$CC} -j10 >>/tmp/c-$dir.log 2>&1 \
    || { echo "$dir BUILD FAIL (skip, not committed)"; grep -iE 'error:|undefined|implicit' /tmp/c-$dir.log|head; git checkout HEAD -- "arch/$dir/" $COUP 2>/dev/null; continue; }
  git add -A
  git commit -q -m "$dir: support page clustering (PAGE_MMUSHIFT)

No functional change when PAGE_MMUSHIFT == 0.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
  echo "$dir: BUILD OK + committed $(git rev-parse --short HEAD)"
done
echo "=== bucket C done. series patches: $(git rev-list --count "$tip"..HEAD 2>/dev/null) ; non-arch+arch remaining vs work: $(git diff "$tip" --name-only | wc -l) ==="
