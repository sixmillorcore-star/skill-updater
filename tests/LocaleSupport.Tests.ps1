$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path (Join-Path $PSScriptRoot '.artifacts') ('locale-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$testExe = Join-Path $testRoot 'LocaleSupport.Tests.exe'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/csc.exe' }
& $compiler /nologo /target:exe /codepage:65001 "/out:$testExe" /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll (Join-Path $appRoot 'LocaleSupport.cs') (Join-Path $PSScriptRoot 'LocaleSupport.Tests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Locale helper compilation failed.' }
& $testExe $appRoot $testRoot
if ($LASTEXITCODE -ne 0) { throw 'Locale helper tests failed.' }
