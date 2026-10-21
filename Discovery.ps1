# Read-only Skill discovery. Compatible with Windows PowerShell 5.1.
# The installed inventories decide which plugin versions are scanned; cache folders
# on their own are never evidence that a plugin is installed.

function Get-DiscoveryProperty($Value, [string]$Name, $Default=$null) {
    if ($null -eq $Value) { return $Default }
    if ($Value -is [Collections.IDictionary]) {
        if ($Value.Contains($Name)) { return $Value[$Name] }
        return $Default
    }
    $property=$Value.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}
function Read-DiscoveryJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
}
function Resolve-DiscoveryPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $full=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
    if ($full.Length -gt [IO.Path]::GetPathRoot($full).Length) { $full=$full.TrimEnd('\','/') }
    if (-not (Test-Path -LiteralPath $full)) { return $full }
    # Resolve junctions and symlink ancestors without walking them. File handles
    # request metadata only and share access with the host applications.
    if (-not ('SkillUpdaterDiscoveryPath' -as [type])) {
        try {
            Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class SkillUpdaterDiscoveryPath {
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 static extern SafeFileHandle CreateFile(string p,uint a,uint s,IntPtr z,uint c,uint f,IntPtr t);
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 static extern uint GetFinalPathNameByHandle(SafeFileHandle h,StringBuilder b,uint n,uint f);
 public static string Resolve(string p) {
  using(var h=CreateFile(p,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
   if(h.IsInvalid) return p;
   var b=new StringBuilder(1024);
   uint size=GetFinalPathNameByHandle(h,b,(uint)b.Capacity,0);
   if(size==0) return p;
   if(size>=b.Capacity) { b=new StringBuilder((int)size+1); if(GetFinalPathNameByHandle(h,b,(uint)b.Capacity,0)==0) return p; }
   string r=b.ToString();
   if(r.StartsWith(@"\\?\UNC\",StringComparison.OrdinalIgnoreCase)) return @"\\"+r.Substring(8);
   return r.StartsWith(@"\\?\",StringComparison.OrdinalIgnoreCase)?r.Substring(4):r;
  }
 }
}
'@ -ErrorAction Stop | Out-Null
        } catch { }
    }
    if ('SkillUpdaterDiscoveryPath' -as [type]) {
        try {
            $resolved=[SkillUpdaterDiscoveryPath]::Resolve($full)
            if ($resolved.Length -gt [IO.Path]::GetPathRoot($resolved).Length) { $resolved=$resolved.TrimEnd('\','/') }
            return $resolved
        } catch { }
    }
    return $full
}
function Get-DiscoveryCommand([string[]]$Names, [string]$Hint) {
    foreach ($name in $Names) {
        $command=Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command -and $command.Source) { return [string]$command.Source }
    }
    if ($Hint -and (Test-Path -LiteralPath $Hint -PathType Leaf)) { return $Hint }
    return $null
}
function Get-DiscoveryEnvironment($Config) {
    $userHome=[string](Get-DiscoveryProperty $Config 'userHome' $env:USERPROFILE)
    if (-not $userHome) { $userHome=[Environment]::GetFolderPath('UserProfile') }
    $userHome=Resolve-DiscoveryPath $userHome
    $codexHome=$env:CODEX_HOME
    if (-not $codexHome) { $codexHome=[string](Get-DiscoveryProperty $Config 'codexHome' (Join-Path $userHome '.codex')) }
    $codexHome=Resolve-DiscoveryPath $codexHome
    $claudeHome=$env:CLAUDE_CONFIG_DIR
    if (-not $claudeHome) { $claudeHome=[string](Get-DiscoveryProperty $Config 'claudeHome' (Get-DiscoveryProperty $Config 'claudeConfigDir' (Join-Path $userHome '.claude'))) }
    $claudeHome=Resolve-DiscoveryPath $claudeHome
    $warnings=New-Object 'Collections.Generic.List[string]'
    $projects=New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $addProject={ param($Candidate)
        if ($Candidate -isnot [string] -or [string]::IsNullOrWhiteSpace($Candidate)) { return }
        try {
            $resolved=Resolve-DiscoveryPath $Candidate
            if ((Test-Path -LiteralPath $resolved -PathType Container) -and $projects.Count -lt 100) { $projects[$resolved]=$resolved }
        } catch { }
    }
    foreach ($project in @(Get-DiscoveryProperty $Config 'projectRoots' @())) { & $addProject $project }
    if ((Get-DiscoveryProperty $Config 'discoverProjects' $true) -ne $false) {
        # Read only known project-root fields. Never enumerate the whole disk.
        $stateFile=Join-Path $codexHome '.codex-global-state.json'
        if (Test-Path -LiteralPath $stateFile) {
            try {
                $state=Read-DiscoveryJson $stateFile
                foreach ($key in @('electron-saved-workspace-roots','active-workspace-roots','workspace-root-order')) {
                    foreach ($project in @(Get-DiscoveryProperty $state $key @())) { & $addProject $project }
                }
                $localProjects=Get-DiscoveryProperty $state 'local-projects'
                if ($localProjects) {
                    foreach ($property in $localProjects.PSObject.Properties) {
                        foreach ($project in @(Get-DiscoveryProperty $property.Value 'rootPaths' @())) { & $addProject $project }
                    }
                }
            } catch { $warnings.Add('อ่านรายชื่อโปรเจกต์ของ Codex ไม่ได้: ' + $_.Exception.Message) }
        }
        $configFile=Join-Path $codexHome 'config.toml'
        if (Test-Path -LiteralPath $configFile) {
            try {
                foreach ($line in [IO.File]::ReadLines($configFile)) {
                    if ($line -match '^\s*\[projects\.\x27([^\x27]+)\x27\]\s*$') { & $addProject $Matches[1] }
                    elseif ($line -match '^\s*\[projects\."((?:\\.|[^"])*)"\]\s*$') {
                        try { & $addProject ('"'+$Matches[1]+'"' | ConvertFrom-Json) } catch { }
                    }
                }
            } catch { $warnings.Add('อ่านตำแหน่งโปรเจกต์ใน config.toml ไม่ได้') }
        }
        # ~/.claude.json also holds sign-in state. Do not inspect it. Claude
        # project paths come from explicit roots and plugin installation records.
    }
    $codexCli=Get-DiscoveryCommand @('codex.exe','codex') ([string](Get-DiscoveryProperty $Config 'codexPath'))
    $claudeCli=Get-DiscoveryCommand @('claude.exe','claude.cmd','claude') ([string](Get-DiscoveryProperty $Config 'claudePath'))
    $providers=@(
        [pscustomobject]@{name='Codex';detected=([bool]$codexCli -or (Test-Path -LiteralPath $codexHome));cliPath=$codexCli;status=$(if($codexCli){'พบ CLI'}elseif(Test-Path -LiteralPath $codexHome){'พบข้อมูล (ไม่พบ CLI)'}else{'ไม่พบในเครื่อง'});detail='ตรวจ Skill ผู้ใช้ ระบบ โปรเจกต์ที่รู้จัก และปลั๊กอินที่ยังติดตั้งอยู่'},
        [pscustomobject]@{name='Claude Code';detected=([bool]$claudeCli -or (Test-Path -LiteralPath $claudeHome));cliPath=$claudeCli;status=$(if($claudeCli){'พบ CLI'}elseif(Test-Path -LiteralPath $claudeHome){'พบข้อมูล (ไม่พบ CLI)'}else{'ไม่พบในเครื่อง'});detail='ตรวจ Skill ผู้ใช้ โปรเจกต์ที่รู้จัก และ installPath จากทะเบียนปลั๊กอิน'}
    )
    return [pscustomobject]@{userHome=$userHome;codexHome=$codexHome;claudeHome=$claudeHome;projectRoots=@($projects.Values | Sort-Object);providers=$providers;warnings=@($warnings.ToArray())}
}
function Get-DiscoveryScalar([string]$Text) {
    $value=$Text.Trim()
    if ($value.Length -ge 2 -and $value[0] -eq '"' -and $value[$value.Length-1] -eq '"') {
        try { return [string]($value | ConvertFrom-Json) } catch { return $value.Substring(1,$value.Length-2) }
    }
    if ($value.Length -ge 2 -and $value[0] -eq "'" -and $value[$value.Length-1] -eq "'") { return $value.Substring(1,$value.Length-2).Replace("''", "'") }
    return ($value -replace '\s+#.*$','').Trim()
}
function Get-DiscoveryMetadata([string]$File, [string]$PackageVersion) {
    $name=Split-Path -Leaf (Split-Path -Parent $File)
    $version=$PackageVersion; $description=''; $warning=''
    try {
        $info=Get-Item -LiteralPath $File -ErrorAction Stop
        if ($info.Length -gt 2097152) { throw 'SKILL.md ใหญ่เกิน 2 MiB' }
        $content=Get-Content -LiteralPath $File -Raw -Encoding UTF8 -ErrorAction Stop
        if ($content -match '(?s)\A\uFEFF?---\s*\r?\n(.*?)\r?\n---(?:\r?\n|$)') {
            $frontmatter=$Matches[1]
            if ($frontmatter -match '(?m)^name:\s*([^\r\n]+)') { $name=Get-DiscoveryScalar $Matches[1] }
            if ($frontmatter -match '(?m)^\s*version:\s*([^\r\n]+)') { $version=Get-DiscoveryScalar $Matches[1] }
            if ($frontmatter -match '(?m)^description:\s*([^\r\n]+)') { $description=Get-DiscoveryScalar $Matches[1] }
        } else { $warning='ไม่พบ YAML frontmatter; แสดงชื่อจากโฟลเดอร์' }
    } catch { $warning=$_.Exception.Message }
    if (-not $version) { $version='ไม่ระบุ' }
    return [pscustomobject]@{name=$name;version=$version;description=$description;warning=$warning}
}
function Get-DiscoveryManifest([string]$PackagePath, [string]$Kind) {
    $candidates=@()
    if ($Kind -eq 'claude-plugin') { $candidates+=Join-Path $PackagePath '.claude-plugin\plugin.json' }
    else { $candidates+=Join-Path $PackagePath '.codex-plugin\plugin.json' }
    $candidates+=Join-Path $PackagePath 'plugin.json'
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Read-DiscoveryJson $candidate) }
    }
    return $null
}
function Get-DiscoveryDisabledCodexSkills([string]$CodexHome, $Warnings) {
    $disabled=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $file=Join-Path $CodexHome 'config.toml'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return ,$disabled }
    $inside=$false; $entryPath=$null; $entryEnabled=$true
    $store={
        if ($inside -and -not $entryEnabled -and $entryPath) {
            try {
                if ([IO.Path]::IsPathRooted($entryPath)) {
                    $resolved=Resolve-DiscoveryPath $entryPath
                    if (Test-Path -LiteralPath $resolved -PathType Container) { $resolved=Join-Path $resolved 'SKILL.md' }
                    $disabled.Add($resolved) | Out-Null
                } else { $Warnings.Add('ข้าม skills.config path ที่ไม่ใช่ absolute path') }
            } catch { $Warnings.Add('อ่าน path ของ Skill ที่ปิดใช้งานไม่ได้') }
        }
    }
    try {
        foreach ($line in [IO.File]::ReadLines($file)) {
            if ($line -match '^\s*\[') {
                & $store
                $inside=($line -match '^\s*\[\[skills\.config\]\]\s*(?:#.*)?$')
                $entryPath=$null; $entryEnabled=$true
            } elseif ($inside -and $line -match '^\s*path\s*=\s*("(?:\\.|[^"])*"|\x27[^\x27]*\x27)\s*(?:#.*)?$') {
                $entryPath=Get-DiscoveryScalar $Matches[1]
            } elseif ($inside -and $line -match '^\s*enabled\s*=\s*(true|false)\s*(?:#.*)?$') { $entryEnabled=($Matches[1] -eq 'true') }
        }
        & $store
    } catch { $Warnings.Add('อ่านการปิดใช้งาน Skill ใน config.toml ไม่ได้') }
    return ,$disabled
}
function Get-DiscoveryPluginRoots([string]$PackagePath, [string]$Kind, $Warnings) {
    $package=Resolve-DiscoveryPath $PackagePath
    $roots=New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    $default=Join-Path $package 'skills'
    if (Test-Path -LiteralPath $default -PathType Container) { $roots[(Resolve-DiscoveryPath $default)]=$default }
    try {
        $manifest=Get-DiscoveryManifest $package $Kind
        foreach ($relative in @(Get-DiscoveryProperty $manifest 'skills' @())) {
            if ($relative -isnot [string]) { continue }
            if ([IO.Path]::IsPathRooted($relative)) { $Warnings.Add('ข้าม skills path แบบ absolute ในปลั๊กอิน: '+$package); continue }
            $candidate=Resolve-DiscoveryPath (Join-Path $package $relative)
            if (-not ($candidate.Equals($package,[StringComparison]::OrdinalIgnoreCase) -or $candidate.StartsWith($package+'\',[StringComparison]::OrdinalIgnoreCase))) { $Warnings.Add('ข้าม skills path ที่อยู่นอกปลั๊กอิน: '+$package); continue }
            if (Test-Path -LiteralPath $candidate -PathType Container) { $roots[$candidate]=$candidate }
        }
        if ($roots.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $package 'SKILL.md') -PathType Leaf)) { $roots[$package]=$package }
    } catch { $Warnings.Add('อ่าน manifest ของปลั๊กอินไม่ได้: '+$package) }
    return @($roots.Values | Sort-Object)
}
function Find-DiscoverySkillFolders([string]$Root, $Warnings) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return }
    $pending=New-Object 'Collections.Generic.Stack[object]'
    $pending.Push([pscustomobject]@{path=$Root;depth=0})
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $scanned=0
    while ($pending.Count -gt 0) {
        $entry=$pending.Pop()
        try {
            $physical=Resolve-DiscoveryPath $entry.path
            if (-not $seen.Add($physical)) { continue }
            $scanned++
            if ($scanned -gt 4000) { $Warnings.Add('ถึงขีดจำกัด 4000 โฟลเดอร์ใน skill root: '+$Root); break }
            $skillFile=Join-Path $physical 'SKILL.md'
            if (Test-Path -LiteralPath $skillFile -PathType Leaf) {
                [pscustomobject]@{skillPath=$physical;skillFile=$skillFile;discoveredPath=$entry.path}
                # Supporting files/examples inside an actual Skill are not new Skills.
                continue
            }
            if ($entry.depth -ge 8) { $Warnings.Add('ถึงความลึกค้นหา 8 ชั้นใน skill root: '+$entry.path); continue }
            foreach ($child in Get-ChildItem -LiteralPath $physical -Directory -Force -ErrorAction Stop) {
                if ($child.Name.StartsWith('.') -or $child.Name -in @('node_modules','__pycache__','venv','build','dist','target')) { continue }
                $pending.Push([pscustomobject]@{path=$child.FullName;depth=($entry.depth+1)})
            }
        } catch { $Warnings.Add('อ่านโฟลเดอร์ Skill ไม่ได้: '+$entry.path+' | '+$_.Exception.Message) }
    }
}
function Get-DiscoveredSkills {
    [CmdletBinding()]
    param($Config, [object[]]$CodexPlugins=@(), [object[]]$ClaudePlugins, $Environment)
    if (-not $Environment) { $Environment=Get-DiscoveryEnvironment $Config }
    $warnings=New-Object 'Collections.Generic.List[string]'
    foreach ($warning in @($Environment.warnings)) { $warnings.Add([string]$warning) }
    $rootList=New-Object 'Collections.Generic.List[object]'
    $addRoot={ param([string]$Path,[string]$Provider,[string]$Scope,[string]$Kind,[string]$OwnerId,[string]$OwnerKey,[string]$Version,[string]$PackagePath,[bool]$Enabled=$true)
        if (-not $Path) { return }
        try {
            $exists=Test-Path -LiteralPath $Path -PathType Container -ErrorAction Stop
            $rootList.Add([pscustomobject]@{path=$Path;provider=$Provider;scope=$Scope;sourceKind=$Kind;ownerId=$OwnerId;ownerKey=$OwnerKey;packageVersion=$Version;packagePath=$PackagePath;enabled=$Enabled;exists=$exists})
        } catch { $warnings.Add('ตรวจตำแหน่ง Skill ไม่ได้: '+$Path+' | '+$_.Exception.Message) }
    }
    & $addRoot (Join-Path $Environment.codexHome 'skills') 'Codex' 'User' 'local' '' '' '' ''
    & $addRoot (Join-Path $Environment.userHome '.agents\skills') 'Codex' 'User' 'local' '' '' '' ''
    & $addRoot (Join-Path $Environment.codexHome 'skills\.system') 'Codex' 'System' 'system' 'codex-system' 'codex-system' '' ''
    & $addRoot (Join-Path $Environment.claudeHome 'skills') 'Claude Code' 'User' 'local' '' '' '' ''
    foreach ($root in @(Get-DiscoveryProperty $Config 'skillRoots' @())) { & $addRoot ([string]$root) 'Codex' 'User' 'local' '' '' '' '' }
    foreach ($root in @(Get-DiscoveryProperty $Config 'claudeSkillRoots' @())) { & $addRoot ([string]$root) 'Claude Code' 'User' 'local' '' '' '' '' }
    foreach ($root in @(Get-DiscoveryProperty $Config 'sharedSkillRoots' @())) {
        & $addRoot ([string]$root) 'Codex' 'User' 'local' '' '' '' ''
        & $addRoot ([string]$root) 'Claude Code' 'User' 'local' '' '' '' ''
    }
    foreach ($root in @(Get-DiscoveryProperty $Config 'adminSkillRoots' @())) { & $addRoot ([string]$root) 'Codex' 'Admin' 'system' 'codex-admin' 'codex-admin' '' '' }
    if ($env:ProgramFiles) { & $addRoot (Join-Path $env:ProgramFiles 'ClaudeCode\.claude\skills') 'Claude Code' 'Enterprise' 'system' 'claude-managed' 'claude-managed' '' '' }
    foreach ($project in @($Environment.projectRoots)) {
        & $addRoot (Join-Path $project '.agents\skills') 'Codex' 'Project' 'local' '' '' '' ''
        & $addRoot (Join-Path $project '.codex\skills') 'Codex' 'Project' 'local' '' '' '' ''
        & $addRoot (Join-Path $project '.claude\skills') 'Claude Code' 'Project' 'local' '' '' '' ''
    }
    foreach ($plugin in @($CodexPlugins)) {
        if ((Get-DiscoveryProperty $plugin 'installed' $true) -eq $false) { continue }
        $name=[string](Get-DiscoveryProperty $plugin 'name'); $market=[string](Get-DiscoveryProperty $plugin 'marketplaceName')
        $version=[string](Get-DiscoveryProperty $plugin 'version'); $id=[string](Get-DiscoveryProperty $plugin 'pluginId')
        if ($name -notmatch '^[a-zA-Z0-9._-]+$' -or $market -notmatch '^[a-zA-Z0-9._-]+$' -or $version -notmatch '^[a-zA-Z0-9._-]+$') { continue }
        $package=Join-Path $Environment.codexHome ('plugins\cache\'+$market+'\'+$name+'\'+$version)
        if (-not (Test-Path -LiteralPath $package -PathType Container)) {
            $source=Get-DiscoveryProperty $plugin 'source'
            $sourcePath=[string](Get-DiscoveryProperty $source 'path')
            if ((Get-DiscoveryProperty $source 'source') -eq 'local' -and $sourcePath -and (Test-Path -LiteralPath $sourcePath -PathType Container)) { $package=$sourcePath }
            else { $warnings.Add('ยังไม่พบไฟล์ปลั๊กอินที่ติดตั้ง: '+$id); continue }
        }
        foreach ($root in @(Get-DiscoveryPluginRoots $package 'codex-plugin' $warnings)) { & $addRoot $root 'Codex' 'Plugin' 'codex-plugin' $id ('codex|'+$id) $version $package ([bool](Get-DiscoveryProperty $plugin 'enabled' $true)) }
    }
    if (-not $PSBoundParameters.ContainsKey('ClaudePlugins')) {
        $inventoryCommand=Get-Command Get-ClaudePluginInventory -ErrorAction SilentlyContinue
        if ($inventoryCommand) {
            try { $ClaudePlugins=@((Get-ClaudePluginInventory -Config $Config).plugins) } catch { $warnings.Add('อ่านรายการปลั๊กอิน Claude Code ไม่ได้: '+$_.Exception.Message) }
        } else { $ClaudePlugins=@(); if(Test-Path -LiteralPath (Join-Path $Environment.claudeHome 'plugins\installed_plugins.json')) { $warnings.Add('ต้องโหลด ClaudeSupport.ps1 เพื่ออ่านทะเบียนปลั๊กอิน Claude Code') } }
    }
    foreach ($plugin in @($ClaudePlugins)) {
        if (-not $plugin) { continue }
        $pluginProject=[string](Get-DiscoveryProperty $plugin 'projectPath' '')
        if ($pluginProject -and (Test-Path -LiteralPath $pluginProject -PathType Container)) {
            & $addRoot (Join-Path $pluginProject '.agents\skills') 'Codex' 'Project' 'local' '' '' '' ''
            & $addRoot (Join-Path $pluginProject '.codex\skills') 'Codex' 'Project' 'local' '' '' '' ''
            & $addRoot (Join-Path $pluginProject '.claude\skills') 'Claude Code' 'Project' 'local' '' '' '' ''
            $Environment.projectRoots=@(@($Environment.projectRoots)+$pluginProject | Sort-Object -Unique)
        }
        $package=[string](Get-DiscoveryProperty $plugin 'installPath')
        if (-not $package -or -not (Test-Path -LiteralPath $package -PathType Container)) { $warnings.Add('ไม่พบ installPath ของปลั๊กอิน Claude Code: '+[string](Get-DiscoveryProperty $plugin 'pluginId')); continue }
        $id=[string](Get-DiscoveryProperty $plugin 'pluginId'); $scope=[string](Get-DiscoveryProperty $plugin 'scope' 'user')
        $project=[string](Get-DiscoveryProperty $plugin 'projectPath' '')
        $ownerKey=[string](Get-DiscoveryProperty $plugin 'ownerKey' ($id+'|'+$scope+'|'+$project))
        foreach ($root in @(Get-DiscoveryPluginRoots $package 'claude-plugin' $warnings)) {
            & $addRoot $root 'Claude Code' $scope 'claude-plugin' $id $ownerKey ([string](Get-DiscoveryProperty $plugin 'version')) $package ([bool](Get-DiscoveryProperty $plugin 'enabled' $true))
        }
    }
    $records=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $scannedRoots=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $disabledCodex=Get-DiscoveryDisabledCodexSkills $Environment.codexHome $warnings
    foreach ($root in $rootList) {
        if (-not $root.exists) { continue }
        $canonicalRoot=Resolve-DiscoveryPath $root.path
        $rootKey=$canonicalRoot+'|'+$root.provider+'|'+$root.sourceKind+'|'+$root.ownerKey+'|'+$root.scope
        if (-not $scannedRoots.Add($rootKey)) { continue }
        foreach ($found in @(Find-DiscoverySkillFolders $root.path $warnings)) {
            $kind=$root.sourceKind; $scope=$root.scope; $ownerId=$root.ownerId; $ownerKey=$root.ownerKey
            if ($root.provider -eq 'Claude Code' -and $kind -eq 'local') {
                $syncedRoot=Resolve-DiscoveryPath (Join-Path $Environment.claudeHome 'skills\synced')
                if ($found.skillPath.StartsWith($syncedRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { $kind='system';$scope='Synced';$ownerId='claude.ai';$ownerKey='claude.ai' }
            }
            # Preserve distinct plugin installations/scopes even when the host
            # cache shares files. Ordinary local aliases merge by physical path.
            $key=$found.skillFile
            if ($kind -in @('codex-plugin','claude-plugin')) { $key+='|'+$ownerKey }
            $candidateEnabled=[bool]$root.enabled
            if ($root.provider -eq 'Codex' -and $disabledCodex.Contains($found.skillFile)) { $candidateEnabled=$false }
            if ($records.ContainsKey($key)) {
                $existing=$records[$key]
                $existing.providers=@(@($existing.providers)+$root.provider | Sort-Object -Unique)
                $existing.enabled=$existing.enabled -or $candidateEnabled
                continue
            }
            $metadata=Get-DiscoveryMetadata $found.skillFile $root.packageVersion
            $enabled=$candidateEnabled
            $record=[pscustomobject]@{name=$metadata.name;version=$metadata.version;description=$metadata.description;providers=@($root.provider);scope=$scope;rootPath=$canonicalRoot;skillPath=$found.skillPath;skillFile=$found.skillFile;discoveredPath=$found.discoveredPath;sourceKind=$kind;ownerId=$ownerId;ownerKey=$ownerKey;packageVersion=$root.packageVersion;packagePath=$root.packagePath;enabled=$enabled;warning=$metadata.warning}
            $records[$key]=$record
        }
    }
    foreach ($provider in $Environment.providers) {
        $count=@($records.Values | Where-Object { $_.providers -contains $provider.name }).Count
        $provider | Add-Member -NotePropertyName skillCount -NotePropertyValue $count -Force
        if ($count -gt 0 -and -not $provider.detected) { $provider.detected=$true; $provider.status='พบ Skill (ไม่พบ CLI)' }
    }
    return [pscustomobject]@{skills=@($records.Values | Sort-Object name,scope,skillPath);providers=@($Environment.providers);roots=@($rootList.ToArray());warnings=@($warnings.ToArray() | Select-Object -Unique);claudePlugins=@($ClaudePlugins);projectRoots=@($Environment.projectRoots);environment=$Environment}
}
