#!/usr/bin/env python3
"""Drill 11 (joins): Jamf vs. Okta Verify drift report, with dirty keys.

Reads data/jamf_computers.csv and data/okta_devices.json and answers:
  which Macs are missing from Okta Verify (anti-join), which Okta devices
  aren't in Jamf, and how dirty keys and duplicates would have fooled you.

Steps that matter more than the join algorithm:
  1. Normalize the key on both sides: strip whitespace, uppercase.
  2. Treat blank serials as invalid, not as a key that matches other blanks.
  3. Check key uniqueness before joining: duplicates multiply join rows.
  4. Then a hash join (dict lookups) does the actual work in O(n + m).

Also times a nested-loop version for comparison and writes drift_report.csv.
"""
import csv
import json
import time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"


def norm(serial):
    return (serial or "").strip().upper()


def main():
    with open(DATA / "jamf_computers.csv", newline="") as f:
        jamf = list(csv.DictReader(f))
    okta = json.loads((DATA / "okta_devices.json").read_text())
    print("Drill 11: Jamf vs. Okta Verify drift report.")
    print(f"Rows: Jamf {len(jamf):,}, Okta {len(okta):,}")

    jamf_keys = [norm(r["serial"]) for r in jamf]
    okta_keys = [norm(r["serialNumber"]) for r in okta]
    print(f"Blank serials skipped: Jamf {jamf_keys.count('')}, Okta {okta_keys.count('')}")

    jamf_count = Counter(k for k in jamf_keys if k)
    okta_count = Counter(k for k in okta_keys if k)
    jamf_dups = sum(1 for n in jamf_count.values() if n > 1)
    okta_dups = sum(1 for n in okta_count.values() if n > 1)
    print(f"Serials listed more than once (after normalizing): Jamf {jamf_dups}, Okta {okta_dups}")

    # Hash join on distinct normalized keys: build the index once, probe it once.
    jamf_set, okta_set = set(jamf_count), set(okta_count)
    both = jamf_set & okta_set
    jamf_only = jamf_set - okta_set
    okta_only = okta_set - jamf_set
    print(f"Devices in both: {len(both):,}")
    print(f"In Jamf, missing from Okta Verify: {len(jamf_only):,}")
    print(f"In Okta, not in Jamf: {len(okta_only):,}")

    # What a join on raw, unnormalized serials would have claimed.
    okta_raw = {r["serialNumber"] for r in okta if r["serialNumber"]}
    raw_missing = {r["serial"] for r in jamf if r["serial"] and r["serial"] not in okta_raw}
    print(f"Joining on raw serials would report {len(raw_missing):,} missing: "
          f"{len(raw_missing) - len(jamf_only)} false alarms from case and whitespace")

    join_rows = sum(jamf_count[k] * okta_count[k] for k in both)
    print(f"A plain inner join returns {join_rows:,} rows for {len(both):,} devices "
          f"(+{join_rows - len(both)} from duplicate keys)")

    # The same anti-join as a nested loop, for timing only.
    okta_list = [k for k in okta_keys if k]
    start = time.perf_counter()
    nested_missing = {k for k in jamf_set if not [o for o in okta_list if o == k]}
    t_nested = time.perf_counter() - start
    start = time.perf_counter()
    index = set(okta_list)
    hash_missing = {k for k in jamf_set if k not in index}
    t_hash = time.perf_counter() - start
    assert nested_missing == hash_missing == jamf_only

    first_jamf, first_okta = {}, {}
    for r, k in zip(jamf, jamf_keys):
        first_jamf.setdefault(k, r["computer_name"])
    for r, k in zip(okta, okta_keys):
        first_okta.setdefault(k, r["id"])
    out = ROOT / "drift_report.csv"
    with open(out, "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["serial", "status", "jamf_computer_name", "okta_device_id"])
        for k in sorted(jamf_set | okta_set):
            status = "both" if k in both else ("jamf_only" if k in jamf_only else "okta_only")
            w.writerow([k, status, first_jamf.get(k, ""), first_okta.get(k, "")])
    print(f"Wrote drift_report.csv ({len(jamf_set | okta_set):,} rows)")
    print(f"~ anti-join timing: nested loop {t_nested:.3f} s, hash {t_hash * 1000:.2f} ms "
          f"({t_nested / t_hash:,.0f}x faster)")


if __name__ == "__main__":
    main()
