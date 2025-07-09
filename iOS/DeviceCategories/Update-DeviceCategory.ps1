# Requires Microsoft.Graph.Authentication module for Connect-MgGraph
# Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

# Write-Log function to output to console and log file
# Define log file path (create Logs directory if it doesn't exist)
$logDir = Join-Path $HOME "Downloads/IntuneLogs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$logFile = Join-Path $logDir "IntuneDeviceCategory_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    
    # Write to console and append to log file using Tee-Object
    $logMessage | Tee-Object -FilePath $logFile -Append
}

# Connect to Microsoft Graph with required scope
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.ReadWrite.All"

# Define category IDs (replace with your actual category IDs from Intune)
$copeCategoryId = "d1e5b96d-862c-4bb9-8729-cdc65b5bf634" # Finkelstein
$byodCategoryId = "389951a6-9482-4c5a-bdc6-111d89ff7c1a"

# Request DevicesWithInventory report
$reportUri = "https://graph.microsoft.com/v1.0/deviceManagement/reports/exportJobs"
$body = @{
    reportName = "DevicesWithInventory"
    filter = "((DeviceType eq '8') or (DeviceType eq '9') or (DeviceType eq '10'))"
    select = @(
        "DeviceId",
        "DeviceName",
        "CategoryName"
    )
    format = "csv"
} | ConvertTo-Json

# Initiate report export job
$response = Invoke-MgGraphRequest -Method POST -Uri $reportUri -Body $body -ContentType "application/json"
$jobId = $response.id

# Poll for report completion
$statusUri = "https://graph.microsoft.com/v1.0/deviceManagement/reports/exportJobs('$jobId')"
$maxRetries = 30
$retryCount = 0
$delaySeconds = 5

do {
    Start-Sleep -Seconds $delaySeconds
    $jobStatus = Invoke-MgGraphRequest -Method GET -Uri $statusUri
    $retryCount++
} while ($jobStatus.status -ne "completed" -and $retryCount -lt $maxRetries)

if ($jobStatus.status -ne "completed") {
    Write-Log "Report generation timed out after $($maxRetries * $delaySeconds) seconds."
    Disconnect-MgGraph
    exit
}

# Download the CSV report (zip)
$csvUrl = $jobStatus.url
$tempFile = ([System.IO.Path]::GetTempFileName()).Replace('.tmp','.zip')
Invoke-WebRequest -Uri $csvUrl -OutFile $tempFile

# Decompress Zip
$tempFileParent = Join-Path "$(split-path $tempFile -Parent)\" (Get-ChildItem $tempFile).BaseName
Expand-Archive $tempFile -DestinationPath $tempFileParent
$reportFile = (Get-ChildItem $tempFileParent\*.csv | Select-Object -First 1).fullname

# Read the CSV and filter for uncategorized iOS devices
$devices = Import-Csv -Path $reportFile
$uncategorizedDevices = $devices | Where-Object {
    $_.'Category' -eq "" -or $_.'Category' -eq "Uncategorized"
}

if($uncategorizedDevices.count -gt 0){
# Process uncategorized devices
foreach ($device in $uncategorizedDevices) {
    $categoryId = if ($device.'Device Name' -like "J_*") { $copeCategoryId } else { $byodCategoryId }
    
    # Assign category using Graph API
    $updateUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($device.'Device Id')/deviceCategory/`$ref"
    $updateBody = @{
        "@odata.id" = "https://graph.microsoft.com/v1.0/deviceManagement/deviceCategories/$categoryId"
    } | ConvertTo-Json
    
    try {
        Invoke-MgGraphRequest -Method PUT -Uri $updateUri -Body $updateBody -ContentType "application/json"
        Write-Log "Assigned $($device.'Device Name') to $(if ($categoryId -eq $copeCategoryId) { 'COPE' } else { 'BYOD' })"
    }
    catch {
        Write-Log "Error updating $($device.'Device Name'): $_"
    }
}
# Output results
    Write-Log "Processed $($uncategorizedDevices.Count) uncategorized iOS devices"
} else {
    write-log "No devices to update in Intune"
}

# Clean up temporary file
Remove-Item -Path $tempFile -Force

# Disconnect from Graph
Disconnect-MgGraph