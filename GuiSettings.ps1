#MTAudotDraw
#Copyright (C) 2022  Myles Treadwell
#
#This program is free software: you can redistribute it and/or modify
#it under the terms of the GNU General Public License as published by
#the Free Software Foundation, either version 3 of the License, or
#(at your option) any later version.
#
#This program is distributed in the hope that it will be useful,
#but WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#GNU General Public License for more details.
#
#You should have received a copy of the GNU General Public License
#along with this program.  If not, see <http://www.gnu.org/licenses/>.

# MTAutoDraw - GUI support
#
# Everything the GUI needs that is not a window: the settings model read out of
# configurationVariables.ps1, profile storage, the prerequisite checks, and the parser for a run's
# log lines. No WinForms type is referenced anywhere in this file, which is what makes all of it
# testable without opening a window.
#
# Deliberately NOT in AutoDraw.ps1's $GLibrariesToLoad. The GUI launches the pipeline as a child
# process; it is not part of it, and nothing in the pipeline may grow a dependency on this file.
#
# Depends on: nothing
# Loaded by:  MTAutoDrawGui.ps1

# Where the repository lives, from this file's own location. Everything else is derived from it, so
# the GUI works from any working directory.
function Get-MTAutoDrawRepositoryRoot {
    [CmdletBinding()]
    param()
    return $PSScriptRoot
}

# ------------------------------------------------------------------------------------------------
# The settings model
#
# Read from configurationVariables.ps1 by parsing it, never by running it. Two reasons: running it
# needs $GPathToScript set and scans the Templates directory, and a settings editor that executes
# the file it is editing is a bad shape. The AST gives the name, the default, and - via the comment
# block above each assignment - the help text, which is the documentation these settings already
# have and the only copy that stays true when someone adds one.
# ------------------------------------------------------------------------------------------------

# Assignments that parse as constants but are not user settings. Everything else with a constant
# right-hand side is surfaced. A new setting must appear either in the Advanced tab or in this skip
# list, so this list going stale surfaces as an error rather than a silently missing control.
$script:MTAutoDrawSettingSkip = @(
    'GMTAutoDrawVersion'              # identifies the build, not a preference
    'GPathToPythonTextFSMScript'      # derived from the repository layout
    'GTextFSMTemplates'               # populated by a directory scan
    'GruntimePortChannelStyles'       # runtime cache
    'GDrawioArrayOfInterfaceTypes'    # a table, not a scalar
    'GPerfTiming'                     # driven by the MTAUTODRAW_PERF environment variable
    'GLogLevel'                       # the GUI passes -LogLevel, which outranks the file
)

# The settings whose value is one of a fixed set. There is no machine-readable declaration of these
# in configurationVariables.ps1 - the allowed values live in its prose and in the switch statements
# that consume them - so the lists are kept here and checked against those consumers by the tests.
$script:MTAutoDrawSettingOptions = @{
    GDrawioTopologyPlacementStrategy = @(
        'Radial', 'SwapAnneal', 'Layered', 'DegreeRings', 'Spiral', 'Spine', 'SpineRadial',
        'Balloon', 'Force', 'ForceSeeded', 'Community', 'Prefix', 'Treemap', 'HTree'
    )
    GDrawioTopologyPlacementPostPass    = @('None', 'GridSnap', 'Gravity')
    GDrawioTopologyRadialRingSpacing    = @('Bound', 'Exact')
    GDrawioTopologyRadialClusterPacking = @('Shelf', 'Corner')
    GDrawioTopologyEndUnitMode          = @('None', 'Stack', 'Grid', 'Wide', 'Chip')
}

# Unwraps the right-hand side of an assignment to the expression that carries the value. A settings
# assignment is a single expression; anything with more to it is code, not a setting.
#
# Two shapes reach here. A plain `$x = 5` gives a CommandExpressionAst directly, while an assignment
# the parser treated as a pipeline gives a PipelineAst wrapping one. Both are unwrapped to the same
# expression; a pipeline with more than one element is a computation and is refused.
function Get-MTAutoDrawSettingValueExpression {
    [CmdletBinding()]
    param([AllowNull()]$Statement)

    if ($Statement -is [System.Management.Automation.Language.CommandExpressionAst]) {
        return $Statement.Expression
    }
    if ($Statement -is [System.Management.Automation.Language.PipelineAst]) {
        $elements = @($Statement.PipelineElements)
        if ($elements.Count -ne 1) { return $null }
        if ($elements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) { return $null }
        return $elements[0].Expression
    }
    return $null
}

# The comment block immediately above a setting, as its help text. Walks up from the assignment and
# stops at the first line that is not a plain '#' comment - a blank line, code, or one of the
# '######' / '## --- Section ---' banners, which introduce a region rather than describe a setting.
function Get-MTAutoDrawSettingHelp {
    [CmdletBinding()]
    param(
        # Not Mandatory, and both Allow attributes: a mandatory [string[]] rejects the empty strings
        # that every blank line in the file becomes, which is most of what is being scanned past.
        [AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines = @(),
        [Parameter(Mandatory = $true)][int]$AssignmentLineNumber
    )

    $collected = [System.Collections.Generic.List[string]]::new()
    for ($index = $AssignmentLineNumber - 2; $index -ge 0; $index--) {
        $line = $Lines[$index]
        if ($line -notmatch '^\s*#') { break }
        if ($line -match '^\s*#{5,}\s*$') { break }
        if ($line -match '^\s*##') { break }
        if ($line -match '^\s*#\s*---.*---\s*$') { break }
        [void]$collected.Add(($line -replace '^\s*#\s?', '').TrimEnd())
    }
    if ($collected.Count -eq 0) { return '' }
    $collected.Reverse()
    return (($collected -join ' ').Trim() -replace '\s{2,}', ' ')
}

<#
.SYNOPSIS
Every user-settable value in configurationVariables.ps1, with its type, default, and help text.

.DESCRIPTION
Returns one object per setting: Name, Type (Bool|Int|Double|String|Enum), Default, Options, Help,
and LineNumber. Only assignments whose right-hand side is a constant qualify - an interpolated path,
a hashtable, or anything computed is code rather than a preference and is left alone.
#>
function Get-MTAutoDrawSettingDefinition {
    [CmdletBinding()]
    param([string]$ConfigurationPath)

    if (-not $ConfigurationPath) {
        $ConfigurationPath = Join-Path (Get-MTAutoDrawRepositoryRoot) 'configurationVariables.ps1'
    }
    if (-not (Test-Path -LiteralPath $ConfigurationPath)) {
        throw "Configuration file not found: $ConfigurationPath"
    }

    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ConfigurationPath, [ref]$null, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw "Could not parse $ConfigurationPath - $(@($parseErrors)[0].Message)"
    }
    $lines = [System.IO.File]::ReadAllLines($ConfigurationPath)

    $assignments = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)

    foreach ($assignment in $assignments) {
        if ($assignment.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $name = $assignment.Left.VariablePath.UserPath
        # A scope prefix means the assignment is reaching past the file's own defaults on purpose.
        if ($name -like '*:*') { continue }
        if ($name -notlike 'G*') { continue }
        if ($script:MTAutoDrawSettingSkip -contains $name) { continue }

        $expression = Get-MTAutoDrawSettingValueExpression -Statement $assignment.Right
        if (-not $expression) { continue }
        # SafeGetValue evaluates constants and throws on anything that would need the runtime, which
        # is exactly the line between a setting and code. Never Invoke-Expression here.
        try { $value = $expression.SafeGetValue() } catch { continue }

        $type = $null
        if ($value -is [bool]) { $type = 'Bool' }
        elseif ($value -is [int] -or $value -is [long]) { $type = 'Int' }
        elseif ($value -is [double] -or $value -is [decimal]) { $type = 'Double' }
        elseif ($value -is [string]) {
            $type = if ($script:MTAutoDrawSettingOptions.ContainsKey($name)) { 'Enum' } else { 'String' }
        }
        if (-not $type) { continue }

        [pscustomobject]@{
            Name       = $name
            Type       = $type
            Default    = $value
            Options    = @(if ($type -eq 'Enum') { $script:MTAutoDrawSettingOptions[$name] })
            Help       = Get-MTAutoDrawSettingHelp -Lines $lines -AssignmentLineNumber $assignment.Extent.StartLineNumber
            LineNumber = $assignment.Extent.StartLineNumber
        }
    }
}

# Names the settings model deliberately leaves out, so a test can tell "excluded on purpose" from
# "quietly missed".
function Get-MTAutoDrawSettingSkipName {
    [CmdletBinding()]
    param()
    return @($script:MTAutoDrawSettingSkip)
}

# ------------------------------------------------------------------------------------------------
# The curated set
#
# The settings that change what you get, as opposed to how it is arranged. These are the ones on the
# Run tab; everything else is reachable on Advanced. Ordered, grouped, and labelled in the language
# of the output rather than the language of the variable.
# ------------------------------------------------------------------------------------------------
function Get-MTAutoDrawCuratedSettingGroup {
    [CmdletBinding()]
    param()

    return [ordered]@{
        'Whole-site pages' = @(
            @{ Name = 'GDrawMultipleDevicesDiagram'; Label = 'Produce the multi-device file'; Master = $true }
            @{ Name = 'GDrawSiteTopologyOverview';   Label = 'Topology Overview' }
            @{ Name = 'GDrawLayer3TopologyOverview'; Label = 'Layer 3 Topology Overview' }
            @{ Name = 'GDrawLayer3Connectivity';     Label = 'Layer 3 Connectivity' }
            @{ Name = 'GDrawLayer3RoutesSummary';    Label = 'Layer 3 Routes Summary' }
            @{ Name = 'GDrawCDPALL';                 Label = 'CDP/LLDP - all neighbours' }
            @{ Name = 'GDrawCDP';                    Label = 'CDP/LLDP - brief' }
            @{ Name = 'GDrawLayer3RoutedLinksOnly';  Label = 'Layer 3 Routed Links Only' }
            @{ Name = 'GDrawLayer3RoutesOnly';       Label = 'Layer 3 Routes Only' }
            @{ Name = 'GDrawSpanningTree';           Label = 'Spanning-Tree' }
        )
        'Firewall pages' = @(
            @{ Name = 'GDrawFirewallOverview';       Label = 'Firewall Overview' }
            @{ Name = 'GDrawFirewallZoneHub';        Label = 'Firewall Zone Hub' }
            @{ Name = 'GDrawFirewallNatInterfaces';  Label = 'Firewall NAT and Interfaces' }
            @{ Name = 'GDrawFirewallRuleRisk';       Label = 'Firewall Rule Risk' }
        )
        'Per-device pages' = @(
            @{ Name = 'GdrawSingles';                Label = 'Produce the per-device file'; Master = $true }
            @{ Name = 'GDrawPhysical';               Label = 'Physical port layout' }
        )
        # $GDrawLayer3 drives the whole-site "Layer 3 All" page AND the per-device Layer 3 page, so it
        # gets one control that says so rather than two that move together for no visible reason.
        'Layer 3 detail' = @(
            @{ Name = 'GDrawLayer3';                 Label = 'Layer 3 pages (whole-site and per-device)' }
        )
        'What the pages include' = @(
            @{ Name = 'GDrawAprEntries';                   Label = 'ARP entries' }
            @{ Name = 'GDrawAprEntriesDetails';            Label = 'ARP entries in full detail' }
            @{ Name = 'GSkipCDPLLDPPhones';                Label = 'Leave IP phones out' }
            @{ Name = 'GSkipHSRPRoutes';                   Label = 'Leave HSRP routes out' }
            @{ Name = 'GConsolidateNeighbors';             Label = 'Consolidate repeated neighbours' }
            @{ Name = 'GSuppressFloodedNeighbors';         Label = 'Suppress flooded neighbours' }
            @{ Name = 'GIncludeInferredTopologyEvidence';  Label = 'Draw inferred topology evidence' }
            @{ Name = 'GIncludeAmbiguousTopologyEvidence'; Label = 'Include ambiguous evidence' }
        )
        'Output' = @(
            @{ Name = 'GExportData';                 Label = 'Write the CSV and JSON exports' }
        )
    }
}

# The two masters and what they gate, so the GUI can grey out controls that would have no effect.
function Get-MTAutoDrawSettingMasterMap {
    [CmdletBinding()]
    param()

    return @{
        GDrawMultipleDevicesDiagram = @(
            'GDrawSiteTopologyOverview', 'GDrawLayer3TopologyOverview', 'GDrawLayer3Connectivity',
            'GDrawLayer3RoutesSummary', 'GDrawCDPALL', 'GDrawCDP', 'GDrawLayer3RoutedLinksOnly',
            'GDrawLayer3RoutesOnly', 'GDrawSpanningTree', 'GDrawFirewallOverview',
            'GDrawFirewallZoneHub', 'GDrawFirewallNatInterfaces', 'GDrawFirewallRuleRisk'
        )
        GdrawSingles = @('GDrawPhysical')
    }
}

# Every curated name, flattened - the Advanced tab shows what is left over.
function Get-MTAutoDrawCuratedSettingName {
    [CmdletBinding()]
    param()

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($group in (Get-MTAutoDrawCuratedSettingGroup).Values) {
        foreach ($entry in $group) { [void]$names.Add([string]$entry.Name) }
    }
    return @($names)
}

# ------------------------------------------------------------------------------------------------
# Profiles and window state
#
# Stored under %APPDATA%, never in the repository: a git pull must not clobber a user's settings, and
# a working tree is not reliably writable. The root is overridable so tests never touch real state.
# ------------------------------------------------------------------------------------------------
$script:MTAutoDrawGuiDataRoot = $null

function Set-MTAutoDrawGuiDataRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $script:MTAutoDrawGuiDataRoot = $Path
}

function Get-MTAutoDrawGuiDataRoot {
    [CmdletBinding()]
    param()
    if ($script:MTAutoDrawGuiDataRoot) { return $script:MTAutoDrawGuiDataRoot }
    return (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'MTAutoDraw')
}

function Get-MTAutoDrawProfileDirectory {
    [CmdletBinding()]
    param()
    return (Join-Path (Get-MTAutoDrawGuiDataRoot) 'Profiles')
}

function Get-MTAutoDrawGuiStatePath {
    [CmdletBinding()]
    param()
    return (Join-Path (Get-MTAutoDrawGuiDataRoot) 'gui-state.json')
}

# A profile carries the run's inputs and only the settings that differ from the file defaults, so it
# stays readable and picks up future default changes instead of pinning today's values forever.
function New-MTAutoDrawProfile {
    [CmdletBinding()]
    param(
        [string]$Name = '',
        [string]$InputDirectory = '',
        [string]$OutputDirectory = '',
        [ValidateSet('Error', 'Warn', 'Info', 'Debug', 'Trace')][string]$LogLevel = 'Info',
        [hashtable]$Settings = @{}
    )

    return [ordered]@{
        SchemaVersion   = '1.0'
        Name            = $Name
        InputDirectory  = $InputDirectory
        OutputDirectory = $OutputDirectory
        LogLevel        = $LogLevel
        Settings        = $Settings
    }
}

function Save-MTAutoDrawProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$ProfileData,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Name -match '[\\/:*?"<>|]') { throw "Profile name contains a character a file name cannot: $Name" }
    $directory = Get-MTAutoDrawProfileDirectory
    if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory -Force }
    $ProfileData.Name = $Name
    $path = Join-Path $directory "$Name.json"
    $ProfileData | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

function Read-MTAutoDrawProfile {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$Path
    )

    if (-not $Path) {
        if (-not $Name) { throw 'Read-MTAutoDrawProfile needs -Name or -Path.' }
        $Path = Join-Path (Get-MTAutoDrawProfileDirectory) "$Name.json"
    }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Profile not found: $Path" }

    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $settings = @{}
    if ($raw.Settings) {
        foreach ($property in $raw.Settings.PSObject.Properties) { $settings[$property.Name] = $property.Value }
    }
    $logLevel = if ($raw.LogLevel) { [string]$raw.LogLevel } else { 'Info' }
    return New-MTAutoDrawProfile -Name ([string]$raw.Name) -InputDirectory ([string]$raw.InputDirectory) `
        -OutputDirectory ([string]$raw.OutputDirectory) -LogLevel $logLevel -Settings $settings
}

function Get-MTAutoDrawProfileName {
    [CmdletBinding()]
    param()

    $directory = Get-MTAutoDrawProfileDirectory
    if (-not (Test-Path -LiteralPath $directory)) { return @() }
    return @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File | Sort-Object Name | ForEach-Object { $_.BaseName })
}

function Remove-MTAutoDrawProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)

    $path = Join-Path (Get-MTAutoDrawProfileDirectory) "$Name.json"
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

# Only what the user actually changed. Comparison is on the string form so an Int control returning
# 5 and a default of 5 are the same value regardless of how each arrived.
function Get-MTAutoDrawChangedSetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Definitions,
        [Parameter(Mandatory = $true)][hashtable]$Values
    )

    $changed = @{}
    foreach ($definition in @($Definitions)) {
        if (-not $Values.ContainsKey($definition.Name)) { continue }
        $current = $Values[$definition.Name]
        if ([string]$current -ne [string]$definition.Default) { $changed[$definition.Name] = $current }
    }
    return $changed
}

# The file AutoDraw.ps1 -SettingsPath reads. Flat name/value JSON; the pipeline applies only keys it
# recognises and warns about the rest.
function Write-MTAutoDrawSettingsFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Settings,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    $ordered = [ordered]@{}
    foreach ($key in @($Settings.Keys | Sort-Object)) { $ordered[$key] = $Settings[$key] }
    ([pscustomobject]$ordered) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding utf8
    return $Path
}

# ------------------------------------------------------------------------------------------------
# Prerequisites
#
# The checks AutoDraw.ps1 makes on its way past, made ahead of time and all at once, so a first run
# fails in a dialog that says what to do rather than on line 167 of a script.
# ------------------------------------------------------------------------------------------------

# Status is Pass, Fail, or Info. Info is for things worth saying that are not a problem.
function New-MTAutoDrawPreflightResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter(Mandatory = $true)][ValidateSet('Pass', 'Fail', 'Info')][string]$Status,
        [AllowEmptyString()][string]$Detail = '',
        [AllowEmptyString()][string]$Fix = ''
    )

    return [pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail; Fix = $Fix }
}

# The interpreter a run will use: an explicit choice, else the bundled location.
function Get-MTAutoDrawDefaultPythonPath {
    [CmdletBinding()]
    param()
    return (Join-Path (Get-MTAutoDrawRepositoryRoot) 'python\python.exe')
}

function Test-MTAutoDrawTextFsmAvailable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PythonPath)

    if (-not (Test-Path -LiteralPath $PythonPath)) { return $false }
    try {
        $null = & $PythonPath '-c' 'import textfsm' 2>&1
        return ($LASTEXITCODE -eq 0)
    }
    catch { return $false }
}

function Get-MTAutoDrawPreflight {
    [CmdletBinding()]
    param(
        [string]$PythonPath,
        [string]$OutputDirectory
    )

    $root = Get-MTAutoDrawRepositoryRoot
    if (-not $PythonPath) { $PythonPath = Get-MTAutoDrawDefaultPythonPath }

    if ($PSVersionTable.PSVersion.Major -ge 7) {
        New-MTAutoDrawPreflightResult -Check 'PowerShell 7 or later' -Status Pass -Detail $PSVersionTable.PSVersion.ToString()
    }
    else {
        New-MTAutoDrawPreflightResult -Check 'PowerShell 7 or later' -Status Fail `
            -Detail "Running on $($PSVersionTable.PSVersion)" `
            -Fix 'The parser uses ForEach-Object -Parallel, which is 7+ only. Install PowerShell 7 from https://aka.ms/powershell'
    }

    $pythonPresent = Test-Path -LiteralPath $PythonPath
    if ($pythonPresent) {
        New-MTAutoDrawPreflightResult -Check 'Python interpreter' -Status Pass -Detail $PythonPath
    }
    else {
        New-MTAutoDrawPreflightResult -Check 'Python interpreter' -Status Fail -Detail "Not found at $PythonPath" `
            -Fix 'Use Set up Python to download an embeddable interpreter, or Browse to one you already have.'
    }

    if (-not $pythonPresent) {
        New-MTAutoDrawPreflightResult -Check 'textfsm package' -Status Fail -Detail 'No interpreter to check' `
            -Fix 'Resolve the Python interpreter first.'
    }
    elseif (Test-MTAutoDrawTextFsmAvailable -PythonPath $PythonPath) {
        New-MTAutoDrawPreflightResult -Check 'textfsm package' -Status Pass -Detail 'import textfsm succeeded'
    }
    else {
        New-MTAutoDrawPreflightResult -Check 'textfsm package' -Status Fail -Detail 'import textfsm failed' `
            -Fix "Install it with: `"$PythonPath`" -m pip install textfsm"
    }

    $textFsmScript = Join-Path $root 'TextFSM.py'
    if (Test-Path -LiteralPath $textFsmScript) {
        New-MTAutoDrawPreflightResult -Check 'TextFSM.py' -Status Pass -Detail $textFsmScript
    }
    else {
        New-MTAutoDrawPreflightResult -Check 'TextFSM.py' -Status Fail -Detail "Missing: $textFsmScript" `
            -Fix 'TextFSM.py is tracked in the repository - this working tree is incomplete. Re-clone or restore the file.'
    }

    $templateDirectory = Join-Path $root 'Templates'
    $templateCount = 0
    if (Test-Path -LiteralPath $templateDirectory) {
        $templateCount = @(Get-ChildItem -LiteralPath $templateDirectory -Filter '*.textfsm' -File -ErrorAction SilentlyContinue).Count
    }
    if ($templateCount -gt 0) {
        New-MTAutoDrawPreflightResult -Check 'TextFSM templates' -Status Pass -Detail "$templateCount templates"
    }
    else {
        New-MTAutoDrawPreflightResult -Check 'TextFSM templates' -Status Fail -Detail "No .textfsm files under $templateDirectory" `
            -Fix 'The Templates directory is tracked - this working tree is incomplete. Re-clone or restore it.'
    }

    $subnetModule = Join-Path $root 'GETIPV4Subnet\GetIPv4Subnet.psm1'
    if (Test-Path -LiteralPath $subnetModule) {
        New-MTAutoDrawPreflightResult -Check 'GetIPv4Subnet module' -Status Pass -Detail $subnetModule
    }
    else {
        New-MTAutoDrawPreflightResult -Check 'GetIPv4Subnet module' -Status Fail -Detail "Missing: $subnetModule" `
            -Fix 'The module is tracked - this working tree is incomplete. Re-clone or restore it.'
    }

    if ($OutputDirectory) {
        $writable = $false
        $detail = ''
        try {
            if (-not (Test-Path -LiteralPath $OutputDirectory)) {
                $null = New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction Stop
            }
            $probe = Join-Path $OutputDirectory ".mtautodraw-write-probe-$([Guid]::NewGuid().ToString('N')).tmp"
            Set-Content -LiteralPath $probe -Value 'probe' -ErrorAction Stop
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            $writable = $true
        }
        catch { $detail = $_.Exception.Message }

        if ($writable) {
            New-MTAutoDrawPreflightResult -Check 'Output folder' -Status Pass -Detail $OutputDirectory
        }
        else {
            New-MTAutoDrawPreflightResult -Check 'Output folder' -Status Fail -Detail $detail -Fix 'Choose a folder you can write to.'
        }
    }

    # Not a problem, but the one thing the tool does that reaches the internet, so it is said out
    # loud rather than discovered in a firewall log. See README, Outbound Network Connections.
    $ouiPath = Join-Path $root 'MacAddressToVendorsMapping.csv'
    if (Test-Path -LiteralPath $ouiPath) {
        New-MTAutoDrawPreflightResult -Check 'MAC vendor mapping' -Status Info -Detail 'Present - no download needed'
    }
    else {
        New-MTAutoDrawPreflightResult -Check 'MAC vendor mapping' -Status Info `
            -Detail 'Absent - the first run downloads the OUI list from devtools360.com and caches it' `
            -Fix 'Only affects vendor names on shapes and in exports. Everything else runs offline.'
    }
}

# ------------------------------------------------------------------------------------------------
# Guided Python setup
#
# The steps only. Every confirmation, and every decision to reach the network at all, belongs to the
# caller - these functions do what they are told and report what happened.
# ------------------------------------------------------------------------------------------------

# Pinned rather than "latest": a known-good embeddable build keeps a first run reproducible, and the
# version moving under a user is not a surprise worth having.
$script:MTAutoDrawPythonVersion = '3.12.7'

function Get-MTAutoDrawPythonDownloadPlan {
    [CmdletBinding()]
    param([string]$Version = $script:MTAutoDrawPythonVersion)

    return [pscustomobject]@{
        Version         = $Version
        PythonUrl       = "https://www.python.org/ftp/python/$Version/python-$Version-embed-amd64.zip"
        PythonFileName  = "python-$Version-embed-amd64.zip"
        ApproximateSize = 'about 11 MB'
        GetPipUrl       = 'https://bootstrap.pypa.io/get-pip.py'
        GetPipFileName  = 'get-pip.py'
    }
}

# The embeddable build ships with site-packages disabled, which is why pip cannot see anything
# installed until the '#import site' line in python3xx._pth is uncommented.
function Enable-MTAutoDrawPythonSitePackages {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PythonDirectory)

    $pthFiles = @(Get-ChildItem -LiteralPath $PythonDirectory -Filter '*._pth' -File -ErrorAction SilentlyContinue)
    if ($pthFiles.Count -eq 0) { return $false }
    foreach ($pth in $pthFiles) {
        $content = Get-Content -LiteralPath $pth.FullName
        $updated = $content -replace '^\s*#\s*import\s+site\s*$', 'import site'
        if (-not ($updated -match '^\s*import\s+site\s*$')) { $updated += 'import site' }
        Set-Content -LiteralPath $pth.FullName -Value $updated
    }
    return $true
}

function Expand-MTAutoDrawPython {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory
    )

    if (-not (Test-Path -LiteralPath $DestinationDirectory)) {
        $null = New-Item -ItemType Directory -Path $DestinationDirectory -Force
    }
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $DestinationDirectory -Force
    $null = Enable-MTAutoDrawPythonSitePackages -PythonDirectory $DestinationDirectory
    return (Join-Path $DestinationDirectory 'python.exe')
}

# ------------------------------------------------------------------------------------------------
# Run output
#
# The log line shape is fixed by Format-MTAutoDrawLogLine in Logging.ps1:
#   [mm:ss.ff] LEVEL   phase    message
# Parsed rather than reformatted, so the GUI shows exactly what the transcript recorded.
# ------------------------------------------------------------------------------------------------
$script:MTAutoDrawLogLinePattern = '^\[(?<minutes>\d+):(?<seconds>\d{2})\.(?<hundredths>\d{2})\]\s+(?<level>\S+)\s+(?<phase>\S+)\s*(?<message>.*)$'

# The phases in the order a run reaches them, from Write-MTAutoDrawLog's ValidateSet. Drives the
# progress strip; a line whose phase is not one of these (a perf line, say) does not move it.
function Get-MTAutoDrawPhaseOrder {
    [CmdletBinding()]
    param()
    return @('Load', 'Ingest', 'Parse', 'Resolve', 'Draw', 'Export', 'Summary')
}

# Returns Level, Phase, Message and Elapsed, or $null when the line is not one of ours - console
# noise and native stderr both reach the GUI, and neither should be dressed up as a log record.
function ConvertFrom-MTAutoDrawLogLine {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    $match = [regex]::Match($Line, $script:MTAutoDrawLogLinePattern)
    if (-not $match.Success) { return $null }

    $elapsed = [TimeSpan]::FromMilliseconds(
        ([int]$match.Groups['minutes'].Value * 60000) +
        ([int]$match.Groups['seconds'].Value * 1000) +
        ([int]$match.Groups['hundredths'].Value * 10))

    return [pscustomobject]@{
        Elapsed = $elapsed
        Level   = $match.Groups['level'].Value
        Phase   = $match.Groups['phase'].Value
        Message = $match.Groups['message'].Value
        Raw     = $Line
    }
}
