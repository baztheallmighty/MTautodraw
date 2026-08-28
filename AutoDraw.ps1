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


#This is the main function. It calls all the other functions.




Param(
    [Parameter(Mandatory = $true)]
    [string] $GDirectory,
    [Parameter(Mandatory = $false)]
    [string] $GPathToScript,
    [Parameter(Mandatory = $true)]
    [string] $GOutPutDirectory,
    [switch] $Quiet,
    # Error|Warn|Info|Debug|Trace. Overrides both the $GLogLevel default and -Quiet when given
    # explicitly; -Quiet alone is shorthand for Warn.
    [ValidateSet('Error', 'Warn', 'Info', 'Debug', 'Trace')]
    [string] $LogLevel,
    # JSON file of setting overrides applied on top of configurationVariables.ps1, e.g.
    # { "GDrawPhysical": false, "GDrawioTopologyEndUnitMode": "Grid" }. A profile saved by the GUI
    # nests the same pairs under "Settings" and is accepted as-is. Named -SettingsPath rather than
    # -SettingsFile because pwsh itself has a -SettingsFile parameter and one name for two things in
    # a single command line is a support call waiting to happen.
    [string] $SettingsPath
)


# These three run before any library - including HelperFunctions.ps1, home of Write-MTAutoDrawLog -
# has loaded, so Write-Warning rather than the standard log contract; there is nothing else available
# to log through this early, and a missing parameter genuinely is warning-worthy.
if(!$GDirectory){
    Write-Warning "No -GDirectory given. Using the current directory."
    $GDirectory =(Get-Location).path
}
if(!$GPathToScript){
    Write-Warning "No -GPathToScript given. Using the current directory."
    $GPathToScript =(Get-Location).path
}
if(!$GOutPutDirectory){
    Write-Warning "No -GOutPutDirectory given. Using the current directory."
    $GOutPutDirectory =(Get-Location).path
}
#Make sure we have a trailing slash.
if($GOutPutDirectory -notmatch "\\$"){
    $GOutPutDirectory="$($GOutPutDirectory)`\"
}
if($GPathToScript -notmatch "\\$"){
    $GPathToScript="$($GPathToScript)`\"
}
if($GDirectory -notmatch "\\$"){
    $GDirectory="$($GDirectory)`\"
}

$runStartedAtUtc = [DateTime]::UtcNow
# -LogLevel is authoritative when given; otherwise -Quiet is shorthand for Warn, else the
# configuration file's default (Info) applies. Resolved once here and reasserted after every library
# import below, because configurationVariables.ps1 sets its own $GLogLevel default when it loads and
# would otherwise silently win over the command line - the same reason $GDebugingEnabled is repeated.
$resolvedLogLevel = if ($LogLevel) { $LogLevel } elseif ($Quiet) { 'Warn' } else { 'Info' }
$script:GDebugingEnabled = -not $Quiet
$global:GDebugingEnabled = -not $Quiet
$script:GLogLevel = $resolvedLogLevel
$global:GLogLevel = $resolvedLogLevel
$runExitCode = 2
$runFatalError = $null
$runCaptureFiles = @()
$runCaptureGroups = @()
$runArtifacts = [System.Collections.Generic.List[string]]::new()
$transcriptStarted = $false

try {
    if (-not (Test-Path -LiteralPath $GDirectory -PathType Container)) {
        throw "Input directory does not exist: $GDirectory"
    }
    if (-not (Test-Path -LiteralPath $GOutPutDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $GOutPutDirectory -Force
    }

    $transcriptPath = "$($GOutPutDirectory)Log$(Get-Date -Format 'yyyyMMddHHmmss').txt"
    Start-Transcript -Path $transcriptPath -NoClobber | Out-Null
    $transcriptStarted = $true
    [void]$runArtifacts.Add($transcriptPath)
    # From here onward every PowerShell runtime error belongs to this run. Errors are
    # summarized structurally below even when a caller redirects the transcript.
    $Error.Clear()
###############################################    load libraries and error checking     ###############################################

# Stopwatch shared by structured logging and performance summaries.
$global:GLastExecutionTime=[System.Diagnostics.Stopwatch]::StartNew()
$global:GLapTime=$global:GLastExecutionTime.ElapsedMilliseconds


# Logging.ps1 loads first: it is home to Write-MTAutoDrawLog, and the loop below logs each library
# as it loads - including Logging.ps1 itself, which is what makes that safe. Nothing else in this
# list runs anything outside a function body at load time (verified), so the rest of the order is
# free.
$GLibrariesToLoad=@(
    "Logging.ps1",
    "ParserRuntime.ps1",
    "ObjectFunctions.ps1",
    "NeighborResolution.ps1",
    "LayoutMath.ps1",
    "DrawioDocument.ps1",
    "DrawFunctions_drawio.ps1",
    "PlacementStrategies.ps1",
    "DiagramModels.ps1",
    "DiagramModels.Layer3.ps1",
    "DiagramModels.Pages.ps1",
    "DrawLogic_drawio.ps1",
    "Exports.ps1",
    "HelperFunctions.ps1",
    "configurationVariables.ps1",
    "StartProcessingConfig.ps1",
    "Network Path Analysis.ps1"
)


$perfLoad = [System.Diagnostics.Stopwatch]::StartNew()   # PERF
foreach ($libary in $GLibrariesToLoad){
    if(test-path ($GPathToScript+$libary)){
        Import-Module "$($GPathToScript)$($libary)" -force
        $script:GDebugingEnabled = -not $Quiet
        $global:GDebugingEnabled = -not $Quiet
        $script:GLogLevel = $resolvedLogLevel
        $global:GLogLevel = $resolvedLogLevel
        Write-MTAutoDrawLog -Level Info -Phase Load -Message "loading:$($GPathToScript)$($libary)"
    }else{
        throw "Required library not found: $($GPathToScript)$($libary)"
    }
}
# PERF: configurationVariables.ps1 has only just been imported, so $GPerfTiming exists from here on
# and not before - which is why this one is a raw stopwatch rather than a Start-MTAutoDrawPerf token.
Add-MTAutoDrawPerf -Label "Load: import $($GLibrariesToLoad.Count) libraries" -Milliseconds $perfLoad.Elapsed.TotalMilliseconds







if(test-path "$($GPathToScript)GETIPV4Subnet\GetIPv4Subnet.psm1"){
    Import-Module -Name "$($GPathToScript)GETIPV4Subnet\GetIPv4Subnet.psm1" -Force -DisableNameChecking
}else{
    throw "Required module not found: $($GPathToScript)GETIPV4Subnet\GetIPv4Subnet.psm1"
}

# -SettingsPath overrides, applied here for two reasons. It is AFTER the library loop, because
# configurationVariables.ps1 sets its defaults as it loads and would otherwise silently win - the
# same hazard the reassert below exists for. It is BEFORE that reassert, so -LogLevel and -Quiet
# still outrank anything a settings file carries, and before the interpreter checks below, so a
# GPathToPythonExe override is validated rather than bypassed.
#
# Import-Module on a .ps1 dot-sources its variables into GLOBAL scope, verified rather than assumed,
# which is both why $global: assignment genuinely replaces a default here and why the $using: block
# in Start-ProcessingFiles can see the result.
#
# The file is data. It is deserialized and assigned, never executed.
if ($SettingsPath) {
    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        throw "Settings file not found: $SettingsPath"
    }

    $settingsDocument = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
    # A GUI profile nests its overrides under .Settings; a hand-written file is usually just the
    # name/value pairs at the top level. Both are accepted so a saved profile works unmodified.
    $settingsRoot = $settingsDocument
    if ($settingsDocument.PSObject.Properties.Name -contains 'Settings' -and $settingsDocument.Settings) {
        $settingsRoot = $settingsDocument.Settings
    }

    $appliedSettings = 0
    foreach ($setting in $settingsRoot.PSObject.Properties) {
        # Whitelist by existence. A name nothing declared is a stale profile, and saying so beats
        # setting a variable no code reads and letting the user believe it took effect.
        #
        # Test-Path on the Variable: drive rather than Get-Variable -ErrorAction SilentlyContinue:
        # the latter still records the failure in $Error, and the summary block below reports
        # everything left in $Error as a runtime processing error - which would turn a handled,
        # already-reported unknown key into a Fail verdict.
        if (-not (Test-Path -LiteralPath ('Variable:Global:' + $setting.Name))) {
            Write-MTAutoDrawLog -Level Warn -Phase Load -Message "Ignoring unknown setting '$($setting.Name)' from $SettingsPath"
            continue
        }
        Set-Variable -Name $setting.Name -Value $setting.Value -Scope Global
        $appliedSettings++
    }
    Write-MTAutoDrawLog -Level Info -Phase Load -Message "Applied $appliedSettings setting override(s) from $SettingsPath"
}

# Configuration files retain a documented default, but the command-line switch is authoritative.
$script:GDebugingEnabled = -not $Quiet
$global:GDebugingEnabled = -not $Quiet
$script:GLogLevel = $resolvedLogLevel
$global:GLogLevel = $resolvedLogLevel

if( ! (test-path $GPathToPythonExe)){
    throw "Bundled Python executable not found: $GPathToPythonExe"
}

if( ! (test-path $GPathToPythonTextFSMScript)){
    throw "TextFSM wrapper not found: $GPathToPythonTextFSMScript"
}

#Python check

if($GPathToPythonExe){

    if(!(test-path $GPathToPythonExe)){
        throw "Python executable is required but was not found: $GPathToPythonExe"
    }
}else{

    if ((get-childitem env:path).value -split ";" | where { $_ -like "*python*" } |select -First 1){
       $GPathToPythonExe="$((get-childitem env:path).value -split ";" | where { $_ -like "*python*" } |select -First 1)python.exe"
    }
    if(!(test-path $GPathToPythonExe)){
        throw "Python executable is required but was not found: $GPathToPythonExe"
    }
}

###############################################    MAIN     ###############################################
#Load known mac to vendor mapping of mac addresses into a hash table for quick lookup.
#Also downloads the mapping if not present on disk.
$perf = Start-MTAutoDrawPerf -Label "Ingest: Get-MacAddressToVendorMapping"   # PERF
$GMacAddressToVendorMapping=Get-MacAddressToVendorMapping
Stop-MTAutoDrawPerf -Token $perf -Detail "$($GMacAddressToVendorMapping.Count) OUI rows"
#Process all config files
$GArrayOfObjects=@() #Array of all the devices,their networks, bgp,cdp,etc
$GArrayOfNetworks=@() #List of unquie networks shared across all devices.
$GArrayOfLLDPDeviceIDs=@() #Array of all LLDP Objects we have processed across all hosts.
$GArrayOfCDPDeviceIDs=@() #Array of all CDP Objects we have processed across all hosts.
$GArrayOfIPApr=@() #Create an array of ip ARP entries. This will be used when drawing layer 3 diagrams.
$GArrayofGatewayHosts=@() #An Array of LLDP,CDP or ARP gateway hosts we know about. This is used to draw the layer 3 link diagram.




$perf = Start-MTAutoDrawPerf -Label "Ingest: enumerate capture files"   # PERF
$runCaptureFiles = @(Get-ChildItem -LiteralPath $GDirectory -File -Recurse -Filter '*.txt')
Stop-MTAutoDrawPerf -Token $perf -Detail "$($runCaptureFiles.Count) files"

$perf = Start-MTAutoDrawPerf -Label "Ingest: Create-FileHostObjects"   # PERF
$runCaptureGroups = @(Create-FileHostObjects -Files $runCaptureFiles)
Stop-MTAutoDrawPerf -Token $perf -Detail "$($runCaptureGroups.Count) capture groups"

$perf = Start-MTAutoDrawPerf -Label "Parse+Resolve: Start-ProcessingFiles (TOTAL)"   # PERF
$processed = Start-ProcessingFiles -Files $runCaptureFiles -CaptureGroups $runCaptureGroups -RunStartedAtUtc $runStartedAtUtc
Stop-MTAutoDrawPerf -Token $perf
$GArrayOfNetworks      = $processed.Networks
$GArrayOfObjects       = $processed.Devices
$GArrayOfCDPDeviceIDs  = $processed.CdpHosts
$GArrayOfLLDPDeviceIDs = $processed.LldpHosts
$GArrayOfIPApr         = $processed.ArpEntries
$GArrayofGatewayHosts  = $processed.GatewayHosts

# Build one evidence model for every consumer. CDP/LLDP stays authoritative;
# STP, CAM, ARP, and strict descriptions only fill unresolved topology gaps.
$perf = Start-MTAutoDrawPerf -Label "Resolve: Get-MTAutoDrawTopologyEvidenceModel"   # PERF
$GTopologyEvidenceModel = Get-MTAutoDrawTopologyEvidenceModel -Devices $GArrayOfObjects -GatewayHosts $GArrayofGatewayHosts
Stop-MTAutoDrawPerf -Token $perf -Detail "$(@($GTopologyEvidenceModel.Rows).Count) evidence rows"




# --- Global drawio Variables ---
$global:itemCounter = 0
$global:drawioXml = ""


#Output data to csv and json
if($GExportData){
    Write-MTAutoDrawPhase -Phase Export -Message "Exporting data to files."
    $vlanRows = foreach ($device in $GArrayOfObjects) {
        foreach ($vlan in @($device.vlans)) {
            [pscustomobject]@{ ParentObject = $device.hostname; Number = $vlan.number; Name = $vlan.name; Description = $vlan.description }
        }
    }
    $perf = Start-MTAutoDrawPerf -Label "Export: vlans.csv"   # PERF
    $vlanRows | Export-Csv "$($GOutPutDirectory)vlans.csv" -NoTypeInformation
    Stop-MTAutoDrawPerf -Token $perf -Detail "$(@($vlanRows).Count) rows"

    $cdpRows = foreach ($device in $GArrayOfObjects) {
        foreach ($neighbor in @($device.CDPNeighbors)) {
            $neighbor | Select-Object DeviceID,SystemName,Platform,InterfaceLocalDevice,InterfaceRemoteDevice,Version,InterfaceIPAddresses,Capabilities,TargetHostname,TargetInterface,MatchConfidence,MatchMethod,Ignored,IgnoreReason,@{ Name = 'ParentObject'; Expression = { $device.hostname } }
        }
    }
    $perf = Start-MTAutoDrawPerf -Label "Export: CDPNeighbors.csv"   # PERF
    $cdpRows | Export-Csv -Path "$($GOutPutDirectory)CDPNeighbors.csv" -NoTypeInformation
    Stop-MTAutoDrawPerf -Token $perf -Detail "$(@($cdpRows).Count) rows"

    $lldpRows = foreach ($device in $GArrayOfObjects) {
        foreach ($neighbor in @($device.LLDPNeighbors)) {
            $neighbor | Select-Object InterfaceLocalDevice,ChassisID,ChassisIDSubtype,InterfaceRemoteDevice,NeighborInterfaceDescription,Hostname,SystemDescription,Capabilities,ManagementIP,VLAN,SERIAL,PortID,PortIDSubtype,TargetHostname,TargetInterface,MatchConfidence,MatchMethod,Ignored,IgnoreReason,@{ Name = 'ParentObject'; Expression = { $device.hostname } }
        }
    }
    $perf = Start-MTAutoDrawPerf -Label "Export: LLDPNeighbors.csv"   # PERF
    $lldpRows | Export-Csv -Path "$($GOutPutDirectory)LLDPNeighbors.csv" -NoTypeInformation
    Stop-MTAutoDrawPerf -Token $perf -Detail "$(@($lldpRows).Count) rows"

    $cidrRows = foreach ($device in $GArrayOfObjects) {
        foreach ($network in @($device.ArrayOfNetworks)) {
            $vendorCounts = @($network.ARPEntries | Group-Object VendorCompanyName | Sort-Object Count -Descending | ForEach-Object { "$($_.Count) $($_.Name)" }) -join '; '
            [pscustomobject]@{
                DeviceIdentifier = $device.DeviceIdentifier; cidr = $network.cidr; routedvlan = $network.routedvlan
                networkname = $network.networkname; ParentObject = $device.hostname; DeviceInVlan = $vendorCounts
            }
        }
    }
    $perf = Start-MTAutoDrawPerf -Label "Export: cidr.csv"   # PERF
    $cidrRows | Export-Csv "$($GOutPutDirectory)cidr.csv" -NoTypeInformation
    Stop-MTAutoDrawPerf -Token $perf -Detail "$(@($cidrRows).Count) rows"

    # Hardware/OS fields come from the shared extraction helper
    # (Get-MTAutoDrawDeviceInventoryRow), which owns the rule for what counts
    # as "the" hardware model or serial. Identity/discovery fields are added on top for the export only.
    $deviceRows = foreach ($device in ($GArrayOfObjects | Sort-Object HostName)) {
        $inventoryRow = Get-MTAutoDrawDeviceInventoryRow -Device $device
        [pscustomobject]@{
            Hostname         = $inventoryRow.Hostname
            DeviceIdentifier = $device.DeviceIdentifier
            DeviceType       = $inventoryRow.DeviceType
            ManagementIP     = $device.ManagementIP
            Platform         = $device.Platform
            Description      = $device.Description
            Origin           = $device.Origin
            Hardware         = $inventoryRow.Hardware
            Serial           = $inventoryRow.Serial
            OSOrImage        = $inventoryRow.OSOrImage
            Uptime           = $inventoryRow.Uptime
        }
    }
    $perf = Start-MTAutoDrawPerf -Label "Export: devices.csv"   # PERF
    $deviceRows | Export-Csv "$($GOutPutDirectory)devices.csv" -NoTypeInformation
    Stop-MTAutoDrawPerf -Token $perf -Detail "$(@($deviceRows).Count) rows"

    # Export all interfaces
    $interfaceRows = foreach ($device in $GArrayOfObjects) {
        foreach ($interface in @($device.interfaces)) {
            [pscustomobject]@{
                Hostname                    = $device.hostname
                DeviceIdentifier            = $device.DeviceIdentifier
                DeviceType                  = $device.DeviceType
                ManagementIP                = $device.ManagementIP
                Interface                   = $interface.Interface
                Description                 = $interface.Description
                IPAddress                   = $interface.IPAddress
                SubnetMask                  = $interface.SubnetMask
                Cidr                        = $interface.Cidr
                SecondaryIPAddress          = @($interface.SecondaryIPAddress) -join '; '
                SecondarySubnetMask         = @($interface.SecondarySubnetMask) -join '; '
                SecondaryCidr               = @($interface.SecondaryCidr) -join '; '
                SwitchportMode              = $interface.SwitchportMode
                SwitchportAccessVlan        = $interface.SwitchportAccessVlan
                SwitchportTrunkVlan         = @($interface.SwitchportTrunkVlan) -join '; '
                NativeVlan                  = $interface.NativeVlan
                Shutdown                    = $interface.shutdown
                VRF                         = $interface.vrf
                RoutedVlan                  = $interface.RoutedVlan
                SwitchPortType              = $interface.SwitchPortType
                IntStatus                   = $interface.IntStatus
                ProtocolStatus              = $interface.INTProtocolStatus
                Speed                       = $interface.Speed
                Duplex                      = $interface.Duplex
                MacAddress                  = $interface.macaddress
                MacAddressArray             = @($interface.MacAddressArray) -join '; '
                ChannelGroup                = $interface.ChannelGroup
                ChannelGroupMode            = $interface.ChannelGroupMode
                VPC                         = $interface.vpc
                Zone                        = $interface.Zone
                StandbyIP                   = $interface.Standbyip
                StandbyNumber               = $interface.StandbyNumber
                StandbyPriority             = $interface.StandbyPriority
                ClusterIP                   = $interface.ClusterIP
                HardwareType                = $interface.HardwareType
                MediaType                   = $interface.MediaType
                SpanningTreePortType        = $interface.SpanningTreePortType
                STState                     = $interface.STState
                STRole                      = $interface.STRole
                HasCDPNeighbor              = $interface.HasCPDNieghbor
                HasLLDPNeighbor             = $interface.HasLLDPNeighbor

                # FortiGate-specific values. Blank for other device types.
                VDOM                        = $interface.VDOM
                Mode                        = $interface.Mode
                AllowAccess                 = $interface.AllowAccess
                Role                        = $interface.Role
                Alias                       = $interface.Alias
                FortiLink                   = $interface.FortiLink
                SecurityMode                = $interface.SecurityMode
                DeviceIdentification        = $interface.DeviceIdentification
                LLDPTransmission            = $interface.LLDPTransmission
                LLDPReception               = $interface.LLDPReception
                SNMPIndex                   = $interface.SNMPIndex
                EstimatedUpstreamBandwidth  = $interface.EstimatedUpstreamBandwidth
                EstimatedDownstreamBandwidth = $interface.EstimatedDownstreamBandwidth
                MonitorBandwidth            = $interface.MonitorBandwidth
                MTUOverride                 = $interface.MTUOverride
            }
        }
    }
    $perf = Start-MTAutoDrawPerf -Label "Export: interfaces.csv"   # PERF
    $interfaceRows | Export-Csv "$($GOutPutDirectory)interfaces.csv" -NoTypeInformation
    Stop-MTAutoDrawPerf -Token $perf -Detail "$(@($interfaceRows).Count) rows"

    # Purpose-built flat Layer 3 exports. These are derived from the resolved in-memory
    # model, so every vendor parser feeds the same schema and next hops can be associated
    # with captured devices or external gateway hosts.
    $perf = Start-MTAutoDrawPerf -Label "Export: routes.csv"   # PERF
    $routeExportRows = Get-MTAutoDrawRouteExportRows -Devices $GArrayOfObjects -GatewayHosts $GArrayofGatewayHosts
    Export-MTAutoDrawCsv -Path "$($GOutPutDirectory)routes.csv" `
        -Columns (Get-MTAutoDrawRouteExportColumns) -Rows $routeExportRows
    Stop-MTAutoDrawPerf -Token $perf -Detail "$(@($routeExportRows).Count) rows"

    $perf = Start-MTAutoDrawPerf -Label "Export: layer3-interfaces.csv"   # PERF
    $layer3InterfaceExportRows = Get-MTAutoDrawLayer3InterfaceExportRows -Devices $GArrayOfObjects
    Export-MTAutoDrawCsv -Path "$($GOutPutDirectory)layer3-interfaces.csv" `
        -Columns (Get-MTAutoDrawLayer3InterfaceExportColumns) -Rows $layer3InterfaceExportRows
    Stop-MTAutoDrawPerf -Token $perf -Detail "$(@($layer3InterfaceExportRows).Count) rows"

    $perf = Start-MTAutoDrawPerf -Label "Export: topology-evidence.csv"   # PERF
    Export-MTAutoDrawCsv -Path "$($GOutPutDirectory)topology-evidence.csv" `
        -Columns (Get-MTAutoDrawTopologyEvidenceColumns) -Rows $GTopologyEvidenceModel.Rows
    Stop-MTAutoDrawPerf -Token $perf -Detail "$(@($GTopologyEvidenceModel.Rows).Count) rows"

    $objectsPath = "$($GOutPutDirectory)Objects.json"
    $perf = Start-MTAutoDrawPerf -Label "Export: Objects.json (model+ConvertTo-Json+write)"   # PERF
    ConvertTo-MTAutoDrawExportModel -Devices $GArrayOfObjects -SourceDirectory $GDirectory |
        ConvertTo-Json -Depth 12 |
        Set-Content -LiteralPath $objectsPath -Encoding utf8
    Stop-MTAutoDrawPerf -Token $perf -Detail "$([Math]::Round((Get-Item -LiteralPath $objectsPath).Length / 1MB, 1)) MB"

    foreach ($artifactName in @('vlans.csv','CDPNeighbors.csv','LLDPNeighbors.csv','cidr.csv','devices.csv','interfaces.csv','routes.csv','layer3-interfaces.csv','topology-evidence.csv','Objects.json')) {
        [void]$runArtifacts.Add("$($GOutPutDirectory)$artifactName")
    }

}

if($GNetworkTracePathAnalysis){
    Invoke-NetworkPathAnalysis -DeviceData $GArrayOfObjects -ReportPath $GOutPutDirectory
}

if($GDrawMultipleDevicesDiagram){
    Write-MTAutoDrawPhase -Phase Draw -Message "Initializing Multi-Device Draw.io file..."
    Initialize-DrawioFile


    # --- One-screen overview pages. Placed ahead of the large detailed pages below, so a user
    # opening the file lands on readable "map" pages first. ---
    if($GDrawSiteTopologyOverview){
        $perf = Start-MTAutoDrawPerf -Label "Draw page: Topology Overview"   # PERF
        Draw-SiteTopologyOverviewDiagram -ArrayOfObjects $GArrayOfObjects -TopologyEvidenceModel $GTopologyEvidenceModel
        Stop-MTAutoDrawPerf -Token $perf -Detail "xml now $([Math]::Round($global:GDrawioBuilder.Length / 1MB, 2)) MB"
    }
    if($GDrawLayer3TopologyOverview){
        $perf = Start-MTAutoDrawPerf -Label "Draw page: Layer 3 Topology Overview"   # PERF
        Draw-Layer3TopologyOverviewDiagram -ArrayOfObjects $GArrayOfObjects -ArrayofGatewayHosts $GArrayofGatewayHosts
        Stop-MTAutoDrawPerf -Token $perf -Detail "xml now $([Math]::Round($global:GDrawioBuilder.Length / 1MB, 2)) MB"
    }
    if($GDrawLayer3Connectivity){
        $perf = Start-MTAutoDrawPerf -Label "Draw page: Layer 3 Connectivity"   # PERF
        Draw-Layer3ConnectivityDiagram -ArrayOfObjects $GArrayOfObjects
        Stop-MTAutoDrawPerf -Token $perf -Detail "xml now $([Math]::Round($global:GDrawioBuilder.Length / 1MB, 2)) MB"
    }
    if($GDrawLayer3RoutesSummary){
        $perf = Start-MTAutoDrawPerf -Label "Draw page: Layer 3 Routes Summary"   # PERF
        Draw-Layer3RoutesSummaryDiagram -ArrayOfObjects $GArrayOfObjects -ArrayofGatewayHosts $GArrayofGatewayHosts
        Stop-MTAutoDrawPerf -Token $perf -Detail "xml now $([Math]::Round($global:GDrawioBuilder.Length / 1MB, 2)) MB"
    }
    # Per-firewall pages, grouped by device so a site's firewall tabs sit together.
    if($GDrawFirewallOverview -or $GDrawFirewallNatInterfaces -or $GDrawFirewallZoneHub -or $GDrawFirewallRuleRisk){
        $securityDeviceTypes = Get-MTAutoDrawSecurityDeviceTypes
        $firewallDevices = @($GArrayOfObjects | Where-Object {
            ($_.DeviceType -and $_.DeviceType -in $securityDeviceTypes) -or
            @($_.SecurityPolicy).Count -gt 0 -or @($_.NatPolicy).Count -gt 0
        } | Sort-Object HostName)
        foreach($firewallDevice in $firewallDevices){
            if($GDrawFirewallOverview){
                $perf = Start-MTAutoDrawPerf -Label "Draw page: FW Overview (all firewalls)"   # PERF
                Draw-FirewallOverviewDiagram -Device $firewallDevice
                Stop-MTAutoDrawPerf -Token $perf
            }
            if($GDrawFirewallZoneHub){
                $perf = Start-MTAutoDrawPerf -Label "Draw page: FW Zone Hub (all firewalls)"   # PERF
                Draw-FirewallZoneHubDiagram -Device $firewallDevice
                Stop-MTAutoDrawPerf -Token $perf
            }
            if($GDrawFirewallNatInterfaces){
                $perf = Start-MTAutoDrawPerf -Label "Draw page: FW NAT and Interfaces (all firewalls)"   # PERF
                Draw-FirewallNatInterfacesDiagram -Device $firewallDevice
                Stop-MTAutoDrawPerf -Token $perf
            }
            if($GDrawFirewallRuleRisk){
                $perf = Start-MTAutoDrawPerf -Label "Draw page: FW Rule Risk (all firewalls)"   # PERF
                Draw-FirewallRuleRiskDiagram -Device $firewallDevice
                Stop-MTAutoDrawPerf -Token $perf
            }
        }
    }
    if($GDrawCDPALL){
        $perf = Start-MTAutoDrawPerf -Label "Draw page: CDP-LLDP All"   # PERF
        Draw-AllNeighborsDrawio -ArrayOfObjects $GArrayOfObjects -ArrayOfCDPDeviceIDs $GArrayOfCDPDeviceIDs -ArrayOfLLDPDeviceIDs $GArrayOfLLDPDeviceIDs -DrawAllNeighbors $true -TopologyEvidenceModel $GTopologyEvidenceModel
        Stop-MTAutoDrawPerf -Token $perf -Detail "xml now $([Math]::Round($global:GDrawioBuilder.Length / 1MB, 2)) MB"
    }
    if($GDrawCDP){
        $perf = Start-MTAutoDrawPerf -Label "Draw page: CDP-LLDP brief"   # PERF
        Draw-AllNeighborsDrawio -ArrayOfObjects $GArrayOfObjects -ArrayOfCDPDeviceIDs $GArrayOfCDPDeviceIDs -ArrayOfLLDPDeviceIDs $GArrayOfLLDPDeviceIDs -DrawAllNeighbors $False -TopologyEvidenceModel $GTopologyEvidenceModel
        Stop-MTAutoDrawPerf -Token $perf -Detail "xml now $([Math]::Round($global:GDrawioBuilder.Length / 1MB, 2)) MB"
    }
    if($GDrawLayer3){
        $perf = Start-MTAutoDrawPerf -Label "Draw page: Layer 3 All"   # PERF
        Draw-Layer3AllDrawio -ArrayOfObjects $GArrayOfObjects -ArrayOfNetworks $GArrayOfNetworks -ArrayOfIPApr $GArrayOfIPApr
        Stop-MTAutoDrawPerf -Token $perf -Detail "xml now $([Math]::Round($global:GDrawioBuilder.Length / 1MB, 2)) MB"
    }
    if($GDrawLayer3RoutedLinksOnly){
        $perf = Start-MTAutoDrawPerf -Label "Draw page: Layer 3 Routed Links Only"   # PERF
        Draw-Layer3RoutedLinksOnlyDrawio -ArrayOfObjects $GArrayOfObjects -ArrayOfNetworks $GArrayOfNetworks -ArrayOfIPApr $GArrayOfIPApr -ArrayofGatewayHosts $GArrayofGatewayHosts
        Stop-MTAutoDrawPerf -Token $perf -Detail "xml now $([Math]::Round($global:GDrawioBuilder.Length / 1MB, 2)) MB"
    }
    if($GDrawLayer3RoutesOnly){
        $perf = Start-MTAutoDrawPerf -Label "Draw page: Layer 3 Routes Only"   # PERF
        Draw-Layer3RoutesOnlyDrawio -ArrayOfObjects $GArrayOfObjects -ArrayOfIPApr $GArrayOfIPApr -ArrayofGatewayHosts $GArrayofGatewayHosts
        Stop-MTAutoDrawPerf -Token $perf -Detail "xml now $([Math]::Round($global:GDrawioBuilder.Length / 1MB, 2)) MB"
    }
    if($GDrawSpanningTree){
        $perf = Start-MTAutoDrawPerf -Label "Draw page: Spanning-Tree"   # PERF
        Draw-SpanningTreeDiagram -ArrayOfObjects $GArrayOfObjects
        Stop-MTAutoDrawPerf -Token $perf -Detail "xml now $([Math]::Round($global:GDrawioBuilder.Length / 1MB, 2)) MB"
    }
    $perf = Start-MTAutoDrawPerf -Label "Draw: Finalize+Save MultiDevice file"   # PERF
    Finalize-DrawioFile
    $multiDeviceFilePath = "$($GOutPutDirectory)MTAudotDraw-MultiDevice-$(get-date -Format yyyyMMdd-hhmm).drawio"
    Save-DrawioFile -Path $multiDeviceFilePath
    Stop-MTAutoDrawPerf -Token $perf -Detail "$([Math]::Round((Get-Item -LiteralPath $multiDeviceFilePath).Length / 1MB, 2)) MB"
    [void]$runArtifacts.Add($multiDeviceFilePath)
    Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Multi-Device Diagram saved to $multiDeviceFilePath"
}


#Finish singles routing.
#Maybe add second file. Look at speed to see what needs fixing next.
# Draw Single-Device Diagrams
if($GdrawSingles){
    Write-MTAutoDrawPhase -Phase Draw -Message "Initializing Singles Draw.io file..."
    Initialize-DrawioFile

    # PERF: per-device pages are accumulated rather than printed one line each - a line per device
    # would bury everything else. The summary carries the total and the call count.
    $perfSinglesAll = Start-MTAutoDrawPerf -Label "Draw: Singles loop (TOTAL)"   # PERF
    foreach ($Device in $GArrayOfObjects){
        # Draw the Layer 3 diagram for the device if enabled
        if($GDrawLayer3){
            $perfOne = [System.Diagnostics.Stopwatch]::StartNew()   # PERF
            Draw-SinglesLayer3Drawio -Device $Device -ArrayOfNetworks $GArrayOfNetworks
            Add-MTAutoDrawPerf -Label "Draw page: <host> L3 (per device, accumulated)" -Milliseconds $perfOne.Elapsed.TotalMilliseconds
        }

        # ADD THIS BLOCK to draw the physical diagram for the device if enabled
        # Assumes a global variable $GDrawPhysical exists.
        if($GDrawPhysical){
            $perfOne = [System.Diagnostics.Stopwatch]::StartNew()   # PERF
            Draw-SingleHostPhysicalDrawio -Device $Device -ArrayOfObjects $GArrayOfObjects -ArrayOfCDPDeviceIDs $GArrayOfCDPDeviceIDs -ArrayOfLLDPDeviceIDs $GArrayOfLLDPDeviceIDs
            Add-MTAutoDrawPerf -Label "Draw page: <host> Physical (per device, accumulated)" -Milliseconds $perfOne.Elapsed.TotalMilliseconds
        }
    }
    Stop-MTAutoDrawPerf -Token $perfSinglesAll -Detail "$(@($GArrayOfObjects).Count) devices"

    $perf = Start-MTAutoDrawPerf -Label "Draw: Finalize+Save Singles file"   # PERF
    Finalize-DrawioFile
    $singlesFilePath = "$($GOutPutDirectory)MTAudotDraw-Singles-$(get-date -Format yyyyMMdd-hhmm).drawio"
    Save-DrawioFile -Path $singlesFilePath
    Stop-MTAutoDrawPerf -Token $perf -Detail "$([Math]::Round((Get-Item -LiteralPath $singlesFilePath).Length / 1MB, 2)) MB"
    [void]$runArtifacts.Add($singlesFilePath)
    Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Single-Device Diagrams saved to $singlesFilePath"
}


$runExitCode = 0
}
catch {
    $runFatalError = $_.Exception.Message
    $runExitCode = 2
    Write-Error "MTAutoDraw failed: $runFatalError" -ErrorAction Continue
}
finally {
    try {
        $summaryPath = "$($GOutPutDirectory)RunSummary.json"
        $processingErrors = [System.Collections.Generic.List[object]]::new()
        foreach ($workerError in @($global:GLastProcessingErrors)) {
            if ($workerError) { [void]$processingErrors.Add($workerError) }
        }
        foreach ($runtimeError in @($Error)) {
            $message = [string]$runtimeError.Exception.Message
            if (-not $message -or $message -like 'Parser failure *' -or $message -like 'MTAutoDraw failed:*') { continue }
            [void]$processingErrors.Add([pscustomobject]@{
                HostID = $null; DeviceType = $null; Parser = 'PowerShell runtime'
                CapturePath = $null; Message = $message
                ScriptName = $runtimeError.InvocationInfo.ScriptName
                Line = $runtimeError.InvocationInfo.ScriptLineNumber
                Position = $runtimeError.InvocationInfo.PositionMessage
                StackTrace = $runtimeError.ScriptStackTrace
            })
        }
        $summary = New-MTAutoDrawRunSummary -SourceDirectory $GDirectory -TextFileCount @($runCaptureFiles).Count `
            -CaptureGroups $runCaptureGroups -Devices $GArrayOfObjects -Artifacts @($runArtifacts) `
            -StartedAtUtc $runStartedAtUtc -ProcessingErrors @($processingErrors) -FatalError $runFatalError
        $runExitCode = [int]$summary.ExitCode
        [void]$runArtifacts.Add($summaryPath)
        $summary.Artifacts = @($runArtifacts | Sort-Object -Unique)
        $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
        # Deliberately not run through Write-MTAutoDrawLog: a run verdict is Pass/Warn/Fail, not one
        # of the five message levels, and this line prints unconditionally regardless of $GLogLevel -
        # it is the one line a -Quiet run still shows. The elapsed prefix matches every other line's
        # format for visual consistency; the colour stays its own three-way mapping.
        $verdictColor = if ($summary.Verdict -eq 'Pass') { 'Green' } elseif ($summary.Verdict -eq 'Warn') { 'Yellow' } else { 'Red' }
        $verdictText = ("MTAutoDraw {0} verdict: {1} (exit {2}); devices={3}; parser errors={4}; worker errors={5}; summary={6}" -f `
            $summary.Version,$summary.Verdict,$summary.ExitCode,$summary.Counts.ProcessedDevices,$summary.Counts.ParserErrors,$summary.Counts.ProcessingErrors,$summaryPath)
        Write-Host (Format-MTAutoDrawLogLine -Elapsed $global:GLastExecutionTime.Elapsed -Level $summary.Verdict -Phase Summary -Message $verdictText) -ForegroundColor $verdictColor
    }
    catch {
        $runExitCode = 2
        Write-Error "Could not write RunSummary.json: $($_.Exception.Message)" -ErrorAction Continue
    }
    # PERF: last thing before the transcript closes, so the table lands in the run log too.
    try { Write-MTAutoDrawPerfSummary } catch { }
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}

exit $runExitCode
