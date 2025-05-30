# Define registry settings in a hash table
$registrySettings = @{
    "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore" = @{
        "EnableScripts" = @{ Value = 1; Type = "DWord" }
        "ExecutionPolicy" = @{ Value = "Unrestricted"; Type = "String" }
    }
    "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\ModuleLogging" = @{
        "EnableModuleLogging" = @{ Value = 0; Type = "DWord" }
    }
    "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\ModuleLogging\ModuleNames" = @{
        "*" = @{ Value = "*"; Type = "String" }
    }
    "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\ScriptBlockLogging" = @{
        "EnableScriptBlockLogging" = @{ Value = 1; Type = "DWord" }
    }
    "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\Transcription" = @{
        "EnableTranscripting" = @{ Value = 0; Type = "DWord" }
        "OutputDirectory" = @{ Value = "C:\ProgramData\PS_Transcript"; Type = "String" }
    }
}

# test key/value pairs
foreach($path in $registrySettings.Keys){
    # read keys, if any are not present, exit 1 to trigger remediation
    # Ensure the registry path exists
    $segments = $path -split '\\'
    for ($i = 4; $i -lt $segments.Length; $i++) {
        $currentPath = ($segments[0..$i] -join '\')
        if (-not (Test-Path -Path $currentPath)) {
            Exit 1 # Trigger remediation from Intune.
        }
    }

    # filter through properties of keys, if mismatch, exit 1 to trigger remediation
    # Process properties for the current path
    foreach ($property in $registrySettings[$path].GetEnumerator()) {
            $currentValue = Get-ItemProperty -Path $path -Name $property.Name -ErrorAction SilentlyContinue

            if ($null -eq $currentValue) {
                # Value does not exist
                Exit 1
            } else {
                # Value exists, check if it needs updating
                $currentPropertyValue = $currentValue.($property.Name)
                if ($currentPropertyValue -ne $property.Value.Value) {
                   # Value Mismatch
                   Exit 1
                } 
            }
    }
}
# We've made it through the list with no exit.  Exit 0 as a success; no remediation required.
Exit 0