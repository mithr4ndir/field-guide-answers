#!/usr/bin/env python3
"""Drill 6 (caching): LRU two ways, SIEVE vs. LRU, and a single-flight wrapper.

Part 1  LRU built on OrderedDict, and LRU built by hand from a dict plus a
        doubly linked list. Both must give identical hit counts.
Part 2  SIEVE: one queue, a "visited" bit per entry, and a moving hand. It is
        compared with LRU on a trace where 30% of requests are one-hit
        wonders, which is what real cache traces look like.
Part 3  Single-flight: 10 threads miss the same key at the same moment. Only
        one calls the slow backend; the others wait and share its result.

The trace comes from MINSTD plus a Zipf distribution, so Python, PowerShell
and Go replay exactly the same 100,000 requests and print the same hit ratios.
"""
import bisect
import threading
import time
from collections import OrderedDict
from concurrent.futures import Future

REQUESTS = 100_000
POPULAR = 10_000          # object ids 0..9,999, requested with Zipf popularity
ONE_HIT_SHARE = 0.30      # share of requests for ids that never repeat
SEED = 7
SIZES = (100, 1_000)


class MinStd:
    """Park-Miller "minimal standard" generator (multiplier 48271). Same in every language."""
    M = 2_147_483_647

    def __init__(self, seed):
        self.state = seed

    def random(self):
        self.state = self.state * 48271 % self.M
        return self.state / self.M


def make_trace():
    """70% Zipf(exponent 1) over POPULAR ids, 30% brand-new ids (one-hit wonders)."""
    rng = MinStd(SEED)
    cdf, total = [], 0.0
    for rank in range(1, POPULAR + 1):
        total += 1.0 / rank                       # weight of rank r is 1/r
        cdf.append(total)
    trace, next_new_id = [], 1_000_000
    for _ in range(REQUESTS):
        if rng.random() < ONE_HIT_SHARE:
            trace.append(next_new_id)
            next_new_id += 1
        else:
            x = rng.random() * total
            trace.append(bisect.bisect_right(cdf, x))   # first index whose cdf > x
    return trace


class LRUOrderedDict:
    """LRU in a few lines: OrderedDict remembers insertion order and can move a key to the end."""

    def __init__(self, capacity):
        self.capacity = capacity
        self.data = OrderedDict()

    def access(self, key):
        """Returns True on a hit. On a miss, inserts the key (evicting if full)."""
        if key in self.data:
            self.data.move_to_end(key)            # now the most recently used
            return True
        self.data[key] = None
        if len(self.data) > self.capacity:
            self.data.popitem(last=False)         # drop the least recently used
        return False


class Node:
    __slots__ = ("key", "prev", "next", "visited")

    def __init__(self, key):
        self.key = key
        self.prev = None
        self.next = None
        self.visited = False


class LRULinked:
    """LRU by hand: dict for O(1) lookup, doubly linked list for O(1) reordering.

    Two sentinel nodes mean no special cases for an empty list:
    head.next is the most recently used entry, tail.prev the least.
    """

    def __init__(self, capacity):
        self.capacity = capacity
        self.map = {}
        self.head, self.tail = Node(None), Node(None)
        self.head.next, self.tail.prev = self.tail, self.head

    def _unlink(self, node):
        node.prev.next, node.next.prev = node.next, node.prev

    def _push_front(self, node):
        node.prev, node.next = self.head, self.head.next
        self.head.next.prev = node
        self.head.next = node

    def access(self, key):
        node = self.map.get(key)
        if node is not None:
            self._unlink(node)
            self._push_front(node)
            return True
        node = Node(key)
        self.map[key] = node
        self._push_front(node)
        if len(self.map) > self.capacity:
            lru = self.tail.prev
            self._unlink(lru)
            del self.map[lru.key]
        return False


class Sieve:
    """SIEVE (NSDI 2024). New entries go in at the head; a hit only sets a bit.

    To evict, the hand walks from the tail toward the head. Visited entries
    have their bit cleared and survive; the first unvisited entry is evicted,
    and the hand stays where it stopped for next time. One-hit wonders are
    never visited, so they leave quickly without pushing popular entries out.
    """

    def __init__(self, capacity):
        self.capacity = capacity
        self.map = {}
        self.head = None   # newest; node.next points toward the tail (older)
        self.tail = None   # oldest; node.prev points toward the head (newer)
        self.hand = None

    def access(self, key):
        node = self.map.get(key)
        if node is not None:
            node.visited = True                   # no list surgery on a hit
            return True
        if len(self.map) >= self.capacity:
            self._evict()
        node = Node(key)
        self.map[key] = node
        node.next = self.head
        if self.head is not None:
            self.head.prev = node
        self.head = node
        if self.tail is None:
            self.tail = node
        return False

    def _evict(self):
        node = self.hand or self.tail
        while node.visited:
            node.visited = False                  # second chance
            node = node.prev or self.tail         # toward the head, wrapping to the tail
        self.hand = node.prev
        if node.prev is not None:
            node.prev.next = node.next
        else:
            self.head = node.next
        if node.next is not None:
            node.next.prev = node.prev
        else:
            self.tail = node.prev
        del self.map[node.key]


class SingleFlight:
    """Collapse concurrent calls for the same key into one call.

    The first caller (the leader) runs fn; anyone arriving while it runs
    waits on the same Future and gets the same result or exception.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._calls = {}

    def do(self, key, fn):
        with self._lock:
            future = self._calls.get(key)
            leader = future is None
            if leader:
                future = Future()
                self._calls[key] = future
        if leader:
            try:
                future.set_result(fn())
            except BaseException as exc:
                future.set_exception(exc)
            finally:
                with self._lock:
                    del self._calls[key]
        return future.result()


def hit_pct(hits, total):
    """Percent with two decimals, rounded half up, integers only. Returns (text, hundredths)."""
    hundredths = (hits * 20000 + total) // (2 * total)
    return f"{hundredths // 100}.{hundredths % 100:02d}%", hundredths


def run(cache, trace):
    return sum(1 for key in trace if cache.access(key))


def single_flight_demo(callers=10):
    calls = 0
    calls_lock = threading.Lock()

    def slow_backend():
        nonlocal calls
        with calls_lock:
            calls += 1
        time.sleep(0.2)                           # a slow catalog rebuild
        return "catalog-v42"

    for use_single_flight in (False, True):
        calls = 0
        flight = SingleFlight()
        barrier = threading.Barrier(callers)
        results = []

        def caller():
            barrier.wait()                        # everyone misses at the same moment
            if use_single_flight:
                results.append(flight.do("catalog", slow_backend))
            else:
                results.append(slow_backend())

        threads = [threading.Thread(target=caller) for _ in range(callers)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        label = "with single-flight:   " if use_single_flight else "without single-flight:"
        same = "yes" if len(set(results)) == 1 else "no"
        print(f"{label} {callers} callers -> {calls} backend call{'s' if calls != 1 else ''}, "
              f"all got the same value: {same}")


def main():
    print(f"Drill 6: caching. {REQUESTS:,} requests: 70% Zipf over {POPULAR:,} objects, "
          f"30% one-hit wonders.")
    trace = make_trace()
    print(f"{'cache size':>10}  {'LRU (library)':>17}  {'LRU (hand-built)':>17}  {'SIEVE':>7}  SIEVE vs LRU")
    agree = True
    for size in SIZES:
        lru_od = run(LRUOrderedDict(size), trace)
        lru_ll = run(LRULinked(size), trace)
        sieve = run(Sieve(size), trace)
        agree = agree and lru_od == lru_ll
        od_txt, od_h = hit_pct(lru_od, REQUESTS)
        ll_txt, _ = hit_pct(lru_ll, REQUESTS)
        sv_txt, sv_h = hit_pct(sieve, REQUESTS)
        diff = sv_h - od_h
        sign = "+" if diff >= 0 else "-"
        print(f"{size:>10,}  {od_txt:>17}  {ll_txt:>17}  {sv_txt:>7}  "
              f"{sign}{abs(diff) // 100}.{abs(diff) % 100:02d} points")
    print(f"Both LRU implementations agree: {'yes' if agree else 'no'}")
    single_flight_demo()


if __name__ == "__main__":
    main()
