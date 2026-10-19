#Requires -Version 7.4

<#
.SYNOPSIS
    Drill 2 (consistent hashing): count how many keys move when an 11th node joins.

.DESCRIPTION
    Assigns 100,000 keys to 10 nodes two ways, adds node-10, and counts moves:

      hash % N   owner = hash(key) % N. Changing N reshuffles almost everything.
      hash ring  each node gets 160 virtual points on a ring; a key belongs to the
                 first point clockwise from its hash. A new node only takes over
                 the arcs in front of its own points, about 1/N of the keys.

    The hash is the first 4 bytes of SHA-256, read big-endian, so every language
    gets identical numbers.

.NOTES
    PowerShell port of python/hash_ring.py.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Keys = 100000
$VNodes = 160
# -f and .ToString() use the current culture ("100.000" on de-DE); pass the invariant one.
$Inv = [cultureinfo]::InvariantCulture

class HashRing {
    [long[]] $Positions
    [string[]] $Owners

    # First 4 bytes of SHA-256 as an unsigned 32-bit integer. A static method rather
    # than a function: a PowerShell function call costs ~10x more than a method call,
    # which adds up over 100,000 keys.
    static [long] H32([string] $Text) {
        $digest = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Text))
        # Big-endian, like Python's int.from_bytes(..., "big"). BitConverter.ToUInt32
        # would read the bytes little-endian on x64 and ARM.
        return [System.Buffers.Binary.BinaryPrimitives]::ReadUInt32BigEndian($digest)
    }

    # Class constructors and methods can't have default parameter values (Python's
    # vnodes=VNODES), so the caller always passes the count.
    HashRing([string[]] $Nodes, [int] $VNodes) {
        $points = [System.Collections.Generic.List[System.ValueTuple[long, string]]]::new()
        foreach ($node in $Nodes) {
            for ($v = 0; $v -lt $VNodes; $v++) {
                $points.Add([System.ValueTuple[long, string]]::new([HashRing]::H32("$node#$v"), $node))
            }
        }
        # Sort by (position, node name) so ties break the same way everywhere. The
        # name tie-break must be ordinal, like Python's string order: Sort-Object and
        # ValueTuple's default comparer both compare strings with culture rules.
        $points.Sort([System.Comparison[System.ValueTuple[long, string]]] {
                param($a, $b)
                $byPosition = $a.Item1.CompareTo($b.Item1)
                if ($byPosition -ne 0) { return $byPosition }
                return [string]::CompareOrdinal($a.Item2, $b.Item2)
            })
        $this.Positions = [long[]]::new($points.Count)
        $this.Owners = [string[]]::new($points.Count)
        for ($i = 0; $i -lt $points.Count; $i++) {
            $this.Positions[$i] = $points[$i].Item1
            $this.Owners[$i] = $points[$i].Item2
        }
    }

    [string] Owner([long] $KeyHash) {
        # BinarySearch returns the index when it finds the value, otherwise the bitwise
        # complement of the index of the next larger element. -bnot turns that into
        # Python's bisect_left: the first point >= the key hash. Pass a [long]: with an
        # [int] PowerShell picks the non-generic overload and Int64.CompareTo throws.
        $i = [Array]::BinarySearch($this.Positions, $KeyHash)
        if ($i -lt 0) {
            $i = -bnot $i
        }
        else {
            # Exact hit. If several points shared this position, BinarySearch could land
            # on any of them; bisect_left wants the first.
            while ($i -gt 0 -and $this.Positions[$i - 1] -eq $KeyHash) { $i-- }
        }
        if ($i -eq $this.Positions.Length) {    # past the last point: wrap to the start
            $i = 0
        }
        return $this.Owners[$i]
    }
}

function Format-Pct {
    <#
    .SYNOPSIS
        Percent with one decimal, rounded half up, using integers only.
    #>
    param([long] $Part, [long] $Whole)
    # PowerShell's / returns a double (7 / 2 is 3.5). [Math]::DivRem is Python's
    # divmod(): exact integer quotient and remainder. It truncates rather than floors,
    # which is the same thing for these non-negative numbers.
    $tenths = [Math]::DivRem($Part * 2000 + $Whole, 2 * $Whole).Item1
    $parts = [Math]::DivRem($tenths, 10)       # (quotient, remainder)
    "$($parts.Item1).$($parts.Item2)%"
}

[string[]] $nodes10 = foreach ($i in 0..9) { "node-$i" }
[string[]] $nodes11 = $nodes10 + 'node-10'
$hashes = [long[]]::new($Keys)
for ($i = 0; $i -lt $Keys; $i++) {
    $hashes[$i] = [HashRing]::H32("key-$i")
}

"Drill 2: consistent hashing. $($Keys.ToString('N0', $Inv)) keys, cluster grows from 10 to 11 nodes."

$movedMod = 0
foreach ($h in $hashes) {
    if ($h % 10 -ne $h % 11) { $movedMod++ }
}
[string]::Format($Inv, 'hash % N   moved {0,6:N0} keys ({1})   expect ~90.9% (10 of 11)',
    $movedMod, (Format-Pct $movedMod $Keys))

$ring10 = [HashRing]::new($nodes10, $VNodes)
$ring11 = [HashRing]::new($nodes11, $VNodes)
$before = [string[]]::new($Keys)
$after = [string[]]::new($Keys)
for ($i = 0; $i -lt $Keys; $i++) {
    $before[$i] = $ring10.Owner($hashes[$i])
    $after[$i] = $ring11.Owner($hashes[$i])
}
$moved = [System.Collections.Generic.List[System.ValueTuple[string, string]]]::new()
for ($i = 0; $i -lt $Keys; $i++) {
    if ($before[$i] -cne $after[$i]) {
        $moved.Add([System.ValueTuple[string, string]]::new($before[$i], $after[$i]))
    }
}
[string]::Format($Inv, 'hash ring  moved {0,6:N0} keys ({1})    expect ~9.1% (1 of 11)',
    $moved.Count, (Format-Pct $moved.Count $Keys))
$wentToNew = $true
foreach ($move in $moved) {
    if ($move.Item2 -cne 'node-10') { $wentToNew = $false; break }
}
"Every key that moved on the ring went to node-10: $(if ($wentToNew) { 'yes' } else { 'no' })"

# Python's Counter: a hashtable of counts. $load[$key]++ on a missing key works
# because $null++ gives 1.
$load = @{}
foreach ($owner in $after) { $load[$owner]++ }
# Walk the node list, not $load.Values, so a node that got no keys counts as 0.
# [int]$null is 0, like .get(n, 0).
$counts = foreach ($node in $nodes11) { [int]$load[$node] }
$spread = $counts | Measure-Object -Minimum -Maximum
[string]::Format($Inv, 'Keys per node, 11 nodes x 160 vnodes: min {0:N0}  max {1:N0}  (ideal {2:N0})',
    $spread.Minimum, $spread.Maximum, [Math]::DivRem(2 * $Keys + 11, 22).Item1)

$onePoint = [HashRing]::new($nodes11, 1)
$load1 = @{}
foreach ($h in $hashes) { $load1[$onePoint.Owner($h)]++ }
$counts1 = foreach ($node in $nodes11) { [int]$load1[$node] }
$spread1 = $counts1 | Measure-Object -Minimum -Maximum
[string]::Format($Inv, 'Keys per node, 11 nodes x 1 vnode:    min {0:N0}  max {1:N0}  (why virtual nodes matter)',
    $spread1.Minimum, $spread1.Maximum)
