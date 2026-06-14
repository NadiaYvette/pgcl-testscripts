#!/bin/bash
# x86_64 PAGE_MMUSHIFT 0..7 sweep at -m 32G (large-RAM, closes the matrix blind spot).
# Source = work branch /home/nyc/src/linux (all session fixes committed).
set -u
D=/home/nyc/src/pgcl
OUT=$D/x86-bigram-sweep
mkdir -p "$OUT"
for N in 0 1 2 3 4 5 6 7; do
  echo "############ PAGE_MMUSHIFT=$N (x86_64, -m 32G) $(date +%H:%M:%S) ############"
  bash "$D/matrix-driver-bigram.sh" /home/nyc/src/linux x86_64 "$N" "$OUT"
  L="$OUT/x86_64_${N}.log"
  # one-line verdict per shift
  if grep -qiE 'BUG:|Oops|kernel panic|not syncing|Call Trace' "$L" 2>/dev/null; then v="OOPS/PANIC"; \
  elif grep -qE 'LTP subtotals: [0-9]+ passed' "$L" 2>/dev/null; then v="$(grep -E 'LTP subtotals:' "$L" | tail -1 | sed 's/^.*LTP subtotals:/LTP:/') $(grep -q 'reboot: Power down' "$L" && echo '(clean poweroff)')"; \
  else v="NO-SUMMARY (hang/early-fail?)"; fi
  echo ">>> shift=$N: $v"
done
echo "############ SWEEP DONE $(date +%H:%M:%S) ############"
