<#
.SYNOPSIS
    Scores local Windows profiles to determine the most active AD user on a device,
    for use as an input to setting the Intune device's Primary User (separate step,
    not performed by this script).

.DESCRIPTION
    Combines three signals per user SID over a configurable lookback window:

      - Recency   : days since last interactive logon. Primary source is Security
                    event 4624; falls back to Win32_UserProfile.LastUseTime, which
                    persists independent of event log rollover.
      - Frequency : distinct calendar days with an interactive logon (event 4624,
                    LogonType 2/10/11).
      - Duration  : total interactive session time, computed by pairing 4624 logons
                    with 4634/4647 logoffs via the shared TargetLogonId correlation
                    field (more accurate than pairing by SID alone, which breaks
                    under fast user switching / concurrent RDP + console sessions).

    Excludes local/well-known SIDs, special profiles, and non-interactive logon types.
    Does NOT call Graph or touch Intune - this only scores what's on the device.

    Targets hybrid Azure AD-joined devices: the profile SID here is the classic on-prem
    AD form (S-1-5-21-...), not a cloud SID. These endpoints have no DC connectivity at
    execution time, so this script makes no attempt at AD or Graph resolution at all -
    MostActiveSid is the headline output, and a separate central process (with Graph
    connectivity) resolves that SID against onPremisesSecurityIdentifier, backed by a
    local cache, before calling "set primary user."

.NOTES
    Must run elevated (reads the Security event log).
    Effective lookback is capped by however far back your Security log actually
    retains 4624/4634/4647 events - check your log retention/max-size policy if
    -LookbackDays results in a shorter effective window than expected.
#>

param(
    [int]$LookbackDays = 30,

    # Adjust to your naming convention for service/helpdesk/shared accounts
    [string[]]$ExcludeSamAccountPatterns = @('svc_*','admin_*','helpdesk*'),

    [double]$RecencyWeight   = 0.5,
    [double]$FrequencyWeight = 0.3,
    [double]$DurationWeight  = 0.2,

    # Half-life in days for the recency exponential decay
    [double]$RecencyHalfLifeDays = 7,

    # Cap on a single paired session's duration, to blunt runaway/unlocked sessions
    [double]$MaxSessionHours = 16
)

$startTime = (Get-Date).AddDays(-$LookbackDays)

function Get-EventFieldValue {
    param($EventXml, [string]$FieldName)
    ($EventXml.Event.EventData.Data | Where-Object Name -eq $FieldName).'#text'
}

# ---- 1. Candidate profiles (persistent recency fallback, survives log rollover) ----
$profiles = Get-CimInstance -ClassName Win32_UserProfile | Where-Object {
    -not $_.Special -and
    $_.SID -match '^S-1-5-21-\d+-\d+-\d+-\d+$' -and
    $_.SID -notmatch '-(500|501)$'   # exclude built-in local Administrator/Guest
}

# ---- 2. Interactive logons (frequency + recency) ----
$logonFilter = @{ LogName = 'Security'; Id = 4624; StartTime = $startTime }
$logons = Get-WinEvent -FilterHashtable $logonFilter -ErrorAction SilentlyContinue | ForEach-Object {
    $xml = [xml]$_.ToXml()
    [PSCustomObject]@{
        TimeCreated = $_.TimeCreated
        TargetSid   = Get-EventFieldValue $xml 'TargetUserSid'
        LogonType   = Get-EventFieldValue $xml 'LogonType'
        LogonId     = Get-EventFieldValue $xml 'TargetLogonId'
    }
} | Where-Object { $_.LogonType -in '2','10','11' -and $_.TargetSid -match '^S-1-5-21-' }

# ---- 3. Logoffs, for duration pairing via TargetLogonId ----
$logoffFilter = @{ LogName = 'Security'; Id = 4634, 4647; StartTime = $startTime }
$logoffByLogonId = @{}
Get-WinEvent -FilterHashtable $logoffFilter -ErrorAction SilentlyContinue | ForEach-Object {
    $xml = [xml]$_.ToXml()
    $logonId = Get-EventFieldValue $xml 'TargetLogonId'
    if ($logonId) { $logoffByLogonId[$logonId] = $_.TimeCreated }
}

# ---- 4. Raw metrics per SID ----
$results = foreach ($p in $profiles) {
    $sid = $p.SID
    $userLogons = $logons | Where-Object TargetSid -eq $sid

    $distinctDays = ($userLogons.TimeCreated | ForEach-Object { $_.Date } | Sort-Object -Unique).Count

    $totalMinutes = 0
    foreach ($lo in $userLogons) {
        if ($lo.LogonId -and $logoffByLogonId.ContainsKey($lo.LogonId)) {
            $span = ($logoffByLogonId[$lo.LogonId] - $lo.TimeCreated).TotalMinutes
            if ($span -gt 0 -and $span -lt ($MaxSessionHours * 60)) { $totalMinutes += $span }
        }
    }

    $lastInteractive = if ($userLogons) {
        ($userLogons.TimeCreated | Sort-Object -Descending | Select-Object -First 1)
    } else {
        $p.LastUseTime   # fallback when the event log window doesn't cover this user
    }
    $daysSinceLast = if ($lastInteractive) { [math]::Round(((Get-Date) - $lastInteractive).TotalDays, 1) } else { $LookbackDays }

    [PSCustomObject]@{
        SID               = $sid
        ProfilePath       = $p.LocalPath
        DaysSinceLast     = $daysSinceLast
        DistinctLoginDays = $distinctDays
        TotalHours        = [math]::Round($totalMinutes / 60, 2)
    }
}

# ---- 5. Resolve SID -> account (profile folder name only), apply exclusion patterns ----
$scoredCandidates = foreach ($r in $results) {
    $account          = $null
    $resolutionMethod = $null

    $leaf = if ($r.ProfilePath) { Split-Path -Leaf $r.ProfilePath } else { $null }
    if ($leaf) {
        $account = $leaf
        $resolutionMethod = 'ProfileFolder-Unconfirmed'
    }
    # else: no profile path to derive a name from - leave $null; SID is still captured below

    $samAccountName = if ($account) { ($account -split '\\')[-1] } else { $null }
    $isExcluded = $false
    if ($samAccountName) {
        foreach ($pattern in $ExcludeSamAccountPatterns) {
            if ($samAccountName -like $pattern) { $isExcluded = $true; break }
        }
    }

    if (-not $isExcluded) {
        $r | Add-Member -NotePropertyName Account -NotePropertyValue $account -PassThru |
             Add-Member -NotePropertyName ResolutionMethod -NotePropertyValue $resolutionMethod -PassThru
    }
}

# ---- 6. Composite score ----
$maxDays  = ($scoredCandidates.DistinctLoginDays | Measure-Object -Maximum).Maximum
$maxHours = ($scoredCandidates.TotalHours       | Measure-Object -Maximum).Maximum

$scored = $scoredCandidates | ForEach-Object {
    $recencyScore   = [math]::Pow(0.5, $_.DaysSinceLast / $RecencyHalfLifeDays)
    $frequencyScore = if ($maxDays  -gt 0) { $_.DistinctLoginDays / $maxDays } else { 0 }
    $durationScore  = if ($maxHours -gt 0) { $_.TotalHours / $maxHours } else { 0 }

    $composite = ($RecencyWeight * $recencyScore) + ($FrequencyWeight * $frequencyScore) + ($DurationWeight * $durationScore)

    $_ | Add-Member -NotePropertyName CompositeScore -NotePropertyValue ([math]::Round($composite, 4)) -PassThru
}

$ranked = $scored | Sort-Object CompositeScore -Descending
$winner = $ranked | Select-Object -First 1

$output = [PSCustomObject]@{
    ComputerName      = $env:COMPUTERNAME
    MostActiveAccount = $winner.Account
    MostActiveSid     = $winner.SID           # the primary field - resolved to an Entra Object ID centrally, not here
    ResolutionMethod  = $winner.ResolutionMethod
    CompositeScore    = $winner.CompositeScore
    DaysSinceLast     = $winner.DaysSinceLast
    DistinctLoginDays = $winner.DistinctLoginDays
    TotalHours        = $winner.TotalHours
    LookbackDays      = $LookbackDays
    ScoredAt          = (Get-Date).ToString('o')
}

$output | ConvertTo-Json
Write-Verbose ($ranked | Format-Table Account, SID, ResolutionMethod, DaysSinceLast, DistinctLoginDays, TotalHours, CompositeScore -AutoSize | Out-String)
