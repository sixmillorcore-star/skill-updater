$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../ClaudeSupport.ps1')
$fixture=Join-Path (Join-Path $PSScriptRoot '.artifacts') ('claude-support-tests-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
$originalConfigEnv=$env:CLAUDE_CONFIG_DIR;$originalCacheEnv=$env:CLAUDE_CODE_PLUGIN_CACHE_DIR
$env:CLAUDE_CONFIG_DIR=$null;$env:CLAUDE_CODE_PLUGIN_CACHE_DIR=$null
$results=New-Object 'Collections.Generic.List[object]'
function Assert-Csu($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Save-FixtureJson($Value,[string]$Path) { [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null; [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding($false))) }
function Write-SkillFixture([string]$Root,[string]$Content) { [IO.Directory]::CreateDirectory((Join-Path $Root 'skills/example')) | Out-Null; [IO.File]::WriteAllText((Join-Path $Root 'skills/example/SKILL.md'),$Content) }
function Test-Csu([string]$Name,[scriptblock]$Body) { try { & $Body; $results.Add([pscustomobject]@{name=$Name;passed=$true;error=$null}) } catch { $results.Add([pscustomobject]@{name=$Name;passed=$false;error=$_.Exception.Message}) } }
$homeFixture=Join-Path $fixture 'user';$configDir=Join-Path $homeFixture '.claude';$pluginRoot=Join-Path $configDir 'plugins'
$config=[pscustomobject]@{userHome=$homeFixture;claudeConfigDir=$configDir}
$originalResolver=(Get-Item Function:\Resolve-ClaudeCli).ScriptBlock
Set-Item Function:\Resolve-ClaudeCli -Value {param($Config) return $null}
try {
    Test-Csu 'Absent Claude is detected without creating folders' {
        $inventory=Get-ClaudePluginInventory -Config $config -SkipCli
        Assert-Csu (-not $inventory.detected -and $inventory.plugins.Count -eq 0 -and $inventory.errors.Count -eq 0) 'Unexpected absent-provider result.'
        Assert-Csu (-not (Test-Path -LiteralPath $configDir)) 'Discovery created config folder.'
    }
    $project=Join-Path $fixture 'Project One';[IO.Directory]::CreateDirectory($project)|Out-Null
    $old=Join-Path $pluginRoot 'cache/official/example/1.0.0';Write-SkillFixture $old 'old skill'
    $projectInstall=Join-Path $pluginRoot 'cache/official/example/1.1.0';Write-SkillFixture $projectInstall 'project skill'
    $registry=[ordered]@{version=2;plugins=[ordered]@{'example@official'=@([ordered]@{scope='user';installPath=$old;version='1.0.0'},[ordered]@{scope='project';projectPath=$project;installPath=$projectInstall;version='1.1.0'})}}
    Save-FixtureJson $registry (Join-Path $pluginRoot 'installed_plugins.json')
    Save-FixtureJson ([ordered]@{enabledPlugins=@{'example@official'=$true}}) (Join-Path $configDir 'settings.json')
    Save-FixtureJson ([ordered]@{enabledPlugins=@{'example@official'=$false}}) (Join-Path $project '.claude/settings.json')
    Test-Csu 'Registry scopes stay distinct and disabled setting respected' {
        $inventory=Get-ClaudePluginInventory -Config $config -SkipCli
        Assert-Csu ($inventory.plugins.Count -eq 2) 'Missing scoped install.'
        $user=@($inventory.plugins|Where-Object {$_.scope -eq 'user'})[0];$proj=@($inventory.plugins|Where-Object {$_.scope -eq 'project'})[0]
        Assert-Csu ($user.enabled -and -not $proj.enabled) 'Merged setting ignored.'
        Assert-Csu ($user.ownerKey -ne $proj.ownerKey) 'Scope owner keys collided.'
    }
    Test-Csu 'Explicit environment config and plugin-cache roots take priority' {
        $env:CLAUDE_CONFIG_DIR=Join-Path $fixture 'env-config';$env:CLAUDE_CODE_PLUGIN_CACHE_DIR=Join-Path $fixture 'env-plugins'
        try { Assert-Csu ((Get-ClaudeConfigDirectory $config) -eq $env:CLAUDE_CONFIG_DIR) 'Config environment ignored.'; Assert-Csu ((Get-ClaudePluginRoot $config) -eq $env:CLAUDE_CODE_PLUGIN_CACHE_DIR) 'Cache environment ignored.' }
        finally { $env:CLAUDE_CONFIG_DIR=$null;$env:CLAUDE_CODE_PLUGIN_CACHE_DIR=$null }
    }
    Test-Csu 'Unreadable registry surfaces error instead of empty-success' {
        $badDir=Join-Path $fixture 'corrupt';[IO.Directory]::CreateDirectory((Join-Path $badDir 'plugins'))|Out-Null
        [IO.File]::WriteAllText((Join-Path $badDir 'plugins/installed_plugins.json'),'{not-json')
        $bad=Get-ClaudePluginInventory -Config ([pscustomobject]@{userHome=$homeFixture;claudeConfigDir=$badDir}) -SkipCli
        Assert-Csu ($bad.detected -and $bad.errors.Count -eq 1) 'Malformed registry was silently accepted.'
    }
    $inventory=Get-ClaudePluginInventory -Config $config -SkipCli
    $plugin=@($inventory.plugins|Where-Object {$_.scope -eq 'user'})[0]
    $plugin.cliPath='fixture-cli.exe'
    $marketplace=Join-Path $fixture 'marketplace';$source=Join-Path $marketplace 'plugins/example'
    Save-FixtureJson ([ordered]@{name='example';version='2.0.0'}) (Join-Path $source '.claude-plugin/plugin.json')
    Save-FixtureJson ([ordered]@{name='official';plugins=@([ordered]@{name='example';source='./plugins/example';version='3.0.0'})}) (Join-Path $marketplace '.claude-plugin/marketplace.json')
    Save-FixtureJson ([ordered]@{official=[ordered]@{installLocation=$marketplace;lastUpdated='2026-10-21T00:00:00Z'}}) (Join-Path $pluginRoot 'known_marketplaces.json')
    Test-Csu 'Cached manifest version takes precedence and newer numeric release is eligible' {
        $plan=Get-ClaudeUpdatePlan -Plugin $plugin -Config $config
        Assert-Csu ($plan.latest -eq '2.0.0' -and $plan.canUpdate) 'Version precedence/newer plan incorrect.'
        Assert-Csu ($plan.detail -match 'marketplace') 'Catalog provenance missing.'
    }
    Test-Csu 'Missing CLI still detects but cannot automatically update' {
        $plugin.cliPath=$null
        try {$plan=Get-ClaudeUpdatePlan -Plugin $plugin -Config $config;Assert-Csu (-not $plan.canUpdate -and $plan.status -eq 'ต้องใช้ Claude CLI') 'No-CLI update incorrectly enabled.'}
        finally {$plugin.cliPath='fixture-cli.exe'}
    }
    Test-Csu 'Unknown hash versions are not guessed as newer' {
        $prior=$plugin.version;$plugin.version='c4d131c50111'
        try {$plan=Get-ClaudeUpdatePlan -Plugin $plugin -Config $config;Assert-Csu (-not $plan.canUpdate) 'Unknown version auto-enabled.'}
        finally {$plugin.version=$prior}
    }
    Test-Csu 'In-place source plugin stays read-only' {
        $plugin.readFromFolder=$old
        try {$plan=Get-ClaudeUpdatePlan -Plugin $plugin -Config $config;Assert-Csu (-not $plan.canUpdate -and $plan.status -eq 'ดูแลต้นทาง') 'In-place files eligible for replacement.'}
        finally {$plugin.readFromFolder=''}
    }
    $cliOriginal=(Get-Item Function:\Invoke-ClaudeCli).ScriptBlock
    Test-Csu 'CLI plugins wrapper with omitted fields preserves registry paths and versions' {
        Set-Item Function:\Resolve-ClaudeCli -Value {param($Config) return 'fixture-cli.exe'}
        Set-Item Function:\Invoke-ClaudeCli -Value {param($CliPath,$Arguments,$WorkingDirectory,$ConfigDirectory,$PluginCacheDirectory,$TimeoutSeconds) return [pscustomobject]@{exitCode=0;stdout='{"plugins":[{"id":"example@official","enabled":true}]}';stderr=''}}
        try {
            $partial=Get-ClaudePluginInventory -Config $config
            $userEntry=@($partial.plugins|Where-Object {$_.scope -eq 'user'})[0]
            Assert-Csu ($partial.plugins.Count -eq 2 -and $userEntry.installPath -eq $old -and $userEntry.version -eq '1.0.0') 'Partial CLI metadata erased installation fields.'
        } finally { Set-Item Function:\Invoke-ClaudeCli -Value $cliOriginal; Set-Item Function:\Resolve-ClaudeCli -Value {param($Config) return $null} }
    }
    Test-Csu 'Canonical project path trailing slash merges one installation' {
        $script:csuProjectJson=(@([pscustomobject]@{id='example@official';scope='project';projectPath=($project+'\');enabled=$true})|ConvertTo-Json -Compress)
        Set-Item Function:\Resolve-ClaudeCli -Value {param($Config) return 'fixture-cli.exe'}
        Set-Item Function:\Invoke-ClaudeCli -Value {param($CliPath,$Arguments,$WorkingDirectory,$ConfigDirectory,$PluginCacheDirectory,$TimeoutSeconds) return [pscustomobject]@{exitCode=0;stdout=$script:csuProjectJson;stderr=''}}
        try {
            $partial=Get-ClaudePluginInventory -Config $config
            $projectEntries=@($partial.plugins|Where-Object {$_.scope -eq 'project'})
            Assert-Csu ($partial.plugins.Count -eq 2 -and $projectEntries.Count -eq 1 -and $projectEntries[0].installPath -eq $projectInstall -and $projectEntries[0].enabled) 'Canonical project merge failed.'
        } finally { Set-Item Function:\Invoke-ClaudeCli -Value $cliOriginal; Set-Item Function:\Resolve-ClaudeCli -Value {param($Config) return $null} }
    }
    $originalInventory=(Get-Item Function:\Get-ClaudePluginInventory).ScriptBlock
    $originalInvoke=(Get-Item Function:\Invoke-ClaudeCli).ScriptBlock
    $script:csuInventoryCalls=0;$script:csuCommandCalls=0;$script:csuBefore=$plugin;$script:csuAfter=$plugin
    Set-Item Function:\Get-ClaudePluginInventory -Value {param($Config) $script:csuInventoryCalls++;return [pscustomobject]@{plugins=@();cliPath='fixture-cli.exe';configDir=$configDir}}
    Set-Item Function:\Invoke-ClaudeCli -Value {param($CliPath,$Arguments,$WorkingDirectory,$ConfigDirectory,$TimeoutSeconds) $script:csuCommandCalls++;return [pscustomobject]@{exitCode=0;stdout='';stderr=''}}
    Test-Csu 'Removed plugin never triggers update or reinstall' {
        $response=Invoke-ClaudePluginUpdate -Plugin $plugin -Config $config -BackupRoot (Join-Path $fixture 'backups')
        Assert-Csu (-not $response.changed -and $script:csuCommandCalls -eq 0 -and $response.status -eq 'อัปเดตไม่สำเร็จ') 'Removed plugin was updated.'
    }
    $newPath=Join-Path $pluginRoot 'cache/official/example/2.0.0';Write-SkillFixture $newPath 'new skill'
    $newPlugin=$plugin|Select-Object *;$newPlugin.version='2.0.0';$newPlugin.installPath=$newPath
    $script:csuAfter=$newPlugin
    Set-Item Function:\Get-ClaudePluginInventory -Value {param($Config) $script:csuInventoryCalls++;$selected=$script:csuBefore;if($script:csuInventoryCalls -gt 1){$selected=$script:csuAfter};return [pscustomobject]@{plugins=@($selected);cliPath='fixture-cli.exe';configDir=$configDir}}
    Set-Item Function:\Invoke-ClaudeCli -Value {param($CliPath,$Arguments,$WorkingDirectory,$ConfigDirectory,$TimeoutSeconds) $script:csuCommandCalls++;$script:csuCapturedArgs=$Arguments;$script:csuCapturedCwd=$WorkingDirectory;return [pscustomobject]@{exitCode=0;stdout='Updated';stderr=''}}
    Test-Csu 'Scoped update backs up and verifies actual changed files' {
        $script:csuInventoryCalls=0;$script:csuCommandCalls=0
        $response=Invoke-ClaudePluginUpdate -Plugin $plugin -Config $config -BackupRoot (Join-Path $fixture 'backups')
        Assert-Csu ($response.changed -and $response.current -eq '2.0.0' -and $response.status -eq 'อัปเดตแล้ว') 'Verified update not reported.'
        Assert-Csu (Test-Path -LiteralPath (Join-Path $response.backupPath 'skills-0/example/SKILL.md')) 'Skill backup absent.'
        Assert-Csu (($script:csuCapturedArgs -join ' ') -eq 'plugin update example@official --scope user') 'Wrong CLI command/scope.'
        Assert-Csu (-not ($script:csuCapturedArgs -contains '-y')) 'Trust acceptance was added.'
    }
    Test-Csu 'CLI failure is truthful and preserves original files' {
        $script:csuInventoryCalls=0;$script:csuAfter=$newPlugin
        Set-Item Function:\Invoke-ClaudeCli -Value {param($CliPath,$Arguments,$WorkingDirectory,$ConfigDirectory,$TimeoutSeconds) return [pscustomobject]@{exitCode=1;stdout='';stderr='Refused'}}
        $response=Invoke-ClaudePluginUpdate -Plugin $plugin -Config $config -BackupRoot (Join-Path $fixture 'backups')
        Assert-Csu (-not $response.changed -and $response.status -eq 'อัปเดตไม่สำเร็จ') 'Failure misreported as update.'
        Assert-Csu ([IO.File]::ReadAllText((Join-Path $old 'skills/example/SKILL.md')) -eq 'old skill') 'Old files changed.'
    }
    Test-Csu 'No-op command never claims an update' {
        $script:csuInventoryCalls=0;$script:csuAfter=$plugin
        Set-Item Function:\Invoke-ClaudeCli -Value {param($CliPath,$Arguments,$WorkingDirectory,$ConfigDirectory,$TimeoutSeconds) return [pscustomobject]@{exitCode=0;stdout='Latest';stderr=''}}
        $response=Invoke-ClaudePluginUpdate -Plugin $plugin -Config $config -BackupRoot (Join-Path $fixture 'backups')
        Assert-Csu (-not $response.changed -and $response.status -eq 'ไม่มีการเปลี่ยนแปลง') 'No-op misreported.'
    }
    Test-Csu 'Project update uses matching project working directory' {
        $projectPlugin=$plugin|Select-Object *;$projectPlugin.scope='project';$projectPlugin.projectPath=$project;$projectPlugin.ownerKey=Get-ClaudeOwnerKey $projectPlugin.pluginId 'project' $project
        $script:csuBefore=$projectPlugin;$script:csuAfter=$projectPlugin;$script:csuInventoryCalls=0
        Set-Item Function:\Invoke-ClaudeCli -Value {param($CliPath,$Arguments,$WorkingDirectory,$ConfigDirectory,$TimeoutSeconds) $script:csuCapturedCwd=$WorkingDirectory;$script:csuCapturedArgs=$Arguments;return [pscustomobject]@{exitCode=0;stdout='Latest';stderr=''}}
        $response=Invoke-ClaudePluginUpdate -Plugin $projectPlugin -Config $config -BackupRoot (Join-Path $fixture 'backups')
        Assert-Csu ($script:csuCapturedCwd -eq $project -and ($script:csuCapturedArgs -join ' ') -match '--scope project$') 'Project scope context missing.'
    }
    Test-Csu 'Numeric downgrade never claims updated and preserves backup' {
        $script:csuBefore=$newPlugin;$script:csuAfter=$plugin;$script:csuInventoryCalls=0
        Set-Item Function:\Invoke-ClaudeCli -Value {param($CliPath,$Arguments,$WorkingDirectory,$ConfigDirectory,$PluginCacheDirectory,$TimeoutSeconds) return [pscustomobject]@{exitCode=0;stdout='Done';stderr=''}}
        $response=Invoke-ClaudePluginUpdate -Plugin $newPlugin -Config $config -BackupRoot (Join-Path $fixture 'backups')
        Assert-Csu (-not $response.changed -and $response.status -eq 'อัปเดตไม่สำเร็จ' -and $response.detail -match 'ลดลง') 'Downgrade was reported as an update.'
        Assert-Csu ($response.current -eq '1.0.0') 'Observed downgraded version was hidden.'
        Assert-Csu (Test-Path -LiteralPath (Join-Path $response.backupPath 'skills-0/example/SKILL.md')) 'Backup missing after downgrade detection.'
    }
    Set-Item Function:\Get-ClaudePluginInventory -Value $originalInventory
    Set-Item Function:\Invoke-ClaudeCli -Value $originalInvoke
} finally {
    Set-Item Function:\Resolve-ClaudeCli -Value $originalResolver
    $env:CLAUDE_CONFIG_DIR=$originalConfigEnv;$env:CLAUDE_CODE_PLUGIN_CACHE_DIR=$originalCacheEnv
}
$summary=[pscustomobject]@{passed=@($results|Where-Object {$_.passed}).Count;failed=@($results|Where-Object {-not $_.passed}).Count;fixture=$fixture;results=@($results.ToArray())}
$summary|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $fixture 'test-results.json') -Encoding UTF8
$summary|ConvertTo-Json -Depth 7
if ($summary.failed) { exit 1 }
