$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-runtime.ps1')

try {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw 'PowerShell 7 or newer is required.'
    }
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Write-Host 'Building Bicep templates...'
    foreach ($template in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'infra/stages') `
            -Filter main.bicep -Recurse) {
        Write-Host "  $($template.FullName)"
        [void](Invoke-LabAz @('bicep', 'build', '--file', $template.FullName, '--stdout'))
    }
    Write-Host 'Parsing PowerShell scripts...'
    $files = @(
        Get-ChildItem -LiteralPath (Join-Path $repoRoot 'artifacts/scripts') -Filter '*.ps1'
        Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1'
    )
    foreach ($file in $files) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $file.FullName, [ref]$tokens, [ref]$errors)
        if ($errors.Count) {
            $errors | ForEach-Object {
                Write-Error "$($file.Name):$($_.Extent.StartLineNumber): $($_.Message)"
            }
            throw "PowerShell parsing failed: $($file.Name)."
        }
    }
    foreach ($test in @('test-powershell-runtime.ps1', 'test-host-ssms.ps1', 'test-stage-view.ps1',
        'test-lab-runtime.ps1', 'test-repository.ps1', 'test-check-sql-media.ps1',
        'test-stage20.ps1', 'test-stage40.ps1', 'test-stage45.ps1',
        'test-stage50.ps1', 'test-stage60.ps1')) {
        Write-Host "Running $test"
        & (Join-Path $PSScriptRoot $test)
        if (-not $?) { throw "$test failed." }
    }
    Write-Host 'Validation completed.'
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
