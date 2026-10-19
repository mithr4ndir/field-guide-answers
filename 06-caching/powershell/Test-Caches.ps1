#Requires -Version 7.4

<#
.SYNOPSIS
    Drill 6 (caching): LRU two ways, SIEVE vs. LRU, and a single-flight wrapper.

.DESCRIPTION
    Part 1  LRU built on an ordered dictionary, and LRU built by hand from a
            dictionary plus a doubly linked list. Both must give identical hit counts.
    Part 2  SIEVE: one queue, a "visited" bit per entry, and a moving hand. It is
            compared with LRU on a trace where 30% of requests are one-hit
            wonders, which is what real cache traces look like.
    Part 3  Single-flight: 10 threads miss the same key at the same moment. Only
            one calls the slow backend; the others wait and share its result.

    The trace comes from MINSTD plus a Zipf distribution, so Python, PowerShell
    and Go replay exactly the same 100,000 requests and print the same hit ratios.

.NOTES
    PowerShell port of python/caches.py.
    The caches are classes because a method call costs a fraction of a function
    call, and the trace makes 600,000 of them.
#>

using namespace System.Collections.Generic

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Requests = 100000
$Popular = 10000            # object ids 0..9,999, requested with Zipf popularity
$OneHitShare = 0.30         # share of requests for ids that never repeat
$Seed = 7
$Sizes = 100, 1000
$Inv = [cultureinfo]::InvariantCulture

class MinStd {
    # Park-Miller "minimal standard" generator (multiplier 48271). Same in every language.
    static [long] $M = 2147483647
    [long] $State           # [long]: State * 48271 overflows [int] (which would quietly become [double])

    MinStd([long] $Seed) {
        $this.State = $Seed
    }

    [double] Random() {
        $this.State = $this.State * 48271 % [MinStd]::M
        return $this.State / [MinStd]::M
    }
}

class LruOrderedDict {
    # LRU in a few lines with OrderedDictionary, the type behind [ordered]@{}.
    # Two differences from Python's OrderedDict bite here:
    #   * There is no move_to_end. Remove + Add does the same job, but Remove scans
    #     the entry list, so it is O(n) where move_to_end is O(1).
    #   * The indexer treats an [int] as a position: $od[5] is the sixth entry, not
    #     key 5, and $od[5] = $x throws on a short dictionary. With integer keys use
    #     Contains/Add/Remove, never $od[$key].
    [int] $Capacity
    hidden [System.Collections.Specialized.OrderedDictionary] $Data = [System.Collections.Specialized.OrderedDictionary]::new()

    LruOrderedDict([int] $Capacity) {
        $this.Capacity = $Capacity
    }

    # $true on a hit. On a miss, inserts the key (evicting if full).
    [bool] Access([int] $Key) {
        if ($this.Data.Contains($Key)) {
            $this.Data.Remove($Key)             # re-adding it makes it the most recently used
            $this.Data.Add($Key, $null)
            return $true
        }
        $this.Data.Add($Key, $null)
        if ($this.Data.Count -gt $this.Capacity) {
            $this.Data.RemoveAt(0)              # drop the least recently used
        }
        return $false
    }
}

class CacheNode {
    [int] $Key
    [CacheNode] $Prev
    [CacheNode] $Next
    [bool] $Visited

    CacheNode([int] $Key) {
        $this.Key = $Key
    }
}

class LruLinked {
    # LRU by hand: a Dictionary for O(1) lookup, a doubly linked list for O(1) reordering.
    #
    # Two sentinel nodes mean no special cases for an empty list:
    # Head.Next is the most recently used entry, Tail.Prev the least.
    [int] $Capacity
    hidden [Dictionary[int, CacheNode]] $Map = [Dictionary[int, CacheNode]]::new()
    hidden [CacheNode] $Head = [CacheNode]::new(-1)
    hidden [CacheNode] $Tail = [CacheNode]::new(-1)

    LruLinked([int] $Capacity) {
        $this.Capacity = $Capacity
        $this.Head.Next = $this.Tail
        $this.Tail.Prev = $this.Head
    }

    hidden [void] Unlink([CacheNode] $Node) {
        $Node.Prev.Next = $Node.Next
        $Node.Next.Prev = $Node.Prev
    }

    hidden [void] PushFront([CacheNode] $Node) {
        $Node.Prev = $this.Head
        $Node.Next = $this.Head.Next
        $this.Head.Next.Prev = $Node
        $this.Head.Next = $Node
    }

    [bool] Access([int] $Key) {
        $node = $null
        if ($this.Map.TryGetValue($Key, [ref]$node)) {
            $this.Unlink($node)
            $this.PushFront($node)
            return $true
        }
        $node = [CacheNode]::new($Key)
        $this.Map[$Key] = $node
        $this.PushFront($node)
        if ($this.Map.Count -gt $this.Capacity) {
            $lru = $this.Tail.Prev
            $this.Unlink($lru)
            # Remove() returns a bool. In a class method only `return` produces output,
            # so it doesn't leak; in a function it would need $null =.
            $this.Map.Remove($lru.Key)
        }
        return $false
    }
}

class Sieve {
    # SIEVE (NSDI 2024). New entries go in at the head; a hit only sets a bit.
    #
    # To evict, the hand walks from the tail toward the head. Visited entries
    # have their bit cleared and survive; the first unvisited entry is evicted,
    # and the hand stays where it stopped for next time. One-hit wonders are
    # never visited, so they leave quickly without pushing popular entries out.
    [int] $Capacity
    hidden [Dictionary[int, CacheNode]] $Map = [Dictionary[int, CacheNode]]::new()
    hidden [CacheNode] $Head        # newest; node.Next points toward the tail (older)
    hidden [CacheNode] $Tail        # oldest; node.Prev points toward the head (newer)
    hidden [CacheNode] $Hand

    Sieve([int] $Capacity) {
        $this.Capacity = $Capacity
    }

    [bool] Access([int] $Key) {
        $node = $null
        if ($this.Map.TryGetValue($Key, [ref]$node)) {
            $node.Visited = $true                   # no list surgery on a hit
            return $true
        }
        if ($this.Map.Count -ge $this.Capacity) {
            $this.Evict()
        }
        $node = [CacheNode]::new($Key)
        $this.Map[$Key] = $node
        $node.Next = $this.Head
        if ($null -ne $this.Head) {
            $this.Head.Prev = $node
        }
        $this.Head = $node
        if ($null -eq $this.Tail) {
            $this.Tail = $node
        }
        return $false
    }

    hidden [void] Evict() {
        # ?? (PowerShell 7) returns the right side when the left is $null: Python's
        # `self.hand or self.tail`.
        $node = $this.Hand ?? $this.Tail
        while ($node.Visited) {
            $node.Visited = $false                  # second chance
            $node = $node.Prev ?? $this.Tail        # toward the head, wrapping to the tail
        }
        $this.Hand = $node.Prev
        if ($null -ne $node.Prev) {
            $node.Prev.Next = $node.Next
        }
        else {
            $this.Head = $node.Next
        }
        if ($null -ne $node.Next) {
            $node.Next.Prev = $node.Prev
        }
        else {
            $this.Tail = $node.Prev
        }
        $this.Map.Remove($node.Key)
    }
}

function New-Trace {
    <#
    .SYNOPSIS
        70% Zipf(exponent 1) over the popular ids, 30% brand-new ids (one-hit wonders).
    #>
    $rng = [MinStd]::new($Seed)
    $cdf = [double[]]::new($Popular)
    $total = 0.0
    for ($rank = 1; $rank -le $Popular; $rank++) {
        $total += 1.0 / $rank                       # weight of rank r is 1/r
        $cdf[$rank - 1] = $total
    }
    $trace = [int[]]::new($Requests)
    $nextNewId = 1000000
    for ($r = 0; $r -lt $Requests; $r++) {
        if ($rng.Random() -lt $OneHitShare) {
            $trace[$r] = $nextNewId
            $nextNewId++
        }
        else {
            $x = $rng.Random() * $total
            # Python's bisect_right (first index whose cdf > x). BinarySearch returns the
            # index of an exact match, or the complement of the next larger index.
            $i = [Array]::BinarySearch($cdf, $x)
            if ($i -ge 0) { $i++ } else { $i = -bnot $i }
            $trace[$r] = $i
        }
    }
    # Without the comma PowerShell would unroll all 100,000 ints into the pipeline
    # and rebuild them as an object[]: slower, and the [int[]] type is lost.
    , $trace
}

function Get-HitPct {
    <#
    .SYNOPSIS
        Percent with two decimals, rounded half up, integers only. Returns text and hundredths.
    #>
    param([long] $Hits, [long] $Total)
    # [Math]::DivRem is Python's divmod(); PowerShell's / would give a double.
    $hundredths = [Math]::DivRem($Hits * 20000 + $Total, 2 * $Total).Item1
    $parts = [Math]::DivRem($hundredths, 100)
    "$($parts.Item1).$($parts.Item2.ToString('D2', $Inv))%"
    $hundredths
}

function Measure-HitCount {
    <#
    .SYNOPSIS
        Replay the trace against any object with an Access($key) method; count hits.
    #>
    param($Cache, [int[]] $Trace)
    $hits = 0
    foreach ($key in $Trace) {
        if ($Cache.Access($key)) { $hits++ }
    }
    $hits
}

function Show-SingleFlightDemo {
    param([int] $Callers = 10)
    foreach ($useSingleFlight in $false, $true) {
        # Only thread-safe .NET objects cross into the parallel runspaces.
        $barrier = [System.Threading.Barrier]::new($Callers)
        $inFlight = [System.Collections.Concurrent.ConcurrentDictionary[string, System.Threading.Tasks.Task[object]]]::new()
        $counter = [hashtable]::Synchronized(@{ Calls = 0 })

        # -ThrottleLimit defaults to 5. With 10 callers at a 10-party barrier, five
        # threads would wait forever for five that never start.
        $results = 1..$Callers | ForEach-Object -ThrottleLimit $Callers -Parallel {
            # Each parallel runspace starts clean: no StrictMode, no preferences, and
            # none of the main script's functions.
            Set-StrictMode -Version Latest
            $ErrorActionPreference = 'Stop'
            $barrier = $using:barrier
            $inFlight = $using:inFlight
            $counter = $using:counter

            function Invoke-SlowBackend {
                # $counter.Calls++ is a read then a write, and another thread can get in
                # between. Hold the lock for both, like Python's `with calls_lock`.
                # ([Threading.Interlocked]::Increment([ref]$counter.Calls) would NOT work:
                # [ref] on a property or array element passes a copy, not the original.)
                [System.Threading.Monitor]::Enter($counter.SyncRoot)
                try {
                    $counter.Calls++
                }
                finally {
                    [System.Threading.Monitor]::Exit($counter.SyncRoot)
                }
                Start-Sleep -Milliseconds 200       # a slow catalog rebuild
                'catalog-v42'
            }

            function Invoke-SingleFlight([string] $Key, [scriptblock] $Fn) {
                # Collapse concurrent calls for the same key into one call. Everyone
                # offers its own task; GetOrAdd keeps the first, so exactly one caller
                # gets its own task back. That caller is the leader and runs $Fn.
                $mine = [System.Threading.Tasks.TaskCompletionSource[object]]::new()
                $task = $inFlight.GetOrAdd($Key, $mine.Task)
                if ([object]::ReferenceEquals($task, $mine.Task)) {
                    try {
                        $mine.SetResult((& $Fn))
                    }
                    catch {
                        $mine.SetException($_.Exception)
                    }
                    finally {
                        $null = $inFlight.TryRemove($Key, [ref]$null)
                    }
                }
                # The leader and the followers all get the same result, or the same
                # exception. GetResult() blocks until the leader has set it.
                $task.GetAwaiter().GetResult()
            }

            # Everyone misses at the same moment. The timeout turns a deadlock into an error.
            if (-not $barrier.SignalAndWait([TimeSpan]::FromSeconds(30))) {
                throw 'Not every caller reached the barrier. Is -ThrottleLimit at least the number of callers?'
            }
            if ($using:useSingleFlight) {
                Invoke-SingleFlight -Key 'catalog' -Fn ${function:Invoke-SlowBackend}
            }
            else {
                Invoke-SlowBackend
            }
        }
        $barrier.Dispose()

        $calls = $counter.Calls
        $label = if ($useSingleFlight) { 'with single-flight:   ' } else { 'without single-flight:' }
        $distinct = [HashSet[string]]::new([string[]]$results)      # Python's set(results)
        $same = if ($distinct.Count -eq 1) { 'yes' } else { 'no' }
        $plural = if ($calls -ne 1) { 's' } else { '' }
        "$label $Callers callers -> $calls backend call$plural, all got the same value: $same"
    }
}

"Drill 6: caching. $($Requests.ToString('N0', $Inv)) requests: 70% Zipf over $($Popular.ToString('N0', $Inv)) objects, " +
'30% one-hit wonders.'
$trace = New-Trace
[string]::Format($Inv, '{0,10}  {1,17}  {2,17}  {3,7}  SIEVE vs LRU', 'cache size', 'LRU (library)', 'LRU (hand-built)', 'SIEVE')
$agree = $true
foreach ($size in $Sizes) {
    $lruOd = Measure-HitCount ([LruOrderedDict]::new($size)) $trace
    $lruLl = Measure-HitCount ([LruLinked]::new($size)) $trace
    $sieve = Measure-HitCount ([Sieve]::new($size)) $trace
    $agree = $agree -and $lruOd -eq $lruLl
    $odText, $odHundredths = Get-HitPct $lruOd $Requests
    $llText, $null = Get-HitPct $lruLl $Requests
    $svText, $svHundredths = Get-HitPct $sieve $Requests
    $diff = $svHundredths - $odHundredths
    $sign = if ($diff -ge 0) { '+' } else { '-' }
    $absDiff = [Math]::Abs($diff)
    [string]::Format($Inv, '{0,10:N0}  {1,17}  {2,17}  {3,7}  {4}{5}.{6:D2} points',
        $size, $odText, $llText, $svText, $sign, [Math]::DivRem($absDiff, 100).Item1, $absDiff % 100)
}
"Both LRU implementations agree: $(if ($agree) { 'yes' } else { 'no' })"
Show-SingleFlightDemo
