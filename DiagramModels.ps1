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


# MTAutoDraw - Diagram models
#
# The topology-evidence model (who's plugged into what, from CDP/LLDP/MAC-table evidence),
# observed unresolved LLDP peers, end-unit collapsing, and the firewall zone/policy risk models.
# A model here never touches the .drawio document - a page function reads the model and draws it,
# but building the model has no drawing knowledge.
#
# Split by domain across three files so no one file carries every page's model:
# DiagramModels.Layer3.ps1 (connectivity/routes/topology) and DiagramModels.Pages.ps1 (the
# remaining per-page/per-host/per-neighbor models) hold the rest.
#
# Depends on: nothing
# Loaded by:  AutoDraw.ps1 ($GLibrariesToLoad)

#region Inferred topology evidence model

function Get-MTAutoDrawTopologyEvidenceColumns {
    [CmdletBinding()]
    param()

    return @(
        'EvidenceId','NodeKind','TargetHostname','TargetLabel','TargetMac','TargetIp','Vendor',
        'SourceHostname','SourceInterface','EvidenceSources','Confidence','AttachmentStatus',
        'Directness','Vlans','RootCost','InterfaceDescription','LearnedMacCount',
        'CandidateCount','Drawn','Notes'
    )
}

# Extracts a normalised MAC address from a value, checking common property names (MacAddress/MAC/macaddress) before falling back to the raw value.
function Get-MTAutoDrawEvidenceMacValue {
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    foreach ($propertyName in @('MacAddress','MAC','macaddress')) {
        $property = $Value.PSObject.Properties[$propertyName]
        if ($property -and $property.Value) {
            return ConvertTo-NormalizedMacIdentity ([string]$property.Value)
        }
    }
    return ConvertTo-NormalizedMacIdentity ([string]$Value)
}

# Builds a stable 'hostname|interface' key for an evidence port, normalising the interface identity.
function Get-MTAutoDrawEvidencePortKey {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Hostname,
        [AllowNull()][string]$Interface
    )

    $hostKey = ([string]$Hostname).Trim().ToLowerInvariant()
    $interfaceKey = ConvertTo-NormalizedInterfaceIdentity $Interface
    if (-not $interfaceKey) { $interfaceKey = ([string]$Interface).Trim().ToLowerInvariant() }
    return '{0}|{1}' -f $hostKey, $interfaceKey
}

# Looks up the vendor (from the global MAC->vendor map) for the first 6 hex digits (OUI) of a normalised MAC. Returns '' when unknown.
function Get-MTAutoDrawEvidenceVendorForMac {
    [CmdletBinding()]
    param([AllowNull()][string]$Mac)

    $normalized = ConvertTo-NormalizedMacIdentity $Mac
    if (-not $normalized) { return '' }
    $prefix = $normalized.Substring(0, 6)
    if ($GMacAddressToVendorMapping -and $GMacAddressToVendorMapping.ContainsKey($prefix)) {
        return [string]$GMacAddressToVendorMapping[$prefix]
    }
    return ''
}

# Adds a node to an evidence state: assigns a stable node ID, initialises the VLAN/cost lists, and increments the node counter. Returns the new node object.
function Add-MTAutoDrawEvidenceNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Label,
        [string]$Mac = '',
        [string]$Ip = '',
        [string]$Vendor = ''
    )

    $State.NodeCounter++
    $node = [pscustomobject][ordered]@{
        NodeId = 'evid-node-{0:D3}' -f $State.NodeCounter
        Kind   = $Kind
        Label  = $Label
        Mac    = $Mac
        Ip     = $Ip
        Vendor = $Vendor
        Vlans  = [System.Collections.Generic.List[string]]::new()
        Costs  = [System.Collections.Generic.List[string]]::new()
    }
    $State.Nodes.Add($node)
    return $node
}

# Adds an edge (link) to an evidence state connecting two nodes, recording the link's kind and any associated MACs/IPs.
function Add-MTAutoDrawEvidenceEdge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Node,
        [Parameter(Mandatory = $true)][string]$SourceHostname,
        [Parameter(Mandatory = $true)][string]$SourceInterface,
        [string]$Confidence = 'Ambiguous',
        [string]$Directness = 'NotProven',
        [string]$EvidenceSources = '',
        [string]$Vlans = '',
        [string]$RootCost = '',
        [string]$InterfaceDescription = '',
        [int]$LearnedMacCount = 0,
        [int]$CandidateCount = 1,
        [string]$Notes = ''
    )

    $State.EdgeCounter++
    $evidenceId = 'evid-edge-{0:D3}' -f $State.EdgeCounter
    $includeMaster = if ($null -eq (Get-Variable -Name GIncludeInferredTopologyEvidence -ErrorAction SilentlyContinue)) { $true } else { [bool]$GIncludeInferredTopologyEvidence }
    $includeAmbiguous = if ($null -eq (Get-Variable -Name GIncludeAmbiguousTopologyEvidence -ErrorAction SilentlyContinue)) { $true } else { [bool]$GIncludeAmbiguousTopologyEvidence }
    $drawn = $includeMaster -and ($Confidence -eq 'Strong' -or $includeAmbiguous)
    $targetHostname = if ($Node.Kind -eq 'ExistingDevice') { [string]$Node.Label } else { '' }

    $edge = [pscustomobject][ordered]@{
        EvidenceId           = $evidenceId
        NodeId               = [string]$Node.NodeId
        NodeKind             = [string]$Node.Kind
        TargetHostname       = $targetHostname
        TargetLabel          = [string]$Node.Label
        TargetMac            = [string]$Node.Mac
        TargetIp             = [string]$Node.Ip
        Vendor               = [string]$Node.Vendor
        SourceHostname       = $SourceHostname
        SourceInterface      = $SourceInterface
        EvidenceSources      = $EvidenceSources
        Confidence           = $Confidence
        Directness           = $Directness
        Vlans                = $Vlans
        RootCost             = $RootCost
        InterfaceDescription = $InterfaceDescription
        LearnedMacCount      = $LearnedMacCount
        CandidateCount       = $CandidateCount
        Drawn                = [bool]$drawn
        Notes                = $Notes
    }
    $State.Edges.Add($edge)

    $State.Rows.Add([pscustomobject][ordered]@{
        EvidenceId           = $evidenceId
        NodeKind             = [string]$Node.Kind
        TargetHostname       = $targetHostname
        TargetLabel          = [string]$Node.Label
        TargetMac            = [string]$Node.Mac
        TargetIp             = [string]$Node.Ip
        Vendor               = [string]$Node.Vendor
        SourceHostname       = $SourceHostname
        SourceInterface      = $SourceInterface
        EvidenceSources      = $EvidenceSources
        Confidence           = $Confidence
        AttachmentStatus     = if ($drawn) { 'Drawn' } else { 'NotDrawn' }
        Directness           = $Directness
        Vlans                = $Vlans
        RootCost             = $RootCost
        InterfaceDescription = $InterfaceDescription
        LearnedMacCount      = $LearnedMacCount
        CandidateCount       = $CandidateCount
        Drawn                = [string][bool]$drawn
        Notes                = $Notes
    })
    return $edge
}

# Appends a topology-evidence audit row that is intentionally not drawn.
function Add-MTAutoDrawEvidenceAuditRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Node,
        [string]$EvidenceSources,
        [string]$Confidence = 'Ambiguous',
        [string]$Directness = 'NotProven',
        [string]$SourceHostname = '',
        [string]$SourceInterface = '',
        [string]$InterfaceDescription = '',
        [int]$LearnedMacCount = 0,
        [int]$CandidateCount = 0,
        [string]$Notes = ''
    )

    $targetHostname = if ($Node.Kind -eq 'ExistingDevice') { [string]$Node.Label } else { '' }
    $State.Rows.Add([pscustomobject][ordered]@{
        EvidenceId=''; NodeKind=$Node.Kind; TargetHostname=$targetHostname; TargetLabel=$Node.Label
        TargetMac=$Node.Mac; TargetIp=$Node.Ip; Vendor=$Node.Vendor
        SourceHostname=$SourceHostname; SourceInterface=$SourceInterface; EvidenceSources=$EvidenceSources
        Confidence=$Confidence; AttachmentStatus='NotDrawn'; Directness=$Directness
        Vlans=''; RootCost=''; InterfaceDescription=$InterfaceDescription; LearnedMacCount=$LearnedMacCount
        CandidateCount=$CandidateCount; Drawn='False'; Notes=$Notes
    })
}

# Builds the topology evidence model from a device set: nodes (devices/peers), edges (links), and the MAC/ARP evidence that ties them together.
function Get-MTAutoDrawTopologyEvidenceModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Devices,
        [AllowNull()][AllowEmptyCollection()]$GatewayHosts = @()
    )

    $allDevices = @($Devices | Where-Object { $_ })
    $state = [pscustomobject]@{
        Nodes       = [System.Collections.Generic.List[object]]::new()
        Edges       = [System.Collections.Generic.List[object]]::new()
        Rows        = [System.Collections.Generic.List[object]]::new()
        NodeCounter = 0
        EdgeCounter = 0
    }

    $hostnameIndex = @{}
    $macDeviceSets = @{}
    foreach ($device in $allDevices) {
        if ($device.hostname) { $hostnameIndex[[string]$device.hostname] = $device }
        foreach ($mac in @(Get-DeviceKnownMacAddress -Device $device)) {
            if (-not $macDeviceSets.ContainsKey($mac)) {
                $macDeviceSets[$mac] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            }
            $macDeviceSets[$mac].Add([string]$device.hostname) | Out-Null
        }
    }
    $macDeviceIndex = @{}
    foreach ($mac in @($macDeviceSets.Keys)) {
        if ($macDeviceSets[$mac].Count -eq 1) {
            $hostname = @($macDeviceSets[$mac])[0]
            $macDeviceIndex[$mac] = $hostnameIndex[$hostname]
        }
    }

    # Any first-hand neighbor observation occupies or makes the local port unsafe for
    # inference. This includes unresolved LLDP, self-neighbors, flooded/shared records,
    # and resolved CDP/LLDP. Lower-level evidence must never add another physical link.
    $blockedPorts = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($device in $allDevices) {
        foreach ($neighbor in @($device.CDPNeighbors) + @($device.LLDPNeighbors)) {
            if (-not $neighbor -or [string]::IsNullOrWhiteSpace([string]$neighbor.InterfaceLocalDevice)) { continue }
            $key = Get-MTAutoDrawEvidencePortKey -Hostname $device.hostname -Interface $neighbor.InterfaceLocalDevice
            if ($key) { [void]$blockedPorts.Add($key) }
        }
    }

    $camTable = @{}
    $camMacIndex = @{}
    foreach ($device in $allDevices) {
        foreach ($interface in @($device.interfaces | Where-Object { $_ })) {
            $portKey = Get-MTAutoDrawEvidencePortKey -Hostname $device.hostname -Interface $interface.Interface
            $macs = @($interface.MacAddressArray | ForEach-Object { Get-MTAutoDrawEvidenceMacValue $_ } | Where-Object { $_ } | Sort-Object -Unique)
            if ($macs.Count -eq 0) { continue }
            $camTable[$portKey] = $macs
            foreach ($mac in $macs) {
                if (-not $camMacIndex.ContainsKey($mac)) {
                    $camMacIndex[$mac] = [System.Collections.Generic.List[object]]::new()
                }
                $camMacIndex[$mac].Add([pscustomobject]@{
                    Device = $device
                    Interface = $interface
                    PortKey = $portKey
                })
            }
        }
    }

    $claimedStrongPorts = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    # STP: collapse all VLAN sightings for one root MAC and keep only unresolved
    # root-port frontiers. This avoids drawing every downstream switch directly
    # to the unknown bridge.
    $stpGroups = @{}
    foreach ($device in $allDevices) {
        $spanningTree = $device.SpanningTree
        if (-not $spanningTree -or -not $spanningTree.SpanningTreeArray) { continue }
        $rootVlans = @($spanningTree.RootBridgeForVlans | ForEach-Object { [string]$_ })
        $selfMacs = @(Get-DeviceKnownMacAddress -Device $device)
        foreach ($instance in @($spanningTree.SpanningTreeArray | Where-Object { $_ })) {
            $vlan = [string]$instance.VlanID
            if ($rootVlans -contains $vlan) { continue }
            $rootPort = [string]$instance.RootBridgePort
            if ([string]::IsNullOrWhiteSpace($rootPort)) { continue }

            # Prefer the per-port designated-bridge MAC from 'show spanning-tree detail': it names
            # whatever is literally one hop away on THIS port, rather than the instance-level global
            # root address, which can be several hops away on a multi-tier topology.
            $rootPortInterface = @($instance.SpanningTreeInterfaces | Where-Object {
                (ConvertTo-NormalizedInterfaceIdentity $_.Interface) -eq (ConvertTo-NormalizedInterfaceIdentity $rootPort)
            } | Select-Object -First 1)
            $designatedBridgeMac = if ($rootPortInterface.Count -gt 0) { ConvertTo-NormalizedMacIdentity ([string]$rootPortInterface[0].DesignatedBridgeAddress) } else { $null }

            $rootMac = ConvertTo-NormalizedMacIdentity ([string]$instance.Address)
            $groupMac = if ($designatedBridgeMac) { $designatedBridgeMac } else { $rootMac }
            if (-not $groupMac -or $selfMacs -contains $groupMac) { continue }

            if (-not $stpGroups.ContainsKey($groupMac)) {
                $stpGroups[$groupMac] = [System.Collections.Generic.List[object]]::new()
            }
            $stpGroups[$groupMac].Add([pscustomobject]@{
                Device=$device; RootPort=$rootPort; Vlan=$vlan; RootCost=[string]$instance.RootBridgeCost
                PortKey=(Get-MTAutoDrawEvidencePortKey -Hostname $device.hostname -Interface $rootPort)
                DesignatedBridgeMatched=[bool]$designatedBridgeMac
            })
        }
    }

    foreach ($groupMac in @($stpGroups.Keys | Sort-Object)) {
        $sightings = @($stpGroups[$groupMac])
        $frontiers = [System.Collections.Generic.List[object]]::new()
        $seenFrontiers = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($sighting in @($sightings | Sort-Object { $_.Device.hostname },RootPort,Vlan)) {
            if ($sighting.PortKey -and $blockedPorts.Contains($sighting.PortKey)) { continue }
            if ($seenFrontiers.Add($sighting.PortKey)) { $frontiers.Add($sighting) }
        }
        if ($frontiers.Count -eq 0) { continue }

        $vlans = @($sightings | ForEach-Object Vlan | Where-Object { $_ } | Sort-Object -Unique)
        $costs = @($sightings | ForEach-Object RootCost | Where-Object { $_ } | Sort-Object -Unique)
        $resolvedDevice = if ($macDeviceIndex.ContainsKey($groupMac)) { $macDeviceIndex[$groupMac] } else { $null }
        if ($resolvedDevice) {
            $node = [pscustomobject]@{ NodeId=''; Kind='ExistingDevice'; Label=[string]$resolvedDevice.hostname; Mac=$groupMac; Ip=''; Vendor=''; Vlans=@($vlans); Costs=@($costs) }
        }
        else {
            $node = Add-MTAutoDrawEvidenceNode -State $state -Kind 'UnknownSTPRoot' -Label 'Unknown STP root/path' -Mac $groupMac -Vendor (Get-MTAutoDrawEvidenceVendorForMac $groupMac)
            foreach ($vlan in $vlans) { $node.Vlans.Add([string]$vlan) }
            foreach ($cost in $costs) { $node.Costs.Add([string]$cost) }
        }

        # Non-designated-bridge frontiers keep the original heuristic: 'Strong' only when this group's
        # only *fallback* evidence is a single sighting, because several fallback sightings sharing one
        # global root address genuinely is ambiguous about which (if any) is a direct neighbor. A
        # designated-bridge match is a literal per-port BPDU field naming its one-hop neighbor, so it's
        # 'Strong' unconditionally - a fan-out target (one switch legitimately terminating several
        # independent uplinks) is not actually ambiguous once each claim is independently port-level
        # evidence.
        $fallbackFrontierCount = @($frontiers | Where-Object { -not $_.DesignatedBridgeMatched }).Count
        foreach ($frontier in $frontiers) {
            $interface = @($frontier.Device.interfaces | Where-Object { (ConvertTo-NormalizedInterfaceIdentity $_.Interface) -eq (ConvertTo-NormalizedInterfaceIdentity $frontier.RootPort) } | Select-Object -First 1)
            $description = if ($interface.Count -gt 0) { [string]$interface[0].Description } else { '' }
            $learned = if ($camTable.ContainsKey($frontier.PortKey)) { @($camTable[$frontier.PortKey]).Count } else { 0 }
            if ($frontier.DesignatedBridgeMatched) {
                $confidence = 'Strong'
                $directness = 'DesignatedBridge'
                $notes = 'STP per-port designated bridge (show spanning-tree detail); names the neighbor physically attached to this exact port'
            }
            else {
                $confidence = if ($fallbackFrontierCount -eq 1) { 'Strong' } else { 'Ambiguous' }
                $directness = 'NotProven'
                $notes = 'STP root-port path; endpoint is not proven directly attached'
            }
            $edge = Add-MTAutoDrawEvidenceEdge -State $state -Node $node -SourceHostname $frontier.Device.hostname -SourceInterface $frontier.RootPort -Confidence $confidence -Directness $directness -EvidenceSources ('STP:{0}' -f ($vlans -join ',')) -Vlans ($vlans -join ', ') -RootCost ($costs -join ', ') -InterfaceDescription $description -LearnedMacCount $learned -CandidateCount $frontiers.Count -Notes $notes
            if ($edge.Drawn -and $confidence -eq 'Strong') { $claimedStrongPorts.Add($frontier.PortKey) | Out-Null }
        }
    }

    # Exact captured-device MAC seen in CAM. A CAM table proves forwarding reachability,
    # not one-hop adjacency, so every sighting is audit-only and never becomes an edge.
    foreach ($targetDevice in @($allDevices | Sort-Object hostname)) {
        foreach ($mac in @(Get-DeviceKnownMacAddress -Device $targetDevice)) {
            if (-not $camMacIndex.ContainsKey($mac)) { continue }
            $sightings = @($camMacIndex[$mac] | Where-Object { $_.Device.hostname -ine $targetDevice.hostname })
            if ($sightings.Count -eq 0) { continue }
            $node = [pscustomobject]@{ NodeId=''; Kind='ExistingDevice'; Label=[string]$targetDevice.hostname; Mac=$mac; Ip=''; Vendor=''; Vlans=@(); Costs=@() }
            foreach ($sighting in @($sightings | Sort-Object { $_.Device.hostname }, { $_.Interface.Interface })) {
                $corroboratesNeighbor = [bool]($sighting.PortKey -and $blockedPorts.Contains($sighting.PortKey))
                $interfaceDescription = if ($sighting.Interface) { [string]$sighting.Interface.Description } else { '' }
                $learnedMacCount = if ($camTable.ContainsKey($sighting.PortKey)) { @($camTable[$sighting.PortKey]).Count } else { 0 }
                Add-MTAutoDrawEvidenceAuditRow -State $state -Node $node -EvidenceSources ('CAM:{0}' -f $mac) `
                    -SourceHostname $sighting.Device.hostname -SourceInterface $sighting.Interface.Interface `
                    -InterfaceDescription $interfaceDescription -LearnedMacCount $learnedMacCount -CandidateCount $sightings.Count `
                    -Notes $(if ($corroboratesNeighbor) { 'CAM sighting on a neighbor-observed port; corroborating reachability only, not drawn' } else { 'CAM sighting only; reachability evidence, not adjacency proof; not drawn' })
            }
        }
    }

    # Route gateway identity from ARP, then exact MAC-to-CAM attachment.
    foreach ($gatewayHost in @($GatewayHosts | Where-Object { $_ -and [string]$_.Origin -eq 'ARP' })) {
        $gatewayIps = @($gatewayHost.ArrayOfIPAddresses | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() } | Sort-Object -Unique)
        $gatewayMac = Get-MTAutoDrawEvidenceMacValue $gatewayHost.hostname
        if (-not $gatewayMac) {
            foreach ($device in $allDevices) {
                foreach ($arp in @($device.IPArpEntries | Where-Object { $_ })) {
                    if ($gatewayIps -contains ([string]$arp.ipaddress).Trim()) {
                        $gatewayMac = Get-MTAutoDrawEvidenceMacValue $arp
                        if ($gatewayMac) { break }
                    }
                }
                if ($gatewayMac) { break }
            }
        }
        if (-not $gatewayMac) { continue }

        $resolvedDevice = if ($macDeviceIndex.ContainsKey($gatewayMac)) { $macDeviceIndex[$gatewayMac] } else { $null }
        if ($resolvedDevice) {
            $node = [pscustomobject]@{ NodeId=''; Kind='ExistingDevice'; Label=[string]$resolvedDevice.hostname; Mac=$gatewayMac; Ip=($gatewayIps -join ', '); Vendor=''; Vlans=@(); Costs=@() }
            $notes = 'Gateway ARP resolves to a captured device'
        }
        else {
            $node = @($state.Nodes | Where-Object { $_.Kind -eq 'UnknownL3Gateway' -and $_.Mac -eq $gatewayMac } | Select-Object -First 1)
            if ($node.Count -eq 0) {
                $gatewayLabel = if ($gatewayIps.Count -gt 0) { 'Unknown L3 gateway ({0})' -f $gatewayIps[0] } else { 'Unknown L3 gateway' }
                $node = Add-MTAutoDrawEvidenceNode -State $state -Kind 'UnknownL3Gateway' -Label $gatewayLabel -Mac $gatewayMac -Ip ($gatewayIps -join ', ') -Vendor (Get-MTAutoDrawEvidenceVendorForMac $gatewayMac)
            }
            else { $node = $node[0] }
            $notes = 'Gateway ARP does not resolve to a captured device'
        }

        $sightings = if ($camMacIndex.ContainsKey($gatewayMac)) { @($camMacIndex[$gatewayMac]) } else { @() }
        if ($sightings.Count -eq 0) {
            Add-MTAutoDrawEvidenceAuditRow -State $state -Node $node -EvidenceSources ('ARP:{0}' -f ($gatewayIps -join ',')) -Notes "$notes; no CAM sighting"
            continue
        }
        foreach ($sighting in @($sightings | Sort-Object { $_.Device.hostname }, { $_.Interface.Interface })) {
            $corroboratesNeighbor = [bool]($sighting.PortKey -and $blockedPorts.Contains($sighting.PortKey))
            $interfaceDescription = if ($sighting.Interface) { [string]$sighting.Interface.Description } else { '' }
            $learnedMacCount = if ($camTable.ContainsKey($sighting.PortKey)) { @($camTable[$sighting.PortKey]).Count } else { 0 }
            Add-MTAutoDrawEvidenceAuditRow -State $state -Node $node -EvidenceSources ('ARP:{0};CAM:{1}' -f ($gatewayIps -join ','),$gatewayMac) `
                -SourceHostname $sighting.Device.hostname -SourceInterface $sighting.Interface.Interface `
                -InterfaceDescription $interfaceDescription -LearnedMacCount $learnedMacCount -CandidateCount $sightings.Count `
                -Notes "$notes; $(if ($corroboratesNeighbor) { 'CAM sighting on a neighbor-observed port; corroborating reachability only, not drawn' } else { 'CAM sighting only; not drawn' })"
        }
    }

    # Strict, low-confidence port descriptions. These never override a vetted
    # neighbour or a strong evidence attachment.
    $descriptionPattern = '(?i)(?:^|[^a-z0-9])(firewall|palo[\s-]*alto|fortigate|check[\s-]*point|fw|router|gateway|switch|bridge)(?:[^a-z0-9]|$)'
    foreach ($sourceDevice in @($allDevices | Sort-Object hostname)) {
        foreach ($interface in @($sourceDevice.interfaces | Where-Object { $_ -and -not $_.shutdown })) {
            $description = ([string]$interface.Description).Trim()
            if (-not $description) { continue }
            $portKey = Get-MTAutoDrawEvidencePortKey -Hostname $sourceDevice.hostname -Interface $interface.Interface
            if (($portKey -and $blockedPorts.Contains($portKey)) -or $claimedStrongPorts.Contains($portKey)) { continue }

            $namedDevice = $null
            foreach ($candidate in $allDevices) {
                if (-not $candidate.hostname -or $candidate.hostname -ieq $sourceDevice.hostname) { continue }
                $namePattern = '(?i)(?<![a-z0-9]){0}(?![a-z0-9])' -f [regex]::Escape([string]$candidate.hostname)
                if ($description -match $namePattern) { $namedDevice = $candidate; break }
            }
            $keywordMatch = [regex]::Match($description, $descriptionPattern)
            if (-not $namedDevice -and -not $keywordMatch.Success) { continue }

            if ($namedDevice) {
                $node = [pscustomobject]@{ NodeId=''; Kind='ExistingDevice'; Label=[string]$namedDevice.hostname; Mac=''; Ip=''; Vendor=''; Vlans=@(); Costs=@() }
                $notes = 'Interface description names a captured device'
            }
            else {
                $keyword = $keywordMatch.Groups[1].Value
                $label = 'Possible device ({0})' -f $keyword
                $node = @($state.Nodes | Where-Object { $_.Kind -eq 'PossibleDevice' -and $_.Label -eq $label } | Select-Object -First 1)
                if ($node.Count -eq 0) { $node = Add-MTAutoDrawEvidenceNode -State $state -Kind 'PossibleDevice' -Label $label }
                else { $node = $node[0] }
                $notes = 'Description-only clue; attachment and identity are not proven'
            }
            $learned = if ($camTable.ContainsKey($portKey)) { @($camTable[$portKey]).Count } else { 0 }
            Add-MTAutoDrawEvidenceEdge -State $state -Node $node -SourceHostname $sourceDevice.hostname -SourceInterface $interface.Interface -Confidence 'Ambiguous' -Directness 'NotProven' -EvidenceSources ('Desc:{0}' -f $description) -InterfaceDescription $description -LearnedMacCount $learned -CandidateCount 1 -Notes $notes | Out-Null
        }
    }

    return [pscustomobject]@{
        Nodes = @($state.Nodes | Sort-Object NodeId)
        Edges = @($state.Edges | Sort-Object EvidenceId)
        Rows  = @($state.Rows | Sort-Object EvidenceId,NodeKind,TargetLabel,EvidenceSources)
    }
}

#endregion Inferred topology evidence model

#region Topology Overview - observed unresolved LLDP peers

function Test-MTAutoDrawInterfaceNetworkFacing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Interface,
        [AllowNull()]$Device = $null
    )

    if (-not $Interface) { return $false }
    $mode = ([string]$Interface.SwitchportMode).Trim()
    if ($mode -match '(?i)trunk') { return $true }
    if ([string]$Interface.ChannelGroup) { return $true }
    if ([string]$Interface.STRole -match '(?i)^(root|alt|alternate)$') { return $true }

    # Some parsers populate only the per-instance root-port field, not Interface.STRole.
    if ($Device -and $Device.SpanningTree) {
        $interfaceKey = ConvertTo-NormalizedInterfaceIdentity $Interface.Interface
        foreach ($instance in @($Device.SpanningTree.SpanningTreeArray | Where-Object { $_ })) {
            if ((ConvertTo-NormalizedInterfaceIdentity $instance.RootBridgePort) -eq $interfaceKey) { return $true }
        }
    }
    return $false
}

$script:GMTAutoDrawEndpointNamePattern = '(?i)(?:^|[^a-z0-9])(?:axis|camera|ip-?phone|phone|polycom|printer|handheld|thin-?client|voip|wlan-?ap|access-?point)(?:[^a-z0-9]|$)'

# Collects the set of LLDP-observed peers for a device, de-duplicated and normalised.
function Get-MTAutoDrawObservedLldpPeers {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Device)

    $peers = [System.Collections.Generic.List[object]]::new()
    foreach ($neighbor in @($Device.LLDPNeighbors | Where-Object { $_ })) {
        if ($neighbor.Ignored -or $neighbor.TargetHostname) { continue }
        # Resolve-MTAutoDrawConfiguredNeighborLinks deliberately leaves an LLDP entry unresolved
        # (blank TargetHostname, not Ignored) when a CDP neighbor on the same local port already
        # covers the same physical link, so the link isn't drawn twice. That blank must not be
        # mistaken for a genuinely unknown peer here, or the CDP-resolved device gets a second,
        # confusing "unknown peer" placeholder alongside its real, already-drawn node.
        $coveredByCdp = @($Device.CDPNeighbors | Where-Object {
            $_.TargetHostname -and
            (ConvertTo-NormalizedInterfaceIdentity $_.InterfaceLocalDevice) -eq (ConvertTo-NormalizedInterfaceIdentity $neighbor.InterfaceLocalDevice)
        }).Count -gt 0
        if ($coveredByCdp) { continue }
        $peerName = ([string]$neighbor.Hostname).Trim()
        if (-not $peerName -or -not $neighbor.InterfaceLocalDevice) { continue }

        $sourceInterface = $Device.interfaces | Where-Object {
            (ConvertTo-NormalizedInterfaceIdentity $_.Interface) -eq
                (ConvertTo-NormalizedInterfaceIdentity $neighbor.InterfaceLocalDevice)
        } | Select-Object -First 1
        if (-not $sourceInterface) { continue }

        $networkFacing = Test-MTAutoDrawInterfaceNetworkFacing -Interface $sourceInterface -Device $Device
        $advertisesSwitch = [bool]([string]$neighbor.Capabilities -match '(?i)(bridge|router|repeater)')
        $isEndpoint = [bool](-not $advertisesSwitch -and $peerName -match $script:GMTAutoDrawEndpointNamePattern)
        $chassisKey = ConvertTo-NormalizedMacIdentity $neighbor.ChassisID
        if (-not $chassisKey) { $chassisKey = ([string]$neighbor.ChassisID).Trim().ToLowerInvariant() }
        $peerKey = if ($chassisKey) { "chassis|$chassisKey" } else { "name|$($peerName.ToLowerInvariant())" }

        $peers.Add([pscustomobject][ordered]@{
            SourceDevice        = $Device
            SourceHostname      = [string]$Device.hostname
            SourceInterface     = [string]$neighbor.InterfaceLocalDevice
            PeerHostname        = $peerName
            PeerPortID          = [string]$neighbor.PortID
            PeerPortIDSubtype   = [string]$neighbor.PortIDSubtype
            PeerRemoteInterface = [string]$neighbor.InterfaceRemoteDevice
            PeerCapabilities    = [string]$neighbor.Capabilities
            NetworkFacing       = [bool]$networkFacing
            AdvertisesSwitch    = $advertisesSwitch
            IsEndpoint          = $isEndpoint
            PeerKey             = $peerKey
            RecordKey           = ($neighbor.InterfaceLocalDevice,$neighbor.ChassisID,$neighbor.PortID,$peerName) -join '|'
            IncludeOnOverview   = [bool](($networkFacing -or $advertisesSwitch) -and -not $isEndpoint)
        })
    }
    return @($peers)
}

#endregion Topology Overview - observed unresolved LLDP peers

#region Topology Overview - end-unit collapsing
# An "end unit" is a node with exactly one link AND no configuration of its own: an observed LLDP
# peer such as an access point, or an inferred-evidence node standing for something we only deduced.
# Several end units under one parent convey the same topology fact and can share one block and link,
# reducing ring demand without losing structure.
#
# A CONFIGURED DEVICE IS NEVER AN END UNIT, however few links it has. Its tier, STP-root/security
# flags, degree, and individual edges require a full card. The caller provides the eligible key set
# through -CollapsibleKeys.
#
# Block width consumes ring circumference; block height consumes radial space. The layout modes expose
# that trade-off without changing which nodes qualify.

# Which nodes are end units, grouped by the single node they hang off.
# Returns @( @{ Parent; Members = @(keys) } ), only for groups of at least $Threshold.
function Get-MTAutoDrawEndUnitGroups {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] [hashtable]$Adjacency,
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Keys,
        # The only keys allowed to BECOME members. Every key in $Keys still counts towards degree and
        # towards who qualifies as a parent - narrowing $Keys instead would change every parent's
        # degree and silently re-qualify or disqualify genuine peers. This is purely an eligibility
        # filter, and it is what keeps configured devices out of blocks.
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$CollapsibleKeys,
        # A lone end unit is left alone: replacing one card with one block saves nothing and costs
        # the reader a level of indirection.
        [int]$Threshold = 2
    )

    $allKeys = @($Keys | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
    if ($allKeys.Count -eq 0) { return , @() }
    $keySet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($key in $allKeys) { [void]$keySet.Add($key) }

    # Symmetric, restricted to the keys actually being placed - a link is a link whichever side
    # reported it, matching how Get-DrawioConnectedComponents reads the same adjacency.
    $neighbors = @{}
    foreach ($key in $allKeys) { $neighbors[$key] = [System.Collections.Generic.HashSet[string]]::new() }
    foreach ($key in @($Adjacency.Keys)) {
        $from = [string]$key
        if (-not $keySet.Contains($from)) { continue }
        foreach ($peer in @($Adjacency[$key])) {
            $to = [string]$peer
            if (-not $to -or $to -eq $from -or -not $keySet.Contains($to)) { continue }
            [void]$neighbors[$from].Add($to)
            [void]$neighbors[$to].Add($from)
        }
    }

    $collapsibleSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($key in @($CollapsibleKeys | Where-Object { $null -ne $_ })) { [void]$collapsibleSet.Add([string]$key) }

    $byParent = @{}
    foreach ($key in $allKeys) {
        if (-not $collapsibleSet.Contains($key)) { continue }
        if ($neighbors[$key].Count -ne 1) { continue }
        $parent = @($neighbors[$key])[0]
        # A parent that is itself an end unit means a two-node component - a pair, not a parent with
        # dependants - and collapsing either half of it would be nonsense.
        if ($neighbors[$parent].Count -le 1) { continue }
        if (-not $byParent.ContainsKey($parent)) { $byParent[$parent] = [System.Collections.Generic.List[string]]::new() }
        $byParent[$parent].Add($key)
    }

    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($parent in @($byParent.Keys | Sort-Object)) {
        if ($byParent[$parent].Count -lt [Math]::Max(2, $Threshold)) { continue }
        $groups.Add([pscustomobject]@{ Parent = $parent; Members = @($byParent[$parent] | Sort-Object) })
    }
    return , @($groups)
}

# Size and text rows for one end-unit block, from the mode and the members.
#
# $Members is @( @{Title; Detail} ). The four modes differ only in how many members share a line,
# which is what moves the block's cost between circumference and radius:
#   Stack  one per line   - narrowest, tallest.  Cheapest on circumference, dearest on radius.
#   Grid   sqrt per line  - the middle.
#   Wide   all on one line- widest, shortest.    The reverse trade.
#   Chip   none listed    - a count only. Smallest possible; the names leave the page entirely.
function Get-MTAutoDrawEndUnitBlockLayout {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] [ValidateSet('Stack', 'Grid', 'Wide', 'Chip')] [string]$Mode,
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Members
    )

    $count = @($Members).Count
    $columnWidth = 150.0
    $lineHeight = 15.0
    $headerHeight = 18.0
    $padding = 12.0

    if ($Mode -eq 'Chip' -or $count -eq 0) {
        return [pscustomobject]@{
            Width = 180.0; Height = 46.0
            Lines = @("$count uncaptured neighbours")
        }
    }

    $columns = switch ($Mode) {
        'Stack' { 1 }
        'Wide'  { $count }
        default { [int][Math]::Ceiling([Math]::Sqrt($count)) }
    }
    $columns = [Math]::Max(1, [Math]::Min($columns, $count))
    $rows = [int][Math]::Ceiling($count / [double]$columns)

    $cells = @($Members | ForEach-Object {
        $title = [string]$_.Title
        $detail = [string]$_.Detail
        if ($detail) { "$title ($detail)" } else { $title }
    })
    $lines = @()
    for ($r = 0; $r -lt $rows; $r++) {
        $slice = @($cells | Select-Object -Skip ($r * $columns) -First $columns)
        # Plain text only - no markup and no HTML entities. The caller encodes the whole block in one
        # go, the way every other shape on this page does, so anything pre-encoded here would come out
        # double-encoded and visible as literal "&#183;".
        if ($slice.Count -gt 0) { $lines += ($slice -join '  /  ') }
    }

    return [pscustomobject]@{
        Width = $padding + ($columns * $columnWidth)
        Height = $headerHeight + ($rows * $lineHeight) + $padding
        Lines = $lines
    }
}

#endregion Topology Overview - end-unit collapsing

#region Firewall policy models
# Canonical security-device list shared by topology flags, per-firewall page selection, and tests.
function Get-MTAutoDrawSecurityDeviceTypes {
    [CmdletBinding()]
    param()
    return @('CheckPoint', 'CiscoASA', 'PaloAlto', 'Fortigate')
}


# Two pure models over $Device.SecurityPolicy, shared by the FW Zone Hub and FW Rule Risk pages.
# They return data and draw nothing, which is what lets both pages agree on what a zone is and how
# many rules govern it. All three parsing vendors normalise Action to 'allow' before it gets here,
# so nothing below branches per vendor.


# Zone-level view of a rulebase: which zone pairs carry policy, and how much policy each zone carries.
#
# Two different shapes come out of this, because the vendors do not agree on what a rule says:
#
#   Pairs       zone-to-zone, populated only when a rule names both a source and a destination zone.
#               PAN-OS and FortiGate fill this; ASA cannot, because an ACL is bound inbound to one
#               interface and says nothing about where traffic leaves.
#   ZoneTotals  per zone, counting a rule against every zone it names in either direction. This is
#               populated for all three vendors, and is what the Zone Hub spokes are labelled with -
#               the deliberate reason the Hub does not depend on Pairs.
function Get-MTAutoDrawZonePolicyModel {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Device)

    $rules = @($Device.SecurityPolicy | Where-Object { $_ })
    $pairs = @{}
    $zoneTotals = @{}
    $involvement = @{}

    # Blocked is anything not explicitly permitted: deny, drop, and the reset-* actions.
    $addTotal = {
        param([string]$Zone, [bool]$IsAllow)
        if (-not $zoneTotals.ContainsKey($Zone)) {
            $zoneTotals[$Zone] = [pscustomobject]@{ Zone = $Zone; Allow = 0; Deny = 0 }
        }
        if ($IsAllow) { $zoneTotals[$Zone].Allow++ } else { $zoneTotals[$Zone].Deny++ }
    }

    foreach ($rule in $rules) {
        $fromZones = @($rule.FromZones | Where-Object { $_ })
        $toZones   = @($rule.ToZones | Where-Object { $_ })
        $isAllow   = ([string]$rule.Action -eq 'allow')

        # Per-zone totals first, so a rule naming only one side still counts. A rule naming the same
        # zone on both sides (intra-zone) counts once, not twice.
        foreach ($zone in @(@($fromZones) + @($toZones) | Select-Object -Unique)) {
            & $addTotal ([string]$zone) $isAllow
            if (-not $involvement.ContainsKey([string]$zone)) { $involvement[[string]$zone] = 0 }
            $involvement[[string]$zone]++
        }

        # Pair counts need both ends; a rule spanning 3 source and 2 destination zones is really 6
        # statements about the segmentation model, so it is expanded into all 6.
        if ($fromZones.Count -eq 0 -or $toZones.Count -eq 0) { continue }
        foreach ($fromZone in $fromZones) {
            foreach ($toZone in $toZones) {
                $key = '{0}>{1}' -f $fromZone, $toZone
                if (-not $pairs.ContainsKey($key)) {
                    $pairs[$key] = [pscustomobject]@{ From = [string]$fromZone; To = [string]$toZone; Allow = 0; Deny = 0 }
                }
                if ($isAllow) { $pairs[$key].Allow++ } else { $pairs[$key].Deny++ }
            }
        }
    }

    # Busiest zones first, so the structure that matters sits where the eye starts. 'any' sorts last
    # regardless: it is a wildcard, not a place in the network.
    $orderedZones = @($involvement.Keys |
        Sort-Object @{ Expression = { if ($_ -ieq 'any') { 1 } else { 0 } } },
                    @{ Expression = { -1 * $involvement[$_] } },
                    @{ Expression = { $_ } })

    # Zones configured on an interface but never named by a rule. Worth stating plainly: it is either
    # dead configuration or a segment with no policy governing it.
    $interfaceZones = @($Device.interfaces | Where-Object { $_.Zone } | Select-Object -ExpandProperty Zone -Unique)
    $zonesWithoutPolicy = @($interfaceZones | Where-Object { -not $involvement.ContainsKey([string]$_) } | Sort-Object)

    return [pscustomobject]@{
        Zones              = $orderedZones
        Pairs              = $pairs
        ZoneTotals         = $zoneTotals
        RuleCount          = $rules.Count
        AllowCount         = @($rules | Where-Object { [string]$_.Action -eq 'allow' }).Count
        DenyCount          = @($rules | Where-Object { [string]$_.Action -ne 'allow' }).Count
        PopulatedPairCount = $pairs.Count
        ZonesWithoutPolicy = $zonesWithoutPolicy
        HasPolicy          = ($rules.Count -gt 0)
    }
}


# The rules worth arguing about, bucketed by why. Ordered most severe first, which is the order the
# risk page draws them in.
#
# Only allow rules can be over-permissive, so every bucket except the last two is filtered to
# Action 'allow' - a deny that matches everything is a default-deny, which is the correct thing for a
# rulebase to end with rather than a finding.
function Get-MTAutoDrawPolicyRiskModel {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Device)

    $rules = @($Device.SecurityPolicy | Where-Object { $_ })
    $zoneModel = Get-MTAutoDrawZonePolicyModel -Device $Device

    # Object groups that resolve to 'any' (ASA). This is what turns 'permit ip any object-group
    # PARTNERS' from a scoped-looking rule into a finding, and it is the reason the object groups are
    # parsed at all.
    $anyGroups = @{}
    foreach ($group in @($Device.PolicyObjectGroups | Where-Object { $_ -and $_.ContainsAny })) {
        $anyGroups[[string]$group.Name] = $true
    }

    # A field is effectively 'any' when it literally says so, or when every entry it names is a group
    # that resolves to any. 'all' is the FortiGate spelling.
    $isEffectivelyAny = {
        param($Values)
        $entries = @($Values | Where-Object { $_ })
        if ($entries.Count -eq 0) { return $false }
        foreach ($entry in $entries) {
            $text = [string]$entry
            if ($text -match '(?i)^(any[46]?|all)$') { return $true }
            # 'object-group PARTNERS' / 'object PARTNERS' - test the name, not the keyword.
            if ($text -match '(?i)^object(-group)?\s+(?<name>\S+)$' -and $anyGroups.ContainsKey($Matches['name'])) { return $true }
            if ($anyGroups.ContainsKey($text)) { return $true }
        }
        return $false
    }

    # Whether a rule permits every protocol. Each vendor spells this differently, and PAN-OS does not
    # spell it as a word at all: its application/service entries encode as '0:any/any/any/app-default'
    # (index:application/protocol/source-port/destination-port), so the application has to be pulled
    # out of the first field before it can be compared. Missing that is the difference between this
    # bucket finding PAN-OS rules and finding none of them.
    $isAnyService = {
        param($Values)
        $entries = @($Values | Where-Object { $_ })
        if ($entries.Count -eq 0) { return $false }
        foreach ($entry in $entries) {
            $text = [string]$entry
            if ($text -match '^\d+:(?<app>[^/]+)') { $text = $Matches['app'] }
            if ($text -match '(?i)^(any[46]?|all|ip)$') { return $true }
        }
        return $false
    }

    $allows = @($rules | Where-Object { [string]$_.Action -eq 'allow' -and -not $_.Disabled })

    # 1. Zone pair wide open: permits traffic from anywhere to anywhere, regardless of addresses.
    $anyZoneToAnyZone = @($allows | Where-Object {
        @($_.FromZones) -contains 'any' -and @($_.ToZones) -contains 'any'
    })

    # 2. A named zone pair with nothing restricting it: both address fields and the service are all
    #    'any', so the rule says "these two zones may do anything to each other".
    #
    #    Requiring the service to be open as well as the addresses is what makes this bucket mean
    #    something on PAN-OS. Leaving source and destination as 'any' and letting the zone pair carry
    #    the restriction is ordinary PAN-OS practice, and a large fraction of a typical rulebase is
    #    written that way - so flagging address breadth alone reports the house style, not a finding.
    $fullyOpenPair = @($allows | Where-Object {
        $_ -notin $anyZoneToAnyZone -and
        (& $isEffectivelyAny $_.Source) -and (& $isEffectivelyAny $_.Destination) -and (& $isAnyService $_.Application)
    })

    # 3. Every protocol permitted with at least one side unrestricted - 'permit ip any host X'.
    #    Narrower than the two above, and deliberately does NOT include a host-to-host 'permit ip':
    #    all-protocols between two named hosts is normal, and 21 of the 178 ASA rules are exactly
    #    that, which would swamp the page with rules nobody needs to look at.
    $anyServiceBroadSide = @($allows | Where-Object {
        $_ -notin $anyZoneToAnyZone -and $_ -notin $fullyOpenPair -and
        (& $isAnyService $_.Application) -and
        ((& $isEffectivelyAny $_.Source) -or (& $isEffectivelyAny $_.Destination))
    })

    $disabled = @($rules | Where-Object { $_.Disabled })

    return [pscustomobject]@{
        HasPolicy            = ($rules.Count -gt 0)
        RuleCount            = $rules.Count
        AnyZoneToAnyZone     = $anyZoneToAnyZone
        FullyOpenPair        = $fullyOpenPair
        AnyServiceBroadSide  = $anyServiceBroadSide
        Disabled             = $disabled
        ZonesWithoutPolicy   = $zoneModel.ZonesWithoutPolicy
        FindingCount         = ($anyZoneToAnyZone.Count + $fullyOpenPair.Count + $anyServiceBroadSide.Count + $disabled.Count + @($zoneModel.ZonesWithoutPolicy).Count)
    }
}
#endregion
