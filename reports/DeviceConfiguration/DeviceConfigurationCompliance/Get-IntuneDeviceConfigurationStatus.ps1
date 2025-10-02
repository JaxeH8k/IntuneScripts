param(
    $policyId,
    $outputFolder
)

<# option 1 - overview (not a report export)
requires Top X
Example
Request URI: https://graph.microsoft.com/beta/deviceManagement/reports/getConfigurationPolicyDevicesReport
Method: POST
Body:
    {
    "select": [
        "DeviceName",
        "UPN",
        "ReportStatus",
        "AssignmentFilterIds",
        "PspdpuLastModifiedTimeUtc",
        "IntuneDeviceId",
        "UnifiedPolicyPlatformType",
        "UserId",
        "PolicyStatus",
        "PolicyBaseTypeName"
    ],
    "skip": 0,
    "top": 50,
    "filter": "((PolicyBaseTypeName eq 'Microsoft.Management.Services.Api.DeviceConfiguration') or (PolicyBaseTypeName eq 'DeviceManagementConfigurationPolicy') or (PolicyBaseTypeName eq 'DeviceConfigurationAdmxPolicy')) and (PolicyId eq '5a334634-cb15-40fa-9c0e-b4bfcf7866f5')",
    "orderBy": []
    }
#>
<# Or Option 2, a full blown report export
Request URI: https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs
Method: POST
Body:
    {
    "reportName": "DeviceStatusesByConfigurationProfile",
    "filter": "((PolicyBaseTypeName eq 'Microsoft.Management.Services.Api.DeviceConfiguration') or (PolicyBaseTypeName eq 'DeviceManagementConfigurationPolicy') or (PolicyBaseTypeName eq 'DeviceConfigurationAdmxPolicy')) and (PolicyId eq '5a334634-cb15-40fa-9c0e-b4bfcf7866f5')",
    "select": [
        "DeviceName",
        "UPN",
        "ReportStatus",
        "AssignmentFilterIds",
        "PspdpuLastModifiedTimeUtc"
    ],
    "format": "csv",
    "snapshotId": ""
    }

followed by job status requests... 
URI: https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs('DeviceStatusesByConfigurationProfileWithPFV3_f0337853-f0d5-42e5-991c-291a85dae9ca')
Method: GET
#>

if (! (Test-Path $outputFolder)){
    try {
        New-Item $outputFolder -ItemType Directory -ErrorAction Stop
    } 
    catch{
        Write-Output "$_"
        Write-Output "Failed to create director $($outputFolder) ... Param should be a folder path. Exit 1"
        Exit 1
    }
}

# test path is writeable // basic touch test, exit if fail
try {
    New-Item -Name 'TestFile.txt' -Path $outputFolder -ErrorAction Stop
    Remove-Item (join-path $outputFolder 'TestFile.txt')
}
catch {
    Write-Output "$_"
    Write-Output "Failed to write test file at location.  Exit 1"
    Exit 1
}

$graphSplat = @{
    URI = 'https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs'
    Method = 'POST'
    Body = @{
        reportName = "DeviceStatusesByConfigurationProfile"
        filter = "((PolicyBaseTypeName eq 'Microsoft.Management.Services.Api.DeviceConfiguration') or (PolicyBaseTypeName eq 'DeviceManagementConfigurationPolicy') or (PolicyBaseTypeName eq 'DeviceConfigurationAdmxPolicy')) and (PolicyId eq '$policyId')"
        select = @(
            "DeviceName",
            "UPN",
            "ReportStatus",
            "AssignmentFilterIds",
            "PspdpuLastModifiedTimeUtc"
        )
        format = 'csv'
        snapshotId = ''
    } | ConvertTo-Json -Depth 4
    ErrorAction = "STOP"
}

try {
    $req = Invoke-MgGraphRequest @graphSplat 
    Write-Output "Requestion Made Succesfully... proceed to query and wait for report to become available."
}
catch{
    Write-Output "Graph Request No Bueno!"
    throw "$_"
}

Start-Sleep 15
$graphSplat = @{ 
    uri = "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs('$($req.id)')"
    method = 'GET'
}
$reqStatus = Invoke-MgGraphRequest @graphSplat

while ( $reqStatus.status -ne 'completed'){
    Start-Sleep 30
    Write-Output 'Checking report status...'
    $reqStatus = Invoke-MgGraphRequest @graphSplat
}

Write-Output 'Report generation complete and ready for download'

$graphSplat = @{
    method = 'get'
    uri = $reqStatus.url
    outputFilePath = (join-path $outputFolder "$policyId.csv")
}

Invoke-MgGraphRequest @graphSplat