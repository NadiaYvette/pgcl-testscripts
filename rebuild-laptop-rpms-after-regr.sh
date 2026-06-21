#!/bin/bash
# Wait for the PGCL=4 regression build+boot to finish (so we don't run two heavy
# -j10 kernel builds at once and re-trigger the OOM), then rebuild the laptop
# pgcl0/4/6 RPMs. They are O= objtrees with source -> /home/nyc/src/linux, so
# they pick up the init_64.c PHYSICAL_PAGE_MASK fix + WARN_ONCE tripwire and the
# 4 sibling fixes. pgcl0 keeps its un-silenced DEBUG_VM+PAGE_OWNER config for the
# pstore-capture testboot. Staged into pgcl-laptop-rpms/. Does NOT install/boot.
set -u
REGLOG=/home/nyc/src/pgcl/pgcl4-regr.log
for i in $(seq 1 600); do
  grep -q 'qemu rc=' "$REGLOG" 2>/dev/null && break
  sleep 5
done
echo "### regression done -> rebuilding laptop RPMs $(date +%H:%M:%S)"
cd /home/nyc/src/pgcl && MJ=10 ./build-laptop-rpms.sh
echo "### laptop RPM rebuild complete $(date +%H:%M:%S)"
ls -la /home/nyc/src/pgcl/pgcl-laptop-rpms/
