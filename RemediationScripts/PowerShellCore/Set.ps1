# Ensure the paths exist before setting properties
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft" -Name "PowerShellCore" -Force | Out-Null
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore" -Name "ModuleLogging" -Force | Out-Null
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\ModuleLogging" -Name "ModuleNames" -Force | Out-Null
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore" -Name "ScriptBlockLogging" -Force | Out-Null
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore" -Name "Transcription" -Force | Out-Null

# Set the registry values
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore" -Name "EnableScripts" -Value 1 -Type DWord
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore" -Name "ExecutionPolicy" -Value "Unrestricted" -Type String

Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\ModuleLogging" -Name "EnableModuleLogging" -Value 1 -Type DWord
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\ModuleLogging\ModuleNames" -Name "*" -Value "*" -Type String

Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\ScriptBlockLogging" -Name "EnableScriptBlockLogging" -Value 1 -Type DWord

Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\Transcription" -Name "EnableTranscripting" -Value 1 -Type DWord
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore\Transcription" -Name "OutputDirectory" -Value "C:\ProgramData\PS_Transcript" -Type String