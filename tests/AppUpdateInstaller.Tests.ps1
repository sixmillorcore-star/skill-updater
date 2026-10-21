$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot
$helper = Join-Path $sourceRoot 'Apply-AppUpdate.ps1'
. $helper -LibraryOnly
$script:Assertions = 0
function Assert-UpdateTest([bool]$Condition, [string]$Message) {
    $script:Assertions++
    if (-not $Condition) { throw ('Assertion failed: ' + $Message) }
}
function Assert-UpdateThrows([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-UpdateTest $threw $Message
}
$artifacts = Join-Path $PSScriptRoot '.artifacts/app-update-installer'
[IO.Directory]::CreateDirectory($artifacts) | Out-Null
function New-UpdateFixture {
    $root = Join-Path $artifacts ([guid]::NewGuid().ToString('N'))
    $stage = Join-Path $root ('data/app-updates/' + [guid]::NewGuid().ToString('N'))
    $package = Join-Path $stage 'package/SkillUpdater'
    [IO.Directory]::CreateDirectory((Join-Path $package 'languages')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $root 'languages')) | Out-Null
    $names = @('SkillUpdater.exe','Backend.ps1','Discovery.ps1','ClaudeSupport.ps1','Apply-AppUpdate.ps1',
        'Install.ps1','Uninstall.ps1','Install.cmd','Uninstall.cmd','settings.json','app-icon.ico','app-icon.png','README.txt','languages/en.json')
    $hashes = [ordered]@{}
    foreach ($name in $names) {
        [IO.File]::WriteAllText((Join-Path $package $name), ('new-' + $name))
        [IO.File]::WriteAllText((Join-Path $root $name), ('old-' + $name))
        $hashes[$name] = (Get-FileHash -LiteralPath (Join-Path $package $name) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $manifest = @{schemaVersion=1;version='1.1.0';files=$hashes}
    Write-UpdateJson $manifest (Join-Path $package 'app-update-manifest.json')
    [IO.File]::WriteAllText((Join-Path $root 'install-state.json'), 'personal-install-state')
    [IO.File]::WriteAllText((Join-Path $root 'data/ui-preferences.json'), 'personal-ui-preferences')
    return [pscustomobject]@{root=$root;stage=$stage;package=$package;backup=(Join-Path $stage 'backup');manifest=$manifest}
}
function Save-UpdateRequest($Fixture, [int]$OwnerId=0, [string]$OwnerTicks='0') {
    $path = Join-Path $Fixture.stage 'install-request.json'
    Write-UpdateJson @{installRoot=$Fixture.root;packageRoot=$Fixture.package;version='1.1.0';ownerProcessId=$OwnerId;ownerStartUtcTicks=$OwnerTicks;noRestart=$true} $path
    return $path
}
function Start-TestInstaller([string]$Request) {
    $exe = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$exe
    $start.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $helper + '" -RequestPath "' + $Request + '"'
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    return [Diagnostics.Process]::Start($start)
}

$fixture = New-UpdateFixture
Install-AppRuntime $fixture.root $fixture.package '1.1.0' $fixture.backup | Out-Null
Assert-UpdateTest ((Get-Content -LiteralPath (Join-Path $fixture.root 'SkillUpdater.exe') -Raw) -ceq 'new-SkillUpdater.exe') 'updates executable'
Assert-UpdateTest ((Get-Content -LiteralPath (Join-Path $fixture.root 'languages/en.json') -Raw) -ceq 'new-languages/en.json') 'updates language pack'
Assert-UpdateTest ((Get-Content -LiteralPath (Join-Path $fixture.root 'settings.json') -Raw) -ceq 'old-settings.json') 'preserves personal settings'
Assert-UpdateTest ((Get-Content -LiteralPath (Join-Path $fixture.root 'install-state.json') -Raw) -ceq 'personal-install-state') 'preserves installation state'
Assert-UpdateTest ((Get-Content -LiteralPath (Join-Path $fixture.root 'data/ui-preferences.json') -Raw) -ceq 'personal-ui-preferences') 'preserves preferences'
Assert-UpdateTest ((Get-Content -LiteralPath (Join-Path $fixture.backup 'SkillUpdater.exe') -Raw) -ceq 'old-SkillUpdater.exe') 'retains backup'
Assert-UpdateTest (-not (Test-Path -LiteralPath (Join-Path $fixture.backup 'settings.json'))) 'personal settings are excluded from replacement and backup'

$fixture = New-UpdateFixture
[IO.File]::AppendAllText((Join-Path $fixture.package 'SkillUpdater.exe'), 'corrupt')
Assert-UpdateThrows { Install-AppRuntime $fixture.root $fixture.package '1.1.0' $fixture.backup } 'rejects corrupt package'
Assert-UpdateTest ((Get-Content -LiteralPath (Join-Path $fixture.root 'SkillUpdater.exe') -Raw) -ceq 'old-SkillUpdater.exe') 'checksum failure leaves application unchanged'

$fixture = New-UpdateFixture
$originalSet = ${function:Set-AppUpdateFile}
$script:SetCount = 0
function Set-AppUpdateFile([string]$Source, [string]$Destination) {
    $script:SetCount++
    if ($script:SetCount -eq 3) { throw 'Injected disk-write failure.' }
    & $originalSet $Source $Destination
}
try { Assert-UpdateThrows { Install-AppRuntime $fixture.root $fixture.package '1.1.0' $fixture.backup } 'partial write failure is reported' }
finally { Set-Item -Path function:Set-AppUpdateFile -Value $originalSet }
foreach ($name in $fixture.manifest.files.Keys) {
    Assert-UpdateTest ((Get-Content -LiteralPath (Join-Path $fixture.root $name) -Raw) -ceq ('old-' + $name)) ('rollback restores ' + $name)
}
Assert-UpdateTest (-not (Test-Path -LiteralPath (Join-Path $fixture.root 'app-update-manifest.json'))) 'rollback removes new-only files'

$fixture = New-UpdateFixture
$lock = [IO.File]::Open((Join-Path $fixture.root 'SkillUpdater.exe'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
try { Assert-UpdateThrows { Install-AppRuntime $fixture.root $fixture.package '1.1.0' $fixture.backup } 'locked executable blocks replacement' }
finally { $lock.Dispose() }
Assert-UpdateTest ((Get-Content -LiteralPath (Join-Path $fixture.root 'Backend.ps1') -Raw) -ceq 'old-Backend.ps1') 'lock preflight fails before changes'

$fixture = New-UpdateFixture
[IO.File]::WriteAllText((Join-Path $fixture.package 'extra.txt'), 'extra')
Assert-UpdateThrows { Get-AppUpdateFiles $fixture.package '1.1.0' } 'rejects unmanifested file'
$fixture = New-UpdateFixture
$fixture.manifest.files['../outside.txt'] = ('0' * 64)
Write-UpdateJson $fixture.manifest (Join-Path $fixture.package 'app-update-manifest.json')
Assert-UpdateThrows { Get-AppUpdateFiles $fixture.package '1.1.0' } 'rejects traversal manifest entry'
$fixture = New-UpdateFixture
Assert-UpdateThrows { Get-AppUpdateFiles $fixture.package '9.0.0' } 'rejects mismatched release version'

$fixture = New-UpdateFixture
$process = Start-TestInstaller (Save-UpdateRequest $fixture)
try {
    Assert-UpdateTest ($process.WaitForExit(15000)) 'helper exits after successful installation'
    Assert-UpdateTest ($process.ExitCode -eq 0) 'helper reports successful exit'
}
finally { $process.Dispose() }
$result = Get-Content -LiteralPath (Join-Path $fixture.root 'data/app-update-result.json') -Raw | ConvertFrom-Json
Assert-UpdateTest ($result.status -ceq 'success' -and $result.version -ceq '1.1.0') 'helper writes success marker'
$probe = [IO.File]::Open((Join-Path $fixture.root 'data/app-update.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$probe.Dispose()
Assert-UpdateTest $true 'helper releases application lock'

$fixture = New-UpdateFixture
$lock = [IO.File]::Open((Join-Path $fixture.root 'data/operation.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $process = Start-TestInstaller (Save-UpdateRequest $fixture)
    try {
        Assert-UpdateTest ($process.WaitForExit(15000)) 'busy-backend helper exits'
        Assert-UpdateTest ($process.ExitCode -eq 1) 'busy backend blocks helper'
    }
    finally { $process.Dispose() }
}
finally { $lock.Dispose() }
Assert-UpdateTest (-not (Test-Path -LiteralPath (Join-Path $fixture.stage 'installer-ready.json'))) 'busy backend prevents ready handshake'
Assert-UpdateTest ((Get-Content -LiteralPath (Join-Path $fixture.root 'SkillUpdater.exe') -Raw) -ceq 'old-SkillUpdater.exe') 'busy backend leaves executable unchanged'

$fixture = New-UpdateFixture
$ownerStart = New-Object Diagnostics.ProcessStartInfo
$ownerStart.FileName=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
$ownerStart.Arguments='-NoLogo -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 3"'
$ownerStart.UseShellExecute=$false; $ownerStart.CreateNoWindow=$true
$owner = [Diagnostics.Process]::Start($ownerStart)
try {
    $request = Save-UpdateRequest $fixture $owner.Id ($owner.StartTime.ToUniversalTime().Ticks.ToString())
    $process = Start-TestInstaller $request
    try {
        $deadline = [datetime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath (Join-Path $fixture.stage 'installer-ready.json')) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
        Assert-UpdateTest (Test-Path -LiteralPath (Join-Path $fixture.stage 'installer-ready.json')) 'helper signals ready before owner exit'
        Assert-UpdateTest (-not $owner.HasExited) 'owner is still running after ready signal'
        Assert-UpdateTest ((Get-Content -LiteralPath (Join-Path $fixture.root 'SkillUpdater.exe') -Raw) -ceq 'old-SkillUpdater.exe') 'helper never replaces running owner files'
        Assert-UpdateTest ($process.WaitForExit(15000)) 'helper finishes after owner exits naturally'
        Assert-UpdateTest ($process.ExitCode -eq 0) 'owner handoff succeeds'
    }
    finally { $process.Dispose() }
}
finally { $owner.Dispose() }

$fixture = New-UpdateFixture
$lock = [IO.File]::Open((Join-Path $fixture.root 'data/app-update.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $process = Start-TestInstaller (Save-UpdateRequest $fixture)
    try {
        Assert-UpdateTest ($process.WaitForExit(15000)) 'concurrent installer exits'
        Assert-UpdateTest ($process.ExitCode -eq 1) 'application lock blocks concurrent installer'
    }
    finally { $process.Dispose() }
}
finally { $lock.Dispose() }
Assert-UpdateTest (-not (Test-Path -LiteralPath (Join-Path $fixture.stage 'installer-ready.json'))) 'concurrent install cannot signal ready'
Assert-UpdateTest ((Get-Content -LiteralPath (Join-Path $fixture.root 'SkillUpdater.exe') -Raw) -ceq 'old-SkillUpdater.exe') 'concurrent install leaves application unchanged'

$fixture = New-UpdateFixture
[IO.File]::WriteAllText((Join-Path $fixture.stage 'cancel-install'), 'cancel')
$process = Start-TestInstaller (Save-UpdateRequest $fixture)
try {
    Assert-UpdateTest ($process.WaitForExit(15000)) 'cancelled installer exits'
    Assert-UpdateTest ($process.ExitCode -eq 1) 'cancellation reports failure'
}
finally { $process.Dispose() }
Assert-UpdateTest ((Get-Content -LiteralPath (Join-Path $fixture.root 'SkillUpdater.exe') -Raw) -ceq 'old-SkillUpdater.exe') 'cancelled handoff leaves application unchanged'

$types = Add-Type -Path (Join-Path $sourceRoot 'AppUpdateInstaller.cs') -ReferencedAssemblies System.dll,System.Core.dll,System.Web.Extensions.dll -PassThru -WarningAction SilentlyContinue
$installerType = @($types | Where-Object FullName -eq 'CodexSkillUpdater.AppUpdateInstaller')[0]
$flags = [Reflection.BindingFlags]'Static,NonPublic'
$isInstalling = $installerType.GetMethod('IsInstalling', $flags)
$launch = $installerType.GetMethod('Launch', $flags)
$fixture = New-UpdateFixture
Assert-UpdateTest (-not $isInstalling.Invoke($null, @([string]$fixture.root))) 'C# startup guard permits idle installation'
$lock = [IO.File]::Open((Join-Path $fixture.root 'data/app-update.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try { Assert-UpdateTest ($isInstalling.Invoke($null, @([string]$fixture.root))) 'C# startup guard rejects active installer' }
finally { $lock.Dispose() }
Assert-UpdateThrows { $launch.Invoke($null, @([string]$fixture.root, [string]$artifacts, '1.1.0')) } 'C# rejects prepared package outside app update stage'
Assert-UpdateThrows { $launch.Invoke($null, @([string]$fixture.root, [string]$fixture.package, 'invalid')) } 'C# rejects invalid version before helper launch'
Write-Output ('AppUpdateInstaller: ' + $script:Assertions + ' assertions passed.')
