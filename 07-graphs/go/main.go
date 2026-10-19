// Drill 7 (graphs): install order, cycle detection, and impact analysis.
//
// Reads package -> requires relationships (Munki style) from data/deps.json:
//
//	Kahn's algorithm   topological sort: install a package only after
//	                   everything it requires. A min-heap of ready packages
//	                   makes the order the same on every run and in every language.
//	DFS, three colors  finds the actual cycle when Kahn's algorithm gets stuck.
//	                   white = unvisited, gray = on the current path, black = done.
//	                   An edge to a gray package closes a cycle.
//	BFS                what installing one package pulls in, and the reverse:
//	                   everything affected if one package breaks.
//
// Usage: go run ./07-graphs/go [path/to/deps.json]
// Make your own deps.json from a Munki repo with python/munki_to_json.py.
//
// Go maps iterate in a random order, on purpose, so code can't come to depend
// on it. Wherever order reaches the output, this program sorts first.
package main

import (
	"container/heap"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// defaultPath finds data/deps.json. Go has no __file__: a compiled program
// doesn't know where its source lives (go run builds it in a temp folder), so
// look relative to the working directory: the repo root or the drill folders.
func defaultPath() string {
	candidates := []string{
		filepath.Join("07-graphs", "data", "deps.json"), // from the repo root
		filepath.Join("..", "data", "deps.json"),        // from 07-graphs/go
		filepath.Join("data", "deps.json"),              // from 07-graphs
	}
	for _, p := range candidates {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return candidates[0] // reading it will fail with a clear error
}

// stringHeap is a min-heap of package names for container/heap, so the next
// ready package is always the alphabetically smallest.
type stringHeap []string

func (h stringHeap) Len() int           { return len(h) }
func (h stringHeap) Less(i, j int) bool { return h[i] < h[j] } // byte-wise: same as Python for ASCII
func (h stringHeap) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }
func (h *stringHeap) Push(x any)        { *h = append(*h, x.(string)) }
func (h *stringHeap) Pop() any {
	old := *h
	x := old[len(old)-1]
	*h = old[:len(old)-1]
	return x
}

// reverse turns package -> requires into package -> dependents (who requires it).
// The dependents lists come out in random order (map iteration), which is
// fine: Kahn's algorithm uses a heap and the BFS sorts each level.
func reverse(requires map[string][]string) map[string][]string {
	dependents := make(map[string][]string, len(requires))
	for pkg, deps := range requires {
		for _, dep := range deps {
			dependents[dep] = append(dependents[dep], pkg) // append to a missing key's nil slice just works
		}
	}
	return dependents
}

// kahnOrder returns the install order, and the packages that can never
// install because they are stuck in or behind a cycle.
func kahnOrder(requires map[string][]string) (order, stuck []string) {
	remaining := make(map[string]int, len(requires))
	for pkg, deps := range requires {
		remaining[pkg] = len(deps)
	}
	dependents := reverse(requires)
	ready := &stringHeap{}
	for pkg, n := range remaining {
		if n == 0 {
			*ready = append(*ready, pkg)
		}
	}
	heap.Init(ready) // alphabetical among ready packages
	for ready.Len() > 0 {
		pkg := heap.Pop(ready).(string)
		order = append(order, pkg)
		for _, dependent := range dependents[pkg] {
			remaining[dependent]--
			if remaining[dependent] == 0 {
				heap.Push(ready, dependent)
			}
		}
	}
	for pkg, n := range remaining {
		if n > 0 {
			stuck = append(stuck, pkg)
		}
	}
	slices.Sort(stuck)
	return order, stuck
}

// findCycle runs a depth-first search with three colors and returns one cycle, or nil.
func findCycle(requires map[string][]string) []string {
	const (
		white = iota // unvisited; the zero value, so the color map needs no setup
		gray         // on the current path
		black        // done
	)
	color := make(map[string]int, len(requires))
	var path []string

	// A closure can only call itself through a variable that already exists,
	// so declare visit first and assign the function second.
	var visit func(pkg string) []string
	visit = func(pkg string) []string {
		color[pkg] = gray
		path = append(path, pkg)
		for _, dep := range sorted(requires[pkg]) {
			switch color[dep] {
			case gray: // back edge: dep is on the current path
				i := slices.Index(path, dep)
				// Clone first: appending to path[i:] could write into path's backing array.
				return append(slices.Clone(path[i:]), dep)
			case white:
				if cycle := visit(dep); cycle != nil {
					return cycle
				}
			}
		}
		path = path[:len(path)-1]
		color[pkg] = black
		return nil
	}

	for _, pkg := range sortedKeys(requires) {
		if color[pkg] == white {
			if cycle := visit(pkg); cycle != nil {
				return cycle
			}
		}
	}
	return nil
}

// bfsLevels is a breadth-first search returning [[level 1 nodes], [level 2 nodes], ...].
// No deque needed: finish one whole level, then make the next level the frontier.
func bfsLevels(graph map[string][]string, start string) [][]string {
	seen := map[string]bool{start: true}
	var levels [][]string
	frontier := []string{start}
	for len(frontier) > 0 {
		var next []string
		for _, node := range frontier {
			for _, neighbor := range graph[node] {
				if !seen[neighbor] {
					seen[neighbor] = true
					next = append(next, neighbor)
				}
			}
		}
		if len(next) > 0 {
			slices.Sort(next)
			levels = append(levels, next)
		}
		frontier = next
	}
	return levels
}

func printLevels(levels [][]string) {
	for i, level := range levels {
		fmt.Printf("  level %d: %s\n", i+1, strings.Join(level, ", "))
	}
}

func printStuck(order, stuck []string, total int) {
	fmt.Printf("Kahn's algorithm placed %d of %d packages. Stuck (%d): %s\n",
		len(order), total, len(stuck), strings.Join(stuck, ", "))
}

func main() {
	path := defaultPath()
	if len(os.Args) > 1 {
		path = os.Args[1]
	}
	data, err := os.ReadFile(path)
	if err != nil {
		log.Fatal(err)
	}
	var requires map[string][]string
	if err := json.Unmarshal(data, &requires); err != nil {
		log.Fatalf("%s: %v", path, err)
	}
	fmt.Printf("Drill 7: graphs. %d packages from %s.\n", len(requires), filepath.Base(path))

	unknown := map[string]bool{} // Go has no set type; a map to bool is the simple stand-in
	for _, deps := range requires {
		for _, dep := range deps {
			if _, ok := requires[dep]; !ok {
				unknown[dep] = true
			}
		}
	}
	if len(unknown) > 0 {
		fmt.Println("Unknown requirements: " + strings.Join(sortedKeys(unknown), ", "))
		return
	}
	fmt.Println("All requirements refer to known packages: yes")

	order, stuck := kahnOrder(requires)
	if len(stuck) > 0 { // a real repo can have cycles: explain and stop
		printStuck(order, stuck, len(requires))
		fmt.Println("DFS found the cycle: " + strings.Join(findCycle(requires), " -> "))
		return
	}
	fmt.Println("Install order (Kahn's algorithm):")
	for i, pkg := range order {
		fmt.Printf("  %2d. %s\n", i+1, pkg)
	}
	position := make(map[string]int, len(order))
	for i, pkg := range order {
		position[pkg] = i
	}
	valid := true
	for pkg, deps := range requires {
		for _, dep := range deps {
			valid = valid && position[dep] < position[pkg]
		}
	}
	fmt.Printf("Every package comes after everything it requires: %s\n", yesNo(valid))

	start := "DefenderOnboarding"
	if _, ok := requires[start]; !ok {
		start = order[len(order)-1]
	}
	fmt.Printf("Installing %s pulls in (BFS over requires):\n", start)
	printLevels(bfsLevels(requires, start))

	target := "MicrosoftAutoUpdate"
	if _, ok := requires[target]; !ok {
		target = order[0]
	}
	fmt.Printf("If %s breaks, these are affected (BFS over reversed edges):\n", target)
	printLevels(bfsLevels(reverse(requires), target))

	// Now break it on purpose: MicrosoftAutoUpdate requires MicrosoftWord, which requires it back.
	_, hasMAU := requires["MicrosoftAutoUpdate"]
	_, hasWord := requires["MicrosoftWord"]
	if hasMAU && hasWord {
		// Copy each slice too. maps.Clone is shallow: both maps would share
		// every backing array, and an append to one could clobber the other.
		broken := make(map[string][]string, len(requires))
		for pkg, deps := range requires {
			broken[pkg] = slices.Clone(deps)
		}
		broken["MicrosoftAutoUpdate"] = append(broken["MicrosoftAutoUpdate"], "MicrosoftWord")
		fmt.Println("Added a cycle: MicrosoftAutoUpdate now requires MicrosoftWord.")
		order, stuck := kahnOrder(broken)
		printStuck(order, stuck, len(broken))
		fmt.Println("DFS found the cycle: " + strings.Join(findCycle(broken), " -> "))
	}
}

// sorted returns a sorted copy, like Python's sorted(); slices.Sort alone
// would reorder the caller's slice in place.
func sorted(xs []string) []string {
	out := slices.Clone(xs)
	slices.Sort(out)
	return out
}

// sortedKeys returns a map's keys in order. (From Go 1.23 this is
// slices.Sorted(maps.Keys(m)); this repo targets Go 1.22.)
func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}

// yesNo exists because Go has no conditional (ternary) expression.
func yesNo(ok bool) string {
	if ok {
		return "yes"
	}
	return "no"
}
