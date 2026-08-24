<#
.SYNOPSIS
    Structured activity logging for the Intune primary-user automation. Every Graph
    operation lands in a local JSONL file and (optionally) a Log Analytics custom table.

.DESCRIPTION
    Two sinks, deliberately independent:

      * Local JSONL  - one JSON object per line, always written, never batched. This is the
                       source of truth: if the network, the token, or the workspace is down,
                       the run is still fully auditable from disk.
      * Log Analytics- batched to the Logs Ingestion API. Best effort only. A failure here
                       is warned about and counted, never thrown - shipping telemetry must
                       not be able to fail a device remediation that already succeeded.

    Log Analytics setup this expects (create once, then pass the values to
    Initialize-GraphLog):

      1. A custom table, e.g. IntuneGraphActivity_CL, with these columns:
           TimeGenerated (datetime), RunId (string), Level (string), Operation (string),
           Method (string), Uri (string), StatusCode (int), DurationMs (int),
           Attempt (int), DeviceId (string), TargetUserId (string), TargetSid (string),
           ClientRequestId (string), GraphRequestId (string), Message (string),
           Details (string)
      2. A Data Collection Endpoint (DCE) - gives you the -DceEndpoint URI.
      3. A Data Collection Rule (DCR) targeting that table - gives you the immutable id
         and the stream name (Custom-IntuneGraphActivity_CL).
      4. The identity running this needs "Monitoring Metrics Publisher" on the DCR.

    PRIVACY: these records intentionally contain UPNs, SIDs and device ids - that is the
    audit trail. Treat the JSONL files and the workspace table as personal data: retention
    policy, access control, the usual. Bearer tokens and secrets are redacted and never
    written, at any log level.

.NOTES
    Debug level is off by default because it records full request/response bodies. Turn it
    on per-run with -DebugLogging, mid-run with Set-GraphLogDebug, or out-of-band with
    $env:GRAPHLOG_DEBUG=1.
#>

$script:GraphLog = @{
    Initialized     = $false
    DebugEnabled    = $false
    RunId           = ''
    LogPath         = ''
    Buffer          = @()
    BatchSize       = 100
    DceEndpoint     = ''
    DcrImmutableId  = ''
    StreamName      = ''
    TokenProvider   = $null
    Token           = ''
    TokenExpiresOn  = [datetime]::MinValue
    Shipped         = 0
    Dropped         = 0
    Counts          = @{}
}

function Initialize-GraphLog {
    <#
    .SYNOPSIS
        Starts a logging run. Call once before any Graph work.

    .DESCRIPTION
        Stamps a RunId (a GUID) that tags every record from this run, so one execution can
        be pulled out of the workspace with a single `where RunId ==` even when runs overlap.

        Log Analytics is only enabled if all three of -DceEndpoint, -DcrImmutableId and
        -StreamName are supplied. Omit them and you get file + console logging with no
        Azure dependency at all.

    .PARAMETER MonitorTokenProvider
        Scriptblock returning a bearer token for https://monitor.azure.com. Only needed for
        the Log Analytics sink - the Graph token that Connect-MgGraph holds is for a
        different audience and cannot be reused here. Defaults to Get-AzAccessToken when
        Az.Accounts is loadable; supply your own for app-only/managed-identity auth.

    .EXAMPLE
        Initialize-GraphLog -LogDirectory ./logs
        Local file + console only.

    .EXAMPLE
        Initialize-GraphLog -LogDirectory ./logs -DebugLogging `
            -DceEndpoint 'https://intune-dce-abcd.eastus-1.ingest.monitor.azure.com' `
            -DcrImmutableId 'dcr-0123456789abcdef0123456789abcdef' `
            -StreamName 'Custom-IntuneGraphActivity_CL'
    #>
    param(
        [string]$LogDirectory = './logs',
        [string]$DceEndpoint,
        [string]$DcrImmutableId,
        [string]$StreamName,
        [scriptblock]$MonitorTokenProvider,
        [int]$BatchSize = 100,
        [switch]$DebugLogging
    )

    if (-not (Test-Path $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }

    # Debug is opt-in from any of three directions: the switch, an env var (lets an operator
    # flip it without editing the caller), or an inherited -Debug on the calling script.
    $debugOn = $DebugLogging -or
               ($env:GRAPHLOG_DEBUG -eq '1') -or
               ($DebugPreference -ne 'SilentlyContinue')

    $script:GraphLog.Initialized    = $true
    $script:GraphLog.DebugEnabled   = [bool]$debugOn
    $script:GraphLog.RunId          = (New-Guid).Guid
    $script:GraphLog.LogPath        = Join-Path $LogDirectory ("graph-activity-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd'))
    $script:GraphLog.Buffer         = @()
    $script:GraphLog.BatchSize      = $BatchSize
    $script:GraphLog.DceEndpoint    = $DceEndpoint
    $script:GraphLog.DcrImmutableId = $DcrImmutableId
    $script:GraphLog.StreamName     = $StreamName
    $script:GraphLog.TokenProvider  = $MonitorTokenProvider
    $script:GraphLog.Token          = ''
    $script:GraphLog.TokenExpiresOn = [datetime]::MinValue
    $script:GraphLog.Shipped        = 0
    $script:GraphLog.Dropped        = 0
    $script:GraphLog.Counts         = @{}

    $laEnabled = [bool]($DceEndpoint -and $DcrImmutableId -and $StreamName)

    Write-GraphLog -Level Information -Operation 'RunStart' -Message 'Logging run started' -Data @{
        logFile        = $script:GraphLog.LogPath
        debugLogging   = $script:GraphLog.DebugEnabled
        logAnalytics   = $laEnabled
        stream         = $StreamName
        user           = $env:USER
        computer       = [System.Net.Dns]::GetHostName()
        psVersion      = $PSVersionTable.PSVersion.ToString()
    }

    return $script:GraphLog.RunId
}

function Set-GraphLogDebug {
    <#
        Flips debug logging mid-run - e.g. one device keeps failing and you want full
        request/response bodies for just that device, without restarting the whole job.
    #>
    param([Parameter(Mandatory)][bool]$Enabled)

    $script:GraphLog.DebugEnabled = $Enabled
    Write-GraphLog -Level Information -Operation 'DebugToggle' -Message "Debug logging set to $Enabled"
}

function Write-GraphLog {
    <#
    .SYNOPSIS
        Writes one structured record to every configured sink.

    .PARAMETER Data
        Free-form hashtable of context. Recognised keys are promoted to their own columns
        (method/uri/statusCode/durationMs/attempt/deviceId/targetUserId/targetSid/
        clientRequestId/graphRequestId); anything else is JSON-serialised into Details, so
        callers can attach whatever they need without a schema change at this layer.
    #>
    param(
        [ValidateSet('Debug','Verbose','Information','Warning','Error')]
        [string]$Level = 'Information',
        [Parameter(Mandatory)][string]$Message,
        [string]$Operation = 'General',
        [hashtable]$Data = @{}
    )

    # Drop debug records entirely unless debug is on - cheapest possible no-op, and it means
    # callers can build debug payloads unconditionally without paying for them.
    if ($Level -eq 'Debug' -and -not $script:GraphLog.DebugEnabled) { return }

    if (-not $script:GraphLog.Initialized) {
        # Never lose a record because someone forgot to initialise; fall back to defaults.
        Initialize-GraphLog | Out-Null
    }

    $known = 'method','uri','statusCode','durationMs','attempt','deviceId','targetUserId','targetSid','clientRequestId','graphRequestId'
    $details = @{}
    foreach ($key in $Data.Keys) {
        if ($known -notcontains $key) { $details[$key] = $Data[$key] }
    }

    $record = [ordered]@{
        TimeGenerated   = (Get-Date).ToUniversalTime().ToString('o')
        RunId           = $script:GraphLog.RunId
        Level           = $Level
        Operation       = $Operation
        Method          = [string]$Data['method']
        Uri             = [string]$Data['uri']
        StatusCode      = [int]$Data['statusCode']      # [int]$null is 0, so a missing key is simply 0
        DurationMs      = [int]$Data['durationMs']
        Attempt         = [int]$Data['attempt']
        DeviceId        = [string]$Data['deviceId']
        TargetUserId    = [string]$Data['targetUserId']
        TargetSid       = [string]$Data['targetSid']
        ClientRequestId = [string]$Data['clientRequestId']
        GraphRequestId  = [string]$Data['graphRequestId']
        Message         = $Message
        Details         = if ($details.Count) { ($details | ConvertTo-Json -Depth 6 -Compress) } else { '' }
    }

    if (-not $script:GraphLog.Counts.ContainsKey($Level)) { $script:GraphLog.Counts[$Level] = 0 }
    $script:GraphLog.Counts[$Level]++

    # Sink 1: local JSONL. Compressed single line so the file stays grep/jq-friendly.
    try {
        ($record | ConvertTo-Json -Depth 8 -Compress) |
            Add-Content -Path $script:GraphLog.LogPath -Encoding UTF8
    }
    catch {
        Write-Warning "Could not write to $($script:GraphLog.LogPath): $($_.Exception.Message)"
    }

    # Sink 2: Log Analytics, batched.
    if ($script:GraphLog.DceEndpoint -and $script:GraphLog.DcrImmutableId -and $script:GraphLog.StreamName) {
        $script:GraphLog.Buffer += ,$record
        if ($script:GraphLog.Buffer.Count -ge $script:GraphLog.BatchSize) { Send-GraphLogBatch }
    }

    # Sink 3: the console, for whoever is watching the run.
    $line = "[{0}] {1,-11} {2} {3}" -f $record.TimeGenerated, $Level.ToUpper(), $Operation, $Message
    switch ($Level) {
        'Debug'       { Write-Debug   $line; if ($details.Count) { Write-Debug "  details: $($record.Details)" } }
        'Verbose'     { Write-Verbose $line }
        'Warning'     { Write-Warning $line }
        'Error'       { Write-Warning $line }   # the caller throws; this is the audit line, not the failure
        default       { Write-Host    $line }
    }
}

function Get-MonitorAccessToken {
    <#
        Bearer token for the Logs Ingestion API (audience https://monitor.azure.com).
        Cached until 5 minutes before expiry. Internal.
    #>
    if ($script:GraphLog.Token -and (Get-Date) -lt $script:GraphLog.TokenExpiresOn.AddMinutes(-5)) {
        return $script:GraphLog.Token
    }

    if ($script:GraphLog.TokenProvider) {
        $token = & $script:GraphLog.TokenProvider
        # A caller-supplied provider owns its own lifetime; assume a conservative 30 min.
        $script:GraphLog.Token          = [string]$token
        $script:GraphLog.TokenExpiresOn = (Get-Date).AddMinutes(30)
        return $script:GraphLog.Token
    }

    if (-not (Get-Module -ListAvailable Az.Accounts)) {
        throw 'No -MonitorTokenProvider supplied and Az.Accounts is not installed - cannot get a monitor.azure.com token.'
    }

    Import-Module Az.Accounts -ErrorAction Stop
    $azToken = Get-AzAccessToken -ResourceUrl 'https://monitor.azure.com' -ErrorAction Stop

    # Az.Accounts 3.x hands back a SecureString; 2.x a plain string. Handle both.
    if ($azToken.Token -is [System.Security.SecureString]) {
        $script:GraphLog.Token = [System.Net.NetworkCredential]::new('', $azToken.Token).Password
    }
    else {
        $script:GraphLog.Token = [string]$azToken.Token
    }
    $script:GraphLog.TokenExpiresOn = [datetime]$azToken.ExpiresOn.UtcDateTime

    return $script:GraphLog.Token
}

function Send-GraphLogBatch {
    <#
        Flushes the buffer to the Logs Ingestion API. Best effort: on failure the records
        are dropped from the buffer (they are already safe on disk) and counted, so a dead
        workspace cannot grow the buffer unboundedly or stall the run. Internal.
    #>
    if (-not $script:GraphLog.Buffer.Count) { return }

    $batch = $script:GraphLog.Buffer
    $script:GraphLog.Buffer = @()

    try {
        $token = Get-MonitorAccessToken
        $uri = "{0}/dataCollectionRules/{1}/streams/{2}?api-version=2023-01-01" -f
                   $script:GraphLog.DceEndpoint.TrimEnd('/'),
                   $script:GraphLog.DcrImmutableId,
                   $script:GraphLog.StreamName

        # The API caps a request at 1 MB, so split rather than blow the whole batch.
        $chunk = @()
        $chunkBytes = 0
        $chunks = @()
        foreach ($record in $batch) {
            $size = [System.Text.Encoding]::UTF8.GetByteCount(($record | ConvertTo-Json -Depth 8 -Compress))
            if ($chunk.Count -and ($chunkBytes + $size) -gt 900KB) {
                $chunks += ,$chunk
                $chunk = @()
                $chunkBytes = 0
            }
            $chunk += ,$record
            $chunkBytes += $size
        }
        if ($chunk.Count) { $chunks += ,$chunk }

        foreach ($c in $chunks) {
            $body = ConvertTo-Json -InputObject @($c) -Depth 8 -Compress
            Invoke-RestMethod -Method POST -Uri $uri -Body $body -ContentType 'application/json' `
                -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop | Out-Null
            $script:GraphLog.Shipped += $c.Count
        }
    }
    catch {
        $script:GraphLog.Dropped += $batch.Count
        # Warn, never throw - and never via Write-GraphLog, which would recurse straight
        # back into this function.
        Write-Warning "Log Analytics ingestion failed ($($batch.Count) records stay file-only): $($_.Exception.Message)"
    }
}

function Complete-GraphLog {
    <#
        Ends the run: writes a summary record, then flushes whatever is still buffered.
        Call this in a finally{} so it runs even when the job dies partway.
    #>
    Write-GraphLog -Level Information -Operation 'RunEnd' -Message 'Logging run complete' -Data @{
        counts       = $script:GraphLog.Counts
        laShipped    = $script:GraphLog.Shipped
        laDropped    = $script:GraphLog.Dropped
        logFile      = $script:GraphLog.LogPath
    }

    Send-GraphLogBatch

    Write-Host ("Log: {0}  (shipped {1}, file-only {2})" -f
        $script:GraphLog.LogPath, $script:GraphLog.Shipped, $script:GraphLog.Dropped)
}

function ConvertTo-SafeLogValue {
    <#
        Redacts anything that looks like a credential before it reaches a sink. Applied to
        headers, bodies and responses at debug level.

        Three passes, because secrets arrive in three shapes:
          * a dictionary key   - @{ Authorization = '...' }
          * a JSON string      - '{"password":"..."}' (bodies are usually already serialised)
          * a bearer token     - anywhere inside any string
        Internal.
    #>
    param($Value, [int]$Depth = 0)

    if ($Depth -gt 10) { return '***DEPTH-LIMIT***' }   # cyclic/very deep payloads

    $secretKeys = 'authorization','client_secret','clientsecret','password','pwd',
                  'access_token','refresh_token','id_token','secret','apikey','api_key'

    if ($null -eq $Value) { return $null }

    if ($Value -is [System.Collections.IDictionary]) {
        $safe = @{}
        foreach ($key in $Value.Keys) {
            if ($secretKeys -contains "$key".ToLower()) { $safe[$key] = '***REDACTED***' }
            else { $safe[$key] = ConvertTo-SafeLogValue -Value $Value[$key] -Depth ($Depth + 1) }
        }
        return $safe
    }

    if ($Value -is [string]) {
        # "password":"hunter2" -> "password":"***REDACTED***"  (bodies arrive pre-serialised)
        $pattern = '(?i)("(' + ($secretKeys -join '|') + ')"\s*:\s*)"[^"]*"'
        $safe = $Value -replace $pattern, '$1"***REDACTED***"'
        # ...and any bearer token, wherever it turns up.
        return ($safe -replace '(?i)(bearer\s+)[A-Za-z0-9\-\._~\+\/]+=*', '$1***REDACTED***')
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $safe = @{}
        foreach ($prop in $Value.PSObject.Properties) {
            if ($secretKeys -contains $prop.Name.ToLower()) { $safe[$prop.Name] = '***REDACTED***' }
            else { $safe[$prop.Name] = ConvertTo-SafeLogValue -Value $prop.Value -Depth ($Depth + 1) }
        }
        return $safe
    }

    # Collections (response header values, arrays of records) - scrub each element.
    if ($Value -is [System.Collections.IEnumerable]) {
        $safe = @()
        foreach ($item in $Value) { $safe += ,(ConvertTo-SafeLogValue -Value $item -Depth ($Depth + 1)) }
        return $safe
    }

    return $Value
}
