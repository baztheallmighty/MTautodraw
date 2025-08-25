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

#This file contains all of the functions that process CheckPoint config.


#This functions calls all the other functions to process all of the files for a junos devices.
#Input: Hostid object.
#Output: $device object.
function Process-JunosHostFiles{
        param (
		[parameter(Mandatory=$true)]
		$hostid,
        $ArrayOfObjects
    )

        $Device=$null
        if($hostid.showrun -and (Test-Path -Path $hostid.showrun)){
            try{
                $config=[xml] (Get-Content -Path $hostid.showrun -raw)
            }
            catch {
                write-host "Invalid XML file: $($hostid.showrun) exiting" -BackgroundColor red
                return $null
            }


            # MODIFICATION: Pass the result of the check to the parsing function.
            $Device=Get-JunosShowRunFromXML -Lconfig $config

            $Device.DeviceIdentifier=($hostid.showrun -replace "\.show run.*",'' -replace "^.*\\",'' -replace "\.show configuration.*",'' )
        }else{
            write-host "File doesn't exist: $($hostid.showrun)" -BackgroundColor red
            return $null
        }
        Add-HostDebugText -HostObject $Device "Processing Junos show config"
        if($null -eq $Device.hostname ){
            Write-host "Can't find hostname in file skipping host: $($hostid.showrun)" -BackgroundColor red
            return $null
        }
        foreach ($ExistingDevice in $ArrayOfObjects){
            if($ExistingDevice.hostname -eq $Device.hostname){
                Add-HostDebugText -HostObject $Device "Hostname already exists $($ExistingDevice.hostname) - $($Device.hostname). This means you either have the same code twice in the folder or someone has named two devices the same. This script requries unquie hostnames." -BackgroundColor red
                Add-HostDebugText -HostObject $Device "Found problem at: $($hostid.HOSTID)" -BackgroundColor red
                Add-HostDebugText -HostObject $Device "Existing HostID's:$($ArrayOfHostIDs | ft HOSTID,showrun | out-string)"
                Add-HostDebugText -HostObject $Device "$($ArrayOfObjects|ft hostname,DeviceIdentifier| out-string)"
                if(!($SkipHostnameErrorCheck)){
                    Add-HostDebugText -HostObject $Device 'Exiting please manually fix this error.'  -BackgroundColor red
                    Start-CleanupAndExit
                }
            }
        }

        if($hostid.ShowVersion){
            Add-HostDebugText -HostObject $Device "Processing Junos show version: $($hostid.ShowVersion)"
            $Device=Get-JunosShowVersionFromXML -JunosShowVersionFile $hostid.ShowVersion -Device $Device
        }
        if($hostid.ShowInterfaceDetail){
            Add-HostDebugText -HostObject $Device "Processing Junos show interface:$($hostid.ShowInterfaceDetail)"
            $Device=Get-JunosShowInterfaceFromXML -JunosInterfaceFile $hostid.ShowInterfaceDetail -Device $Device
        }
        if($hostid.ShowLLDPNeighbors){#CDP must be processed before LLDP.
            Add-HostDebugText -HostObject $Device "Processing show LLDP Details:$($hostid.ShowLLDPNeighbors)"
            $Device=Get-JunosShowLLDPNeighbors -JunosShowLLDPNeighborsFile $hostid.ShowLLDPNeighbors -Device $Device
        }
        if($hostid.ShowRouteAll){
            Add-HostDebugText -HostObject $Device "Processing Junos show route all:$($hostid.ShowRouteAll)"
            $device=Get-JunosShowRouteAllFromXML -device $device -JunosShowRouteAllFile $hostid.ShowRouteAll
        }
        if($hostid.ShowSpanningTreeInterface){
            Add-HostDebugText -HostObject $Device "Processing Junos Show Spanning Tree Interface:$($hostid.ShowSpanningTreeInterface)"
            $device=Get-JunosShowSpanningTreeInterfaceFromXML -device $device -ShowSpanningTreeInterfaceFile $hostid.ShowSpanningTreeInterface
        }
        if($hostid.JunosShowSpanningTreeBridgeFromXML){
            Add-HostDebugText -HostObject $Device "Processing Junos Show Spanning Tree Bridge :$($hostid.JunosShowSpanningTreeBridgeFromXML)"
            $device=Get-JunosShowSpanningTreeBridgeFromXML -device $device -JunosShowSpanningTreeBridgeFile $hostid.JunosShowSpanningTreeBridgeFromXML
        }
        if ($hostid.ShowArp) {
            $device = Get-JunosArpTableFromXML -JunosArpFile $hostid.ShowArp -Device $device
        }
        if ($hostid.ShowEthernetSwitchingTable) {
            $device = Get-JunosMacAddressTableFromXML -JunosMacTableFile $hostid.ShowEthernetSwitchingTable -Device $device
        }
        ## Update VLAN memberships using the more reliable 'show vlans detail' output.
        ## This runs AFTER the main config parse to correct any ambiguities.
        #if ($hostid.ShowVlansDetail -and (Test-Path -Path $hostid.ShowVlansDetail)) {
        #    $device = Get-JunosVlansFromDetailXML -JunosVlansFile $hostid.ShowVlansDetail -Device $device
        #}
        return $device
}


#Extract all the information from the show version all xml file
function Get-JunosShowVersionFromXML{
    param (
		[parameter(Mandatory=$true)]
		$JunosShowVersionFile,
        $device
    )
    $ShowVersion = [xml] (Get-Content -Raw $JunosShowVersionFile )
    $VersionObject=Create-ShowVersionObject
    $VersionObject.Hostname =  $ShowVersion.'rpc-reply'.'multi-routing-engine-results'.'multi-routing-engine-item'.'software-information'.'host-name'
    $VersionObject.Hardware =  $ShowVersion.'rpc-reply'.'multi-routing-engine-results'.'multi-routing-engine-item'.'software-information'.'product-model'

    $device.Version=$VersionObject

    return $device
}



function Get-JunosShowLLDPNeighbors{
    param (
        [parameter(Mandatory=$true)]
        $JunosShowLLDPNeighborsFile,
        $device
    )
    try {
        $Neighbors = [xml] (Get-Content -Raw $JunosShowLLDPNeighborsFile )
    } catch {
        Write-Warning "Could not parse XML file: $JunosShowLLDPNeighborsFile"
        return $device
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
            $LLDPObject.InterfaceLocalDevice="Unknown-Interface-$(Get-Random)"
        }

        $LLDPObject.ChassisID=$Neighbor.'lldp-remote-chassis-id'

        # --- START OF LOGIC FIX ---

        # This section correctly handles inconsistent Juniper XML output.
        $remotePortId = $Neighbor.'lldp-remote-port-id'
        $remotePortDesc = $Neighbor.'lldp-remote-port-description'

        # Always assign the description property. This is crucial for Tier 2 matching.
        $LLDPObject.NeighborInterfaceDescription = $remotePortDesc

        # Now, intelligently determine the Interface Name.
        # Prioritize the specific Port ID tag if it exists.
        if (-not [string]::IsNullOrEmpty($remotePortId)) {
            $LLDPObject.InterfaceRemoteDevice = $remotePortId
        }
        # If no Port ID, check if the description LOOKS like an interface name.
        elseif (Check-InterfaceType -string $remotePortDesc) {
            $LLDPObject.InterfaceRemoteDevice = $remotePortDesc
        }
        # Otherwise, we have a description but no clear interface name.
        else {
            $LLDPObject.InterfaceRemoteDevice = "Unknown Interface"
        }

        # --- END OF LOGIC FIX ---

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

    # Handle cases where multiple neighbors report the same interface name (common with unmanaged switches)
    foreach ($LLDPDevice in $AllLLDPDetailsObjects ){
        if(($AllLLDPDetailsObjects | where { $_.hostname -eq $LLDPDevice.hostname -and $_.InterfaceRemoteDevice -eq $LLDPDevice.InterfaceRemoteDevice}).count -gt 1){
            $LLDPDevice.InterfaceRemoteDevice = "$($LLDPDevice.InterfaceRemoteDevice)___$(Get-Random)"
        }
    }

    $device.LLDPNeighbors=$AllLLDPDetailsObjects | sort -property @{Expression={[int]($_.InterfaceLocalDevice -replace '[a-zA-Z-]+','' -replace "/",'')}}
    return $device
}











function Get-JunosShowSpanningTreeBridgeFromXML {
    param(
        [parameter(Mandatory = $true)]
        $JunosShowSpanningTreeBridgeFile,
        [parameter(Mandatory = $true)]
        $device
    )

    $FunctionName = "Get-JunosShowSpanningTreeBridgeFromXML"

    $SpanningTreeXml = [xml](Get-Content -Raw $JunosShowSpanningTreeBridgeFile)

    # Check for the specific "not enabled" output.
    $disabledMessage = $SpanningTreeXml.SelectSingleNode("/rpc-reply/output[text()='Spanning-tree is not enabled at global level.']")
    if ($null -ne $disabledMessage) {
        # Create a new SpanningTree object and mark it as disabled.
        $device.SpanningTree = Create-SpanningTreeObject
        $device.SpanningTree.SpanningTreeMode = "SpanningTree Disabled"
        return $device
    }

    $namespaceManager = [System.Xml.XmlNamespaceManager]::new($SpanningTreeXml.NameTable)
    $stpNode = $SpanningTreeXml.SelectSingleNode("//*[local-name()='stp-bridge']")

    if ($null -eq $stpNode) {
        # This catch-all handles any other XML format where stp-bridge is not present.
        $device.SpanningTree = Create-SpanningTreeObject
        $device.SpanningTree.SpanningTreeMode = "SpanningTree NotPresent"
        return $device
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
        $stpVlanObject.Address = $rootMac
        $stpVlanObject.RootBridgeHelloTime = if ($helloTimeNode) { $helloTimeNode.'#text' } else { 'N/A' }
        $stpVlanObject.RootBridgeAgingTime = if ($maxAgeNode) { $maxAgeNode.'#text' } else { 'N/A' }

        # --- Local Bridge Information ---
        $stpVlanObject.BridgeIDPriority = if ($bridgePriorityNode) { $bridgePriorityNode.'#text' } else { 'N/A' }
        $stpVlanObject.BridgeIDPriorityaddress = $thisMac

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

    return $device
}



function Get-JunosShowSpanningTreeInterfaceFromXML {
    param (
        [parameter(Mandatory=$true)]
        $ShowSpanningTreeInterfaceFile,
        [parameter(Mandatory=$true)]
        $device
    )
    $SpanningTreeInterfacesXml = [xml] (Get-Content -Raw $ShowSpanningTreeInterfaceFile)

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

    return $device
}


# UPDATED FUNCTION
function get-JunosShowRouteAllFromXML {
    param (
        [parameter(Mandatory=$true)]
        $JunosShowRouteAllFile,

        [parameter(Mandatory=$true)]
        $device
    )

    $routeObjects = [System.Collections.Generic.List[pscustomobject]]::new()

    #--> ADDED: Define protocols to completely exclude from the output.
    # Junos uses 'Direct' for connected routes and 'Local' for local routes.
    $protocolsToExclude = @('Local', 'Direct')

    try {
        $xmlContent = [xml](Get-Content -Path $JunosShowRouteAllFile -Raw)
    }
    catch {
        Write-Warning "Failed to parse '$JunosShowRouteAllFile' as XML. It might be a plain text file or corrupted. Skipping."
        return $device
    }

    $namespaceUri = $xmlContent.DocumentElement.'route-information'.NamespaceURI
    if (-not $namespaceUri) {
        Write-Warning "Could not detect a Junos routing namespace in '$JunosShowRouteAllFile'. Skipping."
        return $device
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

            #--> ADDED: Filter to skip processing and adding local/direct routes.
            if ($protocolsToExclude -contains $routeObject.RouteProtocol) {
                continue # Skip this route and move to the next one.
            }

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

            # This logic now only runs on routes that have a gateway (e.g., Static, BGP, OSPF).
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
    return $device
}

#Extract all the information from the interfaces xml file
function Get-JunosShowInterfaceFromXML{
    param (
		[parameter(Mandatory=$true)]
		$JunosInterfaceFile,
        $device
    )
    $Interfaces = [xml] (Get-Content -Raw $JunosInterfaceFile )
    foreach ($interface in ($interfaces.'rpc-reply'.'interface-information'.'physical-interface')){
        $FoundInterface=$device.interfaces | where { $_.interface -eq $interface.name}
        if($FoundInterface){
            if($interface.'oper-status' -eq "up"){
                $FoundInterface.shutdown=$false
            }else{
                $FoundInterface.shutdown=$true
            }
            $FoundInterface.speed=$interface.speed
            $FoundInterface.duplex=$interface.duplex
            if($interface.'current-physical-address' ){
                $FoundInterface.macaddress=$interface.'current-physical-address'
            }
        }
    }
    return $device
}


#This takes and array of vlans and vlan name to search for and returns the vlan id. AKA 0 - 4096.
function Get-JunosVlanFromVLANArray{
    param (
		[parameter(Mandatory=$true)]
		$VlanArray,
        $VlanName,
        $Device
    )
    foreach($vlan in $VlanArray){
        if($VlanName -eq $vlan.name){
            return $vlan.number
        }
    }
    Add-HostDebugText -HostObject $Device "Cant find vlan name in list. $($VlanName) in $($VlanArray)" -ForegroundColor red
    return $null
}














#
# Extracts all ARP entries from a Junos 'show arp' XML file using the existing object creator.
#
function Get-JunosArpTableFromXML {
    param (
        [parameter(Mandatory = $true)]
        $JunosArpFile,
        [parameter(Mandatory = $true)]
        $Device
    )

    Add-HostDebugText -HostObject $Device "Processing Junos ARP table: $JunosArpFile"

    $AllIPArpObjects = @()

    try {
        # Read the file and cast it directly to an XML object.
        $ArpXml = [xml](Get-Content -Path $JunosArpFile -Raw)
    }
    catch {
        Add-HostDebugText -HostObject $Device "Invalid XML file or could not read file: $JunosArpFile" -BackgroundColor Red
        return $Device # Return the unmodified device object on error
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
        $IPArpObject.cidr = $Device.interfaces | Where-Object { $_.Cidr } | Where-Object {(Find-Subnet -addr1 $_.Cidr -addr2 $IPArpObject.ipaddress).condition } | Select-Object -First 1 | ForEach-Object { $_.cidr }

        # Add the populated object to our collection.
        $AllIPArpObjects += $IPArpObject
    }

    # Assign the completed array of ARP entries to the main device object.
    $Device.IPArpEntries = $AllIPArpObjects

    Add-HostDebugText -HostObject $Device "Finished processing ARP table. Found $($AllIPArpObjects.Count) entries."

    # Return the modified device object.
    return $Device
}

#
# Extracts all MAC address entries from a Junos 'show ethernet-switching table' XML file.
#
function Get-JunosMacAddressTableFromXML {
    param (
        [parameter(Mandatory = $true)]
        $JunosMacTableFile,
        [parameter(Mandatory = $true)]
        $Device
    )

    Add-HostDebugText -HostObject $Device "Processing Junos MAC address table: $JunosMacTableFile"

    try {
        # Read the file and cast it directly to an XML object.
        $MacXml = [xml](Get-Content -Path $JunosMacTableFile -Raw)
    }
    catch {
        Add-HostDebugText -HostObject $Device "Invalid XML file or could not read file: $JunosMacTableFile" -BackgroundColor Red
        return $Device # Return the unmodified device object on error
    }

    # Iterate through each <mac-table-entry> node in the XML.
    foreach ($entry in $MacXml.'rpc-reply'.'ethernet-switching-table-information'.'ethernet-switching-table'.'mac-table-entry') {

        # Skip entries that are not useful (e.g., Flood entries or internal router entries).
        if ($entry.'mac-address' -eq '*' -or $entry.'mac-interface' -eq 'Router') {
            continue
        }

        # Use the existing Create-MacAddressObject function for consistency.
        $MacObject = Create-MacAddressObject

        # Populate the object with data from the XML nodes.
        $MacObject.MacAddress = $entry.'mac-address'
        $MacObject.Vlan       = $entry.'mac-vlan-tag'
        $MacObject.Type       = $entry.'mac-type'

        # Clean up the interface name (e.g., "ge-0/0/23.0" becomes "ge-0/0/23") to match other configs.
        $MacObject.Interface  = $entry.'mac-interface' -replace '\.0$', ''

        # Find the corresponding interface object on the device.
        $DeviceInterface = $Device.interfaces | Where-Object { $_.interface -eq $MacObject.Interface }

        if ($DeviceInterface) {
            # If the interface is found, add the new MAC address object to its array.
            $DeviceInterface.MacAddressArray += $MacObject
        }
        else {
            Add-HostDebugText -HostObject $Device "Could not find interface $($MacObject.Interface) to associate MAC address $($MacObject.MacAddress) with." -BackgroundColor Yellow
        }
    }

    Add-HostDebugText -HostObject $Device "Finished processing MAC address table."
    return $Device
}








#region Helper Functions
function Convert-CidrToSubnetMask {
    param([int]$Cidr)
    if ($Cidr -lt 0 -or $Cidr -gt 32) { return $null }
    $binaryString = ('1' * $Cidr).PadRight(32, '0')
    $octets = for ($i = 0; $i -lt 4; $i++) {
        [Convert]::ToByte($binaryString.Substring($i * 8, 8), 2)
    }
    return $octets -join '.'
}

function Get-NetworkAddress {
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
function Get-JunosShowRunFromXML {
    param (
        [parameter(Mandatory = $true)]
        $Lconfig
    )

    $Device = Create-HostObject
    $Device.Origin = "config"
    $ArrayOfHostNetworks = @()
    $hostname = $Lconfig.'rpc-reply'.configuration.system.'host-name'
    if ($null -eq $hostname -or $hostname -eq "") {
        $hostname = "NoHostNameFoundCheckForConfigProblems"
        Add-HostDebugText -HostObject $Device "No hostname found in Junos config" -BackgroundColor red
    }
    $Device.hostname = $hostname

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

                # --- START: CORRECTED member-range PARSING ---
                foreach ($memberRange in @($rangeNode.'member-range')) {
                    if ($memberRange.name -match '(.+/)(\d+)$') {
                        # Capture the results from the first match immediately
                        $prefix = $matches[1]
                        $start = [int]$matches[2]

                        # Now, perform the second match
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
                # --- END: CORRECTED member-range PARSING ---

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
                    $obj.shutdown = [bool]($unit.disable)
                    $obj.SwitchPortType = 'routed'
                    $obj.RoutedVlan = $unit.name

                    $inet = $unit.family.inet
                    if ($inet.address) {
                        $addresses = @($inet.address)
                        if ($addresses[0].name) {
                            try {
                                $ipParts = $addresses[0].name.Split('/')
                                if ($ipParts.Count -lt 2) { throw "IP address format is missing the CIDR prefix (e.g., /24)." }
                                $prefix = [int]$ipParts[1]
                                $obj.IPAddress = $ipParts[0]
                                $obj.SubnetMask = Convert-CidrToSubnetMask -Cidr $prefix
                                $networkAddr = Get-NetworkAddress -IPAddress $obj.IPAddress -PrefixLength $prefix
                                $obj.Cidr = "$networkAddr/$prefix"
                                $ArrayOfIPAddresses += $obj.IPAddress
                            } catch {
                                Write-Warning "Failed to parse IP Address '$($addresses[0].name)' on interface '$($obj.Interface)'. Error: $($_.Exception.Message)"
                            }
                        }
                        if ($addresses.Count -gt 1 -and $addresses[1].name) {
                            try {
                                $ipParts = $addresses[1].name.Split('/')
                                if ($ipParts.Count -lt 2) { throw "Secondary IP address format is missing the CIDR prefix (e.g., /24)." }
                                $prefix = [int]$ipParts[1]
                                $obj.SecondaryIPAddress = $ipParts[0]
                                $obj.SecondarySubnetMask = Convert-CidrToSubnetMask -Cidr $prefix
                            } catch {
                                Write-Warning "Failed to parse Secondary IP Address '$($addresses[1].name)' on interface '$($obj.Interface)'. Error: $($_.Exception.Message)"
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
                            if ($configToApply.disable) { $obj.shutdown = $true }
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
                if ($ifaceNode.disable) { $obj.shutdown = $true }
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
                    $ifaceObj.SwitchportAccessVlan = $parentAe.SwitchportAccessVlan
                    $ifaceObj.SwitchportTrunkVlan  = $parentAe.SwitchportTrunkVlan
                    $ifaceObj.NativeVlan           = $parentAe.NativeVlan
                    $ifaceObj.IPAddress            = $parentAe.IPAddress
                    $ifaceObj.SubnetMask           = $parentAe.SubnetMask
                    $ifaceObj.Cidr                 = $parentAe.Cidr
                }
            }
        }
    }

    [array]$interfaces = $interfaceObjects.Values | Sort-Object { $_.Interface -replace '\d+', { $_.Value.PadLeft(4, '0') } }

    foreach ($ag in ($interfaces | where { $_.interface -like "ae*"})) {
        $ag.ShapeColor = "$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0)"
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

    $Device.ArrayOfIPAddresses = $ArrayOfIPAddresses
    $Device.ArrayOfNetworks = $ArrayOfHostNetworks
    $Device.vlans = $vlanPSObjects
    $Device.interfaces = $interfaces

    $ipReport = $interfaces | Where-Object { $_.IPAddress } | ForEach-Object {
        $prefix = if ($_.Cidr) { ($_.Cidr -split '/')[1] } else { 'N/A' }
        "$($_.Interface): $($_.IPAddress)/$prefix"
    }
    Add-HostDebugText -HostObject $Device "Final Parsed IP Report: $($ipReport -join '; ')"

    return $Device
}



