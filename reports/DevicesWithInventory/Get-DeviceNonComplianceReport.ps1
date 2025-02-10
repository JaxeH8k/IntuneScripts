# Device Compliance Refresh & Export

Connect-MgGraph -NoWelcome

# request a report export
$graphSplat = @{
    uri    = 'https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs'
    method = 'POST'
    body   = @{
        filter = "(OS eq 'IOS')"
        format = 'json'
        reportName = 'NoncompliantDevicesAndSettings'
        select = @(
            "DeviceName",
            "SettingNm",
            "SettingStatus",
            "UPN",
            "ComplianceState",
            "OS",
            "LastContact",
            "UserEmail",
            "UserName",
            "DeviceId",
            "IMEI",
            "SerialNumber"
        )
        search = ''
    } | ConvertTo-Json -Depth 3
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
        ($exportRequestStatus.requestDateTime - $completedTime | Select-Object @{Name = 'RunTime'; Exp={"Report export completed in $($_.Minutes) minutes and $($_.Seconds) seconds."}}).RunTime
    }
}