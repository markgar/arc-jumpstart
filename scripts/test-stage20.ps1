$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$path = Join-Path $PSScriptRoot '../artifacts/scripts/20-host-network.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }

$definition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Enable-HyperVEnhancedSessionMode'
}, $true)
if (-not $definition) {
    throw 'Stage 20 must define Enable-HyperVEnhancedSessionMode.'
}
. ([scriptblock]::Create($definition.Extent.Text))

& {
    $script:enabled = $false
    function Set-VMHost {
        param($EnableEnhancedSessionMode)
        $script:enabled = $EnableEnhancedSessionMode
    }
    function Get-VMHost {
        [pscustomobject]@{ EnableEnhancedSessionMode = $script:enabled }
    }

    Enable-HyperVEnhancedSessionMode
    if (-not $script:enabled) {
        throw 'Stage 20 did not enable the Hyper-V Enhanced Session Mode policy.'
    }
}

Write-Host 'Stage 20 Enhanced Session Mode regression checks passed.'
