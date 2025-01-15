# Connect to Microsoft Graph
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"

# Define the API endpoint for the DevicesWithInventory report
$graphApiEndpoint = "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs"

$mfgr = 'QEMU'
$mdl = 'Standard PC (Q35 + ICH9, 2008)'

# Prepare the body for the POST request
$requestBody = @{
    filter     = "(((DeviceType eq '0') or (DeviceType eq '1') or (DeviceType eq '7') or (DeviceType eq '16') or (DeviceType eq '19') or (DeviceType eq '4') or (DeviceType eq '15')) and ((Manufacturer eq '$mfgr') and (Model eq '$mdl')))"
    select     = @(
        "DeviceId",
        "DeviceName",
        "managementAgent",
        "OS",
        "LastContact",
        "Model",
        "Manufacturer"
    )
    format     = 'csv'
    reportName = "DevicesWithInventory"
    search     = ""
} | ConvertTo-Json

# Start the export job
$exportJob = Invoke-MgGraphRequest -Method POST -Uri $graphApiEndpoint -Body $requestBody -ContentType "application/json"

# Wait for the job to complete (you might need to adjust the wait time based on the size of your data)
Start-Sleep -Seconds 30

# Check if the export job is completed
$jobStatus = Invoke-MgGraphRequest -Method GET -Uri "$graphApiEndpoint/$($exportJob.id)"

while ($jobStatus.status -ne "completed") {
    Start-Sleep -Seconds 10
    $jobStatus = Invoke-MgGraphRequest -Method GET -Uri "$graphApiEndpoint/$($exportJob.id)"
}

# Download the report
$downloadUrl = $jobStatus.url
$response = Invoke-WebRequest -Uri $downloadUrl -OutFile ".\report.zip"

# Extract the CSV file from the zip
Expand-Archive -Path "C:\temp\DevicesWithInventory.zip" -DestinationPath "C:\temp\"

# The CSV file will be in C:\temp with potentially a name like "report.csv"