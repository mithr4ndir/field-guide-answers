// Drill 10 (binary search): find the first bad thing, and binary search on the answer.
//
// firstTrue(lo, hi, pred) is the one function to know. It assumes pred flips
// exactly once, from false to true, somewhere in the half-open range [lo, hi),
// and returns the first value where it is true (or hi if it never is).
//
//	Part 1  500 commits, the bug arrived in commit 337. Find it in ~9 tests.
//	Part 2  Binary search on the answer: the largest batch size an API accepts.
//	        Search "first size that fails" and subtract one.
//
// The probe sequence is printed so you can check your midpoint math: with
// mid = lo + (hi - lo) / 2 every language visits the same values.
//
// The standard library already has this function: sort.Search(n, pred) is
// firstTrue(0, n, pred), down to the same midpoints. slices.BinarySearch and
// sort.Find are variations on it.
package main

import (
	"fmt"
	"strconv"
	"strings"
)

// firstTrue returns the smallest x in [lo, hi) with pred(x) true. pred must be false...false, true...true.
func firstTrue(lo, hi int, pred func(int) bool) int {
	for lo < hi {
		// lo + (hi-lo)/2 never overflows; (lo+hi)/2 can, because Go ints are
		// fixed width and wrap around silently. Go's / truncates toward zero
		// where Python's // floors, which only differs for negative numbers.
		mid := lo + (hi-lo)/2
		if pred(mid) {
			hi = mid // mid might be the answer; keep it in range
		} else {
			lo = mid + 1 // mid is definitely not the answer
		}
	}
	return lo
}

func main() {
	fmt.Println("Drill 10: binary search and bisection.")

	const commits, culprit = 500, 337
	var tested []int
	isBad := func(commit int) bool {
		tested = append(tested, commit) // a closure captures the variable itself, not a copy
		return commit >= culprit
	}
	found := firstTrue(0, commits, isBad)
	fmt.Printf("Part 1: first bad commit among %d is %d, found in %d tests (log2(%d) is about 9)\n",
		commits, found, len(tested), commits)
	fmt.Println("  tested: " + joinInts(tested, ", "))

	const maxOK = 437
	var probed []int
	fails := func(batch int) bool {
		probed = append(probed, batch)
		return batch > maxOK // the fake API times out above 437 items
	}
	largest := firstTrue(1, 10_001, fails) - 1
	fmt.Printf("Part 2: largest batch the API accepts is %d, found in %d probes of the range 1..10,000\n",
		largest, len(probed))
	fmt.Println("  probed: " + joinInts(probed, ", "))
}

func joinInts(xs []int, sep string) string {
	parts := make([]string, len(xs))
	for i, x := range xs {
		parts[i] = strconv.Itoa(x)
	}
	return strings.Join(parts, sep)
}
