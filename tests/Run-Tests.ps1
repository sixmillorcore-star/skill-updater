[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$powershell = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
if (-not (Test-Path -LiteralPath $powershell)) { throw 'These tests require Windows PowerShell 5.1 on Windows.' }
$suites = @('Backend.Tests.ps1', 'Discovery.Tests.ps1', 'ClaudeSupport.Tests.ps1', 'Backend.Integration.Tests.ps1', 'LocaleSupport.Tests.ps1')
foreach ($suite in $suites) {
    Write-Output ("Running " + $suite)
    & $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $suite)
    if ($LASTEXITCODE -ne 0) { throw ("Failed: " + $suite + " (exit " + $LASTEXITCODE + ")") }
}
Write-Output 'All five isolated test suites passed.'
