#!/usr/bin/env python3
"""Drill 8 (distributed systems): watch writes through leader loss and quorum loss.

Writes lab/counter = 1, 2, 3 ... every 250 ms through etcd's HTTP/JSON gateway
(no client library needed) and prints one line per write: which node took it,
how long it took, and the Raft term. Kill nodes while it runs (see LAB.md):

  kill the leader   a short burst of slow or failed writes, then writes resume
                    under a new Raft term (usually one higher; a split vote adds more)
  kill two nodes    every write fails: one node out of three is not a majority,
                    so nothing can commit. Serializable reads still answer,
                    from local (possibly stale) data.
  start one again   quorum is back and writes resume

Usage: python3 etcd_writer.py [--endpoints localhost:2379,localhost:22379,localhost:32379]
                              [--count N] [--interval 0.25] [--timeout 1.0]
"""
import argparse
import base64
import json
import time
import urllib.error
import urllib.request
from datetime import datetime

KEY = "lab/counter"


def b64(text):
    return base64.b64encode(text.encode()).decode()


def post(endpoint, path, body, timeout):
    request = urllib.request.Request(
        f"http://{endpoint}{path}", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read())


def describe(error):
    """Short reason for a failed request."""
    if isinstance(error, urllib.error.HTTPError):
        try:
            body = json.loads(error.read())
            return body.get("message") or body.get("error") or f"HTTP {error.code}"
        except ValueError:
            return f"HTTP {error.code}"
    reason = getattr(error, "reason", error)
    text = str(reason)
    if "refused" in text.lower():
        return "connection refused"
    if "timed out" in text.lower():
        return "timed out"
    return text


def stamp():
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--endpoints", default="localhost:2379,localhost:22379,localhost:32379")
    parser.add_argument("--count", type=int, default=0, help="number of writes (0 = until Ctrl+C)")
    parser.add_argument("--interval", type=float, default=0.25)
    parser.add_argument("--timeout", type=float, default=1.0)
    args = parser.parse_args()
    endpoints = args.endpoints.split(",")

    i = 0
    try:
        while args.count == 0 or i < args.count:
            i += 1
            tick = time.monotonic()
            errors = []
            for endpoint in endpoints:                       # fail over in order
                start = time.monotonic()
                try:
                    header = post(endpoint, "/v3/kv/put", {"key": b64(KEY), "value": b64(str(i))},
                                  args.timeout)["header"]
                    ms = (time.monotonic() - start) * 1000
                    print(f"{stamp()}  put {KEY}={i:<4} OK    via {endpoint:<15} {ms:5.0f} ms  "
                          f"term {header['raft_term']}  rev {header['revision']}", flush=True)
                    break
                except (urllib.error.URLError, OSError) as error:
                    errors.append(f"{endpoint} {describe(error)}")
            else:
                print(f"{stamp()}  put {KEY}={i:<4} FAIL  " + "; ".join(errors), flush=True)
                # No quorum means no writes, but a serializable read is answered from local data.
                for endpoint in endpoints:
                    try:
                        kvs = post(endpoint, "/v3/kv/range", {"key": b64(KEY), "serializable": True},
                                   args.timeout).get("kvs", [])
                        value = base64.b64decode(kvs[0]["value"]).decode() if kvs else "(none)"
                        print(f"{'':12}  serializable read from {endpoint}: {KEY}={value} "
                              f"(may be stale)", flush=True)
                        break
                    except (urllib.error.URLError, OSError):
                        continue
            time.sleep(max(0.0, args.interval - (time.monotonic() - tick)))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
