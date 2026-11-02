# Systems Algorithms Field Guide

> Snapshot of the [Systems Algorithms Field Guide](https://claude.ai/artifact/6jLnAbn3wrNCsYQcNUDt7W) doc, exported 2026-10-21. The doc is the editable original; re-export it here when it changes. The companion [Answer guide](ANSWER-GUIDE.md) has the expected output for every drill.

Oct 13, 2026 · @Chris

## How to use this guide

Expertise here means you can predict how a system fails before it does. Typing the algorithm from memory is not the goal. Each section gives the core idea, an example from fleet and infra work, the failure mode to watch for, and a drill.

Three levels to aim for on every topic:

1. **Recognize**: you spot the pattern in a design doc or an incident timeline.
2. **Reason**: you can whiteboard the tradeoffs and pick the right variant without looking anything up.
3. **Build**: you have implemented it once by hand, measured it, and broken it on purpose. After that, let AI write the production version and review it.

Do the drills in Python, PowerShell or Go. Reference solutions in all three, with expected output, are in [ANSWER-GUIDE.md](ANSWER-GUIDE.md).

## Big-O intuition

Big-O tells you how cost grows as input grows. At 6,000 devices, O(n) is instant, O(n log n) is fine, and O(n²) is 36 million operations.

| Complexity | Fleet example | At n = 6,000 |
| --- | --- | --- |
| O(1) | Look up a serial in a hash map / dict | 1 step |
| O(log n) | Binary search a sorted list of check-in times | \~13 steps |
| O(n) | One pass over all devices to count OS versions | 6,000 steps |
| O(n log n) | Sort devices by last check-in | \~75,000 steps |
| O(n²) | For each device, scan the full list to find duplicates | 36,000,000 steps |
|  |  |  |

**Real example:** a script reconciles Jamf inventory against Okta Verify device records. The naive version loops over Jamf and, for each device, searches the Okta list with `Where-Object`. That is O(n²). Build a hashtable keyed by serial first, then do one pass: O(n).

**Hidden traps:** an API call inside a loop (n network round trips), string concatenation in a loop in some languages, and `array += item` in PowerShell, which copies the whole array every time. Use `[System.Collections.Generic.List[object]]` instead.

**Drill:** take one of your existing fleet scripts and label the complexity of every loop. Then time it at 100, 1,000, and 6,000 items and see if the curve matches your prediction.

## Hashing and consistent hashing

Plain hashing (`hash(key) % N`) spreads keys evenly across N servers. When N changes, almost every key moves. Consistent hashing fixes that: only about 1/N of keys move when a node joins or leaves.

**How it works:** place servers on a ring at hashed positions. A key goes to the first server clockwise from its own hash. Each server gets many virtual nodes (100–200) so load stays even.

**Where you meet it:**

- **Mimir and Prometheus-style systems** use a hash ring to decide which ingester owns which time series. That's why adding an ingester doesn't reshuffle everything.
- **Load balancers** (Envoy ring hash, Maglev, HAProxy `balance uri` with consistent hashing) keep a client pinned to the same backend for cache locality.
- **Munki or package caches** behind several CDN or cache nodes: consistent hashing on the package URL keeps each package cached on one node instead of all of them.

**Failure modes:** hot keys (one huge tenant still lands on one node), too few virtual nodes (uneven load), and the rebalance storm when a node dies and its neighbor inherits all its traffic at once.

**Variants worth knowing by name:** rendezvous (highest random weight) hashing, which is simpler and needs no ring; jump consistent hash, which needs no memory but only supports adding nodes at the end.

**Drill:** in Python, implement `hash % N` and a ring with virtual nodes. Assign 100,000 keys across 10 nodes, add an 11th, and count how many keys move in each. Expect about 91% vs. about 9%.

## Queues and backpressure

A queue absorbs bursts between a fast producer and a slower consumer. Backpressure is how the consumer tells the producer to slow down when the queue fills. A queue without a bound or backpressure doesn't remove an overload. It delays it and then fails with an out-of-memory error.

**Little's Law** is the one formula to memorize: items in the system = arrival rate × time each item spends inside. If 200 events/sec arrive and each takes 0.5 s, about 100 are in flight. If the consumer slows to 2 s, you need room for 400 or something must give.

**When the queue is full, you have exactly four choices:**

1. **Block** the producer (backpressure). Safe, but can stall upstream.
2. **Drop newest** (reject new work). Good for metrics where fresh data matters less than staying up.
3. **Drop oldest.** Good when only the latest state matters, like device status.
4. **Spill to disk.** Durable, but slower and finite.

**Where you meet it:** Vector's sink buffers have exactly these settings: `buffer.type = memory | disk`, `max_events` or `max_size`, and `when_full = block | drop_newest`. Picking them is a backpressure decision. GitHub Actions job queues behind your self-hosted Windows runners are another queue: too few runners and wait time grows without bound.

**Failure modes:** unbounded in-memory queues, retry loops that re-enqueue failures forever (add a dead-letter queue), and head-of-line blocking where one slow item holds up everything behind it.

**Drill:** write a producer/consumer with a bounded queue in Python (`queue.Queue(maxsize=100)`). Make the consumer slower than the producer and watch each of the four full-queue strategies behave.

## Retry, exponential backoff, and jitter

Retries without backoff and jitter turn a short outage into a long one. When a service blips, every client retries at the same moment, and the synchronized wave knocks it down again. This is the thundering herd.

**The formula ("full jitter"):**

```latex
\text{sleep} = \text{random}(0,\ \min(\text{cap},\ \text{base} \cdot 2^{\text{attempt}}))
```

With base 1 s and cap 60 s, attempt 5 waits a random time between 0 and 32 s. The randomness spreads clients out, and that spreading matters more than the exponential part.

**Fleet example:** an Okta or Jamf API hiccup at 9:00 AM. Six thousand Macs whose LaunchDaemon retries every 30 seconds hit the API in lockstep forever. With full jitter they smear across the window and the API recovers. The same applies to Munki and Intune check-in schedules: randomize the initial check-in offset per device, not just the retry.

**Rules to know cold:**

- Retry only **idempotent** operations, or make them idempotent with a request ID (see Distributed systems).
- Retry only **retryable** errors: 429, 502, 503, 504, timeouts. Never a 400 or 403.
- Honor `Retry-After` headers when the server sends them.
- Set a **max attempts** or **deadline**, and retry at **one layer only**. Three layers each retrying 3 times is 27 calls per user action.
- Pair retries with a **circuit breaker**: after N failures, stop calling for a cooldown period.

**Drill:** simulate 1,000 clients hitting a server that can handle 100 req/s and goes down for 10 s. Plot load over time with no backoff, exponential only, and full jitter.

## Rate limiting

Rate limiters protect a service by capping how many requests a client can make. Token bucket is the default answer in almost every real system and interview.

| Algorithm | How it works | Allows bursts? | Typical use |
| --- | --- | --- | --- |
| Token bucket | Bucket holds up to B tokens, refills at R/sec; each request spends one | Yes, up to B | API gateways, AWS, Stripe, most SaaS APIs |
| Leaky bucket | Requests drain out at a fixed rate; overflow is dropped | No, output is smooth | Traffic shaping, network egress |
| Fixed window | Count per clock minute; reset at :00 | Yes, 2× at window edges | Simple quotas |
| Sliding window log | Store each request timestamp; count those in the last 60 s | No | Exact limits, small scale (memory heavy) |
| Sliding window counter | Weighted blend of current and previous window counts | Slightly | Redis-based limiters at scale |

**Fleet example:** the Jamf Pro API and Okta APIs both enforce limits. A bulk script that updates 6,000 device records needs a client-side token bucket so it stays under the limit rather than eating 429s. Okta returns `X-Rate-Limit-Remaining` and `X-Rate-Limit-Reset`; a good client reads them and paces itself.

**Distributed twist:** with several servers, each one counting locally lets a client get N× the limit. Fixes are a shared counter (Redis with an atomic Lua script), or splitting the limit across nodes and accepting some slack.

**Drill:** implement a token bucket in 20 lines (track `tokens` and `last_refill`, refill lazily on each call). Wrap your next bulk API script with it.

## Caching and eviction

A cache trades freshness for speed. The two hard parts are deciding what to throw out when it's full (eviction) and knowing when stored data is wrong (invalidation).

**Eviction policies:**

- **LRU (least recently used):** evict whatever hasn't been touched longest. Hash map + doubly linked list gives O(1) get and put. This is the one to be able to sketch.
- **LFU (least frequently used):** evict the least-popular item. Better for stable hot sets, worse when popularity shifts.
- **TTL:** every entry expires after a fixed time. Simple, and often all you need.
- **Modern variants:** W-TinyLFU (used by Caffeine) and the FIFO-based S3-FIFO and SIEVE beat plain LRU on real workloads. See the FIFO comeback below.

**The FIFO comeback (2023–2024):** a study of 6,594 production cache traces from 14 datasets found that most cached objects are requested once and never again before eviction. Algorithms that kick those out fast win, and plain FIFO queues turn out to do it better than LRU.

- **S3-FIFO** (SOSP 2023): three FIFO queues. New objects land in a small queue (about 10% of space), and only those hit again there get promoted to the main queue. A ghost queue remembers recently evicted keys so returning objects skip probation.
- **SIEVE** (NSDI 2024): one FIFO queue, a "visited" bit per object, and a moving hand that evicts the first unvisited object it passes, clearing bits as it goes. Simpler than LRU.
- **Results:** S3-FIFO had the lowest mean miss ratio on 10 of the 14 datasets and about 6× the throughput of optimized LRU at 16 threads.
- **Adoption:** in production at Google, VMware, and Redpanda, with 20+ open-source libraries in Go, Rust, Python, and C++.

**Why FIFO scales better:** an LRU hit must move the item to the front of a shared list, which needs a lock. A FIFO hit only flips a bit. Under high concurrency, that lock is the bottleneck.

Sources: [S3-FIFO design post](https://blog.junchengyang.com/system/cache/2023/08/01/s3fifo) · [S3-FIFO results talk](https://alluxio.io/videos/data-infra-meetup-fifo-queues-are-all-you-need-for-cache-eviction) · [adoption](https://cc.gatech.edu/events/2024/04/16/scs-faculty-candidate-seminar-juncheng-yang)

**Write strategies:** cache-aside (app reads cache, falls back to DB, fills cache: the most common), write-through (write cache and DB together), write-back (write cache, flush later: fast but can lose data).

**Fleet example:** a Munki caching server or a Jamf distribution point is a cache for packages. Package files are immutable when versioned, so they can be cached forever. The catalog and manifest files change, so they need short TTLs or explicit invalidation. That split, immutable content vs. mutable index, is a pattern worth recognizing everywhere.

**Cache stampede:** a popular key expires and 1,000 requests miss at once, all hitting the backend. Fixes:

1. **Request coalescing / single-flight:** only one request rebuilds; the rest wait for it.
2. **Jittered TTLs:** don't let a batch of keys expire at the same second.
3. **Stale-while-revalidate:** serve the old value while refreshing in the background.

**Drill:** implement an LRU cache with `OrderedDict` in Python, then again with your own linked list. Then write a single-flight wrapper. Bonus: implement SIEVE in about 30 lines and compare its hit rate to your LRU on the same request trace.

## Graph algorithms

Anything with dependencies is a graph: packages, Terraform resources, CI jobs, network hops, group memberships. Four operations cover almost all systems work.

- **BFS (breadth-first search):** explore level by level. Finds the shortest path in unweighted graphs. Example: "what's the fewest hops from this device to the internet through our proxy chain?"
- **DFS (depth-first search):** go deep first. Basis for cycle detection and topological sort. Example: walking nested Okta or Entra group memberships to find every group a user effectively belongs to.
- **Topological sort:** order nodes so every dependency comes before what needs it. Example: Munki `requires` and `update_for` relationships, Terraform's apply order, GitHub Actions `needs:` jobs, systemd unit ordering. Kahn's algorithm (repeatedly take nodes with no remaining incoming edges) is the one to know.
- **Cycle detection:** if topo sort can't finish, there's a cycle. Example: package A requires B, B requires A, and the install hangs or errors. DFS with three colors (unvisited, in-progress, done) finds it; an edge back to an in-progress node is the cycle.

**Bonus, know by name:** Dijkstra (shortest path with weights, as in routing protocols like OSPF), union-find (fast "are these in the same group?", used in clustering and network partition detection).

**IAM angle:** nested group expansion is a graph walk, and a cycle in group nesting is a real bug class. Your IAM background makes this a strong interview story.

**Drill:** export Munki pkginfo `requires` fields (or a Terraform graph with `terraform graph`), build the graph in Python, topo-sort it with Kahn's algorithm, and add an intentional cycle to see detection work.

## Distributed systems

This is the section with the most interview weight and the most incident value. The core truth: networks drop and delay messages, clocks disagree, and machines pause. Every technique below is a way to stay correct anyway.

**Idempotency:** doing an operation twice has the same effect as once. Retries are only safe on idempotent operations. Make writes idempotent with a client-generated request ID the server remembers. Example: an Intune or Jamf script that "adds device to group" should check membership first, so a retried run doesn't fail or duplicate.

**Quorums:** with N replicas, require W acknowledgments to write and R to read. If R + W > N, every read overlaps the latest write. N = 3, W = 2, R = 2 is the classic. This is how etcd, Cassandra, and Mimir's replication factor work.

**Consensus (Raft):** a cluster agrees on one ordered log despite failures.

1. Nodes elect a **leader** by majority vote; terms number each election.
2. The leader appends entries and replicates them; an entry is **committed** once a majority has it.
3. If the leader dies, followers time out (randomized timeouts, jitter again) and elect a new one.
4. A 5-node cluster tolerates 2 failures; a 4-node cluster also tolerates only 1, so use odd sizes.

You don't need to implement Raft. You need to know why etcd (under Kubernetes) loses writes when it loses quorum, and why split brain is prevented by majority rule.

**CAP and PACELC:** during a network **P**artition, choose **C**onsistency (refuse some requests) or **A**vailability (answer, maybe stale). PACELC adds: **E**lse, in normal operation, trade **L**atency against **C**onsistency. Most real choices are the ELC part.

**Clocks:** wall clocks drift and jump (NTP corrections, VM pauses). Never use wall-clock timestamps to order events across machines. "Last write wins" silently drops data when clocks skew. Use logical clocks (Lamport), version vectors, or a single sequencer. Practical example: comparing device `last_check_in` from Jamf vs. Okta can mislead if either side's clock or time zone is off.

**Delivery semantics:** at-most-once, at-least-once, exactly-once. "Exactly-once" in practice means at-least-once delivery plus idempotent processing.

**Leases and fencing tokens:** a lock with an expiry. If a holder pauses past its lease, it may wake up thinking it still owns the lock. A fencing token (a number that increases with each grant, checked by the storage layer) blocks the stale holder.

**Drill:** run a 3-node etcd cluster in Docker on quasarlab. Kill the leader and watch election. Kill two nodes and watch writes fail. That 30-minute exercise teaches more than a week of reading.

## Probabilistic structures

These trade a small, known error rate for huge memory savings. They show up constantly in observability and storage systems.

**Bloom filter:** answers "is X in the set?" with either "definitely not" or "probably yes." A bit array plus k hash functions; insert sets k bits, lookup checks them. No false negatives, tunable false positives (about 10 bits per item gives roughly 1%).

- Example: storage engines (Cassandra, RocksDB, and the Prometheus/Mimir ecosystem's index lookups) check a Bloom filter before reading a block from disk, skipping blocks that can't contain the key.
- Fleet example: a fast "have we seen this file hash before?" check against millions of known-good binaries, before a slower authoritative lookup.

**HyperLogLog:** estimates how many *distinct* items you've seen using about 12 KB, whether there are a thousand or a billion. Error is around 0.8%.

- Example: counting unique devices or users per day across a log stream without storing every ID. Redis `PFCOUNT` and many observability backends use it.

**Count-Min Sketch:** estimates how often each item appears; good for finding heavy hitters (the noisiest device, the top error message) in a stream.

**Why they matter for cardinality:** high-cardinality labels (a `device_serial` label on every metric in Vector → Mimir) are the classic way to blow up a metrics backend. Knowing these structures helps you reason about what the backend can and can't count cheaply.

**Drill:** implement a Bloom filter in Python with `hashlib`, insert 100,000 items, and measure the false-positive rate against the formula.

## Binary search and bisection debugging

Binary search halves the search space each step, so it finds one item among a million in about 20 steps. Its most valuable use in systems work isn't searching arrays. It's finding *when* or *where* something broke.

**Bisection as a debugging method:**

- **Commits:** `git bisect` finds the commit that broke a build in log₂(n) tests. 500 commits takes about 9 tests.
- **Config:** a 400-line profile or `config.toml` breaks something. Remove half, test, repeat.
- **Fleet rollouts:** a package update breaks some Macs. Split the affected group by OS version, then model, then other installed software, halving each time.
- **Time ranges:** narrow down when a metric went bad by halving the window in Grafana.

**Binary search on the answer:** when you can test "does value X work?" and the answer flips once, binary search the value. Example: the largest batch size the Jamf API accepts before timeouts, or the lowest runner count that keeps the CI queue under 5 minutes.

**The classic bug:** off-by-one errors and the infinite loop when `lo` and `hi` don't converge. Pick one convention (half-open `[lo, hi)`) and always use it.

**Drill:** next time something breaks and you don't know why, write down your bisection plan before changing anything. Practice `git bisect run` with a test script on any repo.

## Joins and data manipulation

Most reconciliation work, like Jamf vs. Okta or Intune vs. Entra, is a join followed by a set difference. Pick the right join algorithm and clean your keys first, and a 30-minute script becomes a 2-second one that's also correct.

**Join algorithms:**

| Algorithm | How it works | Cost | Use when |
| --- | --- | --- | --- |
| Nested loop | For each row in A, scan all of B | O(n × m) | Never on purpose; it's the naive `foreach` + `Where-Object` |
| Hash join | Build a hash map from the smaller side, stream the larger side through it | O(n + m) | Default for unsorted data that fits in memory |
| Sort-merge join | Sort both sides by key, walk them together | O(n log n + m log m), or O(n + m) if already sorted | Data already sorted, or too big for memory (pairs with external sort) |

**Join types, framed as fleet questions:**

- **Inner:** devices in both Jamf and Okta. The healthy set.
- **Left:** every Jamf device, with Okta data where it exists. The base for a compliance report.
- **Anti-join (left join where right is null):** in Jamf but missing from Okta Verify. This is usually the question you actually care about.
- **Full outer:** everything from both sides, flagged by which side it came from. The full drift report.

**The duplicate-key trap:** if a serial appears twice on either side, an inner join multiplies rows (2 × 3 = 6). Reports silently inflate. Always check key uniqueness before joining: `df['serial'].duplicated().sum()` or `Group-Object serial | Where-Object Count -gt 1`.

**Set operations:** union (all devices anywhere), intersection (in both), difference (in A not B). Python `set` operations or SQL `EXCEPT` answer most "what drifted?" questions in one line.

**Group-by and aggregation:** "count devices by OS version per model" is a hash aggregation: one pass, a hash map of group key → running total. Sort-based aggregation is the fallback for huge data. Watch for nulls forming their own silent group.

**Key normalization, where the real bugs live:**

- Serial numbers: casing, leading and trailing whitespace, Windows serials of `To be filled by O.E.M.` or `0` on VMs and some hardware.
- MAC addresses: `AA:BB:CC`, `aa-bb-cc`, and `aabbcc` are the same device.
- Usernames vs. emails: `chris` vs. `chris@okta.com` vs. different casing.
- Timestamps: mixed time zones and formats; normalize to UTC ISO 8601 before comparing.

Normalize into a canonical key column on both sides, join on that, and keep the originals for display.

**When it doesn't fit in memory:** external sort (sort chunks, write them to disk, merge), then sort-merge join. Or stream in chunks and aggregate. In practice, DuckDB does this for you automatically.

**Tools to reach for:**

- **DuckDB:** SQL directly over CSV, JSON, and Parquet files, no server. `SELECT ... FROM 'jamf.csv' j ANTI JOIN 'okta.json' o ON ...`. The best ad-hoc reconciliation tool for this kind of work.
- **Polars or pandas:** DataFrames in Python. Polars is faster and handles larger-than-memory data with its lazy mode; pandas has more examples online.
- **PowerShell:** hashtables for joins, `Group-Object` for aggregation, `Compare-Object` for set difference (fine for small sets; slow at scale).

**Drill:** export Jamf computers and Okta Verify devices to CSV or JSON. Produce the full drift report three ways: a nested-loop PowerShell script, a hashtable version, and a DuckDB query. Time each, then deliberately add duplicate serials and messy casing and see which version catches them.

## Safe to forget (mostly)

These are worth recognizing by name but not memorizing. Your language's standard library or AI handles them, and they rarely decide a systems outcome. The exception is a classic coding interview, which may still ask for them.

| Topic | What it is, in one line | Why you can let it go | Interview risk |
| --- | --- | --- | --- |
| Hand-written sorts (quicksort, mergesort, heapsort) | Ways to order a list in O(n log n) | `sorted()` and `Sort-Object` are faster and correct; just know sorting is O(n log n) and mergesort is stable | Medium: sometimes asked to implement mergesort |
| Balanced tree internals (red-black, AVL rotations) | Self-balancing binary search trees | Know that sorted maps and DB indexes give O(log n) lookups; the rotations never come up | Low |
| Dynamic programming puzzles (knapsack, edit distance, coin change) | Breaking a problem into overlapping subproblems | Rare in infra work; when needed, AI writes it well | High at LeetCode-style shops |
| Exotic structures (tries, segment trees, Fenwick trees) | Specialized indexes for prefixes and range queries | Niche; recognize a trie for prefix matching (routing tables, autocomplete) and move on | Low to medium |
| String algorithms (KMP, Rabin-Karp, Boyer-Moore) | Fast substring search | `grep`, `rg`, and regex engines already use them | Low |
| Hand-rolled crypto and hash functions | Implementing SHA, AES, etc. | Never write your own; know which primitive to choose, which is a different and important skill | None, but a red flag if you'd try |

**One exception to "forget":** heaps. You won't implement one, but "top-K items" and "next scheduled job" are heap problems (`heapq` in Python) that come up in real tooling and interviews alike.

## Path to expertise

Nine weeks at about 4–5 hours a week gets you to "reason" on everything above and "build" on the core. Write each drill by hand first, then have AI write a production version and review it against yours.

| Week | Focus | Build on quasarlab | Read |
| --- | --- | --- | --- |
| 1 | Big-O, hashing | Profile and fix one O(n²) fleet script; hash-vs-ring key movement experiment | DDIA ch. 1 |
| 2 | Queues, Little's Law | Bounded producer/consumer; tune a Vector buffer and force it full | DDIA ch. 11 (stream processing) |
| 3 | Retries, backoff, jitter | Thundering-herd simulator with plots | AWS Builders' Library: timeouts, retries, and backoff with jitter |
| 4 | Rate limiting | Token bucket wrapping a real bulk API script | Stripe engineering blog on rate limiters |
| 5 | Caching | LRU by hand + single-flight wrapper | DDIA ch. 3 (storage and indexes) |
| 6 | Graphs | Topo sort + cycle detection on Munki or Terraform dependencies | Any algorithms text, BFS/DFS/topo chapters |
| 7 | Consensus, quorums | 3-node etcd in Docker; kill leaders, break quorum | Raft paper + raft.github.io visualization |
| 8 | Clocks, idempotency, probabilistic structures | Bloom filter; make one fleet script fully idempotent | DDIA ch. 8–9 (trouble with distributed systems, consistency) |
| 9 | Joins and data manipulation | Jamf vs. Okta drift report three ways (nested loop, hashtable, DuckDB); add dirty keys and duplicates | DuckDB docs on joins; DDIA ch. 10 (batch processing, sort-merge and hash joins) |

**Capstone (pick one):** a small distributed rate limiter backed by Redis, or a fleet check-in simulator that models 6,000 clients with jittered schedules hitting a rate-limited API through a cache. Either one is a strong portfolio piece and interview story for AI-infra roles.

**Core reading list:**

- *Designing Data-Intensive Applications* by Martin Kleppmann: the single best book for this whole guide.
- *Understanding Distributed Systems* by Roberto Vitillo: shorter, more practical, good first pass.
- [Google SRE books](https://sre.google/books/): free online; the chapters on handling overload and cascading failures map directly to sections 4–6.
- [AWS Builders' Library](https://aws.amazon.com/builders-library/): short essays from people who run these systems at scale.
- [Raft](https://raft.github.io/): the paper plus an interactive visualization.
- MIT 6.5840 (formerly 6.824) Distributed Systems: free lectures and labs if you want to go all the way.

**How to know you've got it:** pick any recent incident at work or a public postmortem and explain which of these concepts caused it and which would have prevented it. When you can do that fluently, you're there.

Reading list and chapter references are from general knowledge, not looked up today.
