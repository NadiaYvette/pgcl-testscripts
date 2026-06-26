#!/bin/bash
# Full-repo kernel push to sourcehut -- the ONE host carrying a directly-clonable
# PGCL kernel repo (disroot/framagit get bundles+patch-sequences instead, due to
# space limits).  page-clustering-001 first (bulk history; sets default branch),
# then the rest incrementally (they share its objects, so cheap).  Caller pins
# this to CPUs 12-15 (leaves 16-19 for QEMU) and runs it via setsid so it
# survives session/API interruptions (the earlier b0ztd1r43 push was orphaned).
set -u
cd /home/nyc/src/linux || exit 1
BR="nadia.chambers/page-clustering-001 \
nadia.chambers/pgcl-series \
nadia.chambers/pgcl-mmupage-mapcount \
nadia.chambers/btrfs-pagesize-gt64k \
nadia.chambers/or1k-pgcl-csky \
nadia.chambers/pgcl-per-subtable-ptlock-wip \
wip/hugetlb-pgcl \
wip/or1k-pgcl \
backup/pre-v7.1-rebase \
backup/pre-ikme-migration \
pgcl-on-rc6-backup \
pre-rebase-backup-20260528"
echo "=== push start $(date +%H:%M:%S) ==="
for b in $BR; do
  echo "--- push $b $(date +%H:%M:%S) ---"
  git -c pack.threads=4 push sourcehut "$b" 2>&1
  echo "PUSH-EXIT $b rc=$?"
done
echo "=== push done $(date +%H:%M:%S) ==="
