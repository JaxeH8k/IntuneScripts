param(
    $policyId
)

$graphSplat = @{
    Method = 'POST'
    Uri = 'https://graph.microsoft.com/beta/deviceManagement/reports/getConfigurationPolicySettingsDeviceSummaryReport'
    body = @{
        top = 200 # settings
        skip = 0 # dont know
        select = @(
            'SettingId'
            'SettingName'
            'NumberOfCompliantDevices'
            'NumberOfErrorDevices'
            'NumberOfConflictDevices'
        )
        orderBy = @()
        search = ''
        filter = "(PolicyId eq '$policyId')"
    }
}

$req = Invoke-MgGraphRequest @graphSplat

$jsonReq = $req | ConvertFrom-Json 
$schema = $jsonReq.schema.column
$report = @()
foreach($record in $jsonReq.Values){
    $thisObj = [PSCustomObject]@{}
    for ($i = 0; $i -lt $record.Count; $i++) {
        Add-Member -InputObject $thisObj -MemberType NoteProperty -Name $schema[$i] -Value $record[$i] -Force
    }
    $report += $thisObj
}

$report | Export-Csv "$policyId.csv" -NoTypeInformation