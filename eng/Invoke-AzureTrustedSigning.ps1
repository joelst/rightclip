<#
.SYNOPSIS
Signs a release file using the ArtifactSigning PowerShell module and Azure OIDC.
.DESCRIPTION
Requires ArtifactSigning 0.1.8 and configured AZURE_TRUSTED_SIGNING variables.
Unsigned CI output requires explicit AllowUnsignedDevelopment consent.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$filePath,
    [switch]$allowUnsignedDevelopment
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
    throw "File to sign does not exist: $($filePath)"
}
$required = @(
    'AZURE_TRUSTED_SIGNING_ENDPOINT',
    'AZURE_TRUSTED_SIGNING_ACCOUNT_NAME',
    'AZURE_TRUSTED_SIGNING_CERTIFICATE_PROFILE_NAME'
)
$missing = @($required | Where-Object { [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) })
if ($missing.Count -gt 0) {
    $message = "Azure Trusted Signing is not configured. Missing: $($missing -join ', ')"
    if ($missing.Count -ne $required.Count -or ($env:CI -eq 'true' -and -not $AllowUnsignedDevelopment)) {
        throw $message
    }
    Write-Warning "$message. Skipping local Windows code signing."
    exit 0
}
if ($AllowUnsignedDevelopment) {
    throw 'Development signing cannot be combined with production signing configuration.'
}
$root = Split-Path $PSScriptRoot -Parent
$logDirectory = Join-Path $root 'artifacts'
New-Item -ItemType Directory -Force $logDirectory | Out-Null
$logPath = Join-Path $logDirectory 'rightclip-signing.log'
function Write-SigningLog {
    <#
    .SYNOPSIS
    Writes signing diagnostics to the console and the local build log.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$message)

    $line = "[$(Get-Date -Format o)] $message"
    Write-Output $line
    Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
}

Write-SigningLog "Signing '$($FilePath)' with account '$($env:AZURE_TRUSTED_SIGNING_ACCOUNT_NAME)' and profile '$($env:AZURE_TRUSTED_SIGNING_CERTIFICATE_PROFILE_NAME)'."
try {
    Import-Module ArtifactSigning -ErrorAction Stop
    Invoke-ArtifactSigning `
        -Endpoint $env:AZURE_TRUSTED_SIGNING_ENDPOINT `
        -CodeSigningAccountName $env:AZURE_TRUSTED_SIGNING_ACCOUNT_NAME `
        -CertificateProfileName $env:AZURE_TRUSTED_SIGNING_CERTIFICATE_PROFILE_NAME `
        -Files $FilePath `
        -FileDigest SHA256 `
        -TimestampRfc3161 'http://timestamp.acs.microsoft.com' `
        -TimestampDigest SHA256 `
        -Description 'RightClip' `
        -DescriptionUrl 'https://github.com/joelst/rightclip'
    if ($LASTEXITCODE -ne 0) {
        throw "ArtifactSigning returned exit code $LASTEXITCODE."
    }
}
catch {
    Write-SigningLog "Azure Trusted Signing failed: $($_.Exception.Message)"
    Write-SigningLog $_.ScriptStackTrace
    exit 1
}
Write-SigningLog "Successfully signed '$($FilePath)'."
