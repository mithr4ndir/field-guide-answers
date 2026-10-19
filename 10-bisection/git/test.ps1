# Test for git bisect run, PowerShell version:
#   git bisect run pwsh -NoProfile -File ./test.ps1
# Good (exit 0) if max_batch is within the API limit of 437; exit 125 skips a commit.
$line = Select-String -Path ./config.txt -Pattern '^max_batch=(\d+)$'
if (-not $line) { exit 125 }
$batch = [int]$line.Matches[0].Groups[1].Value
if ($batch -le 437) { exit 0 } else { exit 1 }
