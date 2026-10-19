#Requires -Version 7.4
<#
.SYNOPSIS
    Drill 8 (distributed systems): watch writes through leader loss and quorum loss.

.DESCRIPTION
    Writes lab/counter = 1, 2, 3 ... every 250 ms through etcd's HTTP/JSON gateway
    (no client library needed) and prints one line per write: which node took it,
    how long it took, and the Raft term. Kill nodes while it runs (see LAB.md):

      kill the leader   a short burst of slow or failed writes, then writes resume
                        under a new Raft term (usually one higher; a split vote adds more)
      kill two nodes    every write fails: one node of three is not a majority.
                        Serializable reads still answer from local, possibly stale, data.
      start one again   quorum is back and writes resume

.EXAMPLE
    ./Watch-EtcdWrites.ps1
    ./Watch-EtcdWrites.ps1 -Endpoint localhost:2379,localhost:22379 -Count 100
#>
[CmdletBinding()]
param(
    [string[]]$Endpoint = @('localhost:2379', 'localhost:22379', 'localhost:32379'),
    [int]$Count = 0,                 # 0 = until Ctrl+C
    [double]$IntervalSeconds = 0.25,
    [double]$TimeoutSeconds = 1.0
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$key = 'lab/counter'
# `pwsh -File script.ps1 -Endpoint a,b` passes "a,b" as one string (no array parsing
# with -File), so split on commas to accept both forms.
$Endpoint = @($Endpoint -split ',' | Where-Object { $_ })
# One HttpClient for the whole run. Invoke-RestMethod only takes whole-second timeouts
# and builds a new client per call, which adds latency to every write.
$http = [System.Net.Http.HttpClient]::new()
$http.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

function ConvertTo-Base64([string]$Text) {
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function Invoke-Etcd([string]$Node, [string]$Path, [hashtable]$Body) {
    $content = [System.Net.Http.StringContent]::new(($Body | ConvertTo-Json -Compress),
        [Text.Encoding]::UTF8, 'application/json')
    $response = $http.PostAsync("http://$Node$Path", $content).GetAwaiter().GetResult()
    $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
        $message = try { ($text | ConvertFrom-Json).message } catch { "HTTP $([int]$response.StatusCode)" }
        throw [System.Exception]::new($message)
    }
    $text | ConvertFrom-Json
}

function Get-Reason([System.Exception]$Exception) {
    # Calling a .NET method from PowerShell wraps whatever it throws in a
    # MethodInvocationException. Unwrap it to see the real error.
    while ($Exception -is [System.Management.Automation.MethodInvocationException] -and $Exception.InnerException) {
        $Exception = $Exception.InnerException
    }
    if ($Exception -is [System.Threading.Tasks.TaskCanceledException]) { return 'timed out' }
    $text = $Exception.Message
    if ($Exception.InnerException) { $text += ' ' + $Exception.InnerException.Message }
    if ($text -match 'refused') { return 'connection refused' }
    return $Exception.Message
}

function Get-Stamp { (Get-Date).ToString('HH:mm:ss.fff') }

$i = 0
try {
    while ($Count -eq 0 -or $i -lt $Count) {
        $i++
        $tick = [System.Diagnostics.Stopwatch]::StartNew()
        $errors = [System.Collections.Generic.List[string]]::new()
        $written = $false
        foreach ($node in $Endpoint) {                 # fail over in order
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $header = (Invoke-Etcd $node '/v3/kv/put' @{ key = ConvertTo-Base64 $key; value = ConvertTo-Base64 "$i" }).header
                $ms = $watch.Elapsed.TotalMilliseconds
                '{0}  put {1}={2,-4} OK    via {3,-15} {4,5:F0} ms  term {5}  rev {6}' -f (Get-Stamp), $key, $i, $node, $ms, $header.raft_term, $header.revision
                $written = $true
                break
            } catch {
                $errors.Add("$node $(Get-Reason $_.Exception)")
            }
        }
        if (-not $written) {
            '{0}  put {1}={2,-4} FAIL  {3}' -f (Get-Stamp), $key, $i, ($errors -join '; ')
            # No quorum means no writes, but a serializable read is answered from local data.
            foreach ($node in $Endpoint) {
                try {
                    $result = Invoke-Etcd $node '/v3/kv/range' @{ key = ConvertTo-Base64 $key; serializable = $true }
                    $value = if ($result.PSObject.Properties['kvs']) {
                        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($result.kvs[0].value))
                    } else { '(none)' }
                    '{0}  serializable read from {1}: {2}={3} (may be stale)' -f (' ' * 12), $node, $key, $value
                    break
                } catch { continue }
            }
        }
        $remaining = $IntervalSeconds - $tick.Elapsed.TotalSeconds
        if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int]($remaining * 1000)) }
    }
} finally {
    $http.Dispose()
}
