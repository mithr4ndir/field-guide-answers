#!/usr/bin/env python3
"""Drill 5 (rate limiting): a token bucket, tested with a fake clock.

The bucket holds up to `burst` tokens and refills at `rate` tokens per second.
Each request spends one token; with no token, the request is denied (or the
caller waits). Refill is lazy: it is computed from the elapsed time on each
call, so there is no background timer.

The current time is passed in rather than read inside the class. That one
choice makes it testable: part 1 drives it with exact fake timestamps, part 2
drives it with the real clock to pace a bulk job.
"""
import time


class TokenBucket:
    """Not thread-safe as written: allow() reads, then writes, the token count.
    If several threads share one bucket, guard allow() with a threading.Lock."""

    def __init__(self, rate, burst, now):
        self.rate = float(rate)      # tokens added per second
        self.burst = float(burst)    # bucket size = largest allowed burst
        self.tokens = float(burst)   # start full
        self.last = now

    def allow(self, now, cost=1.0):
        """Spend `cost` tokens if available. Returns True if the request may proceed."""
        self.tokens = min(self.burst, self.tokens + (now - self.last) * self.rate)
        self.last = now
        if self.tokens >= cost:
            self.tokens -= cost
            return True
        return False

    def wait_time(self, cost=1.0):
        """Seconds until `cost` tokens will be available (call after allow() returns False)."""
        return max(0.0, (cost - self.tokens) / self.rate)


def okta_pause(remaining, limit, reset_epoch, now_epoch, floor=0.1):
    """Seconds to pause based on Okta's X-Rate-Limit-* response headers.

    Keep going while more than `floor` of the limit is left; below that,
    wait until the window resets instead of running into 429s. The reset time
    is the server's clock, so take "now" from the response's Date header,
    not the local clock.
    """
    if remaining > limit * floor:
        return 0.0
    return max(0.0, reset_epoch - now_epoch)


def fake_clock_demo():
    rate, burst = 4, 8
    step = 1 / 16                 # 16 requests per second offered; exactly representable
    bucket = TokenBucket(rate, burst, now=0.0)
    print(f"Part 1, fake clock: rate {rate}/s, burst {burst}, one request every 1/16 s for 4 s "
          f"(# allowed, . denied)")
    total = 0
    for second in range(4):
        marks = []
        for i in range(16):
            t = (second * 16 + i) * step
            ok = bucket.allow(t)
            marks.append("#" if ok else ".")
            total += ok
        print(f"  second {second}: {''.join(marks)}  {marks.count('#'):>2} allowed")
    print(f"  total allowed: {total} of 64 (burst {burst} + about {rate}/s x 4 s)")


def paced_bulk_job(calls=20, rate=10, burst=5):
    """Part 2: wrap a bulk job so it never exceeds the limit, using the real clock."""
    bucket = TokenBucket(rate, burst, now=time.monotonic())
    start = time.monotonic()
    for _ in range(calls):
        while not bucket.allow(time.monotonic()):
            time.sleep(bucket.wait_time())
        pass  # the API call would go here
    elapsed = time.monotonic() - start
    expected = (calls - burst) / rate
    print(f"Part 2, real clock: {calls} calls at {rate}/s with burst {burst}")
    print(f"~ took {elapsed:.2f} s (expect about {expected:.1f} s: {burst} immediately, "
          f"then {calls - burst} at {rate}/s)")


def main():
    print("Drill 5: token bucket rate limiter.")
    fake_clock_demo()
    paced_bulk_job()
    pause = okta_pause(remaining=40, limit=600, reset_epoch=1_700_000_012, now_epoch=1_700_000_000)
    print(f"Part 3, Okta headers: 40 of 600 calls left, window resets in 12 s -> pause {pause:.0f} s")


if __name__ == "__main__":
    main()
