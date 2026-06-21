#!/bin/bash
# Full git identity migration gmail -> ik.me for the PGCL branch:
#   - rewrite every commit in v7.1..HEAD: author+committer email
#     nadia.yvette.chambers@gmail.com -> @ik.me (NAMES and DATES preserved)
#   - GPG-sign every rewritten commit with the configured key (E64334A1…,
#     primary UID ik.me)
#   - set repo + global git user.email = ik.me so future commits are ik.me
# Safety: backup/pre-ikme-migration already points at the old HEAD. Verifies the
# resulting tree is byte-identical and every commit is signed before finishing.
# Does NOT push.
set -eu
cd /home/nyc/src/linux
NEW=nadia.yvette.chambers@ik.me
OLD=nadia.yvette.chambers@gmail.com

git config user.email "$NEW"
git config --global user.email "$NEW"

PRE=$(git rev-parse 'HEAD^{tree}')
echo "pre-rewrite tree: $PRE"

FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f \
  --env-filter "
    [ \"\$GIT_AUTHOR_EMAIL\" = \"$OLD\" ]    && export GIT_AUTHOR_EMAIL=$NEW
    [ \"\$GIT_COMMITTER_EMAIL\" = \"$OLD\" ] && export GIT_COMMITTER_EMAIL=$NEW
    true
  " \
  --commit-filter 'git commit-tree -S "$@"' \
  v7.1..HEAD

POST=$(git rev-parse 'HEAD^{tree}')
echo "post-rewrite tree: $POST"
if [ "$PRE" != "$POST" ]; then
  echo "!!! TREE MISMATCH — content changed, aborting confidence. Restore: git reset --hard backup/pre-ikme-migration"
  exit 1
fi
echo "TREE IDENTICAL ✓"

# verification
echo "=== identities after rewrite (should all be @ik.me) ==="
git log v7.1..HEAD --format='%ae|%ce' | sort | uniq -c
echo "=== signature coverage (G=good) — count of unsigned should be 0 ==="
git log v7.1..HEAD --format='%G?' | sort | uniq -c
echo "DONE. Backup at backup/pre-ikme-migration. Not pushed."
