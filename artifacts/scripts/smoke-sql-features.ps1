[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$EngineScriptBase64,
    [ValidateSet('true', 'false')][string]$VerifyOnly = 'false',
    [Parameter(Mandatory)][string]$RunId
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($env:COMPUTERNAME -notin @('JS-RETAIL-01', 'JS-INSIGHT-01')) { throw 'Not an isolated BI smoke-test VM.' }
$work = 'C:\ArcJumpstart\Sql2025'
New-Item -ItemType Directory -Path $work -Force | Out-Null
$lock = [IO.File]::Open("$work\smoke.lock", 'OpenOrCreate', 'ReadWrite', 'None')
try {
    $installer = Join-Path $work '45-install-sql-engine.ps1'
    [IO.File]::WriteAllText($installer, [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EngineScriptBase64)))
    $iso = Join-Path $work 'SQLServer2025-x64-ENU-EntDev.iso'
    if ($VerifyOnly -eq 'false' -and -not (Test-Path $iso)) {
        $uri = 'https://download.microsoft.com/download/dea8c210-c44a-4a9d-9d80-0c81578860c5/ENU/SQLServer2025-x64-ENU-EntDev.iso'
        Write-Host "Downloading Microsoft media for $env:COMPUTERNAME."
        Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile "$iso.partial" -TimeoutSec 1800
        if ((Get-Item "$iso.partial").Length -ne 1265688576 -or
            (Get-FileHash "$iso.partial" -Algorithm SHA256).Hash -ine 'f78f869d44e8c2cbf93be16ce6ea52dd811636f046ded29e7a74dd1352134851') {
            throw 'Smoke media does not match the saved installer release.'
        }
        Move-Item "$iso.partial" $iso
    }
    $result = & $installer -IsoPath $iso -VerifyOnly:($VerifyOnly -eq 'true') -PassThru
    $result | ConvertTo-Json -Depth 6 | Write-Output
    if ($result.Status -eq 'RebootRequired') {
        Write-Output 'SMOKE_REBOOT_REQUIRED: Setup completed; reboot only this VM before rerunning.'
        exit 3010
    }
    if ($result.Status -notin @('InstalledAndVerified', 'VerifiedExisting')) { throw 'Installer did not verify its assigned features.' }
    Write-Output "SMOKE_VERIFIED: $env:COMPUTERNAME run=$RunId"
}
finally { $lock.Dispose() }
