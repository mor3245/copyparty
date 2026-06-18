[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ExecutablePath,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$WinSWPath,

    [ValidateSet("Standalone", "PythonModule")]
    [string]$RuntimeMode = "Standalone",

    [ValidatePattern("^[A-Za-z0-9]+$")]
    [string]$ServiceName = "Copyparty",

    [string]$DisplayName = "Copyparty File Server",
    [string]$Description = "Runs Copyparty as a background Windows service.",

    [ValidateSet("Automatic", "AutomaticDelayedStart", "Manual")]
    [string]$StartupType = "Automatic",

    [ValidateSet("LocalService", "NetworkService", "LocalSystem")]
    [string]$ServiceAccount = "LocalService",

    [string]$ServiceDirectory = "C:\copyparty-service",
    [string]$WorkingDirectory,
    [string]$HealthUrl = "http://127.0.0.1:3923/",
    [ValidateRange(1, 600)][int]$HealthTimeoutSeconds = 60,
    [switch]$EnableLan,
    [ValidateRange(1, 65535)][int]$LanPort = 3923,
    [switch]$SkipHealthCheck,
    [switch]$NoStart,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "windows-service-common.ps1")

if (-not (Test-CopypartyAdministrator)) {
    throw "Run this script from an elevated PowerShell session (Run as administrator)."
}

$ExecutablePath = (Resolve-Path -LiteralPath $ExecutablePath).Path
$ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$WinSWPath = (Resolve-Path -LiteralPath $WinSWPath).Path
$ServiceDirectory = [IO.Path]::GetFullPath($ServiceDirectory)

if (-not $WorkingDirectory) {
    $WorkingDirectory = Split-Path -Parent $ExecutablePath
}
elseif (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
    throw "Working directory does not exist: $WorkingDirectory"
}
else {
    $WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
}

if ([IO.Path]::GetExtension($WinSWPath) -ne ".exe") {
    throw "WinSWPath must point to the WinSW executable."
}

$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$wrapperPath = Join-Path $ServiceDirectory "copyparty-service.exe"
$xmlPath = Join-Path $ServiceDirectory "copyparty-service.xml"
$logDirectory = Join-Path $ServiceDirectory "logs"
$templatePath = Join-Path $PSScriptRoot "copyparty-service.xml.template"

if ($existingService) {
    if (-not $Force) {
        throw "Service '$ServiceName' already exists. Uninstall it first, or rerun with -Force to replace this integration's existing service."
    }

    if (-not (Test-Path -LiteralPath $wrapperPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) {
        throw "Refusing to replace '$ServiceName': its WinSW files were not found in '$ServiceDirectory'. Remove the unrelated service manually or choose another ServiceName."
    }

    if ($PSCmdlet.ShouldProcess($ServiceName, "Stop and uninstall existing service")) {
        if ($existingService.Status -ne "Stopped") {
            Invoke-CopypartyWinSW -WrapperPath $wrapperPath -Command "stop"
        }
        Invoke-CopypartyWinSW -WrapperPath $wrapperPath -Command "uninstall"
    }
}

if (-not $PSCmdlet.ShouldProcess($ServiceDirectory, "Install Copyparty Windows service")) {
    return
}

New-Item -ItemType Directory -Path $ServiceDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

if ([IO.Path]::GetFullPath($WinSWPath) -ne [IO.Path]::GetFullPath($wrapperPath)) {
    Copy-Item -LiteralPath $WinSWPath -Destination $wrapperPath -Force
}

$arguments = Get-CopypartyServiceArguments -RuntimeMode $RuntimeMode -ConfigPath $ConfigPath
New-CopypartyWinSWConfiguration `
    -TemplatePath $templatePath `
    -OutputPath $xmlPath `
    -ServiceName $ServiceName `
    -DisplayName $DisplayName `
    -Description $Description `
    -ExecutablePath $ExecutablePath `
    -Arguments $arguments `
    -WorkingDirectory $WorkingDirectory `
    -LogDirectory $logDirectory `
    -StartupType $StartupType `
    -ServiceAccount $ServiceAccount

$accountIdentity = Get-CopypartyServiceAccountIdentity $ServiceAccount
Protect-CopypartyConfigurationFile -Path $ConfigPath -ServiceIdentity $accountIdentity
Grant-CopypartyDirectoryAccess `
    -Path $ServiceDirectory `
    -Identity $accountIdentity `
    -Rights ([Security.AccessControl.FileSystemRights]::ReadAndExecute)
Grant-CopypartyDirectoryAccess `
    -Path $logDirectory `
    -Identity $accountIdentity `
    -Rights ([Security.AccessControl.FileSystemRights]::Modify)

if ($RuntimeMode -eq "PythonModule") {
    $pythonBase = (& $ExecutablePath -c "import sys; print(sys.base_prefix)").Trim()
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $pythonBase -PathType Container)) {
        throw "Could not determine the base Python directory used by '$ExecutablePath'."
    }

    Grant-CopypartyDirectoryAccess `
        -Path $pythonBase `
        -Identity $accountIdentity `
        -Rights ([Security.AccessControl.FileSystemRights]::ReadAndExecute)
}

Invoke-CopypartyWinSW -WrapperPath $wrapperPath -Command "install"

$firewallRuleName = "$ServiceName-LAN"
$firewallCmd = Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue
if ($EnableLan) {
    if (-not $firewallCmd) {
        throw "Windows Firewall PowerShell commands are unavailable; the LAN firewall rule could not be created."
    }

    Get-NetFirewallRule -Name $firewallRuleName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule `
        -Name $firewallRuleName `
        -DisplayName "Copyparty File Server (LAN)" `
        -Description "Allows LAN clients to reach the Copyparty Windows service." `
        -Direction Inbound `
        -Action Allow `
        -Enabled True `
        -Profile Private `
        -Protocol TCP `
        -LocalPort $LanPort `
        -RemoteAddress LocalSubnet | Out-Null
    Write-Host "LAN firewall rule '$firewallRuleName' allows TCP port $LanPort on Private networks."
}
elseif ($firewallCmd) {
    Get-NetFirewallRule -Name $firewallRuleName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

if ($NoStart) {
    Write-Host "Service '$ServiceName' was installed but not started."
    Write-Host "Start it with: Start-Service -Name '$ServiceName'"
    return
}

Invoke-CopypartyWinSW -WrapperPath $wrapperPath -Command "start"

if (-not $SkipHealthCheck) {
    $deadline = [DateTime]::UtcNow.AddSeconds($HealthTimeoutSeconds)
    $reachable = $false
    do {
        try {
            $response = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 5
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
                $reachable = $true
                break
            }
        }
        catch {
            Start-Sleep -Seconds 2
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    if (-not $reachable) {
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        $status = if ($service) { $service.Status } else { "not found" }
        throw "Service status is '$status', but Copyparty did not respond at '$HealthUrl' within $HealthTimeoutSeconds seconds. Check '$logDirectory'."
    }
}

$installed = Get-Service -Name $ServiceName
Write-Host "Service '$ServiceName' installed successfully (status: $($installed.Status))."
Write-Host "Configuration: $xmlPath"
Write-Host "Logs: $logDirectory"
