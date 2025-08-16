<# Genearate value for var $base64Cert by pasting the response from
    converting your public key exported bitlocker network unlock cert
    with the following:
    $filePath = "C:\temp\bilockerUnlockCertificate.cer"
    [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($filePath)) | clip

#>
$base64Cert = '' # your base64 encoded certificate (see comment above)
$certBytes = [System.Convert]::FromBase64String($base64Cert)
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,$certBytes)

# Construct the GPO-style Blob (header + thumbprint + certificate data)
$certData = $cert.RawData
$certLength = $certData.Length
$certLengthBytes = [BitConverter]::GetBytes($certLength)
$Header = [byte[]]@(0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00)
$prefix = [byte[]]@(0x20, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00) + $certLengthBytes
$thumbprint = $cert.Thumbprint

# Convert thumbprint hex string to byte array
$ThumbprintBytes = [byte[]]@()
for ($i = 0; $i -lt $Thumbprint.Length; $i += 2) {
    $ThumbprintBytes += [Convert]::ToByte($Thumbprint.Substring($i, 2), 16)
}

$Blob = $Header + $ThumbprintBytes + $prefix + $CertData
$regPaths = @(
    "HKLM:\SOFTWARE\Policies\Microsoft\SystemCertificates\FVE\Certificates\$thumbprint",
    "HKLM:\SOFTWARE\Policies\Microsoft\SystemCertificates\FVE\CRLs",
    "HKLM:\SOFTWARE\Policies\Microsoft\SystemCertificates\FVE\CTLs"
)
foreach($regPath in $regPaths){
    New-Item -Path $regPath -Force
}
Set-ItemProperty -Path $regPaths[0] -Name "Blob" -Value $Blob -Type Binary
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\FVE" -Name "OSManageNKP" -Value 1 -Type DWord
