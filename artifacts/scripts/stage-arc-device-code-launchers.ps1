[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ArcResourceGroup,

    [Parameter(Mandatory)]
    [string]$ArcLocation,

    [Parameter(Mandatory)]
    [string]$NestedWindowsPassword,

    [Parameter(Mandatory)]
    [string]$LauncherScriptBase64,

    [Parameter(Mandatory)]
    [string]$RunId
)

$ErrorActionPreference = 'Stop'
$launcherSource = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String($LauncherScriptBase64)
)
$launcher = [scriptblock]::Create($launcherSource)
$securePassword = ConvertTo-SecureString $NestedWindowsPassword -AsPlainText -Force

& $launcher `
    -SubscriptionId $SubscriptionId `
    -ArcResourceGroup $ArcResourceGroup `
    -ArcLocation $ArcLocation `
    -DomainAdministratorPassword $securePassword
