#Requires -Version 7.4

<#
.SYNOPSIS
    Drill 5 (rate limiting): a token bucket, tested with a fake clock.

.DESCRIPTION
    The bucket holds up to Burst tokens and refills at Rate tokens per second.
    Each request spends one token; with no token, the request is denied (or the
    caller waits). Refill is lazy: it is computed from the elapsed time on each
    call, so there is no background timer.

    The current time is passed in rather than read inside the class. That one
    choice makes it testable: part 1 drives it with exact fake timestamps, part 2
    drives it with the real clock to pace a bulk job.

.NOTES
    PowerShell port of python/token_bucket.py.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Inv = [cultureinfo]::InvariantCulture

class TokenBucket {
    # Not thread-safe as written: Allow() reads, then writes, the token count. If
    # several threads share one bucket (say, from ForEach-Object -Parallel), guard
    # Allow() with [System.Threading.Monitor]::Enter/Exit on a lock object, and mark
    # the class [NoRunspaceAffinity()] so its methods may run on other threads.

    [double] $Rate          # tokens added per second
    [double] $Burst         # bucket size = largest allowed burst
    [double] $Tokens        # start full
    [double] $Last

    TokenBucket([double] $Rate, [double] $Burst, [double] $Now) {
        $this.Rate = $Rate
        $this.Burst = $Burst
        $this.Tokens = $Burst
        $this.Last = $Now
    }

    # Class methods can't have default parameter values (Python's cost=1.0); the
    # usual workaround is an overload that fills it in.
    [bool] Allow([double] $Now) {
        return $this.Allow($Now, 1.0)
    }

    # Spend Cost tokens if available. Returns $true if the request may proceed.
    [bool] Allow([double] $Now, [double] $Cost) {
        $this.Tokens = [Math]::Min($this.Burst, $this.Tokens + ($Now - $this.Last) * $this.Rate)
        $this.Last = $Now
        if ($this.Tokens -ge $Cost) {
            $this.Tokens -= $Cost
            return $true
        }
        return $false
    }

    [double] WaitTime() {
        return $this.WaitTime(1.0)
    }

    # Seconds until Cost tokens will be available (call after Allow() returns $false).
    [double] WaitTime([double] $Cost) {
        return [Math]::Max(0.0, ($Cost - $this.Tokens) / $this.Rate)
    }
}

function Get-OktaPause {
    <#
    .SYNOPSIS
        Seconds to pause based on Okta's X-Rate-Limit-* response headers.
    .DESCRIPTION
        Keep going while more than Floor of the limit is left; below that,
        wait until the window resets instead of running into 429s.
    .NOTES
        From a real call: Invoke-RestMethod ... -ResponseHeadersVariable h. Each
        header value is a string array, so [int]$h['X-Rate-Limit-Remaining'] fails;
        use [int]$h['X-Rate-Limit-Remaining'][0]. (Key lookup ignores case.)
    #>
    param(
        [Parameter(Mandatory)] [int] $Remaining,
        [Parameter(Mandatory)] [int] $Limit,
        [Parameter(Mandatory)] [long] $ResetEpoch,
        [Parameter(Mandatory)] [long] $NowEpoch,
        [double] $Floor = 0.1
    )
    if ($Remaining -gt $Limit * $Floor) {
        return 0.0
    }
    return [Math]::Max(0.0, $ResetEpoch - $NowEpoch)
}

function Show-FakeClockDemo {
    $rate = 4
    $burst = 8
    $step = 1 / 16          # 16 requests per second offered; exactly representable
    $bucket = [TokenBucket]::new($rate, $burst, 0.0)
    "Part 1, fake clock: rate $rate/s, burst $burst, one request every 1/16 s for 4 s (# allowed, . denied)"
    $total = 0
    for ($second = 0; $second -lt 4; $second++) {
        # A loop's output can be collected like any other; unary -join glues it
        # together, like Python's ''.join(marks).
        $marks = -join $(
            for ($i = 0; $i -lt 16; $i++) {
                $t = ($second * 16 + $i) * $step
                if ($bucket.Allow($t)) { '#' } else { '.' }
            }
        )
        # With an array on the left, -eq filters: these are the '#' characters.
        $allowed = ($marks.ToCharArray() -eq '#').Count
        $total += $allowed
        [string]::Format($Inv, '  second {0}: {1}  {2,2} allowed', $second, $marks, $allowed)
    }
    "  total allowed: $total of 64 (burst $burst + about $rate/s x 4 s)"
}

function Invoke-PacedBulkJob {
    <#
    .SYNOPSIS
        Part 2: wrap a bulk job so it never exceeds the limit, using the real clock.
    #>
    param([int] $Calls = 20, [int] $Rate = 10, [int] $Burst = 5)
    # A Stopwatch is monotonic like Python's time.monotonic(): it never jumps when
    # the wall clock is adjusted. Don't measure intervals with Get-Date.
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $bucket = [TokenBucket]::new($Rate, $Burst, $clock.Elapsed.TotalSeconds)
    $start = $clock.Elapsed.TotalSeconds
    for ($c = 0; $c -lt $Calls; $c++) {
        while (-not $bucket.Allow($clock.Elapsed.TotalSeconds)) {
            # Sleeps overshoot, especially on Windows (default timer tick ~15.6 ms).
            # That's fine: the next Allow() refills from the real elapsed time, so
            # the error doesn't add up. -Duration (7.3+) takes a TimeSpan, so the
            # fractional wait passes straight in. (In Windows PowerShell 5.1,
            # -Seconds was an [int]: -Seconds 0.1 rounded to 0.)
            Start-Sleep -Duration ([TimeSpan]::FromSeconds($bucket.WaitTime()))
        }
        # the API call would go here
    }
    $elapsed = $clock.Elapsed.TotalSeconds - $start
    $expected = ($Calls - $Burst) / $Rate
    "Part 2, real clock: $Calls calls at $Rate/s with burst $Burst"
    [string]::Format($Inv, '~ took {0:F2} s (expect about {1:F1} s: {2} immediately, then {3} at {4}/s)',
        $elapsed, $expected, $Burst, $Calls - $Burst, $Rate)
}

'Drill 5: token bucket rate limiter.'
Show-FakeClockDemo
Invoke-PacedBulkJob
$pause = Get-OktaPause -Remaining 40 -Limit 600 -ResetEpoch 1700000012 -NowEpoch 1700000000
"Part 3, Okta headers: 40 of 600 calls left, window resets in 12 s -> pause $($pause.ToString('F0', $Inv)) s"
