#!/bin/bash
# Given a bad boot log, for each distinct bad_page folio, dump the LMC ledger of
# its FINAL lifecycle (the run of events ending at the last LMC event before the
# bad_page timestamp), to expose where lmc diverges from the mm_id slots.
L="$1"
echo "=== bad_page folios (pfn -> folio base via order) ==="
grep -A3 'Bad page state' "$L" | grep -oE 'pfn:0x[0-9a-f]+|order [0-9]+' | paste - - 2>/dev/null | head
# distinct bad folio bases: take bad pfns, find their LMC pfn (folio base) by matching the LMC pfn that is <= bad pfn and within order
for badpfn in $(grep 'Bad page state' "$L" | grep -oE 'pfn:0x?[0-9a-f]+' | sed 's/pfn://; s/0x//' | sort -u | head -3); do
  echo "############ bad page pfn=$badpfn ############"
  # find LMC lines whose folio covers this pfn: folio base such that base <= pfn < base+2^ord
  # simplest: grep LMC for any pfn within 0x20 below badpfn (covers up to order-5)
  bd=$((16#$badpfn))
  for cand in $(grep -oE 'LMC[+-] pfn=[0-9a-f]+' "$L" | awk '{print $2}' | sed 's/pfn=//' | sort -u); do
    cb=$((16#$cand)); ord_max=32
    if [ "$cb" -le "$bd" ] && [ $((bd - cb)) -lt 32 ]; then
      n=$(grep -c "LMC[+-] pfn=$cand " "$L")
      echo "  folio base=$cand covers pfn (events=$n) — last 24 events:"
      grep -E "LMC[+-] pfn=$cand " "$L" | tail -24 | sed -E 's/ra=0x0//; s/^\[//; s/\]//'
      break
    fi
  done
done
