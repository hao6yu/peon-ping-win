# peon-ping: Warcraft III Peon voice lines for Claude Code hooks
# Native Windows version (no WSL required)
param(
    [switch]$pause,
    [switch]$resume,
    [switch]$toggle,
    [switch]$status,
    [switch]$packs,
    [string]$pack,
    [switch]$help
)

$PEON_DIR = if ($env:CLAUDE_PEON_DIR) { $env:CLAUDE_PEON_DIR } else { "$env:USERPROFILE\.claude\hooks\peon-ping" }
$CONFIG = "$PEON_DIR\config.json"
$STATE = "$PEON_DIR\.state.json"
$PAUSED_FILE = "$PEON_DIR\.paused"

# --- CLI Commands ---
if ($help) {
    Write-Host @"
Usage: peon <command>

Commands:
  -pause         Mute sounds
  -resume        Unmute sounds
  -toggle        Toggle mute on/off
  -status        Check if paused or active
  -packs         List available sound packs
  -pack <name>   Switch to a specific pack
  -pack          Cycle to the next pack (no argument)
  -help          Show this help
"@
    exit 0
}

if ($pause) {
    New-Item -ItemType File -Path $PAUSED_FILE -Force | Out-Null
    Write-Host "peon-ping: sounds paused"
    exit 0
}

if ($resume) {
    Remove-Item -Path $PAUSED_FILE -Force -ErrorAction SilentlyContinue
    Write-Host "peon-ping: sounds resumed"
    exit 0
}

if ($toggle) {
    if (Test-Path $PAUSED_FILE) {
        Remove-Item -Path $PAUSED_FILE -Force
        Write-Host "peon-ping: sounds resumed"
    } else {
        New-Item -ItemType File -Path $PAUSED_FILE -Force | Out-Null
        Write-Host "peon-ping: sounds paused"
    }
    exit 0
}

if ($status) {
    if (Test-Path $PAUSED_FILE) {
        Write-Host "peon-ping: paused"
    } else {
        Write-Host "peon-ping: active"
    }
    exit 0
}

if ($packs) {
    $cfg = @{ active_pack = "peon" }
    if (Test-Path $CONFIG) {
        $cfg = Get-Content $CONFIG | ConvertFrom-Json
    }
    $activePack = if ($cfg.active_pack) { $cfg.active_pack } else { "peon" }
    
    $packDirs = Get-ChildItem -Path "$PEON_DIR\packs" -Directory -ErrorAction SilentlyContinue
    foreach ($p in $packDirs) {
        $manifestPath = "$($p.FullName)\manifest.json"
        if (Test-Path $manifestPath) {
            $manifest = Get-Content $manifestPath | ConvertFrom-Json
            $name = $p.Name
            $display = if ($manifest.display_name) { $manifest.display_name } else { $name }
            $marker = if ($name -eq $activePack) { " *" } else { "" }
            Write-Host ("  {0,-24} {1}{2}" -f $name, $display, $marker)
        }
    }
    exit 0
}

if ($PSBoundParameters.ContainsKey('pack')) {
    $cfg = @{}
    if (Test-Path $CONFIG) {
        $cfg = Get-Content $CONFIG -Raw | ConvertFrom-Json
    }
    
    $packDirs = Get-ChildItem -Path "$PEON_DIR\packs" -Directory -ErrorAction SilentlyContinue
    $packNames = $packDirs | ForEach-Object { $_.Name } | Sort-Object
    
    if ([string]::IsNullOrEmpty($pack)) {
        # Cycle to next pack
        $currentPack = if ($cfg.active_pack) { $cfg.active_pack } else { "peon" }
        $idx = [array]::IndexOf($packNames, $currentPack)
        $nextIdx = ($idx + 1) % $packNames.Count
        $pack = $packNames[$nextIdx]
    }
    
    if ($pack -notin $packNames) {
        Write-Host "Error: pack '$pack' not found." -ForegroundColor Red
        Write-Host "Available packs: $($packNames -join ', ')"
        exit 1
    }
    
    $cfg | Add-Member -NotePropertyName "active_pack" -NotePropertyValue $pack -Force
    $cfg | ConvertTo-Json -Depth 10 | Set-Content $CONFIG
    
    $manifestPath = "$PEON_DIR\packs\$pack\manifest.json"
    $display = $pack
    if (Test-Path $manifestPath) {
        $manifest = Get-Content $manifestPath | ConvertFrom-Json
        if ($manifest.display_name) { $display = $manifest.display_name }
    }
    Write-Host "peon-ping: switched to $pack ($display)"
    exit 0
}

# --- Hook mode: read JSON from stdin ---
$inputJson = $null
try {
    $inputJson = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputJson)) { exit 0 }
    $eventData = $inputJson | ConvertFrom-Json
} catch {
    exit 0
}

$isPaused = Test-Path $PAUSED_FILE

# Load config
$cfg = @{ enabled = $true; volume = 0.5; active_pack = "peon"; annoyed_threshold = 3; annoyed_window_seconds = 10; categories = @{} }
if (Test-Path $CONFIG) {
    try {
        $loadedCfg = Get-Content $CONFIG -Raw | ConvertFrom-Json
        foreach ($prop in $loadedCfg.PSObject.Properties) {
            $cfg[$prop.Name] = $prop.Value
        }
    } catch {}
}

if ($cfg.enabled -eq $false) { exit 0 }

# Load state (PS 5.1 compatible - no -AsHashtable)
$state = @{}
if (Test-Path $STATE) {
    try {
        $stateObj = Get-Content $STATE -Raw | ConvertFrom-Json
        # Convert PSObject to hashtable manually for PS 5.1 compatibility
        $stateObj.PSObject.Properties | ForEach-Object {
            $state[$_.Name] = $_.Value
        }
    } catch {
        $state = @{}
    }
}

# Parse event
$event = $eventData.hook_event_name
$ntype = $eventData.notification_type
$cwd = $eventData.cwd
$sessionId = $eventData.session_id
$permMode = $eventData.permission_mode

# Agent detection - skip delegate/agent sessions
$agentModes = @("delegate")
$agentSessions = @()
if ($state["agent_sessions"]) {
    $agentSessions = @($state["agent_sessions"])
}

if ($permMode -and $permMode -in $agentModes) {
    if ($sessionId -notin $agentSessions) {
        $agentSessions += $sessionId
        $state["agent_sessions"] = $agentSessions
        $state | ConvertTo-Json -Depth 10 | Set-Content $STATE
    }
    exit 0
}

if ($sessionId -in $agentSessions) { exit 0 }

# Project name
$project = if ($cwd) { Split-Path $cwd -Leaf } else { "claude" }
if ([string]::IsNullOrEmpty($project)) { $project = "claude" }
$project = $project -replace '[^a-zA-Z0-9 ._-]', ''

# Event routing
$category = ""
$statusText = ""
$notify = $false
$notifyColor = "red"
$msg = ""

switch ($event) {
    "SessionStart" {
        $category = "greeting"
        $statusText = "ready"
    }
    "UserPromptSubmit" {
        $statusText = "working"
        # Annoyed detection
        $catEnabled = if ($cfg.categories.annoyed -eq $false) { $false } else { $true }
        if ($catEnabled) {
            $now = [int][double]::Parse((Get-Date -UFormat %s))
            $window = $cfg.annoyed_window_seconds
            $threshold = $cfg.annoyed_threshold
            
            if (-not $state["prompt_timestamps"]) { $state["prompt_timestamps"] = @{} }
            $pts = $state["prompt_timestamps"]
            if ($pts -isnot [hashtable]) { $pts = @{}; $state["prompt_timestamps"] = $pts }
            
            $ts = @()
            if ($pts[$sessionId]) {
                $ts = @($pts[$sessionId] | Where-Object { ($now - $_) -lt $window })
            }
            $ts += $now
            $pts[$sessionId] = $ts
            
            if ($ts.Count -ge $threshold) {
                $category = "annoyed"
            }
        }
    }
    "Stop" {
        $category = "complete"
        $statusText = "done"
        $notify = $true
        $notifyColor = "blue"
        $msg = "$project - Task complete"
    }
    "Notification" {
        switch ($ntype) {
            "permission_prompt" {
                $category = "permission"
                $statusText = "needs approval"
                $notify = $true
                $notifyColor = "red"
                $msg = "$project - Permission needed"
            }
            "idle_prompt" {
                $statusText = "done"
                $notify = $true
                $notifyColor = "yellow"
                $msg = "$project - Waiting for input"
            }
            default { exit 0 }
        }
    }
    "PermissionRequest" {
        $category = "permission"
        $statusText = "needs approval"
        $notify = $true
        $notifyColor = "red"
        $msg = "$project - Permission needed"
    }
    default { exit 0 }
}

# Check if category is enabled
if ($category) {
    $catEnabled = $true
    if ($cfg.categories.PSObject.Properties.Name -contains $category) {
        $catEnabled = $cfg.categories.$category -ne $false
    }
    if (!$catEnabled) { $category = "" }
}

# Pick sound
$soundFile = ""
if ($category -and !$isPaused) {
    $activePack = if ($cfg.active_pack) { $cfg.active_pack } else { "peon" }
    $packDir = "$PEON_DIR\packs\$activePack"
    $manifestPath = "$packDir\manifest.json"
    
    if (Test-Path $manifestPath) {
        try {
            $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
            $sounds = $manifest.categories.$category.sounds
            
            if ($sounds -and $sounds.Count -gt 0) {
                # Avoid repeating last sound
                $lastPlayed = @{}
                if ($state["last_played"]) {
                    # Convert PSObject to hashtable if needed
                    $lp = $state["last_played"]
                    if ($lp -is [hashtable]) {
                        $lastPlayed = $lp
                    } else {
                        $lp.PSObject.Properties | ForEach-Object { $lastPlayed[$_.Name] = $_.Value }
                    }
                }
                $lastFile = if ($lastPlayed[$category]) { $lastPlayed[$category] } else { "" }
                
                $candidates = $sounds
                if ($sounds.Count -gt 1) {
                    $candidates = $sounds | Where-Object { $_.file -ne $lastFile }
                }
                
                $pick = $candidates | Get-Random
                $soundFile = "$packDir\sounds\$($pick.file)"
                
                $lastPlayed[$category] = $pick.file
                $state["last_played"] = $lastPlayed
            }
        } catch {}
    }
}

# Save state
try {
    $state | ConvertTo-Json -Depth 10 | Set-Content $STATE
} catch {}

# Play sound (async)
if ($soundFile -and (Test-Path $soundFile)) {
    $volume = $cfg.volume
    $job = Start-Job -ScriptBlock {
        param($file, $vol)
        Add-Type -AssemblyName PresentationCore
        $player = New-Object System.Windows.Media.MediaPlayer
        $player.Open([Uri]::new($file))
        $player.Volume = $vol
        Start-Sleep -Milliseconds 300
        $player.Play()
        Start-Sleep -Seconds 4
        $player.Close()
    } -ArgumentList $soundFile, $volume
    
    # Don't wait for job, let it run in background
    # Cleanup old jobs
    Get-Job -State Completed | Remove-Job -Force -ErrorAction SilentlyContinue
}

# Send notification (async)
if ($notify -and $msg) {
    $rgb = switch ($notifyColor) {
        "blue"   { @{ r=30; g=80; b=180 } }
        "yellow" { @{ r=200; g=160; b=0 } }
        default  { @{ r=180; g=0; b=0 } }
    }
    
    $notifyJob = Start-Job -ScriptBlock {
        param($message, $r, $g, $b)
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        
        $form = New-Object System.Windows.Forms.Form
        $form.FormBorderStyle = 'None'
        $form.BackColor = [System.Drawing.Color]::FromArgb($r, $g, $b)
        $form.Size = New-Object System.Drawing.Size(450, 70)
        $form.TopMost = $true
        $form.ShowInTaskbar = $false
        $form.StartPosition = 'Manual'
        
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen
        $form.Location = New-Object System.Drawing.Point(
            ($screen.WorkingArea.X + ($screen.WorkingArea.Width - 450) / 2),
            ($screen.WorkingArea.Y + 50)
        )
        
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $message
        $label.ForeColor = [System.Drawing.Color]::White
        $label.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
        $label.TextAlign = 'MiddleCenter'
        $label.Dock = 'Fill'
        $form.Controls.Add($label)
        
        $form.Show()
        $form.Refresh()
        Start-Sleep -Seconds 4
        $form.Close()
    } -ArgumentList $msg, $rgb.r, $rgb.g, $rgb.b
}

# Update terminal title
if ($statusText) {
    $title = "$project - $statusText"
    $host.UI.RawUI.WindowTitle = $title
}
