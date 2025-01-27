# Device Compliance Refresh & Export

Connect-MgGraph -NoWelcome

# POST to Graph a request to refresh the compliance summary
$graphSplat = @{
    uri    = 'https://graph.microsoft.com/beta/deviceManagement/reports/cachedReportConfigurations'
    method = 'POST'
    body   = "
    {
    `"id`": `"DeviceCompliance_00000000-0000-0000-0000-000000000001`",
    `"filter`": `"OS eq 'IOS'`",
    `"orderBy`": [],
    `"select`": [
        `"DeviceName`",
        `"UPN`",
        `"ComplianceState`",
        `"OS`",
        `"OwnerType`",
        `"LastContact`",
        `"SerialNumber`"
    ],
    `"localizationType`": `"ReplaceLocalizableValues`"
    }
    "
}

$refreshRequest = Invoke-MgGraphRequest @graphSplat

# Wait for refresh to complete
$status = $refreshRequest.status
$graphSplat = @{
    uri    = "https://graph.microsoft.com/beta/deviceManagement/reports/cachedReportConfigurations('DeviceCompliance_00000000-0000-0000-0000-000000000001')"
    method = 'GET'
}
while ($status -ne 'completed') {
    $requestStatus = Invoke-MgGraphRequest @graphSplat
    $status = $requestStatus.status
    if ($status -ne 'completed') {
        Start-Sleep 30
    }
}

# refresh is completed by this point, request a report export
$graphSplat = @{
    uri    = 'https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs'
    method = 'POST'
    body   = "{
        `"filter`": `"`",
        `"format`": `"csv`",
        `"search`": `"`",
        `"select`": [
            `"DeviceName`",
            `"UPN`",
            `"ComplianceState`",
            `"OS`",
            `"OSVersion`",
            `"OwnerType`",
            `"LastContact`",
            `"SerialNumber`"
    ],
    `"snapshotId`": `"DeviceCompliance_00000000-0000-0000-0000-000000000001`",
    `"reportName`": `"DeviceCompliance`"
    }"
}
$exportRequest = Invoke-MgGraphRequest @graphSplat

# Wait for refresh to complete
$status = $exportRequest.status
while ($status -ne 'completed') {
    $graphSplat = @{
        uri    = "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs('$($exportRequest.id)')"
        method = 'GET'
    }
    $exportRequestStatus = Invoke-MgGraphRequest @graphSplat
    $status = $exportRequestStatus.status
    if ($status -ne 'completed') {
        Start-Sleep 300 # delay 5 minutes
    }
    else {
        $completedTime = Get-Date
        Invoke-MgGraphRequest -Uri $exportRequestStatus.url -OutputFilePath (Join-Path $home "$(Get-Date -format 'yyyyMMdd')-report.zip") -Method 'GET' -ContentType 'application/json'
        ($exportRequestStatus.requestDateTime - $completedTime | select @{Name = 'RunTime'; Exp={"Report export completed in $($_.Minutes) minutes and $($_.Seconds) seconds."}}).RunTime
    }
}