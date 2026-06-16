#!/bin/bash
# Build the 7.1 mainline baseline kernel RPM (NO PGCL, xe-disabled) for laptop
# A/B testing against the pgcl0/4/6 kernels -- only PGCL differs, GPU driver
# (i915, no xe) is held constant. Source: linux-base @ v7.1; config in
# kernel-rpm-build/base (LOCALVERSION=-mainlinebase, DRM_XE=n). -j10 to avoid OOM
# on the heavy config (override with MJ). Stages into pgcl-laptop-rpms/.
set -u
D=/home/nyc/src/pgcl/kernel-rpm-build/base
STAGE=/home/nyc/src/pgcl/pgcl-laptop-rpms
LOG=/home/nyc/src/pgcl/base-rpm.log
mkdir -p "$STAGE"
echo "############ binrpm-pkg mainline base (v7.1, xe=n)  $(date +%H:%M:%S) ############" >"$LOG"
( cd "$D" && make -j"${MJ:-10}" binrpm-pkg ) >>"$LOG" 2>&1
rc=$?
echo "base binrpm-pkg rc=$rc" >>"$LOG"
if [ "$rc" -eq 0 ]; then
  KREL=$(cat "$D/include/config/kernel.release" 2>/dev/null); V=${KREL//-/_}
  find "$D/rpmbuild/RPMS" "$HOME/rpmbuild/RPMS" -name "kernel-${V}-*.x86_64.rpm" 2>/dev/null \
    | grep -vE 'devel|headers|debug|libc' | sort -u | while read -r f; do cp -v "$f" "$STAGE/"; done >>"$LOG" 2>&1
fi
echo "############ BASE RPM DONE rc=$rc  $(date +%H:%M:%S) ############" >>"$LOG"
