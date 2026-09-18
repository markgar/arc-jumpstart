[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ArcResourceGroup,

    [Parameter(Mandatory)]
    [string]$ArcLocation,

    [Parameter(Mandatory)]
    [securestring]$DomainAdministratorPassword,

    [string[]]$VMNames = @('JS-DC-01', 'JS-SQL-01', 'JS-SQL-AG-01', 'JS-SQL-AG-02')
)

$ErrorActionPreference = 'Stop'
$credential = [pscredential]::new(
    'JUMPSTART\Administrator',
    $DomainAdministratorPassword
)

foreach ($vmName in $VMNames) {
    Write-Host "$([DateTime]::UtcNow.ToString('o')) Staging Azure Arc desktop launcher on $vmName."
    Invoke-Command -VMName $vmName -Credential $credential -ArgumentList @(
        $SubscriptionId,
        $ArcResourceGroup,
        $ArcLocation
    ) -ScriptBlock {
        param($TargetSubscriptionId, $TargetResourceGroup, $TargetLocation)

        $programRoot = 'C:\ProgramData\ArcJumpstart'
        $logRoot = Join-Path $programRoot 'Logs'
        $publicDesktop = Join-Path $env:PUBLIC 'Desktop'
        $launcherPath = Join-Path $programRoot 'Connect to Azure Arc.ps1'
        $desktopPath = Join-Path $publicDesktop 'Connect to Azure Arc.cmd'
        New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
        Remove-Item -LiteralPath (Join-Path $publicDesktop 'Connect to Azure Arc.ps1') -Force -ErrorAction SilentlyContinue

        $launcher = @'
$ErrorActionPreference = 'Stop'
$agent = Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent\azcmagent.exe'
$logRoot = 'C:\ProgramData\ArcJumpstart\Logs'
$logPath = Join-Path $logRoot ('Arc-Connect-' + $env:COMPUTERNAME + '-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '.log')

function Write-Evidence {
    param([string]$Message)
    $line = "$([DateTime]::UtcNow.ToString('o')) $Message"
    Write-Host $line
    Add-Content -LiteralPath $logPath -Value $line
}

try {
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    if (-not (Test-Path $agent)) {
        Write-Evidence 'Downloading the official Azure Connected Machine agent.'
        $msiPath = Join-Path $env:TEMP 'AzureConnectedMachineAgent.msi'
        $msiLog = Join-Path $logRoot ('Arc-Agent-Install-' + $env:COMPUTERNAME + '-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '.log')
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://aka.ms/AzureConnectedMachineAgent' -OutFile $msiPath
        $installer = Start-Process msiexec.exe -ArgumentList @('/i', $msiPath, '/qn', '/l*v', $msiLog) -Wait -PassThru
        if ($installer.ExitCode -notin 0, 3010) {
            throw "Connected Machine agent MSI exited with code $($installer.ExitCode). Installer log: $msiLog"
        }
        if (-not (Test-Path $agent)) {
            throw "The Azure Connected Machine agent is absent after installation. Installer log: $msiLog"
        }
        Write-Evidence "Azure Connected Machine agent installation completed with exit code $($installer.ExitCode)."
    }

    $current = & $agent show --json 2>$null | ConvertFrom-Json
    if ($current.status -eq 'Connected') {
        Write-Evidence "Azure Arc is already connected: agentVersion=$($current.agentVersion)."
        return
    }

    Write-Evidence 'Starting Azure Arc network check.'
    $checkOutput = & $agent check --location '__ARC_LOCATION__' 2>&1
    $checkExitCode = $LASTEXITCODE
    $checkOutput | Write-Host
    Add-Content -LiteralPath $logPath -Value ($checkOutput -join [Environment]::NewLine)
    if ($checkExitCode -ne 0) {
        throw "azcmagent check exited with code $checkExitCode."
    }

    Write-Evidence 'Network check passed. Starting interactive device-code connection.'
    Write-Host 'Complete the displayed device login on your own computer.'
    Write-Host 'The device code is intentionally not written to the evidence log.'
    & $agent connect --subscription-id '__SUBSCRIPTION_ID__' --resource-group '__ARC_RESOURCE_GROUP__' --location '__ARC_LOCATION__' --use-device-code
    if ($LASTEXITCODE -ne 0) {
        throw "azcmagent connect exited with code $LASTEXITCODE."
    }

    $show = & $agent show --json | ConvertFrom-Json
    if ($show.status -ne 'Connected') {
        throw "Connection command returned, but azcmagent status is $($show.status)."
    }
    Write-Evidence "Azure Arc connection verified: status=$($show.status), agentVersion=$($show.agentVersion)."
}
catch {
    Write-Evidence "FAILED: $($_.Exception.Message)"
    Write-Error $_
}
finally {
    Write-Host "Evidence log: $logPath"
    Read-Host 'Press Enter to close'
}
'@

        $launcher = $launcher.
            Replace('__SUBSCRIPTION_ID__', $TargetSubscriptionId).
            Replace('__ARC_RESOURCE_GROUP__', $TargetResourceGroup).
            Replace('__ARC_LOCATION__', $TargetLocation)
        Set-Content -LiteralPath $launcherPath -Value $launcher -Encoding UTF8

        $escapedLauncherPath = $launcherPath.Replace('"', '""')
        $command = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File ""$escapedLauncherPath""'"
"@
        Set-Content -LiteralPath $desktopPath -Value $command -Encoding ASCII

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            DesktopLauncher = $desktopPath
            EvidenceDirectory = $logRoot
            ArcAgentInstalled = Test-Path (Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent\azcmagent.exe')
        }
    }
}
