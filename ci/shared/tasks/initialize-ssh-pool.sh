#!/usr/bin/env bash
# One-time pool bootstrap. Existing members require an explicit recovery plan.
set -euo pipefail
cd pool-repo
test -z "$(git status --porcelain)"
existing=$(git ls-tree -r --name-only HEAD docker-hosts-site1)
while IFS= read -r path; do
  case "$path" in
    ''|docker-hosts-site1/claimed/.gitkeep|docker-hosts-site1/unclaimed/.gitkeep) ;;
    *) echo 'SSH Docker host pool already has members; refuse bootstrap.' >&2; exit 1 ;;
  esac
done <<< "$existing"
for path in docker-hosts-site1 docker-hosts-site1/claimed docker-hosts-site1/unclaimed docker-hosts-site1/claimed/.gitkeep docker-hosts-site1/unclaimed/.gitkeep; do
  test ! -L "$path"
done
mkdir -p docker-hosts-site1/{claimed,unclaimed}
touch docker-hosts-site1/{claimed,unclaimed}/.gitkeep
git add docker-hosts-site1/claimed/.gitkeep docker-hosts-site1/unclaimed/.gitkeep
if ! git diff --cached --quiet; then
  git -c user.name='CI Pool Resource' -c user.email=ci-pool@localhost \
    commit -m 'Initialize empty SSH Docker host pool'
fi
