// Drill 4 (retry, backoff, jitter): simulate a thundering herd.
//
// 1,000 clients each need one successful request. The server handles 100
// requests per second, but it is down for the first 10 seconds. Every failed
// request is retried with one of three strategies:
//
//	none         retry after a fixed 1 s
//	exponential  retry after 1, 2, 4, 8 ... s, capped at 60 s
//	full_jitter  retry after a random time between 0 and the exponential value
//
// This is an event-driven simulation: a min-heap (container/heap) holds every
// client's next attempt, ordered by (time, client id). Nothing really sleeps,
// so it runs instantly and is deterministic. Random numbers come from MINSTD,
// a tiny generator written identically in Python, PowerShell and Go, so all
// three print the same numbers.
//
// Pass -csv (or --csv) to also write retry_load.csv (requests per second per
// strategy) for plotting.
package main

import (
	"container/heap"
	"encoding/csv"
	"flag"
	"fmt"
	"log"
	"os"
	"slices"
	"strconv"
	"strings"
)

const (
	clients      = 1_000
	capacity     = 100  // successful requests per 1-second window
	outageEnd    = 10.0 // server is down for t in [0, 10)
	base         = 1.0  // first retry delay, seconds
	maxDelay     = 60.0 // longest retry delay, seconds (Python's CAP; cap is a Go builtin)
	seed         = 42
	chartSeconds = 60
)

// minStd is the Park-Miller "minimal standard" generator (multiplier 48271).
//
// Small and identical in every language. Fine for simulations, never for
// security (crypto/rand) or anything that needs good randomness (math/rand/v2).
type minStd struct{ state int64 }

const minStdM = 2_147_483_647

// random returns a float64 in (0, 1). state*48271 stays below 2^47, so int64
// can't overflow. The pointer receiver matters: with a value receiver the
// method would update a copy, and every call would return the same number.
func (r *minStd) random() float64 {
	r.state = r.state * 48271 % minStdM
	return float64(r.state) / minStdM
}

// retryDelay returns the seconds to wait after a client's failures-th failure (1-based).
func retryDelay(strategy string, failures int, rng *minStd) float64 {
	if strategy == "none" {
		return 1.0
	}
	// An int, so it can be shifted: float64(1 << n) doesn't compile, because
	// the untyped 1 would take float64 from the context.
	doubling := 1 << min(failures-1, 30)
	backoff := min(maxDelay, base*float64(doubling)) // 1, 2, 4, ... capped at 60
	if strategy == "exponential" {
		return backoff
	}
	// Full jitter: uniform in (0, backoff). The float64() conversion rounds the
	// product on its own, as Python does. The Go spec lets the compiler fuse
	// x*y + z into one FMA instruction, even across an inlined call, so the
	// caller's t + r*backoff could skip that rounding and differ in the last
	// bit (Go fuses on arm64, Apple Silicon included). An explicit conversion
	// is the spec's way to forbid the fusion.
	return float64(rng.random() * backoff)
}

// event is one client's next attempt.
type event struct {
	t      float64
	client int
}

// eventHeap is a min-heap ordered by (time, client id). container/heap only
// provides the algorithms; the type supplies Len, Less, Swap, Push and Pop.
type eventHeap []event

func (h eventHeap) Len() int { return len(h) }
func (h eventHeap) Less(i, j int) bool {
	if h[i].t != h[j].t {
		return h[i].t < h[j].t
	}
	return h[i].client < h[j].client
}
func (h eventHeap) Swap(i, j int) { h[i], h[j] = h[j], h[i] }

// Push and Pop change the slice's length, so they need pointer receivers.
// Call heap.Push and heap.Pop; these two are only hooks for the heap package.
func (h *eventHeap) Push(x any) { *h = append(*h, x.(event)) }
func (h *eventHeap) Pop() any {
	old := *h
	e := old[len(old)-1]
	*h = old[:len(old)-1]
	return e
}

type simResult struct {
	arrivals   map[int]int // second -> requests that reached the server
	total      int
	peak       int
	peakSecond int
	finish     float64
}

func simulate(strategy string) simResult {
	rng := &minStd{state: seed}
	events := make(eventHeap, clients)
	for c := range events {
		events[c] = event{t: 0, client: c} // everyone fires at t=0
	}
	heap.Init(&events)
	failures := make([]int, clients)
	arrivals := map[int]int{}
	served := map[int]int{} // second -> requests that succeeded
	finish := 0.0
	for events.Len() > 0 {
		e := heap.Pop(&events).(event)
		second := int(e.t) // converting truncates toward zero, which is floor since t >= 0
		arrivals[second]++ // a missing key reads as 0
		if e.t >= outageEnd && served[second] < capacity {
			served[second]++
			finish = e.t
			continue // this client is done
		}
		failures[e.client]++ // server down, or over capacity
		heap.Push(&events, event{e.t + retryDelay(strategy, failures[e.client], rng), e.client})
	}

	// The herd that matters is the one that hits the server as it recovers.
	// Highest count wins and ties go to the earlier second. That is a total
	// order, so the random order of a map range can't change the answer.
	total, peak, peakSecond := 0, 0, 0
	for sec, n := range arrivals {
		total += n
		if float64(sec) >= outageEnd && (n > peak || (n == peak && sec < peakSecond)) {
			peak, peakSecond = n, sec
		}
	}
	return simResult{arrivals: arrivals, total: total, peak: peak, peakSecond: peakSecond, finish: finish}
}

// fixed1 is num/den with one decimal, rounded half up, using integers only.
func fixed1(num, den int) string {
	tenths := (num*20 + den) / (2 * den)
	return fmt.Sprintf("%d.%d", tenths/10, tenths%10)
}

// sparkline draws one character per second. Eight heights, each step worth
// top/8 requests, rounded up.
func sparkline(arrivals map[int]int, seconds, top int) string {
	// A []rune, not a string: each block is 3 bytes of UTF-8, and indexing a
	// string gives you bytes, not characters.
	blocks := []rune(" ▁▂▃▄▅▆▇█")
	var b strings.Builder
	for second := range seconds {
		v := arrivals[second]
		level := 0
		if v > 0 {
			level = min(8, (v*8+top-1)/top) // integer ceil, clamped: 1..8
		}
		b.WriteRune(blocks[level])
	}
	return b.String()
}

func main() {
	// The flag package accepts both -csv and --csv.
	writeCSV := flag.Bool("csv", false, "also write retry_load.csv (requests per second per strategy)")
	flag.Parse()
	strategies := []string{"none", "exponential", "full_jitter"}

	fmt.Printf("Drill 4: thundering herd. %s clients, server handles %d/s, down for the first %.0f s.\n",
		commas(clients), capacity, outageEnd)
	results := make(map[string]simResult, len(strategies))
	for _, s := range strategies {
		results[s] = simulate(s)
	}

	fmt.Printf("%-12s %8s %10s   %-21s %11s\n", "strategy", "requests", "per client", "peak after recovery", "all done at")
	for _, s := range strategies {
		r := results[s]
		peak := fmt.Sprintf("%s/s at t=%d", commas(r.peak), r.peakSecond)
		fmt.Printf("%-12s %8s %10s   %-21s %10.1fs\n", s, commas(r.total), fixed1(r.total, clients), peak, r.finish)
	}

	top := clients
	fmt.Printf("Requests per second, first %d s (each block step is %d/s, rounded up; capacity is %d/s):\n",
		chartSeconds, top/8, capacity)
	for _, s := range strategies {
		fmt.Printf("%-12s |%s|\n", s, sparkline(results[s].arrivals, chartSeconds, top))
	}

	var waves []int
	for sec, v := range results["exponential"].arrivals {
		if v >= capacity {
			waves = append(waves, sec)
		}
	}
	slices.Sort(waves) // map order is random: sort before printing
	fmt.Println("exponential sends synchronized waves at t = " + joinInts(waves, ", "))

	if *writeCSV {
		if err := writeLoadCSV("retry_load.csv", strategies, results); err != nil {
			log.Fatal(err)
		}
		fmt.Println("~ wrote retry_load.csv")
	}
}

// writeLoadCSV writes one row per second with the requests each strategy sent.
func writeLoadCSV(path string, strategies []string, results map[string]simResult) error {
	last := 0
	for _, r := range results {
		for sec := range r.arrivals {
			last = max(last, sec)
		}
	}
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	w := csv.NewWriter(f) // "\n" line endings by default
	w.Write(append([]string{"second"}, strategies...))
	for sec := range last + 1 {
		row := []string{strconv.Itoa(sec)}
		for _, s := range strategies {
			row = append(row, strconv.Itoa(results[s].arrivals[sec]))
		}
		w.Write(row)
	}
	// csv.Writer buffers, and a write error sticks: check it once after Flush.
	w.Flush()
	if err := w.Error(); err != nil {
		f.Close()
		return err
	}
	return f.Close() // a failed Close can mean lost data, so check it on files you write
}

func joinInts(xs []int, sep string) string {
	parts := make([]string, len(xs))
	for i, x := range xs {
		parts[i] = strconv.Itoa(x)
	}
	return strings.Join(parts, sep)
}

// commas formats n with thousands separators, like Python's f"{n:,}".
func commas(n int) string {
	s := strconv.Itoa(n)
	head := len(s) - len(strings.TrimLeft(s, "-"))
	for i := len(s) - 3; i > head; i -= 3 {
		s = s[:i] + "," + s[i:]
	}
	return s
}
