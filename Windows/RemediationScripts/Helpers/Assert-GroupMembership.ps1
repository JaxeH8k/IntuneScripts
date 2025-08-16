# Runs as SYSTEM, uses Intune device certificate to connect to Graph API
# No dependency on Microsoft.Graph module

# Get device certificate
$cert = Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { $_.Issuer -like "*Intune*" }

# Define parameters
$tenantId = "your-tenant-id"
$clientId = "0000000a-0000-0000-c000-000000000000"
$groupId = "your-group-id"
$tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
$graphUrl = "https://graph.microsoft.com/v1.0/groups/$groupId/members"

# Create JWT assertion
$jwtHeader = @{ alg = "RS256"; x5t = $cert.Thumbprint } | ConvertTo-Json
$jwtPayload = @{
    aud = $tokenUrl
    iss = $clientId
    sub = $clientId
    jti = [guid]::NewGuid().ToString()
    exp = [int][double]((Get-Date).AddMinutes(60).ToUniversalTime() -UFormat %s)
} | ConvertTo-Json
$jwtHeaderBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($jwtHeader)) -replace '\+','-' -replace '/','_' -replace '='
$jwtPayloadBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($jwtPayload)) -replace '\+','-' -replace '/','_' -replace '='
$jwtToSign = "$jwtHeaderBase64.$jwtPayloadBase64"
$jwtSignature = [Convert]::ToBase64String($cert.PrivateKey.SignData([System.Text.Encoding]::UTF8.GetBytes($jwtToSign), "SHA256")) -replace '\+','-' -replace '/','_' -replace '='
$clientAssertion = "$jwtHeaderBase64.$jwtPayloadBase64.$jwtSignature"

# Request access token
$body = @{
    client_id = $clientId
    scope = "https://graph.microsoft.com/.default"
    client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
    client_assertion = $clientAssertion
    grant_type = "client_credentials"
}
$response = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"
$accessToken = $response.access_token

# Fetch group members
$headers = @{ Authorization = "Bearer $accessToken" }
$members = Invoke-RestMethod -Uri $graphUrl -Method Get -Headers $headers

# Output member details
foreach ($member in $members.value) {
    Write-Output "Member: $($member.id), DisplayName: $($member.displayName)"
}