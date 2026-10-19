#Requires -Version 7.4

<#
.SYNOPSIS
    Drill 10 (binary search): find the first bad thing, and binary search on the answer.

.DESCRIPTION
    Find-FirstTrue is the one function to know. It assumes the predicate flips
    exactly once, from $false to $true, somewhere in the half-open range
    [Lo, Hi), and returns the first value where it is $true (or Hi if it never is).

      Part 1  500 commits, the bug arrived in commit 337. Find it in ~9 tests.
      Part 2  Binary search on the answer: the largest batch size an API accepts.
              Search "first size that fails" and subtract one.

    The probe sequence is printed so you can check your midpoint math: with
    mid = lo + (hi - lo) // 2 every language visits the same values.

.NOTES
    PowerShell port of python/bisect_tools.py.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-FirstTrue {
    <#
    .SYNOPSIS
        Smallest x in [Lo, Hi) where Predicate is $true. Predicate must be $false...$false, $true...$true.
    #>
    param(
        [Parameter(Mandatory)] [long] $Lo,
        [Parameter(Mandatory)] [long] $Hi,
        [Parameter(Mandatory)] [scriptblock] $Predicate
    )
    while ($Lo -lt $Hi) {
        # PowerShell has no // operator. ($Hi - $Lo) / 2 gives a double (62.5), and
        # casting with [int] rounds half to even (63.5 -> 64), so both give the wrong
        # probes. -shr 1 is an exact floor division by 2 on integers.
        # (Python's comment about (lo + hi) overflowing applies here too, just
        # differently: [long] + [long] past the max silently becomes a [double].)
        $mid = $Lo + (($Hi - $Lo) -shr 1)
        if (& $Predicate $mid) {
            $Hi = $mid          # mid might be the answer; keep it in range
        }
        else {
            $Lo = $mid + 1      # mid is definitely not the answer
        }
    }
    $Lo
}

'Drill 10: binary search and bisection.'

$commits = 500
$culprit = 337
$probes = [System.Collections.Generic.List[long]]::new()
# A scriptblock is not a closure by default: it looks up $probes when it runs, in
# whatever scope it runs in. GetNewClosure() captures the variables right now,
# like Python's closure over `probes`. List[T].Add returns nothing; ArrayList.Add
# returns an index, which would leak into the predicate's output and make it truthy.
$isBad = {
    param([long]$Commit)
    $probes.Add($Commit)
    $Commit -ge $culprit
}.GetNewClosure()

$found = Find-FirstTrue -Lo 0 -Hi $commits -Predicate $isBad
"Part 1: first bad commit among $commits is $found, found in $($probes.Count) tests (log2($commits) is about 9)"
'  tested: ' + ($probes -join ', ')

$maxOk = 437
$probes = [System.Collections.Generic.List[long]]::new()
$fails = {
    param([long]$Batch)
    $probes.Add($Batch)
    $Batch -gt $maxOk           # the fake API times out above 437 items
}.GetNewClosure()

# No digit separators in PowerShell numbers: 10_001 is parsed as a command name.
$largest = (Find-FirstTrue -Lo 1 -Hi 10001 -Predicate $fails) - 1
"Part 2: largest batch the API accepts is $largest, found in $($probes.Count) probes of the range 1..10,000"
'  probed: ' + ($probes -join ', ')
