# ai-orch-install

Installer for a private AI Orchestrator host. The script is safe to read: it holds no secrets, and every
sign-in (GitHub, Tailscale, Claude/Codex) is approved by the owner in the browser. Without access to the
private repositories it stops at the clone step.

```powershell
irm https://raw.githubusercontent.com/kevin198776/ai-orch-install/main/Install-AIOrch.ps1 | iex
```

With parameters (for example a dry run that changes nothing):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/kevin198776/ai-orch-install/main/Install-AIOrch.ps1))) -DryRun
```

Windows 10/11 with winget. Re-running is safe: finished steps are skipped.

SHA-256 of Install-AIOrch.ps1: `a0d35a801b609f432a0f01b590bb02a8fc7f30cf6f0c4afff60b942d2a9623fc`
