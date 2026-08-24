<#
.SYNOPSIS
    Exports the Intune "Devices with inventory" (DevicesWithInventory) report for
    Windows devices and writes it to CSV sorted by DeviceId.

.DESCRIPTION
    Submits an export job to /beta/deviceManagement/reports/exportJobs, polls it to
    completion, downloads the resulting zip, expands it, sorts the rows by DeviceId
    and writes a single CSV.

    The exportJobs API has no orderBy, so the sort is done client side after download.

    Reuses the current Microsoft Graph session if there is one (Get-MgContext);
    otherwise connects with DeviceManagementManagedDevices.Read.All.

.PARAMETER Path
    Output CSV path. Defaults to .\DevicesWithInventory-<yyyyMMdd-HHmmss>.csv

.PARAMETER Select
    Report columns to request. Defaults to DeviceId, UPN (the primary user's
    user principal name) and DeviceName. Pass an empty array to export every
    column of the report.

    Column names are case sensitive to Graph and an invalid name fails the job.
    Other useful ones: UserEmail, UserName, SerialNumber, managementAgent, OS,
    OSVersion, Ownership, ComplianceState, LastContact, Manufacturer, Model,
    StorageTotal, StorageFree, WiFiIPv4Address, EthernetMacAddress, JoinType.

.PARAMETER Filter
    Overrides the default Windows platform filter. Pass an empty string for all
    platforms. The default matches the device types the Intune portal uses for
    the Windows platform pill:
      0 desktop, 1 windowsRT, 4 windowsPhone, 7 winEmbedded,
      15 holoLens, 16 surfaceHub, 19 windows10x

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
    .\Export-WindowsDevicesWithInventory.ps1

.EXAMPLE
    # Mail attribute instead of the sign-in name
    .\Export-WindowsDevicesWithInventory.ps1 -Select DeviceId,UserEmail,DeviceName

.EXAMPLE
    # Every column in the report
    .\Export-WindowsDevicesWithInventory.ps1 -Path C:\Reports\win-inventory.csv -Select @()

.EXAMPLE
    # Windows devices that are also non-compliant
    .\Export-WindowsDevicesWithInventory.ps1 -Filter "((DeviceType eq '0') or (DeviceType eq '19')) and (ComplianceState eq '1')"

.NOTES
    Requires: Microsoft.Graph.Authentication
              Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
    Scope:    DeviceManagementManagedDevices.Read.All
#>

[CmdletBinding()]
param(
    [string]$Path = (Join-Path (Get-Location).Path "DevicesWithInventory-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"),

    [string[]]$Select = @('DeviceId', 'UPN', 'DeviceName'),

    [string]$Filter = "((DeviceType eq '0') or (DeviceType eq '1') or (DeviceType eq '4') or (DeviceType eq '7') or (DeviceType eq '15') or (DeviceType eq '16') or (DeviceType eq '19'))",

    [ValidateRange(5, 300)]
    [int]$PollSeconds = 15,

    [ValidateRange(1, 240)]
    [int]$TimeoutMinutes = 30,

    [switch]$KeepRawFiles,

    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

$exportJobsUri = 'https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs'

# --- session ---------------------------------------------------------------
if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) {
    throw 'Microsoft.Graph.Authentication is required: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}

if (-not (Get-MgContext)) {
    Write-Verbose 'No existing Graph session, connecting.'
    Connect-MgGraph -Scopes 'DeviceManagementManagedDevices.Read.All' -NoWelcome
}

$outDir = Split-Path -Path $Path -Parent
if ([string]::IsNullOrWhiteSpace($outDir)) { $outDir = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -Path $outDir -ItemType Directory -Force | Out-Null
}

# --- submit ----------------------------------------------------------------
$body = @{
    reportName = 'DevicesWithInventory'
    format     = 'csv'
    filter     = $Filter
    search     = ''
}
if ($Select) { $body['select'] = @($Select) }

Write-Host "Requesting DevicesWithInventory export..." -ForegroundColor Cyan
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
    throw "Export job $($exportJob.id) failed. Check the report name, filter and select columns."
}

$elapsed = [datetime]::UtcNow - ([datetime]$jobStatus.requestDateTime).ToUniversalTime()
Write-Host ("Export completed in {0:m\m\ ss\s}." -f $elapsed) -ForegroundColor Green

# --- download & expand -----------------------------------------------------
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$zipPath = Join-Path $outDir "DevicesWithInventory-$stamp.zip"
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "DevicesWithInventory-$stamp"

# The URL is a pre-authenticated blob SAS - do not attach the Graph token to it.
Invoke-WebRequest -Uri $jobStatus.url -OutFile $zipPath -UseBasicParsing | Out-Null

New-Item -Path $workDir -ItemType Directory -Force | Out-Null
try {
    Expand-Archive -LiteralPath $zipPath -DestinationPath $workDir -Force

    $rawCsv = Get-ChildItem -LiteralPath $workDir -Filter *.csv -Recurse | Select-Object -First 1
    if (-not $rawCsv) { throw "No CSV found inside $zipPath." }

    # --- sort by DeviceId --------------------------------------------------
    $rows = Import-Csv -LiteralPath $rawCsv.FullName

    $idColumn = ($rows | Select-Object -First 1).PSObject.Properties.Name |
        Where-Object { $_ -replace '\s', '' -eq 'DeviceId' } | Select-Object -First 1
    if (-not $idColumn) {
        throw "The export has no DeviceId column. Add DeviceId to -Select."
    }

    $sorted = $rows | Sort-Object -Property $idColumn
    $sorted | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8

    if ($KeepRawFiles) {
        Copy-Item -LiteralPath $rawCsv.FullName -Destination (Join-Path $outDir "DevicesWithInventory-$stamp-raw.csv") -Force
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
