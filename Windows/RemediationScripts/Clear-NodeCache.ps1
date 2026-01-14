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
}
catch {
    Write-Host "Failed to create log directory: $_" -ForegroundColor Red
    exit 1
}

# Get the Intune Enrollment GUID from registry
try {
    Write-Log "Attempting to locate Intune Enrollment GUID..." "INFO"
    $EnrollmentsPath = "HKLM:\SOFTWARE\Microsoft\Enrollments"
    
    if (-not (Test-Path $EnrollmentsPath)) {
        Write-Log "Enrollments registry path not found: $EnrollmentsPath" "ERROR"
        exit 1
    }
    
    # Find the Intune enrollment by looking for ProviderID = "MS DM Server"
    $EnrollmentGUIDs = Get-ChildItem -Path $EnrollmentsPath | Where-Object {
        $providerID = (Get-ItemProperty -Path $_.PSPath -Name "ProviderID" -ErrorAction SilentlyContinue).ProviderID
        $providerID -eq "MS DM Server"
    }
    
    if (-not $EnrollmentGUIDs -or $EnrollmentGUIDs.Count -eq 0) {
        Write-Log "Could not find Intune enrollment (ProviderID = 'MS DM Server') in registry" "ERROR"
        exit 1
    }
    
    $EnrollmentGUID = $EnrollmentGUIDs[0].PSChildName
    Write-Log "Found Enrollment GUID: $EnrollmentGUID" "SUCCESS"
}
catch {
    Write-Log "Error locating Enrollment GUID: $_" "ERROR"
    exit 1
}

# Define NodeCache registry paths
$NodeCachePaths = @(
    "HKLM:\SOFTWARE\Microsoft\Provisioning\NodeCache\CSP\Device\MS DM Server",
    "HKLM:\SOFTWARE\Microsoft\Provisioning\NodeCache\ProvisioningStatus\MS DM Server"
)

# Remove NodeCache registry keys
foreach ($path in $NodeCachePaths) {
    try {
        Write-Log "Checking registry path: $path" "INFO"
        
        if (Test-Path $path) {
            Write-Log "Path exists, attempting to remove..." "WARNING"
            Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
            Write-Log "Successfully removed: $path" "SUCCESS"
        }
        else {
            Write-Log "Path not found (may not exist): $path" "INFO"
        }
    }
    catch {
        Write-Log "Error removing $path : $_" "ERROR"
    }
}

# Restart Intune Management Extension service
try {
    Write-Log "Attempting to restart IntuneManagementExtension service..." "INFO"
    
    $service = Get-Service -Name IntuneManagementExtension -ErrorAction Stop
    Write-Log "IntuneManagementExtension Service current status: $($service.Status)" "INFO"
    
    Restart-Service -Name IntuneManagementExtension -Force -ErrorAction Stop
    
    Start-Sleep -Seconds 15
    $serviceAfter = Get-Service -Name IntuneManagementExtension
    Write-Log "IntuneManagementExtension Service restarted successfully. New status: $($serviceAfter.Status)" "SUCCESS"
}
catch {
    Write-Log "Error restarting IntuneManagementExtension service: $_" "ERROR"
}

# Trigger MDM sync
try {
    Write-Log "Attempting to trigger MDM sync..." "INFO"
    
    $pushLaunchTasks = Get-ScheduledTask | Where-Object { $_.TaskName -like "*PushLaunch*" }
    if ($pushLaunchTasks) {
        foreach ($pushLaunchTask in $pushLaunchTasks) {
            Write-Log "Found scheduled task: $($pushLaunchTask.TaskName)" "INFO"
            Start-ScheduledTask -InputObject $pushLaunchTask -ErrorAction Stop
            Write-Log "MDM sync task started successfully" "SUCCESS"
        }
    }
    else {
        Write-Log "PushLaunch scheduled task not found" "WARNING"
    }
}
catch {
    Write-Log "Error triggering MDM sync: $_" "ERROR"
}

Write-Log "========== NodeCache Reset Complete ==========" "SUCCESS"
Write-Log "Device will rebuild cache on next sync cycle (5-10 minutes)" "INFO"
Write-Host "`nLog file saved to: $LogFile" -ForegroundColor Cyan
