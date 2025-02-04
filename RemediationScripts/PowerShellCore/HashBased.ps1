# Define a function for logging
function Write-Log {
    param (
        [string]$Message,
        [string]$Severity = "Info"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp][$Severity] $Message"
    Write-Host $logMessage
    Add-Content -Path "C:\ProgramData\PowerShellRegistryLog.txt" -Value $logMessage
}

# Function to handle exceptions
function Handle-Exception {
    param (
        [System.Exception]$Exception,
        [string]$Operation
    )
    $errorMessage = "Error during operation: $Operation`nException: $($Exception.Message)`n$($Exception.StackTrace)"
    Write-Log -Message $errorMessage -Severity "Error"
}

# Ensure the log file directory exists
$logDir = "C:\ProgramData"
if (-not (Test-Path -Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

# Define registry settings in a hash table
$registrySettings = @{
    "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore" = @{
        "EnableScripts" = @{ Value = 1; Type = "DWord" }
        "ExecutionPolicy" = @{ Value = "Unrestricted"; Type = "String" }
    }
    "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\ModuleLogging" = @{
        "EnableModuleLogging" = @{ Value = 1; Type = "DWord" }
    }
    "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\ModuleLogging\ModuleNames" = @{
        "*" = @{ Value = "*"; Type = "String" }
    }
    "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\ScriptBlockLogging" = @{
        "EnableScriptBlockLogging" = @{ Value = 1; Type = "DWord" }
    }
    "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\Transcription" = @{
        "EnableTranscripting" = @{ Value = 1; Type = "DWord" }
        "OutputDirectory" = @{ Value = "C:\ProgramData\PS_Transcript"; Type = "String" }
    }
}

# Main script execution within try-catch for global error handling
try {
    foreach ($path in $registrySettings.Keys) {
        try {
            # Ensure the registry path exists
            $segments = $path -split '\\'
            for ($i = 1; $i -lt $segments.Length; $i++) {
                $currentPath = ($segments[0..$i] -join '\')
                if (-not (Test-Path -Path $currentPath)) {
                    Write-Log -Message "Creating registry key: $currentPath"
                    New-Item -Path $currentPath -Force | Out-Null
                }
            }

            # Process properties for the current path
            foreach ($property in $registrySettings[$path].GetEnumerator()) {
                try {
                    $currentValue = Get-ItemProperty -Path $path -Name $property.Name -ErrorAction SilentlyContinue

                    if ($null -eq $currentValue) {
                        # Value does not exist, create it
                        Write-Log -Message "Creating new property $($property.Name) with value $($property.Value.Value) at $path"
                        Set-ItemProperty -Path $path -Name $property.Name -Value $property.Value.Value -Type $property.Value.Type
                    } else {
                        # Value exists, check if it needs updating
                        $currentPropertyValue = $currentValue.($property.Name)
                        if ($currentPropertyValue -ne $property.Value.Value) {
                            Write-Log -Message "Updating property $($property.Name) from $currentPropertyValue to $($property.Value.Value) at $path"
                            Set-ItemProperty -Path $path -Name $property.Name -Value $property.Value.Value -Type $property.Value.Type
                        } else {
                            Write-Log -Message "Property $($property.Name) already matches desired value at $path"
                        }
                    }
                } catch {
                    Handle-Exception -Exception $Error[0].Exception -Operation "Processing property $($property.Name) at $path"
                }
            }
        } catch {
            Handle-Exception -Exception $Error[0].Exception -Operation "Processing path $path"
        }
    }

    Write-Log -Message "Registry modifications completed." -Severity "Success"
} catch {
    Handle-Exception -Exception $Error[0].Exception -Operation "Script execution"
}