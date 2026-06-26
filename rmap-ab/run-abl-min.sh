#!/bin/bash
D=/home/nyc/src/pgcl/rmap-ab
echo "######## #143 MINIMAL-TRIGGER ABLATION $(date +%H:%M:%S) ########"
MEM=2G bash $D/run-abl-qemu.sh minimal    6   # single proc, read-only fault, no COW, +fadvise +hog
MEM=2G bash $D/run-abl-qemu.sh minnofadv  6   # same but also no fadvise(DONTNEED)
