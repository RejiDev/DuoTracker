@echo off
title Update Duo Tracker
set "DUO_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s = Get-Content -Raw -LiteralPath $env:DUO_SELF; $i = $s.IndexOf('#POWERSHELL#' + [char]13); if ($i -lt 0) { $i = $s.IndexOf('#POWERSHELL#' + [char]10) }; Invoke-Expression $s.Substring($i + 12)"
echo.
pause
exit /b
#POWERSHELL#
# Installs or updates the Duo Tracker addon for WoW Forever, and sets up a
# background check so later updates arrive without running this again.
# Run by hand it talks to you; run by the background task (DUO_SILENT=1) it is quiet.
$ErrorActionPreference = 'Stop'
$Silent = $env:DUO_SILENT -eq '1'
$repo = 'RejiDev/DuoTracker'
$taskName = 'Duo Tracker Updater'
$cfgDir = Join-Path $env:LOCALAPPDATA 'DuoTracker'
$saved = Join-Path $cfgDir 'addons-path.txt'
$ps1 = Join-Path $cfgDir 'updater.ps1'
$vbs = Join-Path $cfgDir 'run-hidden.vbs'
$log = Join-Path $cfgDir 'last-check.txt'
$marker = '#POWER' + 'SHELL#'

function Say($text, $color) {
    if ($Silent) { return }
    if ($color) { Write-Host $text -ForegroundColor $color } else { Write-Host $text }
}

function Get-AddOnsFromRoot($root) {
    if (-not $root) { return $null }
    foreach ($flavour in '_forever_', '_classic_beta_') {
        $game = Join-Path $root $flavour
        if (Test-Path -LiteralPath $game) { return (Join-Path $game 'Interface\AddOns') }
    }
    return $null
}

function Find-AddOns {
    if (Test-Path -LiteralPath $saved) {
        $p = (Get-Content -LiteralPath $saved -TotalCount 1).Trim()
        if ($p -and (Test-Path -LiteralPath (Split-Path -Parent $p))) { return $p }
    }
    $roots = @()
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft', 'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft') {
        $reg = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($reg -and $reg.InstallPath) {
            $path = $reg.InstallPath.TrimEnd('\')
            $roots += $path
            $roots += (Split-Path -Parent $path)
        }
    }
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem)) {
        $d = $drive.Root
        $roots += (Join-Path $d 'Program Files (x86)\World of Warcraft')
        $roots += (Join-Path $d 'Program Files\World of Warcraft')
        $roots += (Join-Path $d 'World of Warcraft')
        $roots += (Join-Path $d 'Games\World of Warcraft')
        $roots += (Join-Path $d 'Blizzard\World of Warcraft')
    }
    foreach ($root in $roots) {
        $found = Get-AddOnsFromRoot $root
        if ($found) { return $found }
    }
    return $null
}

function Ask-AddOns {
    Write-Host "Couldn't find WoW Forever automatically. A window will open: choose your 'World of Warcraft' folder."
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Choose your World of Warcraft folder (the one that contains _forever_)"
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    $chosen = $dialog.SelectedPath
    if ((Split-Path -Leaf $chosen) -eq 'AddOns') { return $chosen }
    if ((Split-Path -Leaf $chosen) -in '_forever_', '_classic_beta_') { return (Join-Path $chosen 'Interface\AddOns') }
    return (Get-AddOnsFromRoot $chosen)
}

function Get-TocVersion($text) {
    if ($text -match '(?m)^## Version:\s*(\S+)') { return $Matches[1] }
    return $null
}

# Saves the script part of an updater .bat as the background updater.
function Save-BackgroundScript($batPath) {
    if (-not ($batPath -and (Test-Path -LiteralPath $batPath))) { return $false }
    $text = Get-Content -Raw -LiteralPath $batPath
    $i = $text.IndexOf($marker + [char]13)
    if ($i -lt 0) { $i = $text.IndexOf($marker + [char]10) }
    if ($i -lt 0) { return $false }
    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    Set-Content -LiteralPath $ps1 -Value $text.Substring($i + $marker.Length) -Encoding UTF8
    $launcher = @(
        'Set sh = CreateObject("WScript.Shell")',
        'sh.Environment("PROCESS")("DUO_SILENT") = "1"',
        ('sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -File """ & "' + $ps1 + '" & """", 0, False')
    )
    Set-Content -LiteralPath $vbs -Value $launcher -Encoding ASCII
    return $true
}

function Register-BackgroundCheck {
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbs + '"')
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(30) -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $addons = Find-AddOns
    if (-not $addons -and -not $Silent) { $addons = Ask-AddOns }
    if (-not $addons) { throw "Couldn't find the WoW Forever folder (no _forever_ folder). Nothing was changed." }
    $dest = Join-Path $addons 'DuoTracker'
    $toc = Join-Path $dest 'DuoTracker.toc'

    $installed = $null
    if (Test-Path -LiteralPath $toc) { $installed = Get-TocVersion (Get-Content -Raw -LiteralPath $toc) }
    $latest = $null
    try {
        $remote = Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/$repo/main/DuoTracker/DuoTracker.toc"
        $latest = Get-TocVersion $remote.Content
    } catch { }

    $newBat = $null
    if ($installed -and $latest -and $installed -eq $latest) {
        Say "Duo Tracker $installed is already the latest version." 'Green'
    } else {
        Say "Downloading the latest Duo Tracker..."
        $tmp = Join-Path $env:TEMP ('DuoTracker-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $zip = Join-Path $tmp 'latest.zip'
        Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$repo/archive/refs/heads/main.zip" -OutFile $zip
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $rootDir = Get-ChildItem -LiteralPath $tmp -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'DuoTracker\DuoTracker.toc') } | Select-Object -First 1
        if (-not $rootDir) { throw "The download didn't contain the addon. Nothing was changed." }
        $source = Join-Path $rootDir.FullName 'DuoTracker'

        New-Item -ItemType Directory -Path $addons -Force | Out-Null
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Copy-Item -LiteralPath $source -Destination $dest -Recurse
        $installed = Get-TocVersion (Get-Content -Raw -LiteralPath $toc)

        $candidate = Join-Path $rootDir.FullName 'Update Duo Tracker.bat'
        if (Save-BackgroundScript $candidate) { $newBat = $candidate }
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

        Say ""
        Say "Done. Duo Tracker $installed is installed in:" 'Green'
        Say "  $dest"
        Say "If the game is open, type /reload in chat. If this is the first install, restart the game."
    }

    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    Set-Content -LiteralPath $saved -Value $addons
    Set-Content -LiteralPath $log -Value ("{0}  installed {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $installed)

    if (-not $Silent) {
        if (-not $newBat) { Save-BackgroundScript $env:DUO_SELF | Out-Null }
        try {
            Register-BackgroundCheck
            Say ""
            Say "Automatic updates are on: this PC now checks for a new version every 30 minutes, quietly." 'Green'
            Say "In game, click the orange 'Update available' button in the Duo Tracker window to load it."
            Say "To turn this off, run 'Remove Duo Tracker auto-update.bat' from the same download page."
        } catch {
            Say ""
            Say "Couldn't switch on automatic updates: $($_.Exception.Message)" 'Yellow'
            Say "The addon itself is installed. Run this file again whenever an update is available."
        }
    }
} catch {
    if ($Silent) {
        try { Set-Content -LiteralPath $log -Value ("{0}  failed: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $_.Exception.Message) } catch { }
    } else {
        Write-Host ""
        Write-Host "Update failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Your existing addon was left as it was unless a line above says otherwise."
    }
}
