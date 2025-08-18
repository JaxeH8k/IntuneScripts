# Background
Network Unlock is a Bitlocker feature that, when an endpoint is configured to require PIN before booting Windows; if the Endpoint can reach a WDS server with a corresponding certificate - the PIN can be bypassed and the endpoint boots right to Windows.

If the endpoint cannot reach the WDS server, a PIN is rquired to unlock the OSDrive and load Windows.

Documentation can be found at: https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/network-unlock

## What this script does.
Microsoft Intune doesn't provide the Settings for 

1. Enabling the feature
2. Installing the Certificate in the FVE_NKP section of the user registry.

Microsoft's documentation instructs users on how to deploy using AD Group Policy, but the corresponding tools are not extended to Intune.  

This script allows an admin to base64 encode the public certificate - and load it into the FVE_NKP section of the HKLM registry (HKLM:\SOFTWARE\Policies\Microsoft\SystemCertificates\FVE_NKP) and enable the Netowrk Unlock flag in the FVE bitlocker settings on the endpoint (HKLM:\SOFTWARE\Policies\Microsoft\FVE).

## Before deploying the script, add the base64 string to the first variable
Save the bitlocker unlock certificate locally on your workstation & convert to base64 string in your clipboard.

```PowerShell
$filePath = "C:\temp\bilockerUnlockCertificate.cer"
[System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($filePath)) | clip
```
Then paste the value into the script for

```PowerShell
$base64Cert = '{base64Goodness}' # your base64 encoded certificate (see comment above)
```
At this point the script is ready to deploy to your endpoints.  

Note: Have only tested this with self-signed certificates containing no CRL's or CA & SubCA's that would exist in a production environment.  Testing with a full certificate chain and CRL's is on my to do list.