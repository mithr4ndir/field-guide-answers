#!/usr/bin/env python3
"""Drill 7 (graphs): install order, cycle detection, and impact analysis.

Reads package -> requires relationships (Munki style) from data/deps.json:

  Kahn's algorithm   topological sort: install a package only after
                     everything it requires. A min-heap of ready packages
                     makes the order the same on every run and in every language.
  DFS, three colors  finds the actual cycle when Kahn's algorithm gets stuck.
                     white = unvisited, gray = on the current path, black = done.
                     An edge to a gray package closes a cycle.
  BFS                what installing one package pulls in, and the reverse:
                     everything affected if one package breaks.

Usage: python3 depgraph.py [path/to/deps.json]
Make your own deps.json from a Munki repo with munki_to_json.py.
"""
import heapq
import json
import sys
from collections import deque
from pathlib import Path

DEFAULT = Path(__file__).resolve().parent.parent / "data" / "deps.json"


def kahn_order(requires):
    """Return (order, stuck). `stuck` lists packages that can never install (cycle)."""
    remaining = {pkg: len(deps) for pkg, deps in requires.items()}
    dependents = {pkg: [] for pkg in requires}
    for pkg, deps in requires.items():
        for dep in deps:
            dependents[dep].append(pkg)
    ready = [pkg for pkg, n in remaining.items() if n == 0]
    heapq.heapify(ready)                       # alphabetical among ready packages
    order = []
    while ready:
        pkg = heapq.heappop(ready)
        order.append(pkg)
        for dependent in dependents[pkg]:
            remaining[dependent] -= 1
            if remaining[dependent] == 0:
                heapq.heappush(ready, dependent)
    stuck = sorted(pkg for pkg, n in remaining.items() if n > 0)
    return order, stuck


def find_cycle(requires):
    """Depth-first search with three colors. Returns one cycle as a list, or None."""
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {pkg: WHITE for pkg in requires}
    path = []

    def visit(pkg):
        color[pkg] = GRAY
        path.append(pkg)
        for dep in sorted(requires[pkg]):
            if color[dep] == GRAY:             # back edge: dep is on the current path
                return path[path.index(dep):] + [dep]
            if color[dep] == WHITE:
                cycle = visit(dep)
                if cycle:
                    return cycle
        path.pop()
        color[pkg] = BLACK
        return None

    for pkg in sorted(requires):
        if color[pkg] == WHITE:
            cycle = visit(pkg)
            if cycle:
                return cycle
    return None


def bfs_levels(graph, start):
    """Breadth-first search. Returns [[level 1 nodes], [level 2 nodes], ...]."""
    seen, levels = {start}, []
    frontier = deque([start])
    while frontier:
        next_level = []
        for _ in range(len(frontier)):
            node = frontier.popleft()
            for neighbor in graph[node]:
                if neighbor not in seen:
                    seen.add(neighbor)
                    next_level.append(neighbor)
        if next_level:
            next_level.sort()
            levels.append(next_level)
            frontier.extend(next_level)
    return levels


def print_levels(levels):
    for i, level in enumerate(levels, 1):
        print(f"  level {i}: {', '.join(level)}")


def main():
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT
    requires = json.loads(path.read_text())
    print(f"Drill 7: graphs. {len(requires)} packages from {path.name}.")

    unknown = sorted({dep for deps in requires.values() for dep in deps if dep not in requires})
    if unknown:
        print("Unknown requirements: " + ", ".join(unknown))
        return
    print("All requirements refer to known packages: yes")

    order, stuck = kahn_order(requires)
    if stuck:                                  # a real repo can have cycles: explain and stop
        print(f"Kahn's algorithm placed {len(order)} of {len(requires)} packages. "
              f"Stuck ({len(stuck)}): {', '.join(stuck)}")
        print("DFS found the cycle: " + " -> ".join(find_cycle(requires)))
        return
    print("Install order (Kahn's algorithm):")
    for i, pkg in enumerate(order, 1):
        print(f"  {i:>2}. {pkg}")
    position = {pkg: i for i, pkg in enumerate(order)}
    valid = all(position[dep] < position[pkg] for pkg, deps in requires.items() for dep in deps)
    print(f"Every package comes after everything it requires: {'yes' if valid else 'no'}")

    start = "DefenderOnboarding" if "DefenderOnboarding" in requires else order[-1]
    print(f"Installing {start} pulls in (BFS over requires):")
    print_levels(bfs_levels(requires, start))

    dependents = {pkg: [] for pkg in requires}
    for pkg, deps in requires.items():
        for dep in deps:
            dependents[dep].append(pkg)
    target = "MicrosoftAutoUpdate" if "MicrosoftAutoUpdate" in requires else order[0]
    print(f"If {target} breaks, these are affected (BFS over reversed edges):")
    print_levels(bfs_levels(dependents, target))

    # Now break it on purpose: MicrosoftAutoUpdate requires MicrosoftWord, which requires it back.
    if "MicrosoftAutoUpdate" in requires and "MicrosoftWord" in requires:
        broken = {pkg: list(deps) for pkg, deps in requires.items()}
        broken["MicrosoftAutoUpdate"].append("MicrosoftWord")
        print("Added a cycle: MicrosoftAutoUpdate now requires MicrosoftWord.")
        order, stuck = kahn_order(broken)
        print(f"Kahn's algorithm placed {len(order)} of {len(broken)} packages. "
              f"Stuck ({len(stuck)}): {', '.join(stuck)}")
        cycle = find_cycle(broken)
        print("DFS found the cycle: " + " -> ".join(cycle))


if __name__ == "__main__":
    main()
