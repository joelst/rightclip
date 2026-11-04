<#
.SYNOPSIS
Exercises the production packaging path with a local mocked signing module.
.DESCRIPTION
Requires the packaging prerequisites. Does not contact Azure or trust certificates.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$outputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\production-signing-dist')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$names = @(
    'AZURE_TRUSTED_SIGNING_ENDPOINT',
    'AZURE_TRUSTED_SIGNING_ACCOUNT_NAME',
    'AZURE_TRUSTED_SIGNING_CERTIFICATE_PROFILE_NAME',
    'AZURE_TRUSTED_SIGNING_PUBLISHER',
    'PSModulePath',
    'RIGHTCLIP_TEST_SIGNING_ROOT',
    'CI'
)
$previous = @{}
foreach ($name in $names) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name)
}
try {
foreach ($name in $names | Where-Object { $_ -like 'AZURE_TRUSTED_SIGNING_*' }) {
    [Environment]::SetEnvironmentVariable($name, $null)
}

$env:CI = 'true'
$signingScript = Join-Path $PSScriptRoot 'Invoke-AzureTrustedSigning.ps1'
$probe = Join-Path $root 'LICENSE'
$diagnostics = & pwsh -NoLogo -NoProfile -File $signingScript -FilePath $probe 2>&1
if ($LASTEXITCODE -eq 0) {
    throw 'Unconfigured production signing unexpectedly succeeded in CI.'
}
Write-Verbose ($diagnostics | Out-String)
& pwsh -NoLogo -NoProfile -File $signingScript -FilePath $probe -AllowUnsignedDevelopment
if ($LASTEXITCODE -ne 0) {
    throw 'Explicit unsigned development signing failed in CI.'
}

$stage = Join-Path $outputDirectory 'RightClip'
New-Item -ItemType Directory -Force $stage | Out-Null
& (Join-Path $PSScriptRoot 'New-IdentityPackage.ps1') -Stage $stage
$work = Join-Path $root 'TestResults\production-signing'
if (Test-Path $work) {
    Remove-Item $work -Recurse -Force
}
$moduleDirectory = Join-Path $work 'Modules\ArtifactSigning'
New-Item -ItemType Directory -Force $moduleDirectory | Out-Null
$module = @'
function Invoke-ArtifactSigning {
    [CmdletBinding()]
    param(
        $Endpoint,
        $CodeSigningAccountName,
        $CertificateProfileName,
        [string[]]$Files,
        $FileDigest,
        $TimestampRfc3161,
        $TimestampDigest,
        $Description,
        $DescriptionUrl
    )

    $root = $env:RIGHTCLIP_TEST_SIGNING_ROOT
    $sdk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Directory |
        Where-Object { $_.Name -match '^10\.\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    $signTool = Join-Path $sdk.FullName 'x64\SignTool.exe'
    $pfx = Join-Path $root 'third_party\signing\RightClip-Identity.pfx'
    $secure = Import-Clixml -LiteralPath (Join-Path $root 'third_party\signing\password.xml')
    $password = [System.Net.NetworkCredential]::new('', $secure).Password
    & $signTool sign /fd SHA256 /f $pfx /p $password $Files
    if ($LASTEXITCODE -ne 0) {
        throw 'Mock production signing failed.'
    }
}
Export-ModuleMember -Function Invoke-ArtifactSigning
'@
Set-Content -Path (Join-Path $moduleDirectory 'ArtifactSigning.psm1') -Value $module

    $env:PSModulePath = (Join-Path $work 'Modules') + [IO.Path]::PathSeparator + $previous['PSModulePath']
    $env:RIGHTCLIP_TEST_SIGNING_ROOT = $root
    $env:AZURE_TRUSTED_SIGNING_ENDPOINT = 'https://test.codesigning.azure.net/'
    $env:AZURE_TRUSTED_SIGNING_ACCOUNT_NAME = 'rightclip-test'
    $env:AZURE_TRUSTED_SIGNING_CERTIFICATE_PROFILE_NAME = 'rightclip-test-profile'
    $env:AZURE_TRUSTED_SIGNING_PUBLISHER = 'CN=RightClip'
    & (Join-Path $PSScriptRoot 'Publish-RightClip.ps1') -OutputDirectory $outputDirectory
    [xml]$properties = Get-Content (Join-Path $root 'Directory.Build.props') -Raw
    $setup = Join-Path $outputDirectory "RightClip-$($properties.Project.PropertyGroup.Version)-win-x64-Setup.exe"
    & (Join-Path $PSScriptRoot 'Test-Installer.ps1') -SetupPath $setup
    if (-not (Test-Path (Join-Path $stage 'RightClip.Identity.Production'))) {
        throw 'The production identity marker was not generated.'
    }
    Write-Output 'Mocked production signing and installer verification passed.'
}
finally {
    foreach ($name in $names) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name])
    }
}
