# Copyparty Windows service

This directory provides a repeatable Windows service installation for Copyparty. It uses [WinSW v2.12.0](https://github.com/winsw/winsw/releases/tag/v2.12.0) to run Copyparty from an isolated Python environment in the background.

The WinSW binary is deliberately not included. The instructions below download the pinned 64-bit v2.12.0 executable from the official release. WinSW v3 is not used because it has a different service-account configuration format.

## GUI wizard

Double-click `launch-wizard.cmd` and approve the Windows administrator prompt. Keep the computer connected to the internet while the Python environment is prepared. The wizard provides four steps:

1. Confirm the base Python executable and virtual-environment directory, then click **Prepare**. The wizard creates the environment, installs current packaging tools, force-installs the complete published Copyparty package from PyPI, and verifies that required browser assets such as `marked.js.gz` are present.
2. Enter the web port, shared directory, administrator username, and administrator password. Keep **Allow access from devices on the Private LAN** selected to create a Windows Firewall rule limited to the Private network profile and local subnet. The wizard creates `C:\copyparty\party.conf`, secures it, and backs up an existing file as `party.conf.bak`. Confirm the WinSW path on the same page.
3. Confirm the startup type, service account, and health URL.
4. Review the settings and click **Install**.

Click **Manage service** to enter a management-only view. This view shows the current status and provides **Start**, **Stop**, **Restart**, and **Uninstall** buttons; it cannot install or replace a service. Click **Return to setup** to resume the installation wizard at the previous step. Installation and uninstallation output is displayed in the wizard.

After installation, the wizard displays the available IPv4 LAN URLs. Windows must classify the connected network as **Private** for another device to connect. Uninstalling the service also removes the `Copyparty-LAN` firewall rule.

The wizard uses `install-service.ps1` and `uninstall-service.ps1`; it does not duplicate their service-management logic.

## Installation

Open PowerShell using **Run as administrator**, then run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
Set-Location "C:\Users\morgan\Documents\mmu_mar_apr_2610\software_evolution_maintenance\Assignment\copyparty"

New-Item -ItemType Directory -Path C:\copyparty\data -Force
python -m venv C:\copyparty\venv
C:\copyparty\venv\Scripts\python.exe -m pip install --upgrade pip setuptools wheel
C:\copyparty\venv\Scripts\python.exe -m pip install .

Copy-Item .\contrib\windows_service\party.example.conf C:\copyparty\party.conf -Force
notepad C:\copyparty\party.conf
```

Replace `CHANGE-ME-BEFORE-USING` with a strong password, save the file, and close Notepad.

Test the exact command that the service will run:

```powershell
C:\copyparty\venv\Scripts\python.exe -m copyparty -c C:\copyparty\party.conf
```

Open `http://127.0.0.1:3923/`. After confirming that Copyparty works, return to PowerShell and press `Ctrl+C`.

Grant the service account access to the Python environment, configuration, and shared directory:

```powershell
icacls C:\copyparty /grant "NT AUTHORITY\LOCAL SERVICE:(OI)(CI)RX"
icacls C:\copyparty\data /grant "NT AUTHORITY\LOCAL SERVICE:(OI)(CI)M"
icacls C:\copyparty\party.conf /inheritance:r
icacls C:\copyparty\party.conf /grant:r "*S-1-5-32-544:F" "*S-1-5-18:F" "*S-1-5-19:R"
```

The last two commands restrict the configuration file to Administrators, Windows itself, and the `LocalService` account. During installation, the script also detects the virtual environment's base Python directory and grants `LocalService` read/execute access to it. This is required because a Windows virtual environment redirects execution to its base Python installation.

Download the pinned WinSW executable:

```powershell
Invoke-WebRequest `
    -Uri "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe" `
    -OutFile C:\copyparty\WinSW-x64.exe
```

Install and start the service:

```powershell
.\contrib\windows_service\install-service.ps1 `
    -RuntimeMode PythonModule `
    -ExecutablePath C:\copyparty\venv\Scripts\python.exe `
    -ConfigPath C:\copyparty\party.conf `
    -WinSWPath C:\copyparty\WinSW-x64.exe
```

Verify the service and web interface:

```powershell
Get-Service Copyparty
Invoke-WebRequest http://127.0.0.1:3923/ -UseBasicParsing
```

The expected service status is `Running`, and the web request should return status code `200`.

## Installer options

- `-StartupType Automatic`, `AutomaticDelayedStart`, or `Manual`; default: `Automatic`.
- `-ServiceAccount LocalService`, `NetworkService`, or `LocalSystem`; default: `LocalService`.
- `-HealthUrl`; default: `http://127.0.0.1:3923/`.
- `-EnableLan -LanPort 3923` creates a Private-profile, local-subnet Windows Firewall rule.
- `-NoStart` installs the service without starting it. This is useful when folder ACLs still need to be configured.
- `-SkipHealthCheck` skips HTTP reachability verification.
- `-Force` replaces an existing service only when its expected WinSW files exist in the selected service directory.
- `-WhatIf` previews the service-changing operation.

`LocalSystem` is available for exceptional deployments but is not recommended as a convenient workaround for incorrect permissions.

## Service management

Use standard Windows commands:

```powershell
Get-Service Copyparty
Start-Service Copyparty
Stop-Service Copyparty
Restart-Service Copyparty
```

The service can also be managed from `services.msc`.

The generated WinSW configuration provides:

- automatic startup by default;
- no persistent console window;
- a 30-second graceful shutdown timeout;
- automatic restart 30 seconds after a non-zero process exit;
- failure-count reset after one hour;
- separate stdout and stderr logs;
- size-based log rotation at 10 MiB with eight retained files.

## Logs and configuration

With the default service directory, the generated files are:

```text
C:\copyparty-service\copyparty-service.exe
C:\copyparty-service\copyparty-service.xml
C:\copyparty-service\logs\copyparty-service.out.log
C:\copyparty-service\logs\copyparty-service.err.log
```

WinSW also writes wrapper diagnostics to the Windows Application event log. Copyparty output is captured by the `.out.log` and `.err.log` files above.

## Uninstall

```powershell
.\uninstall-service.ps1
```

For a non-default service directory or name:

```powershell
.\uninstall-service.ps1 `
    -ServiceName Copyparty `
    -ServiceDirectory D:\services\copyparty
```

Uninstallation removes only the Windows service entry. It deliberately preserves WinSW files, generated XML, logs, the Copyparty configuration, and all shared data.

## Network shares and service accounts

Drive mappings such as `Z:` normally do not exist in a Windows service session. Use UNC paths such as `\\server\share` in the Copyparty configuration and run under an account that has access to that share. The bundled installer does not accept account passwords because placing them in XML or command history would expose them. Configure a dedicated user or group-managed service account through an approved administrative process if network access is required.

## Troubleshooting

### The service starts and immediately stops

- Run Copyparty manually with the same executable and configuration.
- Inspect `copyparty-service.err.log` and the Windows Application event log.
- Confirm that paths containing spaces were passed as complete PowerShell arguments.
- Confirm the service account can read the executable and configuration.

### The service runs but shared folders fail

- Check NTFS and share permissions for the service account.
- Replace mapped drive letters with UNC paths.
- Remember that `LocalService` has different access from the signed-in user.

### The service runs but the health check fails

- Pass the actual configured address with `-HealthUrl`.
- Check whether the configured port is already in use.
- Check Windows Firewall when connecting from another machine.
- Use `-SkipHealthCheck` only when HTTP verification is intentionally unavailable.

### WinSW reports that the service already exists

Use `uninstall-service.ps1` first. `-Force` is intentionally conservative and will not delete an unrelated service that happens to use the same name.

## Testing

Run the non-destructive tests with Pester 3.4 or newer:

```powershell
Invoke-Pester .\tests\windows-service.Tests.ps1
```

See [TESTING.md](TESTING.md) for the administrator-only acceptance test procedure.
