# MTAutoDraw-Standard: v1
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

# This file processes the OLD Cisco Small Business CLI (Sx200 / Sx300 family, firmware 1.x).
#
# It is deliberately thin. The old and current Small Business CLIs emit byte-identical table
# layouts for most operational commands, so this module reuses the readers in
# CiscoSmallBusinessConfigProcessingFunctions.ps1 and only implements what genuinely differs:
#
#   show version        four lines (SW/Boot/HW version), no Active-image: block
#   show ip interface   two stacked tables, far fewer columns than the current CLI
#   show ip route       a distinct short format, and unsupported on most of these switches
#   running config      'show running-config brief', and absent entirely on older firmware
#
# The dispatch in StartProcessingConfig.ps1 imports the current Small Business module before
# this one, so the shared readers are already in scope.
#
# Follows PARSER_STANDARD.md v1; the orchestrator is at the foot of the file.

# --- Platform helpers -----------------------------------------------------------------------------

# The old CLI leaves its prompt on the last line of every capture, for example 'SW13#'. On switches
# whose firmware rejects 'show running-config brief' that prompt is the only place a hostname appears
# at all, so it is the last-resort source for device identity.
function Get-OldCiscoSmallBusinessPromptHostname {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$HostID)

    foreach ($slot in 'ShowSystem', 'ShowVersion', 'ShowSystemId', 'ShowIPInterface', 'ShowVlan', 'ShowInterfaceStatus', 'ShowArp', 'ShowSpanningTree') {
        $path = $HostID.$slot
        if (-not (Test-MTAutoDrawCaptureReadable -Device $null -Path $path -Capture $slot)) { continue }
        # Walk backwards; the prompt is at the end, and echoed commands can look similar.
        $lines = @(Get-MTAutoDrawCaptureText -Path $path -AsLines)
        for ($index = $lines.Count - 1; $index -ge 0; $index--) {
            if ($lines[$index] -match '^\s*(?<name>[A-Za-z0-9][A-Za-z0-9._-]*)[#>]\s*$') { return $Matches['name'] }
        }
    }
    return $null
}

# Hostname, in order of trustworthiness: show system -> running config -> CLI prompt -> capture
# identity. The first two are the shared readers' job; this fills in behind them.
#
# Not an Update-* reader: it consumes no single capture, so it is a reconcile step.
function Resolve-OldCiscoSmallBusinessHostname {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [Parameter(Mandatory = $true)]$HostID
    )

    if ($Device.hostname -and $Device.hostname -notlike '*NoHostNameFound*') { return }

    $promptName = Get-OldCiscoSmallBusinessPromptHostname -HostID $HostID
    if ($promptName)      { $Device.hostname = $promptName }
    elseif ($HostID.HOSTID) { $Device.hostname = $HostID.HOSTID }
}

# --- Capture readers ------------------------------------------------------------------------------
# Each one: GUARD, EXTRACT, MAP, MERGE. Each takes -Device and -Path, returns nothing, and is safe to
# call with a $null path - so the orchestrator needs no per-slot if-wrappers.

# This firmware's 'show version' is four bare lines; the shared reader finds no Active-image: block
# and leaves the version object empty, so the SW and HW lines are read here instead.
function Update-OldCiscoSmallBusinessVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowVersion')) { return }

    # --- EXTRACT / MAP / MERGE ---
    $text = Get-MTAutoDrawCaptureText -Path $Path
    $version = Get-CiscoSmallBusinessVersionObject -Device $Device
    $software = Get-CiscoSmallBusinessRegexValue -Text $text -Pattern '(?mi)^\s*SW version\s+(\S+)'
    $hardware = Get-CiscoSmallBusinessRegexValue -Text $text -Pattern '(?mi)^\s*HW version\s+(\S+)'
    if ($software) { $version.OS = $software }
    if ($hardware -and -not $version.ROMMON) { $version.ROMMON = $hardware }
}

# 'show system id' is the only capture on this firmware carrying a serial number - there is no
# 'show inventory' at all.
function Update-OldCiscoSmallBusinessSystemId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowSystemId')) { return }

    # --- EXTRACT / MAP / MERGE ---
    $serial = Get-CiscoSmallBusinessRegexValue -Text (Get-MTAutoDrawCaptureText -Path $Path) -Pattern '(?mi)^\s*Serial number\s*:\s*(\S+)'
    if ($serial) { (Get-CiscoSmallBusinessVersionObject -Device $Device).Serial = @($serial) }
}

# 'show ip interface' on this CLI prints a gateway table followed by an address table:
#
#   Gateway IP Address        Activity status       Type
#  ----------------------- ----------------------- --------
#  10.0.0.1                Active                  static
#
#      IP Address         I/F       Type       Status
#  ------------------- --------- ----------- -----------
#  10.0.0.17/24        vlan 1    Static      Valid
#
# On switches with no running config this is the only source of the management address, so the SVI
# and its network are created here when the config did not already supply them.
function Update-OldCiscoSmallBusinessIpInterface {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowIPInterface')) { return }

    # --- EXTRACT / MAP / MERGE ---
    foreach ($row in [regex]::Matches((Get-MTAutoDrawCaptureText -Path $Path), '(?m)^\s*(?<ip>\d{1,3}(?:\.\d{1,3}){3})/(?<prefix>\d{1,2})\s+(?<if>vlan\s+\d+|\S+)\s+(?<type>\S+)\s+(?<status>\S+)')) {
        $interfaceName = ConvertTo-CiscoSmallBusinessInterfaceName -Name ($row.Groups['if'].Value -replace '\s+', '')
        if (-not $interfaceName) { continue }

        $existing = Resolve-CiscoSmallBusinessInterface -Device $Device -Name $interfaceName
        if (-not $existing) {
            $existing = Resolve-CiscoSmallBusinessInterface -Device $Device -Name $interfaceName -Create
            $existing.SwitchPortType = 'Routed'
            # Resolve-MTAutoDrawInterface sets an explicit $false rather than the constructor's $null,
            # which matters here: Start-ProcessingFiles counts network connectors with
            # "where { $null -ne $_.ipaddress -and $_.shutdown -eq $false }", and $null -eq $false is
            # False - so an SVI left at $null would be skipped, its network would end up with zero
            # connectors, get dropped from the global list, and the device would silently lose its
            # layer 3 page. The interface is up: it is answering show ip interface.
            if ($interfaceName -match '^Vlan(\d+)$') { $existing.RoutedVlan = $Matches[1] } else { $existing.RoutedVlan = 'no vlan' }
        }
        if ($existing.IPAddress) { continue }   # the running config already supplied it

        $address = Get-NormalizedIPv4Cidr -IPAddress $row.Groups['ip'].Value -PrefixLength $row.Groups['prefix'].Value
        $existing.IPAddress = $row.Groups['ip'].Value
        $existing.SubnetMask = [int]$row.Groups['prefix'].Value
        $existing.Cidr = if ($address) { $address.Cidr } else { $null }
        # The routed VLAN of the network is the interface name ('Vlan1'), not the bare number the
        # interface itself carries - that is what the layer 3 pages label the subnet with.
        $routedVlan = if ($interfaceName -match '^Vlan') { $interfaceName } else { $null }
        $null = Add-MTAutoDrawNetwork -Device $Device -Cidr $existing.Cidr -RoutedVlan $routedVlan -IPAddress $existing.IPAddress
    }
}

# The default gateway from the 'show ip interface' gateway table. Most of these switches answer
# 'show ip route' with '% Unrecognized command' because they are pure layer 2, so without this they
# would contribute no next-hop at all to the layer 3 diagram.
function Update-OldCiscoSmallBusinessDefaultGateway {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowIPInterface')) { return }

    # --- EXTRACT ---
    $gatewayMatch = [regex]::Match((Get-MTAutoDrawCaptureText -Path $Path), '(?m)^\s*(?<gw>\d{1,3}(?:\.\d{1,3}){3})\s+(?<state>Active|Inactive)\s+(?<type>\S+)')
    if (-not $gatewayMatch.Success) { return }
    # A real routing table, where the switch has one, is the better answer.
    if (@($Device.RoutingTable) | Where-Object { $_.defaultgateway }) { return }

    # --- MAP + MERGE ---
    $route = Create-RouteObject
    $route.RouteProtocol = 'static'
    $route.Subnet = '0.0.0.0/0'
    $route.gateway = $gatewayMatch.Groups['gw'].Value
    $route.defaultgateway = $true
    $Device.RoutingTable = @(@($Device.RoutingTable) + $route | Where-Object { $_ })
}

# 'show ip route' on the L3-capable members of this family:
#
#   Codes: > - best, C - connected, S - static
#   S   0.0.0.0/0 [1/1] via 10.0.0.1, 1435:46:28,
#   C   10.0.0.0/24 is directly connected,
#
# Note the connected routes name no interface; Update-LocalRoutesWithInterfaces backfills that from
# the SVI subnets once parsing is done.
function Update-OldCiscoSmallBusinessRoutes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowIPRoute')) { return }

    # --- EXTRACT / MAP ---
    $protocolByCode = @{ 'C' = 'connected'; 'S' = 'static'; 'R' = 'rip'; 'O' = 'ospf'; 'B' = 'bgp' }
    $routes = @($Device.RoutingTable)

    foreach ($row in [regex]::Matches((Get-MTAutoDrawCaptureText -Path $Path), '(?m)^\s*(?<code>[A-Z])\s*>?\s+(?<subnet>\d{1,3}(?:\.\d{1,3}){3}/\d{1,2})\s+(?<rest>[^\r\n]*)')) {
        $code = $row.Groups['code'].Value
        $route = Create-RouteObject
        $route.RouteProtocol = if ($protocolByCode.ContainsKey($code)) { $protocolByCode[$code] } else { $code }
        $route.Subnet = $row.Groups['subnet'].Value

        $viaMatch = [regex]::Match($row.Groups['rest'].Value, 'via\s+(?<gw>\d{1,3}(?:\.\d{1,3}){3})')
        if ($viaMatch.Success) { $route.gateway = $viaMatch.Groups['gw'].Value }
        $route.defaultgateway = $route.Subnet -eq '0.0.0.0/0'

        $routes += ,$route
    }

    # --- MERGE ---
    $Device.RoutingTable = @($routes | Where-Object { $_ })
}

# The ARP table is laid out like the current CLI's except the Interface column is always blank:
#
#     VLAN    Interface     IP address        HW address          status
#   --------------------- --------------- ------------------- ---------------
#   vlan 1                10.0.0.1        50:52:00:80:a9:11   dynamic
#
# The shared reader requires that column and so matches nothing here. The owning interface is
# unambiguous anyway - it is the VLAN named in the first column.
function Update-OldCiscoSmallBusinessArp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowArp')) { return }

    # --- EXTRACT / MAP / MERGE ---
    $entries = @()
    foreach ($line in (Get-MTAutoDrawCaptureText -Path $Path -AsLines)) {
        # The interface group carries a negative lookahead so an absent column cannot swallow the
        # IP address that follows it.
        if ($line -notmatch '^\s*vlan\s+(?<vlan>\d+)\s+(?:(?<interface>(?!\d{1,3}(?:\.\d{1,3}){3}\s)\S+)\s+)?(?<ip>\d{1,3}(?:\.\d{1,3}){3})\s+(?<mac>[0-9A-Fa-f:.-]{12,17})\s+(?<status>\S+)') { continue }

        $entry = Create-ShowIPArpObject
        $entry.PROTOCOL = 'Internet'
        $entry.ipaddress = $Matches['ip']
        $entry.MAC = $Matches['mac']
        $entry.TYPE = $Matches['status']
        $entry.INTERFACE = if ($Matches['interface']) {
            ConvertTo-CiscoSmallBusinessInterfaceName -Name $Matches['interface']
        } else {
            "Vlan$($Matches['vlan'])"
        }
        $entry.VendorCompanyName = Get-CiscoSmallBusinessMacVendor -MacAddress $entry.MAC

        foreach ($interface in $Device.interfaces | Where-Object { $_.Cidr }) {
            try {
                if ((Find-Subnet -addr1 $interface.Cidr -addr2 $entry.ipaddress).condition) {
                    $entry.Cidr = $interface.Cidr
                    break
                }
            }
            catch { }
        }
        $entries += ,$entry
    }
    $Device.IPArpEntries = @($entries)
}

# --- Orchestrator ---------------------------------------------------------------------------------

function Process-OldCiscoSmallBusinessHostFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$HostID,
        $ArrayOfObjects   # Kept for dispatcher signature compatibility; duplicate detection is sequential.
    )

    # 1. IDENTITY - unlike the current Small Business switches, a missing running config is not fatal:
    # older firmware rejects 'show running-config brief' outright, and those devices still carry
    # usable VLAN, neighbour, spanning-tree and address data in their operational captures. The
    # hostname then comes from 'show system', the CLI prompt, or the capture identity, in that order.
    $device = New-MTAutoDrawDevice -Platform 'CiscoSmallBusinessLegacy' -HostID $HostID
    $null = Get-CiscoSmallBusinessVersionObject -Device $device
    Update-CiscoSmallBusinessRunningConfig -Device $device -Path $HostID.ShowRun
    if (-not $device.SpanningTree) { $device.SpanningTree = Create-SpanningTreeObject }
    Update-CiscoSmallBusinessSystem  -Device $device -Path $HostID.ShowSystem
    Update-CiscoSmallBusinessVersion -Device $device -Path $HostID.ShowVersion
    Update-OldCiscoSmallBusinessVersion  -Device $device -Path $HostID.ShowVersion
    Update-OldCiscoSmallBusinessSystemId -Device $device -Path $HostID.ShowSystemId
    $device.Version.Type = 'CiscoSmallBusinessLegacy'
    Resolve-OldCiscoSmallBusinessHostname -Device $device -HostID $HostID
    if (-not $device.hostname -or $device.hostname -like '*NoHostNameFound*') {
        Write-MTAutoDrawDiagnostic -Device $device -Severity Warning -Message "Old Cisco Small Business host '$($HostID.HOSTID)' has no usable hostname; skipping."
        return $null
    }
    Write-MTAutoDrawLog -Level Info -Phase Parse -Device $device -Message "Processing Old Cisco Small Business host: $($device.hostname)"

    # 2. CAPTURES - one line per slot, in dependency order. The first six are laid out identically on
    # both CLI generations, so they are the current module's readers; the rest are this generation's
    # own formats. The SVI has to exist before ARP and the default gateway can be placed in a subnet.
    Update-CiscoSmallBusinessVlans                 -Device $device -Path $HostID.ShowVlan
    Update-CiscoSmallBusinessInterfaceStatus       -Device $device -Path $HostID.ShowInterfaceStatus
    Update-CiscoSmallBusinessInterfaceDescriptions -Device $device -Path $HostID.ShowInterfaceDescription
    Update-CiscoSmallBusinessCdpNeighbors          -Device $device -Path $HostID.ShowCDPNeighborsDetails
    Update-CiscoSmallBusinessLldpNeighbors         -Device $device -Path $HostID.ShowLLDPNeighbors
    Update-CiscoSmallBusinessSpanningTree          -Device $device -Path $HostID.ShowSpanningTree
    Update-CiscoSmallBusinessSpanningTreeDetail    -Device $device -Path $HostID.ShowSpanningTreeDetails
    if ($GDrawPortsWithMacs -ne 0) { Update-CiscoSmallBusinessMacAddressTable -Device $device -Path $HostID.ShowMacAddressTable }

    Update-OldCiscoSmallBusinessIpInterface     -Device $device -Path $HostID.ShowIPInterface
    Update-OldCiscoSmallBusinessRoutes          -Device $device -Path $HostID.ShowIPRoute
    Update-OldCiscoSmallBusinessDefaultGateway  -Device $device -Path $HostID.ShowIPInterface
    if ($GDrawAprEntries) { Update-OldCiscoSmallBusinessArp -Device $device -Path ($HostID.ShowArp ?? $HostID.ShowIPArp) }

    # 3. RECONCILE
    $device.Version.Hardware = @($device.Version.Hardware | Sort-Object -Unique)
    if (-not $device.Version.Hostname) { $device.Version.Hostname = $device.hostname }
    return (Complete-MTAutoDrawDevice -Device $device)
}
