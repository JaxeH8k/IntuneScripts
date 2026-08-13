<#
.SYNOPSIS
    Reverse lookup: given an Entra group object ID, lists every Intune policy the
    group is assigned to or excluded from, using the JSON index produced by
    Export-IntuneAssignmentIndex.ps1.

.DESCRIPTION
    Reads the offline index and answers "what is this group actually used for?".
    No Graph connection is needed unless -IncludeTransitive is used.

    Accepts one or many group IDs, from parameters or the pipeline, so a list of
    suspected-unused groups can be checked in one pass. Emits a result object per
    group with IsAssigned / IncludeCount / ExcludeCount plus the matching policies,
    so results can be filtered or exported.

.PARAMETER GroupId
    One or more Entra group object IDs. Accepts pipeline input, including objects
    with an Id or GroupId property (e.g. output from Get-MgGroup).

.PARAMETER GroupName
    Wildcard match against the group display names captured in the index. Use this
    when you have a name but not an ID. Only finds groups that appear in the index,
    i.e. groups that are assigned to something.

.PARAMETER Path
    Path to the JSON index. Defaults to .\IntuneAssignmentIndex.json.

.PARAMETER IncludeTransitive
    Also check whether the group is used indirectly - that is, whether it is a member
    of another group that is assigned. Requires an active Connect-MgGraph session with
    Group.Read.All. Without this, a nested group can look unused when it is not.

.PARAMETER Summary
    Print one line per group instead of the full policy list.

.PARAMETER ExportCsv
    Write a flat CSV of every match (one row per policy) to this path.

.PARAMETER PassThru
    Emit the result objects to the pipeline in addition to printing them.

.EXAMPLE
    .\Find-IntuneGroupAssignment.ps1 -GroupId 11111111-2222-3333-4444-555555555555

.EXAMPLE
    # Check a list of candidate-for-deletion groups and keep only the truly unused ones
    Get-Content .\candidates.txt | .\Find-IntuneGroupAssignment.ps1 -Summary -PassThru |
        Where-Object { -not $_.IsAssigned } | Select-Object -ExpandProperty GroupId

.EXAMPLE
    .\Find-IntuneGroupAssignment.ps1 -GroupName '*Pilot*' -ExportCsv .\pilot-usage.csv

.EXAMPLE
    # Nested-group aware check (needs Connect-MgGraph -Scopes Group.Read.All first)
    .\Find-IntuneGroupAssignment.ps1 -GroupId 1111... -IncludeTransitive

.NOTES
    The index is a point-in-time snapshot. Re-run Export-IntuneAssignmentIndex.ps1
    before acting on the results, and check the index's "errors" list - a resource
    type that failed to collect is a blind spot.
#>

[CmdletBinding(DefaultParameterSetName = 'ById')]
param(
    [Parameter(ParameterSetName = 'ById', Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('Id', 'ObjectId')]
    [string[]]$GroupId,

    [Parameter(ParameterSetName = 'ByName', Mandatory)]
    [string]$GroupName,

    [string]$Path = (Join-Path (Get-Location).Path 'IntuneAssignmentIndex.json'),

    [switch]$IncludeTransitive,

    [switch]$Summary,

    [string]$ExportCsv,

    [switch]$PassThru
)

begin {
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Index file not found: $Path`nRun Export-IntuneAssignmentIndex.ps1 first."
    }

    $index = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json

    # Normalise the reverse index into a case-insensitive hashtable so pasted
    # upper-case GUIDs still match.
    $lookup = @{}
    foreach ($property in $index.groupIndex.PSObject.Properties) {
        $lookup[$property.Name.ToLowerInvariant()] = $property.Value
    }

    $ageDays = [math]::Round(((Get-Date).ToUniversalTime() - [datetime]::Parse($index.generatedUtc)).TotalDays, 1)

    Write-Host ""
    Write-Host "Index    : $Path" -ForegroundColor DarkGray
    Write-Host "Captured : $($index.generatedUtc) ($ageDays day(s) old) - tenant $($index.tenantId)" -ForegroundColor DarkGray
    Write-Host "Contents : $($index.policyCount) policies, $($index.assignmentCount) assignments, $($index.groupCount) groups in use" -ForegroundColor DarkGray
    if (@($index.errors).Count -gt 0) {
        Write-Warning "The index has $(@($index.errors).Count) collection error(s) - those resource types are blind spots:"
        foreach ($e in $index.errors) { Write-Host "  $($e.resourceType): $($e.error)" -ForegroundColor DarkYellow }
    }
    Write-Host ""

    $transitiveAvailable = $false
    if ($IncludeTransitive) {
        $context = $null
        try { $context = Get-MgContext } catch { $context = $null }
        if ($context) {
            $transitiveAvailable = $true
            Write-Host "Transitive check enabled (connected as $($context.Account))." -ForegroundColor DarkGray
        }
        else {
            Write-Warning "-IncludeTransitive needs a Graph session. Run: Connect-MgGraph -Scopes Group.Read.All. Skipping nested-group check."
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()

    function Write-PolicyLine {
        param($Entry, [string]$Color)

        $suffix = @()
        if ($Entry.intent) { $suffix += "intent: $($Entry.intent)" }
        if ($Entry.filterId) { $suffix += "filter: $($Entry.filterType)" }
        if ($Entry.source -and $Entry.source -ne 'direct') { $suffix += "via $($Entry.source)" }
        $suffixText = if ($suffix.Count -gt 0) { "  [$($suffix -join ', ')]" } else { '' }

        Write-Host ("    {0,-32} {1}{2}" -f $Entry.resourceType, $Entry.displayName, $suffixText) -ForegroundColor $Color
        Write-Host ("    {0,-32} {1}" -f '', $Entry.policyId) -ForegroundColor DarkGray
    }

    function Resolve-GroupResult {
        param([string]$Id, [string]$KnownName)

        $key = $Id.ToLowerInvariant()
        $entry = $lookup[$key]

        $included = @()
        $excluded = @()
        $displayName = $KnownName

        if ($entry) {
            $included = @($entry.includedBy)
            $excluded = @($entry.excludedBy)
            if (-not $displayName) { $displayName = $entry.displayName }
        }

        # Indirect usage: is this group a member of a group that IS assigned?
        $viaParents = [System.Collections.Generic.List[object]]::new()
        if ($transitiveAvailable) {
            try {
                $uri = "$($index.graphBaseUrl)/$($index.apiVersion)/groups/$Id/transitiveMemberOf/microsoft.graph.group" + '?$select=id,displayName'
                $parents = (Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop).value
                foreach ($parent in @($parents)) {
                    $parentEntry = $lookup[([string]$parent.id).ToLowerInvariant()]
                    if ($parentEntry) {
                        $viaParents.Add([PSCustomObject]@{
                            ParentGroupId   = [string]$parent.id
                            ParentGroupName = [string]$parent.displayName
                            IncludeCount    = @($parentEntry.includedBy).Count
                            ExcludeCount    = @($parentEntry.excludedBy).Count
                        })
                    }
                }
            }
            catch {
                Write-Warning "Transitive lookup failed for ${Id}: $($_.Exception.Message)"
            }
        }

        [PSCustomObject]@{
            GroupId          = $Id
            GroupDisplayName = $displayName
            IsAssigned       = ($included.Count + $excluded.Count) -gt 0
            IncludeCount     = $included.Count
            ExcludeCount     = $excluded.Count
            IncludedBy       = $included
            ExcludedBy       = $excluded
            UsedViaParent    = @($viaParents)
            IndexGeneratedUtc = $index.generatedUtc
        }
    }

    function Show-GroupResult {
        param($Result)

        $label = if ($Result.GroupDisplayName) { "$($Result.GroupDisplayName)  [$($Result.GroupId)]" } else { $Result.GroupId }

        if ($Summary) {
            $color = if ($Result.IsAssigned) { 'Green' } elseif ($Result.UsedViaParent.Count -gt 0) { 'Yellow' } else { 'DarkYellow' }
            $state = if ($Result.IsAssigned) { "$($Result.IncludeCount) include / $($Result.ExcludeCount) exclude" }
                     elseif ($Result.UsedViaParent.Count -gt 0) { "not assigned directly, but nested under $($Result.UsedViaParent.Count) assigned group(s)" }
                     else { 'NOT ASSIGNED to anything in the index' }
            Write-Host ("{0,-60} {1}" -f $label, $state) -ForegroundColor $color
            return
        }

        Write-Host ("=" * 90) -ForegroundColor DarkGray
        Write-Host "Group: " -NoNewline -ForegroundColor White
        Write-Host $label -ForegroundColor Cyan

        if (-not $Result.IsAssigned) {
            Write-Host "  No Intune assignments found in the index." -ForegroundColor DarkYellow
        }

        if ($Result.IncludeCount -gt 0) {
            Write-Host "`n  INCLUDED in $($Result.IncludeCount) policy/policies:" -ForegroundColor Green
            foreach ($entry in ($Result.IncludedBy | Sort-Object resourceType, displayName)) {
                Write-PolicyLine -Entry $entry -Color 'Gray'
            }
        }

        if ($Result.ExcludeCount -gt 0) {
            Write-Host "`n  EXCLUDED from $($Result.ExcludeCount) policy/policies:" -ForegroundColor Magenta
            foreach ($entry in ($Result.ExcludedBy | Sort-Object resourceType, displayName)) {
                Write-PolicyLine -Entry $entry -Color 'Gray'
            }
        }

        if ($Result.UsedViaParent.Count -gt 0) {
            Write-Host "`n  Used INDIRECTLY - member of these assigned group(s):" -ForegroundColor Yellow
            foreach ($parent in $Result.UsedViaParent) {
                Write-Host ("    {0}  [{1}]  {2} include / {3} exclude" -f $parent.ParentGroupName, $parent.ParentGroupId, $parent.IncludeCount, $parent.ExcludeCount) -ForegroundColor Gray
            }
        }

        Write-Host ""
    }
}

process {
    if ($PSCmdlet.ParameterSetName -eq 'ByName') { return }

    foreach ($id in @($GroupId)) {
        if (-not $id) { continue }
        $result = Resolve-GroupResult -Id $id.Trim()
        $results.Add($result)
        Show-GroupResult -Result $result
    }
}

end {
    if ($PSCmdlet.ParameterSetName -eq 'ByName') {
        $matched = @($lookup.Values | Where-Object { $_.displayName -like $GroupName })
        if ($matched.Count -eq 0) {
            Write-Host "No group in the index has a display name matching '$GroupName'." -ForegroundColor DarkYellow
            Write-Host "That means no assigned group matches - a group with that name may still exist but be unassigned." -ForegroundColor DarkGray
        }
        foreach ($m in $matched) {
            $result = Resolve-GroupResult -Id $m.groupId -KnownName $m.displayName
            $results.Add($result)
            Show-GroupResult -Result $result
        }
    }

    if ($results.Count -eq 0) {
        Write-Host "No group IDs supplied. Use -GroupId <guid> or pipe a list of IDs." -ForegroundColor Yellow
        return
    }

    if ($results.Count -gt 1) {
        $assigned = @($results | Where-Object { $_.IsAssigned }).Count
        $nested = @($results | Where-Object { -not $_.IsAssigned -and $_.UsedViaParent.Count -gt 0 }).Count
        Write-Host ("-" * 90) -ForegroundColor DarkGray
        Write-Host "Checked $($results.Count) group(s): $assigned assigned, $nested used only via nesting, $($results.Count - $assigned - $nested) unused." -ForegroundColor Cyan
        Write-Host ""
    }

    if ($ExportCsv) {
        $rows = foreach ($result in $results) {
            if (-not $result.IsAssigned) {
                [PSCustomObject]@{
                    GroupId = $result.GroupId; GroupName = $result.GroupDisplayName; Mode = 'None'
                    PolicyType = ''; PolicyName = ''; PolicyId = ''; Intent = ''; FilterType = ''
                }
                continue
            }
            foreach ($pair in @(@{ Mode = 'Include'; Items = $result.IncludedBy }, @{ Mode = 'Exclude'; Items = $result.ExcludedBy })) {
                foreach ($entry in $pair.Items) {
                    [PSCustomObject]@{
                        GroupId = $result.GroupId; GroupName = $result.GroupDisplayName; Mode = $pair.Mode
                        PolicyType = $entry.resourceType; PolicyName = $entry.displayName; PolicyId = $entry.policyId
                        Intent = $entry.intent; FilterType = $entry.filterType
                    }
                }
            }
        }
        $rows | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
        Write-Host "CSV written to: $ExportCsv" -ForegroundColor Green
    }

    if ($PassThru) { $results }
}
