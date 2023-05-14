#The MIT License (MIT)
#
#Copyright © 2023 Myles Treadwell
#
#Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#
#The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
#
#THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#


#This contains all of the object definitions.


function Create-BGPNeighborsObject(){
    $newObject = New-Object -TypeName PSObject                           -value $null
    $newObject| Add-Member -type NoteProperty -Name NEIGHBOR             -value $null
    $newObject| Add-Member -type NoteProperty -Name SOURCE_IFACE         -value $null
    $newObject| Add-Member -type NoteProperty -Name REMOTE_AS            -value $null
    $newObject| Add-Member -type NoteProperty -Name PEER_GROUP           -value $null
    $newObject| Add-Member -type NoteProperty -Name REMOTE_ROUTER_ID     -value $null
    $newObject| Add-Member -type NoteProperty -Name BGP_STATE            -value $null
    $newObject| Add-Member -type NoteProperty -Name LOCALHOST_IP         -value $null
    $newObject| Add-Member -type NoteProperty -Name LOCALHOST_PORT       -value $null
    $newObject| Add-Member -type NoteProperty -Name REMOTE_IP            -value $null
	$newObject| Add-Member -type NoteProperty -Name REMOTE_PORT          -value $null
	$newObject| Add-Member -type NoteProperty -Name INBOUND_ROUTEMAP     -value $null
	$newObject| Add-Member -type NoteProperty -Name OUTBOUND_ROUTEMAP    -value $null
    return $newObject
}



function Create-ShowIPArpObject(){
    $newObject = New-Object -TypeName PSObject
    $newObject| Add-Member -type NoteProperty -Name PROTOCOL -value $null                      #PROTOCOL
    $newObject| Add-Member -type NoteProperty -Name ipaddress -value $null                     #ADDRESS
    $newObject| Add-Member -type NoteProperty -Name AGE -value $null                           #AGE
    $newObject| Add-Member -type NoteProperty -Name MAC -value $null                           #MAC
    $newObject| Add-Member -type NoteProperty -Name TYPE -value $null                          #TYPE
    $newObject| Add-Member -type NoteProperty -Name INTERFACE -value $null                     #normally a vlan interface
    $newObject| Add-Member -type NoteProperty -Name VendorCompanyName -value $null             #VendorCompanyName
    $newObject| Add-Member -type NoteProperty -Name Cidr -value $null                          #cidr
    return $newObject
}



function Create-ShowVersionObject(){
    $newObject = New-Object -TypeName PSObject
    $newObject| Add-Member -type NoteProperty -Name OS -value $null                     #VERSION | OS
    $newObject| Add-Member -type NoteProperty -Name ROMMON -value $null                 #ROMMON
    $newObject| Add-Member -type NoteProperty -Name Hostname -value $null               #HOSTNAME
    $newObject| Add-Member -type NoteProperty -Name Uptime -value $null                 #UPTIME
    $newObject| Add-Member -type NoteProperty -Name UptimeYear -value $null             #UPTIME_YEARS
    $newObject| Add-Member -type NoteProperty -Name UptimeWeeks -value $null            #UPTIME_WEEKS
    $newObject| Add-Member -type NoteProperty -Name UptimeDays -value $null             #UPTIME_DAYS
    $newObject| Add-Member -type NoteProperty -Name UpdateHours -value $null            #UPTIME_HOURS
    $newObject| Add-Member -type NoteProperty -Name UptimeMinutes -value $null          #UPTIME_MINUTES
    $newObject| Add-Member -type NoteProperty -Name ReasonForRelod -value $null         #RELOAD_REASON | LAST_REBOOT_REASON
    $newObject| Add-Member -type NoteProperty -Name Image -value $null                  #RUNNING_IMAGE | BOOT_IMAGE
    $newObject| Add-Member -type NoteProperty -Name Hardware -value @()                 #HARDWARE | PLATFORM
    $newObject| Add-Member -type NoteProperty -Name Serial -value @()                   #SERIAL
    $newObject| Add-Member -type NoteProperty -Name ConfigRegister -value $null         #CONFIG_REGISTER
    $newObject| Add-Member -type NoteProperty -Name MacAddressArray -value @()          #MAC
    $newObject| Add-Member -type NoteProperty -Name LastRestarted -value $null          #RESTARTED
    $newObject| Add-Member -type NoteProperty -Name Type -value $null                   #OS type: XE-IOS,NXOS,IOS
    return $newObject
}


#LLDP Neighbour object
#Data from show cdp neighbours details
function Create-LLDPNeighborObject(){
    $newObject = New-Object -TypeName PSObject
    $newObject| Add-Member -type NoteProperty -Name PartnerEthernetInterface -value $null
    $newObject| Add-Member -type NoteProperty -Name InterfaceLocalDevice -value $null               #LOCAL_INTERFACE this is the interface on the local device
    $newObject| Add-Member -type NoteProperty -Name ChassisID -value $null
    $newObject| Add-Member -type NoteProperty -Name InterfaceRemoteDevice -value $null              #Hostname_PORT_ID remote port id
    $newObject| Add-Member -type NoteProperty -Name NeighborInterfaceDescription -value $null       #Hostname_INTERFACE
    $newObject| Add-Member -type NoteProperty -Name Hostname -value $null
    $newObject| Add-Member -type NoteProperty -Name SystemDescription -value $null
    $newObject| Add-Member -type NoteProperty -Name Capabilities -value $null
    $newObject| Add-Member -type NoteProperty -Name ManagementIP -value $null
    $newObject| Add-Member -type NoteProperty -Name VLAN -value $null
    $newObject| Add-Member -type NoteProperty -Name SERIAL -value $null
    $newObject| Add-Member -type NoteProperty -Name PortID -value $null                             #The port id normally is just a mac address. This can be used for matching show lldp neighbors to show lldp neighbors details
    $newObject| Add-Member -type NoteProperty -Name ParentObject -value $null                       #This will be filled for each host object created from LLDP Neighbors config data
    $newObject| Add-Member -type NoteProperty -Name HasCDPNeighborEntry -value $false               #This device has a cdp neighbors entry already. This is used to not draw duplicate entries from CDP neighbors and LLDP Neighbors
    return $newObject
}



#CDP Neighbour object
#Data from show cdp neighbours details
function Create-CDPNeighborObject(){
    $newObject = New-Object -TypeName PSObject
    $newObject| Add-Member -type NoteProperty -Name PartnerEthernetInterface -value $null
    $newObject| Add-Member -type NoteProperty -Name DeviceID                 -value $null
    $newObject| Add-Member -type NoteProperty -Name SystemName               -value $null
    $newObject| Add-Member -type NoteProperty -Name InterfaceAddress         -value $null
    $newObject| Add-Member -type NoteProperty -Name Platform                 -value $null
    $newObject| Add-Member -type NoteProperty -Name InterfaceLocalDevice     -value $null
    $newObject| Add-Member -type NoteProperty -Name InterfaceRemoteDevice    -value $null
    $newObject| Add-Member -type NoteProperty -Name Version                  -value $null
    $newObject| Add-Member -type NoteProperty -Name NativeVLAN               -value $null
    $newObject| Add-Member -type NoteProperty -Name Duplex                   -value $null
    $newObject| Add-Member -type NoteProperty -Name MTU                      -value $null
    $newObject| Add-Member -type NoteProperty -Name PhysicalLocation         -value $null
    $newObject| Add-Member -type NoteProperty -Name InterfaceIPAddresses     -value $null
    $newObject| Add-Member -type NoteProperty -Name Capabilities		     -value $null
    $newObject| Add-Member -type NoteProperty -Name ParentObject             -value $null                #This will be filled for each host object created from CDPNeighbors config data
    return $newObject
}


#Data from show ip route
function Create-RouteObject(){
    $newObject = New-Object -TypeName PSObject
    $newObject| Add-Member -type NoteProperty -Name RouteProtocol -value $null         #BGP,EIRGP,OSPF,static,etc
    $newObject| Add-Member -type NoteProperty -Name RouteSubType -value $null          #OSPF O1/O2, IS-IS L1/L2
    $newObject| Add-Member -type NoteProperty -Name Subnet -value $null                #The subnet we are routing to.
    $newObject| Add-Member -type NoteProperty -Name gateway -value $null               #The gateway IP for this Subnet
    $newObject| Add-Member -type NoteProperty -Name defaultgateway -value $false       #Is this a default gateway?
    $newObject| Add-Member -type NoteProperty -Name interface -value $null             #The interface if any that this
    $newObject| Add-Member -type NoteProperty -Name GatewayCidr -value $null           #Calculate the gateway subnet to make it easier to connect, Note:This comes from the show run data.
    $newObject| Add-Member -type NoteProperty -Name VRF -value $null                   #VRF for the route
    $newObject| Add-Member -type NoteProperty -Name DISTANCE -value $null              #Nexus routes have a DISTANCE
    $newObject| Add-Member -type NoteProperty -Name METRIC -value $null                #Nexus routes have a METRIC
    $newObject| Add-Member -type NoteProperty -Name GatewayLink -value $null                #Nexus routes have a METRIC
    return $newObject
}

#Spanning tree port array
#Interface           Role Sts Cost      Prio.Nbr Type
#------------------- ---- --- --------- -------- --------------------------------
#Po1                 Root FWD 3         128.1281 P2p 
#Po2                 Desg FWD 3         128.1282 P2p 
function Create-SpanningTreeInterface(){
    $newObject = New-Object -TypeName PSObject
    $newObject| Add-Member -type NoteProperty -Name Interface  -value $null 
    $newObject| Add-Member -type NoteProperty -Name Role       -value $null
    $newObject| Add-Member -type NoteProperty -Name Status     -value $null #This is incorrect and should be state TODO: Fix this. 
    $newObject| Add-Member -type NoteProperty -Name Cost       -value $null
    $newObject| Add-Member -type NoteProperty -Name PrioNbr    -value $null
    $newObject| Add-Member -type NoteProperty -Name Type       -value $null
    return $newObject
}


#Spanning tree Object per vlan
#Data from show spanning
function Create-SpanningTreeVlan(){
    $newObject = New-Object -TypeName PSObject
    $newObject| Add-Member -type NoteProperty -Name VlanID                        -value $null
    $newObject| Add-Member -type NoteProperty -Name port                        -value $null
    $newObject| Add-Member -type NoteProperty -Name protocol                      -value $null
    $newObject| Add-Member -type NoteProperty -Name RootIDPriority                -value $null
    $newObject| Add-Member -type NoteProperty -Name Address                       -value $null
    $newObject| Add-Member -type NoteProperty -Name RootBridge                    -value $null
    $newObject| Add-Member -type NoteProperty -Name RootBridgeHelloTime           -value $null
    $newObject| Add-Member -type NoteProperty -Name RootBridgeCost                -value $null
    $newObject| Add-Member -type NoteProperty -Name RootBridgePort                -value $null
    $newObject| Add-Member -type NoteProperty -Name RootBridgeAgingTime           -value $null
    $newObject| Add-Member -type NoteProperty -Name BridgeIDPriority              -value $null
    $newObject| Add-Member -type NoteProperty -Name BridgeIDPriorityaddress       -value $null
    $newObject| Add-Member -type NoteProperty -Name BridgeIDPriorityHelloTime     -value $null
    $newObject| Add-Member -type NoteProperty -Name SpanningTreeInterfaces        -value $null
    return $newObject
}

#The different file associated with each device.
function Create-FileObject(){
    $newObject = New-Object -TypeName PSObject
    $newObject| Add-Member -type NoteProperty -Name DeviceType -value $null
    $newObject| Add-Member -type NoteProperty -Name HOSTID -value $null
    $newObject| Add-Member -type NoteProperty -Name ShowRun -value $null
    $newObject| Add-Member -type NoteProperty -Name ShowCDPNeighborsDetails -value $null
    $newObject| Add-Member -type NoteProperty -Name ShowIPInterfaceBrief -value $null
    $newObject| Add-Member -type NoteProperty -Name ShowInterfaceStatus -value $null
    $newObject| Add-Member -type NoteProperty -Name ShowMacAddressTable -value $null
    $newObject| Add-Member -type NoteProperty -Name ShowSpanningTree -value $null
    $newObject| Add-Member -type NoteProperty -Name ShowIPRoute -value $null
    $newObject| Add-Member -type NoteProperty -Name ShowIPRouteVRFstar -value $null #This is for cisco devices to get all of the routes for each VRF: show ip route vrf *
    $newObject| Add-Member -type NoteProperty -Name ShowLLDPNeighborsDetails -value $null
    $newObject| Add-Member -type NoteProperty -Name ShowLLDPNeighbors -value $null
    $newObject| Add-Member -type NoteProperty -Name ShowVersion -value $null
    $newObject| Add-Member -type NoteProperty -Name ShowIPArp -value $null
    $newObject| Add-Member -type NoteProperty -Name ShowInterface -value $null
    $newObject| Add-Member -type NoteProperty -Name ShowInterfaceDetail -value $null  #This is used by Junos devices at the time of writing. 
    $newObject| Add-Member -type NoteProperty -Name ShowRouteAll -value $null
    $newObject| Add-Member -type NoteProperty -Name CiscoASAShowRoute -value $null
    $newObject| Add-Member -type NoteProperty -Name ShowSpanningTreeInterface -value $null
    $newObject| Add-Member -type NoteProperty -Name JunosShowSpanningTreeBridgeFromXML -value $null
    return $newObject
}




#Data from show run
function Create-BGPObject(){
    $newObject = New-Object -TypeName PSObject
    $newObject| Add-Member -type NoteProperty -Name ASNumber -value $null
    $newObject| Add-Member -type NoteProperty -Name RouterID -value $null
    $newObject| Add-Member -type NoteProperty -Name Shape -value $null
    $newObject| Add-Member -type NoteProperty -Name vrfs -value $null
    return $newObject
}


#For each address family their is a vrf. This could just be the global one.
#Data from show run
function Create-BGPvrfObject(){
    $newObject = New-Object -TypeName PSObject
    $newObject| Add-Member -type NoteProperty -Name name -value $null
    $newObject| Add-Member -type NoteProperty -Name neighbors -value $null
    $newObject| Add-Member -type NoteProperty -Name networks -value $null
    $newObject| Add-Member -type NoteProperty -Name redistribute -value $null
    return $newObject
}

#Data from show run
function Create-BGPneighborObject(){
    $newObject = New-Object -TypeName PSObject
    $newObject| Add-Member -type NoteProperty -Name RemoteAS -value $null
    $newObject| Add-Member -type NoteProperty -Name ipaddress -value $null
    $newObject| Add-Member -type NoteProperty -Name description -value $null
    $newObject| Add-Member -type NoteProperty -Name activate -value $null
    $newObject| Add-Member -type NoteProperty -Name version -value $null
    $newObject| Add-Member -type NoteProperty -Name FilterListIn -value $null
    $newObject| Add-Member -type NoteProperty -Name FilterListout -value $null
    $newObject| Add-Member -type NoteProperty -Name RouteMapOut -value $null
    $newObject| Add-Member -type NoteProperty -Name RouteMapIn -value $null
    $newObject| Add-Member -type NoteProperty -Name shutdown -value $null
    $newObject| Add-Member -type NoteProperty -Name EbgpMultihop -value $null
    $newObject| Add-Member -type NoteProperty -Name UpdateSource -value $null
    $newObject| Add-Member -type NoteProperty -Name PrefixListIn -value $null
    $newObject| Add-Member -type NoteProperty -Name PrefixListOut -value $null
    $newObject| Add-Member -type NoteProperty -Name shape -value $null
    return $newObject
}


#Data from show run
function Create-VlanObject(){
    $newObject = New-Object -TypeName PSObject
    $newObject| Add-Member -type NoteProperty -Name number -value $null
    $newObject| Add-Member -type NoteProperty -Name name -value $null
    $newObject| Add-Member -type NoteProperty -Name description -value $null
    return $newObject
}

#Data from show mac address-table
function Create-MacAddressObject(){
    $newObject = New-Object -TypeName PSObject
    $newObject| Add-Member -type NoteProperty -Name MacAddress -value $null
    $newObject| Add-Member -type NoteProperty -Name Vlan -value $null
    $newObject| Add-Member -type NoteProperty -Name Interface -value $null
    $newObject| Add-Member -type NoteProperty -Name VendorCompanyName -value $null
    $newObject| Add-Member -type NoteProperty -Name Type -value $null
    $newObject| Add-Member -type NoteProperty -Name protocols -value $null
    return $newObject
}
#Data from show run
#Data for spanning tree comes from show spanning-tree
function Create-InterfaceObejct(){
    $newObject = New-Object -TypeName PSObject
    #Directly from the config
    $newObject| Add-Member -type NoteProperty -Name Interface -value $null                  #Interface number and type e.g Gi0/0/1
    $newObject| Add-Member -type NoteProperty -Name Description -value $null                #Interface description / port description
    $newObject| Add-Member -type NoteProperty -Name IPAddress -value $null                  #Ipaddress for routed interfaces
    $newObject| Add-Member -type NoteProperty -Name SubnetMask -value $null                 #SubnetMask for routed interfaces
    $newObject| Add-Member -type NoteProperty -Name Cidr -value $null                       #network cidr
    $newObject| Add-Member -type NoteProperty -Name SecondaryIPAddress -value $null         #SecondaryIpaddress for routed interfaces
    $newObject| Add-Member -type NoteProperty -Name SecondarySubnetMask -value $null        #SecondarySubnetMask for routed interfaces
    $newObject| Add-Member -type NoteProperty -Name SecondaryCidr -value $null              #Secondary network cidr
    $newObject| Add-Member -type NoteProperty -Name SwitchportMode -value $null             #switch port mode access,trunk,etc
    $newObject| Add-Member -type NoteProperty -Name SwitchportAccessVlan -value $null       #the access vlan
    $newObject| Add-Member -type NoteProperty -Name SwitchportTrunkVlan -value $null        #the trunk vlans
    $newObject| Add-Member -type NoteProperty -Name shutdown -value $null                   #Is this port shutdown
    $newObject| Add-Member -type NoteProperty -Name vrf -value $null                        #VRF this interface is part of
    $newObject| Add-Member -type NoteProperty -Name RoutedVlan -value $null                 #If this is a routed interfaces and it is a vlan the vlan number will live here
    $newObject| Add-Member -type NoteProperty -Name vpc -value $null                        #Is this part of a vpc
    $newObject| Add-Member -type NoteProperty -Name ChannelGroup -value $null               #is this part of a port channel
    $newObject| Add-Member -type NoteProperty -Name ChannelGroupMode -value $null           #What type of mode is the port channel in
    $newObject| Add-Member -type NoteProperty -Name NativeVlan -value $null                 #What is our native vlan
    $newObject| Add-Member -type NoteProperty -Name SpanningTreePortType -value $null       #The mode of spanning tree
    $newObject| Add-Member -type NoteProperty -Name bpdufilter -value $null                 #Is bpdufilter enabled
    $newObject| Add-Member -type NoteProperty -Name SwitchPortType -value $null             #Is this a routed or switched port
    $newObject| Add-Member -type NoteProperty -Name IntStatus -value $null                  #Interface status from show ip int brief or show interface
    $newObject| Add-Member -type NoteProperty -Name INTProtocolStatus -value $null          #Protocol status from show ip int brief or show interface
    $newObject| Add-Member -type NoteProperty -Name MacAddressArray -value $null            #All mac addresses obtained from show mac address-table
    $newObject| Add-Member -type NoteProperty -Name STRootInterfaceForVlans -value $null    #List of all the vlans this interface is root for in spanning tree. This is for PVST or RPVST.
    $newObject| Add-Member -type NoteProperty -Name STALTnInterfaceForVlans -value $null    #List of all the vlans this interface is ALT for in spanning tree. This is for PVST or RPVST.
    $newObject| Add-Member -type NoteProperty -Name STDesgnInterfaceForVlans -value $null   #List of all the vlans this interface is Desg for in spanning tree. This is for PVST or RPVST.
    $newObject| Add-Member -type NoteProperty -Name STState -value $null                    #Spanning Tree state
    $newObject| Add-Member -type NoteProperty -Name STRole -value $null                     #Spanning tree role
    $newObject| Add-Member -type NoteProperty -Name Speed -value $null                      #Interface speed
    $newObject| Add-Member -type NoteProperty -Name Duplex -value $null                     #Duplex of the interface
    $newObject| Add-Member -type NoteProperty -Name Zone -value $null                       #Zone of this interface. This is used for the ASA. This just gives extra information.
    $newObject| Add-Member -type NoteProperty -Name Standbyip -value $null                  #Standby address of interface. This is used to store the HSRP address of the interface.
    $newObject| Add-Member -type NoteProperty -Name StandbyNumber -value $null              #Standby address of interface. This is used to store the HSRP address of the interface.
    $newObject| Add-Member -type NoteProperty -Name StandbyPriority -value $null            #Standby Priority. This is used to determined which one is active.
    $newObject| Add-Member -type NoteProperty -Name macaddress -value $null                 #This is the MacAddress used by this interface. These are not the mac addresses in the show mac address table command. These are the addresses attached to this interface for either ip addresses or LACP. 
    $newObject| Add-Member -type NoteProperty -Name ClusterIP -value $null                  #Standby address of interface. This is the cluster ip address of a checkpoint device. 
    
    $newObject| Add-Member -type NoteProperty -Name HardwareType -value $null               #The hardware type returned by the show interface command Python textfsm reference. HARDWARE_TYPE
    $newObject| Add-Member -type NoteProperty -Name MediaType -value $null                  #The media type is the type of hardware interface e.g. 1000BaseT. This is from the show interface command and the pythong textfsm reference is MEDIA_TYPE.
    
    #Computed values used to link to from interfaces.
    $newObject| Add-Member -type NoteProperty -Name HasCPDNieghbor -value $false            #If there is a cdpneighbor attach to this interface set to true
    $newObject| Add-Member -type NoteProperty -Name HasLLDPNeighbor -value $false           #If there is a LLDPneighbor attach to this interface set to true
    $newObject| Add-Member -type NoteProperty -Name IsLinkedToByCDPorLLDP -value $false     #Something we have CDP or LLDP config for links to this port. Therefore we need to mark it so we can draw it.
    $newObject| Add-Member -type NoteProperty -Name RoutesForInterface -value $null         #A list of all the routes that flow out of this interface.

    #Used for drawing the objects
    $newObject| Add-Member -type NoteProperty -Name ShapeColor -value $null                 #Add colors for better representation of port-channels etc
    $newObject| Add-Member -type NoteProperty -Name VRFColor -value $null                   #Add colors for better representation of VRF's etc
    $newObject| Add-Member -type NoteProperty -Name Physicalshape -value $null              #The shape object associated with this interface. This is the dot we connect the lines to. 
    $newObject| Add-Member -type NoteProperty -Name PhysicalshapeGroup -value $null         #The shape object associated with this interface. This is a group of shapes that make up the interface.  
    $newObject| Add-Member -type NoteProperty -Name Logicalshape -value $null               #The shape object associated with this interface.
    $newObject| Add-Member -type NoteProperty -Name ConnectedLayer3 -value $false           #Has the shape been connected to already. This is used so we don't draw two lines to connect objects we have configuration for.
    $newObject| Add-Member -type NoteProperty -Name ConnectedCDPnieghbors -value $false     #Has the shape been connected to already. This is used so we don't draw two lines to connect objects we have configuration for.
    $newObject| Add-Member -type NoteProperty -Name InterfaceAlreadyDrawn -value $false     #This is used to track if we have already drawn the interface, so we don't draw it twice.
    $newObject| Add-Member -type NoteProperty -Name MacAddressShape -value $null            #If we are drawing an object to represent all of the mac addresses attached to this interface, store the object here. This is used as an extension to show CDP nieghbors drawing. $GDrawPortsWithMacs is used to turn this feature on and off.
    return $newObject
}

#Data from show run
function Create-ConfigStaticRouteObject(){
    $newObject = New-Object -TypeName PSObject
    $newObject| Add-Member -type NoteProperty -Name vrf -value $null
    $newObject| Add-Member -type NoteProperty -Name type -value $null
    $newObject| Add-Member -type NoteProperty -Name networks -value @()
    $newObject| Add-Member -type NoteProperty -Name gateway -value $null
    $newObject| Add-Member -type NoteProperty -Name name -value $null
    $newObject| Add-Member -type NoteProperty -Name interface -value $null
    $newObject| Add-Member -type NoteProperty -Name GatewayCidr -value $null
    $newObject| Add-Member -type NoteProperty -Name shape -value $null
    return $newObject
}

#Data from show run
function Create-ConfigStaticRouteNetworkObject(){
    $newObject = New-Object -TypeName PSObject
    $newObject| Add-Member -type NoteProperty -Name network -value $null
    $newObject| Add-Member -type NoteProperty -Name subnet -value $null
    return $newObject
}

#Data from show run
function Create-vrfObject(){
    $newObject = New-Object -TypeName PSObject
    $newObject| Add-Member -type NoteProperty -Name name -value $null
    $newObject| Add-Member -type NoteProperty -Name rd -value $null
    $newObject| Add-Member -type NoteProperty -Name RouteTarget -value $null
    $newObject| Add-Member -type NoteProperty -Name export -value $null
    $newObject| Add-Member -type NoteProperty -Name shape -value $null
    return $newObject
}


function Create-NetworkObject(){
    $newObject = New-Object -TypeName PSObject
    $newObject| Add-Member -type NoteProperty -Name cidr -value $null
    $newObject| Add-Member -type NoteProperty -Name RoutedVlan -value $null
    $newObject| Add-Member -type NoteProperty -Name NetworkName -value $null
    $newObject| Add-Member -type NoteProperty -Name ARPEntries -value @()
    $newObject| Add-Member -type NoteProperty -Name Shape -value $null
    $newObject| Add-Member -type NoteProperty -Name Color -value $null
    $newObject| Add-Member -type NoteProperty -Name NumberOfConnectors -value 0
    $newObject| Add-Member -type NoteProperty -Name NumberOfRoutedConnectors -value 0
    return $newObject
}

#Data from show spanning-tree
function Create-SpanningTreeObject(){
    $newObject = New-Object -TypeName PSObject
    $newObject| Add-Member -type NoteProperty -Name SpanningTreeMode -value $null
    $newObject| Add-Member -type NoteProperty -Name SpanningTreeExtended -value $null
    $newObject| Add-Member -type NoteProperty -Name SpanningTreeArray -value $null
    $newObject| Add-Member -type NoteProperty -Name RootBridgeForVlans -value $null
    return $newObject
}

function Create-HostObject(){
    $newObject = New-Object -TypeName PSObject
    $newObject| Add-Member -type NoteProperty -Name hostname -value $null                    #Hostname of the device data from show run
    $newObject| Add-Member -type NoteProperty -Name Description -value $null                 #Description used to store system description from LLDP or CDP neighbours
    $newObject| Add-Member -type NoteProperty -Name vlans -value $null                       #Array of vlans configured on the device from show run
    $newObject| Add-Member -type NoteProperty -Name interfaces -value $null                  #Array of interfaces on the device from show run
    $newObject| Add-Member -type NoteProperty -Name ConfigStaticRouteObjects -value $null    #Array of static routes configured on the device from show run
    $newObject| Add-Member -type NoteProperty -Name vrfs -value $null                        #Array of vrfs configured on the device from show run
    $newObject| Add-Member -type NoteProperty -Name BGPConfig -value $null                   #Array of configured bgp information from show run
    $newObject| Add-Member -type NoteProperty -Name BGPNeighborData -value $null             #Array of neighbor data from show bgp neighbors
    $newObject| Add-Member -type NoteProperty -Name CDPNeighbors -value $null                #Array of neighbours  from show cdp neighbours details
    $newObject| Add-Member -type NoteProperty -Name ArrayOfNetworks -value $null             #Array of subnets found on the device from show run
    $newObject| Add-Member -type NoteProperty -Name ArrayOfIPAddresses -value $null          #Array of ip addresses found on the device  from show run
    $newObject| Add-Member -type NoteProperty -Name ArrayOfVlans -value $null                #Not sure this might need deleting. TODO:Check and delete
    $newObject| Add-Member -type NoteProperty -Name SpanningTree -value $null                #Array of Spanning tree configuration data from show spanning-tree
    $newObject| Add-Member -type NoteProperty -Name RoutingTable -value $null                #Array of routes data from show ip route
    $newObject| Add-Member -type NoteProperty -Name ParentObject -value $null                #This will be filled for each host object created from CDP/lldp config data
    $newObject| Add-Member -type NoteProperty -Name LLDPNeighbors -value $null               #Array of LLDP Neighbours
    $newObject| Add-Member -type NoteProperty -Name IPArpEntries -value $null                #Array of show ip arp entries
    $newObject| Add-Member -type NoteProperty -Name Version -value $null                     #Show version information
    $newObject| Add-Member -type NoteProperty -Name DeviceType -value $null                  #Type of Device Cisco, Checkpoint,ASA,etc

    $newObject| Add-Member -type NoteProperty -Name Origin -value $null                      #This is used show where the data was collected from. e.g a host we have config for, cdp/lldp or it's a arp entry.
    $newObject| Add-Member -type NoteProperty -Name Platform -value $null                    #This is used for CDP information and contains the platform that is pulled from cdp neighbors
    $newObject| Add-Member -type NoteProperty -Name Capabilities -value $null                #This is used for CDP information and contains the platform that is pulled from cdp neighbors
    $newObject| Add-Member -type NoteProperty -Name DeviceIdentifier  -value $null           #Part of the file name used to identify this device.
    $newObject| Add-Member -type NoteProperty -Name Shape -value $null                       #Shape object used to hold the shape information for drawing in visio
    return $newObject
}
