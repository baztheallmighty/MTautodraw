#Requires -Version 7.0

<#
    Network Audit GUI
    =================

    Start with README.md if this is your first time working with this project.

    This file contains the Windows Forms interface and the collection engine. The
    editable inventory and command profiles live in NetworkAudit.config.json.
    Passwords never belong in either file; operators enter named password sets in
    the GUI and they remain in memory only until the application closes.

    High-level execution path:
      1. Load and validate the JSON configuration.
      2. Collect password sets and device edits in the GUI.
      3. Filter enabled devices by the selected site.
      4. Run Safe Preflight or Full Audit workers in a background runspace pool.
      5. Send worker events through a thread-safe queue to the GUI timer.
      6. Finalize CSV/JSON/log output after every worker reaches a terminal state.
      7. Optionally launch MTAutoDraw in a separate pwsh process.

    The $script:DeviceWorker script block deliberately contains its own connection,
    prompt, detection, and vendor-specialized helper functions. PowerShell copies
    that complete script block into each background runspace, keeping the GUI thread
    responsive and avoiding shared live SSH/Telnet session objects.
#>

param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'NetworkAudit.config.json'),
    [switch]$UiSmokeTest
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

function Read-NetworkAuditConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path"
    }

    $Config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    if ($Config.ContainsKey('settings') -and -not $Config.settings.ContainsKey('mtautoDrawRoot')) {
        # DataCollection/ sits inside the MTAutoDraw repo, so the parent directory is the
        # default root. Override it in the config when the collector is run from elsewhere.
        $Config.settings.mtautoDrawRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    }
    return $Config
}

function Get-ConfigErrors {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [hashtable]$Credentials,
        [switch]$CheckCredentials
    )

    $Errors = [Collections.Generic.List[string]]::new()

    if ($Config.schemaVersion -ne 1) {
        $Errors.Add('schemaVersion must be 1.')
    }

    foreach ($Name in @('settings', 'devices', 'engineCommands', 'profiles')) {
        if (-not $Config.ContainsKey($Name) -or $null -eq $Config[$Name]) {
            $Errors.Add("Missing configuration section: $Name")
        }
    }

    if ($Errors.Count -gt 0) {
        return $Errors.ToArray()
    }

    $Settings = $Config.settings
    if ([int]$Settings.throttleLimit -lt 1 -or [int]$Settings.throttleLimit -gt 64) {
        $Errors.Add('throttleLimit must be between 1 and 64.')
    }
    foreach ($Name in @('hardTimeoutSeconds', 'idleTimeoutSeconds', 'connectionTimeoutSeconds')) {
        if ([int]$Settings[$Name] -lt 1) {
            $Errors.Add("$Name must be greater than zero.")
        }
    }
    if ([int]$Settings.idleTimeoutSeconds -gt [int]$Settings.hardTimeoutSeconds) {
        $Errors.Add('idleTimeoutSeconds cannot exceed hardTimeoutSeconds.')
    }
    if ([string]$Settings.juniperOutputMode -notin @('XML', 'Text')) {
        $Errors.Add('juniperOutputMode must be XML or Text.')
    }
    if ([string]$Settings.hostKeyPolicy -notin @('TrustOnFirstUse', 'KnownOnly')) {
        $Errors.Add('hostKeyPolicy must be TrustOnFirstUse or KnownOnly.')
    }
    if ([string]::IsNullOrWhiteSpace([string]$Settings.outputBase)) {
        $Errors.Add('outputBase cannot be empty.')
    }
    if (-not $Settings.ContainsKey('mtautoDrawRoot') -or
        [string]::IsNullOrWhiteSpace([string]$Settings.mtautoDrawRoot)) {
        $Errors.Add('mtautoDrawRoot cannot be empty.')
    }

    $RequiredEngineCommands = @(
        'juniperEnterCli', 'checkPointEnterClish', 'ciscoSmallBusinessLegacyCli', 'genericShowVersion',
        'checkPointShowVersion', 'paloAltoSystemInfo', 'ciscoAireOsSystemInfo',
        'huaweiDisplayVersion', 'h3cDisplayVersion', 'fortinetSystemStatus',
        'mikroTikSystemResource', 'arubaShowSystem', 'arubaShowSystemId',
        'cumulusShowSystem', 'f5TmshSystemVersion', 'f5BashSystemVersion',
        'sophosSystemVersion', 'tpLinkSystemInfo', 'unifiInfo', 'enable'
    )
    foreach ($Name in $RequiredEngineCommands) {
        if (-not $Config.engineCommands.ContainsKey($Name) -or
            [string]::IsNullOrWhiteSpace([string]$Config.engineCommands[$Name])) {
            $Errors.Add("Missing engine command: $Name")
        }
    }

    $RequiredSpecial = @{
        DellOS10 = @('active', 'interfaceTemplate')
        ExtremeEXOS = @('stpd', 'portsTemplate', 'countersTemplate')
        MikroTik = @('monitor')
    }

    foreach ($ProfileName in @($Config.profiles.Keys)) {
        $Profile = $Config.profiles[$ProfileName]
        foreach ($Key in @('paging', 'commands', 'enable', 'special', 'specialCommands')) {
            if (-not $Profile.ContainsKey($Key)) {
                $Errors.Add("Profile $ProfileName is missing $Key.")
            }
        }

        foreach ($ListName in @('paging', 'commands')) {
            $Values = @($Profile[$ListName])
            $Blank = @($Values | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) })
            if ($Blank.Count -gt 0) {
                $Errors.Add("Profile $ProfileName contains a blank $ListName entry.")
            }
            $Duplicate = @($Values | Group-Object | Where-Object Count -gt 1)
            if ($Duplicate.Count -gt 0) {
                $Errors.Add("Profile $ProfileName contains duplicate $ListName entries.")
            }
        }

        if ($ProfileName -in @('Juniper', 'JuniperSRX')) {
            if (-not $Profile.ContainsKey('textCommands') -or @($Profile.textCommands).Count -eq 0) {
                $Errors.Add("$ProfileName must include textCommands.")
            }
        }

        if ($RequiredSpecial.ContainsKey($ProfileName)) {
            foreach ($Key in $RequiredSpecial[$ProfileName]) {
                if (-not $Profile.specialCommands.ContainsKey($Key) -or
                    [string]::IsNullOrWhiteSpace([string]$Profile.specialCommands[$Key])) {
                    $Errors.Add("Profile $ProfileName is missing special command $Key.")
                }
            }
        }
    }

    $SeenTargets = @{}
    foreach ($Device in @($Config.devices)) {
        $Target = ([string]$Device.target).Trim()
        if ([string]::IsNullOrWhiteSpace($Target)) {
            $Errors.Add('A device target is blank.')
            continue
        }
        $Key = $Target.ToLowerInvariant()
        if ($SeenTargets.ContainsKey($Key)) {
            $Errors.Add("Duplicate device target: $Target")
        } else {
            $SeenTargets[$Key] = $true
        }

        if ([string]$Device.type -ne 'Auto' -and -not $Config.profiles.ContainsKey([string]$Device.type)) {
            $Errors.Add("Device $Target references unknown type $($Device.type).")
        }
        if ([bool]$Device.enabled -and [string]::IsNullOrWhiteSpace([string]$Device.credential)) {
            $Errors.Add("Device $Target has no credential name.")
        } elseif ($CheckCredentials -and [bool]$Device.enabled -and -not $Credentials.ContainsKey([string]$Device.credential)) {
            $Errors.Add("Device $Target needs credential set '$($Device.credential)'.")
        }
    }

    return $Errors.ToArray()
}

function Save-NetworkAuditConfig {
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Path
    )

    $Directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $Directory)) {
        [IO.Directory]::CreateDirectory($Directory) | Out-Null
    }

    $TempPath = Join-Path $Directory ('.{0}.{1}.tmp' -f [IO.Path]::GetFileName($Path), [guid]::NewGuid())
    try {
        $Json = $Config | ConvertTo-Json -Depth 30
        [IO.File]::WriteAllText($TempPath, $Json, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($TempPath, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $TempPath) {
            Remove-Item -LiteralPath $TempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-UniqueLines {
    param([string]$Text)

    $Seen = @{}
    return @(
        foreach ($Line in ($Text -split "`r?`n")) {
            $Value = $Line.Trim()
            if ($Value -and -not $Seen.ContainsKey($Value)) {
                $Seen[$Value] = $true
                $Value
            }
        }
    )
}

function Get-CommandSafetyClass {
    param([string]$Command)

    $Value = $Command.Trim()
    if ($Value -match '^(?i)(enable|cli|clish|lcli|no page|no paging|disable clipaging|skip-page-display)$' -or
        $Value -match '^(?i)(terminal\s+(length|datadump|more)|config\s+paging\s+disable|set\s+cli\s+(screen-length|screen-width|pager)|screen-length|disable\s+cli\s+paging\s+session)(\s|$)') {
        return 'SessionOnly'
    }
    if ($Value -match "[`r`n;]" -or
        $Value -match '(?i)\|\s*(save|redirect|tee|file)\b' -or
        $Value -match '^(?i)(configure|conf\s+t|write|copy|delete|erase|format|reload|reboot|shutdown|commit|install|upgrade|factory-reset)(\s|$)') {
        return 'Review'
    }
    if ($Value -match '^(?i)(show|display|get|diagnose)(\s|$)' -or
        $Value -match '^(?i)info$' -or
        $Value -match '^(?i)nv\s+show(\s|$)' -or
        $Value -match '^(?i)service\s+show(\s|$)' -or
        $Value -match '^(?i)tmsh\s+(show|list)(\s|$)' -or
        $Value -match '^(?i)list\s+(sys|net|cm|ltm)(\s|$)' -or
        $Value -match '^(?i)system\s+diagnostics\s+(show(\s|$)|utilities\s+(arp|route|route6|netconf|netconf6)$)' -or
        $Value -match '^(?i)request\s+license\s+info$' -or
        $Value -match '^(?i)/.+\s+(print|monitor)(\s|$)') {
        return 'ReadOnly'
    }
    return 'Review'
}

function Get-SiteNames {
    param([object[]]$Devices)

    $Seen = @{}
    return @(
        foreach ($Device in @($Devices)) {
            $Site = ([string]$Device.site).Trim()
            if (-not $Site) { continue }
            $Key = $Site.ToLowerInvariant()
            if (-not $Seen.ContainsKey($Key)) {
                $Seen[$Key] = $true
                $Site
            }
        }
    ) | Sort-Object
}

function Get-ScopedDevices {
    param(
        [object[]]$Devices,
        [string]$SiteScope
    )

    return @(
        $Devices | Where-Object {
            [bool]$_.enabled -and (
                $SiteScope -eq 'All Sites' -or
                ([string]$_.site).Trim().Equals($SiteScope.Trim(), [StringComparison]::OrdinalIgnoreCase)
            )
        }
    )
}

function Get-OfflinePreflightIssues {
    param(
        [hashtable]$Config,
        [object[]]$Devices,
        [hashtable]$Credentials
    )

    $Issues = [Collections.Generic.List[object]]::new()
    $SeenTargets = @{}
    foreach ($Device in @($Devices)) {
        $Target = ([string]$Device.target).Trim()
        $Site = ([string]$Device.site).Trim()
        $Key = $Target.ToLowerInvariant()
        if ($SeenTargets.ContainsKey($Key)) {
            $Issues.Add([pscustomobject]@{ Severity = 'Fail'; Target = $Target; Category = 'Duplicate'; Message = 'Duplicate target in selected scope.' })
        } else { $SeenTargets[$Key] = $true }
        if (-not $Site -or $Site -eq 'Unassigned') {
            $Issues.Add([pscustomobject]@{ Severity = 'Warning'; Target = $Target; Category = 'Site'; Message = 'Site is blank or Unassigned.' })
        }
        if (-not $Credentials.ContainsKey([string]$Device.credential)) {
            $Issues.Add([pscustomobject]@{ Severity = 'Fail'; Target = $Target; Category = 'Credential'; Message = "Credential set '$($Device.credential)' is not loaded." })
        }
        if ([string]$Device.type -ne 'Auto' -and -not $Config.profiles.ContainsKey([string]$Device.type)) {
            $Issues.Add([pscustomobject]@{ Severity = 'Fail'; Target = $Target; Category = 'Profile'; Message = "Unknown profile '$($Device.type)'." })
        }
    }

    $ProfilesInScope = @($Devices | Where-Object type -ne 'Auto' | ForEach-Object type | Sort-Object -Unique)
    foreach ($ProfileName in $ProfilesInScope) {
        if (-not $Config.profiles.ContainsKey([string]$ProfileName)) { continue }
        $Profile = $Config.profiles[[string]$ProfileName]
        if ($ProfileName -ne 'CiscoSG200Web' -and @($Profile.commands).Count -eq 0) {
            $Issues.Add([pscustomobject]@{ Severity = 'Fail'; Target = ''; Category = 'Commands'; Message = "Profile $ProfileName has no collection commands." })
        }
    }

    foreach ($Pair in $Config.engineCommands.GetEnumerator()) {
        if ((Get-CommandSafetyClass -Command ([string]$Pair.Value)) -eq 'Review') {
            $Issues.Add([pscustomobject]@{ Severity = 'Fail'; Target = ''; Category = 'Safety'; Message = "Detection command '$($Pair.Key)' is outside the Safe Mode allowlist: $($Pair.Value)" })
        }
    }
    foreach ($ProfileName in @($Config.profiles.Keys)) {
        $Profile = $Config.profiles[$ProfileName]
        foreach ($Command in @($Profile.commands) + @($Profile.paging) + @($Profile.specialCommands.Values)) {
            if ((Get-CommandSafetyClass -Command ([string]$Command)) -eq 'Review') {
                $Issues.Add([pscustomobject]@{ Severity = 'Warning'; Target = ''; Category = 'Safety'; Message = "Profile $ProfileName contains a command requiring review: $Command" })
            }
        }
    }

    $MtaSupported = @('CiscoIOS','CiscoNXOS','CiscoASA','CiscoSMBOld','CiscoSMBNew','CiscoLegacy','Juniper','AristaEOS','ArubaCX','PaloAlto','CheckPoint')
    $MtaCaptureRequirements = @{
        CiscoIOS = @('^show running-config$', '^show interfaces$', '^show ip route$', '^show (cdp|lldp) neighbors')
        CiscoNXOS = @('^show running-config$', '^show interface$', '^show ip route$', '^show (cdp|lldp) neighbors')
        CiscoASA = @('^show running-config$', '^show interface$', '^show route$', '^show arp$')
        CiscoSMBOld = @('^show running-config brief$', '^show interfaces status$', '^show ip route$', '^show (cdp|lldp) neighbors')
        CiscoSMBNew = @('^show running-config$', '^show interfaces status$', '^show ip route$', '^show (cdp|lldp)')
        CiscoLegacy = @('^show version$', '^show running-config$', '^show interfaces status$', '^show lldp neighbors$')
        Juniper = @('^show configuration ', '^show interfaces ', '^show route ', '^show lldp neighbors ')
        AristaEOS = @('^show running-config$', '^show interfaces$', '^show ip route$', '^show lldp neighbors')
        ArubaCX = @('^show running-config$', '^show interface$', '^show ip route ', '^show lldp neighbor-info')
        PaloAlto = @('^show system info$', '^show interface all$', '^show routing route$', '^show config running$')
        CheckPoint = @('^show configuration$', '^show interfaces all$', '^show route all$', '^show version all$')
    }
    foreach ($ProfileName in $ProfilesInScope) {
        if ($ProfileName -notin $MtaSupported) {
            $Issues.Add([pscustomobject]@{ Severity = 'Warning'; Target = ''; Category = 'MTAutoDraw'; Message = "MTAutoDraw does not declare parser support for profile $ProfileName." })
            continue
        }
        $ProfileCommands = if ($ProfileName -eq 'Juniper' -and $Config.settings.juniperOutputMode -eq 'Text') {
            @($Config.profiles[$ProfileName].textCommands)
        } else { @($Config.profiles[$ProfileName].commands) }
        foreach ($Pattern in $MtaCaptureRequirements[$ProfileName]) {
            if (-not @($ProfileCommands | Where-Object { [string]$_ -match $Pattern })) {
                $Issues.Add([pscustomobject]@{
                    Severity = 'Warning'; Target = ''; Category = 'MTAutoDraw'
                    Message = "Profile $ProfileName is missing an MTAutoDraw capture category matching: $Pattern"
                })
            }
        }
    }

    return $Issues.ToArray()
}

function Get-PreflightSignature {
    param(
        [object[]]$Devices,
        [hashtable]$Credentials,
        [string]$SiteScope
    )

    $Rows = @($Devices | Sort-Object target | ForEach-Object {
        '{0}|{1}|{2}|{3}|{4}' -f $_.target, $_.site, $_.credential, $_.type, [bool]$_.enabled
    })
    $CredentialRows = @($Credentials.Keys | Sort-Object | ForEach-Object {
        '{0}|{1}' -f $_, $Credentials[$_].Credential.UserName
    })
    $Text = ($SiteScope + "`n" + ($Rows -join "`n") + "`n" + ($CredentialRows -join "`n"))
    $Bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
}

function Get-PathSafeName {
    param([string]$Name)

    $SafeName = ($Name -replace '[\\/:*?"<>| ]+', '.').Trim('.')
    if ([string]::IsNullOrWhiteSpace($SafeName)) { return 'Unassigned' }
    return $SafeName
}

function Get-MtautoDrawPrerequisiteErrors {
    param([string]$Root)

    $Errors = [Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        $Errors.Add("MTAutoDraw folder was not found: $Root")
        return $Errors.ToArray()
    }

    $RequiredFiles = @(
        'AutoDraw.ps1',
        'configurationVariables.ps1',
        'StartProcessingConfig.ps1',
        'TextFSM.py',
        'python\python.exe',
        'GETIPV4Subnet\GetIPv4Subnet.psm1'
    )
    foreach ($RelativePath in $RequiredFiles) {
        $Path = Join-Path $Root $RelativePath
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $Errors.Add("Missing MTAutoDraw prerequisite: $RelativePath")
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'Templates') -PathType Container)) {
        $Errors.Add('Missing MTAutoDraw prerequisite: Templates folder')
    }
    return $Errors.ToArray()
}

$script:DeviceWorker = {
    param(
        [hashtable]$Device,
        [hashtable]$Config,
        [hashtable]$CredentialBundle,
        [string]$RunFolder,
        [Collections.Concurrent.ConcurrentQueue[object]]$EventQueue,
        [Threading.CancellationToken]$CancellationToken,
        [ValidateSet('FullAudit', 'Preflight')]
        [string]$RunMode = 'FullAudit'
    )

    $Target = [string]$Device.target
    $Site = if ($Device.site) { [string]$Device.site } else { 'Unassigned' }
    $HardTimeout = [int]$Config.settings.hardTimeoutSeconds
    $IdleTimeout = [int]$Config.settings.idleTimeoutSeconds
    $ConnectionTimeout = [int]$Config.settings.connectionTimeoutSeconds
    $EngineCommands = $Config.engineCommands
    $ExecutedCommands = [Collections.Generic.List[string]]::new()
    $CommandObservations = [Collections.Generic.List[object]]::new()

    function Publish-Event {
        param(
            [string]$Level = 'Info',
            [string]$Phase = '',
            [string]$Status = '',
            [string]$Message = '',
            [string]$Command = '',
            [int]$CommandIndex = 0,
            [int]$CommandTotal = 0,
            [string]$Type = '',
            [bool]$Terminal = $false
        )
        $EventQueue.Enqueue([pscustomobject]@{
            Time = [datetime]::Now
            Level = $Level
            Target = $Target
            Phase = $Phase
            Status = $Status
            Message = $Message
            Command = $Command
            CommandIndex = $CommandIndex
            CommandTotal = $CommandTotal
            Type = $Type
            Terminal = $Terminal
        })
    }

    function Assert-NotCancelled {
        if ($CancellationToken.IsCancellationRequested) {
            throw [OperationCanceledException]::new('Collection cancelled by the operator.')
        }
    }

    function Get-SafeName {

        param(
            [string]$Name
        )

        return (
            $Name -replace '[\\/:*?"<>| ]+', '.'
        ).Trim('.')
    }


    function Get-CommandFileName {

        param(
            [string]$Command
        )

        $Name = $Command

        $Name = $Name -replace '\*', 'star'

        $Name = $Name -replace `
            '\s*\|\s*display\s+xml\s*',
            ''

        $Name = $Name -replace `
            '\s*\|\s*display\s+set\s*',
            '.display-set'

        $Name = $Name -replace `
            '\s*\|\s*no-more\s*',
            ''

        $Name = (
            $Name -replace '[^A-Za-z0-9._-]+', '.'
        ).Trim('.')

        return "$Name.txt"
    }



    function Get-CleanCommandOutput {

        param(
            [string]$Text,
            [string]$Command,
            [string]$Prompt
        )

        if ($null -eq $Text) {
            return ''
        }

        $Lines = @(
            $Text -split "`r?`n"
        )

        if ($Lines.Count -eq 0) {
            return ''
        }

        #
        # Drop blank transport noise before the command echo.
        #
        $Start = 0

        while (
            $Start -lt $Lines.Count -and
            -not $Lines[$Start].Trim()
        ) {
            $Start++
        }

        #
        # Drop the echoed command.
        #
        # Depending on the platform it can look like:
        #
        # show version
        #
        # or:
        #
        # EXAMPLE-SW1#show version
        # root@switch> show version
        #
        if ($Start -lt $Lines.Count) {

            $First = $Lines[$Start].Trim()
            $CommandTrimmed = $Command.Trim()

            $IsCommandEcho = (
                $First -eq $CommandTrimmed
            )

            if (
                -not $IsCommandEcho -and
                $Prompt
            ) {

                $PromptTrimmed = $Prompt.Trim()

                $IsCommandEcho = (
                    $First -eq (
                        $PromptTrimmed +
                        $CommandTrimmed
                    ) -or
                    $First -eq (
                        $PromptTrimmed +
                        ' ' +
                        $CommandTrimmed
                    )
                )
            }

            if ($IsCommandEcho) {
                $Start++
            }
        }

        #
        # Drop blank transport noise at the end.
        #
        $End = $Lines.Count - 1

        while (
            $End -ge $Start -and
            -not $Lines[$End].Trim()
        ) {
            $End--
        }

        #
        # Drop the final device prompt.
        #
        if (
            $End -ge $Start -and
            $Prompt -and
            $Lines[$End].Trim() -eq $Prompt.Trim()
        ) {
            $End--
        }

        while (
            $End -ge $Start -and
            -not $Lines[$End].Trim()
        ) {
            $End--
        }

        if ($End -lt $Start) {
            return ''
        }

        return (
            $Lines[$Start..$End] -join "`r`n"
        )
    }


    function Test-Port {

        param(
            [string]$Computer,
            [int]$Port
        )

        $Client = [Net.Sockets.TcpClient]::new()

        try {

            $Task = $Client.ConnectAsync(
                $Computer,
                $Port
            )

            if (-not $Task.Wait(2000)) {
                return $false
            }

            return $Client.Connected
        }
        catch {

            return $false
        }
        finally {

            $Client.Dispose()
        }
    }


    # ========================================================
    # CONNECTION
    # ========================================================

    function New-Connection {

        param(
            [string]$Target,
            [pscredential]$Credential,
            [string]$Protocol
        )

        if ($Protocol -eq 'SSH') {

            Import-Module Posh-SSH `
                -MinimumVersion 3.2.7 `
                -ErrorAction Stop


            $SshParameters = @{
                ComputerName = $Target
                Credential = $Credential
                ConnectionTimeout = $ConnectionTimeout
                ErrorAction = 'Stop'
            }

            if ($Config.settings.hostKeyPolicy -eq 'TrustOnFirstUse') {
                $SshParameters.AcceptKey = $true
            } else {
                $SshParameters.ErrorOnUntrusted = $true
            }

            $Session = New-SSHSession @SshParameters


            $Stream = New-SSHShellStream `
                -SSHSession $Session `
                -TerminalName 'xterm' `
                -Columns 200 `
                -Rows 50 `
                -BufferSize 100000 `
                -ErrorAction Stop


            return [pscustomobject]@{
                Protocol       = 'SSH'
                Session        = $Session
                Client         = $null
                Stream         = $Stream
                ExpectedPrompt = ''
            }
        }


        $Client = [Net.Sockets.TcpClient]::new()

        $Client.Connect(
            $Target,
            23
        )


        return [pscustomobject]@{
            Protocol       = 'Telnet'
            Session        = $null
            Client         = $Client
            Stream         = $Client.GetStream()
            ExpectedPrompt = ''
        }
    }


    function Close-Connection {

        param(
            $Connection
        )

        if (-not $Connection) {
            return
        }


        if ($Connection.Stream) {

            try {
                $Connection.Stream.Dispose()
            }
            catch {}
        }


        if ($Connection.Client) {

            try {
                $Connection.Client.Dispose()
            }
            catch {}
        }


        if ($Connection.Session) {

            try {

                Remove-SSHSession `
                    -SSHSession $Connection.Session |
                    Out-Null
            }
            catch {}
        }
    }


    # ========================================================
    # READ / WRITE
    # ========================================================

    function Read-Chunk {

        param(
            $Connection
        )

        if (-not $Connection.Stream.DataAvailable) {
            return $null
        }


        if ($Connection.Protocol -eq 'SSH') {

            return $Connection.Stream.Read()
        }


        $Bytes = [byte[]]::new(8192)


        $Count = $Connection.Stream.Read(
            $Bytes,
            0,
            $Bytes.Length
        )


        $Text = [Text.Encoding]::ASCII.GetString(
            $Bytes,
            0,
            $Count
        )


        #
        # Remove Telnet control bytes.
        #
        return $Text -replace `
            '[^\x09\x0A\x0D\x20-\x7E]',
            ''
    }


    function Send-Line {

        param(
            $Connection,
            [string]$Text
        )

        if ($Connection.Protocol -eq 'SSH') {

            $Connection.Stream.WriteLine(
                $Text
            )

            return
        }


        $Bytes = [Text.Encoding]::ASCII.GetBytes(
            "$Text`r`n"
        )


        $Connection.Stream.Write(
            $Bytes,
            0,
            $Bytes.Length
        )
    }


    function Send-Raw {

        param(
            $Connection,
            [string]$Text
        )

        if ($Connection.Protocol -eq 'SSH') {

            $Connection.Stream.Write(
                $Text
            )

            return
        }


        $Bytes = [Text.Encoding]::ASCII.GetBytes(
            $Text
        )


        $Connection.Stream.Write(
            $Bytes,
            0,
            $Bytes.Length
        )
    }


    function Read-UntilPattern {

        param(
            $Connection,
            [string]$Pattern,
            [string]$Description,
            [int]$TimeoutSeconds = 8,
            [string]$InitialText = ''
        )

        $Text = $InitialText
        if ($Text -match $Pattern) {
            return $Text
        }

        $Timer = [Diagnostics.Stopwatch]::StartNew()
        while ($Timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Assert-NotCancelled
            $Data = Read-Chunk -Connection $Connection
            if ($null -eq $Data) {
                Start-Sleep -Milliseconds 50
                continue
            }

            $Text += $Data
            if ($Text -match $Pattern) {
                return $Text
            }
        }

        throw "Legacy Cisco Small Business login timed out waiting for $Description."
    }


    function Enter-CiscoSmallBusinessLegacyCli {

        param(
            $Connection,
            [string]$Username,
            [string]$Password,
            [string]$InitialText = ''
        )

        if ($Connection.Protocol -ne 'Telnet') {
            throw 'The legacy Cisco Small Business menu connector requires Telnet.'
        }

        $Transcript = $InitialText
        if ($Transcript -notmatch '(?i)Switch Main Menu') {
            Publish-Event -Phase 'Legacy SMB login' -Status 'Connecting' `
                -Message 'Waiting for the first Cisco Small Business login screen.'
            $Transcript = Read-UntilPattern -Connection $Connection `
                -Pattern '(?i)Login Screen' -Description 'the first login screen' `
                -TimeoutSeconds 8 -InitialText $Transcript

            # The original menu interface uses a field-based login: username,
            # Down Arrow to select the password field, then the password.
            Send-Raw -Connection $Connection -Text $Username
            Send-Raw -Connection $Connection -Text "`e[B"
            Send-Line -Connection $Connection -Text $Password

            Publish-Event -Phase 'Legacy SMB login' -Status 'Connecting' `
                -Message 'First login submitted; waiting for the switch main menu.'
            $Transcript = Read-UntilPattern -Connection $Connection `
                -Pattern '(?i)Switch Main Menu' -Description 'the switch main menu' `
                -TimeoutSeconds 10
        }

        Assert-NotCancelled
        Publish-Event -Phase 'Legacy SMB login' -Status 'Connecting' `
            -Message 'Opening the legacy command-line interface.'
        Send-Raw -Connection $Connection -Text ([char]26)
        Start-Sleep -Milliseconds 300
        $LegacyCliCommand = [string]$EngineCommands.ciscoSmallBusinessLegacyCli
        $ExecutedCommands.Add($LegacyCliCommand)
        Send-Line -Connection $Connection -Text $LegacyCliCommand

        $null = Read-UntilPattern -Connection $Connection `
            -Pattern '(?i)User\s*Name\s*:' -Description 'the second username prompt' `
            -TimeoutSeconds 8
        Send-Line -Connection $Connection -Text $Username

        $null = Read-UntilPattern -Connection $Connection `
            -Pattern '(?i)Password\s*:' -Description 'the second password prompt' `
            -TimeoutSeconds 8
        Send-Line -Connection $Connection -Text $Password

        $PromptText = Read-UntilPattern -Connection $Connection `
            -Pattern '(?m)[A-Za-z0-9_.-]+#\s*$' -Description 'the LCLI prompt' `
            -TimeoutSeconds 10
        $PromptMatches = [regex]::Matches($PromptText, '(?m)(?<Prompt>[A-Za-z0-9_.-]+#)\s*$')
        if ($PromptMatches.Count -eq 0) {
            throw 'The legacy Cisco Small Business LCLI prompt could not be identified.'
        }

        $Prompt = $PromptMatches[-1].Groups['Prompt'].Value
        $PromptInfo = Get-PromptInfo -Line $Prompt
        $Connection.ExpectedPrompt = $Prompt
        Publish-Event -Phase 'Legacy SMB login' -Status 'Connected' `
            -Message 'The second login succeeded and the LCLI prompt is ready.' -Type 'CiscoLegacy'

        return [pscustomobject]@{
            Status = 'Prompt'
            Text = "Legacy Cisco Small Business menu and second LCLI login succeeded.`r`n$Prompt"
            Prompt = $Prompt
            Hostname = $PromptInfo.Hostname
        }
    }


    # ========================================================
    # PROMPT DETECTION
    # ========================================================

    function Get-PromptInfo {

        param(
            [string]$Line
        )

        $Line = $Line.Trim()


        #
        # MikroTik:
        #
        # [admin@MikroTik] >
        #
        if (
            $Line -match
            '^\[(?:[^@\]]+@)?(?<Host>[^\]:]+)\]\s*[>#]$'
        ) {

            return [pscustomobject]@{
                Match    = $true
                Hostname = $Matches.Host
                Prompt   = $Line
            }
        }


        #
        # Huawei / H3C:
        #
        # <hostname>
        #
        if (
            $Line -match
            '^<(?<Host>[^>]+)>$'
        ) {

            return [pscustomobject]@{
                Match    = $true
                Hostname = $Matches.Host
                Prompt   = $Line
            }
        }


        #
        # ArubaOS 8 Mobility Conductor / Controller:
        #
        # (hostname) [mynode] #
        #
        if (
            $Line -match
            '^\((?<Host>[^)]+)\)\s+\[[^\]]+\](?:\s+\([^)]+\))*\s*[>#]$'
        ) {

            return [pscustomobject]@{
                Match    = $true
                Hostname = $Matches.Host
                Prompt   = $Line
            }
        }


        #
        # F5 BIG-IP tmsh:
        #
        # admin@(bigip)(cfg-sync Standalone)(Active)(/Common)(tmos)#
        #
        if (
            $Line -match
            '^(?:[^@\s]+@)?\((?<Host>[A-Za-z0-9._-]+)\)(?:\([^)]+\))*\s*[>#]$'
        ) {

            return [pscustomobject]@{
                Match    = $true
                Hostname = $Matches.Host
                Prompt   = $Line
            }
        }


        #
        # AireOS:
        #
        # (Cisco Controller) >
        #
        if (
            $Line -match
            '^\((?<Host>[^)]+)\)\s*[>#]$'
        ) {

            return [pscustomobject]@{
                Match    = $true
                Hostname = $Matches.Host
                Prompt   = $Line
            }
        }


        #
        # Nokia SR OS:
        #
        # A:router-name#
        # *B:router-name#
        #
        if (
            $Line -match
            '^\*?[AB]:(?<Host>[A-Za-z0-9._-]+)(?:>[^\s#>]+)*\s*[>#]$'
        ) {

            return [pscustomobject]@{
                Match    = $true
                Hostname = $Matches.Host
                Prompt   = $Line
            }
        }


        #
        # VOSS / Fabric Engine:
        #
        # Switch:1>
        #
        if (
            $Line -match
            '^(?<Host>[A-Za-z0-9._-]+):\d+\s*[>#]$'
        ) {

            return [pscustomobject]@{
                Match    = $true
                Hostname = $Matches.Host
                Prompt   = $Line
            }
        }


        #
        # Check Point Expert:
        #
        # [Expert@hostname:0]#
        #
        if (
            $Line -match
            '^\[(?:[^@\]]+@)?(?<Host>[^:\]]+)(?::[^\]]+)?\](?:\s+\S+)?\s*[#$]$'
        ) {

            return [pscustomobject]@{
                Match    = $true
                Hostname = $Matches.Host
                Prompt   = $Line
            }
        }


        #
        # Juniper / Palo Alto / Unix shell
        #
        if (
            $Line -match
            '^(?:[^@\s]+@)?(?<Host>[A-Za-z0-9._-]+)(?::[^\s]+)?(?:/[^\s]+)?\s*[>#\$%]$'
        ) {

            return [pscustomobject]@{
                Match    = $true
                Hostname = $Matches.Host
                Prompt   = $Line
            }
        }


        #
        # Extreme EXOS often has:
        #
        # * switchname.1 #
        #
        if (
            $Line -match
            '^\*?\s*(?<Host>[A-Za-z0-9._-]+)(?:\.\d+)?\s*[>#]$'
        ) {

            return [pscustomobject]@{
                Match    = $true
                Hostname = $Matches.Host
                Prompt   = $Line
            }
        }


        #
        # Generic Cisco-style prompt
        #
        if (
            $Line -match
            '^(?<Host>[A-Za-z0-9._-]+)(?:\([^)]+\))?(?:/[A-Za-z0-9._/-]+)?\s*[>#]$'
        ) {

            return [pscustomobject]@{
                Match    = $true
                Hostname = $Matches.Host
                Prompt   = $Line
            }
        }


        return [pscustomobject]@{
            Match    = $false
            Hostname = ''
            Prompt   = ''
        }
    }


    function Test-Menu {

        param(
            [string]$Text
        )

        if (
            $Text -match
            '(?im)^\s*(Main|Console|System|Configuration)\s+Menu\b'
        ) {
            return $true
        }


        if (
            $Text -match
            '(?im)^\s*(Select|Choose|Enter).*(option|choice|selection)'
        ) {
            return $true
        }


        return $false
    }


    # ========================================================
    # READ UNTIL PROMPT
    # ========================================================

    function Read-ToPrompt {

        param(
            $Connection,

            [string]$Username = '',
            [string]$Password = '',

            [switch]$HandleLogin,

            [string]$PromptPassword = '',

            [switch]$WakeIfSilent,

            [string]$ExpectedPrompt = ''
        )


        $Buffer = ''
        $Raw = ''

        $UsernameSent = $false
        $PasswordSent = $false
        $WakeSent = $false

        $TotalTimer = [Diagnostics.Stopwatch]::StartNew()
        $IdleTimer  = [Diagnostics.Stopwatch]::StartNew()


        while (
            $TotalTimer.Elapsed.TotalSeconds -lt
            $HardTimeout
        ) {

            Assert-NotCancelled

            Start-Sleep -Milliseconds 200


            #
            # Wake silent CLI only when NOTHING has been sent.
            #
            # This avoids submitting blank usernames.
            #
            if (
                $WakeIfSilent -and
                -not $WakeSent -and
                $Raw.Length -eq 0 -and
                $TotalTimer.Elapsed.TotalSeconds -ge 2
            ) {

                Send-Line `
                    -Connection $Connection `
                    -Text ''

                $WakeSent = $true

                continue
            }


            $Data = Read-Chunk `
                -Connection $Connection


            if ($null -eq $Data) {

                if (
                    $IdleTimer.Elapsed.TotalSeconds -ge
                    $IdleTimeout
                ) {

                    $Status = if (
                        Test-Menu -Text $Raw
                    ) {
                        'Menu'
                    }  else {
                        'Idle'
                    }


                    return [pscustomobject]@{
                        Status   = $Status
                        Text     = $Raw
                        Prompt   = ''
                        Hostname = ''
                    }
                }

                continue
            }


            $IdleTimer.Restart()

            $Raw += $Data
            $Buffer += $Data

            # The legacy Cisco Small Business terminal starts with a
            # full-screen menu rather than a normal username prompt.
            # Return it to the dedicated double-login handler immediately.
            if ($HandleLogin -and $Buffer -match '(?i)(Login Screen|Switch Main Menu)') {
                return [pscustomobject]@{
                    Status = 'Menu'
                    Text = $Raw
                    Prompt = ''
                    Hostname = ''
                }
            }


            #
            # Common paging prompts.
            #
            $MorePattern = (
                '(?i)' +
                '(--More--|' +
                '----\s*More\s*----|' +
                '---\(more[^)]*\)---|' +
                '<---\s*More\s*--->|' +
                'Press any key to continue|' +
                'Press <SPACE> to continue)'
            )


            if ($Buffer -match $MorePattern) {

                Send-Raw `
                    -Connection $Connection `
                    -Text ' '

                $Buffer = $Buffer -replace `
                    $MorePattern,
                    ''

                continue
            }


            if (
                $Buffer -match
                '(?i)Press Enter to continue'
            ) {

                Send-Line `
                    -Connection $Connection `
                    -Text ''

                continue
            }


            #
            # Secondary login, for Cisco SMB etc.
            #
            if (
                $HandleLogin -and
                -not $UsernameSent -and
                $Buffer -match
                '(?i)(User\s*Name|Username|login):\s*$'
            ) {

                Send-Line `
                    -Connection $Connection `
                    -Text $Username

                $UsernameSent = $true
                $Buffer = ''

                continue
            }


            if (
                $HandleLogin -and
                -not $PasswordSent -and
                $Buffer -match
                '(?i)Password:\s*$'
            ) {

                Send-Line `
                    -Connection $Connection `
                    -Text $Password

                $PasswordSent = $true
                $Buffer = ''

                continue
            }


            #
            # Privileged-mode password.
            #
            if (
                $PromptPassword -and
                $Buffer -match
                '(?i)Password:\s*$'
            ) {

                Send-Line `
                    -Connection $Connection `
                    -Text $PromptPassword

                $PromptPassword = ''
                $Buffer = ''

                continue
            }


            if (
                $Buffer -match
                '(?i)(authentication failed|login incorrect|access denied)'
            ) {

                return [pscustomobject]@{
                    Status   = 'AuthenticationFailed'
                    Text     = $Raw
                    Prompt   = ''
                    Hostname = ''
                }
            }


            #
            # Repeated username after attempted login.
            #
            if (
                $HandleLogin -and
                $UsernameSent -and
                $Buffer -match
                '(?i)(User\s*Name|Username|login):\s*$'
            ) {

                return [pscustomobject]@{
                    Status   = 'AuthenticationFailed'
                    Text     = $Raw
                    Prompt   = ''
                    Hostname = ''
                }
            }


            #
            # Repeated password after attempted login.
            #
            if (
                $HandleLogin -and
                $PasswordSent -and
                $Buffer -match
                '(?i)Password:\s*$'
            ) {

                return [pscustomobject]@{
                    Status   = 'AuthenticationFailed'
                    Text     = $Raw
                    Prompt   = ''
                    Hostname = ''
                }
            }


            $Lines = @(
                $Buffer -split "`r?`n" |
                Where-Object {
                    $_.Trim()
                }
            )


            if ($Lines.Count -eq 0) {
                continue
            }


            $LastLine = $Lines[-1].Trim()


            #
            # Once we already know the real device prompt, only
            # that exact prompt may terminate command output.
            #
            # This is intentionally much stricter than the
            # initial login detection. The older working
            # collectors behaved this way and did not mistake
            # ordinary command output for a prompt.
            #
            if ($ExpectedPrompt) {

                if (
                    $LastLine -eq $ExpectedPrompt.Trim()
                ) {

                    $Prompt = Get-PromptInfo `
                        -Line $LastLine

                    return [pscustomobject]@{
                        Status   = 'Prompt'
                        Text     = $Raw
                        Prompt   = $LastLine
                        Hostname = $Prompt.Hostname
                    }
                }
            }
            else {

                $Prompt = Get-PromptInfo `
                    -Line $LastLine


                if ($Prompt.Match) {

                    return [pscustomobject]@{
                        Status   = 'Prompt'
                        Text     = $Raw
                        Prompt   = $Prompt.Prompt
                        Hostname = $Prompt.Hostname
                    }
                }
            }


            #
            # Preserve menu systems.
            #
            if (
                Test-Menu -Text $Raw
            ) {

                return [pscustomobject]@{
                    Status   = 'Menu'
                    Text     = $Raw
                    Prompt   = ''
                    Hostname = ''
                }
            }
        }


        return [pscustomobject]@{
            Status   = 'HardTimeout'
            Text     = $Raw
            Prompt   = ''
            Hostname = ''
        }
    }


    function Enter-SophosDeviceConsole {

        param(
            $Connection,
            [string]$InitialText = ''
        )

        Publish-Event -Phase 'Sophos login' -Status 'Connecting' `
            -Message 'Selecting main-menu option 4 (Device Console).' -Type 'SophosFirewall'
        Send-Line -Connection $Connection -Text '4'

        $Console = Read-ToPrompt -Connection $Connection -WakeIfSilent
        if ($Console.Status -ne 'Prompt') {
            throw "Sophos Firewall menu login did not reach the Device Console prompt ($($Console.Status))."
        }

        $Connection.ExpectedPrompt = $Console.Prompt
        Publish-Event -Phase 'Sophos login' -Status 'Connected' `
            -Message 'Sophos Device Console is ready.' -Type 'SophosFirewall'

        return [pscustomobject]@{
            Status = 'Prompt'
            Text = "$InitialText`r`nSophos main-menu option 4 selected.`r`n$($Console.Text)"
            Prompt = $Console.Prompt
            Hostname = $Console.Hostname
        }
    }


    function Invoke-Command {

        param(
            $Connection,
            [string]$Command,
            [string]$PromptPassword = '',
            [switch]$AllowPromptChange
        )

        $ExecutedCommands.Add($Command)


        Send-Line `
            -Connection $Connection `
            -Text $Command


        $ExpectedPrompt = if (
            $AllowPromptChange
        ) {
            ''
        }
        else {
            $Connection.ExpectedPrompt
        }


        $Result = Read-ToPrompt `
            -Connection $Connection `
            -PromptPassword $PromptPassword `
            -ExpectedPrompt $ExpectedPrompt


        #
        # Commands such as enable, cli and clish legitimately
        # change the prompt. Record the new prompt once seen.
        #
        if (
            $Result.Status -eq 'Prompt'
        ) {
            $Connection.ExpectedPrompt = $Result.Prompt
        }

        $CommandObservations.Add([pscustomobject]@{
            Command = $Command
            Status = [string]$Result.Status
            Rejected = [bool]($Result.Text -match '(?im)(Invalid input|Invalid command|Unknown command|Unrecognized command|Incomplete command|Command not found|command parse error|syntax error|%\s*Error)')
            ResponseCharacters = ([string]$Result.Text).Length
        })


        return $Result
    }


    function Test-CommandFailed {

        param(
            [string]$Text
        )

        return (
            $Text -match
            '(?im)(Invalid input|Invalid command|Unknown command|Unrecognized command|Incomplete command|Command not found|command parse error|syntax error|%\s*Error)'
        )
    }


    # ========================================================
    # DEVICE DETECTION
    # ========================================================

    function Detect-Device {

        param(
            $Connection,
            $Login
        )


        $Fingerprint = $Login.Text
        $Cli = $Login


        #
        # MikroTik often identifies itself immediately.
        #
        if (
            $Fingerprint -match
            '(?i)(MikroTik|RouterOS)'
        ) {

            return [pscustomobject]@{
                Type        = 'MikroTik'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        #
        # Sophos Firewall is identified by the SSH main menu. The login
        # connector has already selected option 4 (Device Console).
        #
        if (
            $Fingerprint -match
            '(?is)(Sophos\s+Firewall|Sophos main-menu option 4 selected)'
        ) {

            return [pscustomobject]@{
                Type        = 'SophosFirewall'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        #
        # Check Point Expert shell.
        #
        if (
            $Cli.Prompt -match
            '^\[Expert@'
        ) {

            $Clish = Invoke-Command `
                -Connection $Connection `
                -Command $EngineCommands.checkPointEnterClish `
                -AllowPromptChange


            $Fingerprint += $Clish.Text


            if ($Clish.Status -eq 'Prompt') {

                $Version = Invoke-Command `
                    -Connection $Connection `
                    -Command $EngineCommands.checkPointShowVersion


                $Fingerprint += $Version.Text


                if (
                    $Version.Text -match
                    '(?i)(Check Point|Gaia)'
                ) {

                    return [pscustomobject]@{
                        Type        = 'CheckPoint'
                        CLI         = $Clish
                        Fingerprint = $Fingerprint
                    }
                }
            }
        }


        #
        # Juniper can initially land in Unix shell.
        #
        if (
            $Cli.Prompt -match '%$' -and
            $Cli.Prompt -match '@'
        ) {

            $JuniperCLI = Invoke-Command `
                -Connection $Connection `
                -Command $EngineCommands.juniperEnterCli `
                -AllowPromptChange


            $Fingerprint += $JuniperCLI.Text


            if ($JuniperCLI.Status -eq 'Prompt') {

                $Version = Invoke-Command `
                    -Connection $Connection `
                    -Command $EngineCommands.genericShowVersion


                $Fingerprint += $Version.Text


                if (
                    $Version.Text -match
                    '(?i)(JUNOS|Juniper Networks)'
                ) {

                    $JuniperType = if (
                        $Version.Text -match '(?i)(\bSRX[0-9A-Z-]*\b|Model:\s*srx)'
                    ) { 'JuniperSRX' } else { 'Juniper' }

                    return [pscustomobject]@{
                        Type        = $JuniperType
                        CLI         = $JuniperCLI
                        Fingerprint = $Fingerprint
                    }
                }
            }
        }


        #
        # First generic detection command.
        #
        $Version = Invoke-Command `
            -Connection $Connection `
            -Command $EngineCommands.genericShowVersion


        $Fingerprint += $Version.Text


        # ----------------------------------------------------
        # Cisco ASA
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(Cisco Adaptive Security Appliance|Cisco Secure Firewall ASA|ASA Version)' -and
            $Fingerprint -notmatch '(?i)(Firepower Threat Defense|Secure Firewall Threat Defense|Cisco Fire Linux OS)'
        ) {

            return [pscustomobject]@{
                Type        = 'CiscoASA'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Cisco FXOS chassis manager
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(Firepower eXtensible Operating System|\bFXOS\b|FPRM:)'
        ) {

            return [pscustomobject]@{
                Type        = 'CiscoFXOS'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Cisco Secure Firewall Threat Defense
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(Firepower Threat Defense|Secure Firewall Threat Defense|Cisco Fire Linux OS)'
        ) {

            return [pscustomobject]@{
                Type        = 'CiscoFTD'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Cisco NX-OS
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(NX-OS|Nexus Operating System|NXOS:)'
        ) {

            return [pscustomobject]@{
                Type        = 'CiscoNXOS'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Cisco Catalyst 9800 WLC (IOS-XE)
        #
        # A 9800 also identifies itself as IOS-XE, so this check
        # must stay before the general Cisco IOS / IOS-XE check.
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(Cisco Catalyst 9800|Catalyst 9800 Wireless Controller|\bC9800(?:-[A-Z0-9]+)?\b)'
        ) {

            return [pscustomobject]@{
                Type        = 'CiscoCatalyst9800WLC'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Cisco IOS XR
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(Cisco IOS XR Software|IOS XR RUN|\bIOS-XR\b)'
        ) {

            return [pscustomobject]@{
                Type        = 'CiscoIOSXR'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Cisco IOS / IOS-XE
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(Cisco IOS Software|Cisco IOS XE Software|IOS-XE)'
        ) {

            return [pscustomobject]@{
                Type        = 'CiscoIOS'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Juniper
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(JUNOS|Juniper Networks)'
        ) {

            $JuniperType = if (
                $Fingerprint -match '(?i)(\bSRX[0-9A-Z-]*\b|Model:\s*srx)'
            ) { 'JuniperSRX' } else { 'Juniper' }

            return [pscustomobject]@{
                Type        = $JuniperType
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Dell OS10
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(SmartFabric OS10|Dell EMC Networking OS10|OS10 Enterprise Edition)'
        ) {

            return [pscustomobject]@{
                Type        = 'DellOS10'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Dell Networking OS9 / FTOS
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(Dell (?:EMC )?(?:Networking )?(?:Operating System|OS) Version(?!10)|Dell Real Time Operating System|\bFTOS\b)'
        ) {

            return [pscustomobject]@{
                Type        = 'DellOS9'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Arista
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(Arista Networks|Arista EOS|Software image version.*EOS)'
        ) {

            return [pscustomobject]@{
                Type        = 'AristaEOS'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Aruba CX
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(ArubaOS-CX|AOS-CX)'
        ) {

            return [pscustomobject]@{
                Type        = 'ArubaCX'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Aruba Instant AOS-8
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(ArubaInstant|Instant AP|Virtual Controller|ArubaOS.*MODEL:\s*(?:I?AP-|[3456][0-9]{2}))'
        ) {

            return [pscustomobject]@{
                Type        = 'ArubaInstantAOS8'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # ArubaOS 8 controller / conductor
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(Mobility Conductor|Mobility Controller|ArubaOS\s+\(MODEL:)'
        ) {

            return [pscustomobject]@{
                Type        = 'ArubaAOS8Controller'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # ArubaOS-Switch / ProVision
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(ArubaOS-Switch|ProVision|ProCurve|Software revision\s+(?:WC|WB|YA|YB|KB|K|RA)\.)'
        ) {

            return [pscustomobject]@{
                Type        = 'ArubaAOSSwitch'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Extreme EXOS
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(ExtremeXOS|Switch Engine)'
        ) {

            return [pscustomobject]@{
                Type        = 'ExtremeEXOS'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Extreme VOSS / Fabric Engine
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(Fabric Engine|Virtual Services Platform|\bVOSS\b)'
        ) {

            return [pscustomobject]@{
                Type        = 'ExtremeVOSS'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Extreme SLX-OS
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(SLX-OS Operating System|SLXOS|Extreme SLX)'
        ) {

            return [pscustomobject]@{
                Type        = 'ExtremeSLXOS'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Ubiquiti EdgeSwitch
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(EdgeSwitch|Ubiquiti.*(?:ES-|EdgeSwitch))'
        ) {

            return [pscustomobject]@{
                Type        = 'UbiquitiEdgeSwitch'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Blue Coat
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(ProxySG|SGOS|Blue Coat)'
        ) {

            return [pscustomobject]@{
                Type        = 'BlueCoat'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Additional platforms identified by show version
        # ----------------------------------------------------

        $VersionSignatures = @(
            @{ Type = 'RuckusFastIron'; Pattern = '(?i)(RUCKUS|Brocade|Foundry).*(FastIron|ICX)|FastIron' },
            @{ Type = 'NokiaSROS'; Pattern = '(?i)(TiMOS|Nokia\s+(?:7750|7450|7950|7210|7705)|Alcatel-Lucent.*TiMOS)' },
            @{ Type = 'VyOS'; Pattern = '(?i)(\bVyOS\b|Release Train:\s*(?:sagitta|circinus))' },
            @{ Type = 'AlliedTelesisAWPlus'; Pattern = '(?i)(AlliedWare Plus|Allied Telesis)' },
            @{ Type = 'NetgearManagedSwitch'; Pattern = '(?i)(NETGEAR.*(?:M4[235][0-9]{2}|Managed Switch)|Machine Model.*(?:M4[235][0-9]{2}))' },
            @{ Type = 'SONiC'; Pattern = '(?i)(SONiC Software Version|SONiC OS Version)' },
            @{ Type = 'WatchGuardFireware'; Pattern = '(?i)(WatchGuard|Fireware|Firebox)' },
            @{ Type = 'SonicWallSwitch'; Pattern = '(?i)(SonicWall Switch|\bSWS1[2-9][0-9]{2}\b)' },
            @{ Type = 'CambiumcnMatrix'; Pattern = '(?i)(cnMatrix|Cambium.*(?:EX|TX)[123][0-9]{3})' },
            @{ Type = 'CambiumEnterpriseWiFi'; Pattern = '(?i)(Cambium.*(?:Enterprise Wi-Fi|cnPilot)|\b(?:XV|XE|XH)[2-9][0-9]{2}\b.*Cambium)' }
        )
        foreach ($Signature in $VersionSignatures) {
            if ($Fingerprint -match $Signature.Pattern) {
                return [pscustomobject]@{
                    Type        = $Signature.Type
                    CLI         = $Cli
                    Fingerprint = $Fingerprint
                }
            }
        }


        # ----------------------------------------------------
        # Cisco SMB new
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?i)(Active-image:|CBS[235][0-9]+|SG350|SG550|SF350)'
        ) {

            return [pscustomobject]@{
                Type        = 'CiscoSMBNew'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Cisco SMB old/new with old-style SW version output
        # ----------------------------------------------------

        if (
            $Fingerprint -match
            '(?im)^\r?[ \t]*SW[ \t]+version[ \t]+'
        ) {

            $System = Invoke-Command `
                -Connection $Connection `
                -Command $EngineCommands.arubaShowSystem


            $SystemID = Invoke-Command `
                -Connection $Connection `
                -Command $EngineCommands.arubaShowSystemId


            $Fingerprint += $System.Text
            $Fingerprint += $SystemID.Text


            if (
                $Fingerprint -match
                '(?i)(CBS[235][0-9]+|SG350|SG550|SF350)'
            ) {
                $SMBType = 'CiscoSMBNew'
            } else {
                $SMBType = 'CiscoSMBOld'
            }


            return [pscustomobject]@{
                Type        = $SMBType
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Huawei / HPE Comware / H3C
        # ----------------------------------------------------

        $DisplayVersion = Invoke-Command `
            -Connection $Connection `
            -Command $EngineCommands.huaweiDisplayVersion


        $Fingerprint += $DisplayVersion.Text


        if (
            $DisplayVersion.Text -match
            '(?i)(Huawei|Versatile Routing Platform|\bVRP\b)'
        ) {

            return [pscustomobject]@{
                Type        = 'Huawei'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        if (
            $DisplayVersion.Text -match
            '(?i)(Hewlett Packard Enterprise|HP(?:E)? Comware|HPE Flex(?:Network|Fabric))'
        ) {

            return [pscustomobject]@{
                Type        = 'HPEComware'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        if (
            $DisplayVersion.Text -match
            '(?i)(H3C|New H3C|H3C Comware)'
        ) {

            return [pscustomobject]@{
                Type        = 'H3C'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Palo Alto
        # ----------------------------------------------------

        $SystemInfo = Invoke-Command `
            -Connection $Connection `
            -Command $EngineCommands.paloAltoSystemInfo


        $Fingerprint += $SystemInfo.Text


        if (
            $SystemInfo.Text -match
            '(?i)(sw-version:|PAN-OS|model:\s*PA-)'
        ) {

            return [pscustomobject]@{
                Type        = 'PaloAlto'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # AireOS WLC
        # ----------------------------------------------------

        $SysInfo = Invoke-Command `
            -Connection $Connection `
            -Command $EngineCommands.ciscoAireOsSystemInfo


        $Fingerprint += $SysInfo.Text


        if (
            $SysInfo.Text -match
            '(?i)(Cisco Controller|Product Version|Burned-in MAC Address)'
        ) {

            return [pscustomobject]@{
                Type        = 'CiscoAireOSWLC'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Check Point
        # ----------------------------------------------------

        $GaiaVersion = Invoke-Command `
            -Connection $Connection `
            -Command $EngineCommands.checkPointShowVersion


        $Fingerprint += $GaiaVersion.Text


        if (
            $GaiaVersion.Text -match
            '(?i)(Check Point|Gaia)'
        ) {

            return [pscustomobject]@{
                Type        = 'CheckPoint'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # FortiGate / FortiSwitch
        # ----------------------------------------------------

        $FortiStatus = Invoke-Command `
            -Connection $Connection `
            -Command $EngineCommands.fortinetSystemStatus


        $Fingerprint += $FortiStatus.Text


        if (
            $FortiStatus.Text -match
            '(?i)(FortiGate|FortiOS)'
        ) {

            return [pscustomobject]@{
                Type        = 'FortiGate'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        if (
            $FortiStatus.Text -match
            '(?i)(FortiSwitch|FortiSwitchOS)'
        ) {

            return [pscustomobject]@{
                Type        = 'FortiSwitch'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # NVIDIA Cumulus Linux NVUE
        # ----------------------------------------------------

        $CumulusSystem = Invoke-Command `
            -Connection $Connection `
            -Command $EngineCommands.cumulusShowSystem

        $Fingerprint += $CumulusSystem.Text

        if (
            $CumulusSystem.Text -match
            '(?i)(Cumulus Linux|NVIDIA Cumulus|NVUE)'
        ) {

            return [pscustomobject]@{
                Type        = 'NvidiaCumulusLinux'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # F5 BIG-IP, either native tmsh or advanced bash shell
        # ----------------------------------------------------

        $F5TmshVersion = Invoke-Command `
            -Connection $Connection `
            -Command $EngineCommands.f5TmshSystemVersion

        $Fingerprint += $F5TmshVersion.Text

        if (
            $F5TmshVersion.Text -match
            '(?i)(BIG-IP|Sys::Version|TMOS)'
        ) {

            return [pscustomobject]@{
                Type        = 'F5BIGIPTMSH'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        $F5BashVersion = Invoke-Command `
            -Connection $Connection `
            -Command $EngineCommands.f5BashSystemVersion

        $Fingerprint += $F5BashVersion.Text

        if (
            $F5BashVersion.Text -match
            '(?i)(BIG-IP|Sys::Version|TMOS)'
        ) {

            return [pscustomobject]@{
                Type        = 'F5BIGIPBash'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # TP-Link JetStream / Omada switch
        # ----------------------------------------------------

        $TPLinkInfo = Invoke-Command `
            -Connection $Connection `
            -Command $EngineCommands.tpLinkSystemInfo

        $Fingerprint += $TPLinkInfo.Text

        if (
            $TPLinkInfo.Text -match
            '(?i)(TP-LINK|JetStream|System Description\s*-.*(?:T[123]600|JetStream))'
        ) {

            return [pscustomobject]@{
                Type        = 'TPLinkJetStream'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Ubiquiti UniFi adoptable Network device
        # ----------------------------------------------------

        $UniFiInfo = Invoke-Command `
            -Connection $Connection `
            -Command $EngineCommands.unifiInfo

        $Fingerprint += $UniFiInfo.Text

        if (
            $UniFiInfo.Text -match
            '(?i)(UniFi|Inform URL|Model:\s*U(?:AP|SW|GW|XG|DM))'
        ) {

            return [pscustomobject]@{
                Type        = 'UbiquitiUniFiNetwork'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # Sophos Device Console fallback (for banners that do not name it)
        # ----------------------------------------------------

        $SophosVersion = Invoke-Command `
            -Connection $Connection `
            -Command $EngineCommands.sophosSystemVersion

        $Fingerprint += $SophosVersion.Text

        if (
            $SophosVersion.Text -match
            '(?i)(Sophos Firewall|SFOS|Sophos.*Build)'
        ) {

            return [pscustomobject]@{
                Type        = 'SophosFirewall'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        # ----------------------------------------------------
        # MikroTik fallback
        # ----------------------------------------------------

        $MikroTikStatus = Invoke-Command `
            -Connection $Connection `
            -Command $EngineCommands.mikroTikSystemResource


        $Fingerprint += $MikroTikStatus.Text


        if (
            $MikroTikStatus.Text -match
            '(?i)(RouterOS|MikroTik|board-name|routerboard)'
        ) {

            return [pscustomobject]@{
                Type        = 'MikroTik'
                CLI         = $Cli
                Fingerprint = $Fingerprint
            }
        }


        return [pscustomobject]@{
            Type        = 'Unknown'
            CLI         = $Cli
            Fingerprint = $Fingerprint
        }
    }


    # ========================================================
    # WEB DISCOVERY
    # ========================================================

    function Get-WebFingerprint {

        param(
            [string]$Target,
            [string]$Folder
        )


        $AllContent = ''


        foreach ($Scheme in @('https', 'http')) {

            $Port = if (
                $Scheme -eq 'https'
            ) {
                443
            } else {
                80
            }


            if (
                -not (
                    Test-Port `
                        -Computer $Target `
                        -Port $Port
                )
            ) {
                continue
            }


            try {

                $Response = Invoke-WebRequest `
                    -Uri ("{0}://{1}/" -f $Scheme, $Target) `
                    -TimeoutSec 10 `
                    -MaximumRedirection 5 `
                    -SkipCertificateCheck `
                    -ErrorAction Stop


                $AllContent += $Response.Content


                $Response.Content |
                    Set-Content `
                        -Path (
                            Join-Path `
                                $Folder `
                                "web-$Scheme.html"
                        ) `
                        -Encoding UTF8
            }
            catch {

                $_ |
                    Out-String |
                    Set-Content `
                        -Path (
                            Join-Path `
                                $Folder `
                                "web-$Scheme.error.txt"
                        )
            }
        }


        if (
            $AllContent -match
            '(?i)(SG200|Cisco Small Business|Cisco Systems|Linksys)'
        ) {
            return 'CiscoSG200Web'
        }


        if ($AllContent) {
            return 'WebUnknown'
        }


        return 'Unknown'
    }


    # ========================================================
    # DELL OS10 SPECIAL BPDU COLLECTION
    # ========================================================

    function Invoke-DellOS10BPDU {

        param(
            $Connection,
            [string]$Folder
        )


        Write-Host (
            "[{0}] BPDU : show spanning-tree active" -f
            $Target
        )


        $Active = Invoke-Command `
            -Connection $Connection `
            -Command $Config.profiles.DellOS10.specialCommands.active


        $ActiveClean = Get-CleanCommandOutput `
            -Text $Active.Text `
            -Command $Config.profiles.DellOS10.specialCommands.active `
            -Prompt $Active.Prompt


        $ActiveClean |
            Set-Content `
                -Path (
                    Join-Path `
                        $Folder `
                        'BPDU.show.spanning-tree.active.txt'
                ) `
                -Encoding UTF8


        if ($Active.Status -ne 'Prompt') {
            return
        }


        #
        # OS10 output uses names such as:
        #
        # ethernet1/1/7
        #
        $Interfaces = @(
            [regex]::Matches(
                $Active.Text,
                '(?i)\bethernet(?<Port>\d+/\d+/\d+(?::\d+)?)\b'
            ) |
            ForEach-Object {
                $_.Groups['Port'].Value
            } |
            Sort-Object -Unique
        )


        foreach ($Interface in $Interfaces) {

            $Command = (
                $Config.profiles.DellOS10.specialCommands.interfaceTemplate -f
                $Interface
            )


            Write-Host (
                "[{0}] BPDU : {1}" -f
                $Target,
                $Command
            )


            $Result = Invoke-Command `
                -Connection $Connection `
                -Command $Command


            $SafeInterface = Get-SafeName `
                -Name $Interface


            $ResultClean = Get-CleanCommandOutput `
                -Text $Result.Text `
                -Command $Command `
                -Prompt $Result.Prompt


            $ResultClean |
                Set-Content `
                    -Path (
                        Join-Path `
                            $Folder `
                            "BPDU.interface.$SafeInterface.txt"
                    ) `
                    -Encoding UTF8


            if ($Result.Status -ne 'Prompt') {
                break
            }
        }
    }


    # ========================================================
    # EXTREME EXOS SPECIAL BPDU COLLECTION
    # ========================================================

    function Invoke-ExtremeEXOSBPDU {

        param(
            $Connection,
            [string]$Folder
        )


        Write-Host (
            "[{0}] BPDU : show stpd" -f
            $Target
        )


        $STPDOutput = Invoke-Command `
            -Connection $Connection `
            -Command $Config.profiles.ExtremeEXOS.specialCommands.stpd


        $STPDClean = Get-CleanCommandOutput `
            -Text $STPDOutput.Text `
            -Command $Config.profiles.ExtremeEXOS.specialCommands.stpd `
            -Prompt $STPDOutput.Prompt


        $STPDClean |
            Set-Content `
                -Path (
                    Join-Path `
                        $Folder `
                        'BPDU.show.stpd.txt'
                ) `
                -Encoding UTF8


        if ($STPDOutput.Status -ne 'Prompt') {
            return
        }


        #
        # Example row:
        #
        # s0  0000  E-----  48 ...
        #
        $STPDs = @(
            $STPDOutput.Text -split "`r?`n" |
            ForEach-Object {

                if (
                    $_ -match
                    '^\s*(?<STPD>[A-Za-z][A-Za-z0-9_-]*)\s+(?:[0-9A-Fa-f]{4}|----)\s+[A-Z-]{3,}'
                ) {
                    $Matches.STPD
                }
            } |
            Sort-Object -Unique
        )


        foreach ($STPD in $STPDs) {

            #
            # First discover participating ports.
            #
            $PortCommand = (
                $Config.profiles.ExtremeEXOS.specialCommands.portsTemplate -f
                $STPD
            )


            Write-Host (
                "[{0}] BPDU : {1}" -f
                $Target,
                $PortCommand
            )


            $PortOutput = Invoke-Command `
                -Connection $Connection `
                -Command $PortCommand


            $SafeSTPD = Get-SafeName `
                -Name $STPD


            $PortClean = Get-CleanCommandOutput `
                -Text $PortOutput.Text `
                -Command $PortCommand `
                -Prompt $PortOutput.Prompt


            $PortClean |
                Set-Content `
                    -Path (
                        Join-Path `
                            $Folder `
                            "BPDU.$SafeSTPD.ports.txt"
                    ) `
                    -Encoding UTF8


            if ($PortOutput.Status -ne 'Prompt') {
                break
            }


            #
            # Extreme ports can look like:
            #
            # 1
            # 24
            # 1:1
            # 10:10
            #
            $Ports = @(
                $PortOutput.Text -split "`r?`n" |
                ForEach-Object {

                    if (
                        $_ -match
                        '^\s*(?<Port>\d+(?::\d+)?)\s+'
                    ) {
                        $Matches.Port
                    }
                } |
                Sort-Object -Unique
            )


            if ($Ports.Count -eq 0) {

                Write-Warning (
                    "{0} : could not determine ports for STPD {1}" -f
                    $Target,
                    $STPD
                )

                continue
            }


            #
            # One command per STPD.
            #
            # Use a multi-port list rather than one command
            # for every physical port.
            #
            $PortList = $Ports -join ','


            $CounterCommand = (
                $Config.profiles.ExtremeEXOS.specialCommands.countersTemplate -f
                $STPD,
                $PortList
            )


            Write-Host (
                "[{0}] BPDU : {1}" -f
                $Target,
                $CounterCommand
            )


            $CounterOutput = Invoke-Command `
                -Connection $Connection `
                -Command $CounterCommand


            $CounterClean = Get-CleanCommandOutput `
                -Text $CounterOutput.Text `
                -Command $CounterCommand `
                -Prompt $CounterOutput.Prompt


            $CounterClean |
                Set-Content `
                    -Path (
                        Join-Path `
                            $Folder `
                            "BPDU.$SafeSTPD.counters.txt"
                    ) `
                    -Encoding UTF8


            if ($CounterOutput.Status -ne 'Prompt') {
                break
            }
        }
    }


    # ========================================================
    # MIKROTIK SPECIAL BPDU COLLECTION
    #
    # User requested:
    #
    # /interface/bridge/port monitor [find]
    #
    # Monitor mode is continuous, so collect for a few seconds,
    # then Ctrl+C and return to CLI.
    # ========================================================

    function Invoke-MikroTikBPDU {

        param(
            $Connection,
            [string]$Folder
        )


        $Command = $Config.profiles.MikroTik.specialCommands.monitor
        $ExecutedCommands.Add($Command)


        Write-Host (
            "[{0}] BPDU : {1}" -f
            $Target,
            $Command
        )


        Send-Line `
            -Connection $Connection `
            -Text $Command


        $Output = ''

        $Timer = [Diagnostics.Stopwatch]::StartNew()


        while ($Timer.Elapsed.TotalSeconds -lt 4) {

            Assert-NotCancelled

            Start-Sleep -Milliseconds 200


            $Data = Read-Chunk `
                -Connection $Connection


            if ($null -ne $Data) {
                $Output += $Data
            }
        }


        #
        # Ctrl+C
        #
        Send-Raw `
            -Connection $Connection `
            -Text ([char]3)


        $PromptResult = Read-ToPrompt `
            -Connection $Connection


        $Output += $PromptResult.Text


        $CleanOutput = Get-CleanCommandOutput `
            -Text $Output `
            -Command $Command `
            -Prompt $PromptResult.Prompt


        $CleanOutput |
            Set-Content `
                -Path (
                    Join-Path `
                        $Folder `
                        'BPDU.interface.bridge.port.monitor.txt'
                ) `
                -Encoding UTF8
    }

    $Credential = $CredentialBundle.Credential
    $Password = $Credential.GetNetworkCredential().Password
    $EnablePassword = $Password
    if ($CredentialBundle.EnablePassword) {
        $EnablePassword = [pscredential]::new(
            'enable',
            [securestring]$CredentialBundle.EnablePassword
        ).GetNetworkCredential().Password
    }

    $DeviceFolder = $null
    if ($RunMode -eq 'FullAudit') {
        $SafeSite = Get-SafeName -Name $Site
        $SafeTarget = Get-SafeName -Name $Target
        $DeviceFolder = Join-Path (Join-Path $RunFolder $SafeSite) $SafeTarget
        [IO.Directory]::CreateDirectory($DeviceFolder) | Out-Null
    }

    $Connection = $null
    $Protocol = ''
    $Type = ''

    try {
        Assert-NotCancelled
        $OpeningMessage = if ($RunMode -eq 'Preflight') { 'Beginning safe preflight.' } else { 'Beginning collection.' }
        Publish-Event -Phase 'Queue' -Status 'Connecting' -Message $OpeningMessage

        $ForcedType = [string]$Device.type
        if ($ForcedType -eq 'Auto') {
            $ForcedType = ''
        }

        if ($ForcedType -eq 'CiscoSG200Web') {
            if ($RunMode -eq 'Preflight') {
                $WebAvailable = (Test-Port -Computer $Target -Port 443) -or (Test-Port -Computer $Target -Port 80)
                $Verdict = if ($WebAvailable) { 'Warning' } else { 'Fail' }
                $Message = if ($WebAvailable) {
                    'Web-managed device is reachable; CLI detection was intentionally skipped.'
                } else {
                    'Web-managed device is not reachable on TCP 80 or 443.'
                }
                Publish-Event -Level 'Warning' -Phase 'Complete' -Status $Verdict -Message $Message `
                    -Type 'CiscoSG200Web' -Terminal $true
                return [pscustomobject]@{
                    Site = $Site; Target = $Target; Protocol = 'Web'; Type = 'CiscoSG200Web'
                    Status = $Verdict; PreflightVerdict = $Verdict; RequestedType = [string]$Device.type
                    DetectedType = 'CiscoSG200Web'; Message = $Message; CommandsExecuted = @($ExecutedCommands)
                }
            }
            Publish-Event -Phase 'Web' -Status 'Running' -Message 'Capturing web fingerprint.'
            $null = Get-WebFingerprint -Target $Target -Folder $DeviceFolder
            $Type = 'CiscoSG200Web'
            Publish-Event -Phase 'Complete' -Status 'Complete' -Message 'Web fingerprint captured.' -Type $Type -Terminal $true
            return [pscustomobject]@{
                Site = $Site; Target = $Target; Protocol = 'Web'; Type = $Type
                Status = 'Complete'; PreflightVerdict = ''; RequestedType = [string]$Device.type
                DetectedType = $Type; Message = 'Web fingerprint captured.'; CommandsExecuted = @($ExecutedCommands)
            }
        }

        $SshAvailable = Test-Port -Computer $Target -Port 22
        Assert-NotCancelled
        $TelnetAvailable = Test-Port -Computer $Target -Port 23
        Publish-Event -Level 'Debug' -Phase 'Connect' -Status 'Connecting' `
            -Message ("SSH={0}; Telnet={1}" -f $SshAvailable, $TelnetAvailable)

        $Login = $null
        $CiscoLegacyLogin = $false
        foreach ($TryProtocol in @('SSH', 'Telnet')) {
            Assert-NotCancelled
            if ($ForcedType -eq 'CiscoLegacy' -and $TryProtocol -eq 'SSH') { continue }
            if ($TryProtocol -eq 'SSH' -and -not $SshAvailable) { continue }
            if ($TryProtocol -eq 'Telnet' -and -not $TelnetAvailable) { continue }

            try {
                Publish-Event -Phase 'Connect' -Status 'Connecting' -Message "Trying $TryProtocol."
                $Connection = New-Connection -Target $Target -Credential $Credential -Protocol $TryProtocol
                $Login = Read-ToPrompt -Connection $Connection -Username $Credential.UserName `
                    -Password $Password -HandleLogin -WakeIfSilent

                if ($TryProtocol -eq 'Telnet' -and $Login.Status -ne 'Prompt' -and (
                    $ForcedType -eq 'CiscoLegacy' -or
                    [string]$Login.Text -match '(?i)(Login Screen|Switch Main Menu)'
                )) {
                    Publish-Event -Phase 'Legacy SMB login' -Status 'Connecting' `
                        -Message 'Cisco Legacy menu interface detected.' -Type 'CiscoLegacy'
                    $Login = Enter-CiscoSmallBusinessLegacyCli -Connection $Connection `
                        -Username $Credential.UserName -Password $Password -InitialText ([string]$Login.Text)
                    $CiscoLegacyLogin = $true
                }

                if ($Login.Status -eq 'Menu' -and (
                    $ForcedType -eq 'SophosFirewall' -or
                    [string]$Login.Text -match '(?is)(Sophos\s+Firewall|Device\s+Console.*Device\s+Management)'
                )) {
                    $Login = Enter-SophosDeviceConsole -Connection $Connection `
                        -InitialText ([string]$Login.Text)
                }

                $SafeInitialText = [string]$Login.Text
                if ($Password) { $SafeInitialText = $SafeInitialText.Replace($Password, '***') }
                if ($EnablePassword) { $SafeInitialText = $SafeInitialText.Replace($EnablePassword, '***') }
                if ($RunMode -eq 'FullAudit') {
                    $SafeInitialText | Set-Content -LiteralPath (Join-Path $DeviceFolder "$TryProtocol.initial.txt") -Encoding UTF8
                }
                if ($Login.Status -eq 'Prompt') {
                    $Connection.ExpectedPrompt = $Login.Prompt
                    $Protocol = $TryProtocol
                    break
                }

                Close-Connection -Connection $Connection
                $Connection = $null
            }
            catch {
                $SafeMessage = $_.Exception.Message.Replace($Password, '***')
                if ($RunMode -eq 'FullAudit') {
                    $SafeMessage | Set-Content -LiteralPath (Join-Path $DeviceFolder "$TryProtocol.error.txt") -Encoding UTF8
                }
                Publish-Event -Level 'Warning' -Phase 'Connect' -Status 'Connecting' -Message "$TryProtocol failed: $SafeMessage"
                if ($Connection) { Close-Connection -Connection $Connection }
                $Connection = $null
                if ($RunMode -eq 'Preflight' -and $TryProtocol -eq 'SSH' -and
                    $SafeMessage -match '(?i)(host.?key|fingerprint|known[_ -]?hosts|key has changed|not trusted|trust failure)') {
                    throw "SSH host-key validation failed: $SafeMessage"
                }
            }
        }

        Assert-NotCancelled
        if (-not $Connection) {
            if ($RunMode -eq 'Preflight') {
                $WebAvailable = (Test-Port -Computer $Target -Port 443) -or (Test-Port -Computer $Target -Port 80)
                $Verdict = if ($WebAvailable) { 'Warning' } else { 'Fail' }
                $Message = if ($WebAvailable) {
                    'No usable CLI, but a web service is reachable.'
                } else {
                    'No usable SSH, Telnet, or web service was found.'
                }
                Publish-Event -Level 'Warning' -Phase 'Complete' -Status $Verdict -Message $Message `
                    -Type $(if ($WebAvailable) { 'WebUnknown' } else { 'Unknown' }) -Terminal $true
                return [pscustomobject]@{
                    Site = $Site; Target = $Target; Protocol = $(if ($WebAvailable) { 'Web' } else { '' })
                    Type = $(if ($WebAvailable) { 'WebUnknown' } else { 'Unknown' })
                    Status = $Verdict; PreflightVerdict = $Verdict; RequestedType = [string]$Device.type
                    DetectedType = ''; Message = $Message; CommandsExecuted = @($ExecutedCommands)
                }
            }
            $WebType = Get-WebFingerprint -Target $Target -Folder $DeviceFolder
            Publish-Event -Level 'Warning' -Phase 'Complete' -Status 'Failed' `
                -Message "No usable CLI; web fingerprint: $WebType" -Type $WebType -Terminal $true
            return [pscustomobject]@{
                Site = $Site; Target = $Target; Protocol = 'Web/Menu'; Type = $WebType
                Status = 'No usable CLI'; PreflightVerdict = ''; RequestedType = [string]$Device.type
                DetectedType = $WebType; Message = 'No usable CLI.'; CommandsExecuted = @($ExecutedCommands)
            }
        }

        Publish-Event -Phase 'Detect' -Status 'Detecting' -Message 'Determining device type.'
        if ($RunMode -eq 'Preflight' -and $CiscoLegacyLogin) {
            $VersionCommand = [string]$EngineCommands.genericShowVersion
            Publish-Event -Phase 'Detect' -Status 'Checking version' `
                -Message $VersionCommand -Command $VersionCommand -Type 'CiscoLegacy'
            $VersionResult = Invoke-Command -Connection $Connection -Command $VersionCommand

            $DetectedType = 'CiscoLegacy'
            $Type = $DetectedType
            $VersionConfirmed = $VersionResult.Status -eq 'Prompt' -and
                -not (Test-CommandFailed -Text $VersionResult.Text) -and
                $VersionResult.Text -match '(?im)^\s*SW\s+version\s+\S+'

            if (-not $VersionConfirmed) {
                $FailureMessage = "Cisco Legacy double login succeeded, but '$VersionCommand' did not return the expected SGE version output."
                Publish-Event -Level 'Error' -Phase 'Complete' -Status 'Fail' `
                    -Message $FailureMessage -Type $Type -Terminal $true
                return [pscustomobject]@{
                    Site = $Site; Target = $Target; Protocol = $Protocol; Type = $Type
                    Status = 'Fail'; PreflightVerdict = 'Fail'; RequestedType = [string]$Device.type
                    DetectedType = $DetectedType; Message = $FailureMessage; CommandsExecuted = @($ExecutedCommands)
                    DetectionCommands = @($VersionCommand); RejectedDetectionCommands = @($VersionCommand)
                }
            }

            $Messages = [Collections.Generic.List[string]]::new()
            $Messages.Add('Cisco Legacy double login succeeded and reached the LCLI prompt.')
            $Messages.Add("The read-only '$VersionCommand' check confirmed $DetectedType.")
            if ($ForcedType -and $ForcedType -ne $DetectedType) {
                $Messages.Add("Requested profile $ForcedType does not match detected type $DetectedType.")
            }
            $Messages.Add('Telnet succeeded, but it is unencrypted.')
            $PreflightMessage = $Messages -join ' '
            Publish-Event -Level 'Warning' -Phase 'Complete' -Status 'Warning' `
                -Message $PreflightMessage -Type $Type -Terminal $true
            return [pscustomobject]@{
                Site = $Site; Target = $Target; Protocol = $Protocol; Type = $Type
                Status = 'Warning'; PreflightVerdict = 'Warning'; RequestedType = [string]$Device.type
                DetectedType = $DetectedType; Message = $PreflightMessage; CommandsExecuted = @($ExecutedCommands)
                DetectionCommands = @($VersionCommand); RejectedDetectionCommands = @()
            }
        } elseif ($RunMode -eq 'Preflight') {
            $ObservationStart = $CommandObservations.Count
            $Detection = Detect-Device -Connection $Connection -Login $Login
            $DetectedType = [string]$Detection.Type
            $Type = if ($Config.profiles.ContainsKey($DetectedType)) { $DetectedType } elseif ($ForcedType) { $ForcedType } else { $DetectedType }

            $DetectionObservations = @($CommandObservations | Select-Object -Skip $ObservationStart)
            $DetectionCommands = @($DetectionObservations | ForEach-Object Command | Select-Object -Unique)
            $RejectedDetectionCommands = @($DetectionObservations | Where-Object Rejected | ForEach-Object Command | Select-Object -Unique)
            $PromptFailureCommands = @($DetectionObservations | Where-Object Status -ne 'Prompt' | ForEach-Object Command | Select-Object -Unique)
            $SuccessfulDetectionCommands = @($DetectionObservations | Where-Object { $_.Status -eq 'Prompt' -and -not $_.Rejected } | ForEach-Object Command | Select-Object -Unique)
            $DetectionDetail = if ($DetectionCommands.Count -eq 0) {
                'The device was identified from its login banner; no detection command was required.'
            } else {
                "Read-only checks attempted: $($DetectionCommands -join ', ')."
            }
            if ($SuccessfulDetectionCommands.Count -gt 0) {
                $DetectionDetail += " Usable responses: $($SuccessfulDetectionCommands -join ', ')."
            }
            if ($RejectedDetectionCommands.Count -gt 0) {
                $DetectionDetail += " Rejected or unsupported commands: $($RejectedDetectionCommands -join ', ')."
            }
            if ($PromptFailureCommands.Count -gt 0) {
                $DetectionDetail += " Commands that did not return to the CLI prompt: $($PromptFailureCommands -join ', ')."
            }

            $Verdict = 'Pass'
            $Messages = [Collections.Generic.List[string]]::new()
            if (-not $Config.profiles.ContainsKey($DetectedType)) {
                if ($ForcedType) {
                    $Verdict = 'Warning'
                    $Messages.Add("Authentication and CLI prompt checks succeeded, but no supported vendor signature matched the read-only responses. Requested profile: $ForcedType. $DetectionDetail Verify the device's version output before running the full audit.")
                } else {
                    $Verdict = 'Fail'
                    $Messages.Add("Authentication and CLI prompt checks succeeded, but the device type could not be safely identified. $DetectionDetail Select a profile manually only after confirming the device family.")
                }
            } elseif ($ForcedType -and $ForcedType -ne $DetectedType) {
                $Verdict = 'Warning'
                $Messages.Add("Profile disagreement: the device is configured as $ForcedType, but its read-only response matched $DetectedType. $DetectionDetail")
            } else {
                $Messages.Add("Authentication and CLI prompt checks succeeded. Detection confirmed $DetectedType. $DetectionDetail")
            }
            if ($Protocol -eq 'Telnet') {
                if ($Verdict -eq 'Pass') { $Verdict = 'Warning' }
                $Messages.Add('Telnet succeeded, but it is unencrypted.')
            }
            $PreflightMessage = $Messages -join ' '
            $Level = if ($Verdict -eq 'Pass') { 'Info' } elseif ($Verdict -eq 'Warning') { 'Warning' } else { 'Error' }
            Publish-Event -Level $Level -Phase 'Complete' -Status $Verdict -Message $PreflightMessage `
                -Type $Type -Terminal $true
            return [pscustomobject]@{
                Site = $Site; Target = $Target; Protocol = $Protocol; Type = $Type
                Status = $Verdict; PreflightVerdict = $Verdict; RequestedType = [string]$Device.type
                DetectedType = $DetectedType; Message = $PreflightMessage; CommandsExecuted = @($ExecutedCommands)
                DetectionCommands = @($DetectionCommands); RejectedDetectionCommands = @($RejectedDetectionCommands)
            }
        } elseif ($CiscoLegacyLogin -and -not $ForcedType) {
            $Type = 'CiscoLegacy'
            $Detection = [pscustomobject]@{
                Type = $Type; CLI = $Login
                Fingerprint = 'Cisco Legacy menu and LCLI double login.'
            }
        } elseif ($ForcedType) {
            $Type = $ForcedType
            if ($Type -in @('Juniper', 'JuniperSRX') -and $Login.Prompt -match '[$%]$') {
                $Login = Invoke-Command -Connection $Connection -Command $EngineCommands.juniperEnterCli -AllowPromptChange
            }
            if ($Type -eq 'CheckPoint' -and $Login.Prompt -match '^\[Expert@') {
                $Login = Invoke-Command -Connection $Connection -Command $EngineCommands.checkPointEnterClish -AllowPromptChange
            }
            $Detection = [pscustomobject]@{ Type = $Type; CLI = $Login; Fingerprint = $Login.Text }
        } else {
            $Detection = Detect-Device -Connection $Connection -Login $Login
            $Type = [string]$Detection.Type
        }

        $SafeFingerprint = [string]$Detection.Fingerprint
        if ($Password) { $SafeFingerprint = $SafeFingerprint.Replace($Password, '***') }
        if ($EnablePassword) { $SafeFingerprint = $SafeFingerprint.Replace($EnablePassword, '***') }
        $SafeFingerprint | Set-Content -LiteralPath (Join-Path $DeviceFolder 'fingerprint.txt') -Encoding UTF8
        Publish-Event -Phase 'Detect' -Status 'Detected' -Message "Detected $Type." -Type $Type

        if (-not $Config.profiles.ContainsKey($Type)) {
            Publish-Event -Level 'Warning' -Phase 'Complete' -Status 'Failed' `
                -Message "Unknown device type: $Type" -Type $Type -Terminal $true
            return [pscustomobject]@{
                Site = $Site; Target = $Target; Protocol = $Protocol; Type = $Type
                Status = 'Unknown device type'; PreflightVerdict = ''; RequestedType = [string]$Device.type
                DetectedType = $Type; Message = 'Unknown device type.'; CommandsExecuted = @($ExecutedCommands)
            }
        }

        $Profile = $Config.profiles[$Type]
        $Cli = $Detection.CLI
        if ([bool]$Profile.enable -and $Cli.Prompt -match '>$') {
            Assert-NotCancelled
            Publish-Event -Phase 'Prepare' -Status 'Preparing' -Message 'Entering enable mode.' -Type $Type
            $EnableResult = Invoke-Command -Connection $Connection -Command $EngineCommands.enable `
                -PromptPassword $EnablePassword -AllowPromptChange
            if ($EnableResult.Status -eq 'Prompt') { $Cli = $EnableResult }
        }

        @"
Site:       $Site
Target:     $Target
Hostname:   $($Cli.Hostname)
Protocol:   $Protocol
Type:       $Type
Collected:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@ | Set-Content -LiteralPath (Join-Path $DeviceFolder 'device-info.txt') -Encoding UTF8

        foreach ($PagingCommand in @($Profile.paging)) {
            Assert-NotCancelled
            Publish-Event -Phase 'Prepare' -Status 'Preparing' -Message $PagingCommand -Command $PagingCommand -Type $Type
            $PagingResult = Invoke-Command -Connection $Connection -Command $PagingCommand
            $PagingResult.Text | Add-Content -LiteralPath (Join-Path $DeviceFolder 'paging.txt') -Encoding UTF8
            if (-not (Test-CommandFailed -Text $PagingResult.Text)) { break }
        }

        $Commands = if ($Type -in @('Juniper', 'JuniperSRX') -and $Config.settings.juniperOutputMode -eq 'Text') {
            @($Profile.textCommands)
        } else {
            @($Profile.commands)
        }
        $Commands = @($Commands | Select-Object -Unique)

        for ($Index = 0; $Index -lt $Commands.Count; $Index++) {
            Assert-NotCancelled
            $Command = [string]$Commands[$Index]
            Publish-Event -Phase 'Collect' -Status ("Running {0}/{1}" -f ($Index + 1), $Commands.Count) `
                -Message $Command -Command $Command -CommandIndex ($Index + 1) -CommandTotal $Commands.Count -Type $Type

            $Result = Invoke-Command -Connection $Connection -Command $Command
            $FileName = "$(Get-SafeName -Name $Target).$(Get-CommandFileName -Command $Command)"
            $OutputFile = Join-Path $DeviceFolder $FileName
            $CleanOutput = Get-CleanCommandOutput -Text $Result.Text -Command $Command -Prompt $Result.Prompt
            $CleanOutput | Set-Content -LiteralPath $OutputFile -Encoding UTF8

            if ($Result.Status -ne 'Prompt') {
                throw "Lost the CLI after '$Command' ($($Result.Status))."
            }
            if ($Type -eq 'CiscoLegacy' -and $Command -eq $EngineCommands.genericShowVersion -and (
                (Test-CommandFailed -Text $Result.Text) -or
                $CleanOutput -notmatch '(?im)^\s*SW\s+version\s+\S+'
            )) {
                throw "Cisco Legacy safety check failed: '$Command' did not return the expected SGE version output."
            }
        }

        Assert-NotCancelled
        switch ([string]$Profile.special) {
            'DellOS10' {
                Publish-Event -Phase 'Special' -Status 'Running special collection' -Message 'Collecting Dell OS10 BPDU details.' -Type $Type
                Invoke-DellOS10BPDU -Connection $Connection -Folder $DeviceFolder
            }
            'ExtremeEXOS' {
                Publish-Event -Phase 'Special' -Status 'Running special collection' -Message 'Collecting Extreme EXOS BPDU details.' -Type $Type
                Invoke-ExtremeEXOSBPDU -Connection $Connection -Folder $DeviceFolder
            }
            'MikroTik' {
                Publish-Event -Phase 'Special' -Status 'Running special collection' -Message 'Collecting MikroTik BPDU details.' -Type $Type
                Invoke-MikroTikBPDU -Connection $Connection -Folder $DeviceFolder
            }
        }

        Publish-Event -Phase 'Complete' -Status 'Complete' -Message 'Collection completed.' -Type $Type -Terminal $true
        return [pscustomobject]@{
            Site = $Site; Target = $Target; Protocol = $Protocol; Type = $Type
            Status = 'Complete'; PreflightVerdict = ''; RequestedType = [string]$Device.type
            DetectedType = $Type; Message = 'Collection completed.'; CommandsExecuted = @($ExecutedCommands)
        }
    }
    catch [OperationCanceledException] {
        $CancelledMessage = if ($RunMode -eq 'Preflight') { 'Preflight cancelled.' } else { 'Collection cancelled.' }
        Publish-Event -Level 'Warning' -Phase 'Complete' -Status 'Cancelled' `
            -Message $CancelledMessage -Type $Type -Terminal $true
        return [pscustomobject]@{
            Site = $Site; Target = $Target; Protocol = $Protocol; Type = $Type
            Status = 'Cancelled'; PreflightVerdict = $(if ($RunMode -eq 'Preflight') { 'Cancelled' } else { '' })
            RequestedType = [string]$Device.type; DetectedType = $Type
            Message = $CancelledMessage; CommandsExecuted = @($ExecutedCommands)
        }
    }
    catch {
        $SafeMessage = $_.Exception.Message
        if ($Password) { $SafeMessage = $SafeMessage.Replace($Password, '***') }
        if ($EnablePassword) { $SafeMessage = $SafeMessage.Replace($EnablePassword, '***') }
        if ($RunMode -eq 'FullAudit') {
            $SafeMessage | Set-Content -LiteralPath (Join-Path $DeviceFolder 'ERROR.txt') -Encoding UTF8
        }
        $FailureStatus = if ($RunMode -eq 'Preflight') { 'Fail' } else { 'Failed' }
        Publish-Event -Level 'Error' -Phase 'Complete' -Status $FailureStatus `
            -Message $SafeMessage -Type $Type -Terminal $true
        return [pscustomobject]@{
            Site = $Site; Target = $Target; Protocol = $Protocol; Type = $Type
            Status = $FailureStatus; PreflightVerdict = $(if ($RunMode -eq 'Preflight') { 'Fail' } else { '' })
            RequestedType = [string]$Device.type; DetectedType = $Type
            Message = $SafeMessage; CommandsExecuted = @($ExecutedCommands)
        }
    }
    finally {
        if ($Connection) { Close-Connection -Connection $Connection }
        $Password = $null
        $EnablePassword = $null
    }
}

try {
    $script:Config = Read-NetworkAuditConfig -Path $ConfigPath
}
catch {
    [Windows.Forms.MessageBox]::Show(
        "Network Audit could not load its configuration.`r`n`r`n$($_.Exception.Message)",
        'Network Audit - Configuration Error',
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    return
}

$script:Credentials = @{}
$script:Running = $false
$script:ClosingAfterCancel = $false
$script:Jobs = [Collections.Generic.List[object]]::new()
$script:Results = [Collections.Generic.List[object]]::new()
$script:RowMap = @{}
$script:ResolvedTypes = @{}
$script:TerminalTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:EventQueue = $null
$script:Cancellation = $null
$script:RunspacePool = $null
$script:RunFolder = ''
$script:LoadedProfileName = ''
$script:RunMode = ''
$script:SiteScope = 'All Sites'
$script:OfflineIssues = @()
$script:PreflightResults = @{}
$script:PreflightSignature = ''
$script:LastFullAuditFolder = ''
$script:LastFullAuditResults = @()
$script:LastFullAuditRequested = @()
$script:CompletedAuditSites = @()
$script:DiagramProcess = $null
$script:DiagramRunning = $false
$script:DiagramOutputFolder = ''
$script:DiagramSite = ''
$script:DiagramStdoutTask = $null
$script:DiagramStderrTask = $null
$script:DiagramCancelled = $false
$script:DiagramStartedUtc = [datetime]::MinValue

function New-UiButton {
    param([string]$Text, [int]$Width = 110)
    $Button = [Windows.Forms.Button]::new()
    $Button.Text = $Text
    $Button.Width = $Width
    $Button.Height = 30
    return $Button
}

function New-UiTextBox {
    param([switch]$Multiline, [switch]$ReadOnly)
    $TextBox = [Windows.Forms.TextBox]::new()
    $TextBox.Multiline = $Multiline
    $TextBox.ReadOnly = $ReadOnly
    if ($Multiline) {
        $TextBox.AcceptsReturn = $true
        $TextBox.AcceptsTab = $true
        $TextBox.ScrollBars = 'Both'
        $TextBox.WordWrap = $false
        $TextBox.Font = [Drawing.Font]::new('Consolas', 9)
    }
    return $TextBox
}

function Add-GridTextColumn {
    param(
        [Windows.Forms.DataGridView]$Grid,
        [string]$Name,
        [string]$Header,
        [int]$Width,
        [switch]$Fill,
        [switch]$ReadOnly
    )
    $Column = [Windows.Forms.DataGridViewTextBoxColumn]::new()
    $Column.Name = $Name
    $Column.HeaderText = $Header
    $Column.Width = $Width
    $Column.ReadOnly = $ReadOnly
    if ($Fill) { $Column.AutoSizeMode = 'Fill' }
    $null = $Grid.Columns.Add($Column)
}

$Form = [Windows.Forms.Form]::new()
$Form.Text = 'Network Audit'
$Form.StartPosition = 'CenterScreen'
$Form.MinimumSize = [Drawing.Size]::new(980, 680)
$Form.Size = [Drawing.Size]::new(1240, 840)
$Form.Font = [Drawing.Font]::new('Segoe UI', 9)

$Tabs = [Windows.Forms.TabControl]::new()
$Tabs.Dock = 'Fill'
$Form.Controls.Add($Tabs)

# Devices tab
$DevicesTab = [Windows.Forms.TabPage]::new('Devices')
$Tabs.TabPages.Add($DevicesTab)

$DevicesLayout = [Windows.Forms.TableLayoutPanel]::new()
$DevicesLayout.Dock = 'Fill'
$DevicesLayout.ColumnCount = 1
$DevicesLayout.RowCount = 3
$DevicesLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 100)) | Out-Null
$DevicesLayout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 215)) | Out-Null
$DevicesLayout.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100)) | Out-Null
$DevicesLayout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 42)) | Out-Null
$DevicesTab.Controls.Add($DevicesLayout)

$DeviceTop = [Windows.Forms.Panel]::new()
$DeviceTop.Dock = 'Fill'
$DevicesLayout.Controls.Add($DeviceTop, 0, 0)

$DeviceEntryLayout = [Windows.Forms.TableLayoutPanel]::new()
$DeviceEntryLayout.Dock = 'Fill'
$DeviceEntryLayout.Padding = [Windows.Forms.Padding]::new(8)
$DeviceEntryLayout.ColumnCount = 2
$DeviceEntryLayout.RowCount = 1
$DeviceEntryLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 48)) | Out-Null
$DeviceEntryLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 52)) | Out-Null
$DeviceEntryLayout.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100)) | Out-Null
$DeviceTop.Controls.Add($DeviceEntryLayout)

$PasteGroup = [Windows.Forms.GroupBox]::new()
$PasteGroup.Text = '1. Paste switches or routers (one per line)'
$PasteGroup.Dock = 'Fill'
$PasteGroup.Padding = [Windows.Forms.Padding]::new(10, 24, 10, 10)
$DeviceEntryLayout.Controls.Add($PasteGroup, 0, 0)

$PasteBox = New-UiTextBox -Multiline
$PasteBox.Dock = 'Fill'
$PasteGroup.Controls.Add($PasteBox)

$DefaultsGroup = [Windows.Forms.GroupBox]::new()
$DefaultsGroup.Text = '2. Choose defaults, then add the pasted devices'
$DefaultsGroup.Dock = 'Fill'
$DefaultsGroup.Padding = [Windows.Forms.Padding]::new(10, 22, 10, 8)
$DeviceEntryLayout.Controls.Add($DefaultsGroup, 1, 0)

$DefaultsLayout = [Windows.Forms.TableLayoutPanel]::new()
$DefaultsLayout.Dock = 'Fill'
$DefaultsLayout.ColumnCount = 2
$DefaultsLayout.RowCount = 5
$DefaultsLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 50)) | Out-Null
$DefaultsLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new('Percent', 50)) | Out-Null
$DefaultsLayout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 22)) | Out-Null
$DefaultsLayout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 32)) | Out-Null
$DefaultsLayout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 22)) | Out-Null
$DefaultsLayout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute', 34)) | Out-Null
$DefaultsLayout.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent', 100)) | Out-Null
$DefaultsGroup.Controls.Add($DefaultsLayout)

$DefaultSiteLabel = [Windows.Forms.Label]::new()
$DefaultSiteLabel.Text = 'Default site'
$DefaultSiteLabel.Dock = 'Fill'
$DefaultSiteLabel.TextAlign = 'BottomLeft'
$DefaultsLayout.Controls.Add($DefaultSiteLabel, 0, 0)

$DefaultSite = [Windows.Forms.TextBox]::new()
$DefaultSite.Text = 'Unassigned'
$DefaultSite.Dock = 'Fill'
$DefaultSite.Margin = [Windows.Forms.Padding]::new(3, 2, 6, 3)
$DefaultsLayout.Controls.Add($DefaultSite, 0, 1)

$DefaultTypeLabel = [Windows.Forms.Label]::new()
$DefaultTypeLabel.Text = 'Default device type'
$DefaultTypeLabel.Dock = 'Fill'
$DefaultTypeLabel.TextAlign = 'BottomLeft'
$DefaultsLayout.Controls.Add($DefaultTypeLabel, 1, 0)

$DefaultType = [Windows.Forms.ComboBox]::new()
$DefaultType.DropDownStyle = 'DropDownList'
$DefaultType.Dock = 'Fill'
$DefaultType.Margin = [Windows.Forms.Padding]::new(6, 2, 3, 3)
$null = $DefaultType.Items.Add('Auto')
foreach ($Name in @($script:Config.profiles.Keys | Sort-Object)) { $null = $DefaultType.Items.Add($Name) }
$DefaultType.SelectedItem = 'Auto'
$DefaultsLayout.Controls.Add($DefaultType, 1, 1)

$DefaultCredentialLabel = [Windows.Forms.Label]::new()
$DefaultCredentialLabel.Text = 'Password set for pasted devices'
$DefaultCredentialLabel.Dock = 'Fill'
$DefaultCredentialLabel.TextAlign = 'BottomLeft'
$DefaultsLayout.Controls.Add($DefaultCredentialLabel, 0, 2)

$PasswordHelpLabel = [Windows.Forms.Label]::new()
$PasswordHelpLabel.Text = 'Passwords stay in memory only'
$PasswordHelpLabel.Dock = 'Fill'
$PasswordHelpLabel.TextAlign = 'BottomLeft'
$DefaultsLayout.Controls.Add($PasswordHelpLabel, 1, 2)

$DefaultCredential = [Windows.Forms.ComboBox]::new()
$DefaultCredential.DropDownStyle = 'DropDownList'
$DefaultCredential.Dock = 'Fill'
$DefaultCredential.Margin = [Windows.Forms.Padding]::new(3, 2, 6, 4)
$DefaultsLayout.Controls.Add($DefaultCredential, 0, 3)

$CredentialButton = New-UiButton -Text 'Enter / manage passwords...' -Width 190
$CredentialButton.Dock = 'Fill'
$CredentialButton.Margin = [Windows.Forms.Padding]::new(6, 1, 3, 3)
$DefaultsLayout.Controls.Add($CredentialButton, 1, 3)

$AddPastedButton = New-UiButton -Text 'Add pasted switches to device list' -Width 300
$AddPastedButton.Dock = 'Fill'
$AddPastedButton.Margin = [Windows.Forms.Padding]::new(3, 6, 3, 3)
$AddPastedButton.Font = [Drawing.Font]::new('Segoe UI', 9, [Drawing.FontStyle]::Bold)
$DefaultsLayout.Controls.Add($AddPastedButton, 0, 4)
$DefaultsLayout.SetColumnSpan($AddPastedButton, 2)

$DeviceButtons = [Windows.Forms.FlowLayoutPanel]::new()
$DeviceButtons.Dock = 'Fill'
$DeviceButtons.FlowDirection = 'LeftToRight'
$DeviceButtons.Padding = [Windows.Forms.Padding]::new(8, 5, 0, 0)
$DevicesLayout.Controls.Add($DeviceButtons, 0, 2)

$RemoveDeviceButton = New-UiButton -Text 'Remove selected' -Width 130
$ClearDeviceButton = New-UiButton -Text 'Clear list'
$SaveConfigButton = New-UiButton -Text 'Save configuration' -Width 150
$ReloadConfigButton = New-UiButton -Text 'Reload configuration' -Width 155
$DeviceButtons.Controls.AddRange(@($RemoveDeviceButton, $ClearDeviceButton, $SaveConfigButton, $ReloadConfigButton))

$DeviceGrid = [Windows.Forms.DataGridView]::new()
$DeviceGrid.Dock = 'Fill'
$DeviceGrid.AllowUserToAddRows = $true
$DeviceGrid.AllowUserToDeleteRows = $true
$DeviceGrid.AutoGenerateColumns = $false
$DeviceGrid.RowHeadersVisible = $false
$DeviceGrid.SelectionMode = 'FullRowSelect'
$DeviceGrid.MultiSelect = $true
$EnabledColumn = [Windows.Forms.DataGridViewCheckBoxColumn]::new()
$EnabledColumn.Name = 'Enabled'
$EnabledColumn.HeaderText = 'Run'
$EnabledColumn.Width = 50
$null = $DeviceGrid.Columns.Add($EnabledColumn)
Add-GridTextColumn -Grid $DeviceGrid -Name 'Target' -Header 'Device / IP address' -Width 220
Add-GridTextColumn -Grid $DeviceGrid -Name 'Site' -Header 'Site' -Width 170
Add-GridTextColumn -Grid $DeviceGrid -Name 'Credential' -Header 'Credential name' -Width 170
Add-GridTextColumn -Grid $DeviceGrid -Name 'Type' -Header 'Device type (or Auto)' -Width 210 -Fill
$DevicesLayout.Controls.Add($DeviceGrid, 0, 1)

# Commands tab
$CommandsTab = [Windows.Forms.TabPage]::new('Commands')
$Tabs.TabPages.Add($CommandsTab)

$CommandHeader = [Windows.Forms.Panel]::new()
$CommandHeader.Dock = 'Top'
$CommandHeader.Height = 52
$CommandsTab.Controls.Add($CommandHeader)

$ProfileLabel = [Windows.Forms.Label]::new()
$ProfileLabel.Text = 'Device profile'
$ProfileLabel.SetBounds(12, 16, 100, 22)
$CommandHeader.Controls.Add($ProfileLabel)

$ProfileSelector = [Windows.Forms.ComboBox]::new()
$ProfileSelector.DropDownStyle = 'DropDownList'
$ProfileSelector.SetBounds(115, 12, 230, 28)
foreach ($Name in @($script:Config.profiles.Keys | Sort-Object)) { $null = $ProfileSelector.Items.Add($Name) }
$CommandHeader.Controls.Add($ProfileSelector)

$ProfileMetadata = [Windows.Forms.Label]::new()
$ProfileMetadata.AutoSize = $true
$ProfileMetadata.SetBounds(365, 16, 500, 22)
$CommandHeader.Controls.Add($ProfileMetadata)

$ApplyCommandsButton = New-UiButton -Text 'Apply edits' -Width 115
$ApplyCommandsButton.SetBounds(900, 10, 115, 31)
$CommandHeader.Controls.Add($ApplyCommandsButton)

$CommandEditors = [Windows.Forms.TabControl]::new()
$CommandEditors.Dock = 'Fill'
$CommandsTab.Controls.Add($CommandEditors)
$CommandEditors.BringToFront()

function Add-EditorPage {
    param([string]$Title, [string]$Help)
    $Page = [Windows.Forms.TabPage]::new($Title)
    $HelpLabel = [Windows.Forms.Label]::new()
    $HelpLabel.Text = $Help
    $HelpLabel.Dock = 'Top'
    $HelpLabel.Height = 34
    $HelpLabel.Padding = [Windows.Forms.Padding]::new(8, 8, 0, 0)
    $Editor = New-UiTextBox -Multiline
    $Editor.Dock = 'Fill'
    $Page.Controls.Add($Editor)
    $Page.Controls.Add($HelpLabel)
    $CommandEditors.TabPages.Add($Page)
    return $Editor
}

$CollectionEditor = Add-EditorPage -Title 'Collection commands' -Help 'One command per line. Line order is execution order.'
$PagingEditor = Add-EditorPage -Title 'Paging commands' -Help 'Alternatives are tried in order until one succeeds.'
$JuniperTextEditor = Add-EditorPage -Title 'Juniper text commands' -Help 'Used only when Juniper output mode is Text.'
$SpecialEditor = Add-EditorPage -Title 'Special commands' -Help 'Protected key=value entries used by specialized collection routines.'
$EngineEditor = Add-EditorPage -Title 'Detection commands' -Help 'Protected key=value entries used during automatic detection and session setup.'

# Preview tab
$PreviewTab = [Windows.Forms.TabPage]::new('Run Preview')
$Tabs.TabPages.Add($PreviewTab)
$PreviewBox = New-UiTextBox -Multiline -ReadOnly
$PreviewBox.Dock = 'Fill'
$PreviewTab.Controls.Add($PreviewBox)

# Run tab
$RunTab = [Windows.Forms.TabPage]::new('Run')
$Tabs.TabPages.Add($RunTab)

$RunTop = [Windows.Forms.Panel]::new()
$RunTop.Dock = 'Top'
$RunTop.Height = 150
$RunTab.Controls.Add($RunTop)

$SiteScopeLabel = [Windows.Forms.Label]::new()
$SiteScopeLabel.Text = 'Site scope'
$SiteScopeLabel.SetBounds(12, 14, 80, 22)
$RunTop.Controls.Add($SiteScopeLabel)

$SiteSelector = [Windows.Forms.ComboBox]::new()
$SiteSelector.DropDownStyle = 'DropDownList'
$SiteSelector.SetBounds(95, 10, 220, 28)
$RunTop.Controls.Add($SiteSelector)

$MtaRootLabel = [Windows.Forms.Label]::new()
$MtaRootLabel.Text = 'MTAutoDraw folder'
$MtaRootLabel.SetBounds(335, 14, 125, 22)
$RunTop.Controls.Add($MtaRootLabel)

$MtaRootPath = [Windows.Forms.TextBox]::new()
$MtaRootPath.Text = [string]$script:Config.settings.mtautoDrawRoot
$MtaRootPath.SetBounds(465, 10, 585, 27)
$MtaRootPath.Anchor = 'Top,Left,Right'
$RunTop.Controls.Add($MtaRootPath)

$BrowseMtaButton = New-UiButton -Text 'Browse...' -Width 95
$BrowseMtaButton.SetBounds(1060, 8, 95, 30)
$BrowseMtaButton.Anchor = 'Top,Right'
$RunTop.Controls.Add($BrowseMtaButton)

$OutputLabel = [Windows.Forms.Label]::new()
$OutputLabel.Text = 'Output base folder'
$OutputLabel.SetBounds(12, 54, 120, 22)
$RunTop.Controls.Add($OutputLabel)

$OutputPath = [Windows.Forms.TextBox]::new()
$OutputPath.Text = [string]$script:Config.settings.outputBase
$OutputPath.SetBounds(135, 50, 915, 27)
$OutputPath.Anchor = 'Top,Left,Right'
$RunTop.Controls.Add($OutputPath)

$BrowseOutputButton = New-UiButton -Text 'Browse...' -Width 95
$BrowseOutputButton.SetBounds(1060, 48, 95, 30)
$BrowseOutputButton.Anchor = 'Top,Right'
$RunTop.Controls.Add($BrowseOutputButton)

$PreflightButton = New-UiButton -Text '1. Safe Preflight' -Width 145
$PreflightButton.SetBounds(12, 98, 145, 34)
$RunTop.Controls.Add($PreflightButton)

$StartButton = New-UiButton -Text '2. Run Full Audit' -Width 155
$StartButton.SetBounds(170, 98, 155, 34)
$RunTop.Controls.Add($StartButton)

$DiagramButton = New-UiButton -Text '3. Generate Site Diagram' -Width 190
$DiagramButton.SetBounds(338, 98, 190, 34)
$DiagramButton.Enabled = $false
$RunTop.Controls.Add($DiagramButton)

$CancelButton = New-UiButton -Text 'Cancel' -Width 100
$CancelButton.SetBounds(540, 98, 100, 34)
$CancelButton.Enabled = $false
$RunTop.Controls.Add($CancelButton)

$RunBottom = [Windows.Forms.Panel]::new()
$RunBottom.Dock = 'Bottom'
$RunBottom.Height = 64
$RunTab.Controls.Add($RunBottom)

$ProgressLabel = [Windows.Forms.Label]::new()
$ProgressLabel.Text = 'Ready'
$ProgressLabel.SetBounds(12, 8, 700, 20)
$RunBottom.Controls.Add($ProgressLabel)

$ProgressBar = [Windows.Forms.ProgressBar]::new()
$ProgressBar.SetBounds(12, 31, 1080, 22)
$ProgressBar.Anchor = 'Left,Right,Top'
$RunBottom.Controls.Add($ProgressBar)

$StatusGrid = [Windows.Forms.DataGridView]::new()
$StatusGrid.Dock = 'Fill'
$StatusGrid.AllowUserToAddRows = $false
$StatusGrid.AllowUserToDeleteRows = $false
$StatusGrid.ReadOnly = $true
$StatusGrid.RowHeadersVisible = $false
$StatusGrid.AutoGenerateColumns = $false
$StatusGrid.SelectionMode = 'FullRowSelect'
Add-GridTextColumn -Grid $StatusGrid -Name 'Site' -Header 'Site' -Width 135 -ReadOnly
Add-GridTextColumn -Grid $StatusGrid -Name 'Target' -Header 'Device' -Width 175 -ReadOnly
Add-GridTextColumn -Grid $StatusGrid -Name 'Type' -Header 'Detected type' -Width 160 -ReadOnly
Add-GridTextColumn -Grid $StatusGrid -Name 'Status' -Header 'Status' -Width 180 -ReadOnly
Add-GridTextColumn -Grid $StatusGrid -Name 'Command' -Header 'Current command / detail' -Width 400 -Fill -ReadOnly
$RunTab.Controls.Add($StatusGrid)
$StatusGrid.BringToFront()

# Logs tab
$LogsTab = [Windows.Forms.TabPage]::new('Logs')
$Tabs.TabPages.Add($LogsTab)
$LogBox = New-UiTextBox -Multiline -ReadOnly
$LogBox.Dock = 'Fill'
$LogsTab.Controls.Add($LogBox)

function Update-CredentialChoices {
    $Previous = [string]$DefaultCredential.SelectedItem
    $DefaultCredential.Items.Clear()
    foreach ($Name in @($script:Credentials.Keys | Sort-Object)) {
        $null = $DefaultCredential.Items.Add($Name)
    }
    if ($Previous -and $DefaultCredential.Items.Contains($Previous)) {
        $DefaultCredential.SelectedItem = $Previous
    } elseif ($DefaultCredential.Items.Count -gt 0) {
        $DefaultCredential.SelectedIndex = 0
    }
}

function Show-CredentialManager {
    $Dialog = [Windows.Forms.Form]::new()
    $Dialog.Text = 'Password Sets (kept in memory only)'
    $Dialog.StartPosition = 'CenterParent'
    $Dialog.FormBorderStyle = 'FixedDialog'
    $Dialog.MaximizeBox = $false
    $Dialog.MinimizeBox = $false
    $Dialog.ClientSize = [Drawing.Size]::new(610, 330)

    $List = [Windows.Forms.ListBox]::new()
    $List.SetBounds(12, 12, 210, 265)
    $Dialog.Controls.Add($List)

    $Fields = @{}
    $Labels = @('Password set name', 'Username', 'Login password', 'Enable password (optional)')
    $Keys = @('Name', 'Username', 'Password', 'Enable')
    for ($i = 0; $i -lt $Labels.Count; $i++) {
        $Label = [Windows.Forms.Label]::new()
        $Label.Text = $Labels[$i]
        $Label.SetBounds(245, 16 + ($i * 60), 300, 20)
        $Dialog.Controls.Add($Label)
        $Field = [Windows.Forms.TextBox]::new()
        $Field.SetBounds(245, 37 + ($i * 60), 340, 26)
        if ($Keys[$i] -in @('Password', 'Enable')) { $Field.UseSystemPasswordChar = $true }
        $Dialog.Controls.Add($Field)
        $Fields[$Keys[$i]] = $Field
    }

    $Save = New-UiButton -Text 'Add / replace' -Width 120
    $Save.SetBounds(245, 275, 120, 32)
    $Dialog.Controls.Add($Save)
    $Remove = New-UiButton -Text 'Remove' -Width 90
    $Remove.SetBounds(375, 275, 90, 32)
    $Dialog.Controls.Add($Remove)
    $Close = New-UiButton -Text 'Close' -Width 90
    $Close.SetBounds(495, 275, 90, 32)
    $Dialog.Controls.Add($Close)

    $RefreshList = {
        $List.Items.Clear()
        foreach ($Name in @($script:Credentials.Keys | Sort-Object)) { $null = $List.Items.Add($Name) }
    }
    & $RefreshList

    $List.Add_SelectedIndexChanged({
        if ($List.SelectedItem) {
            $Name = [string]$List.SelectedItem
            $Fields.Name.Text = $Name
            $Fields.Username.Text = $script:Credentials[$Name].Credential.UserName
            $Fields.Password.Clear()
            $Fields.Enable.Clear()
        }
    })

    $Save.Add_Click({
        $Name = $Fields.Name.Text.Trim()
        $Username = $Fields.Username.Text.Trim()
        if (-not $Name -or -not $Username -or -not $Fields.Password.Text) {
            [Windows.Forms.MessageBox]::Show('Password set name, username, and login password are required.', 'Password Sets') | Out-Null
            return
        }
        $SecurePassword = ConvertTo-SecureString $Fields.Password.Text -AsPlainText -Force
        $EnableSecure = if ($Fields.Enable.Text) {
            ConvertTo-SecureString $Fields.Enable.Text -AsPlainText -Force
        } else { $null }
        $script:Credentials[$Name] = @{
            Credential = [pscredential]::new($Username, $SecurePassword)
            EnablePassword = $EnableSecure
        }
        $script:PreflightSignature = ''
        $script:PreflightResults = @{}
        $Fields.Password.Clear()
        $Fields.Enable.Clear()
        & $RefreshList
        $List.SelectedItem = $Name
    })

    $Remove.Add_Click({
        if ($List.SelectedItem) {
            $script:Credentials.Remove([string]$List.SelectedItem)
            $script:PreflightSignature = ''
            $script:PreflightResults = @{}
            & $RefreshList
            $Fields.Name.Clear(); $Fields.Username.Clear(); $Fields.Password.Clear(); $Fields.Enable.Clear()
        }
    })
    $Close.Add_Click({ $Dialog.Close() })
    $Dialog.Add_FormClosed({ Update-CredentialChoices })
    $Dialog.ShowDialog($Form) | Out-Null
}

function Load-DevicesIntoGrid {
    $DeviceGrid.Rows.Clear()
    foreach ($Device in @($script:Config.devices)) {
        $Index = $DeviceGrid.Rows.Add()
        $Row = $DeviceGrid.Rows[$Index]
        $Row.Cells['Enabled'].Value = [bool]$Device.enabled
        $Row.Cells['Target'].Value = [string]$Device.target
        $Row.Cells['Site'].Value = [string]$Device.site
        $Row.Cells['Credential'].Value = [string]$Device.credential
        $Row.Cells['Type'].Value = [string]$Device.type
    }
    if ($null -ne $SiteSelector) { Update-SiteSelector }
}

function Sync-DevicesFromGrid {
    $null = $DeviceGrid.EndEdit()
    $Devices = [Collections.Generic.List[hashtable]]::new()
    foreach ($Row in $DeviceGrid.Rows) {
        if ($Row.IsNewRow) { continue }
        $Target = ([string]$Row.Cells['Target'].Value).Trim()
        if (-not $Target) { continue }
        $Devices.Add(@{
            enabled = if ($null -eq $Row.Cells['Enabled'].Value) { $true } else { [bool]$Row.Cells['Enabled'].Value }
            target = $Target
            site = if ([string]$Row.Cells['Site'].Value) { ([string]$Row.Cells['Site'].Value).Trim() } else { 'Unassigned' }
            credential = ([string]$Row.Cells['Credential'].Value).Trim()
            type = if ([string]$Row.Cells['Type'].Value) { ([string]$Row.Cells['Type'].Value).Trim() } else { 'Auto' }
        })
    }
    $script:Config.devices = @($Devices)
}

function Update-SiteSelector {
    $Previous = if ($SiteSelector.SelectedItem) { [string]$SiteSelector.SelectedItem } else { $script:SiteScope }
    $SiteSelector.Items.Clear()
    $null = $SiteSelector.Items.Add('All Sites')
    foreach ($Site in @(Get-SiteNames -Devices $script:Config.devices)) {
        $null = $SiteSelector.Items.Add($Site)
    }
    if ($Previous -and $SiteSelector.Items.Contains($Previous)) {
        $SiteSelector.SelectedItem = $Previous
    } else {
        $SiteSelector.SelectedItem = 'All Sites'
    }
    $script:SiteScope = [string]$SiteSelector.SelectedItem
}

function Convert-DictionaryToEditorText {
    param([hashtable]$Dictionary)
    return (($Dictionary.Keys | Sort-Object | ForEach-Object { "$_=$($Dictionary[$_])" }) -join "`r`n")
}

function Convert-EditorTextToDictionary {
    param([string]$Text, [string[]]$RequiredKeys)
    $Result = @{}
    foreach ($Line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($Line)) { continue }
        $Parts = $Line -split '=', 2
        if ($Parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($Parts[0]) -or [string]::IsNullOrWhiteSpace($Parts[1])) {
            throw "Invalid key=value line: $Line"
        }
        $Key = $Parts[0].Trim()
        if ($Result.Contains($Key)) { throw "Duplicate key: $Key" }
        $Result[$Key] = $Parts[1].Trim()
    }
    $Missing = @($RequiredKeys | Where-Object { -not $Result.Contains($_) })
    $Extra = @($Result.Keys | Where-Object { $_ -notin $RequiredKeys })
    if ($Missing.Count -gt 0 -or $Extra.Count -gt 0) {
        throw "Keys are protected. Missing: $($Missing -join ', '); unexpected: $($Extra -join ', ')."
    }
    return $Result
}

function Load-ProfileEditor {
    param([string]$Name)
    if (-not $Name) { return }
    $Profile = $script:Config.profiles[$Name]
    $script:LoadedProfileName = $Name
    $CollectionEditor.Lines = [string[]]@($Profile.commands)
    $PagingEditor.Lines = [string[]]@($Profile.paging)
    $JuniperTextEditor.Lines = if ($Name -in @('Juniper', 'JuniperSRX')) { [string[]]@($Profile.textCommands) } else { @() }
    $JuniperTextEditor.ReadOnly = ($Name -notin @('Juniper', 'JuniperSRX'))
    $SpecialEditor.Text = Convert-DictionaryToEditorText -Dictionary $Profile.specialCommands
    $EngineEditor.Text = Convert-DictionaryToEditorText -Dictionary $script:Config.engineCommands
    $PlatformLabel = @(
        @([string]$Profile['vendor'], [string]$Profile['platform']) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $ProfileMetadata.Text = "Enable: $($Profile.enable)    Special handler: $($Profile.special)"
    if ($PlatformLabel.Count -gt 0) {
        $ProfileMetadata.Text += "    Platform: $($PlatformLabel -join ' / ')"
    }
}

function Apply-ProfileEditor {
    if (-not $script:LoadedProfileName) { return }
    $Profile = $script:Config.profiles[$script:LoadedProfileName]
    $Profile.commands = [string[]]@(Get-UniqueLines -Text $CollectionEditor.Text)
    $Profile.paging = [string[]]@(Get-UniqueLines -Text $PagingEditor.Text)
    if ($script:LoadedProfileName -in @('Juniper', 'JuniperSRX')) {
        $Profile.textCommands = [string[]]@(Get-UniqueLines -Text $JuniperTextEditor.Text)
    }
    $Profile.specialCommands = Convert-EditorTextToDictionary -Text $SpecialEditor.Text `
        -RequiredKeys ([string[]]@($Profile.specialCommands.Keys))
    $script:Config.engineCommands = Convert-EditorTextToDictionary -Text $EngineEditor.Text `
        -RequiredKeys ([string[]]@($script:Config.engineCommands.Keys))
}

function Update-RunPreview {
    Sync-DevicesFromGrid
    $Builder = [Text.StringBuilder]::new()
    $null = $Builder.AppendLine("Site scope: $($script:SiteScope)")
    $null = $Builder.AppendLine()
    foreach ($Device in @(Get-ScopedDevices -Devices $script:Config.devices -SiteScope $script:SiteScope)) {
        $null = $Builder.AppendLine(('=' * 76))
        $null = $Builder.AppendLine("$($Device.target)  |  Site: $($Device.site)  |  Credential: $($Device.credential)")
        $EffectiveType = [string]$Device.type
        if ($EffectiveType -eq 'Auto' -and $script:ResolvedTypes.ContainsKey([string]$Device.target)) {
            $EffectiveType = [string]$script:ResolvedTypes[[string]$Device.target]
            $null = $Builder.AppendLine("Requested type: Auto  |  Resolved type: $EffectiveType")
        }
        if ($EffectiveType -eq 'Auto') {
            $null = $Builder.AppendLine('Type: Auto - the final profile is conditional on detection.')
            $null = $Builder.AppendLine('Detection/session commands that may be used:')
            foreach ($Pair in $script:Config.engineCommands.GetEnumerator() | Sort-Object Key) {
                $null = $Builder.AppendLine("  [$($Pair.Key)] $($Pair.Value)")
            }
            $null = $Builder.AppendLine('After detection, the matching profile commands shown in the Commands tab will run.')
        } else {
            $Profile = $script:Config.profiles[$EffectiveType]
            $null = $Builder.AppendLine("Type: $EffectiveType")
            if ($EffectiveType -in @('Juniper', 'JuniperSRX')) {
                $null = $Builder.AppendLine("  [session, if shell] $($script:Config.engineCommands.juniperEnterCli)")
            } elseif ($EffectiveType -eq 'CheckPoint') {
                $null = $Builder.AppendLine("  [session, if Expert shell] $($script:Config.engineCommands.checkPointEnterClish)")
            } elseif ($EffectiveType -eq 'CiscoLegacy') {
                $null = $Builder.AppendLine('  [session, if legacy menu] first menu login -> Ctrl+Z -> lcli -> second login')
            } elseif ($EffectiveType -eq 'SophosFirewall') {
                $null = $Builder.AppendLine('  [session] SSH admin menu -> option 4 Device Console')
            }
            foreach ($LoginNote in @($Profile['loginNotes'])) {
                if (-not [string]::IsNullOrWhiteSpace([string]$LoginNote)) {
                    $null = $Builder.AppendLine("  [login note] $LoginNote")
                }
            }
            if ([bool]$Profile.enable) { $null = $Builder.AppendLine("  [enable] $($script:Config.engineCommands.enable)") }
            foreach ($Command in @($Profile.paging)) { $null = $Builder.AppendLine("  [paging] $Command") }
            $Commands = if ($EffectiveType -in @('Juniper', 'JuniperSRX') -and $script:Config.settings.juniperOutputMode -eq 'Text') {
                @($Profile.textCommands)
            } else { @($Profile.commands) }
            foreach ($Command in $Commands) { $null = $Builder.AppendLine("  [collect] $Command") }
            foreach ($Pair in $Profile.specialCommands.GetEnumerator() | Sort-Object Key) {
                $null = $Builder.AppendLine("  [special:$($Pair.Key)] $($Pair.Value)")
            }
        }
        $null = $Builder.AppendLine()
    }
    if ($Builder.Length -eq 0) { $null = $Builder.AppendLine('No enabled devices are currently listed.') }
    $PreviewBox.Text = $Builder.ToString()
}

function Add-UiLog {
    param(
        [string]$Level,
        [string]$Target,
        [string]$Phase,
        [string]$Message,
        [datetime]$Time = [datetime]::Now
    )
    if ($Level -eq 'Debug' -and -not [bool]$script:Config.settings.debugLogging) { return }
    $Line = '{0:yyyy-MM-dd HH:mm:ss.fff} [{1,-7}] [{2}] [{3}] {4}' -f $Time, $Level, $Target, $Phase, $Message
    $LogBox.AppendText($Line + "`r`n")
    if ($script:RunFolder) {
        [IO.File]::AppendAllText((Join-Path $script:RunFolder 'Debug.log'), $Line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    }
}

function Set-EditingEnabled {
    param([bool]$Enabled)
    $DeviceTop.Enabled = $Enabled
    $DeviceGrid.ReadOnly = -not $Enabled
    $DeviceButtons.Enabled = $Enabled
    $CommandsTab.Enabled = $Enabled
    $SiteSelector.Enabled = $Enabled
    $MtaRootPath.ReadOnly = -not $Enabled
    $BrowseMtaButton.Enabled = $Enabled
    $OutputPath.ReadOnly = -not $Enabled
    $BrowseOutputButton.Enabled = $Enabled
    $StartButton.Enabled = $Enabled
    $PreflightButton.Enabled = $Enabled
    $DiagramButton.Enabled = $Enabled -and $script:CompletedAuditSites.Count -gt 0
    $CancelButton.Enabled = -not $Enabled
}

function Save-CurrentConfiguration {
    Apply-ProfileEditor
    Sync-DevicesFromGrid
    $script:Config.settings.outputBase = $OutputPath.Text.Trim()
    $script:Config.settings.mtautoDrawRoot = $MtaRootPath.Text.Trim()
    $Errors = @(Get-ConfigErrors -Config $script:Config)
    if ($Errors.Count -gt 0) { throw ($Errors -join "`r`n") }
    Save-NetworkAuditConfig -Config $script:Config -Path $ConfigPath
}

function Complete-NetworkAuditRun {
    $Timer.Stop()
    try {
        $Requested = @(Get-ScopedDevices -Devices $script:Config.devices -SiteScope $script:SiteScope)
        if ($script:RunMode -eq 'Preflight') {
            @($script:Results) | Select-Object Site, Target, RequestedType, DetectedType, Protocol, PreflightVerdict, `
                @{ Name = 'DetectionCommands'; Expression = {
                    if ($_.PSObject.Properties.Name -contains 'DetectionCommands') { @($_.DetectionCommands) -join '; ' } else { '' }
                } }, `
                @{ Name = 'RejectedDetectionCommands'; Expression = {
                    if ($_.PSObject.Properties.Name -contains 'RejectedDetectionCommands') { @($_.RejectedDetectionCommands) -join '; ' } else { '' }
                } }, Message |
                Export-Csv -LiteralPath (Join-Path $script:RunFolder 'Preflight.csv') -NoTypeInformation -Encoding UTF8

            $PreflightModel = [ordered]@{
                schemaVersion = 1
                runMode = 'Preflight'
                siteScope = $script:SiteScope
                finished = [datetime]::Now.ToString('o')
                offlineIssues = @($script:OfflineIssues)
                results = @($script:Results | ForEach-Object {
                    [ordered]@{
                        site = $_.Site; target = $_.Target; requestedType = $_.RequestedType
                        detectedType = $_.DetectedType; protocol = $_.Protocol
                        verdict = $_.PreflightVerdict; message = $_.Message
                        commandsExecuted = @($_.CommandsExecuted)
                        detectionCommands = if ($_.PSObject.Properties.Name -contains 'DetectionCommands') { @($_.DetectionCommands) } else { @() }
                        rejectedDetectionCommands = if ($_.PSObject.Properties.Name -contains 'RejectedDetectionCommands') { @($_.RejectedDetectionCommands) } else { @() }
                    }
                })
            }
            [IO.File]::WriteAllText(
                (Join-Path $script:RunFolder 'Preflight.json'),
                ($PreflightModel | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $script:PreflightResults = @{}
            foreach ($Result in $script:Results) { $script:PreflightResults[[string]$Result.Target] = $Result }
            $script:PreflightSignature = Get-PreflightSignature -Devices $Requested `
                -Credentials $script:Credentials -SiteScope $script:SiteScope
            Add-UiLog -Level 'Info' -Target '-' -Phase 'Preflight' -Message "Safe preflight finished. Output: $($script:RunFolder)"
        } else {
            @($script:Results) | Select-Object Site, Target, Protocol, Type, Status |
                Export-Csv -LiteralPath (Join-Path $script:RunFolder 'Summary.csv') -NoTypeInformation -Encoding UTF8

            $CurrentSignature = Get-PreflightSignature -Devices $Requested -Credentials $script:Credentials -SiteScope $script:SiteScope
            $PreflightState = if (-not $script:PreflightSignature) { 'Missing' } `
                elseif ($script:PreflightSignature -eq $CurrentSignature) { 'Current' } else { 'Stale' }
            $Manifest = [ordered]@{
                schemaVersion = 1
                runMode = 'FullAudit'
                siteScope = $script:SiteScope
                preflightState = $PreflightState
                preflight = [ordered]@{
                    state = $PreflightState
                    pass = @($script:PreflightResults.Values | Where-Object PreflightVerdict -eq 'Pass').Count
                    warning = @($script:PreflightResults.Values | Where-Object PreflightVerdict -eq 'Warning').Count
                    fail = @($script:PreflightResults.Values | Where-Object PreflightVerdict -eq 'Fail').Count
                    devices = @($script:PreflightResults.Values | ForEach-Object {
                        [ordered]@{ target = $_.Target; verdict = $_.PreflightVerdict; detectedType = $_.DetectedType }
                    })
                }
                finished = [datetime]::Now.ToString('o')
                requestedDevices = @($Requested | ForEach-Object {
                    [ordered]@{ target = $_.target; site = $_.site; credential = $_.credential; requestedType = $_.type }
                })
                results = @($script:Results | ForEach-Object {
                    [ordered]@{
                        site = $_.Site; target = $_.Target; protocol = $_.Protocol
                        resolvedType = $_.Type; status = $_.Status; commandsExecuted = @($_.CommandsExecuted)
                    }
                })
            }
            [IO.File]::WriteAllText(
                (Join-Path $script:RunFolder 'RunManifest.json'),
                ($Manifest | ConvertTo-Json -Depth 20),
                [Text.UTF8Encoding]::new($false)
            )
            $script:LastFullAuditFolder = $script:RunFolder
            $script:LastFullAuditResults = @($script:Results | ForEach-Object { $_ })
            $script:LastFullAuditRequested = @($Requested | ForEach-Object { $_ })
            $script:CompletedAuditSites = @(
                $script:Results | Where-Object Status -eq 'Complete' | ForEach-Object Site |
                    Where-Object { $_ } | Sort-Object -Unique
            )
            Add-UiLog -Level 'Info' -Target '-' -Phase 'Run' -Message "Full audit finished. Output: $($script:RunFolder)"
        }
    }
    catch {
        [Windows.Forms.MessageBox]::Show("Could not finalize run output: $($_.Exception.Message)", 'Network Audit') | Out-Null
    }
    finally {
        if ($script:RunspacePool) {
            $script:RunspacePool.Close()
            $script:RunspacePool.Dispose()
            $script:RunspacePool = $null
        }
        if ($script:Cancellation) {
            $script:Cancellation.Dispose()
            $script:Cancellation = $null
        }
        $script:Running = $false
        Set-EditingEnabled -Enabled $true
        $ProgressBar.Value = 100
        $ProgressLabel.Text = "$($script:RunMode) finished: $($script:Results.Count) device results"
        if ($script:ClosingAfterCancel) {
            $script:ClosingAfterCancel = $false
            $Form.Close()
        }
    }
}

$Timer = [Windows.Forms.Timer]::new()
$Timer.Interval = 150
$Timer.Add_Tick({
    if (-not $script:Running) { return }

    $PreviewChanged = $false
    $Event = $null
    while ($script:EventQueue.TryDequeue([ref]$Event)) {
        Add-UiLog -Level $Event.Level -Target $Event.Target -Phase $Event.Phase -Message $Event.Message -Time $Event.Time
        if ($script:RowMap.ContainsKey([string]$Event.Target)) {
            $Row = $script:RowMap[[string]$Event.Target]
            if ($Event.Type) {
                $Row.Cells['Type'].Value = $Event.Type
                if ($script:Config.profiles.ContainsKey([string]$Event.Type)) {
                    $script:ResolvedTypes[[string]$Event.Target] = [string]$Event.Type
                    $PreviewChanged = $true
                }
            }
            if ($Event.Status) { $Row.Cells['Status'].Value = $Event.Status }
            if ($Event.Command) {
                $Row.Cells['Command'].Value = $Event.Command
            } elseif ($Event.Message) {
                $Row.Cells['Command'].Value = $Event.Message
            }
        }
        if ([bool]$Event.Terminal) {
            $null = $script:TerminalTargets.Add([string]$Event.Target)
        }
    }

    if ($PreviewChanged -and $Tabs.SelectedTab -eq $PreviewTab) { Update-RunPreview }

    foreach ($Job in $script:Jobs) {
        if ($Job.Done -or -not $Job.Handle.IsCompleted) { continue }
        try {
            $Output = @($Job.PowerShell.EndInvoke($Job.Handle))
            $Result = @($Output | Where-Object { $_.PSObject.Properties.Name -contains 'Target' } | Select-Object -Last 1)
            if ($Result.Count -gt 0) {
                $script:Results.Add($Result[0])
            } else {
                throw 'The worker completed without returning a device result.'
            }
        }
        catch {
            $Message = $_.Exception.Message
            Add-UiLog -Level 'Error' -Target $Job.Target -Phase 'Worker' -Message $Message
            $FallbackStatus = if ($script:RunMode -eq 'Preflight') { 'Fail' } else { $Message }
            $script:Results.Add([pscustomobject]@{
                Site = $Job.Site; Target = $Job.Target; Protocol = ''; Type = ''
                Status = $FallbackStatus
                PreflightVerdict = $(if ($script:RunMode -eq 'Preflight') { 'Fail' } else { '' })
                RequestedType = $Job.RequestedType; DetectedType = ''; Message = $Message
                CommandsExecuted = @()
            })
            $null = $script:TerminalTargets.Add([string]$Job.Target)
            if ($script:RowMap.ContainsKey([string]$Job.Target)) {
                $script:RowMap[[string]$Job.Target].Cells['Status'].Value = $(if ($script:RunMode -eq 'Preflight') { 'Fail' } else { 'Failed' })
                $script:RowMap[[string]$Job.Target].Cells['Command'].Value = $Message
            }
        }
        finally {
            $Job.Done = $true
            $Job.PowerShell.Dispose()
        }
    }

    $Total = $script:Jobs.Count
    $Complete = $script:TerminalTargets.Count
    if ($Total -gt 0) {
        $ProgressBar.Value = [Math]::Min(100, [int](100 * $Complete / $Total))
    }
    $ProgressLabel.Text = "$Complete of $Total devices finished"

    if ($Total -gt 0 -and @($script:Jobs | Where-Object { -not $_.Done }).Count -eq 0) {
        # Drain terminal events emitted just before the workers returned on the next UI pass.
        $Event = $null
        while ($script:EventQueue.TryDequeue([ref]$Event)) {
            Add-UiLog -Level $Event.Level -Target $Event.Target -Phase $Event.Phase -Message $Event.Message -Time $Event.Time
            if ($script:RowMap.ContainsKey([string]$Event.Target)) {
                $Row = $script:RowMap[[string]$Event.Target]
                if ($Event.Type) {
                    $Row.Cells['Type'].Value = $Event.Type
                    if ($script:Config.profiles.ContainsKey([string]$Event.Type)) {
                        $script:ResolvedTypes[[string]$Event.Target] = [string]$Event.Type
                    }
                }
                if ($Event.Status) { $Row.Cells['Status'].Value = $Event.Status }
                if ($Event.Message) { $Row.Cells['Command'].Value = $Event.Message }
            }
            if ([bool]$Event.Terminal) { $null = $script:TerminalTargets.Add([string]$Event.Target) }
        }
        Complete-NetworkAuditRun
    }
})

$CredentialButton.Add_Click({ Show-CredentialManager })

$AddPastedButton.Add_Click({
    if (-not $DefaultCredential.SelectedItem) {
        [Windows.Forms.MessageBox]::Show(
            'Enter at least one password set first, then select it beside the Add button.',
            'Network Audit - Password set required', 'OK', 'Information'
        ) | Out-Null
        Show-CredentialManager
        return
    }
    $Existing = @{}
    foreach ($Row in $DeviceGrid.Rows) {
        if (-not $Row.IsNewRow -and $Row.Cells['Target'].Value) {
            $Existing[([string]$Row.Cells['Target'].Value).Trim().ToLowerInvariant()] = $true
        }
    }
    $Added = 0
    foreach ($Line in ($PasteBox.Text -split "`r?`n")) {
        $Target = $Line.Trim()
        if (-not $Target) { continue }
        $Key = $Target.ToLowerInvariant()
        if ($Existing.ContainsKey($Key)) { continue }
        $Index = $DeviceGrid.Rows.Add()
        $Row = $DeviceGrid.Rows[$Index]
        $Row.Cells['Enabled'].Value = $true
        $Row.Cells['Target'].Value = $Target
        $Row.Cells['Site'].Value = if ($DefaultSite.Text.Trim()) { $DefaultSite.Text.Trim() } else { 'Unassigned' }
        $Row.Cells['Credential'].Value = [string]$DefaultCredential.SelectedItem
        $Row.Cells['Type'].Value = if ($DefaultType.SelectedItem) { [string]$DefaultType.SelectedItem } else { 'Auto' }
        $Existing[$Key] = $true
        $Added++
    }
    if ($Added -gt 0) {
        $PasteBox.Clear()
        Sync-DevicesFromGrid
        Update-SiteSelector
    }
})

$RemoveDeviceButton.Add_Click({
    foreach ($Row in @($DeviceGrid.SelectedRows | Sort-Object Index -Descending)) {
        if (-not $Row.IsNewRow) { $DeviceGrid.Rows.Remove($Row) }
    }
    Sync-DevicesFromGrid
    Update-SiteSelector
})

$ClearDeviceButton.Add_Click({
    if ([Windows.Forms.MessageBox]::Show('Clear the entire device list?', 'Network Audit', 'YesNo', 'Question') -eq 'Yes') {
        $DeviceGrid.Rows.Clear()
        Sync-DevicesFromGrid
        Update-SiteSelector
    }
})

$DeviceGrid.Add_CellEndEdit({
    Sync-DevicesFromGrid
    Update-SiteSelector
})

$SaveConfigButton.Add_Click({
    try {
        Save-CurrentConfiguration
        [Windows.Forms.MessageBox]::Show('Configuration saved.', 'Network Audit', 'OK', 'Information') | Out-Null
    }
    catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot save configuration', 'OK', 'Error') | Out-Null
    }
})

$ReloadConfigButton.Add_Click({
    try {
        $script:Config = Read-NetworkAuditConfig -Path $ConfigPath
        Load-DevicesIntoGrid
        $OutputPath.Text = [string]$script:Config.settings.outputBase
        $MtaRootPath.Text = [string]$script:Config.settings.mtautoDrawRoot
        if ($ProfileSelector.SelectedItem) { Load-ProfileEditor -Name ([string]$ProfileSelector.SelectedItem) }
        Update-RunPreview
    }
    catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot reload configuration', 'OK', 'Error') | Out-Null
    }
})

$ProfileSelector.Add_SelectedIndexChanged({
    Load-ProfileEditor -Name ([string]$ProfileSelector.SelectedItem)
})

$ApplyCommandsButton.Add_Click({
    try {
        Apply-ProfileEditor
        $Errors = @(Get-ConfigErrors -Config $script:Config)
        if ($Errors.Count -gt 0) { throw ($Errors -join "`r`n") }
        Update-RunPreview
        [Windows.Forms.MessageBox]::Show('Command edits applied in memory. Use Save configuration to keep them.', 'Network Audit') | Out-Null
    }
    catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Invalid command edits', 'OK', 'Error') | Out-Null
    }
})

$Tabs.Add_SelectedIndexChanged({
    if ($Tabs.SelectedTab -eq $PreviewTab) {
        try { Apply-ProfileEditor; Sync-DevicesFromGrid; Update-SiteSelector; Update-RunPreview } catch { $PreviewBox.Text = "Preview unavailable:`r`n$($_.Exception.Message)" }
    }
})

$SiteSelector.Add_SelectedIndexChanged({
    if ($SiteSelector.SelectedItem) {
        $script:SiteScope = [string]$SiteSelector.SelectedItem
        if ($Tabs.SelectedTab -eq $PreviewTab) { Update-RunPreview }
    }
})

$BrowseOutputButton.Add_Click({
    $Picker = [Windows.Forms.FolderBrowserDialog]::new()
    $Picker.Description = 'Choose the base folder for network audit runs'
    if (Test-Path -LiteralPath $OutputPath.Text -PathType Container) { $Picker.SelectedPath = $OutputPath.Text }
    if ($Picker.ShowDialog($Form) -eq 'OK') { $OutputPath.Text = $Picker.SelectedPath }
    $Picker.Dispose()
})

$BrowseMtaButton.Add_Click({
    $Picker = [Windows.Forms.FolderBrowserDialog]::new()
    $Picker.Description = 'Choose the MTAutoDraw project folder'
    if (Test-Path -LiteralPath $MtaRootPath.Text -PathType Container) { $Picker.SelectedPath = $MtaRootPath.Text }
    if ($Picker.ShowDialog($Form) -eq 'OK') { $MtaRootPath.Text = $Picker.SelectedPath }
    $Picker.Dispose()
})

function Start-ScopedNetworkAuditRun {
    param(
        [ValidateSet('Preflight', 'FullAudit')]
        [string]$Mode
    )

    try {
        Apply-ProfileEditor
        Sync-DevicesFromGrid
        $script:Config.settings.outputBase = $OutputPath.Text.Trim()
        $script:Config.settings.mtautoDrawRoot = $MtaRootPath.Text.Trim()
        $script:SiteScope = if ($SiteSelector.SelectedItem) { [string]$SiteSelector.SelectedItem } else { 'All Sites' }
        $Errors = @(Get-ConfigErrors -Config $script:Config -Credentials $script:Credentials -CheckCredentials)
        if ($Errors.Count -gt 0) { throw ($Errors -join "`r`n") }

        $ScopedDevices = @(Get-ScopedDevices -Devices $script:Config.devices -SiteScope $script:SiteScope)
        if ($ScopedDevices.Count -eq 0) { throw "No enabled devices are assigned to site scope '$($script:SiteScope)'." }

        $script:OfflineIssues = @(Get-OfflinePreflightIssues -Config $script:Config -Devices $ScopedDevices -Credentials $script:Credentials)
        $OfflineFailures = @($script:OfflineIssues | Where-Object Severity -eq 'Fail')
        if ($OfflineFailures.Count -gt 0) {
            $FailureText = ($OfflineFailures | Select-Object -First 20 | ForEach-Object {
                $Prefix = if ($_.Target) { "$($_.Target): " } else { '' }
                "- $Prefix$($_.Message)"
            }) -join "`r`n"
            if ($OfflineFailures.Count -gt 20) { $FailureText += "`r`n- ...and $($OfflineFailures.Count - 20) more" }
            throw "Safe offline checks found problems that must be corrected:`r`n`r`n$FailureText"
        }

        $Warnings = [Collections.Generic.List[string]]::new()
        foreach ($Issue in @($script:OfflineIssues | Where-Object Severity -eq 'Warning')) {
            $Prefix = if ($Issue.Target) { "$($Issue.Target): " } else { '' }
            $Warnings.Add("$Prefix$($Issue.Message)")
        }

        $CurrentSignature = Get-PreflightSignature -Devices $ScopedDevices -Credentials $script:Credentials -SiteScope $script:SiteScope
        if ($Mode -eq 'FullAudit') {
            if (-not $script:PreflightSignature) {
                $Warnings.Insert(0, 'No Safe Preflight has been completed for this site scope and current device/credential details.')
            } elseif ($script:PreflightSignature -ne $CurrentSignature) {
                $Warnings.Insert(0, 'The Safe Preflight is stale because the selected scope, device details, or in-memory credentials changed.')
            } else {
                foreach ($Result in @($script:PreflightResults.Values | Where-Object PreflightVerdict -ne 'Pass')) {
                    $Warnings.Insert(0, "$($Result.Target): preflight $($Result.PreflightVerdict) - $($Result.Message)")
                }
                $MissingPreflight = @($ScopedDevices | Where-Object { -not $script:PreflightResults.ContainsKey([string]$_.target) })
                foreach ($Device in $MissingPreflight) {
                    $Warnings.Insert(0, "$($Device.target): no preflight result is available.")
                }
            }
        }

        if ($Warnings.Count -gt 0) {
            $ShownWarnings = @($Warnings | Select-Object -Unique -First 30)
            $WarningText = ($ShownWarnings | ForEach-Object { "- $_" }) -join "`r`n"
            if (@($Warnings | Select-Object -Unique).Count -gt 30) { $WarningText += "`r`n- ...additional warnings are available in the run log." }
            $Prompt = if ($Mode -eq 'Preflight') {
                "Safe offline checks produced warnings. Continue with the online read-only preflight?"
            } else {
                "The full audit can continue, but the following risks were found. Continue?"
            }
            $Choice = [Windows.Forms.MessageBox]::Show(
                "$Prompt`r`n`r`n$WarningText",
                'Network Audit - Review warnings', 'YesNo', 'Warning'
            )
            if ($Choice -ne 'Yes') { return }
        }

        $PoshSsh = Get-Module -ListAvailable -Name Posh-SSH |
            Where-Object Version -GE ([version]'3.2.7') | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $PoshSsh) {
            [Windows.Forms.MessageBox]::Show(
                "Posh-SSH 3.2.7 or newer is required for SSH collection.`r`n`r`nInstall it for the current user with:`r`nInstall-Module Posh-SSH -Scope CurrentUser",
                'Network Audit - Posh-SSH required', 'OK', 'Warning'
            ) | Out-Null
            return
        }

        $BaseFolder = $OutputPath.Text.Trim()
        if (-not $BaseFolder) { throw 'Choose an output base folder.' }
        [IO.Directory]::CreateDirectory($BaseFolder) | Out-Null
        $RunName = if ($Mode -eq 'Preflight') {
            'NetworkAudit_Preflight_{0}' -f (Get-Date -Format 'yyyyMMdd_HHmmss')
        } else {
            'NetworkAudit_{0}' -f (Get-Date -Format 'yyyyMMdd_HHmmss')
        }
        $script:RunFolder = Join-Path $BaseFolder $RunName
        $Suffix = 2
        while (Test-Path -LiteralPath $script:RunFolder) {
            $script:RunFolder = Join-Path $BaseFolder ("${RunName}_$Suffix")
            $Suffix++
        }
        [IO.Directory]::CreateDirectory($script:RunFolder) | Out-Null

        if ($Mode -eq 'FullAudit') {
            $InitialManifest = [ordered]@{
                schemaVersion = 1
                runMode = 'FullAudit'
                siteScope = $script:SiteScope
                started = [datetime]::Now.ToString('o')
                preflightState = if (-not $script:PreflightSignature) { 'Missing' } elseif ($script:PreflightSignature -eq $CurrentSignature) { 'Current' } else { 'Stale' }
                requestedDevices = @($ScopedDevices | ForEach-Object {
                    [ordered]@{ target = $_.target; site = $_.site; credential = $_.credential; requestedType = $_.type }
                })
            }
            [IO.File]::WriteAllText(
                (Join-Path $script:RunFolder 'RunManifest.json'),
                ($InitialManifest | ConvertTo-Json -Depth 10),
                [Text.UTF8Encoding]::new($false)
            )
            $script:CompletedAuditSites = @()
            $script:LastFullAuditFolder = ''
            $script:LastFullAuditResults = @()
            $script:LastFullAuditRequested = @()
        }

        $StatusGrid.Rows.Clear()
        $script:RowMap = @{}
        foreach ($Device in $ScopedDevices) {
            $Index = $StatusGrid.Rows.Add([string]$Device.site, [string]$Device.target, '', 'Queued', '')
            $script:RowMap[[string]$Device.target] = $StatusGrid.Rows[$Index]
        }

        $script:Jobs.Clear()
        $script:Results.Clear()
        $script:TerminalTargets.Clear()
        $script:ResolvedTypes = @{}
        $script:EventQueue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
        $script:Cancellation = [Threading.CancellationTokenSource]::new()
        $script:RunspacePool = [runspacefactory]::CreateRunspacePool(1, [int]$script:Config.settings.throttleLimit)
        $script:RunspacePool.Open()
        $WorkerText = $script:DeviceWorker.ToString()
        $script:RunMode = $Mode

        foreach ($Device in $ScopedDevices) {
            $PowerShell = [powershell]::Create()
            $PowerShell.RunspacePool = $script:RunspacePool
            $Bundle = $script:Credentials[[string]$Device.credential]
            $null = $PowerShell.AddScript($WorkerText).
                AddArgument($Device).
                AddArgument($script:Config).
                AddArgument($Bundle).
                AddArgument($script:RunFolder).
                AddArgument($script:EventQueue).
                AddArgument($script:Cancellation.Token).
                AddArgument($Mode)
            $Handle = $PowerShell.BeginInvoke()
            $script:Jobs.Add([pscustomobject]@{
                Target = [string]$Device.target
                Site = [string]$Device.site
                RequestedType = [string]$Device.type
                PowerShell = $PowerShell
                Handle = $Handle
                Done = $false
            })
        }

        $script:Running = $true
        $ProgressBar.Value = 0
        $ProgressLabel.Text = "0 of $($script:Jobs.Count) devices finished"
        $LogBox.Clear()
        $Phase = if ($Mode -eq 'Preflight') { 'Preflight' } else { 'Run' }
        Add-UiLog -Level 'Info' -Target '-' -Phase $Phase -Message "Started $Mode for $($script:Jobs.Count) devices in '$($script:SiteScope)'. Output: $($script:RunFolder)"
        foreach ($Issue in $script:OfflineIssues) {
            Add-UiLog -Level $Issue.Severity -Target $(if ($Issue.Target) { $Issue.Target } else { '-' }) -Phase 'Offline check' -Message $Issue.Message
        }
        Set-EditingEnabled -Enabled $false
        $Timer.Start()
        $Tabs.SelectedTab = $RunTab
    }
    catch {
        if ($script:Cancellation) {
            try { $script:Cancellation.Cancel() } catch {}
        }
        foreach ($Job in @($script:Jobs)) {
            try { $Job.PowerShell.Stop() } catch {}
            try { $Job.PowerShell.Dispose() } catch {}
        }
        if ($script:RunspacePool) {
            try { $script:RunspacePool.Close() } catch {}
            try { $script:RunspacePool.Dispose() } catch {}
            $script:RunspacePool = $null
        }
        if ($script:Cancellation) {
            $script:Cancellation.Dispose()
            $script:Cancellation = $null
        }
        $script:Jobs.Clear()
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Cannot start $Mode", 'OK', 'Error') | Out-Null
    }
}

$PreflightButton.Add_Click({ Start-ScopedNetworkAuditRun -Mode Preflight })
$StartButton.Add_Click({ Start-ScopedNetworkAuditRun -Mode FullAudit })

function Select-CompletedDiagramSite {
    $Sites = @($script:CompletedAuditSites | Sort-Object)
    if ($Sites.Count -eq 0) { return $null }
    if ($Sites.Count -eq 1) { return [string]$Sites[0] }

    $Dialog = [Windows.Forms.Form]::new()
    $Dialog.Text = 'Choose completed site'
    $Dialog.StartPosition = 'CenterParent'
    $Dialog.FormBorderStyle = 'FixedDialog'
    $Dialog.MaximizeBox = $false
    $Dialog.MinimizeBox = $false
    $Dialog.ClientSize = [Drawing.Size]::new(430, 130)

    $Label = [Windows.Forms.Label]::new()
    $Label.Text = 'Generate a diagram for:'
    $Label.SetBounds(14, 16, 390, 22)
    $Dialog.Controls.Add($Label)

    $Choice = [Windows.Forms.ComboBox]::new()
    $Choice.DropDownStyle = 'DropDownList'
    $Choice.SetBounds(14, 42, 400, 28)
    foreach ($Site in $Sites) { $null = $Choice.Items.Add($Site) }
    $Choice.SelectedIndex = 0
    $Dialog.Controls.Add($Choice)

    $Ok = New-UiButton -Text 'Continue' -Width 100
    $Ok.SetBounds(204, 84, 100, 30)
    $Ok.DialogResult = 'OK'
    $Dialog.Controls.Add($Ok)
    $Cancel = New-UiButton -Text 'Cancel' -Width 100
    $Cancel.SetBounds(314, 84, 100, 30)
    $Cancel.DialogResult = 'Cancel'
    $Dialog.Controls.Add($Cancel)
    $Dialog.AcceptButton = $Ok
    $Dialog.CancelButton = $Cancel

    $Result = if ($Dialog.ShowDialog($Form) -eq 'OK') { [string]$Choice.SelectedItem } else { $null }
    $Dialog.Dispose()
    return $Result
}

function Start-SiteDiagram {
    try {
        if (-not $script:LastFullAuditFolder -or -not (Test-Path -LiteralPath $script:LastFullAuditFolder -PathType Container)) {
            throw 'Complete a full audit before generating a site diagram.'
        }
        $Site = Select-CompletedDiagramSite
        if (-not $Site) { return }

        $Root = $MtaRootPath.Text.Trim()
        $PrerequisiteErrors = @(Get-MtautoDrawPrerequisiteErrors -Root $Root)
        if ($PrerequisiteErrors.Count -gt 0) { throw ($PrerequisiteErrors -join "`r`n") }

        $Expected = @($script:LastFullAuditRequested | Where-Object {
            ([string]$_.site).Trim().Equals($Site.Trim(), [StringComparison]::OrdinalIgnoreCase)
        })
        $SuccessfulTargets = @($script:LastFullAuditResults | Where-Object {
            $_.Status -eq 'Complete' -and ([string]$_.Site).Trim().Equals($Site.Trim(), [StringComparison]::OrdinalIgnoreCase)
        } | ForEach-Object Target)
        $Missing = @($Expected | Where-Object { [string]$_.target -notin $SuccessfulTargets } | ForEach-Object target)
        $SupportedMtaTypes = @('CiscoIOS','CiscoNXOS','CiscoASA','CiscoSMBOld','CiscoSMBNew','CiscoLegacy','Juniper','AristaEOS','ArubaCX','PaloAlto','CheckPoint')
        $Unsupported = @($script:LastFullAuditResults | Where-Object {
            $_.Status -eq 'Complete' -and
            ([string]$_.Site).Trim().Equals($Site.Trim(), [StringComparison]::OrdinalIgnoreCase) -and
            [string]$_.Type -notin $SupportedMtaTypes
        } | ForEach-Object { "$($_.Target) ($($_.Type))" })
        if ($Missing.Count -gt 0 -or $Unsupported.Count -gt 0) {
            $RiskLines = [Collections.Generic.List[string]]::new()
            foreach ($Target in $Missing) { $RiskLines.Add("Missing capture: $Target") }
            foreach ($DeviceDetail in $Unsupported) { $RiskLines.Add("No declared MTAutoDraw parser: $DeviceDetail") }
            $RiskText = ($RiskLines | ForEach-Object { "- $_" }) -join "`r`n"
            $Choice = [Windows.Forms.MessageBox]::Show(
                "The site diagram may be incomplete for '$Site'.`r`n`r`n$RiskText`r`n`r`nGenerate a partial diagram?",
                'Network Audit - Partial site diagram', 'YesNo', 'Warning'
            )
            if ($Choice -ne 'Yes') { return }
        }

        $SafeSite = Get-PathSafeName -Name $Site
        $InputFolder = Join-Path $script:LastFullAuditFolder $SafeSite
        if (-not (Test-Path -LiteralPath $InputFolder -PathType Container)) {
            throw "The completed site capture folder was not found: $InputFolder"
        }
        $CaptureFiles = @(Get-ChildItem -LiteralPath $InputFolder -Recurse -File -Filter '*.txt')
        if ($CaptureFiles.Count -eq 0) { throw "No command capture files were found for site '$Site'." }

        $MtaParent = Join-Path $script:LastFullAuditFolder 'MTAutoDraw'
        $OutputFolder = Join-Path $MtaParent $SafeSite
        [IO.Directory]::CreateDirectory($OutputFolder) | Out-Null

        $PowerShellPath = (Get-Process -Id $PID).Path
        if (-not $PowerShellPath) { $PowerShellPath = 'pwsh.exe' }
        $StartInfo = [Diagnostics.ProcessStartInfo]::new()
        $StartInfo.FileName = $PowerShellPath
        $StartInfo.UseShellExecute = $false
        $StartInfo.CreateNoWindow = $true
        $StartInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $StartInfo.RedirectStandardOutput = $true
        $StartInfo.RedirectStandardError = $true
        foreach ($Argument in @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $Root 'AutoDraw.ps1'),
            '-GDirectory', ([IO.Path]::GetFullPath($InputFolder) + [IO.Path]::DirectorySeparatorChar),
            '-GOutPutDirectory', ([IO.Path]::GetFullPath($OutputFolder) + [IO.Path]::DirectorySeparatorChar),
            '-GPathToScript', ([IO.Path]::GetFullPath($Root) + [IO.Path]::DirectorySeparatorChar),
            '-LogLevel', 'Info'
        )) { $null = $StartInfo.ArgumentList.Add([string]$Argument) }

        $Process = [Diagnostics.Process]::new()
        $Process.StartInfo = $StartInfo
        $LaunchStartedUtc = [datetime]::UtcNow
        if (-not $Process.Start()) { throw 'Windows could not start MTAutoDraw.' }

        $script:DiagramStartedUtc = $LaunchStartedUtc
        $RunningModel = [ordered]@{
            status = 'Running'; site = $Site; started = $script:DiagramStartedUtc.ToString('o')
        }
        [IO.File]::WriteAllText(
            (Join-Path $OutputFolder 'DiagramStatus.json'),
            ($RunningModel | ConvertTo-Json), [Text.UTF8Encoding]::new($false)
        )

        $script:DiagramProcess = $Process
        $script:DiagramStdoutTask = $Process.StandardOutput.ReadToEndAsync()
        $script:DiagramStderrTask = $Process.StandardError.ReadToEndAsync()
        $script:DiagramRunning = $true
        $script:DiagramCancelled = $false
        $script:DiagramOutputFolder = $OutputFolder
        $script:DiagramSite = $Site
        $ProgressBar.Style = 'Marquee'
        $ProgressBar.MarqueeAnimationSpeed = 25
        $ProgressLabel.Text = "MTAutoDraw is generating '$Site'..."
        Set-EditingEnabled -Enabled $false
        $CancelButton.Enabled = $true
        Add-UiLog -Level 'Info' -Target '-' -Phase 'Diagram' -Message "Started MTAutoDraw for '$Site'. Input: $InputFolder; output: $OutputFolder"
        $Tabs.SelectedTab = $RunTab
        $DiagramTimer.Start()
    }
    catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot generate site diagram', 'OK', 'Error') | Out-Null
    }
}

$DiagramTimer = [Windows.Forms.Timer]::new()
$DiagramTimer.Interval = 250
$DiagramTimer.Add_Tick({
    if (-not $script:DiagramRunning -or -not $script:DiagramProcess.HasExited) { return }
    $DiagramTimer.Stop()
    try {
        $script:DiagramProcess.WaitForExit()
        $ExitCode = $script:DiagramProcess.ExitCode
        $StandardOutput = [string]$script:DiagramStdoutTask.Result
        $StandardError = [string]$script:DiagramStderrTask.Result
        foreach ($Line in @($StandardOutput -split "`r?`n" | Where-Object { $_ })) {
            Add-UiLog -Level 'Info' -Target '-' -Phase 'MTAutoDraw' -Message $Line
        }
        foreach ($Line in @($StandardError -split "`r?`n" | Where-Object { $_ })) {
            Add-UiLog -Level 'Error' -Target '-' -Phase 'MTAutoDraw' -Message $Line
        }

        if ($script:DiagramCancelled) {
            $CancelledModel = [ordered]@{
                status = 'Incomplete'; reason = 'Cancelled'; site = $script:DiagramSite
                finished = [datetime]::Now.ToString('o')
            }
            [IO.File]::WriteAllText(
                (Join-Path $script:DiagramOutputFolder 'DiagramStatus.json'),
                ($CancelledModel | ConvertTo-Json), [Text.UTF8Encoding]::new($false)
            )
            Add-UiLog -Level 'Warning' -Target '-' -Phase 'Diagram' -Message "Diagram generation for '$($script:DiagramSite)' was cancelled; output is marked incomplete."
            $ProgressLabel.Text = "Diagram cancelled: $($script:DiagramSite)"
        } else {
            $SummaryPath = Join-Path $script:DiagramOutputFolder 'RunSummary.json'
            $FreshSummary = (Test-Path -LiteralPath $SummaryPath -PathType Leaf) -and
                (Get-Item -LiteralPath $SummaryPath).LastWriteTimeUtc -ge $script:DiagramStartedUtc.AddSeconds(-1)
            $Summary = if ($FreshSummary) {
                Get-Content -LiteralPath $SummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            } else { $null }
            $Verdict = if ($Summary -and $Summary.Verdict) { [string]$Summary.Verdict } elseif ($ExitCode -eq 0) { 'Pass' } else { 'Fail' }
            $Processed = if ($Summary -and $Summary.Counts) { [int]$Summary.Counts.ProcessedDevices } else { 0 }
            $ParserErrors = if ($Summary -and $Summary.Counts) { [int]$Summary.Counts.ParserErrors } else { 0 }
            $Detail = "$Verdict (exit $ExitCode); processed devices: $Processed; parser errors: $ParserErrors"
            $Level = if ($Verdict -eq 'Pass') { 'Info' } elseif ($Verdict -eq 'Warn') { 'Warning' } else { 'Error' }
            Add-UiLog -Level $Level -Target '-' -Phase 'Diagram' -Message $Detail
            $ProgressLabel.Text = "Diagram $Detail"
            $FinalDiagramModel = [ordered]@{
                status = if ($Verdict -eq 'Fail') { 'Incomplete' } else { 'Complete' }
                verdict = $Verdict; exitCode = $ExitCode; site = $script:DiagramSite
                processedDevices = $Processed; parserErrors = $ParserErrors
                finished = [datetime]::Now.ToString('o')
            }
            [IO.File]::WriteAllText(
                (Join-Path $script:DiagramOutputFolder 'DiagramStatus.json'),
                ($FinalDiagramModel | ConvertTo-Json), [Text.UTF8Encoding]::new($false)
            )
            [Windows.Forms.MessageBox]::Show(
                "MTAutoDraw result for '$($script:DiagramSite)':`r`n`r`n$Detail`r`n`r`nOutput: $($script:DiagramOutputFolder)",
                'Network Audit - Site diagram', 'OK', $(if ($Verdict -eq 'Fail') { 'Error' } elseif ($Verdict -eq 'Warn') { 'Warning' } else { 'Information' })
            ) | Out-Null
        }
    }
    catch {
        Add-UiLog -Level 'Error' -Target '-' -Phase 'Diagram' -Message $_.Exception.Message
        $ProgressLabel.Text = "Diagram failed: $($_.Exception.Message)"
    }
    finally {
        $script:DiagramRunning = $false
        if ($script:DiagramProcess) { $script:DiagramProcess.Dispose() }
        $script:DiagramProcess = $null
        $script:DiagramStdoutTask = $null
        $script:DiagramStderrTask = $null
        $ProgressBar.Style = 'Blocks'
        $ProgressBar.Value = if ($script:DiagramCancelled) { 0 } else { 100 }
        Set-EditingEnabled -Enabled $true
        if ($script:ClosingAfterCancel) {
            $script:ClosingAfterCancel = $false
            $Form.Close()
        }
    }
})

$DiagramButton.Add_Click({ Start-SiteDiagram })

$CancelButton.Add_Click({
    if ($script:DiagramRunning -and $script:DiagramProcess -and -not $script:DiagramProcess.HasExited) {
        $script:DiagramCancelled = $true
        try { $script:DiagramProcess.Kill($true) } catch {
            Add-UiLog -Level 'Error' -Target '-' -Phase 'Diagram' -Message "Could not terminate MTAutoDraw: $($_.Exception.Message)"
        }
        $CancelButton.Enabled = $false
        $ProgressLabel.Text = 'Cancelling MTAutoDraw...'
    } elseif ($script:Running -and -not $script:Cancellation.IsCancellationRequested) {
        $script:Cancellation.Cancel()
        $CancelButton.Enabled = $false
        $ProgressLabel.Text = 'Cancellation requested; closing active connections at safe checkpoints...'
        Add-UiLog -Level 'Warning' -Target '-' -Phase 'Run' -Message 'Cancellation requested by operator.'
    }
})

$Form.Add_FormClosing({
    param($Sender, $EventArgs)
    if ($script:Running -or $script:DiagramRunning) {
        $Activity = if ($script:DiagramRunning) { 'diagram generation' } else { 'collection' }
        $Choice = [Windows.Forms.MessageBox]::Show(
            "A $Activity is still running. Cancel it and close when it finishes?",
            'Network Audit', 'YesNo', 'Warning'
        )
        $EventArgs.Cancel = $true
        if ($Choice -eq 'Yes') {
            $script:ClosingAfterCancel = $true
            if ($script:DiagramRunning -and $script:DiagramProcess -and -not $script:DiagramProcess.HasExited) {
                $script:DiagramCancelled = $true
                try { $script:DiagramProcess.Kill($true) } catch {}
            } elseif ($script:Cancellation -and -not $script:Cancellation.IsCancellationRequested) {
                $script:Cancellation.Cancel()
            }
            $CancelButton.Enabled = $false
        }
    }
})

Load-DevicesIntoGrid
Update-CredentialChoices
if ($ProfileSelector.Items.Count -gt 0) { $ProfileSelector.SelectedIndex = 0 }
Update-RunPreview

$InitialErrors = @(Get-ConfigErrors -Config $script:Config)

if ($UiSmokeTest) {
    if ($InitialErrors.Count -gt 0) {
        throw "UI smoke test cannot start because the configuration is invalid: $($InitialErrors -join '; ')"
    }

    $ProfilesVisited = 0
    for ($Index = 0; $Index -lt $ProfileSelector.Items.Count; $Index++) {
        $ProfileSelector.SelectedIndex = $Index
        $ProfilesVisited++
    }

    $OriginalDevices = @($script:Config.devices)
    $ProfilePreviewsVisited = 0
    $TotalPreviewCharacters = 0
    foreach ($ProfileName in @($ProfileSelector.Items)) {
        $script:Config.devices = @(@{
            enabled    = $true
            target     = '192.0.2.254'
            site       = 'UiSmokeTest'
            credential = 'SMOKE_TEST_ONLY'
            type       = [string]$ProfileName
        })
        Load-DevicesIntoGrid
        $SiteSelector.SelectedItem = 'All Sites'
        Update-RunPreview
        if ($PreviewBox.Text -notmatch "(?m)^Type: $([regex]::Escape([string]$ProfileName))`r?$") {
            $PreviewSummary = $PreviewBox.Text.Replace("`r", ' ').Replace("`n", ' | ')
            throw "UI smoke test did not render the Run Preview for profile $ProfileName. Preview: $PreviewSummary"
        }
        $ProfilePreviewsVisited++
        $TotalPreviewCharacters += $PreviewBox.Text.Length
    }
    $script:Config.devices = $OriginalDevices
    Load-DevicesIntoGrid

    $CommandTabsVisited = 0
    foreach ($Page in @($CommandEditors.TabPages)) {
        $CommandEditors.SelectedTab = $Page
        $CommandTabsVisited++
    }

    $MainTabsVisited = 0
    foreach ($Page in @($Tabs.TabPages)) {
        $Tabs.SelectedTab = $Page
        $MainTabsVisited++
    }

    $SiteScopesVisited = 0
    for ($Index = 0; $Index -lt $SiteSelector.Items.Count; $Index++) {
        $SiteSelector.SelectedIndex = $Index
        $SiteScopesVisited++
    }

    Update-RunPreview
    if ([string]::IsNullOrWhiteSpace($PreviewBox.Text)) {
        throw 'UI smoke test produced an empty Run Preview.'
    }

    [pscustomobject]@{
        Status             = 'PASS'
        ProfilesVisited    = $ProfilesVisited
        ProfilePreviews    = $ProfilePreviewsVisited
        MainTabsVisited    = $MainTabsVisited
        CommandTabsVisited = $CommandTabsVisited
        SiteScopesVisited  = $SiteScopesVisited
        PreviewCharacters  = $PreviewBox.Text.Length
        PreviewCharactersAcrossProfiles = $TotalPreviewCharacters
    } | ConvertTo-Json -Compress | Write-Output

    $Timer.Dispose()
    $DiagramTimer.Dispose()
    $Form.Dispose()
    return
}

if ($InitialErrors.Count -gt 0) {
    $Form.Add_Shown({
        [Windows.Forms.MessageBox]::Show(
            "The configuration needs attention before a run can start:`r`n`r`n$($InitialErrors -join "`r`n")",
            'Network Audit - Configuration warning', 'OK', 'Warning'
        ) | Out-Null
    })
}

[Windows.Forms.Application]::Run($Form)

foreach ($Bundle in @($script:Credentials.Values)) {
    try { $Bundle.Credential.Password.Dispose() } catch {}
    if ($Bundle.EnablePassword) {
        try { $Bundle.EnablePassword.Dispose() } catch {}
    }
}
$script:Credentials.Clear()
if ($script:Cancellation) { $script:Cancellation.Dispose() }
$Timer.Dispose()
$DiagramTimer.Dispose()
$Form.Dispose()
