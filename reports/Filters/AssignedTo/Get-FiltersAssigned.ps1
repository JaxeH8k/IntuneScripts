<#
.SYNOPSIS
    Gets all Intune device filters and lists the configurations/policies each filter is assigned to.

.DESCRIPTION
    Retrieves all assignment filters from Microsoft Intune via the Graph API, then queries
    each filter's /payloads endpoint to get the policies/configurations assigned with that filter.
    Uses Graph $batch requests to resolve payload display names and group display names.

    Uses Invoke-MgGraphRequest exclusively for all Graph API calls.
    Supports Commercial, GCC High, and DoD cloud environments.

.PARAMETER Environment
    The cloud environment to connect to. Valid values: Commercial, USGovGCCHigh, USGovDoD.
    Defaults to Commercial.

.PARAMETER ExportCsv
    Optional path to export results as a CSV file.

.EXAMPLE
    .\Get-FiltersAssigned.ps1

.EXAMPLE
    .\Get-FiltersAssigned.ps1 -Environment USGovGCCHigh

.EXAMPLE
    .\Get-FiltersAssigned.ps1 -ExportCsv "C:\Reports\FilterAssignments.csv"
#>

[CmdletBinding()]
param(
    [ValidateSet("Commercial", "USGovGCCHigh", "USGovDoD")]
    [string]$Environment = "Commercial",

    [string]$ExportCsv
)

#region --- Configuration ---

$graphBaseUrls = @{
    Commercial   = "https://graph.microsoft.com"
    USGovGCCHigh = "https://graph.microsoft.us"
    USGovDoD     = "https://dod-graph.microsoft.us"
}

$graphEnvironments = @{
    Commercial   = "Global"
    USGovGCCHigh = "USGov"
    USGovDoD     = "USGovDoD"
}

$graphBaseUrl = $graphBaseUrls[$Environment]
$apiVersion = "beta"

# Maps payloadType enum values (associatedAssignmentPayloadType) to Graph API paths.
# The batch tries all candidate paths per type; the one that returns 200 wins.
$payloadTypeEndpoints = @{
    # Compliance + legacy device config profiles + app config (portal tries all three)
    deviceConfigurationAndCompliance = @(
        "/deviceManagement/deviceCompliancePolicies"
        "/deviceManagement/deviceConfigurations"
        "/deviceAppManagement/mobileAppConfigurations"
    )
    # Settings Catalog
    deviceManagementConfigurationPolicy = @(
        "/deviceManagement/configurationPolicies"
    )
    # Administrative Templates
    groupPolicyConfiguration = @(
        "/deviceManagement/groupPolicyConfigurations"
    )
    # Apps (store, LOB, etc.)
    application = @(
        "/deviceAppManagement/mobileApps"
    )
    androidEnterpriseApp = @(
        "/deviceAppManagement/mobileApps"
    )
    win32app = @(
        "/deviceAppManagement/mobileApps"
    )
    # App configuration
    mobileAppConfiguration = @(
        "/deviceAppManagement/mobileAppConfigurations"
        "/deviceAppManagement/targetedManagedAppConfigurations"
    )
    # Enrollment
    enrollmentConfiguration = @(
        "/deviceManagement/deviceEnrollmentConfigurations"
    )
    # Autopilot / DEP
    zeroTouchDeploymentDeviceConfigProfile = @(
        "/deviceManagement/windowsAutopilotDeploymentProfiles"
    )
    # Android Enterprise
    androidEnterpriseConfiguration = @(
        "/deviceManagement/deviceConfigurations"
    )
    # DFCI
    deviceFirmwareConfigurationInterfacePolicy = @(
        "/deviceManagement/configurationPolicies"
    )
    # Resource access (VPN, Wi-Fi, certs)
    resourceAccessPolicy = @(
        "/deviceManagement/deviceConfigurations"
    )
    # Scripts
    deviceManagementScript = @(
        "/deviceManagement/deviceManagementScripts"
        "/deviceManagement/deviceShellScripts"
    )
    # Remediation scripts
    deviceHealthScript = @(
        "/deviceManagement/deviceHealthScripts"
    )
    # Endpoint security
    intents = @(
        "/deviceManagement/intents"
    )
    # Update profiles
    windowsFeatureUpdateProfile = @(
        "/deviceManagement/windowsFeatureUpdateProfiles"
    )
    windowsDriverUpdateProfile = @(
        "/deviceManagement/windowsDriverUpdateProfiles"
    )
    windowsQualityUpdateProfile = @(
        "/deviceManagement/windowsQualityUpdateProfiles"
    )
    # App protection
    managedAppProtection = @(
        "/deviceAppManagement/iosManagedAppProtections"
        "/deviceAppManagement/androidManagedAppProtections"
        "/deviceAppManagement/windowsManagedAppProtections"
    )
    # iOS provisioning
    iosLobAppProvisioningConfiguration = @(
        "/deviceAppManagement/iosLobAppProvisioningConfigurations"
    )
}

# Fallback endpoints to try for any payloadType not in the map above
$fallbackEndpoints = @(
    "/deviceManagement/deviceCompliancePolicies"
    "/deviceManagement/deviceConfigurations"
    "/deviceManagement/configurationPolicies"
    "/deviceManagement/groupPolicyConfigurations"
    "/deviceManagement/intents"
    "/deviceAppManagement/mobileApps"
    "/deviceManagement/deviceEnrollmentConfigurations"
    "/deviceManagement/deviceManagementScripts"
    "/deviceManagement/deviceHealthScripts"
    "/deviceManagement/windowsAutopilotDeploymentProfiles"
)

# Graph $batch limit is 20 requests per batch
$batchSizeLimit = 20

#endregion

#region --- Helper Functions ---

function Invoke-MgGraphRequestAll {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $allResults = [System.Collections.Generic.List[object]]::new()
    $currentUri = $Uri

    do {
        try {
            $response = Invoke-MgGraphRequest -Method GET -Uri $currentUri -ErrorAction Stop
        }
        catch {
            Write-Warning "Failed to query: $currentUri - $($_.Exception.Message)"
            return $allResults
        }

        if ($response.value) {
            foreach ($item in $response.value) {
                $allResults.Add($item)
            }
        }

        $currentUri = $response.'@odata.nextLink'
    } while ($currentUri)

    return $allResults
}

function Invoke-GraphBatch {
    <#
    .SYNOPSIS
        Sends a batch of requests to the Graph $batch endpoint.
        Automatically chunks into groups of 20 (Graph batch limit).
        Returns all responses across all chunks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Requests
    )

    $allResponses = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $Requests.Count; $i += $batchSizeLimit) {
        $chunk = $Requests[$i..([Math]::Min($i + $batchSizeLimit - 1, $Requests.Count - 1))]
        $batchBody = @{ requests = @($chunk) } | ConvertTo-Json -Depth 10 -Compress
        $batchUri = "$graphBaseUrl/$apiVersion/`$batch"

        try {
            $batchResponse = Invoke-MgGraphRequest -Method POST -Uri $batchUri -Body $batchBody -ContentType "application/json" -ErrorAction Stop
            if ($batchResponse.responses) {
                foreach ($r in $batchResponse.responses) {
                    $allResponses.Add($r)
                }
            }
        }
        catch {
            Write-Warning "Batch request failed: $($_.Exception.Message)"
        }
    }

    return $allResponses
}

function Resolve-PayloadNames {
    <#
    .SYNOPSIS
        Takes a list of payloads, builds batch requests to resolve displayName for each,
        trying all candidate endpoints per payloadType. Returns a hashtable of payloadId -> displayName.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Payloads
    )

    $resolvedNames = @{}
    $batchRequests = [System.Collections.Generic.List[object]]::new()
    $seenPayloadIds = @{}

    # Deduplicate by payloadId - same ID can appear multiple times (different group assignments)
    foreach ($payload in $Payloads) {
        $pid_ = $payload.payloadId
        $ptype = $payload.payloadType

        # Skip if we already built requests for this payloadId
        if ($seenPayloadIds.ContainsKey($pid_)) { continue }
        $seenPayloadIds[$pid_] = $true

        if ($payloadTypeEndpoints.ContainsKey($ptype)) {
            $endpoints = $payloadTypeEndpoints[$ptype]
        }
        else {
            Write-Warning "Unknown payloadType '$ptype' for payload $pid_ - trying fallback endpoints"
            $endpoints = $fallbackEndpoints
        }

        foreach ($endpoint in $endpoints) {
            $endpointShort = ($endpoint -split '/')[-1]
            $batchRequests.Add(@{
                id      = "${pid_}_${endpointShort}"
                method  = "GET"
                url     = "$endpoint/$($pid_)/?`$select=displayName"
                headers = @{ "x-ms-command-name" = "Get-FiltersAssigned_resolvePayloadNames" }
            })
        }
    }

    if ($batchRequests.Count -eq 0) {
        return $resolvedNames
    }

    Write-Host "  Sending $($batchRequests.Count) batch request(s) for $($seenPayloadIds.Count) unique payload(s)..." -ForegroundColor DarkGray
    $responses = Invoke-GraphBatch -Requests $batchRequests
    $successCount = ($responses | Where-Object { $_.status -eq 200 }).Count
    $failCount = ($responses | Where-Object { $_.status -ne 200 }).Count
    Write-Host "  Batch responses: $successCount success, $failCount not found (expected)" -ForegroundColor DarkGray

    # Parse responses - first 200 response per payloadId wins (404s are expected)
    foreach ($resp in $responses) {
        if ($resp.status -ne 200) { continue }

        # Extract payloadId from batch request id: {payloadId}_{endpointShort}
        $lastUnderscore = $resp.id.LastIndexOf('_')
        if ($lastUnderscore -gt 0) {
            $payloadId = $resp.id.Substring(0, $lastUnderscore)
        }
        else {
            continue
        }

        if (-not $resolvedNames.ContainsKey($payloadId)) {
            $name = $resp.body.displayName
            if (-not [string]::IsNullOrEmpty($name)) {
                $resolvedNames[$payloadId] = $name
            }
        }
    }

    return $resolvedNames
}

function Resolve-GroupNames {
    <#
    .SYNOPSIS
        Takes a list of group IDs and batch-resolves their displayNames.
        Returns a hashtable of groupId -> displayName.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$GroupIds
    )

    # Well-known Intune virtual assignment targets (not real Entra ID groups)
    $wellKnownGroups = @{
        "adadadad-808e-44e2-905a-0b7873a8a531" = "All Devices"
        "acacacac-9df4-4c7d-9d50-4ef0226f57a9" = "All Users"
    }

    $resolvedNames = @{}
    $batchRequests = [System.Collections.Generic.List[object]]::new()

    $uniqueIds = $GroupIds | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Unique

    foreach ($gid in $uniqueIds) {
        if ($wellKnownGroups.ContainsKey($gid)) {
            $resolvedNames[$gid] = $wellKnownGroups[$gid]
            continue
        }
        $batchRequests.Add(@{
            id      = $gid
            method  = "GET"
            url     = "/groups/$gid`?`$select=displayName"
            headers = @{ "x-ms-command-name" = "Get-FiltersAssigned_resolveGroupNames" }
        })
    }

    if ($batchRequests.Count -eq 0) {
        return $resolvedNames
    }

    $responses = Invoke-GraphBatch -Requests $batchRequests

    foreach ($resp in $responses) {
        if ($resp.status -eq 200 -and $resp.body.displayName) {
            $resolvedNames[$resp.id] = $resp.body.displayName
        }
    }

    return $resolvedNames
}

#endregion

#region --- Main Execution ---

Write-Host "`n=== Intune Filter Assignment Report ===" -ForegroundColor Cyan
Write-Host "Environment: $Environment ($graphBaseUrl)" -ForegroundColor Cyan
Write-Host ""

$mgEnvironment = $graphEnvironments[$Environment]
$requiredScopes = @(
    "DeviceManagementConfiguration.Read.All"  # Filters, device configs, compliance, settings catalog, intents, updates
    "DeviceManagementApps.Read.All"           # Batch resolution of app payloads (mobileApps, appConfigs, appProtection)
    "DeviceManagementManagedDevices.Read.All" # Batch resolution of scripts, health scripts, autopilot profiles
    "Group.Read.All"                          # Batch resolution of group display names
)

Write-Host "Connecting to Microsoft Graph ($mgEnvironment)..." -ForegroundColor Yellow
try {
    Connect-MgGraph -Scopes $requiredScopes -Environment $mgEnvironment -NoWelcome -ErrorAction Stop -deviceCode
    Write-Host "Connected successfully.`n" -ForegroundColor Green
}
catch {
    Write-Error "Failed to connect to Microsoft Graph: $($_.Exception.Message)"
    return
}

# Step 1: Get all assignment filters
Write-Host "Retrieving assignment filters..." -ForegroundColor Yellow
$filtersUri = "$graphBaseUrl/$apiVersion/deviceManagement/assignmentFilters?`$top=100"
$filters = Invoke-MgGraphRequestAll -Uri $filtersUri

if ($filters.Count -eq 0) {
    Write-Host "No assignment filters found in this tenant." -ForegroundColor Yellow
    return
}

Write-Host "Found $($filters.Count) assignment filter(s).`n" -ForegroundColor Green

# Step 2: For each filter, get its payloads
Write-Host "Retrieving payloads for each filter..." -ForegroundColor Yellow
$allPayloads = [System.Collections.Generic.List[object]]::new()
$filterPayloads = @{}
$filterCount = 0

foreach ($filter in $filters) {
    $filterCount++
    $filterId = $filter.id

    Write-Host "  [$filterCount/$($filters.Count)] $($filter.displayName)" -ForegroundColor DarkGray

    $payloadsUri = "$graphBaseUrl/$apiVersion/deviceManagement/assignmentFilters/$filterId/payloads?`$top=100"
    $payloads = Invoke-MgGraphRequestAll -Uri $payloadsUri

    $filterPayloads[$filterId] = $payloads
    foreach ($p in $payloads) {
        $allPayloads.Add($p)
    }
}

# Step 3: Batch-resolve payload display names
if ($allPayloads.Count -gt 0) {
    Write-Host "`nResolving payload names via batch..." -ForegroundColor Yellow
    $payloadNames = Resolve-PayloadNames -Payloads $allPayloads
    Write-Host "  Resolved $($payloadNames.Count) payload name(s)." -ForegroundColor DarkGray

    # Warn about any payloads that couldn't be resolved
    $unresolvedPayloads = $allPayloads | ForEach-Object { $_.payloadId } | Select-Object -Unique |
        Where-Object { -not $payloadNames.ContainsKey($_) }
    if ($unresolvedPayloads) {
        foreach ($uid in $unresolvedPayloads) {
            $ptype = ($allPayloads | Where-Object { $_.payloadId -eq $uid } | Select-Object -First 1).payloadType
            Write-Warning "Could not resolve payload: $uid (type: $ptype)"
        }
    }
}
else {
    $payloadNames = @{}
}

# Step 4: Batch-resolve group display names
$allGroupIds = $allPayloads | ForEach-Object { $_.groupId } |
    Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Unique

if ($allGroupIds.Count -gt 0) {
    Write-Host "Resolving group names via batch ($($allGroupIds.Count) groups)..." -ForegroundColor Yellow
    $groupNames = Resolve-GroupNames -GroupIds $allGroupIds
    Write-Host "  Resolved $($groupNames.Count) group name(s).`n" -ForegroundColor DarkGray
}
else {
    $groupNames = @{}
}

# Step 5: Output results
Write-Host "=== Results ===" -ForegroundColor Cyan
Write-Host ("=" * 80)

$csvRows = [System.Collections.Generic.List[object]]::new()
$filtersWithAssignments = 0
$totalAssignments = 0

foreach ($filter in ($filters | Sort-Object { $_.displayName })) {
    $filterId = $filter.id
    $filterName = $filter.displayName
    $filterRule = $filter.rule
    $filterPlatform = $filter.platform
    $filterDescription = $filter.description
    $payloads = $filterPayloads[$filterId]

    Write-Host "`nFilter: " -NoNewline -ForegroundColor White
    Write-Host $filterName -ForegroundColor Green
    Write-Host "  Platform:    $filterPlatform"
    Write-Host "  Criteria:    $filterRule"
    if ($filterDescription) {
        Write-Host "  Description: $filterDescription"
    }
    Write-Host "  Filter ID:   $filterId" -ForegroundColor DarkGray

    if ($payloads.Count -eq 0) {
        Write-Host "  Assigned To: (none)" -ForegroundColor DarkYellow
        $csvRows.Add([PSCustomObject]@{
            FilterName    = $filterName
            FilterId      = $filterId
            Platform      = $filterPlatform
            Criteria      = $filterRule
            Description   = $filterDescription
            PayloadType   = ""
            PayloadName   = "(none)"
            PayloadId     = ""
            FilterMode    = ""
            GroupName     = ""
            GroupId       = ""
        })
    }
    else {
        $filtersWithAssignments++
        $totalAssignments += $payloads.Count
        Write-Host "  Assigned To ($($payloads.Count)):" -ForegroundColor White

        foreach ($payload in ($payloads | Sort-Object { $_.payloadType })) {
            $filterMode = $payload.assignmentFilterType
            $payloadType = $payload.payloadType
            $payloadId = $payload.payloadId
            $groupId = $payload.groupId

            # Resolve payload name: prefer batch-resolved, then fall back to ID
            if ($payloadNames.ContainsKey($payloadId)) {
                $payloadName = $payloadNames[$payloadId]
            }
            else {
                $payloadName = $payloadId
            }

            # Resolve group name
            $groupDisplay = ""
            if (-not [string]::IsNullOrEmpty($groupId)) {
                if ($groupNames.ContainsKey($groupId)) {
                    $groupDisplay = $groupNames[$groupId]
                }
                else {
                    $groupDisplay = $groupId
                }
            }

            Write-Host "    - [$($filterMode.ToUpper())] " -NoNewline -ForegroundColor Magenta
            Write-Host "[$payloadType] " -NoNewline -ForegroundColor DarkCyan
            Write-Host "$payloadName" -NoNewline
            if ($groupDisplay) {
                Write-Host " -> Group: $groupDisplay" -ForegroundColor DarkGray
            }
            else {
                Write-Host ""
            }

            $csvRows.Add([PSCustomObject]@{
                FilterName    = $filterName
                FilterId      = $filterId
                Platform      = $filterPlatform
                Criteria      = $filterRule
                Description   = $filterDescription
                PayloadType   = $payloadType
                PayloadName   = $payloadName
                PayloadId     = $payloadId
                FilterMode    = $filterMode
                GroupName     = $groupDisplay
                GroupId       = $groupId
            })
        }
    }
    Write-Host ("-" * 80) -ForegroundColor DarkGray
}

# Summary
$filtersWithoutAssignments = $filters.Count - $filtersWithAssignments

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Total Filters:               $($filters.Count)"
Write-Host "Filters With Assignments:    $filtersWithAssignments" -ForegroundColor Green
Write-Host "Filters Without Assignments: $filtersWithoutAssignments" -ForegroundColor Yellow
Write-Host "Total Filter Assignments:    $totalAssignments"

# Export to CSV if requested
if ($ExportCsv) {
    try {
        $csvRows | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
        Write-Host "`nReport exported to: $ExportCsv" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to export CSV: $($_.Exception.Message)"
    }
}

Write-Host "`nDone.`n" -ForegroundColor Cyan

#endregion
