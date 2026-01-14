# Reset Intune Device NodeCache with Logging
# Run as Administrator

$LogFile = "C:\temp\NodeFlush.log"

# Function to write to log file and console
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $LogEntry
    
    switch ($Level) {
        "ERROR" { Write-Host $Message -ForegroundColor Red }
        "SUCCESS" { Write-Host $Message -ForegroundColor Green }
        "WARNING" { Write-Host $Message -ForegroundColor Yellow }
        default { Write-Host $Message -ForegroundColor White }
    }
}

# Create log directory if it doesn't exist
try {
    if (-not (Test-Path "C:\temp")) {
        New-Item -Path "C:\temp" -ItemType Directory -Force | Out-Null
        Write-Log "Created C:\temp directory" "SUCCESS"
    }
    Write-Log "========== NodeCache Reset Started ==========" "INFO"
} catch {
    Write-Host "Failed to create log directory: $_" -ForegroundColor Red
    exit 1
}

# Get the Intune Provider ID from DMClient
try {
    Write-Log "Attempting to locate Intune Provider ID..." "INFO"
    $DMClientPath = "C:\ProgramData\Microsoft\DMClient"
    
    if (-not (Test-Path $DMClientPath)) {
        Write-Log "DMClient path not found: $DMClientPath" "ERROR"
        exit 1
    }
    
    $ProviderID = (Get-ChildItem -Path $DMClientPath -Directory | Where-Object { $_.Name -match "MS DM Server" }).Name
    
    if (-not $ProviderID) {
        Write-Log "Could not find Intune Provider ID in $DMClientPath" "ERROR"
        exit 1
    }
    
    Write-Log "Found Provider ID: $ProviderID" "SUCCESS"
} catch {
    Write-Log "Error locating Provider ID: $_" "ERROR"
    exit 1
}

# Define NodeCache registry paths
$NodeCachePaths = @(
    "HKLM:\SOFTWARE\Microsoft\Provisioning\NodeCache\CSP\Device\$ProviderID",
    "HKLM:\SOFTWARE\Microsoft\Provisioning\NodeCache\ProvisioningStatus\$ProviderID"
)

# Remove NodeCache registry keys
foreach ($path in $NodeCachePaths) {
    try {
        Write-Log "Checking registry path: $path" "INFO"
        
        if (Test-Path $path) {
            Write-Log "Path exists, attempting to remove..." "WARNING"
            Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
            Write-Log "Successfully removed: $path" "SUCCESS"
        } else {
            Write-Log "Path not found (may not exist): $path" "INFO"
        }
    } catch {
        Write-Log "Error removing $path : $_" "ERROR"
    }
}

# Restart Intune Management Extension service
try {
    Write-Log "Attempting to restart IntuneManagementExtension service..." "INFO"
    
    $service = Get-Service -Name IntuneManagementExtension -ErrorAction Stop
    Write-Log "Service current status: $($service.Status)" "INFO"
    
    Restart-Service -Name IntuneManagementExtension -Force -ErrorAction Stop
    
    Start-Sleep -Seconds 2
    $serviceAfter = Get-Service -Name IntuneManagementExtension
    Write-Log "Service restarted successfully. New status: $($serviceAfter.Status)" "SUCCESS"
} catch {
    Write-Log "Error restarting IntuneManagementExtension service: $_" "ERROR"
}

# Trigger MDM sync
try {
    Write-Log "Attempting to trigger MDM sync..." "INFO"
    
    $pushLaunchTask = Get-ScheduledTask | Where-Object { $_.TaskName -like "*PushLaunch*" }
    
    if ($pushLaunchTask) {
        Write-Log "Found scheduled task: $($pushLaunchTask.TaskName)" "INFO"
        Start-ScheduledTask -InputObject $pushLaunchTask -ErrorAction Stop
        Write-Log "MDM sync task started successfully" "SUCCESS"
    } else {
        Write-Log "PushLaunch scheduled task not found" "WARNING"
    }
} catch {
    Write-Log "Error triggering MDM sync: $_" "ERROR"
}

Write-Log "========== NodeCache Reset Complete ==========" "SUCCESS"
Write-Log "Device will rebuild cache on next sync cycle (5-10 minutes)" "INFO"
Write-Host "`nLog file saved to: $LogFile" -ForegroundColor Cyan
