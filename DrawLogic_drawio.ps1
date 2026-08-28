
#-----------------------------------------------------------------------------------------
# Main Function: Draw-AllNeighborsDrawio
#-----------------------------------------------------------------------------------------
# "CDP-LLDP All" / "CDP-LLDP brief". Every device is a small label box with its interfaces attached
# as ports directly on its border, on whichever side faces that interface's peer, so the connecting
# line comes out straight. Getting there is a two-round process, because a device's footprint (how
# far its ports stick out on each side) and its placement are circular - you cannot pick a port's
# side without knowing where its peer ended up, and you cannot place a device without knowing its
# footprint:
#
#   Round 1 - every node gets an ESTIMATED footprint (ports split evenly N/S, ignoring peers) and is
#             placed by Get-DrawioTierPlacement. This gives every node an approximate center.
#   Round 2 - each port is assigned the SIDE that faces its peer's round-1 center
#             (Get-DrawioBearingSide), each node's REAL footprint is measured for that assignment,
#             and the page is placed again using the real sizes. This gives every node a final
#             center.
#   Slot pass - each port's DESIRED position along its side becomes its peer's FINAL center,
#             converted into this node's own box-relative coordinates - this is what pulls two
#             connected ports into matching coordinates so the line between them is straight, not
#             merely on the correct side.
#
# Placement is tiered (Get-DrawioTierAssignment): nodes are grouped by BFS distance from the
# best-connected device in their component so linked devices usually occupy adjacent rows.
function Draw-AllNeighborsDrawio {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)] $ArrayOfObjects,
        [parameter(Mandatory = $true)] $ArrayOfCDPDeviceIDs,
        [parameter(Mandatory = $true)] $ArrayOfLLDPDeviceIDs,
        [parameter(Mandatory = $true)] $DrawAllNeighbors,
        [AllowNull()] $TopologyEvidenceModel = $null
    )

    if ($DrawAllNeighbors) { Start-DrawioDiagram -Name "CDP-LLDP All" } else { Start-DrawioDiagram -Name "CDP-LLDP brief" }

    $pageModel = Get-MTAutoDrawNeighborPageModel -ArrayOfObjects $ArrayOfObjects `
        -ArrayOfCDPDeviceIDs $ArrayOfCDPDeviceIDs -ArrayOfLLDPDeviceIDs $ArrayOfLLDPDeviceIDs `
        -DrawAllNeighbors $DrawAllNeighbors -TopologyEvidenceModel $TopologyEvidenceModel
    $nodeInfo = $pageModel.NodeInfo
    $nodesByInterface = $pageModel.NodesByInterface
    $wires = $pageModel.Wires

    if ($nodeInfo.Count -eq 0) {
        $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = 100; Y = 100}) `
            -Message "No CDP or LLDP neighbour could be resolved to a device on this page. Either no device reported a neighbour, or every reported neighbour was suppressed as a flooded segment. Raw sightings are in CDPNeighbors.csv and LLDPNeighbors.csv."
        End-DrawioDiagram
        Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Neighbour page has been created (empty)."
        return
    }

    # --- Node-level adjacency (for tiering) and interface -> peer-node lookup (for bearing), both
    # built from the same wire list so they can never disagree about what is connected to what. ---
    $adjacency = @{}
    foreach ($key in $nodeInfo.Keys) { $adjacency[$key] = [System.Collections.Generic.List[string]]::new() }
    $peerNodeOfPort = @{}
    foreach ($wire in $wires) {
        $fromKey = $nodesByInterface[$wire.FromInterface]
        $toKey = $nodesByInterface[$wire.ToInterface]
        if ($fromKey -ne $toKey) {
            $adjacency[$fromKey].Add($toKey)
            $adjacency[$toKey].Add($fromKey)
        }
        $peerNodeOfPort["$fromKey|$($wire.FromInterface.Interface)"] = $toKey
        $peerNodeOfPort["$toKey|$($wire.ToInterface.Interface)"] = $fromKey
    }

    $blocks = Get-DrawioTierAssignment -Adjacency $adjacency -Keys @($nodeInfo.Keys) -BarycenterSweeps $GDrawioTierBarycenterSweeps

    # --- Round 1: estimate, place, get approximate centers. ---
    $estimateFootprintOf = @{}
    foreach ($node in @($nodeInfo.Values | Sort-Object Key)) { $estimateFootprintOf[$node.Key] = Get-DrawioNeighborNodeFootprint -Node $node -SideOf $null }
    $round1Positions = Get-DrawioTierPlacement -Blocks $blocks -FootprintOf $estimateFootprintOf -StartX 100 -StartY 100 -ColumnGap $GDrawioTierColumnGap -RowGap $GDrawioTierRowGap -MaxRowWidth $GDrawioTierMaxRowWidth
    $round1CenterOf = @{}
    foreach ($node in @($nodeInfo.Values | Sort-Object Key)) {
        $pos = $round1Positions[$node.Key]; $fp = $estimateFootprintOf[$node.Key]
        $round1CenterOf[$node.Key] = [PSCustomObject]@{ X = $pos.X + ($fp.Width / 2); Y = $pos.Y + ($fp.Height / 2) }
    }

    # --- Side assignment: which border each port faces, from round-1 centers. Wired ports (real
    # CDP/LLDP links) are assigned FIRST, purely from bearing - these are the ones alignment cares
    # about. A selected-but-unwired port (an STP Root/ALT port with no matched neighbour, for
    # instance, or an "All"-mode port whose neighbour never resolved) has no bearing to go on and is
    # assigned SECOND, to whichever side currently carries the FEWEST wired ports. Doing it in that
    # order - rather than a flat round-robin over every port regardless of kind - keeps filler ports
    # from crowding onto a side a wired port needs, which is what was pulling wired ports away from
    # their peer-aligned position on any device with more selected interfaces than actual links. ---
    $sideOfNode = @{}
    foreach ($node in @($nodeInfo.Values | Sort-Object Key)) {
        $sideOf = @{}
        $wiredSideCounts = @{ 'S' = 0; 'N' = 0; 'E' = 0; 'W' = 0 }
        $unwiredInterfaces = [System.Collections.Generic.List[object]]::new()
        $ownFootprint = $estimateFootprintOf[$node.Key]
        $aspect = if ($ownFootprint.Height -gt 0) { $ownFootprint.Width / $ownFootprint.Height } else { 1.0 }

        foreach ($iface in $node.Interfaces) {
            $portKey = "$($node.Key)|$($iface.Interface)"
            if ($peerNodeOfPort.ContainsKey($portKey)) {
                $peerKey = $peerNodeOfPort[$portKey]
                $dx = $round1CenterOf[$peerKey].X - $round1CenterOf[$node.Key].X
                $dy = $round1CenterOf[$peerKey].Y - $round1CenterOf[$node.Key].Y
                $side = Get-DrawioBearingSide -DeltaX $dx -DeltaY $dy -AspectRatio $aspect
                $sideOf[[string]$iface.Interface] = $side
                $wiredSideCounts[$side]++
            }
            else {
                $unwiredInterfaces.Add($iface)
            }
        }

        foreach ($iface in $unwiredInterfaces) {
            $leastCrowded = ($wiredSideCounts.GetEnumerator() | Sort-Object -Property @{Expression = 'Value'}, @{Expression = 'Key'} | Select-Object -First 1).Key
            $sideOf[[string]$iface.Interface] = $leastCrowded
            $wiredSideCounts[$leastCrowded]++
        }

        $sideOfNode[$node.Key] = $sideOf
    }

    # --- Round 2: real footprints for that side assignment, re-place, get final centers. ---
    $realFootprintOf = @{}
    foreach ($node in @($nodeInfo.Values | Sort-Object Key)) { $realFootprintOf[$node.Key] = Get-DrawioNeighborNodeFootprint -Node $node -SideOf $sideOfNode[$node.Key] }
    $finalPositions = Get-DrawioTierPlacement -Blocks $blocks -FootprintOf $realFootprintOf -StartX 100 -StartY 100 -ColumnGap $GDrawioTierColumnGap -RowGap $GDrawioTierRowGap -MaxRowWidth $GDrawioTierMaxRowWidth
    $finalCenterOf = @{}
    foreach ($node in @($nodeInfo.Values | Sort-Object Key)) {
        $pos = $finalPositions[$node.Key]; $fp = $realFootprintOf[$node.Key]
        $finalCenterOf[$node.Key] = [PSCustomObject]@{ X = $pos.X + ($fp.Width / 2); Y = $pos.Y + ($fp.Height / 2) }
    }

    # --- Slot pass: each port's desired box-relative position is its peer's final center, converted
    # through this node's own final absolute box origin. ---
    $desiredOfNode = @{}
    foreach ($node in @($nodeInfo.Values | Sort-Object Key)) {
        $desired = @{}
        $origin = $finalPositions[$node.Key]
        $fp = $realFootprintOf[$node.Key]
        $boxLeft = $origin.X + $fp.BoxOrigin.X
        $boxTop = $origin.Y + $fp.BoxOrigin.Y
        foreach ($iface in $node.Interfaces) {
            $portKey = "$($node.Key)|$($iface.Interface)"
            if (-not $peerNodeOfPort.ContainsKey($portKey)) { continue }
            $peerKey = $peerNodeOfPort[$portKey]
            $side = $sideOfNode[$node.Key][[string]$iface.Interface]
            $desired[[string]$iface.Interface] = if ($side -eq 'N' -or $side -eq 'S') {
                $finalCenterOf[$peerKey].X - $boxLeft
            }
            else {
                $finalCenterOf[$peerKey].Y - $boxTop
            }
        }
        $desiredOfNode[$node.Key] = $desired
    }

    # --- Draw every node at its final position. ---
    foreach ($node in @($nodeInfo.Values | Sort-Object Key)) {
        $location = $finalPositions[$node.Key]
        $variant = if ($node.Kind -eq 'Configured') { 'Configured' } else { [string]$node.DrawType }
        $null = Add-DrawioPhysicalHost -Device $node.Device -Location $location -Interfaces $node.Interfaces `
            -SideOf $sideOfNode[$node.Key] -DesiredOf $desiredOfNode[$node.Key] -Variant $variant `
            -MacBubbleInterfaceNames $node.MacBubbleNames
        if ($node.Kind -eq 'Configured') {
            $node.Device.CPDHostLocation = $location
        }
    }

    # --- Draw every wire now that both endpoints have real shape ids. ---
    foreach ($wire in $wires) {
        if ($wire.FromInterface.PhysicalDrawioId -and $wire.ToInterface.PhysicalDrawioId) {
            $null = Add-DrawioConnector -SourceId $wire.FromInterface.PhysicalDrawioId -TargetId $wire.ToInterface.PhysicalDrawioId -Style $wire.Style
        }
    }

    # --- Content bounds, for the evidence band and legend below. ---
    $contentRight = 0.0
    $contentBottom = 0.0
    foreach ($node in @($nodeInfo.Values | Sort-Object Key)) {
        $pos = $finalPositions[$node.Key]; $fp = $realFootprintOf[$node.Key]
        if (($pos.X + $fp.Width) -gt $contentRight) { $contentRight = $pos.X + $fp.Width }
        if (($pos.Y + $fp.Height) -gt $contentBottom) { $contentBottom = $pos.Y + $fp.Height }
    }
    $contentLeft = 100

    # Draw inferred evidence after authoritative CDP/LLDP links. Unknown nodes live in a separate
    # band below the tiered content; exact configured-device matches reuse that device's host box.
    # Every inferred connector is visibly dashed.
    if ($TopologyEvidenceModel -and $GIncludeInferredTopologyEvidence) {
        $drawnEvidenceEdges = @($TopologyEvidenceModel.Edges | Where-Object { $_.Drawn })
        $referencedNodeIds = @($drawnEvidenceEdges | Where-Object NodeId | Select-Object -ExpandProperty NodeId -Unique)
        $evidenceNodeShapeIds = @{}
        $evidenceCursor = New-DrawioGridCursor -StartX $contentLeft -StartY ($contentBottom + 60) -ItemsPerRow 8 -HorizontalPadding 45 -VerticalPadding 45
        $evidenceBottom = $contentBottom
        foreach ($node in @($TopologyEvidenceModel.Nodes | Where-Object { $_.NodeId -in $referencedNodeIds } | Sort-Object NodeId)) {
            $shape = Add-DrawioTopologyEvidenceNode -Node $node -Location ([pscustomobject]@{ X = $evidenceCursor.X; Y = $evidenceCursor.Y })
            $evidenceNodeShapeIds[$node.NodeId] = $shape.Id
            $evidenceCursor = Get-DrawioWrappedGridPosition -Cursor $evidenceCursor -DrawnWidth $shape.Width -DrawnHeight $shape.Height
            $evidenceBottom = $evidenceCursor.Y + $evidenceCursor.RowHeight
        }
        if ($evidenceBottom -gt $contentBottom) { $contentBottom = $evidenceBottom }

        foreach ($edge in $drawnEvidenceEdges) {
            $sourceDevice = $ArrayOfObjects | Where-Object { $_.hostname -ieq $edge.SourceHostname } | Select-Object -First 1
            if (-not $sourceDevice) { continue }
            $sourceInterfaceKey = ConvertTo-NormalizedInterfaceIdentity $edge.SourceInterface
            $sourceInterface = $sourceDevice.interfaces | Where-Object {
                (ConvertTo-NormalizedInterfaceIdentity $_.Interface) -eq $sourceInterfaceKey
            } | Select-Object -First 1
            if (-not $sourceInterface -or -not $sourceInterface.PhysicalDrawioId) { continue }

            if ($edge.NodeKind -eq 'ExistingDevice') {
                $targetDevice = $ArrayOfObjects | Where-Object { $_.hostname -ieq $edge.TargetHostname } | Select-Object -First 1
                $targetId = if ($targetDevice) { $targetDevice.PhysicalHostDrawioId } else { $null }
            }
            else {
                $targetId = $evidenceNodeShapeIds[[string]$edge.NodeId]
            }
            if (-not $targetId) { continue }

            $presentation = Get-MTAutoDrawEvidenceConnectorPresentation -Edge $edge
            $label = '{0}: {1}' -f $presentation.Label, $edge.SourceInterface
            $null = Add-DrawioConnector -SourceId $sourceInterface.PhysicalDrawioId -TargetId $targetId -Style $presentation.Style -Text $label
        }
    }

    # Place the interface legend below the measured content it explains.
    $legend = Add-DrawioInterfaceLegend -Location ([PSCustomObject]@{X = $contentLeft; Y = ($contentBottom + 60)})

    $scope = if ($DrawAllNeighbors) {
        "Every interface of every device that reported a CDP or LLDP neighbour. Neighbours suppressed as flooded segments are not drawn; raw sightings are in CDPNeighbors.csv and LLDPNeighbors.csv."
    } else {
        "Only the interfaces carrying a resolved CDP or LLDP link. The CDP-LLDP All page draws every interface of the same devices; raw sightings are in CDPNeighbors.csv and LLDPNeighbors.csv."
    }
    $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = $contentLeft; Y = ($contentBottom + 60 + $legend.Height + 40)}) -Message $scope

    End-DrawioDiagram
}


#-----------------------------------------------------------------------------------------
# Main Function: Draw-SiteTopologyOverviewDiagram
#-----------------------------------------------------------------------------------------
# One-screen physical topology map: one compact icon per device, tiered into Core / Distribution /
# Access purely by resolved CDP/LLDP degree (a display heuristic - no vendor config exposes a real
# role field), plus a distinct look for security devices and spanning-tree root bridges. Per-interface
# detail stays on the CDP-LLDP All / brief pages; this page is the compact entry map.
function Draw-SiteTopologyOverviewDiagram {
    [CmdletBinding()]
    param (
        # An array of all configured device objects processed from the config files.
        [parameter(Mandatory = $true)]
        $ArrayOfObjects,
        [AllowNull()]
        $TopologyEvidenceModel = $null
    )

    Write-MTAutoDrawPhase -Phase Draw -Message "Starting Draw-SiteTopologyOverviewDiagram..."
    Start-DrawioDiagram -Name "Topology Overview"

    $model = Get-MTAutoDrawSiteTopologyModel -Devices $ArrayOfObjects -TopologyEvidenceModel $TopologyEvidenceModel

    $classified            = $model.Classified
    $deviceKeys            = $model.DeviceKeys
    $entryByHostname       = $model.EntryByHostname
    $observedPeerGroups    = $model.ObservedPeerGroups
    $allObservedPeerRecords = $model.AllObservedPeerRecords
    $observedPeerRadialKey = $model.ObservedPeerRadialKey
    $evidenceNodesToDraw   = $model.EvidenceNodesToDraw
    $drawnEvidenceEdges    = $model.DrawnEvidenceEdges
    $evidenceRadialKey     = $model.EvidenceRadialKey
    $endUnitBlocks         = $model.EndUnitBlocks
    $radialAdjacency       = $model.Adjacency
    $radialFootprints      = $model.Footprints

    $radialKeys = @($radialAdjacency.Keys | ForEach-Object { [string]$_ })
    $radialLayout = Get-DrawioTopologyPlacement -Strategy $GDrawioTopologyPlacementStrategy `
        -Adjacency $radialAdjacency -Keys $radialKeys -FootprintOf $radialFootprints -Options @{
            StartX = 100.0; StartY = 100.0
            NodeGap = [double]$GDrawioTopologyRadialNodeGap; RingGap = [double]$GDrawioTopologyRadialRingGap
            AspectRatio = [double]$GDrawioTopologyRadialAspect; Sweeps = [int]$GDrawioTopologyRadialSweeps
            MaxStagger = [int]$GDrawioTopologyRadialMaxStagger
            RingSpacing = [string]$GDrawioTopologyRadialRingSpacing
            Packing = [string]$GDrawioTopologyRadialClusterPacking
            PostPass = [string]$GDrawioTopologyPlacementPostPass
            MaxRowWidth = [double]($GDrawioTopologyOverviewHardMaxWidth - 100)
        }
    $radialPositions = $radialLayout.Positions

    $contentBottom = 100
    foreach ($key in $deviceKeys) {
        $entry = $entryByHostname[$key]
        $position = $radialPositions[$key]
        if (-not $position) { continue }
        $dimensions = Add-DrawioTopologyNode -Device $entry.Device -Location ([PSCustomObject]@{X = $position.X; Y = $position.Y}) `
            -Tier $entry.Tier -IsSecurity $entry.IsSecurity -IsRootBridge $entry.IsRootBridge -Degree $entry.Degree
        if (($position.Y + $dimensions.Height) -gt $contentBottom) { $contentBottom = $position.Y + $dimensions.Height }
    }

    $observedPeerNodeIds = @{}
    foreach ($peerGroup in $observedPeerGroups) {
        $radialKey = $observedPeerRadialKey[[string]$peerGroup.Name]
        if (-not $radialKey) { continue }
        $position = $radialPositions[$radialKey]
        if (-not $position) { continue }
        $peer = @($peerGroup.Group | Sort-Object SourceHostname, SourceInterface)[0]
        $shape = Add-DrawioObservedPeerNode -Peer $peer -Location ([pscustomobject]@{ X = $position.X; Y = $position.Y })
        $observedPeerNodeIds[[string]$peer.PeerKey] = $shape.Id
        if (($position.Y + $shape.Height) -gt $contentBottom) { $contentBottom = $position.Y + $shape.Height }
    }

    $evidenceNodeShapeIds = @{}
    foreach ($node in $evidenceNodesToDraw) {
        $radialKey = $evidenceRadialKey[[string]$node.NodeId]
        if (-not $radialKey) { continue }
        $position = $radialPositions[$radialKey]
        if (-not $position) { continue }
        $shape = Add-DrawioTopologyEvidenceNode -Node $node -Location ([pscustomobject]@{ X = $position.X; Y = $position.Y })
        $evidenceNodeShapeIds[[string]$node.NodeId] = $shape.Id
        if (($position.Y + $shape.Height) -gt $contentBottom) { $contentBottom = $position.Y + $shape.Height }
    }

    # Draw each end-unit block, then point every member it swallowed at the block's shape id. The
    # connector phase below looks those ids up without knowing anything about collapsing, and
    # Add-DrawioConnector already treats repeated endpoint pairs as one edge - so several members
    # sharing a parent produce exactly one link, with no special-casing anywhere downstream.
    #
    # Members are only ever observed peers or evidence nodes; a configured device is never collapsed,
    # so nothing here can overwrite the TopologyOverviewDrawioId its own card was just given above.
    foreach ($block in $endUnitBlocks) {
        $position = $radialPositions[$block.Key]
        if (-not $position) { continue }
        $shape = Add-DrawioEndUnitBlock -Layout $block.Layout -Count $block.Count `
            -Location ([pscustomobject]@{ X = $position.X; Y = $position.Y })
        if (($position.Y + $shape.Height) -gt $contentBottom) { $contentBottom = $position.Y + $shape.Height }

        foreach ($member in @($block.Members)) {
            if ($member -like 'peer:*') {
                $observedPeerNodeIds[$member.Substring(5)] = $shape.Id
            }
            elseif ($member -like 'evidence:*') {
                $evidenceNodeShapeIds[$member.Substring(9)] = $shape.Id
            }
        }
    }

    # --- Phase 4: configured-device connectors. Collect both directions and both protocols before
    # drawing so one link can truthfully show CDP, LLDP, or dual-protocol evidence. ---
    $overviewLinkMap = @{}
    foreach ($device in $ArrayOfObjects) {
        if (-not $device.TopologyOverviewDrawioId) { continue }
        $protocolNeighbors = @(
            foreach ($neighbor in @($device.CDPNeighbors)) { [pscustomobject]@{ Protocol='CDP'; Neighbor=$neighbor } }
            foreach ($neighbor in @($device.LLDPNeighbors)) { [pscustomobject]@{ Protocol='LLDP'; Neighbor=$neighbor } }
        )
        foreach ($protocolNeighbor in $protocolNeighbors) {
            $neighbor = $protocolNeighbor.Neighbor
            if (-not $neighbor.TargetHostname -or $neighbor.Ignored -or $neighbor.TargetHostname -ieq $device.hostname) { continue }
            $targetDevice = $ArrayOfObjects | Where-Object { $_.hostname -ieq $neighbor.TargetHostname } | Select-Object -First 1
            if (-not $targetDevice -or -not $targetDevice.TopologyOverviewDrawioId) { continue }
            $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $neighbor.InterfaceLocalDevice } | Select-Object -First 1
            $endpoints = @([string]$device.TopologyOverviewDrawioId,[string]$targetDevice.TopologyOverviewDrawioId) | Sort-Object
            $linkKey = "$($endpoints[0])|$($endpoints[1])"
            if (-not $overviewLinkMap.ContainsKey($linkKey)) {
                $overviewLinkMap[$linkKey] = [pscustomobject]@{
                    SourceId = $endpoints[0]
                    TargetId = $endpoints[1]
                    Protocols = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    Candidates = [System.Collections.Generic.List[object]]::new()
                }
            }
            [void]$overviewLinkMap[$linkKey].Protocols.Add([string]$protocolNeighbor.Protocol)
            $overviewLinkMap[$linkKey].Candidates.Add([pscustomobject]@{
                MatchConfidence=[string]$neighbor.MatchConfidence
                SourceHostname=[string]$device.hostname
                SourceInterface=[string]$neighbor.InterfaceLocalDevice
            })
        }
    }
    $confidenceRank = @{ High=3; Medium=2; Low=1; None=0; ''=3 }
    foreach ($linkKey in @($overviewLinkMap.Keys | Sort-Object)) {
        $link = $overviewLinkMap[$linkKey]
        $bestCandidate = $link.Candidates | Sort-Object @{ Expression={
            $confidence = [string]$_.MatchConfidence
            if ($confidenceRank.ContainsKey($confidence)) { $confidenceRank[$confidence] } else { 0 }
        }; Descending=$true } | Select-Object -First 1
        $presentation = Get-MTAutoDrawTopologyOverviewConnectorPresentation -Protocols @($link.Protocols) -MatchConfidence $bestCandidate.MatchConfidence
        $null = Add-DrawioConnector -SourceId $link.SourceId -TargetId $link.TargetId -Style $presentation.Style
    }

    # Unresolved, network-facing LLDP peers are authoritative observations, drawn with the same teal
    # LLDP link as the configured-device links above. Their nodes were placed with everything else
    # in Phase 3, so each link here is the short hop from a device to the peer sitting beside it.
    foreach ($peer in $allObservedPeerRecords) {
        $sourceDevice = $peer.SourceDevice
        $targetId = $observedPeerNodeIds[[string]$peer.PeerKey]
        if (-not $sourceDevice.TopologyOverviewDrawioId -or -not $targetId) { continue }
        $presentation = Get-MTAutoDrawTopologyOverviewConnectorPresentation -Protocols @('LLDP') -MatchConfidence 'High'
        $null = Add-DrawioConnector -SourceId $sourceDevice.TopologyOverviewDrawioId -TargetId $targetId `
            -Style $presentation.Style -Text ([string]$peer.SourceInterface)
    }

    foreach ($edge in $drawnEvidenceEdges) {
        $sourceDevice = $ArrayOfObjects | Where-Object { $_.hostname -ieq $edge.SourceHostname } | Select-Object -First 1
        if (-not $sourceDevice -or -not $sourceDevice.TopologyOverviewDrawioId) { continue }
        if ($edge.NodeKind -eq 'ExistingDevice') {
            $targetDevice = $ArrayOfObjects | Where-Object { $_.hostname -ieq $edge.TargetHostname } | Select-Object -First 1
            $targetId = if ($targetDevice) { $targetDevice.TopologyOverviewDrawioId } else { $null }
        }
        else {
            $targetId = $evidenceNodeShapeIds[[string]$edge.NodeId]
        }
        if (-not $targetId) { continue }

        $presentation = Get-MTAutoDrawEvidenceConnectorPresentation -Edge $edge
        $label = '{0}: {1} ({2})' -f $presentation.Label,$edge.SourceInterface,$edge.Directness
        $null = Add-DrawioConnector -SourceId $sourceDevice.TopologyOverviewDrawioId -TargetId $targetId -Style $presentation.Style -Text $label
    }

    $footerY = $contentBottom + 60
    $legend = Add-DrawioTopologyOverviewLegend -Location ([PSCustomObject]@{X=100; Y=$footerY})
    $footerY += $legend.Height + 25

    $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = 100; Y = $footerY}) `
        -Message "Simplified topology overview - the most central device is drawn in the middle and everything else fans out around it by hop distance, so a device's ring is how far it sits from the middle of the site and its direction is which branch it is on. Tiers (colour) are derived from link count, not vendor config. Link colors identify CDP, LLDP, dual-protocol, and inferred evidence as shown in the legend; inferred paths are dashed and state their endpoint directness. Full interface, VLAN and neighbour detail: the CDP-LLDP All / CDP-LLDP brief pages, CDPNeighbors.csv / LLDPNeighbors.csv, or Objects.json."

    End-DrawioDiagram
    Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Site Topology Overview diagram page has been created."
}



function Draw-SingleHostPhysicalDrawio {
    [CmdletBinding()]
    param (
        # The primary device object to be the center of the diagram.
        [parameter(Mandatory = $true)]
        $Device,
        # The full array of all configured device objects.
        [parameter(Mandatory = $true)]
        $ArrayOfObjects,
        # An array of PSObjects for devices discovered only via CDP.
        [parameter(Mandatory = $true)]
        $ArrayOfCDPDeviceIDs,
        # An array of PSObjects for devices discovered only via LLDP.
        [parameter(Mandatory = $true)]
        $ArrayOfLLDPDeviceIDs
    )
    # 1. Initialize the diagram page and layout variables.
    Start-DrawioDiagram -Name "$($Device.hostname) Physical"
    $null = Add-DrawioInterfaceLegend -Location ([PSCustomObject]@{X = 100; Y = 1300})

    # 2. Draw the primary host in a central location. This page keeps its original grid layout
    # (single host, neighbours arranged around it by hand below) rather than the tiered
    # bearing-based placement the CDP-LLDP pages use, so every port simply goes on the south side -
    # a reasonable default for a page whose neighbours are already laid out in one direction.
    $pageModel = Get-MTAutoDrawHostPhysicalModel -Device $Device -Devices $ArrayOfObjects `
        -CdpHosts $ArrayOfCDPDeviceIDs -LldpHosts $ArrayOfLLDPDeviceIDs

    # 2. Draw the primary host in a central location. This page keeps its original grid layout
    # (single host, neighbours arranged around it by hand below) rather than the tiered
    # bearing-based placement the CDP-LLDP pages use, so every port simply goes on the south side -
    # a reasonable default for a page whose neighbours are already laid out in one direction.
    $null = Add-DrawioPhysicalHost -Device $Device -Location ([PSCustomObject]@{X = 800; Y = 100}) `
        -Interfaces $pageModel.Primary.Interfaces -SideOf $pageModel.Primary.SideOf `
        -Variant Configured -MacBubbleInterfaceNames $pageModel.Primary.MacBubbleInterfaceNames

    # 3. Lay the neighbour panels out left to right, in the order the model resolved them - CDP
    # first, then LLDP, which is the order they were discovered in.
    $currentX = 100
    $currentY = 700
    $horizontalPadding = 200 # The fixed space between neighbor shapes.

    foreach ($panel in $pageModel.Panels) {
        $variant = if ($panel.IsConfigured) { 'Configured' } else { [string]$panel.DrawType }
        $panelShape = Add-DrawioPhysicalHost -Device $panel.Device -Location ([PSCustomObject]@{X = $currentX; Y = $currentY}) `
            -Interfaces $panel.Interfaces -SideOf $panel.SideOf -Variant $variant `
            -MacBubbleInterfaceNames $panel.MacBubbleInterfaceNames
        $currentX += $(if ($panel.IsConfigured) { $panelShape.Width } else { 800 }) + $horizontalPadding
    }

    $devicesToConnect = $pageModel.DevicesToConnect
    # 5. Draw connectors ONLY for devices present in the diagram
    # =================================================================
    # Loop through each of the devices we just drew.
    foreach ($device in $devicesToConnect) {
        # --- CDP Connections ---
        if ($device.CDPNeighbors) {
            # Handles connections to fully configured partners
            foreach ($cdpNeighbor in ($device.CDPNeighbors | Where-Object { $_.PartnerEthernetInterface -and $_.PartnerEthernetInterface.Value })) {
                $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $cdpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
                $toInterface = $cdpNeighbor.PartnerEthernetInterface.Value
                # ADDED: Find the partner host to verify it's on the diagram
                $toHost = $ArrayOfObjects | Where-Object { $_.interfaces -contains $toInterface } | Select-Object -First 1
                # ADDED: Skip if the target device was not drawn in Step 4
                if (-not $devicesToConnect.Contains($toHost)) { continue }

                if ($fromInterface.PhysicalDrawioId -and $toInterface.PhysicalDrawioId) {
                    $style = Get-ConnectorStyle -fromInterface $fromInterface -MatchConfidence $cdpNeighbor.MatchConfidence
                    $null = Add-DrawioConnector -SourceId $fromInterface.PhysicalDrawioId -TargetId $toInterface.PhysicalDrawioId -Style $style
                }
            }
            # Handles connections to discovered-only partners
            foreach ($cdpNeighbor in ($device.CDPNeighbors | Where-Object { -not $_.PartnerEthernetInterface })) {
                $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $cdpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
                $cleanedNeighborID = ($cdpNeighbor.DeviceID -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim()
                $toDevice = $ArrayOfCDPDeviceIDs | Where-Object { ($_.HostName -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim() -eq $cleanedNeighborID } | Select-Object -First 1
                
                # ADDED: Skip if the target device was not drawn in Step 4
                if (-not $devicesToConnect.Contains($toDevice)) { continue }

                if ($toDevice) {
                    $toInterface = $toDevice.interfaces | Where-Object { $_.Interface -eq $cdpNeighbor.InterfaceRemoteDevice } | Select-Object -First 1
                    if ($fromInterface.PhysicalDrawioId -and $toInterface.PhysicalDrawioId) {
                        $style = Get-ConnectorStyle -fromInterface $fromInterface
                        $null = Add-DrawioConnector -SourceId $fromInterface.PhysicalDrawioId -TargetId $toInterface.PhysicalDrawioId -Style $style
                    }
                }
            }
        }

        # --- LLDP Connections ---
        if ($device.LLDPNeighbors) {
            # Handles connections to fully configured partners
            foreach ($lldpNeighbor in ($device.LLDPNeighbors | Where-Object { $_.PartnerEthernetInterface -and $_.PartnerEthernetInterface.Value })) {
                $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $lldpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
                $toInterface = $lldpNeighbor.PartnerEthernetInterface.Value
                # ADDED: Find the partner host to verify it's on the diagram
                $toHost = $ArrayOfObjects | Where-Object { $_.interfaces -contains $toInterface } | Select-Object -First 1
                # ADDED: Skip if the target device was not drawn in Step 4
                if (-not $devicesToConnect.Contains($toHost)) { continue }

                if ($fromInterface.PhysicalDrawioId -and $toInterface.PhysicalDrawioId) {
                    $style = Get-ConnectorStyle -fromInterface $fromInterface -MatchConfidence $lldpNeighbor.MatchConfidence
                    $null = Add-DrawioConnector -SourceId $fromInterface.PhysicalDrawioId -TargetId $toInterface.PhysicalDrawioId -Style $style
                }
            }
            # Handles connections to discovered-only partners
            foreach ($lldpNeighbor in ($device.LLDPNeighbors | Where-Object { (-not $_.PartnerEthernetInterface) -and (-not $_.HasCDPNeighborEntry) })) {
                $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $lldpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
                $toInterface = $null
                $toDevice = $null
                :outer foreach ($discoveredDevice in $ArrayOfLLDPDeviceIDs) {
                    $cleanedNeighborHostName = if (-not [string]::IsNullOrEmpty($lldpNeighbor.HostName)) { ($lldpNeighbor.HostName -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim() }
                    $cleanedChassisId = if (-not [string]::IsNullOrEmpty($lldpNeighbor.ChassisID)) { ($lldpNeighbor.ChassisID -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim() }
                    $cleanedDiscoveredHostname = ($discoveredDevice.hostname -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim()
                    if (($cleanedDiscoveredHostname -eq $cleanedNeighborHostName) -or ($cleanedDiscoveredHostname -eq $cleanedChassisId)) {
                        $toDevice = $discoveredDevice # Capture the device object
                        foreach ($remoteInterface in $discoveredDevice.interfaces) {
                            if ($remoteInterface.Interface -eq $lldpNeighbor.InterfaceRemoteDevice) {
                                $toInterface = $remoteInterface
                                break outer
                            }
                        }
                    }
                }
                
                # ADDED: Skip if the target device was not drawn in Step 4
                if (-not $devicesToConnect.Contains($toDevice)) { continue }

                if ($fromInterface.PhysicalDrawioId -and $toInterface.PhysicalDrawioId) {
                    $style = Get-ConnectorStyle -fromInterface $fromInterface
                    $null = Add-DrawioConnector -SourceId $fromInterface.PhysicalDrawioId -TargetId $toInterface.PhysicalDrawioId -Style $style
                }
            }
        }
    }
    
    # 6. Finalize the diagram page.
    End-DrawioDiagram
}








#-----------------------------------------------------------------------------------------
# Helper Function: Get-Layer3RouteEdgePresentation
#-----------------------------------------------------------------------------------------
# One route edge's colour, dash pattern, and label. The -Standby switch captures the only presentation
# difference between primary and standby edges; protocol colour comes from the canonical palette.
#
# More than 30 routes collapse to "Route Count:N": the full
# list for a busy default-route gateway can run to hundreds of lines, and that detail already lives
# in routes.csv / Objects.json.
function Get-Layer3RouteEdgePresentation {
    [CmdletBinding()]
    param(
        # One Group-Object-shaped record: .Name (unused here), .Group (route objects), .Count.
        [parameter(Mandatory = $true)] $RouteGroup,
        [parameter(Mandatory = $true)] [string]$GatewayIp,
        [switch]$Standby
    )

    $routeCount = $RouteGroup.Count
    $protocols = ($RouteGroup.Group.RouteProtocol | Sort-Object -Unique) -join ', '

    $primaryProtocol = ($RouteGroup.Group.RouteProtocol | Select-Object -First 1)
    if ($protocols -like "*BGP*") { $primaryProtocol = "BGP" }
    elseif ($protocols -like "*EIGRP*") { $primaryProtocol = "EIGRP" }
    elseif ($protocols -like "*OSPF*") { $primaryProtocol = "OSPF" }
    elseif ($protocols -like "*static*") { $primaryProtocol = "static" }

    $rawColor = Get-MTAutoDrawRouteProtocolColor -Protocol $primaryProtocol
    $color = if ($rawColor -match '^#') { $rawColor } else { Convert-RgbToHex -RgbString $rawColor }

    if (($RouteGroup.Group | Select-Object subnet).Count -gt 30) {
        if ($RouteGroup.Group | Where-Object { $_.subnet -like "*0.0.0.0/0*" }) {
            $text = "$($protocols)<br>$($GatewayIp)<br>Route Count:$routeCount<br>Routes For: 0.0.0.0/0"
        }
        else {
            $text = "$($protocols)<br>$($GatewayIp)<br>Route Count:$routeCount"
        }
    }
    else {
        $text = "$($protocols)<br>$($GatewayIp)<br>"
        $text += ($RouteGroup.Group | Select-Object -ExpandProperty subnet | Sort-Object) -join '<br>'
    }

    $strokeWidth = 3
    if ($Standby) {
        $text = "Standby: " + $text
        $color = (Get-MTAutoDrawPalette -Scope Shared).Link.Unresolved
        $dashed = $true
    }
    else {
        # Solid means the default route leaves this way; everything else is dashed.
        $dashed = ($text -notlike "*0.0.0.0/0*")
    }

    $style = "endArrow=classic;html=1;strokeWidth=$strokeWidth;strokeColor=$color;endSize=8;"
    if ($dashed) { $style += "dashed=1;" }
    # Opaque, bordered, small and left-aligned so a long subnet list reads as a card sitting on the
    # link rather than text smeared across whatever happens to be underneath it.
    $style += "labelBackgroundColor=$((Get-MTAutoDrawPalette -Scope Shared).Text.Inverse);labelBorderColor=$color;fontSize=9;align=left;verticalAlign=middle;spacingLeft=4;spacingRight=4;"

    return [PSCustomObject]@{ Style = $style; Text = $text; Color = $color }
}

function Get-MTAutoDrawL3DetailFootprint {
    [CmdletBinding()]
    param($Info, [hashtable]$SideOf, [hashtable]$InterfacesByBlock)

    switch ($Info.Kind) {
        'Device' {
            if ($Info.Block.IsSummary) { return Get-DrawioL3DetailSummaryFootprint -Block $Info.Block }
            $hostType = if ($Info.Block.IsGatewayHost) { 'GatewayHost' } else { $null }
            return Get-DrawioHostLayer3Footprint -Device $Info.Block.Members[0].Device `
                -Interfaces $InterfacesByBlock[$Info.Block.Key] -HostType $hostType -SideOf $SideOf
        }
        'Network' { return [pscustomobject]@{ Width = $GDrawioVlanWidth; Height = $GDrawioVlanHeight } }
        'Arp' { return [pscustomobject]@{ Width = $GDrawioArpWidth; Height = (Get-DrawioArpBubbleHeight -Network $Info.Network) } }
    }
}

function Get-MTAutoDrawRoutesOnlyNodeFootprint {
    [CmdletBinding()]
    param($Node, [hashtable]$SideOf)

    switch ($Node.Kind) {
        'Single' { return Get-DrawioHostLayer3Footprint -Device $Node.Block.Members[0] -Interfaces $Node.Block.Interfaces -HostType $Node.Block.HostType -SideOf $SideOf }
        'Group' {
            $group = [pscustomobject]@{
                Devices = @($Node.Block.Members.HostName)
                RouteCount = @($Node.Block.Gateways.Values | ForEach-Object { $_ } | Select-Object -Unique).Count
                HasDefaultRoute = $Node.Block.HasDefaultRoute
                Protocols = $Node.Block.Protocols
            }
            return Get-DrawioL3DependantNodeFootprint -Group $group
        }
        'Hub' { return [pscustomobject]@{ Width = 240; Height = 70 } }
        'Target' { return [pscustomobject]@{ Width = 240; Height = 70 } }
    }
}

function Add-DrawioL3TopologyRoleBandNodes {
    [CmdletBinding()]
    param([string]$Role, [scriptblock]$RankBy, $Model, [double]$StartY, [int]$DeviceCap, [double]$MaxWidth)

    $roleNodes = @($Model.Nodes | Where-Object { $_.Role -eq $Role } | Sort-Object $RankBy, HostName)
    if ($roleNodes.Count -eq 0) { return [pscustomobject]@{ Bottom = $StartY; NodeIdByHost = @{} } }
    $shownRoleNodes = @($roleNodes | Select-Object -First $DeviceCap)
    $overflowRoleNodes = @($roleNodes | Select-Object -Skip $DeviceCap)

    $nodeIds = @{}
    $bandCursor = New-DrawioGridCursor -StartX 100 -StartY $StartY `
        -ItemsPerRow ([Math]::Max(1, [Math]::Floor($MaxWidth / (220 + 40)))) `
        -HorizontalPadding 40 -VerticalPadding 40
    foreach ($node in $shownRoleNodes) {
        $dims = Add-DrawioL3TopologyNode -Node $node -Location ([pscustomobject]@{X = $bandCursor.X; Y = $bandCursor.Y})
        if ($node.Device.L3TopologyDrawioId) { $nodeIds[$node.HostName] = $node.Device.L3TopologyDrawioId }
        $bandCursor = Get-DrawioWrappedGridPosition -Cursor $bandCursor -DrawnWidth $dims.Width -DrawnHeight $dims.Height
    }
    if ($overflowRoleNodes.Count -gt 0) {
        $dims = Add-DrawioOverflowSummaryCard -TitleText "+$($overflowRoleNodes.Count) other $($Role.ToLower()) devices" `
            -DetailLine 'busiest-first; full list in Objects.json' `
            -Names (@($overflowRoleNodes | ForEach-Object HostName)) `
            -Location ([pscustomobject]@{X = $bandCursor.X; Y = $bandCursor.Y})
        $bandCursor = Get-DrawioWrappedGridPosition -Cursor $bandCursor -DrawnWidth $dims.Width -DrawnHeight $dims.Height
    }
    return [pscustomobject]@{ Bottom = ($bandCursor.Y + $bandCursor.RowHeight); NodeIdByHost = $nodeIds }
}

# Shared graph renderer for the two subnet-bearing Layer 3 detail pages. Blocks and subnet/ARP
# nodes are placed as one graph; summary blocks replace duplicate host cards only when the pure
# model proved their visible routes and CIDR memberships are identical.
function Add-MTAutoDrawL3DetailGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Devices,
        [Parameter(Mandatory = $true)]$Networks,
        [AllowEmptyCollection()]$GatewayHosts = @(),
        [ValidateSet('All', 'RoutedLinksOnly')][string]$Mode
    )

    $model = Get-MTAutoDrawL3DetailPageModel -Devices $Devices -Networks $Networks -GatewayHosts $GatewayHosts -Mode $Mode
    $nodeInfo = @{}
    $adjacency = @{}
    foreach ($block in $model.Blocks) {
        $nodeInfo[$block.Key] = [pscustomobject]@{ Kind = 'Device'; Block = $block }
        $adjacency[$block.Key] = [System.Collections.Generic.List[string]]::new()
    }
    foreach ($network in $model.Networks) {
        $key = "network:$([string]$network.Cidr)"
        $nodeInfo[$key] = [pscustomobject]@{ Kind = 'Network'; Network = $network }
        $adjacency[$key] = [System.Collections.Generic.List[string]]::new()
        if ($GDrawAprEntries -and @($network.ARPEntries).Count -gt 0) {
            $arpKey = "arp:$([string]$network.Cidr)"
            $nodeInfo[$arpKey] = [pscustomobject]@{ Kind = 'Arp'; Network = $network }
            $adjacency[$arpKey] = [System.Collections.Generic.List[string]]::new()
            $adjacency[$key].Add($arpKey); $adjacency[$arpKey].Add($key)
        }
    }
    foreach ($edge in $model.Edges) {
        if (-not $adjacency.ContainsKey($edge.SourceKey) -or -not $adjacency.ContainsKey($edge.TargetKey)) { continue }
        $adjacency[$edge.SourceKey].Add($edge.TargetKey); $adjacency[$edge.TargetKey].Add($edge.SourceKey)
    }

    if ($nodeInfo.Count -eq 0) {
        return [pscustomobject]@{ Bottom = 100; Model = $model }
    }

    $interfacesByBlock = @{}
    foreach ($block in $model.Blocks) {
        if ($block.IsSummary) { continue }
        $interfacesByBlock[$block.Key] = @($block.Members[0].Rows | Group-Object Interface | ForEach-Object { $_.Group[0].InterfaceObject } | Sort-Object Interface)
    }

    # Leave room for the 100px page origin and long edge labels. Each connected L3 component is a
    # size-aware starburst: central devices/subnets stay together, their subnet/device branches own
    # separate angular wedges, and ARP annotations naturally fall onto the outer ring.
    $detailMaxRowWidth = [Math]::Max(1200, [double]$GDrawioTierMaxRowWidth - 300)
    $estimate = @{}
    foreach ($key in @($nodeInfo.Keys | Sort-Object)) {
        $sideOf = @{}
        if ($nodeInfo[$key].Kind -eq 'Device' -and -not $nodeInfo[$key].Block.IsSummary) {
            $names = @($interfacesByBlock[$key].Interface)
            for ($i = 0; $i -lt $names.Count; $i++) { $sideOf[[string]$names[$i]] = if ($i % 2) { 'N' } else { 'S' } }
        }
        $estimate[$key] = Get-MTAutoDrawL3DetailFootprint -Info $nodeInfo[$key] -SideOf $sideOf -InterfacesByBlock $interfacesByBlock
    }
    $round1Layout = Get-DrawioRadialPlacement -Adjacency $adjacency -Keys @($nodeInfo.Keys) -FootprintOf $estimate `
        -StartX 100 -StartY 100 -NodeGap 55 -RingGap 55 -AspectRatio 1.8 -ClusterGap 140 `
        -Sweeps 4 -MaxStagger 3 -RingSpacing Exact -ClusterPacking Corner -MaxRowWidth $detailMaxRowWidth
    $round1 = $round1Layout.Positions
    $center1 = @{}
    foreach ($key in $nodeInfo.Keys) {
        $center1[$key] = [pscustomobject]@{ X = $round1[$key].X + ($estimate[$key].Width / 2); Y = $round1[$key].Y + ($estimate[$key].Height / 2) }
    }

    $sideOfBlock = @{}
    foreach ($block in @($model.Blocks | Where-Object { -not $_.IsSummary })) {
        $sideOf = @{}; $counts = @{ N = 0; E = 0; S = 0; W = 0 }
        foreach ($interface in $interfacesByBlock[$block.Key]) {
            $edge = @($model.Edges | Where-Object { $_.SourceKey -eq $block.Key -and @($_.MemberRows | Where-Object { $_.Interface -eq $interface.Interface }).Count -gt 0 } | Sort-Object Cidr | Select-Object -First 1)
            if ($edge.Count -gt 0) {
                $peer = $edge[0].TargetKey
                $fp = $estimate[$block.Key]
                $side = Get-DrawioBearingSide -DeltaX ($center1[$peer].X - $center1[$block.Key].X) -DeltaY ($center1[$peer].Y - $center1[$block.Key].Y) -AspectRatio ($fp.Width / [Math]::Max(1, $fp.Height))
            }
            else { $side = ($counts.GetEnumerator() | Sort-Object Value, Key | Select-Object -First 1).Key }
            $sideOf[[string]$interface.Interface] = $side; $counts[$side]++
        }
        $sideOfBlock[$block.Key] = $sideOf
    }

    $real = @{}
    foreach ($key in @($nodeInfo.Keys | Sort-Object)) {
        $sideOf = if ($sideOfBlock.ContainsKey($key)) { $sideOfBlock[$key] } else { @{} }
        $real[$key] = Get-MTAutoDrawL3DetailFootprint -Info $nodeInfo[$key] -SideOf $sideOf -InterfacesByBlock $interfacesByBlock
    }
    $finalLayout = Get-DrawioRadialPlacement -Adjacency $adjacency -Keys @($nodeInfo.Keys) -FootprintOf $real `
        -StartX 100 -StartY 100 -NodeGap 55 -RingGap 55 -AspectRatio 1.8 -ClusterGap 140 `
        -Sweeps 4 -MaxStagger 3 -RingSpacing Exact -ClusterPacking Corner -MaxRowWidth $detailMaxRowWidth
    $positions = $finalLayout.Positions
    $centers = @{}
    foreach ($key in $nodeInfo.Keys) {
        $centers[$key] = [pscustomobject]@{ X = $positions[$key].X + ($real[$key].Width / 2); Y = $positions[$key].Y + ($real[$key].Height / 2) }
    }

    $desiredByBlock = @{}
    foreach ($block in @($model.Blocks | Where-Object { -not $_.IsSummary })) {
        $desired = @{}; $fp = $real[$block.Key]; $origin = $positions[$block.Key]
        foreach ($interface in $interfacesByBlock[$block.Key]) {
            $edge = @($model.Edges | Where-Object { $_.SourceKey -eq $block.Key -and @($_.MemberRows | Where-Object { $_.Interface -eq $interface.Interface }).Count -gt 0 } | Sort-Object Cidr | Select-Object -First 1)
            if ($edge.Count -eq 0) { continue }
            $side = $sideOfBlock[$block.Key][[string]$interface.Interface]
            $desired[[string]$interface.Interface] = if ($side -in @('N','S')) {
                $centers[$edge[0].TargetKey].X - ($origin.X + $fp.BoxOrigin.X)
            } else { $centers[$edge[0].TargetKey].Y - ($origin.Y + $fp.BoxOrigin.Y) }
        }
        $desiredByBlock[$block.Key] = $desired
    }

    $shapeId = @{}
    foreach ($key in @($nodeInfo.Keys | Sort-Object)) {
        $info = $nodeInfo[$key]; $location = $positions[$key]
        switch ($info.Kind) {
            'Device' {
                if ($info.Block.IsSummary) { $shape = Add-DrawioL3DetailSummaryNode -Block $info.Block -Location $location }
                else {
                    $hostType = if ($info.Block.IsGatewayHost) { 'GatewayHost' } else { $null }
                    $shape = Add-DrawioHostLayer3 -Device $info.Block.Members[0].Device -Location $location -Interfaces $interfacesByBlock[$key] `
                        -HostType $hostType -SideOf $sideOfBlock[$key] -DesiredOf $desiredByBlock[$key]
                }
            }
            'Network' { $shape = Add-DrawioNetworkSegment -Network $info.Network -Location $location }
            'Arp' { $shape = Add-DrawioArpBubble -Network $info.Network -Location $location }
        }
        $shapeId[$key] = $shape.Id
    }

    $edgePalette = Get-MTAutoDrawPalette -Scope Shared
    foreach ($edge in $model.Edges) {
        $block = @($model.Blocks | Where-Object Key -eq $edge.SourceKey | Select-Object -First 1)[0]
        $sourceId = $shapeId[$edge.SourceKey]
        if (-not $block.IsSummary -and $edge.MemberRows.Count -gt 0) { $sourceId = $edge.MemberRows[0].InterfaceObject.LogicalDrawioId }
        $label = if ($block.IsSummary) { "$($edge.MemberRows.Count) member interface$(if($edge.MemberRows.Count -eq 1){''}else{'s'})" }
            elseif ($edge.MemberRows.Count -gt 0) { "$($edge.MemberRows[0].Interface)<br>$($edge.MemberRows[0].IPAddress)" } else { [string]$edge.Cidr }
        if ($sourceId -and $shapeId[$edge.TargetKey]) {
            $null = Add-DrawioConnector -SourceId $sourceId -TargetId $shapeId[$edge.TargetKey] `
                -Style "edgeStyle=none;rounded=0;endArrow=none;html=1;strokeWidth=2;strokeColor=$($edgePalette.Link.Connected);" -Text $label
        }
    }
    foreach ($network in $model.Networks) {
        $networkKey = "network:$([string]$network.Cidr)"; $arpKey = "arp:$([string]$network.Cidr)"
        if ($shapeId.ContainsKey($arpKey)) {
            $null = Add-DrawioConnector -SourceId $shapeId[$networkKey] -TargetId $shapeId[$arpKey] `
                -Style "edgeStyle=none;rounded=0;endArrow=none;dashed=1;strokeColor=$($edgePalette.Link.Annotation);strokeWidth=2;" -Text 'ARP'
        }
    }

    $bottom = 100
    foreach ($key in $nodeInfo.Keys) { $bottom = [Math]::Max($bottom, $positions[$key].Y + $real[$key].Height) }
    return [pscustomobject]@{ Bottom = $bottom; Model = $model }
}

#-----------------------------------------------------------------------------------------
# Main Function: Draw-Layer3AllDrawio
#-----------------------------------------------------------------------------------------
# "Layer 3 All": every subnet in the capture down the left, every device with an IP interface in a
# row to the right with perimeter ports, and a green edge from each interface to its subnet.
function Draw-Layer3AllDrawio {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)] $ArrayOfObjects,
        [parameter(Mandatory = $true)] $ArrayOfNetworks,
        [parameter(Mandatory = $false)] $ArrayOfIPApr
    )

    Write-MTAutoDrawPhase -Phase Draw -Message "Starting Draw-Layer3AllDrawio..."
    Start-DrawioDiagram -Name "Layer 3 All"

    $result = Add-MTAutoDrawL3DetailGraph -Devices $ArrayOfObjects -Networks $ArrayOfNetworks -Mode All

    $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = 100; Y = ($result.Bottom + 80)}) `
        -Message "Every addressed Layer 3 interface and connected network. Devices share one summary only when their complete routed behavior and visible CIDR set match; every member and address remains listed. Full network detail: cidr.csv."

    End-DrawioDiagram
    Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Draw-Layer3AllDrawio finished."
}

#-----------------------------------------------------------------------------------------
# Main Function: Draw-Layer3RoutedLinksOnlyDrawio
#-----------------------------------------------------------------------------------------
# "Layer 3 Routed Links Only": the same shape as Layer 3 All, narrowed to subnets that are actually
# a routed link, plus the ARP-discovered gateway hosts those links hand off to.
function Draw-Layer3RoutedLinksOnlyDrawio {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)] $ArrayOfObjects,
        [parameter(Mandatory = $true)] $ArrayOfNetworks,
        [parameter(Mandatory = $false)] $ArrayOfIPApr,
        [parameter(Mandatory = $false)] $ArrayofGatewayHosts
    )

    Write-MTAutoDrawPhase -Phase Draw -Message "Starting Draw-Layer3RoutedLinksOnlyDrawio..."
    Start-DrawioDiagram -Name "Layer 3 Routed Links Only"

    $result = Add-MTAutoDrawL3DetailGraph -Devices $ArrayOfObjects -Networks $ArrayOfNetworks -GatewayHosts $ArrayofGatewayHosts -Mode RoutedLinksOnly

    $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = 100; Y = ($result.Bottom + 80)}) `
        -Message "Only routed-link subnets and their member interfaces. Devices share one summary only when their complete routed behavior and visible routed-link CIDRs match. Directly-connected-only detail: Layer 3 All; every route: routes.csv."

    End-DrawioDiagram
    Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Draw-Layer3RoutedLinksOnlyDrawio finished."
}

#-----------------------------------------------------------------------------------------
# Main Function: Draw-Layer3RoutesOnlyDrawio
#-----------------------------------------------------------------------------------------
# "Layer 3 Routes Only": devices with an identical routed picture collapse into one summary block
# (Get-MTAutoDrawL3RoutesOnlyModel), a single device keeps its full per-interface card, and every
# remaining shape - single devices, summary blocks, and external next hops that resolve to nothing
# captured - is placed by the same tiered, bearing-aligned layout the CDP-LLDP pages use
# (Get-DrawioTierAssignment / Get-DrawioTierPlacement / Get-DrawioAlignedSlotPositions), so a route
# edge is a straight line wherever the block/device pair's placement allows one.
#
# Only single-device blocks get PER-PORT treatment (an interface facing whichever side its specific
# next hop sits on) - a summary block or an external hop is one shape with no individual interfaces,
# so edges simply attach to that one shape; draw.io places multiple such edges around its border
# without any help needed here.
function Draw-Layer3RoutesOnlyDrawio {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)] $ArrayOfObjects,
        [parameter(Mandatory = $false)] $ArrayOfIPApr,
        [parameter(Mandatory = $false)] $ArrayofGatewayHosts
    )

    Write-MTAutoDrawPhase -Phase Draw -Message "Starting Draw-Layer3RoutesOnlyDrawio..."
    Start-DrawioDiagram -Name "Layer 3 Routes Only"

    $model = Get-MTAutoDrawL3RoutesOnlyModel -Devices $ArrayOfObjects -GatewayHosts $ArrayofGatewayHosts

    if (@($model.Blocks).Count -eq 0) {
        if (@($model.Unrouted).Count -gt 0) {
            $null = Add-DrawioOverflowSummaryCard -TitleText "$(@($model.Unrouted).Count) devices omitted" `
                -DetailLine 'no non-local routed dependency' -Names @($model.Unrouted) `
                -Location ([pscustomobject]@{X=100;Y=100})
        }
        else {
            $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = 100; Y = 100}) -Message "No devices with a Layer 3 route were found for this run."
        }
        End-DrawioDiagram
        return
    }

    # --- Attach the drawn interfaces to each single-member block. ---
    foreach ($block in $model.Blocks) {
        if ($block.Members.Count -eq 1) {
            $device = $block.Members[0]
            $hostType = if ($ArrayofGatewayHosts -and ($ArrayofGatewayHosts -contains $device)) { "GatewayHost" } else { $null }
            $interfaces = Get-DrawioHostLayer3Interfaces -Device $device -HostType $hostType -DiagramType "RoutesOnly"
            $block | Add-Member -NotePropertyName Interfaces -NotePropertyValue $interfaces -Force
            $block | Add-Member -NotePropertyName HostType -NotePropertyValue $hostType -Force
        }
    }

    # --- Discover external next hops: gateway IPs resolving to no captured device. ---
    $externalHubsByIp = @{}
    foreach ($block in $model.Blocks) {
        foreach ($gatewayIp in @($block.Gateways.Keys)) {
            $targetHostname = $model.GatewayIndex[$gatewayIp]
            $resolvedToBlock = $targetHostname -and $model.HostnameToBlockKey.ContainsKey($targetHostname)
            $resolvedToTarget = $targetHostname -and $model.HostnameToTargetKey.ContainsKey($targetHostname)
            if (-not $resolvedToBlock -and -not $resolvedToTarget -and -not $externalHubsByIp.ContainsKey($gatewayIp)) {
                $externalHubsByIp[$gatewayIp] = [PSCustomObject]@{ Key = "hub:$gatewayIp"; Address = $gatewayIp; DeviceName = $null; IsConfigured = $false; DependantCount = 0 }
            }
        }
    }

    # --- Unified node registry: every block and every external hub is one placement node. ---
    $nodeInfo = @{}
    foreach ($block in $model.Blocks) {
        $kind = if ($block.Members.Count -eq 1) { 'Single' } else { 'Group' }
        $nodeInfo[$block.Key] = [PSCustomObject]@{ Key = $block.Key; Kind = $kind; Block = $block }
    }
    foreach ($hub in $externalHubsByIp.Values) {
        $nodeInfo[$hub.Key] = [PSCustomObject]@{ Key = $hub.Key; Kind = 'Hub'; Hub = $hub }
    }
    foreach ($target in $model.TargetOnly) {
        $nodeInfo[$target.Key] = [pscustomobject]@{ Key = $target.Key; Kind = 'Target'; Target = $target }
    }

    # --- Interface-level address index, restricted to interfaces on single-member blocks - the
    # only ones with a real shape a route edge can point at directly. A route resolving to a device
    # merged into a Group block instead attaches to that block's one shared shape. ---
    $primaryIpMap = @{}
    foreach ($block in $model.Blocks) {
        if ($block.Members.Count -ne 1) { continue }
        foreach ($iface in $block.Interfaces) {
            foreach ($addr in @(Get-MTAutoDrawInterfaceIPv4Address -Interface $iface)) {
                if ($addr.IPAddress -and -not $primaryIpMap.ContainsKey($addr.IPAddress)) {
                    $primaryIpMap[$addr.IPAddress] = [PSCustomObject]@{ BlockKey = $block.Key; Interface = $iface }
                }
            }
            foreach ($standbyIp in @($iface.standbyip)) {
                if ($standbyIp -and -not $primaryIpMap.ContainsKey($standbyIp)) {
                    $primaryIpMap[$standbyIp] = [PSCustomObject]@{ BlockKey = $block.Key; Interface = $iface }
                }
            }
        }
    }

    # --- Build wires: one per (block, distinct gateway). ---
    $wires = [System.Collections.Generic.List[object]]::new()
    $adjacency = @{}
    foreach ($key in $nodeInfo.Keys) { $adjacency[$key] = [System.Collections.Generic.List[string]]::new() }
    $peerNodeOfPort = @{}

    foreach ($block in $model.Blocks) {
        foreach ($gatewayIp in @($block.Gateways.Keys | Sort-Object)) {
            $routeObjects = @($block.Gateways[$gatewayIp])
            $targetNodeKey = $null
            $targetInterface = $null
            if ($primaryIpMap.ContainsKey($gatewayIp)) {
                $targetNodeKey = $primaryIpMap[$gatewayIp].BlockKey
                $targetInterface = $primaryIpMap[$gatewayIp].Interface
            }
            else {
                $targetHostname = $model.GatewayIndex[$gatewayIp]
                if ($targetHostname -and $model.HostnameToBlockKey.ContainsKey($targetHostname)) {
                    $targetNodeKey = $model.HostnameToBlockKey[$targetHostname]
                }
                elseif ($targetHostname -and $model.HostnameToTargetKey.ContainsKey($targetHostname)) {
                    $targetNodeKey = $model.HostnameToTargetKey[$targetHostname]
                }
                elseif ($externalHubsByIp.ContainsKey($gatewayIp)) {
                    $targetNodeKey = $externalHubsByIp[$gatewayIp].Key
                }
            }
            if (-not $targetNodeKey -or $targetNodeKey -eq $block.Key) { continue }

            $routeGroup = [PSCustomObject]@{ Name = $gatewayIp; Group = $routeObjects; Count = $routeObjects.Count }
            $presentation = Get-Layer3RouteEdgePresentation -RouteGroup $routeGroup -GatewayIp $gatewayIp

            $sourceInterface = $null
            if ($block.Members.Count -eq 1) {
                $sourceInterface = @($block.Interfaces | Where-Object { @($_.RoutesForInterface | Where-Object { [string]$_.gateway -eq $gatewayIp }).Count -gt 0 }) | Select-Object -First 1
                if ($sourceInterface) { $peerNodeOfPort["$($block.Key)|$($sourceInterface.Interface)"] = $targetNodeKey }
            }
            if ($targetInterface) { $peerNodeOfPort["$targetNodeKey|$($targetInterface.Interface)"] = $block.Key }

            $wires.Add([PSCustomObject]@{
                SourceKey = $block.Key; SourceInterface = $sourceInterface
                TargetKey = $targetNodeKey; TargetInterface = $targetInterface
                Style = $presentation.Style; Text = $presentation.Text
            })
            $adjacency[$block.Key].Add($targetNodeKey)
            $adjacency[$targetNodeKey].Add($block.Key)
        }
    }

    if ($nodeInfo.Count -eq 0) { End-DrawioDiagram; return }

    # --- Round 1: estimate (S/N split for Single nodes), place, get approximate centers. ---
    $blocks = Get-DrawioTierAssignment -Adjacency $adjacency -Keys @($nodeInfo.Keys) -BarycenterSweeps $GDrawioTierBarycenterSweeps
    $estimateFootprintOf = @{}
    foreach ($node in @($nodeInfo.Values | Sort-Object Key)) {
        $sideOf = $null
        if ($node.Kind -eq 'Single') {
            $sideOf = @{}
            $names = @($node.Block.Interfaces.Interface)
            for ($i = 0; $i -lt $names.Count; $i++) { $sideOf[[string]$names[$i]] = if ($i % 2 -eq 0) { 'S' } else { 'N' } }
        }
        $estimateFootprintOf[$node.Key] = Get-MTAutoDrawRoutesOnlyNodeFootprint -Node $node -SideOf $sideOf
    }
    $round1Positions = Get-DrawioTierPlacement -Blocks $blocks -FootprintOf $estimateFootprintOf -StartX 100 -StartY 100 -ColumnGap $GDrawioTierColumnGap -RowGap $GDrawioTierRowGap -MaxRowWidth $GDrawioTierMaxRowWidth
    $round1CenterOf = @{}
    foreach ($node in @($nodeInfo.Values | Sort-Object Key)) {
        $pos = $round1Positions[$node.Key]; $fp = $estimateFootprintOf[$node.Key]
        $round1CenterOf[$node.Key] = [PSCustomObject]@{ X = $pos.X + ($fp.Width / 2); Y = $pos.Y + ($fp.Height / 2) }
    }

    # --- Side assignment for Single nodes only - wired ports first, unwired fill the least-crowded
    # side (same reasoning as the CDP-LLDP page: filler ports competing for the same side as a real
    # link is what pulls the real link's slot away from where its peer actually is). ---
    $sideOfNode = @{}
    foreach ($node in @($nodeInfo.Values | Sort-Object Key)) {
        if ($node.Kind -ne 'Single') { continue }
        $sideOf = @{}
        $wiredSideCounts = @{ 'S' = 0; 'N' = 0; 'E' = 0; 'W' = 0 }
        $unwired = [System.Collections.Generic.List[object]]::new()
        $ownFootprint = $estimateFootprintOf[$node.Key]
        $aspect = if ($ownFootprint.Height -gt 0) { $ownFootprint.Width / $ownFootprint.Height } else { 1.0 }
        foreach ($iface in $node.Block.Interfaces) {
            $portKey = "$($node.Key)|$($iface.Interface)"
            if ($peerNodeOfPort.ContainsKey($portKey)) {
                $peerKey = $peerNodeOfPort[$portKey]
                $dx = $round1CenterOf[$peerKey].X - $round1CenterOf[$node.Key].X
                $dy = $round1CenterOf[$peerKey].Y - $round1CenterOf[$node.Key].Y
                $side = Get-DrawioBearingSide -DeltaX $dx -DeltaY $dy -AspectRatio $aspect
                $sideOf[[string]$iface.Interface] = $side
                $wiredSideCounts[$side]++
            }
            else {
                $unwired.Add($iface)
            }
        }
        foreach ($iface in $unwired) {
            $leastCrowded = ($wiredSideCounts.GetEnumerator() | Sort-Object -Property @{Expression = 'Value'}, @{Expression = 'Key'} | Select-Object -First 1).Key
            $sideOf[[string]$iface.Interface] = $leastCrowded
            $wiredSideCounts[$leastCrowded]++
        }
        $sideOfNode[$node.Key] = $sideOf
    }

    # --- Round 2: real footprints, re-place, final centers. ---
    $realFootprintOf = @{}
    foreach ($node in @($nodeInfo.Values | Sort-Object Key)) {
        $sideOf = if ($node.Kind -eq 'Single') { $sideOfNode[$node.Key] } else { $null }
        $realFootprintOf[$node.Key] = Get-MTAutoDrawRoutesOnlyNodeFootprint -Node $node -SideOf $sideOf
    }
    $finalPositions = Get-DrawioTierPlacement -Blocks $blocks -FootprintOf $realFootprintOf -StartX 100 -StartY 100 -ColumnGap $GDrawioTierColumnGap -RowGap $GDrawioTierRowGap -MaxRowWidth $GDrawioTierMaxRowWidth
    $finalCenterOf = @{}
    foreach ($node in @($nodeInfo.Values | Sort-Object Key)) {
        $pos = $finalPositions[$node.Key]; $fp = $realFootprintOf[$node.Key]
        $finalCenterOf[$node.Key] = [PSCustomObject]@{ X = $pos.X + ($fp.Width / 2); Y = $pos.Y + ($fp.Height / 2) }
    }

    # --- Slot pass for Single nodes: pull each wired port toward its peer's final center. ---
    $desiredOfNode = @{}
    foreach ($node in @($nodeInfo.Values | Sort-Object Key)) {
        if ($node.Kind -ne 'Single') { continue }
        $desired = @{}
        $origin = $finalPositions[$node.Key]
        $fp = $realFootprintOf[$node.Key]
        $boxLeft = $origin.X + $fp.BoxOrigin.X
        $boxTop = $origin.Y + $fp.BoxOrigin.Y
        foreach ($iface in $node.Block.Interfaces) {
            $portKey = "$($node.Key)|$($iface.Interface)"
            if (-not $peerNodeOfPort.ContainsKey($portKey)) { continue }
            $peerKey = $peerNodeOfPort[$portKey]
            $side = $sideOfNode[$node.Key][[string]$iface.Interface]
            $desired[[string]$iface.Interface] = if ($side -eq 'N' -or $side -eq 'S') { $finalCenterOf[$peerKey].X - $boxLeft } else { $finalCenterOf[$peerKey].Y - $boxTop }
        }
        $desiredOfNode[$node.Key] = $desired
    }

    # --- Draw every node. ---
    $hubShapeId = @{}
    $targetShapeId = @{}
    $blockShapeId = @{}
    foreach ($node in @($nodeInfo.Values | Sort-Object Key)) {
        $location = $finalPositions[$node.Key]
        switch ($node.Kind) {
            'Single' {
                $shape = Add-DrawioHostLayer3 -Device $node.Block.Members[0] -Location $location -Interfaces $node.Block.Interfaces -HostType $node.Block.HostType -SideOf $sideOfNode[$node.Key] -DesiredOf $desiredOfNode[$node.Key]
                $blockShapeId[$node.Key] = $shape.Id
            }
            'Group' {
                $groupArg = [PSCustomObject]@{ Devices = @($node.Block.Members.HostName); RouteCount = @($node.Block.Gateways.Values | ForEach-Object { $_ } | Select-Object -Unique).Count; HasDefaultRoute = $node.Block.HasDefaultRoute; Protocols = $node.Block.Protocols }
                $shape = Add-DrawioL3DependantNode -Group $groupArg -Location $location
                $blockShapeId[$node.Key] = $shape.Id
            }
            'Hub' {
                $hub = $node.Hub
                $hub.DependantCount = @($adjacency[$node.Key]).Count
                $shape = Add-DrawioL3HubNode -Hub $hub -Location $location
                $hubShapeId[$node.Key] = $shape.Id
            }
            'Target' {
                $target = $node.Target
                $hub = [pscustomobject]@{
                    Address = @($target.Gateways) -join ', '; DeviceName = [string]$target.HostName
                    IsConfigured = $true; DependantCount = @($adjacency[$node.Key]).Count
                }
                $shape = Add-DrawioL3HubNode -Hub $hub -Location $location
                $targetShapeId[$node.Key] = $shape.Id
            }
        }
    }

    # --- Draw every wire, staggering labels leaving the same node so route lists don't stack. ---
    $labelPositions = @(-0.45, 0.0, 0.45, -0.2, 0.2)
    $labelIndexByKey = @{}
    foreach ($wire in $wires) {
        $sourceId = if ($wire.SourceInterface) { $wire.SourceInterface.LogicalDrawioId } else { $blockShapeId[$wire.SourceKey] }
        $targetId = if ($wire.TargetInterface) { $wire.TargetInterface.LogicalDrawioId } else {
            if ($blockShapeId.ContainsKey($wire.TargetKey)) { $blockShapeId[$wire.TargetKey] }
            elseif ($targetShapeId.ContainsKey($wire.TargetKey)) { $targetShapeId[$wire.TargetKey] }
            else { $hubShapeId[$wire.TargetKey] }
        }
        if (-not $sourceId -or -not $targetId) { continue }
        $idx = if ($labelIndexByKey.ContainsKey($wire.SourceKey)) { $labelIndexByKey[$wire.SourceKey] } else { 0 }
        $labelIndexByKey[$wire.SourceKey] = $idx + 1
        $straightStyle = "edgeStyle=none;rounded=0;" + $wire.Style
        $null = Add-DrawioConnector -SourceId $sourceId -TargetId $targetId -Style $straightStyle -Text $wire.Text -LabelPosition $labelPositions[$idx % $labelPositions.Count]
    }

    if (@($model.Unrouted).Count -gt 0) {
        $bottom = 100
        foreach ($key in $nodeInfo.Keys) {
            $bottom = [Math]::Max($bottom, $finalPositions[$key].Y + $realFootprintOf[$key].Height)
        }
        $null = Add-DrawioOverflowSummaryCard -TitleText "$(@($model.Unrouted).Count) devices omitted" `
            -DetailLine 'no non-local routed dependency; full list in Objects.json' -Names @($model.Unrouted) `
            -Location ([pscustomobject]@{X=100;Y=$bottom+60})
    }

    End-DrawioDiagram
    Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Draw-Layer3RoutesOnlyDrawio finished."
}


#-----------------------------------------------------------------------------------------
# Main Function: Draw-Layer3TopologyOverviewDiagram
#-----------------------------------------------------------------------------------------
# One-screen L3 analogue of Draw-SiteTopologyOverviewDiagram: a device-centric map with fixed-size
# cards in role bands, one merged edge per device pair, and an embedded legend.
#
# Bands, top to bottom: external next hops (not captured) -> Border (default route leaves the site,
# or a firewall) -> Transit (other devices route through it) -> shared-segment chips (3+ devices on
# one subnet) -> Gateway (owns subnets/SVIs only). Role is derived purely from routing - see
# Get-MTAutoDrawL3TopologyModel's header comment for the exact rule and why segment size decides
# whether a shared subnet gets a chip or just becomes an edge label.
#
# Every device-pair fact (shared subnet, routing, FHRP) is merged onto ONE edge to avoid parallel
# adjacency, route, and FHRP connectors. Route/subnet PER-INTERFACE or PER-VLAN detail belongs to
# the Layer 3 Connectivity and Routes Summary pages and to
# layer3-interfaces.csv / routes.csv / Objects.json.
function Draw-Layer3TopologyOverviewDiagram {
    [CmdletBinding()]
    param (
        # An array of all configured device objects.
        [parameter(Mandatory = $true)]
        $ArrayOfObjects,
        # ARP-discovered / unresolved gateway-host placeholder devices, used only to put a resolved
        # identity (vendor/MAC) on an external next-hop card. Optional - a run without ARP data
        # still gets the page, just without that second line on the external cards.
        [parameter(Mandatory = $false)]
        $ArrayofGatewayHosts
    )

    Write-MTAutoDrawPhase -Phase Draw -Message "Starting Draw-Layer3TopologyOverviewDiagram..."
    Start-DrawioDiagram -Name "Layer 3 Topology Overview"

    $model = Get-MTAutoDrawL3TopologyModel -Devices $ArrayOfObjects

    if (@($model.Nodes).Count -eq 0 -and @($model.ExternalHops).Count -eq 0) {
        $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = 100; Y = 100}) `
            -Message "No Layer 3 topology was found for this run. No device carries an IP interface or a parsed route."
        End-DrawioDiagram
        Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Layer 3 Topology Overview diagram page has been created (no L3 topology)."
        return
    }

    $palette = Get-MTAutoDrawPalette -Scope L3Topology

    # Map every gateway-host IP to its object, exactly as Draw-Layer3RoutesSummaryDiagram does, so
    # an external next-hop card can show WHO it is (vendor/MAC) and not just its bare address.
    $gatewayHostByIp = @{}
    foreach ($gwHost in @($ArrayofGatewayHosts | Where-Object { $_ })) {
        foreach ($ip in @($gwHost.arrayofipaddresses | Where-Object { $_ })) {
            $ip = [string]$ip
            if ($ip -and -not $gatewayHostByIp.ContainsKey($ip)) { $gatewayHostByIp[$ip] = $gwHost }
        }
    }

    $devCap  = if ($GDrawioL3TopoMaxDevicesPerBand -gt 0) { [int]$GDrawioL3TopoMaxDevicesPerBand } else { 14 }
    $chipCap = if ($GDrawioL3TopoMaxSegmentChips -gt 0) { [int]$GDrawioL3TopoMaxSegmentChips } else { 10 }
    $hopCap  = if ($GDrawioL3TopoMaxExternalHops -gt 0) { [int]$GDrawioL3TopoMaxExternalHops } else { 6 }

    $nodeIdByHost = @{}
    $bandGap = 70

    # =====================================================================
    # Band 0 - external next hops (default/route targets that resolve to no captured device).
    # Reuses Add-DrawioL3HubNode as-is, exactly like the External row on Routes Summary.
    # =====================================================================
    $shownHops = @($model.ExternalHops | Select-Object -First $hopCap)
    $overflowHops = @($model.ExternalHops | Select-Object -Skip $hopCap)
    $hubIdByAddress = @{}
    $cursor0 = New-DrawioGridCursor -StartX 100 -StartY 100 `
        -ItemsPerRow ([Math]::Max(1, [Math]::Floor($GDrawioOverviewMaxWidth / 280))) `
        -HorizontalPadding 40 -VerticalPadding 40
    foreach ($hop in $shownHops) {
        $gwHost = if ($gatewayHostByIp.ContainsKey([string]$hop.Address)) { $gatewayHostByIp[[string]$hop.Address] } else { $null }
        $hub = [pscustomobject]@{
            Address = $hop.Address
            DeviceName = if ($gwHost -and $gwHost.hostname) { ([string]$gwHost.hostname).Trim() } else { $null }
            IsConfigured = $false
            DependantCount = $hop.DependantCount
        }
        $node = Add-DrawioL3HubNode -Hub $hub -Location ([PSCustomObject]@{X = $cursor0.X; Y = $cursor0.Y})
        $hubIdByAddress[[string]$hop.Address] = $node.Id
        $cursor0 = Get-DrawioWrappedGridPosition -Cursor $cursor0 -DrawnWidth $node.Width -DrawnHeight $node.Height
    }
    if ($overflowHops.Count -gt 0) {
        $dims = Add-DrawioOverflowSummaryCard -TitleText "+$($overflowHops.Count) other external next hops" `
            -DetailLine "fewer dependants each" -Names (@($overflowHops | ForEach-Object { [string]$_.Address })) `
            -Location ([PSCustomObject]@{X = $cursor0.X; Y = $cursor0.Y})
        $cursor0 = Get-DrawioWrappedGridPosition -Cursor $cursor0 -DrawnWidth $dims.Width -DrawnHeight $dims.Height
    }
    $bandBottom = if ($shownHops.Count -gt 0 -or $overflowHops.Count -gt 0) { $cursor0.Y + $cursor0.RowHeight } else { 100 }

    # =====================================================================
    # Bands 1/2/4 - Border, Transit, Gateway device cards. Same wrapped-grid-per-band construction
    # as Draw-SiteTopologyOverviewDiagram's tier bands, each capped and folded into one overflow
    # card so the page stays bounded at any site size.
    # =====================================================================
    # Border and Transit are drawn first (busiest-by-dependants first), then the shared-segment
    # chips, then Gateway last - chips sit between Transit and Gateway regardless of whether either
    # role band actually has members, because a shared 3+ device subnet is independent of role: a
    # site can have shared segments with zero Transit-role devices on them.
    #
    # Add-DrawioL3TopologyRoleBandNodes returns rather than mutates the caller's cursor state - a
    # PowerShell function assigning to an outer-scope variable by name (rather than returning a
    # value) silently creates a new local instead, so the return-value idiom every other Draw-Drawio*
    # helper in this file already uses is followed here too, not just for style.
    $borderResult = Add-DrawioL3TopologyRoleBandNodes -Role 'Border' -RankBy { -1 * $_.DependantCount } `
        -Model $model -StartY ($bandBottom + $bandGap) -DeviceCap $devCap -MaxWidth $GDrawioOverviewMaxWidth
    foreach ($kv in $borderResult.NodeIdByHost.GetEnumerator()) { $nodeIdByHost[$kv.Key] = $kv.Value }
    $bandBottom = $borderResult.Bottom

    $transitResult = Add-DrawioL3TopologyRoleBandNodes -Role 'Transit' -RankBy { -1 * $_.DependantCount } `
        -Model $model -StartY ($bandBottom + $bandGap) -DeviceCap $devCap -MaxWidth $GDrawioOverviewMaxWidth
    foreach ($kv in $transitResult.NodeIdByHost.GetEnumerator()) { $nodeIdByHost[$kv.Key] = $kv.Value }
    $bandBottom = $transitResult.Bottom

    # model.Segments includes every segment with 2+ devices (kept general in case a future page
    # wants the 2-device ones too); only 3+ device segments become a chip here - a 2-device segment
    # is already fully represented by the PairEdges entry between those two devices.
    $chipWorthySegments = @($model.Segments | Where-Object { $_.Devices.Count -ge 3 })
    $chipIdByCidr = @{}
    $shownChips = @($chipWorthySegments | Select-Object -First $chipCap)
    $overflowChips = @($chipWorthySegments | Select-Object -Skip $chipCap)
    if ($shownChips.Count -gt 0 -or $overflowChips.Count -gt 0) {
        $chipCursor = New-DrawioGridCursor -StartX 100 -StartY ($bandBottom + $bandGap) `
            -ItemsPerRow ([Math]::Max(1, [Math]::Floor($GDrawioOverviewMaxWidth / (150 + 30)))) `
            -HorizontalPadding 30 -VerticalPadding 30
        foreach ($segment in $shownChips) {
            $dims = Add-DrawioL3SegmentChip -Segment $segment -VrfColorMap $model.Vrfs -Location ([PSCustomObject]@{X = $chipCursor.X; Y = $chipCursor.Y})
            $chipIdByCidr[[string]$segment.Cidr] = $dims.Id
            $chipCursor = Get-DrawioWrappedGridPosition -Cursor $chipCursor -DrawnWidth $dims.Width -DrawnHeight $dims.Height
        }
        if ($overflowChips.Count -gt 0) {
            $dims = Add-DrawioOverflowSummaryCard -TitleText "+$($overflowChips.Count) other shared subnets" `
                -DetailLine "fewer devices each" -Names (@($overflowChips | ForEach-Object { [string]$_.Cidr })) `
                -Location ([PSCustomObject]@{X = $chipCursor.X; Y = $chipCursor.Y})
            $chipCursor = Get-DrawioWrappedGridPosition -Cursor $chipCursor -DrawnWidth $dims.Width -DrawnHeight $dims.Height
        }
        $bandBottom = $chipCursor.Y + $chipCursor.RowHeight
    }

    $gatewayResult = Add-DrawioL3TopologyRoleBandNodes -Role 'Gateway' -RankBy { -1 * $_.SubnetCount } `
        -Model $model -StartY ($bandBottom + $bandGap) -DeviceCap $devCap -MaxWidth $GDrawioOverviewMaxWidth
    foreach ($kv in $gatewayResult.NodeIdByHost.GetEnumerator()) { $nodeIdByHost[$kv.Key] = $kv.Value }
    $bandBottom = $gatewayResult.Bottom

    # =====================================================================
    # Edges - drawn after every band exists, so every endpoint is a shape already registered on
    # this page. Three classes; see Get-MTAutoDrawL3TopologyModel's header comment for how PairEdges
    # already merged adjacency + routing onto one entry per pair.
    # =====================================================================
    if ($chipIdByCidr) {
        foreach ($segment in $shownChips) {
            $chipId = $chipIdByCidr[[string]$segment.Cidr]
            if (-not $chipId) { continue }
            foreach ($memberHost in @($segment.Devices)) {
                $memberId = $nodeIdByHost[[string]$memberHost]
                if (-not $memberId) { continue }
                $null = Add-DrawioConnector -SourceId $chipId -TargetId $memberId `
                    -Style "endArrow=none;html=1;strokeWidth=1;strokeColor=$($palette.Link.SegmentSpoke.Color);"
            }
        }
    }

    foreach ($pairEdge in @($model.PairEdges)) {
        $sourceId = $nodeIdByHost[[string]$pairEdge.A]
        $targetId = $nodeIdByHost[[string]$pairEdge.B]
        if (-not $sourceId -or -not $targetId) { continue }

        $aToB = $pairEdge.Directions.Contains("$($pairEdge.A)->$($pairEdge.B)")
        $bToA = $pairEdge.Directions.Contains("$($pairEdge.B)->$($pairEdge.A)")
        $protocolText = if (@($pairEdge.Protocols).Count -gt 0) { (@($pairEdge.Protocols) -join '/') } else { 'route' }

        if ($pairEdge.Kind -eq 'Adjacent') {
            $cidrLabel = if (@($pairEdge.SharedCidrs).Count -gt 0) {
                $first = [string]@($pairEdge.SharedCidrs)[0]
                if (@($pairEdge.SharedCidrs).Count -gt 1) { "$first (+$(@($pairEdge.SharedCidrs).Count - 1) more)" } else { $first }
            } else { 'shared segment' }
            $vlanPart = if ($pairEdge.Vlan) { " . Vlan $($pairEdge.Vlan)" } else { '' }
            $vrfPart = if ($pairEdge.Vrf -and $pairEdge.Vrf -ne 'default') { " . [$($pairEdge.Vrf)]" } else { '' }
            $label = "$cidrLabel$vlanPart$vrfPart"
            if ($pairEdge.IsRouted) { $label += " . $protocolText x$($pairEdge.RouteCount)" }

            # HSRP/VRRP is a fact about this SAME pair, not a second edge: Add-DrawioConnector
            # treats any two calls sharing a source/target pair as duplicates of one edge regardless
            # of style, so a genuinely separate FHRP edge would just silently never be drawn. It is
            # folded into this edge's label, and - because "these two are a redundancy pair" is the
            # stronger fact - takes over the line's color/weight even when the pair is also routed.
            if ($pairEdge.HasFhrp) {
                $grpSuffix = if ([int]$pairEdge.FhrpGroupCount -eq 1) { '' } else { 's' }
                $vipText = if (@($pairEdge.FhrpVips).Count -gt 0) {
                    $vipLabel = " . VIP $(@($pairEdge.FhrpVips)[0])"
                    if (@($pairEdge.FhrpVips).Count -gt 1) { $vipLabel += " (+$(@($pairEdge.FhrpVips).Count - 1) more)" }
                    $vipLabel
                } else { '' }
                $label += " . HSRP x$($pairEdge.FhrpGroupCount) grp$grpSuffix$vipText"
            }

            if ($pairEdge.HasFhrp) {
                $arrowStyle = if (-not $pairEdge.IsRouted) { "endArrow=none;" }
                    elseif ($aToB -and $bToA) { "startArrow=block;endArrow=block;" }
                    elseif ($bToA) { "startArrow=block;endArrow=none;" }
                    else { "startArrow=none;endArrow=block;" }
                $dashStyle = if ($pairEdge.IsRouted -and -not $pairEdge.HasDefault) { "dashed=1;" } else { "" }
                $style = "html=1;strokeWidth=4;strokeColor=$($palette.Link.Fhrp.Color);endSize=6;$arrowStyle$dashStyle"
            }
            elseif ($pairEdge.IsRouted) {
                $color = Get-MTAutoDrawL3TopoProtocolColor -Protocol (@($pairEdge.Protocols) | Select-Object -First 1)
                $arrowStyle = if ($aToB -and $bToA) { "startArrow=block;endArrow=block;" }
                    elseif ($bToA) { "startArrow=block;endArrow=none;" }
                    else { "startArrow=none;endArrow=block;" }
                $dashStyle = if (-not $pairEdge.HasDefault) { "dashed=1;" } else { "" }
                $style = "html=1;strokeWidth=2;strokeColor=$color;endSize=6;$arrowStyle$dashStyle"
            }
            else {
                $style = "endArrow=none;html=1;strokeWidth=2;strokeColor=$($palette.Link.Adjacency.Color);"
            }
            $null = Add-DrawioConnector -SourceId $sourceId -TargetId $targetId -Text $label -Style $style
        }
        else {
            # Indirect: a routing dependency with no shared segment - reached over an intermediate.
            $color = if (@($pairEdge.Protocols).Count -gt 0) {
                Get-MTAutoDrawL3TopoProtocolColor -Protocol (@($pairEdge.Protocols) | Select-Object -First 1)
            } else { $palette.Link.Indirect.Color }
            $arrowStyle = if ($aToB -and $bToA) { "startArrow=block;endArrow=block;" }
                elseif ($bToA) { "startArrow=block;endArrow=none;" }
                else { "startArrow=none;endArrow=block;" }
            $label = "$protocolText x$($pairEdge.RouteCount)"
            $style = "html=1;strokeWidth=2;strokeColor=$color;endSize=6;dashed=1;dashPattern=8 4;$arrowStyle"
            $null = Add-DrawioConnector -SourceId $sourceId -TargetId $targetId -Text $label -Style $style
        }
    }

    # Device -> external next hop (the reason Band 0 exists at all). A device can have several
    # routes to the same external IP (rare but possible with floating static routes); those already
    # merged onto one ExternalEdges entry per (device, IP) pair by the model.
    foreach ($extEdge in @($model.ExternalEdges)) {
        $sourceId = $nodeIdByHost[[string]$extEdge.HostName]
        $targetId = $hubIdByAddress[[string]$extEdge.Address]
        if (-not $sourceId -or -not $targetId) { continue }
        $protocolText = if (@($extEdge.Protocols).Count -gt 0) { (@($extEdge.Protocols) -join '/') } else { 'route' }
        $color = Get-MTAutoDrawL3TopoProtocolColor -Protocol (@($extEdge.Protocols) | Select-Object -First 1)
        $dashStyle = if (-not $extEdge.HasDefault) { "dashed=1;" } else { "" }
        $label = "$protocolText x$($extEdge.RouteCount)"
        $null = Add-DrawioConnector -SourceId $sourceId -TargetId $targetId -Text $label `
            -Style "html=1;strokeWidth=2;strokeColor=$color;endArrow=block;endSize=6;$dashStyle"
    }

    # =====================================================================
    # Legend + footer.
    # =====================================================================
    $legend = Add-DrawioL3TopologyLegend -Location ([PSCustomObject]@{X = 100; Y = $bandBottom + $bandGap}) -VrfColorMap $model.Vrfs
    $footerY = $bandBottom + $bandGap + $legend.Height + 25

    $l2Note = if (@($model.L2Only).Count -gt 0) { " $(@($model.L2Only).Count) L2-only devices (no IP interface or route) are omitted." } else { "" }
    $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = 100; Y = $footerY}) `
        -Message "Layer 3 topology overview - role (Border/Transit/Gateway) is derived from routing, not vendor config. A shared subnet with 3+ devices is drawn as its own chip; with 2 it is the label on the edge between them; with 1 it is folded into that device's subnet/SVI count.$l2Note Per-route detail: the Layer 3 Connectivity or Routes Summary pages, or Objects.json."

    End-DrawioDiagram
    Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Layer 3 Topology Overview diagram page has been created."
}


#-----------------------------------------------------------------------------------------
# Main Function: Draw-Layer3ConnectivityDiagram
#-----------------------------------------------------------------------------------------
# One-screen Layer 3 dependency map: which devices route through which upstream next hop.
#
# The "Layer 3 Routes Only" page draws one shape per device and one edge per route group, which is
# why it grows to tens of thousands of pixels wide on a large site - even where most of those
# devices carry the identical single default route. This page draws the FACT once instead: devices
# sharing an identical significant-route set collapse into a single node labelled with the count,
# so the page grows with the number of distinct routing behaviours, not with the device count.
# That is what makes it bounded; a site can double in size without this page changing at all.
#
# Deliberately drawn alongside Layer 3 Routes Only rather than replacing it, so both can be compared
# on the same input before the older page is retired.
function Draw-Layer3ConnectivityDiagram {
    [CmdletBinding()]
    param (
        # An array of all configured device objects.
        [parameter(Mandatory = $true)]
        $ArrayOfObjects
    )

    $edgePalette = Get-MTAutoDrawPalette -Scope Shared

    Write-MTAutoDrawPhase -Phase Draw -Message "Starting Draw-Layer3ConnectivityDiagram..."
    Start-DrawioDiagram -Name "Layer 3 Connectivity"

    $model = Get-MTAutoDrawL3ConnectivityModel -Devices $ArrayOfObjects
    $roleByHost = @{}
    foreach ($roleNode in @((Get-MTAutoDrawL3TopologyModel -Devices $ArrayOfObjects).Nodes)) {
        $roleByHost[[string]$roleNode.HostName] = $roleNode
    }

    if (@($model.Groups).Count -eq 0 -and @($model.DeviceNodes).Count -eq 0 -and @($model.ExternalHubs).Count -eq 0) {
        $detail = if (@($model.Unrouted).Count -gt 0) {
            "All $(@($model.Unrouted).Count) devices carry only directly-connected routes."
        } else { "No routing tables were parsed for this run." }
        $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = 100; Y = 100}) `
            -Message "No routed inter-device dependencies were found. $detail"
        End-DrawioDiagram
        Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Layer 3 Connectivity diagram page has been created (no routed dependencies)."
        return
    }

    $nodeInfo = @{}; $adjacency = @{}
    foreach ($node in $model.DeviceNodes) {
        $nodeInfo[$node.Key] = [pscustomobject]@{ Kind = 'Device'; Value = $node }
        $adjacency[$node.Key] = [System.Collections.Generic.List[string]]::new()
    }
    foreach ($group in $model.Groups) {
        $nodeInfo[$group.Key] = [pscustomobject]@{ Kind = 'Group'; Value = $group }
        $adjacency[$group.Key] = [System.Collections.Generic.List[string]]::new()
    }
    foreach ($hub in $model.ExternalHubs) {
        $nodeInfo[$hub.Key] = [pscustomobject]@{ Kind = 'External'; Value = $hub }
        $adjacency[$hub.Key] = [System.Collections.Generic.List[string]]::new()
    }
    foreach ($edge in $model.Edges) {
        if (-not $adjacency.ContainsKey($edge.SourceKey) -or -not $adjacency.ContainsKey($edge.TargetKey)) { continue }
        $adjacency[$edge.SourceKey].Add($edge.TargetKey); $adjacency[$edge.TargetKey].Add($edge.SourceKey)
    }

    $footprints = @{}
    foreach ($key in $nodeInfo.Keys) {
        $info = $nodeInfo[$key]
        $footprints[$key] = switch ($info.Kind) {
            'Device' { Get-DrawioL3CompositeDeviceFootprint -Node $info.Value }
            'Group' { Get-DrawioL3DependantNodeFootprint -Group $info.Value }
            default { [pscustomobject]@{ Width = 240; Height = 70 } }
        }
    }
    $centerCandidates = [System.Collections.Generic.List[object]]::new()
    foreach ($key in @($nodeInfo.Keys | Sort-Object)) {
        $info = $nodeInfo[$key]
        if ($info.Kind -eq 'Device') {
            $hostName = [string]$info.Value.HostName
            $roleNode = if ($roleByHost.ContainsKey($hostName)) { $roleByHost[$hostName] } else { $null }
            $centerCandidates.Add([pscustomobject]@{
                Key = $key; IsConfigured = $true; HostName = $hostName
                Role = if ($roleNode) { [string]$roleNode.Role } else { 'Gateway' }
                IsSecurity = [bool]($roleNode -and $roleNode.IsSecurity)
            })
        }
        else {
            $centerCandidates.Add([pscustomobject]@{ Key = $key; IsConfigured = $false; HostName = $null; Role = 'Other'; IsSecurity = $false })
        }
    }
    $preferredCenters = @(Get-MTAutoDrawL3PreferredCenters -Nodes @($centerCandidates) -Edges @($model.Edges))
    $layout = Get-DrawioRadialPlacement -Adjacency $adjacency -Keys @($nodeInfo.Keys) -FootprintOf $footprints `
        -StartX 100 -StartY 100 -NodeGap 65 -RingGap 65 -AspectRatio 1.8 -ClusterGap 140 `
        -Sweeps 4 -MaxStagger 3 -RingSpacing Exact -ClusterPacking Corner `
        -MaxRowWidth $GDrawioOverviewMaxWidth -PreferredCenters $preferredCenters
    $positions = $layout.Positions

    $drawn = @{}
    foreach ($key in @($nodeInfo.Keys | Sort-Object)) {
        $info = $nodeInfo[$key]
        $shape = switch ($info.Kind) {
            'Device' { Add-DrawioL3CompositeDeviceNode -Node $info.Value -Location $positions[$key] }
            'Group' { Add-DrawioL3DependantNode -Group $info.Value -Location $positions[$key] }
            default { Add-DrawioL3HubNode -Hub $info.Value -Location $positions[$key] }
        }
        $drawn[$key] = $shape
    }

    $labelPositions = @(-0.45, 0.0, 0.45, -0.2, 0.2)
    $labelIndexBySource = @{}
    foreach ($edge in $model.Edges) {
        if (-not $drawn.ContainsKey($edge.SourceKey) -or -not $drawn.ContainsKey($edge.TargetKey)) { continue }
        $sourceInfo = $nodeInfo[$edge.SourceKey]
        $targetInfo = $nodeInfo[$edge.TargetKey]
        $sourceId = if ($sourceInfo.Kind -eq 'Device') { $drawn[$edge.SourceKey].BoundaryId } else { $drawn[$edge.SourceKey].Id }
        $targetId = if ($targetInfo.Kind -eq 'Device') { $drawn[$edge.TargetKey].BoundaryId } else { $drawn[$edge.TargetKey].Id }
        if (-not $sourceId -or -not $targetId) { continue }
        $protocols = if (@($edge.Protocols).Count -gt 0) { @($edge.Protocols) -join '/' } else { 'route' }
        $style = "edgeStyle=none;rounded=0;endArrow=block;html=1;strokeWidth=2;strokeColor=$($edgePalette.Link.Routed);"
        if (-not $edge.HasDefault) { $style += 'dashed=1;' }
        $labelIndex = if ($labelIndexBySource.ContainsKey($edge.SourceKey)) { $labelIndexBySource[$edge.SourceKey] } else { 0 }
        $labelIndexBySource[$edge.SourceKey] = $labelIndex + 1
        $null = Add-DrawioConnector -SourceId $sourceId -TargetId $targetId -Text "$protocols x$($edge.RouteCount) via $($edge.Gateway)" `
            -Style $style -LabelPosition $labelPositions[$labelIndex % $labelPositions.Count]
    }

    $bottom = 100
    foreach ($key in $nodeInfo.Keys) { $bottom = [Math]::Max($bottom, $positions[$key].Y + $footprints[$key].Height) }

    # --- Devices with no routed dependency at all. Stated once, not once per device: on a switched
    # site this is most of the device list, which as individual nodes would be the entire page. ---
    if (@($model.Unrouted).Count -gt 0) {
        $dims = Add-DrawioOverflowSummaryCard -TitleText "$(@($model.Unrouted).Count) devices with no routed dependency" `
            -DetailLine "directly-connected routes only" -Names @($model.Unrouted) `
            -Location ([PSCustomObject]@{X = 100; Y = ($bottom + 60)})
        $bottom = $bottom + 60 + $dims.Height
    }

    $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = 100; Y = $bottom + 60}) `
        -Message "Layer 3 dependencies. A configured upstream/transit device is one outer container holding every next-hop identity and its own outbound routing; identical non-hub leaf devices share one node. Dashed/orange next hops are not captured. Per-route detail: Layer 3 Routes Only or Objects.json."

    End-DrawioDiagram
    Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Layer 3 Connectivity diagram page has been created."
}


#-----------------------------------------------------------------------------------------
# Main Function: Draw-Layer3RoutesSummaryDiagram
#-----------------------------------------------------------------------------------------
# "Who points where" on one screen. This summary favors a compact operational view; the Layer 3
# Routes Only page retains the full per-route layout.
#
# Every device is classified into one of three buckets by Get-MTAutoDrawL3RoutesSummaryModel:
#   Unrouted     0 significant routes          -> one footer note, not drawn individually
#   SingleStatic  exactly 1 static route        -> collapsed into a shared box per next hop
#   Individual     everything else (2+ routes,   -> own topology-style node
#                 or 1 dynamic-protocol route)
#
# Layout is a primary cluster with one ring around it, matching the page's hub-and-spoke relationships.
#   Primary cluster - the busiest devices, reusing Add-DrawioTopologyNode as-is (200x70 tiered
#            card: Core/Distribution/Access colored by CDP/LLDP neighbour degree, security-purple
#            override for firewalls, red-outline for STP root bridges - the same convention as
#            the Site Topology Overview page). "Primary" = every device already classified Core
#            tier; if none reached that threshold (a small/flat site), the single best-connected
#            device stands in alone. One device centers the ring directly; more than one stack in
#            a tight vertical cluster whose midpoint becomes the ring's center, so the layout still
#            reads as one hub even with two or three core devices.
#   Ring - every other individual device, external next-hop (ARP-resolved / unresolved gateway
#            host, via Add-DrawioL3HubNode, orange/dashed "external / not captured" - deliberately
#            NOT the flat-purple Layer3ARPHostColour, since purple already means "firewall" on the
#            topology page), and single-static next-hop group (via Add-DrawioL3DependantNode:
#            count, protocol, up to N member names, "+N more") is placed once around the primary
#            cluster via Get-DrawioRadialPositions, so every spoke back to the cluster is a
#            straight line and the ring's radius simply grows with node count instead of wrapping
#            into overlapping rows. Ring order favours items whose route resolves to a primary
#            device (they land first, i.e. nearest 12 o'clock and each other) over items that
#            don't, which keeps same-target spokes from scattering around the far side.
#   Footer   - Unrouted bucket and the legend, one overflow summary card / legend box below the ring.
#
# Routing edges attach at DEVICE level (not per-interface, because the individual-device card is
# fixed-size and has no per-interface shape): each device's .RoutesSummaryDrawioId (set by
# Add-DrawioTopologyNode) is the source; the target is the matching card of the captured device
# that owns the gateway IP (via New-MTAutoDrawGatewayIndex), so "A routes via B" is a direct A->B
# arrow. Edges to an EXTERNAL next hop are not drawn - that dependency is already stated on the
# hub card, and a hub-shaped endpoint would muddy the "device points at device" reading. Edge
# colour comes from Get-MTAutoDrawRouteProtocolColor (OSPF standardized on yellow rgb(255,255,51)),
# and the new Add-DrawioRoutesSummaryLegend explains both that and the device tier colours.
#
# Overflow safety: each category caps at a configurable count (busiest-first) and folds the
# remainder into one Add-DrawioOverflowSummaryCard, so the page stays bounded at any site size.
function Add-MTAutoDrawL3RoutesSummaryRadialContent {
    [CmdletBinding()]
    param($ArrayOfObjects, $ArrayofGatewayHosts)

    $model = Get-MTAutoDrawL3RoutesSummaryModel -Devices $ArrayOfObjects
    if (@($model.Individual).Count -eq 0 -and @($model.StaticGroups).Count -eq 0) {
        $detail = if (@($model.Unrouted).Count -gt 0) { "All $(@($model.Unrouted).Count) devices carry only directly-connected routes." }
            else { 'No routing tables were parsed for this run.' }
        $null = Add-DrawioOverviewFooterNote -Location ([pscustomobject]@{X=100;Y=100}) `
            -Message "No routing dependencies were found for the summary page. $detail"
        return
    }

    $gatewayIndex = New-MTAutoDrawGatewayIndex -Devices $ArrayOfObjects
    $roleByHost = @{}
    foreach ($roleNode in @((Get-MTAutoDrawL3TopologyModel -Devices $ArrayOfObjects).Nodes)) {
        $roleByHost[[string]$roleNode.HostName] = $roleNode
    }

    $securityDeviceTypes = Get-MTAutoDrawSecurityDeviceTypes
    $classified = @{}
    foreach ($device in $ArrayOfObjects) {
        if (-not $device.hostname) { continue }
        $degree = @(@($device.CDPNeighbors) + @($device.LLDPNeighbors) | Where-Object {
            $_.TargetHostname -and -not $_.Ignored -and $_.TargetHostname -ine $device.hostname
        }).Count
        $isSecurity = [bool](($device.DeviceType -and $device.DeviceType -in $securityDeviceTypes) -or
            (@($device.interfaces | Where-Object { $_.Zone }).Count -gt 0))
        $classified[[string]$device.hostname] = [pscustomobject]@{
            Tier = if ($degree -ge $GDrawioTopologyCoreDegreeThreshold) { 'Core' }
                elseif ($degree -ge $GDrawioTopologyDistDegreeThreshold) { 'Distribution' } else { 'Access' }
            IsSecurity = $isSecurity
            IsRootBridge = [bool]($device.SpanningTree -and @($device.SpanningTree.RootBridgeForVlans).Count -gt 0)
            Degree = $degree
        }
    }

    $gatewayHostByIp = @{}
    foreach ($gwHost in @($ArrayofGatewayHosts | Where-Object { $_ })) {
        foreach ($ip in @($gwHost.arrayofipaddresses | Where-Object { $_ })) {
            if (-not $gatewayHostByIp.ContainsKey([string]$ip)) { $gatewayHostByIp[[string]$ip] = $gwHost }
        }
    }
    $externalGateways = @{}
    foreach ($group in $model.StaticGroups) {
        if ($group.Gateway -and -not $gatewayIndex.ContainsKey([string]$group.Gateway)) {
            if (-not $externalGateways.ContainsKey([string]$group.Gateway)) { $externalGateways[[string]$group.Gateway] = 0 }
            $externalGateways[[string]$group.Gateway] += $group.DeviceCount
        }
    }
    foreach ($entry in $model.Individual) {
        foreach ($routeGroup in @($entry.GatewayRoutes)) {
            if ($routeGroup.Gateway -and -not $gatewayIndex.ContainsKey([string]$routeGroup.Gateway)) {
                if (-not $externalGateways.ContainsKey([string]$routeGroup.Gateway)) { $externalGateways[[string]$routeGroup.Gateway] = 0 }
                $externalGateways[[string]$routeGroup.Gateway]++
            }
        }
    }
    $gatewayHubs = @($externalGateways.GetEnumerator() | ForEach-Object {
        $ip = [string]$_.Key; $gwHost = if ($gatewayHostByIp.ContainsKey($ip)) { $gatewayHostByIp[$ip] } else { $null }
        [pscustomobject]@{ Address=$ip; DeviceName=$(if($gwHost -and $gwHost.hostname){[string]$gwHost.hostname}else{$null}); IsConfigured=$false; DependantCount=$_.Value }
    } | Sort-Object @{Expression={-1*$_.DependantCount}}, Address)

    $indCap = if ($GDrawioRoutesSummaryMaxIndividualDevices -gt 0) { [int]$GDrawioRoutesSummaryMaxIndividualDevices } else { 12 }
    $gwCap = if ($GDrawioRoutesSummaryMaxGateways -gt 0) { [int]$GDrawioRoutesSummaryMaxGateways } else { 8 }
    $grpCap = if ($GDrawioRoutesSummaryMaxGroups -gt 0) { [int]$GDrawioRoutesSummaryMaxGroups } else { 8 }
    $maxNames = if ($GDrawioRoutesSummaryMaxNamesPerGroup -gt 0) { [int]$GDrawioRoutesSummaryMaxNamesPerGroup } else { 0 }
    $shownIndividual = @($model.Individual | Select-Object -First $indCap)
    $overflowIndividual = @($model.Individual | Select-Object -Skip $indCap)
    $shownGateways = @($gatewayHubs | Select-Object -First $gwCap)
    $overflowGateways = @($gatewayHubs | Select-Object -Skip $gwCap)
    $shownGroups = @($model.StaticGroups | Select-Object -First $grpCap)
    $overflowGroups = @($model.StaticGroups | Select-Object -Skip $grpCap)

    $nodeInfo = @{}; $adjacency = @{}; $footprints = @{}
    $individualKeyByHost = @{}; $groupKeyByGateway = @{}; $gatewayKeyByAddress = @{}
    foreach ($entry in $shownIndividual) {
        $key = "individual:$($entry.HostName)"; $individualKeyByHost[[string]$entry.HostName] = $key
        $nodeInfo[$key] = [pscustomobject]@{Kind='Individual';Data=$entry}; $adjacency[$key] = [System.Collections.Generic.List[string]]::new()
        $footprints[$key] = [pscustomobject]@{Width=$GDrawioOverviewNodeWidth;Height=70}
    }
    foreach ($group in $shownGroups) {
        $key = "group:$($group.Gateway)"; $groupKeyByGateway[[string]$group.Gateway] = $key
        $nodeGroup = [pscustomobject]@{
            Devices=@($group.Devices); RouteCount=$group.DeviceCount
            HasDefaultRoute=[bool](@($group.DestinationSubnets | Where-Object { $_ -match '^0\.0\.0\.0' }).Count -gt 0)
            Protocols=@($group.Protocols)
        }
        $nodeInfo[$key] = [pscustomobject]@{Kind='Group';Data=$group;NodeGroup=$nodeGroup}; $adjacency[$key] = [System.Collections.Generic.List[string]]::new()
        $footprints[$key] = Get-DrawioL3DependantNodeFootprint -Group $nodeGroup -MaxNames $maxNames
    }
    foreach ($hub in $shownGateways) {
        $key = "external:$($hub.Address)"; $gatewayKeyByAddress[[string]$hub.Address] = $key
        $nodeInfo[$key] = [pscustomobject]@{Kind='Gateway';Data=$hub}; $adjacency[$key] = [System.Collections.Generic.List[string]]::new()
        $footprints[$key] = [pscustomobject]@{Width=240;Height=70}
    }

    $wires = [System.Collections.Generic.List[object]]::new()
    $addWire = {
        param([string]$SourceKey,[string]$TargetKey,$Protocols,[int]$Count,[bool]$HasDefault,[string]$Label)
        if (-not $SourceKey -or -not $TargetKey -or $SourceKey -eq $TargetKey) { return }
        $wires.Add([pscustomobject]@{SourceKey=$SourceKey;TargetKey=$TargetKey;Protocols=@($Protocols);Count=$Count;HasDefault=$HasDefault;Label=$Label})
        $adjacency[$SourceKey].Add($TargetKey); $adjacency[$TargetKey].Add($SourceKey)
    }
    foreach ($entry in $shownIndividual) {
        $sourceKey = $individualKeyByHost[[string]$entry.HostName]
        foreach ($routeGroup in @($entry.GatewayRoutes)) {
            $gateway = [string]$routeGroup.Gateway; $targetKey = $null
            if ($gatewayIndex.ContainsKey($gateway)) { $targetKey = $individualKeyByHost[[string]$gatewayIndex[$gateway]] }
            else { $targetKey = $gatewayKeyByAddress[$gateway] }
            & $addWire $sourceKey $targetKey $routeGroup.Protocols $routeGroup.Count ([bool]$routeGroup.HasDefault) $null
        }
    }
    foreach ($group in $shownGroups) {
        $sourceKey = $groupKeyByGateway[[string]$group.Gateway]; $gateway = [string]$group.Gateway; $targetKey = $null
        if ($gatewayIndex.ContainsKey($gateway)) { $targetKey = $individualKeyByHost[[string]$gatewayIndex[$gateway]] }
        else { $targetKey = $gatewayKeyByAddress[$gateway] }
        $hasDefault = [bool](@($group.DestinationSubnets | Where-Object { $_ -match '^0\.0\.0\.0' }).Count -gt 0)
        & $addWire $sourceKey $targetKey $group.Protocols $group.DeviceCount $hasDefault "$($group.DeviceCount) devices"
    }

    $centerCandidates = foreach ($key in @($nodeInfo.Keys | Sort-Object)) {
        $info = $nodeInfo[$key]
        if ($info.Kind -eq 'Individual') {
            $hostName = [string]$info.Data.HostName; $roleNode = if($roleByHost.ContainsKey($hostName)){$roleByHost[$hostName]}else{$null}
            [pscustomobject]@{Key=$key;IsConfigured=$true;HostName=$hostName;Role=$(if($roleNode){$roleNode.Role}else{'Gateway'});IsSecurity=[bool]($roleNode -and $roleNode.IsSecurity)}
        }
        else { [pscustomobject]@{Key=$key;IsConfigured=$false;HostName=$null;Role='Other';IsSecurity=$false} }
    }
    $preferred = @(Get-MTAutoDrawL3PreferredCenters -Nodes @($centerCandidates) -Edges @($wires))
    $layout = Get-DrawioRadialPlacement -Adjacency $adjacency -Keys @($nodeInfo.Keys) -FootprintOf $footprints `
        -StartX 100 -StartY 100 -NodeGap 65 -RingGap 65 -AspectRatio 1.8 -ClusterGap 140 `
        -Sweeps 4 -MaxStagger 3 -RingSpacing Exact -ClusterPacking Corner `
        -MaxRowWidth $GDrawioOverviewMaxWidth -PreferredCenters $preferred

    $shapeId = @{}
    foreach ($key in @($nodeInfo.Keys | Sort-Object)) {
        $info = $nodeInfo[$key]; $location = $layout.Positions[$key]
        switch ($info.Kind) {
            'Individual' {
                $entry=$info.Data; $cls=$classified[[string]$entry.HostName]
                if (-not $cls) { $cls=[pscustomobject]@{Tier='Access';IsSecurity=$false;IsRootBridge=$false;Degree=0} }
                $shape=Add-DrawioTopologyNode -Device $entry.Device -Location $location -Tier $cls.Tier -IsSecurity $cls.IsSecurity -IsRootBridge $cls.IsRootBridge -Degree $cls.Degree
            }
            'Group' { $shape=Add-DrawioL3DependantNode -Group $info.NodeGroup -Location $location -MaxNames $maxNames }
            'Gateway' { $shape=Add-DrawioL3HubNode -Hub $info.Data -Location $location }
        }
        $shapeId[$key]=$shape.Id
    }

    $labelPositions=@(-0.45,0.0,0.45,-0.2,0.2); $labelIndexBySource=@{}
    foreach ($wire in $wires) {
        $protocols=if(@($wire.Protocols).Count -gt 0){@($wire.Protocols)-join '/'}else{'route'}
        $label=if($wire.Label){"$protocols x$($wire.Label)"}else{"$protocols x$($wire.Count)"}
        $color=Get-MTAutoDrawRouteProtocolColor -Protocol (@($wire.Protocols)|Select-Object -First 1)
        $style="edgeStyle=none;rounded=0;endArrow=block;html=1;strokeWidth=2;strokeColor=$color;endSize=6;labelBackgroundColor=#FFFFFF;"
        if(-not $wire.HasDefault){$style+='dashed=1;'}
        $index=if($labelIndexBySource.ContainsKey($wire.SourceKey)){$labelIndexBySource[$wire.SourceKey]}else{0};$labelIndexBySource[$wire.SourceKey]=$index+1
        $null=Add-DrawioConnector -SourceId $shapeId[$wire.SourceKey] -TargetId $shapeId[$wire.TargetKey] -Text $label -Style $style -LabelPosition $labelPositions[$index % $labelPositions.Count]
    }

    $bottom=100
    foreach($key in $nodeInfo.Keys){$bottom=[Math]::Max($bottom,$layout.Positions[$key].Y+$footprints[$key].Height)}
    foreach($overflow in @(
        [pscustomobject]@{Items=$overflowIndividual;Title='other routing devices';Detail='busiest-first; full list in Objects.json';Names=@($overflowIndividual.HostName)}
        [pscustomobject]@{Items=$overflowGateways;Title='other external next hops';Detail='fewer dependants each';Names=@($overflowGateways.Address)}
        [pscustomobject]@{Items=$overflowGroups;Title='other next-hop groups';Detail='busiest-first; full list in Objects.json';Names=@($overflowGroups.Gateway)}
    )) {
        if(@($overflow.Items).Count -eq 0){continue}
        $dims=Add-DrawioOverflowSummaryCard -TitleText "+$(@($overflow.Items).Count) $($overflow.Title)" -DetailLine $overflow.Detail -Names @($overflow.Names) -Location ([pscustomobject]@{X=100;Y=$bottom+45})
        $bottom += 45 + $dims.Height
    }
    if(@($model.Unrouted).Count -gt 0){
        $dims=Add-DrawioOverflowSummaryCard -TitleText "$(@($model.Unrouted).Count) devices with no routed dependency" -DetailLine 'directly-connected routes only' -Names @($model.Unrouted) -Location ([pscustomobject]@{X=100;Y=$bottom+45})
        $bottom += 45 + $dims.Height
    }
    $legend=Add-DrawioRoutesSummaryLegend -Location ([pscustomobject]@{X=100;Y=$bottom+45});$bottom += 45 + $legend.Height
    $null=Add-DrawioOverviewFooterNote -Location ([pscustomobject]@{X=100;Y=$bottom+25}) `
        -Message 'Layer 3 routes summary. Captured Border/firewall devices center the page first, followed by Transit and Gateway roles; visible relationship count breaks ties. Arrows run from the device or group using a route to the captured or external next hop. Full per-route detail: Layer 3 Routes Only or Objects.json.'
}

function Draw-Layer3RoutesSummaryDiagram {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)] $ArrayOfObjects,
        [parameter(Mandatory = $false)] $ArrayofGatewayHosts
    )

    Write-MTAutoDrawPhase -Phase Draw -Message "Starting Draw-Layer3RoutesSummaryDiagram..."
    Start-DrawioDiagram -Name "Layer 3 Routes Summary"

    Add-MTAutoDrawL3RoutesSummaryRadialContent -ArrayOfObjects $ArrayOfObjects -ArrayofGatewayHosts $ArrayofGatewayHosts
    End-DrawioDiagram
    Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Layer 3 Routes Summary diagram page has been created."
    return

    $model = Get-MTAutoDrawL3RoutesSummaryModel -Devices $ArrayOfObjects

    if (@($model.Individual).Count -eq 0 -and @($model.StaticGroups).Count -eq 0) {
        $detail = if (@($model.Unrouted).Count -gt 0) {
            "All $(@($model.Unrouted).Count) devices carry only directly-connected routes."
        } else { "No routing tables were parsed for this run." }
        $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = 100; Y = 100}) `
            -Message "No routing dependencies were found for the summary page. $detail"
        End-DrawioDiagram
        Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Layer 3 Routes Summary diagram page has been created (no routed dependencies)."
        return
    }

    $securityDeviceTypes = Get-MTAutoDrawSecurityDeviceTypes
    $gatewayIndex = New-MTAutoDrawGatewayIndex -Devices $ArrayOfObjects

    # Map every gateway-host IP to the gateway-host object (ARP-discovered / unresolved next-hop
    # placeholder devices). Band 2 draws these as its cards, and the edge-drawing phase below uses
    # this map to route "device → external next hop" edges to the right Band 2 shape.
    $gatewayHostByIp = @{}
    foreach ($gwHost in @($ArrayofGatewayHosts | Where-Object { $_ })) {
        foreach ($ip in @($gwHost.arrayofipaddresses | Where-Object { $_ })) {
            $ip = [string]$ip
            if ($ip -and -not $gatewayHostByIp.ContainsKey($ip)) { $gatewayHostByIp[$ip] = $gwHost }
        }
    }

    # --- Classify each device for Band 1 styling (same heuristic as Draw-SiteTopologyOverviewDiagram). ---
    $classified = @{}
    foreach ($device in $ArrayOfObjects) {
        if (-not $device.hostname) { continue }
        $degree = 0
        foreach ($neighbor in (@($device.CDPNeighbors) + @($device.LLDPNeighbors))) {
            if ($neighbor.TargetHostname -and -not $neighbor.Ignored -and $neighbor.TargetHostname -ine $device.hostname) {
                $degree++
            }
        }
        $isSecurity = [bool](($device.DeviceType -and $device.DeviceType -in $securityDeviceTypes) -or
            (@($device.interfaces | Where-Object { $_.Zone }).Count -gt 0))
        $isRootBridge = [bool]($device.SpanningTree -and @($device.SpanningTree.RootBridgeForVlans).Count -gt 0)
        $tier = if ($degree -ge $GDrawioTopologyCoreDegreeThreshold) { 'Core' }
            elseif ($degree -ge $GDrawioTopologyDistDegreeThreshold) { 'Distribution' }
            else { 'Access' }
        $classified[$device.hostname] = [pscustomobject]@{
            Tier = $tier; IsSecurity = $isSecurity; IsRootBridge = $isRootBridge; Degree = $degree
        }
    }

    # --- Band 2 data: distinct EXTERNAL next-hops (resolve to no captured device) and how many
    # devices depend on each. These are the ARP-resolved / unresolved gateway placeholder devices.
    # When the pipeline produced a gateway-host object for the IP, carry its identity (vendor + MAC,
    # or "Unknown") onto the hub so the card can show WHO the next hop is, not just its address. ---
    $externalGateways = @{}
    foreach ($g in $model.StaticGroups) {
        if ($g.Gateway -and -not $gatewayIndex.ContainsKey([string]$g.Gateway)) {
            if (-not $externalGateways.ContainsKey([string]$g.Gateway)) { $externalGateways[[string]$g.Gateway] = 0 }
            $externalGateways[[string]$g.Gateway] += $g.DeviceCount
        }
    }
    foreach ($entry in $model.Individual) {
        foreach ($gr in @($entry.GatewayRoutes)) {
            if ($gr.Gateway -and -not $gatewayIndex.ContainsKey([string]$gr.Gateway)) {
                if (-not $externalGateways.ContainsKey([string]$gr.Gateway)) { $externalGateways[[string]$gr.Gateway] = 0 }
                $externalGateways[[string]$gr.Gateway] += 1
            }
        }
    }
    $gatewayHubs = @($externalGateways.GetEnumerator() | ForEach-Object {
        $ip = [string]$_.Key
        # Add-DrawioL3HubNode renders $Hub.DeviceName as the bold line when IsConfigured is $true.
        # These are NOT captured/configured devices, so keep IsConfigured $false (orange/dashed "not
        # captured" styling) while still surfacing the ARP-resolved identity on the second line.
        $gwHost = if ($gatewayHostByIp.ContainsKey($ip)) { $gatewayHostByIp[$ip] } else { $null }
        [pscustomobject]@{
            Address = $ip
            DeviceName = if ($gwHost -and $gwHost.hostname) { ([string]$gwHost.hostname).Trim() } else { $null }
            IsConfigured = $false
            DependantCount = $_.Value
        }
    } | Sort-Object @{ Expression = { -1 * $_.DependantCount } }, Address)

    # --- Caps (busiest-first, so a cap keeps the next hops/devices that describe the most of the network). ---
    $indCap   = if ($GDrawioRoutesSummaryMaxIndividualDevices -gt 0) { [int]$GDrawioRoutesSummaryMaxIndividualDevices } else { 12 }
    $gwCap    = if ($GDrawioRoutesSummaryMaxGateways -gt 0) { [int]$GDrawioRoutesSummaryMaxGateways } else { 8 }
    $grpCap   = if ($GDrawioRoutesSummaryMaxGroups -gt 0) { [int]$GDrawioRoutesSummaryMaxGroups } else { 8 }
    $maxNames = if ($GDrawioRoutesSummaryMaxNamesPerGroup -gt 0) { [int]$GDrawioRoutesSummaryMaxNamesPerGroup } else { 6 }

    $shownIndividual = @($model.Individual | Select-Object -First $indCap)
    $overflowIndividual = @($model.Individual | Select-Object -Skip $indCap)
    $shownGateways = @($gatewayHubs | Select-Object -First $gwCap)
    $overflowGateways = @($gatewayHubs | Select-Object -Skip $gwCap)
    $shownGroups = @($model.StaticGroups | Select-Object -First $grpCap)
    $overflowGroups = @($model.StaticGroups | Select-Object -Skip $grpCap)

    $layoutGap = 90

    # =====================================================================
    # Primary cluster - the devices the rest of the network points at.
    # =====================================================================
    # "Core" tier already means "at/above the core-degree threshold" (see the classification loop
    # above) - that is exactly what a primary/hub device is, so no separate heuristic is needed.
    $primaryEntries = @($shownIndividual | Where-Object {
        $classified.ContainsKey($_.HostName) -and $classified[$_.HostName].Tier -eq 'Core'
    })
    if ($primaryEntries.Count -eq 0 -and $shownIndividual.Count -gt 0) {
        # No device reached the Core threshold (a small/flat site) - the single best-connected
        # device still anchors the layout, so fall back to it by degree.
        $primaryEntries = @($shownIndividual | Sort-Object @{ Expression = {
            if ($classified.ContainsKey($_.HostName)) { -1 * $classified[$_.HostName].Degree } else { 0 }
        } } | Select-Object -First 1)
    }
    $primaryHostNames = [System.Collections.Generic.HashSet[string]]::new([string[]]@($primaryEntries | ForEach-Object { [string]$_.HostName }), [System.StringComparer]::OrdinalIgnoreCase)
    $ringIndividual = @($shownIndividual | Where-Object { -not $primaryHostNames.Contains([string]$_.HostName) })

    # =====================================================================
    # The ring - every other individual device, external next hop, and single-static group,
    # placed once around the primary cluster instead of three separate stacked bands.
    # =====================================================================
    $ringItems = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $ringIndividual) { $ringItems.Add([pscustomobject]@{ Kind = 'Individual'; Data = $entry }) }
    foreach ($group in $shownGroups) { $ringItems.Add([pscustomobject]@{ Kind = 'Group'; Data = $group }) }
    foreach ($hub in $shownGateways) { $ringItems.Add([pscustomobject]@{ Kind = 'Gateway'; Data = $hub }) }

    # Items whose route actually resolves to a primary device sort first (stable on their original
    # busiest-first order otherwise), so their spokes land near each other instead of scattering
    # around the far side of the ring. External next hops never resolve to a captured device by
    # construction, so they can never score as "points at primary".
    for ($idx = 0; $idx -lt $ringItems.Count; $idx++) {
        $item = $ringItems[$idx]
        $item | Add-Member -NotePropertyName OriginalIndex -NotePropertyValue $idx
        $pointsAtPrimary = $false
        if ($item.Kind -eq 'Individual') {
            foreach ($gr in @($item.Data.GatewayRoutes)) {
                if ($gr.Gateway -and $gatewayIndex.ContainsKey([string]$gr.Gateway) -and $primaryHostNames.Contains([string]$gatewayIndex[[string]$gr.Gateway])) {
                    $pointsAtPrimary = $true
                    break
                }
            }
        }
        elseif ($item.Kind -eq 'Group') {
            if ($item.Data.Gateway -and $gatewayIndex.ContainsKey([string]$item.Data.Gateway) -and $primaryHostNames.Contains([string]$gatewayIndex[[string]$item.Data.Gateway])) {
                $pointsAtPrimary = $true
            }
        }
        $item | Add-Member -NotePropertyName Score -NotePropertyValue $(if ($pointsAtPrimary) { 0 } else { 1 })
    }
    $orderedRingItems = @($ringItems | Sort-Object Score, OriginalIndex)

    # Radius is sized off a conservative (largest-case) ring-item footprint, covering the largest
    # of Add-DrawioTopologyNode/Add-DrawioL3HubNode/Add-DrawioL3DependantNode, and off the primary
    # cluster's own height so a multi-device cluster never pokes outside the ring. The whole layout
    # is then shifted so its top-left corner sits at the page's usual (100, 100) margin - see
    # Get-DrawioRadialPositions.
    $ringItemWidth = 260
    $ringItemHeight = 150
    $primaryClusterHeight = if ($primaryEntries.Count -gt 0) { ($primaryEntries.Count * 70) + ([Math]::Max(0, $primaryEntries.Count - 1) * 20) } else { 0 }
    $minRingRadius = [Math]::Max(320, ($primaryClusterHeight / 2) + 180)
    $margin = 100
    $ringProbe = Get-DrawioRadialPositions -CenterX 0 -CenterY 0 -Count $orderedRingItems.Count `
        -ItemWidth $ringItemWidth -ItemHeight $ringItemHeight -Padding 50 -MinRadius $minRingRadius
    $centerX = $margin - $ringProbe.Bounds.Left
    $centerY = $margin - $ringProbe.Bounds.Top
    $ring = Get-DrawioRadialPositions -CenterX $centerX -CenterY $centerY -Count $orderedRingItems.Count `
        -ItemWidth $ringItemWidth -ItemHeight $ringItemHeight -Padding 50 -MinRadius $minRingRadius

    $band1IdByHost = @{}
    $band2IdByAddress = @{}
    $band3IdByGateway = @{}

    # One primary device centers the ring directly; more than one stack in a tight vertical
    # cluster whose midpoint is the ring's center, so it still reads as one hub.
    $primaryTop = $centerY - ($primaryClusterHeight / 2)
    for ($i = 0; $i -lt $primaryEntries.Count; $i++) {
        $entry = $primaryEntries[$i]
        $device = $entry.Device
        $cls = if ($classified.ContainsKey($entry.HostName)) { $classified[$entry.HostName] }
        else { [pscustomobject]@{ Tier = 'Core'; IsSecurity = $false; IsRootBridge = $false; Degree = 0 } }
        $y = $primaryTop + ($i * 90)
        $null = Add-DrawioTopologyNode -Device $device -Location ([PSCustomObject]@{X = [Math]::Round($centerX - ($GDrawioOverviewNodeWidth / 2)); Y = [Math]::Round($y)}) `
            -Tier $cls.Tier -IsSecurity $cls.IsSecurity -IsRootBridge $cls.IsRootBridge -Degree $cls.Degree
        if ($device.RoutesSummaryDrawioId) { $band1IdByHost[[string]$entry.HostName] = $device.RoutesSummaryDrawioId }
    }
    $primaryBottom = if ($primaryEntries.Count -gt 0) { $primaryTop + $primaryClusterHeight } else { $centerY }

    for ($i = 0; $i -lt $orderedRingItems.Count; $i++) {
        $item = $orderedRingItems[$i]
        $pos = $ring.Positions[$i]
        switch ($item.Kind) {
            'Individual' {
                $entry = $item.Data
                $device = $entry.Device
                $cls = if ($classified.ContainsKey($entry.HostName)) { $classified[$entry.HostName] }
                else { [pscustomobject]@{ Tier = 'Access'; IsSecurity = $false; IsRootBridge = $false; Degree = 0 } }
                $dimensions = Add-DrawioTopologyNode -Device $device -Location ([PSCustomObject]@{X = $pos.X; Y = $pos.Y}) `
                    -Tier $cls.Tier -IsSecurity $cls.IsSecurity -IsRootBridge $cls.IsRootBridge -Degree $cls.Degree
                if ($device.RoutesSummaryDrawioId) { $band1IdByHost[[string]$entry.HostName] = $device.RoutesSummaryDrawioId }
            }
            'Group' {
                $group = $item.Data
                # Add-DrawioL3DependantNode reads Group.Devices / RouteCount / HasDefaultRoute / Protocols.
                $nodeGroup = [pscustomobject]@{
                    Devices = @($group.Devices)
                    RouteCount = $group.DeviceCount
                    HasDefaultRoute = [bool](@($group.DestinationSubnets | Where-Object { $_ -match '^0\.0\.0\.0' }).Count -gt 0)
                    Protocols = @($group.Protocols)
                }
                $node = Add-DrawioL3DependantNode -Group $nodeGroup -Location ([PSCustomObject]@{X = $pos.X; Y = $pos.Y}) -MaxNames $maxNames
                $band3IdByGateway[[string]$group.Gateway] = $node.Id
            }
            'Gateway' {
                $hub = $item.Data
                $node = Add-DrawioL3HubNode -Hub $hub -Location ([PSCustomObject]@{X = $pos.X; Y = $pos.Y})
                $band2IdByAddress[[string]$hub.Address] = $node.Id
            }
        }
    }

    $overflowX = $ring.Bounds.Left
    $bottom = [Math]::Max($ring.Bounds.Bottom, $primaryBottom)
    if ($overflowIndividual.Count -gt 0) {
        $dims = Add-DrawioOverflowSummaryCard -TitleText "+$($overflowIndividual.Count) other routing devices" `
            -DetailLine "busiest-first; full list in Objects.json" `
            -Names (@($overflowIndividual | ForEach-Object { $_.HostName })) `
            -Location ([PSCustomObject]@{X = $overflowX; Y = ($bottom + 40)})
        $bottom = $bottom + 40 + $dims.Height
    }
    if ($overflowGateways.Count -gt 0) {
        $dims = Add-DrawioOverflowSummaryCard -TitleText "+$($overflowGateways.Count) other external next hops" `
            -DetailLine "fewer dependants each" `
            -Names (@($overflowGateways | ForEach-Object { [string]$_.Address })) `
            -Location ([PSCustomObject]@{X = $overflowX; Y = ($bottom + 40)})
        $bottom = $bottom + 40 + $dims.Height
    }
    if ($overflowGroups.Count -gt 0) {
        $dims = Add-DrawioOverflowSummaryCard -TitleText "+$($overflowGroups.Count) other next-hop groups" `
            -DetailLine "busiest-first; full list in Objects.json" `
            -Names (@($overflowGroups | ForEach-Object { [string]$_.Gateway })) `
            -Location ([PSCustomObject]@{X = $overflowX; Y = ($bottom + 40)})
        $bottom = $bottom + 40 + $dims.Height
    }

    # =====================================================================
    # Routing edges (device-level, colored by protocol) - drawn after all three bands exist, so
    # every endpoint is a shape registered on this page. Two targets are supported:
    #   * a next hop that resolves to a captured device -> the other device's Band 1 card;
    #   * a next hop that resolves to no captured device -> its Band 2 external-gateway card.
    # A next hop that is itself a single-static device is already inside its Band 3 box, so it is
    # not also given a stray edge to a non-device shape (that would double-represent it).
    # =====================================================================
    foreach ($entry in $shownIndividual) {
        $sourceId = $band1IdByHost[[string]$entry.HostName]
        if (-not $sourceId) { continue }
        foreach ($gr in @($entry.GatewayRoutes)) {
            if (-not $gr.Gateway) { continue }
            $gwKey = [string]$gr.Gateway
            $targetId = $null
            if ($gatewayIndex.ContainsKey($gwKey)) {
                # Resolves to a captured device: link to its Band 1 card (if that card was drawn).
                $targetHostName = $gatewayIndex[$gwKey]
                $targetId = $band1IdByHost[[string]$targetHostName]
                if (-not $targetId) { $targetId = $null }
            }
            else {
                # External next hop: link to its Band 2 card (if that card was drawn within the cap).
                $targetId = $band2IdByAddress[[string]$gwKey]
            }
            if (-not $targetId -or $targetId -eq $sourceId) { continue }
            $protocols = if (@($gr.Protocols).Count -gt 0) { (@($gr.Protocols) -join '/') } else { 'route' }
            $label = "$protocols x$($gr.Count)"
            $color = Get-MTAutoDrawRouteProtocolColor -Protocol (@($gr.Protocols) | Select-Object -First 1)
            # A route that is NOT the default route is a specific handoff (dashed), matching the
            # convention the detailed page uses; the default route is solid.
            $edgeStyle = "endArrow=block;html=1;strokeWidth=2;strokeColor=$color;endSize=6;"
            if (-not $gr.HasDefault) { $edgeStyle += "dashed=1;" }
            $null = Add-DrawioConnector -SourceId $sourceId -TargetId $targetId -Text $label -Style $edgeStyle
        }
    }

    # --- Band 3 group -> gateway edges. This is the single-static "who points where": each group
    # (devices sharing one next hop) links to the shape that IS that next hop - a Band 1 device if
    # the gateway resolves to a captured device, else the Band 2 external card. Mirrors the
    # group->hub edges on the Layer 3 Connectivity page. A gateway past the display cap still has
    # a real dependency; it simply has no edge target to draw to, exactly as the connectivity page.
    # ------------------------------------------------------------------
    foreach ($group in $shownGroups) {
        $sourceId = $band3IdByGateway[[string]$group.Gateway]
        if (-not $sourceId) { continue }
        $gwKey = [string]$group.Gateway
        $targetId = $null
        if ($gatewayIndex.ContainsKey($gwKey)) {
            $targetHostName = $gatewayIndex[$gwKey]
            $targetId = $band1IdByHost[[string]$targetHostName]
        }
        else {
            $targetId = $band2IdByAddress[[string]$gwKey]
        }
        if (-not $targetId -or $targetId -eq $sourceId) { continue }
        $protocols = if (@($group.Protocols).Count -gt 0) { (@($group.Protocols) -join '/') } else { 'route' }
        $label = "$protocols x$($group.DeviceCount) devices"
        $color = Get-MTAutoDrawRouteProtocolColor -Protocol (@($group.Protocols) | Select-Object -First 1)
        $hasDefault = [bool](@($group.DestinationSubnets | Where-Object { $_ -match '^0\.0\.0\.0' }).Count -gt 0)
        $edgeStyle = "endArrow=block;html=1;strokeWidth=2;strokeColor=$color;endSize=6;"
        if (-not $hasDefault) { $edgeStyle += "dashed=1;" }
        $null = Add-DrawioConnector -SourceId $sourceId -TargetId $targetId -Text $label -Style $edgeStyle
    }

    # =====================================================================
    # Footer - Unrouted bucket (one card, not one node per device), legend, then the footer note.
    # =====================================================================
    $footerY = $bottom + $layoutGap
    if (@($model.Unrouted).Count -gt 0) {
        $dims = Add-DrawioOverflowSummaryCard -TitleText "$(@($model.Unrouted).Count) devices with no routed dependency" `
            -DetailLine "directly-connected routes only" -Names @($model.Unrouted) `
            -Location ([PSCustomObject]@{X = $overflowX; Y = $footerY})
        $footerY = $footerY + $dims.Height + 40
    }

    $legend = Add-DrawioRoutesSummaryLegend -Location ([PSCustomObject]@{X = $overflowX; Y = $footerY})
    $footerY = $footerY + $legend.Height + 25

    $indNote = if ($overflowIndividual.Count -gt 0) { " Top $indCap of $(@($model.Individual).Count) individual devices shown." } else { "" }
    $gwNote  = if ($overflowGateways.Count -gt 0) { " Top $gwCap of $(@($gatewayHubs).Count) external next hops shown." } else { "" }
    $grpNote = if ($overflowGroups.Count -gt 0) { " Top $grpCap of $(@($model.StaticGroups).Count) next-hop groups shown." } else { "" }
    $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = $overflowX; Y = $footerY}) `
        -Message "Layer 3 routes summary - the busiest device(s) centered, everything else arranged around them. One node per individual routing device, one box per shared next hop for single-static devices, one card per external next hop.$indNote$gwNote$grpNote Full per-route detail: the Layer 3 Routes Only page or Objects.json."

    End-DrawioDiagram
    Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Layer 3 Routes Summary diagram page has been created."
}

#-----------------------------------------------------------------------------------------
# Main Function: Draw-FirewallOverviewDiagram
#-----------------------------------------------------------------------------------------
# One page per firewall: the segmentation shape of the device and nothing else. Zones radiate off the
# firewall, each showing only how many interfaces it holds - no subnets, no rules, no addresses. That
# restraint is the point: this is the page you open to see what the firewall separates, before
# deciding which of the detail pages to open next.
#
# Subnets appear only when the whole device has few enough that they cannot crowd the page
# ($GDrawioFirewallOverviewSubnetLimit), which is the "unless it's a handful and fits easily" case.
function Draw-FirewallOverviewDiagram {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $Device
    )

    $view = Get-MTAutoDrawFirewallInterfaceModel -Device $Device
    Write-MTAutoDrawPhase -Phase Draw -Message "Starting Firewall Overview for $($Device.HostName)..."
    Start-DrawioDiagram -Name "FW Overview - $($Device.HostName)"

    $subnetLimit = if ($GDrawioFirewallOverviewSubnetLimit -ge 0) { [int]$GDrawioFirewallOverviewSubnetLimit } else { 4 }
    $showSubnets = ($view.IpInterfaces.Count -le $subnetLimit)

    if ($view.ZoneGroups.Count -eq 0) {
        $fwNode = Add-DrawioFirewallNode -Device $Device -Stats $view.Stats -Location ([PSCustomObject]@{X = 100; Y = 100})
        $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = 100; Y = ($fwNode.Height + 160)}) `
            -Message "No zone or nameif data was parsed for this device, so there is nothing to segment by. Interface detail: the FW NAT & Interfaces page, interfaces.csv, or the per-device Singles pages."
        End-DrawioDiagram
        Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Firewall Overview page created for $($Device.HostName) (no zone data)."
        return
    }

    $shownZones = $view.AllZonesShown
    $overflowZones = $view.AllZonesOverflow
    $orderedZones = $view.AllZonesOrdered

    # --- Circular layout: firewall centered, zones evenly spaced around it so every spoke is a
    # straight line. Radius is sized off a conservative (largest-case) zone box footprint - see
    # Get-DrawioRadialPositions - then the whole circle is shifted so its top-left corner sits at
    # the page's usual (100, 100) margin. ---
    $zoneItemWidth = if ($showSubnets) { 260 } else { 220 }
    $zoneItemHeight = if ($showSubnets) { 150 } else { 80 }
    $probe = Get-DrawioRadialPositions -CenterX 0 -CenterY 0 -Count $orderedZones.Count `
        -ItemWidth $zoneItemWidth -ItemHeight $zoneItemHeight -Padding 40 -MinRadius 280
    $margin = 100
    $centerX = $margin - $probe.Bounds.Left
    $centerY = $margin - $probe.Bounds.Top
    $radial = Get-DrawioRadialPositions -CenterX $centerX -CenterY $centerY -Count $orderedZones.Count `
        -ItemWidth $zoneItemWidth -ItemHeight $zoneItemHeight -Padding 40 -MinRadius 280

    $fwEstWidth = 300
    $fwEstHeight = 104
    $fwNode = Add-DrawioFirewallNode -Device $Device -Stats $view.Stats `
        -Location ([PSCustomObject]@{X = [Math]::Round($centerX - $fwEstWidth / 2); Y = [Math]::Round($centerY - $fwEstHeight / 2)})

    for ($zoneIndex = 0; $zoneIndex -lt $orderedZones.Count; $zoneIndex++) {
        $zoneGroup = $orderedZones[$zoneIndex]
        $pos = $radial.Positions[$zoneIndex]
        $node = Add-DrawioFirewallZoneNode -ZoneName $zoneGroup.Name -Interfaces @($zoneGroup.Group) `
            -Location ([PSCustomObject]@{X = $pos.X; Y = $pos.Y}) -ShowSubnets $showSubnets `
            -MaxInterfaces $(if ($GDrawioFirewallMaxInterfacesPerZone -gt 0) { [int]$GDrawioFirewallMaxInterfacesPerZone } else { 6 })
        if ($fwNode.Id -and $node.Id) {
            $null = Add-DrawioConnector -SourceId $fwNode.Id -TargetId $node.Id -Style "endArrow=none;html=1;strokeWidth=2;strokeColor=$((Get-MTAutoDrawPalette -Scope Firewall).Node.Zone.Stroke);"
        }
    }
    $bottom = $radial.Bounds.Bottom

    if ($overflowZones.Count -gt 0) {
        $names = @($overflowZones | ForEach-Object { "$($_.Name) ($($_.Count))" })
        $dims = Add-DrawioOverflowSummaryCard -TitleText "+$($overflowZones.Count) other zones" `
            -DetailLine "fewer interfaces each" -Names $names -Location ([PSCustomObject]@{X = $radial.Bounds.Left; Y = ($bottom + 40)})
        $bottom = $bottom + 40 + $dims.Height
    }

    if (@($view.ZonelessWithIp).Count -gt 0) {
        $names = @($view.ZonelessWithIp | ForEach-Object { "$($_.Interface) $(if($_.Cidr){$_.Cidr}else{$_.IPAddress})" })
        $dims = Add-DrawioOverflowSummaryCard -TitleText "$(@($view.ZonelessWithIp).Count) addressed interfaces with no zone" `
            -DetailLine "not covered by zone-based policy" -Names $names -Location ([PSCustomObject]@{X = $radial.Bounds.Left; Y = ($bottom + 60)})
        $bottom = $bottom + 60 + $dims.Height
    }

    $zoneLabel = if ($Device.DeviceType -eq 'CiscoASA') { 'nameif values' } else { 'zones' }
    $policyNote = if ($view.Stats.RuleCount -gt 0) { " $($view.Stats.RuleCount) security rules across these $zoneLabel - per-rule detail in Objects.json." } else { " No security policy capture was parsed for this device." }
    $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = $radial.Bounds.Left; Y = $bottom + 60}) `
        -Message "Segmentation overview only - interface counts, no addresses or rules.$policyNote Addresses and NAT: the FW NAT & Interfaces page."

    End-DrawioDiagram
    Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Firewall Overview page created for $($Device.HostName)."
}

#-----------------------------------------------------------------------------------------
# Main Function: Draw-FirewallNatInterfacesDiagram
#-----------------------------------------------------------------------------------------
# One page per firewall: the layer 3 view - every addressed interface grouped under its zone, plus
# what the device translates traffic to on the way out.
#
# NAT is collapsed by translation target rather than listed rule by rule. A typical edge firewall
# points most of the inside at a single public address, so every rule shares one egress interface
# and one translated address; per-rule shapes would be the same fact repeated. The source zones
# feeding each translation are the part that actually varies.
function Draw-FirewallNatInterfacesDiagram {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $Device
    )

    $view = Get-MTAutoDrawFirewallInterfaceModel -Device $Device
    Write-MTAutoDrawPhase -Phase Draw -Message "Starting Firewall NAT & Interfaces for $($Device.HostName)..."
    Start-DrawioDiagram -Name "FW NAT and Interfaces - $($Device.HostName)"

    $maxPerZone = if ($GDrawioFirewallMaxInterfacesPerZone -gt 0) { [int]$GDrawioFirewallMaxInterfacesPerZone } else { 6 }
    $natRules = @($Device.NatPolicy | Where-Object { $_ })
    if (-not $view.HasNat) {
        $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = 100; Y = 100}) `
            -Message "No NAT policy was parsed for $($Device.HostName), so no firewall, interface, or translation icons are drawn. Interface detail remains in interfaces.csv."
        End-DrawioDiagram
        Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Firewall NAT & Interfaces page created for $($Device.HostName) (no NAT relationships)."
        return
    }

    $headingStyle = 'text;html=1;align=center;verticalAlign=middle;fontSize=14;fontStyle=1;resizable=0;points=[];'
    Add-DrawioCell -Id (New-DrawioId -Prefix 'nat-heading') -Value '1. Original source' -Style $headingStyle `
        -Geometry ([pscustomobject]@{X=100;Y=28;Width=300;Height=28})
    Add-DrawioCell -Id (New-DrawioId -Prefix 'nat-heading') -Value '2. Firewall rule match' -Style $headingStyle `
        -Geometry ([pscustomobject]@{X=500;Y=28;Width=300;Height=28})
    Add-DrawioCell -Id (New-DrawioId -Prefix 'nat-heading') -Value '3. Translation result' -Style $headingStyle `
        -Geometry ([pscustomobject]@{X=920;Y=28;Width=300;Height=28})

    $sourcePlaced = [System.Collections.Generic.List[object]]::new()
    $sourceY = 80
    foreach ($source in $view.NatSources) {
        $node = Add-DrawioFirewallZoneNode -ZoneName $source.Name -Interfaces @($source.Interfaces) `
            -Location ([pscustomobject]@{ X = 100; Y = $sourceY }) -ShowSubnets $true -MaxInterfaces $maxPerZone
        $sourcePlaced.Add([pscustomobject]@{ Model = $source; Node = $node })
        $sourceY += $node.Height + 40
    }

    $translationPlaced = [System.Collections.Generic.List[object]]::new()
    $translationY = 80
    foreach ($translation in $view.NatTranslations) {
        $node = Add-DrawioNatTranslationNode -Translation $translation -Location ([pscustomobject]@{ X = 920; Y = $translationY })
        $translationPlaced.Add([pscustomobject]@{ Model = $translation; Node = $node })
        $translationY += $node.Height + 40
    }

    $columnBottom = [Math]::Max($sourceY, $translationY)
    $fwY = [Math]::Max(80, [int](($columnBottom - 100) / 2))
    $fwNode = Add-DrawioFirewallNode -Device $Device -Stats $view.Stats -Location ([pscustomobject]@{ X = 500; Y = $fwY })
    $natColor = (Get-MTAutoDrawPalette -Scope Firewall).Link.Nat.Color
    foreach ($entry in $sourcePlaced) {
        $null = Add-DrawioConnector -SourceId $entry.Node.Id -TargetId $fwNode.Id `
            -Text "$($entry.Model.RuleCount) rule$(if($entry.Model.RuleCount -eq 1){''}else{'s'}) match this source" `
            -Style "edgeStyle=none;rounded=0;endArrow=block;html=1;strokeWidth=2;strokeColor=$natColor;labelBackgroundColor=#FFFFFF;"
    }
    foreach ($entry in $translationPlaced) {
        $null = Add-DrawioConnector -SourceId $fwNode.Id -TargetId $entry.Node.Id `
            -Text "$($entry.Model.RuleCount) rule$(if($entry.Model.RuleCount -eq 1){''}else{'s'}) produce this translation" `
            -Style "edgeStyle=none;rounded=0;endArrow=block;html=1;dashed=1;strokeWidth=2;strokeColor=$natColor;labelBackgroundColor=#FFFFFF;"
    }

    $bottom = [Math]::Max($columnBottom, $fwY + $fwNode.Height)
    $zoneLabel = if ($Device.DeviceType -eq 'CiscoASA') { 'nameif' } else { 'zone' }
    $legendId = New-DrawioId -Prefix 'nat-legend'
    $surface = (Get-MTAutoDrawPalette -Scope Shared).Surface.Muted
    Add-DrawioCell -Id $legendId -Value "<b>Read left to right</b><br>Solid arrow: source $zoneLabel/interface named by the NAT rule &#8594; firewall rule match<br>Dashed arrow: matched rule &#8594; translated address, mode and/or egress interface" `
        -Style "rounded=1;whiteSpace=wrap;html=1;fillColor=$($surface.Fill);strokeColor=$($surface.Stroke);fontSize=10;align=left;verticalAlign=top;spacingLeft=8;spacingTop=6;" `
        -Geometry ([pscustomobject]@{X=100;Y=$bottom+45;Width=820;Height=78})
    $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = 100; Y = $bottom + 145}) `
        -Message "$($natRules.Count) NAT rules are shown as processing relationships, not packet-return direction: traffic originates in the source $zoneLabel/interface, the counted rules match on $($Device.HostName), and those rules produce the displayed translation. Unrelated addressed interfaces are omitted. Per-interface and per-rule detail: interfaces.csv and Objects.json."

    End-DrawioDiagram
    Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Firewall NAT & Interfaces page created for $($Device.HostName)."
}

#-----------------------------------------------------------------------------------------
# Main Function: Draw-FirewallZoneHubDiagram
#-----------------------------------------------------------------------------------------
# One page per firewall: the firewall in the middle, its zones around it, and how much policy governs
# each one. This is the rules-aware sibling of the FW Overview page - Overview deliberately shows no
# rules at all, because its job is the segmentation shape before you know anything about policy. This
# page answers the next question: which of those segments is actually governed, and how heavily.
#
# Zones sit in two columns with untrusted-looking ones on the left, so the edge of the network reads
# left to right across the firewall. Rule counts ride on the spokes rather than inside the zone boxes,
# which keeps Add-DrawioFirewallZoneNode shared with the other two firewall pages unchanged and keeps
# the zone box about the zone.
#
# Vendor caveat, stated on the page because it changes what the numbers mean: on ASA a zone's count is
# the rules bound inbound to that nameif and there is no destination zone at all, so these are
# per-zone totals rather than zone-pair totals on every vendor - that is exactly why the model exposes
# ZoneTotals separately from Pairs.
function Draw-FirewallZoneHubDiagram {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $Device
    )

    $view = Get-MTAutoDrawFirewallInterfaceModel -Device $Device
    $policy = Get-MTAutoDrawZonePolicyModel -Device $Device
    Write-MTAutoDrawPhase -Phase Draw -Message "Starting Firewall Zone Hub for $($Device.HostName)..."
    Start-DrawioDiagram -Name "FW Zone Hub - $($Device.HostName)"

    if ($view.ZoneGroups.Count -eq 0) {
        $null = Add-DrawioFirewallNode -Device $Device -Stats $view.Stats -Location ([PSCustomObject]@{X = 100; Y = 100})
        $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = 100; Y = 320}) `
            -Message "No zone or nameif data was parsed for this device, so there are no segments to hang policy off. Interface detail: the FW NAT & Interfaces page or interfaces.csv."
        End-DrawioDiagram
        Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Firewall Zone Hub page created for $($Device.HostName) (no zone data)."
        return
    }

    $zoneCap = if ($GDrawioFirewallMaxZones -gt 0) { [int]$GDrawioFirewallMaxZones } else { 14 }
    $shownZones = @($view.ZoneGroups | Select-Object -First $zoneCap)
    $overflowZones = @($view.ZoneGroups | Select-Object -Skip $zoneCap)

    # Untrusted first, then busiest, so the left column fills with the edge of the network.
    $orderedZones = @($shownZones | Sort-Object `
        @{ Expression = { if (Test-MTAutoDrawUntrustedZoneName -ZoneName $_.Name) { 0 } else { 1 } } }, `
        @{ Expression = { -1 * $_.Count } }, Name)

    # Split into two columns, untrusted-heavy side first. Odd counts put the extra row on the left.
    $rowCount = [Math]::Ceiling($orderedZones.Count / 2.0)
    $leftZones = @($orderedZones | Select-Object -First $rowCount)
    $rightZones = @($orderedZones | Select-Object -Skip $rowCount)

    # Interfaces shown per zone shrink as the column gets taller. The page budget is a fixed height,
    # so more zones has to mean less detail each - growing the canvas instead is what these pages
    # exist not to do. The full interface list is one page away on FW NAT & Interfaces.
    $maxPerZone = if ($rowCount -le 4) { 5 } elseif ($rowCount -le 6) { 3 } else { 1 }
    if ($GDrawioFirewallMaxInterfacesPerZone -gt 0 -and $maxPerZone -gt [int]$GDrawioFirewallMaxInterfacesPerZone) {
        $maxPerZone = [int]$GDrawioFirewallMaxInterfacesPerZone
    }

    $leftX = 100
    $centreX = 480
    $rightX = 940
    $topY = 60
    $verticalPadding = 30

    # Draw both columns first, remembering each node so the spokes can be attached once the firewall
    # exists. Heights are whatever the shapes turned out to be - never pre-measured.
    $drawColumn = {
        param([object[]]$Zones, [int]$ColumnX)
        $placed = [System.Collections.Generic.List[object]]::new()
        $y = $topY
        foreach ($zoneGroup in $Zones) {
            $node = Add-DrawioFirewallZoneNode -ZoneName $zoneGroup.Name -Interfaces @($zoneGroup.Group) `
                -Location ([PSCustomObject]@{X = $ColumnX; Y = $y}) -ShowSubnets $true -MaxInterfaces $maxPerZone
            $placed.Add([pscustomobject]@{ Name = $zoneGroup.Name; Node = $node; Y = $y })
            $y += $node.Height + $verticalPadding
        }
        return [pscustomobject]@{ Placed = $placed; Bottom = $y }
    }

    $left = & $drawColumn $leftZones $leftX
    $right = & $drawColumn $rightZones $rightX
    $columnsBottom = [Math]::Max($left.Bottom, $right.Bottom)

    # Firewall vertically centred against the taller column, which is what makes this read as a hub
    # rather than as a third column.
    $fwHeightGuess = 140
    $fwY = [Math]::Max($topY, [int](($topY + $columnsBottom - $fwHeightGuess) / 2))
    $fwNode = Add-DrawioFirewallNode -Device $Device -Stats $view.Stats -Location ([PSCustomObject]@{X = $centreX; Y = $fwY})

    foreach ($entry in @($left.Placed) + @($right.Placed)) {
        if (-not ($fwNode.Id -and $entry.Node.Id)) { continue }
        $totals = $policy.ZoneTotals[[string]$entry.Name]
        $allow = if ($totals) { [int]$totals.Allow } else { 0 }
        $deny  = if ($totals) { [int]$totals.Deny } else { 0 }
        $label = if (-not $policy.HasPolicy) { '' }
                 elseif ($allow -eq 0 -and $deny -eq 0) { 'no rules' }
                 else { "$allow allow / $deny deny" }
        $null = Add-DrawioConnector -SourceId $fwNode.Id -TargetId $entry.Node.Id `
            -Style (Get-DrawioZoneFlowEdgeStyle -AllowCount $allow -DenyCount $deny) -Text $label
    }

    $bottom = $columnsBottom

    if ($overflowZones.Count -gt 0) {
        $names = @($overflowZones | ForEach-Object { "$($_.Name) ($($_.Count))" })
        $dims = Add-DrawioOverflowSummaryCard -TitleText "+$($overflowZones.Count) other zones" `
            -DetailLine "fewer interfaces each" -Names $names -Location ([PSCustomObject]@{X = $leftX; Y = $bottom})
        $bottom += $dims.Height + 20
    }

    # Zones named by policy that no interface carries. The reverse of ZonesWithoutPolicy and just as
    # worth stating: a rule referencing a zone this device does not have is stale configuration.
    $interfaceZoneNames = @($view.ZoneGroups | ForEach-Object { [string]$_.Name })
    $policyOnlyZones = @($policy.Zones | Where-Object { $_ -ne 'any' -and $_ -notin $interfaceZoneNames })
    if ($policyOnlyZones.Count -gt 0) {
        $zoneWord = if ($policyOnlyZones.Count -eq 1) { 'zone' } else { 'zones' }
        $dims = Add-DrawioOverflowSummaryCard -TitleText "$($policyOnlyZones.Count) $zoneWord named by rules but not on any interface" `
            -DetailLine "stale rules, or an interface capture this run did not have" -Names @($policyOnlyZones) `
            -Location ([PSCustomObject]@{X = $leftX; Y = $bottom})
        $bottom += $dims.Height + 20
    }

    $zoneLabel = if ($Device.DeviceType -eq 'CiscoASA') { 'nameif values' } else { 'zones' }
    $policyNote = if (-not $policy.HasPolicy) {
        " No security policy was parsed for this device, so the spokes carry no counts."
    }
    elseif ($Device.DeviceType -eq 'CiscoASA') {
        " Counts are the $($policy.RuleCount) rules bound inbound to each nameif by access-group; ASA policy has no destination zone, so these are per-zone totals, not zone-pair totals."
    }
    else {
        " Counts are the $($policy.RuleCount) security rules naming each zone in either direction, across $($policy.PopulatedPairCount) zone pairs."
    }
    $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = $leftX; Y = $bottom + 20}) `
        -Message "Segments of $($Device.HostName) and the policy governing them, at most $maxPerZone interfaces shown per $zoneLabel.$policyNote Which rules: the FW Rule Risk page for the notable ones, Objects.json for all of them. Segmentation without rules: FW Overview."

    End-DrawioDiagram
    Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Firewall Zone Hub page created for $($Device.HostName)."
}

#-----------------------------------------------------------------------------------------
# Main Function: Draw-FirewallRuleRiskDiagram
#-----------------------------------------------------------------------------------------
# One page per firewall: the rules worth arguing about, bucketed by why, most severe first.
#
# This is deliberately not a rendering of the rulebase. A real firewall carries hundreds of rules,
# and a picture of all of them is a worse table than the one already in Objects.json. What a diagram adds
# is triage: five buckets, sized, so the shape of the problem is visible before anything is read.
#
# Buckets that find nothing are not drawn - an empty bucket is not a finding and drawing it would
# dilute the ones that are. A device with no findings at all still gets a card saying so, because a
# page that renders blank cannot be told apart from one that failed to render.
function Draw-FirewallRuleRiskDiagram {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $Device
    )

    $risk = Get-MTAutoDrawPolicyRiskModel -Device $Device
    Write-MTAutoDrawPhase -Phase Draw -Message "Starting Firewall Rule Risk for $($Device.HostName)..."
    Start-DrawioDiagram -Name "FW Rule Risk - $($Device.HostName)"

    $view = Get-MTAutoDrawFirewallInterfaceModel -Device $Device
    $fwNode = Add-DrawioFirewallNode -Device $Device -Stats $view.Stats -Location ([PSCustomObject]@{X = 100; Y = 60})
    $bottom = 60 + $fwNode.Height

    if (-not $risk.HasPolicy) {
        $vendorNote = switch ([string]$Device.DeviceType) {
            'CheckPoint' { 'Check Point policy is not parsed by this tool.' }
            'Fortigate'  { "No 'show firewall policy' capture was collected for this device." }
            'CiscoASA'   { 'No ACLs were bound to interfaces by access-group in this configuration.' }
            default      { 'No security policy capture was parsed for this device.' }
        }
        $null = Add-DrawioRiskFindingCard -Title 'No policy to assess' -Severity 'None' `
            -Explanation $vendorNote -Names @() -Location ([PSCustomObject]@{X = 100; Y = $bottom + 60})
        $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = 100; Y = $bottom + 180}) `
            -Message "This page assesses parsed security rules; there are none for this device, which is a gap in what was collected or parsed rather than a clean result. Segments: the FW Zone Hub page."
        End-DrawioDiagram
        Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Firewall Rule Risk page created for $($Device.HostName) (no policy)."
        return
    }

    $maxNames = if ($GDrawioFirewallMaxRiskRulesPerCard -gt 0) { [int]$GDrawioFirewallMaxRiskRulesPerCard } else { 8 }
    $describe = { param($Rule) "$($Rule.Name)$(if ($null -ne $Rule.Index) { " #$($Rule.Index)" })" }
    # Card titles are sentences a reader takes at face value, so a bucket holding one item has to read
    # "1 rule allows", not "1 rules allow".
    $count = { param([int]$N, [string]$Singular, [string]$Plural) "$N $(if ($N -eq 1) { $Singular } else { $Plural })" }

    # Ordered most severe first; this is the order they are drawn in.
    $buckets = @(
        [pscustomobject]@{
            Title = "$(& $count @($risk.AnyZoneToAnyZone).Count 'rule allows' 'rules allow') any zone to any zone"
            Explanation = 'Applies between every pair of segments, so the zone model does not constrain it at all.'
            Severity = 'High'
            Names = @($risk.AnyZoneToAnyZone | ForEach-Object { & $describe $_ })
        },
        [pscustomobject]@{
            Title = "$(& $count @($risk.FullyOpenPair).Count 'zone pair is' 'zone pairs are') fully open"
            Explanation = 'Any source, any destination and any service between two named zones - the pair is unsegmented in practice.'
            Severity = 'High'
            Names = @($risk.FullyOpenPair | ForEach-Object { "$(& $describe $_): $(@($_.FromZones) -join ',') > $(@($_.ToZones) -join ',')" })
        },
        [pscustomobject]@{
            Title = "$(& $count @($risk.AnyServiceBroadSide).Count 'rule allows' 'rules allow') every protocol with one side open"
            Explanation = 'Every protocol permitted to or from anywhere. Host-to-host all-protocol rules are excluded as ordinary.'
            Severity = 'Medium'
            Names = @($risk.AnyServiceBroadSide | ForEach-Object { & $describe $_ })
        },
        [pscustomobject]@{
            Title = "$(& $count @($risk.Disabled).Count 'rule is' 'rules are') configured but disabled"
            Explanation = 'Parsed but never enforced. Config debt, or a control someone believes is in place.'
            Severity = 'Low'
            Names = @($risk.Disabled | ForEach-Object { & $describe $_ })
        },
        [pscustomobject]@{
            Title = "$(& $count @($risk.ZonesWithoutPolicy).Count 'zone has' 'zones have') no rules at all"
            Explanation = 'Configured on an interface but named by no rule: dead configuration, or an ungoverned segment.'
            Severity = 'Medium'
            Names = @($risk.ZonesWithoutPolicy | ForEach-Object { [string]$_ })
        }
    ) | Where-Object { @($_.Names).Count -gt 0 }

    if (@($buckets).Count -eq 0) {
        $null = Add-DrawioRiskFindingCard -Title 'No notable rules found' -Severity 'None' `
            -Explanation "All $($risk.RuleCount) rules name a zone pair, a service, and at least one bounded address side." `
            -Names @() -Location ([PSCustomObject]@{X = 100; Y = $bottom + 60})
        $bottom += 60 + 90
    }
    else {
        $cursor = New-DrawioGridCursor -StartX 100 -StartY ($bottom + 60) `
            -ItemsPerRow ([Math]::Max(1, [Math]::Floor($GDrawioOverviewMaxWidth / 340))) `
            -HorizontalPadding 40 -VerticalPadding 40
        foreach ($bucket in $buckets) {
            $card = Add-DrawioRiskFindingCard -Title $bucket.Title -Explanation $bucket.Explanation `
                -Severity $bucket.Severity -Names $bucket.Names -MaxNames $maxNames `
                -Location ([PSCustomObject]@{X = $cursor.X; Y = $cursor.Y})
            if ($fwNode.Id -and $card.Id) {
                $null = Add-DrawioConnector -SourceId $fwNode.Id -TargetId $card.Id -Style "endArrow=none;html=1;dashed=1;strokeWidth=1;strokeColor=$((Get-MTAutoDrawPalette -Scope Firewall).Link.Allow.Color);"
            }
            $cursor = Get-DrawioWrappedGridPosition -Cursor $cursor -DrawnWidth $card.Width -DrawnHeight $card.Height
        }
        $bottom = $cursor.Y + $cursor.RowHeight
    }

    $findingWord = if ($risk.FindingCount -eq 1) { 'finding' } else { 'findings' }
    $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = 100; Y = $bottom + 40}) `
        -Message "$($risk.FindingCount) $findingWord across $($risk.RuleCount) parsed rules, at most $maxNames named per card. Only allow rules are assessed - a deny that matches everything is a default-deny, not a finding. Full rule detail: Objects.json. Which zones these affect: the FW Zone Hub page."

    End-DrawioDiagram
    Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Firewall Rule Risk page created for $($Device.HostName)."
}

# Draws the 'Spanning-Tree' diagram page: sorts devices into root and non-root bridges, dedupes shared root bridges, and lays out the STP topology with each device's per-VLAN root-bridge relationships.
function Draw-SpanningTreeDiagram {
    [CmdletBinding()]
    param (
        # An array of all parsed host objects with their Spanning Tree data.
        [parameter(Mandatory = $true)]
        $ArrayOfObjects
    )

    $edgePalette = Get-MTAutoDrawPalette -Scope Shared

    # 1. Initialize the diagram and a tracker for dummy hosts.
    Start-DrawioDiagram -Name "Spanning-Tree"
    $dummyHosts = @{} # Used to track created dummy root bridges to avoid duplicates.

    # 2. Separate and draw the main devices.
    $pageModel = Get-MTAutoDrawSpanningTreeModel -Devices $ArrayOfObjects
    $rootHosts = $pageModel.RootHosts
    $nonRootHosts = $pageModel.NonRootHosts

    # Layout coordinates
    $horizontalPadding = 80
    $verticalPadding = 150
    $dummyRowY = 50 # New top row for unknown roots.
    $topRowY = $dummyRowY + 100 + $verticalPadding # Main hosts are below dummies.
    $bottomRowY = $topRowY + $GhostHeaderHeight + $GvlanSectionHeight + $verticalPadding
    # STP host cards are wide and their width varies a lot (a root for 200 VLANs is much wider
    # than a root for 2), so both rows wrap instead of running out as one unbroken strip.
    $itemsPerRow = 6

    # Draw Top Row (Root Hosts), wrapping every $itemsPerRow cards. $topRowContentBottom tracks the
    # actual lowest edge drawn (not just the cursor's next-slot Y, which is ambiguous when the last
    # row happens to end exactly full) so the non-root section below can never overlap it.
    $topRowCursor = New-DrawioGridCursor -StartX 50 -StartY $topRowY -ItemsPerRow $itemsPerRow -HorizontalPadding $horizontalPadding -VerticalPadding $verticalPadding
    $topRowContentBottom = $topRowY
    foreach ($device in $rootHosts) {
        $dimensions = Add-DrawioSpanningTreeHost -Device $device -Location ([PSCustomObject]@{X = $topRowCursor.X; Y = $topRowCursor.Y})
        if ($null -ne $dimensions) {
            $topRowContentBottom = [Math]::Max($topRowContentBottom, $topRowCursor.Y + $dimensions.Height)
            $topRowCursor = Get-DrawioWrappedGridPosition -Cursor $topRowCursor -DrawnWidth $dimensions.Width -DrawnHeight $dimensions.Height
        }
    }

    # Draw Bottom Row (Non-Root Hosts), wrapping every $itemsPerRow cards.
    $bottomRowStartY = if ($rootHosts.Count -gt 0) { $topRowContentBottom + $verticalPadding } else { $bottomRowY }
    $bottomRowCursor = New-DrawioGridCursor -StartX 50 -StartY $bottomRowStartY -ItemsPerRow $itemsPerRow -HorizontalPadding $horizontalPadding -VerticalPadding $verticalPadding
    foreach ($device in $nonRootHosts) {
        $dimensions = Add-DrawioSpanningTreeHost -Device $device -Location ([PSCustomObject]@{X = $bottomRowCursor.X; Y = $bottomRowCursor.Y})
        if ($null -ne $dimensions) { $bottomRowCursor = Get-DrawioWrappedGridPosition -Cursor $bottomRowCursor -DrawnWidth $dimensions.Width -DrawnHeight $dimensions.Height }
    }

    # 3. Connect all the non-root VLAN groups.
    Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Drawing spanning-tree connectors."
    $dummyX = 50 # X-coordinate for placing new dummy hosts.
    foreach ($device in $ArrayOfObjects) {
        if (-not $device.SpanningTree) { continue }

        $nonRootGroups = $device.SpanningTree.SpanningTreeArray | Where-Object { -not $_.RootBridge } | Group-Object { ConvertTo-NormalizedMacAddress $_.Address }

        foreach ($group in $nonRootGroups) {
            $sourceShapeId = $group.Group[0].Shape
            $rootBridgeId = $group.Name

            $connectorLabel = ($group.Group.RootBridgePort | Select-Object -Unique) -join ",`n"

            $targetDevice = $null
            $targetShapeId = $null

            foreach ($potentialTarget in $ArrayOfObjects) {
                $foundRootVlan = $potentialTarget.SpanningTree.SpanningTreeArray | Where-Object { (ConvertTo-NormalizedMacAddress $_.Address) -eq $rootBridgeId -and $_.RootBridge -eq $true } | Select-Object -First 1
                if ($foundRootVlan) {
                    $targetDevice = $potentialTarget
                    $targetShapeId = $foundRootVlan.Shape
                    break
                }
            }

            if (-not $targetDevice) {
                Write-MTAutoDrawLog -Level Warn -Phase Draw -Message "Root bridge $($rootBridgeId) not found. Checking for or creating a placeholder."
                if (-not $dummyHosts.ContainsKey($rootBridgeId)) {
                    $dummy = Create-HostObject
                    $dummy.HostName = $rootBridgeId
                    $dummy.SpanningTree = Create-SpanningTreeObject
                    $stpInstance = Create-SpanningTreeVlan
                    $stpInstance.Address = $rootBridgeId
                    $stpInstance.RootBridge = $true
                    $dummy.SpanningTree.SpanningTreeArray += $stpInstance

                    $dummyDimensions = Add-DrawioDummyRootHost -DummyDevice $dummy -Location ([PSCustomObject]@{X = $dummyX; Y = $dummyRowY})
                    $dummyX += $dummyDimensions.Width + $horizontalPadding
                    $dummyHosts[$rootBridgeId] = $dummy
                }
                $targetShapeId = $dummyHosts[$rootBridgeId].SpanningTree.SpanningTreeArray[0].Shape
            }

            if ($sourceShapeId -and $targetShapeId) {
                Write-MTAutoDrawLog -Level Debug -Phase Draw -Message "Drawing connector from $($device.HostName) to root $($rootBridgeId) with label: $($connectorLabel)"

                # This style ensures straight lines.
                $style = "endArrow=classic;html=1;rounded=0;strokeColor=$($edgePalette.Link.SpanningTree);strokeWidth=2;dashed=1;whiteSpace=wrap;"

                $null = Add-DrawioConnector -SourceId $sourceShapeId -TargetId $targetShapeId -Style $style -Text $connectorLabel
            }
        }
    }
    Write-MTAutoDrawLog -Level Info -Phase Draw -Message "Finished spanning-tree connectors."

    $null = Add-DrawioOverviewFooterNote -Location ([PSCustomObject]@{X = 100; Y = ($bottomRowCursor.Y + 240)}) `
        -Message "Only devices that reported spanning-tree data are shown. A root bridge no device has config for is drawn as a placeholder, from the bridge id its neighbours name. Per-VLAN detail is on each device's own page."

    # 4. Finalize and save the file.
    End-DrawioDiagram
}



# Draws the single-device Layer-3 diagram for $Device (Normal or RoutesOnly): its routed interfaces, connected networks (from $ArrayOfNetworks), routes, and any gateway hosts, placed as one cohesive page.
function Draw-SinglesLayer3Drawio {
    [CmdletBinding()]
    param (
        # The single device object for which to create a diagram.
        [parameter(Mandatory = $true)]
        $Device,
        # The complete list of all network segments in the environment.
        [parameter(Mandatory = $true)]
        $ArrayOfNetworks,
        # The type of L3 diagram to create: "Normal" or "RoutesOnly".
        [parameter(Mandatory = $false)]
        [ValidateSet("Normal", "RoutesOnly")]
        [string]$DiagramType = "Normal",
        # An array of ALL device objects. Required when DiagramType is "RoutesOnly".
        [parameter(Mandatory = $false)]
        [array]$ArrayOfObjects,
        # An optional array of gateway-only devices (e.g., firewalls, routers).
        [parameter(Mandatory = $false)]
        [array]$ArrayofGatewayHosts
    )

    $edgePalette = Get-MTAutoDrawPalette -Scope Shared

    # 1. Work out what there is to draw before opening the page. Devices without a
    # connected L3 network still receive an inventory-only page so the Singles
    # artifact has a predictable L3 page for every parsed device.
    $pageModel = Get-MTAutoDrawSingleHostL3Model -Device $Device -DiagramType $DiagramType `
        -SharedNetworks $ArrayOfNetworks -Devices $ArrayOfObjects -GatewayHosts $ArrayofGatewayHosts
    $DeviceArrayOfNetworks = $pageModel.Networks

    if ($DiagramType -eq "Normal" -and $DeviceArrayOfNetworks.Count -eq 0) {
        Write-Warning "No connected L3 networks found for $($Device.hostname). Drawing a device-only L3 page."
    }

    # 2. Start a new page for this device.
    Start-DrawioDiagram -Name "$($Device.hostname) L3"

    # ===================================================================
    # --- DRAWING LOGIC FOR 'Normal' DIAGRAM TYPE ---
    # ===================================================================
    if ($DiagramType -eq "Normal") {
        $currentY = 100
        $lowestNetworkOrArpBottom = 0
        foreach ($network in $DeviceArrayOfNetworks) {
            $netId = (Add-DrawioNetworkSegment -Network $network -Location ([PSCustomObject]@{X = 100; Y = $currentY})).Id
            if ($GDrawAprEntries -and $network.ARPEntries) {
                $arpId = (Add-DrawioArpBubble -Network $network -Location ([PSCustomObject]@{X = $GDrawioVlanWidth + 150; Y = $currentY})).Id
                $lowestNetworkOrArpBottom = [Math]::Max($lowestNetworkOrArpBottom, $currentY + (Get-DrawioArpBubbleHeight -Network $network))
                $null = Add-DrawioConnector -SourceId $netId -TargetId $arpId -Style "endArrow=none;dashed=1;strokeColor=$($edgePalette.Link.Annotation);strokeWidth=4;"
            }
            $lowestNetworkOrArpBottom = [Math]::Max($lowestNetworkOrArpBottom, $currentY + $GDrawioVlanHeight)
            $currentY += 80
        }

        $hostYPos = if ($lowestNetworkOrArpBottom -gt 0) { $lowestNetworkOrArpBottom + 100 } else { 100 }
        $singleInterfaces = Get-DrawioHostLayer3Interfaces -Device $Device -DiagramType "Normal"
        $singleSideOf = @{}
        foreach ($name in @($singleInterfaces.Interface)) { $singleSideOf[[string]$name] = 'S' }
        $null = Add-DrawioHostLayer3 -Device $Device -Location ([PSCustomObject]@{X = 400; Y = $hostYPos}) -Interfaces $singleInterfaces -SideOf $singleSideOf

        foreach ($interface in ($Device.interfaces | Where-Object { -not $_.shutdown -and @(Get-MTAutoDrawInterfaceIPv4Address -Interface $_).Count -gt 0 })) {
            foreach ($address in @(Get-MTAutoDrawInterfaceIPv4Address -Interface $interface | Where-Object Cidr)) {
                $targetNetwork = $DeviceArrayOfNetworks | Where-Object { $_.cidr -eq $address.cidr } | Select-Object -First 1
                if ($interface.LogicalDrawioId -and $targetNetwork -and $targetNetwork.LogicalDrawioId) {
                    $connectorStyle = "endArrow=none;strokeWidth=4;strokeColor=$(Convert-RgbToHex -RgbString $targetNetwork.color);"
                    $null = Add-DrawioConnector -SourceId $interface.LogicalDrawioId -TargetId $targetNetwork.LogicalDrawioId -Style $connectorStyle -Text "$($interface.Interface)<br>$($address.IPAddress)"
                }
            }
        }
    }
    # ===================================================================
    # --- DRAWING LOGIC FOR 'RoutesOnly' DIAGRAM TYPE ---
    # ===================================================================
    elseif ($DiagramType -eq "RoutesOnly") {
        if (-not $ArrayOfObjects) {
            throw "The -ArrayOfObjects parameter, containing all device objects, is required when DiagramType is 'RoutesOnly'."
        }

        # The model has already resolved the peers and flagged the interfaces that carry a link.
        $allPossiblePeers = $ArrayOfObjects + $ArrayofGatewayHosts
        $primaryIpMap = $pageModel.PrimaryIpMap
        $peersToDraw = $pageModel.PeersToDraw

        # 2d. Draw the main host and its identified peers.
        $mainInterfaces = Get-DrawioHostLayer3Interfaces -Device $Device -DiagramType "RoutesOnly"
        $mainSideOf = @{}
        foreach ($name in @($mainInterfaces.Interface)) { $mainSideOf[[string]$name] = 'S' }
        $null = Add-DrawioHostLayer3 -Device $Device -Location ([PSCustomObject]@{X = 800; Y = 500}) -Interfaces $mainInterfaces -SideOf $mainSideOf
        $peerX = 100
        $drawablePeers = $peersToDraw.Values | Sort-Object hostname
        foreach ($peer in $drawablePeers) {
            $peerInterfaces = Get-DrawioHostLayer3Interfaces -Device $peer -DiagramType "RoutesOnly"
            $peerSideOf = @{}
            foreach ($name in @($peerInterfaces.Interface)) { $peerSideOf[[string]$name] = 'N' }
            $null = Add-DrawioHostLayer3 -Device $peer -Location ([PSCustomObject]@{X = $peerX; Y = 1100}) -Interfaces $peerInterfaces -SideOf $peerSideOf
            $peerX += 800
        }

        # 2e. Draw connectors now that IDs exist.
        foreach ($sourceDevice in $allRelevantDevices) {
            foreach ($interface in ($sourceDevice.interfaces | Where-Object { $_.LogicalDrawioId -and $_.RoutesForInterface })) {
                foreach ($group in ($interface.RoutesForInterface | Where-Object Gateway | Group-Object Gateway)) {
                    $gatewayIp = $group.Name
                    $targetInfo = $primaryIpMap[$gatewayIp]

                    if ($targetInfo -and $targetInfo.Interface.LogicalDrawioId) {
                        $targetInterface = $targetInfo.Interface
                        
                        $routeCount = $group.Count
                        $protocols = ($group.Group.RouteProtocol | Sort-Object -Unique) -join ', '
                        $primaryProtocol = ($group.Group.RouteProtocol | Select-Object -First 1)
                        if ($protocols -like "*BGP*") { $primaryProtocol = "BGP" }

                        $color = switch -wildcard ($primaryProtocol) {
                            "static" { "rgb(0,107,60)" }
                            "BGP"    { "rgb(0,0,179)" }
                            "EIGRP"  { "rgb(160,32,240)" }
                            "OSPF"   { "rgb(255,165,0)" }
                            default  { (Get-MTAutoDrawPalette -Scope Shared).Text.Default }
                        }
                        $text = if ($routeCount -gt 15) {
                            "$($protocols)<br>$($gatewayIp)<br>Route Count:$routeCount"
                        } else {
                            "$($protocols)<br>$($gatewayIp)<br>" + (($group.Group | Select-Object -ExpandProperty subnet | Sort-Object) -join '<br>')
                        }
                        $dashed = if ($text -like "*0.0.0.0/0*") { 0 } else { 1 }
                        $style = "endArrow=classic;html=1;strokeWidth=8;strokeColor=$color;endSize=8;dashed=$dashed;"
                        
                        $null = Add-DrawioConnector -SourceId $interface.LogicalDrawioId -TargetId $targetInterface.LogicalDrawioId -Style $style -Text $text
                    }
                }
            }
        }
    }

    # Finalize and save the diagram.
    End-DrawioDiagram
}
