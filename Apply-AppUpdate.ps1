[CmdletBinding()]
param([string]$RequestPath, [switch]$LibraryOnly)
$ErrorActionPreference = 'Stop'

function Resolve-UpdateChild([string]$Path, [string]$Root) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Update path is outside its installation.' }
    return $full
}
function Assert-UpdatePath([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked update files or directories are not supported.' }
    }
}
function Assert-UpdateTree([string]$Path) {
    Assert-UpdatePath $Path
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($Path)
    while ($pending.Count -gt 0) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
            Assert-UpdatePath $item.FullName
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
}
function Write-UpdateJson($Value, [string]$Path) {
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Get-AppUpdateFiles([string]$PackageRoot, [string]$Version) {
    Assert-UpdateTree $PackageRoot
    $manifestPath = Join-Path $PackageRoot 'app-update-manifest.json'
    if ((Get-Item -LiteralPath $manifestPath).Length -gt 131072) { throw 'The update manifest is too large.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.version -cne $Version -or -not $manifest.files) { throw 'The update manifest is invalid.' }
    $allowed = @('SkillUpdater.exe','Backend.ps1','Discovery.ps1','ClaudeSupport.ps1','Apply-AppUpdate.ps1',
        'Install.ps1','Uninstall.ps1','Install.cmd','Uninstall.cmd','settings.json','app-icon.ico','app-icon.png','README.txt')
    $files = @{}
    $total = 0L
    foreach ($property in $manifest.files.PSObject.Properties) {
        $name = [string]$property.Name
        $hash = [string]$property.Value
        if ($allowed -cnotcontains $name -and $name -cnotmatch '^languages/[a-zA-Z0-9-]+\.json$') { throw ('Unsupported update file: ' + $name) }
        if ($hash -cnotmatch '^[a-f0-9]{64}$' -or $files.ContainsKey($name)) { throw 'Invalid or duplicate update checksum.' }
        $path = Resolve-UpdateChild (Join-Path $PackageRoot $name) $PackageRoot
        $item = Get-Item -LiteralPath $path
        if ($item.PSIsContainer) { throw 'An update file is a directory.' }
        $total += $item.Length
        if ($item.Length -gt 33554432 -or $total -gt 67108864) { throw 'The update package exceeds its size limit.' }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hash) { throw ('Update checksum failed: ' + $name) }
        $files[$name] = $path
    }
    if ($files.Count -gt 128) { throw 'The update contains too many files.' }
    foreach ($required in ($allowed + 'languages/en.json')) {
        if (-not $files.ContainsKey($required)) { throw ('Required update file is missing: ' + $required) }
    }
    $actual = @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -File -Force)
    if ($actual.Count -ne $files.Count + 1) { throw 'The update contains files outside its manifest.' }
    $files['app-update-manifest.json'] = $manifestPath
    return $files
}
function Set-AppUpdateFile([string]$Source, [string]$Destination) {
    $temp = $Destination + '.update-' + [guid]::NewGuid().ToString('N') + '.tmp'
    $previous = $Destination + '.previous-' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::Copy($Source, $temp, $false)
        if ([IO.File]::Exists($Destination)) { [IO.File]::Replace($temp, $Destination, $previous) }
        else { [IO.File]::Move($temp, $Destination) }
    }
    finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
        if ([IO.File]::Exists($previous)) { [IO.File]::Delete($previous) }
    }
}
function Install-AppRuntime([string]$InstallRoot, [string]$PackageRoot, [string]$Version, [string]$BackupRoot) {
    $files = Get-AppUpdateFiles $PackageRoot $Version
    Assert-UpdatePath $InstallRoot
    Assert-UpdatePath (Join-Path $InstallRoot 'languages')
    Assert-UpdatePath $BackupRoot
    [IO.Directory]::CreateDirectory($BackupRoot) | Out-Null
    $records = New-Object 'Collections.Generic.List[object]'
    # Back up and preflight every destination before changing any application file.
    foreach ($name in @($files.Keys | Sort-Object)) {
        if ($name -ceq 'settings.json') { continue }
        $destination = Resolve-UpdateChild (Join-Path $InstallRoot $name) $InstallRoot
        Assert-UpdatePath $destination
        $exists = [IO.File]::Exists($destination)
        $backup = Join-Path $BackupRoot $name
        if ($exists) {
            $probe = [IO.File]::Open($destination, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $probe.Dispose()
            [IO.Directory]::CreateDirectory((Split-Path -Parent $backup)) | Out-Null
            [IO.File]::Copy($destination, $backup, $false)
        }
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        $records.Add([pscustomobject]@{name=$name; source=$files[$name]; destination=$destination; backup=$backup; existed=$exists; changed=$false})
    }
    try {
        foreach ($record in $records) {
            $record.changed = $true
            Set-AppUpdateFile $record.source $record.destination
        }
    }
    catch {
        $originalError = $_.Exception.Message
        $rollbackErrors = New-Object 'Collections.Generic.List[string]'
        for ($index=$records.Count-1; $index -ge 0; $index--) {
            $record = $records[$index]
            if (-not $record.changed) { continue }
            try {
                if ($record.existed) { Set-AppUpdateFile $record.backup $record.destination }
                elseif ([IO.File]::Exists($record.destination)) { [IO.File]::Delete($record.destination) }
            }
            catch { $rollbackErrors.Add($record.name + ': ' + $_.Exception.Message) }
        }
        if ($rollbackErrors.Count) { throw ($originalError + ' Rollback needs attention: ' + ($rollbackErrors -join '; ') + '. Backup: ' + $BackupRoot) }
        throw ($originalError + ' The previous application files were restored.')
    }
    return $BackupRoot
}
function Assert-NoOtherApp([string]$Executable, [int]$OwnerId) {
    foreach ($app in @(Get-Process -Name SkillUpdater -ErrorAction SilentlyContinue)) {
        if ($app.Id -eq $OwnerId) { continue }
        try { $processPath = $app.MainModule.FileName }
        catch { if (-not $app.HasExited) { throw 'Another Skill Updater process could not be checked.' }; continue }
        if ([string]::Equals($processPath, $Executable, [StringComparison]::OrdinalIgnoreCase)) { throw 'Another Skill Updater window is open. Close it before updating.' }
    }
}

if ($LibraryOnly) { return }
$operationLock = $null
$applicationLock = $null
$installRoot = $null
$stage = $null
$backup = $null
$request = $null
$success = $false
$ownerExited = $false
$resultPath = $null
try {
    $requestFile = Get-Item -LiteralPath $RequestPath
    if ($requestFile.Length -gt 16384) { throw 'Invalid installer request.' }
    $request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $installRoot = [IO.Path]::GetFullPath([string]$request.installRoot).TrimEnd('\')
    $package = [IO.Path]::GetFullPath([string]$request.packageRoot).TrimEnd('\')
    $updatesRoot = Join-Path $installRoot 'data/app-updates'
    $package = Resolve-UpdateChild $package $updatesRoot
    $stage = Split-Path -Parent (Split-Path -Parent $package)
    $stageId = [guid]::Empty
    if (-not [guid]::TryParseExact((Split-Path -Leaf $stage), 'N', [ref]$stageId) -or
        (Split-Path -Leaf $package) -cne 'SkillUpdater' -or
        (Split-Path -Leaf (Split-Path -Parent $package)) -cne 'package' -or
        [IO.Path]::GetFullPath($RequestPath) -ine (Join-Path $stage 'install-request.json') -or
        [string]$request.version -cnotmatch '^\d+\.\d+\.\d+$') { throw 'Invalid installer paths or version.' }
    foreach ($path in @($installRoot, (Join-Path $installRoot 'data'), $updatesRoot, $stage, (Split-Path -Parent $package), $package)) { Assert-UpdatePath $path }
    $resultPath = Join-Path $installRoot 'data/app-update-result.json'
    Assert-UpdatePath $resultPath
    Assert-UpdatePath (Join-Path $installRoot 'data/app-update.lock')
    Assert-UpdatePath (Join-Path $installRoot 'data/operation.lock')
    $applicationLock = [IO.File]::Open((Join-Path $installRoot 'data/app-update.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $operationLock = [IO.File]::Open((Join-Path $installRoot 'data/operation.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $executable = Join-Path $installRoot 'SkillUpdater.exe'
    Assert-NoOtherApp $executable ([int]$request.ownerProcessId)
    Get-AppUpdateFiles $package ([string]$request.version) | Out-Null
    $writeProbe = Join-Path $installRoot ('.app-update-write-' + [guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllText($writeProbe, 'write') } finally { if (Test-Path -LiteralPath $writeProbe) { [IO.File]::Delete($writeProbe) } }
    Write-UpdateJson @{ready=$true} (Join-Path $stage 'installer-ready.json')
    $deadline = [datetime]::UtcNow.AddSeconds(60)
    while ([int]$request.ownerProcessId -gt 0) {
        if (Test-Path -LiteralPath (Join-Path $stage 'cancel-install')) { throw 'The application cancelled this installation.' }
        $owner = Get-Process -Id ([int]$request.ownerProcessId) -ErrorAction SilentlyContinue
        if (-not $owner) { break }
        if ($owner.StartTime.ToUniversalTime().Ticks.ToString() -cne [string]$request.ownerStartUtcTicks) { break }
        if ([datetime]::UtcNow -ge $deadline) { throw 'The application stayed open. No application files were changed.' }
        Start-Sleep -Milliseconds 100
    }
    if (Test-Path -LiteralPath (Join-Path $stage 'cancel-install')) { throw 'The application cancelled this installation.' }
    $ownerExited = $true
    Assert-NoOtherApp $executable 0
    $backup = Join-Path $stage 'backup'
    Install-AppRuntime $installRoot $package ([string]$request.version) $backup | Out-Null
    Write-UpdateJson @{status='success';version=[string]$request.version;message='Application updated successfully.';backupPath=$backup;timestampUtc=[datetime]::UtcNow.ToString('o')} $resultPath
    $success = $true
}
catch {
    if ($resultPath) {
        try { Write-UpdateJson @{status='failed';version=[string]$request.version;message=$_.Exception.Message;backupPath=$backup;timestampUtc=[datetime]::UtcNow.ToString('o')} $resultPath } catch { }
    }
}
finally {
    if ($operationLock) { $operationLock.Dispose() }
    if ($applicationLock) { $applicationLock.Dispose() }
}
if ($ownerExited -and -not $request.noRestart -and [IO.File]::Exists((Join-Path $installRoot 'SkillUpdater.exe'))) {
    try { Start-Process -FilePath (Join-Path $installRoot 'SkillUpdater.exe') -WorkingDirectory $installRoot | Out-Null }
    catch { exit 2 }
}
if (-not $success) { exit 1 }
