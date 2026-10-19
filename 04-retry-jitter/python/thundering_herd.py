#!/usr/bin/env python3
"""Drill 4 (retry, backoff, jitter): simulate a thundering herd.

1,000 clients each need one successful request. The server handles 100
requests per second, but it is down for the first 10 seconds. Every failed
request is retried with one of three strategies:

  none         retry after a fixed 1 s
  exponential  retry after 1, 2, 4, 8 ... s, capped at 60 s
  full_jitter  retry after a random time between 0 and the exponential value

This is an event-driven simulation: a min-heap holds every client's next
attempt, ordered by (time, client id). Nothing really sleeps, so it runs
instantly and is deterministic. Random numbers come from MINSTD, a tiny
generator written identically in Python, PowerShell and Go, so all three
print the same numbers.

Pass --csv to also write retry_load.csv (requests per second per strategy)
for plotting.
"""
import heapq
import sys

CLIENTS = 1_000
CAPACITY = 100          # successful requests per 1-second window
OUTAGE_END = 10.0       # server is down for t in [0, 10)
BASE = 1.0              # first retry delay, seconds
CAP = 60.0              # longest retry delay, seconds
SEED = 42
CHART_SECONDS = 60
STRATEGIES = ("none", "exponential", "full_jitter")


class MinStd:
    """Park-Miller "minimal standard" generator (multiplier 48271).

    Small and identical in every language. Fine for simulations, never for
    security or anything that needs high-quality randomness.
    """
    M = 2_147_483_647

    def __init__(self, seed):
        self.state = seed

    def random(self):
        """A float in (0, 1)."""
        self.state = self.state * 48271 % self.M
        return self.state / self.M


def retry_delay(strategy, failures, rng):
    """Seconds to wait after a client's `failures`-th failure (1-based)."""
    if strategy == "none":
        return 1.0
    backoff = min(CAP, BASE * 2 ** min(failures - 1, 30))   # 1, 2, 4, ... capped at 60
    if strategy == "exponential":
        return backoff
    return rng.random() * backoff                          # full jitter: uniform in (0, backoff)


def simulate(strategy):
    rng = MinStd(SEED)
    events = [(0.0, client) for client in range(CLIENTS)]  # everyone fires at t=0
    heapq.heapify(events)
    failures = [0] * CLIENTS
    arrivals = {}   # second -> requests that reached the server
    served = {}     # second -> requests that succeeded
    finish = 0.0
    while events:
        t, client = heapq.heappop(events)
        second = int(t)                                    # floor, since t >= 0
        arrivals[second] = arrivals.get(second, 0) + 1
        if t >= OUTAGE_END and served.get(second, 0) < CAPACITY:
            served[second] = served.get(second, 0) + 1
            finish = t
            continue                                       # this client is done
        failures[client] += 1                              # server down, or over capacity
        heapq.heappush(events, (t + retry_delay(strategy, failures[client], rng), client))
    # The herd that matters is the one that hits the server as it recovers.
    peak_second = max((sec for sec in arrivals if sec >= OUTAGE_END), key=lambda sec: (arrivals[sec], -sec))
    return {
        "arrivals": arrivals,
        "total": sum(arrivals.values()),
        "peak": arrivals[peak_second],
        "peak_second": peak_second,
        "finish": finish,
    }


def fixed1(num, den):
    """num/den with one decimal, rounded half up, using integers only."""
    tenths = (num * 20 + den) // (2 * den)
    return f"{tenths // 10}.{tenths % 10}"


def sparkline(arrivals, seconds, top):
    """One character per second. Eight heights, each step worth top/8 requests, rounded up."""
    blocks = " ▁▂▃▄▅▆▇█"
    line = []
    for second in range(seconds):
        v = arrivals.get(second, 0)
        level = 0 if v == 0 else min(8, (v * 8 + top - 1) // top)   # integer ceil, clamped: 1..8
        line.append(blocks[level])
    return "".join(line)


def main():
    print(f"Drill 4: thundering herd. {CLIENTS:,} clients, server handles {CAPACITY}/s, "
          f"down for the first {OUTAGE_END:.0f} s.")
    results = {s: simulate(s) for s in STRATEGIES}

    print(f"{'strategy':<12} {'requests':>8} {'per client':>10}   {'peak after recovery':<21} {'all done at':>11}")
    for s in STRATEGIES:
        r = results[s]
        peak = f"{r['peak']:,}/s at t={r['peak_second']}"
        print(f"{s:<12} {r['total']:>8,} {fixed1(r['total'], CLIENTS):>10}   {peak:<21} {r['finish']:>10.1f}s")

    top = CLIENTS
    print(f"Requests per second, first {CHART_SECONDS} s (each block step is {top // 8}/s, rounded up; "
          f"capacity is {CAPACITY}/s):")
    for s in STRATEGIES:
        print(f"{s:<12} |{sparkline(results[s]['arrivals'], CHART_SECONDS, top)}|")

    waves = sorted(sec for sec, v in results["exponential"]["arrivals"].items() if v >= CAPACITY)
    print("exponential sends synchronized waves at t = " + ", ".join(str(w) for w in waves))

    if "--csv" in sys.argv:
        last = max(max(r["arrivals"]) for r in results.values())
        with open("retry_load.csv", "w") as f:
            f.write("second," + ",".join(STRATEGIES) + "\n")
            for sec in range(last + 1):
                f.write(f"{sec}," + ",".join(str(results[s]["arrivals"].get(sec, 0)) for s in STRATEGIES) + "\n")
        print("~ wrote retry_load.csv")


if __name__ == "__main__":
    main()
