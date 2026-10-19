// Drill 6 (caching): LRU two ways, SIEVE vs. LRU, and a single-flight wrapper.
//
//	Part 1  LRU built on container/list plus a map (Go's stand-in for Python's
//	        OrderedDict), and LRU built by hand from a map plus a doubly
//	        linked list. Both must give identical hit counts.
//	Part 2  SIEVE: one queue, a "visited" bit per entry, and a moving hand. It is
//	        compared with LRU on a trace where 30% of requests are one-hit
//	        wonders, which is what real cache traces look like.
//	Part 3  Single-flight: 10 goroutines miss the same key at the same moment.
//	        Only one calls the slow backend; the others wait and share its result.
//
// The trace comes from MINSTD plus a Zipf distribution, so Python, PowerShell
// and Go replay exactly the same 100,000 requests and print the same hit ratios.
package main

import (
	"container/list"
	"errors"
	"fmt"
	"log"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	requests    = 100_000
	popular     = 10_000 // object ids 0..9,999, requested with Zipf popularity
	oneHitShare = 0.30   // share of requests for ids that never repeat
	seed        = 7
)

// minStd is the Park-Miller "minimal standard" generator (multiplier 48271). Same in every language.
type minStd struct{ state int64 }

const minStdM = 2_147_483_647

func (r *minStd) random() float64 {
	r.state = r.state * 48271 % minStdM
	return float64(r.state) / minStdM
}

// makeTrace returns 70% Zipf(exponent 1) over popular ids, 30% brand-new ids (one-hit wonders).
func makeTrace() []int {
	rng := &minStd{state: seed}
	cdf := make([]float64, 0, popular)
	total := 0.0
	for rank := 1; rank <= popular; rank++ {
		total += 1.0 / float64(rank) // weight of rank r is 1/r
		cdf = append(cdf, total)
	}
	trace := make([]int, 0, requests)
	nextNewID := 1_000_000
	for range requests {
		if rng.random() < oneHitShare {
			trace = append(trace, nextNewID)
			nextNewID++
		} else {
			x := rng.random() * total
			// First index whose cdf > x: Python's bisect_right. (>= would be bisect_left.)
			trace = append(trace, sort.Search(len(cdf), func(i int) bool { return cdf[i] > x }))
		}
	}
	return trace
}

// cache is all the replay loop needs. Go interfaces are satisfied implicitly:
// any type with this method is a cache, with no "implements" declaration.
type cache interface {
	// access returns true on a hit. On a miss it inserts the key, evicting if full.
	access(key int) bool
}

func run(c cache, trace []int) int {
	hits := 0
	for _, key := range trace {
		if c.access(key) {
			hits++
		}
	}
	return hits
}

// lruStdlib is LRU on container/list plus a map, the usual Go answer to
// OrderedDict. The list keeps recency order (front = least recently used,
// back = most, like OrderedDict's end); the map finds a key's element in O(1).
type lruStdlib struct {
	capacity int
	order    *list.List
	elems    map[int]*list.Element
}

func newLRUStdlib(capacity int) *lruStdlib {
	return &lruStdlib{capacity: capacity, order: list.New(), elems: make(map[int]*list.Element, capacity+1)}
}

func (c *lruStdlib) access(key int) bool {
	if e, ok := c.elems[key]; ok {
		c.order.MoveToBack(e) // now the most recently used
		return true
	}
	c.elems[key] = c.order.PushBack(key)
	if c.order.Len() > c.capacity {
		oldest := c.order.Front() // drop the least recently used
		c.order.Remove(oldest)
		delete(c.elems, oldest.Value.(int)) // Value is an `any`; assert it back to int
	}
	return false
}

// node is a doubly linked list entry, used by lruLinked and sieve.
type node struct {
	key        int
	prev, next *node
	visited    bool
}

// lruLinked is LRU by hand: a map for O(1) lookup, a doubly linked list for O(1) reordering.
//
// Two sentinel nodes mean no special cases for an empty list:
// head.next is the most recently used entry, tail.prev the least.
type lruLinked struct {
	capacity   int
	nodes      map[int]*node
	head, tail *node
}

func newLRULinked(capacity int) *lruLinked {
	c := &lruLinked{capacity: capacity, nodes: make(map[int]*node, capacity+1), head: &node{}, tail: &node{}}
	c.head.next, c.tail.prev = c.tail, c.head
	return c
}

func (c *lruLinked) unlink(n *node) {
	// Go evaluates n.prev and n.next on the left before assigning anything,
	// so this swap-style assignment is safe, as in Python.
	n.prev.next, n.next.prev = n.next, n.prev
}

func (c *lruLinked) pushFront(n *node) {
	n.prev, n.next = c.head, c.head.next
	c.head.next.prev = n
	c.head.next = n
}

func (c *lruLinked) access(key int) bool {
	if n, ok := c.nodes[key]; ok {
		c.unlink(n)
		c.pushFront(n)
		return true
	}
	n := &node{key: key}
	c.nodes[key] = n
	c.pushFront(n)
	if len(c.nodes) > c.capacity {
		lru := c.tail.prev
		c.unlink(lru)
		delete(c.nodes, lru.key)
	}
	return false
}

// sieve is SIEVE (NSDI 2024). New entries go in at the head; a hit only sets a bit.
//
// To evict, the hand walks from the tail toward the head. Visited entries
// have their bit cleared and survive; the first unvisited entry is evicted,
// and the hand stays where it stopped for next time. One-hit wonders are
// never visited, so they leave quickly without pushing popular entries out.
type sieve struct {
	capacity int
	nodes    map[int]*node
	head     *node // newest; node.next points toward the tail (older)
	tail     *node // oldest; node.prev points toward the head (newer)
	hand     *node
}

func newSieve(capacity int) *sieve {
	return &sieve{capacity: capacity, nodes: make(map[int]*node, capacity)}
}

func (s *sieve) access(key int) bool {
	if n, ok := s.nodes[key]; ok {
		n.visited = true // no list surgery on a hit
		return true
	}
	if len(s.nodes) >= s.capacity {
		s.evict()
	}
	n := &node{key: key, next: s.head}
	s.nodes[key] = n
	if s.head != nil {
		s.head.prev = n
	}
	s.head = n
	if s.tail == nil {
		s.tail = n
	}
	return false
}

func (s *sieve) evict() {
	n := s.hand // Python's `self.hand or self.tail`: Go has no truthiness, so compare with nil
	if n == nil {
		n = s.tail
	}
	for n.visited {
		n.visited = false // second chance
		n = n.prev        // toward the head...
		if n == nil {
			n = s.tail // ...wrapping to the tail
		}
	}
	s.hand = n.prev
	if n.prev != nil {
		n.prev.next = n.next
	} else {
		s.head = n.next
	}
	if n.next != nil {
		n.next.prev = n.prev
	} else {
		s.tail = n.prev
	}
	delete(s.nodes, n.key)
}

// call is one in-flight backend call that late arrivals can wait on.
type call struct {
	wg  sync.WaitGroup // held at 1 until the leader's fn returns
	val any
	err error
}

// group collapses concurrent calls for the same key into one call. It has the
// same design as golang.org/x/sync/singleflight, which is what to use in
// production (it adds a shared flag, DoChan, Forget, and panic handling).
//
// The first caller (the leader) runs fn; anyone arriving while it runs
// waits on the same call and gets the same result or error.
// The zero value is ready to use.
type group struct {
	mu    sync.Mutex
	calls map[string]*call
}

func (g *group) do(key string, fn func() (any, error)) (any, error) {
	g.mu.Lock()
	if g.calls == nil {
		g.calls = make(map[string]*call)
	}
	if c, ok := g.calls[key]; ok {
		g.mu.Unlock()
		c.wg.Wait() // a follower: wait for the leader, then share its result
		return c.val, c.err
	}
	c := &call{}
	c.wg.Add(1)
	g.calls[key] = c
	g.mu.Unlock()

	c.val, c.err = fn() // the leader calls fn without holding the lock

	g.mu.Lock()
	c.wg.Done()          // wakes the followers; Wait also makes val and err visible to them
	delete(g.calls, key) // the next miss starts a fresh call
	g.mu.Unlock()
	return c.val, c.err
}

// hitPct is hits/total as a percent with two decimals, rounded half up,
// integers only. It returns the text and the value in hundredths.
func hitPct(hits, total int) (string, int) {
	hundredths := (hits*20000 + total) / (2 * total)
	return fmt.Sprintf("%d.%02d%%", hundredths/100, hundredths%100), hundredths
}

func singleFlightDemo(callers int) {
	var calls atomic.Int32 // incremented from many goroutines at once
	slowBackend := func() (any, error) {
		calls.Add(1)
		time.Sleep(200 * time.Millisecond) // a slow catalog rebuild
		return "catalog-v42", nil
	}

	for _, useSingleFlight := range []bool{false, true} {
		calls.Store(0)
		var flight group
		fetch := slowBackend
		if useSingleFlight {
			fetch = func() (any, error) { return flight.do("catalog", slowBackend) }
		}

		values := make([]any, callers) // one slot per goroutine: appending to a shared slice would race
		errs := make([]error, callers)
		var ready, done sync.WaitGroup
		ready.Add(callers)
		done.Add(callers)
		start := make(chan struct{})
		for i := range callers {
			go func() { // since Go 1.22 every iteration has its own i, so capturing it is safe
				defer done.Done()
				ready.Done()
				<-start // everyone misses at the same moment
				values[i], errs[i] = fetch()
			}()
		}
		// Go has no Barrier type. Wait until every goroutine is parked on start,
		// then close it: a closed channel releases all its receivers at once.
		ready.Wait()
		close(start)
		done.Wait()
		if err := errors.Join(errs...); err != nil {
			log.Fatal(err)
		}

		same := true
		for _, v := range values {
			same = same && v == values[0]
		}
		label := "without single-flight:"
		if useSingleFlight {
			label = "with single-flight:   "
		}
		n := calls.Load()
		plural := "s"
		if n == 1 {
			plural = ""
		}
		fmt.Printf("%s %d callers -> %d backend call%s, all got the same value: %s\n",
			label, callers, n, plural, yesNo(same))
	}
}

func main() {
	fmt.Printf("Drill 6: caching. %s requests: 70%% Zipf over %s objects, 30%% one-hit wonders.\n",
		commas(requests), commas(popular))
	trace := makeTrace()
	fmt.Printf("%10s  %17s  %17s  %7s  SIEVE vs LRU\n", "cache size", "LRU (library)", "LRU (hand-built)", "SIEVE")
	agree := true
	for _, size := range []int{100, 1_000} {
		lruStd := run(newLRUStdlib(size), trace)
		lruLL := run(newLRULinked(size), trace)
		sv := run(newSieve(size), trace)
		agree = agree && lruStd == lruLL
		stdTxt, stdH := hitPct(lruStd, requests)
		llTxt, _ := hitPct(lruLL, requests)
		svTxt, svH := hitPct(sv, requests)
		diff := svH - stdH
		sign := "+"
		if diff < 0 {
			sign, diff = "-", -diff
		}
		fmt.Printf("%10s  %17s  %17s  %7s  %s%d.%02d points\n", commas(size), stdTxt, llTxt, svTxt, sign, diff/100, diff%100)
	}
	fmt.Printf("Both LRU implementations agree: %s\n", yesNo(agree))
	singleFlightDemo(10)
}

// yesNo exists because Go has no conditional (ternary) expression.
func yesNo(ok bool) string {
	if ok {
		return "yes"
	}
	return "no"
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
