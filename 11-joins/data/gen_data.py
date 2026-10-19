#!/usr/bin/env python3
"""Generate the fake Jamf and Okta exports for drill 11 (already generated; rerun to rebuild).

jamf_computers.csv  6,000 Macs plus the mess real exports have: 10 re-enrolled
                    devices listed twice and 2 rows with a blank serial.
okta_devices.json   Okta Verify devices: ~5% of the Macs are missing, ~2% of
                    serials are lowercase, ~1% have stray spaces, ~0.5% of
                    devices are registered twice, 100 devices are not in Jamf
                    at all, and 3 records have no serial.

Uses the same MINSTD generator as the other drills, so the files are identical
every time.
"""
import csv
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
ALPHABET = "0123456789ABCDEFGHJKLMNPQRSTUVWXYZ"   # Apple serials skip I and O
SEED = 2026


class MinStd:
    M = 2_147_483_647

    def __init__(self, seed):
        self.state = seed

    def next_int(self):
        self.state = self.state * 48271 % self.M
        return self.state

    def random(self):
        return self.next_int() / self.M


def main():
    rng = MinStd(SEED)
    seen = set()

    def new_serial():
        while True:
            s = "C02" + "".join(ALPHABET[rng.next_int() % len(ALPHABET)] for _ in range(9))
            if s not in seen:
                seen.add(s)
                return s

    versions = ("14.7.1", "15.3.2", "15.4", "15.5")
    devices = [(new_serial(), f"LT-{i:05d}", versions[i % 4], f"user{i % 2500:04d}@example.com")
               for i in range(6000)]

    jamf_rows = list(devices)
    for i in range(0, 1000, 100):                 # 10 re-enrolled devices appear twice
        serial, name, ver, user = devices[i]
        jamf_rows.append((serial, name + "-old", ver, user))
    jamf_rows.insert(1234, ("", "LT-NOSERIAL-1", "15.4", "user9998@example.com"))
    jamf_rows.insert(4321, ("", "LT-NOSERIAL-2", "15.5", "user9999@example.com"))
    with open(HERE / "jamf_computers.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["serial", "computer_name", "os_version", "username"])
        w.writerows(jamf_rows)

    okta, next_id = [], 1

    def okta_record(serial, name):
        nonlocal next_id
        rec = {"id": f"guo{next_id:08d}", "serialNumber": serial, "displayName": name,
               "platform": "MACOS", "status": "ACTIVE"}
        next_id += 1
        return rec

    for serial, name, _, _ in devices:
        if rng.random() < 0.05:
            continue                               # never enrolled in Okta Verify
        r = rng.random()
        if r < 0.02:
            shown = serial.lower()
        elif r < 0.03:
            shown = f" {serial} " if rng.random() < 0.5 else f"{serial}  "
        else:
            shown = serial
        okta.append(okta_record(shown, name))
        if rng.random() < 0.005:                   # registered twice
            okta.append(okta_record(serial.lower() if rng.random() < 0.5 else serial, name))
    for i in range(100):                           # retired or personal devices not in Jamf
        okta.append(okta_record(new_serial(), f"BYOD-{i:03d}"))
    okta.insert(500, okta_record(None, "Unknown-1"))
    okta.insert(2500, okta_record("", "Unknown-2"))
    okta.insert(5000, okta_record(None, "Unknown-3"))
    with open(HERE / "okta_devices.json", "w") as f:
        json.dump(okta, f, indent=1)
        f.write("\n")
    print(f"wrote {len(jamf_rows):,} Jamf rows and {len(okta):,} Okta records")


if __name__ == "__main__":
    main()
