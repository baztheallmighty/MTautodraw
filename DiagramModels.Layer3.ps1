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


# MTAutoDraw - Diagram models: Layer 3
#
# The Layer 3 Connectivity, Routes Summary and Topology Overview page models - who depends on whom
# at layer 3, collapsed and summarised before anything is drawn. Split out of DiagramModels.ps1,
# which holds the topology-evidence, LLDP-peer, end-unit and firewall-policy models; the remaining
# per-page models are in DiagramModels.Pages.ps1. A model here never touches the .drawio document.
#
# Depends on: nothing
# Loaded by:  AutoDraw.ps1 ($GLibrariesToLoad)

# Returns the normalized, order-independent routed behavior of one device. Interface route records
# are the source of truth for the detailed pages because they retain the egress-interface grouping;
# RoutingTable is folded in as a fallback/additional source for vendors whose parser only populated
# the device-wide table. Duplicate facts disappear in the normalized key.
function Get-MTAutoDrawL3RouteBehavior {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        # Routes Only deliberately keeps the historical resolve-pass scope: only interfaces marked
        # DrawOnRoutesOnlyDiagram contribute facts.
        [switch]$RoutesOnly
    )

    $factsByKey = @{}
    $localProtocolPattern = 'connect|host|Access-internal|local|connected|direct'
    $interfaces = if ($RoutesOnly) {
        @($Device.interfaces | Where-Object { $_.DrawOnRoutesOnlyDiagram })
    }
    else { @($Device.interfaces | Where-Object { $_ }) }

    foreach ($interface in $interfaces) {
        foreach ($route in @($interface.RoutesForInterface | Where-Object { $_ })) {
            $gateway = ([string]$route.gateway).Trim()
            $protocol = ([string]$route.RouteProtocol).Trim()
            if (-not $gateway -or $gateway -eq '0.0.0.0' -or $gateway -match '^(?i:null|none)$') { continue }
            if ($protocol -match $localProtocolPattern) { continue }
            $destination = ([string]$route.subnet).Trim()
            $isDefault = [bool]($route.defaultgateway -or $destination -match '^0\.0\.0\.0(?:/0)?$')
            $isStandby = [bool]($route.PSObject.Properties['Standby'] -and $route.Standby)
            $key = '{0}>{1}>{2}>d:{3}>s:{4}' -f $destination, $gateway, $protocol.ToLowerInvariant(), ([int]$isDefault), ([int]$isStandby)
            if (-not $factsByKey.ContainsKey($key)) {
                $factsByKey[$key] = [pscustomobject]@{
                    Key = $key; Destination = $destination; Gateway = $gateway; Protocol = $protocol
                    IsDefault = $isDefault; IsStandby = $isStandby; Interface = [string]$interface.Interface
                    Route = $route
                }
            }
        }
    }

    if (-not $RoutesOnly) {
        foreach ($route in @($Device.RoutingTable | Where-Object { $_ })) {
            $gateway = ([string]$route.gateway).Trim()
            $protocol = ([string]$route.RouteProtocol).Trim()
            if (-not $gateway -or $gateway -eq '0.0.0.0' -or $gateway -match '^(?i:null|none)$') { continue }
            if ($protocol -match $localProtocolPattern) { continue }
            $destination = ([string]$route.Subnet).Trim()
            $isDefault = [bool]($route.defaultgateway -or $destination -match '^0\.0\.0\.0(?:/0)?$')
            $isStandby = [bool]($route.PSObject.Properties['Standby'] -and $route.Standby)
            $key = '{0}>{1}>{2}>d:{3}>s:{4}' -f $destination, $gateway, $protocol.ToLowerInvariant(), ([int]$isDefault), ([int]$isStandby)
            if (-not $factsByKey.ContainsKey($key)) {
                $factsByKey[$key] = [pscustomobject]@{
                    Key = $key; Destination = $destination; Gateway = $gateway; Protocol = $protocol
                    IsDefault = $isDefault; IsStandby = $isStandby; Interface = [string]$route.interface
                    Route = $route
                }
            }
        }
    }

    $facts = @($factsByKey.Values | Sort-Object Key)
    return [pscustomobject]@{
        Facts = $facts
        Signature = (@($facts.Key) -join ',')
        Gateways = @($facts | Select-Object -ExpandProperty Gateway -Unique | Sort-Object)
        Protocols = @($facts | Select-Object -ExpandProperty Protocol -Unique | Where-Object { $_ } | Sort-Object)
        HasDefaultRoute = [bool](@($facts | Where-Object IsDefault).Count -gt 0)
    }
}

# Chooses the ordered centre preference for a directed Layer-3 relationship graph. Routing role is
# authoritative; displayed relationship degree only breaks ties inside that role. A second centre
# is returned only for a directly-connected peer in the same role whose degree is at least half the
# primary's, matching the redundant-core-pair rule used by the radial solver.
function Get-MTAutoDrawL3PreferredCenters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Nodes,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Edges
    )

    $nodeByKey = @{}
    $neighbors = @{}
    foreach ($node in @($Nodes | Where-Object { $_ -and $_.Key })) {
        $key = [string]$node.Key
        $nodeByKey[$key] = $node
        $neighbors[$key] = [System.Collections.Generic.HashSet[string]]::new()
    }
    foreach ($edge in @($Edges | Where-Object { $_ })) {
        $from = [string]$edge.SourceKey; $to = [string]$edge.TargetKey
        if (-not $neighbors.ContainsKey($from) -or -not $neighbors.ContainsKey($to) -or $from -eq $to) { continue }
        [void]$neighbors[$from].Add($to); [void]$neighbors[$to].Add($from)
    }

    $ranked = @($nodeByKey.Values | Where-Object { $neighbors[[string]$_.Key].Count -gt 0 } | ForEach-Object {
        $roleRank = if (-not $_.IsConfigured) { 4 }
            elseif ([string]$_.Role -eq 'Border' -or $_.IsSecurity) { 0 }
            elseif ([string]$_.Role -eq 'Transit') { 1 }
            elseif ([string]$_.Role -eq 'Gateway') { 2 }
            else { 3 }
        [pscustomobject]@{
            Key = [string]$_.Key; RoleRank = $roleRank
            Degree = $neighbors[[string]$_.Key].Count
        }
    } | Sort-Object RoleRank, @{Expression={-1*$_.Degree}}, Key)
    if ($ranked.Count -eq 0) { return @() }

    $primary = $ranked[0]
    $centers = [System.Collections.Generic.List[string]]::new()
    $centers.Add($primary.Key)
    foreach ($candidate in @($ranked | Select-Object -Skip 1)) {
        if ($candidate.RoleRank -ne $primary.RoleRank) { break }
        if ($candidate.Degree -lt ($primary.Degree * 0.5)) { continue }
        if (-not $neighbors[$primary.Key].Contains($candidate.Key)) { continue }
        $centers.Add($candidate.Key)
        break
    }
    return @($centers)
}

# Pure model for the two subnet-bearing detail pages. Devices collapse only when every routed fact
# and every CIDR visible on that page match. Host/interface/IP rows remain attached to the block so
# the renderer can preserve the addressing facts without drawing one duplicate host card per member.
function Get-MTAutoDrawL3DetailPageModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Devices,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Networks,
        [AllowEmptyCollection()]$GatewayHosts = @(),
        [ValidateSet('All', 'RoutedLinksOnly')][string]$Mode = 'All'
    )

    $drawableNetworks = @($Networks | Where-Object {
        $_ -and ($Mode -eq 'All' -or $_.NumberOfConnectors -ge 2 -or $_.NumberOfRoutedConnectors -gt 0)
    } | Sort-Object Cidr)
    $networkByCidr = @{}
    foreach ($network in $drawableNetworks) {
        $cidr = [string]$network.Cidr
        if ($cidr -and -not $networkByCidr.ContainsKey($cidr)) { $networkByCidr[$cidr] = $network }
    }

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($device in @(@($Devices) + @($GatewayHosts) | Where-Object { $_ } | Sort-Object HostName)) {
        $isGatewayHost = [bool](@($GatewayHosts | Where-Object { $_ -eq $device }).Count -gt 0)
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($interface in @($device.interfaces | Where-Object { -not $_.shutdown })) {
            foreach ($address in @(Get-MTAutoDrawInterfaceIPv4Address -Interface $interface | Where-Object { $_.IPAddress })) {
                $cidr = [string]$address.Cidr
                if ($Mode -eq 'RoutedLinksOnly' -and (-not $cidr -or -not $networkByCidr.ContainsKey($cidr))) { continue }
                $rows.Add([pscustomobject]@{
                    HostName = [string]$device.HostName; Interface = [string]$interface.Interface
                    IPAddress = [string]$address.IPAddress; Cidr = $cidr; InterfaceObject = $interface
                })
            }
        }
        $behavior = Get-MTAutoDrawL3RouteBehavior -Device $device
        $visibleCidrs = @($rows | Select-Object -ExpandProperty Cidr -Unique | Where-Object { $_ } | Sort-Object)
        $signature = 'kind:{0}|routes:{1}|cidrs:{2}' -f $(if ($isGatewayHost) { 'gateway' } else { 'configured' }), $behavior.Signature, ($visibleCidrs -join ',')
        $records.Add([pscustomobject]@{
            Device = $device; HostName = [string]$device.HostName; Rows = @($rows)
            VisibleCidrs = $visibleCidrs; Behavior = $behavior; Signature = $signature; IsGatewayHost = $isGatewayHost
        })
    }

    $blocks = [System.Collections.Generic.List[object]]::new()
    $blockIndex = 0
    foreach ($group in @($records | Group-Object Signature | Sort-Object Name)) {
        $members = @($group.Group | Sort-Object HostName)
        $blocks.Add([pscustomobject]@{
            Key = "device:$blockIndex"; Signature = [string]$group.Name; Members = $members
            HostNames = @($members.HostName); VisibleCidrs = @($members[0].VisibleCidrs)
            Behavior = $members[0].Behavior; IsSummary = ($members.Count -gt 1); IsGatewayHost = $members[0].IsGatewayHost
        })
        $blockIndex++
    }

    $edges = [System.Collections.Generic.List[object]]::new()
    foreach ($block in $blocks) {
        foreach ($cidr in $block.VisibleCidrs) {
            if (-not $networkByCidr.ContainsKey([string]$cidr)) { continue }
            $memberRows = @($block.Members | ForEach-Object { $_.Rows } | Where-Object { [string]$_.Cidr -eq [string]$cidr } | Sort-Object HostName, Interface, IPAddress)
            $edges.Add([pscustomobject]@{
                SourceKey = $block.Key; TargetKey = "network:$cidr"; Cidr = [string]$cidr; MemberRows = $memberRows
            })
        }
    }

    return [pscustomobject]@{ Blocks = @($blocks); Networks = $drawableNetworks; Edges = @($edges) }
}

# Pure model for Layer 3 Routes Only. Kept here rather than in DrawLogic so the route signature is
# shared and directly testable. A multi-member block carries no individual interface cards.
function Get-MTAutoDrawL3RoutesOnlyModel {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Devices, $GatewayHosts)

    $allHosts = @(@($Devices) + @($GatewayHosts) | Where-Object { $_ })
    $gatewayIndex = New-MTAutoDrawGatewayIndex -Devices $allHosts
    $records = foreach ($device in $allHosts) {
        [pscustomobject]@{ Device = $device; HostName = [string]$device.HostName; Behavior = (Get-MTAutoDrawL3RouteBehavior -Device $device -RoutesOnly) }
    }

    $blocks = [System.Collections.Generic.List[object]]::new()
    $hostnameToBlockKey = @{}
    $blockIndex = 0
    foreach ($group in @($records | Where-Object { $_.Behavior.Signature } | Group-Object { $_.Behavior.Signature } | Sort-Object Name)) {
        $members = @($group.Group | Sort-Object HostName)
        $representative = $members[0].Behavior
        $gatewayMap = @{}
        foreach ($gateway in $representative.Gateways) {
            $gatewayMap[$gateway] = @($representative.Facts | Where-Object { $_.Gateway -eq $gateway } | ForEach-Object { $_.Route })
        }
        $key = "block:$blockIndex"; $blockIndex++
        $block = [pscustomobject]@{
            Key = $key; Members = @($members.Device); Gateways = $gatewayMap
            Protocols = $representative.Protocols; HasDefaultRoute = $representative.HasDefaultRoute
        }
        $blocks.Add($block)
        foreach ($member in $members) { $hostnameToBlockKey[$member.HostName] = $key }
    }
    # A route-less device belongs on this page only when another route resolves to it. Keep those
    # target-only identities as compact endpoints; every other route-less device is represented by
    # one footer summary instead of an isolated host card.
    $recordByHost = @{}
    foreach ($record in $records) { $recordByHost[$record.HostName] = $record }
    $targetGatewayByHost = @{}
    foreach ($block in $blocks) {
        foreach ($gateway in @($block.Gateways.Keys)) {
            if (-not $gatewayIndex.ContainsKey([string]$gateway)) { continue }
            $targetHost = [string]$gatewayIndex[[string]$gateway]
            if ($hostnameToBlockKey.ContainsKey($targetHost)) { continue }
            if (-not $targetGatewayByHost.ContainsKey($targetHost)) {
                $targetGatewayByHost[$targetHost] = [System.Collections.Generic.List[string]]::new()
            }
            if ($targetGatewayByHost[$targetHost] -notcontains [string]$gateway) {
                $targetGatewayByHost[$targetHost].Add([string]$gateway)
            }
        }
    }

    $targetOnly = [System.Collections.Generic.List[object]]::new()
    $hostnameToTargetKey = @{}
    foreach ($targetHost in @($targetGatewayByHost.Keys | Sort-Object)) {
        if (-not $recordByHost.ContainsKey($targetHost)) { continue }
        $key = "target:$targetHost"
        $targetOnly.Add([pscustomobject]@{
            Key = $key; HostName = $targetHost; Device = $recordByHost[$targetHost].Device
            Gateways = @($targetGatewayByHost[$targetHost] | Sort-Object)
        })
        $hostnameToTargetKey[$targetHost] = $key
    }

    $unrouted = @($records | Where-Object {
        -not $_.Behavior.Signature -and -not $hostnameToTargetKey.ContainsKey($_.HostName)
    } | Select-Object -ExpandProperty HostName | Sort-Object)

    return [pscustomobject]@{
        Blocks = @($blocks); TargetOnly = @($targetOnly); Unrouted = $unrouted
        GatewayIndex = $gatewayIndex; HostnameToBlockKey = $hostnameToBlockKey
        HostnameToTargetKey = $hostnameToTargetKey
    }
}

# Builds the model behind the Layer 3 Connectivity page: who depends on whom at layer 3, with
# identical dependants collapsed.
#
# The collapse is the whole point. Routing tables are overwhelmingly repetitive: on a typical site
# most devices carry the exact same single default route, and on a switched site most carry no
# routed entries at all. Drawing one node per device there is drawing the same fact dozens of times
# and burying the handful of devices that genuinely differ. Devices whose entire significant-route
# set is identical therefore share one node, labelled with the count.
#
# Configured devices used as next hops are composite nodes and are never also members of a collapsed
# group. Each composite owns its gateway-address panels and its optional outbound-route panel.
function Get-MTAutoDrawL3ConnectivityModel {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Devices)

    $allDevices = @($Devices | Where-Object { $_ })
    $gatewayIndex = New-MTAutoDrawGatewayIndex -Devices $allDevices

    $recordByHost = @{}
    $hubByAddress = @{}
    foreach ($device in $allDevices) {
        $hostname = [string]$device.hostname
        if (-not $hostname) { continue }
        $behavior = Get-MTAutoDrawL3RouteBehavior -Device $device
        $recordByHost[$hostname] = [pscustomobject]@{ Device = $device; HostName = $hostname; Behavior = $behavior }
        foreach ($gateway in $behavior.Gateways) {
            if (-not $hubByAddress.ContainsKey($gateway)) {
                $resolvedHost = if ($gatewayIndex.ContainsKey($gateway)) { [string]$gatewayIndex[$gateway] } else { $null }
                $hubByAddress[$gateway] = [pscustomobject]@{
                    Key = $(if ($resolvedHost) { "hub:$resolvedHost`:$gateway" } else { "external:$gateway" })
                    Address = [string]$gateway; DeviceName = $resolvedHost; IsConfigured = [bool]$resolvedHost
                    DependantCount = 0; SourceHosts = [System.Collections.Generic.List[string]]::new()
                }
            }
            if ($hubByAddress[$gateway].SourceHosts -notcontains $hostname) {
                $hubByAddress[$gateway].SourceHosts.Add($hostname)
                $hubByAddress[$gateway].DependantCount++
            }
        }
    }

    $configuredHubHosts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($hub in $hubByAddress.Values) { if ($hub.IsConfigured) { [void]$configuredHubHosts.Add([string]$hub.DeviceName) } }

    $deviceNodes = foreach ($hostname in @($configuredHubHosts | Sort-Object)) {
        $record = $recordByHost[$hostname]
        if (-not $record) { continue }
        [pscustomobject]@{
            Key = "device:$hostname"; HostName = $hostname; Device = $record.Device; Behavior = $record.Behavior
            HubPanels = @($hubByAddress.Values | Where-Object { $_.IsConfigured -and $_.DeviceName -ieq $hostname } | Sort-Object Address)
        }
    }

    $unrouted = [System.Collections.Generic.List[string]]::new()
    $bySignature = @{}
    foreach ($record in @($recordByHost.Values | Sort-Object HostName)) {
        if ($configuredHubHosts.Contains($record.HostName)) { continue }
        if (-not $record.Behavior.Signature) { $unrouted.Add($record.HostName); continue }
        if (-not $bySignature.ContainsKey($record.Behavior.Signature)) {
            $bySignature[$record.Behavior.Signature] = [pscustomobject]@{
                Key = ''; Signature = $record.Behavior.Signature; Devices = [System.Collections.Generic.List[string]]::new()
                Behavior = $record.Behavior; RouteCount = @($record.Behavior.Facts).Count
                Protocols = $record.Behavior.Protocols; HasDefaultRoute = $record.Behavior.HasDefaultRoute
            }
        }
        $bySignature[$record.Behavior.Signature].Devices.Add($record.HostName)
    }
    $groups = @($bySignature.Values | Sort-Object @{ Expression = { -1 * $_.Devices.Count } }, Signature)
    for ($i = 0; $i -lt $groups.Count; $i++) { $groups[$i].Key = "group:$i" }

    $sourceKeyByHost = @{}
    foreach ($node in $deviceNodes) { $sourceKeyByHost[$node.HostName] = $node.Key }
    foreach ($group in $groups) { foreach ($hostname in $group.Devices) { $sourceKeyByHost[$hostname] = $group.Key } }

    $edges = [System.Collections.Generic.List[object]]::new()
    foreach ($record in @($recordByHost.Values | Sort-Object HostName)) {
        if (-not $sourceKeyByHost.ContainsKey($record.HostName)) { continue }
        $sourceKey = $sourceKeyByHost[$record.HostName]
        foreach ($gatewayGroup in @($record.Behavior.Facts | Group-Object Gateway | Sort-Object Name)) {
            $hub = $hubByAddress[[string]$gatewayGroup.Name]
            if (-not $hub) { continue }
            $targetKey = if ($hub.IsConfigured) { "device:$($hub.DeviceName)" } else { $hub.Key }
            if ($targetKey -eq $sourceKey) { continue }
            # A collapsed group has identical facts by construction; emit the group edge once.
            if (@($edges | Where-Object { $_.SourceKey -eq $sourceKey -and $_.TargetKey -eq $targetKey -and $_.Gateway -eq $hub.Address }).Count -gt 0) { continue }
            $facts = @($gatewayGroup.Group)
            $edges.Add([pscustomobject]@{
                SourceKey = $sourceKey; TargetKey = $targetKey; Gateway = $hub.Address
                TargetPanelKey = $hub.Key; RouteCount = $facts.Count
                Protocols = @($facts.Protocol | Where-Object { $_ } | Sort-Object -Unique)
                HasDefault = [bool](@($facts | Where-Object IsDefault).Count -gt 0)
            })
        }
    }

    return [pscustomobject]@{
        DeviceNodes = @($deviceNodes | Sort-Object HostName)
        Groups = $groups
        ExternalHubs = @($hubByAddress.Values | Where-Object { -not $_.IsConfigured } | Sort-Object @{Expression={-1*$_.DependantCount}}, Address)
        Edges = @($edges)
        Unrouted = @($unrouted | Sort-Object)
        TotalDevices = $allDevices.Count
    }
}

# Pure model builder for the "Layer 3 Routes Summary" page - it returns data and draws nothing, so
# the draw function can be a thin loop over this output (same contract as
# Get-MTAutoDrawL3ConnectivityModel above).
#
# Three buckets, from the "which routes count" answer Get-MTAutoDrawSignificantRoutes already owns:
#
#   Unrouted       0 significant routes. Not drawn individually - one footer note for the lot.
#   SingleStatic   exactly 1 significant route, and that route is static-ish (see the
#                  $script:GMTAutoDrawStaticRouteProtocolPattern exact-match list). These collapse
#                  into StaticGroups below.
#   Individual     everything else - 2+ significant routes, or a single route from a dynamic
#                  protocol (OSPF/BGP/EIGRP/...), because such a device is a real routing node and
#                  must stay individually visible.
#
# StaticGroups deliberately group by RESOLVED NEXT HOP (gateway IP), not by destination subnet -
# that is the opposite of Get-MTAutoDrawL3ConnectivityModel's route-signature grouping on purpose:
# the question here is "who points where", so two devices with different destination subnets but
# the same next hop belong in the same box.
function Get-MTAutoDrawL3RoutesSummaryModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Devices
    )

    $allDevices = @($Devices | Where-Object { $_ })
    $gatewayIndex = New-MTAutoDrawGatewayIndex -Devices $allDevices

    $unrouted = [System.Collections.Generic.List[string]]::new()
    $individual = [System.Collections.Generic.List[object]]::new()
    $singleStatic = [System.Collections.Generic.List[object]]::new()

    foreach ($device in $allDevices) {
        $hostname = [string]$device.hostname
        if (-not $hostname) { continue }
        $routes = @(Get-MTAutoDrawSignificantRoutes -Device $device)
        if ($routes.Count -eq 0) { $unrouted.Add($hostname); continue }

        if ($routes.Count -eq 1) {
            $protocol = [string]$routes[0].RouteProtocol
            if ($protocol -match $script:GMTAutoDrawStaticRouteProtocolPattern) {
                $singleStatic.Add([pscustomobject]@{
                    Device = $device
                    HostName = $hostname
                    Gateway = [string]$routes[0].gateway
                    Subnet = [string]$routes[0].Subnet
                    Protocol = $protocol
                })
                continue
            }
        }
        # GatewayRoutes carries the per-next-hop data the draw function's device-level edges need
        # (count, protocol mix, default-route presence) without re-deriving the routes there.
        $gatewayRoutes = @(
            $routes | Group-Object gateway | ForEach-Object {
                [pscustomobject]@{
                    Gateway = [string]$_.Name
                    Count = $_.Count
                    Protocols = @($_.Group | Select-Object -ExpandProperty RouteProtocol -Unique | Where-Object { $_ } | Sort-Object)
                    HasDefault = [bool](@($_.Group | Where-Object { [string]$_.Subnet -match '^0\.0\.0\.0' }).Count -gt 0)
                }
            } | Sort-Object { $_.Gateway }
        )
        $individual.Add([pscustomobject]@{
            Device = $device
            HostName = $hostname
            RouteCount = $routes.Count
            Protocols = @($routes | Select-Object -ExpandProperty RouteProtocol -Unique | Where-Object { $_ } | Sort-Object)
            GatewayRoutes = $gatewayRoutes
        })
    }

    # Group-Object -Property gateway across the SingleStatic list (mirrors the per-interface idiom
    # Add-DrawioLayer3RouteConnectors-style code uses, applied across devices instead of within one
    # device).
    $staticGroups = foreach ($group in (@($singleStatic) | Group-Object -Property Gateway)) {
        $gateway = [string]$group.Name
        $members = @($group.Group | Sort-Object { $_.HostName })
        [pscustomobject]@{
            Gateway = $gateway
            GatewayHostName = if ($gatewayIndex.ContainsKey($gateway)) { $gatewayIndex[$gateway] } else { $null }
            GatewayIsConfigured = $gatewayIndex.ContainsKey($gateway)
            Devices = @($members | ForEach-Object { $_.HostName })
            DeviceCount = $members.Count
            DestinationSubnets = @($members | ForEach-Object { $_.Subnet } | Where-Object { $_ } | Sort-Object -Unique)
            Protocols = @($members | ForEach-Object { $_.Protocol } | Where-Object { $_ } | Sort-Object -Unique)
        }
    }
    # Busiest groups first, so a display cap keeps the next hops that describe the most devices.
    $staticGroups = @($staticGroups | Sort-Object @{ Expression = { -1 * $_.DeviceCount } }, @{ Expression = { $_.Gateway } })

    # Busiest individual devices first, for the same cap-keeps-the-important-ones reason.
    $individual = @($individual | Sort-Object @{ Expression = { -1 * $_.RouteCount } }, @{ Expression = { $_.HostName } })

    return [pscustomobject]@{
        Individual   = $individual
        StaticGroups = $staticGroups
        Unrouted     = @($unrouted | Sort-Object)
        TotalDevices = $allDevices.Count
    }
}

# Pure model builder for the "Layer 3 Topology Overview" page - it returns data and draws nothing,
# same contract as Get-MTAutoDrawL3ConnectivityModel / Get-MTAutoDrawL3RoutesSummaryModel above.
#
# Unlike those two (which answer "who points where" per route), this model answers "what is
# L3-wired to what": it groups devices into L3 roles (Border/Transit/Gateway, derived purely from
# routing - no vendor config exposes a real role), finds shared L3 segments between devices, and
# merges adjacency + routing + FHRP facts onto ONE edge per device pair rather than one edge per
# route or VLAN. The merged model keeps the page device-centric and avoids parallel connectors.
#
# Segment sizing decides how a shared subnet is drawn (decided by the draw function, not here):
#   1 device   stub - rolled into that device SubnetCount/SviCount, never a shape of its own.
#   2 devices  becomes (or upgrades) the PairEdges entry between those two devices.
#   3+ devices becomes a segment chip with one spoke per attached device; a routing dependency
#              between two devices that are ONLY adjacent via a 3+ device segment is not given its
#              own edge - the chip spokes already state the adjacency, and full per-route detail
#              is deliberately left to the Layer 3 Connectivity / Routes Summary pages.
function Get-MTAutoDrawL3TopologyModel {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Devices)

    $allDevices = @($Devices | Where-Object { $_ })
    $gatewayIndex = New-MTAutoDrawGatewayIndex -Devices $allDevices
    $securityDeviceTypes = Get-MTAutoDrawSecurityDeviceTypes

    # =====================================================================
    # Phase 1 - per-device interface facts (subnets/SVIs/VRFs) and the segment map (cidr -> which
    # devices sit on it, its VLAN/VRF, and any FHRP VIPs seen there).
    # =====================================================================
    $ifaceFactsByHost = @{}
    $segments = @{}   # cidr -> pscustomobject
    $vrfNamesSeen = New-Object System.Collections.Generic.List[string]

    foreach ($device in $allDevices) {
        $hostname = [string]$device.hostname
        if (-not $hostname) { continue }

        $subnetCidrs = New-Object System.Collections.Generic.List[string]
        $sviCidrs = New-Object System.Collections.Generic.List[string]
        $deviceVrfs = New-Object System.Collections.Generic.List[string]
        $seenCidr = @{}

        foreach ($interface in @($device.interfaces | Where-Object { $_ -and -not $_.shutdown })) {
            $addresses = @(Get-MTAutoDrawInterfaceIPv4Address -Interface $interface)
            if ($addresses.Count -eq 0) { continue }
            $vrfName = if ($interface.vrf) { ([string]$interface.vrf).Trim() } else { '' }
            if ($vrfName -and $vrfName -ne 'default') {
                if (-not $deviceVrfs.Contains($vrfName)) { $deviceVrfs.Add($vrfName) }
                if (-not $vrfNamesSeen.Contains($vrfName)) { $vrfNamesSeen.Add($vrfName) }
            }
            # Every parser sets RoutedVlan to the literal string "no vlan" (not $null/empty) on a
            # point-to-point routed physical interface, so it can't be tested for truthiness - only
            # a genuine numeric VLAN ID counts as an SVI here.
            $realVlan = if ([string]$interface.RoutedVlan -match '^\d+$') { [string]$interface.RoutedVlan } else { $null }

            foreach ($address in $addresses) {
                $cidr = [string]$address.Cidr
                if (-not $cidr -or $seenCidr.ContainsKey($cidr)) { continue }
                $seenCidr[$cidr] = $true
                $subnetCidrs.Add($cidr)
                if ($realVlan) { $sviCidrs.Add($cidr) }

                if (-not $segments.ContainsKey($cidr)) {
                    $segments[$cidr] = [pscustomobject]@{
                        Cidr = $cidr
                        Vlan = $realVlan
                        Vrf = if ($vrfName) { $vrfName } else { 'default' }
                        Devices = New-Object System.Collections.Generic.List[string]
                        FhrpVips = New-Object System.Collections.Generic.List[string]
                        IsPointToPoint = [bool]($cidr -match '/(3[01])$')
                    }
                }
                $segment = $segments[$cidr]
                if (-not $segment.Devices.Contains($hostname)) { $segment.Devices.Add($hostname) }
                if (-not $segment.Vlan -and $realVlan) { $segment.Vlan = $realVlan }
                if ($segment.Vrf -eq 'default' -and $vrfName -and $vrfName -ne 'default') { $segment.Vrf = $vrfName }

                # FHRP: a standby/virtual address configured on THIS cidr interface. All members of
                # a redundancy group configure the same VIP, so the value naturally de-dupes below.
                $vip = [string]$interface.Standbyip
                if ($vip -and -not $segment.FhrpVips.Contains($vip)) { $segment.FhrpVips.Add($vip) }
            }
        }

        $ifaceFactsByHost[$hostname] = [pscustomobject]@{
            SubnetCidrs = @($subnetCidrs)
            SviCidrs    = @($sviCidrs)
            Vrfs        = @($deviceVrfs | Sort-Object)
        }
    }

    # Fixed six-colour ring, assigned by sorted VRF name so the same VRF is the same colour on every
    # run of the same site (not insertion-order dependent).
    $vrfColorRing = @('#00838F', '#6A1B9A', '#EF6C00', '#2E7D32', '#AD1457', '#4527A0')
    $vrfColorMap = @{}
    $sortedVrfNames = @($vrfNamesSeen | Sort-Object -Unique)
    for ($i = 0; $i -lt $sortedVrfNames.Count; $i++) {
        $vrfColorMap[$sortedVrfNames[$i]] = $vrfColorRing[$i % $vrfColorRing.Count]
    }

    # Pair -> shared-segment record, built once from EVERY segment regardless of size, purely to
    # classify a routing dependency as direct (shares a segment) vs indirect (reached over an
    # intermediate) below. Only 2-device segments additionally become an adjacency edge.
    $sharedSegmentPairs = @{}
    $adjacencyByPair = @{}
    # Sorted by Cidr (the hashtable key, so this is a total order). Bucket order is not stable
    # between runs, and several fields below are first-one-wins over this loop - Vlan, Vrf, and the
    # order of SharedCidrs, which decides which subnet an edge label leads with. Unsorted, the same
    # input produced a different edge label each run.
    foreach ($segment in ($segments.Values | Sort-Object Cidr)) {
        $members = @($segment.Devices)
        for ($a = 0; $a -lt $members.Count; $a++) {
            for ($b = $a + 1; $b -lt $members.Count; $b++) {
                $pair = @($members[$a], $members[$b]) | Sort-Object
                $pairKey = $pair -join '|'
                $sharedSegmentPairs[$pairKey] = $true
            }
        }
        if ($members.Count -eq 2) {
            $pair = @($members[0], $members[1]) | Sort-Object
            $pairKey = $pair -join '|'
            if (-not $adjacencyByPair.ContainsKey($pairKey)) {
                $adjacencyByPair[$pairKey] = [pscustomobject]@{
                    Kind = 'Adjacent'
                    A = $pair[0]; B = $pair[1]
                    SharedCidrs = New-Object System.Collections.Generic.List[string]
                    Vlan = $null; Vrf = 'default'
                    Directions = New-Object System.Collections.Generic.HashSet[string]
                    Protocols = New-Object System.Collections.Generic.List[string]
                    RouteCount = 0; HasDefault = $false; IsRouted = $false
                    HasFhrp = $false; FhrpGroupCount = 0; FhrpVips = @()
                }
            }
            $entry = $adjacencyByPair[$pairKey]
            if (-not $entry.SharedCidrs.Contains($segment.Cidr)) { $entry.SharedCidrs.Add($segment.Cidr) }
            if (-not $entry.Vlan -and $segment.Vlan) { $entry.Vlan = $segment.Vlan }
            if ($entry.Vrf -eq 'default' -and $segment.Vrf -ne 'default') { $entry.Vrf = $segment.Vrf }
        }
    }

    # FHRP pairs: one entry per 2-device segment that carries a VIP. A 3+-member redundancy group
    # (GLBP with three routers) is rare and, at this page summary altitude, is represented by its
    # segment chip instead - see the file-header comment.
    #
    # Merged straight onto that pair's adjacencyByPair entry (every FHRP pair is, by construction,
    # a 2-device segment, so an Adjacent entry for it always already exists) rather than kept as a
    # second, separate edge: Add-DrawioConnector treats any two calls with the same source/target
    # pair as duplicates of ONE edge regardless of style, so a second edge between the same two
    # device cards would silently never be drawn. This also keeps the one-edge-per-pair rule intact.
    $fhrpPairs = @{}
    foreach ($segment in ($segments.Values | Where-Object { $_.Devices.Count -eq 2 -and $_.FhrpVips.Count -gt 0 } | Sort-Object Cidr)) {
        $pair = @($segment.Devices[0], $segment.Devices[1]) | Sort-Object
        $pairKey = $pair -join '|'
        if (-not $fhrpPairs.ContainsKey($pairKey)) {
            $fhrpPairs[$pairKey] = [pscustomobject]@{
                A = $pair[0]; B = $pair[1]
                GroupCount = 0
                Vips = New-Object System.Collections.Generic.List[string]
            }
        }
        $fhrpPairs[$pairKey].GroupCount++
        foreach ($vip in $segment.FhrpVips) {
            if (-not $fhrpPairs[$pairKey].Vips.Contains($vip)) { $fhrpPairs[$pairKey].Vips.Add($vip) }
        }
    }
    foreach ($fhrpKey in $fhrpPairs.Keys) {
        if (-not $adjacencyByPair.ContainsKey($fhrpKey)) { continue }
        $adjEntry = $adjacencyByPair[$fhrpKey]
        $adjEntry.HasFhrp = $true
        $adjEntry.FhrpGroupCount = $fhrpPairs[$fhrpKey].GroupCount
        $adjEntry.FhrpVips = @($fhrpPairs[$fhrpKey].Vips)
    }

    # =====================================================================
    # Phase 2 - routing: resolve every significant route next hop to a hostname (or "external"),
    # then fold it onto the adjacency edge for that pair (direct) or a standalone Indirect edge (no
    # shared segment). Also derives Border/Transit candidacy and the default-route egress per device.
    # =====================================================================
    $dependantCountByHost = @{}     # hostname -> distinct devices that route via it
    $countedDependants = @{}        # "source|target" seen-once guard
    $externalHops = @{}             # gateway IP -> distinct devices that depend on it
    $externalEdgesByKey = @{}       # "hostname|ip" -> merged edge record (draw function connects Border/Gateway -> Band 0 hub)
    $indirectByPair = @{}
    $nodeRoutingByHost = @{}

    foreach ($device in $allDevices) {
        $hostname = [string]$device.hostname
        if (-not $hostname) { continue }
        $routes = @(Get-MTAutoDrawSignificantRoutes -Device $device)
        $routing = [pscustomobject]@{
            HasDefaultRoute = $false
            DefaultViaHost  = $null
            DefaultViaExternal = $null
            Protocols       = New-Object System.Collections.Generic.List[string]
            HasDynamicRoute = $false
        }

        foreach ($route in $routes) {
            $protocol = [string]$route.RouteProtocol
            if ($protocol -and -not $routing.Protocols.Contains($protocol)) { $routing.Protocols.Add($protocol) }
            $isDynamic = [bool]($protocol -notmatch $script:GMTAutoDrawStaticRouteProtocolPattern)
            if ($isDynamic) { $routing.HasDynamicRoute = $true }
            $isDefault = [bool](([string]$route.Subnet) -match '^0\.0\.0\.0(?:/0)?$' -or $route.defaultgateway)

            $gwIp = [string]$route.gateway
            $targetHost = if ($gwIp -and $gatewayIndex.ContainsKey($gwIp)) { $gatewayIndex[$gwIp] } else { $null }

            if ($isDefault -and -not $routing.HasDefaultRoute) {
                $routing.HasDefaultRoute = $true
                if ($targetHost) { $routing.DefaultViaHost = $targetHost } else { $routing.DefaultViaExternal = $gwIp }
            }

            if ($targetHost -and $targetHost -ine $hostname) {
                $dependKey = "$hostname|$targetHost"
                if (-not $countedDependants.ContainsKey($dependKey)) {
                    $countedDependants[$dependKey] = $true
                    if (-not $dependantCountByHost.ContainsKey($targetHost)) { $dependantCountByHost[$targetHost] = 0 }
                    $dependantCountByHost[$targetHost]++
                }

                $pair = @($hostname, $targetHost) | Sort-Object
                $pairKey = $pair -join '|'
                if ($adjacencyByPair.ContainsKey($pairKey)) {
                    $entry = $adjacencyByPair[$pairKey]
                    $entry.IsRouted = $true
                    if ($protocol -and -not $entry.Protocols.Contains($protocol)) { $entry.Protocols.Add($protocol) }
                    $entry.RouteCount++
                    if ($isDefault) { $entry.HasDefault = $true }
                    [void]$entry.Directions.Add("$hostname->$targetHost")
                }
                elseif (-not $sharedSegmentPairs.ContainsKey($pairKey)) {
                    # No shared segment at all: reached over an intermediate. Its own edge class.
                    if (-not $indirectByPair.ContainsKey($pairKey)) {
                        $indirectByPair[$pairKey] = [pscustomobject]@{
                            Kind = 'Indirect'
                            A = $pair[0]; B = $pair[1]
                            SharedCidrs = @()
                            Vlan = $null; Vrf = $null
                            Directions = New-Object System.Collections.Generic.HashSet[string]
                            Protocols = New-Object System.Collections.Generic.List[string]
                            RouteCount = 0; HasDefault = $false; IsRouted = $true
                        }
                    }
                    $entry = $indirectByPair[$pairKey]
                    if ($protocol -and -not $entry.Protocols.Contains($protocol)) { $entry.Protocols.Add($protocol) }
                    $entry.RouteCount++
                    if ($isDefault) { $entry.HasDefault = $true }
                    [void]$entry.Directions.Add("$hostname->$targetHost")
                }
                # else: adjacent only via a 3+ device segment chip - deliberately not given its own
                # edge; see the file-header comment.
            }
            elseif (-not $targetHost -and $gwIp) {
                $extKey = "$hostname|$gwIp"
                if (-not $externalEdgesByKey.ContainsKey($extKey)) {
                    $externalEdgesByKey[$extKey] = [pscustomobject]@{
                        HostName = $hostname; Address = $gwIp
                        Protocols = New-Object System.Collections.Generic.List[string]
                        RouteCount = 0; HasDefault = $false
                    }
                    if (-not $externalHops.ContainsKey($gwIp)) { $externalHops[$gwIp] = 0 }
                    $externalHops[$gwIp]++
                }
                $extEdge = $externalEdgesByKey[$extKey]
                if ($protocol -and -not $extEdge.Protocols.Contains($protocol)) { $extEdge.Protocols.Add($protocol) }
                $extEdge.RouteCount++
                if ($isDefault) { $extEdge.HasDefault = $true }
            }
        }

        $nodeRoutingByHost[$hostname] = $routing
    }

    # =====================================================================
    # Phase 3 - assemble per-device nodes (Role, SVI/subnet counts, VRFs, FHRP, routing summary).
    # Devices with neither an L3 interface nor a route are L2-only and never drawn individually.
    # =====================================================================
    $nodes = New-Object System.Collections.Generic.List[object]
    $l2Only = New-Object System.Collections.Generic.List[string]

    foreach ($device in $allDevices) {
        $hostname = [string]$device.hostname
        if (-not $hostname) { continue }
        $facts = $ifaceFactsByHost[$hostname]
        $routing = $nodeRoutingByHost[$hostname]
        $hasL3 = [bool]($facts -and $facts.SubnetCidrs.Count -gt 0)
        $hasRoutes = [bool]($routing -and ($routing.HasDefaultRoute -or $routing.Protocols.Count -gt 0))
        if (-not $hasL3 -and -not $hasRoutes) { $l2Only.Add($hostname); continue }

        $isSecurity = [bool](($device.DeviceType -and $device.DeviceType -in $securityDeviceTypes) -or
            (@($device.interfaces | Where-Object { $_.Zone }).Count -gt 0))

        $transitSegmentCount = @($segments.Values | Where-Object { $_.Devices.Count -ge 2 -and $_.Devices.Contains($hostname) }).Count
        $isDependedOn = [bool]($dependantCountByHost.ContainsKey($hostname) -and $dependantCountByHost[$hostname] -gt 0)
        $isDynamicTransit = [bool]($routing -and $routing.HasDynamicRoute -and $transitSegmentCount -ge 2)
        $defaultToExternal = [bool]($routing -and $routing.HasDefaultRoute -and $routing.DefaultViaExternal)

        $role = if ($isSecurity -or $defaultToExternal) { 'Border' }
            elseif ($isDependedOn -or $isDynamicTransit) { 'Transit' }
            else { 'Gateway' }

        $fhrpGroupCount = 0
        foreach ($fhrp in $fhrpPairs.Values) {
            if ($fhrp.A -ieq $hostname -or $fhrp.B -ieq $hostname) { $fhrpGroupCount += $fhrp.GroupCount }
        }

        $defaultVia = if (-not $routing -or -not $routing.HasDefaultRoute) { $null }
            elseif ($routing.DefaultViaHost) { $routing.DefaultViaHost }
            else { $routing.DefaultViaExternal }

        $nodes.Add([pscustomobject]@{
            HostName            = $hostname
            Device              = $device
            Role                = $role
            SubnetCount         = if ($facts) { $facts.SubnetCidrs.Count } else { 0 }
            SviCount            = if ($facts) { $facts.SviCidrs.Count } else { 0 }
            Vrfs                = if ($facts) { $facts.Vrfs } else { @() }
            TransitSegmentCount = $transitSegmentCount
            HasDefaultRoute     = [bool]($routing -and $routing.HasDefaultRoute)
            DefaultVia          = $defaultVia
            IsSecurity          = $isSecurity
            Protocols           = if ($routing) { @($routing.Protocols) } else { @() }
            BgpAs               = $device.BGP_AS_Number
            FhrpGroupCount      = $fhrpGroupCount
            DependantCount      = if ($dependantCountByHost.ContainsKey($hostname)) { $dependantCountByHost[$hostname] } else { 0 }
        })
    }

    # Sorted, not raw .Values: a hashtable enumerates in bucket order, which is not stable between
    # runs. Every other collection returned below already sorts; these two did not, so the same
    # input produced the same SET of edges in a different ORDER each run - which changes edge
    # z-order on the page and makes the rendered .drawio impossible to compare byte-for-byte.
    # A and B are already ordered within a pair, so A,B,Kind is a total order over the edges.
    $pairEdges = @(@($adjacencyByPair.Values) + @($indirectByPair.Values) | Sort-Object A, B, Kind)
    $externalHopList = @($externalHops.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ Address = [string]$_.Key; DependantCount = $_.Value }
    } | Sort-Object @{ Expression = { -1 * $_.DependantCount } }, Address)

    return [pscustomobject]@{
        Nodes         = @($nodes | Sort-Object @{ Expression = { -1 * $_.DependantCount } }, HostName)
        Segments      = @($segments.Values | Where-Object { $_.Devices.Count -ge 2 } | Sort-Object @{ Expression = { -1 * $_.Devices.Count } }, Cidr)
        # PairEdges' Adjacent entries already carry HasFhrp/FhrpGroupCount/FhrpVips (see the FHRP
        # merge above) - there is no separate FhrpPairs collection, because Add-DrawioConnector
        # cannot draw a second edge between the same two shapes.
        PairEdges     = $pairEdges
        ExternalHops  = $externalHopList
        ExternalEdges = @($externalEdgesByKey.Values | Sort-Object HostName, Address)
        Vrfs          = $vrfColorMap
        L2Only        = @($l2Only | Sort-Object)
        TotalDevices  = $allDevices.Count
    }
}
