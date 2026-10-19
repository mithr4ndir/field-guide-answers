// Drill 9 (probabilistic structures): a Bloom filter, measured against the formula.
//
// Sizes a filter for 100,000 items at a 1% false-positive target, inserts
// 100,000 device ids, then asks about 100,000 ids that were never inserted
// and counts how many it wrongly says "probably yes" to.
//
//	m = -n ln(p) / (ln 2)^2   bits
//	k = (m / n) ln 2          hash functions
//	predicted false-positive rate = (1 - e^(-k n / m))^k
//
// The k bit positions come from one SHA-256 digest (double hashing):
// h1 = bytes 0-7 and h2 = bytes 8-15, each read as a big-endian unsigned
// 64-bit number and reduced mod m, then index_i = (h1 + i * h2) mod m.
// Reducing first keeps the math inside 64 bits in every language.
package main

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
)

const (
	numItems = 100_000 // Python's N
	fpTarget = 0.01    // Python's P
)

type bloomFilter struct {
	m    uint64 // bits
	k    int    // hash functions
	bits []byte
}

func newBloomFilter(n int, p float64) *bloomFilter {
	// math.Log(2) at run time, not the math.Ln2 constant: math.Ln2*math.Ln2 is
	// a constant expression, evaluated exactly at compile time, and it rounds
	// to a float64 one ulp away from Python's math.log(2) ** 2. Mirror float
	// math step by step at run time when results must match another language.
	//
	// Go's math package is its own code, not the C library Python calls, so
	// Log, Exp and Pow can differ from Python in the last bit (math.Log(0.01)
	// does). Here m is rounded up and the predictions print 3 decimals, so it
	// doesn't show.
	ln2 := math.Log(2)
	m := uint64(math.Ceil(-float64(n) * math.Log(p) / (ln2 * ln2)))
	// math.Round rounds halves away from zero; Python's round() rounds halves
	// to even. k is about 6.64 here, so both give 7, but RoundToEven is the match.
	k := int(math.RoundToEven(float64(m) / float64(n) * ln2))
	return &bloomFilter{m: m, k: k, bits: make([]byte, (m+7)/8)}
}

// positions returns the k bit indexes for item.
func (b *bloomFilter) positions(item string) []uint64 {
	d := sha256.Sum256([]byte(item))
	h1 := binary.BigEndian.Uint64(d[0:8]) % b.m
	h2 := binary.BigEndian.Uint64(d[8:16]) % b.m
	if h2 == 0 {
		h2 = 1 // a zero step would put all k probes on the same bit
	}
	pos := make([]uint64, b.k)
	for i := range pos {
		pos[i] = (h1 + uint64(i)*h2) % b.m // h1 and h2 are below m, so no uint64 overflow
	}
	return pos
}

func (b *bloomFilter) add(item string) {
	for _, pos := range b.positions(item) {
		b.bits[pos>>3] |= 1 << (pos & 7)
	}
}

// contains reports whether item is probably in the set. Go has no operator
// overloading, so Python's `item in bf` (__contains__) is a plain method.
func (b *bloomFilter) contains(item string) bool {
	for _, pos := range b.positions(item) {
		// Unlike C, Go's & binds tighter than ==, so this means what it looks like.
		if b.bits[pos>>3]&(1<<(pos&7)) == 0 {
			return false
		}
	}
	return true
}

// countIn returns how many of prefix0 .. prefix(n-1) the filter says it holds.
func countIn(bf *bloomFilter, prefix string, n int) int {
	count := 0
	for i := range n {
		if bf.contains(prefix + strconv.Itoa(i)) {
			count++
		}
	}
	return count
}

func predictedRate(m uint64, k, n int) float64 {
	return math.Pow(1-math.Exp(-float64(k*n)/float64(m)), float64(k))
}

// rateText is count/total as a percent with three decimals, rounded half up, integers only.
func rateText(count, total int) string {
	thousandths := (count*200_000 + total) / (2 * total)
	return fmt.Sprintf("%d.%03d%%", thousandths/1000, thousandths%1000)
}

func main() {
	fmt.Printf("Drill 9: Bloom filter sized for %s items at %.0f%% false positives.\n", commas(numItems), fpTarget*100)
	start := time.Now()
	bf := newBloomFilter(numItems, fpTarget)
	fmt.Printf("m = %s bits (%s KiB), k = %d hash functions\n", commas(int(bf.m)), commas(int(bf.m/8/1024)), bf.k)

	for i := range numItems {
		bf.add("device-" + strconv.Itoa(i))
	}
	misses := numItems - countIn(bf, "device-", numItems)
	fmt.Printf("False negatives on the %s inserted ids: %d (must be 0)\n", commas(numItems), misses)

	fp := countIn(bf, "other-", numItems)
	fmt.Printf("False positives on %s ids never inserted: %s = %s   predicted %.3f%%\n",
		commas(numItems), commas(fp), rateText(fp, numItems), predictedRate(bf.m, bf.k, numItems)*100)

	for i := numItems; i < 2*numItems; i++ { // overfill to twice the design size
		bf.add("device-" + strconv.Itoa(i))
	}
	fp2 := countIn(bf, "other-", numItems)
	fmt.Printf("Overfilled to %s items: %s = %s   predicted %.3f%%\n",
		commas(2*numItems), commas(fp2), rateText(fp2, numItems), predictedRate(bf.m, bf.k, 2*numItems)*100)
	fmt.Printf("~ ran in %.2f s\n", time.Since(start).Seconds())
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
