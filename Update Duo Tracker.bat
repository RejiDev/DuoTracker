@echo off
title Update Duo Tracker
set "DUO_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s = Get-Content -Raw -LiteralPath $env:DUO_SELF; $i = $s.IndexOf('#POWERSHELL#' + [char]13); if ($i -lt 0) { $i = $s.IndexOf('#POWERSHELL#' + [char]10) }; Invoke-Expression $s.Substring($i + 12)"
echo.
pause
exit /b
#POWERSHELL#
# Installs or updates the Duo Tracker addon for WoW Forever.
$ErrorActionPreference = 'Stop'
$repo = 'RejiDev/DuoTracker'
$cfgDir = Join-Path $env:LOCALAPPDATA 'DuoTracker'
$saved = Join-Path $cfgDir 'addons-path.txt'

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

try {
    $addons = Find-AddOns
    if (-not $addons) { $addons = Ask-AddOns }
    if (-not $addons) { throw "That folder doesn't contain WoW Forever (no _forever_ folder inside it). Nothing was changed." }

    Write-Host "Downloading the latest Duo Tracker..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $tmp = Join-Path $env:TEMP ('DuoTracker-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $zip = Join-Path $tmp 'latest.zip'
    Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$repo/archive/refs/heads/main.zip" -OutFile $zip
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $source = Get-ChildItem -LiteralPath $tmp -Directory | ForEach-Object { Join-Path $_.FullName 'DuoTracker' } |
        Where-Object { Test-Path -LiteralPath (Join-Path $_ 'DuoTracker.toc') } | Select-Object -First 1
    if (-not $source) { throw "The download didn't contain the addon. Nothing was changed." }

    New-Item -ItemType Directory -Path $addons -Force | Out-Null
    $dest = Join-Path $addons 'DuoTracker'
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Copy-Item -LiteralPath $source -Destination $dest -Recurse
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    Set-Content -LiteralPath $saved -Value $addons

    $version = (Select-String -LiteralPath (Join-Path $dest 'DuoTracker.toc') -Pattern '^## Version:\s*(.+)$').Matches[0].Groups[1].Value
    Write-Host ""
    Write-Host "Done. Duo Tracker $version is installed in:" -ForegroundColor Green
    Write-Host "  $dest"
    Write-Host "If the game is open, type /reload in chat. If this is the first install, restart the game."
} catch {
    Write-Host ""
    Write-Host "Update failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Your existing addon was left as it was unless a line above says otherwise."
}
