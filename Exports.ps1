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

# MTAutoDraw - Exports
#
# The in-memory model becomes CSV and JSON: device inventory rows, the neighbor/route/layer-3 export
# models, CSV column/row builders, and the generic Export-MTAutoDrawCsv writer (headers-only file
# when there is no data, so a run with zero of something still produces a valid, openable CSV).
#
# Depends on: nothing
# Loaded by:  AutoDraw.ps1 ($GLibrariesToLoad)
# Extracts the flat set of per-device hardware/OS fields exported to devices.csv. Kept as a shared
# helper (rather than inlined at the one call site) because it holds the single implementation of
# "which Hardware/Serial array entry counts as THE model/serial for display" - several vendors
# report those as arrays, and any future consumer needs to agree with the CSV.
function Get-MTAutoDrawDeviceInventoryRow {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Device)

    $hardware = if ($Device.Version -and $Device.Version.Hardware) {
        if ($Device.Version.Hardware -is [array]) { $Device.Version.Hardware[0] } else { $Device.Version.Hardware }
    }
    else { "" }
    $serial = if ($Device.Version -and $Device.Version.Serial) {
        if ($Device.Version.Serial -is [array]) { $Device.Version.Serial[0] } else { $Device.Version.Serial }
    }
    else { "" }
    # OS is normally the concise version string (e.g. "15.2(4)E7"); Image is a longer boot-image
    # filename some parsers only get, so it's a fallback rather than a separate column.
    $osOrImage = if ($Device.Version -and $Device.Version.OS) { $Device.Version.OS }
    elseif ($Device.Version -and $Device.Version.Image) { $Device.Version.Image }
    else { "" }
    $uptime = if ($Device.Version -and $Device.Version.Uptime) { $Device.Version.Uptime } else { "" }

    return [PSCustomObject]@{
        Hostname = $Device.HostName; DeviceType = [string]$Device.DeviceType
        Hardware = [string]$hardware; Serial = [string]$serial
        OSOrImage = [string]$osOrImage; Uptime = [string]$uptime
    }
}

# Normalises one CDP or LLDP neighbour into a flat export record.
function ConvertTo-MTAutoDrawNeighborExport {
    [CmdletBinding()]
    param($Neighbor, [string]$Protocol, [Parameter(Mandatory = $true)]$Devices)

    $partner = if ($Neighbor.PartnerEthernetInterface) { $Neighbor.PartnerEthernetInterface.Value } else { $null }
    $targetDevice = if ($partner) { $Devices | Where-Object { @($_.interfaces) -contains $partner } | Select-Object -First 1 } else { $null }
    $common = [ordered]@{
        Protocol = $Protocol
        InterfaceLocalDevice = $Neighbor.InterfaceLocalDevice
        TargetHostname = $targetDevice.hostname
        TargetInterface = $partner.Interface
        MatchConfidence = $Neighbor.MatchConfidence
        MatchMethod = $Neighbor.MatchMethod
        Ignored = [bool]$Neighbor.Ignored
        IgnoreReason = $Neighbor.IgnoreReason
    }
    if ($Protocol -eq 'CDP') {
        $common.DeviceID = $Neighbor.DeviceID; $common.SystemName = $Neighbor.SystemName
        $common.InterfaceRemoteDevice = $Neighbor.InterfaceRemoteDevice; $common.InterfaceAddress = $Neighbor.InterfaceAddress
        $common.Platform = $Neighbor.Platform; $common.InterfaceIPAddresses = @($Neighbor.InterfaceIPAddresses)
    } else {
        $common.Hostname = $Neighbor.Hostname; $common.ChassisID = $Neighbor.ChassisID
        $common.ChassisIDSubtype = $Neighbor.ChassisIDSubtype
        $common.InterfaceRemoteDevice = $Neighbor.InterfaceRemoteDevice
        $common.NeighborInterfaceDescription = $Neighbor.NeighborInterfaceDescription
        $common.ManagementIP = $Neighbor.ManagementIP; $common.PortID = $Neighbor.PortID
        $common.PortIDSubtype = $Neighbor.PortIDSubtype
    }
    return [pscustomobject]$common
}

# Flattens devices into a structured export model: normalised device records, neighbour links, and significant routes ready for CSV emission.
function ConvertTo-MTAutoDrawExportModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Devices,
        [Parameter(Mandatory = $true)][string]$SourceDirectory
    )

    $allDevices = @($Devices | Where-Object { $_ })

    $exportDevices = foreach ($device in @($allDevices | Sort-Object hostname, DeviceIdentifier)) {
        $version = if ($device.Version) {
            [ordered]@{
                OS = $device.Version.OS; Type = $device.Version.Type; Image = $device.Version.Image
                ROMMON = $device.Version.ROMMON; Uptime = $device.Version.Uptime
                ReasonForReload = $device.Version.ReasonForRelod
                Hardware = @($device.Version.Hardware); Serial = @($device.Version.Serial)
                MacAddresses = @($device.Version.MacAddressArray)
            }
        } else { $null }

        $interfaces = foreach ($interface in @($device.interfaces | Sort-Object Interface)) {
            [ordered]@{
                Interface = $interface.Interface; Description = $interface.Description
                IPAddress = $interface.IPAddress; SubnetMask = $interface.SubnetMask; Cidr = $interface.Cidr
                SecondaryIPAddress = $interface.SecondaryIPAddress; SecondarySubnetMask = $interface.SecondarySubnetMask
                SecondaryCidr = $interface.SecondaryCidr; VRF = $interface.vrf; Zone = $interface.Zone
                SwitchPortType = $interface.SwitchPortType; SwitchportMode = $interface.SwitchportMode
                SwitchportAccessVlan = $interface.SwitchportAccessVlan; SwitchportTrunkVlan = $interface.SwitchportTrunkVlan
                NativeVlan = $interface.NativeVlan; RoutedVlan = $interface.RoutedVlan
                Status = $interface.IntStatus; ProtocolStatus = $interface.INTProtocolStatus; Shutdown = $interface.shutdown
                MacAddress = $interface.macaddress; LearnedMacAddresses = @($interface.MacAddressArray)
                Speed = $interface.Speed; Duplex = $interface.Duplex; MediaType = $interface.MediaType
                ChannelGroup = $interface.ChannelGroup; ChannelGroupMode = $interface.ChannelGroupMode
                VPC = $interface.vpc; StandbyIP = @($interface.Standbyip); StandbyNumber = $interface.StandbyNumber
                StandbyPriority = $interface.StandbyPriority; ClusterIP = $interface.ClusterIP
                VDOM = $interface.VDOM; Mode = $interface.Mode; Role = $interface.Role; Alias = $interface.Alias
                AllowAccess = $interface.AllowAccess; FortiLink = $interface.FortiLink
            }
        }

        $networks = foreach ($network in @($device.ArrayOfNetworks | Sort-Object cidr, NetworkName)) {
            [ordered]@{
                Cidr = $network.cidr; RoutedVlan = $network.RoutedVlan; NetworkName = $network.NetworkName
                ArpEntries = @($network.ARPEntries | Select-Object PROTOCOL,ipaddress,AGE,MAC,TYPE,INTERFACE,VendorCompanyName,Cidr)
            }
        }

        $routes = @($device.RoutingTable | Sort-Object VRF, Subnet, gateway, interface | Select-Object RouteProtocol,RouteSubType,Subnet,gateway,defaultgateway,interface,GatewayCidr,VRF,DISTANCE,METRIC)
        $arpEntries = @($device.IPArpEntries | Sort-Object ipaddress, MAC | Select-Object PROTOCOL,ipaddress,AGE,MAC,TYPE,INTERFACE,VendorCompanyName,Cidr)
        $cdpNeighbors = @($device.CDPNeighbors | Sort-Object DeviceID, InterfaceLocalDevice | ForEach-Object { ConvertTo-MTAutoDrawNeighborExport -Neighbor $_ -Protocol CDP -Devices $allDevices })
        $lldpNeighbors = @($device.LLDPNeighbors | Sort-Object Hostname, InterfaceLocalDevice | ForEach-Object { ConvertTo-MTAutoDrawNeighborExport -Neighbor $_ -Protocol LLDP -Devices $allDevices })
        $bgpNeighbors = @($device.BGPNeighbors | Sort-Object VRF, NEIGHBOR | Select-Object NEIGHBOR,DESCRIPTION,SOURCE_IFACE,VRF,REMOTE_AS,LOCAL_AS,PEER_GROUP,REMOTE_ROUTER_ID,BGP_STATE,LOCALHOST_IP,LOCALHOST_PORT,REMOTE_IP,REMOTE_PORT,INBOUND_ROUTEMAP,OUTBOUND_ROUTEMAP,AdvertisedRoutes)

        $spanningTree = if ($device.SpanningTree) {
            [ordered]@{
                Mode = $device.SpanningTree.SpanningTreeMode
                ExtendedSystemId = $device.SpanningTree.SpanningTreeExtended
                RootBridgeForVlans = @($device.SpanningTree.RootBridgeForVlans)
                Instances = @($device.SpanningTree.SpanningTreeArray | Sort-Object VlanID | ForEach-Object {
                    [ordered]@{
                        VlanID = $_.VlanID; Protocol = $_.protocol; RootBridge = $_.RootBridge
                        RootIDPriority = $_.RootIDPriority; RootAddress = $_.Address
                        RootPort = $_.RootBridgePort; RootCost = $_.RootBridgeCost
                        BridgePriority = $_.BridgeIDPriority; BridgeAddress = $_.BridgeIDPriorityaddress
                        Interfaces = @($_.SpanningTreeInterfaces | Select-Object Interface,Role,Status,Cost,PrioNbr,Type)
                    }
                })
            }
        } else { $null }

        [ordered]@{
            DeviceIdentifier = $device.DeviceIdentifier; Hostname = $device.hostname
            DeviceType = $device.DeviceType; Platform = $device.Platform; Origin = $device.Origin
            Description = $device.Description; Version = $version
            Vlans = @($device.vlans | Sort-Object number | Select-Object number,name,description)
            VRFs = @($device.vrfs); Interfaces = @($interfaces); Networks = @($networks)
            IPAddresses = @($device.ArrayOfIPAddresses); Routes = $routes; ArpEntries = $arpEntries
            CDPNeighbors = $cdpNeighbors; LLDPNeighbors = $lldpNeighbors
            BGPASNumber = $device.BGP_AS_Number; BGPNeighbors = $bgpNeighbors
            SpanningTree = $spanningTree
            # Firewalls only, and empty for every other device type. Exported in full because the
            # firewall diagram pages summarize policy down to zone pairs and counts, and point here
            # for the per-rule detail they deliberately leave out - that pointer has to be true.
            SecurityPolicy = @($device.SecurityPolicy)
            NatPolicy = @($device.NatPolicy)
        }
    }

    return [ordered]@{
        SchemaVersion = '1.0'
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        SourceDirectory = [System.IO.Path]::GetFullPath($SourceDirectory)
        DeviceCount = @($exportDevices).Count
        Devices = @($exportDevices)
    }
}

# Routes that only restate a device's own directly-attached interfaces (connected/local/direct/host)
# say nothing about which OTHER device this one depends on, and they are the bulk of most routing
# tables. Same exclusion pattern StartProcessingConfig.ps1 already applies when attaching routes to
# an interface, kept identical on purpose so the connectivity view and the per-interface route
# lists agree about what counts as a real routed dependency.
$script:GMTAutoDrawLocalRouteProtocolPattern = 'connect|host|Access-internal|local|connected|direct'

# Case-insensitive EXACT match for the protocol strings the parsers emit for static routes.
# "static" is the majority, "Static" is the JunOS variant, and "Default gateway" is the Cisco
# IOS/NXOS fallback path. Anchored on purpose: a loose substring test would also match things like
# "statically resolved" if a parser ever emits a longer string, and that is not a protocol.
$script:GMTAutoDrawStaticRouteProtocolPattern = '^(?i:static|default gateway)$'

# Single source of truth for the route-protocol -> edge-colour mapping. Draw-Layer3RoutesOnlyDrawio's
# Get-Layer3RouteEdgePresentation calls this instead of inlining its own switch, as do the overview
# pages (Layer 3 Routes Summary and friends). The RoutesOnly branch of Draw-SinglesLayer3Drawio
# still carries its own hand-written copy - deliberately left alone so that unrelated page's output
# does not change.
#
# OSPF is standardized on yellow rgb(255,255,51) - the value 3 of the 4 existing occurrences used.
function Get-MTAutoDrawRouteProtocolColor {
    [CmdletBinding()]
    param([AllowNull()][string]$Protocol)

    $key = ([string]$Protocol).Trim()
    if ($key -eq '') { return '#000000' }

    # BGP variants (B, BGP, BGP-IBGP, BGP-EBGP, ...) all collapse to one colour.
    if ($key -ieq 'B' -or $key -clike 'BGP*') { return 'rgb(0,0,179)' }

    switch -case ($key) {
        'EIGRP'           { 'rgb(160,32,240)' }
        'OSPF'            { 'rgb(255,255,51)' }
        'Default gateway' { 'rgb(0,107,60)' }
        'RIP'             { 'rgb(179,89,0)' }
        'IS-IS'           { 'rgb(204,238,255)' }
        default {
            # "static" case-insensitively: the parsers emit "static" (most vendors) and "Static"
            # (JunOS) for the same fact, so a case-sensitive table would color JunOS edges black.
            # Mirrors the Get-Layer3RouteEdgePresentation normalization (-like "*static*").
            if ($key -like 'static') { 'rgb(0,107,60)' } else { '#000000' }
        }
    }
}

# Filters a device's routing table to significant routes: those with a real gateway, not a local protocol, and not a null/0.0.0.0 next-hop.
function Get-MTAutoDrawSignificantRoutes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$Device)

    return @($Device.RoutingTable | Where-Object {
        $_ -and $_.gateway -and
        $_.RouteProtocol -notmatch $script:GMTAutoDrawLocalRouteProtocolPattern -and
        # 0.0.0.0 as a NEXT HOP means "out this interface, no next hop" - it is not a device that
        # can be drawn as an upstream. (0.0.0.0/0 as a DESTINATION is the default route and is very
        # much wanted, which is why this tests gateway and not subnet.)
        ([string]$_.gateway) -ne '0.0.0.0' -and
        ([string]$_.gateway) -notmatch '^(?i)(?:null|none)'
    })
}

# Index of every IPv4 address that identifies a configured device, so a route's next hop can be
# resolved to the device that answers for it. Includes HSRP/VRRP standby addresses and Check Point
# cluster addresses: a redundant pair's downstream switches point at the virtual address, never at
# either member's real interface address, so without these the busiest gateway in the network
# resolves to nothing.
function New-MTAutoDrawGatewayIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Devices)

    $index = @{}
    foreach ($device in @($Devices | Where-Object { $_ })) {
        $hostname = [string]$device.hostname
        if (-not $hostname) { continue }
        foreach ($interface in @($device.interfaces | Where-Object { $_ })) {
            foreach ($address in @(Get-MTAutoDrawInterfaceIPv4Address -Interface $interface)) {
                if ($address.IPAddress -and -not $index.ContainsKey($address.IPAddress)) {
                    $index[$address.IPAddress] = $hostname
                }
            }
            foreach ($virtual in @(@($interface.Standbyip) + @($interface.ClusterIP))) {
                $value = [string]$virtual
                if ($value -match '^\d{1,3}(?:\.\d{1,3}){3}$' -and -not $index.ContainsKey($value)) {
                    $index[$value] = $hostname
                }
            }
        }
    }
    return $index
}

# ============================================================================
# routes.csv / layer3-interfaces.csv export builders
# ============================================================================

function Join-MTAutoDrawCsvValues {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()]$Values,
        [switch]$PreserveEmpty
    )

    $items = @($Values)
    if ($PreserveEmpty) {
        return (@($items | ForEach-Object {
            if ($null -eq $_) { '' } else { ([string]$_).Trim() }
        }) -join '; ')
    }

    $clean = @($items | Where-Object { $null -ne $_ } | ForEach-Object {
        ([string]$_).Trim()
    } | Where-Object { $_ -ne '' })
    if ($clean.Count -eq 0) { return '' }
    return ($clean -join '; ')
}

# Collapses any value to a single-line CSV-safe string (newlines -> spaces, trimmed). Returns '' for null/blank input.
function ConvertTo-MTAutoDrawCsvText {
    [CmdletBinding()]
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return (([string]$Value) -replace '[\r\n]+', ' ').Trim()
}

# Splits an IP address into its components (address, prefix, mask, CIDR) accepting 'ip/prefix', mask, or CIDR forms and normalising them.
function Get-MTAutoDrawIPv4AddressParts {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Address,
        [AllowNull()][string]$Prefix,
        [AllowNull()][string]$Mask,
        [AllowNull()][string]$Cidr
    )

    if ([string]::IsNullOrWhiteSpace($Address)) { return $null }
    $addressValue = $Address.Trim()
    $prefixValue = ([string]$Prefix).Trim()
    $maskValue = ([string]$Mask).Trim()
    $cidrValue = ([string]$Cidr).Trim()

    if ($addressValue -match '^(?<ip>\d{1,3}(?:\.\d{1,3}){3})/(?<prefix>\d{1,2})$') {
        $addressValue = $Matches['ip']
        if (-not $prefixValue) { $prefixValue = $Matches['prefix'] }
    }
    if (-not $prefixValue -and $maskValue -match '^\d{1,2}$') {
        $prefixValue = $maskValue
    }
    if (-not $prefixValue -and $cidrValue -match '/(?<prefix>\d{1,2})$') {
        $prefixValue = $Matches['prefix']
    }

    $normalized = $null
    if ($prefixValue -match '^\d{1,2}$' -and [int]$prefixValue -ge 0 -and [int]$prefixValue -le 32) {
        $normalized = Get-NormalizedIPv4Cidr -IPAddress $addressValue -PrefixLength $prefixValue
    }
    elseif ($maskValue -match '^\d{1,3}(?:\.\d{1,3}){3}$') {
        $normalized = Get-NormalizedIPv4Cidr -IPAddress $addressValue -SubnetMask $maskValue
    }

    if ($normalized) {
        return [pscustomobject][ordered]@{
            IPAddress    = [string]$normalized.IPAddress
            PrefixLength = [string]$normalized.PrefixLength
            SubnetMask   = [string]$normalized.SubnetMask
            Cidr         = [string]$normalized.Cidr
        }
    }

    return [pscustomobject][ordered]@{
        IPAddress    = $addressValue
        PrefixLength = $prefixValue
        SubnetMask   = $maskValue
        Cidr         = $cidrValue
    }
}

# Interprets an interface/admin status string and returns $true when up, $false when down, or $null when indeterminate. Handles vendor-specific phrasing.
function Get-MTAutoDrawStatusIsUp {
    [CmdletBinding()]
    param([AllowNull()][string]$Status)

    $value = ([string]$Status).Trim()
    if (-not $value) { return $null }

    # Test negative states first because values such as "not connected" also contain
    # the positive token "connected".
    if ($value -match '(?i)(administratively\s+down|admin(?:istrative)?\s+down|not[ -]?connect(?:ed)?|not\s+present|xcvrabsen|err(?:-disabled)?|disabled|absent|lowerlayerdown|\bdown\b)') {
        return $false
    }
    if ($value -match '(?i)(\bup\b|\bconnected\b)') { return $true }
    return $null
}

# Builds a gateway-address -> devices/index lookup across all devices, mapping each IP to the device + interface that owns it.
function New-MTAutoDrawGatewayAddressIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Devices)

    $index = @{}
    $seen = @{}
    foreach ($device in @($Devices | Where-Object { $_ })) {
        $hostname = [string]$device.hostname
        if (-not $hostname) { continue }
        foreach ($interface in @($device.interfaces | Where-Object { $_ })) {
            $interfaceName = [string]$interface.Interface
            $addAddress = {
                param([AllowNull()][string]$Address, [string]$AddressType)

                $addressValue = ([string]$Address).Trim()
                if ($addressValue -notmatch '^\d{1,3}(?:\.\d{1,3}){3}$') { return }
                $recordKey = '{0}|{1}|{2}|{3}|{4}' -f $addressValue, $hostname, $device.DeviceIdentifier, $interfaceName, $AddressType
                if ($seen.ContainsKey($recordKey)) { return }
                $seen[$recordKey] = $true
                if (-not $index.ContainsKey($addressValue)) {
                    $index[$addressValue] = [System.Collections.Generic.List[object]]::new()
                }
                $index[$addressValue].Add([pscustomobject]@{
                    Hostname = $hostname
                    DeviceIdentifier = [string]$device.DeviceIdentifier
                    Interface = $interfaceName
                    AddressType = $AddressType
                })
            }

            foreach ($address in @(Get-MTAutoDrawInterfaceIPv4Address -Interface $interface)) {
                & $addAddress ([string]$address.IPAddress) ([string]$address.AddressType)
            }
            foreach ($address in @($interface.Standbyip | Where-Object { $_ })) {
                & $addAddress ([string]$address) 'Standby'
            }
            foreach ($address in @($interface.ClusterIP | Where-Object { $_ })) {
                & $addAddress ([string]$address) 'Cluster'
            }
        }
    }
    return $index
}

# Returns the ordered list of column names for the routes CSV export.
function Get-MTAutoDrawRouteExportColumns {
    [CmdletBinding()]
    param()

    return @(
        'SourceHostname','SourceDeviceIdentifier','SourceDeviceType','SourceManagementIP',
        'VRF','RouteProtocol','RouteSubType','DestinationSubnet','IsDefaultRoute','IsConnectedOrLocal',
        'NextHopAddress','EgressInterface','GatewayCidr','AdministrativeDistance','Metric',
        'NextHopResolution','NextHopHostnames','NextHopDeviceIdentifiers','NextHopInterfaces','NextHopOrigin','NextHopMatchCount'
    )
}

# Returns the ordered list of column names for the Layer-3 interfaces CSV export.
function Get-MTAutoDrawLayer3InterfaceExportColumns {
    [CmdletBinding()]
    param()

    return @(
        'Hostname','DeviceIdentifier','DeviceType','ManagementIP','Interface','Description','VRF','Zone','RoutedVlan','SwitchPortType',
        'IPAddress','PrefixLength','SubnetMask','Cidr',
        'SecondaryIPAddress','SecondaryPrefixLength','SecondarySubnetMask','SecondaryCidr',
        'StandbyIP','ClusterIP',
        'Shutdown','AdminState','InterfaceStatusRaw','ProtocolStatusRaw','ConnectionState','ProtocolState'
    )
}

# Builds the list of route export rows across all devices, resolving next-hop gateways against the gateway index and external gateway hosts.
function Get-MTAutoDrawRouteExportRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Devices,
        [AllowNull()]$GatewayHosts = @()
    )

    $allDevices = @($Devices | Where-Object { $_ })
    $gatewayAddressIndex = New-MTAutoDrawGatewayAddressIndex -Devices $allDevices
    $externalGatewayIndex = @{}
    foreach ($gatewayHost in @($GatewayHosts | Where-Object { $_ })) {
        foreach ($address in @($gatewayHost.ArrayOfIPAddresses | Where-Object { $_ })) {
            $addressValue = ([string]$address).Trim()
            if (-not $addressValue) { continue }
            if (-not $externalGatewayIndex.ContainsKey($addressValue)) {
                $externalGatewayIndex[$addressValue] = [System.Collections.Generic.List[object]]::new()
            }
            $externalGatewayIndex[$addressValue].Add($gatewayHost)
        }
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($device in $allDevices) {
        foreach ($route in @($device.RoutingTable | Where-Object { $_ })) {
            $protocol = [string]$route.RouteProtocol
            $destination = [string]$route.Subnet
            $gateway = ([string]$route.gateway).Trim()
            $isDefault = [bool]$route.defaultgateway -or $destination -match '^0\.0\.0\.0(?:/0)?$'
            $isConnectedOrLocal = [bool]($protocol -match $script:GMTAutoDrawLocalRouteProtocolPattern)
            $isPlaceholder = -not $gateway -or $gateway -eq '0.0.0.0' -or $gateway -match '^(?i:null|none)$'

            $resolution = $null
            $nextHopHostnames = @()
            $nextHopDeviceIdentifiers = @()
            $nextHopInterfaces = @()
            $nextHopOrigin = $null
            $nextHopMatchCount = 0

            if ($isConnectedOrLocal) {
                $resolution = 'ConnectedLocal'
            }
            elseif ($isPlaceholder) {
                $resolution = 'InterfaceOnly'
            }
            elseif ($gatewayAddressIndex.ContainsKey($gateway)) {
                $matches = @($gatewayAddressIndex[$gateway])
                $nextHopHostnames = @($matches | Select-Object -ExpandProperty Hostname | Where-Object { $_ } | Sort-Object -Unique)
                $nextHopDeviceIdentifiers = @($matches | Select-Object -ExpandProperty DeviceIdentifier | Where-Object { $_ } | Sort-Object -Unique)
                $nextHopInterfaces = @($matches | ForEach-Object {
                    if ($_.Interface) { '{0}/{1}' -f $_.Hostname, $_.Interface } else { $_.Hostname }
                } | Where-Object { $_ } | Sort-Object -Unique)
                $resolution = 'CapturedDevice'
                $nextHopOrigin = 'device-interface'
                $nextHopMatchCount = $matches.Count
            }
            elseif ($externalGatewayIndex.ContainsKey($gateway)) {
                $matches = @($externalGatewayIndex[$gateway])
                $arpMatches = @($matches | Where-Object { [string]$_.Origin -eq 'ARP' })
                $selectedMatches = if ($arpMatches.Count -gt 0) { $arpMatches } else { $matches }
                $nextHopHostnames = @($selectedMatches | ForEach-Object { [string]$_.hostname } | Where-Object { $_ } | Sort-Object -Unique)
                $nextHopInterfaces = @($selectedMatches | ForEach-Object {
                    $gatewayHostname = [string]$_.hostname
                    foreach ($gatewayInterface in @($_.interfaces | Where-Object { $_ })) {
                        if ($gatewayInterface.Interface) { '{0}/{1}' -f $gatewayHostname, $gatewayInterface.Interface } else { $gatewayHostname }
                    }
                } | Where-Object { $_ } | Sort-Object -Unique)
                $nextHopMatchCount = $selectedMatches.Count
                if ($arpMatches.Count -gt 0) {
                    $resolution = 'ARPExternal'
                    $nextHopOrigin = 'arp'
                }
                else {
                    $resolution = 'UnresolvedExternal'
                    $nextHopOrigin = 'routing-table-placeholder'
                }
            }
            else {
                $resolution = 'UnresolvedExternal'
                $nextHopOrigin = 'unresolved'
            }

            $rows.Add([pscustomobject][ordered]@{
                SourceHostname           = ConvertTo-MTAutoDrawCsvText -Value ([string]$device.hostname)
                SourceDeviceIdentifier   = [string]$device.DeviceIdentifier
                SourceDeviceType         = [string]$device.DeviceType
                SourceManagementIP       = [string]$device.ManagementIP
                VRF                      = [string]$route.VRF
                RouteProtocol            = $protocol
                RouteSubType             = [string]$route.RouteSubType
                DestinationSubnet        = $destination
                IsDefaultRoute           = $isDefault
                IsConnectedOrLocal       = $isConnectedOrLocal
                NextHopAddress           = $gateway
                EgressInterface          = [string]$route.interface
                GatewayCidr              = [string]$route.GatewayCidr
                AdministrativeDistance   = if ($null -eq $route.DISTANCE) { '' } else { [string]$route.DISTANCE }
                Metric                   = if ($null -eq $route.METRIC) { '' } else { [string]$route.METRIC }
                NextHopResolution        = $resolution
                NextHopHostnames         = ConvertTo-MTAutoDrawCsvText -Value (Join-MTAutoDrawCsvValues -Values $nextHopHostnames)
                NextHopDeviceIdentifiers = ConvertTo-MTAutoDrawCsvText -Value (Join-MTAutoDrawCsvValues -Values $nextHopDeviceIdentifiers)
                NextHopInterfaces        = ConvertTo-MTAutoDrawCsvText -Value (Join-MTAutoDrawCsvValues -Values $nextHopInterfaces)
                NextHopOrigin            = $nextHopOrigin
                NextHopMatchCount        = $nextHopMatchCount
            })
        }
    }

    return @($rows | Sort-Object SourceHostname,VRF,DestinationSubnet,RouteProtocol,NextHopAddress,EgressInterface)
}

# Builds the list of Layer-3 interface export rows across all devices, including routed ports and those with any configured address.
function Get-MTAutoDrawLayer3InterfaceExportRows {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Devices)

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($device in @($Devices | Where-Object { $_ })) {
        foreach ($interface in @($device.interfaces | Where-Object { $_ })) {
            $switchPortType = ([string]$interface.SwitchPortType).Trim()
            $isRouted = $switchPortType -match '^(?i:routed)$'
            $secondaryAddresses = @($interface.SecondaryIPAddress)
            $secondaryMasks = @($interface.SecondarySubnetMask)
            $secondaryCidrs = @($interface.SecondaryCidr)
            $hasSecondary = @($secondaryAddresses | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0
            $hasAddress = -not [string]::IsNullOrWhiteSpace([string]$interface.IPAddress) -or
                -not [string]::IsNullOrWhiteSpace([string]$interface.Cidr) -or $hasSecondary -or
                @($interface.Standbyip | Where-Object { $_ }).Count -gt 0 -or
                @($interface.ClusterIP | Where-Object { $_ }).Count -gt 0
            if (-not ($isRouted -or $hasAddress)) { continue }

            $primaryParts = $null
            if (-not [string]::IsNullOrWhiteSpace([string]$interface.IPAddress)) {
                $primaryParts = Get-MTAutoDrawIPv4AddressParts -Address ([string]$interface.IPAddress) `
                    -Mask ([string]$interface.SubnetMask) -Cidr ([string]$interface.Cidr)
            }

            $secondaryIpCells = [System.Collections.Generic.List[string]]::new()
            $secondaryPrefixCells = [System.Collections.Generic.List[string]]::new()
            $secondaryMaskCells = [System.Collections.Generic.List[string]]::new()
            $secondaryCidrCells = [System.Collections.Generic.List[string]]::new()
            for ($index = 0; $index -lt $secondaryAddresses.Count; $index++) {
                $address = ([string]$secondaryAddresses[$index]).Trim()
                if (-not $address) { continue }
                $mask = if ($index -lt $secondaryMasks.Count) { [string]$secondaryMasks[$index] } else { '' }
                $cidr = if ($index -lt $secondaryCidrs.Count) { [string]$secondaryCidrs[$index] } else { '' }
                $parts = Get-MTAutoDrawIPv4AddressParts -Address $address -Mask $mask -Cidr $cidr
                $secondaryIpCells.Add([string]$parts.IPAddress)
                $secondaryPrefixCells.Add([string]$parts.PrefixLength)
                $secondaryMaskCells.Add([string]$parts.SubnetMask)
                $secondaryCidrCells.Add([string]$parts.Cidr)
            }

            $shutdown = $interface.shutdown
            $adminState = if ($shutdown -eq $true) { 'Down' } elseif ($shutdown -eq $false) { 'Up' } else { 'Unknown' }
            $interfaceIsUp = Get-MTAutoDrawStatusIsUp -Status ([string]$interface.IntStatus)
            $protocolIsUp = Get-MTAutoDrawStatusIsUp -Status ([string]$interface.INTProtocolStatus)
            $connectionState = if ($shutdown -eq $true) { 'NotConnected' } elseif ($null -eq $interfaceIsUp) { 'Unknown' } elseif ($interfaceIsUp) { 'Connected' } else { 'NotConnected' }
            $protocolState = if ($null -eq $protocolIsUp) { 'Unknown' } elseif ($protocolIsUp) { 'Up' } else { 'Down' }

            $rows.Add([pscustomobject][ordered]@{
                Hostname              = ConvertTo-MTAutoDrawCsvText -Value ([string]$device.hostname)
                DeviceIdentifier      = [string]$device.DeviceIdentifier
                DeviceType            = [string]$device.DeviceType
                ManagementIP          = [string]$device.ManagementIP
                Interface             = ConvertTo-MTAutoDrawCsvText -Value ([string]$interface.Interface)
                Description           = ConvertTo-MTAutoDrawCsvText -Value ([string]$interface.Description)
                VRF                   = [string]$interface.vrf
                Zone                  = ConvertTo-MTAutoDrawCsvText -Value ([string]$interface.Zone)
                RoutedVlan            = [string]$interface.RoutedVlan
                SwitchPortType        = $switchPortType
                IPAddress             = if ($primaryParts) { [string]$primaryParts.IPAddress } else { '' }
                PrefixLength          = if ($primaryParts) { [string]$primaryParts.PrefixLength } else { '' }
                SubnetMask            = if ($primaryParts) { [string]$primaryParts.SubnetMask } else { '' }
                Cidr                  = if ($primaryParts -and $primaryParts.Cidr) { [string]$primaryParts.Cidr } else { [string]$interface.Cidr }
                SecondaryIPAddress    = Join-MTAutoDrawCsvValues -Values $secondaryIpCells -PreserveEmpty
                SecondaryPrefixLength = Join-MTAutoDrawCsvValues -Values $secondaryPrefixCells -PreserveEmpty
                SecondarySubnetMask   = Join-MTAutoDrawCsvValues -Values $secondaryMaskCells -PreserveEmpty
                SecondaryCidr         = Join-MTAutoDrawCsvValues -Values $secondaryCidrCells -PreserveEmpty
                StandbyIP             = Join-MTAutoDrawCsvValues -Values @($interface.Standbyip)
                ClusterIP             = Join-MTAutoDrawCsvValues -Values @($interface.ClusterIP)
                Shutdown              = if ($shutdown -eq $true) { $true } elseif ($shutdown -eq $false) { $false } else { '' }
                AdminState            = $adminState
                InterfaceStatusRaw    = ConvertTo-MTAutoDrawCsvText -Value ([string]$interface.IntStatus)
                ProtocolStatusRaw     = ConvertTo-MTAutoDrawCsvText -Value ([string]$interface.INTProtocolStatus)
                ConnectionState       = $connectionState
                ProtocolState         = $protocolState
            })
        }
    }

    return @($rows | Sort-Object Hostname,DeviceIdentifier,Interface)
}

# Writes rows to a CSV at $Path with the supplied columns. When there are no rows, writes a header-only file so the column schema is preserved.
function Export-MTAutoDrawCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Columns,
        [AllowNull()][AllowEmptyCollection()]$Rows
    )

    $data = @($Rows | Where-Object { $_ })
    if ($data.Count -gt 0) {
        $data | Select-Object -Property $Columns | Export-Csv -LiteralPath $Path -NoTypeInformation
        return
    }

    $headerObject = [ordered]@{}
    foreach ($column in $Columns) { $headerObject[$column] = $null }
    $header = @([pscustomobject]$headerObject | ConvertTo-Csv -NoTypeInformation)[0]
    Set-Content -LiteralPath $Path -Value $header -Encoding utf8
}
