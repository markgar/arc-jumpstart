$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$path = Join-Path $PSScriptRoot '../artifacts/scripts/60-configure-sql-ag.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors.Message -join "`n") }
$definition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Set-LabSqlServiceAccount'
}, $true)
if (-not $definition) { throw 'Missing SQL service account helper.' }
. ([scriptblock]::Create($definition.Extent.Text))

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected failure containing: $Message"
}
function Get-CimInstance {
    param($Namespace, $ClassName, $Filter, $ErrorAction)
    if ($Namespace -ne 'root\Microsoft\SqlServer\ComputerManagement17' -or
        $ClassName -ne 'SqlService' -or $Filter -ne "ServiceName='MSSQLSERVER'") {
        throw 'Must use the SQL 2025 provider and default instance, not Win32_Service.'
    }
    $script:services
}
function Invoke-CimMethod {
    param($InputObject, $MethodName, $Arguments, $ErrorAction)
    if ($MethodName -ne 'SetServiceAccount' -or
        $Arguments.ServiceStartName -ne 'JUMPSTART\sqlsvc' -or
        $Arguments.ServiceStartPassword -ne 'test-only-password') {
        throw 'Incorrect SQL WMI method or argument names.'
    }
    $script:calls++
    if ($script:providerThrows) { throw 'provider unavailable' }
    if ($script:returnCode -eq 0 -and $script:applyChange) {
        $InputObject.StartName = $Arguments.ServiceStartName
    }
    [pscustomobject]@{ ReturnValue = $script:returnCode }
}
function Reset-Case {
    $script:services = @([pscustomobject]@{ ServiceName = 'MSSQLSERVER'; StartName = 'NT SERVICE\MSSQLSERVER' })
    $script:calls = 0
    $script:returnCode = 0
    $script:applyChange = $true
    $script:providerThrows = $false
}
$action = { Set-LabSqlServiceAccount -Identity 'JUMPSTART\sqlsvc' -Password 'test-only-password' }
Reset-Case
if ((& $action) -ne $true -or $script:calls -ne 1) { throw 'Account change should succeed once.' }
if ((& $action) -ne $false -or $script:calls -ne 1) { throw 'Matching account must be retained.' }
foreach ($code in @(1, 5, $null)) {
    Reset-Case
    $script:returnCode = $code
    Assert-Throws $action 'SetServiceAccount failed'
}
Reset-Case
$script:applyChange = $false
Assert-Throws $action 'service account did not change'
Reset-Case
$script:providerThrows = $true
Assert-Throws $action 'provider unavailable'
Reset-Case
$script:services = @()
Assert-Throws $action 'exactly one'
Reset-Case
$script:services += $script:services[0]
Assert-Throws $action 'exactly one'

foreach ($stage in @('50-configure-domain.ps1', '60-configure-sql-ag.ps1')) {
    $stageAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot "../artifacts/scripts/$stage"), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors.Message -join "`n") }
    $calls = $stageAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.CommandElements[0].Extent.Text -eq '$sqlcmd'
    }, $true)
    if (-not $calls.Count) { throw "No sqlcmd calls found in $stage." }
    foreach ($call in $calls) {
        $elements = @($call.CommandElements | ForEach-Object { $_.Extent.Text })
        $listenerCall = $call.Extent.Text.Contains('"tcp:$Fqdn,1433"')
        if ($elements -cnotcontains '-C' -or $elements -cnotcontains '-b' -or
            $elements -cnotcontains '-E' -or (-not $listenerCall -and $elements -notcontains 'localhost')) {
            throw "$stage must explicitly trust the lab certificate and retain integrated auth/error handling."
        }
    }
}
function Get-FunctionText {
    param([string]$Name)
    $node = $ast.Find({
        param($n)
        $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
    }, $true)
    if (-not $node) { throw "Missing function $Name" }
    $node.Extent.Text
}
& {
    $source = Get-FunctionText Assert-LabWindowsSetupComplete
    foreach ($contract in @(
        '[DllImport("kernel32.dll", SetLastError = true)]',
        '[return: MarshalAs(UnmanagedType.Bool)]',
        'public static extern bool OOBEComplete([MarshalAs(UnmanagedType.Bool)] out bool complete);')) {
        if (-not $source.Contains($contract)) { throw 'OOBE interop must preserve the verified BOOL/out BOOL signature and last-error capture.' }
    }
    $nativeCall = '[ArcJumpstart.Stage60Oobe]::OOBEComplete([ref]$complete)'
    $errorCall = '[Runtime.InteropServices.Marshal]::GetLastWin32Error()'
    if (-not $source.Contains($nativeCall) -or -not $source.Contains($errorCall)) { throw 'OOBE native query contract changed.' }
    # Compile the actual interop declaration, but replace native calls on non-Windows.
    . ([scriptblock]::Create($source.Replace($nativeCall, '(Get-FakeOobeComplete ([ref]$complete))').Replace($errorCall, '(Get-FakeOobeError)')))
    function Write-Host { param($Object) }
    function Get-FakeOobeComplete {
        param([ref]$Complete)
        $script:oobeQueries++
        $Complete.Value = $script:oobeComplete
        $script:oobeQuerySucceeded
    }
    function Get-FakeOobeError { $script:oobeErrorReads++; 123 }
    $script:oobeQueries = 0; $script:oobeErrorReads = 0
    $script:oobeQuerySucceeded = $true; $script:oobeComplete = $true
    Assert-LabWindowsSetupComplete
    if ($script:oobeQueries -ne 1 -or $script:oobeErrorReads) { throw 'Completed OOBE must require only one read-only query.' }
    $script:oobeQueries = 0; $script:oobeComplete = $false
    Assert-Throws { Assert-LabWindowsSetupComplete } 'Windows Setup is unfinished'
    if ($script:oobeQueries -ne 1 -or $script:oobeErrorReads) { throw 'Unfinished OOBE must fail immediately without polling or reading an unrelated last-error value.' }
    foreach ($outValue in @($false, $true)) {
        $script:oobeQueries = 0; $script:oobeErrorReads = 0
        $script:oobeQuerySucceeded = $false; $script:oobeComplete = $outValue
        $failure = $null
        try { Assert-LabWindowsSetupComplete } catch { $failure = $_.Exception }
        if ($failure -isnot [ComponentModel.Win32Exception] -or $failure.NativeErrorCode -ne 123 -or
            $failure.Message -notlike '*OOBEComplete query failed*' -or $script:oobeQueries -ne 1 -or $script:oobeErrorReads -ne 1) {
            throw 'API failure must retain the Win32 error and never trust the out BOOL.'
        }
    }
}
& {
    . ([scriptblock]::Create((Get-FunctionText Assert-LabWindowsSetupComplete)))
    $guardCall = $ast.Find({
        param($n)
        $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-Command' -and
            $n.Extent.Text.Contains('${function:Assert-LabWindowsSetupComplete}')
    }, $true)
    if (-not $guardCall) { throw 'The native OOBE guard must run inside each AG guest.' }
    $loop = $guardCall.Parent
    while ($loop -and $loop -isnot [Management.Automation.Language.ForEachStatementAst]) { $loop = $loop.Parent }
    if (-not $loop -or $loop.Condition.Extent.Text -ne '$sqlNodes') { throw 'Preflight both AG nodes before any preparation work.' }
    $moduleCall = $ast.Find({
        param($n)
        $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-SqlServerModulePackage'
    }, $true)
    $featureCall = $ast.Find({
        param($n)
        $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Install-WindowsFeature'
    }, $true)
    foreach ($offset in @($moduleCall.Extent.StartOffset, $featureCall.Extent.StartOffset,
        $ast.Extent.Text.IndexOf('$inventoryScript ='), $ast.Extent.Text.IndexOf('$clusterScript ='))) {
        if ($offset -le $loop.Extent.EndOffset) { throw 'OOBE checks must finish before downloads, features, inventory, or cluster operations.' }
    }
    function Write-Host { param($Object) }
    function Invoke-Command {
        param($VMName, $Credential, $ScriptBlock, $ErrorAction)
        if ($ErrorAction -ne 'Stop' -or $Credential.UserName -ne 'JUMPSTART\Administrator' -or
            -not $ScriptBlock.ToString().Contains('::OOBEComplete([ref]$complete)')) { throw 'Pass the native guard and protected credential into the guest.' }
        $script:oobeGuestCalls += $VMName
        if ($VMName -eq $script:unfinishedGuest) { throw "Windows Setup is unfinished on $VMName" }
    }
    $sqlNodes = @('JS-SQL-AG-01', 'JS-SQL-AG-02')
    $domainCredential = [pscredential]::new('JUMPSTART\Administrator', (ConvertTo-SecureString 'test-only' -AsPlainText -Force))
    $script:oobeGuestCalls = @(); $script:unfinishedGuest = ''
    & ([scriptblock]::Create($loop.Extent.Text))
    if (($script:oobeGuestCalls -join ',') -ne ($sqlNodes -join ',')) { throw 'Both AG guests need an independent native readiness query.' }
    foreach ($node in $sqlNodes) {
        $script:oobeGuestCalls = @(); $script:unfinishedGuest = $node
        Assert-Throws { & ([scriptblock]::Create($loop.Extent.Text)) } 'Windows Setup is unfinished'
        if (@($script:oobeGuestCalls | Where-Object { $_ -eq $node }).Count -ne 1 -or $script:oobeGuestCalls[-1] -ne $node) {
            throw 'An unfinished guest must fail without retries or subsequent configuration.'
        }
    }
}
foreach ($name in @('Get-SqlServerModulePackage', 'Initialize-LabInstalledUpdateInventory', 'Assert-LabClusterValidationReport', 'Test-LabAgListener', 'Test-LabListenerTcp')) {
    . ([scriptblock]::Create((Get-FunctionText $name)))
}
& {
    function Write-Host { param($Object) }
    function Write-Warning { param($Message) $script:inventoryWarnings++ }
    function New-Object {
        param($ComObject, $ErrorAction)
        if ($ComObject -ne 'Microsoft.Update.Session') { throw 'Only the configured WUA session is permitted.' }
        $script:inventorySessions++
        $script:inventorySession
    }
    function New-InventoryResult($Code = 2) { [pscustomobject]@{ ResultCode = $Code; Updates = @{ Count = 6 } } }
    function Reset-InventoryCase([object[]]$Outcomes) {
        $script:inventoryCalls = @(); $script:inventoryWarnings = 0; $script:inventorySessions = 0
        $script:inventoryOutcomes = [Collections.Generic.Queue[object]]::new()
        foreach ($outcome in $Outcomes) { $script:inventoryOutcomes.Enqueue($outcome) }
        # Deliberately do not expose policy/source setters or download/install APIs.
        $script:inventorySearcher = [pscustomobject]@{ Online = $null }
        $script:inventorySearcher | Add-Member ScriptMethod Search {
            param($Criteria)
            if ($Criteria -cne 'IsInstalled=1') { throw 'Search only installed update metadata.' }
            $script:inventoryCalls += [bool]$this.Online
            $outcome = $script:inventoryOutcomes.Dequeue()
            if ($outcome -is [Exception]) { throw $outcome }
            $outcome
        }
        $script:inventorySession = [pscustomobject]@{ ClientApplicationID = '' }
        $script:inventorySession | Add-Member ScriptMethod CreateUpdateSearcher { $script:inventorySearcher }
    }
    $unknown = [Runtime.InteropServices.COMException]::new('Unknown update service', [Convert]::ToInt32('80248014', 16))
    $denied = [Runtime.InteropServices.COMException]::new('Access denied', [Convert]::ToInt32('80070005', 16))
    $run = { Initialize-LabInstalledUpdateInventory }
    Reset-InventoryCase @((New-InventoryResult))
    $result = & $run
    if (($script:inventoryCalls -join ',') -ne 'False' -or $result.MetadataInitialized -or
        $result.InstalledUpdateCount -ne 6 -or $script:inventoryWarnings -or $script:inventorySessions -ne 1 -or
        $script:inventorySession.ClientApplicationID -ne 'ArcJumpstart-InstalledUpdateInventory') {
        throw 'Healthy offline inventory must not make an online call or alter its source.'
    }
    Reset-InventoryCase @([Reflection.TargetInvocationException]::new('wrapped COM error', $unknown), (New-InventoryResult), (New-InventoryResult))
    $result = & $run
    if (($script:inventoryCalls -join ',') -ne 'False,True,False' -or -not $result.MetadataInitialized -or
        $result.ResultCode -ne 2 -or $script:inventoryWarnings -ne 1 -or $script:inventorySessions -ne 1) {
        throw 'Only unknown-service recovery may do one online search followed by an offline success check.'
    }
    foreach ($failure in @($denied, [Exception]::new('Message mentions 0x80248014 but is not a COM failure'))) {
        Reset-InventoryCase @($failure)
        Assert-Throws $run $failure.Message
        if (($script:inventoryCalls -join ',') -ne 'False' -or $script:inventoryWarnings) { throw 'Unrelated failures must never initialize metadata.' }
    }
    foreach ($code in @(0, 1, 3, 4, 5, $null)) {
        Reset-InventoryCase @((New-InventoryResult $code))
        Assert-Throws $run 'Offline installed-update inventory did not fully succeed'
        if (($script:inventoryCalls -join ',') -ne 'False') { throw 'Non-success offline results are not the unknown-service exception.' }
        Reset-InventoryCase @($unknown, (New-InventoryResult $code))
        Assert-Throws $run 'Online installed-update metadata search did not fully succeed'
        if (($script:inventoryCalls -join ',') -ne 'False,True') { throw 'Do not continue after a partial/failed online search.' }
        Reset-InventoryCase @($unknown, (New-InventoryResult), (New-InventoryResult $code))
        Assert-Throws $run 'Offline installed-update inventory did not fully succeed'
        if (($script:inventoryCalls -join ',') -ne 'False,True,False') { throw 'Require the offline postcondition without another online attempt.' }
    }
    Reset-InventoryCase @($unknown, $denied)
    Assert-Throws $run 'Access denied'
    if (($script:inventoryCalls -join ',') -ne 'False,True') { throw 'Online exceptions must propagate without retries.' }
    Reset-InventoryCase @($unknown, (New-InventoryResult), $unknown)
    Assert-Throws $run 'Unknown update service'
    if (($script:inventoryCalls -join ',') -ne 'False,True,False' -or $script:inventoryWarnings -ne 1) { throw 'A failed offline recheck must not trigger another initialization.' }
}
if ($ast.Extent.Text.Contains('HADR_Enabled') -or $ast.Extent.Text.Contains('LoadWithPartialName')) {
    throw 'HADR must use the documented cmdlet, never raw registry writes or GAC assumptions.'
}
if ($ast.Extent.Text -match '(?i)SET SINGLE_USER WITH ROLLBACK|CLUSTER_CONNECTION_OPTIONS') {
    throw 'Do not destroy secondary data or override SQL2025 cluster connection defaults.'
}
$sqlStrings = $ast.FindAll({
    param($n)
    ($n -is [Management.Automation.Language.StringConstantExpressionAst] -or
        $n -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and
        $n.Extent.Text -match '(?i)^\s*["''@]+.*DROP DATABASE'
}, $true)
foreach ($node in $sqlStrings) {
    if ($node.Extent.Text -notlike '*automatic DROP DATABASE or replacement is forbidden*') {
        throw 'No executable DROP DATABASE is permitted.'
    }
}
foreach ($query in $ast.FindAll({
    param($n)
    ($n -is [Management.Automation.Language.StringConstantExpressionAst] -or
        $n -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and
        $n.Extent.Text -match '(?i)SET NOCOUNT ON;'
}, $true)) {
    if ($query.Extent.Text -match '(?i)sys\.(dm_hadr_|availability_)' -and
        $query.Extent.Text -notmatch '\$(AgName|AvailabilityGroupName|agLiteral)') {
        throw "An AG state query is not scoped to the intended AG: $($query.Extent.Text)"
    }
}

& {
    function New-Item { param($ItemType, $Path, [switch]$Force) }
    function Join-Path { param($Path, $ChildPath) "$Path\$ChildPath" }
    function Test-Path { param($Path) $true }
    function Get-Item { param($Path) @{ Length = 47388419 } }
    function Get-FileHash { param($Path, $Algorithm) @{ Hash = $script:packageHash } }
    $script:packageHash = 'fc07531bceece44a5b7ffb29a8fd8d0b07a1a9f0eb0cb4535646fb0025a990b606954fc657af8981c8b650b5b3226c4c79874edc2802a3c05fe909ba9053e9b4'
    $package = Get-SqlServerModulePackage
    if ($package.Version -ne '22.4.5.1' -or $package.Hash -ne $script:packageHash) { throw 'Module must be version/hash pinned.' }
    $script:packageHash = 'bad'
    Assert-Throws { Get-SqlServerModulePackage } 'does not match the published package'
}
& {
    function Write-Warning { param($Message) $script:acceptedWarnings++ }
    function New-ResultRow($Name, $Target, $Status) {
        $icon = $Status.Replace(' ', '') + 'Img'
        "<tr><td><a href=`"&#xD;&#xA; #$Target`">$Name</a></td><td><result><IMG name=`"$icon`"></result></td><td><description>$Status</description></td></tr>"
    }
    function New-NativeReport {
        param($NetworkStatus = 'Success', $UpdateStatus = 'Success',
            $NetworkDetail = 'Nodes communicate by only one pair of network interfaces.',
            $UpdateDetail = 'All software updates present. All servers have same software updates.',
            $SystemStatus = $UpdateStatus)
        @"
<html lang="en-US" dir="LTR"><head><META http-equiv="Content-Type" content="text/html; charset=utf-8"></head><body>
<h2>Results by Category</h2><table>
$(New-ResultRow Inventory 1 Success)
$(New-ResultRow Network 2 $NetworkStatus)
$(New-ResultRow 'System Configuration' 3 $SystemStatus)
</table>
<a name="1"></a><h2>Inventory</h2><table>$(New-ResultRow 'List Operating System Information' 10 Success)</table>
<a name="10"></a><p>Inventory collected.<br>Success.</p>
<a name="2"></a><h2>Network</h2><table>$(New-ResultRow 'Validate Network Communication' 31 $NetworkStatus)</table>
<a name="31"></a><h3>Validate Network Communication</h3><p>$NetworkDetail<br></p>
<a name="3"></a><h2>System Configuration</h2><table>
$(New-ResultRow 'Validate Software Update Levels' 40 $UpdateStatus)
$(New-ResultRow 'Validate Switch Enabled Teaming' 41 Success)
</table>
<a name="40"></a><h3>Validate Software Update Levels</h3><p>$UpdateDetail</p>
<a name="41"></a><p>SwitchEnabledTeaming skipped as not applicable: neither node is HyperV.</p>
</body></html>
"@
    }
    Assert-LabClusterValidationReport (New-NativeReport)
    foreach ($status in @('Failed', 'Failure', 'Error', 'Canceled', 'Cancelled', 'Not Run')) {
        Assert-Throws { Assert-LabClusterValidationReport (New-NativeReport -UpdateStatus $status) } 'failed, canceled or unexecuted'
    }
    Assert-Throws { Assert-LabClusterValidationReport '<html>unknown format</html>' } 'Unrecognized'
    Assert-Throws { Assert-LabClusterValidationReport '<table><tr><td>Success</td></tr></table>' } 'Unrecognized'
    Assert-Throws { Assert-LabClusterValidationReport (New-NativeReport) @('Domain validation failed') } 'requires investigation'
    $script:acceptedWarnings = 0
    $network = New-NativeReport -NetworkStatus Warning
    Assert-LabClusterValidationReport $network @('Nodes communicate by only one pair of network interfaces.')
    if ($script:acceptedWarnings -ne 1) { throw 'Expected lab warnings must be reported explicitly.' }
    Assert-LabClusterValidationReport $network # The standalone gate can read the report without WarningVariable.
    $nativeSummary = [Management.Automation.WarningRecord]::new('Network - Validate Network Communication: The test reported some warnings.')
    $script:acceptedWarnings = 0
    Assert-LabClusterValidationReport $network @($nativeSummary)
    if ($script:acceptedWarnings -ne 1) { throw 'Correlated native summary must retain the explicit lab-warning notification.' }
    $streamRecords = @()
    foreach ($message in @(
        'Network - Validate Network Communication: The test reported some warnings.',
        " `r`nNetwork  -  Validate Network`r`nCommunication:  The test reported some warnings. `r`n")) {
        $captured = @()
        # Bypass this test scope's notification mock and capture real engine records.
        Microsoft.PowerShell.Utility\Write-Warning -Message $message -WarningVariable captured -WarningAction SilentlyContinue
        if ($captured.Count -ne 1 -or $captured[0] -isnot [Management.Automation.WarningRecord] -or
            $captured[0].Message -cne $message -or $captured[0].ToString() -cne $message -or "$($captured[0])" -cne $message) {
            throw 'Native warning-stream capture must preserve the unnormalized message and actual record type.'
        }
        Assert-LabClusterValidationReport $network -Warnings $captured
        $streamRecords += $captured
    }
    # Verbatim recovered records, including the doubled period and native wraps.
    $rawFirst = 'Network - Validate Network Communication: The test reported some warnings..'
    $rawOverall = "`r`nTest Result:`r`nHadUnselectedTests, ClusterConditionallyApproved`r`nTesting has completed for the tests you selected. You should review the warnings in the Report.  A `r`ncluster solution is supported by Microsoft only if you run all cluster validation tests, and all `r`ntests succeed (with or without warnings).`r`nTest report file path: C:\ArcJumpstart\Logs\ClusterValidation\Validation-20260916T055058731Z.htm`r`n"
    $liveReportPath = 'C:\ArcJumpstart\Logs\ClusterValidation\Validation-20260916T055058731Z.htm'
    $labSelection = @('Inventory', 'Network', 'System Configuration')
    $warningFile = Join-Path (Get-Location) ('.stage60-warnings-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        [IO.File]::WriteAllText($warningFile, "$rawFirst`r`n$rawOverall")
        $rawMessages = [IO.File]::ReadAllText($warningFile) -split "`r`n", 2
        if ($rawMessages.Count -ne 2 -or $rawMessages[0] -cne $rawFirst -or $rawMessages[1] -cne $rawOverall) {
            throw 'The regression must retain the recovered warning text without pre-normalizing it.'
        }
        $recoveredRecords = @()
        foreach ($message in $rawMessages) {
            $captured = @()
            Microsoft.PowerShell.Utility\Write-Warning -Message $message -WarningVariable captured -WarningAction SilentlyContinue
            if ($captured.Count -ne 1 -or $captured[0] -isnot [Management.Automation.WarningRecord] -or $captured[0].Message -cne $message) {
                throw 'Recovered messages must enter the gate as unnormalized native warning records.'
            }
            $recoveredRecords += $captured
        }
    }
    finally { Remove-Item $warningFile -Force -ErrorAction SilentlyContinue }
    Assert-LabClusterValidationReport $network -Warnings $recoveredRecords -ReportPath $liveReportPath -SelectedCategories $labSelection
    $wrappedRecord = @()
    Microsoft.PowerShell.Utility\Write-Warning -Message ($rawOverall.Replace("`r`n", "`r`r`n")) -WarningVariable wrappedRecord -WarningAction SilentlyContinue
    Assert-LabClusterValidationReport $network -Warnings @($recoveredRecords[0], $wrappedRecord[0]) -ReportPath $liveReportPath -SelectedCategories $labSelection
    Assert-Throws { Assert-LabClusterValidationReport $network -Warnings $recoveredRecords } 'requires investigation'
    Assert-Throws {
        Assert-LabClusterValidationReport $network -Warnings $recoveredRecords -ReportPath 'C:\other-report.htm' -SelectedCategories $labSelection
    } 'requires investigation'
    foreach ($selection in @(
        @('Inventory', 'Network'), @('Inventory', 'Network', 'Storage'),
        @('Inventory', 'Network', 'System Configuration', 'Storage'))) {
        Assert-Throws {
            Assert-LabClusterValidationReport $network -Warnings $recoveredRecords -ReportPath $liveReportPath -SelectedCategories $selection
        } 'requires investigation'
    }
    foreach ($flags in @('HadUnselectedTests, ClusterNotApproved', 'HadUnselectedTests, ClusterConditionallyApproved, UnknownFlag',
        'HadUnselectedTests, Failed', 'ClusterConditionallyApproved')) {
        $badOverall = [Management.Automation.WarningRecord]::new($rawOverall.Replace('HadUnselectedTests, ClusterConditionallyApproved', $flags))
        Assert-Throws {
            Assert-LabClusterValidationReport $network -Warnings @($recoveredRecords[0], $badOverall) -ReportPath $liveReportPath -SelectedCategories $labSelection
        } 'requires investigation'
    }
    Assert-Throws {
        Assert-LabClusterValidationReport $network -Warnings @($rawFirst + '.', $recoveredRecords[1]) -ReportPath $liveReportPath -SelectedCategories $labSelection
    } 'requires investigation'
    Assert-Throws {
        Assert-LabClusterValidationReport $network -Warnings @($recoveredRecords + [Management.Automation.WarningRecord]::new('Additional unknown warning')) -ReportPath $liveReportPath -SelectedCategories $labSelection
    } 'requires investigation'
    Assert-Throws {
        Assert-LabClusterValidationReport (New-NativeReport) -Warnings $recoveredRecords -ReportPath $liveReportPath -SelectedCategories $labSelection
    } 'requires investigation'
    Assert-Throws {
        Assert-LabClusterValidationReport (New-NativeReport -NetworkStatus Warning -UpdateStatus Warning) -Warnings $recoveredRecords -ReportPath $liveReportPath -SelectedCategories $labSelection
    } 'Validate Software Update Levels'
    Assert-Throws {
        Assert-LabClusterValidationReport (New-NativeReport -NetworkStatus Warning -UpdateStatus 'Not Run') -Warnings $recoveredRecords -ReportPath $liveReportPath -SelectedCategories $labSelection
    } 'failed, canceled or unexecuted'
    Assert-Throws {
        Assert-LabClusterValidationReport '' -Warnings $recoveredRecords -ReportPath $liveReportPath -SelectedCategories $labSelection
    } 'Unrecognized'
    $embeddedAssignment = $ast.Find({
        param($n)
        $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$validationScript'
    }, $true)
    $childText = & ([scriptblock]::Create($embeddedAssignment.Extent.Text + "`n" + '$validationScript'))
    $childAst = [Management.Automation.Language.Parser]::ParseInput($childText, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Generated validation child failed parsing.' }
    $childGates = @($childAst.FindAll({
        param($n)
        $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-LabClusterValidationReport'
    }, $true))
    $sourceGates = @($ast.FindAll({
        param($n)
        $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-LabClusterValidationReport'
    }, $true))
    if ($childGates.Count -ne 1 -or $sourceGates.Count -ne 1 -or
        $childGates[0].Body.GetScriptBlock().ToString().Trim().Replace("`r`n", "`n") -cne
        $sourceGates[0].Body.GetScriptBlock().ToString().Trim().Replace("`r`n", "`n")) {
        throw 'The generated child must embed exactly one current gate without body changes or duplicate copies.'
    }
    & {
        . ([scriptblock]::Create($childGates[0].Extent.Text))
        Assert-LabClusterValidationReport $network -Warnings $streamRecords
        Assert-LabClusterValidationReport $network -Warnings $recoveredRecords -ReportPath $liveReportPath -SelectedCategories $labSelection
        Assert-Throws {
            Assert-LabClusterValidationReport (New-NativeReport -NetworkStatus Warning -UpdateStatus Warning) -Warnings $streamRecords
        } 'Validate Software Update Levels'
        $additional = @()
        Microsoft.PowerShell.Utility\Write-Warning -Message 'Unrecognized validation warning' -WarningVariable additional -WarningAction SilentlyContinue
        Assert-Throws {
            Assert-LabClusterValidationReport $network -Warnings @($streamRecords + $additional)
        } 'requires investigation'
    }
    Assert-Throws { Assert-LabClusterValidationReport '' @($nativeSummary) } 'Unrecognized'
    Assert-Throws { Assert-LabClusterValidationReport (New-NativeReport) @($nativeSummary) } 'requires investigation'
    Assert-Throws {
        Assert-LabClusterValidationReport (New-NativeReport -NetworkStatus Failed) @($nativeSummary)
    } 'failed, canceled or unexecuted'
    Assert-Throws {
        Assert-LabClusterValidationReport ($network.Replace('<a name="31">', '<a name="missing">')) @($nativeSummary)
    } 'detail anchor'
    Assert-Throws {
        Assert-LabClusterValidationReport (New-NativeReport -NetworkStatus Warning -NetworkDetail 'Unexpected adapter warning.') @($nativeSummary)
    } 'its own detail'
    Assert-Throws {
        Assert-LabClusterValidationReport (New-NativeReport -NetworkStatus Warning -UpdateStatus Warning) @($nativeSummary)
    } 'Validate Software Update Levels'
    foreach ($unknownRecord in @(
        'Network - Validate Other Network Settings: The test reported some warnings.',
        'System Configuration - Validate Software Update Levels: The test reported some warnings.',
        'Network - Validate Network Communication: The test reported some warnings. Additional problem.',
        'Unrecognized validation warning')) {
        Assert-Throws { Assert-LabClusterValidationReport $network @($nativeSummary, $unknownRecord) } 'requires investigation'
    }
    $qfe = 'There was an error retrieving the QFE information from node AG01. Exception from HRESULT: 0x80248014<br>There was an error retrieving the QFE information from node AG02. Exception from HRESULT: 0x80248014<br>All software updates present. All servers have same software updates.'
    Assert-Throws {
        Assert-LabClusterValidationReport (New-NativeReport -NetworkStatus Warning -UpdateStatus Warning -UpdateDetail $qfe)
    } 'Validate Software Update Levels'
    Assert-Throws {
        Assert-LabClusterValidationReport (New-NativeReport -NetworkStatus Warning -UpdateStatus Warning -SystemStatus Success) @('Nodes communicate by only one pair of network interfaces.')
    } 'Validate Software Update Levels'
    Assert-Throws {
        Assert-LabClusterValidationReport (New-NativeReport -UpdateDetail $qfe)
    } 'QFE retrieval error'
    Assert-Throws {
        Assert-LabClusterValidationReport $network @('Nodes communicate by only one pair of network interfaces.', 'Error retrieving QFE information')
    } 'requires investigation'
    Assert-Throws {
        Assert-LabClusterValidationReport (New-NativeReport -SystemStatus Warning)
    } 'category warning requires investigation'
    Assert-Throws {
        Assert-LabClusterValidationReport (New-NativeReport -NetworkStatus Warning -NetworkDetail 'Unexpected adapter warning.' -UpdateDetail 'Nodes communicate by only one pair of network interfaces.')
    } 'its own detail'
    Assert-Throws {
        Assert-LabClusterValidationReport (New-NativeReport -NetworkStatus Warning -NetworkDetail 'Only one pair of interfaces; a network test failed.')
    } 'its own detail'
    Assert-Throws {
        Assert-LabClusterValidationReport ($network.Replace('<a name="31">', '<a name="missing">'))
    } 'detail anchor'
    Assert-Throws {
        Assert-LabClusterValidationReport ($network.Replace('name="WarningImg"', 'name="SuccessImg"'))
    } 'contradictory'
    Assert-Throws {
        Assert-LabClusterValidationReport ($network.Replace('Validate Network Communication', 'Validate Other Network Settings'))
    } 'Validate Other Network Settings'
    Assert-Throws {
        Assert-LabClusterValidationReport ($network.Replace('<description>Warning</description>', '<description>Unexpected</description>'))
    } 'Unrecognized'
    $categoriesOnly = '<table>' + (New-ResultRow Inventory 1 Success) + (New-ResultRow Network 2 Success) + (New-ResultRow 'System Configuration' 3 Success) + '</table>'
    Assert-Throws { Assert-LabClusterValidationReport $categoriesOnly } 'per-test results'
}
$validationAssignment = $ast.Find({
    param($n)
    $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$validationScript'
}, $true)
& {
    function Import-Module {
        param([Parameter(Mandatory)][string]$Name)
        if ($Name -cne 'FailoverClusters') { throw 'Generated actions must import FailoverClusters.' }
    }
    function New-Cluster {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
            [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Node,
            [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StaticAddress,
            [switch]$NoStorage, [switch]$Force
        )
        if ($Name -cne $ClusterName -or ($Node -join ',') -cne "$primaryName,$secondaryName" -or
            $StaticAddress -cne $ClusterIp -or -not $NoStorage -or -not $Force -or $ErrorActionPreference -ne 'Stop') {
            throw 'Generated New-Cluster lost its intended name, nodes, address or flags.'
        }
        $script:clusterActionCalls++
        if ($script:clusterActionFails) { throw 'cluster cmdlet failed' }
    }
    function Add-ClusterNode {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Cluster,
            [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
            [switch]$NoStorage
        )
        if ($Cluster -cne $ClusterName -or $Name -cne $secondaryName -or -not $NoStorage -or $ErrorActionPreference -ne 'Stop') {
            throw 'Generated Add-ClusterNode lost its intended cluster, node or flags.'
        }
        $script:clusterActionCalls++
        if ($script:clusterActionFails) { throw 'cluster cmdlet failed' }
    }
    function Set-ClusterQuorum {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Cluster,
            [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FileShareWitness
        )
        if ($Cluster -cne $ClusterName -or $FileShareWitness -cne "\\$dcName\ClusterWitness" -or $ErrorActionPreference -ne 'Stop') {
            throw 'Generated Set-ClusterQuorum lost its intended cluster or witness path.'
        }
        $script:clusterActionCalls++
        if ($script:clusterActionFails) { throw 'cluster cmdlet failed' }
    }
    $contracts = @(
        @{ Script = 'clusterScript'; Command = 'New-Cluster'; Parameters = @('Name', 'Node', 'StaticAddress', 'NoStorage', 'Force', 'ErrorAction') },
        @{ Script = 'addNodeScript'; Command = 'Add-ClusterNode'; Parameters = @('Cluster', 'Name', 'NoStorage', 'ErrorAction') },
        @{ Script = 'quorumScript'; Command = 'Set-ClusterQuorum'; Parameters = @('Cluster', 'FileShareWitness', 'ErrorAction') }
    )
    foreach ($customNames in @($false, $true)) {
        $ClusterName = if ($customNames) { 'OTHER-CLUSTER' } else { 'JS-SQLCLU' }
        $ClusterIp = if ($customNames) { '10.10.10.20' } else { '192.168.128.20' }
        $primaryName = if ($customNames) { 'OTHER-AG-01' } else { 'JS-SQL-AG-01' }
        $secondaryName = if ($customNames) { 'OTHER-AG-02' } else { 'JS-SQL-AG-02' }
        $dcName = if ($customNames) { 'OTHER-DC' } else { 'JS-DC-01' }
        foreach ($contract in $contracts) {
            $assignment = $ast.Find({
                param($n)
                $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$' + $contract.Script)
            }, $true)
            $generated = & ([scriptblock]::Create($assignment.Extent.Text + "`n" + ('$' + $contract.Script)))
            $generatedAst = [Management.Automation.Language.Parser]::ParseInput($generated, [ref]$tokens, [ref]$errors)
            if ($errors.Count) { throw 'Invalid generated cluster action.' }
            $commands = @($generatedAst.FindAll({
                param($n)
                $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $contract.Command
            }, $true))
            $parameters = @($commands.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] } | ForEach-Object ParameterName)
            # Fail before a mandatory-parameter prompt if continuations regress.
            if ($commands.Count -ne 1 -or @($contract.Parameters | Where-Object { $_ -notin $parameters }).Count) {
                throw "Generated $($contract.Command) is missing bound command parameters."
            }
            $script:clusterActionCalls = 0; $script:clusterActionFails = $false
            & ([scriptblock]::Create($generated))
            if ($script:clusterActionCalls -ne 1) { throw 'Each generated action must execute exactly one cluster cmdlet.' }
            $script:clusterActionFails = $true
            Assert-Throws { & ([scriptblock]::Create($generated)) } 'cluster cmdlet failed'
        }
    }
}
$clusterAssignment = $ast.Find({
    param($n)
    $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$clusterScript'
}, $true)
if ($validationAssignment.Extent.StartOffset -ge $clusterAssignment.Extent.StartOffset -or
    -not $validationAssignment.Extent.Text.Contains("Test-Cluster -Node") -or
    -not $validationAssignment.Extent.Text.Contains("'Inventory', 'Network', 'System Configuration'") -or
    -not $validationAssignment.Extent.Text.Contains('-ReportName') -or
    -not $ast.Extent.Text.Contains("-OperationName 'ArcJumpstart-ValidateCluster'")) {
    throw 'Cluster validation/report retention must precede creation in a local domain-account process.'
}
if ($validationAssignment.Extent.Text.Contains("+ '.htm'") -or
    -not $validationAssignment.Extent.Text.Contains('Get-Content `$report[0].FullName -Raw') -or
    -not $validationAssignment.Extent.Text.Contains('ReportPath = `$report[0].FullName') -or
    -not $validationAssignment.Extent.Text.Contains('-Include `$selectedCategories') -or
    -not $validationAssignment.Extent.Text.Contains('-ReportPath `$report[0].FullName -SelectedCategories `$selectedCategories')) {
    throw 'Use extensionless ReportName and retain/read the actual returned FileInfo.FullName.'
}
& {
    $primaryName = 'JS-SQL-AG-01'; $secondaryName = 'JS-SQL-AG-02'; $dcName = 'JS-DC-01'
    $ClusterName = 'JS-SQLCLU'; $ClusterIp = '192.168.128.20'
    $ListenerName = 'JS-AG-LSTN'; $DomainName = 'jumpstart.lab'; $ListenerIp = '192.168.128.21'
    $AvailabilityGroupName = 'JS-AG-01'; $SampleDatabaseName = 'JumpstartDB'
    foreach ($name in @('inventoryScript', 'validationScript', 'clusterScript', 'addNodeScript', 'verifyClusterScript', 'quorumScript', 'listenerScript')) {
        $assignment = $ast.Find({
            param($n)
            $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$' + $name)
        }, $true)
        $text = & ([scriptblock]::Create($assignment.Extent.Text + "`n" + ('$' + $name)))
        $null = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw "Invalid embedded $name : $($errors.Message -join '; ')" }
    }
    & {
        $inventoryCall = $ast.Find({
            param($n)
            $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-GuestLocalProcess' -and
                $n.Extent.Text.Contains("'ArcJumpstart-InstalledUpdateInventory'")
        }, $true)
        if (-not $inventoryCall -or $inventoryCall.Extent.EndOffset -ge $validationAssignment.Extent.StartOffset) {
            throw 'Both nodes must complete installed-update inventory before Test-Cluster is launched.'
        }
        $loop = $inventoryCall.Parent
        while ($loop -and $loop -isnot [Management.Automation.Language.ForEachStatementAst]) { $loop = $loop.Parent }
        if (-not $loop -or $loop.Condition.Extent.Text -ne '@($primaryName, $secondaryName)' -or
            -not $inventoryCall.Extent.Text.Contains('-VMName $nodeName') -or
            -not $inventoryCall.Extent.Text.Contains('-ScriptText $inventoryScript')) {
            throw 'Inventory must run locally on each AG guest, not on the host or only one node.'
        }
    }
}

& {
    $block = @($ast.FindAll({
        param($n)
        $n -is [Management.Automation.Language.ScriptBlockExpressionAst] -and $n.Extent.Text.Contains('Enable-SqlAlwaysOn')
    }, $true) | Sort-Object { $_.Extent.Text.Length })[0].ScriptBlock.GetScriptBlock()
    function Import-Module {
        param($Name, $RequiredVersion, $ErrorAction)
        if ($RequiredVersion -ne '22.4.5.1' -or $Name -notlike '*22.4.5.1\SqlServer.psd1') { throw 'Import the transported pinned module.' }
    }
    function Get-Command { param($Name, $ErrorAction) @{ Source = 'Invoke-FakeHadrSql' } }
    function Enable-SqlAlwaysOn {
        param($ServerInstance, [switch]$NoServiceRestart, [switch]$Confirm, $ErrorAction)
        if (-not $NoServiceRestart -or $Confirm) { throw 'Restart must be controlled one node at a time.' }
        $script:events += 'enable'
        if ($script:enableFails) { throw 'documented enable failed' }
    }
    function Restart-Service { param($Name, [switch]$Force) $script:events += 'restart' }
    function Invoke-FakeHadrSql {
        param($S, [switch]$E, [switch]$b, [switch]$C, $l, $t, $h, [switch]$W, $Q)
        $global:LASTEXITCODE = 0
        if ($Q -like '*SELECT SERVERPROPERTY*') { "$script:beforeHadr" }
        elseif ($Q -like '*CONCAT*') {
            if ($Q -cne "SET NOCOUNT ON; SELECT CONCAT(CONVERT(int, SERVERPROPERTY('IsHadrEnabled')), ',', CONVERT(int, SERVERPROPERTY('HadrManagerStatus')));") {
                throw 'Both sql_variant SERVERPROPERTY results require explicit conversion before CONCAT.'
            }
            $script:events += 'probe'; '1,1'
        }
        else { $script:events += 'endpoint' }
    }
    $script:enableFails = $false
    foreach ($case in @(@(0, $false, 1), @(1, $false, 0), @(1, $true, 1))) {
        $script:events = @(); $script:beforeHadr = $case[0]
        & $block 'JUMPSTART\sqlsvc' $case[1]
        if (@($script:events | Where-Object { $_ -eq 'restart' }).Count -ne $case[2] -or
            $script:events[0] -ne 'enable' -or $script:events[-1] -ne 'endpoint') {
            throw 'HADR enabling/restart/readiness ordering is incorrect.'
        }
    }
    $script:enableFails = $true
    Assert-Throws { & $block 'JUMPSTART\sqlsvc' $false } 'documented enable failed'
}
& {
    . ([scriptblock]::Create((Get-FunctionText Wait-LabSqlHadrReady)))
    function Get-Command { param($Name, $ErrorAction) @{ Source = 'Invoke-FakeReadinessSql' } }
    function Get-Date { $script:readinessClock }
    function Start-Sleep { param($Seconds) $script:readinessSleeps++; $script:readinessClock = $script:readinessClock.AddSeconds($Seconds) }
    function Write-Host { param($Object) $script:readinessMessages += [string]$Object }
    function Restart-Service { throw 'Readiness must never automatically restart SQL.' }
    function Invoke-FakeReadinessSql {
        param($S, [switch]$E, [switch]$b, [switch]$C, $l, $t, $h, [switch]$W, $Q)
        if ($S -ne 'localhost' -or -not $E -or -not $b -or -not $C -or $l -ne 15 -or $t -ne 30 -or
            $Q -cne "SET NOCOUNT ON; SELECT CONCAT(CONVERT(int, SERVERPROPERTY('IsHadrEnabled')), ',', CONVERT(int, SERVERPROPERTY('HadrManagerStatus')));") {
            throw 'Preserve integrated auth, lab certificate trust, timeouts and explicit sql_variant conversions.'
        }
        $index = [Math]::Min($script:readinessCalls, $script:readinessResults.Count - 1)
        $script:readinessCalls++
        $result = $script:readinessResults[$index]
        $global:LASTEXITCODE = $result.Code
        if ($result.Stderr) { Write-Error $result.Text } else { $result.Text }
    }
    function Reset-Readiness([object[]]$Results) {
        $script:readinessClock = [DateTime]::UtcNow
        $script:readinessCalls = 0; $script:readinessSleeps = 0; $script:readinessResults = $Results
        $script:readinessMessages = @()
    }
    Reset-Readiness @(@{ Code = 0; Text = '1,1' })
    Wait-LabSqlHadrReady
    if ($script:readinessCalls -ne 1 -or $script:readinessSleeps) { throw 'Ready SQL must succeed immediately.' }
    foreach ($errorText in @(
        "Msg 257, Level 16, State 3, Line 1`nImplicit conversion from data type sql_variant to varchar is not allowed. Use the CONVERT function.",
        'Msg 102, Level 15, State 1, Line 1 Incorrect syntax.',
        'Login failed for user JUMPSTART\Administrator.',
        'SSL Provider: certificate error. Login timeout expired.',
        'Unrecognized SQL command failure')) {
        Reset-Readiness @(@{ Code = 1; Text = $errorText })
        Assert-Throws { Wait-LabSqlHadrReady } 'not a startup delay'
        if ($script:readinessCalls -ne 1 -or $script:readinessSleeps) { throw 'Semantic/authentication/unknown errors must never wait for startup.' }
    }
    foreach ($transient in @(
        @{ Code = 0; Text = '1,0' },
        @{ Code = 0; Text = '1,2' },
        @{ Code = 1; Text = 'Sqlcmd: Error: Login timeout expired.' },
        @{ Code = 1; Text = 'Sqlcmd: Error: Login timeout expired.'; Stderr = $true },
        @{ Code = 1; Text = 'TCP Provider: No connection could be made because the target machine actively refused it.' })) {
        Reset-Readiness @($transient, @{ Code = 0; Text = '1,1' })
        Wait-LabSqlHadrReady -TimeoutSeconds 30
        if ($script:readinessCalls -ne 2 -or $script:readinessSleeps -ne 1) { throw 'Recognized startup states must retain bounded retries.' }
        if ($transient.Text -eq '1,2' -and ($script:readinessMessages -join '') -notlike '*sqlcmd exit 0*: 1,2*') {
            throw 'The observed 1,2 startup state must be logged, not silently ignored.'
        }
    }
    Reset-Readiness @(@{ Code = 0; Text = '1,0' })
    Assert-Throws { Wait-LabSqlHadrReady -TimeoutSeconds 20 } 'did not become HADR-ready within 20 seconds'
    if ($script:readinessCalls -ne 2 -or $script:readinessSleeps -ne 2) { throw 'Readiness polling must honor its bounded deadline.' }
    Reset-Readiness @(@{ Code = 0; Text = '1,2' })
    Assert-Throws { Wait-LabSqlHadrReady -TimeoutSeconds 20 } 'Last result (sqlcmd exit 0): 1,2. Inspect'
    if ($script:readinessCalls -ne 2 -or $script:readinessSleeps -ne 2) { throw 'Persistent 1,2 must time out, never become success or trigger a restart.' }
    Reset-Readiness @(@{ Code = 0; Text = '0,2' })
    Assert-Throws { Wait-LabSqlHadrReady } 'HADR manager failed to start'
    Reset-Readiness @(@{ Code = 0; Text = '1,3' })
    Assert-Throws { Wait-LabSqlHadrReady } 'Invalid HADR readiness result'
    Reset-Readiness @(@{ Code = 0; Text = ',1' })
    Assert-Throws { Wait-LabSqlHadrReady } 'Invalid HADR readiness result'
    if ($script:readinessSleeps) { throw 'Malformed success output must not be treated as startup.' }
    Reset-Readiness @(@{ Code = 1; Text = 'Msg 257, Level 16, State 3, Line 1: sql_variant conversion error'; Stderr = $true })
    Assert-Throws { Wait-LabSqlHadrReady } 'not a startup delay'
    if ($script:readinessSleeps -or $ErrorActionPreference -ne 'Stop') { throw 'Native stderr classification must not weaken fail-fast behavior.' }
}
& {
    function Get-Command { param($Name, $ErrorAction) @{ Source = 'Invoke-FakeListenerSql' } }
    function Resolve-DnsName {
        param($Name, $Type, [switch]$DnsOnly, $ErrorAction)
        @{ IPAddress = $script:listenerIp }
    }
    function Test-LabListenerTcp { param($Fqdn) if ($script:tcpFails) { throw 'TCP blocked' } }
    function Invoke-FakeListenerSql {
        param($S, [switch]$E, [switch]$b, [switch]$C, $l, $t, $d, $h, [switch]$W, $Q)
        if ($S -ne 'tcp:listener.jumpstart.lab,1433' -or -not $E -or -not $C -or -not $b -or
            $l -ne 15 -or $t -ne 30 -or $d -ne 'JumpstartDB' -or
            $Q -notlike '*fn_hadr_is_primary_replica*' -or $Q -notlike "*ag.name = N'JS-AG-01'*") {
            throw 'Listener must be queried over TCP with explicit lab trust and intended primary AG/database checks.'
        }
        $global:LASTEXITCODE = $script:queryCode
        '1'
    }
    $probe = { Test-LabAgListener listener.jumpstart.lab 192.168.128.21 JS-AG-01 JumpstartDB -TimeoutSeconds 0 }
    $script:listenerIp = '192.168.128.21'; $script:tcpFails = $false; $script:queryCode = 0
    & $probe
    $script:listenerIp = '192.168.128.99'
    Assert-Throws $probe 'Listener DNS'
    $script:listenerIp = '192.168.128.21'; $script:tcpFails = $true
    Assert-Throws $probe 'TCP blocked'
    $script:tcpFails = $false; $script:queryCode = 1
    Assert-Throws $probe 'Listener SQL query failed'
}
& {
    . ([scriptblock]::Create((Get-FunctionText Invoke-GuestWithRetry)))
    function Invoke-Command {
        [CmdletBinding()]
        param($VMName, $Credential, $ScriptBlock, $ArgumentList)
        $script:connectionAttempts++
        if ($script:connectionAttempts -gt 1) { return 'ready' }
        $exception = if ($script:transportError) {
            [Management.Automation.Remoting.PSRemotingTransportException]::new($script:connectionMessage)
        }
        else { [InvalidOperationException]::new($script:connectionMessage) }
        $record = [Management.Automation.ErrorRecord]::new($exception, $script:connectionErrorId, $script:connectionCategory, $null)
        if ($script:connectionDetails) { $record.ErrorDetails = [Management.Automation.ErrorDetails]::new($script:connectionDetails) }
        $PSCmdlet.ThrowTerminatingError($record)
    }
    function Start-Sleep { param($Seconds) $script:connectionSleeps++ }
    function Reset-ConnectionCase {
        $script:connectionAttempts = 0; $script:connectionSleeps = 0; $script:transportError = $true
        $script:connectionMessage = 'VM transport unavailable'; $script:connectionErrorId = 'PSSessionStateBroken'
        $script:connectionCategory = [Management.Automation.ErrorCategory]::OpenError
        $script:connectionDetails = ''
    }
    $credential = [pscredential]::new('JUMPSTART\Administrator', (ConvertTo-SecureString dummy -AsPlainText -Force))
    $invoke = { Invoke-GuestWithRetry -VMName JS-SQL-AG-01 -Credential $credential -ScriptBlock { 'probe' } }
    foreach ($message in @('The credential is invalid.', 'The credentials are invalid.', 'Authentication failed.',
        'Logon failure: unknown user.', 'The user name or password is incorrect.')) {
        Reset-ConnectionCase
        $script:connectionMessage = $message
        Assert-Throws $invoke $message
        if ($script:connectionAttempts -ne 1 -or $script:connectionSleeps -ne 0) { throw 'Definite authentication failures must never retry.' }
    }
    foreach ($id in @('AuthenticationFailed,PSSessionStateBroken', 'InvalidCredential,InvokeCommandCommand')) {
        Reset-ConnectionCase
        $script:connectionErrorId = $id
        Assert-Throws $invoke 'VM transport unavailable'
        if ($script:connectionAttempts -ne 1 -or $script:connectionSleeps -ne 0) { throw 'Authentication IDs must override transport retry classification.' }
    }
    Reset-ConnectionCase
    $script:connectionCategory = [Management.Automation.ErrorCategory]::AuthenticationError
    Assert-Throws $invoke 'VM transport unavailable'
    if ($script:connectionAttempts -ne 1) { throw 'Authentication category must fail fast.' }
    Reset-ConnectionCase
    $script:connectionDetails = 'The credential is invalid.'
    Assert-Throws $invoke 'VM transport unavailable'
    if ($script:connectionAttempts -ne 1) { throw 'Authentication error details must fail fast.' }
    Reset-ConnectionCase
    $script:transportError = $false; $script:connectionErrorId = 'SqlConfigurationFailed'
    Assert-Throws $invoke 'VM transport unavailable'
    if ($script:connectionAttempts -ne 1) { throw 'Non-transport guest errors must not be retried.' }
    Reset-ConnectionCase
    if ((& $invoke) -ne 'ready' -or $script:connectionAttempts -ne 2 -or $script:connectionSleeps -ne 1) {
        throw 'Genuine transient transport failures must retain bounded retry behavior.'
    }
}
& {
    . ([scriptblock]::Create((Get-FunctionText Wait-LabClusterReady)))
    function Get-Date { $script:clusterNow }
    function Start-Sleep {
        param($Seconds)
        $script:clusterSleeps++
        $script:clusterNow = $script:clusterNow.AddSeconds($Seconds)
    }
    function Write-Host { param($Object) $script:clusterMessages += "$Object" }
    function Get-Cluster {
        param($Name, $ErrorAction)
        $script:clusterAttempts++
        if ($script:clusterAttempts -le $script:clusterFailures) { throw $script:clusterError }
        [pscustomobject]@{ Name = $Name }
    }
    function Get-ClusterNode {
        param($Cluster, $ErrorAction)
        $script:clusterNodes
    }
    function Reset-ClusterCase {
        $script:clusterNow = [DateTime]::Parse('2026-09-16T16:20:00Z').ToUniversalTime()
        $script:clusterSleeps = 0
        $script:clusterMessages = @()
        $script:clusterAttempts = 0
        $script:clusterFailures = 1
        $script:clusterError = 'An error occurred opening cluster JS-SQLCLU.'
        $script:clusterNodes = @(
            [pscustomobject]@{ Name = 'JS-SQL-AG-01'; State = 'Up' },
            [pscustomobject]@{ Name = 'JS-SQL-AG-02'; State = 'Up' }
        )
    }
    Reset-ClusterCase
    $ready = Wait-LabClusterReady -ClusterName JS-SQLCLU `
        -ExpectedNodes @('JS-SQL-AG-01', 'JS-SQL-AG-02') -TimeoutSeconds 30 -IntervalSeconds 15
    if ($script:clusterAttempts -ne 2 -or $script:clusterSleeps -ne 1 -or
        $ready.Nodes.Count -ne 2 -or ($script:clusterMessages -join "`n") -notlike '*An error occurred opening cluster*') {
        throw 'Transient post-create cluster-open failures must be logged and retried to both-nodes-Up readiness.'
    }
    Reset-ClusterCase
    $script:clusterFailures = [int]::MaxValue
    Assert-Throws {
        Wait-LabClusterReady -ClusterName JS-SQLCLU `
            -ExpectedNodes @('JS-SQL-AG-01', 'JS-SQL-AG-02') -TimeoutSeconds 30 -IntervalSeconds 15
    } 'An error occurred opening cluster'
    if ($script:clusterSleeps -ne 2) { throw 'Cluster readiness timeout must remain bounded by the configured interval/deadline.' }
    Reset-ClusterCase
    $script:clusterFailures = 0
    $script:clusterNodes[1].State = 'Joining'
    Assert-Throws {
        Wait-LabClusterReady -ClusterName JS-SQLCLU `
            -ExpectedNodes @('JS-SQL-AG-01', 'JS-SQL-AG-02') -TimeoutSeconds 30 -IntervalSeconds 15
    } 'JS-SQL-AG-02=Joining'
}
. ([scriptblock]::Create((Get-FunctionText Assert-LocalProcessCompletion)))
. ([scriptblock]::Create((Get-FunctionText Assert-NoActiveLabOperation)))
& {
    $submitted = [DateTime]::Parse('2026-09-17T00:00:00Z').ToUniversalTime()
    $process = [pscustomobject]@{ Id = 123; StartTime = $submitted; ExitCode = 0; HasExited = $true }
    $completion = [pscustomobject]@{
        AttemptId = 'fresh'; Status = 'Completed'; ExitCode = 0; ProcessId = 123
        ProcessStartUtc = $submitted.ToString('o'); Identity = 'JUMPSTART\Administrator'; IsAdministrator = $true; RemoteSession = $false
        StartedUtc = $submitted.AddSeconds(1).ToString('o'); CompletedUtc = $submitted.AddSeconds(2).ToString('o')
        Error = 'captured failure'; ErrorId = 'ActionFailure'
    }
    $check = { Assert-LocalProcessCompletion $process $completion fresh 'JUMPSTART\Administrator' $submitted }
    & $check
    Assert-Throws { Assert-LocalProcessCompletion $process $null fresh 'JUMPSTART\Administrator' $submitted } 'Missing, stale'
    foreach ($state in @('Prepared', 'Queued', 'Running', 'Unknown')) {
        $completion.Status = $state
        Assert-Throws $check 'Incomplete or invalid'
    }
    $completion.Status = 'Completed'; $completion.AttemptId = 'stale'
    Assert-Throws $check 'Missing, stale'
    $completion.AttemptId = 'fresh'
    $completion.StartedUtc = $submitted.AddSeconds(-1).ToString('o')
    Assert-Throws $check 'Stale local-process completion timestamps'
    $completion.StartedUtc = $submitted.AddSeconds(1).ToString('o')
    $completion.CompletedUtc = $null
    Assert-Throws $check 'Incomplete or invalid'
    $completion.CompletedUtc = $submitted.AddSeconds(2).ToString('o')
    $process.HasExited = $false
    Assert-Throws $check 'Incomplete or invalid'
    $process.HasExited = $true; $process.Id = 456
    Assert-Throws $check 'Incomplete or invalid'
    $process.Id = 123; $completion.ProcessStartUtc = $submitted.AddDays(1).ToString('o')
    Assert-Throws $check 'Stale local-process completion timestamps'
    $completion.ProcessStartUtc = $submitted.ToString('o'); $completion.RemoteSession = $true
    Assert-Throws $check 'intended elevated local domain process'
    $completion.RemoteSession = $false; $completion.Identity = 'NT AUTHORITY\SYSTEM'
    Assert-Throws $check 'intended elevated local domain process'
    $completion.Identity = 'JUMPSTART\Administrator'; $completion.Status = 'Failed'; $completion.ExitCode = 7
    Assert-Throws $check 'disagrees'
    $process.ExitCode = 7
    Assert-Throws $check 'captured failure'
}

$helperAst = $ast.Find({
    param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-GuestLocalProcess'
}, $true)
$remoteAst = $helperAst.Find({
    param($n)
    $n -is [Management.Automation.Language.ScriptBlockExpressionAst] -and
        $n.ScriptBlock.ParamBlock.Parameters.Name.VariablePath.UserPath -contains 'LocalCredential'
}, $true)
if ($helperAst.Find({
    param($n)
    $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @(
        'Stop-Process', 'Stop-Job', 'Stop-ScheduledTask', 'Unregister-ScheduledTask', 'Register-ScheduledTask',
        'Start-ScheduledTask', 'New-ScheduledTaskAction', 'Invoke-GuestWithRetry')
}, $true)) { throw 'Local operations must not schedule tasks, force termination, or blindly retry mutations.' }
& {
    . ([scriptblock]::Create($helperAst.Extent.Text))
    $credential = [pscredential]::new('JUMPSTART\Administrator', (ConvertTo-SecureString 'test-only-secret' -AsPlainText -Force))
    $script:sessionEvents = @(); $script:invokeFails = $false; $script:knownFailure = $false
    function New-PSSession {
        param($VMName, $Credential, $ErrorAction)
        if ($VMName -ne 'JS-SQL-AG-01' -or $Credential.UserName -ne 'JUMPSTART\Administrator') { throw 'Incorrect Direct connection identity.' }
        $script:sessionEvents += 'connect'
        @{ Id = 7 }
    }
    function Invoke-Command {
        param($Session, $ScriptBlock, $ArgumentList, $ErrorAction)
        if ($Session.Id -ne 7 -or $ArgumentList[0] -isnot [pscredential] -or $ArgumentList[1] -ne 'ArcJumpstart-CreateCluster') {
            throw 'Hold one explicit Direct session and transport the run-as credential only as PSCredential.'
        }
        $script:sessionEvents += 'invoke'
        if ($script:knownFailure) {
            throw "Local operation ArcJumpstart-CreateCluster attempt=$($ArgumentList[4]) failed: Local operation failed (exit 1): native cluster failure."
        }
        if ($script:invokeFails) { throw 'unknown transport outcome' }
        @{ AttemptId = $ArgumentList[4]; ExitCode = 0 }
    }
    function Remove-PSSession {
        param($Session, $ErrorAction)
        $script:sessionEvents += 'close'
    }
    function Write-Warning { param($Message) }
    $run = { Invoke-GuestLocalProcess JS-SQL-AG-01 $credential $credential ArcJumpstart-CreateCluster 'Write-Output action' }
    $result = & $run
    if (($script:sessionEvents -join ',') -ne 'connect,invoke,close' -or -not $result.AttemptId) { throw 'Close the held session only after the synchronous invocation returns.' }
    $script:sessionEvents = @(); $script:invokeFails = $true
    Assert-Throws $run 'unknown transport outcome'
    if (($script:sessionEvents -join ',') -ne 'connect,invoke') { throw 'An unknown outcome must not trigger a retry or explicit session termination.' }
    $script:sessionEvents = @(); $script:invokeFails = $false; $script:knownFailure = $true
    Assert-Throws $run 'native cluster failure'
    if (($script:sessionEvents -join ',') -ne 'connect,invoke,close') {
        throw 'A recognized terminal local-operation failure must preserve the error and close its held Direct session.'
    }
}
if (-not $ast.Extent.Text.Contains('${function:Wait-LabClusterReady}') -or
    -not $ast.Extent.Text.Contains("Wait-LabClusterReady -ClusterName")) {
    throw 'Generated cluster verification must embed and invoke the bounded readiness helper.'
}
& {
    function Join-Path { param($Path, $ChildPath) "$Path\$ChildPath" }
    function Get-CimInstance { param($ClassName, $Filter, $ErrorAction) $script:ownedProcesses }
    function Get-Process { param($Id, $ErrorAction) $script:priorProcess }
    function Test-Path { param($Path) $script:priorFiles.ContainsKey($Path) }
    function Get-Content { param($Path, [switch]$Raw) $script:priorFiles[$Path] }
    $root = 'C:\ArcJumpstart\Operations'
    $token = '0123456789abcdef0123456789abcdef'
    $wrapper = "$root\ArcJumpstart-CreateCluster\$token\wrapper.ps1"
    $result = "$root\ArcJumpstart-CreateCluster\$token\result.json"
    $start = [DateTime]::UtcNow.AddMinutes(-1)
    $active = @{ AttemptId = $token; ProcessId = 123; ProcessStartUtc = $start.ToString('o'); WrapperPath = $wrapper; ResultPath = $result }
    $receipt = @{ AttemptId = $token; ProcessId = 123; ProcessStartUtc = $start.ToString('o'); Status = 'Completed'; CompletedUtc = [DateTime]::UtcNow.ToString('o'); ExitCode = 0 }
    $script:priorFiles = @{}
    $script:ownedProcesses = @(); $script:priorProcess = $null
    Assert-NoActiveLabOperation $root
    $script:priorFiles["$root\active.json"] = $active | ConvertTo-Json
    $script:priorFiles[$result] = $receipt | ConvertTo-Json
    $script:priorProcess = @{ Id = 123; StartTime = $start }
    $script:ownedProcesses = @(@{ ProcessId = 123; CommandLine = "powershell.exe -NoProfile -File `"$wrapper`"" })
    Assert-Throws { Assert-NoActiveLabOperation $root } 'commandTokenMatches=True'
    $script:ownedProcesses = @()
    Assert-Throws { Assert-NoActiveLabOperation $root } 'commandTokenMatches=False'
    $script:priorProcess.StartTime = $start.AddDays(1)
    Assert-NoActiveLabOperation $root # Reused PID, unrelated command, terminal prior action.
    $script:priorProcess = $null
    $receipt.Status = 'Failed'; $receipt.ExitCode = 1
    $script:priorFiles[$result] = $receipt | ConvertTo-Json
    Assert-NoActiveLabOperation $root # Known terminal failure needs no marker deletion or acknowledgement.
    $script:priorProcess = @{ Id = 123; StartTime = $start }
    Assert-Throws { Assert-NoActiveLabOperation $root } 'still active'
    $script:priorProcess = $null
    $script:priorFiles.Remove($result)
    Assert-Throws { Assert-NoActiveLabOperation $root } 'outcome is unknown'
    $receipt.AttemptId = 'stale'
    $script:priorFiles[$result] = $receipt | ConvertTo-Json
    Assert-Throws { Assert-NoActiveLabOperation $root } 'outcome is unknown'
    $script:priorFiles.Clear()
    $script:ownedProcesses = @(@{ ProcessId = 123; CommandLine = "powershell.exe -File `"$wrapper`"" })
    Assert-Throws { Assert-NoActiveLabOperation $root } 'owned local-operation process remains active'
}
& {
    # Execute the real transport body; mock only Windows process/filesystem boundaries.
    $source = $remoteAst.ScriptBlock.GetScriptBlock().ToString()
    foreach ($lockCall in @(
        '[IO.File]::Open("$operationRoot\observer.lock", ''OpenOrCreate'', ''ReadWrite'', ''None'')',
        '[IO.File]::Open($operationLockPath, ''OpenOrCreate'', ''ReadWrite'', ''None'')')) {
        if (-not $source.Contains($lockCall)) { throw 'Local-operation lock contract changed.' }
        $source = $source.Replace($lockCall, '(New-FakeControlLock)')
    }
    $code = [scriptblock]::Create($source)
    function New-FakeControlLock {
        $lock = [pscustomobject]@{}
        $lock | Add-Member ScriptMethod Dispose {}
        $lock
    }
    function icacls.exe { $global:LASTEXITCODE = 0 }
    function New-Item { param($ItemType, $Path, [switch]$Force) }
    function Join-Path { param($Path, $ChildPath) "$Path\$ChildPath" }
    function Set-Content {
        [CmdletBinding()]
        param([Parameter(Position=0)]$Path, [Parameter(Position=1,ValueFromPipeline)]$Value, $Encoding)
        begin { $parts = @() }
        process { $parts += $Value }
        end { $script:operationFiles[$Path] = $parts -join "`n" }
    }
    function Test-Path { param($Path) $script:operationFiles.ContainsKey($Path) }
    function Get-Content { param($Path, [switch]$Raw) $script:operationFiles[$Path] }
    function Get-Date { [DateTime]::UtcNow.AddSeconds(-$script:elapsedSeconds) }
    function Write-Host { param($Object) }
    function Get-CimInstance { param($ClassName, $Filter, $ErrorAction) }
    function Get-ScheduledTask { param($TaskName, $ErrorAction) $script:legacyTasks }
    function Start-Process {
        param($FilePath, $ArgumentList, $Credential, [switch]$LoadUserProfile, [switch]$Wait, [switch]$PassThru,
            $RedirectStandardOutput, $RedirectStandardError, $ErrorAction)
        if (-not $Wait -or -not $PassThru -or -not $LoadUserProfile -or
            $Credential.UserName -ne 'JUMPSTART\Administrator' -or $Credential.GetNetworkCredential().Password -ne 'test-only-secret' -or
            -not $FilePath.EndsWith('\powershell.exe') -or -not $RedirectStandardOutput.EndsWith('\stdout.log') -or
            -not $RedirectStandardError.EndsWith('\stderr.log') -or $ArgumentList -notlike '*-NoProfile -NonInteractive*') {
            throw 'Local credentialed process must use the proven synchronous flags and isolated output files.'
        }
        $script:starts++
        $started = [DateTime]::UtcNow
        if (-not $script:missingReceipt) {
            $completion = @{
                AttemptId = $script:receiptAttempt; Status = $(if ($script:nativeCode) { 'Failed' } else { 'Completed' }); ExitCode = $script:nativeCode
                ProcessId = 123; ProcessStartUtc = $started.ToString('o'); StartedUtc = $started.ToString('o'); CompletedUtc = $started.ToString('o')
                Identity = $Credential.UserName; IsAdministrator = $true; RemoteSession = $false
                Error = 'captured native failure'; ErrorId = 'ActionFailure'
            }
            $script:operationFiles['C:\ArcJumpstart\Operations\ArcJumpstart-CreateCluster\fresh\result.json'] = $completion | ConvertTo-Json
        }
        [pscustomobject]@{ Id = 123; StartTime = $started; ExitCode = $script:nativeCode; HasExited = $true }
    }
    function Reset-ProcessCase {
        $script:operationFiles = @{}; $script:starts = 0; $script:nativeCode = 0; $script:elapsedSeconds = 0
        $script:legacyTasks = @(); $script:receiptAttempt = 'fresh'; $script:missingReceipt = $false
    }
    $credential = [pscredential]::new('JUMPSTART\Administrator', (ConvertTo-SecureString 'test-only-secret' -AsPlainText -Force))
    $invokeProcess = { & $code $credential 'ArcJumpstart-CreateCluster' 'Write-Output action' 6 fresh }
    Reset-ProcessCase
    $result = & $invokeProcess
    if ($result.AttemptId -ne 'fresh' -or $script:starts -ne 1 -or -not ($script:operationFiles.Keys -like '*exit-observation.json')) {
        throw 'Require one synchronous process, matching completion, and retained native exit evidence.'
    }
    if (($script:operationFiles.Values -join "`n").Contains('test-only-secret')) { throw 'Credentials must never be serialized into generated scripts or evidence.' }
    foreach ($state in @('Queued', 'Running')) {
        Reset-ProcessCase
        $script:legacyTasks = @(@{ TaskName = 'ArcJumpstart-CreateCluster'; State = $state })
        Assert-Throws $invokeProcess 'Legacy tasks remain active'
        if ($script:starts) { throw 'Legacy active work must prevent a new process.' }
    }
    Reset-ProcessCase; $script:missingReceipt = $true
    Assert-Throws $invokeProcess 'Missing, stale'
    Reset-ProcessCase; $script:receiptAttempt = 'stale'
    Assert-Throws $invokeProcess 'Missing, stale'
    Reset-ProcessCase; $script:nativeCode = 7
    Assert-Throws $invokeProcess 'captured native failure'
    Reset-ProcessCase; $script:elapsedSeconds = 10
    Assert-Throws $invokeProcess 'completed successfully but exceeded'
    if ($script:starts -ne 1 -or -not ($script:operationFiles.Keys -like '*result.json')) { throw 'Budget handling must wait for completion and retain evidence, never kill the process.' }
}

# Run the generated wrapper locally; replace only the Windows token lookup.
& {
    $wrapperAssignment = $helperAst.Find({
        param($n)
        $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$wrappedScript'
    }, $true)
    $AttemptId = [guid]::NewGuid().ToString('N')
    $prefix = Join-Path (Get-Location) ".stage60-wrapper-$AttemptId"
    $actionPath = "$prefix-action.ps1"; $resultPath = "$prefix-result.json"; $outputPath = "$prefix-output.log"
    $wrapperPath = "$prefix.ps1"; $scriptPath = $wrapperPath
    $activePath = "$prefix-active.json"; $operationLockPath = "$prefix.lock"; $Operation = 'Test'
    try {
        $wrapper = & ([scriptblock]::Create($wrapperAssignment.Extent.Text + "`n" + '$wrappedScript'))
        $wrapperAst = [Management.Automation.Language.Parser]::ParseInput($wrapper, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw ($errors.Message -join '; ') }
        $identityFunction = $wrapperAst.Find({
            param($n)
            $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-LocalExecutionIdentity'
        }, $true)
        $wrapper = $wrapper.Replace($identityFunction.Extent.Text, 'function Get-LocalExecutionIdentity { @{ Identity = "JUMPSTART\Administrator"; IsAdministrator = $true; RemoteSession = $false } }')
        Set-Content $wrapperPath $wrapper -Encoding UTF8
        foreach ($case in @(@('Write-Output action-output', 0), @('Write-Output action-output; throw "action exploded"', 1),
            @('Write-Output action-output; Write-Error "action error"', 1), @('Write-Output action-output; exit 7', 7))) {
            Set-Content $actionPath $case[0] -Encoding UTF8
            $submitted = [DateTime]::UtcNow
            $process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-File', "`"$wrapperPath`"") -Wait -PassThru `
                -RedirectStandardOutput $outputPath -RedirectStandardError "$prefix-error.log"
            $completion = Get-Content $resultPath -Raw | ConvertFrom-Json
            if ($process.ExitCode -ne $case[1] -or $completion.ExitCode -ne $case[1] -or
                $completion.AttemptId -cne $AttemptId -or -not $completion.StartedUtc -or -not $completion.CompletedUtc) {
                throw 'Wrapper must retain its actual completed action exit code and fresh attempt identity.'
            }
            if ($case[1] -and (-not $completion.Error -or -not $completion.ErrorId)) { throw 'Action failure details were not captured.' }
            if ((Get-Content $outputPath -Raw) -notlike '*action-output*') { throw 'Action output must be retained.' }
            if ($case[1] -eq 0) { Assert-LocalProcessCompletion $process $completion $AttemptId 'JUMPSTART\Administrator' $submitted }
            else { Assert-Throws { Assert-LocalProcessCompletion $process $completion $AttemptId 'JUMPSTART\Administrator' $submitted } 'Local operation failed' }
            $active = Get-Content $activePath -Raw | ConvertFrom-Json
            if ($active.ProcessId -ne $process.Id -or $active.AttemptId -ne $AttemptId -or
                $active.ProcessStartUtc -ne $completion.ProcessStartUtc) { throw 'Persist PID, start time, and token for safe process identity inspection.' }
        }
    }
    finally {
        Remove-Item $actionPath, $resultPath, "$resultPath.new", $outputPath, $wrapperPath, $activePath,
            "$activePath.new", $operationLockPath, "$prefix-error.log" -Force -ErrorAction SilentlyContinue
    }
}

. ([scriptblock]::Create((Get-FunctionText Get-ExpectedClusterComputer)))
& {
    $probeAst = $ast.Find({
        param($n)
        $n -is [Management.Automation.Language.ScriptBlockExpressionAst] -and
            $n.Extent.Text.Contains('Fresh cluster validation postcondition is missing')
    }, $true)
    $probe = $probeAst.ScriptBlock.GetScriptBlock()
    function Test-Path { param($Path) $script:proofExists }
    function Get-Content {
        param($Path, [switch]$Raw)
        @{ AttemptId = $script:proofAttempt; ValidatedUtc = '2026-09-17T00:00:00Z'
            Nodes = @('JS-SQL-AG-01', 'JS-SQL-AG-02'); ReportPath = 'retained-report.htm' } | ConvertTo-Json
    }
    $script:proofExists = $false
    Assert-Throws { & $probe fresh JS-SQL-AG-01 JS-SQL-AG-02 } 'Fresh cluster validation postcondition is missing'
    $script:proofExists = $true; $script:proofAttempt = 'stale'
    Assert-Throws { & $probe fresh JS-SQL-AG-01 JS-SQL-AG-02 } 'do not match this invocation'
    $script:proofAttempt = 'fresh'
    & $probe fresh JS-SQL-AG-01 JS-SQL-AG-02
}
& {
    function Get-ADDomain { param($ErrorAction) @{ NetBIOSName = 'JUMPSTART' } }
    function Get-ADComputer {
        param($Identity, $Properties, $ErrorAction)
        if ($script:cnoMissing) { throw 'object not found' }
        $script:cno
    }
    $script:cnoMissing = $true
    Assert-Throws { Get-ExpectedClusterComputer JUMPSTART JS-SQLCLU } 'JUMPSTART\JS-SQLCLU$ is absent'
    $script:cnoMissing = $false
    $script:cno = @{ SamAccountName = 'JS-SQLCLU$'; Enabled = $true; SID = 'S-1-5-21-1-2-3-1001' }
    if ((Get-ExpectedClusterComputer JUMPSTART JS-SQLCLU).SID -ne $script:cno.SID) { throw 'Use the actual AD CNO SID for ACLs.' }
    $script:cno.Enabled = $false
    Assert-Throws { Get-ExpectedClusterComputer JUMPSTART JS-SQLCLU } 'disabled, or mismatched'
    Assert-Throws { Get-ExpectedClusterComputer WRONG JS-SQLCLU } "not in this DC's domain"
}
$text = $ast.Extent.Text
$orderedGates = @(
    $text.IndexOf('$validationRun = Invoke-GuestLocalProcess'),
    $text.IndexOf('Fresh cluster validation postcondition is missing'),
    $text.IndexOf('$clusterScript ='),
    $text.IndexOf('$verifyClusterScript ='),
    $text.IndexOf('$clusterComputer = Get-ExpectedClusterComputer'),
    $text.IndexOf('$witnessAcl.SetAccessRule')
)
for ($i = 1; $i -lt $orderedGates.Count; $i++) {
    if ($orderedGates[$i - 1] -lt 0 -or $orderedGates[$i] -le $orderedGates[$i - 1]) { throw 'Validation -> cluster membership -> CNO -> witness ACL ordering is required.' }
}
Write-Output 'Stage 60 local-process transport, completion evidence, active-operation safety, cluster/CNO postconditions and existing AG regression checks passed.'
