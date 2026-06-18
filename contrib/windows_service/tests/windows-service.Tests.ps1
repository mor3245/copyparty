$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$serviceRoot = Split-Path -Parent $here
. (Join-Path $serviceRoot "windows-service-common.ps1")

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}

Describe "Copyparty Windows service configuration" {
    It "parses the GUI and Python setup scripts without PowerShell syntax errors" {
        foreach ($file in @("service-wizard.ps1", "setup-python-env.ps1")) {
            $tokens = $null
            $errors = $null
            [Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $serviceRoot $file),
                [ref]$tokens,
                [ref]$errors
            ) | Out-Null

            if ($errors.Count -ne 0) {
                throw ($errors | ForEach-Object { $_.Message } | Out-String)
            }
        }
    }

    It "keeps management mode separate from the installation flow" {
        $wizard = Get-Content -LiteralPath (Join-Path $serviceRoot "service-wizard.ps1") -Raw
        Assert-True ($wizard.Contains('$btnInstall.Visible = -not $script:ManagementMode')) "Management mode does not hide installation."
        Assert-True ($wizard.Contains('if (-not (Test-WizardInstallReady))')) "Install action does not enforce prerequisites."
        Assert-True ($wizard.Contains('$script:PythonPrepared')) "Python completion state is not tracked."
        Assert-True ($wizard.Contains('$script:ConfigurationPrepared')) "Configuration completion state is not tracked."
        Assert-True ($wizard.Contains('$script:ManagementMode = $true')) "Successful installation does not transition to management mode."
    }

    It "installs and verifies the complete published browser assets" {
        $setup = Get-Content -LiteralPath (Join-Path $serviceRoot "setup-python-env.ps1") -Raw
        Assert-True ($setup.Contains('"--force-reinstall", "copyparty"')) "Python setup does not replace incomplete local builds."
        Assert-True ($setup.Contains("marked.js.gz")) "Python setup does not verify the Markdown parser asset."
        Assert-True (-not $setup.Contains('[string]$SourcePath')) "Python setup still installs from the incomplete source checkout."
    }

    It "builds standalone arguments with a quoted configuration path" {
        $actual = Get-CopypartyServiceArguments -RuntimeMode Standalone -ConfigPath "C:\party files\party.conf"
        Assert-Equal $actual '-c "C:\party files\party.conf"' "Standalone arguments differ."
    }

    It "builds Python module arguments" {
        $actual = Get-CopypartyServiceArguments -RuntimeMode PythonModule -ConfigPath "C:\party.conf"
        Assert-Equal $actual '-m copyparty -c "C:\party.conf"' "Python arguments differ."
    }

    It "maps WinSW service accounts to Windows ACL identities" {
        Assert-Equal (Get-CopypartyServiceAccountIdentity LocalService) "NT AUTHORITY\LOCAL SERVICE" "LocalService identity differs."
        Assert-Equal (Get-CopypartyServiceAccountIdentity NetworkService) "NT AUTHORITY\NETWORK SERVICE" "NetworkService identity differs."
        Assert-Equal (Get-CopypartyServiceAccountIdentity LocalSystem) "NT AUTHORITY\SYSTEM" "LocalSystem identity differs."
    }

    It "generates an authenticated Copyparty configuration" {
        $config = Join-Path $TestDrive "party.conf"
        $shared = Join-Path $TestDrive "shared"
        New-CopypartyConfiguration `
            -ConfigPath $config `
            -Port 3923 `
            -SharedPath $shared `
            -Username "admin" `
            -Password "SafePass123!" `
            -AllowLan $true

        $content = Get-Content -LiteralPath $config -Raw
        Assert-True ($content.Contains("p: 3923")) "Configured port is missing."
        Assert-True ($content.Contains("i: ::")) "LAN interface binding is missing."
        Assert-True ($content.Contains("admin: SafePass123!")) "Administrator account is missing."
        Assert-True ($content.Contains("rwmda: admin")) "Administrator permissions are missing."
        Assert-True (-not $content.Contains("r: *")) "Generated configuration unexpectedly allows anonymous access."
        Assert-True (Test-Path -LiteralPath $shared -PathType Container) "Shared directory was not created."
    }

    It "binds only to localhost when LAN access is disabled" {
        $config = Join-Path $TestDrive "localhost.conf"
        New-CopypartyConfiguration `
            -ConfigPath $config `
            -Port 3923 `
            -SharedPath (Join-Path $TestDrive "local-only") `
            -Username "admin" `
            -Password "SafePass123!" `
            -AllowLan $false

        $content = Get-Content -LiteralPath $config -Raw
        Assert-True ($content.Contains("i: 127.0.0.1, ::1")) "Local-only interface binding is missing."
    }

    It "limits the LAN firewall rule to private local networks" {
        $installer = Get-Content -LiteralPath (Join-Path $serviceRoot "install-service.ps1") -Raw
        $uninstaller = Get-Content -LiteralPath (Join-Path $serviceRoot "uninstall-service.ps1") -Raw
        Assert-True ($installer.Contains("-Profile Private")) "Firewall rule is not limited to Private profiles."
        Assert-True ($installer.Contains("-RemoteAddress LocalSubnet")) "Firewall rule is not limited to the local subnet."
        Assert-True ($uninstaller.Contains('"$ServiceName-LAN"')) "Uninstaller does not remove the LAN firewall rule."
    }

    It "generates valid XML and escapes path characters" {
        $output = Join-Path $TestDrive "copyparty-service.xml"
        New-CopypartyWinSWConfiguration `
            -TemplatePath (Join-Path $serviceRoot "copyparty-service.xml.template") `
            -OutputPath $output `
            -ServiceName "CopypartyTest" `
            -DisplayName "Copyparty & Test" `
            -Description "Test service" `
            -ExecutablePath "C:\apps\copyparty & tools\copyparty.exe" `
            -Arguments '-c "C:\config\party.conf"' `
            -WorkingDirectory "C:\apps" `
            -LogDirectory "C:\logs" `
            -StartupType "AutomaticDelayedStart" `
            -ServiceAccount "LocalService"

        [xml]$xml = Get-Content -LiteralPath $output -Raw
        Assert-Equal $xml.service.id "CopypartyTest" "Service ID differs."
        Assert-Equal $xml.service.name "Copyparty & Test" "Display name was not XML-decoded."
        Assert-Equal $xml.service.executable "C:\apps\copyparty & tools\copyparty.exe" "Executable path was not XML-decoded."
        Assert-True ($null -ne $xml.service.SelectSingleNode("delayedAutoStart")) "Delayed auto-start element is missing."
        Assert-Equal $xml.service.serviceaccount.user "LocalService" "Service account differs."
        Assert-Equal $xml.service.log.mode "roll-by-size" "Log mode differs."
        Assert-Equal $xml.service.onfailure.action "restart" "Recovery action differs."
    }

    It "does not add delayed start for a manual service" {
        $output = Join-Path $TestDrive "manual.xml"
        New-CopypartyWinSWConfiguration `
            -TemplatePath (Join-Path $serviceRoot "copyparty-service.xml.template") `
            -OutputPath $output `
            -ServiceName "CopypartyManual" `
            -DisplayName "Copyparty Manual" `
            -Description "Test service" `
            -ExecutablePath "C:\copyparty.exe" `
            -Arguments '-c "C:\party.conf"' `
            -WorkingDirectory "C:\" `
            -LogDirectory "C:\logs" `
            -StartupType "Manual" `
            -ServiceAccount "NetworkService"

        [xml]$xml = Get-Content -LiteralPath $output -Raw
        Assert-Equal $xml.service.startmode "Manual" "Start mode differs."
        Assert-True ($null -eq $xml.service.SelectSingleNode("delayedAutoStart")) "Manual service unexpectedly has delayed auto-start."
        Assert-Equal $xml.service.serviceaccount.user "NetworkService" "Service account differs."
    }
}
