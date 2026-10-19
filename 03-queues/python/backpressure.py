#!/usr/bin/env python3
"""Drill 3 (queues and backpressure): what happens when a bounded queue fills up.

A producer makes 50 items, one every 20 ms. A consumer needs 60 ms per item,
so it is 3x too slow. The queue holds 5 items. Each run uses one of the four
things you can do when the queue is full:

  block        producer waits for space (backpressure). Nothing lost; the
               producer slows to the consumer's pace.
  drop_newest  reject the new item. Keeps the oldest data.
  drop_oldest  evict the oldest queued item to make room. Keeps the newest data.
  spill        overflow goes to a file on disk and is drained in order.
               Nothing lost, producer never waits, but disk is slower and finite.

Thread timing varies, so the counts are approximate (lines starting with "~").
The invariants on the other lines hold on every run.
"""
import os
import queue
import tempfile
import threading
import time
from collections import deque

ITEMS = 50
PRODUCE_EVERY = 0.020   # seconds between items
CONSUME_TIME = 0.060    # seconds of work per item
CAPACITY = 5
DONE = None             # sentinel that tells the consumer to stop


class SpillQueue:
    """Bounded in-memory queue that overflows to a file instead of blocking.

    Order is preserved: once anything is on disk, new items also go to disk
    until the consumer has drained it, and the consumer always empties memory
    before reading the file. So memory always holds the oldest items.
    """

    def __init__(self, capacity, path):
        self.capacity = capacity
        self.memory = deque()
        self.cond = threading.Condition()
        self.writer = open(path, "w")
        self.reader = open(path, "r")
        self.on_disk = 0     # items written to the file and not yet read back
        self.spilled = 0     # total items that ever went to disk
        self.closed = False

    def put(self, item):
        with self.cond:
            if self.on_disk == 0 and len(self.memory) < self.capacity:
                self.memory.append(item)
            else:
                self.writer.write(f"{item}\n")
                self.writer.flush()
                self.on_disk += 1
                self.spilled += 1
            self.cond.notify()

    def get(self):
        with self.cond:
            while not self.memory and self.on_disk == 0:
                if self.closed:
                    return DONE
                self.cond.wait()
            if self.memory:
                return self.memory.popleft()
            self.on_disk -= 1
            return int(self.reader.readline())

    def close(self):
        with self.cond:
            self.closed = True
            self.cond.notify_all()
        # The consumer may still be reading; files are closed after it finishes.


def run(strategy):
    spill_path = None
    if strategy == "spill":
        fd, spill_path = tempfile.mkstemp(prefix="spill-", suffix=".log")
        os.close(fd)
        q = SpillQueue(CAPACITY, spill_path)
    else:
        q = queue.Queue(maxsize=CAPACITY)

    delivered = []
    born = [0.0] * ITEMS      # when each item was produced
    ages = []                 # how old each item was when the consumer picked it up

    def consumer():
        while True:
            item = q.get()
            if item is DONE:
                return
            ages.append(time.perf_counter() - born[item])
            time.sleep(CONSUME_TIME)  # simulate slow work
            delivered.append(item)

    worker = threading.Thread(target=consumer)
    worker.start()

    dropped = 0
    start = time.perf_counter()
    for i in range(ITEMS):
        born[i] = time.perf_counter()
        if strategy in ("block", "spill"):
            q.put(i)                       # block waits for space; spill never waits
        elif strategy == "drop_newest":
            try:
                q.put_nowait(i)
            except queue.Full:
                dropped += 1               # the new item is lost
        elif strategy == "drop_oldest":
            while True:
                try:
                    q.put_nowait(i)
                    break
                except queue.Full:
                    try:
                        q.get_nowait()     # throw away the oldest queued item
                        dropped += 1
                    except queue.Empty:
                        pass               # consumer took one first; just retry
        time.sleep(PRODUCE_EVERY)
    producer_seconds = time.perf_counter() - start

    if strategy == "spill":
        q.close()
    else:
        q.put(DONE)                        # waits for space, then the consumer exits
    worker.join()
    total_seconds = time.perf_counter() - start

    spilled = 0
    if strategy == "spill":
        spilled = q.spilled
        q.writer.close()
        q.reader.close()
        os.remove(spill_path)
    avg_age_ms = sum(ages) / len(ages) * 1000
    return delivered, dropped, spilled, producer_seconds, total_seconds, avg_age_ms


def ranges(ids):
    """Compress [0,1,2,5,7,8,9] into '0-2,5,7-9'."""
    parts, i = [], 0
    while i < len(ids):
        j = i
        while j + 1 < len(ids) and ids[j + 1] == ids[j] + 1:
            j += 1
        parts.append(str(ids[i]) if i == j else f"{ids[i]}-{ids[j]}")
        i = j + 1
    return ",".join(parts)


def main():
    print(f"Drill 3: queues and backpressure. {ITEMS} items, producer every {PRODUCE_EVERY * 1000:.0f} ms, "
          f"consumer {CONSUME_TIME * 1000:.0f} ms/item, queue holds {CAPACITY}.")
    rows = []
    for strategy in ("block", "drop_newest", "drop_oldest", "spill"):
        delivered, dropped, spilled, producer_s, total_s, avg_age_ms = run(strategy)
        in_order = delivered == sorted(delivered)
        accounted = len(delivered) + dropped == ITEMS
        if strategy in ("block", "spill"):
            lost = ITEMS - len(delivered)
            print(f"{strategy:<12} lost {lost}, in order: {'yes' if in_order else 'no'}")
        elif strategy == "drop_newest":
            first_ids_kept = all(i in delivered for i in range(CAPACITY))
            print(f"{strategy:<12} delivered + dropped = {ITEMS}: {'yes' if accounted else 'no'}, "
                  f"ids 0-{CAPACITY - 1} all delivered: {'yes' if first_ids_kept else 'no'} "
                  f"(the queue still has room when they arrive)")
        else:
            print(f"{strategy:<12} delivered + dropped = {ITEMS}: {'yes' if accounted else 'no'}, "
                  f"last delivered id: {delivered[-1]} (the newest item always survives)")
        rows.append((strategy, delivered, dropped, spilled, producer_s, total_s, avg_age_ms))

    print(f"~ {'strategy':<12} {'delivered':>9} {'dropped':>7} {'spilled':>7} {'producer(s)':>11} "
          f"{'total(s)':>8} {'avg age(ms)':>11}  delivered ids")
    for strategy, delivered, dropped, spilled, producer_s, total_s, avg_age_ms in rows:
        print(f"~ {strategy:<12} {len(delivered):>9} {dropped:>7} {spilled:>7} {producer_s:>11.2f} "
              f"{total_s:>8.2f} {avg_age_ms:>11.0f}  {ranges(delivered)}")


if __name__ == "__main__":
    main()
