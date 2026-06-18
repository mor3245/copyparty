Set-StrictMode -Version Latest

function Test-CopypartyAdministrator {
    if ($env:OS -ne "Windows_NT") {
        return $false
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-CopypartyXmlText {
    param([AllowEmptyString()][string]$Value)

    return [Security.SecurityElement]::Escape($Value)
}

function Get-CopypartyServiceArguments {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Standalone", "PythonModule")]
        [string]$RuntimeMode,

        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    if ($RuntimeMode -eq "PythonModule") {
        return "-m copyparty -c `"$ConfigPath`""
    }

    return "-c `"$ConfigPath`""
}

function Get-CopypartyServiceAccountXml {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("LocalService", "NetworkService", "LocalSystem")]
        [string]$ServiceAccount
    )

    switch ($ServiceAccount) {
        "LocalService" {
            return @"
  <serviceaccount>
    <domain>NT AUTHORITY</domain>
    <user>LocalService</user>
  </serviceaccount>
"@
        }
        "NetworkService" {
            return @"
  <serviceaccount>
    <domain>NT AUTHORITY</domain>
    <user>NetworkService</user>
  </serviceaccount>
"@
        }
        "LocalSystem" {
            return @"
  <serviceaccount>
    <user>LocalSystem</user>
  </serviceaccount>
"@
        }
    }
}

function Get-CopypartyServiceAccountIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("LocalService", "NetworkService", "LocalSystem")]
        [string]$ServiceAccount
    )

    switch ($ServiceAccount) {
        "LocalService" { return "NT AUTHORITY\LOCAL SERVICE" }
        "NetworkService" { return "NT AUTHORITY\NETWORK SERVICE" }
        "LocalSystem" { return "NT AUTHORITY\SYSTEM" }
    }
}

function Grant-CopypartyDirectoryAccess {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)]
        [Security.AccessControl.FileSystemRights]$Rights
    )

    $acl = Get-Acl -LiteralPath $Path
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $Identity,
        $Rights,
        $inheritance,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    )
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Protect-CopypartyConfigurationFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ServiceIdentity
    )

    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleAll($rule)
    }

    $administrators = [Security.Principal.SecurityIdentifier]::new("S-1-5-32-544").Translate(
        [Security.Principal.NTAccount]
    ).Value
    $system = [Security.Principal.SecurityIdentifier]::new("S-1-5-18").Translate(
        [Security.Principal.NTAccount]
    ).Value

    foreach ($entry in @(
        @($administrators, [Security.AccessControl.FileSystemRights]::FullControl),
        @($system, [Security.AccessControl.FileSystemRights]::FullControl),
        @($ServiceIdentity, [Security.AccessControl.FileSystemRights]::Read)
    )) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $entry[0],
            $entry[1],
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
    }

    Set-Acl -LiteralPath $Path -AclObject $acl
}

function New-CopypartyConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port,
        [Parameter(Mandatory = $true)][string]$SharedPath,
        [Parameter(Mandatory = $true)][ValidatePattern("^[A-Za-z0-9._-]+$")][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][bool]$AllowLan
    )

    if ($Password.Length -lt 8) {
        throw "The Copyparty administrator password must contain at least 8 characters."
    }
    if ($Password -notmatch "^[A-Za-z0-9!@`$%^&*()_+\-=\[\]{},.?]+$") {
        throw "The password contains characters that cannot be written safely to a Copyparty configuration file."
    }

    $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    $SharedPath = [IO.Path]::GetFullPath($SharedPath)
    $configDirectory = Split-Path -Parent $ConfigPath
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $SharedPath -Force | Out-Null

    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        Copy-Item -LiteralPath $ConfigPath -Destination ($ConfigPath + ".bak") -Force
    }

    $content = @(
        "[global]"
        $(if ($AllowLan) { "  i: ::" } else { "  i: 127.0.0.1, ::1" })
        "  p: $Port"
        ""
        "[accounts]"
        "  ${Username}: $Password"
        ""
        "[/]"
        "  $SharedPath"
        "  accs:"
        "    rwmda: $Username"
        ""
    )
    Set-Content -LiteralPath $ConfigPath -Value $content -Encoding UTF8
}

function New-CopypartyWinSWConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$ServiceName,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$LogDirectory,
        [Parameter(Mandatory = $true)]
        [ValidateSet("Automatic", "AutomaticDelayedStart", "Manual")]
        [string]$StartupType,
        [Parameter(Mandatory = $true)]
        [ValidateSet("LocalService", "NetworkService", "LocalSystem")]
        [string]$ServiceAccount
    )

    $template = Get-Content -LiteralPath $TemplatePath -Raw
    $startMode = if ($StartupType -eq "Manual") { "Manual" } else { "Automatic" }
    $delayedStart = if ($StartupType -eq "AutomaticDelayedStart") { "  <delayedAutoStart/>" } else { "" }

    $values = [ordered]@{
        "{{SERVICE_ID}}" = ConvertTo-CopypartyXmlText $ServiceName
        "{{DISPLAY_NAME}}" = ConvertTo-CopypartyXmlText $DisplayName
        "{{DESCRIPTION}}" = ConvertTo-CopypartyXmlText $Description
        "{{EXECUTABLE}}" = ConvertTo-CopypartyXmlText $ExecutablePath
        "{{ARGUMENTS}}" = ConvertTo-CopypartyXmlText $Arguments
        "{{WORKING_DIRECTORY}}" = ConvertTo-CopypartyXmlText $WorkingDirectory
        "{{LOG_DIRECTORY}}" = ConvertTo-CopypartyXmlText $LogDirectory
        "{{START_MODE}}" = $startMode
        "{{DELAYED_AUTO_START}}" = $delayedStart
        "{{SERVICE_ACCOUNT}}" = Get-CopypartyServiceAccountXml $ServiceAccount
    }

    foreach ($entry in $values.GetEnumerator()) {
        $template = $template.Replace($entry.Key, $entry.Value)
    }

    if ($template -match "\{\{[A-Z_]+\}\}") {
        throw "The WinSW configuration template contains an unresolved placeholder: $($Matches[0])"
    }

    $parent = Split-Path -Parent $OutputPath
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Set-Content -LiteralPath $OutputPath -Value $template -Encoding UTF8

    try {
        [xml](Get-Content -LiteralPath $OutputPath -Raw) | Out-Null
    }
    catch {
        Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
        throw "Generated WinSW configuration is invalid XML: $($_.Exception.Message)"
    }
}

function Invoke-CopypartyWinSW {
    param(
        [Parameter(Mandatory = $true)][string]$WrapperPath,
        [Parameter(Mandatory = $true)][string]$Command
    )

    & $WrapperPath $Command
    if ($LASTEXITCODE -ne 0) {
        throw "WinSW command '$Command' failed with exit code $LASTEXITCODE."
    }
}
