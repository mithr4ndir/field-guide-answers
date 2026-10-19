#Requires -Version 7.4

<#
.SYNOPSIS
    Drill 3 (queues and backpressure): what happens when a bounded queue fills up.

.DESCRIPTION
    A producer makes 50 items, one every 20 ms. A consumer needs 60 ms per item,
    so it is 3x too slow. The queue holds 5 items. Each run uses one of the four
    things you can do when the queue is full:

      block        producer waits for space (backpressure). Nothing lost; the
                   producer slows to the consumer's pace.
      drop_newest  reject the new item. Keeps the oldest data.
      drop_oldest  evict the oldest queued item to make room. Keeps the newest data.
      spill        overflow goes to a file on disk and is drained in order.
                   Nothing lost, producer never waits, but disk is slower and finite.

    Thread timing varies, so the counts are approximate (lines starting with "~").
    The invariants on the other lines hold on every run.

.NOTES
    PowerShell port of python/backpressure.py.
    The producer runs on the main thread and the consumer in a thread job
    (Start-ThreadJob, which ships with PowerShell 7). The two threads share
    only objects that are safe to use from several threads: BlockingCollection,
    ConcurrentQueue, ManualResetEventSlim, and the SpillQueue below, which does
    its own locking.
    Sleep times are approximate. Windows' default timer resolution is about
    15.6 ms, so a 20 ms sleep there can take up to ~31 ms.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Items = 50
$ProduceEveryMs = 20    # milliseconds between items
$ConsumeMs = 60         # milliseconds of work per item
$Capacity = 5
$Inv = [cultureinfo]::InvariantCulture

# By default a PowerShell class instance is tied to the runspace that created it:
# calling its methods from another thread sends them back to that runspace, which
# can corrupt its state or deadlock. [NoRunspaceAffinity()] (new in 7.4) runs each
# method in the calling thread's own runspace instead. All shared state here is
# plain .NET fields, guarded by one lock.
[NoRunspaceAffinity()]
class SpillQueue {
    # Bounded in-memory queue that overflows to a file instead of blocking.
    #
    # Order is preserved: once anything is on disk, new items also go to disk
    # until the consumer has drained it, and the consumer always empties memory
    # before reading the file. So memory always holds the oldest items.

    [int] $Capacity
    [int] $OnDisk          # items written to the file and not yet read back
    [int] $Spilled         # total items that ever went to disk
    [bool] $Closed
    hidden [System.Collections.Generic.Queue[int]] $Memory = [System.Collections.Generic.Queue[int]]::new()
    hidden [object] $Lock = [object]::new()
    hidden [System.IO.StreamWriter] $Writer
    hidden [System.IO.StreamReader] $Reader

    SpillQueue([int] $Capacity, [string] $Path) {
        $this.Capacity = $Capacity
        # Two handles on one file. Windows refuses the second open unless each handle
        # allows the other's access, so both share ReadWrite.
        $this.Writer = [System.IO.StreamWriter]::new([System.IO.FileStream]::new($Path, 'Create', 'Write', 'ReadWrite'))
        $this.Reader = [System.IO.StreamReader]::new([System.IO.FileStream]::new($Path, 'Open', 'Read', 'ReadWrite'))
    }

    # Monitor.Enter/Wait/Pulse/Exit is Python's threading.Condition. try/finally
    # makes sure the lock is released even on return or error.
    [void] Put([int] $Item) {
        [System.Threading.Monitor]::Enter($this.Lock)
        try {
            if ($this.OnDisk -eq 0 -and $this.Memory.Count -lt $this.Capacity) {
                $this.Memory.Enqueue($Item)
            }
            else {
                $this.Writer.WriteLine($Item)
                $this.Writer.Flush()
                $this.OnDisk++
                $this.Spilled++
            }
            [System.Threading.Monitor]::Pulse($this.Lock)
        }
        finally {
            [System.Threading.Monitor]::Exit($this.Lock)
        }
    }

    # Next item, or $null once the queue is closed and empty (Python's DONE).
    [object] Get() {
        [System.Threading.Monitor]::Enter($this.Lock)
        try {
            while ($this.Memory.Count -eq 0 -and $this.OnDisk -eq 0) {
                if ($this.Closed) {
                    return $null
                }
                $null = [System.Threading.Monitor]::Wait($this.Lock)    # releases the lock while it waits
            }
            if ($this.Memory.Count -gt 0) {
                return $this.Memory.Dequeue()
            }
            $this.OnDisk--
            return [int]$this.Reader.ReadLine()
        }
        finally {
            [System.Threading.Monitor]::Exit($this.Lock)
        }
    }

    [void] Close() {
        [System.Threading.Monitor]::Enter($this.Lock)
        try {
            $this.Closed = $true
            [System.Threading.Monitor]::PulseAll($this.Lock)
        }
        finally {
            [System.Threading.Monitor]::Exit($this.Lock)
        }
        # The consumer may still be reading; the files are closed after it finishes.
    }

    [void] Dispose() {
        $this.Writer.Dispose()
        $this.Reader.Dispose()
    }
}

function Invoke-Strategy {
    <#
    .SYNOPSIS
        Run the producer and consumer once with one strategy; return what happened.
    #>
    param([Parameter(Mandatory)] [string] $Strategy)

    $spillFile = $null
    if ($Strategy -eq 'spill') {
        $spillFile = New-TemporaryFile
        $queue = [SpillQueue]::new($Capacity, $spillFile.FullName)
    }
    else {
        # Bounded: Add() blocks while full, TryAdd() returns $false instead.
        $queue = [System.Collections.Concurrent.BlockingCollection[int]]::new($Capacity)
    }
    $delivered = [System.Collections.Concurrent.ConcurrentQueue[int]]::new()
    $ages = [System.Collections.Concurrent.ConcurrentQueue[double]]::new()     # ms from produced to picked up
    # When each item was produced. Only the producer writes born[i], and only before
    # it hands item i to the queue; the consumer reads it after taking item i out.
    # The queue's own locking orders the two, so a plain array is safe here.
    $born = [long[]]::new($Items)
    $ready = [System.Threading.ManualResetEventSlim]::new($false)

    try {
        $worker = Start-ThreadJob -ScriptBlock {
            # A thread job is a fresh runspace: it does not inherit StrictMode or
            # $ErrorActionPreference from the script that started it.
            Set-StrictMode -Version Latest
            $ErrorActionPreference = 'Stop'
            # $using: passes references to the same objects; nothing is copied.
            $queue = $using:queue
            $delivered = $using:delivered
            $ages = $using:ages
            $born = $using:born
            $consumeMs = $using:ConsumeMs

            function Receive-QueueItem([int] $Item) {
                $ages.Enqueue([System.Diagnostics.Stopwatch]::GetElapsedTime($born[$Item]).TotalMilliseconds)
                Start-Sleep -Milliseconds $consumeMs        # simulate slow work
                $delivered.Enqueue($Item)
            }

            ($using:ready).Set()
            if ($using:Strategy -eq 'spill') {
                # Compare with $null: `while ($item = $queue.Get())` would stop at item 0,
                # because 0 is falsy. Python's `item is DONE` avoids the same trap.
                while ($null -ne ($item = $queue.Get())) {
                    Receive-QueueItem $item
                }
            }
            else {
                # Blocks while empty; ends once CompleteAdding() was called and the queue is drained.
                foreach ($item in $queue.GetConsumingEnumerable()) {
                    Receive-QueueItem $item
                }
            }
        }

        # Start-ThreadJob returns before the new runspace is running (over 100 ms
        # the first time). Wait for it, or the producer races ahead of a consumer
        # that doesn't exist yet. Python's thread starts in microseconds.
        if (-not $ready.Wait([TimeSpan]::FromSeconds(30))) {
            throw 'The consumer thread did not start.'
        }

        $dropped = 0
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt $Items; $i++) {
            $born[$i] = [System.Diagnostics.Stopwatch]::GetTimestamp()
            switch ($Strategy) {
                'block' {
                    $queue.Add($i)                      # waits for space
                }
                'spill' {
                    $queue.Put($i)                      # never waits
                }
                'drop_newest' {
                    if (-not $queue.TryAdd($i)) {
                        $dropped++                      # the new item is lost
                    }
                }
                'drop_oldest' {
                    while (-not $queue.TryAdd($i)) {
                        $oldest = 0
                        if ($queue.TryTake([ref]$oldest)) {
                            $dropped++                  # threw away the oldest queued item
                        }
                        # else the consumer took one first; just retry
                    }
                }
            }
            Start-Sleep -Milliseconds $ProduceEveryMs
        }
        $producerSeconds = $clock.Elapsed.TotalSeconds

        if ($Strategy -eq 'spill') {
            $queue.Close()
        }
        else {
            $queue.CompleteAdding()                     # .NET's way to say DONE: no sentinel value needed
        }
        # Python's worker.join(). Receive-Job also re-throws any error from the thread;
        # Wait-Job alone would leave the job quietly marked Failed.
        Receive-Job -Job $worker -Wait -AutoRemoveJob
        $totalSeconds = $clock.Elapsed.TotalSeconds

        $spilled = if ($Strategy -eq 'spill') { $queue.Spilled } else { 0 }
        [pscustomobject]@{
            Strategy        = $Strategy
            Delivered       = $delivered.ToArray()
            Dropped         = $dropped
            Spilled         = $spilled
            ProducerSeconds = $producerSeconds
            TotalSeconds    = $totalSeconds
            AvgAgeMs        = ($ages.ToArray() | Measure-Object -Average).Average
        }
    }
    finally {
        $queue.Dispose()
        $ready.Dispose()
        if ($spillFile) {
            Remove-Item -LiteralPath $spillFile.FullName
        }
    }
}

function Format-IdRange {
    <#
    .SYNOPSIS
        Compress 0,1,2,5,7,8,9 into '0-2,5,7-9'.
    #>
    param([int[]] $Ids)
    $parts = [System.Collections.Generic.List[string]]::new()
    $i = 0
    while ($i -lt $Ids.Count) {
        $j = $i
        while ($j + 1 -lt $Ids.Count -and $Ids[$j + 1] -eq $Ids[$j] + 1) {
            $j++
        }
        $parts.Add($(if ($i -eq $j) { "$($Ids[$i])" } else { "$($Ids[$i])-$($Ids[$j])" }))
        $i = $j + 1
    }
    $parts -join ','
}

function ConvertTo-YesNo([bool] $Value) {
    if ($Value) { 'yes' } else { 'no' }
}

"Drill 3: queues and backpressure. $Items items, producer every $ProduceEveryMs ms, " +
"consumer $ConsumeMs ms/item, queue holds $Capacity."

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($strategy in 'block', 'drop_newest', 'drop_oldest', 'spill') {
    $run = Invoke-Strategy -Strategy $strategy
    $delivered = $run.Delivered
    $inOrder = $true
    for ($k = 1; $k -lt $delivered.Count; $k++) {
        if ($delivered[$k] -lt $delivered[$k - 1]) { $inOrder = $false }
    }
    $accounted = $delivered.Count + $run.Dropped -eq $Items
    if ($strategy -in 'block', 'spill') {
        $lost = $Items - $delivered.Count
        [string]::Format($Inv, '{0,-12} lost {1}, in order: {2}', $strategy, $lost, (ConvertTo-YesNo $inOrder))
    }
    elseif ($strategy -eq 'drop_newest') {
        $firstIdsKept = $true
        foreach ($id in 0..($Capacity - 1)) {
            if ($id -notin $delivered) { $firstIdsKept = $false }
        }
        [string]::Format($Inv, '{0,-12} delivered + dropped = {1}: {2}, ids 0-{3} all delivered: {4} (the queue still has room when they arrive)',
            $strategy, $Items, (ConvertTo-YesNo $accounted), ($Capacity - 1), (ConvertTo-YesNo $firstIdsKept))
    }
    else {
        [string]::Format($Inv, '{0,-12} delivered + dropped = {1}: {2}, last delivered id: {3} (the newest item always survives)',
            $strategy, $Items, (ConvertTo-YesNo $accounted), $delivered[-1])
    }
    $rows.Add($run)
}

[string]::Format($Inv, '~ {0,-12} {1,9} {2,7} {3,7} {4,11} {5,8} {6,11}  delivered ids',
    'strategy', 'delivered', 'dropped', 'spilled', 'producer(s)', 'total(s)', 'avg age(ms)')
foreach ($run in $rows) {
    [string]::Format($Inv, '~ {0,-12} {1,9} {2,7} {3,7} {4,11:F2} {5,8:F2} {6,11:F0}  {7}',
        $run.Strategy, $run.Delivered.Count, $run.Dropped, $run.Spilled, $run.ProducerSeconds,
        $run.TotalSeconds, $run.AvgAgeMs, (Format-IdRange $run.Delivered))
}
