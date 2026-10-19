// Drill 5 (rate limiting): a token bucket, tested with a fake clock.
//
// The bucket holds up to burst tokens and refills at rate tokens per second.
// Each request spends one token; with no token, the request is denied (or the
// caller waits). Refill is lazy: it is computed from the elapsed time on each
// call, so there is no background timer or goroutine.
//
// The current time is passed in rather than read inside the type. That one
// choice makes it testable: part 1 drives it with exact fake timestamps, part 2
// drives it with the real clock to pace a bulk job.
//
// In production Go code, use golang.org/x/time/rate: rate.NewLimiter(10, 5)
// is this same token bucket with Allow, Wait(ctx) and Reserve built in, and
// its AllowN(t, n) takes the time as an argument for the same testability reason.
package main

import (
	"fmt"
	"strings"
	"sync"
	"time"
)

// tokenBucket is safe for concurrent use. Without the mutex, two goroutines
// calling allow at once would race on tokens and last (each call reads, then
// writes them) and could spend the same token twice. Don't copy a
// tokenBucket after first use, since that copies the mutex too; pass a
// pointer around (go vet's copylocks check flags copies).
type tokenBucket struct {
	mu     sync.Mutex
	rate   float64 // tokens added per second
	burst  float64 // bucket size = largest allowed burst
	tokens float64
	last   float64 // time of the last refill, in seconds
}

func newTokenBucket(rate, burst, now float64) *tokenBucket {
	return &tokenBucket{rate: rate, burst: burst, tokens: burst, last: now} // start full
}

// allow spends one token if one is available. Go has no default arguments,
// so Python's cost=1.0 becomes a second method, allowN (the x/time/rate style).
func (b *tokenBucket) allow(now float64) bool { return b.allowN(now, 1) }

// allowN spends cost tokens if available and reports whether the request may proceed.
func (b *tokenBucket) allowN(now, cost float64) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	// float64(...) rounds the product on its own, so the compiler can't fuse
	// tokens + elapsed*rate into one FMA instruction (Go does that on arm64).
	// Part 1's numbers are exact multiples of 1/16, so fusing wouldn't change
	// them, but with other rates the last bit could differ from Python's.
	b.tokens = min(b.burst, b.tokens+float64((now-b.last)*b.rate))
	b.last = now
	if b.tokens >= cost {
		b.tokens -= cost
		return true
	}
	return false
}

// waitTime returns the seconds until cost tokens will be available (call it after allow returns false).
func (b *tokenBucket) waitTime(cost float64) float64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	return max(0, (cost-b.tokens)/b.rate)
}

// oktaPause returns how long to pause based on Okta's X-Rate-Limit-* response
// headers: X-Rate-Limit-Remaining, X-Rate-Limit-Limit and X-Rate-Limit-Reset
// (a Unix time; turn it into a time.Time with strconv.ParseInt and time.Unix).
//
// Keep going while more than floor of the limit is left; below that,
// wait until the window resets instead of running into 429s.
func oktaPause(remaining, limit int, reset, now time.Time, floor float64) time.Duration {
	if float64(remaining) > float64(limit)*floor {
		return 0
	}
	return max(0, reset.Sub(now))
}

func fakeClockDemo() {
	const rate, burst = 4, 8
	// 16 requests per second offered; exactly representable in binary. Write
	// 1.0/16, not 1/16: with two integer constants that is integer division, 0.
	const step = 1.0 / 16
	bucket := newTokenBucket(rate, burst, 0)
	fmt.Printf("Part 1, fake clock: rate %d/s, burst %d, one request every 1/16 s for 4 s (# allowed, . denied)\n",
		rate, burst)
	total := 0
	for second := range 4 {
		var marks strings.Builder
		allowed := 0 // Go won't add a bool to an int, so count explicitly
		for i := range 16 {
			t := float64(second*16+i) * step
			if bucket.allow(t) {
				marks.WriteByte('#')
				allowed++
			} else {
				marks.WriteByte('.')
			}
		}
		total += allowed
		fmt.Printf("  second %d: %s  %2d allowed\n", second, marks.String(), allowed)
	}
	fmt.Printf("  total allowed: %d of 64 (burst %d + about %d/s x 4 s)\n", total, burst, rate)
}

// pacedBulkJob wraps a bulk job so it never exceeds the limit, using the real clock.
func pacedBulkJob(calls, rate, burst int) {
	// time.Now carries a monotonic clock reading and time.Since uses it, so
	// this works like Python's time.monotonic(): a wall-clock change mid-run
	// can't make the elapsed time jump.
	origin := time.Now()
	now := func() float64 { return time.Since(origin).Seconds() }
	bucket := newTokenBucket(float64(rate), float64(burst), now())
	start := time.Now()
	for range calls {
		for !bucket.allow(now()) {
			// A Duration is integer nanoseconds, so float seconds need converting.
			time.Sleep(time.Duration(bucket.waitTime(1) * float64(time.Second)))
		}
		// the API call would go here
	}
	elapsed := time.Since(start)
	expected := float64(calls-burst) / float64(rate)
	fmt.Printf("Part 2, real clock: %d calls at %d/s with burst %d\n", calls, rate, burst)
	fmt.Printf("~ took %.2f s (expect about %.1f s: %d immediately, then %d at %d/s)\n",
		elapsed.Seconds(), expected, burst, calls-burst, rate)
}

func main() {
	fmt.Println("Drill 5: token bucket rate limiter.")
	fakeClockDemo()
	pacedBulkJob(20, 10, 5)
	pause := oktaPause(40, 600, time.Unix(1_700_000_012, 0), time.Unix(1_700_000_000, 0), 0.1)
	fmt.Printf("Part 3, Okta headers: 40 of 600 calls left, window resets in 12 s -> pause %.0f s\n", pause.Seconds())
}
