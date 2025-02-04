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

# Main script execution within try-catch for global error handling
try {
    # Ensure the paths exist before setting properties
    try {
        Write-Log -Message "Creating registry key: HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore"
        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft" -Name "PowerShellCore" -Force | Out-Null
    } catch {
        Handle-Exception -Exception $Error[0].Exception -Operation "Creating PowerShellCore registry key"
    }

    try {
        Write-Log -Message "Creating registry key: HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\ModuleLogging"
        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore" -Name "ModuleLogging" -Force | Out-Null
    } catch {
        Handle-Exception -Exception $Error[0].Exception -Operation "Creating ModuleLogging registry key"
    }

    try {
        Write-Log -Message "Creating registry key: HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\ModuleLogging\ModuleNames"
        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\ModuleLogging" -Name "ModuleNames" -Force | Out-Null
    } catch {
        Handle-Exception -Exception $Error[0].Exception -Operation "Creating ModuleNames registry key"
    }

    try {
        Write-Log -Message "Creating registry key: HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\ScriptBlockLogging"
        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore" -Name "ScriptBlockLogging" -Force | Out-Null
    } catch {
        Handle-Exception -Exception $Error[0].Exception -Operation "Creating ScriptBlockLogging registry key"
    }

    try {
        Write-Log -Message "Creating registry key: HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\Transcription"
        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore" -Name "Transcription" -Force | Out-Null
    } catch {
        Handle-Exception -Exception $Error[0].Exception -Operation "Creating Transcription registry key"
    }

    # Set the registry values
    try {
        Write-Log -Message "Setting EnableScripts to 1"
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore" -Name "EnableScripts" -Value 1 -Type DWord
    } catch {
        Handle-Exception -Exception $Error[0].Exception -Operation "Setting EnableScripts"
    }

    try {
        Write-Log -Message "Setting ExecutionPolicy to Unrestricted"
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore" -Name "ExecutionPolicy" -Value "Unrestricted" -Type String
    } catch {
        Handle-Exception -Exception $Error[0].Exception -Operation "Setting ExecutionPolicy"
    }

    try {
        Write-Log -Message "Setting EnableModuleLogging to 1"
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\ModuleLogging" -Name "EnableModuleLogging" -Value 1 -Type DWord
    } catch {
        Handle-Exception -Exception $Error[0].Exception -Operation "Setting EnableModuleLogging"
    }

    try {
        Write-Log -Message "Setting ModuleNames to *"
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\ModuleLogging\ModuleNames" -Name "*" -Value "*" -Type String
    } catch {
        Handle-Exception -Exception $Error[0].Exception -Operation "Setting ModuleNames"
    }

    try {
        Write-Log -Message "Setting EnableScriptBlockLogging to 1"
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\ScriptBlockLogging" -Name "EnableScriptBlockLogging" -Value 1 -Type DWord
    } catch {
        Handle-Exception -Exception $Error[0].Exception -Operation "Setting EnableScriptBlockLogging"
    }

    try {
        Write-Log -Message "Setting EnableTranscripting to 1"
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\Transcription" -Name "EnableTranscripting" -Value 1 -Type DWord
    } catch {
        Handle-Exception -Exception $Error[0].Exception -Operation "Setting EnableTranscripting"
    }

    try {
        Write-Log -Message "Setting OutputDirectory to C:\ProgramData\PS_Transcript"
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\Transcription" -Name "OutputDirectory" -Value "C:\ProgramData\PS_Transcript" -Type String
    } catch {
        Handle-Exception -Exception $Error[0].Exception -Operation "Setting OutputDirectory"
    }

    Write-Log -Message "Registry modifications completed." -Severity "Success"
} catch {
    Handle-Exception -Exception $Error[0].Exception -Operation "Script execution"
    Exit 1
}
Write-Log -Message "PowerShellCore ADMX Registry Settings Application Complete"
Exit 0