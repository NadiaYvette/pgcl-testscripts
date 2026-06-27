#!/bin/bash
# memhog.sh [SIZE_GB] [SECS] — recreate host memory pressure on demand.
#
# Substitutes for the incidental cbmc/"frankenstein" load that made rr-record
# land #143's racy -smp1 schedule (=> a reverse-debuggable capture), and backs
# A/B runs should the live -smp8 oracle ever need pressure.  172 GiB swap => no
# OOM at sane sizes; the OOM killer would target this hog (biggest RSS) anyway.
#
# Keeps the region WARM (continuous re-touch) so the kernel evicts the guest's
# pages, not the hog's.  CPU-pinned off Telix (default the pgcl cores 12-15) so
# it doesn't perturb the real-time co-tenant; the *memory* pressure is global by
# nature -- that is the point.
#
#   start:  ./memhog.sh 45 3600 &        # 45 GiB, 1 h, background
#   stop :  pkill -f '[m]emhog.sh'       # or Ctrl-C if foreground
#   watch:  free -g                      # free column should drop toward swap
#
# Prefers stress-ng (--vm-keep); falls back to a dependency-free python hog.
set -u
GB="${1:-45}"; SECS="${2:-3600}"; CORES="${MEMHOG_CORES:-12-15}"
BYTES=$(( GB * 1024 * 1024 * 1024 ))
echo "memhog: ${GB} GiB warm for ${SECS}s on cores ${CORES}; free now $(free -g | awk '/Mem|Speicher/{print $4}') GiB"
echo "memhog: stop with  pkill -f '[m]emhog.sh'"

HOGPID=""
trap 'echo "memhog: stopping"; kill $HOGPID 2>/dev/null; exit 0' INT TERM

if command -v stress-ng >/dev/null 2>&1; then
  echo "memhog: backend = stress-ng --vm-keep (4 workers)"
  taskset -c "$CORES" stress-ng --vm 4 --vm-bytes "$(( BYTES / 4 ))" --vm-keep --timeout "${SECS}s" &
else
  echo "memhog: backend = python continuous-sweep (stress-ng not found)"
  taskset -c "$CORES" python3 -c '
import sys, time
n = int(sys.argv[1]); end = time.time() + float(sys.argv[2])
b = bytearray(n)                          # allocate
for i in range(0, n, 4096): b[i] = 1      # touch every page -> resident
print("memhog: %d GiB resident; holding warm" % (n >> 30), flush=True)
while time.time() < end:                  # continuous sweep keeps pages hot
    for i in range(0, n, 4096): b[i] ^= 1
' "$BYTES" "$SECS" &
fi
HOGPID=$!
wait $HOGPID
echo "memhog: done"
