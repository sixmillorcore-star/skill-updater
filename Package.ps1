[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist')
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Build.ps1') | Out-Host
$binaryVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $PSScriptRoot 'SkillUpdater.exe')).ProductVersion
if ($binaryVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'The built application has an invalid release version.' }
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = $binaryVersion }
if ($binaryVersion -ne $Version) { throw "Package version $Version differs from the built application version $binaryVersion." }
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($outputRoot) | Out-Null
$staging = Join-Path $outputRoot ('staging-' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $staging 'SkillUpdater'
$archive = Join-Path $outputRoot ('SkillUpdater-v' + $Version + '-windows.zip')
[IO.Directory]::CreateDirectory($package) | Out-Null
try {
    $files = @('SkillUpdater.exe', 'Backend.ps1', 'Discovery.ps1', 'ClaudeSupport.ps1',
        'Install.ps1', 'Uninstall.ps1', 'Install.cmd', 'Uninstall.cmd',
        'settings.json', 'app-icon.ico', 'app-icon.png', 'Apply-AppUpdate.ps1')
    foreach ($file in $files) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $package $file)
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'languages') -Destination $package -Recurse
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'docs/QUICKSTART.txt') -Destination (Join-Path $package 'README.txt')
    $manifestFiles = [ordered]@{}
    foreach ($item in (Get-ChildItem -LiteralPath $package -File -Recurse | Sort-Object FullName)) {
        $relative = $item.FullName.Substring($package.Length + 1).Replace('\', '/')
        $manifestFiles[$relative] = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $manifest = [ordered]@{ schemaVersion = 1; version = $Version; files = $manifestFiles }
    [IO.File]::WriteAllText((Join-Path $package 'app-update-manifest.json'), ($manifest | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    # Explicit ZIP entry names keep releases identical on Windows PowerShell 5.1
    # and PowerShell 7; Compress-Archive can emit Windows path separators on 5.1.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archiveStream = [IO.File]::Open($archive, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $zip = $null
    try {
        $zip = New-Object IO.Compression.ZipArchive($archiveStream, [IO.Compression.ZipArchiveMode]::Create, $true)
        foreach ($item in (Get-ChildItem -LiteralPath $package -File -Recurse | Sort-Object FullName)) {
            $relative = $item.FullName.Substring($package.Length + 1).Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $item.FullName,
                ('SkillUpdater/' + $relative), [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    }
    finally {
        if ($zip) { $zip.Dispose() }
        $archiveStream.Dispose()
    }
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
