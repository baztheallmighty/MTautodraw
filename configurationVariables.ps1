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






#Path to Python Executable. This is used to call the TextFSM library.
$GPathToPythonExe="C:\ProgramData\Miniconda3\python.exe"

#Path to Python script for converting config with TextFSM.
$GPathToPythonTextFSMScript="$($GPathToScript)TextFSM.py"

#This is the path to the TextFSm Templates. These are used to by a small python script to convert cisco config to Objects.
#See https://pyneng.readthedocs.io/en/latest/book/21_textfsm/textfsm_examples.html for more details.
#Templates come from here: https://github.com/networktocode/ntc-templates
#Base path to Templates
$GPathToTextFSMTemplates="$($GPathToScript)Templates\"

#The Template Objects for use with TextFSM
$GTemplate = New-Object -TypeName PSObject
$GTemplate | Add-Member -type NoteProperty -Name NexusSHOWIPROUTETemplate               -value "$($GPathToTextFSMTemplates)cisco_nxos_show_ip_route.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSSHOWIPROUTETemplate                 -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_route.textfsm"

$GTemplate | Add-Member -type NoteProperty -Name IOSShowMacAddressTableTemplate         -value "$($GPathToTextFSMTemplates)cisco_ios_show_mac-address-table.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name NexusShowMacAddressTableTemplate       -value "$($GPathToTextFSMTemplates)cisco_nxos_show_mac_address-table.textfsm"

$GTemplate | Add-Member -type NoteProperty -Name IOSShowLLDPNeighborsDetailsTemplate    -value "$($GPathToTextFSMTemplates)cisco_ios_show_lldp_neighbors_detail.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name NexusShowLLDPNeighborsDetailsTemplate  -value "$($GPathToTextFSMTemplates)cisco_nxos_show_lldp_neighbors_detail.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name XEIOSShowLLDPNeighborsDetailsTemplate  -value "$($GPathToTextFSMTemplates)cisco_ios_show_lldp_neighbors.textfsm"

$GTemplate | Add-Member -type NoteProperty -Name IOSShowVersionTemplate                 -value "$($GPathToTextFSMTemplates)cisco_ios_show_version.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name NexusShowVersionTemplate               -value "$($GPathToTextFSMTemplates)cisco_nxos_show_version.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSShowIPArpTemplate                   -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_arp.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name NexusShowIPArpTemplate                 -value "$($GPathToTextFSMTemplates)cisco_nxos_show_ip_arp.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name XEIOSShowMacAddressTableTemplate       -value "$($GPathToTextFSMTemplates)cisco_xeios_show_mac-address-table.textfsm"

$GTemplate | Add-Member -type NoteProperty -Name IOSShowIPBGPNeighbors                   -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_bgp_neighbors.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSShowIPBGPSummary                     -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_bgp_summary.textfsm"

$GTemplate | Add-Member -type NoteProperty -Name IOSShowIPeigrpNeighbors                 -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_eigrp_neighbors.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSShowIPeigrpTopology                  -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_eigrp_topology.textfsm"

$GTemplate | Add-Member -type NoteProperty -Name IOSShowIPospfInterfaceBrief             -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_ospf_interface_brief.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSShowIPospfNeighbor                   -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_ospf_neighbor.textfsm"

#$GTemplate | Add-Member -type NoteProperty -Name NexusShowIPBGP -value "$($GPathToTextFSMTemplates)cisco_nxos_show_ip_bgp.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name NexusShowIPBGPneighbors -value "$($GPathToTextFSMTemplates)cisco_nxos_show_ip_bgp_neighbors.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name NexusShowIPospfneighbor -value "$($GPathToTextFSMTemplates)cisco_nxos_show_ip_ospf_neighbor.textfsm"


$GTemplate | Add-Member -type NoteProperty -Name IOSShowIPIntBrief -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_interface_brief.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name NexusShowIPIntBrief -value "$($GPathToTextFSMTemplates)cisco_nxos_show_ip_interface_brief.textfsm"

$GTemplate | Add-Member -type NoteProperty -Name IOSShowCDPNeighborsDetailsTemplate    -value "$($GPathToTextFSMTemplates)cisco_ios_show_cdp_neighbors_detail.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name NexusShowCDPNeighborsDetailsTemplate  -value "$($GPathToTextFSMTemplates)cisco_nxos_show_cdp_neighbors_detail.textfsm"

$GTemplate | Add-Member -type NoteProperty -Name IOSShowInterfaceTemplate  -value "$($GPathToTextFSMTemplates)cisco_ios_show_interfaces.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name NexusShowInterfaceTemplate  -value "$($GPathToTextFSMTemplates)cisco_nxos_show_interface.textfsm"

$GTemplate | Add-Member -type NoteProperty -Name NexusShowInterfaceStatus  -value "$($GPathToTextFSMTemplates)cisco_nxos_show_interface_status.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSShowInterfaceStatus  -value "$($GPathToTextFSMTemplates)cisco_ios_show_interfaces_status.textfsm"

#CheckPoint Templates
$GTemplate | Add-Member -type NoteProperty -Name CheckPointShowInterfaceTemplate  -value "$($GPathToTextFSMTemplates)checkpoint_gaia_show_interfaces_all.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name CheckPointShowRouteTemplate  -value "$($GPathToTextFSMTemplates)checkpoint_gaia_show_route.textfsm"

#Cisco ASA
$GTemplate | Add-Member -type NoteProperty -Name CiscoASAShowInterfaceTemplate  -value "$($GPathToTextFSMTemplates)cisco_asa_show_interface.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name CiscoASAShowRouteTemplate  -value "$($GPathToTextFSMTemplates)cisco_asa_show_route.textfsm"


#$GTemplate | Add-Member -type NoteProperty -Name XRShowLLDPNeighborsDetailsTemplate     -value "$($GPathToTextFSMTemplates)cisco_xr_show_lldp_neighbors.textfsm"


######################What do you want to draw? ######################
#This draws the diagrams with multiple devices per per page and links them together.
#This is the diagram you are probably after.
$GDrawMultipleDevicesDiagram=$true

#A single device diagram per visio page.
#This is good to see the configuration of individual devices. e.g. device with 10 different
#static routes to different locations.
$GdrawSingles=$true

#Draw CDP / LLDP Diagram. This will draw a phyiscal diagram.
$GDrawCDP=$true
#Draw a logical layer 3 diagram.
$GDrawLayer3=$true

#Layer 3 diagram but only with the links that have routes.
$GDrawLayer3RoutedLinksOnly=$true

#Draw a Layer 3 diagram with only the routes. No vlans and their links. 
$GDrawLayer3RoutesOnly=$true

#Draws all of the ports of a switch.
$GDrawEthernet=$false #Note this is quiet slow



#Skip HSRP routes. Use this option to not see HSRP routes in the routing protocol as they are mostly just noise.
$SkipHSRPRoutes=$true




#Skip phones if the platform name contains the word phones.
#Access switches can have a lot of phones and they just mess up the diagram.
$GSkipCDPLLDPPhones=$true


$GDebugingEnabled=$TRUE #Write host debug text

#Draw ports with more than X Mac addresses attached to them on CDP neighbor diagrams
#0 means don't draw them. This also disables the processing of show mac address-table config as it is slow.
$GDrawPortsWithMacs=2

#Draw CDP and LLDP neighbours consolidated. If there are multiple entries for a neighbor across multiple switches consolidate them based on hostname and management IP address.
#This means one host object will be created for devices with the same name or management ip. If set to disabled multiple objects will be created.
#Note: LLDP and CDP will not be consolidated together. This means if you have entries for both you could still end up with multiple objects. CPD neighbors are preferred over LLDP neighbors.
#CDP objects will be drawn in preference to LLDP neighbors.
$GConsolidateNeighbors=$true

#Draw arp entries for each vlan for layer 3 diagram. This will draw a summary.
$GDrawAprEntries=$true

#Draw full details not just a summary.
$GDrawAprEntriesDetails=$true


#Shorten interface name e.g Gi0/1 or te0/1
$GShortenInterfacesNames=$true

#Export CSV of vlans,cidr and subnets
$GExportData=$true

#If we know we have duplicate hostnames and we want to skip the hard error out. Note this is a bad idea to skip and will give unpredictable results.
$SkipHostnameErrorCheck=$false




#####################Drawing variables##############################
$GVRFSpacing=0.3 #Spacing between VRF's
$GEthernetSpacingPhysical=0.6 #Spacing between Ethernet Device when drawing
$GEthernetSpacingLogical=0.4 #Spacing between Ethernet Device when drawing
$GStartLocationNetwork=(0,10)#Location to start placing vlans
$GStartLocationGateway=(0,20)#Location to start placing vlans
$GVlanStep=2 #Distance between vlans
$GGatewayStep=3 #Distance between gateways
$GStartLocationHosts=(0,0) #The starting location for drawingall hosts.
$GStartARPLocationHosts=(0,-20) #The starting location for drawing all ARP hosts.
$GStartLocationCDPHosts=(0,-20)
$GStartLocationLLDPHosts=(0,+20)
$GHostLayer3Step=10 #Distance between hosts when drawing layer 3 diagrams
$GHostEthernetStep=10 #Distance between hosts when drawing ethernet diagrams

$GPhysicalInterfaceFontSize="8pt"
$GCDPHostFontSize="12pt"
$GLogicalInterfaceFontSize="8pt"
$GHostEthernetFontSize="8pt"
$GRouteFontSize="8pt"

#Size of VRF objects. This should generally be the same size as the interface object.
$GVRFXFormWidth=2
$GVRFXFormHeight=2

#Size of Draw-HostCDPNeighbors host objects
$GHostCDPXFormHeight=2.4
$GHostCDPXFormWidth=2

#Logical interface size
$GLogicalInterfaceFormHeight=0.9
$GLogicalInterfaceFormWidth=1

#Physical interface size
$GPhysicalInterfaceFormHeight=1
$GPhysicalInterfaceFormWidth=1.3

#Draw-HostEthernet Size of host objects
$GEthernetHostFormHeight=2
$GEthernetHostFormWidth=2
$GNeighborHightExtension=1.5

#Draw-HostLayer3 Size of host objects
$GLayer3HostFormHeight=2
$GLayer3HostFormWidth=3
$GLayer3HightExtension=2



#Size of BGP objects drawn in protocols.
$GBGPWidth=2.5
$GBGPhight=2.5

#vlan size
$GVlanWidth=10
$GVlanHight=0.75

#ARP Bubles size
$GARPWidth=4
$GARPHight=3

#Gateway size
$GGatewayWidth=2
$GGatewayHight=2

#This is use to move the interface up or down relative to the host object
#These are used to draw hosts we have config for.
$GPhysicalHostInterfaceOffsetY=1.5
$GLogicalInterfacesOffsetY=1.1

#How much higher up should we draw the mac addresses.
$GMacAddressOffSetY=8

#How much lower we should draw the icon relative to the lldp or cdp host object.
$GCDPLLDPIconOffsetDown=1.5

#How much lower we should draw the icon relative to the ARP host object.
$GCDPARPIconOffsetDown=1

#This is used in the Draw-HostEthernet function to offset the interface upwards relative to the host object.
#This is mainly used to draw lldp or cdp devices we don't have config for.
$GPhysicalInterfaceOffSetUP=1.6
$GNOVlanSubnetOffset=-15

#Where do we want to put the arp entries relative to the starting position
$GARPEntriesOffsetX=-10

#Space between ARP entries.
$GARPEntriesSpacingHeigh=10

#This is added to spanning tree interfaces to allow room for the text.
$GSpanningTreeInterfaceSize=0.4

#This is added to Logical interfaces to allow room for the VRF text.
$GVRFTextSizeExtension=0.4

#Colour of Layer 3 hosts
$Layer3HostColour="rgb(93,138,168)"

#Layer 3 ARP host colour
$Layer3ARPHostColour="rgb(59,0,179)"

#Colour black used for Layer 3 links
$GColourBlack="rgb(0,0,0)"

#Physical interface speed and type diagram properties. 
$GInterfaceCircleXFormWidth = 0.4
$GInterfaceCircleXFormHeight = 0.4
$GInterfaceLineWidth = 0.5

#Color for the line if we are using a SPF.
$GInterfaceCircleLineColorNormal = "rgb(100,100,100)"

#Color for the line if we are using a RJ45 SPF adaptor.
$GInterfaceCircleLineColorRed = "rgb(255,153,170)"

#Default color for Interfaces "WHITE"
$GDefaultInterfacesColor="rgb(255,255,255)"

#Colors for interface types. These are the common interfaces and the colors that go with them.
$GArrayOfInterfaceTypes=@(
@("Unknown","Unknown"            ,"rgb(0,0,0,)"),
@("RJ45","100BaseTX"             ,"rgb(85,85,85)"),
@("RJ45","10/100BaseTX"          ,"rgb(85,85,85)"),
@("RJ45","10/100/1000-TX"        ,"rgb(0,0,0)"),
@("RJ45","10/100/1000BaseT"      ,"rgb(0,0,0)"),
@("RJ45","10/100/1000BaseTX"     ,"rgb(0,0,0)"),
@("RJ45","1000BaseT"             ,"rgb(0,0,0)"),
@("RJ45-SFP","10/100/1000BaseTX SFP","rgb(0,0,0)"),
@("RJ45","T"                     ,"rgb(0,0,0)"),
@("RJ45","RJ45"                  ,"rgb(0,0,0)"),
@("Unknown","1G"                 ,"rgb(255,204,204)"),
@("Unknown","10G"                ,"rgb(255,102,102)"),
@("Unknown","40G"                ,"rgb(255,0,0)"),
@("Fibre","1000BaseLH"           ,"rgb(213,255,204)"),
@("Fibre","LH"                   ,"rgb(128,255,102)"),
@("Fibre","1000BaseLX SFP"       ,"rgb(179,255,242)"),
@("Fibre","LX"                   ,"rgb(25,255,217)"),
@("Fibre","1000BaseSX"           ,"rgb(204,204,255)"),
@("Fibre","1000BaseSX SFP"       ,"rgb(128,128,255)"),
@("Fibre","SX"                   ,"rgb(51,51,255)"),
@("Fibre","10GBase-LR"           ,"rgb(255,255,230)"),
@("Fibre","SFP-10GBase-LR"       ,"rgb(255,255,128)"),
@("Fibre","SFP-LR"               ,"rgb(255,255,51)"),
@("Fibre","10Gbase-LRM"          ,"rgb(153,153,0)"),
@("Fibre","10Gbase-ZR"           ,"rgb(255,102,229)"),
@("Fibre","10GBase-CU 3M"        ,"rgb(179,0,149)"),
@("Fibre","10Gbase-SR"           ,"rgb(247,255,230)"),
@("Fibre","SFP-10GBase-SR"       ,"rgb(221,255,153)"),
@("Fibre","SFP-10GBase-ZR"       ,"rgb(179,255,25)"))
