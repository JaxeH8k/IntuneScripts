$env:TENANT_NAME = "yourtenant.onmicrosoft.com"
$env:CLIENT_ID   = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

IntuneCD-startbackup.exe -i -m 1 -p C:\temp\bkup -o json `
  --scopes `
    "DeviceManagementApps.Read.All" `
    "DeviceManagementConfiguration.Read.All" `
    "DeviceManagementScripts.Read.All" `
    "DeviceManagementServiceConfig.Read.All" `
    "DeviceManagementManagedDevices.Read.All" `
    "DeviceManagementRBAC.Read.All" `
    "Group.Read.All" `
    "Policy.Read.All" `
    "Policy.Read.ConditionalAccess" `
    "Application.Read.All"