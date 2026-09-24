<#
.SYNOPSIS
  Windows side of windows-selfhost-kit: WSL2, copying the kit into Ubuntu, auto-start.

.DESCRIPTION
  Run the phases in this order (README Part A):
    Check      read-only checks: Windows version, virtualization, WSL2, distro, disk, git, kit.env
    Install    install/update WSL and make WSL2 the default (asks for admin rights: UAC)
    Stage      copy this kit folder into Ubuntu as ~/selfhost-kit (run again after editing kit.env)
    Configure  keep WSL2 running, start everything at logon, Desktop shortcuts (asks for admin once)
    Uninstall  remove what Configure added
  A log of every run is written to C:\ProgramData\selfhost-kit\setup-<Phase>.log

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\setup-windows.ps1 -Phase Check
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\setup-windows.ps1 -Phase Configure -UseStartupFolder
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Check', 'Install', 'Stage', 'Configure', 'Uninstall', 'RegisterTask', 'UnregisterTask')]
    [string]$Phase,
    [string]$Distro,
    [switch]$UseStartupFolder,   # Configure: auto-start via the Startup folder (no admin needed)
    [string]$ForUser             # internal: user account for RegisterTask
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')
$Distro = Get-KitDistro $Distro
$TaskName = "SelfHostKit-WSL-$Distro"
$LogDir = Join-Path $env:ProgramData 'selfhost-kit'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir "setup-$Phase.log"
try { Start-Transcript -Path $LogFile -Force | Out-Null } catch { $null = $_ }   # a log is nice-to-have only

# The command the logon task / startup shortcut runs (hidden window).
$AutoStartArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"& wsl.exe -d '$Distro' --exec bash -lc '~/selfhost-kit/wsl/selfhost.sh autostart'`""

function Invoke-Elevated([string]$PhaseName, [string]$Extra = '') {
    Write-Step "Windows will ask for administrator rights: click 'Yes' in the prompt."
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Phase $PhaseName -Distro `"$Distro`" $Extra"
    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -Verb RunAs -Wait -PassThru
    } catch {
        Write-Fail "Administrator rights were not granted ($($_.Exception.Message))."
        return 1
    }
    $childLog = Join-Path $LogDir "setup-$PhaseName.log"
    if (Test-Path $childLog) {
        Write-Host "---- output of the admin window ($childLog) ----"
        Get-Content $childLog | Where-Object { $_ -notmatch '^\*{10}|^(Start|End) time|^Username|^RunAs User|^Configuration Name|^Machine|^Host Application|^Process ID|^PS(Version|Edition|Compatible|RemotingProtocol)|^BuildVersion|^CLRVersion|^WSManStack|^SerializationVersion|^Transcript started' } | Out-Host
        Write-Host "---- end ----"
    }
    return $p.ExitCode
}

function Set-IniValue([string]$Path, [string]$Section, [string]$Key, [string]$Value) {
    $lines = @()
    if (Test-Path $Path) { $lines = @(Get-Content -LiteralPath $Path) }
    $out = New-Object System.Collections.Generic.List[string]
    $inSec = $false; $done = $false
    foreach ($l in $lines) {
        if ($l -match '^\s*\[(.+)\]\s*$') {
            if ($inSec -and -not $done) { $out.Add("$Key=$Value"); $done = $true }
            $inSec = ($Matches[1].Trim() -ieq $Section)
            $out.Add($l); continue
        }
        if ($inSec -and $l -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) {
            if (-not $done) { $out.Add("$Key=$Value"); $done = $true }
            continue
        }
        $out.Add($l)
    }
    if (-not $done) {
        if (-not $inSec) { if ($out.Count -gt 0) { $out.Add('') }; $out.Add("[$Section]") }
        $out.Add("$Key=$Value")
    }
    [IO.File]::WriteAllLines($Path, $out)
}

function New-Shortcut([string]$Path, [string]$Target, [string]$Arguments, [int]$WindowStyle = 1) {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath = $Target
    $lnk.Arguments = $Arguments
    $lnk.WindowStyle = $WindowStyle
    $lnk.WorkingDirectory = $env:USERPROFILE
    $lnk.Save()
}

# ------------------------------------------------------------------------------------------
function Invoke-Check {
    $ErrorActionPreference = 'Continue'
    $fails = 0
    $build = [Environment]::OSVersion.Version.Build
    if ($build -ge 19045) { Write-Pass "Windows build $build" }
    elseif ($build -ge 19041) { Write-Warn2 "Windows build $build works, but Windows 11 or Windows 10 22H2 (19045) is recommended." }
    else { Write-Fail "Windows build $build is too old for WSL2 ('wsl --install' needs 19041+). Run Windows Update."; $fails++ }

    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    if ($cs.HypervisorPresent -or $cpu.VirtualizationFirmwareEnabled) { Write-Pass 'CPU virtualization is enabled' }
    else { Write-Fail 'CPU virtualization is OFF. Turn on Intel VT-x / AMD SVM (AMD-V) in the BIOS/UEFI setup, then run Check again.'; $fails++ }

    $freeGb = [math]::Round((Get-PSDrive -Name C).Free / 1GB)
    if ($freeGb -ge 20) { Write-Pass "Free disk space on C: $freeGb GB" }
    else { Write-Warn2 "Only $freeGb GB free on C:. 20 GB or more is recommended (Docker images, Maven cache)." }

    $v = & wsl.exe --version 2>$null
    if ($LASTEXITCODE -eq 0 -and $v) { Write-Pass ("WSL is installed: " + (($v | Select-Object -First 1) -replace '\x00', '').Trim()) }
    else { Write-Warn2 'WSL is not installed yet (or is an old version). Next: -Phase Install' }

    $d = Get-WslDistros | Where-Object { $_.Name -eq $Distro }
    if ($d) {
        if ($d.Version -eq 2) { Write-Pass "$Distro is installed and uses WSL2" }
        else { Write-Fail "$Distro uses WSL1. Fix: wsl --set-version $Distro 2   (or run -Phase Install)"; $fails++ }
    } else { Write-Warn2 "$Distro is not installed yet (README Part A, step A3)." }

    if (Get-Command git -ErrorAction SilentlyContinue) { Write-Pass 'Git for Windows is installed' }
    else { Write-Warn2 'Git for Windows not found. Install it: winget install --id Git.Git -e   (then open a new PowerShell)' }

    if (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue) {
        Write-Warn2 "Docker Desktop is running. This kit uses Docker Engine inside WSL2; turn off Docker Desktop's WSL integration for $Distro (or quit Docker Desktop)."
    }

    $kitEnv = Join-Path $KitRoot 'kit.env'
    if (-not (Test-Path $kitEnv)) { Write-Warn2 "kit.env not found. Copy kit.env.example to kit.env and fill it in: notepad `"$kitEnv`"" }
    elseif (Select-String -LiteralPath $kitEnv -Pattern '=your-|\\you\\' -Quiet) { Write-Warn2 'kit.env still has example values (your-... or \you\). Fill them in.' }
    else { Write-Pass 'kit.env is filled in' }

    if ($fails -gt 0) { Write-Fail "$fails problem(s) must be fixed first."; return 1 }
    Write-Next 'powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\setup-windows.ps1 -Phase Install'
    return 0
}

function Invoke-Install {
    if (-not (Test-IsAdmin)) { return (Invoke-Elevated 'Install') }
    $ErrorActionPreference = 'Continue'
    Write-Step 'Installing / updating WSL (this can take a few minutes)'
    & wsl.exe --install --no-distribution | Out-Host
    & wsl.exe --update | Out-Host
    & wsl.exe --set-default-version 2 | Out-Host
    $d = Get-WslDistros | Where-Object { $_.Name -eq $Distro }
    if ($d -and $d.Version -ne 2) {
        Write-Step "Converting $Distro to WSL2"
        & wsl.exe --set-version $Distro 2 | Out-Host
    }
    $reboot = $false
    foreach ($f in 'VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux') {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue).State
        Write-Host "  Windows feature $f : $state"
        if ("$state" -like '*Pending*') { $reboot = $true }
    }
    if ($reboot) {
        Write-Warn2 'REBOOT REQUIRED. Restart Windows, then run -Phase Install once more (it is safe to repeat).'
        return 0
    }
    Write-Pass 'WSL2 is installed and is the default version.'
    if (-not $d) {
        Write-Next "[HUMAN] In a normal (not admin) PowerShell window run:  wsl --install -d $Distro"
        Write-Host  '      A Ubuntu window opens and asks for a NEW Linux username and password.'
        Write-Host  '      Use lowercase letters for the name. Remember the password (it is your "sudo" password).'
    } else {
        Write-Next 'powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\setup-windows.ps1 -Phase Stage'
    }
    return 0
}

function Invoke-Stage {
    if (-not (Test-Path (Join-Path $KitRoot 'kit.env'))) {
        Write-Fail "kit.env not found. Copy kit.env.example to kit.env in $KitRoot and fill it in first."
        return 1
    }
    $d = Get-WslDistros | Where-Object { $_.Name -eq $Distro }
    if (-not $d) { Write-Fail "$Distro is not installed (README Part A, step A3)."; return 1 }
    if ($d.Version -ne 2) { Write-Fail "$Distro uses WSL1. Run: wsl --set-version $Distro 2"; return 1 }
    Write-Step "Copying the kit into $Distro as ~/selfhost-kit"
    $src = $KitRoot -replace "'", "'\''"
    $script = @'
set -euo pipefail
src="$(wslpath -a '__SRC__')"
dst="$HOME/selfhost-kit"
rm -rf "$dst.new"
cp -r "$src" "$dst.new"
# Remove Windows line endings from every text file (not inside .git), make scripts executable.
find "$dst.new" -type f ! -path '*/.git/*' -print0 | xargs -0 grep -IlZ $'\r' 2>/dev/null | xargs -0 -r sed -i 's/\r$//'
find "$dst.new" -type f -name '*.sh' -exec chmod +x {} +
rm -rf "$dst.old"
if [ -d "$dst" ]; then mv "$dst" "$dst.old"; fi
mv "$dst.new" "$dst"
rm -rf "$dst.old"
echo "Kit copied to $dst"
source "$dst/wsl/lib.sh"
load_kit_env && validate_kit_env && pass "kit.env: SERVICE_NAME=$SERVICE_NAME REPO=$GITHUB_OWNER/$REPO"
'@
    $script = $script.Replace('__SRC__', $src)
    $code = Invoke-WslBash -Script $script -Distro $Distro
    if ($code -ne 0) { Write-Fail "Stage failed (exit $code)."; return $code }
    Write-Pass 'Kit staged.'
    Write-Next "[AGENT] .\windows\wsl-run.ps1 -Root '`$KIT/wsl/bootstrap.sh --user `$KIT_USER'"
    return 0
}

function Invoke-Configure {
    $ErrorActionPreference = 'Continue'
    # 1. Keep WSL2 running when no terminal is open.
    $cfg = Join-Path $env:USERPROFILE '.wslconfig'
    if (Test-Path $cfg) { Copy-Item $cfg ("$cfg.bak-" + (Get-Date -Format 'yyyyMMddHHmmss')) }
    Set-IniValue $cfg 'wsl2' 'vmIdleTimeout' '-1'
    Set-IniValue $cfg 'general' 'instanceIdleTimeout' '-1'
    Write-Pass "Updated $cfg (WSL2 keeps running when no window is open)"

    # 2. Desktop shortcuts.
    $desktop = [Environment]::GetFolderPath('Desktop')
    $wsl = Join-Path $env:WINDIR 'System32\wsl.exe'
    $pause = "echo; read -rp 'Press Enter to close this window '"
    New-Shortcut (Join-Path $desktop 'Start SelfHost.lnk') $wsl "-d $Distro --exec bash -lc `"~/selfhost-kit/wsl/selfhost.sh up; $pause`""
    New-Shortcut (Join-Path $desktop 'SelfHost Status.lnk') $wsl "-d $Distro --exec bash -lc `"~/selfhost-kit/wsl/selfhost.sh status; ~/selfhost-kit/wsl/doctor.sh; $pause`""
    New-Shortcut (Join-Path $desktop 'Stop SelfHost.lnk') $wsl "-d $Distro --exec bash -lc `"~/selfhost-kit/wsl/selfhost.sh down; $pause`""
    Write-Pass "Desktop shortcuts: 'Start SelfHost', 'SelfHost Status', 'Stop SelfHost'"

    # 3. Start everything when you log in to Windows.
    $startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'SelfHost autostart.lnk'
    $useStartup = [bool]$UseStartupFolder
    if (-not $useStartup) {
        $me = "$env:USERDOMAIN\$env:USERNAME"
        $code = Invoke-Elevated 'RegisterTask' "-ForUser `"$me`""
        if ($code -ne 0) {
            Write-Warn2 'Could not create the logon task; using the Startup folder instead.'
            $useStartup = $true
        } elseif (Test-Path $startupLnk) {
            Remove-Item $startupLnk -Force
        }
    }
    if ($useStartup) {
        New-Shortcut $startupLnk (Join-Path $PSHOME 'powershell.exe') $AutoStartArgs 7
        Write-Pass "Auto-start at logon via the Startup folder ($startupLnk)"
    }
    Write-Next '[AGENT] wsl --shutdown   (applies .wslconfig; everything starts again with the next WSL command or logon)'
    return 0
}

function Invoke-RegisterTask {
    if (-not (Test-IsAdmin)) { Write-Fail 'RegisterTask must run as administrator.'; return 1 }
    if (-not $ForUser) { Write-Fail 'RegisterTask needs -ForUser DOMAIN\user'; return 1 }
    $action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument $AutoStartArgs
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $ForUser
    $trigger.Delay = 'PT20S'
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $ForUser -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description 'windows-selfhost-kit: start WSL2 stacks at logon' -Force | Out-Null
    Write-Pass "Logon task '$TaskName' created for $ForUser (runs 20 s after you log in, also on battery)."
    return 0
}

function Invoke-Uninstall {
    $ErrorActionPreference = 'Continue'
    $desktop = [Environment]::GetFolderPath('Desktop')
    foreach ($n in 'Start SelfHost.lnk', 'SelfHost Status.lnk', 'Stop SelfHost.lnk') {
        $p = Join-Path $desktop $n
        if (Test-Path $p) { Remove-Item $p -Force; Write-Pass "Removed $p" }
    }
    $startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'SelfHost autostart.lnk'
    if (Test-Path $startupLnk) { Remove-Item $startupLnk -Force; Write-Pass "Removed $startupLnk" }
    $cfg = Join-Path $env:USERPROFILE '.wslconfig'
    if (Test-Path $cfg) {
        $kept = Get-Content -LiteralPath $cfg | Where-Object { $_ -notmatch '^\s*(vmIdleTimeout|instanceIdleTimeout)\s*=\s*-1\s*$' }
        [IO.File]::WriteAllLines($cfg, [string[]]$kept)
        Write-Pass "Removed the idle-timeout settings from $cfg"
    }
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        $null = Invoke-Elevated 'UnregisterTask'
    }
    Write-Host 'Your Ubuntu distro, containers and data were NOT touched (README Part J).'
    return 0
}

function Invoke-UnregisterTask {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Pass "Removed logon task '$TaskName'"
    return 0
}

# ------------------------------------------------------------------------------------------
$rc = 1
try {
    switch ($Phase) {
        'Check'          { $rc = Invoke-Check }
        'Install'        { $rc = Invoke-Install }
        'Stage'          { $rc = Invoke-Stage }
        'Configure'      { $rc = Invoke-Configure }
        'Uninstall'      { $rc = Invoke-Uninstall }
        'RegisterTask'   { $rc = Invoke-RegisterTask }
        'UnregisterTask' { $rc = Invoke-UnregisterTask }
    }
} catch {
    Write-Fail $_.Exception.Message
    $rc = 1
} finally {
    try { Stop-Transcript | Out-Null } catch { $null = $_ }
}
exit ([int]($rc | Select-Object -Last 1))
