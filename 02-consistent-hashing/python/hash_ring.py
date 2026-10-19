#!/usr/bin/env python3
"""Drill 2 (consistent hashing): count how many keys move when an 11th node joins.

Assigns 100,000 keys to 10 nodes two ways, adds node-10, and counts moves:

  hash % N   owner = hash(key) % N. Changing N reshuffles almost everything.
  hash ring  each node gets 160 virtual points on a ring; a key belongs to the
             first point clockwise from its hash. A new node only takes over
             the arcs in front of its own points, about 1/N of the keys.

The hash is the first 4 bytes of SHA-256, read big-endian, so every language
gets identical numbers.
"""
import bisect
import hashlib
from collections import Counter

KEYS = 100_000
VNODES = 160


def h32(text):
    """First 4 bytes of SHA-256 as an unsigned 32-bit integer."""
    return int.from_bytes(hashlib.sha256(text.encode()).digest()[:4], "big")


class HashRing:
    def __init__(self, nodes, vnodes=VNODES):
        # Sort by (position, node name) so ties break the same way everywhere.
        points = sorted((h32(f"{node}#{v}"), node) for node in nodes for v in range(vnodes))
        self.positions = [pos for pos, _ in points]
        self.owners = [node for _, node in points]

    def owner(self, key_hash):
        i = bisect.bisect_left(self.positions, key_hash)  # first point >= key hash
        if i == len(self.positions):  # past the last point: wrap to the start
            i = 0
        return self.owners[i]


def pct(part, whole):
    """Percent with one decimal, rounded half up, using integers only."""
    tenths = (part * 2000 + whole) // (2 * whole)
    return f"{tenths // 10}.{tenths % 10}%"


def main():
    nodes10 = [f"node-{i}" for i in range(10)]
    nodes11 = nodes10 + ["node-10"]
    hashes = [h32(f"key-{i}") for i in range(KEYS)]

    print(f"Drill 2: consistent hashing. {KEYS:,} keys, cluster grows from 10 to 11 nodes.")

    moved_mod = sum(1 for h in hashes if h % 10 != h % 11)
    print(f"hash % N   moved {moved_mod:>6,} keys ({pct(moved_mod, KEYS)})   expect ~90.9% (10 of 11)")

    ring10, ring11 = HashRing(nodes10), HashRing(nodes11)
    before = [ring10.owner(h) for h in hashes]
    after = [ring11.owner(h) for h in hashes]
    moved = [(b, a) for b, a in zip(before, after) if b != a]
    print(f"hash ring  moved {len(moved):>6,} keys ({pct(len(moved), KEYS)})    expect ~9.1% (1 of 11)")
    went_to_new = all(a == "node-10" for _, a in moved)
    print(f"Every key that moved on the ring went to node-10: {'yes' if went_to_new else 'no'}")

    load = Counter(after)
    counts = [load.get(n, 0) for n in nodes11]      # include nodes that got no keys at all
    print(f"Keys per node, 11 nodes x 160 vnodes: min {min(counts):,}  max {max(counts):,}"
          f"  (ideal {(2 * KEYS + 11) // 22:,})")
    one_point = HashRing(nodes11, vnodes=1)
    load1 = Counter(one_point.owner(h) for h in hashes)
    counts1 = [load1.get(n, 0) for n in nodes11]
    print(f"Keys per node, 11 nodes x 1 vnode:    min {min(counts1):,}  max {max(counts1):,}"
          f"  (why virtual nodes matter)")


if __name__ == "__main__":
    main()
