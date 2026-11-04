<#
.SYNOPSIS
Builds and runs native Explorer-command tests without COM registration.
.DESCRIPTION
Requires Visual Studio C++ x64 tools and an already built shell DLL.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$shellPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\RightClip\RightClip.Shell.dll')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$work = Join-Path $root 'TestResults\shell-smoke'
if (Test-Path $work) {
    Remove-Item $work -Recurse -Force
}
New-Item -ItemType Directory -Force $work | Out-Null
Copy-Item $ShellPath (Join-Path $work 'RightClip.Shell.dll')
Set-Content -Path (Join-Path $work 'first video.mp4') -Value 'fixture'
Set-Content -Path (Join-Path $work 'second.mov') -Value 'fixture'
Set-Content -Path (Join-Path $work 'ignore.txt') -Value 'fixture'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0) {
    throw 'Visual Studio toolchain discovery failed.'
}
if (-not $installation) {
    throw 'No Visual Studio C++ x64 toolchain was found.'
}
$vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
$tests = Join-Path $root 'tests\RightClip.Shell.Tests'
$discoveryDirectory = Split-Path $vswhere -Parent
$command = "set `"PATH=$($discoveryDirectory);%PATH%`" && call `"$($vcvars)`" && cd /d `"$($work)`" && cl.exe /nologo /W4 /WX /EHsc /std:c++17 /utf-8 `"$($tests)\WorkerStub.cpp`" /Fe:`"$($work)\RightClip.exe`" /link kernel32.lib /SUBSYSTEM:WINDOWS && cl.exe /nologo /W4 /WX /EHsc /std:c++17 /utf-8 `"$($tests)\ShellTests.cpp`" /Fe:`"$($work)\ShellTests.exe`" /link ole32.lib shell32.lib uuid.lib"
& cmd.exe /d /s /c $command
if ($LASTEXITCODE -ne 0) {
    throw 'The native shell smoke tests did not compile.'
}

& (Join-Path $work 'ShellTests.exe') (Join-Path $work 'RightClip.Shell.dll') `
    (Join-Path $work 'first video.mp4') (Join-Path $work 'second.mov') (Join-Path $work 'ignore.txt')
if ($LASTEXITCODE -ne 0) {
    throw 'The native Explorer command smoke test failed.'
}
