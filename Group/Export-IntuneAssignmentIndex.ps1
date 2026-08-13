<#
.SYNOPSIS
    Exports every Intune policy/profile/app and the Entra groups it is assigned to
    (or excluded from) into a single JSON index file on disk.

.DESCRIPTION
    Walks a table of ~30 Graph resource collections that support group assignments
    (Settings Catalog, device configurations, compliance, admin templates, endpoint
    security intents, scripts, remediations, update rings, Autopilot, enrollment
    configurations, apps, app config, app protection, policy sets, Windows 365, ...).

    For each collection it first tries ?$expand=assignments in a single paged call.
    If the collection does not support $expand, it falls back to listing the items
    and fetching /{id}/assignments through Graph $batch (20 per batch, with retry
    on throttled sub-responses).

    Group display names are resolved once, in batch, for every group ID that appears
    in any assignment. Groups that no longer exist are flagged.

    The resulting JSON contains both:
      policies[]  - one entry per policy, with its assignments
      groupIndex  - a prebuilt reverse index: groupId -> { includedBy[], excludedBy[] }

    Use Find-IntuneGroupAssignment.ps1 against the JSON for the reverse lookup.
    Uses Invoke-MgGraphRequest exclusively. Supports Commercial, GCC High and DoD.

.PARAMETER Path
    Output JSON path. Defaults to .\IntuneAssignmentIndex.json in the current directory.

.PARAMETER CsvPath
    Optional flat CSV export (one row per policy/assignment pair) for pivoting in Excel.

.PARAMETER Environment
    Cloud environment. Commercial (default), USGovGCCHigh, or USGovDoD.

.PARAMETER ExcludeResourceType
    One or more friendly resource type names to skip (wildcards allowed), e.g.
    -ExcludeResourceType 'Mobile App','Windows 365*'. Use -ListResourceType to see names.

.PARAMETER ListResourceType
    Print the resource types this script collects and exit without connecting.

.PARAMETER IncludeConditionalAccess
    Also collect Conditional Access policy include/exclude groups. Off by default
    because CA is not Intune, but it matters if you are hunting unused groups.
    Requires Policy.Read.All.

.PARAMETER UseDeviceCode
    Authenticate with device code flow instead of an interactive browser.

.EXAMPLE
    .\Export-IntuneAssignmentIndex.ps1

.EXAMPLE
    .\Export-IntuneAssignmentIndex.ps1 -Path C:\Reports\IntuneAssignmentIndex.json -CsvPath C:\Reports\Assignments.csv

.EXAMPLE
    .\Export-IntuneAssignmentIndex.ps1 -Environment USGovGCCHigh -IncludeConditionalAccess -UseDeviceCode

.NOTES
    Requires: Microsoft.Graph.Authentication
              Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

    Known blind spots when using this to prove a group is unused:
      * Nested groups - a group can be used indirectly by being a member of an
        assigned group. Find-IntuneGroupAssignment.ps1 -IncludeTransitive checks this.
      * Intune RBAC scope/member groups, Entra role-assignable groups, app role
        assignments, licensing groups, Defender/Purview scoping, on-prem sync.
      * Conditional Access, unless -IncludeConditionalAccess is used.
#>

[CmdletBinding()]
param(
    [string]$Path = (Join-Path (Get-Location).Path 'IntuneAssignmentIndex.json'),

    [string]$CsvPath,

    [ValidateSet("Commercial", "USGovGCCHigh", "USGovDoD")]
    [string]$Environment = "Commercial",

    [string[]]$ExcludeResourceType,

    [switch]$ListResourceType,

    [switch]$IncludeConditionalAccess,

    [switch]$UseDeviceCode
)

$ErrorActionPreference = 'Stop'

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
$batchSizeLimit = 20

# Well-known virtual assignment targets - these are not real Entra groups.
$wellKnownGroups = @{
    "adadadad-808e-44e2-905a-0b7873a8a531" = "All Devices"
    "acacacac-9df4-4c7d-9d50-4ef0226f57a9" = "All Users"
}

# Every Graph collection that carries group assignments.
#   Name     - friendly type name written to the index
#   Uri      - path below /beta (also used verbatim inside $batch requests)
#   NameProp - property holding the display name
#   Expand   - $false to skip the $expand=assignments attempt (known unsupported)
#   Extra    - additional properties to carry into the index, if present
$resources = @(
    @{ Name = 'Settings Catalog';                  Uri = '/deviceManagement/configurationPolicies';                  NameProp = 'name';        Extra = @('platforms', 'technologies', 'templateReference') }
    @{ Name = 'Device Configuration';              Uri = '/deviceManagement/deviceConfigurations';                   NameProp = 'displayName' }
    @{ Name = 'Compliance Policy';                 Uri = '/deviceManagement/deviceCompliancePolicies';               NameProp = 'displayName' }
    @{ Name = 'Administrative Template';           Uri = '/deviceManagement/groupPolicyConfigurations';              NameProp = 'displayName' }
    @{ Name = 'Endpoint Security Intent';          Uri = '/deviceManagement/intents';                                NameProp = 'displayName'; Expand = $false }
    @{ Name = 'Platform Script (Windows)';         Uri = '/deviceManagement/deviceManagementScripts';                NameProp = 'displayName' }
    @{ Name = 'Shell Script (macOS)';              Uri = '/deviceManagement/deviceShellScripts';                     NameProp = 'displayName' }
    @{ Name = 'Custom Attribute Script (macOS)';   Uri = '/deviceManagement/deviceCustomAttributeShellScripts';      NameProp = 'displayName' }
    @{ Name = 'Remediation Script';                Uri = '/deviceManagement/deviceHealthScripts';                    NameProp = 'displayName' }
    @{ Name = 'Feature Update Profile';            Uri = '/deviceManagement/windowsFeatureUpdateProfiles';           NameProp = 'displayName' }
    @{ Name = 'Quality Update Profile';            Uri = '/deviceManagement/windowsQualityUpdateProfiles';           NameProp = 'displayName' }
    @{ Name = 'Quality Update Policy';             Uri = '/deviceManagement/windowsQualityUpdatePolicies';           NameProp = 'displayName' }
    @{ Name = 'Driver Update Profile';             Uri = '/deviceManagement/windowsDriverUpdateProfiles';            NameProp = 'displayName' }
    @{ Name = 'Autopilot Deployment Profile';      Uri = '/deviceManagement/windowsAutopilotDeploymentProfiles';     NameProp = 'displayName' }
    @{ Name = 'Enrollment Configuration';          Uri = '/deviceManagement/deviceEnrollmentConfigurations';         NameProp = 'displayName'; Extra = @('priority') }
    @{ Name = 'Hardware Configuration';            Uri = '/deviceManagement/hardwareConfigurations';                 NameProp = 'displayName' }
    @{ Name = 'Terms and Conditions';              Uri = '/deviceManagement/termsAndConditions';                     NameProp = 'displayName' }
    @{ Name = 'Windows 365 Provisioning Policy';   Uri = '/deviceManagement/virtualEndpoint/provisioningPolicies';   NameProp = 'displayName' }
    @{ Name = 'Windows 365 User Setting';          Uri = '/deviceManagement/virtualEndpoint/userSettings';           NameProp = 'displayName' }
    @{ Name = 'Mobile App';                        Uri = '/deviceAppManagement/mobileApps';                          NameProp = 'displayName'; Extra = @('publisher') }
    @{ Name = 'App Configuration (Devices)';       Uri = '/deviceAppManagement/mobileAppConfigurations';             NameProp = 'displayName' }
    @{ Name = 'App Configuration (Apps)';          Uri = '/deviceAppManagement/targetedManagedAppConfigurations';    NameProp = 'displayName' }
    @{ Name = 'App Protection (iOS)';              Uri = '/deviceAppManagement/iosManagedAppProtections';            NameProp = 'displayName' }
    @{ Name = 'App Protection (Android)';          Uri = '/deviceAppManagement/androidManagedAppProtections';        NameProp = 'displayName' }
    @{ Name = 'App Protection (Windows)';          Uri = '/deviceAppManagement/windowsManagedAppProtections';        NameProp = 'displayName' }
    @{ Name = 'Windows Information Protection';    Uri = '/deviceAppManagement/mdmWindowsInformationProtectionPolicies'; NameProp = 'displayName' }
    @{ Name = 'iOS App Provisioning Profile';      Uri = '/deviceAppManagement/iosLobAppProvisioningConfigurations'; NameProp = 'displayName' }
    @{ Name = 'Managed eBook';                     Uri = '/deviceAppManagement/managedEBooks';                       NameProp = 'displayName' }
    @{ Name = 'Policy Set';                        Uri = '/deviceAppManagement/policySets';                          NameProp = 'displayName' }
    @{ Name = 'WDAC Supplemental Policy';          Uri = '/deviceAppManagement/wdacSupplementalPolicies';            NameProp = 'displayName' }
)

if ($ListResourceType) {
    Write-Host "`nResource types collected by this script:`n" -ForegroundColor Cyan
    $resources | ForEach-Object { '{0,-32} {1}' -f $_.Name, $_.Uri } | Write-Host
    if ($IncludeConditionalAccess) { '{0,-32} {1}' -f 'Conditional Access Policy', '/identity/conditionalAccess/policies' | Write-Host }
    Write-Host ""
    return
}

#endregion

#region --- Helper Functions ---

function Get-Prop {
    <#
    .SYNOPSIS
        Reads a property from either a hashtable (what Invoke-MgGraphRequest returns)
        or a PSCustomObject, without throwing when the key is absent.
    #>
    param($InputObject, [string]$Name)

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Invoke-MgGraphRequestAll {
    <#
    .SYNOPSIS
        GETs a collection and follows @odata.nextLink. Throws if the FIRST page fails
        (so the caller can fall back or record the resource as unavailable); a failure
        on a later page only warns and returns what was collected.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $allResults = [System.Collections.Generic.List[object]]::new()
    $currentUri = $Uri
    $isFirstPage = $true

    do {
        try {
            $response = Invoke-MgGraphRequest -Method GET -Uri $currentUri -ErrorAction Stop
        }
        catch {
            if ($isFirstPage) { throw }
            Write-Warning "Paging stopped early for $currentUri - $($_.Exception.Message)"
            return $allResults
        }

        $value = Get-Prop $response 'value'
        if ($value) {
            foreach ($item in $value) { $allResults.Add($item) }
        }

        $isFirstPage = $false
        $currentUri = Get-Prop $response '@odata.nextLink'
    } while ($currentUri)

    return $allResults
}

function Invoke-GraphBatch {
    <#
    .SYNOPSIS
        Sends requests through $batch in chunks of 20 and returns every sub-response.
        Throttled (429) sub-responses are retried up to 3 rounds honouring Retry-After.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Requests
    )

    $allResponses = [System.Collections.Generic.List[object]]::new()
    $batchUri = "$graphBaseUrl/$apiVersion/`$batch"
    $pending = @($Requests)
    $round = 0

    while ($pending.Count -gt 0 -and $round -lt 4) {
        $round++
        $throttled = [System.Collections.Generic.List[object]]::new()
        $requestsById = @{}
        foreach ($r in $pending) { $requestsById[$r.id] = $r }

        for ($i = 0; $i -lt $pending.Count; $i += $batchSizeLimit) {
            $chunk = $pending[$i..([Math]::Min($i + $batchSizeLimit - 1, $pending.Count - 1))]
            $batchBody = @{ requests = @($chunk) } | ConvertTo-Json -Depth 10 -Compress

            try {
                $batchResponse = Invoke-MgGraphRequest -Method POST -Uri $batchUri -Body $batchBody -ContentType "application/json" -ErrorAction Stop
            }
            catch {
                Write-Warning "Batch request failed: $($_.Exception.Message)"
                continue
            }

            foreach ($resp in (Get-Prop $batchResponse 'responses')) {
                if ((Get-Prop $resp 'status') -eq 429) {
                    $throttled.Add($requestsById[(Get-Prop $resp 'id')])
                    continue
                }
                $allResponses.Add($resp)
            }
        }

        $pending = @($throttled | Where-Object { $_ })
        if ($pending.Count -gt 0) {
            Write-Host "  Throttled on $($pending.Count) request(s), retrying in 20s..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds 20
        }
    }

    if ($pending.Count -gt 0) {
        Write-Warning "$($pending.Count) request(s) still throttled after retries - assignments for those items are missing."
    }

    return $allResponses
}

function ConvertTo-AssignmentRecord {
    <#
    .SYNOPSIS
        Normalises one Graph assignment object into a flat record.
        Returns $null for assignment shapes that carry no target.
    #>
    param($Assignment)

    $target = Get-Prop $Assignment 'target'
    if (-not $target) { return $null }

    $odataType = [string](Get-Prop $target '@odata.type')
    $groupId = [string](Get-Prop $target 'groupId')

    $targetType = switch -Regex ($odataType) {
        'exclusionGroupAssignmentTarget$'                 { 'Group'; break }
        'groupAssignmentTarget$'                          { 'Group'; break }
        'allDevicesAssignmentTarget$'                     { 'AllDevices'; break }
        'allLicensedUsersAssignmentTarget$'               { 'AllUsers'; break }
        'configurationManagerCollectionAssignmentTarget$' { 'ConfigMgrCollection'; break }
        default                                           { 'Other' }
    }

    $mode = if ($odataType -match 'exclusion') { 'Exclude' } else { 'Include' }

    # Some legacy payloads express All Users / All Devices as a group target
    # pointing at a well-known virtual GUID.
    if ($targetType -eq 'Group' -and $wellKnownGroups.ContainsKey($groupId)) {
        $targetType = if ($wellKnownGroups[$groupId] -eq 'All Devices') { 'AllDevices' } else { 'AllUsers' }
    }

    [ordered]@{
        mode        = $mode
        targetType  = $targetType
        groupId     = if ($targetType -eq 'Group') { $groupId } else { $null }
        odataType   = $odataType
        filterId    = Get-Prop $target 'deviceAndAppManagementAssignmentFilterId'
        filterType  = Get-Prop $target 'deviceAndAppManagementAssignmentFilterType'
        collectionId = Get-Prop $target 'collectionId'
        intent      = Get-Prop $Assignment 'intent'          # apps: required / available / uninstall
        source      = Get-Prop $Assignment 'source'          # 'policySets' when inherited
        sourceId    = Get-Prop $Assignment 'sourceId'
    }
}

function Resolve-GroupNames {
    <#
    .SYNOPSIS
        Batch-resolves group display names. Groups that return 404 are marked as
        "(deleted or not found)" so stale assignments are visible in the index.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$GroupIds
    )

    $resolved = @{}
    $batchRequests = [System.Collections.Generic.List[object]]::new()

    foreach ($gid in ($GroupIds | Where-Object { $_ } | Select-Object -Unique)) {
        if ($wellKnownGroups.ContainsKey($gid)) { $resolved[$gid] = $wellKnownGroups[$gid]; continue }
        $batchRequests.Add(@{
            id      = $gid
            method  = 'GET'
            url     = "/groups/$gid" + '?$select=id,displayName'
            headers = @{ "x-ms-command-name" = "Export-IntuneAssignmentIndex_resolveGroups" }
        })
    }

    if ($batchRequests.Count -eq 0) { return $resolved }

    foreach ($resp in (Invoke-GraphBatch -Requests $batchRequests)) {
        $id = Get-Prop $resp 'id'
        $status = Get-Prop $resp 'status'
        if ($status -eq 200) {
            $resolved[$id] = [string](Get-Prop (Get-Prop $resp 'body') 'displayName')
        }
        elseif ($status -eq 404) {
            $resolved[$id] = '(deleted or not found)'
        }
    }

    return $resolved
}

function Get-ResourceAssignments {
    <#
    .SYNOPSIS
        Returns @{ Items = <list>; Assignments = @{ id -> assignment[] } } for one
        resource collection, using $expand where supported and $batch otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Resource
    )

    $baseUri = "$graphBaseUrl/$apiVersion" + $Resource.Uri
    $assignmentsById = @{}
    $items = $null

    if ($Resource.Expand -ne $false) {
        try {
            $items = Invoke-MgGraphRequestAll -Uri ($baseUri + '?$expand=assignments')
            foreach ($item in $items) {
                $assignmentsById[[string](Get-Prop $item 'id')] = @(Get-Prop $item 'assignments')
            }
            return @{ Items = $items; Assignments = $assignmentsById; Method = 'expand' }
        }
        catch {
            # $expand unsupported (400) or transient - fall through to the batch path.
            # A hard failure on the plain list below is what actually surfaces the error.
            Write-Verbose "$($Resource.Name): `$expand=assignments failed ($($_.Exception.Message)), falling back to `$batch."
            $items = $null
        }
    }

    $items = Invoke-MgGraphRequestAll -Uri $baseUri

    $batchRequests = [System.Collections.Generic.List[object]]::new()
    $idByRequestId = @{}
    $n = 0
    foreach ($item in $items) {
        $itemId = [string](Get-Prop $item 'id')
        if (-not $itemId) { continue }
        $requestId = "r$n"; $n++
        $idByRequestId[$requestId] = $itemId
        $batchRequests.Add(@{
            id      = $requestId
            method  = 'GET'
            url     = "$($Resource.Uri)/$itemId/assignments"
            headers = @{ "x-ms-command-name" = "Export-IntuneAssignmentIndex_getAssignments" }
        })
    }

    if ($batchRequests.Count -gt 0) {
        foreach ($resp in (Invoke-GraphBatch -Requests $batchRequests)) {
            $itemId = $idByRequestId[[string](Get-Prop $resp 'id')]
            if ((Get-Prop $resp 'status') -eq 200) {
                $assignmentsById[$itemId] = @(Get-Prop (Get-Prop $resp 'body') 'value')
            }
        }
    }

    return @{ Items = $items; Assignments = $assignmentsById; Method = 'batch' }
}

#endregion

#region --- Connect ---

Write-Host "`n=== Intune Assignment Index Export ===" -ForegroundColor Cyan
Write-Host "Environment : $Environment ($graphBaseUrl)" -ForegroundColor Cyan
Write-Host "Output      : $Path" -ForegroundColor Cyan
Write-Host ""

$requiredScopes = @(
    "DeviceManagementConfiguration.Read.All"
    "DeviceManagementApps.Read.All"
    "DeviceManagementManagedDevices.Read.All"
    "DeviceManagementServiceConfig.Read.All"
    "DeviceManagementRBAC.Read.All"
    "Group.Read.All"
)
if ($IncludeConditionalAccess) { $requiredScopes += "Policy.Read.All" }

$context = $null
try { $context = Get-MgContext } catch { $context = $null }

$missingScopes = @()
if ($context) {
    $missingScopes = @($requiredScopes | Where-Object { $_ -notin $context.Scopes })
}

if ($context -and $missingScopes.Count -eq 0) {
    Write-Host "Reusing existing Graph connection ($($context.Account))." -ForegroundColor Green
}
else {
    if ($context) { Write-Host "Existing connection is missing scopes: $($missingScopes -join ', ')" -ForegroundColor Yellow }
    Write-Host "Connecting to Microsoft Graph ($($graphEnvironments[$Environment]))..." -ForegroundColor Yellow
    try {
        $connectParams = @{
            Scopes      = $requiredScopes
            Environment = $graphEnvironments[$Environment]
            NoWelcome   = $true
            ErrorAction = 'Stop'
        }
        if ($UseDeviceCode) { $connectParams['UseDeviceCode'] = $true }
        Connect-MgGraph @connectParams
        $context = Get-MgContext
        Write-Host "Connected as $($context.Account)." -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to connect to Microsoft Graph: $($_.Exception.Message)"
        return
    }
}
Write-Host ""

#endregion

#region --- Collect ---

$policies = [System.Collections.Generic.List[object]]::new()
$collectionErrors = [System.Collections.Generic.List[object]]::new()
$allGroupIds = [System.Collections.Generic.List[string]]::new()

$selectedResources = $resources | Where-Object {
    $name = $_.Name
    -not ($ExcludeResourceType | Where-Object { $name -like $_ })
}

$resourceNumber = 0
foreach ($resource in $selectedResources) {
    $resourceNumber++
    Write-Host ("[{0,2}/{1}] {2}" -f $resourceNumber, @($selectedResources).Count, $resource.Name) -NoNewline -ForegroundColor White

    try {
        $result = Get-ResourceAssignments -Resource $resource
    }
    catch {
        $message = $_.Exception.Message
        Write-Host "  -> skipped ($message)" -ForegroundColor DarkYellow
        $collectionErrors.Add([ordered]@{
            resourceType = $resource.Name
            uri          = $resource.Uri
            error        = $message
        })
        continue
    }

    $items = @($result.Items)
    $assignedCount = 0

    foreach ($item in $items) {
        $itemId = [string](Get-Prop $item 'id')
        $displayName = [string](Get-Prop $item $resource.NameProp)
        if (-not $displayName) { $displayName = [string](Get-Prop $item 'displayName') }

        $records = [System.Collections.Generic.List[object]]::new()
        foreach ($assignment in @($result.Assignments[$itemId])) {
            $record = ConvertTo-AssignmentRecord -Assignment $assignment
            if ($record) {
                $records.Add($record)
                if ($record.groupId) { $allGroupIds.Add($record.groupId) }
            }
        }
        if ($records.Count -gt 0) { $assignedCount++ }

        $policy = [ordered]@{
            id              = $itemId
            displayName     = $displayName
            resourceType    = $resource.Name
            odataType       = [string](Get-Prop $item '@odata.type')
            endpoint        = $resource.Uri
            assignmentCount = $records.Count
            assignments     = @($records)
        }

        foreach ($extra in @($resource.Extra)) {
            if ($extra) {
                $value = Get-Prop $item $extra
                if ($null -ne $value) { $policy[$extra] = $value }
            }
        }

        $policies.Add($policy)
    }

    Write-Host ("  -> {0} item(s), {1} assigned" -f $items.Count, $assignedCount) -ForegroundColor DarkGray
}

# Conditional Access is optional and shaped differently: groups live on the policy
# conditions rather than on an assignments collection.
if ($IncludeConditionalAccess) {
    Write-Host "[CA] Conditional Access policies" -NoNewline -ForegroundColor White
    try {
        $caPolicies = Invoke-MgGraphRequestAll -Uri "$graphBaseUrl/$apiVersion/identity/conditionalAccess/policies"
        foreach ($ca in $caPolicies) {
            $users = Get-Prop (Get-Prop $ca 'conditions') 'users'
            $records = [System.Collections.Generic.List[object]]::new()

            foreach ($pair in @(
                    @{ Prop = 'includeGroups'; Mode = 'Include' }
                    @{ Prop = 'excludeGroups'; Mode = 'Exclude' }
                )) {
                foreach ($gid in @(Get-Prop $users $pair.Prop)) {
                    if (-not $gid) { continue }
                    $records.Add([ordered]@{
                        mode       = $pair.Mode
                        targetType = 'Group'
                        groupId    = [string]$gid
                        odataType  = '#conditionalAccess'
                        filterId   = $null; filterType = $null; collectionId = $null
                        intent     = $null; source = $null; sourceId = $null
                    })
                    $allGroupIds.Add([string]$gid)
                }
            }

            $policies.Add([ordered]@{
                id              = [string](Get-Prop $ca 'id')
                displayName     = [string](Get-Prop $ca 'displayName')
                resourceType    = 'Conditional Access Policy'
                odataType       = '#conditionalAccess'
                endpoint        = '/identity/conditionalAccess/policies'
                state           = [string](Get-Prop $ca 'state')
                assignmentCount = $records.Count
                assignments     = @($records)
            })
        }
        Write-Host ("  -> {0} item(s)" -f @($caPolicies).Count) -ForegroundColor DarkGray
    }
    catch {
        Write-Host "  -> skipped ($($_.Exception.Message))" -ForegroundColor DarkYellow
        $collectionErrors.Add([ordered]@{
            resourceType = 'Conditional Access Policy'
            uri          = '/identity/conditionalAccess/policies'
            error        = $_.Exception.Message
        })
    }
}

#endregion

#region --- Resolve group names ---

$uniqueGroupIds = @($allGroupIds | Select-Object -Unique)
Write-Host ""
Write-Host "Resolving $($uniqueGroupIds.Count) unique group name(s)..." -ForegroundColor Yellow
$groupNames = Resolve-GroupNames -GroupIds $uniqueGroupIds
Write-Host "  Resolved $($groupNames.Count)." -ForegroundColor DarkGray

foreach ($policy in $policies) {
    foreach ($assignment in $policy.assignments) {
        if ($assignment.groupId -and $groupNames.ContainsKey($assignment.groupId)) {
            $assignment['groupDisplayName'] = $groupNames[$assignment.groupId]
        }
        elseif ($assignment.groupId) {
            $assignment['groupDisplayName'] = '(unresolved)'
        }
    }
}

#endregion

#region --- Build reverse index ---

$groupIndex = [ordered]@{}

foreach ($policy in $policies) {
    foreach ($assignment in $policy.assignments) {
        $gid = $assignment.groupId
        if (-not $gid) { continue }

        if (-not $groupIndex.Contains($gid)) {
            $groupIndex[$gid] = [ordered]@{
                groupId     = $gid
                displayName = $assignment['groupDisplayName']
                includedBy  = [System.Collections.Generic.List[object]]::new()
                excludedBy  = [System.Collections.Generic.List[object]]::new()
            }
        }

        $entry = [ordered]@{
            policyId     = $policy.id
            displayName  = $policy.displayName
            resourceType = $policy.resourceType
            endpoint     = $policy.endpoint
            filterId     = $assignment.filterId
            filterType   = $assignment.filterType
            intent       = $assignment.intent
            source       = $assignment.source
        }

        if ($assignment.mode -eq 'Exclude') { $groupIndex[$gid].excludedBy.Add($entry) }
        else { $groupIndex[$gid].includedBy.Add($entry) }
    }
}

# Materialise the lists as arrays so ConvertTo-Json emits [] rather than a
# List<T> object with Capacity/Count properties.
foreach ($key in @($groupIndex.Keys)) {
    $groupIndex[$key].includedBy = @($groupIndex[$key].includedBy)
    $groupIndex[$key].excludedBy = @($groupIndex[$key].excludedBy)
}

#endregion

#region --- Write output ---

$totalAssignments = ($policies | ForEach-Object { $_.assignmentCount } | Measure-Object -Sum).Sum
$deletedGroups = @($groupIndex.Keys | Where-Object { $groupIndex[$_].displayName -eq '(deleted or not found)' })

$index = [ordered]@{
    schemaVersion     = 1
    generatedUtc      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    generatedBy       = $context.Account
    tenantId          = $context.TenantId
    environment       = $Environment
    graphBaseUrl      = $graphBaseUrl
    apiVersion        = $apiVersion
    includesConditionalAccess = [bool]$IncludeConditionalAccess
    resourceTypes     = @($selectedResources | ForEach-Object { $_.Name })
    policyCount       = $policies.Count
    assignmentCount   = [int]$totalAssignments
    groupCount        = $groupIndex.Count
    errors            = @($collectionErrors)
    groupIndex        = $groupIndex
    policies          = @($policies)
}

$directory = Split-Path -Path $Path -Parent
if ($directory -and -not (Test-Path $directory)) {
    New-Item -Path $directory -ItemType Directory -Force | Out-Null
}

$index | ConvertTo-Json -Depth 12 | Set-Content -Path $Path -Encoding UTF8

if ($CsvPath) {
    $rows = foreach ($policy in $policies) {
        if ($policy.assignments.Count -eq 0) {
            [PSCustomObject]@{
                PolicyType = $policy.resourceType; PolicyName = $policy.displayName; PolicyId = $policy.id
                Mode = ''; TargetType = '(unassigned)'; GroupName = ''; GroupId = ''
                FilterId = ''; FilterType = ''; Intent = ''; Source = ''
            }
            continue
        }
        foreach ($assignment in $policy.assignments) {
            [PSCustomObject]@{
                PolicyType = $policy.resourceType; PolicyName = $policy.displayName; PolicyId = $policy.id
                Mode = $assignment.mode; TargetType = $assignment.targetType
                GroupName = $assignment['groupDisplayName']; GroupId = $assignment.groupId
                FilterId = $assignment.filterId; FilterType = $assignment.filterType
                Intent = $assignment.intent; Source = $assignment.source
            }
        }
    }
    $rows | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
}

#endregion

#region --- Summary ---

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Policies collected      : $($policies.Count)"
Write-Host "Group assignments       : $totalAssignments"
Write-Host "Distinct groups in use  : $($groupIndex.Count)" -ForegroundColor Green
if ($deletedGroups.Count -gt 0) {
    Write-Host "Assignments to deleted groups: $($deletedGroups.Count)" -ForegroundColor Yellow
    foreach ($gid in $deletedGroups) { Write-Host "  $gid" -ForegroundColor DarkYellow }
}
if ($collectionErrors.Count -gt 0) {
    Write-Host "Resource types skipped  : $($collectionErrors.Count)" -ForegroundColor Yellow
    foreach ($e in $collectionErrors) { Write-Host "  $($e.resourceType): $($e.error)" -ForegroundColor DarkYellow }
    Write-Host "  A skipped type is a blind spot - a group used only there will look unused." -ForegroundColor DarkYellow
}

Write-Host "`nIndex written to: $Path" -ForegroundColor Green
if ($CsvPath) { Write-Host "CSV written to  : $CsvPath" -ForegroundColor Green }
Write-Host "`nNext: .\Find-IntuneGroupAssignment.ps1 -GroupId <entra-group-object-id> -Path `"$Path`"`n" -ForegroundColor Cyan

#endregion
