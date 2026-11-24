#Requires -Version 5.1
<#
.SYNOPSIS
  Moves a Hex install that was made from inside the Claude desktop app to the
  normal per-user location.

.DESCRIPTION
  The Claude desktop app is a packaged (MSIX) app: anything it writes under
  %APPDATA% and %LOCALAPPDATA% lands in its private storage,
  %LOCALAPPDATA%\Packages\Claude_...\LocalCache. A Hex installed from a Claude
  session therefore keeps its settings and speech models there, and a Hex opened
  from the Start menu looks in the real folders and finds none of them.

  Run this from an ordinary PowerShell window (Start menu > PowerShell), NOT from
  a terminal inside Claude. It:
    1. stops any running Hex,
    2. copies the downloaded speech models to the real %LOCALAPPDATA%\hex\models,
    3. runs install-windows.ps1 beside this script, which installs Hex in the real
       %APPDATA%\hex and applies the Traditional Chinese step, language and shortcut,
    4. imports Breeze ASR 25, selects it, and restores the vocabulary.
  Nothing is deleted; the copy inside Claude's storage stays until you remove it.

.PARAMETER AllowUnreviewedInstaller
  Passed on to install-windows.ps1.
#>
[CmdletBinding()]
param([switch]$AllowUnreviewedInstaller)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }

$package = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'LocalCache\Roaming\hex') } |
    Select-Object -First 1
if (-not $package) { throw 'No Hex install was found inside the Claude app storage; nothing to move.' }
$sandbox = Join-Path $package.FullName 'LocalCache'
$sandboxModels = Join-Path $sandbox 'Local\hex\models'

# Inside the Claude app the real folders are overlaid by the sandbox, so this
# script would only copy the files onto themselves.
$probe = Join-Path $env:LOCALAPPDATA ("hex-sandbox-probe-{0}.tmp" -f [guid]::NewGuid().ToString('N'))
Set-Content -Path $probe -Value 'probe'
$insideSandbox = Test-Path (Join-Path $sandbox ("Local\" + (Split-Path $probe -Leaf)))
Remove-Item $probe -Force
if ($insideSandbox) {
    throw 'This window runs inside the Claude app. Open PowerShell from the Start menu and run the script there.'
}

Write-Step 'Stopping Hex'
$running = @(Get-Process hex -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*\hex\versions\*\hex.exe' })
foreach ($process in $running) {
    $shim = Join-Path (Split-Path $process.Path) 'hex.com'
    if (Test-Path $shim) { & $shim quit *> $null }
}
for ($i = 0; $i -lt 20 -and (Get-Process hex -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*\hex\versions\*\hex.exe' }); $i++) {
    Start-Sleep -Milliseconds 500
}
Get-Process hex -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*\hex\versions\*\hex.exe' } |
    Stop-Process -Force -ErrorAction SilentlyContinue
Write-Ok 'stopped'

Write-Step 'Copying the downloaded speech models'
$models = Join-Path $env:LOCALAPPDATA 'hex\models'
New-Item -ItemType Directory -Force -Path $models | Out-Null
foreach ($file in Get-ChildItem $sandboxModels -File -Filter '*.gguf*') {
    $target = Join-Path $models $file.Name
    if ((Test-Path $target) -and (Get-Item $target).Length -eq $file.Length) {
        Write-Ok "already there: $($file.Name)"
    } else {
        Copy-Item $file.FullName $target -Force
        Write-Ok "copied: $($file.Name)"
    }
}

Write-Step 'Installing and configuring Hex in the normal location'
$installer = Join-Path $PSScriptRoot 'install-windows.ps1'
$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installer)
if ($AllowUnreviewedInstaller) { $arguments += '-AllowUnreviewedInstaller' }
& powershell.exe @arguments
if ($LASTEXITCODE -ne 0) { throw "install-windows.ps1 exited with $LASTEXITCODE; see its messages above." }

$hex = Join-Path $env:APPDATA 'hex\bin\hex.com'

Write-Step 'Importing Breeze ASR 25'
$breeze = Get-ChildItem (Join-Path $sandboxModels 'custom') -File -Filter '*.gguf' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($breeze) {
    $imported = (& $hex model import $breeze.FullName --name 'Breeze ASR 25' 2>&1 | ForEach-Object { "$_" }) -join ' '
    Write-Ok $imported
    if ($imported -match '(custom-[0-9a-f]+)') {
        Write-Ok ((& $hex model use $Matches[1] 2>&1 | ForEach-Object { "$_" }) -join ' ')
    } else {
        Write-Host '    Breeze was not imported; Hex keeps its own choice of model.' -ForegroundColor Yellow
    }
} else {
    Write-Host '    no imported model found in the Claude storage; skipped.' -ForegroundColor Yellow
}

Write-Step 'Restoring the vocabulary'
foreach ($term in 'Hex', 'Claude') {
    Write-Ok ((& $hex vocabulary add $term 2>&1 | ForEach-Object { "$_" }) -join ' ')
}

Write-Step 'Result'
& $hex status
& $hex model status
Write-Host ''
Write-Host "Done. The old copy is still in $sandbox (about 3.4 GB); it can be removed once dictation works."
