// Drill 1 (Big-O): time an O(n^2) reconciliation against an O(n) one.
//
// Reconciles N Jamf devices against N Okta Verify devices, where every 20th
// device is missing from Okta, two ways:
//
//	nested  for each Jamf device, scan the whole Okta list. This is the
//	        foreach + Where-Object pattern: n x n comparisons, O(n^2).
//	hash    build a map keyed by serial once (O(n)), then one pass over
//	        Jamf with O(1) lookups. O(n) overall.
//
// Then it checks the growth against the prediction: 6x more devices should
// cost about 36x more for nested and about 6x more for hash.
//
// Lines starting with "~" are timings and vary by machine. For real
// measurements in Go, write a BenchmarkXxx function in a _test.go file and run
// go test -bench: the testing package picks the repeat count for you.
package main

import (
	"fmt"
	"math"
	"slices"
	"strconv"
	"strings"
	"time"
)

// The records carry a field nothing reads (osVersion, trust), as the Python
// dicts do, so they look like real exports.
type jamfDevice struct {
	serial    string
	osVersion string
}

type oktaDevice struct {
	serial string
	trust  string
}

// makeInventory builds deterministic fake inventories. Okta lists devices in a
// different order (real exports rarely line up) and is missing every 20th one.
func makeInventory(n int) ([]jamfDevice, []oktaDevice) {
	versions := [...]string{"14.7", "15.3", "15.4"}
	jamf := make([]jamfDevice, 0, n)
	for i := range n {
		jamf = append(jamf, jamfDevice{serial: fmt.Sprintf("SN%06d", i), osVersion: versions[i%3]})
	}
	var okta []oktaDevice
	for i := n - 1; i >= 0; i-- {
		if i%20 != 0 {
			okta = append(okta, oktaDevice{serial: fmt.Sprintf("SN%06d", i), trust: "managed"})
		}
	}
	return jamf, okta
}

// missingNested is O(n^2): the inner loop scans every Okta record for every
// Jamf record. Like Where-Object, it doesn't stop at the first match; a break
// would halve the average cost, but it would still be O(n^2).
func missingNested(jamf []jamfDevice, okta []oktaDevice) []string {
	var missing []string
	for _, j := range jamf {
		matches := 0
		for _, o := range okta { // o is a copy of the element, cheap for a small struct
			if o.serial == j.serial {
				matches++
			}
		}
		if matches == 0 {
			missing = append(missing, j.serial)
		}
	}
	return missing
}

// missingHash is O(n): one pass to build the index, one pass to probe it.
func missingHash(jamf []jamfDevice, okta []oktaDevice) []string {
	oktaBySerial := make(map[string]oktaDevice, len(okta)) // sized up front, so it never rehashes
	for _, o := range okta {
		oktaBySerial[o.serial] = o
	}
	var missing []string
	for _, j := range jamf {
		// The comma-ok form tells "not there" apart from a stored zero value.
		if _, ok := oktaBySerial[j.serial]; !ok {
			missing = append(missing, j.serial)
		}
	}
	return missing
}

// timed runs fn repeats times and keeps the fastest run. Tiny timings are
// noisy, and the minimum is the best estimate of the real cost. Go has no
// *args, so the caller wraps its arguments in a closure.
func timed(repeats int, fn func() []string) ([]string, time.Duration) {
	var result []string
	best := time.Duration(math.MaxInt64)
	for range repeats {
		start := time.Now()
		result = fn()
		best = min(best, time.Since(start)) // time.Since uses the monotonic clock
	}
	return result, best
}

func main() {
	fmt.Println("Drill 1: Big-O. Reconcile N Jamf devices against N Okta devices (every 20th missing from Okta).")
	sizes := []int{100, 1_000, 6_000}
	type timing struct{ nested, hash time.Duration }
	timings := make(map[int]timing, len(sizes))
	var found []string
	for _, n := range sizes {
		jamf, okta := makeInventory(n)
		nested, tNested := timed(3, func() []string { return missingNested(jamf, okta) })
		hashed, tHash := timed(50, func() []string { return missingHash(jamf, okta) })
		if !slices.Equal(nested, hashed) {
			panic("both methods must find the same devices") // Go has no assert statement
		}
		found = append(found, fmt.Sprintf("n=%s -> %s", commas(n), commas(len(nested))))
		timings[n] = timing{tNested, tHash}
	}
	fmt.Println("Missing devices found: " + strings.Join(found, ", ") + " (both methods agree)")

	fmt.Printf("~ %6s  %10s  %9s  %8s\n", "n", "nested (s)", "hash (s)", "speedup")
	for _, n := range sizes { // ranging over the map would give a random order
		t := timings[n]
		speedup := t.nested.Seconds() / t.hash.Seconds()
		fmt.Printf("~ %6s  %10.5f  %9.5f  %7sx\n", commas(n), t.nested.Seconds(), t.hash.Seconds(), commasF(speedup))
	}
	nestedGrowth := timings[6_000].nested.Seconds() / timings[1_000].nested.Seconds()
	hashGrowth := timings[6_000].hash.Seconds() / timings[1_000].hash.Seconds()
	fmt.Printf("~ Growth from 1,000 to 6,000 devices (6x): nested %.1fx slower (predict 36x), hash %.1fx (predict 6x)\n",
		nestedGrowth, hashGrowth)
}

// commas formats n with thousands separators, like Python's f"{n:,}". fmt has
// no flag for this (golang.org/x/text/message does, outside the standard library).
func commas(n int) string { return group(strconv.Itoa(n)) }

// commasF rounds x to a whole number with separators, like f"{x:,.0f}".
// FormatFloat rounds halves to even, as Python does.
func commasF(x float64) string { return group(strconv.FormatFloat(x, 'f', 0, 64)) }

// group inserts a comma every three digits from the right, after any sign.
func group(s string) string {
	head := len(s) - len(strings.TrimLeft(s, "+-"))
	for i := len(s) - 3; i > head; i -= 3 {
		s = s[:i] + "," + s[i:]
	}
	return s
}
