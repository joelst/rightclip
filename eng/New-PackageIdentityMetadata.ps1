<#
.SYNOPSIS
Sets the application manifest publisher to match the selected package signer.
.DESCRIPTION
Requires PowerShell 7; does not install or trust any certificates.
DevelopmentSigning uses the development publisher regardless of Azure settings.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$outputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts\identity\RightClip.app.manifest'),
    [switch]$developmentSigning
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$azureConfigured = -not [string]::IsNullOrWhiteSpace($env:AZURE_TRUSTED_SIGNING_ENDPOINT) -or
    -not [string]::IsNullOrWhiteSpace($env:AZURE_TRUSTED_SIGNING_ACCOUNT_NAME) -or
    -not [string]::IsNullOrWhiteSpace($env:AZURE_TRUSTED_SIGNING_CERTIFICATE_PROFILE_NAME)
$publisher = 'CN=RightClip'
if ($azureConfigured -and -not $DevelopmentSigning) {
    foreach ($name in @('AZURE_TRUSTED_SIGNING_ENDPOINT', 'AZURE_TRUSTED_SIGNING_ACCOUNT_NAME',
            'AZURE_TRUSTED_SIGNING_CERTIFICATE_PROFILE_NAME', 'AZURE_TRUSTED_SIGNING_PUBLISHER')) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            throw "Production package identity requires $name."
        }
    }
    $publisher = $env:AZURE_TRUSTED_SIGNING_PUBLISHER
}

[xml]$manifest = Get-Content (Join-Path $root 'src\RightClip.App\app.manifest') -Raw
$manifest.assembly.msix.publisher = $publisher
$directory = Split-Path $OutputPath -Parent
New-Item -ItemType Directory -Force $directory | Out-Null
$manifest.Save($OutputPath)
Write-Output "Application package identity publisher: $($publisher)"
