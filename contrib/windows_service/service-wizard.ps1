[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "windows-service-common.ps1")

if ($env:OS -ne "Windows_NT") {
    throw "The Copyparty service wizard requires Windows."
}

function Test-WizardAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-WizardAdministrator)) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $PSCommandPath

    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $arguments -WindowStyle Hidden
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$script:ServiceName = "Copyparty"
$script:CurrentPage = 0
$script:Busy = $false
$script:ActiveCommand = $null
$script:LogTarget = $null
$script:ManagementMode = $false
$script:InstallPageBeforeManagement = 0
$script:PythonPrepared = $false
$script:ConfigurationPrepared = $false
$script:ServiceWasRunningBeforeSetup = $false

function New-WizardLabel {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width = 720,
        [int]$Height = 24
    )

    $label = [Windows.Forms.Label]::new()
    $label.Text = $Text
    $label.Location = [Drawing.Point]::new($X, $Y)
    $label.Size = [Drawing.Size]::new($Width, $Height)
    return $label
}

function Select-WizardFile {
    param(
        [Windows.Forms.TextBox]$Target,
        [string]$Title,
        [string]$Filter
    )

    $dialog = [Windows.Forms.OpenFileDialog]::new()
    $dialog.Title = $Title
    $dialog.Filter = $Filter
    $dialog.CheckFileExists = $true

    if ($Target.Text -and (Test-Path -LiteralPath $Target.Text -PathType Leaf)) {
        $dialog.InitialDirectory = Split-Path -Parent $Target.Text
        $dialog.FileName = Split-Path -Leaf $Target.Text
    }

    if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
        $Target.Text = $dialog.FileName
    }

    $dialog.Dispose()
}

function Select-WizardFolder {
    param(
        [Windows.Forms.TextBox]$Target,
        [string]$Description
    )

    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $true
    if ($Target.Text -and (Test-Path -LiteralPath $Target.Text -PathType Container)) {
        $dialog.SelectedPath = $Target.Text
    }

    if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
        $Target.Text = $dialog.SelectedPath
    }

    $dialog.Dispose()
}

function Quote-WizardArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    return '"{0}"' -f $Value.Replace('"', '\"')
}

function Add-WizardLog {
    param([string]$Text)

    if (-not $Text -or $null -eq $script:LogTarget) {
        return
    }

    $script:LogTarget.AppendText($Text.TrimEnd() + [Environment]::NewLine)
    $script:LogTarget.SelectionStart = $script:LogTarget.TextLength
    $script:LogTarget.ScrollToCaret()
}

function Set-WizardBusy {
    param([bool]$IsBusy)

    $script:Busy = $IsBusy
    $form.UseWaitCursor = $IsBusy
    $btnBack.Enabled = -not $IsBusy -and -not $script:ManagementMode -and $script:CurrentPage -gt 0
    $btnNext.Enabled = -not $IsBusy -and -not $script:ManagementMode -and $script:CurrentPage -lt 3
    $btnInstall.Enabled = -not $IsBusy -and (Test-WizardInstallReady)
    $btnRefresh.Enabled = -not $IsBusy
    $btnStart.Enabled = -not $IsBusy -and $btnStart.Tag
    $btnStop.Enabled = -not $IsBusy -and $btnStop.Tag
    $btnRestart.Enabled = -not $IsBusy -and $btnRestart.Tag
    $btnUninstall.Enabled = -not $IsBusy -and $btnUninstall.Tag
    $btnManage.Enabled = -not $IsBusy
}

function Test-WizardInstallReady {
    if ($script:ManagementMode -or $script:CurrentPage -ne 3) {
        return $false
    }
    if (-not $script:PythonPrepared -or -not $script:ConfigurationPrepared) {
        return $false
    }

    return $null -eq (Get-WizardValidationError)
}

function Get-WizardValidationError {
    if (-not (Test-Path -LiteralPath $txtPython.Text -PathType Leaf)) {
        return "Python executable not found: $($txtPython.Text)"
    }
    if (-not (Test-Path -LiteralPath $txtConfig.Text -PathType Leaf)) {
        return "Copyparty configuration not found: $($txtConfig.Text)"
    }
    if (-not (Test-Path -LiteralPath $txtWinSW.Text -PathType Leaf)) {
        return "WinSW executable not found: $($txtWinSW.Text)"
    }

    $uri = $null
    if (-not [Uri]::TryCreate($txtHealth.Text, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @("http", "https")) {
        return "Health URL must be a complete HTTP or HTTPS address."
    }

    return $null
}

function Get-PythonSetupValidationError {
    if (-not (Test-Path -LiteralPath $txtBasePython.Text -PathType Leaf)) {
        return "Base Python executable not found: $($txtBasePython.Text)"
    }
    if (-not $txtVenv.Text.Trim()) {
        return "Enter a virtual environment directory."
    }
    return $null
}

function Get-CopypartyConfigValidationError {
    if (-not $txtSharedPath.Text.Trim()) {
        return "Enter a shared directory."
    }
    if ($txtUsername.Text -notmatch "^[A-Za-z0-9._-]+$") {
        return "The administrator username may contain only letters, numbers, periods, underscores, and hyphens."
    }
    if ($txtPassword.Text.Length -lt 8) {
        return "The administrator password must contain at least 8 characters."
    }
    if ($txtPassword.Text -ne $txtConfirmPassword.Text) {
        return "The administrator passwords do not match."
    }
    if ($txtPassword.Text -notmatch "^[A-Za-z0-9!@`$%^&*()_+\-=\[\]{},.?]+$") {
        return "Use letters, numbers, and standard punctuation in the administrator password."
    }

    return $null
}

function Get-InstallInputsValidationError {
    if (-not (Test-Path -LiteralPath $txtPython.Text -PathType Leaf)) {
        return "Prepared Python executable not found: $($txtPython.Text)"
    }
    if (-not (Test-Path -LiteralPath $txtWinSW.Text -PathType Leaf)) {
        return "WinSW executable not found: $($txtWinSW.Text)"
    }

    return Get-CopypartyConfigValidationError
}

function Get-WizardLanUrls {
    $urls = @()
    foreach ($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($adapter.OperationalStatus -ne [Net.NetworkInformation.OperationalStatus]::Up -or
            $adapter.NetworkInterfaceType -eq [Net.NetworkInformation.NetworkInterfaceType]::Loopback) {
            continue
        }

        foreach ($address in $adapter.GetIPProperties().UnicastAddresses) {
            $ip = $address.Address
            if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
                continue
            }
            $text = $ip.ToString()
            if ($text.StartsWith("127.") -or $text.StartsWith("169.254.")) {
                continue
            }
            $urls += "http://${text}:$([int]$numPort.Value)/"
        }
    }

    return @($urls | Sort-Object -Unique)
}

function Update-WizardReview {
    if ($script:ManagementMode) {
        $txtReview.Text = @"
Service management mode

Use the controls below to start, stop, restart, or uninstall the existing
Copyparty service. Installation is disabled in this mode.
"@.Trim()
        return
    }

    $txtReview.Text = @"
Python:          $($txtPython.Text)
Configuration:   $($txtConfig.Text)
Web port:         $($numPort.Value)
Shared directory: $($txtSharedPath.Text)
Administrator:    $($txtUsername.Text)
LAN access:       $($chkLan.Checked)
LAN URLs:         $(if ($chkLan.Checked) { (Get-WizardLanUrls) -join ", " } else { "Disabled" })
WinSW:            $($txtWinSW.Text)
Startup type:     $($cmbStartup.SelectedItem)
Service account:  $($cmbAccount.SelectedItem)
Health URL:       $($txtHealth.Text)
Replace existing: $($chkForce.Checked)
"@.Trim()
}

function Update-WizardServiceStatus {
    $service = Get-Service -Name $script:ServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        $lblStatusValue.Text = "Not installed"
        $lblStatusValue.ForeColor = [Drawing.Color]::DimGray
        $btnStart.Tag = $false
        $btnStop.Tag = $false
        $btnRestart.Tag = $false
        $btnUninstall.Tag = $false
    }
    else {
        $lblStatusValue.Text = [string]$service.Status
        if ($service.Status -eq "Running") {
            $lblStatusValue.ForeColor = [Drawing.Color]::ForestGreen
        }
        else {
            $lblStatusValue.ForeColor = [Drawing.Color]::DarkOrange
        }
        $btnStart.Tag = $service.Status -eq "Stopped"
        $btnStop.Tag = $service.Status -ne "Stopped"
        $btnRestart.Tag = $service.Status -eq "Running"
        $btnUninstall.Tag = $true
    }

    if (-not $script:Busy) {
        Set-WizardBusy $false
    }
}

function Set-WizardPage {
    param([ValidateRange(0, 3)][int]$Page)

    if ($script:ManagementMode) {
        $Page = 3
    }
    elseif ($Page -gt 0 -and -not $script:PythonPrepared) {
        $Page = 0
    }
    elseif ($Page -gt 1 -and -not $script:ConfigurationPrepared) {
        $Page = 1
    }

    $script:CurrentPage = $Page
    for ($index = 0; $index -lt $script:Pages.Count; $index++) {
        $script:Pages[$index].Visible = $index -eq $Page
    }

    $lblStep.Text = if ($script:ManagementMode) { "Service management" } else { "Step $($Page + 1) of 4" }
    $btnBack.Visible = -not $script:ManagementMode -and $Page -gt 0
    $btnNext.Visible = -not $script:ManagementMode -and $Page -lt 3
    $btnNext.Text = if ($Page -eq 0) { "Prepare >" } else { "Next >" }
    $btnInstall.Visible = -not $script:ManagementMode -and $Page -eq 3
    $btnManage.Text = if ($script:ManagementMode) { "Return to setup" } else { "Manage service" }

    if ($Page -eq 3) {
        $script:LogTarget = $txtOutput
        Update-WizardReview
        Update-WizardServiceStatus
    }

    Set-WizardBusy $script:Busy
}

function Start-WizardScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory = $true)][scriptblock]$OnComplete
    )

    if ($script:Busy) {
        return
    }

    $powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $allArguments = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath) + $Arguments

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $powershell
    $startInfo.Arguments = ($allArguments | ForEach-Object { Quote-WizardArgument $_ }) -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.WorkingDirectory = $PSScriptRoot

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Could not start PowerShell."
    }

    $script:ActiveCommand = [pscustomobject]@{
        Process = $process
        StandardOutput = $process.StandardOutput.ReadToEndAsync()
        StandardError = $process.StandardError.ReadToEndAsync()
        OnComplete = $OnComplete
    }

    Set-WizardBusy $true
    $commandTimer.Start()
}

function Invoke-WizardServiceAction {
    param([ValidateSet("Start", "Stop", "Restart")][string]$Action)

    try {
        switch ($Action) {
            "Start" { Start-Service -Name $script:ServiceName }
            "Stop" { Stop-Service -Name $script:ServiceName }
            "Restart" { Restart-Service -Name $script:ServiceName }
        }
        Add-WizardLog "$Action command completed."
    }
    catch {
        [Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "Copyparty service",
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        Update-WizardServiceStatus
    }
}

$form = [Windows.Forms.Form]::new()
$form.Text = "Copyparty Windows Service Wizard"
$form.StartPosition = "CenterScreen"
$form.ClientSize = [Drawing.Size]::new(820, 620)
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.Font = [Drawing.Font]::new("Segoe UI", 9)

$lblTitle = New-WizardLabel "Copyparty Windows Service" 24 16 600 32
$lblTitle.Font = [Drawing.Font]::new("Segoe UI Semibold", 18)
$form.Controls.Add($lblTitle)

$lblStep = New-WizardLabel "Step 1 of 4" 610 25 180 24
$lblStep.TextAlign = "MiddleRight"
$lblStep.ForeColor = [Drawing.Color]::DimGray
$form.Controls.Add($lblStep)

$content = [Windows.Forms.Panel]::new()
$content.Location = [Drawing.Point]::new(24, 62)
$content.Size = [Drawing.Size]::new(772, 474)
$content.BorderStyle = "FixedSingle"
$form.Controls.Add($content)

$pagePython = [Windows.Forms.Panel]::new()
$pagePython.Dock = "Fill"
$content.Controls.Add($pagePython)

$pagePython.Controls.Add((New-WizardLabel "Prepare the Python environment" 20 18 700 30))
$pagePython.Controls[$pagePython.Controls.Count - 1].Font = [Drawing.Font]::new("Segoe UI Semibold", 13)

$pagePython.Controls.Add((New-WizardLabel "Base Python executable" 20 66))
$txtBasePython = [Windows.Forms.TextBox]::new()
$txtBasePython.Location = [Drawing.Point]::new(20, 92)
$txtBasePython.Size = [Drawing.Size]::new(620, 26)
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
$txtBasePython.Text = if ($pythonCommand) { $pythonCommand.Source } else { "" }
$pagePython.Controls.Add($txtBasePython)
$btnBrowseBasePython = [Windows.Forms.Button]::new()
$btnBrowseBasePython.Text = "Browse..."
$btnBrowseBasePython.Location = [Drawing.Point]::new(650, 90)
$btnBrowseBasePython.Size = [Drawing.Size]::new(90, 29)
$pagePython.Controls.Add($btnBrowseBasePython)

$pagePython.Controls.Add((New-WizardLabel "Virtual environment directory" 20 136))
$txtVenv = [Windows.Forms.TextBox]::new()
$txtVenv.Location = [Drawing.Point]::new(20, 162)
$txtVenv.Size = [Drawing.Size]::new(620, 26)
$txtVenv.Text = "C:\copyparty\venv"
$pagePython.Controls.Add($txtVenv)
$btnBrowseVenv = [Windows.Forms.Button]::new()
$btnBrowseVenv.Text = "Browse..."
$btnBrowseVenv.Location = [Drawing.Point]::new(650, 160)
$btnBrowseVenv.Size = [Drawing.Size]::new(90, 29)
$pagePython.Controls.Add($btnBrowseVenv)

$lblSource = New-WizardLabel "Copyparty package: complete published release from PyPI" 20 206 720 42
$lblSource.ForeColor = [Drawing.Color]::DimGray
$pagePython.Controls.Add($lblSource)

$txtSetupOutput = [Windows.Forms.RichTextBox]::new()
$txtSetupOutput.Location = [Drawing.Point]::new(20, 254)
$txtSetupOutput.Size = [Drawing.Size]::new(720, 176)
$txtSetupOutput.ReadOnly = $true
$txtSetupOutput.BackColor = [Drawing.Color]::FromArgb(30, 30, 30)
$txtSetupOutput.ForeColor = [Drawing.Color]::Gainsboro
$txtSetupOutput.Font = [Drawing.Font]::new("Consolas", 9)
$pagePython.Controls.Add($txtSetupOutput)

$pageFiles = [Windows.Forms.Panel]::new()
$pageFiles.Dock = "Fill"
$pageFiles.Visible = $false
$content.Controls.Add($pageFiles)

$pageFiles.Controls.Add((New-WizardLabel "Configure Copyparty" 20 18 700 30))
$pageFiles.Controls[$pageFiles.Controls.Count - 1].Font = [Drawing.Font]::new("Segoe UI Semibold", 13)

$txtPython = [Windows.Forms.TextBox]::new()
$txtPython.Text = "C:\copyparty\venv\Scripts\python.exe"
$txtConfig = [Windows.Forms.TextBox]::new()
$txtConfig.Text = "C:\copyparty\party.conf"

$pageFiles.Controls.Add((New-WizardLabel "Web port" 20 66 200 24))
$numPort = [Windows.Forms.NumericUpDown]::new()
$numPort.Location = [Drawing.Point]::new(230, 62)
$numPort.Size = [Drawing.Size]::new(130, 26)
$numPort.Minimum = 1
$numPort.Maximum = 65535
$numPort.Value = 3923
$pageFiles.Controls.Add($numPort)

$chkLan = [Windows.Forms.CheckBox]::new()
$chkLan.Text = "Allow access from devices on the Private LAN"
$chkLan.Location = [Drawing.Point]::new(390, 60)
$chkLan.Size = [Drawing.Size]::new(350, 30)
$chkLan.Checked = $true
$pageFiles.Controls.Add($chkLan)

$pageFiles.Controls.Add((New-WizardLabel "Shared directory" 20 104))
$txtSharedPath = [Windows.Forms.TextBox]::new()
$txtSharedPath.Location = [Drawing.Point]::new(20, 130)
$txtSharedPath.Size = [Drawing.Size]::new(620, 26)
$txtSharedPath.Text = "C:\copyparty\data"
$pageFiles.Controls.Add($txtSharedPath)
$btnBrowseShared = [Windows.Forms.Button]::new()
$btnBrowseShared.Text = "Browse..."
$btnBrowseShared.Location = [Drawing.Point]::new(650, 128)
$btnBrowseShared.Size = [Drawing.Size]::new(90, 29)
$pageFiles.Controls.Add($btnBrowseShared)

$pageFiles.Controls.Add((New-WizardLabel "Administrator username" 20 174 300 24))
$txtUsername = [Windows.Forms.TextBox]::new()
$txtUsername.Location = [Drawing.Point]::new(20, 200)
$txtUsername.Size = [Drawing.Size]::new(330, 26)
$txtUsername.Text = "admin"
$pageFiles.Controls.Add($txtUsername)

$pageFiles.Controls.Add((New-WizardLabel "Administrator password" 20 238 330 24))
$txtPassword = [Windows.Forms.TextBox]::new()
$txtPassword.Location = [Drawing.Point]::new(20, 264)
$txtPassword.Size = [Drawing.Size]::new(330, 26)
$txtPassword.UseSystemPasswordChar = $true
$pageFiles.Controls.Add($txtPassword)

$pageFiles.Controls.Add((New-WizardLabel "Confirm password" 390 238 330 24))
$txtConfirmPassword = [Windows.Forms.TextBox]::new()
$txtConfirmPassword.Location = [Drawing.Point]::new(390, 264)
$txtConfirmPassword.Size = [Drawing.Size]::new(350, 26)
$txtConfirmPassword.UseSystemPasswordChar = $true
$pageFiles.Controls.Add($txtConfirmPassword)

$pageFiles.Controls.Add((New-WizardLabel "WinSW executable" 20 304))
$txtWinSW = [Windows.Forms.TextBox]::new()
$txtWinSW.Location = [Drawing.Point]::new(20, 330)
$txtWinSW.Size = [Drawing.Size]::new(620, 26)
$txtWinSW.Text = "C:\copyparty\WinSW-x64.exe"
$pageFiles.Controls.Add($txtWinSW)
$btnBrowseWinSW = [Windows.Forms.Button]::new()
$btnBrowseWinSW.Text = "Browse..."
$btnBrowseWinSW.Location = [Drawing.Point]::new(650, 328)
$btnBrowseWinSW.Size = [Drawing.Size]::new(90, 29)
$pageFiles.Controls.Add($btnBrowseWinSW)

$lblFilesHelp = New-WizardLabel "The wizard writes C:\copyparty\party.conf with authenticated administrator access to the shared directory. Existing configuration is backed up as party.conf.bak." 20 378 720 54
$lblFilesHelp.ForeColor = [Drawing.Color]::DimGray
$pageFiles.Controls.Add($lblFilesHelp)

$pageSettings = [Windows.Forms.Panel]::new()
$pageSettings.Dock = "Fill"
$pageSettings.Visible = $false
$content.Controls.Add($pageSettings)

$pageSettings.Controls.Add((New-WizardLabel "Configure the service" 20 18 700 30))
$pageSettings.Controls[$pageSettings.Controls.Count - 1].Font = [Drawing.Font]::new("Segoe UI Semibold", 13)

$pageSettings.Controls.Add((New-WizardLabel "Startup type" 20 76 220 24))
$cmbStartup = [Windows.Forms.ComboBox]::new()
$cmbStartup.DropDownStyle = "DropDownList"
$cmbStartup.Location = [Drawing.Point]::new(250, 72)
$cmbStartup.Size = [Drawing.Size]::new(260, 28)
[void]$cmbStartup.Items.AddRange(@("Automatic", "AutomaticDelayedStart", "Manual"))
$cmbStartup.SelectedItem = "Automatic"
$pageSettings.Controls.Add($cmbStartup)

$pageSettings.Controls.Add((New-WizardLabel "Service account" 20 132 220 24))
$cmbAccount = [Windows.Forms.ComboBox]::new()
$cmbAccount.DropDownStyle = "DropDownList"
$cmbAccount.Location = [Drawing.Point]::new(250, 128)
$cmbAccount.Size = [Drawing.Size]::new(260, 28)
[void]$cmbAccount.Items.AddRange(@("LocalService", "NetworkService", "LocalSystem"))
$cmbAccount.SelectedItem = "LocalService"
$pageSettings.Controls.Add($cmbAccount)

$pageSettings.Controls.Add((New-WizardLabel "Health URL" 20 188 220 24))
$txtHealth = [Windows.Forms.TextBox]::new()
$txtHealth.Location = [Drawing.Point]::new(250, 184)
$txtHealth.Size = [Drawing.Size]::new(360, 26)
$txtHealth.Text = "http://127.0.0.1:3923/"
$pageSettings.Controls.Add($txtHealth)

$chkForce = [Windows.Forms.CheckBox]::new()
$chkForce.Text = "Replace the existing Copyparty service"
$chkForce.Location = [Drawing.Point]::new(250, 242)
$chkForce.Size = [Drawing.Size]::new(350, 28)
$pageSettings.Controls.Add($chkForce)

$lblSettingsHelp = New-WizardLabel "Automatic startup and LocalService are the recommended settings. Select replacement when reinstalling or updating the existing service." 20 306 720 52
$lblSettingsHelp.ForeColor = [Drawing.Color]::DimGray
$pageSettings.Controls.Add($lblSettingsHelp)

$pageFinish = [Windows.Forms.Panel]::new()
$pageFinish.Dock = "Fill"
$pageFinish.Visible = $false
$content.Controls.Add($pageFinish)

$pageFinish.Controls.Add((New-WizardLabel "Review and manage" 20 12 700 30))
$pageFinish.Controls[$pageFinish.Controls.Count - 1].Font = [Drawing.Font]::new("Segoe UI Semibold", 13)

$txtReview = [Windows.Forms.TextBox]::new()
$txtReview.Location = [Drawing.Point]::new(20, 48)
$txtReview.Size = [Drawing.Size]::new(720, 130)
$txtReview.Multiline = $true
$txtReview.ReadOnly = $true
$txtReview.BackColor = [Drawing.Color]::White
$txtReview.Font = [Drawing.Font]::new("Consolas", 9)
$pageFinish.Controls.Add($txtReview)

$lblStatus = New-WizardLabel "Service status:" 20 192 110 28
$lblStatus.Font = [Drawing.Font]::new("Segoe UI Semibold", 9)
$pageFinish.Controls.Add($lblStatus)
$lblStatusValue = New-WizardLabel "Not installed" 132 192 130 28
$pageFinish.Controls.Add($lblStatusValue)

$btnRefresh = [Windows.Forms.Button]::new()
$btnRefresh.Text = "Refresh"
$btnRefresh.Location = [Drawing.Point]::new(270, 188)
$btnRefresh.Size = [Drawing.Size]::new(82, 30)
$pageFinish.Controls.Add($btnRefresh)

$btnStart = [Windows.Forms.Button]::new()
$btnStart.Text = "Start"
$btnStart.Location = [Drawing.Point]::new(368, 188)
$btnStart.Size = [Drawing.Size]::new(82, 30)
$btnStart.Tag = $false
$pageFinish.Controls.Add($btnStart)

$btnStop = [Windows.Forms.Button]::new()
$btnStop.Text = "Stop"
$btnStop.Location = [Drawing.Point]::new(456, 188)
$btnStop.Size = [Drawing.Size]::new(82, 30)
$btnStop.Tag = $false
$pageFinish.Controls.Add($btnStop)

$btnRestart = [Windows.Forms.Button]::new()
$btnRestart.Text = "Restart"
$btnRestart.Location = [Drawing.Point]::new(544, 188)
$btnRestart.Size = [Drawing.Size]::new(82, 30)
$btnRestart.Tag = $false
$pageFinish.Controls.Add($btnRestart)

$btnUninstall = [Windows.Forms.Button]::new()
$btnUninstall.Text = "Uninstall"
$btnUninstall.Location = [Drawing.Point]::new(632, 188)
$btnUninstall.Size = [Drawing.Size]::new(108, 30)
$btnUninstall.Tag = $false
$pageFinish.Controls.Add($btnUninstall)

$txtOutput = [Windows.Forms.RichTextBox]::new()
$txtOutput.Location = [Drawing.Point]::new(20, 234)
$txtOutput.Size = [Drawing.Size]::new(720, 205)
$txtOutput.ReadOnly = $true
$txtOutput.BackColor = [Drawing.Color]::FromArgb(30, 30, 30)
$txtOutput.ForeColor = [Drawing.Color]::Gainsboro
$txtOutput.Font = [Drawing.Font]::new("Consolas", 9)
$pageFinish.Controls.Add($txtOutput)

$btnBack = [Windows.Forms.Button]::new()
$btnBack.Text = "< Back"
$btnBack.Location = [Drawing.Point]::new(530, 556)
$btnBack.Size = [Drawing.Size]::new(82, 34)
$form.Controls.Add($btnBack)

$btnNext = [Windows.Forms.Button]::new()
$btnNext.Text = "Next >"
$btnNext.Location = [Drawing.Point]::new(620, 556)
$btnNext.Size = [Drawing.Size]::new(82, 34)
$form.Controls.Add($btnNext)

$btnInstall = [Windows.Forms.Button]::new()
$btnInstall.Text = "Install"
$btnInstall.Location = [Drawing.Point]::new(620, 556)
$btnInstall.Size = [Drawing.Size]::new(82, 34)
$btnInstall.Visible = $false
$form.Controls.Add($btnInstall)

$btnClose = [Windows.Forms.Button]::new()
$btnClose.Text = "Close"
$btnClose.Location = [Drawing.Point]::new(710, 556)
$btnClose.Size = [Drawing.Size]::new(82, 34)
$form.Controls.Add($btnClose)

$btnManage = [Windows.Forms.Button]::new()
$btnManage.Text = "Manage service"
$btnManage.Location = [Drawing.Point]::new(24, 556)
$btnManage.Size = [Drawing.Size]::new(120, 34)
$form.Controls.Add($btnManage)

$script:Pages = @($pagePython, $pageFiles, $pageSettings, $pageFinish)

$commandTimer = [Windows.Forms.Timer]::new()
$commandTimer.Interval = 250
$commandTimer.Add_Tick({
    if (-not $script:ActiveCommand -or -not $script:ActiveCommand.Process.HasExited) {
        return
    }

    $commandTimer.Stop()
    $active = $script:ActiveCommand
    $script:ActiveCommand = $null
    $exitCode = $active.Process.ExitCode
    $standardOutput = $active.StandardOutput.Result
    $standardError = $active.StandardError.Result
    $active.Process.Dispose()

    Add-WizardLog $standardOutput
    Add-WizardLog $standardError
    Set-WizardBusy $false
    Update-WizardServiceStatus
    & $active.OnComplete $exitCode
})

$btnBrowseBasePython.Add_Click({
    Select-WizardFile $txtBasePython "Select base Python executable" "Python executable (python.exe)|python.exe|Executable files (*.exe)|*.exe"
})
$btnBrowseVenv.Add_Click({
    Select-WizardFolder $txtVenv "Select the directory for the Copyparty Python environment"
})
$btnBrowseShared.Add_Click({
    Select-WizardFolder $txtSharedPath "Select the directory Copyparty will share"
})
$btnBrowseWinSW.Add_Click({
    Select-WizardFile $txtWinSW "Select WinSW executable" "WinSW executable (*.exe)|*.exe"
})

$invalidatePythonSetup = {
    $script:PythonPrepared = $false
    $script:ConfigurationPrepared = $false
    $txtPython.Text = ""
    if (-not $script:Busy) {
        Set-WizardBusy $false
    }
}
$txtBasePython.Add_TextChanged($invalidatePythonSetup)
$txtVenv.Add_TextChanged($invalidatePythonSetup)

$invalidateConfiguration = {
    $script:ConfigurationPrepared = $false
    if (-not $script:Busy) {
        Set-WizardBusy $false
    }
}
$numPort.Add_ValueChanged($invalidateConfiguration)
$txtSharedPath.Add_TextChanged($invalidateConfiguration)
$txtUsername.Add_TextChanged($invalidateConfiguration)
$txtPassword.Add_TextChanged($invalidateConfiguration)
$txtConfirmPassword.Add_TextChanged($invalidateConfiguration)
$chkLan.Add_CheckedChanged($invalidateConfiguration)

$btnBack.Add_Click({
    if (-not $script:Busy -and -not $script:ManagementMode -and $script:CurrentPage -gt 0) {
        Set-WizardPage ($script:CurrentPage - 1)
    }
})

$btnNext.Add_Click({
    if ($script:ManagementMode -or $script:Busy) {
        return
    }

    if ($script:CurrentPage -eq 0) {
        $errorMessage = Get-PythonSetupValidationError
        if ($errorMessage) {
            [Windows.Forms.MessageBox]::Show(
                $errorMessage,
                "Check Python setup",
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }

        $txtSetupOutput.Clear()
        $script:PythonPrepared = $false
        $script:ConfigurationPrepared = $false
        $script:LogTarget = $txtSetupOutput
        Add-WizardLog "Preparing the Copyparty Python environment..."
        $script:ServiceWasRunningBeforeSetup = $false
        try {
            $existingService = Get-Service -Name $script:ServiceName -ErrorAction SilentlyContinue
            if ($existingService -and $existingService.Status -ne "Stopped") {
                Add-WizardLog "Stopping the Copyparty service while its Python environment is updated..."
                Stop-Service -Name $script:ServiceName
                $existingService.WaitForStatus(
                    [ServiceProcess.ServiceControllerStatus]::Stopped,
                    [TimeSpan]::FromSeconds(30)
                )
                $script:ServiceWasRunningBeforeSetup = $true
            }
        }
        catch {
            [Windows.Forms.MessageBox]::Show(
                "Could not stop the existing Copyparty service: $($_.Exception.Message)",
                "Python setup blocked",
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return
        }

        Start-WizardScript `
            -ScriptPath (Join-Path $PSScriptRoot "setup-python-env.ps1") `
            -Arguments @(
                "-BasePythonPath", $txtBasePython.Text
                "-VenvPath", $txtVenv.Text
            ) `
            -OnComplete {
                param($ExitCode)
                if ($script:ServiceWasRunningBeforeSetup) {
                    try {
                        Start-Service -Name $script:ServiceName
                        Add-WizardLog "Restarted the Copyparty service after the environment update."
                    }
                    catch {
                        Add-WizardLog "Could not restart the existing service: $($_.Exception.Message)"
                    }
                    $script:ServiceWasRunningBeforeSetup = $false
                }
                if ($ExitCode -eq 0) {
                    $txtPython.Text = Join-Path ([IO.Path]::GetFullPath($txtVenv.Text)) "Scripts\python.exe"
                    $script:PythonPrepared = $true
                    $script:ConfigurationPrepared = $false
                    Set-WizardPage 1
                }
                else {
                    [Windows.Forms.MessageBox]::Show(
                        "Python environment setup failed. Review the output in the wizard.",
                        "Python setup failed",
                        [Windows.Forms.MessageBoxButtons]::OK,
                        [Windows.Forms.MessageBoxIcon]::Error
                    ) | Out-Null
                }
            }
        return
    }
    elseif ($script:CurrentPage -eq 1) {
        if (-not $script:PythonPrepared) {
            Set-WizardPage 0
            return
        }
        $errorMessage = Get-InstallInputsValidationError
        if ($errorMessage) {
            [Windows.Forms.MessageBox]::Show(
                $errorMessage,
                "Check installation files",
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }

        try {
            $script:ConfigurationPrepared = $false
            New-CopypartyConfiguration `
                -ConfigPath $txtConfig.Text `
                -Port ([int]$numPort.Value) `
                -SharedPath $txtSharedPath.Text `
                -Username $txtUsername.Text `
                -Password $txtPassword.Text `
                -AllowLan $chkLan.Checked
            Protect-CopypartyConfigurationFile `
                -Path $txtConfig.Text `
                -ServiceIdentity (Get-CopypartyServiceAccountIdentity "LocalService")
            $script:ConfigurationPrepared = $true
        }
        catch {
            [Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                "Could not write Copyparty configuration",
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return
        }
    }
    elseif ($script:CurrentPage -eq 2) {
        if (-not $script:PythonPrepared -or -not $script:ConfigurationPrepared) {
            Set-WizardPage 0
            return
        }
        $errorMessage = Get-WizardValidationError
        if ($errorMessage) {
            [Windows.Forms.MessageBox]::Show(
                $errorMessage,
                "Check service settings",
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }
    }

    Set-WizardPage ($script:CurrentPage + 1)
})

$btnManage.Add_Click({
    if ($script:ManagementMode) {
        $script:ManagementMode = $false
        Set-WizardPage $script:InstallPageBeforeManagement
    }
    else {
        $script:InstallPageBeforeManagement = $script:CurrentPage
        $script:ManagementMode = $true
        Set-WizardPage 3
    }
})

$btnInstall.Add_Click({
    if (-not (Test-WizardInstallReady)) {
        [Windows.Forms.MessageBox]::Show(
            "Complete the Python, Copyparty configuration, and service-settings steps before installing.",
            "Installation steps incomplete",
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        Set-WizardPage 0
        return
    }

    $errorMessage = Get-WizardValidationError
    if ($errorMessage) {
        [Windows.Forms.MessageBox]::Show(
            $errorMessage,
            "Cannot install",
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }

    $txtOutput.Clear()
    $script:LogTarget = $txtOutput
    Add-WizardLog "Installing Copyparty service..."
    $arguments = @(
        "-RuntimeMode", "PythonModule"
        "-ExecutablePath", $txtPython.Text
        "-ConfigPath", $txtConfig.Text
        "-WinSWPath", $txtWinSW.Text
        "-StartupType", [string]$cmbStartup.SelectedItem
        "-ServiceAccount", [string]$cmbAccount.SelectedItem
        "-HealthUrl", $txtHealth.Text
    )
    if ($chkForce.Checked) {
        $arguments += "-Force"
    }
    if ($chkLan.Checked) {
        $arguments += @("-EnableLan", "-LanPort", [string][int]$numPort.Value)
    }

    Start-WizardScript `
        -ScriptPath (Join-Path $PSScriptRoot "install-service.ps1") `
        -Arguments $arguments `
        -OnComplete {
            param($ExitCode)
            if ($ExitCode -eq 0) {
                $lanDetails = if ($chkLan.Checked) {
                    "`n`nLAN addresses:`n" + ((Get-WizardLanUrls) -join "`n")
                }
                else {
                    ""
                }
                $txtPassword.Clear()
                $txtConfirmPassword.Clear()
                $script:ConfigurationPrepared = $false
                $script:InstallPageBeforeManagement = 0
                $script:ManagementMode = $true
                Set-WizardPage 3
                [Windows.Forms.MessageBox]::Show(
                    "Copyparty was installed successfully.$lanDetails",
                    "Installation complete",
                    [Windows.Forms.MessageBoxButtons]::OK,
                    [Windows.Forms.MessageBoxIcon]::Information
                ) | Out-Null
            }
            else {
                [Windows.Forms.MessageBox]::Show(
                    "Installation failed. Review the output in the wizard.",
                    "Installation failed",
                    [Windows.Forms.MessageBoxButtons]::OK,
                    [Windows.Forms.MessageBoxIcon]::Error
                ) | Out-Null
            }
        }
})

$btnRefresh.Add_Click({ Update-WizardServiceStatus })
$btnStart.Add_Click({ Invoke-WizardServiceAction "Start" })
$btnStop.Add_Click({ Invoke-WizardServiceAction "Stop" })
$btnRestart.Add_Click({ Invoke-WizardServiceAction "Restart" })

$btnUninstall.Add_Click({
    $answer = [Windows.Forms.MessageBox]::Show(
        "Remove the Copyparty Windows service? Configuration, logs, and shared data will be preserved.",
        "Uninstall Copyparty service",
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
        return
    }

    $script:LogTarget = $txtOutput
    Add-WizardLog "Uninstalling Copyparty service..."
    Start-WizardScript `
        -ScriptPath (Join-Path $PSScriptRoot "uninstall-service.ps1") `
        -Arguments @() `
        -OnComplete {
            param($ExitCode)
            if ($ExitCode -eq 0) {
                [Windows.Forms.MessageBox]::Show(
                    "The Copyparty service was removed. Files and data were preserved.",
                    "Uninstallation complete",
                    [Windows.Forms.MessageBoxButtons]::OK,
                    [Windows.Forms.MessageBoxIcon]::Information
                ) | Out-Null
            }
            else {
                [Windows.Forms.MessageBox]::Show(
                    "Uninstallation failed. Review the output in the wizard.",
                    "Uninstallation failed",
                    [Windows.Forms.MessageBoxButtons]::OK,
                    [Windows.Forms.MessageBoxIcon]::Error
                ) | Out-Null
            }
        }
})

$btnClose.Add_Click({
    if (-not $script:Busy) {
        $form.Close()
    }
})

$form.Add_FormClosing({
    param($Sender, $EventArgs)
    if ($script:Busy) {
        $EventArgs.Cancel = $true
        [Windows.Forms.MessageBox]::Show(
            "Wait for the current service operation to finish.",
            "Operation in progress",
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
})

Set-WizardPage 0
[void]$form.ShowDialog()
$commandTimer.Dispose()
$form.Dispose()
