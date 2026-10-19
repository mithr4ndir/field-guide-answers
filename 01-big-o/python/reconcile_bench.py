#!/usr/bin/env python3
"""Drill 1 (Big-O): time an O(n^2) reconciliation against an O(n) one.

Reconciles N Jamf devices against N Okta Verify devices, where every 20th
device is missing from Okta, two ways:

  nested  for each Jamf device, scan the whole Okta list. This is the
          foreach + Where-Object pattern: n x n comparisons, O(n^2).
  hash    build a dict keyed by serial once (O(n)), then one pass over
          Jamf with O(1) lookups. O(n) overall.

Then it checks the growth against the prediction: 6x more devices should
cost about 36x more for nested and about 6x more for hash.

Lines starting with "~" are timings and vary by machine.
"""
import time

SIZES = (100, 1_000, 6_000)


def make_inventory(n):
    """Deterministic fake inventories. Okta lists devices in a different order
    (real exports rarely line up) and is missing every 20th one."""
    jamf = [{"serial": f"SN{i:06d}", "os": ("14.7", "15.3", "15.4")[i % 3]} for i in range(n)]
    okta = [{"serial": f"SN{i:06d}", "trust": "managed"} for i in reversed(range(n)) if i % 20 != 0]
    return jamf, okta


def missing_nested(jamf, okta):
    """O(n^2): the inner list comprehension scans every Okta record for every Jamf record."""
    missing = []
    for j in jamf:
        matches = [o for o in okta if o["serial"] == j["serial"]]
        if not matches:
            missing.append(j["serial"])
    return missing


def missing_hash(jamf, okta):
    """O(n): one pass to build the index, one pass to probe it."""
    okta_by_serial = {o["serial"]: o for o in okta}
    return [j["serial"] for j in jamf if j["serial"] not in okta_by_serial]


def timed(fn, *args, repeats=1):
    """Run fn `repeats` times and keep the fastest run. Tiny timings are noisy,
    and the minimum is the best estimate of the real cost."""
    best = float("inf")
    for _ in range(repeats):
        start = time.perf_counter()
        result = fn(*args)
        best = min(best, time.perf_counter() - start)
    return result, best


def main():
    print("Drill 1: Big-O. Reconcile N Jamf devices against N Okta devices (every 20th missing from Okta).")
    found, timings = [], {}
    for n in SIZES:
        jamf, okta = make_inventory(n)
        nested, t_nested = timed(missing_nested, jamf, okta, repeats=3)
        hashed, t_hash = timed(missing_hash, jamf, okta, repeats=50)
        assert nested == hashed, "both methods must find the same devices"
        found.append(f"n={n:,} -> {len(nested):,}")
        timings[n] = (t_nested, t_hash)
    print("Missing devices found: " + ", ".join(found) + " (both methods agree)")

    print(f"~ {'n':>6}  {'nested (s)':>10}  {'hash (s)':>9}  {'speedup':>8}")
    for n, (t_nested, t_hash) in timings.items():
        print(f"~ {n:>6,}  {t_nested:>10.5f}  {t_hash:>9.5f}  {t_nested / t_hash:>7,.0f}x")
    nested_growth = timings[6_000][0] / timings[1_000][0]
    hash_growth = timings[6_000][1] / timings[1_000][1]
    print(f"~ Growth from 1,000 to 6,000 devices (6x): nested {nested_growth:.1f}x slower (predict 36x), "
          f"hash {hash_growth:.1f}x (predict 6x)")


if __name__ == "__main__":
    main()
