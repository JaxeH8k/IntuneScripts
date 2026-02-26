<#
.SYNOPSIS
    Assigns an Intune policy to a deployment ring group and optionally excludes
    the group from a previous policy version.

.DESCRIPTION
    Supports two input modes:

    MODE A — Config file (recommended):
        Supply -ConfigFile pointing to Rollout-Config.psd1 and -RingNumber (0–3).
        All GUIDs are read from the config; no other parameters needed.

    MODE B — Direct parameters (original behavior):
        Supply -PolicyId, -GroupId, and optionally -OldPolicyId directly.

    In both modes:
      1. Policy type is resolved automatically (Settings Catalog, Device Configuration,
         or Compliance Policy) by probing the Graph API.
      2. Existing assignments are read and preserved before writing (Graph /assign
         replaces ALL assignments, not just adds one).
      3. The ring group is added as an Include assignment on the target policy.
      4. If OldPolicyId is set, the ring group is also added as an Exclude on the old
         policy so devices stop receiving it as soon as they pick up the new one.

    Requires the Microsoft.Graph.Authentication module and an active
    Connect-MgGraph session with DeviceManagementConfiguration.ReadWrite.All.

.PARAMETER ConfigFile
    Path to Rollout-Config.psd1. Use with -RingNumber for config-file mode.

.PARAMETER RingNumber
    Ring to deploy (0, 1, 2, or 3). Used with -ConfigFile.

.PARAMETER PolicyId
    [Direct mode] GUID of the Intune policy to assign.

.PARAMETER GroupId
    [Direct mode] Azure AD group Object ID to add as Include assignment.

.PARAMETER OldPolicyId
    [Direct mode / optional] GUID of the old policy version to exclude the group from.

.PARAMETER WhatIf
    Simulate without writing anything to Intune. Always run this first.

.EXAMPLE
    # Config-file mode — dry run for Ring 0
    .\Invoke-IntuneRingAssignment.ps1 -ConfigFile .\Rollout-Config.psd1 -RingNumber 0 -WhatIf

    # Config-file mode — live Ring 0
    .\Invoke-IntuneRingAssignment.ps1 -ConfigFile .\Rollout-Config.psd1 -RingNumber 0

    # Config-file mode — live Ring 1
    .\Invoke-IntuneRingAssignment.ps1 -ConfigFile .\Rollout-Config.psd1 -RingNumber 1

.EXAMPLE
    # Direct mode — dry run
    .\Invoke-IntuneRingAssignment.ps1 `
        -PolicyId "aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa" `
        -GroupId  "bbbbbbbb-1111-1111-1111-bbbbbbbbbbbb" `
        -WhatIf

    # Direct mode — live, with old policy exclusion
    .\Invoke-IntuneRingAssignment.ps1 `
        -PolicyId    "aaaaaaaa-0000-0000-0000-aaaaaaaaaaaa" `
        -GroupId     "cccccccc-2222-2222-2222-cccccccccccc" `
        -OldPolicyId "dddddddd-9999-9999-9999-dddddddddddd"

.NOTES
    Version : 2.0
    Requires: Microsoft.Graph.Authentication module
              Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

    Connect before running:
        Connect-MgGraph -Scopes "DeviceManagementConfiguration.ReadWrite.All"
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ConfigFile')]
param (
    # ── Config-file mode ───────────────────────────────────────────────────────
    [Parameter(Mandatory = $true,  ParameterSetName = 'ConfigFile')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigFile,

    [Parameter(Mandatory = $true,  ParameterSetName = 'ConfigFile')]
    [ValidateRange(0, 3)]
    [int]$RingNumber,

    # ── Direct mode ────────────────────────────────────────────────────────────
    [Parameter(Mandatory = $true,  ParameterSetName = 'Direct')]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$PolicyId,

    [Parameter(Mandatory = $true,  ParameterSetName = 'Direct')]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$GroupId,

    [Parameter(Mandatory = $false, ParameterSetName = 'Direct')]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$OldPolicyId
)

#Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- Helpers -----------------------------------------------------------

function Write-Step   { param([string]$Message, [string]$Color = 'Cyan')  Write-Host "`n==> $Message" -ForegroundColor $Color }
function Write-Detail { param([string]$Message)                            Write-Host "    $Message"   -ForegroundColor Gray  }
function Write-Success{ param([string]$Message)                            Write-Host "    [OK] $Message" -ForegroundColor Green  }
function Write-Warn   { param([string]$Message)                            Write-Host "    [WARN] $Message" -ForegroundColor Yellow }

function Resolve-IntunePolicy {
    param([string]$Id)
    $candidates = @(
            @{ Type = 'Settings Catalog';      BaseUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$Id";      AssignUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$Id/assign";      ListUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$Id/assignments";      NameField = 'name' },
            @{ Type = 'Device Configuration';  BaseUri = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$Id";        AssignUri = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$Id/assign";        ListUri = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$Id/assignments";        NameField = 'displayName' },
            @{ Type = 'Compliance Policy';     BaseUri = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/$Id";    AssignUri = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/$Id/assign";    ListUri = "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/$Id/assignments";    NameField = 'displayName' }
    )
    foreach ($c in $candidates) {
        try {
            $policy = Invoke-MgGraphRequest -Method GET -Uri $c.BaseUri
            return @{ DisplayName = $policy[$c.NameField]; Type = $c.Type; AssignUri = $c.AssignUri; ListUri = $c.ListUri }
        } catch { }
    }
    throw "Policy ID '$Id' not found in Settings Catalog, Device Configurations, or Compliance Policies."
}

function Get-ExistingAssignments {
    param([string]$ListUri)
    try {
        $val = (Invoke-MgGraphRequest -Method GET -Uri $ListUri).value
        if ($null -eq $val) { return @() }
        return @($val | Where-Object { $null -ne $_ })
    }
    catch { Write-Warn "Could not read existing assignments. Proceeding with empty base."; return @() }
}

function New-GroupAssignmentTarget {
    param([string]$GroupId, [ValidateSet('include','exclude')][string]$Intent)
    $odata = if ($Intent -eq 'include') { '#microsoft.graph.groupAssignmentTarget' } else { '#microsoft.graph.exclusionGroupAssignmentTarget' }
    return @{ target = @{ '@odata.type' = $odata; groupId = $GroupId } }
}

function Set-PolicyAssignments {
    param([string]$AssignUri, [array]$Assignments, [string]$PolicyDisplayName, [string]$Action)
    # Build the JSON body manually to guarantee assignments is always a JSON array.
    # ConvertTo-Json in PowerShell 5.1 unwraps single-element arrays inside hashtables,
    # producing {"assignments":{...}} instead of {"assignments":[{...}]}, which causes
    # a Graph API ModelValidationFailure.
    $assignmentsJson = ($Assignments | ForEach-Object { ConvertTo-Json $_ -Depth 9 -Compress }) -join ','
    $body = "{`"assignments`":[$assignmentsJson]}"
    if ($PSCmdlet.ShouldProcess($PolicyDisplayName, $Action)) {
        Invoke-MgGraphRequest -Method POST -Uri $AssignUri -Body $body -ContentType 'application/json' | Out-Null
        return $true
    }
    return $false
}

#endregion

#region --- Resolve input mode ------------------------------------------------
# Use neutral working variables ($work*) so that the [ValidatePattern] attributes
# on the Direct-mode parameters never fire against values loaded from the config.
# (PowerShell re-validates parameter variables on assignment, so assigning an empty
# string from the config would throw before our own friendly error message could run.)

$guidPattern     = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
$workPolicyId    = ''
$workGroupId     = ''
$workOldPolicyId = ''

if ($PSCmdlet.ParameterSetName -eq 'ConfigFile') {
    Write-Step "Loading config from '$ConfigFile'..."
    $cfg = Import-PowerShellDataFile -Path $ConfigFile

    $ring = $cfg.Rings | Where-Object { $_.Number -eq $RingNumber }
    if (-not $ring) { throw "Ring $RingNumber not found in config file." }

    $workPolicyId    = $cfg.PolicyId
    $workGroupId     = $ring.GroupId
    $workOldPolicyId = if ($cfg.OldPolicyId) { $cfg.OldPolicyId } else { '' }

    # Validate GUIDs were actually filled in — give a clear, actionable message
    if ($workPolicyId    -notmatch $guidPattern) { throw "PolicyId in config is empty or invalid. Open Rollout-Config.psd1 and fill in the PolicyId field." }
    if ($workGroupId     -notmatch $guidPattern) { throw "Ring $RingNumber GroupId in config is empty or invalid. Open Rollout-Config.psd1 and fill in the GroupId for Ring $RingNumber." }
    if ($workOldPolicyId -and $workOldPolicyId -notmatch $guidPattern) { throw "OldPolicyId in config is not a valid GUID. Clear it to '' if there is no predecessor policy." }

    Write-Detail "Change ID   : $($cfg.ChangeId)"
    Write-Detail "Policy      : $($cfg.PolicyName) ($workPolicyId)"
    Write-Detail "Ring        : $RingNumber — $($ring.Description) ($($ring.GroupName))"
    Write-Detail "Group ID    : $workGroupId"
    if ($workOldPolicyId) { Write-Detail "Old Policy  : $workOldPolicyId (will be excluded)" }
} else {
    # Direct mode — copy validated parameters into working variables
    $workPolicyId    = $PolicyId
    $workGroupId     = $GroupId
    $workOldPolicyId = if ($OldPolicyId) { $OldPolicyId } else { '' }
}

#endregion

#region --- Pre-flight --------------------------------------------------------

Write-Step "Checking Microsoft Graph connection..."
try {
    $ctx = Get-MgContext
    if (-not $ctx) { throw "No active context" }
    Write-Detail "Connected as : $($ctx.Account)"
    Write-Detail "Tenant       : $($ctx.TenantId)"
} catch {
    Write-Error "Not connected. Run: Connect-MgGraph -Scopes 'DeviceManagementConfiguration.ReadWrite.All'"
    exit 1
}

#endregion

#region --- Resolve policies --------------------------------------------------

Write-Step "Resolving target policy ($workPolicyId)..."
$targetPolicy = Resolve-IntunePolicy -Id $workPolicyId
Write-Success "Found: '$($targetPolicy.DisplayName)' [$($targetPolicy.Type)]"

$oldPolicy = $null
if ($workOldPolicyId) {
    Write-Step "Resolving old policy ($workOldPolicyId)..."
    $oldPolicy = Resolve-IntunePolicy -Id $workOldPolicyId
    Write-Success "Found: '$($oldPolicy.DisplayName)' [$($oldPolicy.Type)]"
}

#endregion

#region --- Assign ring group as Include on new policy ------------------------

Write-Step "Reading existing assignments on target policy..."
# @() wrapper ensures we get an empty array (not $null) when the function returns no output.
# In PowerShell, a function returning @() produces no pipeline output — callers receive $null
# unless the call is wrapped in @(...), which collects output into an array.
[array]$existingAssignments = @(Get-ExistingAssignments -ListUri $targetPolicy.ListUri)

$alreadyIncluded = $existingAssignments | Where-Object {
    $_.target.'@odata.type' -eq '#microsoft.graph.groupAssignmentTarget' -and $_.target.groupId -eq $workGroupId
}

if ($alreadyIncluded) {
    Write-Warn "Group '$workGroupId' is already an Include on '$($targetPolicy.DisplayName)'. Skipping."
    [array]$newAssignments = $existingAssignments
} else {
    Write-Detail "Existing assignment count: $($existingAssignments.Count)"
    [array]$newAssignments = @($existingAssignments) + @(New-GroupAssignmentTarget -GroupId $workGroupId -Intent 'include')
    Write-Step "Adding '$workGroupId' as Include on '$($targetPolicy.DisplayName)'..."
    $executed = Set-PolicyAssignments -AssignUri $targetPolicy.AssignUri -Assignments $newAssignments `
        -PolicyDisplayName $targetPolicy.DisplayName -Action "Add Include assignment for group $workGroupId"
    if ($executed) { Write-Success "Include added. Total assignments: $($newAssignments.Count)" }
    else           { Write-Warn "[WhatIf] Would have added Include. (No changes made)" }
}

#endregion

#region --- Exclude ring group from old policy --------------------------------

if ($workOldPolicyId -and $oldPolicy) {
    Write-Step "Reading existing assignments on old policy..."
    [array]$oldAssignments = @(Get-ExistingAssignments -ListUri $oldPolicy.ListUri)

    $alreadyExcluded = $oldAssignments | Where-Object {
        $_.target.'@odata.type' -eq '#microsoft.graph.exclusionGroupAssignmentTarget' -and $_.target.groupId -eq $workGroupId
    }

    if ($alreadyExcluded) {
        Write-Warn "Group '$workGroupId' is already an Exclude on '$($oldPolicy.DisplayName)'. Skipping."
    } else {
        Write-Detail "Existing assignment count: $($oldAssignments.Count)"
        [array]$updatedOld = @($oldAssignments) + @(New-GroupAssignmentTarget -GroupId $workGroupId -Intent 'exclude')
        Write-Step "Adding '$workGroupId' as Exclude on old policy '$($oldPolicy.DisplayName)'..."
        $executed = Set-PolicyAssignments -AssignUri $oldPolicy.AssignUri -Assignments $updatedOld `
            -PolicyDisplayName $oldPolicy.DisplayName -Action "Add Exclude assignment for group $workGroupId"
        if ($executed) { Write-Success "Exclude added. Devices in this ring will stop receiving old policy." }
        else           { Write-Warn "[WhatIf] Would have added Exclude to old policy. (No changes made)" }
    }
}

#endregion

#region --- Summary -----------------------------------------------------------

Write-Step "Summary" -Color Yellow
Write-Host ""
Write-Host "  Target policy : $($targetPolicy.DisplayName)" -ForegroundColor White
Write-Host "  Group (ring)  : $workGroupId"                 -ForegroundColor White
Write-Host "  Action        : Added as Include assignment"   -ForegroundColor White
if ($workOldPolicyId -and $oldPolicy) {
    Write-Host "  Old policy    : $($oldPolicy.DisplayName)"                              -ForegroundColor White
    Write-Host "  Action        : Group added as Exclude on old policy"                   -ForegroundColor White
}
if ($WhatIfPreference) { Write-Host ""; Write-Warn "WhatIf active — no changes written to Intune." }

Write-Host ""
Write-Step "Next steps" -Color Yellow
Write-Host "  1. Force sync on a sample endpoint: Company Portal > Sync" -ForegroundColor Gray
Write-Host "  2. Intune portal: Devices > Config profiles > $($targetPolicy.DisplayName) > Device status" -ForegroundColor Gray
Write-Host "  3. Verify 'Succeeded' grows and 'Error/Conflict' stays < 1%" -ForegroundColor Gray
Write-Host "  4. Evaluate Go/No-Go criteria before advancing to the next ring" -ForegroundColor Gray
Write-Host ""

#endregion
