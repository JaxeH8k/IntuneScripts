# Test-HttpsHandshake.ps1
# Tests HTTPS handshake and reports encryption type for a given URL

param (
    [Parameter(Mandatory=$true)]
    [string]$Url
)

try {
    # Create WebRequest to initiate HTTPS handshake
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = "GET"
    
    # Get response to complete handshake
    $response = $request.GetResponse()
    
    # Get SSL/TLS details
    $cert = $request.ServicePoint.Certificate
    $sslProtocol = $request.ServicePoint.SslProtocol
    $cipher = $request.ServicePoint.CurrentCipherAlgorithm
    $keyExchange = $request.ServicePoint.CurrentKeyExchangeAlgorithm
    
    # Output results
    Write-Output "HTTPS Handshake Successful for $Url"
    Write-Output "SSL/TLS Protocol: $sslProtocol"
    Write-Output "Cipher Algorithm: $cipher"
    Write-Output "Key Exchange Algorithm: $keyExchange"
    Write-Output "Certificate Subject: $($cert.Subject)"
    Write-Output "Certificate Issuer: $($cert.Issuer)"
    
    # Clean up
    $response.Close()
}
catch {
    Write-Error "HTTPS Handshake Failed: $($_.Exception.Message)"
}