#Requires -Version 5.1
<#
.SYNOPSIS
  Installs Hex and makes its dictation output Traditional Chinese (Taiwan).

.DESCRIPTION
  What this script changes:
    1. Installs Hex from https://anoma.ly/hex/install-windows.ps1 when hex.com is missing.
       The vendor installer checks the download's size and SHA-256 against its own
       manifest; it does NOT check the Authenticode signature. This script adds that:
       the vendor installer must match a reviewed SHA-256, the stable channel is
       forced, and the installed hex.exe / hex.com must carry a valid signature from
       Anomaly Innovations, Inc before this script starts them.
    2. Creates ~/.config/hex and drops the OpenCC s2tw / s2twp transformers into it.
       Every transformer file is checked against a pinned SHA-256, whether it comes
       from the folder beside this script or from the pinned commit on GitHub.
       An existing, different hex.config.ts is backed up first.
    3. Adds the s2twp step to "Every dictation", sets the interface language to
       zh-Hant and an IME-safe dictation shortcut (Ctrl+Space is the Chinese IME
       toggle on Windows, so Hex's default collides). All three go through Hex's
       own `hex settings apply`, which validates them and changes all or none;
       nothing edits settings.json by hand and Hex does not have to be stopped.
       An existing settings.json is backed up first.
    4. Verifies the result and exits non-zero when a check fails.

  Hex has no built-in simplified-to-traditional conversion for transcripts, and
  none of its speech models reliably picks the script. This script installs the
  officially supported workaround: a personal transformation in hex.config.ts.
  See https://github.com/anomalyco/hex/issues/829 and /issues/1835.

.PARAMETER Hotkey
  Dictation shortcut in Hex's text form: `control+option+space`, `f5`,
  `right-command`, `caps-lock`. Default: control+option+space

.PARAMETER SkipHotkey
  Leave the dictation shortcut exactly as it is.

.PARAMETER ConfigureOnly
  Do not install Hex, do not open it, and leave its language and shortcut alone;
  only install the transformer and add the s2twp step. Requires Hex to be installed.

.PARAMETER AllowUnreviewedInstaller
  Run the vendor installer even when its SHA-256 differs from the reviewed copy
  (the vendor has updated it). The signature check on the installed files still runs.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\install-windows.ps1

.EXAMPLE
  ./install-windows.ps1 -SkipHotkey
#>
[CmdletBinding()]
param(
    [string]$Hotkey = 'control+option+space',
    [switch]$SkipHotkey,
    [switch]$ConfigureOnly,
    [switch]$AllowUnreviewedInstaller
)

$ErrorActionPreference = 'Stop'

# Remote fallback for the transformer files: a fixed commit, never a branch.
$RepoOwner  = 'mathruffian-dot'
$RepoName   = 'hex-zh-hant'
$RepoCommit = '055aefb9ff81338d709552be2e282d5431ece5e1'
$RawBase    = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$RepoCommit/transformer"

# SHA-256 of each transformer file (LF line endings). Hex runs these as code.
$TransformerFiles = [ordered]@{
    'hex.config.ts'  = 'bbc4d99124899fe505ea5c44ed7b3710303809234a050ba28f46dabb2d0f743f'
    'hex-s2tw.ts'    = '4faeb8df96410f6a3b3272c2805bf192199847db72350375050a3ed4ed7c5e4f'
    'hex-data-st.ts' = 'a1ba50019b144b0476ae7bc47eb7ab0b552b3b46e6ed4a3404dbacb6f643171c'
    'hex-data-tw.ts' = 'cc1efef2f033f0c841d4e8fbfb2b3d9cbd72164eafbdfc6ed1e60f2a84769cda'
}

# The vendor installer as reviewed on 2026-11-23.
$VendorInstallerUrl    = 'https://anoma.ly/hex/install-windows.ps1'
$VendorInstallerSha256 = 'ffa55d3f331d9766ff2d75a13adcd26e7bb11f733509772ab71aefa1d6a50f50'
$VendorSigner          = 'Anomaly Innovations, Inc'

$SupportDir   = Join-Path $env:APPDATA 'hex'
$Hex          = Join-Path $SupportDir 'bin\hex.com'
$SettingsPath = Join-Path $SupportDir 'settings.json'
$ConfigDir    = Join-Path $env:USERPROFILE '.config\hex'
$Stamp        = Get-Date -Format yyyyMMdd-HHmmss

function Write-Step  { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Warn2 { param([string]$Message) Write-Host "    $Message" -ForegroundColor Yellow }

# Runs hex.com and returns its output as plain strings; the exit code is left in
# $script:HexExit. Windows PowerShell 5.1 turns a native program's stderr into
# error records, which abort the script under ErrorActionPreference = Stop, so
# the preference is relaxed for the call only.
function Invoke-Hex {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Hex @Arguments 2>&1 | ForEach-Object { "$_" }
        $script:HexExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    $output
}

# The release host drops a connection now and then; retry before giving up.
function Save-Remote {
    param([string]$Url, [string]$Path)
    for ($attempt = 1; ; $attempt++) {
        try {
            Invoke-WebRequest $Url -OutFile $Path -UseBasicParsing -TimeoutSec 60
            return
        } catch {
            if ($attempt -ge 4) { throw }
            Write-Warn2 "download failed ($($_.Exception.Message)); retrying"
            Start-Sleep -Seconds (3 * $attempt)
        }
    }
}

function Get-Sha256 { param([string]$Path) (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }

function Assert-HexSignature {
    param([string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '(none)' }
    if ($signature.Status -ne 'Valid' -or $subject -notlike "*$VendorSigner*") {
        throw "$Path does not carry a valid $VendorSigner signature (status: $($signature.Status); signer: $subject). Not starting it."
    }
    Write-Ok "signature ok: $(Split-Path $Path -Leaf)"
}

# Hex processes that belong to this install; an unrelated program named hex is left alone.
function Get-HexProcess {
    Get-Process hex -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($SupportDir, [StringComparison]::OrdinalIgnoreCase) }
}

function Get-HexExe {
    $pointer = Join-Path $SupportDir 'current-version'
    if (Test-Path $pointer) {
        $version = (Get-Content $pointer -Raw).Trim()
        $candidate = Join-Path $SupportDir "versions\$version\hex.exe"
        if (Test-Path $candidate) { return $candidate }
    }
    Get-ChildItem (Join-Path $SupportDir 'versions') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'hex.exe' } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
}

# `hex start` goes through hex.com, the console shim that waits for hex.exe to
# exit, so calling it from a script blocks until the app is closed. Launch the
# executable directly and poll the control pipe instead.
function Start-Hex {
    if (Get-HexProcess) { return }
    $exe = Get-HexExe
    if (-not $exe) { throw 'hex.exe was not found under %APPDATA%\hex\versions.' }
    Assert-HexSignature $exe
    Start-Process $exe -ArgumentList 'app' | Out-Null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        Invoke-Hex status | Out-Null
        if ($script:HexExit -eq 0) { return }
    }
    Write-Warn2 'Hex did not answer within 20 s; carrying on.'
}

# True when the parsed JSON holds a DateTime: PowerShell 6-7.4 turns ISO date
# strings into DateTime on read and would write them back in a different form.
function Test-HasDateTime {
    param($Node)
    if ($null -eq $Node) { return $false }
    if ($Node -is [datetime]) { return $true }
    if ($Node -is [string] -or $Node.GetType().IsPrimitive) { return $false }
    if ($Node -is [System.Collections.IEnumerable]) {
        foreach ($item in $Node) { if (Test-HasDateTime $item) { return $true } }
        return $false
    }
    foreach ($property in $Node.PSObject.Properties) {
        if (Test-HasDateTime $property.Value) { return $true }
    }
    $false
}

# ---------------------------------------------------------------------------
# 1. Hex itself
# ---------------------------------------------------------------------------
if (-not (Test-Path $Hex)) {
    if ($ConfigureOnly) {
        throw "Hex is not installed: $Hex is missing and -ConfigureOnly was given."
    }
    Write-Step 'Installing Hex'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $installer = Join-Path $env:TEMP ("hex-install-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
    Save-Remote $VendorInstallerUrl $installer
    try {
        $actual = Get-Sha256 $installer
        if ($actual -ne $VendorInstallerSha256) {
            if (-not $AllowUnreviewedInstaller) {
                throw "The vendor installer changed since it was reviewed (SHA-256 $actual). Read $VendorInstallerUrl, then re-run with -AllowUnreviewedInstaller."
            }
            Write-Warn2 "vendor installer differs from the reviewed copy (SHA-256 $actual); continuing as asked."
        } else {
            Write-Ok 'vendor installer matches the reviewed copy'
        }
        # The vendor installer follows these two variables to another server or
        # to dev builds. Pin it to Anomaly's stable channel for this run.
        $savedBase = $env:HEX_RELEASE_BASE_URL
        $savedChannel = $env:HEX_INSTALL_CHANNEL
        $env:HEX_RELEASE_BASE_URL = $null
        $env:HEX_INSTALL_CHANNEL = 'stable'
        try {
            # The vendor installer is safe to repeat and has no retry of its own.
            for ($attempt = 1; ; $attempt++) {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer
                if ($LASTEXITCODE -eq 0) { break }
                if ($attempt -ge 3) { throw "Hex's installer exited with $LASTEXITCODE" }
                Write-Warn2 "Hex's installer exited with $LASTEXITCODE; retrying"
                Start-Sleep -Seconds 5
            }
        } finally {
            $env:HEX_RELEASE_BASE_URL = $savedBase
            $env:HEX_INSTALL_CHANNEL = $savedChannel
        }
    } finally {
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $Hex)) { throw "Hex's installer finished but $Hex is missing." }
    Write-Ok "installed $Hex"
}

Write-Step 'Checking the Authenticode signature of Hex'
Assert-HexSignature $Hex
$installedExe = Get-HexExe
if (-not $installedExe) { throw 'hex.exe was not found under %APPDATA%\hex\versions.' }
Assert-HexSignature $installedExe

# ---------------------------------------------------------------------------
# 2. The transformer workspace
# ---------------------------------------------------------------------------
Write-Step "Installing the OpenCC transformer into $ConfigDir"
# `commands init` writes a starter hex.config.ts; only a config that was there
# before it is the user's own and worth keeping.
$hadConfig = Test-Path (Join-Path $ConfigDir 'hex.config.ts')
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
Invoke-Hex commands init | Out-Null

# Stage and verify everything before touching the workspace.
$localTransformer = Join-Path $PSScriptRoot 'transformer'
$staging = Join-Path $env:TEMP ("hex-zh-hant-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $staging | Out-Null
try {
    foreach ($name in $TransformerFiles.Keys) {
        $staged = Join-Path $staging $name
        $source = Join-Path $localTransformer $name
        if (Test-Path $source) {
            Copy-Item $source $staged -Force
        } else {
            Save-Remote "$RawBase/$name" $staged
        }
        $actual = Get-Sha256 $staged
        if ($actual -ne $TransformerFiles[$name]) {
            throw "$name does not match its pinned SHA-256 (got $actual). A checkout that converted line endings to CRLF also causes this."
        }
    }
    foreach ($name in $TransformerFiles.Keys) {
        $target = Join-Path $ConfigDir $name
        if ($name -eq 'hex.config.ts' -and $hadConfig -and (Test-Path $target) -and (Get-Sha256 $target) -ne $TransformerFiles[$name]) {
            $kept = "$target.bak-$Stamp"
            Copy-Item $target $kept -Force
            Write-Warn2 "the previous hex.config.ts is kept as $kept; merge your own transformations back by hand."
        }
        Copy-Item (Join-Path $staging $name) $target -Force
    }
} finally {
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Ok 'transformer files verified and copied'

$check = (Invoke-Hex commands check) -join ' '
Write-Ok $check
if ($check -notmatch '(\d+)\s+transformations' -or [int]$Matches[1] -lt 3) {
    throw "hex commands check did not report the 3 transformations: $check"
}

# ---------------------------------------------------------------------------
# 3. Settings, through Hex's own `settings apply`
# ---------------------------------------------------------------------------
# `hex settings apply` validates the values and changes all of them or none. It
# talks to the running Hex, or writes settings.json itself when Hex is stopped,
# so nothing here edits that file by hand or has to stop the app.
Write-Step 'Adding the s2twp step to Every dictation'
if (-not $ConfigureOnly) { Start-Hex }

$jsonParameters = @{}
if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonParameters.DateKind = 'String' }

$mode = $null
$reply = (Invoke-Hex settings get dictation_processing.default_mode --json) -join "`n"
if ($script:HexExit -eq 0) {
    $entry = @(($reply | ConvertFrom-Json @jsonParameters).settings | Where-Object { $_.key -eq 'dictation_processing.default_mode' })
    if ($entry.Count -eq 1) { $mode = $entry[0].value }
} elseif (Test-Path $SettingsPath) {
    # Hex is not running (-ConfigureOnly): read the stored mode instead.
    $stored = [IO.File]::ReadAllText($SettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json @jsonParameters
    if ($stored.PSObject.Properties['dictation_processing']) { $mode = $stored.dictation_processing.default_mode }
}
if ($null -eq $mode -or $mode -isnot [pscustomobject]) {
    throw 'Could not read dictation_processing.default_mode. Start Hex (or run without -ConfigureOnly) and try again.'
}
if (Test-HasDateTime $mode) {
    throw 'This PowerShell would rewrite a date stored in the mode. Run the script with powershell.exe (Windows PowerShell 5.1) or PowerShell 7.5+.'
}
$existing = if ($mode.PSObject.Properties['transformations']) { @($mode.transformations | Where-Object { $_ }) } else { @() }
if (@($existing | Where-Object { $_ -isnot [string] }).Count -gt 0) {
    throw 'default_mode.transformations is not a list of step names; this Hex version stores steps differently. Add s2twp in Settings > Output instead.'
}

$changes = [ordered]@{}
if ($existing -contains 's2twp') {
    Write-Ok ('already present; steps: ' + ($existing -join ', '))
} else {
    $steps = @($existing) + 's2twp'
    $mode | Add-Member -NotePropertyName transformations -NotePropertyValue ([string[]]$steps) -Force
    $changes['dictation_processing.default_mode'] = $mode
    Write-Ok ('steps: ' + ($steps -join ', '))
}
if (-not $ConfigureOnly) {
    # Only what differs, so a second run changes nothing and writes no backup.
    if (((Invoke-Hex settings get ui_language) -join ' ').Trim() -ne 'zh-Hant') { $changes['ui_language'] = 'zh-Hant' }
    if (-not $SkipHotkey -and $Hotkey -and ((Invoke-Hex settings get dictation_hotkey) -join ' ').Trim() -ne $Hotkey) {
        $changes['dictation_hotkey'] = $Hotkey
    }
}

if ($changes.Count -gt 0) {
    if (Test-Path $SettingsPath) {
        $backup = "$SettingsPath.bak-$Stamp"
        Copy-Item $SettingsPath $backup -Force
        Write-Ok "settings backed up to $backup"
    }
    Write-Step ('Applying: ' + ($changes.Keys -join ', '))
    $applyFile = Join-Path $env:TEMP ("hex-apply-{0}.json" -f [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($applyFile, ($changes | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding($false)))
    try {
        $out = Invoke-Hex settings apply $applyFile
        if ($script:HexExit -ne 0) { throw "hex settings apply refused the change: $($out -join ' ')" }
    } finally {
        Remove-Item $applyFile -Force -ErrorAction SilentlyContinue
    }
    Write-Ok (($out -join ' ').Trim())
}

# ---------------------------------------------------------------------------
# 4. Verify
# ---------------------------------------------------------------------------
Write-Step 'Result'
$failures = @()

$check = (Invoke-Hex commands check) -join ' '
Write-Host "    commands check: $check"
if ($check -notmatch '(\d+)\s+transformations' -or [int]$Matches[1] -lt 3) { $failures += 'hex commands check does not list 3 transformations' }

Invoke-Hex status | Out-Null
if ($script:HexExit -eq 0) {
    $modeNow = (Invoke-Hex settings get dictation_processing.default_mode) -join ' '
    Write-Host "    default_mode: $modeNow"
    if ($modeNow -notmatch '"s2twp"') { $failures += 's2twp is not in dictation_processing.default_mode' }

    $language = (Invoke-Hex settings get ui_language) -join ' '
    Write-Host "    ui_language: $language"
    if (-not $ConfigureOnly -and $language -notmatch 'zh-Hant') { $failures += 'ui_language is not zh-Hant' }

    Write-Host ("    dictation_hotkey: " + ((Invoke-Hex settings get dictation_hotkey) -join ' '))
} else {
    # Hex is stopped (-ConfigureOnly): check what was written to disk.
    $onDisk = [IO.File]::ReadAllText($SettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json @jsonParameters
    $diskSteps = @($onDisk.dictation_processing.default_mode.transformations)
    Write-Host ("    steps on disk: " + ($diskSteps -join ', '))
    if ($diskSteps -notcontains 's2twp') { $failures += 's2twp is not in dictation_processing.default_mode on disk' }
}

Write-Host ''
if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "FAILED: $failure" -ForegroundColor Red }
    exit 1
}
Write-Host 'All checks passed. Speak one sentence somewhere, then:'
Write-Host '  hex history --raw --limit 1     # raw_text is simplified, final_text must be traditional'
