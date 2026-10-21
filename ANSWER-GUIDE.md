# Answer guide

> Snapshot of the Answer guide tab of the [Systems Algorithms Field Guide](https://claude.ai/artifact/6jLnAbn3wrNCsYQcNUDt7W) doc, exported 2026-10-21. The drills themselves are in [FIELD-GUIDE.md](FIELD-GUIDE.md).

Reference solutions for every drill in Python, PowerShell 7 and Go. Try each drill yourself first, then compare. Most drills are deterministic: they print the same numbers in all three languages, so your output should match the expected results here exactly.

## How to run

Clone this repo and run any drill from the repo root in whichever language you're practicing. `./check.sh` runs every drill and compares the output with what's below.

| Tool | Version | Used for |
| --- | --- | --- |
| Python | 3.10+ | All drills; `pip install duckdb` for the SQL in drill 11 |
| PowerShell | 7.4+ (`pwsh`) | All drills; not Windows PowerShell 5.1 |
| Go | 1.22+ | All drills; one module at the top folder |
| Docker with Compose | recent | Drill 8 |

```
python3 04-retry-jitter/python/thundering_herd.py
pwsh -File 04-retry-jitter/powershell/Invoke-ThunderingHerd.ps1
go run ./04-retry-jitter/go

./check.sh                 # every drill, all three languages
./check.sh powershell      # one language
DRILL=06 ./check.sh go     # one drill
```

- Lines starting with `~` are timings or other machine-dependent values. Everything else should match this guide exactly.
- The numbers match across languages by design: one seeded random generator (MINSTD) written the same way in each, SHA-256 for hashing, integer math for percentages, ordinal sorting and culture-invariant number formatting. Each of those is a lesson in itself, because it's a place where languages quietly differ.
- Every file opens with a header explaining the approach, and comments mark the language-specific traps.

One example: PowerShell's `-f` operator and `.ToString()` follow the current culture, so under de-DE `'{0:N1}' -f 1234.5` prints `1.234,5`. The scripts pass the invariant culture everywhere. Expect the PowerShell versions of drills 1 and 11 to take about 20 s and 100 s: they time the slow loops on purpose.

## 1. Big-O: nested loop vs. hashtable

Both versions must find the same missing devices: 5, 50 and 300. From 1,000 to 6,000 devices, the nested loop should get about 36 times slower and the hashtable version about 6 times.

**Expected output:**

```
Drill 1: Big-O. Reconcile N Jamf devices against N Okta devices (every 20th missing from Okta).
Missing devices found: n=100 -> 5, n=1,000 -> 50, n=6,000 -> 300 (both methods agree)
```

**Sample timings** (2-core Linux VM, one language at a time):

| Language | Nested, 1,000 | Nested, 6,000 | Nested growth | Hashtable, 6,000 |
| --- | --- | --- | --- | --- |
| Go | 1.8 ms | 64 ms | 36x | 0.17 ms |
| Python | 36 ms | 1.23 s | 34x | 0.60 ms |
| PowerShell (`foreach` + `-ceq`) | 127 ms | 3.9 s | 31x | 2.8 ms |

PowerShell's hashtable version (2.8 ms) beats Go's nested loop (64 ms) by more than 20x: the algorithm matters more than the language. The classic `foreach` + `Where-Object` took 4.2 s at 1,000 devices, 33 times slower than the `-ceq` loop. At 6,000 that projects to about 150 s, so the PowerShell script times the `-ceq` loop and runs `Where-Object` once, at 1,000.

**What a correct answer shows:**

- Compare growth ratios, not raw times. Raw times depend on the machine and language; the ratios (about 36x and 6x) carry over.
- Tiny timings are noisy. Run each size a few times and keep the fastest run.
- An early `break` halves the nested loop's average work but leaves it O(n²).

**Language notes:**

| Language | The fast version | Watch out for |
| --- | --- | --- |
| Python | `{o["serial"]: o for o in okta}`, then `in` | A list-comprehension filter inside a loop rescans the whole list every time |
| PowerShell | A hashtable or `Dictionary[string,object]` built once, then `.ContainsKey()` | `Where-Object` costs about 4 µs per item against 0.12 µs for `foreach` with `-ceq`: both O(n²), 35x apart. `$array += $item` copies the whole array each time, so use `List[T]` |
| Go | `map[string]struct{}` as a set | `time.Since` is fine here; real benchmarks belong in `testing.B` (`go test -bench`) |

**Files:** `01-big-o/python/reconcile_bench.py` · `powershell/Measure-Reconcile.ps1` · `go/main.go`

## 2. Consistent hashing

Growing from 10 to 11 nodes, hash % N moved 90,959 of 100,000 keys. The ring moved 9,064, and every one of them went to the new node.

**Expected output:**

```
Drill 2: consistent hashing. 100,000 keys, cluster grows from 10 to 11 nodes.
hash % N   moved 90,959 keys (91.0%)   expect ~90.9% (10 of 11)
hash ring  moved  9,064 keys (9.1%)    expect ~9.1% (1 of 11)
Every key that moved on the ring went to node-10: yes
Keys per node, 11 nodes x 160 vnodes: min 7,673  max 9,653  (ideal 9,091)
Keys per node, 11 nodes x 1 vnode:    min 272  max 30,914  (why virtual nodes matter)
```

**What a correct answer shows:**

- Mod-N moves about 10 keys in 11, because a key stays put only when h mod 10 equals h mod 11.
- The ring moves about 1 key in 11, and only to the new node. The old nodes never trade keys with each other.
- Virtual nodes are what even out the load: with one point per node, one node owned 30,914 keys and another 272.
- Your numbers match exactly only with the same hash and lookup rule: the first 4 bytes of SHA-256 read big-endian, and "first point at or after the key's hash, wrapping to the start".

**Language notes:**

| Language | Ring lookup | Watch out for |
| --- | --- | --- |
| Python | `bisect.bisect_left` over the sorted positions | Sort points by (position, node name) so any tie breaks the same way everywhere |
| PowerShell | `[Array]::BinarySearch` on a sorted `[long[]]`; a miss returns the bitwise complement of the next index (`-bnot`) | Pass a `[long]` to `[Array]::BinarySearch`: with a plain `25`, PowerShell picks the non-generic overload and it throws. `Sort-Object` compares strings with culture rules, so break ties with `[string]::CompareOrdinal` |
| Go | `sort.Search(n, func(i int) bool { return pos[i] >= h })` | `sha256.Sum256(b)[:4]` won't compile, because the result is an array value; assign it to a variable first. Sorts aren't stable, so compare position, then node name |

**Files:** `02-consistent-hashing/python/hash_ring.py` · `powershell/Test-HashRing.ps1` · `go/main.go`

## 3. Queues and backpressure

Block and spill lose nothing. Both drop strategies lose more than half the items, but drop\_newest serves old data while drop\_oldest serves fresh data.

**Expected output** (the `~` lines are one sample run; thread timing changes them every time):

```
Drill 3: queues and backpressure. 50 items, producer every 20 ms, consumer 60 ms/item, queue holds 5.
block        lost 0, in order: yes
drop_newest  delivered + dropped = 50: yes, ids 0-4 all delivered: yes (the queue still has room when they arrive)
drop_oldest  delivered + dropped = 50: yes, last delivered id: 49 (the newest item always survives)
spill        lost 0, in order: yes
~ strategy     delivered dropped spilled producer(s) total(s) avg age(ms)  delivered ids
~ block               50       0       0        2.67     3.01         308  0-49
~ drop_newest         22      28       0        1.01     1.32         239  0-7,9,12,15,18,21,24,27,30,33,36,39,42,45,48
~ drop_oldest         22      28       0        1.01     1.32         112  0-2,4,7,10,13,16,19,22,25,28,31,34,37,40,43,45-49
~ spill               50       0      42        1.01     3.01         980  0-49
```

**What a correct answer shows:**

- The first five lines hold on every run. The counts and ages vary, and on Windows sleeps round up to the \~15.6 ms timer tick, so expect different numbers there.
- Block moves the slowness upstream: the producer takes about 3 s instead of 1 s.
- Avg age is the real tradeoff. Drop\_newest keeps the oldest items, so what gets processed is stale; drop\_oldest keeps the freshest.
- Spill stays in order only if new items keep going to disk while anything is on disk. That's why 42 of 50 spilled, and why they were about a second old when processed.

**Language notes:**

| Language | Bounded queue | Watch out for |
| --- | --- | --- |
| Python | `queue.Queue(maxsize=5)`: `put` blocks, `put_nowait` raises `queue.Full` | Stop the consumer with a sentinel; spill needs a `Condition`, not just a queue |
| PowerShell | `BlockingCollection[int]` with a capacity: `Add` blocks, `TryAdd` returns `$false` when full | `while ($item = $q.Get())` stops at item 0, because 0 is falsy; compare with `$null`. A class used from several threads needs `[NoRunspaceAffinity()]` (7.4+), and thread jobs don't inherit StrictMode or `$ErrorActionPreference` |
| Go | Buffered channel `make(chan int, 5)`; `select` with `default` makes a send non-blocking | `break` inside a `select` only leaves the `select`, not the loop around it. Close the channel from the sending side to stop the consumer |

**Files:** `03-queues/python/backpressure.py` · `powershell/Test-Backpressure.ps1` · `go/main.go`

## 4. Retry: the thundering herd

Full jitter used the fewest requests (6,062) and kept the spike after recovery near capacity (134/s). Exponential backoff without jitter took 483 s, because all 1,000 clients stayed in lockstep.

**Expected output:**

```
Drill 4: thundering herd. 1,000 clients, server handles 100/s, down for the first 10 s.
strategy     requests per client   peak after recovery   all done at
none           15,500       15.5   1,000/s at t=10             19.0s
exponential     9,500        9.5   1,000/s at t=15            483.0s
full_jitter     6,062        6.1   134/s at t=10               67.4s
Requests per second, first 60 s (each block step is 125/s, rounded up; capacity is 100/s):
none         |████████████▇▆▅▄▄▃▂▁                                        |
exponential  |██ █   █       █               █                            |
full_jitter  |█▆▄▃▃▂▂▂▂▂▂▂▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁ ▁ ▁▁    ▁     ▁ ▁|
exponential sends synchronized waves at t = 0, 1, 3, 7, 15, 31, 63, 123, 183, 243, 303, 363, 423, 483
```

**What a correct answer shows:**

- No backoff: 1,000 requests a second through the outage, then 1,000, 900, 800 … 100 as the server works through them. 15,500 in all.
- Exponential without jitter: identical waves at 0, 1, 3, 7, 15, 31, 63 s, then every 60 s at the cap, with only 100 clients finishing per wave.
- Full jitter matches exactly only if you draw one random number per failure, in event order, and handle same-time events in client-id order.
- The lesson: jitter does the real work. The exponent alone only makes the herd wait longer between stampedes.

**Language notes:** all three run the same event-driven simulation on a min-heap of (time, client id), with no real sleeping.

| Language | Event queue | Watch out for |
| --- | --- | --- |
| Python | `heapq` with `(time, client)` tuples | Tuples compare element by element, which gives the tie-break for free |
| PowerShell | `PriorityQueue[int, ValueTuple[double,int]]` (.NET 6+, so PowerShell 7.2 or later) | `[int]$t` rounds half to even (`[int]3.5` is 4), unlike Python's `int()`, so use `[Math]::Floor` for the per-second bucket. Set `[Console]::OutputEncoding` to UTF-8 for the chart on older Windows consoles |
| Go | `container/heap` with `Less` comparing time, then client id | On arm64, including Apple Silicon Macs, Go compiles `t + r*backoff` to one fused multiply-add, which can change the last bit; `t + float64(r*backoff)` forces separate rounding |

**Files:** `04-retry-jitter/python/thundering_herd.py` (`--csv` writes the per-second load for plotting) · `powershell/Invoke-ThunderingHerd.ps1` · `go/main.go`

## 5. Rate limiting: token bucket

With a rate of 4/s and a burst of 8, the bucket allows 11 requests in the first second and exactly 4 a second after that: 23 of 64.

**Expected output** (part 2 also prints a `~` timing line, about 1.5 s):

```
Drill 5: token bucket rate limiter.
Part 1, fake clock: rate 4/s, burst 8, one request every 1/16 s for 4 s (# allowed, . denied)
  second 0: ##########..#...  11 allowed
  second 1: #...#...#...#...   4 allowed
  second 2: #...#...#...#...   4 allowed
  second 3: #...#...#...#...   4 allowed
  total allowed: 23 of 64 (burst 8 + about 4/s x 4 s)
Part 2, real clock: 20 calls at 10/s with burst 5
Part 3, Okta headers: 40 of 600 calls left, window resets in 12 s -> pause 12 s
```

**What a correct answer shows:**

- The first second allows the burst (8) plus what refills during that second (3).
- Passing the time in as an argument is what makes the test exact to the request. A bucket that reads the clock itself can't be tested this way.
- When a request is denied, the wait is (1 − tokens) / rate. Sleeping that long is how a bulk script paces itself instead of eating 429s.
- Measure elapsed time with a monotonic clock, never wall-clock time, which can jump.

**Language notes:**

| Language | Clock | Watch out for |
| --- | --- | --- |
| Python | `time.monotonic()` | `time.time()` can jump when NTP corrects the clock |
| PowerShell | `[System.Diagnostics.Stopwatch]` | `Start-Sleep` on Windows rounds up to the \~15.6 ms timer tick. With `Invoke-RestMethod -ResponseHeadersVariable h`, each header is a `string[]`, so read `$h['X-Rate-Limit-Remaining'][0]` |
| Go | `time.Now()` and `time.Since` (Go's monotonic reading is built in) | Put a `sync.Mutex` in the bucket if goroutines share it; in production, use `golang.org/x/time/rate` |

**Files:** `05-rate-limiting/python/token_bucket.py` · `powershell/Test-TokenBucket.ps1` · `go/main.go`

## 6. Caching: LRU, SIEVE and single-flight

SIEVE beat LRU by 11.07 points with 100 entries and 7.41 points with 1,000, because one-hit wonders stop pushing popular items out.

**Expected output:**

```
Drill 6: caching. 100,000 requests: 70% Zipf over 10,000 objects, 30% one-hit wonders.
cache size      LRU (library)   LRU (hand-built)    SIEVE  SIEVE vs LRU
       100             23.47%             23.47%   34.54%  +11.07 points
     1,000             41.20%             41.20%   48.61%  +7.41 points
Both LRU implementations agree: yes
without single-flight: 10 callers -> 10 backend calls, all got the same value: yes
with single-flight:    10 callers -> 1 backend call, all got the same value: yes
```

**What a correct answer shows:**

- Your two LRUs agree exactly. If they don't, one has a bug, usually in unlinking a node.
- SIEVE does no list surgery on a hit; it only sets a bit. That's also why it scales better across threads than LRU.
- SIEVE's hand keeps its place between evictions. Restarting it from the tail every time is an easy mistake, and it changes the results.
- Single-flight turns 10 simultaneous misses into 1 backend call, and every caller gets the same value.
- The hit rates match exactly only if your trace matches: the same MINSTD draws, Zipf weights of 1/rank, and "first index whose running total exceeds the draw".

**Language notes:**

| Language | LRU and single-flight | Watch out for |
| --- | --- | --- |
| Python | `OrderedDict.move_to_end` / `popitem(last=False)`; a `Future` per in-flight key | Release the lock before calling the backend, or single-flight serializes everything |
| PowerShell | Library LRU on `OrderedDictionary` (the type behind `[ordered]@{}`) plus a hand-built list; single-flight via `ConcurrentDictionary.GetOrAdd` and a `TaskCompletionSource` | `OrderedDictionary.Remove` is O(n), and an `[int]` index means position, not key. `ForEach-Object -Parallel` runs 5 at a time by default, which deadlocks a 10-caller start barrier |
| Go | `container/list` plus a map; single-flight with a mutex, a map of calls and `sync.WaitGroup` | `golang.org/x/sync/singleflight` is the production version of exactly this |

**Files:** `06-caching/python/caches.py` · `powershell/Test-Caches.ps1` · `go/main.go`

## 7. Graphs: install order and cycles

All 18 packages get a valid install order. One bad requirement leaves 8 packages stuck, and DFS names the 2-package cycle behind them.

**Expected output:**

```
Drill 7: graphs. 18 packages from deps.json.
All requirements refer to known packages: yes
Install order (Kahn's algorithm):
   1. AdobeAcrobatReader
   2. GoogleChrome
   3. ChromeEnterprisePolicy
   4. MicrosoftAutoUpdate
   5. CompanyPortal
   6. MicrosoftLicensingHelper
   7. MicrosoftExcel
   8. MicrosoftOutlook
   9. MicrosoftTeams
  10. MicrosoftWord
  11. NetworkExtensionProfile
  12. MicrosoftDefender
  13. DefenderOnboarding
  14. OktaVerify
  15. DeviceAssuranceProfile
  16. Slack
  17. VPNClient
  18. Zoom
Every package comes after everything it requires: yes
Installing DefenderOnboarding pulls in (BFS over requires):
  level 1: MicrosoftDefender
  level 2: MicrosoftAutoUpdate, NetworkExtensionProfile
If MicrosoftAutoUpdate breaks, these are affected (BFS over reversed edges):
  level 1: CompanyPortal, MicrosoftDefender, MicrosoftExcel, MicrosoftOutlook, MicrosoftTeams, MicrosoftWord
  level 2: DefenderOnboarding
Added a cycle: MicrosoftAutoUpdate now requires MicrosoftWord.
Kahn's algorithm placed 10 of 18 packages. Stuck (8): CompanyPortal, DefenderOnboarding, MicrosoftAutoUpdate, MicrosoftDefender, MicrosoftExcel, MicrosoftOutlook, MicrosoftTeams, MicrosoftWord
DFS found the cycle: MicrosoftAutoUpdate -> MicrosoftWord -> MicrosoftAutoUpdate
```

**What a correct answer shows:**

- Any order where each package comes after its requirements is valid. You'll match this exact order only if the ready set always hands out the alphabetically first package (a min-heap).
- "Stuck" is the cycle plus everything downstream of it: 8 packages, not just the 2 in the cycle.
- DFS needs three colors. With two, you can't tell an edge back into the current path (a cycle) from an edge into a branch you already finished (harmless).
- Reversing the edges turns "what does this need?" into "what breaks if this breaks?", the same BFS either way.
- Run it on your real catalog: `munki_to_json.py /path/to/repo/pkgsinfo > my_deps.json`, then pass that file in. If your repo has a cycle, the program stops and names it.

**Language notes:**

| Language | Ready set | Watch out for |
| --- | --- | --- |
| Python | `heapq` of package names | `heapq` is a min-heap only; push tuples or negate values for anything else |
| PowerShell | `SortedSet[string]` with `[StringComparer]::Ordinal` | `ConvertFrom-Json -AsHashtable` keys are case-sensitive, but `@{}` and `[ordered]@{}` ignore case. `Sort-Object` follows culture rules; use ordinal comparers when the order must match |
| Go | `container/heap` of strings | Map iteration order is random by design; sort the keys whenever output order matters |

**Files:** `07-graphs/python/depgraph.py` · `python/munki_to_json.py` · `data/deps.json` · `powershell/Get-InstallOrder.ps1` · `go/main.go`

## 8. Distributed systems: etcd lab

A crashed leader cost about 2 seconds of failed writes. A gracefully stopped leader cost none. Losing two of three nodes stopped every write until one came back. These are real results from etcd 3.5.17 in Docker; `08-etcd-lab/LAB.md` has the full step-by-step.

| Step | What the writer shows | Why |
| --- | --- | --- |
| `docker kill` the leader | About 2 s of FAIL lines, then OK under a new Raft term | Followers wait out the election timeout after missed heartbeats, then elect a new leader |
| Kill one of the two survivors | Every write fails; a serializable read still returns the last value | One node of three is not a majority, so nothing commits; serializable reads use local data |
| Start a stopped node | Writes resume in about 0.5 s, under another new term | Majority is back; returning nodes catch up from the leader's log |
| `docker stop` the leader (clean) | No failures at all; the term still goes up | On clean shutdown the leader hands leadership to a caught-up follower before exiting |

**Expected output** when the leader crashes:

```
18:37:32.751  put lab/counter=17   OK    via localhost:2379     11 ms  term 2  rev 18
18:37:34.997  put lab/counter=18   FAIL  localhost:2379 timed out; localhost:22379 timed out; localhost:32379 connection refused
18:37:35.003  put lab/counter=19   OK    via localhost:2379      2 ms  term 3  rev 19
```

Without quorum, `etcdctl put` and a default `get` both fail with `Error: context deadline exceeded`, while `etcdctl get --consistency=s` still answers from local data.

**What a correct answer shows:**

- The term goes up on every leadership change, including the graceful one (usually by 1; a split vote adds more).
- Writes fail during quorum loss even though the surviving node is up and answering.
- After recovery, all three nodes report the same `RAFT INDEX` in the status table.

**Language notes:** the writers talk to etcd's HTTP/JSON gateway, so no client library is needed in any language.

| Language | Approach | Watch out for |
| --- | --- | --- |
| Python | `urllib.request` + `json`, keys and values base64-encoded | 64-bit fields like `raft_term` arrive as JSON strings |
| PowerShell | One reused `HttpClient` with a 1 s timeout | `Invoke-RestMethod` only takes whole-second timeouts; .NET errors arrive wrapped in `MethodInvocationException`; `pwsh -File x.ps1 -Endpoint a,b` passes one string, not an array |
| Go | `net/http` client with `Timeout`; `errors.As` for timeouts, `errors.Is(err, syscall.ECONNREFUSED)` for refused | Real code should use `go.etcd.io/etcd/client/v3`, which handles failover for you |

**Files:** `08-etcd-lab/docker-compose.yml` · `LAB.md` · `python/etcd_writer.py` · `powershell/Watch-EtcdWrites.ps1` · `go/main.go`

## 9. Bloom filter

Sized for 100,000 items at 1%, the filter took 117 KiB and wrongly said yes to 992 of 100,000 ids it never saw: 0.992%, against 1.004% predicted. Overfilled to 200,000 items, the rate jumped to 15.8%.

**Expected output:**

```
Drill 9: Bloom filter sized for 100,000 items at 1% false positives.
m = 958,506 bits (117 KiB), k = 7 hash functions
False negatives on the 100,000 inserted ids: 0 (must be 0)
False positives on 100,000 ids never inserted: 992 = 0.992%   predicted 1.004%
Overfilled to 200,000 items: 15,848 = 15.848%   predicted 15.745%
```

**What a correct answer shows:**

- Zero false negatives, always. A single one means a bug, usually in the bit indexing.
- The measured rate lands within a few tenths of a percent of the formula.
- Doubling the load multiplied false positives by 16. Size the filter for your peak, not today's count.
- Your exact counts match only with the same hashing: bytes 0–7 and 8–15 of the SHA-256 digest, each read as a big-endian 64-bit number and reduced mod m before combining.

**Language notes:**

| Language | Bit array and hashing | Watch out for |
| --- | --- | --- |
| Python | A `bytearray`; `int.from_bytes(digest[:8], "big")` | Python integers never overflow, so it's easy to write math that silently breaks in other languages; reduce mod m first |
| PowerShell | `[System.Buffers.Binary.BinaryPrimitives]::ReadUInt64BigEndian` on the digest | `[BitConverter]::ToUInt64` reads little-endian on Intel. `[uint64]::MaxValue + 1` silently becomes a `[double]`, while `[uint64] % [long]` stays exact |
| Go | `binary.BigEndian.Uint64`; a `[]uint64` bitset | `math.Round` rounds halves away from zero while Python's `round` rounds to even; `math.RoundToEven` matches it |

**Files:** `09-bloom-filter/python/bloom.py` · `powershell/Test-BloomFilter.ps1` · `go/main.go`

## 10. Bisection

Commit 337 was found in 9 tests out of 500, and the largest batch the API accepts (437) in 14 probes of 1 to 10,000. The git demo finds the bad change in 7 test runs over 100 commits.

**Expected output:**

```
Drill 10: binary search and bisection.
Part 1: first bad commit among 500 is 337, found in 9 tests (log2(500) is about 9)
  tested: 250, 375, 313, 344, 329, 337, 333, 335, 336
Part 2: largest batch the API accepts is 437, found in 14 probes of the range 1..10,000
  probed: 5001, 2501, 1251, 626, 313, 470, 392, 431, 451, 441, 436, 439, 438, 437
```

The git demo (`bash 10-bisection/git/bisect_demo.sh`) ends with:

```
First bad commit message: Change 63: tune batch size
Steps: 7 test runs for 100 commits (log2(100) is about 7)
```

**What a correct answer shows:**

- Your probe sequence matches exactly. If it doesn't, your midpoint or your boundary update differs.
- One convention, every time: half-open \[lo, hi), `hi = mid` when the test is true, `lo = mid + 1` when it's false, loop while `lo < hi`.
- `lo + (hi - lo) / 2`, not `(lo + hi) / 2`, which overflows in fixed-width integers.
- "Largest that works" is "first that fails, minus one". Most binary-search-on-the-answer problems reduce to that one function.
- `git bisect run` exit codes: 0 means good, 125 means skip this commit, any other 1–127 means bad. `test.sh` and `test.ps1` show both shells.

**Language notes:**

| Language | Midpoint | Watch out for |
| --- | --- | --- |
| Python | `lo + (hi - lo) // 2` | `/` returns a float in Python 3; `//` is integer division |
| PowerShell | `$lo + (($hi - $lo) -shr 1)` | `/` on two integers returns a double, and `[int]` casts round to even, so `[int](7/2)` is 4, not 3 |
| Go | `lo + (hi-lo)/2` | `sort.Search` is this exact function in the standard library |

**Files:** `10-bisection/python/bisect_tools.py` · `powershell/Find-FirstBad.ps1` · `go/main.go` · `git/bisect_demo.sh` · `git/test.sh` · `git/test.ps1`

## 11. Joins: the drift report

275 Macs are missing from Okta Verify. A join on raw serials would have reported 447: 172 false alarms from lowercase and padded serials.

**Expected output:**

```
Drill 11: Jamf vs. Okta Verify drift report.
Rows: Jamf 6,012, Okta 5,869
Blank serials skipped: Jamf 2, Okta 3
Serials listed more than once (after normalizing): Jamf 10, Okta 41
Devices in both: 5,725
In Jamf, missing from Okta Verify: 275
In Okta, not in Jamf: 100
Joining on raw serials would report 447 missing: 172 false alarms from case and whitespace
A plain inner join returns 5,775 rows for 5,725 devices (+50 from duplicate keys)
Wrote drift_report.csv (6,100 rows)
```

The DuckDB version (`sql/drift.sql`) returns the same numbers straight from the CSV and JSON files.

**Sample timings** for the anti-join alone (2-core Linux VM):

| Language | Nested loop | Hash join |
| --- | --- | --- |
| Go | 0.07 s | 0.38 ms |
| Python | 0.67 s | 0.82 ms |
| PowerShell (`foreach` + `Where-Object`) | 99.6 s | 8.2 ms |

**What a correct answer shows:**

- Normalize both sides (trim, then uppercase) and drop blank serials before joining. Blank must never match blank.
- Count duplicates before you join: 10 in Jamf, 41 in Okta. A plain inner join returns 5,775 rows for 5,725 devices.
- `drift_report.csv` comes out byte-for-byte identical in all three languages, sorted by serial.
- PowerShell trap: default hashtables and `-eq` ignore case, so a PowerShell join quietly "works" on dirty keys and hides the very problem you're looking for.

**Language notes:**

| Language | Join | Watch out for |
| --- | --- | --- |
| Python | `set` intersection and difference; `Counter` for duplicates | `csv.writer` defaults to `\r\n` line endings; pass `lineterminator="\n"` when bytes matter |
| PowerShell | `HashSet[string]` with `[StringComparer]::Ordinal` | With a default `@{}` or `-notin`, the raw join reports 341 missing instead of 447: the lowercase false alarms vanish, so you never see the problem. `Export-Csv` writes CRLF on Windows; write lines yourself when the bytes must match |
| Go | `map[string]int` of counts per key | JSON `null` decodes to `""` in a string field, which is what you want here |
| SQL (DuckDB) | `ANTI JOIN` for "in A, not in B" | `trim()` strips spaces only, not tabs |

**Files:** `11-joins/python/drift_report.py` · `sql/drift.sql` · `sql/run_sql.py` · `powershell/Get-DriftReport.ps1` · `go/main.go` · `data/gen_data.py`
