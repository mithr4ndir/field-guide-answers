#Requires -Version 7.4

<#
.SYNOPSIS
    Drill 7 (graphs): install order, cycle detection, and impact analysis.

.DESCRIPTION
    Reads package -> requires relationships (Munki style) from data/deps.json:

      Kahn's algorithm   topological sort: install a package only after
                         everything it requires. Always taking the alphabetically
                         first ready package makes the order the same on every
                         run and in every language.
      DFS, three colors  finds the actual cycle when Kahn's algorithm gets stuck.
                         white = unvisited, gray = on the current path, black = done.
                         An edge to a gray package closes a cycle.
      BFS                what installing one package pulls in, and the reverse:
                         everything affected if one package breaks.

    Make your own deps.json from a Munki repo with python/munki_to_json.py.

.PARAMETER Path
    The deps.json to read. Defaults to ../data/deps.json next to this script.

.EXAMPLE
    ./Get-InstallOrder.ps1 ./my_deps.json

.NOTES
    PowerShell port of python/depgraph.py.
#>

using namespace System.Collections.Generic

[CmdletBinding()]
param(
    [string] $Path = (Join-Path $PSScriptRoot '..' 'data' 'deps.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Inv = [cultureinfo]::InvariantCulture

# Every collection below uses .NET's default string comparer, which is ordinal and
# case-sensitive like Python's dict and set. PowerShell's @{} and [ordered]@{}
# ignore case instead, so they would quietly treat "Zoom" and "zoom" as one package.

function Get-OrdinalSorted {
    <#
    .SYNOPSIS
        Sort strings like Python's sorted(): by code point, case-sensitive.
    .NOTES
        Sort-Object uses culture rules and ignores case (apple, Apple, zeta, Zoom).
        Ordinal order puts all uppercase first (Apple, Zoom, apple, zeta), like Python.
    #>
    param([Parameter(ValueFromPipeline)] [string] $InputObject)
    begin { $items = [List[string]]::new() }
    process { $items.Add($InputObject) }
    end {
        $items.Sort([StringComparer]::Ordinal)
        , $items.ToArray()          # the comma returns the array itself, even when empty
    }
}

function Get-DependentMap {
    <#
    .SYNOPSIS
        Reverse the edges: package -> the packages that require it.
    #>
    param([System.Collections.IDictionary] $Requires)
    $dependents = [Dictionary[string, List[string]]]::new()
    foreach ($pkg in $Requires.Keys) {
        $dependents[$pkg] = [List[string]]::new()
    }
    foreach ($pkg in $Requires.Keys) {
        foreach ($dep in $Requires[$pkg]) {
            $dependents[$dep].Add($pkg)
        }
    }
    $dependents                     # a dictionary is never unrolled, so no comma needed
}

function Get-KahnOrder {
    <#
    .SYNOPSIS
        Return (order, stuck). Stuck lists packages that can never install (cycle).
    #>
    param([System.Collections.IDictionary] $Requires)
    $remaining = [Dictionary[string, int]]::new()
    foreach ($pkg in $Requires.Keys) {
        $remaining[$pkg] = @($Requires[$pkg]).Count
    }
    $dependents = Get-DependentMap $Requires
    # Python pops the smallest name from a min-heap. A SortedSet with an ordinal
    # comparer does the same job: Min, then Remove, is the pop.
    $ready = [SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($pkg in $remaining.Keys) {
        if ($remaining[$pkg] -eq 0) { $null = $ready.Add($pkg) }
    }
    $order = [List[string]]::new()
    while ($ready.Count -gt 0) {
        $pkg = $ready.Min
        $null = $ready.Remove($pkg)
        $order.Add($pkg)
        foreach ($dependent in $dependents[$pkg]) {
            $remaining[$dependent]--
            if ($remaining[$dependent] -eq 0) { $null = $ready.Add($dependent) }
        }
    }
    $stuck = $remaining.Keys | Where-Object { $remaining[$_] -gt 0 } | Get-OrdinalSorted
    return $order, $stuck
}

function Find-Cycle {
    <#
    .SYNOPSIS
        Depth-first search with three colors. Returns one cycle as a list, or $null.
    #>
    param([System.Collections.IDictionary] $Requires)
    $white, $gray, $black = 0, 1, 2
    $color = [Dictionary[string, int]]::new()
    foreach ($pkg in $Requires.Keys) {
        $color[$pkg] = $white
    }
    $path = [List[string]]::new()

    # The nested function finds $color, $path and $Requires through PowerShell's
    # dynamic scoping. It only changes those objects, never reassigns the variables,
    # so it needs no $script: or [ref].
    function Find-CycleFrom([string] $Pkg) {
        $color[$Pkg] = $gray
        $path.Add($Pkg)
        foreach ($dep in ($Requires[$Pkg] | Get-OrdinalSorted)) {
            if ($color[$dep] -eq $gray) {           # back edge: dep is on the current path
                $from = $path.IndexOf($dep)
                $cycle = $path.GetRange($from, $path.Count - $from)
                $cycle.Add($dep)
                return , $cycle
            }
            if ($color[$dep] -eq $white) {
                $cycle = Find-CycleFrom $dep
                if ($null -ne $cycle) { return , $cycle }
            }
        }
        $path.RemoveAt($path.Count - 1)
        $color[$Pkg] = $black
        return $null
    }

    foreach ($pkg in ($Requires.Keys | Get-OrdinalSorted)) {
        if ($color[$pkg] -eq $white) {
            $cycle = Find-CycleFrom $pkg
            if ($null -ne $cycle) { return , $cycle }
        }
    }
    return $null
}

function Get-BfsLevel {
    <#
    .SYNOPSIS
        Breadth-first search. Returns a list of levels, each a sorted string array.
    #>
    param([System.Collections.IDictionary] $Graph, [string] $Start)
    $seen = [HashSet[string]]::new()
    $null = $seen.Add($Start)
    $levels = [List[string[]]]::new()
    $frontier = [Queue[string]]::new()
    $frontier.Enqueue($Start)
    while ($frontier.Count -gt 0) {
        $nextLevel = [List[string]]::new()
        for ($n = $frontier.Count; $n -gt 0; $n--) {
            $node = $frontier.Dequeue()
            foreach ($neighbor in $Graph[$node]) {
                if ($seen.Add($neighbor)) {         # Add() is $false when it was already seen
                    $nextLevel.Add($neighbor)
                }
            }
        }
        if ($nextLevel.Count -gt 0) {
            $sorted = $nextLevel | Get-OrdinalSorted
            $levels.Add($sorted)
            foreach ($node in $sorted) { $frontier.Enqueue($node) }
        }
    }
    # Output is unrolled one level: a single level would come back as a bare
    # string[] and the caller would loop over its strings. The comma prevents that.
    , $levels
}

function Show-BfsLevel([List[string[]]] $Levels) {
    for ($i = 0; $i -lt $Levels.Count; $i++) {
        "  level $($i + 1): $($Levels[$i] -join ', ')"
    }
}

# -AsHashtable gives an ordered hashtable with case-sensitive keys (unlike @{}),
# which matches Python's dict. Each value is an object[] of names, even when it
# holds one name or none.
$requires = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
"Drill 7: graphs. $($requires.Count) packages from $(Split-Path -Leaf $Path)."

$unknown = [HashSet[string]]::new()
foreach ($deps in $requires.Values) {
    foreach ($dep in $deps) {
        if (-not $requires.ContainsKey($dep)) { $null = $unknown.Add($dep) }
    }
}
if ($unknown.Count -gt 0) {
    'Unknown requirements: ' + (($unknown | Get-OrdinalSorted) -join ', ')
    return
}
'All requirements refer to known packages: yes'

$order, $stuck = Get-KahnOrder $requires
if ($stuck.Count -gt 0) {                           # a real repo can have cycles: explain and stop
    "Kahn's algorithm placed $($order.Count) of $($requires.Count) packages. Stuck ($($stuck.Count)): $($stuck -join ', ')"
    'DFS found the cycle: ' + ((Find-Cycle $requires) -join ' -> ')
    return
}
"Install order (Kahn's algorithm):"
for ($i = 0; $i -lt $order.Count; $i++) {
    [string]::Format($Inv, '  {0,2}. {1}', $i + 1, $order[$i])
}
$position = [Dictionary[string, int]]::new()
for ($i = 0; $i -lt $order.Count; $i++) {
    $position[$order[$i]] = $i
}
$valid = $true
foreach ($pkg in $requires.Keys) {
    foreach ($dep in $requires[$pkg]) {
        if ($position[$dep] -ge $position[$pkg]) { $valid = $false }
    }
}
"Every package comes after everything it requires: $(if ($valid) { 'yes' } else { 'no' })"

$start = if ($requires.ContainsKey('DefenderOnboarding')) { 'DefenderOnboarding' } else { $order[-1] }
"Installing $start pulls in (BFS over requires):"
Show-BfsLevel (Get-BfsLevel $requires $start)

$dependents = Get-DependentMap $requires
$target = if ($requires.ContainsKey('MicrosoftAutoUpdate')) { 'MicrosoftAutoUpdate' } else { $order[0] }
"If $target breaks, these are affected (BFS over reversed edges):"
Show-BfsLevel (Get-BfsLevel $dependents $target)

# Now break it on purpose: MicrosoftAutoUpdate requires MicrosoftWord, which requires it back.
if ($requires.ContainsKey('MicrosoftAutoUpdate') -and $requires.ContainsKey('MicrosoftWord')) {
    # A real copy with new lists. $requires.Clone() would be shallow: both tables
    # would share the same arrays.
    $broken = [Dictionary[string, List[string]]]::new()
    foreach ($pkg in $requires.Keys) {
        $broken[$pkg] = [List[string]]::new([string[]]$requires[$pkg])
    }
    $broken['MicrosoftAutoUpdate'].Add('MicrosoftWord')
    'Added a cycle: MicrosoftAutoUpdate now requires MicrosoftWord.'
    $order, $stuck = Get-KahnOrder $broken
    "Kahn's algorithm placed $($order.Count) of $($broken.Count) packages. Stuck ($($stuck.Count)): $($stuck -join ', ')"
    $cycle = Find-Cycle $broken
    'DFS found the cycle: ' + ($cycle -join ' -> ')
}
