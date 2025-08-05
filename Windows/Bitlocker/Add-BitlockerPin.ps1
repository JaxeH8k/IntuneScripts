# Defining log file path and function for logging
$logFile = "C:\Logs\BitLockerPinLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
$osDrive = $env:SystemDrive

# Creating log directory if it doesn't exist
if (-not (Test-Path -Path "C:\Logs")) {
    New-Item -ItemType Directory -Path "C:\Logs" -Force
}

# Logging function
function Write-Log {
    param($Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Tee-Object -FilePath $logFile -Append
}

# Starting log
Write-Log "Starting script to add BitLocker startup PIN to OS drive ($osDrive)"

try {
    # Checking for administrative privileges
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Log "ERROR: Script not running with administrative privileges"
        throw "This script requires administrative privileges. Please run as Administrator."
    }
    Write-Log "Administrative privileges confirmed"

    # Checking if TPM is available
    $tpm = Get-Tpm -ErrorAction SilentlyContinue
    if (-not $tpm -or -not $tpm.TpmReady) {
        Write-Log "ERROR: TPM not available or not ready"
        throw "TPM is required for BitLocker with PIN. Ensure TPM is enabled and ready."
    }
    Write-Log "TPM is available and ready"

    # Checking if BitLocker is already enabled on OS drive
    $bitLockerStatus = Get-BitLockerVolume -MountPoint $osDrive -ErrorAction Stop
    if ($bitLockerStatus.ProtectionStatus -eq "On" -and $bitLockerStatus.EncryptionPercentage -eq 100) {
        Write-Log "BitLocker already enabled on $osDrive"
    }
    elseif ($bitLockerStatus.ProtectionStatus -eq "Off" -and $bitLockerStatus.EncryptionPercentage -gt 0){
        # Seeing windows enabling bitlocker, but without a TPMPIN, it's not showing protection status "On"
        Write-Log "Bitlocker Encrypted but Protection Status not showing On.  Proceed to adding TPMPIN"
    }
    else {
        Write-Log "Enabling BitLocker on $osDrive"
        try {
            Enable-BitLocker -MountPoint $osDrive -EncryptionMethod XtsAes128 -UsedSpaceOnly -RecoveryPasswordProtector -ErrorAction Stop
            Write-Log "SUCCESS: BitLocker enabled on $osDrive with recovery password"
        }
        catch {
            Write-Log "ERROR: Failed to enable BitLocker on $osDrive. Error: $_"
            throw
        }
    }

    # Defining the startup PIN (replace '123456' with your desired PIN)
    $pin = ConvertTo-SecureString "123456" -AsPlainText -Force
    Write-Log "Attempting to add BitLocker startup PIN"

    # Adding TPM and PIN protector
    try {
        $protector = Add-BitLockerKeyProtector -MountPoint $osDrive -TpmAndPinProtector -Pin $pin -ErrorAction Stop
        Write-Log "SUCCESS: Added TPM and PIN protector to $osDrive"
    }
    catch {
        Write-Log "ERROR: Failed to add TPM and PIN protector. Error: $_"
        throw
    }

    # Verifying the key protector
    $keyProtectors = Get-BitLockerVolume -MountPoint $osDrive -ErrorAction Stop
    if ($keyProtectors.KeyProtector | Where-Object { $_.KeyProtectorType -eq "TpmAndPin" }) {
        Write-Log "SUCCESS: Verified TPM and PIN protector on $osDrive"
    }
    else {
        Write-Log "ERROR: Verification failed - TPM and PIN protector not found"
        throw "Failed to verify TPM and PIN protector"
    }

    Write-Log "Script completed successfully. Restart required for PIN to take effect."
}
catch {
    Write-Log "CRITICAL ERROR: Script failed. Error: $_"
    exit 1
}