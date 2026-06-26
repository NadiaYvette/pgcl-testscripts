#!/bin/bash
# Fix-A/B CONTROL: build the CURRENT tree (no #143 debug instrumentation) and run
# smp8 x N, scoring NATIVE kernel corruption signals only (DEBUG_VM bad_page /
# BUG / rss-counter / kill-init).  Establishes the clean reproduction rate that
# any fix arm is measured against.  Arm tag via TAG env (default "ctl").
set -u
SRC=/home/nyc/src/linux
O=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
D=/home/nyc/src/pgcl/rmap-ab
TAG=${TAG:-ctl}
BZ=$D/bzImage-$TAG
N=${N:-12}
echo "=== [$TAG] BUILD start $(date +%H:%M:%S) ==="
taskset -c 12-19 make -C "$SRC" O="$O" -j8 bzImage 2>&1 | tail -4
rc=${PIPESTATUS[0]}
echo "BUILD-EXIT rc=$rc $(date +%H:%M:%S)"
[ "$rc" = 0 ] || { echo "BUILD FAILED"; exit 1; }
cp "$O/arch/x86/boot/bzImage" "$BZ"
echo "staged $(basename "$BZ") $(stat -c %s "$BZ")"
echo "=== [$TAG] batch ($N runs smp8) start $(date +%H:%M:%S) ==="
corrupt=0
for r in $(seq 1 "$N"); do
  L=$D/$TAG-$r.log
  bash "$D/run-rr.sh" "$BZ" "$L" 220 8 >/dev/null 2>&1
  bpm=$(grep -ac 'BUG: Bad page' "$L")
  rss=$(grep -ac 'Bad rss-counter' "$L")
  ki=$(grep -ac 'Attempted to kill init' "$L")
  bug=$(grep -acE 'kernel BUG at|VM_BUG_ON|refcount_t:' "$L")
  login=$(grep -acE 'login:|Welcome to' "$L")
  sig=$((bpm+rss+ki+bug))
  [ "$sig" -gt 0 ] && corrupt=$((corrupt+1))
  echo "$TAG$r: badpage=$bpm rss=$rss killinit=$ki bug=$bug login=$login => $([ "$sig" -gt 0 ] && echo CORRUPT || echo clean) $(date +%H:%M:%S)"
done
echo "=== [$TAG] done: $corrupt/$N corrupt $(date +%H:%M:%S) ==="
