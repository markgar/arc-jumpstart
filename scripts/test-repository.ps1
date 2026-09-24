$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Assert-Contains {
    param([string]$Text, [string]$Expected, [string]$Context)
    if (-not $Text.Contains($Expected)) {
        throw "$Context is missing expected text: $Expected"
    }
}

function Assert-NotContains {
    param([string]$Text, [string]$Forbidden, [string]$Context)
    if ($Text.Contains($Forbidden)) {
        throw "$Context contains forbidden text: $Forbidden"
    }
}

$documents = @(
    'README.md', 'AGENTS.md', 'infra/README.md', 'scripts/README.md',
    'skills/arc-jumpstart/SKILL.md'
) + @(Get-ChildItem -LiteralPath (Join-Path $root 'docs') -Filter '*.md' |
    ForEach-Object { "docs/$($_.Name)" })
foreach ($relative in $documents) {
    $path = Join-Path $root $relative
    $text = [System.IO.File]::ReadAllText($path)
    foreach ($match in [regex]::Matches($text, '!?\[[^\]]*\]\(([^)]+)\)')) {
        $target = ($match.Groups[1].Value.Trim() -split '\s+', 2)[0].Trim('<', '>')
        if ($target -match '^(#|https?://|mailto:)') { continue }
        $linkedPath = [uri]::UnescapeDataString(($target -split '#', 2)[0])
        if ($linkedPath -and -not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $path) $linkedPath))) {
            throw "Broken documentation link: $relative -> $target"
        }
    }
}

$readme = [System.IO.File]::ReadAllText((Join-Path $root 'README.md'))
$readmeLines = $readme -split '\r?\n'
if ($readmeLines[0] -ne '# Arc Jumpstart v2' -or
    $readmeLines[2] -ne '**Clone this repo and ask your agent: "Help me use this to make an Arc environment."**') {
    throw 'README opening guidance changed unexpectedly.'
}
foreach ($expected in @('without further', 'stops before adding the servers to Azure Arc',
    'SQL Server extension should then deploy automatically', 'Standard_E16s_v7',
    'westus2', 'SQL Server 2025 Enterprise Developer')) {
    Assert-Contains $readme $expected 'README.md'
}
foreach ($forbidden in @('lab.local.env', 'imageSourceUrl', 'Hyper-V replication')) {
    Assert-NotContains $readme $forbidden 'README.md'
}
foreach ($relative in @('README.md', 'AGENTS.md', 'docs/00-agent-bootstrap.md',
    'docs/01-prerequisites.md', 'docs/02-deploy.md', 'scripts/README.md',
    'skills/arc-jumpstart/SKILL.md')) {
    $text = [System.IO.File]::ReadAllText((Join-Path $root $relative))
    Assert-Contains $text 'ArcJumpstart/<root>.env' $relative
    Assert-NotContains $text '.config/arc-jumpstart' $relative
}
foreach ($relative in @('README.md', 'AGENTS.md', 'docs/00-agent-bootstrap.md',
    'docs/01-prerequisites.md', 'scripts/README.md', 'skills/arc-jumpstart/SKILL.md')) {
    $text = [System.IO.File]::ReadAllText((Join-Path $root $relative))
    foreach ($expected in @('PowerShell 7', 'Azure CLI', 'deploy.ps1')) {
        Assert-Contains $text $expected $relative
    }
}
foreach ($relative in @('AGENTS.md', 'docs/00-agent-bootstrap.md',
    'skills/arc-jumpstart/SKILL.md')) {
    $text = [System.IO.File]::ReadAllText((Join-Path $root $relative))
    foreach ($expected in @('actual full', 'user-facing', 'Finder', 'TextEdit',
        'File Explorer', 'Notepad', 'execution host')) {
        Assert-Contains $text $expected $relative
    }
}
$bootstrap = [System.IO.File]::ReadAllText((Join-Path $root 'docs/00-agent-bootstrap.md'))
Assert-Contains $bootstrap 'Verify that this file still exists' 'bootstrap'
Assert-Contains $bootstrap 'must not be shared or committed' 'bootstrap'
Assert-Contains ([System.IO.File]::ReadAllText((Join-Path $root 'docs/04-assessment.md'))) `
    'arc-sql-modeling-inventory.kql' 'assessment'
Assert-Contains ([System.IO.File]::ReadAllText((Join-Path $root 'docs/05-migration.md'))) `
    'JumpstartStandaloneDB' 'migration'

$skill = [System.IO.File]::ReadAllText((Join-Path $root 'skills/arc-jumpstart/SKILL.md')).Replace("`r`n", "`n")
if (-not $skill.StartsWith("---`n") -or $skill -notmatch '(?m)^name: arc-jumpstart$' -or
    $skill -notmatch '(?m)^description: .+' -or
    $skill -match '(?i)(password|secret)\s*=\s*[^\s`]+') {
    throw 'Skill frontmatter or credential guidance failed validation.'
}
foreach ($expected in @('AGENTS.md', 'docs/00-agent-bootstrap.md',
    'infra/README.md', 'scripts/README.md', 'docs/03-arc-onboarding.md',
    'docs/04-assessment.md', 'docs/05-migration.md', 'PowerShell 7',
    'ENV_FILE', './scripts/validate.ps1', './scripts/preflight.ps1 infra',
    './scripts/deploy.ps1 all', './scripts/lab.ps1 build-status',
    'Never rerun `deploy.ps1 all`', 'agent must not connect Arc')) {
    Assert-Contains $skill $expected 'skill'
}

$launcher = [System.IO.File]::ReadAllText((Join-Path $root 'artifacts/scripts/prepare-arc-device-code-launchers.ps1'))
$stager = [System.IO.File]::ReadAllText((Join-Path $root 'artifacts/scripts/stage-arc-device-code-launchers.ps1'))
$bicep = [System.IO.File]::ReadAllText((Join-Path $root 'infra/stages/arc-launchers/main.bicep'))
foreach ($expected in @("'JS-DC-01'", "'JS-SQL-01'", "'JS-SQL-AG-01'",
    "'JS-SQL-AG-02'", "Join-Path `$env:PUBLIC 'Desktop'",
    "Join-Path `$programRoot 'Connect to Azure Arc.ps1'",
    "'Connect to Azure Arc.cmd'",
    "Remove-Item -LiteralPath (Join-Path `$publicDesktop 'Connect to Azure Arc.ps1')",
    '[securestring]$DomainAdministratorPassword',
    '--use-device-code', "if (`$current.status -eq 'Connected')",
    'Azure Arc is already connected',
    'The device code is intentionally not written to the evidence log.')) {
    Assert-Contains $launcher $expected 'Arc launcher'
}
Assert-NotContains $launcher 'Start-Transcript' 'Arc launcher'
Assert-NotContains $launcher 'Tee-Object' 'Arc launcher'
Assert-NotContains $launcher 'ConvertTo-SecureString $DomainAdministratorPassword -AsPlainText' 'Arc launcher'
$install = $launcher.IndexOf('https://aka.ms/AzureConnectedMachineAgent')
$check = $launcher.IndexOf('& $agent check --location')
$connect = $launcher.IndexOf('& $agent connect --subscription-id')
if ($install -lt 0 -or $check -le $install -or $connect -le $check) {
    throw 'Arc launcher must install, check connectivity, then connect.'
}
Assert-Contains $stager 'ConvertTo-SecureString $NestedWindowsPassword -AsPlainText -Force' 'Arc stager'
Assert-NotContains $stager 'Write-Host $NestedWindowsPassword' 'Arc stager'
Assert-Contains $bicep 'protectedScriptParameters' 'Arc Bicep'
Assert-Contains $bicep "name: 'NestedWindowsPassword'" 'Arc Bicep'
Assert-Contains $bicep "base64(loadTextContent('../../../artifacts/scripts/prepare-arc-device-code-launchers.ps1'))" 'Arc Bicep'

if (@(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -File |
    Where-Object { $_.Extension -in @('.py', '.sh') }).Count) {
    throw 'Only PowerShell source and test entry points are supported in scripts/.'
}
Write-Host 'Repository documentation and Arc launcher checks passed.'
