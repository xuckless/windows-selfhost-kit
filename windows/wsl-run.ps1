<#
.SYNOPSIS
  Run a bash command inside WSL2 from Windows PowerShell, safely (for AI agents and humans).

.DESCRIPTION
  Quoting commands for "wsl -- bash -c ..." from PowerShell is error-prone. This script
  sends the command base64-encoded, so what you write is exactly what bash runs.
  Inside the command you can use:
    $KIT_USER  your Linux user name
    $KIT       your kit folder in Linux (/home/<user>/selfhost-kit)
  Use single quotes in PowerShell so that $ signs reach bash unchanged.

.EXAMPLE
  .\windows\wsl-run.ps1 'docker ps'
.EXAMPLE
  .\windows\wsl-run.ps1 -Root '$KIT/wsl/bootstrap.sh --user $KIT_USER'
.EXAMPLE
  .\windows\wsl-run.ps1 'cd ~/apps/myrepo && scripts/status.sh'
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Command,
    [switch]$Root,
    [string]$Distro
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')
$code = Invoke-WslBash -Script $Command -Distro $Distro -Root:$Root
exit $code
