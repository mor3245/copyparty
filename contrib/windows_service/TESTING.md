# Windows service acceptance testing

The Pester suite validates argument construction, XML escaping, startup modes, service accounts, logging, and recovery configuration without modifying Windows services.

The following acceptance tests require an elevated disposable Windows virtual machine. Record the date, Windows version, Copyparty version, WinSW checksum, commands, observed service state, HTTP result, and relevant log filenames for each test.

| Test | Procedure | Expected result |
| --- | --- | --- |
| Installation | Run `install-service.ps1` with `-NoStart`; inspect `Get-Service Copyparty` and the generated XML. | The service exists with the selected startup mode. |
| Startup | Grant the selected service account access, start the service, and request the configured health URL. | Service state is `Running` and HTTP responds. |
| Background execution | Sign out of the interactive user session and connect from another machine. | Copyparty remains reachable with no terminal window. |
| Stop | Run `Stop-Service Copyparty`, then retry the health URL. | Service state is `Stopped` and HTTP is unavailable. |
| Restart | Run `Restart-Service Copyparty`, then retry the health URL. | Service returns to `Running` and HTTP responds. |
| Recovery | While the service is running, terminate only the child Copyparty process and wait at least 30 seconds. | Windows restarts the service and Copyparty becomes reachable again. |
| Logging | Generate normal traffic and one configuration error. | `.out.log` and `.err.log` are created and useful diagnostics are visible. |
| Reboot | Reboot with startup type `Automatic`. | Copyparty starts without a user signing in. |
| Uninstallation | Run `uninstall-service.ps1`; inspect the service directory and shared data. | Service entry is gone; configuration, logs, and shared data remain. |

Do not run the recovery test by terminating an unrelated Python process. Identify the process from the WinSW service process tree first.

## Test record

Copy this table into the assignment report and attach screenshots or command output as evidence:

| Test | Pass/Fail | Evidence | Notes |
| --- | --- | --- | --- |
| Installation | Not run | | Requires elevated Windows test VM |
| Startup and reachability | Not run | | Requires deployment paths and ACLs |
| Background execution | Not run | | |
| Stop and restart | Not run | | |
| Failure recovery | Not run | | |
| Logging | Not run | | |
| Reboot persistence | Not run | | Requires reboot |
| Uninstallation and preservation | Not run | | |
