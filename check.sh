#!/usr/bin/env bash
# Run every drill in one or more languages and compare with expected/*.txt.
# Lines starting with "~" are timings or other machine-dependent values and are ignored.
#
# Usage: ./check.sh                 all three languages
#        ./check.sh go powershell   just these
#        DRILL=06 ./check.sh go     just one drill
set -uo pipefail
cd "$(dirname "$0")"
langs=("$@")
[ ${#langs[@]} -eq 0 ] && langs=(python powershell go)
declare -A py=(
  [01-big-o]=reconcile_bench.py [02-consistent-hashing]=hash_ring.py [03-queues]=backpressure.py
  [04-retry-jitter]=thundering_herd.py [05-rate-limiting]=token_bucket.py [06-caching]=caches.py
  [07-graphs]=depgraph.py [09-bloom-filter]=bloom.py [10-bisection]=bisect_tools.py [11-joins]=drift_report.py
)
fail=0
for exp in expected/*.txt; do
  drill=$(basename "$exp" .txt)
  [[ -n "${DRILL:-}" && "$drill" != "${DRILL}"* ]] && continue
  for lang in "${langs[@]}"; do
    case $lang in
      python)     cmd=(python3 "$drill/python/${py[$drill]}") ;;
      powershell) ps=("$drill"/powershell/*.ps1); cmd=(pwsh -NoLogo -NoProfile -File "${ps[0]}") ;;
      go)         cmd=(go run "./$drill/go") ;;
      *) echo "unknown language $lang"; exit 2 ;;
    esac
    start=$(date +%s.%N)
    actual=$("${cmd[@]}" 2>&1 | grep -v '^~')
    secs=$(printf '%.1f' "$(echo "$(date +%s.%N) - $start" | bc)")
    if diff <(grep -v '^~' "$exp") <(printf '%s\n' "$actual") > /dev/null; then
      result="PASS"
    else
      result="FAIL"; fail=1
    fi
    if [ "$drill" = "11-joins" ] && [ "$result" = "PASS" ]; then
      if ! sha256sum -c --quiet expected/11-joins.drift_report.sha256 2>/dev/null; then
        result="FAIL (drift_report.csv differs)"; fail=1
      fi
    fi
    printf '%-6s %-24s %-11s %6ss\n' "${result%% *}" "$drill" "$lang" "$secs"
    if [ "$result" != "PASS" ]; then
      diff <(grep -v '^~' "$exp") <(printf '%s\n' "$actual") | head -20 | sed 's/^/    /'
    fi
  done
done
exit $fail
