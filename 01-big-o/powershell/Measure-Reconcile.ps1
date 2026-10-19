#Requires -Version 7.4

<#
.SYNOPSIS
    Drill 1 (Big-O): time an O(n^2) reconciliation against an O(n) one.

.DESCRIPTION
    Reconciles N Jamf devices against N Okta Verify devices, where every 20th
    device is missing from Okta, two ways:

      nested  for each Jamf device, scan the whole Okta list. This is the
              foreach + Where-Object pattern: n x n comparisons, O(n^2).
      hash    build a dictionary keyed by serial once (O(n)), then one pass over
              Jamf with O(1) lookups. O(n) overall.

    Then it checks the growth against the prediction: 6x more devices should
    cost about 36x more for nested and about 6x more for hash.

    Lines starting with "~" are timings and vary by machine.

.NOTES
    PowerShell port of python/reconcile_bench.py.

    Where-Object runs a scriptblock per item, about 4 microseconds each on the
    test machine. At n = 6,000 that is 34 million calls, about two minutes per
    run, and the timing takes the best of 3 runs: over 5 minutes. So the timed
    nested version is a plain foreach with -ceq. It is still O(n^2), just about
    35x cheaper per comparison. The classic Where-Object version is
    Get-MissingWhereObject; it runs once at n = 1,000 so you can see its cost.
#>

using namespace System.Collections.Generic

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Sizes = 100, 1000, 6000
# -f and .ToString() use the current culture: '{0:N0}' -f 1234 prints "1.234" on a
# de-DE machine. Pass the invariant culture so the output is the same everywhere.
$Inv = [cultureinfo]::InvariantCulture

function New-Inventory {
    <#
    .SYNOPSIS
        Deterministic fake inventories. Okta lists devices in a different order
        (real exports rarely line up) and is missing every 20th one.
    #>
    param([Parameter(Mandatory)] [int] $N)
    $osVersions = '14.7', '15.3', '15.4'
    # List[T].Add is O(1). $array += $item copies the whole array each time, which
    # is O(n^2) all by itself.
    $jamf = [List[object]]::new($N)
    for ($i = 0; $i -lt $N; $i++) {
        $jamf.Add([pscustomobject]@{ serial = 'SN' + $i.ToString('D6', $Inv); os = $osVersions[$i % 3] })
    }
    $okta = [List[object]]::new($N)
    for ($i = $N - 1; $i -ge 0; $i--) {
        if ($i % 20 -ne 0) {
            $okta.Add([pscustomobject]@{ serial = 'SN' + $i.ToString('D6', $Inv); trust = 'managed' })
        }
    }
    # Two objects out; the caller unpacks them with $jamf, $okta = New-Inventory ...
    return $jamf, $okta
}

function Get-MissingNested {
    <#
    .SYNOPSIS
        O(n^2): scan every Okta record for every Jamf record.
    #>
    param($Jamf, $Okta)
    $missing = [List[string]]::new()
    foreach ($j in $Jamf) {
        $serial = $j.serial
        # Like Python's list comprehension: collect every match, no early exit.
        # -ceq is case-sensitive like Python's ==. The everyday -eq ignores case,
        # which is harmless with these all-uppercase serials; drill 11 shows when it isn't.
        $hits = @(foreach ($o in $Okta) { if ($o.serial -ceq $serial) { $o } })
        if ($hits.Count -eq 0) {
            $missing.Add($serial)
        }
    }
    # A function's output is unrolled: a one-item list would come back as a bare
    # string and an empty one as $null. The leading comma returns the list itself.
    , $missing
}

function Get-MissingWhereObject {
    <#
    .SYNOPSIS
        The same O(n^2) scan, written as the classic foreach + Where-Object.
    #>
    param($Jamf, $Okta)
    $missing = [List[string]]::new()
    foreach ($j in $Jamf) {
        # Don't call this variable $matches: that's the automatic variable -match fills in.
        $hits = @($Okta | Where-Object { $_.serial -ceq $j.serial })
        if ($hits.Count -eq 0) {
            $missing.Add($j.serial)
        }
    }
    , $missing
}

function Get-MissingHash {
    <#
    .SYNOPSIS
        O(n): one pass to build the index, one pass to probe it.
    #>
    param($Jamf, $Okta)
    # A generic Dictionary compares string keys case-sensitively (ordinal), like
    # Python's dict. @{} would also work for this data, but it ignores case.
    $oktaBySerial = [Dictionary[string, object]]::new()
    foreach ($o in $Okta) {
        $oktaBySerial[$o.serial] = $o
    }
    $missing = [List[string]]::new()
    foreach ($j in $Jamf) {
        if (-not $oktaBySerial.ContainsKey($j.serial)) {
            $missing.Add($j.serial)
        }
    }
    , $missing
}

function Measure-Fastest {
    <#
    .SYNOPSIS
        Run the scriptblock $Repeats times and keep the fastest run. Tiny timings
        are noisy, and the minimum is the best estimate of the real cost.
    .NOTES
        Measure-Command would time it too, but it throws away the scriptblock's
        output, and here we need the result as well.
    #>
    param(
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [int] $Repeats = 1
    )
    $best = [double]::PositiveInfinity
    $result = $null
    for ($r = 0; $r -lt $Repeats; $r++) {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = & $ScriptBlock
        $stopwatch.Stop()
        $best = [Math]::Min($best, $stopwatch.Elapsed.TotalSeconds)
    }
    return $result, $best
}

'Drill 1: Big-O. Reconcile N Jamf devices against N Okta devices (every 20th missing from Okta).'
$found = [List[string]]::new()
$timings = @{}
foreach ($n in $Sizes) {
    $jamf, $okta = New-Inventory -N $n
    $nested, $tNested = Measure-Fastest { Get-MissingNested $jamf $okta } -Repeats 3
    $hashed, $tHash = Measure-Fastest { Get-MissingHash $jamf $okta } -Repeats 50
    # Same devices in the same order. (-eq between two lists doesn't compare them;
    # it filters the left list, so use SequenceEqual.)
    if (-not [System.Linq.Enumerable]::SequenceEqual($nested, $hashed)) {
        throw 'both methods must find the same devices'
    }
    if ($n -eq 1000) {
        $piped, $tWhereObject = Measure-Fastest { Get-MissingWhereObject $jamf $okta }
        if (-not [System.Linq.Enumerable]::SequenceEqual($piped, $hashed)) {
            throw 'Where-Object must find the same devices'
        }
        $tForeach1000 = $tNested
    }
    $found.Add([string]::Format($Inv, 'n={0:N0} -> {1:N0}', $n, $nested.Count))
    $timings[$n] = $tNested, $tHash
}
'Missing devices found: ' + ($found -join ', ') + ' (both methods agree)'

# Composite format {0,6} is Python's {:>6}; {0,-12} would be {:<12}.
[string]::Format($Inv, '~ {0,6}  {1,10}  {2,9}  {3,8}', 'n', 'nested (s)', 'hash (s)', 'speedup')
foreach ($n in $Sizes) {
    $tNested, $tHash = $timings[$n]
    [string]::Format($Inv, '~ {0,6:N0}  {1,10:F5}  {2,9:F5}  {3,7:N0}x', $n, $tNested, $tHash, $tNested / $tHash)
}
# PowerShell code runs slower in the first seconds of a session while the engine
# warms up, and timings of a few milliseconds suffer most. On the test machine the
# hash version's n = 1,000 time reads about twice its settled value, so its growth
# shows as 2-3x; run the same loop a second time in one session and it reads ~6x.
$nestedGrowth = $timings[6000][0] / $timings[1000][0]
$hashGrowth = $timings[6000][1] / $timings[1000][1]
[string]::Format($Inv, '~ Growth from 1,000 to 6,000 devices (6x): nested {0:F1}x slower (predict 36x), hash {1:F1}x (predict 6x)',
    $nestedGrowth, $hashGrowth)
[string]::Format($Inv, '~ foreach + Where-Object at n=1,000: {0:F2} s, {1:F1}x the foreach loop; about {2:N0} s per run at n=6,000 (36x)',
    $tWhereObject, $tWhereObject / $tForeach1000, $tWhereObject * 36)
