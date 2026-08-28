# MTAutoDraw-Standard: v1
# MTAudotDraw - FortiGate Module
# Copyright (C) 2022 Myles Treadwell
#
# FortiGate capture processing. Follows PARSER_STANDARD.md v1; the orchestrator is at the foot of the
# file, after the readers it calls.

# --- Platform helpers -----------------------------------------------------------------------------

# Three captures each contribute part of the version record - 'get system status' the bulk of it,
# 'get system ha status' the peer serials, and the running configuration the model and release when
# the VM reports neither - so they merge into one object rather than each replacing it.
function Get-FortiGateVersionObject {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Device)

    if (-not $Device.Version) {
        $Device.Version = Create-ShowVersionObject
        $Device.Version.Type = 'FortiGate'
    }
    return $Device.Version
}

# --- Capture readers ------------------------------------------------------------------------------
# Each one: GUARD, EXTRACT, MAP, MERGE. Each takes -Device and -Path, returns nothing, and is safe to
# call with a $null path - so the orchestrator needs no per-slot if-wrappers.

# Reads 'get system status' - the authoritative source for hostname, release and chassis serial.
function Update-FortiGateVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'SystemStatus')) { return }

    # --- EXTRACT ---
    $row = @(Invoke-MTAutoDrawTextFSM -Device $Device -Template 'fortinet_get_system_status' -Path $Path) | Select-Object -First 1
    if (-not $row) { return }

    # --- MAP + MERGE ---
    $version = Get-FortiGateVersionObject -Device $Device
    $version.Hostname       = $row.HOSTNAME
    $version.OS             = $row.VERSION
    $version.Serial        += $row.SERIAL_NUMBER
    $version.ROMMON         = $row.BIOS_VERSION
    $version.Hardware       = $row.SYSTEM_PART_NUMBER
    $version.Uptime         = $row.CLUSTER_UPTIME
    $version.ReasonForRelod = $row.LAST_REBOOT_REASON
    if ($version.Hostname) { $Device.hostname = $version.Hostname }
}

# Reads 'get system ha status' for the serial of each unit in the cluster. On a standalone box this
# capture is present but empty, which is not an error.
function Update-FortiGateHaStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'HaStatus')) { return }

    # --- EXTRACT ---
    $row = @(Invoke-MTAutoDrawTextFSM -Device $Device -Template 'fortinet_get_system_ha_status' -Path $Path) | Select-Object -First 1
    if (-not $row) { return }

    # --- MAP + MERGE ---
    $version = Get-FortiGateVersionObject -Device $Device
    foreach ($serial in $row.HA_MASTER_UNIT_SERIAL, $row.HA_SLAVE_UNIT_SERIAL) {
        if ($serial -and $version.Serial -notcontains $serial) { $version.Serial += $serial }
    }
}

# Reads 'show full-configuration': the identity and version fields the operational captures do not
# carry, and the 'config system interface' section, which is the only place role, vdom and
# allowaccess appear.
function Update-FortiGateRunningConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowFullConfig')) { return }

    # --- EXTRACT ---
    $configText = Get-MTAutoDrawCaptureText -Path $Path

    # --- MAP + MERGE: version and identity, filling only what 'get system status' left empty ---
    $version = Get-FortiGateVersionObject -Device $Device
    if ($configText -match '#config-version=(?<Model>[A-Za-z0-9]+)-(?<Version>[0-9\.]+)-FW-build(?<Build>\d+)') {
        if (-not $version.Hardware) { $version.Hardware = $Matches['Model'] }
        if (-not $version.OS)       { $version.OS = 'v' + $Matches['Version'] + ' build ' + $Matches['Build'] }
    }
    if ([string]::IsNullOrWhiteSpace($version.Hostname) -and $configText -match '(?m)^\s*set hostname\s+"?(?<Hostname>[^"\r\n]+)"?') {
        $version.Hostname = $Matches['Hostname']
        $Device.hostname  = $Matches['Hostname']
    }
    if ($configText -match '(?ms)config system ha\s+.*?set mode\s+(?<Mode>\S+)') {
        $version | Add-Member -MemberType NoteProperty -Name 'HAMode' -Value $Matches['Mode'] -Force
    }

    # --- MAP + MERGE: interfaces ---
    foreach ($block in (Get-FortiGateConfigInterfaceBlock -ConfigText $configText)) {
        if ($block -notmatch '^"?(?<name>[^"\s]+)"?') { continue }
        $interface = Resolve-MTAutoDrawInterface -Device $Device -Name $Matches['name']

        if ($block -match '(?m)^\s*set vrf\s+(?<vrf>\d+)')                     { $interface.vrf   = $Matches['vrf'] }
        if ($block -match '(?m)^\s*set vdom\s+"?(?<vdom>[^"\r\n]+)"?')         { $interface.VDOM  = $Matches['vdom'] }
        if ($block -match '(?m)^\s*set mode\s+(?<mode>\w+)')                   { $interface.Mode  = $Matches['mode'] }
        # FortiGate has no zone concept in this capture, so Role is the closest thing to the
        # segmentation label PAN-OS and ASA provide, and it is what the firewall pages fall back to.
        if ($block -match '(?m)^\s*set role\s+(?<role>\w+)')                   { $interface.Role  = $Matches['role'] }
        # Security-relevant on its own: ping/https/ssh/snmp reachable on a WAN-role interface is
        # exactly the sort of thing a firewall review wants surfaced.
        if ($block -match '(?m)^\s*set allowaccess\s+(?<access>[^\r\n]+)')     { $interface.AllowAccess = $Matches['access'].Trim() }

        # An interface with no address is written as 'set ip 0.0.0.0 0.0.0.0'.
        if ($block -match '(?m)^\s*set ip\s+(?<ip>\d{1,3}(\.\d{1,3}){3})\s+(?<mask>\d{1,3}(\.\d{1,3}){3})' -and
            -not ($Matches['ip'] -eq '0.0.0.0' -and $Matches['mask'] -eq '0.0.0.0')) {
            $address = Get-NormalizedIPv4Cidr -IPAddress $Matches['ip'] -SubnetMask $Matches['mask']
            if ($address) {
                $interface.IPAddress  = $address.IPAddress
                $interface.SubnetMask = [int]$address.PrefixLength
                $interface.Cidr       = $address.Cidr
                $null = Add-MTAutoDrawNetwork -Device $Device -Cidr $address.Cidr -IPAddress $address.IPAddress
            }
        }

        $interface.shutdown  = $block -match '(?m)^\s*set status\s+down'
        $interface.IntStatus = if ($interface.shutdown) { 'down' } else { 'up' }
    }
}

# Returns each 'edit <name>' block of the running configuration's 'config system interface' section.
#
# Cut out by walking config/end nesting rather than by one regex: the section contains nested 'config'
# stanzas (secondaryip, ipv6, l2tp), and a non-greedy match to the first 'end' would stop inside one.
function Get-FortiGateConfigInterfaceBlock {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ConfigText)

    $interfaceLines = [System.Collections.Generic.List[string]]::new()
    $depth = 0
    foreach ($line in ($ConfigText -split "`r?`n")) {
        if ($depth -eq 0) {
            if ($line -match '^\s*config system interface') { $depth = 1 }
            continue
        }
        if ($line -match '^\s*config ') { $depth++ }
        if ($line -match '^\s*end\s*$') {
            $depth--
            if ($depth -eq 0) { break }
        }
        $interfaceLines.Add($line)
    }
    if ($interfaceLines.Count -eq 0) { return @() }

    return @(($interfaceLines -join "`n") -split '(?m)^\s*edit\s+' | Where-Object { $_ -match '\S' })
}

# Reads 'get system interface', which refines what the running configuration already established:
# operational status, hardware type, and the address as the device currently holds it.
function Update-FortiGateInterfaces {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'SystemInterface')) { return }

    # --- EXTRACT ---
    # FortiOS wraps this output at terminal width, sometimes in the middle of a word. Parse the stable
    # block header and the leading key/value fields rather than requiring one physical line per record.
    $text = Get-MTAutoDrawCaptureText -Path $Path
    $blocks = [regex]::Matches($text, '(?ms)^==\s*\[\s*(?<header>[^\]]+)\s*\]\s*\r?\n(?<body>.*?)(?=^==\s*\[|\z)')

    # --- MAP + MERGE ---
    foreach ($block in $blocks) {
        $body = $block.Groups['body'].Value -replace '\r?\n\s*', ''
        $nameMatch = [regex]::Match($body, '(?:^|\s)name:\s*(?<value>\S+)')
        $name = if ($nameMatch.Success) { $nameMatch.Groups['value'].Value } else { $block.Groups['header'].Value.Trim() }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $interface = Resolve-MTAutoDrawInterface -Device $Device -Name $name

        $mode = [regex]::Match($body, '(?:^|\s)mode:\s*(?<value>\S+)')
        $status = [regex]::Match($body, '(?:^|\s)status:\s*(?<value>\S+)')
        $type = [regex]::Match($body, '(?:^|\s)type:\s*(?<value>\S+)')
        $ip = [regex]::Match($body, '(?:^|\s)ip:\s*(?<address>\d{1,3}(?:\.\d{1,3}){3})\s+(?<mask>\d{1,3}(?:\.\d{1,3}){3})')

        if ($mode.Success) { $interface.Mode = $mode.Groups['value'].Value }
        if ($status.Success) {
            $interface.IntStatus = $status.Groups['value'].Value
            $interface.INTProtocolStatus = $status.Groups['value'].Value
        }
        if ($type.Success) { $interface.HardwareType = $type.Groups['value'].Value }
        if ($ip.Success -and $ip.Groups['address'].Value -ne '0.0.0.0') {
            $normalized = Get-NormalizedIPv4Cidr -IPAddress $ip.Groups['address'].Value -SubnetMask $ip.Groups['mask'].Value
            if ($normalized) {
                $interface.IPAddress = $normalized.IPAddress
                # Deliberately the dotted mask, not the prefix length the running-config reader wrote:
                # this is the later reader, and the firewall pages render this value as FortiOS shows it.
                $interface.SubnetMask = $normalized.SubnetMask
                $interface.Cidr = $normalized.Cidr
                $interface.SwitchPortType = 'Routed'
                $null = Add-MTAutoDrawNetwork -Device $Device -Cidr $normalized.Cidr -IPAddress $normalized.IPAddress
            }
        }
    }

    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Parsed $($blocks.Count) FortiGate operational interface blocks."
}

# Parses 'get router info routing-table all' into the device's routing table.
function Update-FortiGateRoutes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowRoutingTable')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'fortinet_get_router_info_routing-table_all' -Path $Path
    if (@($rows).Count -eq 0) { return }

    # Egress-interface lookup for routes whose gateway is on a connected subnet. The last answer is
    # cached because a routing table is overwhelmingly consecutive runs of the same next hop.
    $activeInterfaces = @($Device.interfaces | Where-Object { $_.cidr -and $_.IntStatus -ne 'down' })
    $lastGateway = $null
    $lastInterface = $null

    # --- MAP + MERGE ---
    $Device.RoutingTable = @(foreach ($row in $rows) {
        $route = Create-RouteObject
        $route.VRF = $row.VRF

        switch -Regex ([string]$row.TYPE) {
            '^C'    { $route.RouteProtocol = 'connected' }
            '^S'    { $route.RouteProtocol = 'static' }
            '^R'    { $route.RouteProtocol = 'RIP' }
            '^B'    { $route.RouteProtocol = 'BGP' }
            '^O'    { $route.RouteProtocol = 'OSPF' }
            '^i'    { $route.RouteProtocol = 'IS-IS' }
            default { $route.RouteProtocol = $row.TYPE }
        }
        # A multi-character code carries the sub-type as well ('O E2', 'B IA'), so it is kept whole.
        if ([string]$row.TYPE -and ([string]$row.TYPE).Length -gt 1) { $route.RouteSubType = $row.TYPE }

        $route.Subnet   = $row.DESTINATION
        $route.DISTANCE = $row.DISTANCE
        $route.METRIC   = $row.METRIC
        # FortiOS prints the prose 'is directly connected' where other vendors leave the column blank.
        $route.gateway  = if ($row.GATEWAY -match 'is directly connected') { '0.0.0.0' } else { $row.GATEWAY }

        if (-not [string]::IsNullOrWhiteSpace($row.INTERFACE)) {
            $route.Interface = $row.INTERFACE
        }
        elseif ($route.gateway -and $route.gateway -ne '0.0.0.0') {
            if ($route.gateway -eq $lastGateway) {
                $route.Interface = $lastInterface
            }
            else {
                foreach ($candidate in $activeInterfaces) {
                    if ((Find-Subnet -addr1 $candidate.cidr -addr2 $route.gateway).condition) {
                        $route.Interface = $candidate.Interface
                        $lastGateway = $route.gateway
                        $lastInterface = $candidate.Interface
                        break
                    }
                }
            }
        }

        $route.defaultgateway = $route.Subnet -eq '0.0.0.0/0'
        $route
    })

    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Found $(@($Device.RoutingTable).Count) routes."
}

# Parses 'get system arp' into the device's ARP entries, associating each with the most specific
# connected subnet it falls inside.
function Update-FortiGateArp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowArp')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'fortinet_get_system_arp' -Path $Path
    if (@($rows).Count -eq 0) { return }

    $subnetLookup = @{}
    foreach ($interface in @($Device.interfaces | Where-Object { $_.Cidr })) { $subnetLookup[$interface.Cidr] = $true }

    # --- MAP + MERGE ---
    $Device.IPArpEntries = @(foreach ($row in $rows) {
        $arp = Create-ShowIPArpObject
        $arp.ipaddress = ([string]$row.IP_ADDRESS).Trim()
        $arp.AGE       = ([string]$row.AGE).Trim()
        $arp.MAC       = ([string]$row.MAC_ADDRESS).Trim()
        $arp.INTERFACE = ([string]$row.INTERFACE).Trim()
        $arp.VendorCompanyName = Get-FortiGateMacVendor -MacAddress $arp.MAC

        # Longest prefix first, so a /30 wins over the /24 containing it.
        for ($prefix = 32; $prefix -ge 1; $prefix--) {
            $candidate = Get-NormalizedIPv4Cidr -IPAddress $arp.ipaddress -PrefixLength ([string]$prefix)
            if ($candidate -and $subnetLookup.ContainsKey($candidate.Cidr)) { $arp.cidr = $candidate.Cidr; break }
        }
        $arp
    })

    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Found $(@($Device.IPArpEntries).Count) ARP entries."
}

# Looks up the vendor for a MAC address by matching its OUI prefix (8 or 5 characters of the
# colon-separated form) against the global MAC->vendor map. Returns 'UNKNOWN Vendor' when not found.
function Get-FortiGateMacVendor {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$MacAddress)

    if ([string]::IsNullOrWhiteSpace($MacAddress) -or $MacAddress.Length -lt 8) { return $null }
    foreach ($length in 8, 5) {
        if ($MacAddress.Length -lt $length) { continue }
        $prefix = $MacAddress.Substring(0, $length)
        if ($GMacAddressToVendorMapping[$prefix]) { return $GMacAddressToVendorMapping[$prefix] }
    }
    return 'UNKNOWN Vendor'
}


#region Security policy

# Resolves a FortiGate srcintf/dstintf value to the closest thing this device has to a zone.
#
# FortiGate config in these captures has no 'config system zone' at all, so an interface's Role
# (lan/wan/dmz) is the segmentation label - the same fallback the firewall pages already use for
# FortiGate interfaces. Where an interface has no role, the interface name itself is used rather than
# dropping the rule: an unlabelled segment is still a segment. 'all' becomes 'any' to match the
# PAN-OS vocabulary, so a wildcard reads the same on every vendor's diagram.
function Resolve-FortiGateInterfaceZone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$InterfaceName
    )

    if ([string]::IsNullOrWhiteSpace($InterfaceName)) { return $null }
    if ($InterfaceName -in @('all', 'any')) { return 'any' }

    $match = @($Device.interfaces | Where-Object { $_.Interface -eq $InterfaceName }) | Select-Object -First 1
    if ($match -and $match.Role -and $match.Role -ne 'undefined') { return [string]$match.Role }
    return $InterfaceName
}


# Reads 'config firewall policy' - the FortiGate equivalent of a PAN-OS security rulebase.
#
#     edit 1
#         set name "allow"
#         set srcintf "all"
#         set dstintf "port1"
#         set action accept
#     next
#
# Unlike ASA, both directions are present, so these rules carry a real zone pair. Action is
# normalised to the PAN-OS vocabulary here ('accept' -> 'allow'); note that FortiGate omits the
# action line entirely on a deny rule, which is why the default below is 'deny' and not 'allow' -
# reading it the other way round would silently turn every block rule into a permit.
function Update-FortiGateFirewallPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowFirewallPolicy')) { return }

    # --- EXTRACT ---
    $text = Get-MTAutoDrawCaptureText -Path $Path
    # Anchor on the policy section so a full-configuration capture containing many 'edit' blocks
    # cannot bleed non-policy stanzas in. Non-greedy to the section's own closing 'end'.
    #
    # The optional prompt prefix is not optional in practice: collectors capture the echoed command,
    # so the real captures open with "Forti # config firewall policy" on one line. Tolerated here
    # rather than by running the text through Remove-DevicePrompt, which ends in Out-String and can
    # wrap the long 'set' lines this parser depends on.
    #
    # The leading \s* is equally load-bearing. Where the prompt has been stripped - by a sanitizer, or
    # by a collector that removes it - what is left on that line is a single space before
    # "config firewall policy", and without this the section is never found and the device silently
    # reports no firewall rules at all.
    $section = [regex]::Match($text, '(?ms)^\s*(?:\S+\s*[#>]\s*)?config firewall policy\s*$(?<body>.*?)^\s*end\s*$')
    if (-not $section.Success) {
        Write-MTAutoDrawDiagnostic -Device $Device -Message 'No config firewall policy section found in the capture.'
        return
    }

    $rules = [System.Collections.Generic.List[object]]::new()
    foreach ($block in [regex]::Matches($section.Groups['body'].Value, '(?ms)^\s*edit\s+(?<id>\d+)\s*$(?<body>.*?)^\s*next\s*$')) {
        $body = $block.Groups['body'].Value

        # 'set srcaddr "A" "B"' - a space-separated list of quoted names, or bare words.
        # The trailing \s* is load-bearing: captures are CRLF, and without it the value class
        # [^\r\n]+ stops at the \r while $ anchors before the \n, so nothing matches at all.
        $readList = {
            param([string]$Key)
            $match = [regex]::Match($body, "(?m)^\s*set $([regex]::Escape($Key))\s+(?<value>[^\r\n]+?)\s*$")
            if (-not $match.Success) { return @() }
            return @([regex]::Matches($match.Groups['value'].Value, '"(?<item>[^"]*)"|(?<item>\S+)') |
                ForEach-Object { $_.Groups['item'].Value } | Where-Object { $_ })
        }
        $readOne = {
            param([string]$Key)
            $match = [regex]::Match($body, "(?m)^\s*set $([regex]::Escape($Key))\s+`"?(?<value>[^`"\r\n]+?)`"?\s*$")
            if ($match.Success) { return $match.Groups['value'].Value.Trim() }
            return $null
        }

        # --- MAP ---
        $rule = Create-SecurityPolicyRuleObject
        $rule.Name        = (& $readOne 'name')
        if (-not $rule.Name) { $rule.Name = "policy $($block.Groups['id'].Value)" }
        $rule.Index       = [int]$block.Groups['id'].Value
        $rule.FromZones   = @(& $readList 'srcintf' | ForEach-Object { Resolve-FortiGateInterfaceZone -Device $Device -InterfaceName $_ } | Where-Object { $_ } | Select-Object -Unique)
        $rule.ToZones     = @(& $readList 'dstintf' | ForEach-Object { Resolve-FortiGateInterfaceZone -Device $Device -InterfaceName $_ } | Where-Object { $_ } | Select-Object -Unique)
        $rule.Source      = @(& $readList 'srcaddr')
        $rule.Destination = @(& $readList 'dstaddr')
        $rule.Application = @(& $readList 'service')
        $action           = (& $readOne 'action')
        # FortiGate writes no action line at all for a deny, so absence means deny.
        $rule.Action      = if ($action -eq 'accept') { 'allow' } else { 'deny' }
        $rule.RuleType    = 'policy'
        $rule.Disabled    = ((& $readOne 'status') -eq 'disable')
        $rules.Add($rule)
    }

    # --- MERGE ---
    $Device.SecurityPolicy = @($rules)
    Write-MTAutoDrawDiagnostic -Device $Device -Message "Parsed $($rules.Count) FortiGate firewall policy rules."
}
#endregion


# --- Orchestrator ---------------------------------------------------------------------------------

function Process-FortiGateHostFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$HostID,
        $ArrayOfObjects   # Kept for dispatcher signature compatibility; duplicate detection is sequential.
    )

    # 1. IDENTITY - the hostname is in 'get system status', and in the running configuration as a
    # fallback for a box whose status capture failed. Both are optional individually, neither is
    # optional collectively.
    $device = New-MTAutoDrawDevice -Platform 'FortiGate' -HostID $HostID
    # Every FortiGate carries a version object even when no capture produced one: the diagrams read
    # Version.Type to label the vendor.
    $null = Get-FortiGateVersionObject -Device $device
    Update-FortiGateVersion       -Device $device -Path $HostID.SystemStatus
    Update-FortiGateRunningConfig -Device $device -Path $HostID.ShowFullConfig
    if ([string]::IsNullOrEmpty($device.hostname)) {
        Write-MTAutoDrawDiagnostic -Device $device -Severity Warning -Message "FortiGate '$($HostID.HOSTID)' has no hostname in any capture; skipping host."
        return $null
    }

    # 2. CAPTURES - one line per slot, in dependency order. Interfaces come from the running config
    # first (role, vdom, allowaccess) and are then refined by the operational capture; routes and ARP
    # both resolve their egress against those interfaces, so they follow.
    Update-FortiGateHaStatus       -Device $device -Path $HostID.HaStatus
    Update-FortiGateInterfaces     -Device $device -Path $HostID.SystemInterface
    Update-FortiGateRoutes         -Device $device -Path $HostID.ShowRoutingTable
    if ($GDrawAprEntries) { Update-FortiGateArp -Device $device -Path $HostID.ShowArp }
    Update-FortiGateFirewallPolicy -Device $device -Path $HostID.ShowFirewallPolicy

    # 3. RECONCILE - the chassis serial and the HA peer serials overlap on a standalone unit.
    $device.Version.Serial = $device.Version.Serial | Select-Object -Unique | Where-Object { $_ -ne '' }
    return (Complete-MTAutoDrawDevice -Device $device)
}
