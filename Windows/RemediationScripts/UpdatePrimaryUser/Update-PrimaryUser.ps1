#!/usr/bin/pwsh 

# load entra helpers 
. .\Update-PrimaryUserHelpers.ps1

$cache = Import-EntraIdCache

# import the Primary User Remediation Detection Output from Intune
$import = Import-CSV -Path sample.csv | 
	where-object DetectionScriptStatus -eq 'Without Issues' 

$updates = [System.Collections.Generic.List[psobject]]::new()
foreach ($result in $import) {
	$sid = ($result.PreRemediationDetectionScriptOutput | ConvertFrom-Json ).MostActiveSid
	if ($null -notlike $sid) {
		$updates.add(
			[PSCustomObject]@{
				deviceId = $result.DeviceId
				userSid  = $sid
			}
		)
	}
}

# import sorted device inventory
$devices = import-csv "./inventory.csv" | Sort-Object -Property 'Device Id'

# create a hashmap to speed up Where-Object array filtering
$prefixIndex = [ordered]@{}
for ($i = 0; $i -lt $devices.Count; $i++) {
	$prefix = $devices[$i].'Device ID'.Substring(0, 4).ToLowerInvariant()

	if ($prefixIndex.Contains($prefix)) {
		$prefixIndex[$prefix].lastLoc = $i
	}
	else {
		<# the first time prefix is seen, init prefixIndex@{} mapping 
			first & last are same (first loc = $i; last loc = $i)
		                 **this is ok**
		            lastLoc is updated separately 
		#>
		$prefixIndex[$prefix] = [pscustomobject]@{ firstLoc = $i; lastLoc = $i }
	}
}

$updated = 0
$skipped = 0

foreach($device in $updates){
	$deviceId = $device.deviceId
	$bucket = $prefixIndex[$deviceId.Substring(0, 4).ToLowerInvariant()]
	if ($bucket) {
		$intuneDevice = $devices[$bucket.firstLoc..$bucket.lastLoc] |
			Where-Object { $_.'Device Id' -eq $deviceId }
		if($intuneDevice) {
			# resolve the user SID, request back the users upn to match against the remediation output
			$upn = Resolve-EntraObjectId -Sid $device.userSid -Cache $cache -getUpn
			if ($null -notlike $upn){
				if ($upn -ne $intuneDevice.'Primary user UPN'){
					# update Intune device primary user id. $false back means Graph refused the
					# user (no Intune licence / deleted) - already logged, so keep going.
					$changed = Set-IntunePrimaryUser -DeviceId $device.deviceId `
						-UserObjectId $cache[($device.userSid)].id `
						-DeviceName $intuneDevice.'Device name' `
						-PreviousUserUpn $intuneDevice.'Primary user UPN' `
						-NewUserUpn $upn
					if ($changed) { $updated++ } else { $skipped++ }
				}
			}
		}
	}
}

Write-GraphLog -Level Information -Operation 'UpdatePrimaryUser' -Message "Run complete - $updated device(s) updated, $skipped skipped" -Data @{
	devicesConsidered = $updates.Count
	devicesUpdated    = $updated
	devicesSkipped    = $skipped
}
