#!/bin/bash
# build-pgcl4-variants.sh — build pgcl4 PERF + DEBUG laptop RPMs from the
# mapcount-fixed work tree, both = base (mainline laptop) config + PAGE_MMUSHIFT=4,
# differing only by debug knobs.  Sequential (disk-safe). Stages to pgcl-laptop-rpms/.
set -u
D=/home/nyc/src/pgcl; LX=/home/nyc/src/linux
BASE="$D/kernel-rpm-build/base/.config"
STAGE="$D/pgcl-laptop-rpms"; mkdir -p "$STAGE"
LOG="$D/pgcl4-variants.log"; : >"$LOG"

build_variant() {  # $1=objdir $2=localversion $3=extra-scripts-config-args
  local OBJ="$D/kernel-rpm-build/$1" lv="$2" extra="$3"
  echo "############ $1 ($lv) build start $(date +%H:%M:%S) ############" >>"$LOG"
  mkdir -p "$OBJ"; cp "$BASE" "$OBJ/.config"
  ( cd "$LX"
    scripts/config --file "$OBJ/.config" --set-val PAGE_MMUSHIFT 4 --set-str LOCALVERSION "$lv" $extra
    make O="$OBJ" olddefconfig >>"$LOG" 2>&1
    make O="$OBJ" -j10 binrpm-pkg >>"$LOG" 2>&1 )
  local rc=$?
  echo "$1 binrpm-pkg rc=$rc $(date +%H:%M:%S)" >>"$LOG"
  if [ "$rc" -eq 0 ]; then
    local KREL; KREL=$(cat "$OBJ/include/config/kernel.release" 2>/dev/null); local V=${KREL//-/_}
    find "$OBJ/rpmbuild/RPMS" "$HOME/rpmbuild/RPMS" -name "kernel-${V}-*.x86_64.rpm" 2>/dev/null \
      | grep -vE 'devel|headers|debug' | sort -u | while read -r f; do cp -v "$f" "$STAGE/" >>"$LOG" 2>&1; done
    echo "  $1 staged: $(ls "$STAGE"/kernel-*${lv//-/_}*.rpm 2>/dev/null)" >>"$LOG"
  fi
  return $rc
}

echo "=== [1/2] pgcl4 PERF (DAMON on, debug+poisoning off) @ $(date +%T) ==="
build_variant pgcl4 -pgcl4perf ""
echo "=== [2/2] pgcl4 DEBUG (+DEBUG_VM, verifies faithful userspace) @ $(date +%T) ==="
build_variant pgcl4-debug -pgcl4debug "--enable DEBUG_VM --enable DEBUG_VM_PGTABLE"
echo "============ PGCL4 VARIANTS DONE @ $(date +%T) ============"
grep -E 'binrpm-pkg rc=|staged:' "$LOG" | tail -6
ls -la "$STAGE"/kernel-7.1.0_pgcl4perf*.rpm "$STAGE"/kernel-7.1.0_pgcl4debug*.rpm 2>/dev/null
