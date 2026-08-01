# Lean Windows Performance

An audit-first Windows performance toolkit focused on measurable cleanup, healthy power behavior, low-noise startup, and vendor-safe maintenance.

This is the portable successor to a large XPS LeanPerformance V2 system. The original grew into a full operating regimen: audits, user tweaks, protected administrator pruning, daily/weekly/startup maintenance, Windows health checks, Dell update verification, gaming profiles, hidden tasks, baselines, reports, and canonical backups. This repository keeps the conservative performance core; scheduling and gaming are independent companion repositories.

## Design promises

- Audit is the default and changes nothing.
- No blanket “debloat everything” operation.
- No service or task is disabled unless explicitly named in configuration.
- Dell, Intel, NVIDIA, Microsoft Store, Windows Update, audio, Bluetooth, accessibility, security, networking, Xbox/gaming, Steam, Riot, and VPN-related names are protected by default.
- User-profile paths are discovered from environment variables, never hardcoded.
- Every administrator change gets a baseline that can be restored.
- Existing lockdown protections are out of scope and never modified.

## Modes

```powershell
# Read-only inventory and recommendations
.\src\Invoke-LeanPerformance.ps1 -Mode Audit

# Conservative per-user UI and Game Mode settings
.\src\Invoke-LeanPerformance.ps1 -Mode ApplyUser -Apply

# Explicit admin changes from config, after a baseline is captured
.\src\Invoke-LeanPerformance.ps1 -Mode ApplyAdmin -Apply

# Safe recurring cleanup
.\src\Invoke-LeanPerformance.ps1 -Mode DailyMaintenance -Apply
.\src\Invoke-LeanPerformance.ps1 -Mode WeeklyMaintenance -Apply

# Read-only DISM/SFC checks or an explicit repair pass
.\src\Invoke-LeanPerformance.ps1 -Mode Verify
.\src\Invoke-LeanPerformance.ps1 -Mode RepairWindowsHealth -Apply

# Restore a recorded service/task/power baseline
.\src\Invoke-LeanPerformance.ps1 -Mode RestoreBaseline -BaselinePath C:\path\baseline.json -Apply
```

Use `-ConfigPath .\config\performance.example.json` to override defaults.

## What “performance” means here

The project does not promise magical benchmark gains. It targets recurring, observable sources of drag:

- stale temporary data and crash dumps;
- bloated Delivery Optimization cache;
- missed SSD retrim/component maintenance;
- unintended startup entries;
- unhealthy devices or pending restarts;
- power-plan drift;
- explicitly selected unused services/tasks;
- Windows component-store corruption.

Reports retain the before/after evidence so improvements can be evaluated instead of guessed.

## Companion projects

- `windows-maintenance-orchestrator` installs hidden scheduled triggers.
- `adaptive-gaming-power` handles AC/battery and per-game GPU routing.
- `windows-cleanup-auditor` handles orphaned game/app data with a separate approval plan.
- `windows-backup-integrity` publishes canonical archives and manifests.

## License

MIT.

