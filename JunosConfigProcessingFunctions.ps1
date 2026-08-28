# MTAutoDraw-Standard: v1
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

# This file contains all of the functions that process Junos config.
#
# Junos captures are XML ("| display xml"), not text, so every reader reads through
# Get-JunosXmlDocument; this platform uses no TextFSM template at all.
#
# Follows PARSER_STANDARD.md v1.


# --- Orchestrator ---------------------------------------------------------------------------------

function Process-JunosHostFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$HostID,
        $ArrayOfObjects   # Kept for dispatcher signature compatibility; duplicate detection is sequential.
    )

    # 1. IDENTITY - the configuration is the only capture carrying the hostname, and it is also where
    # the interfaces and VLANs come from, so nothing else can run without it.
    $device = New-MTAutoDrawDevice -Platform 'Junos' -HostID $HostID
    Update-JunosRunningConfig -Device $device -Path $HostID.ShowRun
    if (-not $device.hostname) {
        Write-MTAutoDrawDiagnostic -Device $device -Severity Warning -Message "Junos '$($HostID.HOSTID)' has no usable configuration capture; skipping host."
        return $null
    }

    # 2. CAPTURES - one line per slot, in dependency order. The configuration already created the
    # interfaces, so every reader below merges onto them.
    Update-JunosVersion               -Device $device -Path $HostID.ShowVersion
    Update-JunosInterfaces            -Device $device -Path $HostID.ShowInterfaceTerse
    Update-JunosLldpNeighbors         -Device $device -Path $HostID.ShowLLDPNeighbors
    Update-JunosRoutes                -Device $device -Path $HostID.ShowRouteAll
    Update-JunosSpanningTreeInterface -Device $device -Path $HostID.ShowSpanningTreeInterface
    Update-JunosSpanningTreeBridge    -Device $device -Path $HostID.JunosShowSpanningTreeBridgeFromXML
    Update-JunosArp                   -Device $device -Path $HostID.ShowArp
    Update-JunosMacAddressTable       -Device $device -Path $HostID.ShowEthernetSwitchingTable

    # 3. RECONCILE
    return (Complete-MTAutoDrawDevice -Device $device)
}


#Extract all the information from the show version all xml file
function Update-JunosVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowVersion')) { return }

    # --- EXTRACT / MAP / MERGE ---
    $ShowVersion = Get-JunosXmlDocument -Path $Path
    $VersionObject=Create-ShowVersionObject
    $VersionObject.Hostname =  $ShowVersion.'rpc-reply'.'multi-routing-engine-results'.'multi-routing-engine-item'.'software-information'.'host-name'
    $VersionObject.Hardware =  $ShowVersion.'rpc-reply'.'multi-routing-engine-results'.'multi-routing-engine-item'.'software-information'.'product-model'

    $device.Version=$VersionObject

}



# Parses Junos 'show lldp neighbors' XML output into the device's LLDP neighbour objects. Logs a warning and returns the device unchanged if the XML cannot be parsed.
function Update-JunosLldpNeighbors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowLLDPNeighbors')) { return }

    # --- EXTRACT ---
    try {
        $Neighbors = Get-JunosXmlDocument -Path $Path
    } catch {
        Write-MTAutoDrawDiagnostic -Device $Device -Severity Warning -Message "Could not parse XML file: $Path"
        return
    }

    $AllLLDPDetailsObjects=@()
    foreach ($Neighbor in ($Neighbors.'rpc-reply'.'lldp-neighbors-information'.'lldp-neighbor-information')){
        $LLDPObject=Create-LLDPNeighborObject
        $LLDPObject.ParentObject=$device.hostname

        if($Neighbor.'lldp-remote-system-name'){
            $LLDPObject.Hostname=$Neighbor.'lldp-remote-system-name'
        }else{
            $LLDPObject.Hostname=$Neighbor.'lldp-remote-chassis-id'
        }

        if($Neighbor.'lldp-local-interface'){
            $LLDPObject.InterfaceLocalDevice=($Neighbor.'lldp-local-interface' -replace "\.0$",'')
        }elseif($Neighbor.'lldp-local-port-id'){
            $LLDPObject.InterfaceLocalDevice=($Neighbor.'lldp-local-port-id' -replace "\.0$",'')
        }else{
            $LLDPObject.InterfaceLocalDevice=$null
        }

        $LLDPObject.ChassisID=$Neighbor.'lldp-remote-chassis-id'
        $LLDPObject.ChassisIDSubtype=$Neighbor.'lldp-remote-chassis-id-subtype'
        $LLDPObject.PortIDSubtype=$Neighbor.'lldp-remote-port-id-subtype'

        $remotePortId = ([string]$Neighbor.'lldp-remote-port-id').Trim()
        $remotePortDesc = ([string]$Neighbor.'lldp-remote-port-description').Trim()
        $LLDPObject.PortID = if ($remotePortId) { $remotePortId } else { $null }
        $LLDPObject.NeighborInterfaceDescription = $remotePortDesc

        # A remote port ID is not necessarily an interface name. Junos brief XML commonly
        # advertises it as a MAC address. Interface-name subtypes are semantic interfaces;
        # locally-assigned values are accepted only when they look like an interface.
        $portIdSubtype = ([string]$LLDPObject.PortIDSubtype).Trim()
        $portIdIsInterface = $false
        if ($portIdSubtype -match '(?i)interface') {
            $portIdIsInterface = $true
        }
        elseif ($portIdSubtype -match '(?i)local' -and $remotePortId -and (Check-InterfaceType -string $remotePortId)) {
            $portIdIsInterface = $true
        }
        elseif (-not $portIdSubtype -and $remotePortId -and (Check-InterfaceType -string $remotePortId)) {
            $portIdIsInterface = $true
        }

        if ($portIdIsInterface -and $remotePortId) {
            $LLDPObject.InterfaceRemoteDevice = $remotePortId
        }
        elseif ($remotePortDesc -and (Check-InterfaceType -string $remotePortDesc)) {
            $LLDPObject.InterfaceRemoteDevice = $remotePortDesc
        }
        else {
            $LLDPObject.InterfaceRemoteDevice = $null
        }

        # Clean up common Juniper ".0" suffix from the name
        if($LLDPObject.InterfaceRemoteDevice -match "\.0$"){
            $LLDPObject.InterfaceRemoteDevice=$LLDPObject.InterfaceRemoteDevice -replace "\.0$",''
        }

        $TempInterface=$device.interfaces | where { $_.interface -eq $LLDPObject.InterfaceLocalDevice}
        if($TempInterface) {
             $TempInterface.HasLLDPNeighbor = $true
        }

        $AllLLDPDetailsObjects+=$LLDPObject
    }

    # Do not mutate duplicate remote interface names. The record tuple of local port,
    # chassis ID, raw port ID, and system name already distinguishes LLDP observations.

    $device.LLDPNeighbors=$AllLLDPDetailsObjects | sort -property @{Expression={[int]($_.InterfaceLocalDevice -replace '[a-zA-Z-]+','' -replace "/",'')}}
}











# Parses Junos 'show spanning-tree bridge' XML into the device's spanning-tree object (per-VLAN root bridges, priorities), and records when STP is not enabled at global level.
function Update-JunosSpanningTreeBridge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'JunosShowSpanningTreeBridgeFromXML')) { return }

    $FunctionName = "Update-JunosSpanningTreeBridge"

    # --- EXTRACT ---
    $SpanningTreeXml = Get-JunosXmlDocument -Path $Path

    # Check for the specific "not enabled" output.
    $disabledMessage = $SpanningTreeXml.SelectSingleNode("/rpc-reply/output[text()='Spanning-tree is not enabled at global level.']")
    if ($null -ne $disabledMessage) {
        # Create a new SpanningTree object and mark it as disabled.
        $device.SpanningTree = Create-SpanningTreeObject
        $device.SpanningTree.SpanningTreeMode = "SpanningTree Disabled"
        return
    }

    $namespaceManager = [System.Xml.XmlNamespaceManager]::new($SpanningTreeXml.NameTable)
    $stpNode = $SpanningTreeXml.SelectSingleNode("//*[local-name()='stp-bridge']")

    if ($null -eq $stpNode) {
        # This catch-all handles any other XML format where stp-bridge is not present.
        $device.SpanningTree = Create-SpanningTreeObject
        $device.SpanningTree.SpanningTreeMode = "SpanningTree NotPresent"
        return
    }


    $namespaceURI = $stpNode.NamespaceURI
    $namespaceManager.AddNamespace("j", $namespaceURI)

    $device.SpanningTree = Create-SpanningTreeObject

    $cistParams = $stpNode.SelectSingleNode("j:cist-bridge-parameters", $namespaceManager)

    # Safely get node values
    $protocolNode = $stpNode.SelectSingleNode("j:protocol", $namespaceManager)
    $extendedIdNode = $cistParams.SelectSingleNode("j:extended-system-id", $namespaceManager)
    $rootMacNode = $cistParams.SelectSingleNode("j:root-bridge/j:bridge-mac", $namespaceManager)
    $thisMacNode = $cistParams.SelectSingleNode("j:this-bridge/j:bridge-mac", $namespaceManager)

    $device.SpanningTree.SpanningTreeMode = if ($protocolNode) { $protocolNode.'#text' } else { 'N/A' }
    $device.SpanningTree.SpanningTreeExtended = if ($extendedIdNode -and $extendedIdNode.'#text' -ne "0") { $true } else { $false }

    $rootMac = if ($rootMacNode) { $rootMacNode.'#text' } else { '' }
    $thisMac = if ($thisMacNode) { $thisMacNode.'#text' } else { '' }
    $isRootBridge = ($rootMac -eq $thisMac -and $rootMac -ne '')


    foreach ($vlan in $device.vlans) {
        $stpVlanObject = Create-SpanningTreeVlan

        $stpVlanObject.VlanID = $vlan.number
        $stpVlanObject.protocol = $device.SpanningTree.SpanningTreeMode
        $stpVlanObject.RootBridge = $isRootBridge

        # Safely get node values for the loop
        $rootPriorityNode = $cistParams.SelectSingleNode("j:root-bridge/j:bridge-priority", $namespaceManager)
        $helloTimeNode = $cistParams.SelectSingleNode("j:hello-time-learned", $namespaceManager)
        $maxAgeNode = $cistParams.SelectSingleNode("j:max-age-learned", $namespaceManager)
        $bridgePriorityNode = $cistParams.SelectSingleNode("j:this-bridge/j:bridge-priority", $namespaceManager)

        # --- Root Bridge Information ---
        $stpVlanObject.RootIDPriority = if ($rootPriorityNode) { $rootPriorityNode.'#text' } else { 'N/A' }
        $stpVlanObject.Address = ConvertTo-NormalizedMacAddress $rootMac
        $stpVlanObject.RootBridgeHelloTime = if ($helloTimeNode) { $helloTimeNode.'#text' } else { 'N/A' }
        $stpVlanObject.RootBridgeAgingTime = if ($maxAgeNode) { $maxAgeNode.'#text' } else { 'N/A' }

        # --- Local Bridge Information ---
        $stpVlanObject.BridgeIDPriority = if ($bridgePriorityNode) { $bridgePriorityNode.'#text' } else { 'N/A' }
        $stpVlanObject.BridgeIDPriorityaddress = ConvertTo-NormalizedMacAddress $thisMac

        if (-not $isRootBridge) {
            $rootCostNode = $cistParams.SelectSingleNode("j:root-cost", $namespaceManager)
            $rootPortNode = $cistParams.SelectSingleNode("j:root-port", $namespaceManager)

            $stpVlanObject.RootBridgeCost = if ($rootCostNode) { $rootCostNode.'#text' } else { '0' }
            $stpVlanObject.RootBridgePort = if ($rootPortNode) { $rootPortNode.'#text' } else { 'N/A' }
            $stpVlanObject.port = $stpVlanObject.RootBridgePort
        }

        $device.SpanningTree.SpanningTreeArray += $stpVlanObject
    }

    $device.SpanningTree.RootBridgeForVlans = $device.SpanningTree.SpanningTreeArray | Where-Object { $_.RootBridge -eq $true } | Select-Object -ExpandProperty VlanID
}



# Parses Junos 'show spanning-tree interface' XML to attach per-interface STP state (port role, cost) onto the device's interface objects.
function Update-JunosSpanningTreeInterface {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowSpanningTreeInterface')) { return }

    # --- EXTRACT ---
    $SpanningTreeInterfacesXml = Get-JunosXmlDocument -Path $Path

    if ($device.interfaces -and $SpanningTreeInterfacesXml.'rpc-reply'.'stp-interface-information'.'stp-instance'.'stp-interfaces'.'stp-interface-entry') {

        $stpInterfaceEntries = $SpanningTreeInterfacesXml.'rpc-reply'.'stp-interface-information'.'stp-instance'.'stp-interfaces'.'stp-interface-entry'

        # Loop through each interface object directly on the $device
        foreach ($currentDeviceInterface in $device.interfaces) {
            # Check if the interface is part of a ChannelGroup
            if ($currentDeviceInterface.ChannelGroup) {
                $searchInterfaceName = $currentDeviceInterface.ChannelGroup  -replace "\.0$"
            } else {
                $searchInterfaceName = $currentDeviceInterface.Interface -replace "\.0$"
            }

            # Find the matching STP entry from the XML data
            $matchingStpEntry = $stpInterfaceEntries | Where-Object {
                ($_.'interface-name' -eq $searchInterfaceName)
            }

            if ($matchingStpEntry) {
                # Add debug logging for each interface search

                # Update the Spanning Tree Role property directly on the $currentDeviceInterface
                switch ($matchingStpEntry.'port-role') {
                    'ROOT' { $currentDeviceInterface.STRole = 'Root' }
                    'ALT' { $currentDeviceInterface.STRole = 'ALT' }
                    'DESG' { $currentDeviceInterface.STRole = 'DESG' }
                    'BACKUP' { $currentDeviceInterface.STRole = 'BACKUP' }
                    'BKUP' { $currentDeviceInterface.STRole = 'BACKUP' }
                    'DIS' { $currentDeviceInterface.STRole = 'DIS' }
                    default { $currentDeviceInterface.STRole = 'UNKNOWN' }
                }

                # Update the Spanning Tree State property directly on the $currentDeviceInterface
                switch ($matchingStpEntry.'port-state') {
                    'FWD' { $currentDeviceInterface.STState = 'FWD' }
                    'LEARN' { $currentDeviceInterface.STState = 'LEARN' }
                    'BLK' { $currentDeviceInterface.STState = 'BLK' }
                    default { $currentDeviceInterface.STState = 'UNKNOWN' }
                }
            }
        }
    }

}


# UPDATED FUNCTION
function Update-JunosRoutes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowRouteAll')) { return }

    $routeObjects = [System.Collections.Generic.List[pscustomobject]]::new()

    # --- EXTRACT ---
    try {
        $xmlContent = Get-JunosXmlDocument -Path $Path
    }
    catch {
        Write-MTAutoDrawDiagnostic -Device $Device -Severity Warning -Message "Failed to parse '$Path' as XML. It might be a plain text file or corrupted. Skipping."
        return
    }

    $namespaceUri = $xmlContent.DocumentElement.'route-information'.NamespaceURI
    if (-not $namespaceUri) {
        Write-MTAutoDrawDiagnostic -Device $Device -Severity Warning -Message "Could not detect a Junos routing namespace in '$Path'. Skipping."
        return
    }

    $namespace = @{ jrt = $namespaceUri }
    $routeEntries = Select-Xml -Xml $xmlContent -XPath "//jrt:rt" -Namespace $namespace

    foreach ($entry in $routeEntries) {
        $routeNode = $entry.Node
        $routingTableName = $routeNode.ParentNode.'table-name'

        foreach ($nextHop in $routeNode.'rt-entry') {
            $routeObject = Create-RouteObject
            $routeObject.VRF = $routingTableName
            $routeObject.Subnet = $routeNode.'rt-destination'
            $routeObject.RouteProtocol = $nextHop.'protocol-name'


            if ($nextHop.preference) {
                $routeObject.DISTANCE = [int]$nextHop.preference
            }

            if ($nextHop.metric) {
                $routeObject.METRIC = [int]$nextHop.metric
            }

            if ($routeObject.Subnet -eq '0.0.0.0/0') {
                $routeObject.defaultgateway = $true
            }

            if ($null -ne $nextHop.nh) {
                if ($nextHop.nh.to) {
                    $routeObject.Gateway = $nextHop.nh.to
                }
                if ($nextHop.nh.via) {
                    $routeObject.Interface = $nextHop.nh.via -replace "vlan\.", 'vlan' -replace "irb\.", 'irb' -replace "\.0$", ''
                }
                elseif ($nextHop.nh.'nh-local-interface') {
                    $routeObject.Interface = $nextHop.nh.'nh-local-interface'
                }
            }

            # Interface lookup applies only to gateway-bearing routes such as static, BGP, and OSPF.
            $localProtocolsForGatewaySearch = @('Receive', 'Aggregate') # Protocols that can have gateways but we might still want to skip the search for.
            if ($routeObject.Gateway -and $device.interfaces -and ($localProtocolsForGatewaySearch -notcontains $routeObject.RouteProtocol)) {

                foreach ($interface in $device.interfaces) {
                    if ($interface.Cidr -and (Find-Subnet -addr1 $interface.Cidr -addr2 $routeObject.Gateway).condition) {
                        $routeObject.GatewayCidr = $interface.Cidr

                        if (-not $routeObject.Interface) {
                           $routeObject.Interface = $interface.Interface
                        }
                        break
                    }
                }
            }

            $routeObjects.Add($routeObject)
        }
    }

    $device.RoutingTable = $routeObjects
}


























#Extract all the information from the 'show interfaces terse' xml file
function Update-JunosInterfaces {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowInterfaceTerse')) { return }

    # --- EXTRACT ---
    $Interfaces = Get-JunosXmlDocument -Path $Path
    
    # --- Flag for debug logging for the specific host ---
    #$enableDebug = ($device.hostname -eq 'xxxx')

    # Iterate through each physical interface in the XML data
    foreach ($physical_interface in $Interfaces.'rpc-reply'.'interface-information'.'physical-interface') {
        # Find the corresponding physical interface object in the main device object
        $FoundInterface = $device.interfaces | where { $_.interface -eq $physical_interface.name }
        if ($FoundInterface) {
            # Update the operational status based on the XML

            if($physical_interface.'oper-status' -eq "up"){
                $FoundInterface.shutdown = $false
                $FoundInterface.IntStatus = "up"
                $FoundInterface.INTProtocolStatus = "up"
            }else{
                $FoundInterface.shutdown = $true
                $FoundInterface.IntStatus = "down"
                $FoundInterface.INTProtocolStatus = "down"
            }                 
        }

        # Check for and iterate through any logical interfaces associated with the physical one
        if ($physical_interface.'logical-interface') {
            # Ensure the logical interfaces are always treated as a collection, even if there's only one
            $logicalInterfaces = @($physical_interface.'logical-interface')

            foreach ($logical_interface in $logicalInterfaces) {
                # Determine the object to update, starting with a normalized name (e.g., "irb.53" -> "irb53")
                $normalizedName = $logical_interface.name -replace '\.', ''
                $interfaceToUpdate = $device.interfaces | Where-Object { $_.interface -eq $normalizedName }

                # Fallback for .0 sub-interfaces, which should apply to the parent physical interface
                if (-not $interfaceToUpdate -and $FoundInterface -and $logical_interface.name -eq "$($FoundInterface.interface).0") {
                    $interfaceToUpdate = $FoundInterface
                }

                if ($interfaceToUpdate) {
                    # Update the logical interface's operational status
                    if($logical_interface.'oper-status' -eq "up"){
                        $interfaceToUpdate.shutdown = $false
                        $interfaceToUpdate.IntStatus = "up"
                        $interfaceToUpdate.INTProtocolStatus = "up"
                    }else{
                        $interfaceToUpdate.shutdown = $true
                        $interfaceToUpdate.IntStatus = "down"
                        $interfaceToUpdate.INTProtocolStatus = "down"
                    }  

                    # Find the 'inet' address family to extract IP address information
                    $inetFamily = $logical_interface.'address-family' | Where-Object { $_.'address-family-name' -eq 'inet' }
                    if ($inetFamily -and $inetFamily.'interface-address') {
                        $ipAddressNodes = @($inetFamily.'interface-address'.'ifa-local')

                        # Loop through all available IP addresses on the interface
                        for ($i = 0; $i -lt $ipAddressNodes.Count; $i++) {
                            $ipNode = $ipAddressNodes[$i]
                            if ($null -ne $ipNode -and -not [string]::IsNullOrWhiteSpace($ipNode.'#text')) {
                                $ipString = $ipNode.'#text'
                                if ($ipString -like '*/*') {
                                    $ip, $prefix = $ipString -Split '/'
                                    
                                    # Calculate the full network CIDR
                                    $networkAddr = Get-JunosNetworkAddress -IPAddress $ip -PrefixLength ([int]$prefix)
                                    $cidr = "$networkAddr/$prefix"

                                    if ($i -eq 0) { # Handle Primary IP Address
                                        $interfaceToUpdate.IPAddress = $ip
                                        $interfaceToUpdate.Cidr = $cidr
                                        $interfaceToUpdate.SubnetMask = "$prefix"
                                    }
                                    elseif ($i -eq 1) { # Handle Secondary IP Address
                                        $interfaceToUpdate.SecondaryIPAddress = $ip
                                        $interfaceToUpdate.SecondaryCidr = $cidr
                                        $interfaceToUpdate.SecondarySubnetMask = "$prefix"
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    # --- START: Final debug output for all interfaces ---
    if ($enableDebug) {
        Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $device -Message "--- FINAL INTERFACE STATE BEFORE RETURN ---"
        # Select key properties to display in the log for clarity
        $finalInterfaceState = $device.interfaces | Format-Table Interface, shutdown, IPAddress, SubnetMask, Cidr, IntStatus -AutoSize | Out-String
        Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $device -Message $finalInterfaceState
    }
    # --- END: Final debug output ---

}











#This takes and array of vlans and vlan name to search for and returns the vlan id. AKA 0 - 4096.
#function Get-JunosVlanFromVLANArray{
#    param (
#		[parameter(Mandatory=$true)]
#		$VlanArray,
#        $VlanName,
#        $device
#    )
#    foreach($vlan in $VlanArray){
#        if($VlanName -eq $vlan.name){
#            return $vlan.number
#        }
#    }

#    return $null
#}














#
# Extracts all ARP entries from a Junos 'show arp' XML file using the existing object creator.
#
function Update-JunosArp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowArp')) { return }

    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $device -Message "Processing Junos ARP table: $Path"

    $AllIPArpObjects = @()

    # --- EXTRACT ---
    try {
        $ArpXml = Get-JunosXmlDocument -Path $Path
    }
    catch {
        Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $device -Message "Invalid XML file or could not read file: $Path"
        return
    }

    # Iterate through each <arp-table-entry> node in the XML.
    foreach ($entry in $ArpXml.'rpc-reply'.'arp-table-information'.'arp-table-entry') {
        # Use the EXISTING Create-ShowIPArpObject function.
        $IPArpObject = Create-ShowIPArpObject

        # Populate the object with data from the XML nodes.
        # Note: PROTOCOL, AGE, and TYPE will remain null as they are not in the Junos XML.
        $IPArpObject.MAC       = $entry.'mac-address'
        $IPArpObject.ipaddress = $entry.'ip-address'

        # Clean up the interface name (e.g., "vlan.100" becomes "vlan100") and assign it.
        $IPArpObject.INTERFACE = $entry.'interface-name' -replace '\.', ''

        # Find the parent network CIDR by matching the ARP IP against the device's own interface subnets.
        $IPArpObject.cidr = $device.interfaces | Where-Object { $_.Cidr } | Where-Object {(Find-Subnet -addr1 $_.Cidr -addr2 $IPArpObject.ipaddress).condition } | Select-Object -First 1 | ForEach-Object { $_.cidr }

        # Add the populated object to our collection.
        $AllIPArpObjects += $IPArpObject
    }

    # Assign the completed array of ARP entries to the main device object.
    $device.IPArpEntries = $AllIPArpObjects

    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $device -Message "Finished processing ARP table. Found $($AllIPArpObjects.Count) entries."

    # Return the modified device object.
}

#
# Resolves the OUI of a learned MAC to a vendor name, the value the per-port MAC bubble groups by.
# Matches the other platforms: try the 28-bit prefix first, then fall back to the 24-bit one.
#
function Get-JunosMacVendor {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$MacAddress)

    $hex = [string]$MacAddress -replace '[^0-9A-Fa-f]', ''
    if ($hex.Length -ne 12) { return 'UNKNOWN Vendor' }
    $colonForm = (0..5 | ForEach-Object { $hex.Substring($_ * 2, 2) }) -join ':'
    foreach ($length in 8, 5) {
        if ($GMacAddressToVendorMapping[$colonForm.Substring(0, $length)]) { return $GMacAddressToVendorMapping[$colonForm.Substring(0, $length)] }
    }
    return 'UNKNOWN Vendor'
}

#
# ELS carries the VLAN twice - a numeric id and a name - and splits the two across the entry and
# its wrapper depending on the output style: the brief style puts the id on the wrapper and the
# name on the child. The numeric id wins wherever it is found, because that is what the pre-ELS
# <mac-vlan-tag> put in this field; the name is only a fallback. Returns '' when neither exists.
#
function Get-JunosMacTableVlanLabel {
    [CmdletBinding()]
    param(
        [AllowNull()]$Element,
        [AllowNull()]$Parent
    )

    foreach ($name in @('l2ng-l2-vlan-id', 'l2ng-l2-mac-vlan-name')) {
        foreach ($source in @($Element, $Parent)) {
            if (-not $source) { continue }
            $value = [string]$source.$name
            if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
        }
    }
    return ''
}

#
# Junos publishes the forwarding table under two unrelated XML schemas, and both are still in the
# field, so the reader detects which one it was handed rather than replacing one with the other:
#
#   pre-ELS   <ethernet-switching-table-information><ethernet-switching-table><mac-table-entry>
#   ELS       <l2ng-l2ald-rtb-macdb><l2ng-l2ald-mac-entry-vlan>          (what 22.4 emits)
#
# The two root names live here, once, and Update-JunosMacAddressTable asks through this. It is
# XPath rather than property access because an empty container element - which is exactly how a
# switch with nothing learned reports - reads back as absent through the property adapter, and
# "the table is empty" must not be mistaken for "this is a schema nobody taught the reader".
#
function Test-JunosMacTableSchema {
    [CmdletBinding()]
    param([AllowNull()]$Xml)

    if (-not $Xml) { return $false }
    foreach ($root in @('/rpc-reply/l2ng-l2ald-rtb-macdb', '/rpc-reply/ethernet-switching-table-information')) {
        if ($Xml.SelectSingleNode($root)) { return $true }
    }
    return $false
}

#
# Every field is renamed between the two schemas, and ELS has no <mac-type> equivalent at all.
# Returns rows in one shape - MacAddress, Vlan, Type, Interface - so the caller maps only once.
#
function Get-JunosMacTableEntry {
    [CmdletBinding()]
    param([AllowNull()]$Xml)

    if (-not $Xml) { return }

    foreach ($entry in @($Xml.SelectNodes('/rpc-reply/ethernet-switching-table-information/ethernet-switching-table/mac-table-entry'))) {
        if (-not $entry) { continue }
        [pscustomobject]@{
            MacAddress = [string]$entry.'mac-address'
            Vlan       = [string]$entry.'mac-vlan-tag'
            Type       = [string]$entry.'mac-type'
            Interface  = [string]$entry.'mac-interface'
        }
    }

    # The 'detail' and 'extensive' styles put every field on the <l2ng-l2ald-mac-entry-vlan>
    # element itself. The brief style makes that same element a per-VLAN wrapper around
    # <l2ng-mac-entry> children instead, so the VLAN identity has to be inherited downwards.
    foreach ($vlanEntry in @($Xml.SelectNodes('/rpc-reply/l2ng-l2ald-rtb-macdb/l2ng-l2ald-mac-entry-vlan'))) {
        if (-not $vlanEntry) { continue }
        $children = @($vlanEntry.'l2ng-mac-entry' | Where-Object { $_ })
        foreach ($entry in @(if ($children.Count -gt 0) { $children } else { $vlanEntry })) {
            $vlan = Get-JunosMacTableVlanLabel -Element $entry -Parent $vlanEntry

            # There is no ELS equivalent of <mac-type>. The entry flags are the closest thing the
            # schema carries, so they occupy Type rather than leaving it blank; the extensive form
            # spells them 'entry-flags' and the brief form 'flags'.
            $flags = [string]$entry.'l2ng-l2-mac-entry-flags'
            if ([string]::IsNullOrWhiteSpace($flags)) { $flags = [string]$entry.'l2ng-l2-mac-flags' }

            [pscustomobject]@{
                MacAddress = [string]$entry.'l2ng-l2-mac-address'
                Vlan       = $vlan
                Type       = $flags.Trim()
                Interface  = [string]$entry.'l2ng-l2-mac-logical-interface'
            }
        }
    }
}

#
# Extracts all MAC address entries from a Junos 'show ethernet-switching table' XML file.
#
function Update-JunosMacAddressTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowEthernetSwitchingTable')) { return }

    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Processing Junos MAC address table: $Path"

    # --- EXTRACT ---
    try {
        $MacXml = Get-JunosXmlDocument -Path $Path
    }
    catch {
        Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "Invalid XML file or could not read file: $Path"
        return
    }
    if (-not $MacXml) { return }

    # A switch with nothing in its forwarding table is normal, and is not the same thing as a
    # schema this reader does not know, so the two are separated before anything is logged.
    if (-not (Test-JunosMacTableSchema -Xml $MacXml)) {
        Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "MAC address table capture matched neither the pre-ELS nor the ELS schema: $Path"
        return
    }

    $entries = @(Get-JunosMacTableEntry -Xml $MacXml)
    if ($entries.Count -eq 0) {
        Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "MAC address table is empty: $Path"
        return
    }

    # --- MAP + MERGE ---
    $missingInterfaces = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $merged = 0
    foreach ($entry in $entries) {

        # Skip entries that are not useful (e.g., Flood entries or internal router entries).
        if ($entry.MacAddress -eq '*' -or $entry.Interface -eq 'Router') {
            continue
        }

        # Clean up the interface name (e.g., "ge-0/0/23.0" becomes "ge-0/0/23") to match other configs.
        $name = ([string]$entry.Interface).Trim() -replace '\.0$', ''
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        # Use the existing Create-MacAddressObject function for consistency.
        $MacObject = Create-MacAddressObject
        $MacObject.MacAddress = ConvertTo-NormalizedMacAddress (([string]$entry.MacAddress).Trim())
        if ([string]::IsNullOrWhiteSpace($MacObject.MacAddress)) { continue }
        $MacObject.Vlan              = $entry.Vlan
        $MacObject.Type              = $entry.Type
        $MacObject.Interface         = $name
        $MacObject.VendorCompanyName = Get-JunosMacVendor -MacAddress $MacObject.MacAddress

        # Find the corresponding interface object on the device. A MAC learned on a port the
        # configuration never declared is a capture inconsistency, not a reason to invent a port.
        $deviceInterface = Resolve-MTAutoDrawInterface -Device $Device -Name $name -NoCreate
        if (-not $deviceInterface) {
            $null = $missingInterfaces.Add($name)
            continue
        }
        $deviceInterface.MacAddressArray += , $MacObject
        $merged++
    }

    # Aggregate unmatched MACs by device so a busy uplink produces one actionable diagnostic.
    if ($missingInterfaces.Count -gt 0) {
        Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "Could not find $($missingInterfaces.Count) interface(s) to associate learned MAC addresses with: $((@($missingInterfaces) | Sort-Object) -join ', ')."
    }

    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Finished processing MAC address table. Merged $merged of $($entries.Count) entries."
}






# Computes the network address (subnet base IP) for an IP + prefix length using 32-bit mask arithmetic. Returns the dotted-quad network address string.
function Get-JunosNetworkAddress {
    param($IPAddress, $PrefixLength)
    $ip = [System.Net.IPAddress]::Parse($IPAddress)
    $mask = 0xFFFFFFFF -shl (32 - $PrefixLength)
    $ipBytes = $ip.GetAddressBytes()
    if ([System.BitConverter]::IsLittleEndian) { [System.Array]::Reverse($ipBytes) }
    $ipInt = [System.BitConverter]::ToUInt32($ipBytes, 0)
    $networkInt = $ipInt -band $mask
    $networkBytes = [System.BitConverter]::GetBytes($networkInt)
    if ([System.BitConverter]::IsLittleEndian) { [System.Array]::Reverse($networkBytes) }
    return ([System.Net.IPAddress]$networkBytes).IPAddressToString
}
#endregion


# Helper function to expand interface range syntax e.g., ge-0/0/[0-7]
function Expand-JunosInterfaceRange {
    param([string]$Name)
    $expandedNames = @()
    if ($Name -match '(.+?)\[(\d+)-(\d+)\](.*)') {
        $prefix = $matches[1]
        $start = [int]$matches[2]
        $end = [int]$matches[3]
        $suffix = $matches[4]
        for ($i = $start; $i -le $end; $i++) {
            $expandedNames += "$prefix$i$suffix"
        }
    } else {
        $expandedNames += $Name
    }
    return $expandedNames
}



# Reads a Junos 'show configuration' XML capture: the hostname, the VLAN database, and every
# interface with its addressing, aggregation and switching configuration. This is the capture the
# whole device is built from - the operational captures only annotate what it produced.
function Update-JunosRunningConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowRun')) { return }

    # --- EXTRACT ---
    try {
        $Lconfig = Get-JunosXmlDocument -Path $Path
    }
    catch {
        Write-MTAutoDrawDiagnostic -Device $Device -Severity Warning -Message "Invalid XML file: $Path"
        return
    }

    $ArrayOfHostNetworks = @()
    $hostname = $Lconfig.'rpc-reply'.configuration.system.'host-name'
    if ($null -eq $hostname -or $hostname -eq "") {
        $hostname = "NoHostNameFoundCheckForConfigProblems"
        Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $device -Message "No hostname found in Junos config"
    }
    $device.hostname = $hostname

    $vlanPSObjects = @()
    $vlanMap = @{}
    # Check if the vlans tag exists before processing
    if ($Lconfig.'rpc-reply'.configuration.vlans) {
        # Force the object into an array to handle single and multiple VLANs
        foreach ($vlan in @($Lconfig.'rpc-reply'.configuration.vlans.vlan)) {
            $vlanObject = Create-vlanObject

            # Check if the properties exist before accessing them
            if ($vlan.'vlan-id') {
                $vlanObject.number = $vlan.'vlan-id'
            }

            if ($vlan.name) {
                $vlanObject.name = $vlan.name
            }

            if ($vlan.description) {
                $vlanObject.description = $vlan.description
            }

            $vlanPSObjects += $vlanObject
            # This line will only work if $vlan.name and $vlan.'vlan-id' exist
            if ($vlan.name -and $vlan.'vlan-id') {
                $vlanMap[$vlan.name] = $vlan.'vlan-id'
            }
        }
    }

    [array]$ArrayOfIPAddresses = @()
    $interfaceObjects = @{}
    $configNode = $Lconfig.'rpc-reply'.configuration

    $groupMap = @{}
    foreach ($group in @($configNode.groups)) {
        if ($group.name) {
            $groupMap[$group.name] = $group
        }
    }

    if ($configNode.interfaces.'interface-range') {
        foreach ($rangeNode in @($configNode.interfaces.'interface-range')) {
            $configToApply = $null
            $groupName = $rangeNode.'apply-groups'

            if ($groupName -and $groupMap.ContainsKey($groupName)) {
                $configToApply = $groupMap[$groupName].interfaces.interface
            }
            else {
                $configToApply = $rangeNode
            }

            if ($configToApply) {
                $allMemberNames = @()
                foreach ($member in @($rangeNode.member)) {
                    $allMemberNames += Expand-JunosInterfaceRange -Name $member.name
                }

                # Parse inclusive member ranges while preserving the prefix from the start value.
                foreach ($memberRange in @($rangeNode.'member-range')) {
                    if ($memberRange.name -match '(.+/)(\d+)$') {
                        # Capture the results from the first match immediately
                        $prefix = $matches[1]
                        $start = [int]$matches[2]

                        # Parse the range endpoint after saving the first match's prefix and start.
                        if ($memberRange.'end-range' -match '(.+/)(\d+)$') {
                            $end = [int]$matches[2]

                            if ($start -le $end) {
                                for ($i = $start; $i -le $end; $i++) {
                                    $allMemberNames += "$prefix$i"
                                }
                            }
                        }
                    }
                }
                foreach ($ifaceName in ($allMemberNames | Sort-Object -Unique)) {
                    if (-not $interfaceObjects.ContainsKey($ifaceName)) {
                        $obj = Create-InterfaceObject
                        $obj.Interface = $ifaceName
                        $interfaceObjects[$ifaceName] = $obj
                    }
                    $obj = $interfaceObjects[$ifaceName]

                    $obj.NativeVlan = $configToApply.'native-vlan-id'

                    $etherOptions = $configToApply.'ether-options'
                    if (-not $etherOptions) { $etherOptions = $configToApply.'gigether-options' }
                    if (-not $etherOptions) { $etherOptions = $configToApply.'ten-gigether-options' }
                    if ($etherOptions) {
                        $bundle = $etherOptions.'ieee-802.3ad'.bundle
                        if (-not $bundle) { $bundle = $etherOptions.'802.3ad' }
                        if ($bundle) { $obj.ChannelGroup = $bundle.Trim() }
                    }

                    foreach ($unit in @($configToApply.unit)) {
                        $switching = $unit.family.'ethernet-switching'
                        if ($switching) {
                            $obj.SwitchPortType = 'switched'
                            $obj.SwitchportMode = 'access'
                            $obj.SwitchportAccessVlan = '1'
                            if ($switching.'native-vlan-id') {
                                $nativeVlanName = $switching.'native-vlan-id'
                                $obj.NativeVlan = if ($vlanMap.ContainsKey($nativeVlanName)) { $vlanMap[$nativeVlanName] } else { $nativeVlanName }
                            }
                            $portMode = $switching.'interface-mode'
                            if (-not $portMode) { $portMode = $switching.'port-mode' }
                            if ($portMode) { $obj.SwitchportMode = $portMode }
                            if ($switching.vlan.members) {
                                if ($obj.SwitchportMode -eq 'access') {
                                    $vlanName = $switching.vlan.members
                                    if ($vlanName) { $obj.SwitchportAccessVlan = if ($vlanMap.ContainsKey($vlanName)) { $vlanMap[$vlanName] } else { $vlanName } }
                                } elseif ($obj.SwitchportMode -eq 'trunk') {
                                    $obj.SwitchportAccessVlan = $null
                                    if ($switching.vlan.members -eq 'all') {
                                        $obj.SwitchportTrunkVlan = ($vlanMap.Values | Sort-Object -Unique) -join ','
                                    } else {
                                        $trunkVlans = @($switching.vlan.members) | Where-Object { $_ } | ForEach-Object { if ($vlanMap.ContainsKey($_)) { $vlanMap[$_] } else { $_ } }
                                        $obj.SwitchportTrunkVlan = ($trunkVlans | Sort-Object -Unique) -join ','
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if ($configNode.interfaces) {
        foreach ($ifaceNode in @($configNode.interfaces.interface)) {
            $baseInterfaceName = $ifaceNode.name

            if ($baseInterfaceName -match '^(irb|vlan)$') {
                foreach ($unit in @($ifaceNode.unit)) {
                    $logicalInterfaceName = "$baseInterfaceName$($unit.name)"
                    if (-not $interfaceObjects.ContainsKey($logicalInterfaceName)) {
                        $obj = Create-InterfaceObject
                        $obj.Interface = $logicalInterfaceName
                        $interfaceObjects[$logicalInterfaceName] = $obj
                    }
                    $obj = $interfaceObjects[$logicalInterfaceName]

                    $obj.Description = $unit.description
                    if ($unit.disable -or $unit.inactive -eq 'inactive') {
                        $obj.shutdown = $true
                        $obj.IntStatus = "down" 
                        $obj.INTProtocolStatus = "down"                        
                    }else{
                        $obj.shutdown = $false
                        $obj.IntStatus = "up" 
                        $obj.INTProtocolStatus = "up" 
                    }
                    $obj.SwitchPortType = 'routed'
                    $obj.RoutedVlan = $unit.name

                    $inet = $unit.family.inet
                    if ($inet.address) {
                        $addresses = @($inet.address)
                        # Loop through all addresses to handle primary, secondary, etc.
                        for ($i = 0; $i -lt $addresses.Count; $i++) {
                            $addressEntry = $addresses[$i]
                            # --- FIX: Validate that the address name exists and is not empty ---
                            # If an address is marked as inactive, set the interface to shutdown.
							if ($addressEntry.inactive -eq 'inactive') {
								$obj.shutdown = $true
                                $obj.IntStatus = "down" 
                                $obj.INTProtocolStatus = "down"
							}else{
                                $obj.shutdown = $false
                                $obj.IntStatus = "up" 
                                $obj.INTProtocolStatus = "up" 
                            }

 								# Validate that the address name exists and is not empty before processing.
                            if ($addressEntry -and -not [string]::IsNullOrWhiteSpace($addressEntry.name)) {
                                try {
                                    $ipParts = $addressEntry.name.Split('/')
                                    if ($ipParts.Count -lt 2) { throw "IP address format is missing the CIDR prefix." }
                                    
                                    # --- FIX: Validate the IP part is not empty after splitting ---
                                    if (-not [string]::IsNullOrWhiteSpace($ipParts[0])) {
                                        $ip = $ipParts[0]
                                        $prefix = [int]$ipParts[1]
                                        $subnetMask = "$prefix"
                                        $networkAddr = Get-JunosNetworkAddress -IPAddress $ip -PrefixLength $prefix
                                        $cidr = "$networkAddr/$prefix"

                                        if ($i -eq 0) { # Primary IP
                                            $obj.IPAddress = $ip
                                            $obj.SubnetMask = $subnetMask
                                            $obj.Cidr = $cidr
                                            $ArrayOfIPAddresses += $obj.IPAddress
                                        }
                                        elseif ($i -eq 1) { # Secondary IP
                                            $obj.SecondaryIPAddress = $ip
                                            $obj.SecondarySubnetMask = $subnetMask
                                            $obj.SecondaryCidr = $cidr
                                        }
                                    }
                                } catch {
                                    Write-MTAutoDrawDiagnostic -Device $Device -Severity Warning -Message "Failed to parse IP Address '$($addressEntry.name)' on interface '$($obj.Interface)'. Error: $($_.Exception.Message)"
                                }
                            }
                        }
                    }
                }
            } else {
                if (-not $interfaceObjects.ContainsKey($baseInterfaceName)) {
                    $obj = Create-InterfaceObject
                    $obj.Interface = $baseInterfaceName
                    $interfaceObjects[$baseInterfaceName] = $obj
                }
                $obj = $interfaceObjects[$baseInterfaceName]

                if ($ifaceNode.'apply-groups') {
                    $groupName = $ifaceNode.'apply-groups'
                    if ($groupName -and $groupMap.ContainsKey($groupName)) {
                        $groupTemplate = $groupMap[$groupName]
                        $configToApply = $groupTemplate.interfaces.interface
                        if ($configToApply) {
                            if ($configToApply.description) { $obj.Description = $configToApply.description }
                            if ($configToApply.disable -or $configToApply.inactive -eq 'inactive') {
                                $obj.shutdown = $true
                                $obj.IntStatus = "down" 
                                $obj.INTProtocolStatus = "down"                                
                            }else{
                                $obj.shutdown = $false
                                $obj.IntStatus = "up" 
                                $obj.INTProtocolStatus = "up" 
                            }
                            if ($configToApply.'native-vlan-id') { $obj.NativeVlan = $configToApply.'native-vlan-id' }

                            foreach ($unit in @($configToApply.unit)) {
                                $switching = $unit.family.'ethernet-switching'
                                if ($switching) {
                                    $obj.SwitchPortType = 'switched'
                                    $obj.SwitchportMode = 'access'
                                    $obj.SwitchportAccessVlan = '1'
                                    if ($switching.'native-vlan-id') {
                                        $nativeVlanName = $switching.'native-vlan-id'
                                        $obj.NativeVlan = if ($vlanMap.ContainsKey($nativeVlanName)) { $vlanMap[$nativeVlanName] } else { $nativeVlanName }
                                    }
                                    $portMode = $switching.'interface-mode'
                                    if (-not $portMode) { $portMode = $switching.'port-mode' }
                                    if ($portMode) { $obj.SwitchportMode = $portMode }
                                    if ($switching.vlan.members) {
                                        if ($obj.SwitchportMode -eq 'access') {
                                            $vlanName = $switching.vlan.members
                                            if ($vlanName) { $obj.SwitchportAccessVlan = if ($vlanMap.ContainsKey($vlanName)) { $vlanMap[$vlanName] } else { $vlanName } }
                                        } elseif ($obj.SwitchportMode -eq 'trunk') {
                                            $obj.SwitchportAccessVlan = $null
                                            if ($switching.vlan.members -eq 'all') {
                                                $obj.SwitchportTrunkVlan = ($vlanMap.Values | Sort-Object -Unique) -join ','
                                            } else {
                                                $trunkVlans = @($switching.vlan.members) | Where-Object { $_ } | ForEach-Object { if ($vlanMap.ContainsKey($_)) { $vlanMap[$_] } else { $_ } }
                                                $obj.SwitchportTrunkVlan = ($trunkVlans | Sort-Object -Unique) -join ','
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if ($ifaceNode.description) { $obj.Description = $ifaceNode.description }
                if ($ifaceNode.disable -or $ifaceNode.inactive -eq 'inactive') {
                    $obj.shutdown = $true
                    $obj.IntStatus = "down" 
                    $obj.INTProtocolStatus = "down"                    
                }else{
                    $obj.shutdown = $false
                    $obj.IntStatus = "up" 
                    $obj.INTProtocolStatus = "up" 
                }
                if ($ifaceNode.'native-vlan-id') { $obj.NativeVlan = $ifaceNode.'native-vlan-id' }

                $etherOptions = $ifaceNode.'ether-options'
                if (-not $etherOptions) { $etherOptions = $ifaceNode.'gigether-options' }
                if (-not $etherOptions) { $etherOptions = $ifaceNode.'ten-gigether-options' }
                if (-not $etherOptions) { $etherOptions = $ifaceNode.'aggregated-ether-options' }

                $bundle = $null
                if ($etherOptions) {
                    $bundle = $etherOptions.'ieee-802.3ad'.bundle
                    if (-not $bundle) { $bundle = $etherOptions.'802.3ad' }
                }
                if ($bundle) { $obj.ChannelGroup = $bundle.Trim() }

                foreach ($unit in @($ifaceNode.unit)) {
                    $switching = $unit.family.'ethernet-switching'
                    if ($switching) {
                        $obj.SwitchPortType = 'switched'
                        $obj.SwitchportMode = 'access'
                        $obj.SwitchportAccessVlan = '1'
                        if ($switching.'native-vlan-id') {
                            $nativeVlanName = $switching.'native-vlan-id'
                            $obj.NativeVlan = if ($vlanMap.ContainsKey($nativeVlanName)) { $vlanMap[$nativeVlanName] } else { $nativeVlanName }
                        }
                        $portMode = $switching.'interface-mode'
                        if (-not $portMode) {
                            $portMode = $switching.'port-mode'
                        }
                        if ($portMode) {
                            $obj.SwitchportMode = $portMode
                        }

                        if ($switching.vlan.members) {
                            if ($obj.SwitchportMode -eq 'access') {
                                $vlanName = $switching.vlan.members
                                if ($null -ne $vlanName) {
                                    $obj.SwitchportAccessVlan = if ($vlanMap.ContainsKey($vlanName)) { $vlanMap[$vlanName] } else { $vlanName }
                                }
                            } elseif ($obj.SwitchportMode -eq 'trunk') {
                                $obj.SwitchportAccessVlan = $null
                                if ($switching.vlan.members -eq 'all') {
                                    $obj.SwitchportTrunkVlan = ($vlanMap.Values | Sort-Object -Unique) -join ','
                                } else {
                                    $trunkVlans = @($switching.vlan.members) | Where-Object { $_ } | ForEach-Object { if ($vlanMap.ContainsKey($_)) { $vlanMap[$_] } else { $_ } }
                                    $obj.SwitchportTrunkVlan = ($trunkVlans | Sort-Object -Unique) -join ','
                                }
                            }
                        }
                    }

                    $inet = $unit.family.inet
                    if ($inet.address) {
                        $obj.SwitchPortType = 'routed'
                    }
                }
            }
        }

        foreach ($ifaceObj in $interfaceObjects.Values) {
            if ($ifaceObj.ChannelGroup) {
                $aeName = $ifaceObj.ChannelGroup
                if ($interfaceObjects.ContainsKey($aeName)) {
                    $parentAe = $interfaceObjects[$aeName]

                    $ifaceObj.SwitchPortType       = $parentAe.SwitchPortType
                    $ifaceObj.SwitchportMode       = $parentAe.SwitchportMode
                    $ifaceObj.SwitchportAccessVlan  = $parentAe.SwitchportAccessVlan
                    $ifaceObj.SwitchportTrunkVlan   = $parentAe.SwitchportTrunkVlan
                    $ifaceObj.NativeVlan            = $parentAe.NativeVlan
                    $ifaceObj.IPAddress             = $parentAe.IPAddress
                    $ifaceObj.SubnetMask            = $parentAe.SubnetMask
                    $ifaceObj.Cidr                  = $parentAe.Cidr
                    $ifaceObj.SecondaryIPAddress    = $parentAe.SecondaryIPAddress
                    $ifaceObj.SecondarySubnetMask   = $parentAe.SecondarySubnetMask
                    $ifaceObj.SecondaryCidr         = $parentAe.SecondaryCidr
                }
            }
        }
    }

    [array]$interfaces = $interfaceObjects.Values | Sort-Object { $_.Interface -replace '\d+', { $_.Value.PadLeft(4, '0') } }

    foreach ($ag in ($interfaces | where { $_.interface -like "ae*"})) {
        $ag.ShapeColor = Get-DeterministicRgbColor -Seed "aggregate|$($ag.Interface)"
        $interfaces | where { $_.ChannelGroup -eq $ag.interface } | ForEach-Object { $_.ShapeColor = $ag.ShapeColor }
    }

    foreach ($interface in $interfaces) {
        if ($null -ne $interface.Cidr) {
            $NetworkObject = Create-NetworkObject
            $NetworkObject.Cidr = $interface.Cidr
            if ($interface.Interface -like "*vlan*" -or $interface.Interface -like "*irb*") {
                $NetworkObject.Routedvlan = $interface.Interface
            } else {
                $NetworkObject.Routedvlan = "no vlan"
            }
            $ArrayOfHostNetworks += $NetworkObject
        }
    }

    $device.ArrayOfIPAddresses = $ArrayOfIPAddresses
    $device.ArrayOfNetworks = $ArrayOfHostNetworks
    $device.vlans = $vlanPSObjects
    $device.interfaces = $interfaces

    $ipReport = $interfaces | Where-Object { $_.IPAddress } | ForEach-Object {
        $prefix = if ($_.Cidr) { ($_.Cidr -split '/')[1] } else { 'N/A' }
        "$($_.Interface): $($_.IPAddress)/$prefix"
    }
    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $device -Message "Final Parsed IP Report: $($ipReport -join '; ')"

}


# Junos captures taken with "| display xml" carry the echoed command on the first line and a
# "{master:0}" / "root@host>" prompt after the closing tag. A direct [xml] cast throws on both.
# This trims to the outermost element before casting.
function Get-JunosXmlDocument {
    param([Parameter(Mandatory = $true)][string]$Path)

    $raw = Get-MTAutoDrawCaptureText -Path $Path
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    $open = $raw.IndexOf('<')
    if ($open -lt 0) { return $null }
    $closeTag = '</rpc-reply>'
    $close = $raw.LastIndexOf($closeTag)
    $trimmed = if ($close -gt $open) { $raw.Substring($open, ($close + $closeTag.Length) - $open) } else { $raw.Substring($open) }

    return [xml]$trimmed
}
