// Drill 3 (queues and backpressure): what happens when a bounded queue fills up.
//
// A producer makes 50 items, one every 20 ms. A consumer needs 60 ms per item,
// so it is 3x too slow. The queue holds 5 items. Each run uses one of the four
// things you can do when the queue is full:
//
//	block        producer waits for space (backpressure). Nothing lost; the
//	             producer slows to the consumer's pace.
//	drop_newest  reject the new item. Keeps the oldest data.
//	drop_oldest  evict the oldest queued item to make room. Keeps the newest data.
//	spill        overflow goes to a file on disk and is drained in order.
//	             Nothing lost, producer never waits, but disk is slower and finite.
//
// The first three use a buffered channel, which is Go's built-in bounded FIFO.
// Spill needs two tiers (memory, then disk), so it is a mutex, a sync.Cond
// and a temp file.
//
// Goroutine timing varies, so the counts are approximate (lines starting with "~").
// The invariants on the other lines hold on every run.
package main

import (
	"bufio"
	"errors"
	"fmt"
	"log"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	items        = 50
	produceEvery = 20 * time.Millisecond // a time.Duration: an int64 count of nanoseconds
	consumeTime  = 60 * time.Millisecond // of work per item
	capacity     = 5
)

// spillQueue is a bounded in-memory queue that overflows to a file instead of blocking.
//
// Order is preserved: once anything is on disk, new items also go to disk
// until the consumer has drained it, and the consumer always empties memory
// before reading the file. So memory always holds the oldest items.
//
// sync.Cond is rare in Go; a channel covers most cases. Here the consumer has
// to wait for "memory or disk has an item", which one channel can't express.
type spillQueue struct {
	mu       sync.Mutex
	ready    *sync.Cond // signaled when an item arrives or the queue closes
	capacity int
	memory   []int         // FIFO: append at the back, take from the front
	writer   *os.File      // os.File writes are unbuffered syscalls, so no flush needed
	readFile *os.File      // a second handle on the same file, for reading
	reader   *bufio.Reader // not bufio.Scanner: a Scanner stops for good at the first EOF
	onDisk   int           // items written to the file and not yet read back
	spilled  int           // total items that ever went to disk
	closed   bool
}

func newSpillQueue(capacity int, path string) (*spillQueue, error) {
	w, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	r, err := os.Open(path)
	if err != nil {
		w.Close()
		return nil, err
	}
	q := &spillQueue{capacity: capacity, writer: w, readFile: r, reader: bufio.NewReader(r)}
	q.ready = sync.NewCond(&q.mu)
	return q, nil
}

// put adds an item. It never waits for space: when memory is full it writes to disk.
func (q *spillQueue) put(item int) error {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.onDisk == 0 && len(q.memory) < q.capacity {
		q.memory = append(q.memory, item)
	} else {
		if _, err := fmt.Fprintf(q.writer, "%d\n", item); err != nil {
			return err
		}
		q.onDisk++
		q.spilled++
	}
	q.ready.Signal()
	return nil
}

// get returns the next item in order, waiting if there is none yet. ok is
// false once the queue is closed and empty: the same comma-ok shape as
// receiving from a closed channel, instead of Python's DONE sentinel.
func (q *spillQueue) get() (item int, ok bool, err error) {
	q.mu.Lock()
	defer q.mu.Unlock()
	// Wait in a loop: the condition can change again between the Signal and
	// this goroutine getting the lock back.
	for len(q.memory) == 0 && q.onDisk == 0 {
		if q.closed {
			return 0, false, nil
		}
		q.ready.Wait() // unlocks mu while waiting, locks it again before returning
	}
	if len(q.memory) > 0 {
		item, q.memory = q.memory[0], q.memory[1:]
		return item, true, nil
	}
	line, err := q.reader.ReadString('\n')
	if err != nil {
		return 0, false, err
	}
	q.onDisk--
	item, err = strconv.Atoi(strings.TrimSuffix(line, "\n"))
	return item, err == nil, err
}

// close tells the consumer that no more items are coming. The consumer may
// still be reading; the files are removed after it finishes.
func (q *spillQueue) close() {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.closed = true
	q.ready.Broadcast()
}

// removeFile closes both handles and deletes the spill file.
func (q *spillQueue) removeFile() error {
	return errors.Join(q.writer.Close(), q.readFile.Close(), os.Remove(q.writer.Name()))
}

type result struct {
	strategy  string
	delivered []int
	dropped   int
	spilled   int
	producer  time.Duration
	total     time.Duration
	avgAge    time.Duration // how long an item sat in the queue before the consumer took it
}

func run(strategy string) (result, error) {
	if strategy == "spill" {
		return runSpill()
	}
	return runChannel(strategy), nil
}

// runChannel runs block, drop_newest or drop_oldest on a buffered channel.
func runChannel(strategy string) result {
	ch := make(chan int, capacity)
	born := make([]time.Time, items) // when each item was produced
	var delivered []int
	var ages []time.Duration // how old each item was when the consumer picked it up
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { // the consumer
		defer wg.Done()
		for item := range ch { // ends once ch is closed and drained
			// born[item] is safe to read: the producer wrote it before the send,
			// and a send happens before the matching receive completes.
			ages = append(ages, time.Since(born[item]))
			time.Sleep(consumeTime) // simulate slow work
			delivered = append(delivered, item)
		}
	}()

	dropped := 0
	start := time.Now()
	for i := range items {
		born[i] = time.Now()
		switch strategy {
		case "block":
			ch <- i // waits for space
		case "drop_newest":
			select {
			case ch <- i:
			default: // full: the new item is lost
				dropped++
			}
		case "drop_oldest":
			dropped += sendDropOldest(ch, i)
		}
		time.Sleep(produceEvery)
	}
	producer := time.Since(start)

	close(ch) // Go's DONE sentinel: the consumer gets what is still queued, then its loop ends
	wg.Wait() // also makes the consumer's writes to delivered and ages visible here
	return result{strategy: strategy, delivered: delivered, dropped: dropped,
		producer: producer, total: time.Since(start), avgAge: average(ages)}
}

// sendDropOldest queues v, throwing away the oldest queued items until it
// fits, and returns how many it threw away.
func sendDropOldest(ch chan int, v int) (evicted int) {
	for {
		select {
		case ch <- v:
			return evicted // a bare break here would only leave the select, not the loop
		default:
		}
		select {
		case <-ch: // throw away the oldest queued item
			evicted++
		default: // the consumer took one first; just retry
		}
	}
}

// runSpill runs the spill strategy on a spillQueue backed by a temp file.
func runSpill() (result, error) {
	f, err := os.CreateTemp("", "spill-*.log")
	if err != nil {
		return result{}, err
	}
	path := f.Name()
	f.Close()
	q, err := newSpillQueue(capacity, path)
	if err != nil {
		os.Remove(path)
		return result{}, err
	}

	born := make([]time.Time, items)
	var delivered []int
	var ages []time.Duration
	var consumerErr error
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { // the consumer
		defer wg.Done()
		for {
			item, ok, err := q.get()
			if err != nil || !ok {
				consumerErr = err
				return
			}
			ages = append(ages, time.Since(born[item])) // safe: put and get share the mutex
			time.Sleep(consumeTime)                     // simulate slow work
			delivered = append(delivered, item)
		}
	}()

	var putErr error
	start := time.Now()
	for i := range items {
		born[i] = time.Now()
		if putErr = q.put(i); putErr != nil { // spill never waits
			break
		}
		time.Sleep(produceEvery)
	}
	producer := time.Since(start)

	q.close()
	wg.Wait() // the consumer is done; its results are safe to read
	total := time.Since(start)
	if err := errors.Join(putErr, consumerErr, q.removeFile()); err != nil {
		return result{}, err
	}
	return result{strategy: "spill", delivered: delivered, spilled: q.spilled,
		producer: producer, total: total, avgAge: average(ages)}, nil
}

// average returns the mean duration, or 0 for none. Dividing a Duration by an
// int variable needs a conversion: Duration and int are different types.
func average(ds []time.Duration) time.Duration {
	if len(ds) == 0 {
		return 0
	}
	var sum time.Duration
	for _, d := range ds {
		sum += d
	}
	return sum / time.Duration(len(ds))
}

// ranges compresses [0 1 2 5 7 8 9] into "0-2,5,7-9".
func ranges(ids []int) string {
	var parts []string
	for i := 0; i < len(ids); {
		j := i
		for j+1 < len(ids) && ids[j+1] == ids[j]+1 {
			j++
		}
		if i == j {
			parts = append(parts, strconv.Itoa(ids[i]))
		} else {
			parts = append(parts, fmt.Sprintf("%d-%d", ids[i], ids[j]))
		}
		i = j + 1
	}
	return strings.Join(parts, ",")
}

func main() {
	fmt.Printf("Drill 3: queues and backpressure. %d items, producer every %d ms, consumer %d ms/item, queue holds %d.\n",
		items, produceEvery.Milliseconds(), consumeTime.Milliseconds(), capacity)
	var rows []result
	for _, strategy := range []string{"block", "drop_newest", "drop_oldest", "spill"} {
		r, err := run(strategy)
		if err != nil {
			log.Fatal(err)
		}
		inOrder := slices.IsSorted(r.delivered)
		accounted := len(r.delivered)+r.dropped == items
		switch strategy {
		case "block", "spill":
			fmt.Printf("%-12s lost %d, in order: %s\n", strategy, items-len(r.delivered), yesNo(inOrder))
		case "drop_newest":
			firstKept := true
			for id := range capacity {
				firstKept = firstKept && slices.Contains(r.delivered, id)
			}
			fmt.Printf("%-12s delivered + dropped = %d: %s, ids 0-%d all delivered: %s (the queue still has room when they arrive)\n",
				strategy, items, yesNo(accounted), capacity-1, yesNo(firstKept))
		default:
			fmt.Printf("%-12s delivered + dropped = %d: %s, last delivered id: %d (the newest item always survives)\n",
				strategy, items, yesNo(accounted), r.delivered[len(r.delivered)-1])
		}
		rows = append(rows, r)
	}

	fmt.Printf("~ %-12s %9s %7s %7s %11s %8s %11s  delivered ids\n",
		"strategy", "delivered", "dropped", "spilled", "producer(s)", "total(s)", "avg age(ms)")
	for _, r := range rows {
		fmt.Printf("~ %-12s %9d %7d %7d %11.2f %8.2f %11.0f  %s\n", r.strategy, len(r.delivered), r.dropped,
			r.spilled, r.producer.Seconds(), r.total.Seconds(), r.avgAge.Seconds()*1000, ranges(r.delivered))
	}
}

// yesNo exists because Go has no conditional (ternary) expression.
func yesNo(ok bool) string {
	if ok {
		return "yes"
	}
	return "no"
}
