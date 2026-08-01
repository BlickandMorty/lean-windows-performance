$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'src\Invoke-LeanPerformance.ps1'
$tokens = $null; $errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join '; ') }
$config = Get-Content -LiteralPath (Join-Path $root 'config\performance.example.json') -Raw | ConvertFrom-Json
if (@($config.optionalDisableServices).Count -ne 0) { throw 'Example service disable list must be empty.' }
if (@($config.optionalDisableScheduledTasks).Count -ne 0) { throw 'Example task disable list must be empty.' }
foreach ($required in @('Dell', 'Intel', 'NVIDIA', 'Windows Update', 'Qobuz')) {
    if ($config.protectedNamePatterns -notcontains $required) { throw "Missing protected pattern: $required" }
}
Write-Host 'Static checks passed.'

