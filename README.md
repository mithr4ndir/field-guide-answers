# Systems Algorithms Field Guide: answer key

Reference solutions for every drill in the Field Guide, in Python, PowerShell 7 and Go.
Try each drill yourself first, then compare. The Answer guide tab in the Field Guide
has the expected output and what a correct answer shows for each one.

## Requirements

| Tool | Version | Notes |
| --- | --- | --- |
| Python | 3.10+ | Standard library only. `pip install duckdb` for the SQL part of drill 11. |
| PowerShell | 7.4+ (`pwsh`) | Not Windows PowerShell 5.1: several drills use .NET 8 types and PS 7 features. |
| Go | 1.22+ | One module (`go.mod`) at the repo root, standard library only. |
| Docker + Compose | recent | Drill 8 only. |

## Running a drill

Run everything from the repo root:

```bash
python3 04-retry-jitter/python/thundering_herd.py
pwsh -File 04-retry-jitter/powershell/Invoke-ThunderingHerd.ps1
go run ./04-retry-jitter/go
```

Check every drill in every language against `expected/` (bash, needs `bc`):

```bash
./check.sh                  # all three languages
./check.sh go               # one language
DRILL=06 ./check.sh python  # one drill
```

## Reading the output

- Lines starting with `~` are timings or other machine-dependent values. Everything else
  should match `expected/` exactly, in every language.
- Outputs match across languages because every drill avoids language-specific defaults:
  a shared seeded random generator (MINSTD), SHA-256 for hashing, integer math for
  percentages, ordinal string sorting, and invariant number formatting.
- Each file opens with a header explaining the approach. Comments mark the
  language-specific traps; those are often the most useful part.
- Most drills finish in a second or two. Drill 3 (about 9 s) and drill 5 (about 2 s)
  sleep on purpose. The PowerShell versions of drills 1 and 11 take about 20 s and
  100 s, because they time the slow nested loops; that slowness is the lesson.

## Layout

| Folder | Drill |
| --- | --- |
| `01-big-o` | Nested loop vs. hash reconciliation timings |
| `02-consistent-hashing` | Keys moved by mod-N vs. a hash ring with virtual nodes |
| `03-queues` | Block, drop newest, drop oldest, spill to disk |
| `04-retry-jitter` | Thundering-herd simulator: no backoff, exponential, full jitter |
| `05-rate-limiting` | Token bucket with a fake clock, real-time pacing, Okta headers |
| `06-caching` | LRU two ways, SIEVE vs. LRU, single-flight |
| `07-graphs` | Kahn's topological sort, cycle detection, BFS impact analysis; `munki_to_json.py` exports a real Munki repo |
| `08-etcd-lab` | 3-node etcd in Docker plus a writer in each language; steps in `LAB.md` |
| `09-bloom-filter` | Measured vs. predicted false-positive rate |
| `10-bisection` | Binary search on the answer; `git bisect run` demo |
| `11-joins` | Jamf vs. Okta drift report with dirty keys; DuckDB SQL in `sql/` |

Each drill folder has `python/`, `powershell/` and `go/` subfolders. Data files live in
the drill's `data/` folder; `11-joins/data/gen_data.py` rebuilds the fake exports.

## Windows notes

- Run the PowerShell scripts with `pwsh`. If drill 4's chart shows garbage characters,
  your console isn't UTF-8; Windows Terminal handles it.
- `check.sh` needs bash (Git Bash or WSL). Without it, run drills one at a time and
  compare with `expected/`.
