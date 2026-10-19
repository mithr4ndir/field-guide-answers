#Requires -Version 7.4

<#
.SYNOPSIS
    Drill 4 (retry, backoff, jitter): simulate a thundering herd.

.DESCRIPTION
    1,000 clients each need one successful request. The server handles 100
    requests per second, but it is down for the first 10 seconds. Every failed
    request is retried with one of three strategies:

      none         retry after a fixed 1 s
      exponential  retry after 1, 2, 4, 8 ... s, capped at 60 s
      full_jitter  retry after a random time between 0 and the exponential value

    This is an event-driven simulation: a min-heap holds every client's next
    attempt, ordered by (time, client id). Nothing really sleeps, so it runs
    instantly and is deterministic. Random numbers come from MINSTD, a tiny
    generator written identically in Python, PowerShell and Go, so all three
    print the same numbers.

    Pass -Csv to also write retry_load.csv (requests per second per strategy)
    for plotting.

.PARAMETER Csv
    Also write retry_load.csv to the current directory (Python's --csv).

.NOTES
    PowerShell port of python/thundering_herd.py.
#>

[CmdletBinding()]
param(
    [switch] $Csv
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# The chart uses block characters. A Windows console defaults to an OEM code page
# and would print them as '?'. (.NET never writes a BOM to the console, so this is safe.)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Clients = 1000
$Capacity = 100         # successful requests per 1-second window
$OutageEnd = 10.0       # server is down for t in [0, 10)
$Base = 1.0             # first retry delay, seconds
$Cap = 60.0             # longest retry delay, seconds
$Seed = 42
$ChartSeconds = 60
$Strategies = 'none', 'exponential', 'full_jitter'
$Inv = [cultureinfo]::InvariantCulture

class MinStd {
    # Park-Miller "minimal standard" generator (multiplier 48271).
    # Small and identical in every language. Fine for simulations, never for
    # security or anything that needs high-quality randomness.

    static [long] $M = 2147483647
    # [long], not [int]: State * 48271 needs up to 47 bits. An [int] product that
    # overflows doesn't raise an error; PowerShell quietly turns it into a [double].
    [long] $State

    MinStd([long] $Seed) {
        $this.State = $Seed
    }

    # A double in (0, 1).
    [double] Random() {
        $this.State = $this.State * 48271 % [MinStd]::M
        # [long] / [long] is a double division, the same IEEE operation as Python's /.
        return $this.State / [MinStd]::M
    }
}

function Get-RetryDelay {
    <#
    .SYNOPSIS
        Seconds to wait after a client's Failures-th failure (1-based).
    #>
    param([string] $Strategy, [int] $Failures, [MinStd] $Rng)
    if ($Strategy -eq 'none') {
        return 1.0
    }
    $backoff = [Math]::Min($Cap, $Base * [Math]::Pow(2, [Math]::Min($Failures - 1, 30)))  # 1, 2, 4, ... capped at 60
    if ($Strategy -eq 'exponential') {
        return $backoff
    }
    return $Rng.Random() * $backoff                     # full jitter: uniform in (0, backoff)
}

function Invoke-Simulation {
    <#
    .SYNOPSIS
        Run the whole herd with one retry strategy and return per-second arrivals.
    #>
    param([Parameter(Mandatory)] [string] $Strategy)
    $rng = [MinStd]::new($Seed)
    # A min-heap keyed by (time, client id). ValueTuple compares item by item, so
    # equal times go to the lower client id, exactly like Python's tuples.
    $events = [System.Collections.Generic.PriorityQueue[int, System.ValueTuple[double, int]]]::new()
    for ($client = 0; $client -lt $Clients; $client++) {
        $events.Enqueue($client, [System.ValueTuple[double, int]]::new(0.0, $client))    # everyone fires at t=0
    }
    $failures = [int[]]::new($Clients)
    $arrivals = @{}     # second -> requests that reached the server
    $served = @{}       # second -> requests that succeeded
    $finish = 0.0
    $client = 0
    $when = [System.ValueTuple[double, int]]::new(0.0, 0)
    while ($events.TryDequeue([ref]$client, [ref]$when)) {
        $t = $when.Item1
        # Python's int(t) truncates; PowerShell's [int]$t rounds, half to even
        # ([int]2.5 is 2, [int]3.5 is 4). Floor first, then cast the whole number:
        # the keys must all be [int], because [double]10.0 and [int]10 are
        # different hashtable keys.
        $second = [int][Math]::Floor($t)
        $arrivals[$second] += 1                         # a missing key reads as $null, and $null + 1 is 1
        if ($t -ge $OutageEnd -and [int]$served[$second] -lt $Capacity) {
            $served[$second] += 1
            $finish = $t
            continue                                    # this client is done
        }
        $failures[$client]++                            # server down, or over capacity
        $retryAt = $t + (Get-RetryDelay $Strategy $failures[$client] $rng)
        $events.Enqueue($client, [System.ValueTuple[double, int]]::new($retryAt, $client))
    }
    # The herd that matters is the one that hits the server as it recovers. Python's
    # max(key=(arrivals, -sec)): most arrivals, and the earliest second on a tie.
    $peakSecond = $arrivals.Keys | Where-Object { $_ -ge $OutageEnd } |
        Sort-Object -Property @{ Expression = { $arrivals[$_] }; Descending = $true }, @{ Expression = { $_ } } |
        Select-Object -First 1
    [pscustomobject]@{
        Arrivals   = $arrivals
        Total      = [int]($arrivals.Values | Measure-Object -Sum).Sum
        Peak       = $arrivals[$peakSecond]
        PeakSecond = $peakSecond
        Finish     = $finish
    }
}

function Format-Fixed1 {
    <#
    .SYNOPSIS
        Num/Den with one decimal, rounded half up, using integers only.
    #>
    param([long] $Num, [long] $Den)
    # PowerShell's / gives a double. [Math]::DivRem is an exact integer divmod (it
    # truncates, which matches Python's // for non-negative numbers).
    $tenths = [Math]::DivRem($Num * 20 + $Den, 2 * $Den).Item1
    "$([Math]::DivRem($tenths, 10).Item1).$($tenths % 10)"
}

function Get-Sparkline {
    <#
    .SYNOPSIS
        One character per second. Eight heights, each step worth Top/8 requests, rounded up.
    #>
    param([hashtable] $Arrivals, [int] $Seconds, [int] $Top)
    # " ▁▂▃▄▅▆▇█" written with escapes so the script file stays plain ASCII.
    $blocks = " `u{2581}`u{2582}`u{2583}`u{2584}`u{2585}`u{2586}`u{2587}`u{2588}"
    $line = [System.Text.StringBuilder]::new()
    for ($second = 0; $second -lt $Seconds; $second++) {
        $v = [int]$Arrivals[$second]                    # [int]$null is 0, like .get(second, 0)
        $level = if ($v -eq 0) { 0 } else { [Math]::Min(8, [Math]::DivRem($v * 8 + $Top - 1, $Top).Item1) }  # integer ceil, clamped: 1..8
        # Append() returns the builder. Without $null = it would become part of
        # this function's output.
        $null = $line.Append($blocks[$level])
    }
    $line.ToString()
}

"Drill 4: thundering herd. $($Clients.ToString('N0', $Inv)) clients, server handles $Capacity/s, " +
"down for the first $($OutageEnd.ToString('F0', $Inv)) s."
$results = @{}
foreach ($s in $Strategies) {
    $results[$s] = Invoke-Simulation -Strategy $s
}

[string]::Format($Inv, '{0,-12} {1,8} {2,10}   {3,-21} {4,11}', 'strategy', 'requests', 'per client', 'peak after recovery', 'all done at')
foreach ($s in $Strategies) {
    $r = $results[$s]
    $peak = [string]::Format($Inv, '{0:N0}/s at t={1}', $r.Peak, $r.PeakSecond)
    [string]::Format($Inv, '{0,-12} {1,8:N0} {2,10}   {3,-21} {4,10:F1}s', $s, $r.Total, (Format-Fixed1 $r.Total $Clients), $peak, $r.Finish)
}

$top = $Clients
[string]::Format($Inv, 'Requests per second, first {0} s (each block step is {1}/s, rounded up; capacity is {2}/s):',
    $ChartSeconds, [Math]::DivRem($top, 8).Item1, $Capacity)
foreach ($s in $Strategies) {
    [string]::Format($Inv, '{0,-12} |{1}|', $s, (Get-Sparkline $results[$s].Arrivals $ChartSeconds $top))
}

$waves = $results['exponential'].Arrivals.GetEnumerator() |
    Where-Object { $_.Value -ge $Capacity } | ForEach-Object { $_.Key } | Sort-Object
'exponential sends synchronized waves at t = ' + ($waves -join ', ')

if ($Csv) {
    $last = ($results.Values | ForEach-Object { $_.Arrivals.Keys } | Measure-Object -Maximum).Maximum
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('second,' + ($Strategies -join ','))
    for ($sec = 0; $sec -le $last; $sec++) {
        $lines.Add("$sec," + (($Strategies | ForEach-Object { [int]$results[$_].Arrivals[$sec] }) -join ','))
    }
    # Set-Content resolves a relative path against PowerShell's current location.
    # .NET calls such as [IO.File]::WriteAllLines('retry_load.csv', ...) use the
    # process's working directory instead, which Set-Location does not change.
    Set-Content -Path 'retry_load.csv' -Value $lines
    '~ wrote retry_load.csv'
}
