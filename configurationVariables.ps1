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


#region Paths and external dependencies
################################################################################
## --- File and Path Configuration ---
## These variables define the locations of necessary executables, scripts, and
## templates required for the script to function.
################################################################################

# Released version reported in RunSummary.json and on the verdict line to identify the producing build.
$GMTAutoDrawVersion = '1.0.0'

#Path to Python Executable. This is used to call the TextFSM library for parsing configuration files.
$GPathToPythonExe="$($GPathToScript)\python\python.exe"

#Path to Python script for converting config with TextFSM.
$GPathToPythonTextFSMScript="$($GPathToScript)TextFSM.py"



# Every TextFSM template, keyed by file name without the extension, e.g. "cisco_ios_show_ip_route".
# This hashtable is what every parser looks a template up in - see Invoke-MTAutoDrawTextFSM - and it
# is the only form the path is needed in, so the directory itself is a local rather than a global.
# Templates come from https://github.com/networktocode/ntc-templates; on TextFSM itself see
# https://pyneng.readthedocs.io/en/latest/book/21_textfsm/textfsm_examples.html
$templateDirectory = "$($GPathToScript)Templates\"
$GTextFSMTemplates = @{}
Get-ChildItem -Path $templateDirectory -Filter '*.textfsm' -File | ForEach-Object {
    $GTextFSMTemplates[$_.BaseName] = $_.FullName
}
#endregion Paths and external dependencies

#region Diagram toggles
################################################################################
## --- Diagram Generation Toggles ---
## These boolean variables control which types of diagrams are generated.
################################################################################
# Network path analysis is experimental and is disabled until its data model and
# output have dedicated regression coverage.
$GNetworkTracePathAnalysis = $false

# The MultiDevice file: every whole-site page - Topology Overview, the Layer 3 pages, CDP-LLDP,
# Spanning-Tree. Turning this off leaves only the per-device Singles file, so the site is documented
# device by device with nothing showing how they join up. This is the file most people want.
$GDrawMultipleDevicesDiagram=$true

# The Singles file: one Layer 3 page and one Physical page per device, each showing that device in
# full rather than the site-wide summary. This is where you go to read one switch - all its ports,
# all its routes - after an overview page has told you which switch to look at.
$GdrawSingles=$true

# Adds the per-device "<host> Physical" pages to the Singles file: the device with every port drawn
# on its border, and its directly connected neighbours around it. Off, the Singles file keeps its
# Layer 3 pages but nothing shows which port faces which neighbour.
$GDrawPhysical=$true

# Adds the "CDP-LLDP brief" page: the Layer 2 topology, drawing only the ports that carry a resolved
# link between two devices we have config for. The readable one - a 60-port switch contributes the
# two or three ports that actually go somewhere.
#
# Also gates MAC address-table parsing in the vendor parsers, which is slow. Off, ports have no MAC
# lists on any page.
$GDrawCDP=$true

# Adds the "CDP-LLDP All" page: the same Layer 2 topology as above, but every port of every device
# that reported a neighbour, including the ones connected to nothing we captured. Wider and slower
# to read; use it when you need to see what a device has spare, not how the site joins up.
$GDrawCDPALL=$true

# Adds the "Layer 3 All" page: every addressed device and network in a graph-aware layout. Devices
# with the exact same routed behavior and visible CIDRs share one full-membership summary; their
# individual interface/IP rows remain inside it. The addressing view of the site - which VLAN lives
# where without a wall of duplicate host cards.
$GDrawLayer3=$true

# Adds the "Layer 3 Routed Links Only" page: the graph above narrowed to routed-link subnets and
# their member interfaces. Exact-behavior hosts collapse safely; directly-connected access VLANs do
# not dominate the traffic-path view.
$GDrawLayer3RoutedLinksOnly=$true

# Adds the "Layer 3 Routes Only" page: devices and routes with no network shapes. Hosts with an
# identical complete route signature share one dynamically-sized box listing every hostname.
$GDrawLayer3RoutesOnly=$true


# Adds the "Spanning-Tree" page: one card per device showing its bridge id, mode, and which VLANs it
# is root for, with an arrow from each switch to the root bridge it points at. A root bridge no
# device has config for is drawn as a placeholder from the bridge id its neighbours report, which is
# usually how an unexpected root gets noticed.
$GDrawSpanningTree=$true

# --- One-screen overview diagrams ---
# These are deliberately scoped to a SUBSET of the network (not full detail) so each one fits on a
# single 1080p screen. Full detail always remains available on the diagrams above, plus the CSV/JSON
# exports below.

# Icon-per-device physical topology map, tiered by resolved neighbour degree (Core/Distribution/Access).
$GDrawSiteTopologyOverview=$true

# L3 analogue of the Topology Overview above: devices tiered into Border/Transit/Gateway (a role
# derived purely from routing - who holds the default route out, who other devices route through,
# who just owns subnets), with shared-subnet chips for a VLAN spanning 3+ devices, one merged edge
# per device pair (adjacency + routing + protocol, not three separate lines), and a compact
# HSRP/VRRP pairing edge.
$GDrawLayer3TopologyOverview=$true

# Layer 3 dependency map: configured upstream/transit devices are one outer container holding all
# of their next-hop identities and their own outbound routing. Non-hub leaves whose entire route set
# is identical share one node. Full per-route detail remains on Layer 3 Routes Only and exports.
$GDrawLayer3Connectivity=$true

# Layer 3 routes summary: "who points where" on one screen. Individual routing nodes (reusing the
# Topology Overview tier/security/root-bridge coloring) + single-static devices collapsed into one
# box per shared next-hop + external next-hop cards for gateways that resolve to no captured device.
# Full per-route detail remains on the "Layer 3 Routes Only" page and in the exports.
$GDrawLayer3RoutesSummary=$true

# --- Per-firewall pages ---
# One page per firewall device per topic, for devices of type CheckPoint/CiscoASA/PaloAlto/Fortigate
# (or any device with parsed security/NAT policy). Sites have 1-3 firewalls, so this adds few pages.

# Segmentation shape only: zones and how many interfaces each holds. No addresses, no rules.
$GDrawFirewallOverview=$true

# Layer 3 NAT flow: only source zone/interfaces used by NAT, the firewall, and translation targets.
# A device with no parsed NAT rules gets a note-only page, never disconnected icons.
$GDrawFirewallNatInterfaces=$true

# Firewall at the centre, zones around it, each spoke labelled with how many rules govern that zone.
# The rules-aware counterpart to the Overview page above.
$GDrawFirewallZoneHub=$true

# The rules worth arguing about, bucketed by why: any-to-any, fully open zone pairs, all-protocol
# rules with an open side, disabled rules, and zones no rule mentions.
$GDrawFirewallRuleRisk=$true


#endregion Diagram toggles

#region Processing behaviour
################################################################################
## --- Processing and Behavior Toggles ---
## These variables control how the script processes data and handles specific cases.
################################################################################



# Skip HSRP routes. Use this option to not see HSRP routes in the routing protocol as they are mostly just noise.
$GSkipHSRPRoutes=$false

# Skip phones if the platform name contains the word "phone".
# Access switches can have a lot of phones and they just mess up the diagram.
$GSkipCDPLLDPPhones=$false

# Drop CDP/LLDP neighbour entries that arrived over a flooded shared segment rather than a direct
# link. A device that does not consume CDP (Junos, media converters, carrier ethernet) forwards the
# multicast, so every switch on the segment sees every other one and each sighting would otherwise
# be drawn as a physical link that does not exist.
$GSuppressFloodedNeighbors=$true

# How many distinct configured devices a single physical port may report before its entries are
# treated as flooded. A real point-to-point port reports exactly one.
$GMaxNeighborDevicesPerPort=1


# Draw ports with more than X Mac addresses attached to them on CDP neighbor diagrams.
# A value of 0 means don't draw them. This also disables the processing of "show mac address-table" config as it is slow.
# This was assigned twice - 2 here and 5 further down under Shared Diagram Metrics, where the second
# silently won and made this line dead. Consolidated to the value that was actually in effect.
$GDrawPortsWithMacs=5

# Draw CDP and LLDP neighbours consolidated. If there are multiple entries for a neighbor across multiple switches, consolidate them based on hostname and management IP address.
# This means one host object will be created for devices with the same name or management IP. If set to disabled, multiple objects will be created.
# Note: LLDP and CDP will not be consolidated together. This means if you have entries for both you could still end up with multiple objects. CDP neighbors are preferred over LLDP neighbors.
# CDP objects will be drawn in preference to LLDP neighbors.
$GConsolidateNeighbors=$true

# Attaches an ARP bubble to each network shape on the Layer 3 pages, saying how many hosts were seen
# on that subnet and by which vendor. This is what turns a VLAN from a name into an occupancy count.
# Also gates ARP parsing in the vendor parsers, so off means the ARP columns of the exports are empty
# too.
$GDrawAprEntries=$true

# If drawing ARP entries, set to $true to draw full details (IP, MAC, Vendor) instead of a summary.
$GDrawAprEntriesDetails=$false
$GDrawArpEntryDetailLimit=40 #Even when detail is enabled, summarize larger tables so Layer 3 shapes remain usable.


# Export processed data (VLANs, CIDR, etc.) to CSV and JSON files in the output directory.
$GExportData=$true

# Obsolete. It gated a hard exit on duplicate hostnames that was copy-pasted into the vendor parsers
# and could never fire - the dispatcher passes no device list, because duplicates cannot be detected
# from inside a parallel worker. The real check is sequential, after aggregation, in
# StartProcessingConfig.ps1: it skips a duplicate that shares a serial, and renames one that does not.
# Kept only so an existing caller passing -SkipHostnameErrorCheck does not break.
$SkipHostnameErrorCheck=$false


#endregion Processing behaviour

#region Logging
################################################################################
## --- Console and log verbosity ---
## What the run prints while it works. Neither affects what is drawn.
################################################################################

# Enable or disable debug text output to the console.
$GDebugingEnabled=$true #Detailed parser and drawing diagnostics are the default; AutoDraw.ps1 -Quiet overrides this.

# The console/log verbosity threshold: Error | Warn | Info | Debug | Trace, ascending. Info includes
# phases, outcomes, and warnings; route- and connector-level detail requires Debug or Trace.
# AutoDraw.ps1 -Quiet is shorthand for Warn; -LogLevel overrides either.
$GLogLevel="Info"

#endregion Logging

#region Presentation
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
## These sizes are FLOORS, not fixed sizes - Measure-DrawioTextBlock (HelperFunctions.ps1) grows a
## box past its floor when its own text needs the room. Shrunk from the original 160/80/10/12 as
## part of the CDP-LLDP/Layer3 detail-page rework: every port becomes a small chip on the host's
## perimeter rather than a large free-floating box, so the floor only needs to fit a short label -
## text that overflows still grows the specific chip that needs it.
# Width of a physical interface port chip in pixels.
$GDrawioPhysicalInterfaceWidth = 104
# Floor height of a physical interface port chip in pixels.
$GDrawioPhysicalInterfaceHeight = 34
# Floor height of the main host box shape in pixels.
$GDrawioHostPhysicalHeight = 34
# Spacing between physical interface port chips in pixels.
# Font size for text inside physical interface port chips.
$GDrawioPhysicalInterfaceFontSize = 8
# Font size for text inside the main host box.
$GDrawioHostFontSize = 9
# Toggles short interface names. Note: This is a duplicate of a global toggle but is used by drawing functions.
$GDrawioShortenInterfacesNames = $true
# Extra height in pixels to add to an interface shape if it's a Spanning Tree root/alt port.
# Vertical offset in pixels to move STP ports upwards to make them stand out.
# Default fill color (white) for interfaces with an unknown media type.
$GDrawioDefaultInterfacesColor = "#FFFFFF"


## --- Logical (L3) Diagram Metrics ---
## Same floor-not-fixed convention as the physical metrics above.
# Width of a logical interface port chip (e.g., SVI) in pixels.
$GDrawioLogicalInterfaceWidth = 96
# Floor height of a logical interface port chip in pixels.
$GDrawioLogicalInterfaceHeight = 32
# Floor width of the main Layer 3 host box in pixels.
$GDrawioLayer3HostFormWidth = 140
# Floor height of the main Layer 3 host box in pixels.
$GDrawioLayer3HostFormHeight = 34
# Extra height in pixels to add to a logical interface if it has VRF or HSRP info.
# Spacing between logical interface port chips in pixels.
# Font size for text inside logical interface port chips.
$GDrawioLogicalInterfaceFontSize = 8
# Font size for text inside the Layer 3 host box.
$GCDPHostFontSize = 9
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



# Keep this one for links that are not Port-Channels
$GDefaultConnectorStyle = "endArrow=none;html=1;strokeWidth=2;strokeColor=#6c8ebf;"


# This hashtable keeps deterministic Port-Channel styles for the current run.
# It is created here and passed by reference to the helper function.
# This ensures that all segments of the same Port-Channel have a consistent visual style (e.g., color, pattern).
$GruntimePortChannelStyles = @{}




# Global variables for controlling the layout of Spanning Tree hosts.
$GhostHeaderHeight = 80 # Reserved vertical space for the host text
$GvlanSectionHeight = 60 # Reserved vertical space for the VLAN boxes section
$GvlanSpacing = 10        # The horizontal and vertical spacing between elements


#endregion Presentation

#region Layout limits
################################################################################
## --- One-Screen Overview Diagram Budget ---
## Target canvas size for $GDrawSiteTopologyOverview / $GDrawLayer3TopologyOverview, sized so a page
## is still readable at 100% zoom on a 1080p
## display with browser/draw.io chrome visible (tighter than the raw 1920x1080 panel).
## Past the soft target the page should lean harder on its own summarizing/bucketing logic;
## the hard cap is a backstop for an unusually large site, so a page degrades by summarizing more
## rather than silently growing unreadably large.
################################################################################
$GDrawioOverviewMaxWidth = 1900      # Soft width target, in px.

# The Topology Overview gets its own, larger cap, because it is not the same kind of page as the
# others this budget governs. Every page above summarizes: the Layer 3 views bucket devices by role
# and fold the rest into "+N more" cards, so their size is a choice about how much detail to keep.
# The Topology Overview draws every device and every resolved link - that is what makes it the map
# you open first - so its size is decided by the site, not by a display policy.
#
# The layout has been pushed hard against this, and gap tuning, ring spacing, sub-ring staggering
# and cluster packing all reduce the width - but only so far. The floor is arithmetic, not layout:
# N cards at 200px each need at least 200N px of card width however they are arranged, and a
# starburst spreads them across roughly a third of its own width. Below that floor the only
# remaining lever is to stop drawing devices and fold the outer rings into a summary card.
#
# So the cap is honest about what this page is: 6,000px, the point past which the page has really
# become unreadable rather than merely large. A site that exceeds it is the signal to revisit
# summarizing, not to tune the layout again.
$GDrawioTopologyOverviewHardMaxWidth = 6000

# Default node footprint on the Topology / Layer 3 Topology overview pages.
$GDrawioOverviewNodeWidth = 200


################################################################################
## --- Detail Page Layout: perimeter ports + tiered placement ---
## Controls the graph layout on the detail pages. CDP/LLDP keeps one card per configured device;
## Layer 3 pages may replace exact duplicate behavior with a complete-membership summary. Interfaces
## on singleton cards remain perimeter ports, and connected nodes are placed in BFS tiers with
## barycenter refinement.
################################################################################

# Gap in pixels between a port chip and the host border it sits against, and between adjacent chips
# on the same side.
$GDrawioPortGap = 6

# Horizontal gap between devices placed in the same tier row.
$GDrawioTierColumnGap = 90
# Vertical gap between one tier row and the next.
$GDrawioTierRowGap = 110

# Barycenter sweeps run after the initial BFS ordering, to reduce edge crossings within a tier. Each
# sweep moves a device towards the average column position of its neighbours. Two is enough for the
# common case; 0 disables refinement and keeps the plain BFS order.
$GDrawioTierBarycenterSweeps = 2

# A tier row wider than this wraps onto additional sub-rows. Without a cap a single tier is
# unbounded: one access switch reporting ~100 LLDP endpoints puts all 100 in tier 1 side by side,
# which runs to tens of thousands of pixels across. 4000px is roughly five printed pages wide, so
# small and mid-size sites never wrap at all.
$GDrawioTierMaxRowWidth = 4000

# On the Layer 3 Topology Overview, show at most this many devices individually per role band
# (Border/Transit/Gateway, ranked busiest-first within each); the rest fold into one overflow card
# per band. The band-height backstop - each page is meant to fit a single 1080p screen.
$GDrawioL3TopoMaxDevicesPerBand = 14

# On the Layer 3 Topology Overview, show at most this many shared-subnet chips (a VLAN spanning 3+
# devices), ranked by device count; the rest fold into one overflow card.
$GDrawioL3TopoMaxSegmentChips = 10

# On the Layer 3 Topology Overview, show at most this many external next hops (ranked by dependant
# count); the rest fold into one overflow card. Mirrors $GDrawioL3ConnMaxHubs below.
$GDrawioL3TopoMaxExternalHops = 6

# On the Layer 3 Topology Overview, how many VRF names to list on one device card before folding the
# rest into a "+N" count. Keeps a heavily VRF-segmented core's card from growing without bound.
$GDrawioL3TopoMaxVrfsPerCard = 3

# Legacy compatibility setting. Connectivity now draws every external next hop because omitting one
# would create a route with no endpoint; configured next hops live inside composite device boxes.
$GDrawioL3ConnMaxHubs = 8

# Legacy compatibility setting. Collapsed detail/identity summaries now list every hostname.
$GDrawioL3ConnMaxNamesPerGroup = 6

# On the Layer 3 Routes Summary page, show at most this many individual routing devices (ranked
# busiest-first, i.e. most significant routes first); the rest fold into one overflow card. This is
# the band-1 height backstop - the page is meant to fit a single 1080p screen.
$GDrawioRoutesSummaryMaxIndividualDevices = 12

# On the Layer 3 Routes Summary page, show at most this many single-static next-hop groups (ranked
# by member count); the rest fold into one overflow card. Band-3 backstop, same principle.
$GDrawioRoutesSummaryMaxGroups = 8

# On the Layer 3 Routes Summary page, show at most this many external next-hop cards (ranked by
# dependant count); the rest fold into one overflow card. Band-2 backstop.
$GDrawioRoutesSummaryMaxGateways = 8

# On the Layer 3 Routes Summary page, how many member hostnames to name inside one next-hop group
# before the rest become "+N more". 0 means unlimited and is the default: summary placement measures
# the real card height, so even very large groups remain clear without silently hiding membership.
$GDrawioRoutesSummaryMaxNamesPerGroup = 0

# On the firewall pages, show at most this many zones individually (ranked by interface count); the
# rest fold into one overflow card.
$GDrawioFirewallMaxZones = 14

# On the firewall pages, how many interfaces to list inside one zone before "+N more". A PAN-OS
# device can carry a dozen sub-interfaces in a single zone.
$GDrawioFirewallMaxInterfacesPerZone = 6

# On the FW Overview page only, show per-interface subnets when the whole device has this many
# addressed interfaces or fewer. Above it the page stays counts-only, which is its purpose. Set to 0
# to never show subnets there.
$GDrawioFirewallOverviewSubnetLimit = 4

# On the FW Rule Risk page, how many rule names to list inside one finding card before "+N more".
# A real rulebase can put 40+ rules in a single bucket, and the card is a pointer into Objects.json,
# not a replacement for it.
$GDrawioFirewallMaxRiskRulesPerCard = 8

# Degree thresholds (count of resolved CDP/LLDP neighbours) used to tier devices on the Site
# Topology Overview into Core / Distribution / Access. This is a derived display heuristic only -
# no vendor config exposes a "role" field, so treat these as a starting point to tune per network.
$GDrawioTopologyCoreDegreeThreshold = 5
$GDrawioTopologyDistDegreeThreshold = 2

# When $true, Access-tier devices (below the Distribution threshold) that resolve to one or zero
# CDP/LLDP neighbours are dropped from the Topology Overview entirely - they add little to a
# backbone-level view. Root bridges and multi-homed devices are always shown regardless.
$GDrawioTopologyHideLeafAccess = $false

# Which placement the Topology Overview uses. 'Radial' is the starburst everything below configures;
# the alternatives in PlacementStrategies.ps1 exist so the choice can be re-measured rather than
# assumed, and are selected here only for experiments.
#   Radial | SwapAnneal | Layered | DegreeRings | Spiral | Spine | SpineRadial
#   Balloon | Force | ForceSeeded | Community | Prefix | Treemap | HTree
$GDrawioTopologyPlacementStrategy = 'Radial'

# An optional tidy-up applied after placement. 'None', 'GridSnap' (line the cards up on a coarse
# grid) or 'Gravity' (pull every card toward the middle as far as it will go without touching
# anything). Both are measured through the same sweep as the strategies themselves.
$GDrawioTopologyPlacementPostPass = 'None'

# --- Starburst placement on the Topology Overview (Get-DrawioRadialPlacement) ---
# The page is laid out as concentric rings around the most central device.
#
# Every value below was chosen by measurement rather than taste. Each was scored across a range of
# topology shapes and sizes for card overlaps, links running through unrelated cards, link crossings
# and page size. Re-measure the same way after changing any of them.
#
# The clearance left between cards, which sets how tightly the rings pack: NodeGap between two cards
# side by side, RingGap between two stacked. They are separate because the cards are nearly three
# times wider than they are tall, so the same visual density needs a much larger horizontal figure.
# 35 rather than a more conservative 60: the tighter figure measurably reduces the zoom-out needed
# to read a whole page without adding links through cards or extra crossings. Tighter than this
# starts trading readability for size - at 35 the lines already pass close to the cards they miss.
$GDrawioTopologyRadialNodeGap = 35
$GDrawioTopologyRadialRingGap = 35

# How much wider than tall the rings are drawn. 1 gives true circles. A circular page has to be
# shrunk to its HEIGHT to be seen whole on a 16:9 screen, so a landscape starburst fits far more of
# itself on screen for the same content - measured across small, medium and large topologies,
# squashing to 1.8 cut the zoom-out needed to see the whole page by around 20%. Past roughly 2.2 it
# reverses, because the page then starts running off the sides instead. This is an exact coordinate
# scaling applied to the cards as well as to the rings, so it cannot make two cards overlap.
$GDrawioTopologyRadialAspect = 1.8

# Crossing-reduction sweeps over the starburst. Each sweep re-orders every device's children by the
# average direction of everything they link to, so a device that is also cross-linked to another
# branch is turned towards it. Four is past the point of diminishing returns; 0 keeps the plain
# BFS order.
$GDrawioTopologyRadialSweeps = 4

# Most concentric sub-rings one ring may be split into. A ring holding a lot of devices is what makes
# a big site's page enormous - its circumference has to fit every one of them - and splitting it so
# consecutive devices alternate between two or three sub-rings cuts the radius it needs by roughly
# the same factor, for one or two clearances of extra thickness. Each ring still costs every split
# and picks the cheapest for itself, so this is only a ceiling: raising it cannot make a sparse ring
# worse, and 1 forces every ring back to a single clean circle.
$GDrawioTopologyRadialMaxStagger = 3

# How far apart consecutive rings sit.
#   'Bound' uses the worst-case card diagonal and favors predictable clearance.
#   'Exact' finds the smallest radius that clears the cards at their actual angles and favors a
#            smaller page. Exact works best with end-unit grouping; use Bound if individual end-unit
#            cards create connector/card collisions on a dense topology.
$GDrawioTopologyRadialRingSpacing = 'Exact'

# Where independent starbursts (separate connected components) go.
#   'Shelf'  places rows below the main component.
#   'Corner' scores available corners and reuses space inside the main component's bounding box when
#            a small component fits there.
$GDrawioTopologyRadialClusterPacking = 'Corner'

# --- End-unit grouping on the Topology Overview ---
# An end unit is an uncaptured, single-link observed peer or inferred-evidence node. Configured
# devices are never eligible, because their tier, flags, and links require a full device card.
# Grouping several end units under their common parent reduces ring demand without hiding parsed
# devices.
#
#   'None'   draws every eligible end unit as its own card.
#   'Stack'  draws one narrow block per parent, one neighbor per line.
#   'Grid'   draws a roughly square block per parent.
#   'Wide'   draws one row per parent.
#   'Chip'   draws only the count; names are omitted from this page.
#
# Width consumes ring circumference while height consumes radial space, so Stack is the default for
# dense sites. See Get-MTAutoDrawEndUnitBlockLayout for the footprint rules.
$GDrawioTopologyEndUnitMode = 'Stack'

# Smallest group to replace with a shared block. Smaller groups remain individual cards.
$GDrawioTopologyEndUnitThreshold = 2

################################################################################
## --- Inferred topology evidence ---
## STP, exact MAC/CAM and ARP/CAM identity, and strict interface-description
## clues can reveal devices that are missing from CDP/LLDP discovery.
################################################################################

# Master drawing switch. The evidence model and topology-evidence.csv are still
# produced when disabled, but all rows are marked as not drawn.
$GIncludeInferredTopologyEvidence = $true

# Draw low-confidence/multi-frontier and description-only candidates as grey or
# dotted evidence. Strong single-frontier evidence is unaffected.
$GIncludeAmbiguousTopologyEvidence = $true

#endregion Layout limits

################################################################################
## --- TEMPORARY: per-step timing instrumentation ---
################################################################################
# Diagnostic only - it changes nothing the tool produces or decides. When on, every instrumented
# step prints a [perf] line as it finishes and the run ends with a table sorted by total time, so
# "the whole thing is slow" can be turned into "these three steps are 80% of it".
#
# Off by default. Turn it on for a run without editing anything:  $env:MTAUTODRAW_PERF = "1"
# See Start-MTAutoDrawPerf / Write-MTAutoDrawPerfSummary in Logging.ps1.
# Set global, not module-scoped like the layout settings above: the readers live in Logging.ps1,
# which is a different module, and this has to be reachable from every one of them.
$global:GPerfTiming = [bool]($env:MTAUTODRAW_PERF -eq "1")
$GPerfTiming = $global:GPerfTiming
