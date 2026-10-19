// Drill 2 (consistent hashing): count how many keys move when an 11th node joins.
//
// Assigns 100,000 keys to 10 nodes two ways, adds node-10, and counts moves:
//
//	hash % N   owner = hash(key) % N. Changing N reshuffles almost everything.
//	hash ring  each node gets 160 virtual points on a ring; a key belongs to the
//	           first point clockwise from its hash. A new node only takes over
//	           the arcs in front of its own points, about 1/N of the keys.
//
// The hash is the first 4 bytes of SHA-256, read big-endian, so every language
// gets identical numbers.
package main

import (
	"cmp"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"slices"
	"sort"
	"strconv"
	"strings"
)

const (
	keys   = 100_000
	vnodes = 160
)

// h32 returns the first 4 bytes of SHA-256 as an unsigned 32-bit integer.
func h32(text string) uint32 {
	// Sum256 returns a [32]byte array value. You can't slice a function's
	// return value directly (sha256.Sum256(b)[:4] won't compile), so name it first.
	sum := sha256.Sum256([]byte(text))
	return binary.BigEndian.Uint32(sum[:4])
}

// hashRing keeps the ring as two parallel slices sorted by position:
// owners[i] is the node that placed the point at positions[i].
type hashRing struct {
	positions []uint32
	owners    []string
}

func newHashRing(nodes []string, vnodes int) *hashRing {
	type point struct {
		pos  uint32
		node string
	}
	points := make([]point, 0, len(nodes)*vnodes)
	for _, node := range nodes {
		for v := range vnodes {
			points = append(points, point{h32(node + "#" + strconv.Itoa(v)), node})
		}
	}
	// Sort by (position, node name) so ties break the same way everywhere.
	// Go's sorts are not stable, so the comparison has to be a total order.
	slices.SortFunc(points, func(a, b point) int {
		if c := cmp.Compare(a.pos, b.pos); c != 0 {
			return c
		}
		return cmp.Compare(a.node, b.node) // byte-wise, same as Python for ASCII
	})
	r := &hashRing{positions: make([]uint32, len(points)), owners: make([]string, len(points))}
	for i, p := range points {
		r.positions[i], r.owners[i] = p.pos, p.node
	}
	return r
}

// owner returns the node that owns keyHash: the first point at or after it.
func (r *hashRing) owner(keyHash uint32) string {
	// sort.Search returns the first index where the test is true. With >= that
	// is Python's bisect_left (slices.BinarySearch gives the same index).
	i := sort.Search(len(r.positions), func(i int) bool { return r.positions[i] >= keyHash })
	if i == len(r.positions) { // past the last point: wrap to the start
		i = 0
	}
	return r.owners[i]
}

// pct is part/whole as a percent with one decimal, rounded half up, using
// integers only. Go's / truncates toward zero and Python's // floors; they
// agree for non-negative numbers like these.
func pct(part, whole int) string {
	tenths := (part*2000 + whole) / (2 * whole)
	return fmt.Sprintf("%d.%d%%", tenths/10, tenths%10)
}

func main() {
	nodes10 := make([]string, 10)
	for i := range nodes10 {
		nodes10[i] = "node-" + strconv.Itoa(i)
	}
	// Clone before appending: append may write into the original's backing
	// array when it has spare capacity, and then the two slices share data.
	nodes11 := append(slices.Clone(nodes10), "node-10")
	hashes := make([]uint32, keys)
	for i := range hashes {
		hashes[i] = h32("key-" + strconv.Itoa(i))
	}

	fmt.Printf("Drill 2: consistent hashing. %s keys, cluster grows from 10 to 11 nodes.\n", commas(keys))

	movedMod := 0
	for _, h := range hashes {
		if h%10 != h%11 {
			movedMod++
		}
	}
	// In a Printf format, %% prints a literal percent sign.
	fmt.Printf("hash %% N   moved %6s keys (%s)   expect ~90.9%% (10 of 11)\n", commas(movedMod), pct(movedMod, keys))

	ring10, ring11 := newHashRing(nodes10, vnodes), newHashRing(nodes11, vnodes)
	moved, wentToNew := 0, true
	load := map[string]int{} // Python's Counter: a missing key reads as 0, so ++ just works
	for _, h := range hashes {
		before, after := ring10.owner(h), ring11.owner(h)
		load[after]++
		if before != after {
			moved++
			wentToNew = wentToNew && after == "node-10"
		}
	}
	fmt.Printf("hash ring  moved %6s keys (%s)    expect ~9.1%% (1 of 11)\n", commas(moved), pct(moved, keys))
	fmt.Printf("Every key that moved on the ring went to node-10: %s\n", yesNo(wentToNew))

	counts := make([]int, 0, len(load))
	for _, n := range load {
		counts = append(counts, n)
	}
	fmt.Printf("Keys per node, 11 nodes x 160 vnodes: min %s  max %s  (ideal %s)\n",
		commas(slices.Min(counts)), commas(slices.Max(counts)), commas((2*keys+11)/22))

	onePoint := newHashRing(nodes11, 1)
	load1 := map[string]int{}
	for _, h := range hashes {
		load1[onePoint.owner(h)]++
	}
	counts1 := make([]int, 0, len(nodes11))
	for _, node := range nodes11 {
		counts1 = append(counts1, load1[node]) // a node with no keys counts as 0
	}
	fmt.Printf("Keys per node, 11 nodes x 1 vnode:    min %s  max %s  (why virtual nodes matter)\n",
		commas(slices.Min(counts1)), commas(slices.Max(counts1)))
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
