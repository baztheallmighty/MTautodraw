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


#This contains all of the object definitions.

function Create-ShowIPArpObject() {
    return [PSCustomObject]@{
        PROTOCOL          = $null #PROTOCOL
        ipaddress         = $null #ADDRESS
        AGE               = $null #AGE
        MAC               = $null #MAC
        TYPE              = $null #TYPE
        INTERFACE         = $null #normally a vlan interface
        VendorCompanyName = $null #VendorCompanyName
        Cidr              = $null #cidr
    }
}

function Create-ShowVersionObject() {
    return [PSCustomObject]@{
        OS               = $null #VERSION | OS
        ROMMON           = $null #ROMMON
        Hostname         = $null #HOSTNAME
        Uptime           = $null #UPTIME
        UptimeYear       = $null #UPTIME_YEARS
        UptimeWeeks      = $null #UPTIME_WEEKS
        UptimeDays       = $null #UPTIME_DAYS
        UpdateHours      = $null #UPTIME_HOURS
        UptimeMinutes    = $null #UPTIME_MINUTES
        ReasonForRelod   = $null #RELOAD_REASON | LAST_REBOOT_REASON
        Image            = $null #RUNNING_IMAGE | BOOT_IMAGE
        Hardware         = @() #HARDWARE | PLATFORM
        Serial           = @() #SERIAL
        ConfigRegister   = $null #CONFIG_REGISTER
        MacAddressArray  = @() #MAC
        LastRestarted    = $null #RESTARTED
        Type             = $null #OS type: XE-IOS,NXOS,IOS
    }
}


#LLDP Neighbour object
#Data from show cdp neighbours details
function Create-LLDPNeighborObject() {
    return [PSCustomObject]@{
        PartnerEthernetInterface   = $null
        InterfaceLocalDevice       = $null #LOCAL_INTERFACE this is the interface on the local device
        ChassisID                  = $null
        InterfaceRemoteDevice      = $null #Hostname_PORT_ID remote port id
        NeighborInterfaceDescription = $null #Hostname_INTERFACE
        Hostname                   = $null
        SystemDescription          = $null
        Capabilities               = $null
        ManagementIP               = $null
        VLAN                       = $null
        SERIAL                     = $null
        PortID                     = $null #The port id normally is just a mac address. This can be used for matching show lldp neighbors to show lldp neighbors details
        ParentObject               = $null #This will be filled for each host object created from LLDP Neighbors config data
        HasCDPNeighborEntry        = $false #This device has a cdp neighbors entry already. This is used to not draw duplicate entries from CDP neighbors and LLDP Neighbors
    }
}

#CDP Neighbour object
#Data from show cdp neighbours details
function Create-CDPNeighborObject() {
    return [PSCustomObject]@{
        PartnerEthernetInterface = $null
        DeviceID                 = $null
        SystemName               = $null
        InterfaceAddress         = $null
        Platform                 = $null
        InterfaceLocalDevice     = $null
        InterfaceRemoteDevice    = $null
        Version                  = $null
        NativeVLAN               = $null
        Duplex                   = $null
        MTU                      = $null
        PhysicalLocation         = $null
        InterfaceIPAddresses     = $null
        Capabilities             = $null
        ParentObject             = $null #This will be filled for each host object created from CDPNeighbors config data
    }
}

#Data from show ip route
function Create-RouteObject() {
    return [PSCustomObject]@{
        RouteProtocol = $null #BGP,EIRGP,OSPF,static,etc
        RouteSubType  = $null #OSPF O1/O2, IS-IS L1/L2
        Subnet        = $null #The subnet we are routing to.
        gateway       = $null #The gateway IP for this Subnet
        defaultgateway = $false #Is this a default gateway?
        interface     = $null #The interface if any that this
        GatewayCidr   = $null #Calculate the gateway subnet to make it easier to connect, Note:This comes from the show run data.
        VRF           = $null #VRF for the route
        DISTANCE      = $null #Nexus routes have a DISTANCE
        METRIC        = $null #Nexus routes have a METRIC
        GatewayLink   = $null #Nexus routes have a METRIC
    }
}

#Spanning tree port array
#Interface           Role Sts Cost      Prio.Nbr Type
#------------------- ---- --- --------- -------- --------------------------------
#Po1                 Root FWD 3         128.1281 P2p
#Po2                 Desg FWD 3         128.1282 P2p
function Create-SpanningTreeInterface() {
    return [PSCustomObject]@{
        Interface = $null
        Role      = $null
        Status    = $null
        Cost      = $null
        PrioNbr   = $null
        Type      = $null
    }
}

#Spanning tree Object per vlan
#Data from show spanning
function Create-SpanningTreeVlan() {
    return [PSCustomObject]@{
        VlanID                     = $null # The VLAN ID for this spanning-tree instance
        port                       = $null # The root port for this instance
        protocol                   = $null # Protocol in use (e.g., rstp)
        RootIDPriority             = $null # Priority of the Root Bridge
        Address                    = $null # MAC Address of the Root Bridge
        RootBridge                 = $false # Is this local device the root bridge for this instance?
        RootBridgeHelloTime        = $null # Hello time of the root bridge
        RootBridgeCost             = $null # Cost to reach the root bridge
        RootBridgePort             = $null # Port used to reach the root bridge
        RootBridgeAgingTime        = $null # Aging time of the root bridge
        BridgeIDPriority           = $null # Priority of the local bridge
        BridgeIDPriorityaddress    = $null # MAC address of the local bridge
        BridgeIDPriorityHelloTime  = $null # Hello time of the local bridge
        SpanningTreeInterfaces     = @() # Array of interface states for this spanning-tree instance
        Shape                      = $null
    }
}

#The different file associated with each device.
function Create-FileObject() {
    return [PSCustomObject]@{
        DeviceType                       = $null
        HOSTID                           = $null
        ShowRun                          = $null
        ShowCDPNeighborsDetails          = $null
        ShowIPInterfaceBrief             = $null
        ShowInterfaceStatus              = $null
        ShowMacAddressTable              = $null
        ShowSpanningTree                 = $null
        ShowIPRoute                      = $null
        ShowIPRouteVRFstar               = $null #This is for cisco devices to get all of the routes for each VRF: show ip route vrf *
        ShowLLDPNeighborsDetails         = $null
        ShowLLDPNeighbors                = $null
        ShowVersion                      = $null
        ShowIPArp                        = $null
        ShowInterface                    = $null
        ShowInterfaceDetail              = $null #This is used by Junos devices at the time of writing.
        ShowRouteAll                     = $null
        CiscoASAShowRoute                = $null
        ShowSpanningTreeInterface        = $null
        JunosShowSpanningTreeBridgeFromXML = $null
        ShowIPBGPSummary                 = $null
        ShowIPBGPVPNv4Neighbors          = $null
        ShowSystemInfo                   = $null # Add this line
        ShowInterfaceAll                 = $null # Add this line
        ShowArp                          = $null
        ShowEthernetSwitchingTable       = $null
        ShowVlansDetail                  = $null
        ShowAssetAll                     = $null
        ShowInterfaceTerse               = $null # Used for Junos 'show interfaces terse'
        ShowIPBGPNeighbors               = $null
        # --- Fortigate Specific ---
        ShowFullConfig                    = $null
        SystemStatus                      = $null
        SystemInterface                   = $null
        LldpNeighborDetails               = $null
        ShowRoutingTable                  = $null
        ShowBgpSummary                    = $null
        ShowOspfNeighbor                  = $null
    }
}

#Data from show run
function Create-VlanObject() {
    return [PSCustomObject]@{
        number      = $null
        name        = $null
        description = $null
    }
}

#Data from show mac address-table
function Create-MacAddressObject() {
    return [PSCustomObject]@{
        MacAddress        = $null
        Vlan              = $null
        Interface         = $null
        VendorCompanyName = $null
        Type              = $null
        protocols         = $null
    }
}

#Data from show run
#Data for spanning tree comes from show spanning-tree
function Create-InterfaceObject() {
    return [PSCustomObject]@{
        Interface              = $null #Interface number and type e.g Gi0/0/1
        Description            = $null #Interface description / port description
        IPAddress              = $null #Ipaddress for routed interfaces
        SubnetMask             = $null #SubnetMask for routed interfaces
        Cidr                   = $null #network cidr
        SecondaryIPAddress     = $null #SecondaryIpaddress for routed interfaces
        SecondarySubnetMask    = $null #SecondarySubnetMask for routed interfaces
        SecondaryCidr          = $null #Secondary network cidr
        SwitchportMode         = $null #switch port mode access,trunk,etc
        SwitchportAccessVlan   = $null #the access vlan
        SwitchportTrunkVlan    = $null #the trunk vlans
        shutdown               = $null #Is this port shutdown
        vrf                    = $null #VRF this interface is part of
        RoutedVlan             = $null #If this is a routed interfaces and it is a vlan the vlan number will live here
        vpc                    = $null #Is this part of a vpc
        ChannelGroup           = $null #is this part of a port channel
        ChannelGroupMode       = $null #What type of mode is the port channel in
        NativeVlan             = $null #What is our native vlan
        SpanningTreePortType   = $null #The mode of spanning tree
        bpdufilter             = $null #Is bpdufilter enabled
        SwitchPortType         = $null #Is this a routed or switched port
        IntStatus              = $null #Interface status from show ip int brief or show interface
        INTProtocolStatus      = $null #Protocol status from show ip int brief or show interface
        MacAddressArray        = @() #All mac addresses obtained from show mac address-table
        STRootInterfaceForVlans = @() #List of all the vlans this interface is root for in spanning tree. This is for PVST or RPVST.
        STALTnInterfaceForVlans = @() #List of all the vlans this interface is ALT for in spanning tree. This is for PVST or RPVST.
        STDesgnInterfaceForVlans = @() #List of all the vlans this interface is Desg for in spanning tree. This is for PVST or RPVST.
        STState                = $null #Spanning Tree state
        STRole                 = $null #Spanning tree role
        Speed                  = $null #Interface speed
        Duplex                 = $null #Duplex of the interface
        Zone                   = $null #Zone of this interface. This is used for the ASA. This just gives extra information.
        Standbyip              = $null #Standby address of interface. This is used to store the HSRP address of the interface.
        StandbyNumber          = $null #Standby address of interface. This is used to store the HSRP address of the interface.
        StandbyPriority        = $null #Standby Priority. This is used to determined which one is active.
        macaddress             = $null #This is the MacAddress used by this interface. These are not the mac addresses in the show mac address table command. These are the addresses attached to this interface for either ip addresses or LACP.
        ClusterIP              = $null #Standby address of interface. This is the cluster ip address of a checkpoint device.
        HardwareType           = $null #The hardware type returned by the show interface command Python textfsm reference. HARDWARE_TYPE
        MediaType              = $null #The media type is the type of hardware interface e.g. 1000BaseT. This is from the show interface command and the pythong textfsm reference is MEDIA_TYPE.
        HasCPDNieghbor         = $false #If there is a cdpneighbor attach to this interface set to true
        HasLLDPNeighbor        = $false #If there is a LLDPneighbor attach to this interface set to true
        IsLinkedToByCDPorLLDP  = $false #Something we have CDP or LLDP config for links to this port. Therefore we need to mark it so we can draw it.
        RoutesForInterface     = @() #A list of all the routes that flow out of this interface.
        ShapeColor             = $null #Add colors for better representation of port-channels etc
        VRFColor               = $null #Add colors for better representation of VRF's etc
        ConnectedLayer3        = $false #Has the shape been connected to already. This is used so we don't draw two lines to connect objects we have configuration for.
        ConnectedCDPnieghbors  = $false #Has the shape been connected to already. This is used so we don't draw two lines to connect objects we have configuration for.
        PhysicalDrawioId       = $null #The unique ID for the physical interface shape in the draw.io diagram.
        LogicalDrawioId        = $null #The unique ID for the logical interface shape in the draw.io diagram.
        DrawOnRoutesOnlyDiagram = $false
# --- FortiGate Specific Properties ---
        VDOM                        = $null # Virtual Domain the interface belongs to (e.g., "root")
        Mode                        = $null # IP assignment mode (static, dhcp, pppoe)
        AllowAccess                 = $null # Management access allowed (ping, https, ssh, fgfm, etc.)
        Role                        = $null # Interface role (lan, wan, dmz, undefined)
        Alias                       = $null # Short alias/name for the interface (distinct from Description)
        FortiLink                   = $null # Is FortiLink enabled (for managing FortiSwitches)
        SecurityMode                = $null # Security mode (captive-portal, 802.1x, none)
        DeviceIdentification        = $null # Is device detection enabled
        LLDPTransmission            = $null # LLDP Transmission setting (vdom, disable, etc.)
        LLDPReception               = $null # LLDP Reception setting (vdom, disable, etc.)
        SNMPIndex                   = $null # SNMP Index ID
        EstimatedUpstreamBandwidth  = $null # Upstream bandwidth setting
        EstimatedDownstreamBandwidth= $null # Downstream bandwidth setting
        MonitorBandwidth            = $null # Is bandwidth monitoring enabled
        MTUOverride                 = $null # Is MTU override enabled        
    }
}


function Create-NetworkObject() {
    return [PSCustomObject]@{
        cidr                    = $null
        RoutedVlan              = $null
        NetworkName             = $null
        ARPEntries              = @()
        Shape                   = $null
        Color                   = $null
        NumberOfConnectors      = 0
        NumberOfRoutedConnectors = 0
        # --- Shape with a specific Drawio ID property ---
        LogicalDrawioId         = $null
    }
}

#Data from show spanning-tree
function Create-SpanningTreeObject() {
    return [PSCustomObject]@{
        SpanningTreeMode   = $null # The mode of STP (e.g., rstp, pvst, mst)
        SpanningTreeExtended = $null # Spanning-tree system-id extension state
        SpanningTreeArray  = @() # Array of spanning tree instances/VLANs
        RootBridgeForVlans = @() # Array of VLAN IDs for which this device is the root bridge
    }
}

function Create-HostObject() {
    return [PSCustomObject]@{
        hostname              = $null #Hostname of the device data from show run
        Description           = $null #Description used to store system description from LLDP or CDP neighbours
        vlans                 = @() #Array of vlans configured on the device from show run
        interfaces            = @() #Array of interfaces on the device from show run
        vrfs                  = @() #Array of vrfs configured on the device from show run
        BGPConfig             = $null #Array of configured bgp information from show run
        BGPNeighborData       = @() #Array of neighbor data from show bgp neighbors
        CDPNeighbors          = @() #Array of neighbours  from show cdp neighbours details
        ArrayOfNetworks       = @() #Array of subnets found on the device from show run
        ArrayOfIPAddresses    = @() #Array of ip addresses found on the device  from show run
        SpanningTree          = $null #Object containing Spanning tree configuration data from show spanning-tree
        RoutingTable          = @() #Array of routes data from show ip route
        ParentObject          = $null #This will be filled for each host object created from CDP/lldp config data
        LLDPNeighbors         = @() #Array of LLDP Neighbours
        IPArpEntries          = @() #Array of show ip arp entries
        Version               = $null #Show version information
        DeviceType            = $null #Type of Device Cisco, Checkpoint,ASA,etc
        Origin                = $null #This is used show where the data was collected from. e.g a host we have config for, cdp/lldp or it's a arp entry.
        Platform              = $null #This is used for CDP information and contains the platform that is pulled from cdp neighbors
        Capabilities          = $null #This is used for CDP information and contains the platform that is pulled from cdp neighbors
        DeviceIdentifier      = $null #Part of the file name used to identify this device.
        Shape                 = $null #Shape object used to hold the shape information for drawing in visio
        BGP_AS_Number         = $null #store the bgp AS
        BGPNeighbors          = @() #Array of BGP neighbor objects
        DebugLog              = @() #debug logs created when processing config files.
        ProcessOutputObjects  = @() #Stores raw objects after processing of Execute-PythonTextFSM
        HostTypeIfCDPorLLDP   = @() #If this device is a lldp or cdp neighbor and it's name is a mac address we store it's make here. e.g HP or Dell or whatever
        CPDHostLocation       = $null #The location on the diagram where this object is drawn.
        L2OverviewDrawioId      = $null # ID for the simplified L2 overview shape
    }
}

function Create-BGPNeighborObject() {
    return [PSCustomObject]@{
        NEIGHBOR            = $null
        DESCRIPTION         = $null # <-- Add this
        SOURCE_IFACE        = $null # <-- Add this
        VRF                 = "default"
        REMOTE_AS           = $null
        LOCAL_AS            = $null
        PEER_GROUP          = $null
        REMOTE_ROUTER_ID    = $null
        BGP_STATE           = $null
        LOCALHOST_IP        = $null
        LOCALHOST_PORT      = $null
        REMOTE_IP           = $null
        REMOTE_PORT         = $null
        INBOUND_ROUTEMAP    = $null
        OUTBOUND_ROUTEMAP   = $null
        AdvertisedRoutes    = @()
    }
}