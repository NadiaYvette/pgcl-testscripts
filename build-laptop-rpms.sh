#!/bin/bash
# Package the laptop PGCL boot kernels (0, 6, 4) as binary RPMs via the kernel's
# own binrpm-pkg target. Staged into a buildroot — installs nothing live.
# Order: 0 and 6 first (needed for those boots), then 4 (manifest-hygiene rebuild).
set -u
SRC=/home/nyc/src/linux
STAGE=/home/nyc/src/pgcl/pgcl-laptop-rpms
mkdir -p "$STAGE"
for N in 0 6 4; do
  D=/home/nyc/src/pgcl/kernel-rpm-build/pgcl$N
  echo "############ binrpm-pkg pgcl$N  $(date +%H:%M:%S) ############"
  # -j10 (not 20): the laptop config is heavy (all-drivers + PAGE_OWNER +
  # DEBUG_VM); some TUs spike to multiple GB, and -j20 OOM-killed gcc on a
  # loaded box. One config builds at a time, so peak = one -jMJ kernel build.
  ( cd "$D" && make -j"${MJ:-10}" binrpm-pkg ) > /home/nyc/src/pgcl/pgcl$N-rpm.log 2>&1
  rc=$?
  echo "pgcl$N binrpm-pkg rc=$rc"
  if [ $rc -ne 0 ]; then
    echo "  --- last 15 log lines ---"; tail -n 15 /home/nyc/src/pgcl/pgcl$N-rpm.log
    continue
  fi
  # collect ONLY this objtree's freshly-built image RPM, matched by its exact
  # kernelrelease (RPM converts '-' to '_'); avoids re-scooping stale RPMs that
  # accumulate in the shared ~/rpmbuild/RPMS topdir.
  KREL=$(cat "$D/include/config/kernel.release" 2>/dev/null)
  V=${KREL//-/_}
  find "$D/rpmbuild/RPMS" "$HOME/rpmbuild/RPMS" -name "kernel-${V}-*.x86_64.rpm" 2>/dev/null \
    | grep -vE 'devel|headers|debug|libc' | sort -u | while read -r f; do cp -v "$f" "$STAGE/"; done
done
echo "############ RPMS DONE  $(date +%H:%M:%S) ############"
ls -la "$STAGE"
