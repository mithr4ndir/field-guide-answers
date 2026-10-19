#Requires -Version 7.4

<#
.SYNOPSIS
    Drill 11 (joins): Jamf vs. Okta Verify drift report, with dirty keys.

.DESCRIPTION
    Reads data/jamf_computers.csv and data/okta_devices.json and answers:
    which Macs are missing from Okta Verify (anti-join), which Okta devices
    aren't in Jamf, and how dirty keys and duplicates would have fooled you.

    Steps that matter more than the join algorithm:
      1. Normalize the key on both sides: trim whitespace, uppercase.
      2. Treat blank serials as invalid, not as a key that matches other blanks.
      3. Check key uniqueness before joining: duplicates multiply join rows.
      4. Then a hash join (HashSet lookups) does the actual work in O(n + m).

    Also times a nested-loop version for comparison and writes drift_report.csv.

.NOTES
    PowerShell port of python/drift_report.py.

    PowerShell compares strings without case by default: -eq, -contains, -in,
    Group-Object, @{} and [ordered]@{} all treat 'c02abc' and 'C02ABC' as one
    key. Here that hides the lowercase serials: a raw join built on @{} or -notin
    reports 341 missing instead of 447, so 106 of the 172 false alarms vanish and
    the export looks much cleaner than it is. So every key below goes through a
    case-sensitive .NET collection (HashSet, Dictionary with an ordinal comparer)
    or the case-sensitive -ceq.

    The nested loop is the classic foreach + Where-Object: about 35 million
    scriptblock calls, so it takes a minute or two. That's the point.
#>

using namespace System.Collections.Generic

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot        # the 11-joins folder
$Data = Join-Path $Root 'data'
$Inv = [cultureinfo]::InvariantCulture

function ConvertTo-SerialKey {
    <#
    .SYNOPSIS
        Python's norm(): (serial or "").strip().upper().
    .NOTES
        A [string] parameter turns $null into '' (handy here: a JSON null serial
        becomes blank). ToUpperInvariant, not ToUpper: under a Turkish culture
        'i'.ToUpper() is a dotted capital I, which would split one key in two.
    #>
    param([string] $Serial)
    $Serial.Trim().ToUpperInvariant()
}

function Get-KeyCount {
    <#
    .SYNOPSIS
        Python's Counter over the non-blank keys.
    #>
    param([string[]] $Keys)
    $counts = [Dictionary[string, int]]::new([StringComparer]::Ordinal)
    foreach ($k in $Keys) {
        if ($k -ne '') {
            $counts[$k]++               # a missing key reads as $null, and $null + 1 is 1
        }
    }
    $counts                             # dictionaries aren't unrolled, so no comma needed
}

function ConvertTo-CsvField {
    <#
    .SYNOPSIS
        Python csv's QUOTE_MINIMAL: quote a field only if it holds a comma, a quote
        or a line break, doubling any quotes inside. Nothing in this data needs it.
    #>
    param([string] $Value)
    if ($Value.IndexOfAny([char[]]@(',', '"', "`r", "`n")) -ge 0) {
        return '"' + $Value.Replace('"', '""') + '"'
    }
    $Value
}

# Import-Csv: one object per row, every field a string (a blank field is '').
$jamf = Import-Csv -LiteralPath (Join-Path $Data 'jamf_computers.csv')
# ConvertFrom-Json: a JSON null stays $null.
$okta = Get-Content -LiteralPath (Join-Path $Data 'okta_devices.json') -Raw | ConvertFrom-Json
'Drill 11: Jamf vs. Okta Verify drift report.'
[string]::Format($Inv, 'Rows: Jamf {0:N0}, Okta {1:N0}', $jamf.Count, $okta.Count)

[string[]] $jamfKeys = foreach ($row in $jamf) { ConvertTo-SerialKey $row.serial }
[string[]] $oktaKeys = foreach ($row in $okta) { ConvertTo-SerialKey $row.serialNumber }
# With an array on the left, comparison operators filter: ($keys -ceq '') is the blank keys.
"Blank serials skipped: Jamf $(($jamfKeys -ceq '').Count), Okta $(($oktaKeys -ceq '').Count)"

$jamfCount = Get-KeyCount $jamfKeys
$oktaCount = Get-KeyCount $oktaKeys
$jamfDups = @($jamfCount.Values | Where-Object { $_ -gt 1 }).Count
$oktaDups = @($oktaCount.Values | Where-Object { $_ -gt 1 }).Count
"Serials listed more than once (after normalizing): Jamf $jamfDups, Okta $oktaDups"

# Hash join on distinct normalized keys: build the index once, probe it once.
# Python's & and - make new sets; IntersectWith/ExceptWith change the set in place,
# so start each one from a copy.
$jamfSet = [HashSet[string]]::new($jamfCount.Keys, [StringComparer]::Ordinal)
$oktaSet = [HashSet[string]]::new($oktaCount.Keys, [StringComparer]::Ordinal)
$both = [HashSet[string]]::new($jamfSet, [StringComparer]::Ordinal)
$both.IntersectWith($oktaSet)
$jamfOnly = [HashSet[string]]::new($jamfSet, [StringComparer]::Ordinal)
$jamfOnly.ExceptWith($oktaSet)
$oktaOnly = [HashSet[string]]::new($oktaSet, [StringComparer]::Ordinal)
$oktaOnly.ExceptWith($jamfSet)
[string]::Format($Inv, 'Devices in both: {0:N0}', $both.Count)
[string]::Format($Inv, 'In Jamf, missing from Okta Verify: {0:N0}', $jamfOnly.Count)
[string]::Format($Inv, 'In Okta, not in Jamf: {0:N0}', $oktaOnly.Count)

# What a join on raw, unnormalized serials would have claimed. A non-empty string
# is truthy and '' or $null is not, the same as Python.
$oktaRaw = [HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($row in $okta) {
    if ($row.serialNumber) { $null = $oktaRaw.Add($row.serialNumber) }
}
$rawMissing = [HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($row in $jamf) {
    if ($row.serial -and -not $oktaRaw.Contains($row.serial)) { $null = $rawMissing.Add($row.serial) }
}
[string]::Format($Inv, 'Joining on raw serials would report {0:N0} missing: {1} false alarms from case and whitespace',
    $rawMissing.Count, $rawMissing.Count - $jamfOnly.Count)

$joinRows = 0
foreach ($k in $both) {
    $joinRows += $jamfCount[$k] * $oktaCount[$k]
}
[string]::Format($Inv, 'A plain inner join returns {0:N0} rows for {1:N0} devices (+{2} from duplicate keys)',
    $joinRows, $both.Count, $joinRows - $both.Count)

# The same anti-join as a nested loop, for timing only: the classic foreach +
# Where-Object, scanning every Okta key for every Jamf key.
[string[]] $oktaList = $oktaKeys -cne ''
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$nestedMissing = [HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($k in $jamfSet) {
    # -ceq, because -eq ignores case. Even -ceq compares with culture rules, so it
    # calls 'ab' and 'a<soft hyphen>b' equal; the ordinal HashSet does not.
    if (-not ($oktaList | Where-Object { $_ -ceq $k })) {
        $null = $nestedMissing.Add($k)
    }
}
$tNested = $clock.Elapsed.TotalSeconds
$clock.Restart()
$index = [HashSet[string]]::new($oktaList, [StringComparer]::Ordinal)
$hashMissing = [HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($k in $jamfSet) {
    if (-not $index.Contains($k)) { $null = $hashMissing.Add($k) }
}
$tHash = $clock.Elapsed.TotalSeconds
if (-not ($nestedMissing.SetEquals($hashMissing) -and $hashMissing.SetEquals($jamfOnly))) {
    throw 'The nested loop, the hash join and the set difference must agree.'
}

# First row seen for each key, in file order. TryAdd does nothing if the key is
# already there: Python's setdefault.
$firstJamf = [Dictionary[string, string]]::new([StringComparer]::Ordinal)
for ($i = 0; $i -lt $jamf.Count; $i++) {
    $null = $firstJamf.TryAdd($jamfKeys[$i], $jamf[$i].computer_name)
}
$firstOkta = [Dictionary[string, string]]::new([StringComparer]::Ordinal)
for ($i = 0; $i -lt $okta.Count; $i++) {
    $null = $firstOkta.TryAdd($oktaKeys[$i], $okta[$i].id)
}

$allKeys = [HashSet[string]]::new($jamfSet, [StringComparer]::Ordinal)
$allKeys.UnionWith($oktaSet)
$sortedKeys = [string[]]::new($allKeys.Count)
$allKeys.CopyTo($sortedKeys)
# Ordinal, like Python's sorted(). Sort-Object would use culture rules and ignore case.
[Array]::Sort($sortedKeys, [StringComparer]::Ordinal)

$lines = [List[string]]::new($sortedKeys.Count + 1)
$lines.Add('serial,status,jamf_computer_name,okta_device_id')
foreach ($k in $sortedKeys) {
    $status = if ($both.Contains($k)) { 'both' } elseif ($jamfOnly.Contains($k)) { 'jamf_only' } else { 'okta_only' }
    # A missing key reads as $null, and [string]$null is '': Python's .get(k, "").
    $fields = $k, $status, [string]$firstJamf[$k], [string]$firstOkta[$k]
    $lines.Add(($fields | ForEach-Object { ConvertTo-CsvField $_ }) -join ',')
}
# Not Export-Csv: it quotes every field by default and ends lines with the platform
# newline (CRLF on Windows). Byte-identical output needs LF endings, a final newline
# and UTF-8 without a BOM, so write the text directly. Give .NET a full path: it
# resolves relative paths against the process directory, not PowerShell's $PWD.
$out = Join-Path $Root 'drift_report.csv'
[System.IO.File]::WriteAllText($out, ($lines -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
[string]::Format($Inv, 'Wrote drift_report.csv ({0:N0} rows)', $allKeys.Count)
[string]::Format($Inv, '~ anti-join timing: nested loop {0:F3} s, hash {1:F2} ms ({2:N0}x faster)',
    $tNested, $tHash * 1000, $tNested / $tHash)
