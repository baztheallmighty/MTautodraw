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


################################################################################
## --- File and Path Configuration ---
## These variables define the locations of necessary executables, scripts, and
## templates required for the script to function.
################################################################################

#Path to Python Executable. This is used to call the TextFSM library for parsing configuration files.
$GPathToPythonExe="$($GPathToScript)\python\python.exe"

#Path to Python script for converting config with TextFSM.
$GPathToPythonTextFSMScript="$($GPathToScript)TextFSM.py"

#This is the path to the TextFSm Templates. These are used to by a small python script to convert cisco config to Objects.
#See https://pyneng.readthedocs.io/en/latest/book/21_textfsm/textfsm_examples.html for more details.
#Templates come from here: https://github.com/networktocode/ntc-templates
#Base path to Templates
$GPathToTextFSMTemplates="$($GPathToScript)Templates\"

#The Template Objects for use with TextFSM. This object holds the full path to each .textfsm file.
$GTemplate = New-Object -TypeName PSObject
$GTemplate | Add-Member -type NoteProperty -Name NexusSHOWIPROUTETemplate          -value "$($GPathToTextFSMTemplates)cisco_nxos_show_ip_route.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSSHOWIPROUTETemplate              -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_route.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSShowMacAddressTableTemplate      -value "$($GPathToTextFSMTemplates)cisco_ios_show_mac-address-table.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name NexusShowMacAddressTableTemplate    -value "$($GPathToTextFSMTemplates)cisco_nxos_show_mac_address-table.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSShowLLDPNeighborsDetailsTemplate   -value "$($GPathToTextFSMTemplates)cisco_ios_show_lldp_neighbors_detail.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name NexusShowLLDPNeighborsDetailsTemplate -value "$($GPathToTextFSMTemplates)cisco_nxos_show_lldp_neighbors_detail.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name XEIOSShowLLDPNeighborsDetailsTemplate -value "$($GPathToTextFSMTemplates)cisco_ios_show_lldp_neighbors.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSShowVersionTemplate              -value "$($GPathToTextFSMTemplates)cisco_ios_show_version.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name NexusShowVersionTemplate            -value "$($GPathToTextFSMTemplates)cisco_nxos_show_version.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSShowIPArpTemplate                -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_arp.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name NexusShowIPArpTemplate              -value "$($GPathToTextFSMTemplates)cisco_nxos_show_ip_arp.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name XEIOSShowMacAddressTableTemplate      -value "$($GPathToTextFSMTemplates)cisco_xeios_show_mac-address-table.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSShowIPBGPNeighbors             -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_bgp_neighbors.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSShowIPBGPSummary                 -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_bgp_summary.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSShowIPeigrpNeighbors             -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_eigrp_neighbors.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSShowIPeigrpTopology              -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_eigrp_topology.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSShowIPospfInterfaceBrief         -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_ospf_interface_brief.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSShowIPospfNeighbor               -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_ospf_neighbor.textfsm"
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
$GTemplate | Add-Member -type NoteProperty -Name IOSShowInterfaceStatus    -value "$($GPathToTextFSMTemplates)cisco_ios_show_interfaces_status.textfsm"

#CheckPoint Templates
$GTemplate | Add-Member -type NoteProperty -Name CheckPointShowInterfaceTemplate -value "$($GPathToTextFSMTemplates)checkpoint_gaia_show_interfaces_all.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name CheckPointShowRouteTemplate   -value "$($GPathToTextFSMTemplates)checkpoint_gaia_show_route.textfsm"

#Cisco ASA Templates
$GTemplate | Add-Member -type NoteProperty -Name CiscoASAShowInterfaceTemplate -value "$($GPathToTextFSMTemplates)cisco_asa_show_interface.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name CiscoASAShowRouteTemplate     -value "$($GPathToTextFSMTemplates)cisco_asa_show_route.textfsm"


#$GTemplate | Add-Member -type NoteProperty -Name XRShowLLDPNeighborsDetailsTemplate       -value "$($GPathToTextFSMTemplates)cisco_xr_show_lldp_neighbors.textfsm"

$GTemplate | Add-Member -type NoteProperty -Name ASAShowBGPSummaryTemplate -value "$($GPathToTextFSMTemplates)cisco_asa_show_bgp_summary.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSShowIPBGPSummaryTemplate -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_bgp_summary.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSShowIPBGPNeighborsTemplate -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_bgp_neighbors.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name IOSShowIPBGPNeighborsAdvertisedTemplate -value "$($GPathToTextFSMTemplates)cisco_ios_show_ip_bgp_neighbors_advertised-routes.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name NexusShowIPBGPSummaryTemplate -value "$($GPathToTextFSMTemplates)cisco_nxos_show_ip_bgp_summary.textfsm"
$GTemplate | Add-Member -type NoteProperty -Name NexusShowIPBGPNeighborsTemplate -value "$($GPathToTextFSMTemplates)cisco_nxos_show_ip_bgp_neighbors.textfsm"

################################################################################
## --- Diagram Generation Toggles ---
## These boolean variables control which types of diagrams are generated.
################################################################################

# This draws the diagrams with multiple devices per page and links them together.
# This is the primary diagram you are probably after.
$GDrawMultipleDevicesDiagram=$true

# A single device diagram per Draw.io page.
# This is good to see the configuration of individual devices, e.g., a device with 10 different
# static routes to different locations.
$GdrawSingles=$true

# Draw CDP / LLDP Diagram. This will draw a physical (Layer 2) diagram.
$GDrawCDP=$true

# Draw a logical Layer 3 diagram.
$GDrawLayer3=$true

# Draw a Layer 3 diagram but only with the inter-device links that have routes.
$GDrawLayer3RoutedLinksOnly=$true

# Draw a Layer 3 diagram with only the routes. No VLANs and their links will be drawn.
$GDrawLayer3RoutesOnly=$true

# Draws all of the ports of a switch. (DEPRECATED/UNUSED)
#$GDrawEthernet=$false #Note this is quiet slow


################################################################################
## --- Processing and Behavior Toggles ---
## These variables control how the script processes data and handles specific cases.
################################################################################

# Skip HSRP routes. Use this option to not see HSRP routes in the routing protocol as they are mostly just noise.
$SkipHSRPRoutes=$true

# Skip phones if the platform name contains the word "phone".
# Access switches can have a lot of phones and they just mess up the diagram.
$GSkipCDPLLDPPhones=$true

# Enable or disable debug text output to the console.
$GDebugingEnabled=$TRUE #Write host debug text

# Draw ports with more than X Mac addresses attached to them on CDP neighbor diagrams.
# A value of 0 means don't draw them. This also disables the processing of "show mac address-table" config as it is slow.
$GDrawPortsWithMacs=2

# Draw CDP and LLDP neighbours consolidated. If there are multiple entries for a neighbor across multiple switches, consolidate them based on hostname and management IP address.
# This means one host object will be created for devices with the same name or management IP. If set to disabled, multiple objects will be created.
# Note: LLDP and CDP will not be consolidated together. This means if you have entries for both you could still end up with multiple objects. CDP neighbors are preferred over LLDP neighbors.
# CDP objects will be drawn in preference to LLDP neighbors.
$GConsolidateNeighbors=$true

# Draw ARP entries for each VLAN on the Layer 3 diagram.
$GDrawAprEntries=$true

# If drawing ARP entries, set to $true to draw full details (IP, MAC, Vendor) instead of a summary.
$GDrawAprEntriesDetails=$true

# Shorten interface names (e.g., GigabitEthernet0/1 becomes Gi0/1).
$GShortenInterfacesNames=$true

# Export processed data (VLANs, CIDR, etc.) to CSV and JSON files in the output directory.
$GExportData=$true

# If we know we have duplicate hostnames and we want to skip the hard error out. Note: this is a bad idea to skip and will give unpredictable results.
$SkipHostnameErrorCheck=$false


################################################################################
## --- LEGACY Drawing Variables (DEPRECATED) ---
## This entire section contains variables from a previous version of the script
## that generated Visio diagrams. They are no longer used by the current
## Draw.io functions and can be safely ignored.
################################################################################

#$GVRFSpacing=0.3 #Spacing between VRF's
#$GEthernetSpacingPhysical=0.6 #Spacing between Ethernet Device when drawing
#$GEthernetSpacingLogical=0.4 #Spacing between Ethernet Device when drawing
#$GStartLocationNetwork=(0,10)#Location to start placing vlans
#$GStartLocationGateway=(0,20)#Location to start placing vlans
#$GVlanStep=2 #Distance between vlans
#$GGatewayStep=3 #Distance between gateways
#$GStartLocationHosts=(0,0) #The starting location for drawingall hosts.
#$GStartARPLocationHosts=(0,-20) #The starting location for drawing all ARP hosts.
#$GStartLocationCDPHosts=(0,-20)
#$GStartLocationLLDPHosts=(0,+20)
#$GHostLayer3Step=10 #Distance between hosts when drawing layer 3 diagrams
#$GHostEthernetStep=10 #Distance between hosts when drawing ethernet diagrams
#$GPhysicalInterfaceFontSize="8pt"
#$GCDPHostFontSize="12pt"
#$GLogicalInterfaceFontSize="8pt"
#$GHostEthernetFontSize="8pt"
#$GRouteFontSize="8pt"
#Size of VRF objects. This should generally be the same size as the interface object.
#$GVRFXFormWidth=2
#$GVRFXFormHeight=2
#Size of Draw-HostCDPNeighbors host objects
#$GHostCDPXFormHeight=2.4
#$GHostCDPXFormWidth=2
#Logical interface size
#$GLogicalInterfaceFormHeight=0.9
#$GLogicalInterfaceFormWidth=1
#Physical interface size
#$GPhysicalInterfaceFormHeight=1
#$GPhysicalInterfaceFormWidth=1.3
#Draw-HostEthernet Size of host objects
#$GEthernetHostFormHeight=2
#$GEthernetHostFormWidth=2
#$GNeighborHightExtension=1.5
#Draw-HostLayer3 Size of host objects
#$GLayer3HostFormHeight=2
#$GLayer3HostFormWidth=3
#$GLayer3HightExtension=2
#Size of BGP objects drawn in protocols.
#$GBGPWidth=2.5
#$GBGPhight=2.5
#vlan size
#$GVlanWidth=10
#$GVlanHight=0.75
#ARP Bubles size
#$GARPWidth=4
#$GARPHight=3
#Gateway size
#$GGatewayWidth=2
#$GGatewayHight=2
#This is use to move the interface up or down relative to the host object
#These are used to draw hosts we have config for.
#$GPhysicalHostInterfaceOffsetY=1.5
#$GLogicalInterfacesOffsetY=1.1
#How much higher up should we draw the mac addresses.
#$GMacAddressOffSetY=8
#How much lower we should draw the icon relative to the lldp or cdp host object.
#$GCDPLLDPIconOffsetDown=1.5
#How much lower we should draw the icon relative to the ARP host object.
#$GCDPARPIconOffsetDown=1
#This is used in the Draw-HostEthernet function to offset the interface upwards relative to the host object.
#This is mainly used to draw lldp or cdp devices we don't have config for.
#$GPhysicalInterfaceOffSetUP=1.6
#$GNOVlanSubnetOffset=-15
#Where do we want to put the arp entries relative to the starting position
#$GARPEntriesOffsetX=-10
#Space between ARP entries.
#$GARPEntriesSpacingHeigh=10
#This is added to spanning tree interfaces to allow room for the text.
#$GSpanningTreeInterfaceSize=0.4
#This is added to Logical interfaces to allow room for the VRF text.
#$GVRFTextSizeExtension=0.4
#Colour of Layer 3 hosts
#$Layer3HostColour="rgb(93,138,168)"
#Layer 3 ARP host colour
#$Layer3ARPHostColour="rgb(59,0,179)"
#Colour black used for Layer 3 links
#$GColourBlack="rgb(0,0,0)"
#Physical interface speed and type diagram properties. 
#$GInterfaceCircleXFormWidth = 0.4
#$GInterfaceCircleXFormHeight = 0.4
#$GInterfaceLineWidth = 0.5
#Color for the line if we are using a SPF.
#$GInterfaceCircleLineColorNormal = "rgb(100,100,100)"
#Color for the line if we are using a RJ45 SPF adaptor.
#$GInterfaceCircleLineColorRed = "rgb(255,153,170)"
#Default color for Interfaces "WHITE"
#$GDefaultInterfacesColor="rgb(255,255,255)"
#Colors for interface types. These are the common interfaces and the colors that go with them.
#$GArrayOfInterfaceTypes=@(
#@("Unknown","Unknown"               ,"rgb(0,0,0,)"),
#@("RJ45","100BaseTX"                 ,"rgb(85,85,85)"),
#@("RJ45","10/100BaseTX"              ,"rgb(85,85,85)"),
#@("RJ45","10/100/1000-TX"             ,"rgb(0,0,0)"),
#@("RJ45","10/100/1000BaseT"           ,"rgb(0,0,0)"),
#@("RJ45","10/100/1000BaseTX"          ,"rgb(0,0,0)"),
#@("RJ45","1000BaseT"                 ,"rgb(0,0,0)"),
#@("RJ45-SFP","10/100/1000BaseTX SFP","rgb(0,0,0)"),
#@("RJ45","T"                         ,"rgb(0,0,0)"),
#@("RJ45","RJ45"                      ,"rgb(0,0,0)"),
#@("Unknown","1G"                      ,"rgb(255,204,204)"),
#@("Unknown","10G"                     ,"rgb(255,102,102)"),
#@("Unknown","40G"                     ,"rgb(255,0,0)"),
#@("Fibre","1000BaseLH"                ,"rgb(213,255,204)"),
#@("Fibre","LH"                        ,"rgb(128,255,102)"),
#@("Fibre","1000BaseLX SFP"            ,"rgb(179,255,242)"),
#@("Fibre","LX"                        ,"rgb(25,255,217)"),
#@("Fibre","1000BaseSX"                ,"rgb(204,204,255)"),
#@("Fibre","1000BaseSX SFP"            ,"rgb(128,128,255)"),
#@("Fibre","SX"                        ,"rgb(51,51,255)"),
#@("Fibre","10GBase-LR"                ,"rgb(255,255,230)"),
#@("Fibre","SFP-10GBase-LR"            ,"rgb(255,255,128)"),
#@("Fibre","SFP-LR"                    ,"rgb(255,255,51)"),
#@("Fibre","10Gbase-LRM"               ,"rgb(153,153,0)"),
#@("Fibre","10Gbase-ZR"                ,"rgb(255,102,229)"),
#@("Fibre","10GBase-CU 3M"             ,"rgb(179,0,149)"),
#@("Fibre","10Gbase-SR"                ,"rgb(247,255,230)"),
#@("Fibre","SFP-10GBase-SR"            ,"rgb(221,255,153)"),
#@("Fibre","SFP-10GBase-ZR"            ,"rgb(179,255,25)"))


################################################################################
## --- Draw.io Diagram Configuration ---
## These variables control the appearance, dimensions, and styling of elements
## in the final Draw.io diagrams.
################################################################################

## --- Legend Styling ---
# The size of the colored square in the legend.
$GDrawioInterfaceLegend_SwatchWidth = 20
$GDrawioInterfaceLegend_SwatchHeight = 20

# The border width for the swatch. In Draw.io, this is 'strokeWidth'.
$GDrawioInterfaceLegend_LineWidth = 2

# Hex color for the border of SFP transceivers in the legend.
$GDrawioInterfaceLegend_LineColorSFP = "#646464"

# Hex color for the border of RJ45-SFP adaptors in the legend to highlight them.
$GDrawioInterfaceLegend_LineColorSFP_RJ45 = "#FF99AA"

## --- Interface Media Type Colors ---
# Defines the fill color for physical interfaces based on their media type (from show interface status).
# Format: @("Family", "Cisco Media Type Name", "rgb(r,g,b)")
# "Family" is used to determine border style (e.g., for SFPs).
$GDrawioArrayOfInterfaceTypes=@(
    @("Unknown","Unknown"                 ,"rgb(0,0,0)"),
    @("RJ45","100BaseTX"                  ,"rgb(85,85,85)"),
    @("RJ45","10/100BaseTX"               ,"rgb(85,85,85)"),
    @("RJ45","10/100/1000-TX"             ,"rgb(0,0,0)"),
    @("RJ45","10/100/1000BaseT"           ,"rgb(0,0,0)"),
    @("RJ45","10/100/1000BaseTX"          ,"rgb(0,0,0)"),
    @("RJ45","1000BaseT"                  ,"rgb(0,0,0)"),
    @("RJ45-SFP","10/100/1000BaseTX SFP"  ,"rgb(0,0,0)"),
    @("RJ45","T"                          ,"rgb(0,0,0)"),
    @("RJ45","RJ45"                       ,"rgb(0,0,0)"),
    @("Unknown","1G"                       ,"rgb(255,204,204)"),
    @("Unknown","10G"                      ,"rgb(255,102,102)"),
    @("Unknown","40G"                      ,"rgb(255,0,0)"),
    @("Fibre","1000BaseLH"                 ,"rgb(213,255,204)"),
    @("Fibre","LH"                         ,"rgb(128,255,102)"),
    @("Fibre","1000BaseLX SFP"             ,"rgb(179,255,242)"),
    @("Fibre","LX"                         ,"rgb(25,255,217)"),
    @("Fibre","1000BaseSX"                 ,"rgb(204,204,255)"),
    @("Fibre","1000BaseSX SFP"             ,"rgb(128,128,255)"),
    @("Fibre","SX"                         ,"rgb(51,51,255)"),
    @("Fibre","10GBase-LR"                 ,"rgb(255,255,230)"),
    @("Fibre","SFP-10GBase-LR"             ,"rgb(255,255,128)"),
    @("Fibre","SFP-LR"                     ,"rgb(255,255,51)"),
    @("Fibre","10Gbase-LRM"                ,"rgb(153,153,0)"),
    @("Fibre","10Gbase-ZR"                 ,"rgb(255,102,229)"),
    @("Fibre","10GBase-CU 3M"              ,"rgb(179,0,149)"),
    @("Fibre","10Gbase-SR"                 ,"rgb(247,255,230)"),
    @("Fibre","SFP-10GBase-SR"             ,"rgb(221,255,153)"),
    @("Fibre","SFP-10GBase-ZR"             ,"rgb(179,255,25)")
)


## --- Physical (L2) Diagram Metrics ---
# Width of a physical interface shape in pixels.
$GDrawioPhysicalInterfaceWidth = 160
# Height of a physical interface shape in pixels.
$GDrawioPhysicalInterfaceHeight = 80
# Height of the main host box shape in pixels.
$GDrawioHostPhysicalHeight = 80
# Spacing between physical interface shapes in pixels.
$GDrawioEthernetSpacingPhysical = 15
# Font size for text inside physical interface shapes.
$GDrawioPhysicalInterfaceFontSize = 10
# Font size for text inside the main host box.
$GDrawioHostFontSize = 12
# Toggles short interface names. Note: This is a duplicate of a global toggle but is used by drawing functions.
$GDrawioShortenInterfacesNames = $true
# Extra height in pixels to add to an interface shape if it's a Spanning Tree root/alt port.
$GDrawioSpanningTreeInterfaceSize = 20
# Vertical offset in pixels to move STP ports upwards to make them stand out.
$GDrawioPhysicalHostInterfaceOffsetY = 40
# Default fill color (white) for interfaces with an unknown media type.
$GDrawioDefaultInterfacesColor = "#FFFFFF"


## --- Logical (L3) Diagram Metrics ---
# Width of a logical interface shape (e.g., SVI) in pixels.
$GDrawioLogicalInterfaceWidth = 120
# Height of a logical interface shape in pixels.
$GDrawioLogicalInterfaceHeight = 70
# Width of the main Layer 3 host box in pixels.
$GDrawioLayer3HostFormWidth = 250
# Height of the main Layer 3 host box in pixels.
$GDrawioLayer3HostFormHeight = 120
# Extra height in pixels to add to a logical interface if it has VRF or HSRP info.
$GDrawioVrfTextSizeExtension = 15
# Spacing between logical interface shapes in pixels.
$GDrawioEthernetSpacingLogical = 15
# Font size for text inside logical interface shapes.
$GDrawioLogicalInterfaceFontSize = 9
# Font size for text inside the Layer 3 host box.
$GCDPHostFontSize = 12
# Fill color for a standard host box in the L3 diagram.
$Layer3HostColour = "rgb(93,138,168)"  # Blue
# Fill color for a gateway/ARP-discovered host box in the L3 diagram.
$Layer3ARPHostColour = "rgb(59,0,179)"   # Purple


## --- Shared Diagram Metrics ---
# Width of the VLAN / Network Segment shape in pixels.
$GDrawioVlanWidth = 300
# Height of the VLAN / Network Segment shape in pixels.
$GDrawioVlanHeight = 40
# Width of the ARP entries "cloud" shape in pixels.
$GDrawioArpWidth = 350


# Draw ports with more than X Mac addresses attached to them on CDP neighbor diagrams.
# A value of 0 means don't draw them.
$GDrawPortsWithMacs = 5



# Keep this one for links that are not Port-Channels
$GDefaultConnectorStyle = "endArrow=none;html=1;strokeWidth=2;strokeColor=#6c8ebf;"

$global:runtimePortChannelStyles = @{}

