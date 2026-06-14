#!/bin/bash
set -u
D=/home/nyc/src/pgcl/kernel-rpm-build/pgcl0
STAGE=/home/nyc/src/pgcl/pgcl-laptop-rpms
mkdir -p "$STAGE"
echo "######## pgcl0-unsil binrpm-pkg start $(date +%H:%M:%S) ########"
( cd "$D" && make -j20 binrpm-pkg ) > /home/nyc/src/pgcl/pgcl0-unsil-rpm.log 2>&1
rc=$?
echo "pgcl0-unsil binrpm-pkg rc=$rc $(date +%H:%M:%S)"
if [ $rc -ne 0 ]; then echo "--- last 20 log lines ---"; tail -20 /home/nyc/src/pgcl/pgcl0-unsil-rpm.log; echo "######## BUILD FAIL ########"; exit $rc; fi
KREL=$(cat "$D/include/config/kernel.release" 2>/dev/null); V=${KREL//-/_}
find "$D/rpmbuild/RPMS" "$HOME/rpmbuild/RPMS" -name "kernel-${V}-*.x86_64.rpm" 2>/dev/null \
  | grep -vE 'devel|headers|debug|libc' | sort -u | while read -r f; do cp -v "$f" "$STAGE/"; done
echo "######## pgcl0-unsil RPM DONE $(date +%H:%M:%S) ########"
ls -la "$STAGE"/kernel-*unsil* 2>/dev/null
