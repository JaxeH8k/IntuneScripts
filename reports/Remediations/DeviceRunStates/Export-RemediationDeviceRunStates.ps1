<#
.SYNOPSIS
    Exports the Intune remediation (proactive remediation) device run states report
    (DeviceRunStatesByProactiveRemediation) for one remediation policy and writes
    it to CSV sorted by DeviceId.

.DESCRIPTION
    Submits an export job to /beta/deviceManagement/reports/exportJobs, polls it to
    completion, downloads the resulting zip, expands it, sorts the rows by DeviceId
    and writes a single CSV.

    The exportJobs API has no orderBy, so the sort is done client side after download.

    Reuses the current Microsoft Graph session if there is one (Get-MgContext);
    otherwise connects with DeviceManagementManagedDevices.Read.All and
    DeviceManagementConfiguration.Read.All.

.PARAMETER PolicyId
    Id (GUID) of the remediation script / device health script whose run states you
    want. This is the id from /beta/deviceManagement/deviceHealthScripts, and the
    guid in the portal URL when the remediation is open.

.PARAMETER Path
    Output CSV path. Defaults to
    .\RemediationDeviceRunStates-<policyId>-<yyyyMMdd-HHmmss>.csv

.PARAMETER Select
    Report columns to request. Defaults to every column of the report, because the
    useful payload (the detection script output) lives in the wide columns.

    Column names are case sensitive to Graph and an invalid name fails the job.
    Commonly used ones: DeviceId, DeviceName, UPN, UserName, UserEmail,
    DetectionStatus, RemediationStatus, PreRemediationDetectScriptOutput,
    PreRemediationDetectScriptError, PostRemediationDetectScriptOutput,
    PostRemediationDetectScriptError, RemediationScriptErrorDetails, OSVersion,
    LastSyncTime, InternalVersion, ModifiedTime. Verify a narrowed list against a
    full export first - a typo just fails the job with no detail.

.PARAMETER Filter
    Overrides the default filter, which is "(PolicyId eq '<PolicyId>')". The report
    requires a PolicyId filter, so anything you pass here should still include it,
    e.g. "(PolicyId eq '<guid>') and (DetectionStatus eq '1')".

.PARAMETER PollSeconds
    Seconds between status checks. Default 15.

.PARAMETER TimeoutMinutes
    Give up if the job has not completed in this long. Default 30.

.PARAMETER KeepRawFiles
    Keep the downloaded zip and the raw unsorted CSV next to -Path instead of
    cleaning them up.

.PARAMETER PassThru
    Also emit the sorted rows to the pipeline.

.EXAMPLE
    .\Export-RemediationDeviceRunStates.ps1 -PolicyId 8f2c1d4e-1234-4a7b-9c8d-0e1f2a3b4c5d

.EXAMPLE
    # Just the identity and status columns
    .\Export-RemediationDeviceRunStates.ps1 -PolicyId <guid> -Select DeviceId,DeviceName,UPN,DetectionStatus,RemediationStatus

.EXAMPLE
    # Find the policy ids first
    Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts?$select=id,displayName' |
        Select-Object -ExpandProperty value | ForEach-Object { [pscustomobject]$_ }

.NOTES
    Requires: Microsoft.Graph.Authentication
              Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
    Scopes:   DeviceManagementManagedDevices.Read.All,
              DeviceManagementConfiguration.Read.All

    DetectionStatus / RemediationStatus come back as numeric codes, not text -
    1 = success / issue not detected, 2 = issue detected, 3 = failed, 4 = script
    error, 5 = pending. Portal wording differs slightly per column.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$PolicyId,

    [string]$Path,

    [string[]]$Select = @(),

    [string]$Filter,

    [ValidateRange(5, 300)]
    [int]$PollSeconds = 15,

    [ValidateRange(1, 240)]
    [int]$TimeoutMinutes = 30,

    [switch]$KeepRawFiles,

    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

$exportJobsUri = 'https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs'

if (-not $Filter) { $Filter = "(PolicyId eq '$PolicyId')" }
if (-not $Path) {
    $Path = Join-Path (Get-Location).Path "RemediationDeviceRunStates-$PolicyId-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
}

# --- session ---------------------------------------------------------------
if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) {
    throw 'Microsoft.Graph.Authentication is required: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}

if (-not (Get-MgContext)) {
    Write-Verbose 'No existing Graph session, connecting.'
    Connect-MgGraph -Scopes 'DeviceManagementManagedDevices.Read.All', 'DeviceManagementConfiguration.Read.All' -NoWelcome
}

$outDir = Split-Path -Path $Path -Parent
if ([string]::IsNullOrWhiteSpace($outDir)) { $outDir = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -Path $outDir -ItemType Directory -Force | Out-Null
}

# --- submit ----------------------------------------------------------------
$body = @{
    reportName = 'DeviceRunStatesByProactiveRemediation'
    format     = 'csv'
    filter     = $Filter
    search     = ''
}
if ($Select) { $body['select'] = @($Select) }

Write-Host "Requesting DeviceRunStatesByProactiveRemediation export..." -ForegroundColor Cyan
Write-Verbose "Filter: $Filter"

$exportJob = Invoke-MgGraphRequest -Method POST -Uri $exportJobsUri `
    -Body ($body | ConvertTo-Json -Depth 3) -ContentType 'application/json'

$jobUri    = "$exportJobsUri('$($exportJob.id)')"
$jobStatus = $exportJob
Write-Verbose "Export job id: $($exportJob.id)"

# --- poll ------------------------------------------------------------------
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$status   = $exportJob.status

while ($status -notin @('completed', 'failed')) {
    if ((Get-Date) -gt $deadline) {
        throw "Export job $($exportJob.id) did not complete within $TimeoutMinutes minutes (last status: $status)."
    }
    Start-Sleep -Seconds $PollSeconds
    $jobStatus = Invoke-MgGraphRequest -Method GET -Uri $jobUri
    $status    = $jobStatus.status
    Write-Verbose "Status: $status"
}

if ($status -eq 'failed') {
    throw "Export job $($exportJob.id) failed. Check the policy id, filter and select columns."
}

$elapsed = [datetime]::UtcNow - ([datetime]$jobStatus.requestDateTime).ToUniversalTime()
Write-Host ("Export completed in {0:m\m\ ss\s}." -f $elapsed) -ForegroundColor Green

# --- download & expand -----------------------------------------------------
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$zipPath = Join-Path $outDir "RemediationDeviceRunStates-$stamp.zip"
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "RemediationDeviceRunStates-$stamp"

# The URL is a pre-authenticated blob SAS - do not attach the Graph token to it.
Invoke-WebRequest -Uri $jobStatus.url -OutFile $zipPath -UseBasicParsing | Out-Null

New-Item -Path $workDir -ItemType Directory -Force | Out-Null
try {
    Expand-Archive -LiteralPath $zipPath -DestinationPath $workDir -Force

    $rawCsv = Get-ChildItem -LiteralPath $workDir -Filter *.csv -Recurse | Select-Object -First 1
    if (-not $rawCsv) { throw "No CSV found inside $zipPath." }

    # --- sort by DeviceId --------------------------------------------------
    $rows = Import-Csv -LiteralPath $rawCsv.FullName

    if (-not $rows) {
        Write-Warning "The export returned no rows. Check that policy $PolicyId is assigned and has reported devices."
    }

    $idColumn = ($rows | Select-Object -First 1).PSObject.Properties.Name |
        Where-Object { $_ -replace '\s', '' -eq 'DeviceId' } | Select-Object -First 1
    if ($rows -and -not $idColumn) {
        throw "The export has no DeviceId column. Add DeviceId to -Select."
    }

    $sorted = if ($idColumn) { @($rows | Sort-Object -Property $idColumn) } else { @() }
    $sorted | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8

    if ($KeepRawFiles) {
        Copy-Item -LiteralPath $rawCsv.FullName -Destination (Join-Path $outDir "RemediationDeviceRunStates-$stamp-raw.csv") -Force
    }

    Write-Host "$($sorted.Count) rows written to $Path" -ForegroundColor Green
    if ($PassThru) { $sorted }
}
finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $KeepRawFiles) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }
}
