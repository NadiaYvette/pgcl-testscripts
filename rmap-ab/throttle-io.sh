#!/bin/bash
# Leave NVMe I/O headroom for Telix (qemu-rt, latency-sensitive) by capping the
# bandwidth of OUR heavy I/O (the sourcehut push + the repro testbeds) via the
# cgroup-v2 io controller.  scheduler=[none] on nvme0n1, so ionice is a no-op --
# io.max (blk-throttle) is the only lever, and it works above any scheduler.
# Moving a running PID into a cgroup is transparent (no restart), so this honors
# "don't restart the push, let it finish".  Idempotent; safe to re-run.
set -u
DEV="259:0"                      # nvme0n1
RBPS=${RBPS:-83886080}           # 80 MB/s read cap
WBPS=${WBPS:-41943040}           # 40 MB/s write cap
BASE=/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service
CG="$BASE/pgcl-io"

# 1. ensure io is enabled in children of user@1000.service, then make the leaf
grep -qw io "$BASE/cgroup.subtree_control" 2>/dev/null || echo +io > "$BASE/cgroup.subtree_control"
mkdir -p "$CG"
echo "$DEV rbps=$RBPS wbps=$WBPS" > "$CG/io.max"
echo "io.max set: $(cat "$CG/io.max")"

# 2. collect PIDs to confine.  DEFAULT: the push tree only (PGID 693945) -- it's
#    the new bulk reader coincident with Telix's disturbance, and definitely
#    secondary.  The repro is left alone to preserve the race timing unless
#    ALL=1 is set (then also confine the repro pipeline root, so future QEMU
#    children inherit the cap, plus any live repro QEMU).
pids="$(pgrep -g 693945 2>/dev/null)"
if [ "${ALL:-0}" = 1 ]; then
  pids="$pids $(pgrep -f 'bash .*/run-va.sh' 2>/dev/null)"
  pids="$pids $(pgrep -f 'bash .*/run-rr.sh' 2>/dev/null)"
  pids="$pids $(pgrep -f 'qemu-system-x86_64 .*bzImage-va' 2>/dev/null)"
fi

moved=0
for p in $pids; do
  [ -d "/proc/$p" ] || continue
  if echo "$p" > "$CG/cgroup.procs" 2>/dev/null; then
    moved=$((moved+1))
  fi
done
echo "moved $moved pids into pgcl-io"
echo "members now: $(wc -w < "$CG/cgroup.procs") tasks"
