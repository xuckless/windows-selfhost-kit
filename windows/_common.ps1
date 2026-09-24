# Shared helpers for setup-windows.ps1 and wsl-run.ps1 (dot-sourced). Windows PowerShell 5.1+.
# Keep this file ASCII-only: PowerShell 5.1 misreads non-ASCII scripts saved without a BOM.

$KitRoot = Split-Path -Parent $PSScriptRoot
$env:WSL_UTF8 = '1'   # make wsl.exe print normal text instead of UTF-16

function Read-KitEnv {
    $result = @{}
    $file = Join-Path $KitRoot 'kit.env'
    if (-not (Test-Path $file)) { return $result }
    foreach ($line in Get-Content -LiteralPath $file) {
        $l = $line.Trim()
        if ($l -eq '' -or $l.StartsWith('#')) { continue }
        $i = $l.IndexOf('=')
        if ($i -gt 0) { $result[$l.Substring(0, $i)] = $l.Substring($i + 1) }
    }
    return $result
}

function Get-KitDistro {
    param([string]$Distro)
    if ($Distro) { return $Distro }
    $kit = Read-KitEnv
    if ($kit['DISTRO']) { return $kit['DISTRO'] }
    return 'Ubuntu-24.04'
}

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Pass([string]$msg) { Write-Host "[PASS] $msg" -ForegroundColor Green }
function Write-Warn2([string]$msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Fail([string]$msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red }
function Write-Next([string]$msg) { Write-Host "NEXT: $msg" -ForegroundColor Yellow }

function Test-IsAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Returns @{ Name = ...; Version = 1|2; State = ... } for each installed distro.
function Get-WslDistros {
    $ErrorActionPreference = 'Continue'   # PS 5.1: redirected native stderr must not throw
    $list = @()
    $out = & wsl.exe -l -v 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $list }
    foreach ($line in ($out | Select-Object -Skip 1)) {
        $t = ($line -replace '\x00', '').Trim().TrimStart('*').Trim()
        if (-not $t) { continue }
        $parts = $t -split '\s+'
        if ($parts.Count -ge 3) {
            $list += [pscustomobject]@{ Name = $parts[0]; State = $parts[1]; Version = [int]$parts[2] }
        }
    }
    return $list
}

# Runs a bash script inside WSL2 and returns its exit code. The script travels
# base64-encoded as a single argument, so PowerShell/wsl.exe quoting can't break it.
# $KIT_USER (your Linux user) and $KIT (its ~/selfhost-kit) are available in the script.
function Invoke-WslBash {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [string]$Distro,
        [switch]$Root
    )
    $ErrorActionPreference = 'Continue'
    $Distro = Get-KitDistro $Distro
    $user = (& wsl.exe -d $Distro --exec whoami 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $user) {
        throw "Could not start WSL distro '$Distro'. Is it installed? (wsl -l -v)"
    }
    $prefix = "export KIT_USER='$user'; export KIT=`"`$(getent passwd '$user' | cut -d: -f6)/selfhost-kit`"`n"
    $full = ($prefix + $Script) -replace "`r", ''
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($full))
    $runner = 'f=$(mktemp); printf %s $1 | base64 -d > $f; bash -l $f; rc=$?; rm -f $f; exit $rc'
    $wslArgs = @('-d', $Distro)
    if ($Root) { $wslArgs += @('-u', 'root') }
    $wslArgs += @('--exec', 'bash', '-c', $runner, 'wsl-run', $b64)
    & wsl.exe @wslArgs | Out-Host
    return $LASTEXITCODE
}
