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


# MTAutoDraw - Diagram models: pages
#
# One model per remaining page or page family: the site topology overview, single-host physical,
# CDP/LLDP neighbor pages, single-host Layer 3, spanning tree, firewall interfaces, and the
# all-in-one Layer 3 page. DiagramModels.ps1 holds the topology-evidence/LLDP-peer/end-unit/
# firewall-policy models these draw on; DiagramModels.Layer3.ps1 holds the L3
# connectivity/routes/topology trio. A model here never touches the .drawio document.
#
# Depends on: nothing
# Loaded by:  AutoDraw.ps1 ($GLibrariesToLoad)

# Builds everything the Topology Overview page needs to know before it can place anything: who each
# device's vetted neighbours are, what tier it lands in, which observed LLDP peers and inferred
# evidence nodes get their own node, and which of those single-link non-devices collapse into an
# end-unit block. Configured devices always get their own node.
#
# Returned as one adjacency map plus one footprint map, keyed the same way, because that pair is
# exactly what the placement engine takes. Observed peers and evidence nodes are in the SAME maps as
# the configured devices, not alongside them - that is what puts an LLDP peer beside the switch that
# reported it rather than in a strip at the bottom of the page.
#
# Pure: no XML, no page state. It reads the topology config toggles and nothing the page set up.
function Get-MTAutoDrawSiteTopologyModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Devices,
        [AllowNull()]$TopologyEvidenceModel = $null
    )

    $ArrayOfObjects = $Devices

    $securityDeviceTypes = Get-MTAutoDrawSecurityDeviceTypes

    # --- Phase 1: resolve each device's neighbour set once, from the same vetted CDP/LLDP
    # resolution (.TargetHostname / .Ignored / .MatchConfidence) that Draw-AllNeighborsDrawio uses
    # above - not a fresh Resolve-ConfiguredNeighborName pass like the older CDP-LLDP pages use.
    # That distinction matters: Set-FloodedNeighborEntries has already run over this data, so a
    # shared/flooded segment doesn't fan out into extra edges here the way it can on that page.
    $neighborNamesByHost = @{}
    $observedPeersByHost = @{}
    $allObservedPeerRecords = [System.Collections.Generic.List[object]]::new()
    foreach ($device in $ArrayOfObjects) {
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($neighbor in (@($device.CDPNeighbors) + @($device.LLDPNeighbors))) {
            if ($neighbor.TargetHostname -and -not $neighbor.Ignored -and $neighbor.TargetHostname -ine $device.hostname) {
                if (-not $names.Contains($neighbor.TargetHostname)) { $names.Add($neighbor.TargetHostname) }
            }
        }
        $neighborNamesByHost[$device.hostname] = $names

        # Keep unresolved LLDP peers separate from configured-device resolution. Only
        # network-facing peers are promoted to the overview; endpoints stay in the
        # detailed LLDP output.
        $observedPeers = @(Get-MTAutoDrawObservedLldpPeers -Device $device |
            Where-Object { $_.IncludeOnOverview })
        $observedPeersByHost[$device.hostname] = $observedPeers
        foreach ($peer in $observedPeers) { $allObservedPeerRecords.Add($peer) }
    }

    # --- Phase 2: classify every device once - degree tier, security flag, root-bridge flag, and
    # whether it's multi-homed (only used to protect a device from the optional leaf-hiding filter
    # below; a device that routes for more than one subnet is never just a leaf). ---
    $classified = foreach ($device in $ArrayOfObjects) {
        $observedPeerCount = @($observedPeersByHost[$device.hostname] |
            Select-Object -ExpandProperty PeerKey -Unique).Count
        $degree = $neighborNamesByHost[$device.hostname].Count + $observedPeerCount
        $isRootBridge = [bool]($device.SpanningTree -and $device.SpanningTree.RootBridgeForVlans.Count -gt 0)
        $isSecurity = [bool](($device.DeviceType -and $device.DeviceType -in $securityDeviceTypes) -or
            (@($device.interfaces | Where-Object { $_.Zone }).Count -gt 0))
        $distinctCidrs = @($device.interfaces | Where-Object { -not $_.shutdown } |
            ForEach-Object { Get-MTAutoDrawInterfaceIPv4Address -Interface $_ } |
            Select-Object -ExpandProperty Cidr -Unique)
        $isMultiHomed = $distinctCidrs.Count -ge 2
        $tier = if ($degree -ge $GDrawioTopologyCoreDegreeThreshold) { 'Core' }
            elseif ($degree -ge $GDrawioTopologyDistDegreeThreshold) { 'Distribution' }
            else { 'Access' }

        [PSCustomObject]@{
            Device = $device; Degree = $degree; Tier = $tier
            IsSecurity = $isSecurity; IsRootBridge = $isRootBridge; IsMultiHomed = $isMultiHomed
        }
    }

    # Optionally drop low-value Access leaves so a very large site's overview stays focused on the
    # backbone. Off by default - every device is shown. Root bridges and multi-homed devices are
    # never dropped, regardless of this setting.
    if ($GDrawioTopologyHideLeafAccess) {
        $evidenceHostnames = @()
        if ($TopologyEvidenceModel) {
            $evidenceHostnames = @($TopologyEvidenceModel.Edges | Where-Object Drawn |
                ForEach-Object { @($_.SourceHostname,$_.TargetHostname) } |
                Where-Object { $_ } | Sort-Object -Unique)
        }
        $observedSourceHostnames = @($allObservedPeerRecords |
            Select-Object -ExpandProperty SourceHostname -Unique)
        $classified = @($classified | Where-Object {
            -not ($_.Tier -eq 'Access' -and $_.Degree -le 1 -and -not $_.IsRootBridge -and -not $_.IsMultiHomed -and
                $_.Device.hostname -notin $evidenceHostnames -and $_.Device.hostname -notin $observedSourceHostnames)
        })
    }

    # --- Phase 3: build the page's whole graph, then place it as a starburst. ---
    #
    # Everything drawn on this page is placed in ONE pass by Get-DrawioRadialPlacement: the most
    # central device sits in the middle, its neighbours fan out around it, their neighbours fan out
    # again inside the wedge their own parent occupies, and so on. Each device's Core/Distribution/
    # Access tier still drives its colour and shape exactly as before - that classification is what
    # the legend explains, and it stays per-device - but it no longer decides WHERE the device goes.
    #
    # Place configured devices, observed peers, and inferred evidence in one graph. A radial component
    # keeps directly related nodes in the same branch, while attached non-device nodes occupy the
    # outer part of their parent's wedge. This avoids treating degree bands or hostname order as
    # geometry and keeps short logical relationships short on the page.
    $entryByHostname = @{}
    foreach ($entry in $classified) { $entryByHostname[[string]$entry.Device.hostname] = $entry }

    $radialAdjacency = @{}
    $radialFootprints = @{}
    $deviceKeys = @($classified | ForEach-Object { [string]$_.Device.hostname })
    foreach ($key in $deviceKeys) {
        $radialAdjacency[$key] = @($neighborNamesByHost[$key])
        # Every device is a fixed 200x70 card (Add-DrawioTopologyNode).
        $radialFootprints[$key] = [PSCustomObject]@{ Width = $GDrawioOverviewNodeWidth; Height = 70 }
    }

    # Observed peers: one node per chassis, linked to every configured device that reported it. A
    # peer seen by two switches genuinely sits between them and the placer will put it between them.
    $observedPeerGroups = @($allObservedPeerRecords | Group-Object -Property PeerKey | Sort-Object Name)
    $observedPeerRadialKey = @{}
    foreach ($peerGroup in $observedPeerGroups) {
        $sourceHostnames = @($peerGroup.Group | ForEach-Object { [string]$_.SourceHostname } |
            Where-Object { $entryByHostname.ContainsKey($_) } | Sort-Object -Unique)
        if ($sourceHostnames.Count -eq 0) { continue }
        $radialKey = "peer:$($peerGroup.Name)"
        $observedPeerRadialKey[[string]$peerGroup.Name] = $radialKey
        $radialAdjacency[$radialKey] = $sourceHostnames
        $radialFootprints[$radialKey] = [PSCustomObject]@{ Width = 180; Height = 58 }
    }

    # Inferred evidence nodes, on the same footing. Edges whose target is an already-drawn device
    # (NodeKind 'ExistingDevice') contribute no node of their own - only the ones that stand for
    # something not captured do.
    $evidenceNodesToDraw = @()
    $drawnEvidenceEdges = @()
    $evidenceRadialKey = @{}
    if ($TopologyEvidenceModel -and $GIncludeInferredTopologyEvidence) {
        $drawnEvidenceEdges = @($TopologyEvidenceModel.Edges | Where-Object { $_.Drawn })
        $referencedNodeIds = @($drawnEvidenceEdges | Where-Object NodeId | Select-Object -ExpandProperty NodeId -Unique)
        $evidenceNodesToDraw = @($TopologyEvidenceModel.Nodes | Where-Object { $_.NodeId -in $referencedNodeIds } | Sort-Object NodeId)
        foreach ($node in $evidenceNodesToDraw) {
            $sourceHostnames = @($drawnEvidenceEdges | Where-Object { [string]$_.NodeId -eq [string]$node.NodeId } |
                ForEach-Object { [string]$_.SourceHostname } | Where-Object { $entryByHostname.ContainsKey($_) } | Sort-Object -Unique)
            if ($sourceHostnames.Count -eq 0) { continue }
            $radialKey = "evidence:$($node.NodeId)"
            $evidenceRadialKey[[string]$node.NodeId] = $radialKey
            $radialAdjacency[$radialKey] = $sourceHostnames
            $radialFootprints[$radialKey] = [PSCustomObject]@{ Width = 240; Height = 82 }
        }

        # An 'ExistingDevice' evidence edge contributes no node of its own - the target already has
        # one - but the link itself is real graph structure and belongs in the placement graph.
        # Without it, a device whose only CDP/LLDP-resolved link is a single uplink but which several
        # other switches independently designate as their neighbour (e.g. a fiber distribution switch
        # reached only via STP evidence) is placed as a bare one-link leaf out on the rim, instead of
        # in the middle of the branch that actually depends on it. It no longer decides whether the
        # device is COLLAPSED - a configured device never is - only where it lands.
        foreach ($edge in ($drawnEvidenceEdges | Where-Object { $_.NodeKind -eq 'ExistingDevice' -and $_.TargetHostname })) {
            $from = [string]$edge.SourceHostname
            $to = [string]$edge.TargetHostname
            if ($from -ieq $to -or -not $entryByHostname.ContainsKey($from) -or -not $entryByHostname.ContainsKey($to)) { continue }
            if ($radialAdjacency[$from] -notcontains $to) { $radialAdjacency[$from] = @($radialAdjacency[$from]) + $to }
            if ($radialAdjacency[$to] -notcontains $from) { $radialAdjacency[$to] = @($radialAdjacency[$to]) + $from }
        }
    }

    # --- End-unit collapsing ------------------------------------------------------------------
    # Observed peers and inferred-evidence nodes with exactly one link carry no topology: they
    # terminate, and every one of them hanging off the same parent says the same thing. They are also
    # most of a typical site's node count. Folding each such group into one block hands the placer ONE
    # slot and ONE link where it had several - see Get-MTAutoDrawEndUnitGroups.
    #
    # ONLY they are eligible. Every configured device keeps its own card however few links it has,
    # which is what -CollapsibleKeys below enforces: the eligible set is "every radial key that is not
    # a device", so anything new added to this graph is collapsible by default and devices never are.
    # $radialAdjacency.Keys - not the eligible set - is still passed as -Keys, because degree and the
    # parent test must see the whole graph.
    #
    # The whole substitution happens here, before placement, so nothing downstream needs to know: the
    # placer sees a normal node that happens to be a different size, and the connector phase below
    # finds the block's shape id where it would have found the member's, because collapsed members are
    # given the block's id. That is what keeps this from touching the edge-drawing code at all.
    $endUnitBlocks = [System.Collections.Generic.List[object]]::new()
    if ($GDrawioTopologyEndUnitMode -ne 'None') {
        # No configured-device branch: -CollapsibleKeys below cannot hand this a device hostname.
        $memberDescriptor = {
            param([string]$Key)
            if ($Key -like 'peer:*') {
                $peerKey = $Key.Substring(5)
                $group = @($observedPeerGroups | Where-Object { [string]$_.Name -eq $peerKey }) | Select-Object -First 1
                if ($group) {
                    $peer = @($group.Group | Sort-Object SourceHostname, SourceInterface)[0]
                    return [pscustomobject]@{ Title = [string]$peer.PeerHostname; Detail = [string]$peer.SourceInterface }
                }
            }
            if ($Key -like 'evidence:*') {
                $nodeId = $Key.Substring(9)
                $node = @($evidenceNodesToDraw | Where-Object { [string]$_.NodeId -eq $nodeId }) | Select-Object -First 1
                if ($node) { return [pscustomobject]@{ Title = [string]$node.Label; Detail = '' } }
            }
            return [pscustomobject]@{ Title = $Key; Detail = '' }
        }

        $groups = Get-MTAutoDrawEndUnitGroups -Adjacency $radialAdjacency `
            -Keys @($radialAdjacency.Keys | ForEach-Object { [string]$_ }) `
            -CollapsibleKeys @($radialAdjacency.Keys | ForEach-Object { [string]$_ } |
                Where-Object { -not $entryByHostname.ContainsKey($_) }) `
            -Threshold $GDrawioTopologyEndUnitThreshold
        $blockIndex = 0
        foreach ($group in $groups) {
            $members = @($group.Members | ForEach-Object { & $memberDescriptor $_ })
            $layout = Get-MTAutoDrawEndUnitBlockLayout -Mode $GDrawioTopologyEndUnitMode -Members $members
            $blockKey = "endunit:$blockIndex"
            $blockIndex++
            foreach ($member in @($group.Members)) { $null = $radialAdjacency.Remove($member); $null = $radialFootprints.Remove($member) }
            $radialAdjacency[$blockKey] = @([string]$group.Parent)
            $radialFootprints[$blockKey] = [PSCustomObject]@{ Width = $layout.Width; Height = $layout.Height }
            $endUnitBlocks.Add([pscustomobject]@{
                Key = $blockKey; Parent = [string]$group.Parent
                Members = @($group.Members); Layout = $layout; Count = @($group.Members).Count
            })
        }
    }

    return [pscustomobject]@{
        # Per-device classification, in the order the page draws them.
        Classified            = @($classified)
        DeviceKeys            = @($classified | ForEach-Object { [string]$_.Device.hostname })
        EntryByHostname       = $entryByHostname
        NeighborNamesByHost   = $neighborNamesByHost
        # One group per observed LLDP chassis, and the adjacency key each was given.
        ObservedPeerGroups    = @($observedPeerGroups)
        # Every peer sighting, not grouped: the page needs the raw records to draw one edge per sighting.
        AllObservedPeerRecords = @($allObservedPeerRecords)
        ObservedPeerRadialKey = $observedPeerRadialKey
        # Inferred evidence that stands for something not captured.
        EvidenceNodesToDraw   = @($evidenceNodesToDraw)
        DrawnEvidenceEdges    = @($drawnEvidenceEdges)
        EvidenceRadialKey     = $evidenceRadialKey
        # Single-link observed peers / evidence nodes folded into one block each. Never a device.
        EndUnitBlocks         = @($endUnitBlocks)
        # What the placement engine consumes.
        Adjacency             = $radialAdjacency
        Footprints            = $radialFootprints
    }
}


# Builds one configured or discovered panel for a single-host physical page.
function New-MTAutoDrawHostPhysicalPanel {
    [CmdletBinding()]
    param($PanelDevice, [string]$DrawType)

    if ($PanelDevice.DeviceIdentifier) {
        $selection = Get-DrawioHostPhysicalInterfaces -Device $PanelDevice -DrawAllNeighbors $true -TopologyEvidenceModel $null
        $sideOf = @{}
        foreach ($name in @($selection.All.Interface)) { $sideOf[[string]$name] = 'S' }
        return [pscustomobject]@{
            Device = $PanelDevice; IsConfigured = $true; DrawType = $DrawType
            Interfaces = $selection.All; SideOf = $sideOf
            MacBubbleInterfaceNames = @($selection.MacBubbleInterfaces.Interface)
        }
    }

    $interfaces = @($PanelDevice.interfaces | Where-Object { $_ })
    $sideOf = @{}
    foreach ($name in @($interfaces.Interface)) { $sideOf[[string]$name] = 'N' }
    return [pscustomobject]@{
        Device = $PanelDevice; IsConfigured = $false; DrawType = $DrawType
        Interfaces = $interfaces; SideOf = $sideOf; MacBubbleInterfaceNames = @()
    }
}

# Decides what the "<host> Physical" page draws: the primary host's own interface selection, and one
# panel per neighbour that can be resolved to a device - configured ones drawn as full hosts, ones
# known only from a CDP or LLDP sighting drawn as a simple neighbour box.
#
# Order is the output, not an accident of it: CDP neighbours first in the order the device reported
# them, then LLDP neighbours that CDP did not already cover. The page lays panels out left to right
# in exactly that order, so re-sorting here would move every shape on the page.
#
# A neighbour is drawn once however many adjacencies point at it, which is why the dedupe belongs
# here rather than in the drawing loop.
#
# Pure: reads the device arrays and nothing the page set up.
function Get-MTAutoDrawHostPhysicalModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Devices,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$CdpHosts,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$LldpHosts
    )

    $primarySelection = Get-DrawioHostPhysicalInterfaces -Device $Device -DrawAllNeighbors $true -TopologyEvidenceModel $null
    $primarySideOf = @{}
    foreach ($name in @($primarySelection.All.Interface)) { $primarySideOf[[string]$name] = 'S' }

    $panels = [System.Collections.Generic.List[object]]::new()
    $devicesToConnect = [System.Collections.Generic.List[object]]::new()
    $devicesToConnect.Add($Device)
    $drawnNeighbors = @{}

    # --- Lookups built once per page instead of scanning devices for every neighbor. --------------
    # $interfaceOwner uses object-reference identity. First writer wins; the model contract assigns
    # an interface object to exactly one device, so a tie indicates malformed input.
    $interfaceOwner = [System.Collections.Generic.Dictionary[object,object]]::new()
    foreach ($ownerDevice in @($Devices)) {
        foreach ($ownerInterface in @($ownerDevice.interfaces)) {
            if ($ownerInterface -and -not $interfaceOwner.ContainsKey($ownerInterface)) {
                $interfaceOwner[$ownerInterface] = $ownerDevice
            }
        }
    }

    # Discovered-host names, cleaned once with the same two regexes the loops used per candidate.
    $cdpHostByCleanName = @{}
    foreach ($cdpHost in @($CdpHosts)) {
        $cleanName = ([string]$cdpHost.HostName -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim()
        if ($cleanName -and -not $cdpHostByCleanName.ContainsKey($cleanName)) { $cdpHostByCleanName[$cleanName] = $cdpHost }
    }

    # The LLDP side matched a discovered host on EITHER the advertised name or the chassis id, in a
    # single pass over $LldpHosts - so the winner is whichever host comes first in that array,
    # whichever of the two values it matched on. Keeping the index preserves exactly that, where two
    # separate name/chassis dictionaries would have silently preferred a name match further down the
    # list over a chassis match at the top of it.
    $lldpHostByCleanName = @{}
    $lldpHostIndex = 0
    foreach ($lldpHost in @($LldpHosts)) {
        $cleanName = ([string]$lldpHost.hostname -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim()
        if ($cleanName -and -not $lldpHostByCleanName.ContainsKey($cleanName)) {
            $lldpHostByCleanName[$cleanName] = [pscustomobject]@{ Device = $lldpHost; Index = $lldpHostIndex }
        }
        $lldpHostIndex++
    }

    # --- CDP neighbours ---
    foreach ($cdpNeighbor in @($Device.CDPNeighbors)) {
        $partnerHost = $null
        if ($cdpNeighbor.PartnerEthernetInterface -and $cdpNeighbor.PartnerEthernetInterface.Value) {
            $partnerInterface = $cdpNeighbor.PartnerEthernetInterface.Value
            if ($interfaceOwner.ContainsKey($partnerInterface)) { $partnerHost = $interfaceOwner[$partnerInterface] }
        }
        else {
            $cleanedNeighborID = ($cdpNeighbor.DeviceID -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim()
            if ($cleanedNeighborID -and $cdpHostByCleanName.ContainsKey($cleanedNeighborID)) { $partnerHost = $cdpHostByCleanName[$cleanedNeighborID] }
        }
        if (-not $partnerHost -or $drawnNeighbors.ContainsKey($partnerHost.HostName)) { continue }

        $panels.Add((New-MTAutoDrawHostPhysicalPanel -PanelDevice $partnerHost -DrawType 'CDPNeighbor'))
        $drawnNeighbors[$partnerHost.HostName] = $partnerHost
        $devicesToConnect.Add($partnerHost)
    }

    # --- LLDP neighbours CDP did not already account for ---
    foreach ($lldpNeighbor in @($Device.LLDPNeighbors | Where-Object { -not $_.HasCDPNeighborEntry })) {
        $partnerHost = $null
        if ($lldpNeighbor.PartnerEthernetInterface -and $lldpNeighbor.PartnerEthernetInterface.Value) {
            $partnerInterface = $lldpNeighbor.PartnerEthernetInterface.Value
            if ($interfaceOwner.ContainsKey($partnerInterface)) { $partnerHost = $interfaceOwner[$partnerInterface] }
        }
        else {
            # A discovered-only LLDP peer is matched on either the advertised system name or the
            # chassis id, because a device that advertises no name appears under its chassis id.
            # Whichever candidate sits earlier in $LldpHosts wins, exactly as the single pass did.
            $cleanedNeighborHostName = if (-not [string]::IsNullOrEmpty($lldpNeighbor.HostName)) { ($lldpNeighbor.HostName -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim() }
            $cleanedChassisId = if (-not [string]::IsNullOrEmpty($lldpNeighbor.ChassisID)) { ($lldpNeighbor.ChassisID -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim() }
            $byName = if ($cleanedNeighborHostName -and $lldpHostByCleanName.ContainsKey($cleanedNeighborHostName)) { $lldpHostByCleanName[$cleanedNeighborHostName] } else { $null }
            $byChassis = if ($cleanedChassisId -and $lldpHostByCleanName.ContainsKey($cleanedChassisId)) { $lldpHostByCleanName[$cleanedChassisId] } else { $null }
            $winner = if ($byName -and $byChassis) { if ($byName.Index -le $byChassis.Index) { $byName } else { $byChassis } }
                elseif ($byName) { $byName } else { $byChassis }
            if ($winner) { $partnerHost = $winner.Device }
        }
        if (-not $partnerHost -or $drawnNeighbors.ContainsKey($partnerHost.HostName)) { continue }

        $panels.Add((New-MTAutoDrawHostPhysicalPanel -PanelDevice $partnerHost -DrawType 'LLDPNeighbor'))
        $drawnNeighbors[$partnerHost.HostName] = $partnerHost
        $devicesToConnect.Add($partnerHost)
    }

    return [pscustomobject]@{
        Primary = [pscustomobject]@{
            Device                 = $Device
            Interfaces             = $primarySelection.All
            SideOf                 = $primarySideOf
            MacBubbleInterfaceNames = @($primarySelection.MacBubbleInterfaces.Interface)
        }
        Panels           = @($panels)
        DevicesToConnect = $devicesToConnect
    }
}

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


#-----------------------------------------------------------------------------------------
# Helper Function: Get-DrawioNeighborNodes
#-----------------------------------------------------------------------------------------
# Builds the unified node registry for the CDP-LLDP pages - every configured device plus, on the
# "All" page, every device CDP/LLDP discovered but has no local config - and a lookup from every
# drawn interface object back to the node key that owns it. That lookup is what lets wire-building
# below turn a resolved neighbour interface into a node the tiering/placement code can reason about.
#
# Discovered devices are keyed by their index in whichever array reported them, not by hostname -
# the same physical box can legitimately appear once via CDP and once via LLDP, and is drawn as two
# separate cards when it does. Index keys can never collide on that; hostnames would.
function Get-DrawioNeighborNodes {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $ArrayOfObjects,
        [parameter(Mandatory = $true)] $ArrayOfCDPDeviceIDs,
        [parameter(Mandatory = $true)] $ArrayOfLLDPDeviceIDs,
        [parameter(Mandatory = $true)] $DrawAllNeighbors
    )

    $nodeInfo = @{}
    $nodesByInterface = [System.Collections.Generic.Dictionary[object, string]]::new()

    foreach ($device in @($ArrayOfObjects | Where-Object { $_ } | Sort-Object HostName)) {
        $key = "cfg:$($device.HostName)"
        $nodeInfo[$key] = [PSCustomObject]@{ Key = $key; Kind = 'Configured'; Device = $device; DrawType = $null }
        foreach ($iface in @($device.interfaces | Where-Object { $_ })) { $nodesByInterface[$iface] = $key }
    }

    if ($DrawAllNeighbors) {
        $index = 0
        foreach ($discovered in @($ArrayOfCDPDeviceIDs | Where-Object { $_ })) {
            $key = "cdp:$index"; $index++
            $nodeInfo[$key] = [PSCustomObject]@{ Key = $key; Kind = 'Discovered'; Device = $discovered; DrawType = 'CDPNeighbor' }
            foreach ($iface in @($discovered.interfaces | Where-Object { $_ })) { $nodesByInterface[$iface] = $key }
        }
        $index = 0
        foreach ($discovered in @($ArrayOfLLDPDeviceIDs | Where-Object { $_ })) {
            $key = "lldp:$index"; $index++
            $nodeInfo[$key] = [PSCustomObject]@{ Key = $key; Kind = 'Discovered'; Device = $discovered; DrawType = 'LLDPNeighbor' }
            foreach ($iface in @($discovered.interfaces | Where-Object { $_ })) { $nodesByInterface[$iface] = $key }
        }
    }

    return [PSCustomObject]@{ NodeInfo = $nodeInfo; NodesByInterface = $nodesByInterface }
}


#-----------------------------------------------------------------------------------------
# Helper Function: Get-DrawioNeighborWires
#-----------------------------------------------------------------------------------------
# Every CDP/LLDP link to draw, as a (FromInterface, ToInterface, Style) triple - the matching rules
# are the exact four cases the original single-pass version handled inline (configured-to-configured
# and configured-to-discovered, once each for CDP and LLDP), just building a list instead of drawing
# immediately, because the perimeter-port layout has to see every wire before it can decide which
# side of a host each interface belongs on.
function Get-DrawioNeighborWires {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $ArrayOfObjects,
        [parameter(Mandatory = $true)] $ArrayOfCDPDeviceIDs,
        [parameter(Mandatory = $true)] $ArrayOfLLDPDeviceIDs,
        [parameter(Mandatory = $true)] $DrawAllNeighbors,
        [parameter(Mandatory = $true)] [System.Collections.Generic.Dictionary[object, string]]$NodesByInterface
    )

    $wires = [System.Collections.Generic.List[object]]::new()

    foreach ($device in @($ArrayOfObjects | Where-Object { $_ })) {
        if ($device.CDPNeighbors) {
            foreach ($cdpNeighbor in ($device.CDPNeighbors | Where-Object { $_.PartnerEthernetInterface -and $_.PartnerEthernetInterface.Value })) {
                $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $cdpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
                $toInterface = $cdpNeighbor.PartnerEthernetInterface.Value
                if ($fromInterface -and $toInterface -and $NodesByInterface.ContainsKey($fromInterface) -and $NodesByInterface.ContainsKey($toInterface)) {
                    $wires.Add([PSCustomObject]@{ FromInterface = $fromInterface; ToInterface = $toInterface; Style = (Get-ConnectorStyle -fromInterface $fromInterface -MatchConfidence $cdpNeighbor.MatchConfidence) })
                }
            }
            if ($DrawAllNeighbors) {
                foreach ($cdpNeighbor in ($device.CDPNeighbors | Where-Object { -not $_.PartnerEthernetInterface })) {
                    $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $cdpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
                    $toDevice = $ArrayOfCDPDeviceIDs | Where-Object { $_.HostName -eq $cdpNeighbor.DeviceID } | Select-Object -First 1
                    if ($toDevice) {
                        $toInterface = $toDevice.interfaces | Where-Object { $_.Interface -eq $cdpNeighbor.InterfaceRemoteDevice } | Select-Object -First 1
                        if ($fromInterface -and $toInterface -and $NodesByInterface.ContainsKey($fromInterface) -and $NodesByInterface.ContainsKey($toInterface)) {
                            $wires.Add([PSCustomObject]@{ FromInterface = $fromInterface; ToInterface = $toInterface; Style = (Get-ConnectorStyle -fromInterface $fromInterface) })
                        }
                    }
                }
            }
        }

        if ($device.LLDPNeighbors) {
            foreach ($lldpNeighbor in ($device.LLDPNeighbors | Where-Object { $_.PartnerEthernetInterface -and $_.PartnerEthernetInterface.Value })) {
                $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $lldpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
                $toInterface = $lldpNeighbor.PartnerEthernetInterface.Value
                if ($fromInterface -and $toInterface -and $NodesByInterface.ContainsKey($fromInterface) -and $NodesByInterface.ContainsKey($toInterface)) {
                    $wires.Add([PSCustomObject]@{ FromInterface = $fromInterface; ToInterface = $toInterface; Style = (Get-ConnectorStyle -fromInterface $fromInterface -MatchConfidence $lldpNeighbor.MatchConfidence) })
                }
            }
            if ($DrawAllNeighbors) {
                foreach ($lldpNeighbor in ($device.LLDPNeighbors | Where-Object { (-not $_.PartnerEthernetInterface) -and (-not $_.HasCDPNeighborEntry) })) {
                    $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $lldpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
                    $toInterface = $null
                    :outer foreach ($discoveredDevice in $ArrayOfLLDPDeviceIDs) {
                        $cleanedNeighborHostName = if (-not [string]::IsNullOrEmpty($lldpNeighbor.HostName)) { ($lldpNeighbor.HostName -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim() }
                        $cleanedChassisId = if (-not [string]::IsNullOrEmpty($lldpNeighbor.ChassisID)) { ($lldpNeighbor.ChassisID -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim() }
                        if (($discoveredDevice.hostname -eq $cleanedNeighborHostName) -or ($discoveredDevice.hostname -eq $lldpNeighbor.HostName) -or ($discoveredDevice.hostname -eq $cleanedChassisId) -or ($discoveredDevice.hostname -eq $lldpNeighbor.ChassisID)) {
                            foreach ($remoteInterface in $discoveredDevice.interfaces) {
                                if ($remoteInterface.Interface -eq $lldpNeighbor.InterfaceRemoteDevice) { $toInterface = $remoteInterface; break outer }
                            }
                        }
                    }
                    if (-not $toInterface) {
                        Write-MTAutoDrawLog -Level Warn -Phase Draw -Message "Could not find a matching discovered LLDP device for neighbor '$($lldpNeighbor.HostName)' on interface '$($lldpNeighbor.InterfaceRemoteDevice)'. Skipping connector."
                    }
                    if ($fromInterface -and $toInterface -and $NodesByInterface.ContainsKey($fromInterface) -and $NodesByInterface.ContainsKey($toInterface)) {
                        $wires.Add([PSCustomObject]@{ FromInterface = $fromInterface; ToInterface = $toInterface; Style = (Get-ConnectorStyle -fromInterface $fromInterface) })
                    }
                }
            }
        }
    }

    return , @($wires)
}


#-----------------------------------------------------------------------------------------
# Helper Function: Get-DrawioNeighborNodeFootprint
#-----------------------------------------------------------------------------------------
# One node's footprint for a given per-port side assignment, dispatching to whichever draw family
# (configured vs discovered) the node belongs to. $SideOf may be $null / empty, in which case ports
# are split evenly across the S/N sides as a placement estimate - see the two-round comment on
# Draw-AllNeighborsDrawio for why an estimate is needed before real sides can be decided.
function Get-DrawioNeighborNodeFootprint {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $Node,
        [hashtable]$SideOf,
        [hashtable]$DesiredOf = @{}
    )

    if (-not $SideOf -or $SideOf.Count -eq 0) {
        $SideOf = @{}
        $names = @($Node.Interfaces.Interface)
        for ($i = 0; $i -lt $names.Count; $i++) { $SideOf[[string]$names[$i]] = if ($i % 2 -eq 0) { 'S' } else { 'N' } }
    }

    $variant = if ($Node.Kind -eq 'Configured') { 'Configured' } else { [string]$Node.DrawType }
    return Get-DrawioPhysicalHostFootprint -Device $Node.Device -Interfaces $Node.Interfaces -SideOf $SideOf `
        -Variant $variant -MacBubbleInterfaceNames $Node.MacBubbleNames
}

# Everything the CDP-LLDP pages need to know before they can place anything: which nodes exist, what
# wires join them, and which interfaces each node draws.
#
# Get-DrawioNeighborNodes and Get-DrawioNeighborWires already existed and are called from here rather
# than reimplemented - folding them into one entry point is the point, so a page asks one question
# instead of three and cannot get the order of them wrong.
#
# Every pass over NodeInfo sorts by Key rather than taking raw .Values order. Hashtable enumeration
# order is not a documented guarantee in .NET and the draw pass assigns shape ids in iteration order,
# so an unsorted pass could emit a byte-different file from identical input.
#
# Pure: reads the device arrays and the DrawAllNeighbors switch, and nothing the page set up.
function Get-MTAutoDrawNeighborPageModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$ArrayOfObjects,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$ArrayOfCDPDeviceIDs,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$ArrayOfLLDPDeviceIDs,
        [bool]$DrawAllNeighbors = $true,
        [AllowNull()]$TopologyEvidenceModel = $null
    )

    $registry = Get-DrawioNeighborNodes -ArrayOfObjects $ArrayOfObjects -ArrayOfCDPDeviceIDs $ArrayOfCDPDeviceIDs `
        -ArrayOfLLDPDeviceIDs $ArrayOfLLDPDeviceIDs -DrawAllNeighbors $DrawAllNeighbors
    $nodeInfo = $registry.NodeInfo
    $nodesByInterface = $registry.NodesByInterface

    $wires = @()
    if ($nodeInfo.Count -gt 0) {
        $wires = Get-DrawioNeighborWires -ArrayOfObjects $ArrayOfObjects -ArrayOfCDPDeviceIDs $ArrayOfCDPDeviceIDs `
            -ArrayOfLLDPDeviceIDs $ArrayOfLLDPDeviceIDs -DrawAllNeighbors $DrawAllNeighbors -NodesByInterface $nodesByInterface

        # Which interfaces each node draws. A configured device gets the same selection it would get
        # on its own page; a discovered-only sighting draws whatever interfaces it reported.
        foreach ($node in @($nodeInfo.Values | Sort-Object Key)) {
            if ($node.Kind -eq 'Configured') {
                $selection = Get-DrawioHostPhysicalInterfaces -Device $node.Device -DrawAllNeighbors $DrawAllNeighbors -TopologyEvidenceModel $TopologyEvidenceModel
                $node | Add-Member -NotePropertyName Interfaces -NotePropertyValue @($selection.All) -Force
                $node | Add-Member -NotePropertyName MacBubbleNames -NotePropertyValue @($selection.MacBubbleInterfaces.Interface) -Force
            }
            else {
                $node | Add-Member -NotePropertyName Interfaces -NotePropertyValue @($node.Device.interfaces | Where-Object { $_ }) -Force
                $node | Add-Member -NotePropertyName MacBubbleNames -NotePropertyValue @() -Force
            }
        }
    }

    return [pscustomobject]@{
        NodeInfo         = $nodeInfo
        NodesByInterface = $nodesByInterface
        Wires            = $wires
    }
}

# Decides what a single device's "<host> L3" page draws, for both of its shapes.
#
# Normal: the shared network objects this device is connected to, in the order the page stacks them.
# The shared object is used rather than the device's own copy so the connector count and ARP entries
# on the page are the site-wide ones.
#
# RoutesOnly: which other devices have a routing relationship with this one. The test is two-way on
# purpose - a peer counts if this device routes via it OR it routes via this device - because a
# default route pointing at a core switch is a relationship the core switch's own table never
# mentions.
#
# Not pure, and deliberately so: it clears and sets DrawOnRoutesOnlyDiagram on the interfaces that
# carry a drawn link. That flag lives on the shared interface objects because the connector pass and
# the shape pass both need it, and copying it out would mean two places could disagree.
function Get-MTAutoDrawSingleHostL3Model {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [Parameter(Mandatory = $true)][string]$DiagramType,
        [AllowEmptyCollection()]$SharedNetworks = @(),
        [AllowEmptyCollection()]$Devices = @(),
        [AllowEmptyCollection()]$GatewayHosts = @()
    )

    $networks = @()
    $primaryIpMap = @{}
    $peersToDraw = @{}

    if ($DiagramType -eq 'Normal') {
        foreach ($deviceNetwork in @($Device.ArrayOfNetworks)) {
            $shared = $SharedNetworks | Where-Object { $_.cidr -eq $deviceNetwork.cidr } | Select-Object -First 1
            if ($shared) { $networks += $shared }
        }
        $networks = @($networks | Sort-Object NumberOfConnectors, RoutedVlan, cidr)
        return [pscustomobject]@{ Networks = $networks; PrimaryIpMap = $primaryIpMap; PeersToDraw = $peersToDraw }
    }

    if ($DiagramType -ne 'RoutesOnly') {
        return [pscustomobject]@{ Networks = $networks; PrimaryIpMap = $primaryIpMap; PeersToDraw = $peersToDraw }
    }

    if (-not $Devices) {
        throw "The -Devices parameter, containing all device objects, is required when DiagramType is 'RoutesOnly'."
    }
    $allPossiblePeers = $Devices + $GatewayHosts

    # Address -> the interface and device that owns it. First owner wins, which matters for an
    # address two devices both claim: the page draws one link, not two.
    foreach ($deviceObject in $allPossiblePeers) {
        if (-not $deviceObject.interfaces) { continue }
        foreach ($iface in $deviceObject.interfaces) {
            foreach ($address in @(Get-MTAutoDrawInterfaceIPv4Address -Interface $iface)) {
                if (-not $address.IPAddress) { continue }
                if (-not $primaryIpMap.ContainsKey($address.IPAddress)) {
                    $primaryIpMap[$address.IPAddress] = [PSCustomObject]@{ Interface = $iface; Device = $deviceObject }
                }
            }
            # Cleared for every device on every page: the flag is per-page state on a shared object.
            $iface.DrawOnRoutesOnlyDiagram = $false
        }
    }

    # This device routes via the peer...
    if ($Device.RoutingTable) {
        foreach ($route in $Device.RoutingTable | Where-Object Gateway) {
            $targetInfo = $primaryIpMap[$route.gateway]
            if ($targetInfo -and $targetInfo.Device.hostname -ne $Device.hostname) {
                $peersToDraw[$targetInfo.Device.hostname] = $targetInfo.Device
            }
        }
    }
    # ...or the peer routes via this device.
    foreach ($otherDevice in ($allPossiblePeers | Where-Object { $_.hostname -ne $Device.hostname })) {
        if (-not $otherDevice.RoutingTable) { continue }
        foreach ($route in $otherDevice.RoutingTable | Where-Object Gateway) {
            $targetInfo = $primaryIpMap[$route.gateway]
            if ($targetInfo -and $targetInfo.Device.hostname -eq $Device.hostname) {
                $peersToDraw[$otherDevice.hostname] = $otherDevice
                break
            }
        }
    }

    # Flag both ends of every link the page will draw.
    foreach ($sourceDevice in (@($Device) + $peersToDraw.Values)) {
        foreach ($interface in ($sourceDevice.interfaces | Where-Object { $_.RoutesForInterface })) {
            foreach ($group in ($interface.RoutesForInterface | Where-Object Gateway | Group-Object Gateway)) {
                $targetInfo = $primaryIpMap[$group.Name]
                if ($targetInfo -and ($targetInfo.Device.hostname -eq $Device.hostname -or $peersToDraw.ContainsKey($targetInfo.Device.hostname))) {
                    $interface.DrawOnRoutesOnlyDiagram = $true
                    $targetInfo.Interface.DrawOnRoutesOnlyDiagram = $true
                }
            }
        }
    }

    return [pscustomobject]@{ Networks = $networks; PrimaryIpMap = $primaryIpMap; PeersToDraw = $peersToDraw }
}

# Splits the devices the Spanning-Tree page draws into the two rows it draws them in, and decides the
# order within each.
#
# Root bridges go alphabetically - there is nothing better to sort them by, and the page puts them in
# the top row.
#
# Non-root switches are sorted by whichever root bridge most of their VLAN instances point to - the
# mode, for a PVST or RPVST device carrying several - rather than by hostname. That is what actually
# shortens the connectors: switches in the same spanning-tree domain land next to each other instead
# of being scattered alphabetically. Hostname is the tiebreak, so the order is still deterministic.
#
# Pure: reads the device array and nothing else.
function Get-MTAutoDrawSpanningTreeModel {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()]$Devices)

    $rootHosts = @($Devices |
        Where-Object { ($_.SpanningTree.SpanningTreeArray | Where-Object { $_.RootBridge -eq $true }).Count -gt 0 } |
        Sort-Object HostName)

    $nonRootHosts = @($Devices |
        Where-Object { ($_.SpanningTree.SpanningTreeArray | Where-Object { $_.RootBridge -eq $true }).Count -eq 0 } |
        Sort-Object -Property @(
            @{ Expression = {
                $rootGroups = @($_.SpanningTree.SpanningTreeArray | Where-Object { -not $_.RootBridge } | Group-Object { ConvertTo-NormalizedMacAddress $_.Address })
                if ($rootGroups.Count -gt 0) { ($rootGroups | Sort-Object Count -Descending | Select-Object -First 1).Name } else { "" }
            } },
            @{ Expression = { $_.HostName } }
        ))

    return [pscustomobject]@{
        RootHosts    = $rootHosts
        NonRootHosts = $nonRootHosts
    }
}



#-----------------------------------------------------------------------------------------
# Helper: shared firewall page setup
#-----------------------------------------------------------------------------------------
# Both firewall pages need the same view of a device: its zones (with the interfaces in each) and a
# few headline counts. Built once here so the two pages can never disagree about what a zone is or
# how many there are.
function Get-MTAutoDrawFirewallInterfaceModel {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Device)

    $interfaces = @($Device.interfaces | Where-Object { $_ })
    # ASA reports nameif here rather than a true zone; both answer "which segment is this interface
    # on", which is what these pages group by. The label on the page says which one it is.
    $zoneGroups = @($interfaces | Where-Object { $_.Zone } | Group-Object Zone | Sort-Object @{ Expression = { -1 * $_.Count } }, Name)
    $ipInterfaces = @($interfaces | Where-Object { $_.IPAddress -or $_.Cidr })

    $zonelessWithIp = @($ipInterfaces | Where-Object { -not $_.Zone })

    # Both firewall pages cap how many zones they draw and collapse the rest into an overflow card.
    $zoneCap = if ($GDrawioFirewallMaxZones -gt 0) { [int]$GDrawioFirewallMaxZones } else { 14 }

    # The NAT and Interfaces page is a Layer 3 page, so only zones carrying an address belong on it.
    $addressedZoneGroups = @($zoneGroups | Where-Object { @($_.Group | Where-Object { $_.IPAddress -or $_.Cidr }).Count -gt 0 })
    # Addressed interfaces with no zone still belong there - on a device with no zone concept at all
    # (FortiGate in these captures) they are the entire layer 3 story, and dropping them would leave
    # the page claiming to show interfaces while showing none. Grouped under an explicit heading so
    # it reads as unzoned rather than mis-parsed.
    if ($zonelessWithIp.Count -gt 0) {
        $addressedZoneGroups = @($addressedZoneGroups) + @([pscustomobject]@{
            Name  = '(no zone assigned)'
            Count = $zonelessWithIp.Count
            Group = $zonelessWithIp
        })
    }

    # The Overview page draws every zone, addressed or not, and orders untrusted-looking ones first
    # so the top of its circle - 12 o'clock, going clockwise - reads as the edge of the network.
    $allZonesShown = @($zoneGroups | Select-Object -First $zoneCap)

    # NAT participants are an explicit graph, not a second copy of every addressed interface. A
    # missing zone/translation is represented by a connected placeholder so the incomplete rule is
    # visible without leaving unrelated icons floating on the page.
    $natRules = @($Device.NatPolicy | Where-Object { $_ })
    $natSourcesByName = @{}
    foreach ($rule in $natRules) {
        $fromZones = @($rule.FromZones | Where-Object { $_ } | Select-Object -Unique)
        if ($fromZones.Count -eq 0) { $fromZones = @('(unresolved source zone)') }
        foreach ($zoneName in $fromZones) {
            $key = [string]$zoneName
            if (-not $natSourcesByName.ContainsKey($key)) {
                $match = @($zoneGroups | Where-Object { [string]$_.Name -ieq $key } | Select-Object -First 1)
                $matchedInterfaces = if ($match.Count -gt 0) { @($match[0].Group | Where-Object { $_.IPAddress -or $_.Cidr } | Sort-Object Interface) } else { @() }
                $natSourcesByName[$key] = [pscustomobject]@{
                    Name = $key; Interfaces = $matchedInterfaces; RuleCount = 0
                    IsUnresolved = ($match.Count -eq 0); RuleNames = [System.Collections.Generic.List[string]]::new()
                }
            }
            $natSourcesByName[$key].RuleCount++
            if ($rule.Name) { $natSourcesByName[$key].RuleNames.Add([string]$rule.Name) }
        }
    }

    $natTranslations = foreach ($group in @($natRules | Group-Object {
        $interface = if ($_.TranslatedInterface) { [string]$_.TranslatedInterface } else { '(unresolved interface)' }
        $address = if ($_.TranslatedAddress) { [string]$_.TranslatedAddress } else { '(unresolved translation)' }
        $mode = if ($_.TranslationMode) { [string]$_.TranslationMode } else { '(mode not parsed)' }
        "$interface|$address|$mode"
    })) {
        $first = $group.Group[0]
        [pscustomobject]@{
            Key = [string]$group.Name
            Interface = if ($first.TranslatedInterface) { [string]$first.TranslatedInterface } else { '(unresolved interface)' }
            Address = if ($first.TranslatedAddress) { [string]$first.TranslatedAddress } else { '(unresolved translation)' }
            Mode = if ($first.TranslationMode) { [string]$first.TranslationMode } else { '(mode not parsed)' }
            RuleCount = $group.Count
            SourceZones = @($group.Group | ForEach-Object {
                $zones = @($_.FromZones | Where-Object { $_ })
                if ($zones.Count -gt 0) { $zones } else { '(unresolved source zone)' }
            } | Select-Object -Unique | Sort-Object)
            IsUnresolved = (-not $first.TranslatedAddress -and -not $first.TranslatedInterface)
        }
    }

    return [pscustomobject]@{
        Device           = $Device
        ZoneGroups       = $zoneGroups
        IpInterfaces     = $ipInterfaces
        ZonelessWithIp   = $zonelessWithIp
        AddressedZonesShown    = @($addressedZoneGroups | Select-Object -First $zoneCap)
        AddressedZonesOverflow = @($addressedZoneGroups | Select-Object -Skip $zoneCap)
        AllZonesShown    = $allZonesShown
        AllZonesOverflow = @($zoneGroups | Select-Object -Skip $zoneCap)
        AllZonesOrdered  = @($allZonesShown | Sort-Object @{ Expression = { if (Test-MTAutoDrawUntrustedZoneName -ZoneName $_.Name) { 0 } else { 1 } } }, @{ Expression = { -1 * $_.Count } }, Name)
        NatSources       = @($natSourcesByName.Values | Sort-Object @{Expression={-1*$_.RuleCount}}, Name)
        NatTranslations  = @($natTranslations | Sort-Object @{Expression={-1*$_.RuleCount}}, Address, Interface)
        HasNat            = ($natRules.Count -gt 0)
        Stats            = [pscustomobject]@{
            ZoneCount        = $zoneGroups.Count
            IpInterfaceCount = $ipInterfaces.Count
            RuleCount        = @($Device.SecurityPolicy).Count
            NatCount         = @($Device.NatPolicy).Count
            TunnelCount      = @($interfaces | Where-Object { $_.Interface -match '(?i)tunnel|vpn|ipsec' }).Count
        }
    }
}

# Orders the devices the Layer 3 All page draws: most addressed interfaces first, hostname as the
# tiebreak.
#
# Busiest-first is what keeps the page readable. The networks are drawn in a column down the left and
# every device connects back to them, so putting the device with the most connections nearest the
# column shortens the most edges. Hostname second keeps the order deterministic between runs, which
# matters because the draw pass assigns shape ids in iteration order.
#
# Pure: reads the device array and nothing else.
function Get-MTAutoDrawL3AllModel {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()]$Devices)

    return [pscustomobject]@{
        Hosts = @($Devices | Sort-Object `
            @{ Expression = { 0 - @($_.interfaces | Where-Object { -not $_.shutdown -and @(Get-MTAutoDrawInterfaceIPv4Address -Interface $_).Count -gt 0 }).Count } }, `
            @{ Expression = { $_.HostName } })
    }
}
