#!/bin/bash
# Post-v7.1-rebase build smoke. Out-of-tree (O=) so the checkout stays clean.
#   x86_64 PGCL=0  -> Newton-limit regression (must compile like mainline)
#   x86_64 PGCL=4  -> primary PGCL path
#   arm64  PGCL=4  -> the conflict arch (free_hotplug_pgtable_page resolution)
set -u
SRC=/home/nyc/src/linux
LOG=/home/nyc/src/pgcl/bv-v71.log
: > "$LOG"
run() {
  local tag=$1 arch=$2 cross=$3 cfg=$4 sh=$5 tgt=$6
  local bv=/home/nyc/src/pgcl/bv-v71-$tag
  echo "=== $tag : ARCH=$arch $cfg PAGE_MMUSHIFT=$sh @ $(date +%T) ===" >>"$LOG"
  if [ -n "$cross" ] && ! command -v "${cross}gcc" >/dev/null 2>&1; then
    echo "RESULT $tag: SKIP (no ${cross}gcc)" >>"$LOG"; return
  fi
  rm -rf "$bv"; mkdir -p "$bv"
  ( cd "$SRC"
    make ARCH=$arch ${cross:+CROSS_COMPILE=$cross} O="$bv" "$cfg"
    scripts/config --file "$bv/.config" --set-val PAGE_MMUSHIFT "$sh"
    make ARCH=$arch ${cross:+CROSS_COMPILE=$cross} O="$bv" olddefconfig
    make ARCH=$arch ${cross:+CROSS_COMPILE=$cross} O="$bv" -j"$(nproc)" $tgt
  ) >>"$LOG" 2>&1
  local rc=$?
  echo "RESULT $tag PAGE_MMUSHIFT=$sh: $([ $rc -eq 0 ] && echo OK || echo "FAIL rc=$rc")" >>"$LOG"
  grep -H 'CONFIG_PAGE_MMUSHIFT' "$bv/.config" >>"$LOG" 2>&1
}
run x86-0   x86   ""                  x86_64_defconfig 0 bzImage
run x86-4   x86   ""                  x86_64_defconfig 4 bzImage
run arm64-4 arm64 aarch64-linux-gnu-  defconfig        4 Image
echo "=== ALL DONE @ $(date +%T) ===" >>"$LOG"
echo "--- summary ---" >>"$LOG"
grep '^RESULT' "$LOG" >>"$LOG"
