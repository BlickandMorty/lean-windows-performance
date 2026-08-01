[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Audit', 'ApplyUser', 'ApplyAdmin', 'DailyMaintenance', 'WeeklyMaintenance', 'Verify', 'RepairWindowsHealth', 'RestoreBaseline')]
    [string]$Mode = 'Audit',
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\performance.example.json'),
    [string]$BaselinePath,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-IsAdministrator)) { throw 'This mode requires an elevated PowerShell session.' }
}

function Expand-ConfigPath {
    param([string]$Value)
    [Environment]::ExpandEnvironmentVariables($Value)
}

function Read-Configuration {
    $resolved = (Resolve-Path -LiteralPath $ConfigPath).Path
    $value = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
    if ($value.schemaVersion -ne 1) { throw "Unsupported configuration schema: $($value.schemaVersion)" }
    $value
}

function Test-ProtectedName {
    param([string]$Text, $Config)
    foreach ($pattern in @($Config.protectedNamePatterns)) {
        if ($Text -match [regex]::Escape([string]$pattern)) { return $true }
    }
    return $false
}

function Write-JsonFile {
    param([string]$Path, $Value)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

function Invoke-ExternalText {
    param([string]$FilePath, [string[]]$Arguments)
    $output = & $FilePath @Arguments 2>&1 | Out-String
    [pscustomobject]@{ command = "$FilePath $($Arguments -join ' ')"; exitCode = $LASTEXITCODE; output = $output.Trim() }
}

function Get-SystemAudit {
    $systemDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem
    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    $pnpProblems = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object Status -ne 'OK' | Select-Object Class, FriendlyName, InstanceId, Status)
    $startup = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Select-Object Name, Command, Location, User)
    $activePower = (& powercfg.exe /GetActiveScheme 2>&1 | Out-String).Trim()
    [ordered]@{
        generatedAt = (Get-Date).ToString('o')
        computerName = $env:COMPUTERNAME
        user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        administrator = Test-IsAdministrator
        manufacturer = $computer.Manufacturer
        model = $computer.Model
        memoryGiB = [Math]::Round($computer.TotalPhysicalMemory / 1GB, 1)
        windows = $os.Caption
        build = $os.BuildNumber
        lastBoot = $os.LastBootUpTime
        systemDriveFreeGiB = [Math]::Round($systemDrive.FreeSpace / 1GB, 1)
        systemDriveSizeGiB = [Math]::Round($systemDrive.Size / 1GB, 1)
        batteryEstimatedCharge = if ($battery) { $battery.EstimatedChargeRemaining } else { $null }
        activePowerScheme = $activePower
        startupCommands = $startup
        pnpProblems = $pnpProblems
        pendingRebootSignals = [ordered]@{
            componentBasedServicing = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
            windowsUpdate = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
            pendingFileRename = $null -ne (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
        }
    }
}

function Save-Baseline {
    param($Config, [string]$ReportDirectory)

    $services = foreach ($name in @($Config.optionalDisableServices)) {
        $service = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f ([string]$name).Replace("'", "''")) -ErrorAction SilentlyContinue
        if ($service) { [pscustomobject]@{ name = $service.Name; startMode = $service.StartMode; state = $service.State } }
    }
    $tasks = foreach ($fullName in @($Config.optionalDisableScheduledTasks)) {
        $text = [string]$fullName
        $taskName = Split-Path $text -Leaf
        $taskPath = $text.Substring(0, $text.Length - $taskName.Length)
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
        if ($task) { [pscustomobject]@{ taskName = $task.TaskName; taskPath = $task.TaskPath; state = [string]$task.State; enabled = [bool]$task.Settings.Enabled } }
    }
    $baseline = [ordered]@{
        schemaVersion = 1
        createdAt = (Get-Date).ToString('o')
        activePowerScheme = (& powercfg.exe /GetActiveScheme 2>&1 | Out-String).Trim()
        hibernateEnabled = Test-Path (Join-Path $env:SystemDrive 'hiberfil.sys')
        fastStartup = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
        services = @($services)
        tasks = @($tasks)
    }
    $path = Join-Path $ReportDirectory 'baseline.json'
    Write-JsonFile -Path $path -Value $baseline
    $path
}

function Remove-OldChildren {
    param([string]$Root, [int]$OlderThanDays)
    if (-not (Test-Path -LiteralPath $Root)) { return [pscustomobject]@{ root = $Root; removed = 0; errors = 0 } }
    $resolved = (Resolve-Path -LiteralPath $Root).Path
    $allowedRoots = @($env:TEMP, (Join-Path $env:LOCALAPPDATA 'Temp'), (Join-Path $env:LOCALAPPDATA 'CrashDumps')) | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
    if ($resolved.TrimEnd('\') -notin $allowedRoots) { throw "Cleanup root is not allowlisted: $resolved" }
    $cutoff = (Get-Date).AddDays(-[Math]::Max(1, $OlderThanDays))
    $removed = 0; $errors = 0
    Get-ChildItem -LiteralPath $resolved -Force -ErrorAction SilentlyContinue | Where-Object LastWriteTime -lt $cutoff | ForEach-Object {
        try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop; $removed++ } catch { $errors++ }
    }
    [pscustomobject]@{ root = $resolved; removed = $removed; errors = $errors }
}

function Apply-UserSettings {
    $changes = @(
        @{ path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; name = 'TaskbarAnimations'; value = 0 },
        @{ path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; name = 'EnableTransparency'; value = 0 },
        @{ path = 'HKCU:\Software\Microsoft\GameBar'; name = 'AutoGameModeEnabled'; value = 1 },
        @{ path = 'HKCU:\System\GameConfigStore'; name = 'GameDVR_Enabled'; value = 0 }
    )
    foreach ($change in $changes) {
        New-Item -Path $change.path -Force | Out-Null
        New-ItemProperty -Path $change.path -Name $change.name -Value $change.value -PropertyType DWord -Force | Out-Null
    }
}

function Apply-ExplicitAdminChanges {
    param($Config)
    foreach ($name in @($Config.optionalDisableServices)) {
        $service = Get-Service -Name ([string]$name) -ErrorAction Stop
        if (Test-ProtectedName "$($service.Name) $($service.DisplayName)" $Config) { throw "Protected service refused: $($service.Name)" }
        Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
        Set-Service -Name $service.Name -StartupType Disabled
    }
    foreach ($fullName in @($Config.optionalDisableScheduledTasks)) {
        if (Test-ProtectedName ([string]$fullName) $Config) { throw "Protected scheduled task refused: $fullName" }
        $taskName = Split-Path ([string]$fullName) -Leaf
        $taskPath = ([string]$fullName).Substring(0, ([string]$fullName).Length - $taskName.Length)
        Disable-ScheduledTask -TaskName $taskName -TaskPath $taskPath | Out-Null
    }
    if ([bool]$Config.power.disableHibernate) { & powercfg.exe /hibernate off | Out-Null }
    if ([bool]$Config.power.disableFastStartup) {
        New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0 -PropertyType DWord -Force | Out-Null
    }
}

function Restore-Baseline {
    param([string]$Path)
    if (-not $Path) { throw '-BaselinePath is required for RestoreBaseline.' }
    $baseline = Get-Content -LiteralPath (Resolve-Path -LiteralPath $Path) -Raw | ConvertFrom-Json
    if ($baseline.schemaVersion -ne 1) { throw 'Unsupported baseline schema.' }
    foreach ($service in @($baseline.services)) {
        $startup = switch ([string]$service.startMode) { 'Auto' { 'Automatic' } 'Manual' { 'Manual' } 'Disabled' { 'Disabled' } default { 'Manual' } }
        Set-Service -Name ([string]$service.name) -StartupType $startup
        if ($service.state -eq 'Running') { Start-Service -Name ([string]$service.name) -ErrorAction SilentlyContinue }
    }
    foreach ($task in @($baseline.tasks)) {
        if ([bool]$task.enabled) { Enable-ScheduledTask -TaskName $task.taskName -TaskPath $task.taskPath | Out-Null }
        else { Disable-ScheduledTask -TaskName $task.taskName -TaskPath $task.taskPath | Out-Null }
    }
    if ([int]$baseline.fastStartup -in @(0, 1)) {
        New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value ([int]$baseline.fastStartup) -PropertyType DWord -Force | Out-Null
    }
}

$config = Read-Configuration
$reportRoot = Expand-ConfigPath ([string]$config.reportRoot)
$runRoot = Join-Path $reportRoot ("{0}-{1}" -f $Mode, (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$result = [ordered]@{ mode = $Mode; startedAt = (Get-Date).ToString('o'); apply = [bool]$Apply; actions = @(); audit = Get-SystemAudit }

if (-not $Apply -and $Mode -ne 'Audit' -and $Mode -ne 'Verify') {
    $result.preview = 'No changes made. Add -Apply to execute this mode.'
    Write-JsonFile -Path (Join-Path $runRoot 'result.json') -Value $result
    $result | ConvertTo-Json -Depth 8
    return
}

switch ($Mode) {
    'Audit' { $result.actions += 'Read-only inventory completed.' }
    'ApplyUser' {
        if ($PSCmdlet.ShouldProcess('Current user profile', 'Apply conservative responsiveness and Game Mode settings')) { Apply-UserSettings; $result.actions += 'Applied user settings.' }
    }
    'ApplyAdmin' {
        Assert-Administrator
        $result.baselinePath = Save-Baseline -Config $config -ReportDirectory $runRoot
        if ($PSCmdlet.ShouldProcess('Explicit configuration entries', 'Apply administrator changes')) { Apply-ExplicitAdminChanges -Config $config; $result.actions += 'Applied explicit administrator configuration.' }
    }
    'DailyMaintenance' {
        $result.actions += Remove-OldChildren -Root $env:TEMP -OlderThanDays ([int]$config.cleanup.temporaryFilesOlderThanDays)
        if ([bool]$config.cleanup.clearCrashDumps) { $result.actions += Remove-OldChildren -Root (Join-Path $env:LOCALAPPDATA 'CrashDumps') -OlderThanDays 2 }
        Clear-DnsClientCache -ErrorAction SilentlyContinue
    }
    'WeeklyMaintenance' {
        Assert-Administrator
        $result.actions += Remove-OldChildren -Root $env:TEMP -OlderThanDays ([int]$config.cleanup.temporaryFilesOlderThanDays)
        if ([bool]$config.cleanup.clearDeliveryOptimizationCacheWeekly -and (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue)) {
            Delete-DeliveryOptimizationCache -Force -ErrorAction Continue
            $result.actions += 'Delivery Optimization cache cleanup requested.'
        }
        $driveLetter = $env:SystemDrive.TrimEnd(':')
        Optimize-Volume -DriveLetter $driveLetter -ReTrim -ErrorAction Continue | Out-String | ForEach-Object { $result.actions += $_.Trim() }
        $result.actions += Invoke-ExternalText dism.exe @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    }
    'Verify' {
        $result.actions += Invoke-ExternalText dism.exe @('/Online', '/Cleanup-Image', '/CheckHealth')
        $result.actions += Invoke-ExternalText sfc.exe @('/verifyonly')
    }
    'RepairWindowsHealth' {
        Assert-Administrator
        $result.actions += Invoke-ExternalText dism.exe @('/Online', '/Cleanup-Image', '/RestoreHealth')
        $result.actions += Invoke-ExternalText sfc.exe @('/scannow')
    }
    'RestoreBaseline' {
        Assert-Administrator
        if ($PSCmdlet.ShouldProcess($BaselinePath, 'Restore recorded service/task settings')) { Restore-Baseline -Path $BaselinePath; $result.actions += 'Baseline restored.' }
    }
}

$result.completedAt = (Get-Date).ToString('o')
$result.after = Get-SystemAudit
Write-JsonFile -Path (Join-Path $runRoot 'result.json') -Value $result
$result | ConvertTo-Json -Depth 10

