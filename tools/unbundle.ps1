<#
.SYNOPSIS
  Recreate the windows-selfhost-kit folder from the single-file edition (windows-selfhost-kit.md).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\unbundle.ps1 .\windows-selfhost-kit.md
  Creates .\windows-selfhost-kit\... in the current folder and verifies every file's checksum.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Bundle,
    [Parameter(Position = 1)][string]$OutParent = '.'
)
$ErrorActionPreference = 'Stop'
$lines = [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Bundle).Path)
$parent = (Resolve-Path -LiteralPath $OutParent).Path
$out = Join-Path $parent 'windows-selfhost-kit'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$count = 0

function Write-KitFile([string]$rel, [System.Collections.Generic.List[string]]$buf) {
    if ($rel -match '(^|/)\.\.(/|$)' -or $rel.StartsWith('/') -or $rel -match '^[A-Za-z]:') {
        throw "Unsafe path in bundle: $rel"
    }
    $path = Join-Path $out $rel   # '/' works as a separator on Windows too
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $text = ''
    if ($buf.Count -gt 0) { $text = ($buf -join "`n") + "`n" }
    [IO.File]::WriteAllText($path, $text, $utf8NoBom)
    $script:count++
}

$state = ''
$rel = ''
$fence = ''
$buf = New-Object System.Collections.Generic.List[string]
foreach ($line in $lines) {
    if ($state -eq 'readme') {
        if ($line -eq '<!-- END README -->') { Write-KitFile 'README.md' $buf; $state = '' }
        else { $buf.Add($line) }
        continue
    }
    if ($state -eq 'body') {
        if ($line -eq $fence) { Write-KitFile $rel $buf; $state = '' }
        else { $buf.Add($line) }
        continue
    }
    if ($state -eq 'want_fence') {
        if ($line -match '^(`{3,})') { $fence = $Matches[1]; $buf = New-Object System.Collections.Generic.List[string]; $state = 'body' }
        continue
    }
    if ($line -eq '<!-- BEGIN README -->') { $buf = New-Object System.Collections.Generic.List[string]; $state = 'readme'; continue }
    if ($line -match '^### File: `windows-selfhost-kit/(.+)`$') { $rel = $Matches[1]; $state = 'want_fence'; continue }
}
Write-Host "unbundle: wrote $count files to $out"

# Verify checksums (sha256sum format: "<hash>  <path>").
$inSums = $false; $inFence = $false; $bad = 0; $checked = 0
foreach ($line in $lines) {
    if ($line -match '^## Checksums') { $inSums = $true; continue }
    if (-not $inSums) { continue }
    if ($line -match '^```') { if ($inFence) { break } else { $inFence = $true; continue } }
    if ($inFence -and $line -match '^([0-9a-f]{64})\s+\*?(.+)$') {
        $p = Join-Path $out $Matches[2]
        $want = $Matches[1]
        $have = (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLower()
        $checked++
        if ($have -ne $want) { Write-Host "CHECKSUM MISMATCH: $($Matches[2])" -ForegroundColor Red; $bad++ }
    }
}
if ($bad -gt 0) { Write-Host "unbundle: $bad file(s) differ. Re-download the .md file." -ForegroundColor Red; exit 1 }
Write-Host "unbundle: all $checked checksums OK" -ForegroundColor Green
Write-Host "Next: open $out\README.md and start at Part A."
