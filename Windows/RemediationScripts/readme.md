# PowerShell Core Security Settings Remediation Script

### Logging function
The script defines a `Write-Log` function that writes messages to both the console and a log file located at C:\ProgramData\PowerShellRegistryLog.txt.

### Error handling
The script includes a `Handle-Exception` function that catches exceptions, logs them with error severity, and continues execution.

### Registry settings definition
The script defines a hash table (`$registrySettings`) containing registry paths and their corresponding settings (e.g., values, types).

## Main script execution
The script iterates through the registry settings in `$registrySettings`, ensuring each path exists and creating it if necessary. For each setting:
* It checks if the value already exists in the registry.
* If not, it creates a new property with the specified value and type.
* If the value does exist but doesn't match the desired one, it updates the property.

### Completion and error handling
After processing all registry settings, the script logs a completion message with success severity. In case of any errors during execution, it uses the `Handle-Exception` function to log the error.
