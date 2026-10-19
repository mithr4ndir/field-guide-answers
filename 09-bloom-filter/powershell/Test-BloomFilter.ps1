#Requires -Version 7.4

<#
.SYNOPSIS
    Drill 9 (probabilistic structures): a Bloom filter, measured against the formula.

.DESCRIPTION
    Sizes a filter for 100,000 items at a 1% false-positive target, inserts
    100,000 device ids, then asks about 100,000 ids that were never inserted
    and counts how many it wrongly says "probably yes" to.

      m = -n ln(p) / (ln 2)^2   bits
      k = (m / n) ln 2          hash functions
      predicted false-positive rate = (1 - e^(-k n / m))^k

    The k bit positions come from one SHA-256 digest (double hashing):
    h1 = bytes 0-7 and h2 = bytes 8-15, each read as a big-endian unsigned
    64-bit number and reduced mod m, then index_i = (h1 + i * h2) mod m.
    Reducing first keeps the math inside 64 bits in every language.

.NOTES
    PowerShell port of python/bloom.py.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$N = 100000
$P = 0.01
$Inv = [cultureinfo]::InvariantCulture

class BloomFilter {
    [long] $M
    [int] $K
    hidden [byte[]] $Bits

    BloomFilter([int] $N, [double] $P) {
        $this.M = [long][Math]::Ceiling(-$N * [Math]::Log($P) / [Math]::Pow([Math]::Log(2), 2))
        # [Math]::Round rounds half to even unless told otherwise, the same as Python's round().
        $this.K = [int][Math]::Round($this.M / $N * [Math]::Log(2))
        $this.Bits = [byte[]]::new([Math]::DivRem($this.M + 7, 8).Item1)
    }

    hidden [long[]] Positions([string] $Item) {
        $digest = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Item))
        # Read big-endian like Python's int.from_bytes(..., "big"); BitConverter would
        # read little-endian on x64 and ARM. ReadUInt64BigEndian takes a Span, which
        # PowerShell can't create, but it converts a byte[] or an ArraySegment for you.
        $h1 = [System.Buffers.Binary.BinaryPrimitives]::ReadUInt64BigEndian($digest) % [uint64]$this.M
        $h2 = [System.Buffers.Binary.BinaryPrimitives]::ReadUInt64BigEndian([System.ArraySegment[byte]]::new($digest, 8, 8)) % [uint64]$this.M
        if ($h2 -eq 0) {
            $h2 = 1         # a zero step would put all k probes on the same bit
        }
        # Both are now below m, so [long] math is exact. Unreduced, h1 + i * h2 could
        # pass 2^64, and PowerShell doesn't wrap or throw on overflow: it quietly
        # switches to [double] and loses the low digits.
        $h1 = [long]$h1
        $h2 = [long]$h2
        $positions = [long[]]::new($this.K)
        for ($i = 0; $i -lt $this.K; $i++) {
            $positions[$i] = ($h1 + $i * $h2) % $this.M
        }
        return $positions
    }

    [void] Add([string] $Item) {
        foreach ($pos in $this.Positions($Item)) {
            $this.Bits[$pos -shr 3] = $this.Bits[$pos -shr 3] -bor (1 -shl ($pos -band 7))
        }
    }

    [bool] Contains([string] $Item) {
        foreach ($pos in $this.Positions($Item)) {
            if (($this.Bits[$pos -shr 3] -band (1 -shl ($pos -band 7))) -eq 0) {
                return $false
            }
        }
        return $true
    }
}

function Get-PredictedRate([long] $M, [int] $K, [long] $N) {
    [Math]::Pow(1 - [Math]::Exp(-$K * $N / $M), $K)
}

function Format-Rate([long] $Count, [long] $Total) {
    # Percent with three decimals, rounded half up, integers only. [Math]::DivRem is
    # Python's divmod(); PowerShell's / would give a double.
    $thousandths = [Math]::DivRem($Count * 200000 + $Total, 2 * $Total).Item1
    $parts = [Math]::DivRem($thousandths, 1000)
    "$($parts.Item1).$($parts.Item2.ToString('D3', $Inv))%"
}

# Python's {P:.0%} gives "1%". The .NET "P0" format puts a space before the % sign
# in the invariant culture ("1 %"), so build it by hand.
"Drill 9: Bloom filter sized for $($N.ToString('N0', $Inv)) items at $(($P * 100).ToString('F0', $Inv))% false positives."
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$bf = [BloomFilter]::new($N, $P)
[string]::Format($Inv, 'm = {0:N0} bits ({1:N0} KiB), k = {2} hash functions',
    $bf.M, [Math]::DivRem($bf.M, 8 * 1024).Item1, $bf.K)     # bits -> bytes -> KiB

for ($i = 0; $i -lt $N; $i++) {
    $bf.Add("device-$i")
}
$misses = 0
for ($i = 0; $i -lt $N; $i++) {
    if (-not $bf.Contains("device-$i")) { $misses++ }
}
"False negatives on the $($N.ToString('N0', $Inv)) inserted ids: $misses (must be 0)"

$fp = 0
for ($i = 0; $i -lt $N; $i++) {
    if ($bf.Contains("other-$i")) { $fp++ }
}
[string]::Format($Inv, 'False positives on {0:N0} ids never inserted: {1:N0} = {2}   predicted {3:F3}%',
    $N, $fp, (Format-Rate $fp $N), (Get-PredictedRate $bf.M $bf.K $N) * 100)

for ($i = $N; $i -lt 2 * $N; $i++) {        # overfill to twice the design size
    $bf.Add("device-$i")
}
$fp2 = 0
for ($i = 0; $i -lt $N; $i++) {
    if ($bf.Contains("other-$i")) { $fp2++ }
}
[string]::Format($Inv, 'Overfilled to {0:N0} items: {1:N0} = {2}   predicted {3:F3}%',
    2 * $N, $fp2, (Format-Rate $fp2 $N), (Get-PredictedRate $bf.M $bf.K (2 * $N)) * 100)
[string]::Format($Inv, '~ ran in {0:F2} s', $clock.Elapsed.TotalSeconds)
