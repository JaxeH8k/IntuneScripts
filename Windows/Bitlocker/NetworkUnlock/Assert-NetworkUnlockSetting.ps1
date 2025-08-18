<# Genearate value for var $base64Cert by pasting the response from
    converting your public key exported bitlocker network unlock cert
    with the following:
    $filePath = "C:\temp\bilockerUnlockCertificate.cer"
    [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($filePath)) | clip

#>

$base64Cert = '' # your base64 encoded certificate (see comment above)

# logging
function Write-Log {
    param(
        [string]$message,
        [string]$logLevel = "Info"
    )

    $eventTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss.ffff"
    "$eventTime | $logLevel | $message" | Tee-Object -FilePath $logPath -Append
}

$logLocation = "C:\programdata\DGTK\Bitlocker\Enable-NetworkUnlock $(get-date -format 'yyyy-MM-dd HH:mm:ss').log"
# test if parent directory exists
if(! (Test-Path (Split-Path $logLocation -Parent))){
    New-Item (Split-Path $logLocation -Parent) -ItemType Directory -Force
}

Write-Log "---Begin Enablement of Network Unlock Script---"

$certBytes = [System.Convert]::FromBase64String($base64Cert)
if($?){
    Write-Log 'Converted public network unlock script from base64 string to byte array'
}else{
    Write-Log "$error[0].ErrorMessage" -logLevel "Error"
    Exit 1
}
try{
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,$certBytes) -ErrorAction Stop
    Write-Log 'Converted byte array to x509 certificate object'
}catch{
    Write-Log "Failed to convert byte array to x509 certificate object"
    Write-Log "$_" -logLevel "Error"
    Exit 1
}

Write-Log "Construct GPO registry blob representing the certificate (header + thumbrint bytes + prefix (+ cert length) + certificate data)"
if( $cert.PSObject.Properties["RawData"]){
    Write-Log 'X509 Certificate Contains Data.  Proceed...'
    $certData = $cert.RawData
}else{
    Write-Log 'X509 Certificate Object Contains no Data. Exit'
    Exit 1
}

Write-Log 'X509 cert succesfully contructed. Proceed to construct registry blob'
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
    "HKLM:\SOFTWARE\Policies\Microsoft\SystemCertificates\FVE_NKP\Certificates\$thumbprint",
    "HKLM:\SOFTWARE\Policies\Microsoft\SystemCertificates\FVE_NKP\CRLs",
    "HKLM:\SOFTWARE\Policies\Microsoft\SystemCertificates\FVE_NKP\CTLs"
)
foreach($regPath in $regPaths){
    if(! (test-Path -path $regPath)){
        try{
            New-Item -Path $regPath -Force -ErrorAction Stop
            Write-Log "Created $regPath succesfully."
        }catch{
            Write-Log "$_" -logLevel 'Error'
            Write-Log "Failed to create $regPath" -logLevel 'Error'
        }
    }else{
        Write-Log "$regPath already exists. Skipping..."
    }
}
try{
    Set-ItemProperty -Path $regPaths[0] -Name "Blob" -Value $Blob -Type Binary -ErrorAction Stop
    Write-Log 'Succesfully wrote certificate binary data to registry'
}catch{
    Write-Log "$_" -logLevel 'Error'
    Exit 1
}
try{
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\FVE" -Name "OSManageNKP" -Value 1 -Type DWord -ErrorAction Stop
    Write-Log 'Succefully wrote registry value for gpo setting "Allow Network Unlock"'
}catch{
    Write-Log "$_" -logLevel 'Error'
    Exit 1
}
