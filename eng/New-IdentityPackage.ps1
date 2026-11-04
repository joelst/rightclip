<#
.SYNOPSIS
Builds and verifies a sparse identity package using the Windows SDK.
.DESCRIPTION
Development PFX passwords are protected with Windows DPAPI for the current user.
Requires PowerShell 7, MakeAppx, and SignTool; never trusts certificates.
DevelopmentSigning uses a self-signed identity regardless of Azure settings.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$stage = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\RightClip'),
    [switch]$developmentSigning
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sdk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Directory |
    Where-Object { $_.Name -match '^10\.\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (-not $sdk) {
    throw 'A Windows SDK with MakeAppx.exe and SignTool.exe is required.'
}
$makeAppx = Join-Path $sdk.FullName 'x64\MakeAppx.exe'
$signTool = Join-Path $sdk.FullName 'x64\SignTool.exe'
foreach ($tool in @($makeAppx, $signTool)) {
    if (-not (Test-Path $tool)) {
        throw "Windows SDK tool not found: $tool"
    }
}

$azureNames = @('AZURE_TRUSTED_SIGNING_ENDPOINT', 'AZURE_TRUSTED_SIGNING_ACCOUNT_NAME', 'AZURE_TRUSTED_SIGNING_CERTIFICATE_PROFILE_NAME')
$azureCount = @($azureNames | Where-Object { -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) }).Count
$production = -not $DevelopmentSigning -and ($azureCount -gt 0)
if ($production) {
    foreach ($name in $azureNames + 'AZURE_TRUSTED_SIGNING_PUBLISHER') {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            throw "Production identity signing requires $name."
        }
    }
    $publisher = $env:AZURE_TRUSTED_SIGNING_PUBLISHER
    Remove-Item (Join-Path $Stage 'RightClip.Identity.cer') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Stage 'RightClip.Identity.thumbprint') -Force -ErrorAction SilentlyContinue
    Set-Content -Path (Join-Path $Stage 'RightClip.Identity.Production') -Value $publisher -NoNewline
}
else {
    $publisher = 'CN=RightClip'
    Remove-Item (Join-Path $Stage 'RightClip.Identity.Production') -Force -ErrorAction SilentlyContinue
    $signing = Join-Path $root 'third_party\signing'
    New-Item -ItemType Directory -Force $signing | Out-Null
    $pfx = Join-Path $signing 'RightClip-Identity.pfx'
    $passwordFile = Join-Path $signing 'password.xml'
    $legacyPasswordFile = Join-Path $signing 'password.txt'
    if (-not (Test-Path $pfx)) {
        $secure = [System.Security.SecureString]::new()
        foreach ($character in [guid]::NewGuid().ToString('N').ToCharArray()) {
            $secure.AppendChar($character)
        }
        $secure.MakeReadOnly()
        $secure | Export-Clixml -LiteralPath $passwordFile
        $certificate = New-SelfSignedCertificate -Subject $publisher -Type CodeSigningCert `
            -CertStoreLocation 'Cert:\CurrentUser\My' -KeyExportPolicy Exportable `
            -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(3)
        Export-PfxCertificate -Cert $certificate -FilePath $pfx -Password $secure | Out-Null
    }
    elseif (-not (Test-Path $passwordFile) -and (Test-Path $legacyPasswordFile)) {
        $secure = [System.Security.SecureString]::new()
        foreach ($character in (Get-Content $legacyPasswordFile -Raw).ToCharArray()) {
            $secure.AppendChar($character)
        }
        $secure.MakeReadOnly()
        $secure | Export-Clixml -LiteralPath $passwordFile
        Remove-Item -LiteralPath $legacyPasswordFile -Force
    }
    $secure = Import-Clixml -LiteralPath $passwordFile
    $certificate = Get-PfxCertificate -FilePath $pfx -Password $secure
    $storeCertificate = Get-Item -LiteralPath (Join-Path 'Cert:\CurrentUser\My' $certificate.Thumbprint) -ErrorAction SilentlyContinue
    if ($null -eq $storeCertificate -or -not $storeCertificate.HasPrivateKey) {
        $certificate = Import-PfxCertificate -FilePath $pfx -Password $secure -CertStoreLocation 'Cert:\CurrentUser\My' -Exportable
    }
    Export-Certificate -Cert $certificate -FilePath (Join-Path $Stage 'RightClip.Identity.cer') -Force | Out-Null
    Set-Content -Path (Join-Path $Stage 'RightClip.Identity.thumbprint') -Value $certificate.Thumbprint -NoNewline
}

$work = Join-Path $root 'artifacts\identity'
if (Test-Path $work) {
    Remove-Item $work -Recurse -Force
}
New-Item -ItemType Directory -Force $work | Out-Null
[xml]$manifest = Get-Content (Join-Path $root 'packaging\AppxManifest.xml') -Raw
$manifest.Package.Identity.Publisher = $publisher
$manifest.Save((Join-Path $work 'AppxManifest.xml'))
$assetDirectory = Join-Path $work 'Assets'
New-Item -ItemType Directory -Force $assetDirectory | Out-Null
Copy-Item (Join-Path $root 'assets\RightClip.png') $assetDirectory
Copy-Item (Join-Path $root 'assets\Square150x150Logo.png') $assetDirectory
Copy-Item (Join-Path $root 'assets\Square44x44Logo.png') $assetDirectory
$identityPackage = Join-Path $work 'RightClip.Identity.msix'
& $makeAppx pack /o /d $work /nv /p $identityPackage
if ($LASTEXITCODE -ne 0) {
    throw 'MakeAppx could not build the RightClip identity package.'
}
if ($production) {
    & (Join-Path $PSScriptRoot 'Invoke-AzureTrustedSigning.ps1') -FilePath $identityPackage
    if ($LASTEXITCODE -ne 0) {
        throw 'Azure Trusted Signing failed for the identity package.'
    }
}
else {
    & $signTool sign /fd SHA256 /sha1 $certificate.Thumbprint $identityPackage
    if ($LASTEXITCODE -ne 0) {
        throw 'SignTool could not sign the RightClip identity package.'
    }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Security.Cryptography.Pkcs
$archive = [System.IO.Compression.ZipFile]::OpenRead($identityPackage)
try {
    $signatureEntry = $archive.Entries | Where-Object FullName -eq 'AppxSignature.p7x'
    if ($null -eq $signatureEntry) {
        throw 'The identity package has no CMS signature.'
    }
    $signatureStream = $signatureEntry.Open()
    try {
        $prefix = [byte[]]::new(4)
        $signatureStream.ReadExactly($prefix)
        $signatureBytes = [byte[]]::new($signatureEntry.Length - 4)
        $signatureStream.ReadExactly($signatureBytes)
    }
    finally {
        $signatureStream.Dispose()
    }
}
finally {
    $archive.Dispose()
}
$signedCms = [System.Security.Cryptography.Pkcs.SignedCms]::new()
$signedCms.Decode($signatureBytes)
$signedCms.CheckSignature($true)
if (-not $production -and ($signedCms.SignerInfos.Count -ne 1 -or $signedCms.SignerInfos[0].Certificate.Thumbprint -ne $certificate.Thumbprint)) {
    throw 'The identity package signer does not match the expected certificate.'
}
Copy-Item $identityPackage (Join-Path $Stage 'RightClip.Identity.msix') -Force
Write-Output "Created and verified $($identityPackage) with publisher $($publisher)"
