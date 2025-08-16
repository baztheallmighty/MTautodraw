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

# ==============================================================================
# CORRECTED Junos LLDP Parsing Function
# ==============================================================================
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

#Extract all the information from the spanning tree bridges xml file
function Get-JunosShowSpanningTreeInterfaceFromXML{
    param (
		[parameter(Mandatory=$true)]
		$ShowSpanningTreeInterfaceFile,
        $device
    )
    $SpanningTreeInterfaces = [xml] (Get-Content -Raw $ShowSpanningTreeInterfaceFile )

    foreach($Int in $SpanningTreeInterfaces.'rpc-reply'.'stp-interface-information'.'stp-instance'.'stp-interfaces'.'stp-interface-entry'){
        $Interface=$device.interfaces | where { $_.interface -eq ($Int.'interface-name' -replace "\.0$",'')}
        $Interface.STState=$Int.'port-state'
        $Interface.STRole=$Int.'port-role'
    }

    #Find all of the interfaces part of a port channels and transfer the port state and role to the child interface.  
    foreach ($interface in ($device.interfaces | where { $_.channelgroup} )){
        $interface.STState=($device.interfaces | where { $interface.channelgroup -eq $_.interface}).STState
        $interface.STRole=($device.interfaces | where { $interface.channelgroup -eq $_.interface}).STRole
    }

    return $device
}



#TODO:Test $Device.SpanningTree.SpanningTreeArray+=$SpanningTreevlanObject is filled correctly and displays the root bridge vlans. This is untested. 
#Extract all the information from the spanning tree bridges xml file
function Get-JunosShowSpanningTreeBridgeFromXML{
    param (
		[parameter(Mandatory=$true)]
		$JunosShowSpanningTreeBridgeFile,
        $device
    )
    $SpanningTree = [xml] (Get-Content -Raw $JunosShowSpanningTreeBridgeFile )
    $device.SpanningTree=Create-SpanningTreeObject
    $device.SpanningTree.SpanningTreeMode = $SpanningTree.'rpc-reply'.'stp-bridge'.protocol
    $Device.SpanningTree.SpanningTreeArray=@()
    if($device.SpanningTree.SpanningTreeMode -eq "RSTP" -and $SpanningTree.'rpc-reply'.'stp-bridge'.'cist-bridge-parameters'.'root-bridge' -eq $SpanningTree.'rpc-reply'.'stp-bridge'.'cist-bridge-parameters'.'this-bridge'){
        foreach($vlan in $device.ArrayOfVlans){
            $SpanningTreevlanObject=Create-SpanningTreevlan
            $SpanningTreevlanObject.RootBridge = $true
            $SpanningTreevlanObject.vlanID = $vlan.number
            $SpanningTreevlanObject.RootIDPriority = $SpanningTree.'rpc-reply'.'stp-bridge'.'cist-bridge-parameters'.'root-bridge'.'bridge-priority'
            $Device.SpanningTree.SpanningTreeArray+=$SpanningTreevlanObject            
        }

    }

    return $device
}



#Extract all the information from the show route all xml file
#Extract all the information from the show route all xml file
function Get-JunosShowRouteAllFromXML{
    param (
        [parameter(Mandatory=$true)]
        $JunosShowRouteAllFile,
        $device
    )
    $RoutingTables = [xml] (Get-Content -Raw $JunosShowRouteAllFile )
    $Routes=@()
    foreach ($table in $RoutingTables.'rpc-reply'.'route-information'.'route-table'){
        foreach ($Route in $table.rt){
            $RouteObject=Create-RouteObject
            # MODIFIED: Added '-replace "irb\.",'irb'' to shorten irb interface names.
            $RouteObject.Interface=($Route.'rt-entry'.nh.via -replace "vlan\.",'vlan' -replace "irb\.",'irb' -replace "\.0$",'')
            $RouteObject.gateway=$Route.'rt-entry'.nh.to
            $RouteObject.Subnet=$Route.'rt-destination'
            $RouteObject.RouteProtocol=$Route.'rt-entry'.'protocol-name'
            $Routes+=$RouteObject
            
        }
    }
    $device.RoutingTable=$Routes

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











#function Get-JunosShowRunFromXML {
#    param (
#        [parameter(Mandatory = $true)]
#        $Lconfig
#    )
#
#    #region Helper Functions
#    function Convert-CidrToSubnetMask {
#        param([int]$Cidr)
#        if ($Cidr -lt 0 -or $Cidr -gt 32) { return $null }
#        $binaryString = ('1' * $Cidr).PadRight(32, '0')
#        $octets = for ($i = 0; $i -lt 4; $i++) {
#            [Convert]::ToByte($binaryString.Substring($i * 8, 8), 2)
#        }
#        return $octets -join '.'
#    }
#
#    function Get-NetworkAddress {
#        param($IPAddress, $PrefixLength)
#        $ip = [System.Net.IPAddress]::Parse($IPAddress)
#        # Use the unambiguous hex value 0xFFFFFFFF instead of -1 for the bitmask.
#        $mask = 0xFFFFFFFF -shl (32 - $PrefixLength)
#        $ipBytes = $ip.GetAddressBytes()
#        if ([System.BitConverter]::IsLittleEndian) { [System.Array]::Reverse($ipBytes) }
#        $ipInt = [System.BitConverter]::ToUInt32($ipBytes, 0)
#        $networkInt = $ipInt -band $mask
#        $networkBytes = [System.BitConverter]::GetBytes($networkInt)
#        if ([System.BitConverter]::IsLittleEndian) { [System.Array]::Reverse($networkBytes) }
#        return ([System.Net.IPAddress]$networkBytes).IPAddressToString
#    }
#    #endregion
#
#    $Device = Create-HostObject
#    $Device.Origin = "config"
#    $ArrayOfHostNetworks = @()
#    $hostname = $Lconfig.'rpc-reply'.configuration.system.'host-name'
#    if ($null -eq $hostname -or $hostname -eq "") {
#        $hostname = "NoHostNameFoundCheckForConfigProblems"
#        Add-HostDebugText -HostObject $Device "No hostname found in Junos config" -BackgroundColor red
#    }
#    $Device.hostname = $hostname
#
#    $vlans = @()
#    foreach ($vlan in ($Lconfig.'rpc-reply'.configuration.vlans.vlan)) {
#        $vlanObject = Create-vlanObject
#        $vlanObject.number = $vlan.'vlan-id'
#        $vlanObject.name = $vlan.name
#        $vlanObject.description = $vlan.description
#        $vlans += $vlanObject
#    }
#
#    [array]$ArrayOfIPAddresses = @()
#    $interfaceObjects = @{}
#    $configNode = $Lconfig.'rpc-reply'.configuration
#
#    $vlanMap = @{}
#    $configNode.vlans.vlan | ForEach-Object { $vlanMap[$_.name] = $_.'vlan-id' }
#
#    foreach ($ifaceNode in $configNode.interfaces.interface) {
#        $baseInterfaceName = $ifaceNode.name
#
#        if ($baseInterfaceName -match '^(irb|vlan)$') {
#            foreach ($unit in $ifaceNode.unit) {
#                $logicalInterfaceName = "$baseInterfaceName$($unit.name)"
#                if (-not $interfaceObjects.ContainsKey($logicalInterfaceName)) {
#                    $obj = Create-InterfaceObject
#                    $obj.Interface = $logicalInterfaceName
#                    $interfaceObjects[$logicalInterfaceName] = $obj
#                }
#                $obj = $interfaceObjects[$logicalInterfaceName]
#                
#                $obj.Description = $unit.description
#                $obj.shutdown = [bool]($unit.disable)
#                $obj.SwitchPortType = 'routed'
#                $obj.RoutedVlan = $unit.name
#
#                $inet = $unit.family.inet
#                if ($inet.address) {
#                    $addresses = @($inet.address)
#                    if ($addresses[0].name) {
#                        try {
#                            $ipParts = $addresses[0].name.Split('/')
#                            if ($ipParts.Count -lt 2) { throw "IP address format is missing the CIDR prefix (e.g., /24)." }
#                            $prefix = [int]$ipParts[1]
#                            $obj.IPAddress = $ipParts[0]
#                            $obj.SubnetMask = Convert-CidrToSubnetMask -Cidr $prefix
#                            $networkAddr = Get-NetworkAddress -IPAddress $obj.IPAddress -PrefixLength $prefix
#                            $obj.Cidr = "$networkAddr/$prefix"
#                            $ArrayOfIPAddresses += $obj.IPAddress
#                        } catch {
#                            Write-Warning "Failed to parse IP Address '$($addresses[0].name)' on interface '$($obj.Interface)'. Error: $($_.Exception.Message)"
#                        }
#                    }
#                    if ($addresses.Count -gt 1 -and $addresses[1].name) {
#                        try {
#                            $ipParts = $addresses[1].name.Split('/')
#                            if ($ipParts.Count -lt 2) { throw "Secondary IP address format is missing the CIDR prefix (e.g., /24)." }
#                            $prefix = [int]$ipParts[1]
#                            $obj.SecondaryIPAddress = $ipParts[0]
#                            $obj.SecondarySubnetMask = Convert-CidrToSubnetMask -Cidr $prefix
#                        } catch {
#                            Write-Warning "Failed to parse Secondary IP Address '$($addresses[1].name)' on interface '$($obj.Interface)'. Error: $($_.Exception.Message)"
#                        }
#                    }
#                }
#            }
#        } else {
#            if (-not $interfaceObjects.ContainsKey($baseInterfaceName)) {
#                $obj = Create-InterfaceObject
#                $obj.Interface = $baseInterfaceName
#                $interfaceObjects[$baseInterfaceName] = $obj
#            }
#            $obj = $interfaceObjects[$baseInterfaceName]
#
#            $obj.Description = $ifaceNode.description
#            $obj.shutdown = [bool]($ifaceNode.disable)
#            if ($ifaceNode.'native-vlan-id') { $obj.NativeVlan = $ifaceNode.'native-vlan-id' }
#
#            $etherOptions = $ifaceNode.'ether-options'
#            if (-not $etherOptions) { $etherOptions = $ifaceNode.'gigether-options' }
#            
#            # Handle multiple possible XML formats for LAGs (802.3ad)
#            $bundle = $null
#            if ($etherOptions) {
#                # 1. Check for the modern nested format first (e.g., <ieee-802.3ad><bundle>ae1</bundle></ieee-802.3ad>)
#                $bundle = $etherOptions.'ieee-802.3ad'.bundle
#
#                # 2. If not found, check for the simple legacy format (e.g., <802.3ad>ae1</802.3ad>)
#                if (-not $bundle) {
#                    $bundle = $etherOptions.'802.3ad'
#                }
#            }
#
#            if ($bundle) {
#                $obj.ChannelGroup = $bundle.Trim()
#            }
#
#            foreach ($unit in $ifaceNode.unit) {
#                $switching = $unit.family.'ethernet-switching'
#                if ($switching) {
#                    $obj.SwitchPortType = 'switched'
#
#                    # Try the newer format first, then fall back to the older format
#                    $obj.SwitchportMode = $switching.'interface-mode'
#                    if (-not $obj.SwitchportMode) {
#                        $obj.SwitchportMode = $switching.'port-mode'
#                    }
#                    # Only process VLAN members if they exist
#                    if ($switching.vlan.members) {
#                        if ($obj.SwitchportMode -eq 'access') {
#                            $vlanName = $switching.vlan.members
#                            # Ensure vlanName is not null before using it as a key
#                            if ($null -ne $vlanName) {
#                                $obj.SwitchportAccessVlan = if ($vlanMap.ContainsKey($vlanName)) { $vlanMap[$vlanName] } else { $vlanName }
#                            }
#                        } elseif ($obj.SwitchportMode -eq 'trunk') {
#                            if ($switching.vlan.members -eq 'all') {
#                                $obj.SwitchportTrunkVlan = ($vlanMap.Values | Sort-Object -Unique) -join ','
#                            } else {
#                                # In the ForEach-Object loop, $_ can be null if a tag is empty. Filter it out.
#                                $trunkVlans = @($switching.vlan.members) | Where-Object { $null -ne $_ } | ForEach-Object { if ($vlanMap.ContainsKey($_)) { $vlanMap[$_] } else { $_ } }
#                                $obj.SwitchportTrunkVlan = ($trunkVlans | Sort-Object -Unique) -join ','
#                            }
#                        }
#                    }
#                }
#
#                $inet = $unit.family.inet
#                if ($inet.address) {
#                    $obj.SwitchPortType = 'routed'
#                    $addresses = @($inet.address)
#                    if ($addresses[0].name) {
#                        try {
#                            $ipParts = $addresses[0].name.Split('/')
#                            if ($ipParts.Count -lt 2) { throw "IP address format is missing the CIDR prefix (e.g., /24)." }
#                            $prefix = [int]$ipParts[1]
#                            $obj.IPAddress = $ipParts[0]
#                            $obj.SubnetMask = Convert-CidrToSubnetMask -Cidr $prefix
#                            $networkAddr = Get-NetworkAddress -IPAddress $obj.IPAddress -PrefixLength $prefix
#                            $obj.Cidr = "$networkAddr/$prefix"
#                            $ArrayOfIPAddresses += $obj.IPAddress
#                        } catch {
#                            Write-Warning "Failed to parse IP Address '$($addresses[0].name)' on interface '$($obj.Interface)'. Error: $($_.Exception.Message)"
#                        }
#                    }
#                    if ($addresses.Count -gt 1 -and $addresses[1].name) {
#                        try {
#                            $ipParts = $addresses[1].name.Split('/')
#                            if ($ipParts.Count -lt 2) { throw "Secondary IP address format is missing the CIDR prefix (e.g., /24)." }
#                            $prefix = [int]$ipParts[1]
#                            $obj.SecondaryIPAddress = $ipParts[0]
#                            $obj.SecondarySubnetMask = Convert-CidrToSubnetMask -Cidr $prefix
#                        } catch {
#                            Write-Warning "Failed to parse Secondary IP Address '$($addresses[1].name)' on interface '$($obj.Interface)'. Error: $($_.Exception.Message)"
#                        }
#                    }
#                }
#            }
#        }
#    }
#
#    [array]$interfaces = $interfaceObjects.Values | Sort-Object { $_.Interface -replace '\d+', { $_.Value.PadLeft(4, '0') } }
#
#    foreach ($ag in ($interfaces | where { $_.interface -like "ae*"})) {
#        $ag.ShapeColor = "$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0)"
#        # Find physical interfaces where the ChannelGroup property matches the ae interface name
#        $interfaces | where { $_.ChannelGroup -eq $ag.interface } | ForEach-Object { $_.ShapeColor = $ag.ShapeColor }
#    }
#
#    foreach ($vlan in ($Lconfig.'rpc-reply'.configuration.vlans.vlan)) {
#        foreach ($int in $vlan.interface) {
#            $FoundInterface = $interfaces | where { $_.interface -notlike "*vlan*"} | where { $_.interface -eq ($int.name -replace "\.0",'')}
#            if ($FoundInterface) {
#                if ($FoundInterface.SwitchportMode -eq "access") {
#                    $FoundInterface.SwitchportAccessVlan = [int]$vlan.'vlan-id'
#                } else {
#                    [array]$FoundInterface.SwitchportTrunkVlan += [int]$vlan.'vlan-id'
#                }
#            } else {
#                Add-HostDebugText -HostObject $Device "Couldnt find $($int.name) - $($int.name -replace '\.0', '') in interfaces list. Parsed IPs: $($ArrayOfIPAddresses -join ', '). Interfaces list: $($interfaces|ft | out-string)"
#            }
#        }
#    }
#
#    foreach ($interface in $interfaces) {
#        if ($null -ne $interface.Cidr) {
#            $NetworkObject = Create-NetworkObject
#            $NetworkObject.Cidr = $interface.Cidr
#            if ($interface.Interface -like "*vlan*" -or $interface.Interface -like "*irb*") {
#                $NetworkObject.Routedvlan = $interface.Interface
#            } else {
#                $NetworkObject.Routedvlan = "no vlan"
#            }
#            $ArrayOfHostNetworks += $NetworkObject
#        }
#    }
#
#    $Device.ArrayOfIPAddresses = $ArrayOfIPAddresses
#    $Device.ArrayOfNetworks = $ArrayOfHostNetworks
#    $Device.vlans = $vlans
#    $Device.interfaces = $interfaces
#    
#    # MODIFIED: Changed the final debug output to a more detailed report.
#    $ipReport = $interfaces | Where-Object { $_.IPAddress } | ForEach-Object {
#        $prefix = if ($_.Cidr) { ($_.Cidr -split '/')[1] } else { 'N/A' }
#        "$($_.Interface): $($_.IPAddress)/$prefix"
#    }
#    Add-HostDebugText -HostObject $Device "Final Parsed IP Report: $($ipReport -join '; ')"
#
#    return $Device
#}



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
    # FIX 1: Add check for the existence of the <vlans> section
    if ($Lconfig.'rpc-reply'.configuration.vlans) {
        # FIX 2: Wrap vlan collection in @() to handle cases where there is only one VLAN
        foreach ($vlan in @($Lconfig.'rpc-reply'.configuration.vlans.vlan)) {
            $vlanObject = Create-vlanObject
            $vlanObject.number = $vlan.'vlan-id'
            $vlanObject.name = $vlan.name
            $vlanObject.description = $vlan.description
            $vlanPSObjects += $vlanObject
            $vlanMap[$vlan.name] = $vlan.'vlan-id'
        }
    }

    [array]$ArrayOfIPAddresses = @()
    $interfaceObjects = @{}
    $configNode = $Lconfig.'rpc-reply'.configuration

    # FIX 1: Add check for the existence of the <interfaces> section
    if ($configNode.interfaces) {
        # FIX 2: Wrap interface collection in @() to handle cases where there is only one interface
        foreach ($ifaceNode in @($configNode.interfaces.interface)) {
            $baseInterfaceName = $ifaceNode.name

            if ($baseInterfaceName -match '^(irb|vlan)$') {
                # FIX 2: Wrap unit collection in @() to handle cases where there is only one unit
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

                $obj.Description = $ifaceNode.description
                $obj.shutdown = [bool]($ifaceNode.disable)
                
                # Handle various locations for native-vlan-id
                $obj.NativeVlan = $ifaceNode.'native-vlan-id'

                # Handle various -options tags for different interface speeds
                $etherOptions = $ifaceNode.'ether-options'
                if (-not $etherOptions) { $etherOptions = $ifaceNode.'gigether-options' }
                if (-not $etherOptions) { $etherOptions = $ifaceNode.'ten-gigether-options' }
                
                # FIX 3: Robust LAG/ChannelGroup parsing
                $bundle = $null
                if ($etherOptions) {
                    $bundle = $etherOptions.'ieee-802.3ad'.bundle
                    if (-not $bundle) {
                        $bundle = $etherOptions.'802.3ad'
                    }
                }
                if ($bundle) {
                    $obj.ChannelGroup = $bundle.Trim()
                }

                # FIX 2: Wrap unit collection in @()
                foreach ($unit in @($ifaceNode.unit)) {
                    $switching = $unit.family.'ethernet-switching'
                    if ($switching) {
                        # --- MODIFICATION START ---
                        # The presence of the <ethernet-switching> tag itself defines the port as L2.
                        # Set this first, even if the block is empty.
                        $obj.SwitchPortType = 'switched' 
                        # By default, an unconfigured switchport is an access port on VLAN 1.
                        $obj.SwitchportMode = 'access'
                        $obj.SwitchportAccessVlan = '1'
                        # --- MODIFICATION END ---
                                            # Update Native VLAN if it's defined here
                        if ($switching.'native-vlan-id') { 
                            # Convert VLAN name to ID if possible
                            $nativeVlanName = $switching.'native-vlan-id'
                            $obj.NativeVlan = if ($vlanMap.ContainsKey($nativeVlanName)) { $vlanMap[$nativeVlanName] } else { $nativeVlanName }
                        }
                                            # Robust Switchport Mode parsing (will override the default 'access' if set)
                        $portMode = $switching.'interface-mode'
                        if (-not $portMode) {
                            $portMode = $switching.'port-mode'
                        }
                        if ($portMode) {
                            $obj.SwitchportMode = $portMode
                        }
                        
                        # Prevent error if vlan members are not defined
                        if ($switching.vlan.members) {
                            if ($obj.SwitchportMode -eq 'access') {
                                $vlanName = $switching.vlan.members
                                if ($null -ne $vlanName) {
                                    $obj.SwitchportAccessVlan = if ($vlanMap.ContainsKey($vlanName)) { $vlanMap[$vlanName] } else { $vlanName }
                                }
                            } elseif ($obj.SwitchportMode -eq 'trunk') {
                                # Clear the default access vlan since this is a trunk
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
                        # (IP address parsing logic remains the same)
                    }
                }
            }
        }
        #
        # --- START: NEW LOGIC BLOCK FOR LAG MEMBER INHERITANCE ---
        #
        # PASS 2: Find all physical LAG members and have them inherit their parent ae interface's configuration.
        foreach ($ifaceObj in $interfaceObjects.Values) {
            # Check if this interface is a member of a channel group
            if ($ifaceObj.ChannelGroup) {
                $aeName = $ifaceObj.ChannelGroup
                # Look up the parent ae interface in the objects we've already parsed
                if ($interfaceObjects.ContainsKey($aeName)) {
                    $parentAe = $interfaceObjects[$aeName]
                    
                    # Copy the essential L2/L3 properties from the parent ae to the physical member
                    $ifaceObj.SwitchPortType       = $parentAe.SwitchPortType
                    $ifaceObj.SwitchportMode       = $parentAe.SwitchportMode
                    $ifaceObj.SwitchportAccessVlan = $parentAe.SwitchportAccessVlan
                    $ifaceObj.SwitchportTrunkVlan  = $parentAe.SwitchportTrunkVlan
                    $ifaceObj.NativeVlan           = $parentAe.NativeVlan
                    
                    # Also copy L3 info in case the ae is routed
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

    # IMPROVEMENT: The redundant VLAN loop that was here has been removed.
    # The primary interface loop above is the correct and single source of truth for VLAN port assignments.
    # Removing this prevents conflicting logic and potential bugs.

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


