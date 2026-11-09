$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'artifacts/scripts/inspect-sql-connectivity.ps1'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$errors)
if ($errors) { throw ($errors.Message -join "`n") }
$commands = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)
foreach ($command in $commands) {
    if ($command.GetCommandName() -match '^(Set|Start|Stop|Restart|Remove|Install|Uninstall|Enable|Disable|Add|Clear|Reset)-') {
        throw "The SQL connectivity diagnostic must remain read-only: $($command.GetCommandName())"
    }
}
$source = Get-Content -LiteralPath $sourcePath -Raw
if ($source -notmatch 'Pooling=false' -or $source -notmatch 'EncryptedLoopbackSql' -or
    $source -notmatch 'SQL_GUEST_DIAGNOSTICS_COMPLETED') {
    throw 'Require fresh physical host connections, an encrypted loopback comparison and explicit completion.'
}
$bicep = Get-Content (Join-Path $root 'infra/stages/sql-connectivity-check/main.bicep') -Raw
if ($bicep -notmatch '@secure\(\)\s+param nestedWindowsPassword' -or
    $bicep -notmatch 'protectedScriptParameters:' -or $bicep -match 'asyncExecution:\s*true') {
    throw 'Guest credentials must remain protected and the diagnostic must finish synchronously.'
}
$wrapper = Join-Path $PSScriptRoot 'inspect-sql-connectivity.ps1'
[void][Management.Automation.Language.Parser]::ParseFile($wrapper, [ref]$null, [ref]$errors)
if ($errors) { throw ($errors.Message -join "`n") }
Write-Host 'Read-only SQL connectivity diagnostic checks passed.'
