# MTAutoDraw-Standard: v1
# This file contains all of the functions that process Arista EOS config.
#
# Follows PARSER_STANDARD.md v1; the orchestrator is at the foot of the file, after the readers.

# --- Platform helpers -----------------------------------------------------------------------------

# Normalizes an Arista interface name (expanding short forms and fixing 'Port-Channel' casing) and resolves it to the matching interface object on $Device.
function Resolve-AristaInterface {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$NoCreate
    )

    $normalized = (Replace-InterfaceShortName -String $Name) -replace '(?i)^Port-Channel', 'Port-channel'
    return (Resolve-MTAutoDrawInterface -Device $Device -Name $normalized -NoCreate:$NoCreate)
}

# Looks up the vendor for a Cisco-dotted MAC by its OUI. Returns 'UNKNOWN Vendor' on a miss.
function Get-AristaMacVendor {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$MacAddress)

    $hex = [string]$MacAddress -replace '[^0-9A-Fa-f]', ''
    if ($hex.Length -ne 12) { return 'UNKNOWN Vendor' }
    $colonForm = (0..5 | ForEach-Object { $hex.Substring($_ * 2, 2) }) -join ':'
    foreach ($length in 8, 5) {
        if ($GMacAddressToVendorMapping[$colonForm.Substring(0, $length)]) { return $GMacAddressToVendorMapping[$colonForm.Substring(0, $length)] }
    }
    return 'UNKNOWN Vendor'
}

# Picks which of the three routing captures to parse: an all-VRF table if one was collected and is
# usable, then the literal-star alias, then the plain table. Only one of them is ever parsed, because
# each is a complete table and parsing two would double every route.
function Select-AristaRouteCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [Parameter(Mandatory = $true)]$HostID
    )

    foreach ($slot in 'ShowIPRouteVRFAll', 'ShowIPRouteVRFstar', 'ShowIPRoute') {
        if (Test-MTAutoDrawCaptureReadable -Device $Device -Path $HostID.$slot -Capture $slot) { return $HostID.$slot }
    }
    return $null
}

# --- Capture readers ------------------------------------------------------------------------------
# Each one: GUARD, EXTRACT, MAP, MERGE. Each takes -Device and -Path, returns nothing, and is safe to
# call with a $null path - so the orchestrator needs no per-slot if-wrappers.

# Reads the running configuration for the device hostname. EOS interface configuration is not read
# here: 'show interfaces' carries strictly more, and is the capture this platform always collects.
function Update-AristaRunningConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowRun')) { return }

    # --- EXTRACT / MAP / MERGE ---
    if ((Get-MTAutoDrawCaptureText -Path $Path) -match '(?im)^hostname\s+(\S+)') { $Device.hostname = $Matches[1].Trim() }
}

# 'show hostname' is the fallback identity capture for collectors that do not take a running config.
function Update-AristaHostname {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if ($Device.hostname) { return }   # the running config already answered
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowHostname')) { return }

    # --- EXTRACT / MAP / MERGE ---
    $row = @(Invoke-MTAutoDrawTextFSM -Device $Device -Template 'arista_eos_show_hostname' -Path $Path) | Select-Object -First 1
    if ($row -and $row.HOSTNAME) { $Device.hostname = $row.HOSTNAME }
}

# Parses an Arista EOS 'show version' (via TextFSM) into the device's version object.
function Update-AristaVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowVersion')) { return }

    # --- EXTRACT ---
    $row = @(Invoke-MTAutoDrawTextFSM -Device $Device -Template 'arista_eos_show_version' -Path $Path) | Select-Object -First 1
    if (-not $row) { return }

    # --- MAP + MERGE ---
    $version = Create-ShowVersionObject
    $version.Type = 'Arista-EOS'
    $version.OS = $row.IMAGE
    $version.Image = $row.IMAGE
    $version.Uptime = $row.UPTIME
    $version.Hardware = @($row.MODEL)
    $version.Serial = @($row.SERIAL_NUMBER)
    $version.MacAddressArray = @($row.SYS_MAC)
    $Device.Version = $version
    $Device.Platform = $row.MODEL
}

# 'show reload cause' is a separate capture from 'show version', but the only field taken from it
# belongs on the version object, so it merges into whatever Update-AristaVersion already built.
function Update-AristaReloadCause {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowReloadCause')) { return }

    # --- EXTRACT / MAP / MERGE ---
    $row = @(Invoke-MTAutoDrawTextFSM -Device $Device -Template 'arista_eos_show_reload_cause' -Path $Path) | Select-Object -First 1
    if (-not $row) { return }
    if (-not $Device.Version) { $Device.Version = Create-ShowVersionObject }
    $Device.Version.ReasonForRelod = $row.RELOAD_CAUSE
}

# Parses an Arista EOS 'show vlan' capture (via TextFSM) into the device's VLAN objects (number, name, interfaces), de-duplicated by number. Returns early if the capture is unreadable or has no rows.
function Update-AristaVlans {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowVlan')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'arista_eos_show_vlan' -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    $byNumber = @{}
    foreach ($existing in @($Device.vlans | Where-Object { $_ -and $null -ne $_.number })) {
        $byNumber[[string]$existing.number] = $existing
    }
    foreach ($row in @($rows)) {
        $number = ([string]$row.VLAN_ID).Trim()
        if ($number -notmatch '^\d+$') { continue }
        if (-not $byNumber.ContainsKey($number)) {
            $vlan = Create-VlanObject
            $vlan.number = [int]$number
            $byNumber[$number] = $vlan
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$row.VLAN_NAME)) {
            $byNumber[$number].name = ([string]$row.VLAN_NAME).Trim()
        }
    }
    $Device.vlans = @($byNumber.Values | Sort-Object { [int]$_.number })
}

# Parses an Arista 'show interfaces trunk' capture, splitting the summary (Port/Mode/Status/Native vlan) and allowed-VLAN sections, and attaches trunking properties to each interface. Returns early if unreadable.
function Update-AristaInterfaceTrunks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowInterfaceTrunk')) { return }

    # --- EXTRACT + MAP + MERGE ---
    $section = ''
    foreach ($line in (Get-MTAutoDrawCaptureText -Path $Path -AsLines)) {
        if ($line -match '^\s*Port\s+Mode\s+Status\s+Native vlan\s*$') { $section = 'Summary'; continue }
        if ($line -match '^\s*Port\s+Vlans allowed\s*$') { $section = 'Allowed'; continue }
        if ($line -match '^\s*Port\s+Vlans allowed and active\b') { $section = 'Ignore'; continue }
        if ($line -match '^\s*Port\s+Vlans in spanning tree forwarding state\b') { $section = 'Ignore'; continue }
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*-+') { continue }

        if ($section -eq 'Summary' -and
            $line -match '^\s*(?<port>\S+)\s+(?<mode>\S+)\s+(?<status>\S+)\s+(?<native>\S+)\s*$') {
            $interface = Resolve-AristaInterface -Device $Device -Name $Matches['port']
            $interface.SwitchportMode = $Matches['mode'].ToLowerInvariant()
            if ($Matches['native'] -notin @('-', 'none')) { $interface.NativeVlan = $Matches['native'] }
            $interface.SwitchPortType = 'Switched'
            continue
        }

        if ($section -eq 'Allowed' -and $line -match '^\s*(?<port>\S+)\s+(?<vlans>.+?)\s*$') {
            $interface = Resolve-AristaInterface -Device $Device -Name $Matches['port']
            $interface.SwitchportTrunkVlan = $Matches['vlans'].Trim()
            $interface.SwitchportMode = 'trunk'
            $interface.SwitchPortType = 'Switched'
        }
    }
}

# Parses an Arista 'show spanning-tree' capture into the device's spanning-tree object, splitting per-MST-instance blocks (root, priority, per-VLAN state). Returns early if no instances are found.
function Update-AristaSpanningTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowSpanningTree')) { return }

    # --- EXTRACT ---
    $text = Get-MTAutoDrawCaptureText -Path $Path
    $blocks = [regex]::Matches($text, '(?ms)^(?<instance>MST\d+)\s*\r?\n(?<body>.*?)(?=^MST\d+\s*\r?$|\z)')
    if ($blocks.Count -eq 0) { return }

    # --- MAP + MERGE ---
    $spanningTree = Create-SpanningTreeObject
    foreach ($block in $blocks) {
        $instanceName = $block.Groups['instance'].Value.Trim()
        $body = $block.Groups['body'].Value
        $rootSection = [regex]::Match($body, '(?ms)^\s*Root ID\s+(?<text>.*?)(?=^\s*Bridge ID\s+)')
        $bridgeSection = [regex]::Match($body, '(?ms)^\s*Bridge ID\s+(?<text>.*?)(?=^Interface\s+Role|\z)')
        if (-not $rootSection.Success -or -not $bridgeSection.Success) { continue }

        $rootText = $rootSection.Groups['text'].Value
        $bridgeText = $bridgeSection.Groups['text'].Value
        $instance = Create-SpanningTreeVlan
        $instance.VlanID = $instanceName

        if ($body -match '(?im)^\s*Spanning tree enabled protocol\s+(?<value>\S+)') {
            $instance.protocol = $Matches['value'].Trim().ToLowerInvariant()
            if (-not $spanningTree.SpanningTreeMode) { $spanningTree.SpanningTreeMode = $instance.protocol }
        }
        if ($rootText -match '(?im)Priority\s+(?<value>\d+)') { $instance.RootIDPriority = $Matches['value'] }
        if ($rootText -match '(?im)^\s*Address\s+(?<value>\S+)') {
            $instance.Address = ConvertTo-NormalizedMacAddress $Matches['value']
        }
        if ($rootText -match '(?im)^\s*Cost\s+(?<value>.+?)\s*$') { $instance.RootBridgeCost = $Matches['value'].Trim() }
        if ($rootText -match '(?im)^\s*Port\s+(?:\d+\s+)?(?:\((?<paren>[^)]+)\)|(?<plain>\S+))') {
            $rootPort = if ($Matches['paren']) { $Matches['paren'] } else { $Matches['plain'] }
            $instance.RootBridgePort = (Replace-InterfaceShortName -String $rootPort) -replace '(?i)^Port-Channel', 'Port-channel'
            $instance.port = $instance.RootBridgePort
        }
        if ($rootText -match '(?im)^\s*Hello Time\s+(?<value>[\d.]+)') { $instance.RootBridgeHelloTime = $Matches['value'] }

        if ($bridgeText -match '(?im)Priority\s+(?<value>\d+)') { $instance.BridgeIDPriority = $Matches['value'] }
        if ($bridgeText -match '(?im)^\s*Address\s+(?<value>\S+)') {
            $instance.BridgeIDPriorityaddress = ConvertTo-NormalizedMacAddress $Matches['value']
        }
        if ($bridgeText -match '(?im)^\s*Hello Time\s+(?<value>[\d.]+)') { $instance.BridgeIDPriorityHelloTime = $Matches['value'] }

        $instance.RootBridge = ($rootText -match '(?im)^\s*This bridge is the root\s*$') -or
            ($instance.Address -and $instance.Address -eq $instance.BridgeIDPriorityaddress)
        if ($instance.RootBridge) {
            $instance.RootBridgePort = $null
            $instance.port = $null
            if ($spanningTree.RootBridgeForVlans -notcontains $instanceName) {
                $spanningTree.RootBridgeForVlans += ,$instanceName
            }
        }

        $tableStart = $body.IndexOf('Interface')
        if ($tableStart -ge 0) {
            foreach ($line in ($body.Substring($tableStart) -split '\r?\n')) {
                if ($line -notmatch '^\s*(?<name>\S+)\s+(?<role>root|designated|alternate|backup|master|disabled)\s+(?<state>\S+)\s+(?<cost>\S+)\s+(?<prio>\S+)\s*(?<type>.*)$') { continue }

                $role = switch ($Matches['role'].ToLowerInvariant()) {
                    'root'       { 'Root' }
                    'designated' { 'Desg' }
                    'alternate'  { 'Altn' }
                    'backup'     { 'Back' }
                    'master'     { 'Mast' }
                    default      { 'Disabled' }
                }
                $state = switch ($Matches['state'].ToLowerInvariant()) {
                    'forwarding' { 'FWD' }
                    'learning'   { 'LRN' }
                    'blocking'   { 'BLK' }
                    'discarding' { 'DISC' }
                    default      { $Matches['state'] }
                }
                $interfaceName = Replace-InterfaceShortName -String $Matches['name']
                $stInterface = Create-SpanningTreeInterface
                $stInterface.Interface = $interfaceName
                $stInterface.Role = $role
                $stInterface.Status = $state
                $stInterface.Cost = $Matches['cost']
                $stInterface.PrioNbr = $Matches['prio']
                $stInterface.Type = $Matches['type'].Trim()
                $instance.SpanningTreeInterfaces += ,$stInterface

                $deviceInterface = Resolve-AristaInterface -Device $Device -Name $interfaceName
                $deviceInterface.STRole = $role
                $deviceInterface.STState = $state
                switch ($role) {
                    'Root' { if ($deviceInterface.STRootInterfaceForVlans -notcontains $instanceName) { $deviceInterface.STRootInterfaceForVlans += ,$instanceName } }
                    'Desg' { if ($deviceInterface.STDesgnInterfaceForVlans -notcontains $instanceName) { $deviceInterface.STDesgnInterfaceForVlans += ,$instanceName } }
                    'Altn' { if ($deviceInterface.STALTnInterfaceForVlans -notcontains $instanceName) { $deviceInterface.STALTnInterfaceForVlans += ,$instanceName } }
                }
            }
        }

        $spanningTree.SpanningTreeArray += ,$instance
    }

    if (@($spanningTree.SpanningTreeArray).Count -gt 0) { $Device.SpanningTree = $spanningTree }
}

# The 'show lldp neighbors' summary table. Only used when the detail capture produced nothing: it
# carries no chassis ID, management address or system description.
function Update-AristaLldpNeighbors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (@($Device.LLDPNeighbors).Count -gt 0) { return }
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowLLDPNeighbors')) { return }

    # --- EXTRACT / MAP / MERGE ---
    $Device.LLDPNeighbors = @(foreach ($line in (Get-MTAutoDrawCaptureText -Path $Path -AsLines)) {
        if ($line -notmatch '^\s*(?<local>\S+)\s+(?<neighbor>\S+)\s+(?<remote>\S+)\s+\d+\s*$') { continue }
        $neighbor = Create-LLDPNeighborObject
        $neighbor.InterfaceLocalDevice = Replace-InterfaceShortName $Matches['local']
        $neighbor.InterfaceRemoteDevice = Replace-InterfaceShortName $Matches['remote']
        $neighbor.Hostname = $Matches['neighbor']
        $neighbor.ParentObject = $Device.hostname
        $neighbor
    })
}

# 'show lldp neighbors detail' is the preferred neighbour capture: it is the only one carrying the
# chassis ID, management address and system description the topology matcher uses.
function Update-AristaLldpNeighborDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowLLDPNeighborsDetails')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'arista_eos_show_lldp_neighbors_detail' -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    $neighbors = @(foreach ($row in $rows) {
        if ($GSkipCDPLLDPPhones -and (([string]$row.NEIGHBOR_DESCRIPTION -like '*Phone*') -or ([string]$row.NEIGHBOR_DESCRIPTION -like '*Endpoint*'))) { continue }

        $neighbor = Create-LLDPNeighborObject
        $neighbor.Hostname = ([string]$row.NEIGHBOR_NAME).Trim()
        $neighbor.ChassisID = ([string]$row.CHASSIS_ID).Trim()
        $neighbor.ManagementIP = ([string]$row.MGMT_ADDRESS).Trim()
        $neighbor.SystemDescription = ([string]$row.NEIGHBOR_DESCRIPTION).Trim()
        $neighbor.InterfaceRemoteDevice = (Replace-InterfaceShortName -String $row.NEIGHBOR_INTERFACE)
        $neighbor.PortID = ([string]$row.NEIGHBOR_INTERFACE).Trim()   # the raw port ID, for matching
        $neighbor.InterfaceLocalDevice = (Replace-InterfaceShortName -String $row.LOCAL_INTERFACE)
        $neighbor.ParentObject = $Device.hostname
        if ([string]::IsNullOrEmpty($neighbor.Hostname)) { $neighbor.Hostname = $neighbor.ChassisID }

        $interface = Resolve-AristaInterface -Device $Device -Name $neighbor.InterfaceLocalDevice -NoCreate
        if ($interface) {
            $interface.HasLLDPNeighbor = $true
            if ($interface.HasCPDNieghbor) { $neighbor.HasCDPNeighborEntry = $true }
        }
        $neighbor
    })
    # Sorted by port number so the diagram lists neighbours in physical order rather than capture order.
    $Device.LLDPNeighbors = $neighbors | Sort-Object -Property @{ Expression = { [int]($_.InterfaceLocalDevice -replace '[a-zA-Z-]+', '' -replace '/', '') } }
}

# Parses 'show interfaces' (via TextFSM) into the device's interfaces. This is the richest interface
# capture EOS offers, so it runs before the brief and status readers, which only fill its gaps.
function Update-AristaInterfaces {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowInterface')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'arista_eos_show_interfaces' -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    foreach ($row in $rows) {
        $interface = Resolve-AristaInterface -Device $Device -Name $row.INTERFACE
        $interface.IntStatus = $row.LINK_STATUS -replace 'administratively ', '' -replace '\s*\(.*', ''
        $interface.INTProtocolStatus = $row.PROTOCOL_STATUS -replace '\s*\(.*', '' -replace ',.*', ''
        $interface.shutdown = ($interface.IntStatus -eq 'down' -or $interface.INTProtocolStatus -eq 'down')
        $interface.HardwareType = $row.HARDWARE_TYPE
        $interface.macaddress = $row.MAC_ADDRESS
        $interface.Speed = $row.BANDWIDTH -replace 'bit/s', 'b/s'
        if ([string]::IsNullOrEmpty($interface.Description)) { $interface.Description = $row.DESCRIPTION }

        if ([string]::IsNullOrEmpty($interface.IPAddress) -and -not [string]::IsNullOrEmpty($row.IP_ADDRESS)) {
            $address = Get-NormalizedIPv4Cidr -IPAddress ([string]$row.IP_ADDRESS)
            if ($address) {
                $interface.IPAddress = $address.IPAddress
                $interface.SubnetMask = $address.PrefixLength
                $interface.Cidr = $address.Cidr
            }
        }
    }
}

# 'show ip interface brief' is the fallback interface capture, used only when 'show interfaces' was
# not collected - it carries no MAC, no hardware type and no subnet mask.
function Update-AristaInterfaceBrief {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (@($Device.interfaces).Count -gt 0) { return }
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowIPInterfaceBrief')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'arista_eos_show_ip_interface_brief' -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    foreach ($row in $rows) {
        $interface = Resolve-AristaInterface -Device $Device -Name $row.INTERFACE
        $interface.IntStatus = $row.STATUS
        $interface.INTProtocolStatus = $row.PROTOCOL
        $interface.shutdown = $row.STATUS -ne 'up'

        $address = Get-NormalizedIPv4Cidr -IPAddress ([string]$row.IP_ADDRESS)
        if (-not $address) { continue }
        $interface.IPAddress = $address.IPAddress
        $interface.SubnetMask = $address.PrefixLength
        $interface.Cidr = $address.Cidr
        $interface.SwitchPortType = 'Routed'
        $routedVlan = if ($interface.Interface -match '^Vlan(\d+)$') { $Matches[1] } else { $null }
        $null = Add-MTAutoDrawNetwork -Device $Device -Cidr $address.Cidr -RoutedVlan $routedVlan -IPAddress $address.IPAddress
    }
}

# 'show interfaces status' fills in the media, duplex, speed and access VLAN the richer captures omit.
function Update-AristaInterfaceStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowInterfaceStatus')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'arista_eos_show_interfaces_status' -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    foreach ($row in $rows) {
        $existing = Resolve-AristaInterface -Device $Device -Name $row.PORT -NoCreate
        if ($existing) {
            if ([string]::IsNullOrEmpty($existing.Description))          { $existing.Description = $row.NAME }
            if ([string]::IsNullOrEmpty($existing.IntStatus))            { $existing.IntStatus = $row.STATUS }
            if ([string]::IsNullOrEmpty($existing.SwitchportAccessVlan) -and $row.VLAN_ID -notin @('trunk','routed')) { $existing.SwitchportAccessVlan = $row.VLAN_ID }
            if ([string]::IsNullOrEmpty($existing.Duplex))               { $existing.Duplex = $row.DUPLEX }
            if ([string]::IsNullOrEmpty($existing.Speed))                { $existing.Speed = $row.SPEED }
            if ([string]::IsNullOrEmpty($existing.MediaType))            { $existing.MediaType = $row.TYPE }
            continue
        }

        $interface = Resolve-AristaInterface -Device $Device -Name $row.PORT
        $interface.Description = $row.NAME
        $interface.IntStatus = $row.STATUS
        $interface.shutdown = $row.STATUS -notin @('connected','up')
        if ($row.VLAN_ID -notin @('trunk','routed')) { $interface.SwitchportAccessVlan = $row.VLAN_ID }
        elseif ($row.VLAN_ID -eq 'trunk')            { $interface.SwitchportMode = 'trunk' }
        else                                         { $interface.SwitchPortType = 'Routed' }
        $interface.Duplex = $row.DUPLEX
        $interface.Speed = $row.SPEED
        $interface.MediaType = $row.TYPE
    }
}

# Parses 'show ip bgp summary' into the device's BGP neighbour objects.
function Update-AristaBgpSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowIPBGPSummary')) { return }
    # A switch with BGP configured but not running answers with this rather than an error.
    if ((Get-MTAutoDrawCaptureText -Path $Path) -match 'BGP not active') {
        Write-MTAutoDrawDiagnostic -Device $Device -Message 'BGP is not active on this device; no neighbours to parse.'
        return
    }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'arista_eos_show_ip_bgp_summary' -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    $Device.BGPNeighbors = @(foreach ($row in $rows) {
        $neighbor = Create-BGPNeighborObject
        $neighbor.LOCAL_AS = $row.LOCAL_AS
        $neighbor.VRF = $row.VRF
        $neighbor.DESCRIPTION = $row.DESCRIPTION
        $neighbor.NEIGHBOR = $row.BGP_NEIGH
        $neighbor.REMOTE_AS = $row.NEIGH_AS
        $neighbor.BGP_STATE = $row.STATE
        $neighbor
    })
    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message " -> Populated $(@($Device.BGPNeighbors).Count) BGP neighbors from summary file."
}

# Parses 'show ip route' into the device's routing table. The capture is chosen by
# Select-AristaRouteCapture, which prefers an all-VRF table over the single-VRF one.
function Update-AristaRoutes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowIPRoute')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'arista_eos_show_ip_route' -Path $Path
    if (@($rows).Count -eq 0) { return }

    # Egress-interface lookup for routes whose next hop is on a connected subnet. The last answer is
    # cached because a routing table is overwhelmingly consecutive runs of the same next hop, which
    # is also why the rows are sorted by next hop first.
    $activeInterfaces = @($Device.interfaces | Where-Object { $_.cidr -and $_.IntStatus -ne 'down' })
    $lastGateway = $null
    $lastInterface = $null

    # --- MAP + MERGE ---
    $Device.RoutingTable = @(foreach ($row in ($rows | Sort-Object { $_.NEXT_HOP })) {
        $route = Create-RouteObject
        $route.VRF = $row.VRF
        $route.RouteProtocol = $row.PROTOCOL
        $route.Subnet = "$($row.NETWORK)/$($row.PREFIX_LENGTH)"
        $route.DISTANCE = $row.DISTANCE
        $route.METRIC = $row.METRIC
        # NEXT_HOP and INTERFACE are List values; a route with equal-cost paths carries several.
        $route.gateway = [string](@($row.NEXT_HOP) | Select-Object -First 1)
        $route.Interface = [string](@($row.INTERFACE) | Select-Object -First 1)
        if ($route.gateway -eq 'connected') { $route.gateway = $null }
        $route.defaultgateway = $route.Subnet -eq '0.0.0.0/0'

        if ($route.gateway -and $route.gateway -ne 'Null0' -and $route.RouteProtocol -notin 'local', 'connected', 'direct') {
            if ($route.gateway -eq $lastGateway) {
                $route.Interface = $lastInterface
            }
            else {
                $found = $false
                foreach ($interface in $activeInterfaces) {
                    if ((Find-Subnet -addr1 $interface.cidr -addr2 $route.gateway).condition) {
                        $route.Interface = $interface.Interface
                        $lastGateway = $route.gateway
                        $lastInterface = $interface.Interface
                        $found = $true
                        break
                    }
                }
                if (-not $found) {
                    Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "No matching interface found for gateway $($route.gateway)"
                }
            }
        }
        $route
    })
    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "$(@($Device.RoutingTable).Count) routes found"
}

# Parses 'show ip arp' into the device's ARP entries, associating each with the most specific
# connected subnet it falls inside.
function Update-AristaArp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowIPArp')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'arista_eos_show_ip_arp' -Path $Path
    if (@($rows).Count -eq 0) { return }

    $subnetLookup = @{}
    foreach ($interface in @($Device.interfaces | Where-Object { $_.Cidr })) { $subnetLookup[$interface.Cidr] = $true }

    # --- MAP + MERGE ---
    $Device.IPArpEntries = @(foreach ($row in $rows) {
        $arp = Create-ShowIPArpObject
        $arp.ipaddress = ([string]$row.IP_ADDRESS).Trim()
        $arp.AGE = ([string]$row.AGE).Trim()
        $arp.MAC = ([string]$row.MAC_ADDRESS).Trim()
        $arp.INTERFACE = ([string]$row.INTERFACE).Trim()
        $arp.VendorCompanyName = Get-AristaMacVendor -MacAddress $arp.MAC

        # Longest prefix first, so a /30 wins over the /24 containing it.
        for ($prefix = 32; $prefix -ge 1; $prefix--) {
            $candidate = Get-NormalizedIPv4Cidr -IPAddress $arp.ipaddress -PrefixLength ([string]$prefix)
            if ($candidate -and $subnetLookup.ContainsKey($candidate.Cidr)) { $arp.cidr = $candidate.Cidr; break }
        }
        $arp
    })
}

# Parses 'show mac address-table' into the per-interface MAC lists the layer 2 pages draw from.
function Update-AristaMacAddressTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowMacAddressTable')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'arista_eos_show_mac_address-table' -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    foreach ($row in $rows) {
        # DESTINATION_PORT is a List: one MAC can be learned on several ports.
        foreach ($port in @($row.DESTINATION_PORT)) {
            if (-not $port -or $port -in @('CPU', 'Router', 'Switch')) { continue }

            $macEntry = Create-MacAddressObject
            $macEntry.Interface = (Replace-InterfaceShortName -String $port)
            if (-not (Check-InterfaceType -string $macEntry.Interface)) { continue }

            $macEntry.MacAddress = ([string]$row.MAC_ADDRESS).Trim()
            $macEntry.type = ([string]$row.TYPE).Trim()
            $macEntry.vlan = ([string]$row.VLAN_ID).Trim()
            $macEntry.VendorCompanyName = Get-AristaMacVendor -MacAddress $macEntry.MacAddress

            $interface = Resolve-AristaInterface -Device $Device -Name $macEntry.Interface -NoCreate
            if (-not $interface) {
                Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "We could not find the interface $($macEntry.Interface) on the switch. Replace-InterfaceShortName might be the problem."
                continue
            }
            $interface.MacAddressArray += ,$macEntry
        }
    }
}

# --- Orchestrator ---------------------------------------------------------------------------------

function Process-AristaHostFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$HostID,
        $ArrayOfObjects   # Kept for dispatcher signature compatibility; duplicate detection is sequential.
    )

    # 1. IDENTITY - the running config first, then 'show hostname'.
    $device = New-MTAutoDrawDevice -Platform 'AristaEOS' -HostID $HostID
    Update-AristaRunningConfig -Device $device -Path $HostID.ShowRun
    Update-AristaHostname      -Device $device -Path $HostID.ShowHostname
    if (-not $device.hostname) {
        # Some collectors omit both running-config and show hostname. The capture identifier is
        # accurate and stable, so retain the device under that identifier instead of dropping it.
        $device.hostname = $HostID.HOSTID
        Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $device -Message "Arista hostname capture is unavailable; using capture identifier '$($HostID.HOSTID)'."
    }
    Write-MTAutoDrawLog -Level Info -Phase Parse -Device $device -Message "Processing Arista Host: $($device.hostname)"

    # 2. CAPTURES - one line per slot, in dependency order. The neighbour captures run before the
    # interface ones, as they always have: the detail reader only annotates interfaces that already
    # exist, and on EOS none do at that point. Trunk, spanning-tree, route and ARP data then merge
    # onto the interfaces the three interface readers created. Arista devices do not run CDP, so
    # there is no CDP reader.
    Update-AristaVersion             -Device $device -Path $HostID.ShowVersion
    Update-AristaReloadCause         -Device $device -Path $HostID.ShowReloadCause
    Update-AristaLldpNeighborDetails -Device $device -Path $HostID.ShowLLDPNeighborsDetails
    Update-AristaLldpNeighbors       -Device $device -Path $HostID.ShowLLDPNeighbors
    Update-AristaInterfaces          -Device $device -Path $HostID.ShowInterface
    Update-AristaInterfaceBrief      -Device $device -Path $HostID.ShowIPInterfaceBrief
    Update-AristaInterfaceStatus     -Device $device -Path $HostID.ShowInterfaceStatus
    Update-AristaVlans               -Device $device -Path $HostID.ShowVlan
    Update-AristaInterfaceTrunks     -Device $device -Path $HostID.ShowInterfaceTrunk
    Update-AristaSpanningTree        -Device $device -Path $HostID.ShowSpanningTree
    Update-AristaBgpSummary          -Device $device -Path $HostID.ShowIPBGPSummary
    Update-AristaRoutes              -Device $device -Path (Select-AristaRouteCapture -Device $device -HostID $HostID)
    if ($GDrawAprEntries) { Update-AristaArp -Device $device -Path $HostID.ShowIPArp }
    # GDrawCDP is the "draw layer 2 links" toggle on this platform, which is what the MAC table feeds.
    if ($GDrawPortsWithMacs -ne 0 -and $GDrawCDP) { Update-AristaMacAddressTable -Device $device -Path $HostID.ShowMacAddressTable }

    # 3. RECONCILE
    return (Complete-MTAutoDrawDevice -Device $device)
}
