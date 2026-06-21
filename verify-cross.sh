#!/bin/bash
# verify-cross.sh — post-anon-MMUPAGE gates:
#   [A] PGCL=0 Newton-limit build (x86_64, build-only): the converted files must
#       still compile byte-identical-behaviour at shift 0 (catches e.g. the
#       migrate.c first_frag-now-PGCL-only decl being referenced at shift 0).
#   [B] 20-arch PGCL=6 matrix column (build+boot+pgcl-test/stress/LTP per cell)
#       — the cross-arch regression gate for the generic mm rmap/migrate/THP edits.
# Disk-sequenced (/home tight): the Newton build dir is removed before the matrix.
set -u
D=/home/nyc/src/pgcl
LX=/home/nyc/src/linux
OUT=$D/cross-verify-out
mkdir -p "$OUT"

echo "=== [A] PGCL=0 Newton build (x86_64) @ $(date +%T) ==="
cd "$LX" || exit 2
NB=$D/x86-pgcl0-newton
rm -rf "$NB"; mkdir -p "$NB"
make ARCH=x86 O="$NB" x86_64_defconfig >/dev/null 2>&1
scripts/config --file "$NB/.config" --set-val PAGE_MMUSHIFT 0 --enable DEBUG_VM >/dev/null 2>&1
make ARCH=x86 O="$NB" olddefconfig >/dev/null 2>&1
if make ARCH=x86 O="$NB" -j10 bzImage > "$OUT/pgcl0-build.log" 2>&1 && [ -f "$NB/arch/x86/boot/bzImage" ]; then
  echo "NEWTON_PGCL0_BUILD: PASS"
else
  echo "NEWTON_PGCL0_BUILD: FAIL"
  grep -iE 'error:|Error [0-9]' "$OUT/pgcl0-build.log" | head
fi
rm -rf "$NB"
echo "  (newton build dir removed) @ $(date +%T)"

echo "=== [B] 20-arch PGCL=6 matrix (PAR=4) @ $(date +%T) ==="
cd "$D" || exit 3
PAR=4 LX="$LX" ./matrix-column.sh 6
MCOL=$(ls -dt "$D"/matrix-col6-* 2>/dev/null | head -1)
echo "=== MATRIX SUMMARY ($MCOL) ==="
cat "$MCOL/SUMMARY.txt" 2>/dev/null
echo "=== mapcount/rmap regressions across cells? ==="
grep -lE 'rmap\.h:|nonzero.*mapcount|does not match folio|BUG: Bad page' "$MCOL"/*.log 2>/dev/null || echo "  NONE — clean"
echo "CROSS_VERIFY_DONE @ $(date +%T)"
