param(
    $policyId,
    $outputFolder
)

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

$report | Export-Csv (join-path $outputFolder "$policyId.csv") -NoTypeInformation