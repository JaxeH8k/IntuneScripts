param(
    $certType
)

$dbBytes = [byte[]](Get-SecureBootUEFI -Name $certType).bytes

$offset = 0
$certs = [System.Collections.Generic.List[System.Security.Cryptography.X509Certificates.X509Certificate2]]::new()

while ($offset -lt $dbBytes.Length) {
    $guidBytes     = [byte[]]$dbBytes[$offset..($offset + 15)]
    $signatureType = [System.Guid]::new($guidBytes)
    $listSize      = [BitConverter]::ToUInt32($dbBytes, $offset + 16)
    $headerSize    = [BitConverter]::ToUInt32($dbBytes, $offset + 20)
    $signatureSize = [BitConverter]::ToUInt32($dbBytes, $offset + 24)

    $entryOffset = $offset + 28 + $headerSize

    while ($entryOffset -lt ($offset + $listSize)) {
        # signatureSize includes the 16-byte owner GUID, so cert length = signatureSize - 16
        $certStart = $entryOffset + 16
        $certEnd   = $entryOffset + $signatureSize - 1
        $certBytes = [byte[]]$dbBytes[$certStart..$certEnd]

        try {
            $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certBytes)
            $certs.Add($cert)
        } catch {
            Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }

        $entryOffset += $signatureSize
    }

    $offset += $listSize
}

# After building $certs from the previous script, export each one:

$outputPath = "$env:USERPROFILE\Desktop\SecureBootCerts"
New-Item -Path $outputPath -ItemType Directory -Force | Out-Null

for ($i = 0; $i -lt $certs.Count; $i++) {
    $safeName = $certs[$i].Subject -replace '[\\/:*?"<>|]', '_'
    $filePath = Join-Path $outputPath "Cert_${i}_${safeName}.cer"
    [System.IO.File]::WriteAllBytes($filePath, $certs[$i].RawData)
    Write-Host "Saved: $filePath" -ForegroundColor Green
}