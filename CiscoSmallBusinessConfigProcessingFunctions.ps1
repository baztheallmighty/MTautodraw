# MTAutoDraw-Standard: v1
#MTAudotDraw
#Copyright (C) 2022  Myles Treadwell
#
#This program is free software: you can redistribute it and/or modify
#it under the terms of the GNU General Public License as published by
#the Free Software Foundation, either version 3 of the License, or
#(at your option) any later version.

# Cisco Small Business (SG/CBS) parsing. The functions in this file populate the same
# host/interface/neighbor/route objects as the Cisco IOS parser. No TextFSM: none of these captures
# has an ntc-template, so every reader is regex over named groups.
#
# Follows PARSER_STANDARD.md v1; the orchestrator is at the foot of the file, after the readers.

# --- Platform helpers -----------------------------------------------------------------------------

function Get-CiscoSmallBusinessRegexValue {
    param(
        [AllowNull()]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$Pattern,
        [int]$Group = 1
    )

    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $match = [regex]::Match($Text, $Pattern)
    if (-not $match.Success -or $match.Groups.Count -le $Group) { return $null }
    return $match.Groups[$Group].Value.Trim()
}

# Normalizes a Cisco interface shorthand (gi/te/fi/fa/Po/Vlan + number) into its full canonical name (GigabitEthernet, TenGigabitEthernet, Port-channel, Vlan, etc.) by stripping whitespace and matching a regex table.
function ConvertTo-CiscoSmallBusinessInterfaceName {
    param([AllowNull()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $value = ($Name.Trim() -replace '\s+', '')

    switch -Regex ($value) {
        '^gi(?<id>\d.*)$'                  { return "GigabitEthernet$($Matches.id)" }
        # Some older Small Business firmware (e.g. the SG200/SRW2000 line) abbreviates
        # GigabitEthernet to a bare 'g' rather than 'gi' - both in its own port tables and in the
        # LLDP neighbour data it reports, so this has to canonicalize the same as 'gi' does.
        '^g(?<id>\d.*)$'                   { return "GigabitEthernet$($Matches.id)" }
        '^te(?<id>\d.*)$'                  { return "TenGigabitEthernet$($Matches.id)" }
        '^fi(?<id>\d.*)$'                  { return "FiveGigabitEthernet$($Matches.id)" }
        '^fa(?<id>\d.*)$'                  { return "FastEthernet$($Matches.id)" }
        '^po(?:rt-channel)?(?<id>\d+)$'    { return "Port-channel$($Matches.id)" }
        '^vlan(?<id>\d+)$'                 { return "Vlan$($Matches.id)" }
        '^gigabitethernet(?<id>\d.*)$'     { return "GigabitEthernet$($Matches.id)" }
        '^tengigabitethernet(?<id>\d.*)$'  { return "TenGigabitEthernet$($Matches.id)" }
        '^fivegigabitethernet(?<id>\d.*)$' { return "FiveGigabitEthernet$($Matches.id)" }
        '^fastethernet(?<id>\d.*)$'        { return "FastEthernet$($Matches.id)" }
        default                            { return $Name.Trim() }
    }
}

# Expands a comma-separated list of numbers and ranges (e.g. '1,3,5-8') into a flat List[int] of every individual number, for use with VLAN/interface lists.
function Expand-CiscoSmallBusinessNumberList {
    param([AllowNull()][string]$Value)

    $numbers = [System.Collections.Generic.List[int]]::new()
    foreach ($item in @($Value -split ',')) {
        $part = $item.Trim()
        if ($part -match '^(\d+)-(\d+)$') {
            $start = [int]$Matches[1]
            $end = [int]$Matches[2]
            if ($start -le $end) {
                foreach ($number in $start..$end) { $numbers.Add($number) }
            }
        }
        elseif ($part -match '^\d+$') {
            $numbers.Add([int]$part)
        }
    }
    return @($numbers | Sort-Object -Unique)
}

# Find-or-create by interface name, canonicalising first. Wraps the shared helper rather than calling
# it directly because every capture on this platform spells the same port differently: the running
# config says 'TenGigabitEthernet1/0/12' and every operational capture says 'te1/0/12'. Without the
# canonicalisation each capture would build its own parallel set of interfaces.
#
# -Create is opt-in, not opt-out as in the shared helper: several readers here (switchport, MAC table,
# spanning tree) must only enrich ports the running config or status capture already proved exist.
function Resolve-CiscoSmallBusinessInterface {
    param(
        [Parameter(Mandatory = $true)]$Device,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$Create
    )

    $canonicalName = ConvertTo-CiscoSmallBusinessInterfaceName -Name $Name
    if (-not $canonicalName) { return $null }
    if (-not $Create) { return (Resolve-MTAutoDrawInterface -Device $Device -Name $canonicalName -NoCreate) }
    return (Resolve-MTAutoDrawInterface -Device $Device -Name $canonicalName)
}

# Resolves the OUI vendor for a MAC address by looking up its first 8 or 5 hex digits in the $GMacAddressToVendorMapping table. Returns 'UNKNOWN Vendor' for blank/malformed addresses or a miss.
function Get-CiscoSmallBusinessMacVendor {
    param([AllowNull()][string]$MacAddress)

    if ([string]::IsNullOrWhiteSpace($MacAddress)) { return 'UNKNOWN Vendor' }
    $hex = ($MacAddress -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($hex.Length -ne 12) { return 'UNKNOWN Vendor' }
    $formatted = '{0}:{1}:{2}:{3}:{4}:{5}' -f $hex.Substring(0,2),$hex.Substring(2,2),$hex.Substring(4,2),$hex.Substring(6,2),$hex.Substring(8,2),$hex.Substring(10,2)

    if ($GMacAddressToVendorMapping) {
        if ($GMacAddressToVendorMapping.ContainsKey($formatted.Substring(0,8))) {
            return $GMacAddressToVendorMapping[$formatted.Substring(0,8)]
        }
        if ($GMacAddressToVendorMapping.ContainsKey($formatted.Substring(0,5))) {
            return $GMacAddressToVendorMapping[$formatted.Substring(0,5)]
        }
    }
    return 'UNKNOWN Vendor'
}

# The three identity captures each fill part of one version record, so they merge into it rather than
# each replacing it. Whichever runs first creates it.
function Get-CiscoSmallBusinessVersionObject {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Device)

    if (-not $Device.Version) {
        $Device.Version = Create-ShowVersionObject
        $Device.Version.Type = 'CiscoSmallBusiness'
    }
    return $Device.Version
}

# Extracts a fixed-column substring (Start..End) from a whitespace-aligned table line, trimming the result. Returns '' if the range is out of bounds.
function Get-CiscoSmallBusinessColumnValue {
    param(
        [Parameter(Mandatory = $true)][string]$Line,
        [Parameter(Mandatory = $true)][int]$Start,
        [Parameter(Mandatory = $true)][int]$End
    )

    if ($Line.Length -le $Start) { return '' }
    $length = [Math]::Min($End, $Line.Length) - $Start
    if ($length -le 0) { return '' }
    return $Line.Substring($Start, $length).Trim()
}

# --- Capture readers ------------------------------------------------------------------------------
# Each one: GUARD, EXTRACT, MAP, MERGE. Each takes -Device and -Path, returns nothing, and is safe to
# call with a $null path - so the orchestrator needs no per-slot if-wrappers.

# Reads the running configuration: hostname, spanning-tree mode, the interface stanzas, and the VLAN
# database. Everything else in this module enriches what this reader established.
function Update-CiscoSmallBusinessRunningConfig {
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
    $Device.hostname = Get-CiscoSmallBusinessRegexValue -Text $config -Pattern '(?mi)^\s*hostname\s+(\S+)'
    if (-not $Device.hostname) { $Device.hostname = 'NoHostNameFoundCheckForConfigProblems' }

    $Device.SpanningTree = Create-SpanningTreeObject
    $Device.SpanningTree.SpanningTreeMode = Get-CiscoSmallBusinessRegexValue -Text $config -Pattern '(?mi)^\s*spanning-tree\s+mode\s+(\S+)'

    # --- MAP + MERGE: interfaces ---
    foreach ($match in [regex]::Matches($config, '(?ms)^[ \t]*interface\s+(?<name>[^\r\n]+)\r?\n(?<body>.*?)(?=^[^\s\r\n]|\z)')) {
        $interface = Resolve-CiscoSmallBusinessInterface -Device $Device -Name $match.Groups['name'].Value -Create
        if (-not $interface) { continue }
        $body = $match.Groups['body'].Value
        $interface.shutdown = $body -match '(?mi)^\s*shutdown\s*$'

        $interface.Description = Get-CiscoSmallBusinessRegexValue -Text $body -Pattern '(?mi)^\s*description\s+(.+)$'
        $interface.SwitchportMode = Get-CiscoSmallBusinessRegexValue -Text $body -Pattern '(?mi)^\s*switchport\s+mode\s+(\S+)'
        $interface.SwitchportAccessVlan = Get-CiscoSmallBusinessRegexValue -Text $body -Pattern '(?mi)^\s*switchport\s+access\s+vlan\s+(\d+)'
        $interface.SwitchportTrunkVlan = Get-CiscoSmallBusinessRegexValue -Text $body -Pattern '(?mi)^\s*switchport\s+trunk\s+allowed\s+vlan(?:\s+add)?\s+(.+)$'
        $interface.NativeVlan = Get-CiscoSmallBusinessRegexValue -Text $body -Pattern '(?mi)^\s*switchport\s+trunk\s+native\s+vlan\s+(\d+)'
        $interface.SpanningTreePortType = Get-CiscoSmallBusinessRegexValue -Text $body -Pattern '(?mi)^\s*spanning-tree\s+port(?:\s+type)?\s+(.+)$'
        $interface.bpdufilter = Get-CiscoSmallBusinessRegexValue -Text $body -Pattern '(?mi)^\s*spanning-tree\s+bpdufilter\s+(.+)$'

        $channelMatch = [regex]::Match($body, '(?mi)^\s*channel-group\s+(\d+)(?:\s+mode\s+(\S+))?')
        if ($channelMatch.Success) {
            $interface.ChannelGroup = $channelMatch.Groups[1].Value
            $interface.ChannelGroupMode = $channelMatch.Groups[2].Value
        }

        $ipMatch = [regex]::Match($body, '(?mi)^\s*ip\s+address\s+(?<ip>\d{1,3}(?:\.\d{1,3}){3})\s+(?<mask>\d{1,3}(?:\.\d{1,3}){3})\s*$')
        if ($ipMatch.Success) {
            $interface.IPAddress = $ipMatch.Groups['ip'].Value
            $interface.SubnetMask = $ipMatch.Groups['mask'].Value
            $address = Get-NormalizedIPv4Cidr -IPAddress $ipMatch.Groups['ip'].Value -SubnetMask $ipMatch.Groups['mask'].Value
            if ($address) {
                $interface.Cidr = $address.Cidr
                $interface.SubnetMask = $address.PrefixLength
            }
        }

        if ($interface.Interface -match '^Vlan(\d+)$') {
            $interface.RoutedVlan = $Matches[1]
        }
        elseif ($interface.IPAddress) {
            $interface.RoutedVlan = 'no vlan'
        }

        if ($interface.IPAddress -or $body -match '(?mi)^\s*no\s+switchport\s*$') {
            $interface.SwitchPortType = 'Routed'
        }
        elseif ($interface.SwitchportMode -or $interface.SwitchportAccessVlan -or $body -match '(?mi)^\s*switchport') {
            $interface.SwitchPortType = 'Switched'
        }

        if ($interface.Cidr) {
            # The routed VLAN of an SVI's network is the interface name ('Vlan1'), not the bare number
            # the interface itself carries - that is what the layer 3 pages label the subnet with.
            $routedVlan = if ($interface.Interface -match '^Vlan') { $interface.Interface } else { $null }
            $null = Add-MTAutoDrawNetwork -Device $Device -Cidr $interface.Cidr -RoutedVlan $routedVlan -IPAddress $interface.IPAddress
        }
    }

    # --- MAP + MERGE: VLAN database ---
    $vlans = @()
    foreach ($match in [regex]::Matches($config, '(?mi)^vlan\s+([0-9,\-]+)\s*$')) {
        foreach ($number in @(Expand-CiscoSmallBusinessNumberList -Value $match.Groups[1].Value)) {
            $vlan = Create-VlanObject
            $vlan.number = $number
            $vlan.name = 'No name'
            $vlans += ,$vlan
        }
    }
    $Device.vlans = @($vlans | Sort-Object { [int]$_.number } -Unique)
}

# Reads 'show system' for the switch's name, model description, location, uptime and chassis MAC.
function Update-CiscoSmallBusinessSystem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowSystem')) { return }

    # --- EXTRACT ---
    $text = Get-MTAutoDrawCaptureText -Path $Path
    $systemName = Get-CiscoSmallBusinessRegexValue -Text $text -Pattern '(?i)System Name:[ \t]*([^\r\n]+)'
    $description = Get-CiscoSmallBusinessRegexValue -Text $text -Pattern '(?i)System Description:[ \t]*([^\r\n]+)'
    $location = Get-CiscoSmallBusinessRegexValue -Text $text -Pattern '(?i)System Location:[ \t]*([^\r\n]*)'
    $systemMac = Get-CiscoSmallBusinessRegexValue -Text $text -Pattern '(?i)System MAC Address:[ \t]*(\S+)'

    # --- MAP + MERGE ---
    $version = Get-CiscoSmallBusinessVersionObject -Device $Device
    if ($systemName) {
        $version.Hostname = $systemName
        if (-not $Device.hostname -or $Device.hostname -like '*NoHostNameFound*') { $Device.hostname = $systemName }
    }
    if ($description) {
        $Device.Platform = ($description -split '\s+')[0]
        $Device.Description = if ($location) { "$description`r`nLocation: $location" } else { $description }
        $version.Hardware += $Device.Platform
    }
    $version.Uptime = Get-CiscoSmallBusinessRegexValue -Text $text -Pattern '(?i)System Up Time \(days,hour:min:sec\):[ \t]*([^\r\n]+)'
    if ($systemMac) { $version.MacAddressArray = @($systemMac) }
}

# Reads 'show version' for the running firmware image and its release.
function Update-CiscoSmallBusinessVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowVersion')) { return }

    # --- EXTRACT / MAP / MERGE ---
    $active = [regex]::Match((Get-MTAutoDrawCaptureText -Path $Path), '(?ms)Active-image:\s*(?<image>\S+)\s+Version:\s*(?<version>\S+)')
    if (-not $active.Success) { return }
    $version = Get-CiscoSmallBusinessVersionObject -Device $Device
    $version.Image = $active.Groups['image'].Value
    $version.OS = $active.Groups['version'].Value
}

# Reads 'show inventory' for each stack member's PID and serial number.
function Update-CiscoSmallBusinessInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowInventory')) { return }

    # --- EXTRACT / MAP / MERGE ---
    $version = Get-CiscoSmallBusinessVersionObject -Device $Device
    foreach ($item in [regex]::Matches((Get-MTAutoDrawCaptureText -Path $Path), '(?ms)^NAME:\s*"(?<name>[^"]+)"\s+DESCR:\s*"(?<description>[^"]*)"\s*\r?\nPID:\s*(?<pid>\S+)\s+VID:\s*(?<vid>\S*)\s+SN:\s*(?<serial>\S+)')) {
        if ($item.Groups['pid'].Value)    { $version.Hardware += $item.Groups['pid'].Value }
        if ($item.Groups['serial'].Value) { $version.Serial   += $item.Groups['serial'].Value }
    }
}

# Parses a 'show vlan' capture into the device's VLAN objects (number, name), reading the tabular rows below the column separator.
function Update-CiscoSmallBusinessVlans {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowVlan')) { return }

    # --- EXTRACT / MAP ---
    $vlans = @()
    $inTable = $false
    foreach ($line in (Get-MTAutoDrawCaptureText -Path $Path -AsLines)) {
        if ($line -match '^----\s+') { $inTable = $true; continue }
        if (-not $inTable) { continue }
        if ($line -match '^\S+[#>]\s*$') { break }
        if ($line -match '^\s*(?<number>\d+)\s+(?<name>\S+)') {
            $vlan = Create-VlanObject
            $vlan.number = [int]$Matches['number']
            $vlan.name = $Matches['name']
            $vlans += ,$vlan
        }
    }

    # --- MERGE ---
    # Only when the capture actually produced rows: the running config's VLAN database is a better
    # answer than an empty table from a switch that answered the command with a banner and nothing else.
    if ($vlans.Count -gt 0) { $Device.vlans = @($vlans | Sort-Object { [int]$_.number }) }
}

# Parses a 'show interface status' capture to set per-interface admin/oper status and speed/duplex on the device's interface objects.
function Update-CiscoSmallBusinessInterfaceStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowInterfaceStatus')) { return }

    # --- EXTRACT / MAP / MERGE ---
    foreach ($line in (Get-MTAutoDrawCaptureText -Path $Path -AsLines)) {
        if ($line -notmatch '^\s*(?<port>(?:(?:gi|te|fi|fa|g)\d\S*|Po\d+))\s+') { continue }
        $tokens = @($line.Trim() -split '\s+')
        if ($tokens.Count -lt 7) { continue }

        # A 'Not Present' row is a slot in a stack unit that is not installed. It must not create an
        # interface, but it is recorded on one that already exists.
        $isNotPresent = $line -match '\bNot Present\b'
        $interface = Resolve-CiscoSmallBusinessInterface -Device $Device -Name $tokens[0] -Create:(!$isNotPresent)
        if (-not $interface) { continue }
        if ($isNotPresent) {
            $interface.IntStatus = 'Not Present'
            continue
        }

        $interface.MediaType = if ($tokens[1] -ne '--') { $tokens[1] } else { $interface.MediaType }
        $interface.Duplex = if ($tokens[2] -ne '--') { $tokens[2] } else { $interface.Duplex }
        if ($tokens[3] -ne '--') {
            $interface.Speed = if ($tokens[3] -match '^\d+$') { "$($tokens[3])Mb/s" } else { $tokens[3] }
        }
        $interface.IntStatus = if ($tokens[6] -eq 'Up') { 'Up' } else { 'Down' }
        $interface.INTProtocolStatus = $interface.IntStatus
    }
}

# Parses 'show interfaces switchport' per-interface blocks (Name:, Access mode, VLAN, Trunking encapsulation, etc.) to populate each interface's switchport properties.
function Update-CiscoSmallBusinessInterfaceSwitchport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowInterfaceSwitchport')) { return }

    # --- EXTRACT / MAP / MERGE ---
    foreach ($block in [regex]::Split((Get-MTAutoDrawCaptureText -Path $Path), '(?m)(?=^Name:)')) {
        $name = Get-CiscoSmallBusinessRegexValue -Text $block -Pattern '(?mi)^Name:\s*(\S+)'
        if (-not $name) { continue }
        # show interfaces switchport includes default ports for absent stack members. Only enrich
        # interfaces proven by the running config or the status capture.
        $interface = Resolve-CiscoSmallBusinessInterface -Device $Device -Name $name
        if (-not $interface) { continue }

        $enabled = Get-CiscoSmallBusinessRegexValue -Text $block -Pattern '(?mi)^Switchport:\s*(\S+)'
        if ($enabled -and $enabled -ne 'enable') { continue }
        $mode = Get-CiscoSmallBusinessRegexValue -Text $block -Pattern '(?mi)^Administrative Mode:\s*(.+)$'
        if ($mode) { $interface.SwitchportMode = $mode.ToLowerInvariant() }
        $accessVlan = Get-CiscoSmallBusinessRegexValue -Text $block -Pattern '(?mi)^Access Mode VLAN:\s*(\d+)'
        if ($accessVlan) { $interface.SwitchportAccessVlan = $accessVlan }
        $nativeVlan = Get-CiscoSmallBusinessRegexValue -Text $block -Pattern '(?mi)^Trunking Native Mode VLAN:\s*(\d+)'
        if ($nativeVlan) { $interface.NativeVlan = $nativeVlan }
        $trunkVlans = Get-CiscoSmallBusinessRegexValue -Text $block -Pattern '(?mi)^Trunking VLANs:\s*(.+)$'
        if ($trunkVlans -and $trunkVlans -ne 'none') { $interface.SwitchportTrunkVlan = $trunkVlans.Trim() }
        $interface.SwitchPortType = 'Switched'

        if (-not $interface.IntStatus) {
            $operational = Get-CiscoSmallBusinessRegexValue -Text $block -Pattern '(?mi)^Operational Mode:\s*(\S+)'
            if ($operational) { $interface.IntStatus = if ($operational -eq 'up') { 'Up' } else { 'Down' } }
        }
    }
}

# Parses a 'show interfaces description' capture to set the description text on each matching interface object.
function Update-CiscoSmallBusinessInterfaceDescriptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowInterfaceDescription')) { return }

    # --- EXTRACT / MAP / MERGE ---
    foreach ($line in (Get-MTAutoDrawCaptureText -Path $Path -AsLines)) {
        if ($line -notmatch '^\s*(?<port>(?:gi|te|fi|fa|g|Po)\S*)\s*(?<description>.*)$') { continue }
        $port = $Matches['port']
        $description = $Matches['description'].Trim()
        $interface = Resolve-CiscoSmallBusinessInterface -Device $Device -Name $port
        if ($interface -and $description) { $interface.Description = $description }
    }
}

# Parses 'show cdp neighbors detail' blocks (Device-ID + local/remote interface) into the device's CDP neighbour objects, mapping each to its local interface.
function Update-CiscoSmallBusinessCdpNeighbors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowCDPNeighborsDetails')) { return }

    # --- EXTRACT ---
    $text = Get-MTAutoDrawCaptureText -Path $Path
    $neighbors = @()

    # Two CDP-detail dialects appear in the SG/CBS captures. The older one uses 'Device-ID:'
    # (hyphen, 'Capabilities:' as its own line, 'IP <addr>' under Addresses:). The newer SG350/SG550
    # firmware uses 'Device ID:' (space), 'Platform: ...,  Capabilities: ...' on one line, and
    # 'IP address:' under Entry address(es):. The block split and the field extraction below
    # therefore accept an optional space in the field name and both address spellings.
    $blockRe = '(?ms)^\s*Device-?ID:\s*(?<id>[^
\n]+)
?\n(?<body>.*?)(?=^\s*-{5,}\s*$|\z)'

    # --- MAP + MERGE ---
    foreach ($match in [regex]::Matches($text, $blockRe)) {
        $body = $match.Groups['body'].Value
        $capabilities = Get-CiscoSmallBusinessRegexValue -Text $body -Pattern '(?mi)^Capabilities:\s*(.+)$'
        if ($capabilities -ceq '') {
            $inline = [regex]::Match($body, '(?im)Platform:.*?Capabilities:\s*(.+?)\s*$')
            if ($inline.Success) { $capabilities = $inline.Groups[1].Value }
        }
        if ($GSkipCDPLLDPPhones -and $capabilities -match '(?i)phone') { continue }

        $interfaceMatch = [regex]::Match($body, '(?mi)^Interface:\s*(?<local>[^,]+),\s*Port ID \(outgoing port\):\s*(?<remote>.+)$')
        if (-not $interfaceMatch.Success) { continue }
        $neighbor = Create-CDPNeighborObject
        $neighbor.DeviceID = $match.Groups['id'].Value.Trim()
        # SG/CBS switches report Device-ID as a bare MAC address and carry the real hostname in
        # SysName. Without this the neighbour can only ever be identified by a MAC, which never
        # matches a configured hostname and leaves the link undrawn.
        $neighbor.SystemName = Get-CiscoSmallBusinessRegexValue -Text $body -Pattern '(?mi)^SysName:\s*(.+)$'
        $neighbor.Platform = Get-CiscoSmallBusinessRegexValue -Text $body -Pattern '(?mi)^Platform:\s*(.+)$'
        $neighbor.Capabilities = $capabilities
        $neighbor.InterfaceLocalDevice = ConvertTo-CiscoSmallBusinessInterfaceName -Name $interfaceMatch.Groups['local'].Value
        $neighbor.InterfaceRemoteDevice = ConvertTo-CiscoSmallBusinessInterfaceName -Name $interfaceMatch.Groups['remote'].Value
        $neighbor.Version = Get-CiscoSmallBusinessRegexValue -Text $body -Pattern '(?mi)^Version:\s*(.+)$'
        $neighbor.NativeVLAN = Get-CiscoSmallBusinessRegexValue -Text $body -Pattern '(?mi)^Native VLAN:\s*(\S+)'
        $neighbor.InterfaceIPAddresses = Get-CiscoSmallBusinessRegexValue -Text $body -Pattern '(?mi)^\s*IP\s+(\d{1,3}(?:\.\d{1,3}){3})'
        $neighbor.ParentObject = $Device.hostname
        $interface = Resolve-CiscoSmallBusinessInterface -Device $Device -Name $neighbor.InterfaceLocalDevice
        if ($interface) { $interface.HasCPDNieghbor = $true }
        $neighbors += ,$neighbor
    }
    $Device.CDPNeighbors = @($neighbors)
}

# Parses a headered 'show lldp neighbors table' capture (Port / Device ID / Port ID / System Name / Capabilities / TTL) into the device's LLDP neighbour objects.
function Update-CiscoSmallBusinessLldpNeighbors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowLLDPNeighbors')) { return }

    # --- EXTRACT ---
    # This table has no delimiter and wraps long values onto continuation lines, so the only reliable
    # way to read it is by the column offsets its own '---- ----' separator declares.
    $lines = @(Get-MTAutoDrawCaptureText -Path $Path -AsLines)
    $headerIndex = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        # TTL is its own dash-group on current SG3xx/CBS firmware, but older Small Business firmware
        # (the same generation that abbreviates GigabitEthernet to bare 'g') omits the column entirely -
        # so it can't be required here.
        if ($lines[$index] -match '^\s*Port\s+Device ID\s+Port ID\s+System Name\s+Capabilities') {
            $headerIndex = $index
            break
        }
    }
    if ($headerIndex -lt 0) { return }

    $separatorIndex = -1
    for ($index = $headerIndex + 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^-+\s+-+') { $separatorIndex = $index; break }
    }
    if ($separatorIndex -lt 0) { return }
    $columns = @([regex]::Matches($lines[$separatorIndex], '-+'))
    # 5 dash-groups (no TTL column) on older firmware, 6 on current firmware.
    if ($columns.Count -lt 5) { return }
    $portStart = $columns[0].Index
    $deviceStart = $columns[1].Index
    $remoteStart = $columns[2].Index
    $systemStart = $columns[3].Index
    $capabilityStart = $columns[4].Index
    # No TTL column to bound Capabilities on the right - run it to the end of the line instead.
    $ttlStart = if ($columns.Count -ge 6) { $columns[5].Index } else { [int]::MaxValue }

    # --- MAP + MERGE ---
    $neighbors = @()
    foreach ($line in $lines[($separatorIndex + 1)..($lines.Count - 1)]) {
        if ($line -match '^\S+[#>]\s*$') { break }
        if ($line -match '^\s*-+' -or [string]::IsNullOrWhiteSpace($line)) { continue }

        $port = Get-CiscoSmallBusinessColumnValue -Line $line -Start $portStart -End $deviceStart
        # A handful of this era's firmware drops the interface-type prefix in this table's own Port
        # column - showing bare '11' where its interface tables and every neighbour that sees it both
        # say 'g11'. These switches only ever have Gigabit copper/combo ports, so a bare port number
        # here is unambiguously Gigabit.
        if ($port -match '^\d+$') { $port = "g$port" }
        if ($port -notmatch '^(?:gi|te|fi|fa|g|Po)\S*') { continue }
        $deviceId = Get-CiscoSmallBusinessColumnValue -Line $line -Start $deviceStart -End $remoteStart
        $remotePort = Get-CiscoSmallBusinessColumnValue -Line $line -Start $remoteStart -End $systemStart
        $systemName = Get-CiscoSmallBusinessColumnValue -Line $line -Start $systemStart -End $capabilityStart
        $capabilities = Get-CiscoSmallBusinessColumnValue -Line $line -Start $capabilityStart -End $ttlStart
        if ($GSkipCDPLLDPPhones -and $capabilities -match '(^|\s)T($|\s)') { continue }

        $neighbor = Create-LLDPNeighborObject
        $neighbor.ChassisID = $deviceId
        $neighbor.Hostname = if ($systemName) { $systemName } else { $deviceId }
        $neighbor.InterfaceLocalDevice = ConvertTo-CiscoSmallBusinessInterfaceName -Name $port
        $neighbor.InterfaceRemoteDevice = ConvertTo-CiscoSmallBusinessInterfaceName -Name $remotePort
        if (-not $neighbor.InterfaceRemoteDevice) { $neighbor.InterfaceRemoteDevice = 'Unknown Interface' }
        $neighbor.PortID = $neighbor.InterfaceRemoteDevice
        $neighbor.Capabilities = $capabilities
        $neighbor.ParentObject = $Device.hostname

        $interface = Resolve-CiscoSmallBusinessInterface -Device $Device -Name $neighbor.InterfaceLocalDevice
        if ($interface) {
            $interface.HasLLDPNeighbor = $true
            if ($interface.HasCPDNieghbor) { $neighbor.HasCDPNeighborEntry = $true }
        }
        $neighbors += ,$neighbor
    }
    $Device.LLDPNeighbors = @($neighbors)
}

# Parses a 'show ip route' capture into the device's routing table, handling both directly-connected and via-gateway entries (code, subnet, distance/metric, gateway, interface).
function Update-CiscoSmallBusinessRoutes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowIPRoute')) { return }

    # --- EXTRACT / MAP ---
    $routes = @()
    foreach ($line in (Get-MTAutoDrawCaptureText -Path $Path -AsLines)) {
        $connected = [regex]::Match($line, '^\s*>?(?<code>[A-Z]+)\s+(?<subnet>\d{1,3}(?:\.\d{1,3}){3}/\d+)\s+is directly connected,\s*(?<interface>.+?)\s*$')
        $via = [regex]::Match($line, '^\s*>?(?<code>[A-Z]+)\s+(?<subnet>\d{1,3}(?:\.\d{1,3}){3}/\d+)\s+\[(?<distance>\d+)/(?<metric>\d+)\]\s+via\s+(?<gateway>\d{1,3}(?:\.\d{1,3}){3}),.*?,\s*(?<interface>.+?)\s*$')
        if (-not $connected.Success -and -not $via.Success) { continue }
        $match = if ($connected.Success) { $connected } else { $via }

        $route = Create-RouteObject
        switch ($match.Groups['code'].Value) {
            'C' { $route.RouteProtocol = 'connected' }
            'S' { $route.RouteProtocol = 'static' }
            'R' { $route.RouteProtocol = 'RIP' }
            default { $route.RouteProtocol = $match.Groups['code'].Value }
        }
        $route.Subnet = $match.Groups['subnet'].Value
        $route.Interface = ConvertTo-CiscoSmallBusinessInterfaceName -Name $match.Groups['interface'].Value
        if ($via.Success) {
            $route.gateway = $match.Groups['gateway'].Value
            $route.DISTANCE = $match.Groups['distance'].Value
            $route.METRIC = $match.Groups['metric'].Value
        }
        if ($route.Subnet -eq '0.0.0.0/0') { $route.defaultgateway = $true }
        $routes += ,$route
    }

    # --- MERGE ---
    $Device.RoutingTable = @($routes)
}

# Parses a 'show arp' capture (vlan, interface, ip, mac, status) into the device's ARP entries, resolving each to its interface.
function Update-CiscoSmallBusinessArp {
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
        if ($line -notmatch '^\s*vlan\s+(?<vlan>\d+)\s+(?<interface>\S+)\s+(?<ip>\d{1,3}(?:\.\d{1,3}){3})\s+(?<mac>[0-9A-Fa-f:.-]{12,17})\s+(?<status>\S+)') { continue }
        $entry = Create-ShowIPArpObject
        $entry.PROTOCOL = 'Internet'
        $entry.ipaddress = $Matches['ip']
        $entry.MAC = $Matches['mac']
        $entry.TYPE = $Matches['status']
        $entry.INTERFACE = ConvertTo-CiscoSmallBusinessInterfaceName -Name $Matches['interface']
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

# Parses a 'show mac address-table' capture (vlan, mac, port, type) into the device's interface MAC lists.
function Update-CiscoSmallBusinessMacAddressTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowMacAddressTable')) { return }

    # --- EXTRACT / MAP / MERGE ---
    foreach ($line in (Get-MTAutoDrawCaptureText -Path $Path -AsLines)) {
        $rowMatch = [regex]::Match($line, '^\s*(?<vlan>\d+)\s+(?<mac>[0-9A-Fa-f:.-]{12,17})\s+(?<port>\S+)\s+(?<type>\S+)')
        if (-not $rowMatch.Success) { continue }
        $port = $rowMatch.Groups['port'].Value
        $type = $rowMatch.Groups['type'].Value
        # 'self' rows are the switch's own address, and a port that is not a physical or channel
        # interface is a CPU/internal entry.
        if ($type -eq 'self' -or $port -notmatch '^(?:(?:gi|te|fi|fa|g)\d\S*|Po\d+)$') { continue }
        $interface = Resolve-CiscoSmallBusinessInterface -Device $Device -Name $port
        if (-not $interface) { continue }

        $entry = Create-MacAddressObject
        $entry.Vlan = $rowMatch.Groups['vlan'].Value
        $entry.MacAddress = $rowMatch.Groups['mac'].Value
        $entry.Interface = $interface.Interface
        $entry.Type = $type
        $entry.VendorCompanyName = Get-CiscoSmallBusinessMacVendor -MacAddress $entry.MacAddress
        $interface.MacAddressArray += ,$entry
    }
}

# Parses a 'show spanning-tree' capture into the device's spanning-tree object (root bridge, priority, per-VLAN state).
function Update-CiscoSmallBusinessSpanningTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowSpanningTree')) { return }

    # --- EXTRACT ---
    $text = Get-MTAutoDrawCaptureText -Path $Path
    if (-not $Device.SpanningTree) { $Device.SpanningTree = Create-SpanningTreeObject }

    $mode = Get-CiscoSmallBusinessRegexValue -Text $text -Pattern '(?mi)^\s*Spanning tree enabled mode:?\s*(\S+)'
    if ($mode) { $Device.SpanningTree.SpanningTreeMode = $mode }

    $rootBlock = [regex]::Match($text, '(?ms)^\s*Root ID\s+Priority:?\s*(?<priority>\d+).*?^\s*Address:?\s*(?<address>\S+)(?<body>.*?)(?=^\s*Bridge ID|^\s*Number of topology changes)')
    $bridgeBlock = [regex]::Match($text, '(?ms)^\s*Bridge ID\s+Priority:?\s*(?<priority>\d+).*?^\s*Address:?\s*(?<address>\S+)(?<body>.*?)(?=^\s*Number of topology changes|^\s*Interfaces|\z)')
    if (-not $rootBlock.Success) { return }

    $rootAddress = $rootBlock.Groups['address'].Value
    $isExplicitRoot = $text -match '(?mi)^\s*This switch is the root'
    if ($bridgeBlock.Success) {
        $bridgeAddress = $bridgeBlock.Groups['address'].Value
        $bridgePriority = $bridgeBlock.Groups['priority'].Value
        $bridgeBody = $bridgeBlock.Groups['body'].Value
    }
    elseif ($isExplicitRoot) {
        # Some firmware omits the Bridge ID section when the local switch is root.
        $bridgeAddress = $rootAddress
        $bridgePriority = $rootBlock.Groups['priority'].Value
        $bridgeBody = $rootBlock.Groups['body'].Value
    }
    else { return }
    $isRoot = (($rootAddress -replace '[^0-9A-Fa-f]', '') -eq ($bridgeAddress -replace '[^0-9A-Fa-f]', '')) -or $isExplicitRoot
    $rootCost = Get-CiscoSmallBusinessRegexValue -Text $rootBlock.Groups['body'].Value -Pattern '(?mi)^\s*Cost:?\s*(\S+)'
    $rootPort = Get-CiscoSmallBusinessRegexValue -Text $rootBlock.Groups['body'].Value -Pattern '(?mi)^\s*Port:?\s*(\S+)'
    $rootHello = Get-CiscoSmallBusinessRegexValue -Text $rootBlock.Groups['body'].Value -Pattern '(?mi)^\s*Hello Time:?\s*(\S+)'
    $rootMaxAge = Get-CiscoSmallBusinessRegexValue -Text $rootBlock.Groups['body'].Value -Pattern '(?mi)Max Age:?\s*(\S+)'
    $bridgeHello = Get-CiscoSmallBusinessRegexValue -Text $bridgeBody -Pattern '(?mi)^\s*Hello Time:?\s*(\S+)'

    $rows = @()
    foreach ($line in $text -split '\r?\n') {
        $rowMatch = [regex]::Match($line, '^\s*(?<interface>(?:gi|te|fi|fa|g|Po)\S*)\s+(?<enabled>enabled|disabled)\s+(?<priority>\d+\.\d+)\s+(?<cost>\d+)\s+(?<status>\S+)\s+(?<role>\S+)\s+(?<portfast>\S+)\s*(?<type>.*)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $rowMatch.Success) { continue }
        $rows += ,[pscustomobject]@{
            Interface = ConvertTo-CiscoSmallBusinessInterfaceName -Name $rowMatch.Groups['interface'].Value
            Priority = $rowMatch.Groups['priority'].Value
            Cost = $rowMatch.Groups['cost'].Value
            Status = $rowMatch.Groups['status'].Value
            Role = $rowMatch.Groups['role'].Value
            Type = (($rowMatch.Groups['portfast'].Value + ' ' + $rowMatch.Groups['type'].Value).Trim())
        }
    }

    # --- MAP + MERGE ---
    # This CLI prints one global spanning-tree table, not one per VLAN, so the same instance data is
    # recorded against every configured VLAN. That is what makes the per-VLAN diagram pages work.
    $vlanIds = @($Device.vlans | ForEach-Object { [int]$_.number } | Sort-Object -Unique)
    if ($vlanIds.Count -eq 0) { $vlanIds = @(1) }
    $Device.SpanningTree.SpanningTreeArray = @()
    $Device.SpanningTree.RootBridgeForVlans = @()

    foreach ($vlanId in $vlanIds) {
        $instance = Create-SpanningTreeVlan
        $instance.VlanID = $vlanId
        $instance.protocol = $mode
        $instance.RootIDPriority = $rootBlock.Groups['priority'].Value
        $instance.Address = ConvertTo-NormalizedMacAddress $rootAddress
        $instance.RootBridge = $isRoot
        $instance.RootBridgeCost = $rootCost
        $instance.RootBridgePort = ConvertTo-CiscoSmallBusinessInterfaceName -Name $rootPort
        $instance.port = $instance.RootBridgePort
        $instance.RootBridgeHelloTime = $rootHello
        $instance.RootBridgeAgingTime = $rootMaxAge
        $instance.BridgeIDPriority = $bridgePriority
        $instance.BridgeIDPriorityaddress = ConvertTo-NormalizedMacAddress $bridgeAddress
        $instance.BridgeIDPriorityHelloTime = $bridgeHello

        foreach ($row in $rows) {
            $stInterface = Create-SpanningTreeInterface
            $stInterface.Interface = $row.Interface
            $stInterface.Role = $row.Role
            $stInterface.Status = $row.Status
            $stInterface.Cost = $row.Cost
            $stInterface.PrioNbr = $row.Priority
            $stInterface.Type = $row.Type
            $instance.SpanningTreeInterfaces += ,$stInterface

            $interface = Resolve-CiscoSmallBusinessInterface -Device $Device -Name $row.Interface
            if ($interface) {
                $interface.STState = $row.Status
                $interface.STRole = $row.Role
                switch ($row.Role) {
                    'Root' { $interface.STRootInterfaceForVlans += ,$vlanId }
                    'Desg' { $interface.STDesgnInterfaceForVlans += ,$vlanId }
                    { $_ -in @('Altn','ALT') } { $interface.STALTnInterfaceForVlans += ,$vlanId }
                }
            }
        }
        $Device.SpanningTree.SpanningTreeArray += ,$instance
        if ($isRoot) { $Device.SpanningTree.RootBridgeForVlans += ,$vlanId }
    }
}

# Parses a 'show spanning-tree detail' capture and layers each port's Designated bridge Address (the
# chassis MAC of whatever is physically attached to that exact port) onto the SpanningTreeInterfaces
# entries Update-CiscoSmallBusinessSpanningTree already built. This is meaningfully more precise than
# the instance-level global root Address: on a multi-tier topology the root can be several hops away,
# while the designated bridge on a specific port names whatever is one hop away on THAT port.
function Update-CiscoSmallBusinessSpanningTreeDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowSpanningTreeDetails')) { return }
    if (-not $Device.SpanningTree -or @($Device.SpanningTree.SpanningTreeArray).Count -eq 0) { return }

    # --- EXTRACT ---
    $text = Get-MTAutoDrawCaptureText -Path $Path
    $designatedBridgeByPort = @{}
    foreach ($block in [regex]::Matches($text, '(?ms)^Port\s+(?<port>\S+)\s+(?:enabled|disabled)\s*$(?<body>.*?)(?=^Port\s+\S+\s+(?:enabled|disabled)\s*$|\z)')) {
        $portName = ConvertTo-CiscoSmallBusinessInterfaceName -Name $block.Groups['port'].Value
        if (-not $portName) { continue }
        $designatedMac = Get-CiscoSmallBusinessRegexValue -Text $block.Groups['body'].Value -Pattern '(?mi)Designated bridge Priority\s*:\s*\d+\s+Address:\s*(\S+)'
        if (-not $designatedMac) { continue }
        $designatedBridgeByPort[$portName] = ConvertTo-NormalizedMacAddress $designatedMac
    }
    if ($designatedBridgeByPort.Count -eq 0) { return }

    # --- MAP + MERGE ---
    # Like the summary capture, this CLI prints one global table, not one per VLAN, so the same
    # per-port designated-bridge address applies to every VLAN instance's copy of that port.
    foreach ($instance in @($Device.SpanningTree.SpanningTreeArray | Where-Object { $_ })) {
        foreach ($stInterface in @($instance.SpanningTreeInterfaces | Where-Object { $_ })) {
            if ($designatedBridgeByPort.ContainsKey($stInterface.Interface)) {
                $stInterface.DesignatedBridgeAddress = $designatedBridgeByPort[$stInterface.Interface]
            }
        }
    }
}

# --- Orchestrator ---------------------------------------------------------------------------------

function Process-CiscoSmallBusinessHostFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$HostID,
        $ArrayOfObjects   # Kept for dispatcher signature compatibility; duplicate detection is sequential.
    )

    # 1. IDENTITY - the running configuration names the switch; 'show system' overrides it, because a
    # stack reports its real System Name there even when the config carries a stale hostname.
    $device = New-MTAutoDrawDevice -Platform 'CiscoSmallBusiness' -HostID $HostID
    $null = Get-CiscoSmallBusinessVersionObject -Device $device
    Update-CiscoSmallBusinessRunningConfig -Device $device -Path $HostID.ShowRun
    Update-CiscoSmallBusinessSystem        -Device $device -Path $HostID.ShowSystem
    if (-not $device.hostname -or $device.hostname -like '*NoHostNameFound*') {
        Write-MTAutoDrawDiagnostic -Device $device -Severity Warning -Message "Cisco Small Business host '$($HostID.HOSTID)' has no usable hostname; skipping."
        return $null
    }
    Write-MTAutoDrawLog -Level Info -Phase Parse -Device $device -Message "Processing Cisco Small Business host: $($device.hostname)"

    # 2. CAPTURES - one line per slot, in dependency order. Status runs before switchport and the MAC
    # table because those two only enrich ports that already exist; spanning tree runs after the VLAN
    # captures, because it records one instance per known VLAN; ARP runs after the SVIs exist.
    Update-CiscoSmallBusinessVersion               -Device $device -Path $HostID.ShowVersion
    Update-CiscoSmallBusinessInventory             -Device $device -Path $HostID.ShowInventory
    Update-CiscoSmallBusinessVlans                 -Device $device -Path $HostID.ShowVlan
    Update-CiscoSmallBusinessInterfaceStatus       -Device $device -Path $HostID.ShowInterfaceStatus
    Update-CiscoSmallBusinessInterfaceSwitchport   -Device $device -Path $HostID.ShowInterfaceSwitchport
    Update-CiscoSmallBusinessInterfaceDescriptions -Device $device -Path $HostID.ShowInterfaceDescription
    Update-CiscoSmallBusinessCdpNeighbors          -Device $device -Path $HostID.ShowCDPNeighborsDetails
    Update-CiscoSmallBusinessLldpNeighbors         -Device $device -Path $HostID.ShowLLDPNeighbors
    Update-CiscoSmallBusinessSpanningTree          -Device $device -Path $HostID.ShowSpanningTree
    Update-CiscoSmallBusinessSpanningTreeDetail    -Device $device -Path $HostID.ShowSpanningTreeDetails
    Update-CiscoSmallBusinessRoutes                -Device $device -Path $HostID.ShowIPRoute
    if ($GDrawAprEntries)          { Update-CiscoSmallBusinessArp             -Device $device -Path ($HostID.ShowArp ?? $HostID.ShowIPArp) }
    if ($GDrawPortsWithMacs -ne 0) { Update-CiscoSmallBusinessMacAddressTable -Device $device -Path $HostID.ShowMacAddressTable }

    # 3. RECONCILE - the model name from 'show system' and the PIDs from 'show inventory' overlap.
    $device.Version.Hardware = @($device.Version.Hardware | Sort-Object -Unique)
    $device.Version.Serial   = @($device.Version.Serial   | Sort-Object -Unique)
    if (-not $device.Version.Hostname) { $device.Version.Hostname = $device.hostname }
    return (Complete-MTAutoDrawDevice -Device $device)
}
