#!/bin/bash
# #143 re-ablation on the SWAP-FIXED kernel (bzImage-vanswap). Earlier truth-table
# was swap-quirk-contaminated; now nocow/nofork cleanly reveal #143's necessary op.
# Oracle = killinit (manifestation B) + wp/badpage. minimal already validated clean.
export BZ=/home/nyc/src/pgcl/rmap-ab/bzImage-vanswap
for arm in full nofork nocow; do
  echo "########## ARM=$arm (bzImage-vanswap, swap-fixed) ##########"
  bash /home/nyc/src/pgcl/rmap-ab/run-abl-qemu.sh "$arm" 4
done
