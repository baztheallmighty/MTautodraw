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
        Add-HostDebugText -HostObject $Device "Processing Junos show config"
        $Device=$null
        if($hostid.showrun -and (Test-Path -Path $hostid.showrun)){
            try{
                $config=[xml] (Get-Content -Path $hostid.showrun -raw)
            }
            catch {
                write-host "Invalid XML file: $($hostid.showrun) exiting" -BackgroundColor red
                return $null
            }
            $Device=Get-JunosShowRunFromXML -Lconfig $config
            $Device.DeviceIdentifier=($hostid.showrun -replace "\.show run.*",'' -replace "^.*\\",'' -replace "\.show configuration.*",'' )
        }else{
            write-host "File doesn't exist: $($hostid.showrun)" -BackgroundColor red
            return $null
        }
        
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



#Extract all the information from the neighbors xml file
function Get-JunosShowLLDPNeighbors{
    param (
		[parameter(Mandatory=$true)]
		$JunosShowLLDPNeighborsFile,
        $device
    )
    #TODO: Add error check here for xml file reading and empty files etc. 
    $Neighbors = [xml] (Get-Content -Raw $JunosShowLLDPNeighborsFile )
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
            $LLDPObject.InterfaceLocalDevice=($Neighbor.'lldp-local-interface' -replace "\.0",'')
        }elseif($Neighbor.'lldp-local-port-id'){
            $LLDPObject.InterfaceLocalDevice=($Neighbor.'lldp-local-port-id' -replace "\.0",'')
        }else{
            $LLDPObject.InterfaceLocalDevice="Unknown, probably a issue with XML extraction on a junos device.$(Get-Random)"
        }
        $LLDPObject.ChassisID=$Neighbor.'lldp-remote-chassis-id'
        
        $LLDPObject.SystemDescription=$Neighbor.'lldp-remote-port-description'
        $LLDPObject.InterfaceRemoteDevice=$Neighbor.'lldp-remote-port-description'
        if(($LLDPObject.InterfaceRemoteDevice -eq "") -or ($null -eq $LLDPObject.InterfaceRemoteDevice)){
            $LLDPObject.InterfaceRemoteDevice="Unknown Interface"
        }
        if($LLDPObject.InterfaceRemoteDevice -match "\w+-\d+\/\d+/\d+.0$"){
            #Probably another Junpier. Lets fix the name. 
            $LLDPObject.InterfaceRemoteDevice=$LLDPObject.InterfaceRemoteDevice -replace "\.0",''
        }
        if($LLDPObject.InterfaceRemoteDevice -match  "^[A-Z][A-Za-z]+\s?([0-9]+/){0,}[0-9]+$"){
            #probably a cisco interface lets fix the interface name to be longer. 
            $LLDPObject.InterfaceRemoteDevice=Replace-InterfaceShortName -string $LLDPObject.InterfaceRemoteDevice 
        }

        $TempInterface=$null
        $TempInterface=$device.interfaces | where { $_.interface -eq $LLDPObject.InterfaceLocalDevice}
        $TempInterface.HasLLDPNeighbor = $true

        $AllLLDPDetailsObjects+=$LLDPObject
    }
    #Do we have duplicate interfaces names on the same host. If so lets change there names. 
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
            $RouteObject.Interface=($Route.'rt-entry'.nh.via -replace "vlan\.",'vlan' -replace "\.0$",'')
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
    
    
    
#Read in the checkpoint config. and process it.
#Note:These is limited processing of the show config for now. This will be expanded in future as required.
function Get-JunosShowRunFromXML{
    param (
		[parameter(Mandatory=$true)]
		$Lconfig
    )
    #Create host/device object to hold all the parsed data
    $Device=Create-HostObject
    $Device.Origin="config"
    $ArrayOfHostNetworks=@()
    $hostname = $Lconfig.'rpc-reply'.configuration.system.'host-name'
    if($null -eq $hostname  -or $hostname -eq "" ){
        $hostname = "NoHostNameFoundCheckForConfigProblems"
        Add-HostDebugText -HostObject $Device "No hostname found in Junos config"  -BackgroundColor red
    }
    $Device.hostname = $hostname
    #Process vlans
    $vlans=@()
    foreach ($vlan in ($Lconfig.'rpc-reply'.configuration.vlans.vlan)){
            $vlanObject = Create-vlanObject
            $vlanObject.number =   $vlan.'vlan-id'
            $vlanObject.name = $vlan.name
            $vlanObject.description = $vlan.description
            $vlans+=$vlanObject
    }
    [array]$ArrayOfIPAddresses=@()
    [array]$interfaces = @()
    foreach ($interface in $Lconfig.'rpc-reply'.configuration.interfaces.interface){
        if($interface.name -eq "vlan"){#This is an array of vlan interfaces
            foreach ($vlanInt in ($interface.unit)){
                $interfaceObject                = Create-InterfaceObject
                $interfaceObject.Interface      = "vlan$($vlanInt.name)"
                $interfaceObject.shutdown       = $false
                $interfaceObject.SwitchPortType = 'Routed'
                if($vlanInt.Innerxml -notlike "*dhcp*"){                 
                    $interfaceObject.IPAddress      = ($vlanInt.family.Innertext -split "/")[0]
                    $interfaceObject.SubnetMask     = ($vlanInt.family.Innertext -split "/")[1]
                    if($null -ne $interfaceObject.IPAddress  -and $null -ne $interfaceObject.SubnetMask ){
                        $interfaceObject.Cidr = (Get-IPv4Subnet -IPAddress $interfaceObject.IPAddress  -PrefixLength $interfaceObject.SubnetMask).cidrid
                    }
                    if($interfaceObject.IPAddress){
                        $ArrayOfIPAddresses+=$interfaceObject.IPAddress
                    }                       
                }else{
                    $interfaceObject.IPAddress = "DHCP"
                }
                 
                $interfaces += $interfaceObject
            }
        }else{
            $interfaceObject = Create-InterfaceObject
            $interfaceObject.shutdown=$false
            $interfaceObject.Interface   = $interface.name
            $interfaceObject.Description = $interface.Description
            if($interface.unit.family.'ethernet-switching'.'port-mode'){
                $interfaceObject.SwitchportMode = $interface.unit.family.'ethernet-switching'.'port-mode'
                if($interfaceObject.SwitchportMode -eq "access"){
                    $interfaceObject.SwitchportAccessVlan = Get-JunosVlanFromVLANArray -VlanArray $vlans -VlanName $interface.unit.family.'ethernet-switching'.vlan.members -Device $Device
                }else{
                    foreach ($vlan in $interface.unit.family.'ethernet-switching'.vlan.members){
                        if($interfaceObject.SwitchportTrunkVlan){
                            $interfaceObject.SwitchportTrunkVlan += ",$(Get-JunosVlanFromVLANArray -VlanArray $vlans -VlanName $vlan -Device $Device )"
                        }else{
                            $interfaceObject.SwitchportTrunkVlan += "$(Get-JunosVlanFromVLANArray -VlanArray $vlans -VlanName $vlan -Device $Device )"
                        }
                    }
                    if($interface.unit.family.'ethernet-switching'.'native-vlan-id'){
                        $interfaceObject.SwitchportTrunkVlan += ",$(Get-JunosVlanFromVLANArray -VlanArray $vlans -VlanName $interface.unit.family.'ethernet-switching'.'native-vlan-id' -Device $Device)"
                        $interfaceObject.NativeVlan = Get-JunosVlanFromVLANArray -VlanArray $vlans -VlanName $interface.unit.family.'ethernet-switching'.'native-vlan-id' -Device $Device
                    }
                    
                }
            }else{
                $interfaceObject.SwitchportMode = 'access' #default to access port. This may not be the best option.
            }

            $interfaceObject.ChannelGroup =  $interface.'ether-options'.'ieee-802.3ad'.bundle
            
            #TODO:test. This may need fixing. Untested. TODO:DHCP fix. 
            if($interface.unit.family.inet.address.name){
                $interfaceObject.SwitchPortType = 'Routed'
                $interfaceObject.IPAddress  = ($interface.unit.family.inet.address.name -split "/")[0]
                $interfaceObject.SubnetMask = ($interface.unit.family.inet.address.name -split "/")[1]
            }
            if($null -ne $interfaceObject.IPAddress  -and $null -ne $interfaceObject.SubnetMask ){
                $interfaceObject.Cidr = (Get-IPv4Subnet -IPAddress $interfaceObject.IPAddress  -PrefixLength $interfaceObject.SubnetMask).cidrid
            }
            if($interfaceObject.IPAddress){
                $ArrayOfIPAddresses+=$interfaceObject.IPAddress
            }            
              
            
            $interfaces += $interfaceObject            
        }


    }
    #Add colors for aggregated interfaces. 
    foreach($ag in ($interfaces | where { $_.interface -like "ae*"})){
        $ag.ShapeColor = "$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0)"
        $interfaces | where { $_.ChannelGroup -eq ($ag.interface -replace "(p|P)ort\-channel\s*",'')} | % { $_.ShapeColor = $ag.ShapeColor }
    }
    #We have to add interfaces that don't have a access vlan or are trunk all vlans in there config and hence we have to add all the vlans. This is normally old versions of junos that cause this problem. 
    foreach ($vlan in ($Lconfig.'rpc-reply'.configuration.vlans.vlan)){
        foreach ($int in $vlan.interface){
            $FoundInterface = $interfaces | where { $_.interface -notlike "*vlan*"} | where { $_.interface -eq ($int.name -replace "\.0",'')}
            if($FoundInterface){
                if($FoundInterface.SwitchportMode -eq "access"){
                    $FoundInterface.SwitchportAccessVlan = [int]$vlan.'vlan-id'
                }else{
                    [array]$FoundInterface.SwitchportTrunkVlan += [int]$vlan.'vlan-id'
                }
            }else{
                Add-HostDebugText -HostObject $Device "Couldnt find $($int.name) - $($int.name -replace "\.0",'') in $($interfaces|ft | out-string)"
            }
        }
    }
    
    foreach($interface in $interfaces){
        if($null -ne $interface.Cidr){
            $NetworkObject = Create-NetworkObject
            $NetworkObject.Cidr = $interface.Cidr
            if( $interface.Interface -like "*vlan*"){
                $NetworkObject.Routedvlan = $interface.Interface
            }else {
                $NetworkObject.Routedvlan = "no vlan"
            }
            $ArrayOfHostNetworks += $NetworkObject
        }  
    }
    $Device.ArrayOfIPAddresses=$ArrayOfIPAddresses
    $Device.ArrayOfNetworks=$ArrayOfHostNetworks
    $Device.vlans = $vlans
    $Device.interfaces = $interfaces
    $Device.vrfs = $vrfs


    return $Device
}
