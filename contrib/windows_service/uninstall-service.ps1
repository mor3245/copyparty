[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidatePattern("^[A-Za-z0-9]+$")]
    [string]$ServiceName = "Copyparty",

    [string]$ServiceDirectory = "C:\copyparty-service"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "windows-service-common.ps1")

if (-not (Test-CopypartyAdministrator)) {
    throw "Run this script from an elevated PowerShell session (Run as administrator)."
}

$firewallCmd = Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue
$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $service) {
    $firewallRule = if ($firewallCmd) {
        Get-NetFirewallRule -Name "$ServiceName-LAN" -ErrorAction SilentlyContinue
    }
    else {
        $null
    }
    if ($firewallRule -and $PSCmdlet.ShouldProcess("$ServiceName-LAN", "Remove Copyparty LAN firewall rule")) {
        $firewallRule | Remove-NetFirewallRule
        Write-Host "Removed LAN firewall rule '$ServiceName-LAN'."
    }
    Write-Host "Service '$ServiceName' is not installed; nothing to do."
    return
}

$ServiceDirectory = [IO.Path]::GetFullPath($ServiceDirectory)
$wrapperPath = Join-Path $ServiceDirectory "copyparty-service.exe"
$xmlPath = Join-Path $ServiceDirectory "copyparty-service.xml"

if (-not (Test-Path -LiteralPath $wrapperPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) {
    throw "WinSW files were not found in '$ServiceDirectory'. Refusing to remove a service that may belong to another installation."
}

if (-not $PSCmdlet.ShouldProcess($ServiceName, "Stop and uninstall Copyparty service")) {
    return
}

if ($service.Status -ne "Stopped") {
    Invoke-CopypartyWinSW -WrapperPath $wrapperPath -Command "stop"
}

Invoke-CopypartyWinSW -WrapperPath $wrapperPath -Command "uninstall"

$firewallRule = if ($firewallCmd) {
    Get-NetFirewallRule -Name "$ServiceName-LAN" -ErrorAction SilentlyContinue
}
else {
    $null
}
if ($firewallRule) {
    $firewallRule | Remove-NetFirewallRule
    Write-Host "Removed LAN firewall rule '$ServiceName-LAN'."
}

if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    throw "WinSW returned successfully, but service '$ServiceName' is still present. It may be pending deletion until Services Manager is closed."
}

Write-Host "Service '$ServiceName' was removed."
Write-Host "The wrapper, generated XML, logs, Copyparty configuration, and shared data were preserved."
