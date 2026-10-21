[CmdletBinding()]
param([switch]$Live)
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path (Join-Path $PSScriptRoot '.artifacts') ('app-update-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$testExe = Join-Path $testRoot 'AppUpdate.Tests.exe'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/csc.exe' }
& $compiler /nologo /target:exe /codepage:65001 "/out:$testExe" /r:System.dll /r:System.Core.dll /r:System.Web.Extensions.dll /r:System.IO.Compression.dll (Join-Path $appRoot 'AppUpdate.cs') (Join-Path $PSScriptRoot 'AppUpdate.Tests.cs')
if ($LASTEXITCODE -ne 0) { throw 'App update engine test compilation failed.' }
if ($Live) { & $testExe $testRoot --live }
else { & $testExe $testRoot }
if ($LASTEXITCODE -ne 0) { throw 'App update engine tests failed.' }
