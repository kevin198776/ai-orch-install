<#
.SYNOPSIS
  One-line installer for an AI Orchestrator (Ciel) host on Windows.

.DESCRIPTION
  Idempotent: every step first checks whether it is already done and skips it.
  Runs on Windows PowerShell 5.1 and PowerShell 7 (keep the syntax 5.1 compatible and the file ASCII-only).

  One-line use (the public installer repo publishes a copy of this file):
    irm https://raw.githubusercontent.com/<owner>/<installer-repo>/main/Install-AIOrch.ps1 | iex
  With parameters:
    & ([scriptblock]::Create((irm <same-url>))) -InstallRoot D:\AI_Orchestrator -DryRun

  The installer never reads, prints or stores tokens, keys or cookies. Every sign-in (tailnet approval,
  gh browser login, Claude/Codex login) is done by the owner in the browser.
  It never runs "tailscale up" on a host that is already connected, so an existing host is never moved
  off its current tailnet; changing the login server of a connected host is refused (that is gate G4).

  Network: by default the host joins the owner's own control server (CielSpace, a self-hosted Headscale with
  its own relay), so hosts reach each other without Tailscale's account or coordination service. The new
  device is approved from a host that is already on that network. "-LoginServer official" joins Tailscale's
  own network instead. Only the Tailscale client program is used in both cases.
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = "",
    [string]$Repository = "kevin198776/AI_Orchestrator",
    [string]$SecondBrainRepository = "kevin198776/SecondBrain",
    [string]$SecondBrainPath = "",
    [string]$ProjectRegistryPath = "",
    [string]$LoginServer = "https://hs.wealthwaifu.org",
    [int[]]$ServePorts = @(8791, 8792),
    [switch]$SkipCiel,
    [switch]$DryRun,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT") { throw "Install-AIOrch supports Windows only." }

function Get-DefaultInstallRoot {
    if (Test-Path -LiteralPath "D:\" -PathType Container) { return "D:\AI_Orchestrator" }
    return (Join-Path $HOME "AI_Orchestrator")
}
if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = Get-DefaultInstallRoot }
if ([string]::IsNullOrWhiteSpace($SecondBrainPath)) { $SecondBrainPath = Join-Path $HOME "SecondBrain" }
if ([string]::IsNullOrWhiteSpace($ProjectRegistryPath)) {
    $ProjectRegistryPath = Join-Path (Join-Path $HOME ".ai-orchestrator") "project-registry"
}
foreach ($pathValue in @($InstallRoot, $SecondBrainPath, $ProjectRegistryPath)) {
    if (-not [System.IO.Path]::IsPathRooted($pathValue)) { throw "Paths must be absolute: $pathValue" }
}
if ($Repository -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$') { throw "Invalid repository: $Repository" }
if ($SecondBrainRepository -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$') { throw "Invalid repository: $SecondBrainRepository" }
$UseOfficial = ($LoginServer -eq "official")
if ($UseOfficial) { $LoginServer = "" }
if (-not $UseOfficial -and [string]::IsNullOrWhiteSpace($LoginServer)) {
    throw 'LoginServer is empty: pass the control server URL, or "official" for Tailscale''s own network.'
}
# Tailscale's network issues HTTPS certificates for serve; a self-hosted control server does not (HTTP serve,
# still tailnet only and encrypted by the tailnet itself).
$ServeKind = "http"
if ($UseOfficial) { $ServeKind = "https" }
if ($LoginServer -and $LoginServer -notmatch '^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$') {
    throw "LoginServer must be an https URL without a path: $LoginServer"
}

$script:Results = New-Object System.Collections.Generic.List[object]

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ";"
    foreach ($extra in @("$env:ProgramFiles\Tailscale", "$env:ProgramFiles\GitHub CLI", "$env:ProgramFiles\Git\cmd")) {
        if ((Test-Path -LiteralPath $extra) -and ($env:Path -notlike "*$extra*")) { $env:Path = "$env:Path;$extra" }
    }
}

function Test-Command([string]$Name) { return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Invoke-Native {
    param([string]$File, [string[]]$Arguments)
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw ("Command failed (exit {0}): {1} {2}" -f $LASTEXITCODE, $File, ($Arguments -join " ")) }
}

function Invoke-Step {
    param([string]$Name, [string]$Plan, [scriptblock]$IsDone, [scriptblock]$Action)
    # IsDone probes must be read-only and handle their own errors; an exception here (for example the
    # gate G4 refusal) stops the installer instead of being treated as "not done".
    $done = [bool](& $IsDone)
    if ($done) {
        $script:Results.Add([pscustomobject]@{ step = $Name; status = "already-done"; plan = $Plan })
        if (-not $Json) { Write-Host ("[skip] {0}: already done" -f $Name) }
        return
    }
    if ($DryRun) {
        $script:Results.Add([pscustomobject]@{ step = $Name; status = "planned"; plan = $Plan })
        if (-not $Json) { Write-Host ("[plan] {0}: {1}" -f $Name, $Plan) }
        return
    }
    if (-not $Json) { Write-Host ("[run ] {0}: {1}" -f $Name, $Plan) }
    & $Action
    $script:Results.Add([pscustomobject]@{ step = $Name; status = "done"; plan = $Plan })
}

function Get-TailscaleState {
    if (-not (Test-Command "tailscale")) { return $null }
    $raw = & tailscale status --json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    try { return ($raw | Out-String | ConvertFrom-Json) } catch { return $null }
}

function Test-TailscaleConnected {
    $state = Get-TailscaleState
    return ($null -ne $state -and $state.BackendState -eq "Running")
}

function Test-GhLoggedIn {
    if (-not (Test-Command "gh")) { return $false }
    & gh auth status --hostname github.com *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-GitRepo([string]$Path) {
    return (Test-Path -LiteralPath (Join-Path $Path ".git"))
}

function Test-ServePort([int]$Port) {
    if (-not (Test-Command "tailscale")) { return $false }
    $raw = & tailscale serve status --json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $false }
    try { $serve = ($raw | Out-String | ConvertFrom-Json) } catch { return $false }
    if ($null -eq $serve -or -not $serve.PSObject.Properties["TCP"] -or $null -eq $serve.TCP) { return $false }
    $entry = $serve.TCP.PSObject.Properties[[string]$Port]
    $key = $ServeKind.ToUpperInvariant()
    return ($null -ne $entry -and $entry.Value.PSObject.Properties[$key] -and $entry.Value.$key -eq $true)
}

function Get-HttpStatus([string]$Uri) {
    # Any HTTP status means the server answers; the loopback page answers 403 to callers that are not
    # coming through tailscale serve, which is the expected healthy state.
    try {
        return [int](Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec 3).StatusCode
    } catch {
        $resp = $null
        if ($_.Exception.PSObject.Properties["Response"]) { $resp = $_.Exception.Response }
        if ($null -ne $resp) { return [int]$resp.StatusCode }
        return 0
    }
}

function Get-VenvPython { return (Join-Path $InstallRoot ".venv\Scripts\python.exe") }

function Get-PsExe {
    if (Test-Command "pwsh") { return "pwsh" }
    return "powershell"
}

Update-SessionPath

# 1. Tools ------------------------------------------------------------------------------------------
$packages = @(
    @{ Name = "git"; Id = "Git.Git" },
    @{ Name = "gh"; Id = "GitHub.cli" },
    @{ Name = "tailscale"; Id = "Tailscale.Tailscale" }
)
foreach ($package in $packages) {
    $p = $package
    Invoke-Step -Name ("install-" + $p.Name) -Plan ("winget install --id " + $p.Id) `
        -IsDone { Test-Command $p.Name } `
        -Action {
            if (-not (Test-Command "winget")) { throw "winget is missing; install App Installer from the Microsoft Store first." }
            Invoke-Native "winget" @("install", "--id", $p.Id, "--exact", "--silent", "--accept-package-agreements", "--accept-source-agreements")
            Update-SessionPath
        }
}
Invoke-Step -Name "install-python314" -Plan "winget install --id Python.Python.3.14" `
    -IsDone {
        if (-not (Test-Command "py")) { return $false }
        & py -3.14 -c "import sys" *> $null
        return ($LASTEXITCODE -eq 0)
    } `
    -Action {
        Invoke-Native "winget" @("install", "--id", "Python.Python.3.14", "--exact", "--silent", "--accept-package-agreements", "--accept-source-agreements")
        Update-SessionPath
    }

# 2. GitHub sign-in (browser; the owner approves the one-time device code) ---------------------------
Invoke-Step -Name "gh-login" -Plan "gh auth login --web --hostname github.com --git-protocol https (approve in the browser)" `
    -IsDone { Test-GhLoggedIn } `
    -Action {
        Invoke-Native "gh" @("auth", "login", "--web", "--hostname", "github.com", "--git-protocol", "https")
        Invoke-Native "gh" @("auth", "setup-git", "--hostname", "github.com")
    }

# 3. Code -------------------------------------------------------------------------------------------
Invoke-Step -Name "clone" -Plan ("gh repo clone {0} {1} -- --filter=blob:none" -f $Repository, $InstallRoot) `
    -IsDone { Test-GitRepo $InstallRoot } `
    -Action {
        if ((Test-Path -LiteralPath $InstallRoot) -and @(Get-ChildItem -LiteralPath $InstallRoot -Force).Count -gt 0) {
            throw "InstallRoot exists, is not empty and is not a git clone: $InstallRoot"
        }
        Invoke-Native "gh" @("repo", "clone", $Repository, $InstallRoot, "--", "--filter=blob:none")
    }
Invoke-Step -Name "venv" -Plan "py -3.14 -m venv .venv; pip install -e .[desktop]" `
    -IsDone {
        $py = Get-VenvPython
        if (-not (Test-Path -LiteralPath $py)) { return $false }
        & $py -c "import ai_orchestrator, PIL" *> $null
        return ($LASTEXITCODE -eq 0)
    } `
    -Action {
        $py = Get-VenvPython
        if (-not (Test-Path -LiteralPath $py)) { Invoke-Native "py" @("-3.14", "-m", "venv", (Join-Path $InstallRoot ".venv")) }
        Invoke-Native $py @("-m", "pip", "install", "--disable-pip-version-check", "-e", ($InstallRoot + "[desktop]"))
    }

# 4. Tailnet (never re-run "up" on a connected host) -------------------------------------------------
$loginPlan = "tailscale up (official login server)"
$approvePlan = "; approve the device in the browser"
if ($LoginServer) {
    $loginPlan = "tailscale up --login-server $LoginServer"
    $approvePlan = "; approve the device from a host already on that network"
}
Invoke-Step -Name "tailnet" -Plan ($loginPlan + $approvePlan) `
    -IsDone {
        if (-not (Test-TailscaleConnected)) { return $false }
        if ($LoginServer) {
            $prefs = & tailscale debug prefs 2>$null | Out-String
            $current = ""
            try { $current = ($prefs | ConvertFrom-Json).ControlURL } catch { $current = "" }
            if ($current -and ($current.TrimEnd("/") -ne $LoginServer.TrimEnd("/"))) {
                throw "This host is connected to $current. Moving it to $LoginServer is gate G4 and is not done by the installer (use scripts\Join-CielSpace.ps1 to move it, or -LoginServer official to keep it)."
            }
        }
        return $true
    } `
    -Action {
        $arguments = @("up")
        if ($LoginServer) { $arguments += @("--login-server", $LoginServer) }
        Invoke-Native "tailscale" $arguments
    }

# 5. Second Brain and machine bootstrap --------------------------------------------------------------
Invoke-Step -Name "second-brain" -Plan ("gh repo clone {0} {1}" -f $SecondBrainRepository, $SecondBrainPath) `
    -IsDone { Test-GitRepo $SecondBrainPath } `
    -Action { Invoke-Native "gh" @("repo", "clone", $SecondBrainRepository, $SecondBrainPath) }
Invoke-Step -Name "machine-bootstrap" -Plan "scripts\Initialize-AIMachine.ps1 -Profile default -ApproveMachineBootstrap" `
    -IsDone {
        $wrapper = Join-Path $InstallRoot "scripts\Invoke-AIController.ps1"
        if (-not (Test-Path -LiteralPath $wrapper)) { return $false }
        $out = & (Get-PsExe) -NoProfile -ExecutionPolicy Bypass -File $wrapper rules-sync check 2>$null | Out-String
        return ($LASTEXITCODE -eq 0 -and $out -match '"status":\s*"current"')
    } `
    -Action {
        $init = Join-Path $InstallRoot "scripts\Initialize-AIMachine.ps1"
        & (Get-PsExe) -NoProfile -ExecutionPolicy Bypass -File $init -Profile default -SecondBrainPath $SecondBrainPath `
            -ProjectRegistryPath $ProjectRegistryPath -ApproveMachineBootstrap
        if ($LASTEXITCODE -ne 0) { throw "Initialize-AIMachine.ps1 failed (exit $LASTEXITCODE)" }
    }

# 6. Ciel web pages (tailnet only, never public), startup entry and launch --------------------------
if (-not $SkipCiel) {
    foreach ($port in $ServePorts) {
        $servePort = $port
        Invoke-Step -Name ("serve-" + $servePort) -Plan ("tailscale serve --bg --{1}={0} http://127.0.0.1:{0} (tailnet only)" -f $servePort, $ServeKind) `
            -IsDone { Test-ServePort $servePort } `
            -Action { Invoke-Native "tailscale" @("serve", "--bg", ("--{1}={0}" -f $servePort, $ServeKind), ("http://127.0.0.1:{0}" -f $servePort)) }
    }
    Invoke-Step -Name "ciel-startup" -Plan "scripts\Set-AIWorkPetStartup.ps1 -Action Enable" `
        -IsDone {
            $startup = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
            return (Test-Path -LiteralPath (Join-Path $startup ([string][char]0x590F + [char]0x723E + ".lnk")))
        } `
        -Action {
            & (Get-PsExe) -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallRoot "scripts\Set-AIWorkPetStartup.ps1") -Action Enable
            if ($LASTEXITCODE -ne 0) { throw "Set-AIWorkPetStartup.ps1 failed (exit $LASTEXITCODE)" }
        }
    Invoke-Step -Name "ciel-launch" -Plan "wscript scripts\Show-AIWorkPet.vbs" `
        -IsDone {
            $code = Get-HttpStatus "http://127.0.0.1:$($ServePorts[0])/"
            return ($code -gt 0 -and $code -lt 500)
        } `
        -Action {
            Start-Process -FilePath (Join-Path $env:SystemRoot "System32\wscript.exe") `
                -ArgumentList ('"{0}"' -f (Join-Path $InstallRoot "scripts\Show-AIWorkPet.vbs"))
        }
}

# 7. Self-check (read-only) -------------------------------------------------------------------------
$checks = [ordered]@{}
if (-not $DryRun) {
    $state = Get-TailscaleState
    $peerCount = 0
    if ($null -ne $state -and $state.PSObject.Properties["Peer"] -and $null -ne $state.Peer) {
        $peerCount = @($state.Peer.PSObject.Properties).Count
    }
    $checks["tailnet_connected"] = ($null -ne $state -and $state.BackendState -eq "Running")
    $checks["tailnet_peers"] = $peerCount
    $checks["gh_logged_in"] = (Test-GhLoggedIn)
    $checks["clone"] = (Test-GitRepo $InstallRoot)
    if (-not $SkipCiel) {
        $webOk = $false
        for ($i = 0; $i -lt 20 -and -not $webOk; $i++) {
            $code = Get-HttpStatus "http://127.0.0.1:$($ServePorts[0])/"
            $webOk = ($code -gt 0 -and $code -lt 500)
            if (-not $webOk) { Start-Sleep -Seconds 3 }
        }
        $checks["ciel_web_responding"] = $webOk
        foreach ($port in $ServePorts) { $checks[("serve_" + $port)] = (Test-ServePort $port) }
    }
}

$summary = [pscustomobject]@{
    kind = "ai-orch-install/1"
    dry_run = [bool]$DryRun
    install_root = $InstallRoot
    login_server = $(if ($LoginServer) { $LoginServer } else { "official" })
    steps = $script:Results
    checks = $checks
}
if ($Json) {
    $summary | ConvertTo-Json -Depth 5
} else {
    Write-Host ""
    if ($DryRun) {
        Write-Host "Dry run only: nothing was changed."
    } elseif (($checks.Values | Where-Object { $_ -is [bool] -and -not $_ }).Count -eq 0) {
        Write-Host "Install complete. Next: sign in to Claude/Codex yourself, then send a test letter from Ciel to another host."
    } else {
        Write-Host "Install finished with failed checks:"
        $checks.GetEnumerator() | ForEach-Object { Write-Host ("  {0} = {1}" -f $_.Key, $_.Value) }
        exit 1
    }
}
