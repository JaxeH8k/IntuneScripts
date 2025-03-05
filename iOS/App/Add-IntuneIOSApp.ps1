param(
    [string]$bundleId = $null,
    [string]$appId = $null
)

# get itunes app data
if ($null -like $bundleId -and $null -like $appId){
    return "Either -AppId or -BundleId required"
    exit 1
}

if($null -notlike $bundleId){
    $lookupVal = $bundleId
    $url = "https://itunes.apple.com/lookup?bundleId="
} elseIf ($null -notlike $appId){
    $lookupVal = $appId # google maps
    $url = "https://itunes.apple.com/lookup?id="
}
# get info from iOS Store for later use in creating the Intune Mobile App
$req = Invoke-RestMethod -Uri "$url$lookupVal"

# fetch image icon and convert to base64 // see https://raw.githubusercontent.com/microsoftgraph/powershell-intune-samples/refs/heads/master/Applications/Application_iOS_Add.ps1
$iconUrl = $req.results.artworkUrl60
if ($iconUrl -eq $null){
    $iconUrl = $app.results.artworkUrl100

    if ($iconUrl -eq $null){
        $iconUrl = $req.results.iconfUrl512
    }
}
$iconResponse = Invoke-WebRequest $iconUrl
$base64icon = [System.Convert]::ToBase64String($iconResponse.Content)
$iconType = $iconResponse.Headers["Content-Type"]

# supported device info
$ipad = "false"
$iphone = "false"
foreach($dev in $req.results.supportedDevices){
    if ($dev -match 'iPad'){
        $ipad = "true"
    }
    if ($dev -match 'iPhone'){
        $iphone = "true"
    }
}

# minimum supported os info
if ($req.results.minimumOsVersion.split(".").Count -gt 2){
    # take first two items for double
    $ver = $req.results.minimumOsVersion.split(".")[0..1] -join "."
    $osVersion = [Convert]::ToDouble($ver)
}else{
    $osVersion = [Convert]::ToDouble($req.results.minimumOsVersion)
}

switch ($osVersion){
    {$_ -lt 9}                          {$minOsVersion = "`"v8_0`": true"}
    {$_.ToString().StartsWith("9")}     {$minOsVersion = "`"v9_0`": true"}
    {$_.ToString().StartsWith("10")}    {$minOsVersion = "`"v10_0`": true"}
    {$_.ToString().StartsWith("11")}    {$minOsVersion = "`"v11_0`": true"}
    {$_.ToString().StartsWith("12")}    {$minOsVersion = "`"v12_0`": true"}
    {$_.ToString().StartsWith("13")}    {$minOsVersion = "`"v13_0`": true"}
    {$_.ToString().StartsWith("14")}    {$minOsVersion = "`"v14_0`": true"}
    {$_.ToString().StartsWith("15")}    {$minOsVersion = "`"v15_0`": true"}
    {$_.ToString().StartsWith("16")}    {$minOsVersion = "`"v16_0`": true"}
    {$_.ToString().StartsWith("17")}    {$minOsVersion = "`"v17_0`": true"}
    {$_.ToString().StartsWith("18")}    {$minOsVersion = "`"v18_0`": true"}
    {$_.ToString().StartsWith("19")}    {$minOsVersion = "`"v19_0`": true"}
}

$graphSplat = @{
    uri = 'https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps'
    method = 'POST'
    contentType = 'application/json'
    body = "{
        `"@odata.type`": `"microsoft.graph.iosStoreApp`",
        `"displayName`": `"$($req.results.trackName)`",
        `"description`": `"$($req.results.description)`",
        `"publisher`": `"$($req.results.sellerName)`",
        `"largeIcon`": {
            `"@odata.type`": `"microsoft.graph.mimeContent`",
            `"type`": `"$iconType`",
            `"value`": `"$base64icon`"
        },
        `"isFeatured`": false,
        `"owner`": `"DangerousAdmins`",
        `"publisher`": `"$($req.results.sellerName)`",
        `"applicableDeviceType`": {
            `"@odata.type`": `"microsoft.graph.iosDeviceType`",
            `"iPad`": $ipad,
            `"iPhoneAndIPod`": $iphone
        },
        `"privacyInformationUrl`": `"$($req.results.sellerUrl)`",
        `"informationUrl`": `"$($req.results.sellerUrl)`",
        `"notes`": `"$($req.results.releaseNotes)`",
        `"appStoreUrl`": `"$($req.results.trackViewUrl)`",
        `"bundleId`": `"$($req.results.bundleId)`",
        `"minimumSupportedOperatingSystem`": {
            `"@odata.type`": `"microsoft.graph.iosMinimumOperatingSystem`",
                $($minOsVersion)
        }
    }"
}

Invoke-MgGraphRequest @graphSplat