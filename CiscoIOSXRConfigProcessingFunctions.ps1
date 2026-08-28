# MTAutoDraw-Standard: v1
#
# Cisco IOS XR capture processing. This module is the reference implementation of the parser standard
# described in PARSER_STANDARD.md - read it alongside that document.
#
# Route parsing is implemented but remains unverified: it has not yet been exercised against a real
# `show ip route` capture from this platform, so treat its output as provisional.

# --- Platform helpers -----------------------------------------------------------------------------

# IOS XR names interfaces consistently between `show run` and `show interfaces brief`, so the shared
# find-or-create needs no normalisation here. Platforms whose captures disagree about naming (Aruba's
# "lag 1" against "lag1") wrap this instead of calling the shared helper directly.
function Resolve-CiscoIOSXRInterface {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [Parameter(Mandatory = $true)][string]$Name
    )
    return (Resolve-MTAutoDrawInterface -Device $Device -Name $Name)
}

# --- Capture readers ------------------------------------------------------------------------------
# Each one: GUARD, EXTRACT, MAP, MERGE. Each takes -Device and -Path, returns nothing, and is safe to
# call with a $null path - so the orchestrator needs no per-slot if-wrappers.

function Update-CiscoIOSXRVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowVersion')) { return }

    # --- EXTRACT ---
    $text = Get-MTAutoDrawCaptureText -Path $Path

    # --- MAP ---
    $version = Create-ShowVersionObject
    $version.Type = 'IOS-XR'
    if ($text -match '(?im)^Cisco IOS XR Software, Version\s+([^\[\r\n]+)') { $version.OS = $Matches[1].Trim() }
    elseif ($text -match '(?im)^.*IOS XR RELEASE SOFTWARE.*Version\s+([^,\s]+)') { $version.OS = $Matches[1].Trim() }
    if ($text -match '(?im)^([^\s]+) uptime is\s+(.+)$') { $version.Hostname = $Matches[1].Trim(); $version.Uptime = $Matches[2].Trim() }
    if ($text -match '(?im)^System image file is\s+"?([^"\r\n]+)') { $version.Image = $Matches[1].Trim() }
    if ($text -match '(?im)^cisco\s+(.+?)\s+\([^\r\n]+\)\s+processor') { $version.Hardware = @($Matches[1].Trim()) }
    elseif ($text -match '(?im)^(ASR\s+\d+[^\r\n]*Chassis)') { $version.Hardware = @($Matches[1].Trim()) }
    if ($text -match '(?im)^Configuration register.*?\s(is|:)\s*(\S+)') { $version.ConfigRegister = $Matches[2] }

    # --- MERGE ---
    # Device.Version is what the orchestrator gates identity on, so it is only set once parsed.
    $Device.Version = $version
    if (-not $Device.hostname) { $Device.hostname = $version.Hostname }
    if ($version.Hardware.Count -gt 0) { $Device.Platform = $version.Hardware[0] }
}

# Parses a Cisco IOS-XR 'show running-config' to populate the device hostname, PID/serial, and hardware platform. Reads the capture via the MTAutoDraw capture helpers.
function Update-CiscoIOSXRRunningConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowRun')) { return }

    # --- EXTRACT ---
    $config = Get-MTAutoDrawCaptureText -Path $Path

    # --- MAP + MERGE: identity ---
    if ($config -match '(?im)^hostname\s+(\S+)') {
        $Device.hostname = $Matches[1].Trim()
        if ($Device.Version) { $Device.Version.Hostname = $Device.hostname }
    }
    # IOS XR writes inventory as comment lines: "! PID: A9K-MPA-4X10GE, SN: FOC1234ABCD".
    $serials  = @([regex]::Matches($config, '(?im)^!\s*PID:\s*([^,\r\n]+).*?SN:\s*(\S+)') | ForEach-Object { $_.Groups[2].Value.Trim() } | Where-Object { $_ -and $_ -ne 'N/A' } | Select-Object -Unique)
    $hardware = @([regex]::Matches($config, '(?im)^!\s*PID:\s*([^,\r\n]+)') | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if ($Device.Version -and $serials.Count  -gt 0) { $Device.Version.Serial   = $serials }
    if ($Device.Version -and $hardware.Count -gt 0) { $Device.Version.Hardware = $hardware }

    # --- MAP + MERGE: interfaces ---
    foreach ($match in [regex]::Matches($config, '(?ms)^interface\s+(?<name>\S+)\s*\r?\n(?<body>.*?)(?=^!\s*$|^interface\s+|\z)')) {
        $interface = Resolve-CiscoIOSXRInterface -Device $Device -Name $match.Groups['name'].Value
        $body = $match.Groups['body'].Value
        if ($body -match '(?im)^\s+description\s+(.+)$')           { $interface.Description  = $Matches[1].Trim() }
        if ($body -match '(?im)^\s+vrf\s+(\S+)')                   { $interface.VRF          = $Matches[1].Trim() }
        if ($body -match '(?im)^\s+shutdown\s*$')                  { $interface.shutdown     = $true }
        if ($body -match '(?im)^\s+bundle\s+id\s+(\d+)')           { $interface.ChannelGroup = $Matches[1] }
        if ($body -match '(?im)^\s+encapsulation\s+dot1q\s+(\d+)') { $interface.RoutedVlan   = $Matches[1] }

        $addresses = [regex]::Matches($body, '(?im)^\s+ipv4 address\s+(?<ip>\d{1,3}(?:\.\d{1,3}){3})(?:(?:/(?<prefix>\d{1,2}))|(?:\s+(?<mask>\d{1,3}(?:\.\d{1,3}){3})))(?<suffix>[^\r\n]*)')
        foreach ($addressMatch in $addresses) {
            $addressInfo = Get-NormalizedIPv4Cidr -IPAddress $addressMatch.Groups['ip'].Value -PrefixLength $addressMatch.Groups['prefix'].Value -SubnetMask $addressMatch.Groups['mask'].Value
            if (-not $addressInfo) { continue }

            # An address is secondary when IOS XR says so, or when this interface already took a primary.
            if ($addressMatch.Groups['suffix'].Value -match '(?i)secondary' -or $interface.IPAddress) {
                if (-not $interface.SecondaryIPAddress) {
                    $interface.SecondaryIPAddress  = $addressInfo.IPAddress
                    $interface.SecondarySubnetMask = $addressInfo.PrefixLength
                    $interface.SecondaryCidr       = $addressInfo.Cidr
                }
            }
            else {
                $interface.IPAddress      = $addressInfo.IPAddress
                $interface.SubnetMask     = $addressInfo.PrefixLength
                $interface.Cidr           = $addressInfo.Cidr
                $interface.SwitchPortType = 'Routed'
            }
            $null = Add-MTAutoDrawNetwork -Device $Device -Cidr $addressInfo.Cidr -RoutedVlan $interface.RoutedVlan -IPAddress $addressInfo.IPAddress
        }
    }
}

# Parses IOS-XR interface-brief output into the device's interface objects, setting status, protocol status, shutdown flag, and VRF per interface.
function Update-CiscoIOSXRInterfaceBrief {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowIPInterfaceBrief')) { return }

    # --- EXTRACT / MAP / MERGE ---
    foreach ($line in (Get-MTAutoDrawCaptureText -Path $Path -AsLines)) {
        if ($line -notmatch '^\s*(?<name>\S+)\s+(?<ip>\S+)\s+(?<status>Up|Down|Shutdown)\s+(?<protocol>Up|Down)\s+(?<vrf>\S+)\s*$') { continue }
        $interface = Resolve-CiscoIOSXRInterface -Device $Device -Name $Matches['name']
        $interface.IntStatus         = $Matches['status']
        $interface.INTProtocolStatus = $Matches['protocol']
        $interface.shutdown          = $Matches['status'] -eq 'Shutdown'
        $interface.VRF               = $Matches['vrf']

        # Only fill an address the running configuration did not already provide.
        if ($Matches['ip'] -ne 'unassigned' -and -not $interface.IPAddress) {
            $interface.IPAddress      = $Matches['ip']
            $interface.SwitchPortType = 'Routed'
            $null = Add-MTAutoDrawNetwork -Device $Device -IPAddress $interface.IPAddress
        }
    }
}

# Parses IOS-XR 'show arp' output into the device's ARP entries, resolving each entry to its owning interface/subnet.
function Update-CiscoIOSXRArp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowArp')) { return }

    # `show arp` carries no subnet, so each entry is placed in the most specific configured network it
    # falls inside. Longest prefix first, so a /30 wins over the /24 containing it.
    $knownNetworks = @($Device.interfaces | Where-Object Cidr |
        ForEach-Object { [pscustomobject]@{ Cidr = $_.Cidr; Prefix = [int](($_.Cidr -split '/')[1]) } } |
        Sort-Object Prefix -Descending)

    # --- EXTRACT / MAP / MERGE ---
    $Device.IPArpEntries = @(foreach ($line in (Get-MTAutoDrawCaptureText -Path $Path -AsLines)) {
        if ($line -notmatch '^\s*(?<ip>\d{1,3}(?:\.\d{1,3}){3})\s+(?<age>\S+)\s+(?<mac>\S+)\s+(?<state>\S+)\s+(?<type>\S+)\s+(?<interface>\S+)\s*$') { continue }
        $arp = Create-ShowIPArpObject
        $arp.ipaddress         = $Matches['ip']
        $arp.AGE               = $Matches['age']
        $arp.MAC               = ConvertTo-NormalizedMacAddress $Matches['mac']
        $arp.TYPE              = $Matches['type']
        $arp.INTERFACE         = $Matches['interface']
        $arp.PROTOCOL          = 'Internet'
        $arp.VendorCompanyName = 'UNKNOWN Vendor'
        foreach ($network in $knownNetworks) {
            $candidate = Get-NormalizedIPv4Cidr -IPAddress $arp.ipaddress -PrefixLength ([string]$network.Prefix)
            if ($candidate -and $candidate.Cidr -eq $network.Cidr) { $arp.Cidr = $network.Cidr; break }
        }
        $arp
    })
}

# Parses IOS-XR 'show cdp neighbors detail' (via TextFSM) into the device's CDP neighbour objects.
function Update-CiscoIOSXRCdpNeighbors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowCDPNeighborsDetails')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'cisco_xr_show_cdp_neighbors_detail' -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    $Device.CDPNeighbors = @(foreach ($row in $rows) {
        $neighbor = Create-CDPNeighborObject
        $neighbor.DeviceID              = $row.CHASSIS_ID
        $neighbor.SystemName            = $row.NEIGHBOR_NAME
        $neighbor.InterfaceAddress      = $row.MGMT_ADDRESS
        $neighbor.Platform              = $row.PLATFORM
        $neighbor.InterfaceRemoteDevice = $row.NEIGHBOR_INTERFACE
        $neighbor.InterfaceLocalDevice  = $row.LOCAL_INTERFACE
        $neighbor.Version               = $row.NEIGHBOR_DESCRIPTION
        $neighbor.Capabilities          = $row.CAPABILITIES
        $neighbor.ParentObject          = $Device.hostname
        $neighbor
    })
}

# Parses IOS-XR 'show lldp neighbors detail' (via TextFSM) into the device's LLDP neighbour objects.
function Update-CiscoIOSXRLldpNeighbors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowLLDPNeighborsDetails')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'cisco_xr_show_lldp_neighbors_detail' -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    $Device.LLDPNeighbors = @(foreach ($row in $rows) {
        $neighbor = Create-LLDPNeighborObject
        $neighbor.InterfaceLocalDevice         = $row.LOCAL_INTERFACE
        $neighbor.ChassisID                    = $row.CHASSIS_ID
        $neighbor.NeighborInterfaceDescription = $row.NEIGHBOR_PORT_DESCRIPTION
        $neighbor.InterfaceRemoteDevice        = $row.NEIGHBOR_PORT_ID
        $neighbor.Hostname                     = $row.NEIGHBOR
        $neighbor.SystemDescription            = $row.SYSTEM_DESCRIPTION
        $neighbor.Capabilities                 = $row.CAPABILITIES
        $neighbor.ManagementIP                 = $row.MANAGEMENT_IP
        $neighbor.ParentObject                 = $Device.hostname
        $neighbor
    })
}

# Parses IOS-XR 'show ip route' (via TextFSM) into the device's routing table, capturing VRF, protocol, subnet, and next-hop per route.
function Update-CiscoIOSXRRoutes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowIPRoute')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'cisco_xr_show_ip_route' -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    $Device.RoutingTable = @(foreach ($row in $rows) {
        $route = Create-RouteObject
        $route.VRF           = $row.VRF
        $route.RouteProtocol = $row.PROTOCOL
        $route.Subnet        = "$($row.NETWORK)/$($row.PREFIX_LENGTH)"
        $route.DISTANCE      = $row.DISTANCE
        $route.METRIC        = $row.METRIC
        if ($row.NEXT_HOP -and $row.NEXT_HOP -ne 'connected') { $route.gateway = $row.NEXT_HOP }
        $route.interface      = ([string]$row.INTERFACE -replace '^vrf\s+', '')
        $route.defaultgateway = $route.Subnet -eq '0.0.0.0/0'
        $route
    })
}

# --- Orchestrator ---------------------------------------------------------------------------------

function Process-CiscoIOSXRHostFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$HostID,
        $ArrayOfObjects   # Kept for dispatcher signature compatibility; duplicate detection is sequential.
    )

    # 1. IDENTITY - without a version capture there is nothing confirming this is IOS XR.
    $device = New-MTAutoDrawDevice -Platform 'CiscoIOSXR' -HostID $HostID
    Update-CiscoIOSXRVersion -Device $device -Path $HostID.ShowVersion
    if (-not $device.Version) {
        Write-MTAutoDrawDiagnostic -Device $device -Severity Error -Message "Cisco IOS XR '$($HostID.HOSTID)' has no valid show version capture; skipping."
        return $null
    }
    Update-CiscoIOSXRRunningConfig -Device $device -Path $HostID.ShowRun
    if (-not $device.hostname) {
        Write-MTAutoDrawDiagnostic -Device $device -Severity Error -Message "Cisco IOS XR '$($HostID.HOSTID)' has no usable hostname; skipping."
        return $null
    }

    # 2. CAPTURES - one line per slot, in dependency order. Missing slots are the reader's problem.
    Update-CiscoIOSXRInterfaceBrief -Device $device -Path $HostID.ShowIPInterfaceBrief
    Update-CiscoIOSXRArp            -Device $device -Path ($HostID.ShowArp ?? $HostID.ShowIPArp)
    Update-CiscoIOSXRCdpNeighbors   -Device $device -Path $HostID.ShowCDPNeighborsDetails
    Update-CiscoIOSXRLldpNeighbors  -Device $device -Path $HostID.ShowLLDPNeighborsDetails
    Update-CiscoIOSXRRoutes         -Device $device -Path $HostID.ShowIPRoute

    # 3. RECONCILE
    return (Complete-MTAutoDrawDevice -Device $device)
}
