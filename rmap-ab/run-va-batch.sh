#!/bin/bash
# #143 vaddr-keyed attribution -- VOLUME run.  The detector catch (manifestation
# A: dangling-PTE zap drives _mapcount<-1 -> wp_check) is rare (~1/8 runs; the
# other ~7/8 hit manifestation B -> init SIGSEGV panic, no detector fire).  So
# loop smp8 runs on 16-19 (the proven A/B "corrupt" config) until we land
# CATCHES enough catches (default 3) or hit MAX runs, and dump the attribution
# (wp underflow line + timeline + the pgcl_va_dump install-add list, with the
# >>> culprit) from each catching run.  Reuses the already-built bzImage-va.
set -u
D=/home/nyc/src/pgcl/rmap-ab
BZ=$D/bzImage-va
MAX=${MAX:-40}
CATCHES=${CATCHES:-3}
[ -f "$BZ" ] || { echo "no $BZ -- run run-va.sh first"; exit 1; }

caught=0
echo "=== batch start $(date +%H:%M:%S)  (max $MAX runs, stop after $CATCHES catches) ==="
for r in $(seq 1 "$MAX"); do
  L=$D/vab-$r.log
  bash "$D/run-rr.sh" "$BZ" "$L" 220 8 >/dev/null 2>&1
  tl=$(grep -ac '#143tl' "$L"); wp=$(grep -ac '#143wp' "$L")
  va=$(grep -ac '#143va' "$L"); cu=$(grep -ac '>>> ts=' "$L")
  cr=$(grep -ac '#143cr: SURVIVING' "$L"); pn=$(grep -ac 'kill init' "$L")
  crt=$(grep -ac 'SURVIVING PTE at truncate-cleanup' "$L")
  disc=$(grep -ac '#143disc' "$L")
  nm=$(grep -ac '#143nm' "$L")
  fm155=$(grep -ac 'BUG at mm/filemap.c:155' "$L")
  echo "run$r: cr=$cr (trunc=$crt) nm=$nm disc=$disc fm155=$fm155 wp=$wp tl=$tl va=$va culprit=$cu panic=$pn $(date +%H:%M:%S)"
  if [ "$nm" -gt 0 ] || [ "$cr" -gt 0 ] || [ "$disc" -gt 0 ] || [ "$fm155" -gt 0 ] || [ "$tl" -gt 0 ] || [ "$wp" -gt 0 ]; then
    caught=$((caught+1))
    echo "  +++ CATCH #$caught in $L -- attribution: +++"
    grep -aE '#143nm|#143cr|#143disc|#143lev|#143wp|#143va|>>> ts=|BUG at mm/filemap.c:155|filemap_unaccount_folio|truncate_inode_pages_range|folio_unmap_invalidate' "$L" | sed 's/^/    /' | head -140
    [ "$caught" -ge "$CATCHES" ] && { echo "=== got $caught catches, stopping ==="; break; }
  fi
done
echo "=== batch done $(date +%H:%M:%S): $caught catch(es) ==="
