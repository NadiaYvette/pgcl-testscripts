#!/bin/bash
D=/home/nyc/src/pgcl/rmap-ab
echo "######## #143 ABLATION BATCH $(date +%H:%M:%S) ########"
MEM=2G  bash $D/run-abl-qemu.sh full   4
MEM=12G bash $D/run-abl-qemu.sh full   4   # pressure control: expect ~clean
MEM=2G  bash $D/run-abl-qemu.sh nofork 6   # cross-mm needed?
MEM=2G  bash $D/run-abl-qemu.sh nocow  6   # COW needed?
MEM=2G  bash $D/run-abl-qemu.sh nohog  6   # reclaim needed?
echo; echo "######## SUMMARY ########"
grep -hE '=== \[abl-.*corrupt ===' /dev/stdin 2>/dev/null
