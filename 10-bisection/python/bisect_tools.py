#!/usr/bin/env python3
"""Drill 10 (binary search): find the first bad thing, and binary search on the answer.

first_true(lo, hi, pred) is the one function to know. It assumes pred flips
exactly once, from False to True, somewhere in the half-open range [lo, hi),
and returns the first value where it is True (or hi if it never is).

Part 1  500 commits, the bug arrived in commit 337. Find it in ~9 tests.
Part 2  Binary search on the answer: the largest batch size an API accepts.
        Search "first size that fails" and subtract one.

The probe sequence is printed so you can check your midpoint math: with
mid = lo + (hi - lo) // 2 every language visits the same values.
"""


def first_true(lo, hi, pred):
    """Smallest x in [lo, hi) with pred(x) True. pred must be False...False, True...True."""
    while lo < hi:
        mid = lo + (hi - lo) // 2      # never overflows, unlike (lo + hi) // 2 in fixed-width ints
        if pred(mid):
            hi = mid                   # mid might be the answer; keep it in range
        else:
            lo = mid + 1               # mid is definitely not the answer
    return lo


def main():
    print("Drill 10: binary search and bisection.")

    commits, culprit, probes = 500, 337, []

    def is_bad(commit):
        probes.append(commit)
        return commit >= culprit

    found = first_true(0, commits, is_bad)
    print(f"Part 1: first bad commit among {commits} is {found}, found in {len(probes)} tests "
          f"(log2({commits}) is about 9)")
    print("  tested: " + ", ".join(str(p) for p in probes))

    max_ok, probes = 437, []

    def fails(batch):
        probes.append(batch)
        return batch > max_ok           # the fake API times out above 437 items

    largest = first_true(1, 10_001, fails) - 1
    print(f"Part 2: largest batch the API accepts is {largest}, found in {len(probes)} probes "
          f"of the range 1..10,000")
    print("  probed: " + ", ".join(str(p) for p in probes))


if __name__ == "__main__":
    main()
