#Requires -Version 5.1
<#
.SYNOPSIS
    A small key/value object cache backed by a single JSON file: CRUD against an in-memory
    hashtable, plus load/save of that hashtable to disk.

.DESCRIPTION
    The cache is a plain hashtable, keyed by string, whose values are plain hashtables (or
    scalars). Nothing clever, and deliberately so - a hashtable is passed by reference, so
    every function here mutates the caller's cache in place and the calling script keeps
    holding the same object it started with:

        $cache = Import-ObjectCache
        Set-CacheEntry -Cache $cache -Key $sid -Value @{ id = $id; upn = $upn }
        Save-ObjectCache -Cache $cache

    WINDOWS POWERSHELL 5.1: this file is 5.1-clean and carries no PowerShell 7 syntax. The
    places 5.1 actually bites are handled here rather than at the call sites:

      * ConvertFrom-Json has no -AsHashtable in 5.1, so it hands back PSCustomObject. Those
        are converted to hashtables on load (see ConvertTo-CacheValue) so that an entry read
        from disk and an entry added this run are the same type and can both be updated.
        Reading either way is identical - $entry.id works on a hashtable too.
      * Set-Content -Encoding UTF8 writes a BOM in 5.1. The save path uses .NET's
        UTF8Encoding($false) instead, so the file stays BOM-less and anything else that
        picks it up (jq, Python, a 7.x run of this same script) reads it cleanly. The load
        path reads through a StreamReader constructed on UTF8, because Get-Content on 5.1
        falls back to the ANSI code page when there is no BOM to sniff. 5.1 escapes
        non-ASCII to \uXXXX on the way out, 7.x does not, so this is what keeps a file
        written by one readable by the other.
      * PowerShell function calls are expensive - roughly 50 us each once parameter binding
        is counted. At one call per field, normalising 50,000 cached entries costs seconds
        on its own, dwarfing the actual parse. Both loaders therefore handle the flat case
        inline and only call out to ConvertTo-CacheValue for the nested values that
        genuinely need the recursion.

    FILE FORMAT: two of them, chosen automatically on save and detected on load, because
    JSON stops being cheap somewhere in the low tens of thousands of entries. Measured on
    PowerShell 7.6, 50,000 three-field entries, loading into a usable hashtable:

        table   190 ms load,  113 ms save,  7.1 MB   <- default when the data allows it
        json  2,351 ms load,  164 ms save,  9.0 MB
        csv     247 ms load,  628 ms save,  6.7 MB   (Import-Csv into a hashtable)
        clixml  620 ms load,  748 ms save, 28.4 MB   (Export-Clixml, for the record)

    CLIXML is the obvious "just use a serialised format" answer and it is not one: it is
    slower than the table format both ways and its file is four times the size, because it
    is XML carrying a type annotation for every string.

    Those numbers are 7.x. Windows PowerShell 5.1 uses a different (slower) JSON parser, so
    the json row gets worse there while the table row barely moves - it is a StreamReader,
    a String.Split and a hashtable assignment, with no object materialisation to be slow at.

      * table - one line per entry, tab-separated, self-describing:

            #objectcache 1 table
            S-1-5-21-...-1234<TAB>id=9f2c...<TAB>upn=a@x.net<TAB>cachedAt=2026-...

        Values are strings, and only strings - that is what makes the loader a Split and
        an assignment with no object materialisation anywhere. Tab, newline and backslash
        inside a value are escaped (\t, \n, \r, \\); nothing else is touched.

      * json - everything else. An entry with a nested object, an array, a number, a
        boolean or a $null in it cannot round-trip through the table format without
        quietly changing type, so those caches are written as JSON instead.

    -Format Auto (the default) writes a table when every entry is flat and string-valued
    and JSON when it is not, so you get the fast path without having to think about it and
    correct data when you would not. Load auto-detects, so a file written either way - or
    by an older version of this script - reads back the same.

    CONCURRENCY: none. One flat file, last writer wins, meant for a single sequential caller
    (scheduled task / runbook). Parallel workers sharing one cache file will lose writes -
    that case wants SQLite/Table Storage, not this.

    KEYS: always strings. Non-string keys are cast, because JSON object names are strings and
    a key that only survives as its ToString() would not round-trip. Keys are matched
    case-insensitively in memory (default hashtable behaviour), so a cache file containing
    two keys differing only in case cannot be loaded - ConvertFrom-Json rejects it first.

.NOTES
    Values must be JSON-friendly: strings, numbers, booleans, dates, arrays, and nested
    hashtables/PSCustomObjects. A live object (a Graph response object, a FileInfo) will
    serialise to something you did not intend - store the fields you care about.
#>

# Same structured log as the rest of the run, so cache activity lands in the same JSONL
# file and the same Log Analytics table as the Graph calls. Dot-sourcing twice is harmless.
. (Join-Path $PSScriptRoot 'Write-GraphLog.ps1')

# Beside the script, not beside the working directory. A scheduled task's cwd is
# C:\Windows\System32 as often as not, and a cache that silently starts empty because it
# was looked for in the wrong place is a full re-resolve against Graph, not an error anyone
# gets told about.
$script:ObjectCacheDefaultPath = Join-Path $PSScriptRoot 'cache.dat'

# Plain text either way, despite the extension - .dat only because the file may hold
# either format and calling a tab-separated file cache.json would be a lie. Load sniffs
# the content, not the name, so an existing cache.json still opens fine.

# Characters that have to be escaped inside a table field. IndexOfAny against this is the
# check on the write path; a value containing none of them (which is nearly all of them:
# SIDs, GUIDs, UPNs, timestamps) is written through untouched.
$script:CacheEscapeChars     = [char[]]@('\', "`t", "`r", "`n")
$script:CacheNameEscapeChars = [char[]]@('\', "`t", "`r", "`n", '=')
$script:CacheTableHeader  = '#objectcache 1 table'

function ConvertTo-CacheValue {
    <#
        Normalises a value into hashtables-all-the-way-down. PSCustomObject (what
        ConvertFrom-Json returns on 5.1) becomes a hashtable; dictionaries are rebuilt with
        string keys; arrays are mapped element-wise; everything else is returned as-is.

        Depth is bounded because a cyclic object graph would otherwise recurse forever -
        past the limit the value is stored as-is and ConvertTo-Json's own depth handling
        deals with it. Internal.
    #>
    param($Value, [int]$Depth = 0)

    if ($null -eq $Value)  { return $null }
    if ($Depth -ge 20)     { return $Value }

    if ($Value -is [System.Collections.IDictionary]) {
        $copy = @{}
        # @($Value.Keys) snapshots the keys - enumerating a dictionary while writing to it
        # throws, and the caller may well have handed us the object we are about to edit.
        foreach ($key in @($Value.Keys)) {
            $copy[[string]$key] = ConvertTo-CacheValue -Value $Value[$key] -Depth ($Depth + 1)
        }
        return $copy
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $copy = @{}
        foreach ($prop in $Value.PSObject.Properties) {
            $copy[[string]$prop.Name] = ConvertTo-CacheValue -Value $prop.Value -Depth ($Depth + 1)
        }
        return $copy
    }

    # A string is IEnumerable, so test it before the array case or every string comes back
    # as an array of characters.
    if ($Value -is [string]) { return $Value }

    if ($Value -is [array]) {
        $copy = @()
        foreach ($item in $Value) { $copy += ,(ConvertTo-CacheValue -Value $item -Depth ($Depth + 1)) }
        return ,$copy   # leading comma: without it a one-element array unrolls to a scalar
    }

    return $Value
}

function New-ObjectCache {
    <#
        A new empty cache. Optionally seeded from an existing hashtable, whose values are
        normalised on the way in.
    #>
    param([hashtable]$Seed)

    $cache = @{}
    if ($null -ne $Seed) {
        foreach ($key in @($Seed.Keys)) {
            $cache[[string]$key] = ConvertTo-CacheValue -Value $Seed[$key]
        }
    }
    return $cache
}

function Test-CacheEntry {
    <#
        Whether a key is present. Present-but-$null still counts as present - that is the
        difference between "we looked this up and it was nothing" and "we never looked".
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Cache,
        [Parameter(Mandatory)][string]$Key
    )
    return $Cache.ContainsKey($Key)
}

function Get-CacheEntry {
    <#
        READ. Returns the entry, or -Default (which is $null unless you say otherwise) on a
        miss. The entry is returned by reference, not copied: editing what comes back edits
        what is in the cache. That is usually what you want; -Clone when it is not.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Cache,
        [Parameter(Mandatory)][string]$Key,
        $Default = $null,
        [switch]$Clone
    )

    if (-not $Cache.ContainsKey($Key)) {
        Write-GraphLog -Level Debug -Operation 'Cache' -Message 'Cache miss' -Data @{ cacheKey = $Key }
        return $Default
    }

    $value = $Cache[$Key]
    if ($Clone) { $value = ConvertTo-CacheValue -Value $value }

    Write-GraphLog -Level Debug -Operation 'Cache' -Message 'Cache hit' -Data @{ cacheKey = $Key }

    # An array would unroll on the way out and a single-element one would arrive as a
    # scalar, so hand arrays back wrapped.
    if ($value -is [array]) { return ,$value }
    return $value
}

function Add-CacheEntry {
    <#
        CREATE. Adds an entry only if the key is new; an existing key is left alone and
        $false comes back, unless -Force. Use this where a collision means something went
        wrong and you want to hear about it - Set-CacheEntry is the one that just writes.

        Returns $true when the entry was written.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Cache,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)]$Value,
        [switch]$Force,
        [switch]$NoTimestamp
    )

    if ($Cache.ContainsKey($Key) -and -not $Force) {
        Write-GraphLog -Level Warning -Operation 'Cache' -Message 'Entry already cached, not overwritten (use -Force)' -Data @{ cacheKey = $Key }
        return $false
    }

    $Cache[$Key] = Add-CacheTimestamp -Value (ConvertTo-CacheValue -Value $Value) -NoTimestamp:$NoTimestamp
    Write-GraphLog -Level Debug -Operation 'Cache' -Message 'Entry added' -Data @{ cacheKey = $Key }
    return $true
}

function Set-CacheEntry {
    <#
        UPDATE (upsert). Writes the entry whether or not the key exists.

        -Merge keeps the fields already on the existing entry and overlays the new ones,
        rather than replacing it wholesale - for topping up an entry with a field a later
        run learned about. Merge is shallow and only applies when both sides are
        hashtables; anything else replaces.

        Returns $true if the key was new, $false if an existing entry was updated.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Cache,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)]$Value,
        [switch]$Merge,
        [switch]$NoTimestamp
    )

    $isNew    = -not $Cache.ContainsKey($Key)
    $incoming = ConvertTo-CacheValue -Value $Value

    if ($Merge -and -not $isNew) {
        $existing = $Cache[$Key]
        if ($existing -is [hashtable] -and $incoming -is [hashtable]) {
            $merged = @{}
            foreach ($field in @($existing.Keys)) { $merged[$field] = $existing[$field] }
            foreach ($field in @($incoming.Keys)) { $merged[$field] = $incoming[$field] }
            $incoming = $merged
        }
    }

    # cachedAt is refreshed on every write, so it reads as "when this was last written",
    # not "when the key first appeared".
    $Cache[$Key] = Add-CacheTimestamp -Value $incoming -NoTimestamp:$NoTimestamp -Refresh

    if ($isNew) { $message = 'Entry added' } else { $message = 'Entry updated' }
    Write-GraphLog -Level Debug -Operation 'Cache' -Message $message -Data @{ cacheKey = $Key }
    return $isNew
}

function Remove-CacheEntry {
    <#
        DELETE. Returns $true if there was something to remove. Removing an absent key is
        not an error - it is the state you were asking for.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Cache,
        [Parameter(Mandatory)][string]$Key
    )

    if (-not $Cache.ContainsKey($Key)) { return $false }

    $Cache.Remove($Key)
    Write-GraphLog -Level Debug -Operation 'Cache' -Message 'Entry removed' -Data @{ cacheKey = $Key }
    return $true
}

function Clear-ObjectCache {
    <#
        Empties the cache in place, keeping the caller's reference valid. Nothing touches
        disk until Save-ObjectCache - and Save refuses to write an empty cache over a
        populated file without -Force, so clearing by accident does not destroy the file.
    #>
    param([Parameter(Mandatory)][hashtable]$Cache)

    $count = $Cache.Count
    $Cache.Clear()
    Write-GraphLog -Level Information -Operation 'Cache' -Message "Cache cleared in memory ($count entrie(s) dropped)" -Data @{ entryCount = $count }
}

function Add-CacheTimestamp {
    <#
        Stamps cachedAt (UTC, round-trip format, matching the log records) onto hashtable
        entries so the file says when each entry was written. Scalars are returned
        untouched - there is nowhere to put it. Internal.
    #>
    param($Value, [switch]$NoTimestamp, [switch]$Refresh)

    if ($NoTimestamp) { return $Value }
    if ($Value -isnot [hashtable]) { return $Value }
    if ($Value.ContainsKey('cachedAt') -and -not $Refresh) { return $Value }

    $Value['cachedAt'] = (Get-Date).ToUniversalTime().ToString('o')
    return $Value
}

function Resolve-CachePath {
    <#
        Turns whatever the caller passed into a full filesystem path.

        Necessary because .NET's idea of the current directory is not PowerShell's - a
        relative path handed straight to [System.IO.File] lands wherever the process
        started, which for a scheduled task is not where the script lives. Internal.
    #>
    param([Parameter(Mandatory)][string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function ConvertTo-CacheField {
    <#
        Escapes one name or value for the table format. The IndexOfAny check is the whole
        point: a SID, GUID, UPN or timestamp contains none of these characters, so the
        common case is a comparison and a return rather than four string allocations.
        Internal.
    #>
    param([string]$Text)

    if ($Text.IndexOfAny($script:CacheEscapeChars) -lt 0) { return $Text }
    return $Text.Replace('\', '\\').Replace("`t", '\t').Replace("`r", '\r').Replace("`n", '\n')
}

function ConvertTo-CacheName {
    <#
        Escapes a field name. Same as ConvertTo-CacheField plus '=', which separates a name
        from its value and so cannot appear raw in a name. Values need no such treatment -
        they are whatever follows the first unescaped '=', '=' signs included. Internal.
    #>
    param([string]$Text)

    if ($Text.IndexOfAny($script:CacheNameEscapeChars) -lt 0) { return $Text }
    return (ConvertTo-CacheField -Text $Text).Replace('=', '\=')
}

function ConvertFrom-CacheField {
    <#
        Reverses ConvertTo-CacheField. Single pass rather than four chained .Replace calls,
        because chained replaces get \\t wrong - they would turn an escaped backslash
        followed by a literal t into a tab. Only called for fields that contain a
        backslash. Internal.
    #>
    param([string]$Text)

    $out = New-Object System.Text.StringBuilder $Text.Length
    $i = 0
    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if ($ch -eq '\' -and $i -lt ($Text.Length - 1)) {
            $i++
            switch ($Text[$i]) {
                't'     { [void]$out.Append("`t") }
                '='     { [void]$out.Append('=') }
                'r'     { [void]$out.Append("`r") }
                'n'     { [void]$out.Append("`n") }
                '\'     { [void]$out.Append('\') }
                default { [void]$out.Append('\'); [void]$out.Append($Text[$i]) }   # not an escape we wrote, leave it
            }
        }
        else {
            [void]$out.Append($ch)
        }
        $i++
    }
    return $out.ToString()
}

function ConvertTo-CacheTable {
    <#
        Renders the cache as the tab-separated table format, or returns $null if the data
        cannot survive the trip - a nested object, an array, a number, a boolean or a $null
        anywhere means the table format would silently change its type on the way back in,
        and JSON should be used instead.

        The check and the render are the same pass: bail the moment something unsuitable
        turns up rather than walking every entry twice. -Coerce turns the bail into a
        [string] cast, for callers who asked for the table format explicitly and have
        accepted what that means. Internal.
    #>
    param([Parameter(Mandatory)][hashtable]$Cache, [switch]$Coerce)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($script:CacheTableHeader).Append("`r`n")

    # Hoisted out of the loop, and the IndexOfAny tests are inline rather than a call to
    # ConvertTo-CacheField per field: at four fields an entry, a 50,000-entry cache is
    # 200,000 PowerShell function calls, which costs seconds all on its own. IndexOfAny is
    # a method call on a string, which does not. The escape helpers are still there for the
    # rare field that actually needs one.
    $escapeChars     = $script:CacheEscapeChars
    $nameEscapeChars = $script:CacheNameEscapeChars

    foreach ($pair in $Cache.GetEnumerator()) {
        $key = [string]$pair.Key
        if ($key.IndexOfAny($escapeChars) -ge 0) { $key = ConvertTo-CacheField -Text $key }
        [void]$sb.Append($key)

        $entry = $pair.Value

        if ($entry -is [hashtable]) {
            foreach ($field in $entry.GetEnumerator()) {
                $name = [string]$field.Key

                # An empty field name is the marker for a bare scalar entry; a record
                # carrying one could not be told apart from one on the way back in.
                if ($name.Length -eq 0) { return $null }

                $value = $field.Value
                if ($value -isnot [string]) {
                    if (-not $Coerce) { return $null }
                    if ($null -eq $value) { $value = '' } else { $value = [string]$value }
                }

                if ($name.IndexOfAny($nameEscapeChars) -ge 0) { $name = ConvertTo-CacheName -Text $name }
                if ($value.IndexOfAny($escapeChars) -ge 0)    { $value = ConvertTo-CacheField -Text $value }

                [void]$sb.Append("`t").Append($name).Append('=').Append($value)
            }
        }
        elseif ($entry -is [string]) {
            # A scalar entry: one field with no name. Nothing else can produce an empty
            # field name, so this round-trips unambiguously.
            if ($entry.IndexOfAny($escapeChars) -ge 0) { $entry = ConvertTo-CacheField -Text $entry }
            [void]$sb.Append("`t=").Append($entry)
        }
        else {
            if (-not $Coerce) { return $null }
            if ($null -eq $entry) { $entry = '' } else { $entry = [string]$entry }
            if ($entry.IndexOfAny($escapeChars) -ge 0) { $entry = ConvertTo-CacheField -Text $entry }
            [void]$sb.Append("`t=").Append($entry)
        }

        [void]$sb.Append("`r`n")
    }

    return $sb.ToString()
}

function Import-ObjectCache {
    <#
        LOAD. Reads the cache file into a hashtable keyed by string.

        The format is detected from the content, not the file name: a first line of
        "#objectcache 1 table" is read line by line, anything else is parsed as JSON. Either
        way you get back the same shape - string keys, hashtable or scalar values.

        Returns an empty cache rather than throwing when the file is missing (first run),
        empty, or unreadable. A cache is an optimisation: losing it costs Graph calls, and
        failing the whole run over it would cost the run. A corrupt file is renamed aside as
        <name>.corrupt-<timestamp> before the empty cache is returned - the run keeps going,
        the bad file is still there to look at, and the next save writes a clean one. Every
        one of those cases is logged at Warning.
    #>
    param([string]$Path = $script:ObjectCacheDefaultPath)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-GraphLog -Level Information -Operation 'Cache' -Message 'No cache file yet, starting empty' -Data @{ cachePath = $Path }
        return @{}
    }

    $fullPath = Resolve-CachePath -Path $Path
    $cache    = @{}
    $skipped  = 0
    $isTable  = $false
    $jsonText = $null

    try {
        # UTF8 + detectEncodingFromByteOrderMarks: correct for a BOM-less file (which is
        # what this script writes) and for one with a BOM (which 5.1's Set-Content would
        # have written), on both 5.1 and 7.x. Get-Content's default would guess ANSI.
        $reader = New-Object System.IO.StreamReader($fullPath, [System.Text.Encoding]::UTF8, $true)
    }
    catch {
        Write-GraphLog -Level Warning -Operation 'Cache' -Message "Cache file could not be opened, starting empty: $($_.Exception.Message)" -Data @{ cachePath = $fullPath }
        return @{}
    }

    try {
        $first = $reader.ReadLine()

        # A zero-byte file is what a machine that lost power mid-write leaves behind, and
        # 5.1's ConvertFrom-Json throws on an empty string rather than returning nothing.
        if ($null -eq $first -or [string]::IsNullOrWhiteSpace($first)) {
            $rest = $reader.ReadToEnd()
            if ([string]::IsNullOrWhiteSpace($rest)) {
                Write-GraphLog -Level Warning -Operation 'Cache' -Message 'Cache file is empty, starting empty' -Data @{ cachePath = $fullPath }
                return @{}
            }
            $jsonText = $rest
        }
        elseif ($first.StartsWith('#objectcache')) {
            $isTable = $true

            while ($null -ne ($line = $reader.ReadLine())) {
                if ($line.Length -eq 0) { continue }

                # One Split and a walk over the fields - no objects are created per row,
                # which is the entire reason this format exists.
                $parts     = $line.Split([char]9)
                $hasEscape = $line.IndexOf('\') -ge 0

                $entryKey = $parts[0]
                if ($hasEscape) { $entryKey = ConvertFrom-CacheField -Text $entryKey }

                if ($parts.Length -eq 2 -and $parts[1].Length -gt 0 -and $parts[1][0] -eq '=') {
                    # Empty field name = the entry is a bare scalar, not a record.
                    $scalar = $parts[1].Substring(1)
                    if ($hasEscape) { $scalar = ConvertFrom-CacheField -Text $scalar }
                    $cache[$entryKey] = $scalar
                    continue
                }

                $entry = @{}
                for ($i = 1; $i -lt $parts.Length; $i++) {
                    $part = $parts[$i]

                    if ($hasEscape) {
                        # A name is allowed to contain an escaped '=', so the separator is
                        # the first one with an even number of backslashes in front of it.
                        # Only lines that actually contain a backslash pay for this scan.
                        $eq = -1
                        $backslashes = 0
                        for ($c = 0; $c -lt $part.Length; $c++) {
                            $ch = $part[$c]
                            if ($ch -eq '\') { $backslashes++; continue }
                            if ($ch -eq '=' -and ($backslashes % 2) -eq 0) { $eq = $c; break }
                            $backslashes = 0
                        }
                    }
                    else {
                        $eq = $part.IndexOf('=')
                    }

                    if ($eq -lt 1) { $skipped++; continue }   # no separator at all, or an empty name where a record was expected

                    $name  = $part.Substring(0, $eq)
                    $value = $part.Substring($eq + 1)
                    if ($hasEscape) {
                        $name  = ConvertFrom-CacheField -Text $name
                        $value = ConvertFrom-CacheField -Text $value
                    }
                    $entry[$name] = $value
                }
                $cache[$entryKey] = $entry
            }
        }
        else {
            $jsonText = $first + "`n" + $reader.ReadToEnd()
        }
    }
    catch {
        Write-GraphLog -Level Warning -Operation 'Cache' -Message "Cache file could not be read, starting empty: $($_.Exception.Message)" -Data @{ cachePath = $fullPath }
        return @{}
    }
    finally {
        $reader.Dispose()
    }

    if (-not $isTable) {
        try {
            $parsed = $jsonText | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Move-CorruptCacheFile -Path $fullPath -Reason $_.Exception.Message
            return @{}
        }

        # A JSON array or bare scalar is a valid document but not a cache.
        if ($parsed -isnot [System.Management.Automation.PSCustomObject]) {
            Move-CorruptCacheFile -Path $fullPath -Reason 'top-level JSON value is not an object'
            return @{}
        }

        foreach ($prop in $parsed.PSObject.Properties) {
            $value = $prop.Value

            # Flat records inline, which is nearly all of them. Only a value that is itself
            # an object or an array is worth a function call, because at ~50 us a call the
            # recursion costs more than the parse on a cache of any size.
            if ($value -is [System.Management.Automation.PSCustomObject]) {
                $entry = @{}
                foreach ($field in $value.PSObject.Properties) {
                    $fieldValue = $field.Value
                    if ($fieldValue -is [System.Management.Automation.PSCustomObject] -or
                        ($fieldValue -isnot [string] -and $fieldValue -is [System.Collections.IEnumerable])) {
                        $entry[$field.Name] = ConvertTo-CacheValue -Value $fieldValue
                    }
                    else {
                        $entry[$field.Name] = $fieldValue
                    }
                }
                $cache[$prop.Name] = $entry
            }
            elseif ($value -isnot [string] -and $value -is [System.Collections.IEnumerable]) {
                $cache[$prop.Name] = ConvertTo-CacheValue -Value $value
            }
            else {
                $cache[$prop.Name] = $value
            }
        }
    }

    if ($skipped -gt 0) {
        Write-GraphLog -Level Warning -Operation 'Cache' -Message "Cache loaded with $skipped unparseable field(s) skipped" -Data @{
            cachePath = $fullPath; skippedFields = $skipped
        }
    }

    if ($isTable) { $format = 'table' } else { $format = 'json' }
    Write-GraphLog -Level Information -Operation 'Cache' -Message "Cache loaded - $($cache.Count) entrie(s) ($format)" -Data @{
        cachePath = $fullPath; entryCount = $cache.Count; cacheFormat = $format
    }
    return $cache
}

function Move-CorruptCacheFile {
    <#
        Renames an unusable cache file out of the way so the run can continue with an empty
        one. If even the rename fails, say so and carry on - the next save overwrites it
        anyway. Internal.
    #>
    param([Parameter(Mandatory)][string]$Path, [string]$Reason)

    $corruptPath = "$Path.corrupt-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    try {
        Move-Item -LiteralPath $Path -Destination $corruptPath -Force -ErrorAction Stop
        Write-GraphLog -Level Warning -Operation 'Cache' -Message "Cache file unreadable ($Reason) - moved aside, starting empty" -Data @{
            cachePath = $Path; corruptPath = $corruptPath
        }
    }
    catch {
        Write-GraphLog -Level Warning -Operation 'Cache' -Message "Cache file unreadable ($Reason) and could not be moved aside: $($_.Exception.Message)" -Data @{ cachePath = $Path }
    }
}

function Save-ObjectCache {
    <#
        SAVE. Serialises the cache and writes it to disk.

        -Format Auto (default) writes the fast tab-separated table when every entry is flat
        and string-valued, and JSON when one is not - see the FORMAT notes at the top of
        this file. Table forces the table format and casts non-string values to string,
        which is lossy and logged; Json forces JSON.

        Written to a temp file in the same directory and renamed over the original, so a
        crash mid-write leaves the previous good cache intact rather than a half-written
        one. Same-directory matters: the rename is only cheap and all-or-nothing while both
        paths are on the same volume.

        Refuses to write an empty cache over a file that has entries in it, unless -Force.
        An empty cache at save time usually means the load failed or something threw before
        the work happened, and overwriting a good cache with nothing in that situation turns
        one bad run into a full re-resolve on the next one.

        Returns $true when the file was written.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Cache,
        [string]$Path = $script:ObjectCacheDefaultPath,
        [ValidateSet('Auto','Table','Json')]
        [string]$Format = 'Auto',
        [int]$Depth = 10,
        [switch]$Compress,
        [switch]$Force
    )

    $fullPath = Resolve-CachePath -Path $Path

    if ($Cache.Count -eq 0 -and -not $Force -and (Test-Path -LiteralPath $fullPath)) {
        Write-GraphLog -Level Warning -Operation 'Cache' -Message 'Refusing to overwrite existing cache file with an empty cache (use -Force)' -Data @{ cachePath = $fullPath }
        return $false
    }

    $parent = Split-Path -Path $fullPath -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    $text        = $null
    $usedFormat  = 'json'

    if ($Format -eq 'Table') {
        $text = ConvertTo-CacheTable -Cache $Cache -Coerce
        $usedFormat = 'table'
        Write-GraphLog -Level Debug -Operation 'Cache' -Message 'Table format forced - non-string values are written as strings' -Data @{ cachePath = $fullPath }
    }
    elseif ($Format -eq 'Auto') {
        $text = ConvertTo-CacheTable -Cache $Cache      # $null when the data will not fit the format
        if ($null -ne $text) { $usedFormat = 'table' }
    }

    if ($null -eq $text) {
        $text = $Cache | ConvertTo-Json -Depth $Depth -Compress:$Compress

        # ConvertTo-Json returns nothing at all for an empty hashtable on some 5.1 builds;
        # an empty cache is still a legitimate thing to write, and it must be valid JSON.
        if ([string]::IsNullOrWhiteSpace($text)) { $text = '{}' }
    }

    $tempPath = "$fullPath.tmp"
    try {
        # UTF8Encoding($false) = no BOM. Set-Content -Encoding UTF8 on 5.1 would add one.
        [System.IO.File]::WriteAllText($tempPath, $text, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tempPath -Destination $fullPath -Force -ErrorAction Stop
    }
    catch {
        Write-GraphLog -Level Error -Operation 'Cache' -Message "Cache could not be saved: $($_.Exception.Message)" -Data @{ cachePath = $fullPath }
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
        throw
    }

    Write-GraphLog -Level Information -Operation 'Cache' -Message "Cache saved - $($Cache.Count) entrie(s) ($usedFormat)" -Data @{
        cachePath = $fullPath; entryCount = $Cache.Count; cacheFormat = $usedFormat
    }
    return $true
}
