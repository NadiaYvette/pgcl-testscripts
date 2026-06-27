#!/bin/bash
# build-run-143detect.sh — build the #143 producer-resurrection DETECTOR kernel
# (VM_WARN_ON_ONCE before each per-cluster rmap-add: fires once, with a backtrace
# naming the exact add-site, when a cluster is mapped while already at refcount 0
# or a per-cluster page is mis-keyed [#140]) and run it on the live -smp8 oracle.
# The detector is a pure observer, so the crash still reproduces; the WARN says WHERE.
set -u
SRC=/home/nyc/src/linux; O=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
D=/home/nyc/src/pgcl/rmap-ab
echo "=== build #143 detector kernel $(date +%T) (branch $(git -C "$SRC" rev-parse --abbrev-ref HEAD)) ==="
taskset -c 12-19 make -C "$SRC" O="$O" -j8 bzImage 2>&1 | tail -6
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || { echo "KERNEL-FAIL rc=$rc"; exit 1; }
cp "$O/arch/x86/boot/bzImage" "$D/bzImage-143detect" && echo "OK -> bzImage-143detect $(date +%T)"
echo "=== run detector on live -smp8 oracle (4x, 240s) $(date +%T) ==="
cd "$D"
BZ="$D/bzImage-143detect" bash run-smp8-trip.sh 4 240
echo
echo "=== DETECTOR VERDICT: which add-site fired (names the bug) ==="
for L in "$D"/trip-*.log; do
  [ -f "$L" ] || continue
  w=$(grep -ac 'WARNING:' "$L")
  ki=$(grep -acE 'kill init|Attempted to kill init' "$L")
  bp=$(grep -acE 'Bad page map|bad_page|BUG: Bad' "$L")
  site=$(grep -aoE 'at mm/(filemap|memory)\.c:[0-9]+ [A-Za-z_]+' "$L" | head -1)
  echo "$(basename "$L"): WARNs=$w killinit=$ki badpage=$bp firstWARNsite=[$site]"
done
echo "--- full first WARN block (the in-flagrante producer site) ---"
for L in "$D"/trip-*.log; do
  grep -aq 'WARNING:' "$L" 2>/dev/null || continue
  echo ">>> $L"; grep -anA18 'WARNING:' "$L" | head -22; break
done
echo "=== DONE $(date +%T) ==="
