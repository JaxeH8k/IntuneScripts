<#
.SYNOPSIS
    Functions for resolving a hybrid on-prem AD SID to its Entra ID Object ID, backed by
    a local JSON cache, for use in the central "set Intune primary user" step.

.DESCRIPTION
    Both identifiers are permanent for the life of an account (an AD SID is never reused;
    an Entra Object ID never changes), so once a SID resolves, the mapping is cached
    forever - no TTL/expiry logic needed for hits.

    Misses are deliberately NOT cached: a SID that doesn't resolve today may just be a
    user whose on-prem account hasn't synced to Entra yet (Azure AD Connect sync delay).
    Caching a miss permanently would mean that device never gets retried.

    Assumes a single sequential caller (scheduled task / runbook). If this ever runs as
    multiple parallel workers against the same cache file, replace the flat JSON file with
    something that has real concurrency control (SQLite, Table Storage, SQL, etc.) - a flat
    file is a shared-write hazard under concurrent access.
#>

# Logging layer - every Graph call in this file is recorded through it.
. (Join-Path $PSScriptRoot 'Write-GraphLog.ps1')
# Cache layer - CRUD plus load/save for the SID -> Entra identity map below.
. (Join-Path $PSScriptRoot 'ObjectCache.ps1')
# Shared cool-off gate. When Graph throttles one call, every later call through
# Invoke-GraphRequest waits out the remaining window instead of each earning its own 429.
# Script-scoped, so it lives as long as this file stays dot-sourced.
$script:GraphCoolOffUntil = [datetime]::MinValue
# Graph refuses the primary-user assignment with this when the target account has no Intune
# licence, or has been deleted since the detection run. That is a problem with that one
# user, not with the run, so Set-IntunePrimaryUser records it and moves on rather than
# throwing and taking every device still queued behind it down with it.
$script:UnlicensedUserPattern = 'does not have intune license|is deleted'

function Invoke-JhGraphRequest {
    <#
    .SYNOPSIS
        Invoke-MgGraphRequest wrapper that honours Graph throttling (429), retries transient
        5xx responses, and writes an audit record for every single call it makes.

    .DESCRIPTION
        Graph returns 429 with a Retry-After header (seconds) telling you exactly how long
        to back off. That header is authoritative - respect it rather than guessing. If it
        is missing (or on a 503/504), fall back to exponential backoff: 2, 4, 8, 16...
        seconds, capped at -MaxCoolOffSeconds.

        Uses -SkipHttpErrorCheck so a 429 comes back as a status code rather than a thrown
        exception, which is the only way to read Retry-After off the response.

        Any other non-2xx (400/403/404...) is a real error and throws immediately - retrying
        a bad request just wastes the retry budget.

        LOGGING: every attempt produces a record - Verbose on success, Warning on a
        throttle/retry, Error on a hard failure. Verbose records are NOT dropped; they go to
        the JSONL file and Log Analytics like everything else, they just stay off the console
        unless -Verbose is on. Only Debug records (full request/response bodies) are gated,
        by Initialize-GraphLog -DebugLogging / Set-GraphLogDebug.

        A client-request-id is generated per call and sent on the wire. Graph echoes a
        request-id back; both are logged. Those two ids are what Microsoft support asks for
        when you need them to explain what happened to a specific call.

    .PARAMETER Operation
        Business name for what this call is doing (ResolveSid, SetPrimaryUser...). Becomes
        the Operation column, so the workspace can be queried by intent rather than by URL.

    .PARAMETER LogContext
        Extra context merged into every record for this call - typically
        @{ deviceId = ...; targetUserId = ...; targetSid = ... }.
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        $Body,
        [hashtable]$Headers,
        [string]$ContentType = 'application/json',
        [int]$MaxAttempts = 5,
        [int]$MaxCoolOffSeconds = 300,
        [string]$Operation = 'GraphRequest',
        [hashtable]$LogContext = @{}
    )

    # Wait out any cool-off a previous call already earned.
    $remaining = ($script:GraphCoolOffUntil - (Get-Date)).TotalSeconds
    if ($remaining -gt 0) {
        Write-GraphLog -Level Warning -Operation $Operation -Message ("Cool-off in effect, waiting {0:N0}s before calling Graph" -f $remaining) -Data ($LogContext + @{
            method = $Method; uri = $Uri; waitSeconds = [math]::Ceiling($remaining)
        })
        Start-Sleep -Seconds ([math]::Ceiling($remaining))
    }

    $attempt = 0
    while ($true) {
        $attempt++

        # One id per attempt, so a retried call is distinguishable from the original.
        $clientRequestId = (New-Guid).Guid

        $callHeaders = @{}
        if ($null -ne $Headers) {
            foreach ($key in $Headers.Keys) { $callHeaders[$key] = $Headers[$key] }
        }
        $callHeaders['client-request-id'] = $clientRequestId

        $context = $LogContext + @{
            method          = $Method
            uri             = $Uri
            attempt         = $attempt
            clientRequestId = $clientRequestId
        }

        Write-GraphLog -Level Debug -Operation $Operation -Message "Graph request" -Data ($context + @{
            requestHeaders = ConvertTo-SafeLogValue -Value $callHeaders
            requestBody    = ConvertTo-SafeLogValue -Value $Body
        })

        $params = @{
            Method                  = $Method
            Uri                     = $Uri
            Headers                 = $callHeaders
            SkipHttpErrorCheck      = $true
            StatusCodeVariable      = 'status'
            ResponseHeadersVariable = 'respHeaders'
            ErrorAction             = 'Stop'
        }
        if ($null -ne $Body) { $params.Body = $Body; $params.ContentType = $ContentType }

        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $response = Invoke-MgGraphRequest @params
        }
        catch {
            # A thrown exception here is transport-level (DNS, TLS, no token) - there is no
            # status code to inspect, so log it and let it out.
            $timer.Stop()
            Write-GraphLog -Level Error -Operation $Operation -Message "Graph call failed before a response: $($_.Exception.Message)" -Data ($context + @{
                durationMs = $timer.ElapsedMilliseconds
            })
            throw
        }
        $timer.Stop()

        $context['statusCode'] = $status
        $context['durationMs'] = $timer.ElapsedMilliseconds
        $context['graphRequestId'] = Get-ResponseHeaderValue -Headers $respHeaders -Name 'request-id'

        Write-GraphLog -Level Debug -Operation $Operation -Message "Graph response" -Data ($context + @{
            responseHeaders = ConvertTo-SafeLogValue -Value $respHeaders
            responseBody    = ConvertTo-SafeLogValue -Value $response
        })

        if ($status -ge 200 -and $status -lt 300) {
            Write-GraphLog -Level Verbose -Operation $Operation -Message "$Method succeeded (HTTP $status)" -Data $context
            return $response
        }

        if ($status -ne 429 -and $status -ne 503 -and $status -ne 504) {
            $detail = $response | ConvertTo-Json -Depth 5 -Compress
            Write-GraphLog -Level Error -Operation $Operation -Message "$Method failed with HTTP $status" -Data ($context + @{
                errorBody = ConvertTo-SafeLogValue -Value $detail
            })
            throw "Graph $Method $Uri failed with HTTP $status : $detail"
        }

        # Retry-After if Graph gave one, otherwise exponential backoff.
        $wait = [int](Get-ResponseHeaderValue -Headers $respHeaders -Name 'Retry-After')
        if ($wait -le 0) { $wait = [int][math]::Pow(2, $attempt) }
        if ($wait -gt $MaxCoolOffSeconds) { $wait = $MaxCoolOffSeconds }

        # Record the window before deciding whether to give up, so that even when this call
        # runs out of attempts the next caller still waits rather than walking into a 429.
        $script:GraphCoolOffUntil = (Get-Date).AddSeconds($wait)
        $context['waitSeconds'] = $wait

        if ($attempt -ge $MaxAttempts) {
            Write-GraphLog -Level Error -Operation $Operation -Message "Still throttled (HTTP $status) after $MaxAttempts attempts, giving up" -Data $context
            throw "Graph $Method $Uri still throttled (HTTP $status) after $MaxAttempts attempts"
        }

        Write-GraphLog -Level Warning -Operation $Operation -Message "HTTP $status, cooling off ${wait}s (attempt $attempt of $MaxAttempts)" -Data $context
        Start-Sleep -Seconds $wait
    }
}

function Get-ResponseHeaderValue {
    <#
        Pulls a single header value out of the response-headers dictionary. Header names are
        case-insensitive on the wire and the dictionary type varies by SDK version, so match
        by string comparison rather than indexing. Returns '' when absent. Internal.
    #>
    param($Headers, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Headers) { return '' }

    foreach ($key in $Headers.Keys) {
        if ($key -eq $Name) { return [string](@($Headers[$key])[0]) }
    }
    return ''
}

function Import-EntraIdCache {
    <#
        Loads the SID -> Entra identity cache into an in-memory hashtable, keyed by SID.
        Each value carries id/upn/cachedAt.

        A named wrapper over the generic Import-ObjectCache in ObjectCache.ps1, so this
        script keeps talking about the Entra cache while there is only one implementation
        of the file handling (missing file, empty file, corrupt JSON, atomic writes) to
        get right. Pass -Path to point at a cache other than the default beside the script.
    #>
    param([string]$Path)

    if ($Path) { return Import-ObjectCache -Path $Path }
    return Import-ObjectCache
}

function Resolve-EntraObjectId {
    <#
        Resolves a SID to its Entra Object ID. Checks the in-memory cache first (zero
        Graph calls on a hit); on a miss, does a single filtered Graph lookup and, if
        found, stores the result back into $Cache for this run and future runs (once
        Save-EntraIdCache is called).
    #>
    param(
        [Parameter(Mandatory)][string]$Sid,
        [Parameter(Mandatory)][hashtable]$Cache,
        [switch]$getUpn = $false
    )

    if (Test-CacheEntry -Cache $Cache -Key $Sid) {
      $entry = Get-CacheEntry -Cache $Cache -Key $Sid
      Write-GraphLog -Level Debug -Operation 'ResolveSid' -Message 'Cache hit, no Graph call' -Data @{
        targetSid = $Sid; targetUserId = $entry.id
      }
      if($getUpn){
        return $entry.upn
      }
      return $entry.id
    }

    # Miss - one Graph call for this SID only.
    # $count=true + ConsistencyLevel: eventual are the "advanced query" parameters Graph
    # requires for filtering on several on-premises-synced properties (confirmed pattern
    # for onPremisesSyncEnabled; including them here is a safe superset even if
    # onPremisesSecurityIdentifier's `eq` filter alone turns out not to strictly need it).
    $uri = "https://graph.microsoft.com/v1.0/users" +
           "?`$filter=onPremisesSecurityIdentifier eq '$Sid'" +
           "&`$select=id,userPrincipalName" +
           "&`$count=true"

    $headers = @{ ConsistencyLevel = 'eventual' }
    
    $result = Invoke-JhGraphRequest -Method GET -Uri $uri -Headers $headers `
                  -Operation 'ResolveSid' -LogContext @{ targetSid = $Sid }
    
    if ($result.value.Count -eq 1) {
        # Out-Null: Set-CacheEntry reports whether the key was new, and that boolean would
        # otherwise fall out of this function alongside the id we actually return.
        # cachedAt is stamped by the cache layer, so there is nothing to date by hand.
        Set-CacheEntry -Cache $Cache -Key $Sid -Value @{
            id  = $result.value[0].id
            upn = $result.value[0].userPrincipalName
        } | Out-Null
        $entry = Get-CacheEntry -Cache $Cache -Key $Sid

        Write-GraphLog -Level Information -Operation 'ResolveSid' -Message 'SID resolved to Entra user' -Data @{
            targetSid = $Sid; targetUserId = $entry.id; upn = $entry.upn
        }
        if($getUpn){
          return $entry.upn
        }
        return $entry.id
    }

    # Zero matches is the sync-delay case; more than one means duplicate SIDs in the
    # tenant, which is a data problem someone needs to look at - log them differently.
    Write-GraphLog -Level Warning -Operation 'ResolveSid' -Message "SID did not resolve to exactly one Entra user (matches: $($result.value.Count))" -Data @{
        targetSid = $Sid; matchCount = $result.value.Count
    }

    return $null   # miss - deliberately not cached, retried on next run
}

function Save-EntraIdCache {
    <#
        Writes the cache back to disk (temp file + rename, so a crash mid-write cannot
        leave a truncated cache). Counterpart to Import-EntraIdCache; see
        Save-ObjectCache in ObjectCache.ps1 for the details, including its refusal to
        overwrite a populated cache file with an empty cache.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Cache,
        [string]$Path
    )

    if ($Path) { return Save-ObjectCache -Cache $Cache -Path $Path }
    return Save-ObjectCache -Cache $Cache
}

function Set-IntunePrimaryUser {
    <#
        Sets the Intune primary user on a managed device.

        Primary user is a navigation property, so this is a POST to users/$ref with the
        target user's resource URL - not a PATCH on the managedDevice itself. POST replaces
        whatever the current primary user is, so there's no need to DELETE the existing
        reference first. Success is 204 No Content (no response body).

        This navigation only exists on the beta endpoint - there is no v1.0 equivalent.

        DeviceName/PreviousUserUpn/NewUserUpn are carried for the audit trail only. The ids
        say what changed; these say it in the terms whoever reads the log back thinks in.

        Returns $true when the assignment was made and $false when it was skipped because
        Graph reported the target user as unlicensed or deleted. Every other Graph failure
        still throws.

        Requires scope: DeviceManagementManagedDevices.ReadWrite.All
    #>
    param(
        [Parameter(Mandatory)][string]$DeviceId,        # Intune managedDevice id
        [Parameter(Mandatory)][string]$UserObjectId,    # Entra ID object id (GUID) - a UPN here returns 400
        [string]$DeviceName,
        [string]$PreviousUserUpn,
        [string]$NewUserUpn
    )

    $uri  = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$DeviceId/users/`$ref"
    $body = @{ '@odata.id' = "https://graph.microsoft.com/beta/users/$UserObjectId" } | ConvertTo-Json

    # deviceId/targetUserId are promoted to their own log columns; the three names below ride
    # along in Details, and are attached to every Graph record this call produces, not just
    # the success one - a failed assignment is exactly when you want to know who it was for.
    $logContext = @{
        deviceId        = $DeviceId
        targetUserId    = $UserObjectId
        deviceName      = $DeviceName
        previousUserUpn = $PreviousUserUpn
        newUserUpn      = $NewUserUpn
    }

    try {
        Invoke-JhGraphRequest -Method POST -Uri $uri -Body $body -ContentType 'application/json' `
            -Operation 'SetPrimaryUser' -LogContext $logContext | Out-Null
    }
    catch {
        if ($_.Exception.Message -match $script:UnlicensedUserPattern) {
            Write-GraphLog -Level Warning -Operation 'SetPrimaryUser' -Message 'Skipped - target user has no Intune license or is deleted' -Data ($logContext + @{
                graphError = $_.Exception.Message
            })
            return $false
        }
        throw   # anything else is still a real failure
    }

    # Information level: this is the record of a change actually made in the tenant, which
    # is what an auditor comes looking for. Everything above it is how we got here.
    Write-GraphLog -Level Information -Operation 'SetPrimaryUser' -Message 'Primary user set' -Data $logContext
    return $true
}
