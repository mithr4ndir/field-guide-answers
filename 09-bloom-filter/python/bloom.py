#!/usr/bin/env python3
"""Drill 9 (probabilistic structures): a Bloom filter, measured against the formula.

Sizes a filter for 100,000 items at a 1% false-positive target, inserts
100,000 device ids, then asks about 100,000 ids that were never inserted
and counts how many it wrongly says "probably yes" to.

  m = -n ln(p) / (ln 2)^2   bits
  k = (m / n) ln 2          hash functions
  predicted false-positive rate = (1 - e^(-k n / m))^k

The k bit positions come from one SHA-256 digest (double hashing):
h1 = bytes 0-7 and h2 = bytes 8-15, each read as a big-endian unsigned
64-bit number and reduced mod m, then index_i = (h1 + i * h2) mod m.
Reducing first keeps the math inside 64 bits in every language.
"""
import hashlib
import math
import time

N = 100_000
P = 0.01


class BloomFilter:
    def __init__(self, n, p):
        self.m = math.ceil(-n * math.log(p) / math.log(2) ** 2)
        self.k = round(self.m / n * math.log(2))
        self.bits = bytearray((self.m + 7) // 8)

    def _positions(self, item):
        digest = hashlib.sha256(item.encode()).digest()
        h1 = int.from_bytes(digest[:8], "big") % self.m
        h2 = int.from_bytes(digest[8:16], "big") % self.m
        if h2 == 0:
            h2 = 1                     # a zero step would put all k probes on the same bit
        # (Steps that share a factor with m, like m/2, also cluster probes. It's rare;
        # a prime m avoids it entirely.)
        return [(h1 + i * h2) % self.m for i in range(self.k)]

    def add(self, item):
        for pos in self._positions(item):
            self.bits[pos >> 3] |= 1 << (pos & 7)

    def __contains__(self, item):
        return all(self.bits[pos >> 3] & (1 << (pos & 7)) for pos in self._positions(item))


def predicted_rate(m, k, n):
    return (1 - math.exp(-k * n / m)) ** k


def rate_text(count, total):
    """Percent with three decimals, rounded half up, integers only."""
    thousandths = (count * 200_000 + total) // (2 * total)
    return f"{thousandths // 1000}.{thousandths % 1000:03d}%"


def main():
    print(f"Drill 9: Bloom filter sized for {N:,} items at {P:.0%} false positives.")
    start = time.perf_counter()
    bf = BloomFilter(N, P)
    print(f"m = {bf.m:,} bits ({bf.m // 8 // 1024:,} KiB), k = {bf.k} hash functions")

    for i in range(N):
        bf.add(f"device-{i}")
    misses = sum(1 for i in range(N) if f"device-{i}" not in bf)
    print(f"False negatives on the {N:,} inserted ids: {misses} (must be 0)")

    fp = sum(1 for i in range(N) if f"other-{i}" in bf)
    print(f"False positives on {N:,} ids never inserted: {fp:,} = {rate_text(fp, N)}"
          f"   predicted {predicted_rate(bf.m, bf.k, N) * 100:.3f}%")

    for i in range(N, 2 * N):              # overfill to twice the design size
        bf.add(f"device-{i}")
    fp2 = sum(1 for i in range(N) if f"other-{i}" in bf)
    print(f"Overfilled to {2 * N:,} items: {fp2:,} = {rate_text(fp2, N)}"
          f"   predicted {predicted_rate(bf.m, bf.k, 2 * N) * 100:.3f}%")
    print(f"~ ran in {time.perf_counter() - start:.2f} s")


if __name__ == "__main__":
    main()
