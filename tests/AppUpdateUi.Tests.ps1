param()
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot
$artifactRoot = Join-Path $PSScriptRoot '.artifacts'
New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/csc.exe' }
$outputPath = Join-Path $artifactRoot 'AppUpdateUi.Tests.exe'
$sourcePaths = @(Get-ChildItem -LiteralPath $sourceRoot -Filter '*.cs' | Select-Object -ExpandProperty FullName) + @(Join-Path $PSScriptRoot 'AppUpdateUi.Tests.cs')
& $compiler /nologo /target:exe /optimize+ /utf8output /main:CodexSkillUpdater.AppUpdateUiTests /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll "/out:$outputPath" $sourcePaths
if ($LASTEXITCODE -ne 0) { throw 'Could not compile app update UI tests.' }
& $outputPath $sourceRoot
if ($LASTEXITCODE -ne 0) { throw 'App update UI tests failed.' }
