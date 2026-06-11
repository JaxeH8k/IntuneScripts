<#
.SYNOPSIS
    Reports recent Intune (MDM) sync sessions with status and errors to CSV.

.DESCRIPTION
    Correlates two data sources on the local device:
      1. Windows Event Log:
         Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin
           - Event ID 208 : OMA-DM session started (includes Origin = trigger source)
           - Event ID 209 : OMA-DM session ended with status (success or error HRESULT)
           - Event ID 201 : OMA-DM message failed to be sent (transport-level error)
           - Event ID 404 : MDM ConfigurationManager command failure (CSP/policy errors
                            that occurred during the sync window)
      2. Registry:
           - HKLM:\SOFTWARE\Microsoft\Enrollments\<GUID>          (enrollment metadata)
           - HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts\<GUID>\Protected\ConnInfo
               ServerLastAccessTime  = last sync attempt
               ServerLastSuccessTime = last successful sync

    Sessions are reconstructed by pairing each 208 (start) with the next 209 (end)
    for the same enrollment, then attaching any 201/404 errors that fired inside
    that session's time window.

.PARAMETER Days
    How many days of event history to include. Default: 7.

.PARAMETER OutputPath
    CSV output path. Default: .\IntuneSyncHistory_<COMPUTERNAME>_<timestamp>.csv

.PARAMETER IncludePolicyErrors
    Also collect Event ID 404 (CSP command failures) within each sync window.

.NOTES
    Run as Administrator (the OMADM\Accounts\Protected key is ACL-restricted).
    Tested pattern targets Windows 10/11 Intune-enrolled devices.

.EXAMPLE
    .\Get-IntuneSyncHistory.ps1 -Days 14 -IncludePolicyErrors
#>

[CmdletBinding()]
param(
    [int]$Days = 7,
    [string]$OutputPath = (Join-Path (Get-Location) ("IntuneSyncHistory_{0}_{1:yyyyMMdd_HHmmss}.csv" -f $env:COMPUTERNAME, (Get-Date))),
    [switch]$IncludePolicyErrors
)

#region --- Constants ---------------------------------------------------------

$LogName        = 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin'
$SessionStartId = 208
$SessionEndId   = 209
$SendFailId     = 201
$CspFailId      = 404
$StartTime      = (Get-Date).AddDays(-$Days)

# Known Origin codes for Event 208 (what triggered the sync).
# Sources: petervanderwoude.nl MDM policy refresh analysis.
# Codes not in this table are reported as the raw hex value.
$OriginMap = @{
    '0x3'  = 'Scheduled check-in'
    '0x7'  = 'Push notification (Intune-initiated / portal Sync button)'
    '0x25' = 'Manual sync (client UI)'        # observed in the wild; exact UI source varies by build
    '0x26' = 'Manual sync (client UI)'        # observed in the wild; exact UI source varies by build
    # <VERIFY_THIS>: Microsoft does not publish a complete Origin code table.
    # 0xF and other codes appear in field reports without authoritative meaning.
}

#endregion

#region --- Helpers -----------------------------------------------------------

function ConvertTo-FriendlyHResult {
    param([string]$HexCode)
    if ([string]::IsNullOrWhiteSpace($HexCode)) { return '' }
    try {
        $intVal = [Convert]::ToInt32($HexCode, 16)
        $msg = [System.ComponentModel.Win32Exception]::new($intVal).Message
        if ($msg -and $msg -notmatch '^Unknown error') { return $msg }
    } catch { }
    return "Unresolved error code $HexCode"
}

function Get-EventField {
    # Extracts a value like "Origin: (0x7)" from an event message via regex.
    param([string]$Message, [string]$FieldName)
    if ($Message -match "$FieldName\s*:?\s*\(([^)]*)\)") { return $Matches[1] }
    return $null
}

function Parse-OmaDmTimestamp {
    # ServerLastAccessTime / ServerLastSuccessTime are stored as strings.
    # Observed format: 'yyyy/MM/dd:HH:mm:ss' in UTC, but this varies by OS build,
    # so parse defensively.
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $formats = @(
        'yyyy/MM/dd:HH:mm:ss',
        'yyyy/MM/dd HH:mm:ss',
        'yyyy-MM-ddTHH:mm:ss'
    )
    foreach ($f in $formats) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($Raw, $f, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
            return $parsed.ToLocalTime()
        }
    }
    # Fall back to a loose parse; if everything fails, return the raw string.
    $loose = [datetime]::MinValue
    if ([datetime]::TryParse($Raw, [ref]$loose)) { return $loose }
    return $Raw
}

#endregion

#region --- 1. Registry: enrollment + last sync state -------------------------

Write-Verbose 'Reading MDM enrollment registry data...'

$Enrollments = @{}
$EnrollmentRoot = 'HKLM:\SOFTWARE\Microsoft\Enrollments'

Get-ChildItem -Path $EnrollmentRoot -ErrorAction SilentlyContinue | ForEach-Object {
    $props = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
    # EnrollmentType 6 = full MDM enrollment (Intune)
    if ($props.EnrollmentType -eq 6) {
        $guid = $_.PSChildName
        $connInfoPath = "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts\$guid\Protected\ConnInfo"
        $connInfo = Get-ItemProperty -Path $connInfoPath -ErrorAction SilentlyContinue

        $Enrollments[$guid] = [PSCustomObject]@{
            EnrollmentGuid        = $guid
            UPN                   = $props.UPN
            DiscoveryServiceUrl   = $props.DiscoveryServiceFullUrl
            LastSyncAttempt       = Parse-OmaDmTimestamp $connInfo.ServerLastAccessTime
            LastSyncSuccess       = Parse-OmaDmTimestamp $connInfo.ServerLastSuccessTime
        }
    }
}

if ($Enrollments.Count -eq 0) {
    Write-Warning 'No MDM (EnrollmentType=6) enrollment found in registry. Is this device Intune-enrolled? Are you running elevated?'
}

#endregion

#region --- 2. Event log: reconstruct sync sessions ---------------------------

Write-Verbose "Querying '$LogName' for the last $Days day(s)..."

$idsToQuery = @($SessionStartId, $SessionEndId, $SendFailId)
if ($IncludePolicyErrors) { $idsToQuery += $CspFailId }

$events = Get-WinEvent -FilterHashtable @{
    LogName   = $LogName
    Id        = $idsToQuery
    StartTime = $StartTime
} -ErrorAction SilentlyContinue | Sort-Object TimeCreated

if (-not $events) {
    Write-Warning "No events found in '$LogName' for the last $Days day(s)."
}

# Bucket events by type for correlation
$startEvents = @($events | Where-Object Id -eq $SessionStartId)
$endEvents   = [System.Collections.Generic.List[object]]@($events | Where-Object Id -eq $SessionEndId)
$sendFails   = @($events | Where-Object Id -eq $SendFailId)
$cspFails    = @($events | Where-Object Id -eq $CspFailId)

$Sessions = foreach ($start in $startEvents) {

    $enrollGuid = Get-EventField -Message $start.Message -FieldName 'EnrollmentID'
    $sessionId  = Get-EventField -Message $start.Message -FieldName 'SessionID'
    $originRaw  = Get-EventField -Message $start.Message -FieldName 'Origin'

    $originFriendly = if ($originRaw -and $OriginMap.ContainsKey($originRaw)) {
        $OriginMap[$originRaw]
    } elseif ($originRaw) {
        "Unknown origin ($originRaw)"
    } else { '' }

    # Pair with the FIRST 209 that occurs after this 208 (sessions don't overlap
    # per enrollment in practice). Remove it from the pool once consumed.
    $end = $endEvents | Where-Object { $_.TimeCreated -gt $start.TimeCreated } | Select-Object -First 1
    if ($end) { [void]$endEvents.Remove($end) }

    $endStatusRaw = ''
    $status       = 'Incomplete / no session-end event found'
    if ($end) {
        # 209 message: "MDM Session: OMA-DM session ended with status: (...)"
        if ($end.Message -match 'status:\s*\((.+?)\)\.?\s*$') { $endStatusRaw = $Matches[1] }
        $status = if ($endStatusRaw -match 'success|The operation completed successfully|0x0\b' -or
                      $endStatusRaw -eq '') {
            'Success'
        } else {
            'Failed'
        }
    }

    # Window for attaching errors: start -> end (or start + 10 min if no end)
    $windowEnd = if ($end) { $end.TimeCreated } else { $start.TimeCreated.AddMinutes(10) }

    $windowSendFails = $sendFails | Where-Object {
        $_.TimeCreated -ge $start.TimeCreated -and $_.TimeCreated -le $windowEnd
    }
    $windowCspFails = $cspFails | Where-Object {
        $_.TimeCreated -ge $start.TimeCreated -and $_.TimeCreated -le $windowEnd
    }

    $transportErrors = ($windowSendFails | ForEach-Object {
        if ($_.Message -match 'Result:\s*\((.+?)\)') { $Matches[1] } else { $_.Message }
    } | Select-Object -Unique) -join ' | '

    $policyErrors = ($windowCspFails | ForEach-Object {
        $uri = Get-EventField -Message $_.Message -FieldName 'CSP URI'
        $res = if ($_.Message -match 'Result:\s*\((.+?)\)') { $Matches[1] } else { '' }
        if ($uri) { "$uri => $res" } else { $res }
    } | Select-Object -Unique) -join ' | '

    if ($status -eq 'Success' -and ($transportErrors -or $policyErrors)) {
        $status = 'Success (with errors during session)'
    }

    $enrollInfo = if ($enrollGuid -and $Enrollments.ContainsKey($enrollGuid)) { $Enrollments[$enrollGuid] } else { $null }

    [PSCustomObject]@{
        ComputerName            = $env:COMPUTERNAME
        SyncStart               = $start.TimeCreated
        SyncEnd                 = if ($end) { $end.TimeCreated } else { $null }
        DurationSeconds         = if ($end) { [math]::Round(($end.TimeCreated - $start.TimeCreated).TotalSeconds, 1) } else { $null }
        Status                  = $status
        EndStatusDetail         = $endStatusRaw
        TriggerOrigin           = $originFriendly
        OriginCode              = $originRaw
        SessionID               = $sessionId
        EnrollmentGuid          = $enrollGuid
        EnrolledUPN             = $enrollInfo.UPN
        TransportErrors_Evt201  = $transportErrors
        PolicyErrors_Evt404     = $policyErrors
        Reg_LastSyncAttempt     = $enrollInfo.LastSyncAttempt
        Reg_LastSyncSuccess     = $enrollInfo.LastSyncSuccess
    }
}

#endregion

#region --- 3. Output ---------------------------------------------------------

if ($Sessions) {
    $Sessions = $Sessions | Sort-Object SyncStart -Descending
    $Sessions | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Host "Exported $(@($Sessions).Count) sync session(s) to: $OutputPath" -ForegroundColor Green

    # Quick console summary
    $failed = @($Sessions | Where-Object Status -like 'Failed*')
    Write-Host ("Summary: {0} total | {1} failed | {2} with in-session errors" -f
        @($Sessions).Count, $failed.Count,
        @($Sessions | Where-Object Status -like '*with errors*').Count)
} else {
    Write-Warning 'No sync sessions reconstructed. Nothing exported.'
}

#endregion
