# peon-ping Windows installer
# Native Windows support (no WSL required)
# Run: iwr -useb https://raw.githubusercontent.com/hao6yu/peon-ping-win/main/install.ps1 | iex

$ErrorActionPreference = "Stop"

$INSTALL_DIR = "$env:USERPROFILE\.claude\hooks\peon-ping"
$SETTINGS = "$env:USERPROFILE\.claude\settings.json"
$REPO_BASE = "https://raw.githubusercontent.com/hao6yu/peon-ping-win/main"

# Sound packs to download
$PACKS = @("peon", "peon_fr", "peon_pl", "peasant", "peasant_fr", "ra2_soviet_engineer", "sc_battlecruiser", "sc_kerrigan")

Write-Host ""
Write-Host "=== peon-ping Windows installer ===" -ForegroundColor Cyan
Write-Host ""

# Check prerequisites
if (!(Test-Path "$env:USERPROFILE\.claude")) {
    Write-Host "Error: ~/.claude/ not found. Is Claude Code installed?" -ForegroundColor Red
    exit 1
}

# Check for Python
$python = Get-Command python -ErrorAction SilentlyContinue
if (!$python) {
    $python = Get-Command python3 -ErrorAction SilentlyContinue
}
if (!$python) {
    Write-Host "Error: Python is required. Install from https://python.org" -ForegroundColor Red
    exit 1
}
$PYTHON = $python.Source
Write-Host "Found Python: $PYTHON" -ForegroundColor Green

# Create install directory
if (!(Test-Path $INSTALL_DIR)) {
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
}

Write-Host "Installing to: $INSTALL_DIR"
Write-Host ""

# Download core files
$coreFiles = @("peon.ps1", "config.json", "VERSION")
foreach ($file in $coreFiles) {
    Write-Host "  Downloading $file..."
    $url = "$REPO_BASE/$file"
    $dest = "$INSTALL_DIR\$file"
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    } catch {
        Write-Host "    Failed to download $file" -ForegroundColor Yellow
    }
}

# Download sound packs
Write-Host ""
Write-Host "Downloading sound packs..." -ForegroundColor Cyan
$packsDir = "$INSTALL_DIR\packs"
if (!(Test-Path $packsDir)) {
    New-Item -ItemType Directory -Path $packsDir -Force | Out-Null
}

foreach ($pack in $PACKS) {
    $packDir = "$packsDir\$pack"
    $soundsDir = "$packDir\sounds"
    
    if (!(Test-Path $packDir)) {
        New-Item -ItemType Directory -Path $packDir -Force | Out-Null
    }
    if (!(Test-Path $soundsDir)) {
        New-Item -ItemType Directory -Path $soundsDir -Force | Out-Null
    }
    
    # Download manifest
    $manifestUrl = "$REPO_BASE/packs/$pack/manifest.json"
    $manifestDest = "$packDir\manifest.json"
    
    try {
        Invoke-WebRequest -Uri $manifestUrl -OutFile $manifestDest -UseBasicParsing
        Write-Host "  Downloaded: $pack" -ForegroundColor Green
        
        # Parse manifest and download sounds
        $manifest = Get-Content $manifestDest | ConvertFrom-Json
        $categories = $manifest.categories.PSObject.Properties
        
        foreach ($cat in $categories) {
            $sounds = $cat.Value.sounds
            foreach ($sound in $sounds) {
                $soundFile = $sound.file
                $soundUrl = "$REPO_BASE/packs/$pack/sounds/$soundFile"
                $soundDest = "$soundsDir\$soundFile"
                
                if (!(Test-Path $soundDest)) {
                    try {
                        Invoke-WebRequest -Uri $soundUrl -OutFile $soundDest -UseBasicParsing
                    } catch {
                        # Silent fail for individual sounds
                    }
                }
            }
        }
    } catch {
        Write-Host "  Skipped: $pack (not found)" -ForegroundColor Yellow
    }
}

# Configure Claude Code settings.json
Write-Host ""
Write-Host "Configuring Claude Code hooks..." -ForegroundColor Cyan

$hookCommand = "powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$INSTALL_DIR\peon.ps1`""

if (Test-Path $SETTINGS) {
    $settings = Get-Content $SETTINGS -Raw | ConvertFrom-Json
} else {
    $settings = [PSCustomObject]@{}
}

# New Claude Code hooks format (object with event keys, not array)
# Format: { "hooks": { "EventName": [{ "hooks": [{ "type": "command", "command": "..." }] }] } }

$hookEntry = @{
    hooks = @(
        @{
            type = "command"
            command = $hookCommand
        }
    )
}

$hooksConfig = @{
    SessionStart = @($hookEntry)
    Stop = @($hookEntry)
    Notification = @($hookEntry)
    UserPromptSubmit = @($hookEntry)
}

# Update or add hooks property
if ($settings.hooks) {
    # Merge with existing hooks
    $existingHooks = @{}
    $settings.hooks.PSObject.Properties | ForEach-Object { $existingHooks[$_.Name] = $_.Value }
    foreach ($key in $hooksConfig.Keys) {
        $existingHooks[$key] = $hooksConfig[$key]
    }
    $settings.hooks = [PSCustomObject]$existingHooks
} else {
    $settings | Add-Member -NotePropertyName "hooks" -NotePropertyValue ([PSCustomObject]$hooksConfig) -Force
}

# Write settings
$jsonOutput = $settings | ConvertTo-Json -Depth 10
$jsonOutput | Out-File -FilePath "$env:USERPROFILE\.claude\settings.json" -Force

Write-Host ""
Write-Host "=== Installation complete! ===" -ForegroundColor Green
Write-Host ""
Write-Host "peon-ping is now active. Start a new Claude Code session to hear:" -ForegroundColor Cyan
Write-Host '  "Ready to work!"' -ForegroundColor Yellow
Write-Host ""
Write-Host "Commands:" -ForegroundColor Cyan
Write-Host "  peon --pause     Mute sounds"
Write-Host "  peon --resume    Unmute sounds"
Write-Host "  peon --packs     List sound packs"
Write-Host "  peon --pack <n>  Switch pack"
Write-Host ""

# Create peon.cmd wrapper for easy CLI access
$peonCmd = "@echo off`npowershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$INSTALL_DIR\peon.ps1`" %*"
$peonCmdPath = "$INSTALL_DIR\peon.cmd"
Set-Content -Path $peonCmdPath -Value $peonCmd

# Add to PATH hint
Write-Host "Tip: Add to PATH for 'peon' command:" -ForegroundColor Cyan
Write-Host "  `$env:PATH += `";$INSTALL_DIR`"" -ForegroundColor Gray
Write-Host ""
