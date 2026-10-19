#!/usr/bin/env bash
# Drill 10, part 3: practice `git bisect run` on a throwaway repo.
#
# Builds a repo with 100 commits. Each commit bumps a "max_batch" setting in
# config.txt; commit 63 sets it above what the (pretend) API allows. Then
# git bisect finds that commit automatically using test.sh, in ~7 steps.
#
# Usage: bash bisect_demo.sh
# Exit codes `git bisect run` understands: 0 = good, 125 = skip this commit,
# any other 1-127 = bad. Anything that returns those works as a test:
#   git bisect run ./test.sh
#   git bisect run pwsh -NoProfile -File ./test.ps1
#   git bisect run go test ./...
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(mktemp -d)"
cd "$repo"
git init -q
git config user.email "bisect@example.com"
git config user.name "Bisect Demo"

for i in $(seq 1 100); do
  if [ "$i" -ge 63 ]; then batch=$((400 + i)); else batch=$((300 + i)); fi
  printf 'commit=%s\nmax_batch=%s\n' "$i" "$batch" > config.txt
  git add config.txt
  git commit -q -m "Change $i: tune batch size"
done

cp "$here/test.sh" ./test.sh
chmod +x test.sh
first=$(git rev-list --max-parents=0 HEAD)
git bisect start HEAD "$first" | tee bisect.log
git bisect run ./test.sh | tee -a bisect.log | grep -E "is the first bad commit|^Bisecting" || true
echo "First bad commit message: $(git log -1 --format=%s refs/bisect/bad)"
echo "Steps: $(grep -c '^Bisecting' bisect.log) test runs for 100 commits (log2(100) is about 7)"
git bisect reset > /dev/null 2>&1
echo "Demo repo left at $repo"
