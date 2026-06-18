[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BasePythonPath,

    [Parameter(Mandatory = $true)]
    [string]$VenvPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$BasePythonPath = (Resolve-Path -LiteralPath $BasePythonPath).Path
$VenvPath = [IO.Path]::GetFullPath($VenvPath)
$venvPython = Join-Path $VenvPath "Scripts\python.exe"

if ($VenvPath.TrimEnd('\') -eq [IO.Path]::GetPathRoot($VenvPath).TrimEnd('\')) {
    throw "The virtual environment cannot be created at the root of a drive."
}

if ((Test-Path -LiteralPath $VenvPath -PathType Container) -and
    -not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    $existingItems = @(Get-ChildItem -LiteralPath $VenvPath -Force)
    if ($existingItems.Count -gt 0) {
        throw "The virtual environment directory is not empty and does not contain a Python environment: $VenvPath"
    }
}

function Invoke-CheckedPython {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    & $PythonPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage Exit code: $LASTEXITCODE."
    }
}

Write-Host "Base Python: $BasePythonPath"
Write-Host "Virtual environment: $VenvPath"

if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    $parent = Split-Path -Parent $VenvPath
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Write-Host "Creating Python virtual environment..."
    Invoke-CheckedPython `
        -PythonPath $BasePythonPath `
        -Arguments @("-m", "venv", $VenvPath) `
        -FailureMessage "Could not create the Python virtual environment."
}
else {
    Write-Host "Using the existing Python virtual environment."
}

Write-Host "Installing Python packaging tools..."
Invoke-CheckedPython `
    -PythonPath $venvPython `
    -Arguments @("-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel") `
    -FailureMessage "Could not install Python packaging tools. Check the internet connection."

Write-Host "Installing the complete published Copyparty package..."
Invoke-CheckedPython `
    -PythonPath $venvPython `
    -Arguments @("-m", "pip", "install", "--upgrade", "--force-reinstall", "copyparty") `
    -FailureMessage "Could not install Copyparty."

Write-Host "Verifying Copyparty and its browser dependencies..."
Push-Location $VenvPath
try {
    Invoke-CheckedPython `
        -PythonPath $venvPython `
        -Arguments @(
            "-c",
            "import pathlib, copyparty; p=pathlib.Path(copyparty.__file__).parent/'web'/'deps'/'marked.js.gz'; assert p.is_file(), 'missing browser dependency: '+str(p); print('Copyparty Python environment is ready.')"
        ) `
        -FailureMessage "Copyparty or its required browser dependencies are incomplete."
}
finally {
    Pop-Location
}

Write-Output $venvPython
