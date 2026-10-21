[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = '1.0.0',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist')
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Build.ps1') | Out-Host
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($outputRoot) | Out-Null
$staging = Join-Path $outputRoot ('staging-' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $staging 'SkillUpdater'
$archive = Join-Path $outputRoot ('SkillUpdater-v' + $Version + '-windows.zip')
[IO.Directory]::CreateDirectory($package) | Out-Null
try {
    $files = @('SkillUpdater.exe', 'Backend.ps1', 'Discovery.ps1', 'ClaudeSupport.ps1',
        'Install.ps1', 'Uninstall.ps1', 'Install.cmd', 'Uninstall.cmd',
        'settings.json', 'app-icon.ico', 'app-icon.png')
    foreach ($file in $files) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $package $file)
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'languages') -Destination $package -Recurse
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'docs/QUICKSTART.txt') -Destination (Join-Path $package 'README.txt')
    Compress-Archive -LiteralPath $package -DestinationPath $archive -Force
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $outputRoot 'SHA256SUMS.txt'),
        ($hash + '  ' + [IO.Path]::GetFileName($archive) + [Environment]::NewLine),
        (New-Object Text.UTF8Encoding($false)))
    Write-Output $archive
}
finally {
    $resolvedStaging = [IO.Path]::GetFullPath($staging)
    if (-not $resolvedStaging.StartsWith(($outputRoot.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The temporary package path escaped its output directory.'
    }
    if (Test-Path -LiteralPath $resolvedStaging) { Remove-Item -LiteralPath $resolvedStaging -Recurse -Force }
}
