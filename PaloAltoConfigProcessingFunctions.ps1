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

# Palo Alto PAN-OS capture processing. Follows PARSER_STANDARD.md v1; the orchestrator is at the foot
# of the file, after the readers it calls.

# --- Capture readers ------------------------------------------------------------------------------
# Each one: GUARD, EXTRACT, MAP, MERGE. Each takes -Device and -Path, returns nothing, and is safe to
# call with a $null path - so the orchestrator needs no per-slot if-wrappers.

# Parses a Palo Alto 'show arp' output into the device's ARP entries, resolving each entry to its owning interface/subnet. Skips lines that do not match the expected format.
function Update-PaloAltoArp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowArp')) { return }

    $knownNetworks = @($Device.interfaces | ForEach-Object { Get-MTAutoDrawInterfaceIPv4Address -Interface $_ } | Where-Object Cidr | ForEach-Object {
        [pscustomobject]@{ Cidr = $_.Cidr; Prefix = [int](($_.Cidr -split '/')[1]) }
    } | Sort-Object Prefix -Descending)

    # --- EXTRACT / MAP / MERGE ---
    $Device.IPArpEntries = @(foreach ($line in (Get-MTAutoDrawCaptureText -Path $Path -AsLines)) {
        if ($line -notmatch '^\s*(?<interface>\S+)\s+(?<ip>\d{1,3}(?:\.\d{1,3}){3})\s+(?<mac>[0-9a-fA-F:.-]{12,17})\s+\S+\s+(?<status>\S+)\s+(?<ttl>\d+)\s*$') { continue }
        $arp = Create-ShowIPArpObject
        $arp.ipaddress = $Matches['ip']
        $arp.MAC = ConvertTo-NormalizedMacAddress $Matches['mac']
        $arp.INTERFACE = $Matches['interface']
        $arp.TYPE = $Matches['status']
        $arp.AGE = $Matches['ttl']
        $arp.VendorCompanyName = 'UNKNOWN Vendor'
        foreach ($network in $knownNetworks) {
            $candidate = Get-NormalizedIPv4Cidr -IPAddress $arp.ipaddress -PrefixLength ([string]$network.Prefix)
            if ($candidate -and $candidate.Cidr -eq $network.Cidr) { $arp.Cidr = $network.Cidr; break }
        }
        $arp
    })
}

# Reads 'show system info' for the device identity and its management addressing. This is the only
# capture Palo Alto carries a hostname in, so the orchestrator gates identity on it.
function Update-PaloAltoSystemInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowSystemInfo')) { return }

    # --- EXTRACT / MAP / MERGE ---
    # 'show system info' is a flat 'key: value' list. The management fields have no home in the host
    # schema, so they are attached as note properties; NeighborResolution reads ManagementIP.
    foreach ($line in (Get-MTAutoDrawCaptureText -Path $Path -AsLines)) {
        if ($line -notmatch '^\s*(?<key>[^:]+):\s*(?<value>.*)') { continue }
        $key = $Matches['key'].Trim()
        $value = $Matches['value'].Trim()
        switch ($key) {
            'hostname'          { $Device.hostname = $value }
            'model'             { $Device.Platform = $value } # The 'model' maps to the 'Platform' property.
            'ip-address'        { $Device | Add-Member -MemberType NoteProperty -Name 'ManagementIP' -Value $value -Force }
            'public-ip-address' { $Device | Add-Member -MemberType NoteProperty -Name 'ManagementPublicIP' -Value $value -Force }
            'netmask'           { $Device | Add-Member -MemberType NoteProperty -Name 'ManagementNetmask' -Value $value -Force }
            'default-gateway'   { $Device | Add-Member -MemberType NoteProperty -Name 'ManagementGateway' -Value $value -Force }
            'mac-address'       { $Device | Add-Member -MemberType NoteProperty -Name 'ManagementMacAddress' -Value $value -Force }
        }
    }
}

# Processes the 'show interface all' command output using two TextFSM templates to build a complete
# interface list. PAN-OS prints one table of hardware ports and a second of the logical interfaces
# configured on top of them, in the same capture - hence two templates over one file.
function Update-PaloAltoInterfaces {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowInterfaceAll')) { return }

    # --- EXTRACT: hardware ports first, so the logical rows have something to merge into ---
    $hardwareRows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'paloalto_panos_show_interface_hardware' -Path $Path
    $logicalRows  = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'paloalto_panos_show_interface_logical' -Path $Path
    if (@($hardwareRows).Count -eq 0 -and @($logicalRows).Count -eq 0) { return }

    # --- MAP + MERGE: hardware ---
    foreach ($row in $hardwareRows) {
        $interface = Resolve-MTAutoDrawInterface -Device $Device -Name $row.INTERFACE
        $interface.Speed      = $row.SPEED
        $interface.Duplex     = $row.DUPLEX
        $interface.IntStatus  = ($row.STATE -replace 'down\(autoneg\)', 'down')
        $interface.macaddress = $row.MAC_ADDRESS
        $interface.shutdown   = $interface.IntStatus -ne 'up'
    }

    # --- MAP + MERGE: logical ---
    # An interface here with no hardware row is purely logical (loopback.1, tunnel.1, a VLAN
    # interface); find-or-create covers both cases in one path.
    foreach ($row in $logicalRows) {
        $existing = Resolve-MTAutoDrawInterface -Device $Device -Name $row.INTERFACE -NoCreate
        $interface = if ($existing) { $existing } else {
            $new = Resolve-MTAutoDrawInterface -Device $Device -Name $row.INTERFACE
            $new.shutdown = $false   # a logical interface is up unless its hardware port says otherwise
            $new
        }
        $interface.Zone = $row.ZONE

        $addressInfo = Get-NormalizedIPv4Cidr -IPAddress ([string]$row.IP_ADDRESS)
        if (-not $addressInfo) { continue }
        $interface.IPAddress      = $addressInfo.IPAddress
        $interface.SubnetMask     = $addressInfo.PrefixLength
        $interface.SwitchPortType = 'Routed'
        $interface.Cidr           = $addressInfo.Cidr
        # PAN-OS tags every logical interface, so the tag is always the routed VLAN - including tag 0,
        # which is an untagged interface and is written 'vlan0' rather than 'no vlan'.
        $null = Add-MTAutoDrawNetwork -Device $Device -Cidr $addressInfo.Cidr -RoutedVlan "vlan$([string]$row.VLAN_ID)" -IPAddress $addressInfo.IPAddress
    }

    # PAN-OS prints additional addresses on continuation lines beneath the logical row.
    # TextFSM records the primary row; retain those continuation addresses explicitly.
    $secondaryByInterface = @{}
    $currentLogicalInterface = $null
    foreach ($line in (Get-MTAutoDrawCaptureText -Path $Path -AsLines)) {
        if ($line -match '^\s*(?<interface>\S+)\s+\d+\s+\d+\s+.*$') {
            $currentLogicalInterface = $Matches['interface']
            continue
        }
        if ($currentLogicalInterface -and $line -match '^\s+(?<address>\d{1,3}(?:\.\d{1,3}){3}/\d{1,2})\s*$') {
            if (-not $secondaryByInterface.ContainsKey($currentLogicalInterface)) {
                $secondaryByInterface[$currentLogicalInterface] = [System.Collections.Generic.List[string]]::new()
            }
            $secondaryByInterface[$currentLogicalInterface].Add($Matches['address'])
            continue
        }
        $currentLogicalInterface = $null
    }

    foreach ($interfaceName in $secondaryByInterface.Keys) {
        $interfaceObject = Resolve-MTAutoDrawInterface -Device $Device -Name $interfaceName -NoCreate
        if (-not $interfaceObject) {
            Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "Ignoring secondary address continuation for unknown interface '$interfaceName'."
            continue
        }
        $secondaryAddresses = [System.Collections.Generic.List[string]]::new()
        $secondaryMasks = [System.Collections.Generic.List[string]]::new()
        $secondaryCidrs = [System.Collections.Generic.List[string]]::new()
        foreach ($address in $secondaryByInterface[$interfaceName]) {
            $addressInfo = Get-NormalizedIPv4Cidr -IPAddress $address
            if (-not $addressInfo) {
                Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "Ignoring malformed secondary address '$address' on '$interfaceName'."
                continue
            }
            $secondaryAddresses.Add($addressInfo.IPAddress)
            $secondaryMasks.Add($addressInfo.PrefixLength)
            $secondaryCidrs.Add($addressInfo.Cidr)
            # A continuation line carries no tag, so the network is recorded as 'vlan' with no number.
            $null = Add-MTAutoDrawNetwork -Device $Device -Cidr $addressInfo.Cidr -RoutedVlan 'vlan' -IPAddress $addressInfo.IPAddress
        }
        $interfaceObject.SecondaryIPAddress = @($secondaryAddresses)
        $interfaceObject.SecondarySubnetMask = @($secondaryMasks)
        $interfaceObject.SecondaryCidr = @($secondaryCidrs)
    }
}





# Splits a PAN-OS policy capture into its top-level rule blocks.
#
#   "Allow VPN Traffic from Outside; index: 2" {
#           from Outside;
#           to [ Corp-VPN-Zone Corp-DC ];
#           action allow;
#   }
#
# Regex per rule rather than TextFSM: the format is brace-delimited and nested, which TextFSM's
# line-oriented state machine handles badly, and values appear either bare or as [ bracketed lists ].
function Split-PaloAltoPolicyBlocks {
    param([Parameter(Mandatory = $true)][string]$Text)

    $blocks = [System.Collections.Generic.List[object]]::new()
    # (?s) so the body can span lines; non-greedy up to the first line-initial closing brace, which is
    # how PAN-OS closes a rule - inner braces are always indented.
    foreach ($match in [regex]::Matches($Text, '(?ms)^"(?<name>[^"]*?)(?:;\s*index:\s*(?<index>\d+))?"\s*\{(?<body>.*?)^\}')) {
        $blocks.Add([pscustomobject]@{
            Name  = $match.Groups['name'].Value.Trim()
            Index = if ($match.Groups['index'].Success) { [int]$match.Groups['index'].Value } else { $null }
            Body  = $match.Groups['body'].Value
        })
    }
    return $blocks
}

# Reads one `key value;` field out of a rule body, returning it as a list. PAN-OS writes a single
# value bare ("from Outside;") and multiple values bracketed ("to [ A B ];"), and both forms mean the
# same thing to the reader, so both collapse to a list here.
function Get-PaloAltoPolicyFieldValues {
    param(
        [Parameter(Mandatory = $true)][string]$Body,
        [Parameter(Mandatory = $true)][string]$Key
    )

    $match = [regex]::Match($Body, "(?m)^\s*$([regex]::Escape($Key))\s+(?<value>.*?);\s*$")
    if (-not $match.Success) { return @() }
    $value = $match.Groups['value'].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return @() }
    if ($value -match '^\[\s*(?<items>.*?)\s*\]$') {
        return @($Matches['items'] -split '\s+' | Where-Object { $_ })
    }
    return @($value)
}

# Parses a Palo Alto 'show running security-policy' capture into the device's security-policy rule objects (source/destination, zones, action). Validates the capture first.
function Update-PaloAltoSecurityPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowRunningSecurityPolicy')) { return }

    # --- EXTRACT ---
    $text = Get-MTAutoDrawCaptureText -Path $Path
    $rules = [System.Collections.Generic.List[object]]::new()
    foreach ($block in (Split-PaloAltoPolicyBlocks -Text $text)) {
        $rule = Create-SecurityPolicyRuleObject
        $rule.Name        = $block.Name
        $rule.Index       = $block.Index
        $rule.FromZones   = @(Get-PaloAltoPolicyFieldValues -Body $block.Body -Key 'from')
        $rule.ToZones     = @(Get-PaloAltoPolicyFieldValues -Body $block.Body -Key 'to')
        $rule.Source      = @(Get-PaloAltoPolicyFieldValues -Body $block.Body -Key 'source')
        $rule.Destination = @(Get-PaloAltoPolicyFieldValues -Body $block.Body -Key 'destination')
        $rule.Application = @(Get-PaloAltoPolicyFieldValues -Body $block.Body -Key 'application/service')
        $rule.Action      = @(Get-PaloAltoPolicyFieldValues -Body $block.Body -Key 'action') | Select-Object -First 1
        $rule.RuleType    = @(Get-PaloAltoPolicyFieldValues -Body $block.Body -Key 'type') | Select-Object -First 1
        $rule.Disabled    = [bool](@(Get-PaloAltoPolicyFieldValues -Body $block.Body -Key 'disabled') -contains 'yes')
        $rules.Add($rule)
    }

    # --- MERGE ---
    $Device.SecurityPolicy = @($rules)
    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "  -> Parsed $($rules.Count) security rules."
}

# Parses a Palo Alto 'show running nat-policy' capture into the device's NAT policy rule objects. Validates the capture first.
function Update-PaloAltoNatPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowRunningNatPolicy')) { return }

    # --- EXTRACT ---
    $text = Get-MTAutoDrawCaptureText -Path $Path
    $rules = [System.Collections.Generic.List[object]]::new()
    foreach ($block in (Split-PaloAltoPolicyBlocks -Text $text)) {
        $rule = Create-NatPolicyRuleObject
        $rule.Name        = $block.Name
        $rule.Index       = $block.Index
        $rule.NatType     = @(Get-PaloAltoPolicyFieldValues -Body $block.Body -Key 'nat-type') | Select-Object -First 1
        $rule.FromZones   = @(Get-PaloAltoPolicyFieldValues -Body $block.Body -Key 'from')
        $rule.ToZones     = @(Get-PaloAltoPolicyFieldValues -Body $block.Body -Key 'to')
        $rule.Source      = @(Get-PaloAltoPolicyFieldValues -Body $block.Body -Key 'source')
        $rule.Destination = @(Get-PaloAltoPolicyFieldValues -Body $block.Body -Key 'destination')
        $rule.Service     = @(Get-PaloAltoPolicyFieldValues -Body $block.Body -Key 'service') | Select-Object -First 1

        # translate-to is a quoted free-text field, e.g.
        #   translate-to "src: ethernet1/1 203.0.113.200 (dynamic-ip-and-port) (pool idx: 1)"
        # Pull the egress interface, public address and mode out of it, but keep the raw string too so
        # an unrecognised translation form is never silently dropped.
        $translation = [regex]::Match($block.Body, '(?m)^\s*translate-to\s+"(?<value>[^"]*)"')
        if ($translation.Success) {
            $raw = $translation.Groups['value'].Value.Trim()
            $rule.RawTranslation = $raw
            if ($raw -match '^(?<dir>src|dst)\s*:') { $rule.TranslationType = $Matches['dir'] }
            if ($raw -match '(?<iface>(?:ethernet|ae|tunnel|loopback|vlan)[\d/.]*)') { $rule.TranslatedInterface = $Matches['iface'] }
            if ($raw -match '(?<ip>\d{1,3}(?:\.\d{1,3}){3})') { $rule.TranslatedAddress = $Matches['ip'] }
            if ($raw -match '\((?<mode>[a-z0-9-]+)\)') { $rule.TranslationMode = $Matches['mode'] }
        }
        $rules.Add($rule)
    }

    # --- MERGE ---
    $Device.NatPolicy = @($rules)
    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "  -> Parsed $($rules.Count) NAT rules."
}

# 'show interface all' truncates zone names to a 16-character column (Corp-Executive-W), while the
# policy capture carries them in full (Corp-Executive-WiFi-Zone). Where a truncated interface zone is
# an unambiguous prefix of exactly one policy zone, replace it with the full name so the diagrams and
# the zone matrix agree on what a zone is called. Ambiguous or unmatched values are left untouched -
# a wrong full name would be worse than a short one.
#
# Not an Update-* reader: it consumes no capture, only data three readers have already produced, so
# it is a reconcile step the orchestrator runs after them.
function Resolve-PaloAltoInterfaceZoneNames {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Device)

    $policyZones = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($rule in @($Device.SecurityPolicy) + @($Device.NatPolicy)) {
        foreach ($zone in (@($rule.FromZones) + @($rule.ToZones))) {
            if ($zone -and $zone -ne 'any') { [void]$policyZones.Add($zone) }
        }
    }
    if ($policyZones.Count -eq 0) { return }

    $resolved = 0
    foreach ($interface in @($Device.interfaces | Where-Object { $_.Zone })) {
        $current = [string]$interface.Zone
        if ($policyZones.Contains($current)) { continue }   # already the full name
        $candidates = @($policyZones | Where-Object { $_.StartsWith($current, [StringComparison]::OrdinalIgnoreCase) })
        if ($candidates.Count -eq 1) {
            $interface.Zone = $candidates[0]
            $resolved++
        }
    }
    if ($resolved -gt 0) {
        Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "  -> Restored $resolved truncated interface zone name(s) from policy data."
    }
}

# Returns $true when a token is a valid Palo Alto route flag string (route-table flag characters like A/C/S/R/O/B/M/E etc.), else $false.
function Test-PaloAltoRouteFlagToken {
    param([AllowNull()][string]$Token)
    return (-not [string]::IsNullOrWhiteSpace($Token) -and $Token -match '^[A?CHS~ROBEMio12]+$')
}

# Resolves a gateway IP to the interface on $TargetDevice that owns it (or a connected subnet), returning {Interface, Status} with Status 'NotApplicable' for non-IP/0.0.0.0 gateways.
function Resolve-PaloAltoGatewayInterface {
    param([string]$Gateway,$TargetDevice)

    $parsedGateway = $null
    if (-not [System.Net.IPAddress]::TryParse($Gateway, [ref]$parsedGateway) -or
        $parsedGateway.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $Gateway -eq '0.0.0.0') {
        return [pscustomobject]@{ Interface = $null; Status = 'NotApplicable' }
    }

    $candidates = foreach ($candidateInterface in @($TargetDevice.interfaces | Where-Object { -not $_.shutdown })) {
        foreach ($address in @(Get-MTAutoDrawInterfaceIPv4Address -Interface $candidateInterface | Where-Object Cidr)) {
            $prefix = [int](($address.Cidr -split '/')[1])
            $gatewayNetwork = Get-NormalizedIPv4Cidr -IPAddress $Gateway -PrefixLength ([string]$prefix)
            if ($gatewayNetwork -and $gatewayNetwork.Cidr -eq $address.Cidr) {
                [pscustomobject]@{ Interface = [string]$candidateInterface.Interface; Prefix = $prefix }
            }
        }
    }

    if (@($candidates).Count -eq 0) {
        return [pscustomobject]@{ Interface = $null; Status = 'Unmatched' }
    }
    $bestPrefix = @($candidates | Measure-Object Prefix -Maximum)[0].Maximum
    $bestInterfaces = @($candidates | Where-Object Prefix -eq $bestPrefix | Select-Object -ExpandProperty Interface -Unique)
    if ($bestInterfaces.Count -eq 1) {
        return [pscustomobject]@{ Interface = $bestInterfaces[0]; Status = 'Inferred' }
    }
    return [pscustomobject]@{ Interface = $null; Status = "Ambiguous: $($bestInterfaces -join ', ')" }
}

# Parse the PAN-OS routing table without relying on blank, fixed-width columns.
function Update-PaloAltoRoutes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowRouteAll')) { return }

    # --- EXTRACT ---
    $ShowRouteText = Get-MTAutoDrawCaptureText -Path $Path

    $AllRouteObjects = [System.Collections.Generic.List[object]]::new()
    $currentVRF = "default"
    $knownInterfaceNames = @{}
    foreach ($interfaceObject in @($Device.interfaces)) {
        if ($interfaceObject.Interface) {
            $knownInterfaceNames[[string]$interfaceObject.Interface.ToLowerInvariant()] = [string]$interfaceObject.Interface
        }
    }
    $inferredRoutes = @{}
    $unresolvedRoutes = @{}

    $lines = $ShowRouteText -split '\r?\n'

    foreach ($line in $lines) {
        # Capture the current Virtual Router (VRF) name
        if ($line -match 'VIRTUAL ROUTER: (.*) \(id \d+\)') {
            $currentVRF = $matches[1].Trim()
            continue 
        }

        if ($line -notmatch '^\s*\d{1,3}(?:\.\d{1,3}){3}/\d{1,2}\s+') { continue }

        $tokens = $line.Trim() -split '\s+'
        if ($tokens.Count -lt 3) { continue }

        $RouteObject = Create-RouteObject
        $RouteObject.VRF = $currentVRF
        $RouteObject.Subnet = $tokens[0]

        if ($tokens[1] -eq 'vr') {
            if ($tokens.Count -lt 4) { continue }
            $RouteObject.gateway = "$($tokens[1]) $($tokens[2])"
            $remainingTokens = @($tokens | Select-Object -Skip 3)
        } else {
            $RouteObject.gateway = $tokens[1]
            $remainingTokens = @($tokens | Select-Object -Skip 2)
        }

        if ($RouteObject.Subnet -eq "0.0.0.0/0") {
            $RouteObject.defaultgateway = $true
        }

        foreach ($token in $remainingTokens) {
            $key = $token.ToLowerInvariant()
            if ($knownInterfaceNames.ContainsKey($key)) {
                $RouteObject.interface = $knownInterfaceNames[$key]
                break
            }
            if ($token -match '^(?:ethernet\d+/\d+(?:\.\d+)?|ae\d+(?:\.\d+)?|loopback(?:\.\d+)?|tunnel(?:\.\d+)?|vlan(?:\.\d+)?)$') {
                $RouteObject.interface = $token
                break
            }
        }

        $flagTokens = @($remainingTokens | Where-Object { Test-PaloAltoRouteFlagToken $_ })
        $flagText = ($flagTokens -join '')
        $RouteObject.RouteSubType = $flagText
        if ($flagText -match 'B') { $RouteObject.RouteProtocol = 'BGP' }
        elseif ($flagText -match 'S') { $RouteObject.RouteProtocol = 'static' }
        elseif ($flagText -match 'O') { $RouteObject.RouteProtocol = 'OSPF' }
        elseif ($flagText -match 'R') { $RouteObject.RouteProtocol = 'RIP' }
        elseif ($flagText -match 'C') { $RouteObject.RouteProtocol = 'connect' }
        elseif ($flagText -match 'H') { $RouteObject.RouteProtocol = 'host' }
        else { $RouteObject.RouteProtocol = 'unknown' }

        $firstFlagIndex = -1
        for ($index = 0; $index -lt $remainingTokens.Count; $index++) {
            if (Test-PaloAltoRouteFlagToken $remainingTokens[$index]) { $firstFlagIndex = $index; break }
        }
        if ($firstFlagIndex -gt 0 -and $remainingTokens[0] -match '^\d+$') {
            $RouteObject.DISTANCE = [int]$remainingTokens[0]
        }

        if (-not $RouteObject.interface) {
            $resolution = Resolve-PaloAltoGatewayInterface -Gateway ([string]$RouteObject.gateway) -TargetDevice $Device
            if ($resolution.Status -eq 'Inferred') {
                $RouteObject.interface = $resolution.Interface
                $key = "$($RouteObject.gateway)|$($resolution.Interface)"
                $inferredRoutes[$key] = 1 + [int]$inferredRoutes[$key]
            }
            elseif ($resolution.Status -ne 'NotApplicable') {
                $unresolvedRoutes[[string]$RouteObject.gateway] = $resolution.Status
            }
        }

        $AllRouteObjects.Add($RouteObject)
    }

    foreach ($entry in $inferredRoutes.GetEnumerator() | Sort-Object Name) {
        $parts = $entry.Name -split '\|', 2
        Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Inferred Palo Alto egress interface '$($parts[1])' for gateway '$($parts[0])' on $($entry.Value) route(s)."
    }
    foreach ($entry in $unresolvedRoutes.GetEnumerator() | Sort-Object Name) {
        Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "Could not infer a Palo Alto egress interface for gateway '$($entry.Name)' ($($entry.Value))."
    }
    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Found $($AllRouteObjects.Count) Palo Alto routes."

    # --- MERGE ---
    $Device.RoutingTable = $AllRouteObjects
}


# --- Orchestrator ---------------------------------------------------------------------------------

function Process-PaloAltoHostFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$HostID,
        $ArrayOfObjects   # Kept for dispatcher signature compatibility; duplicate detection is sequential.
    )

    # 1. IDENTITY - 'show system info' is the only PAN-OS capture carrying a hostname.
    $device = New-MTAutoDrawDevice -Platform 'PaloAlto' -HostID $HostID
    Update-PaloAltoSystemInfo -Device $device -Path $HostID.ShowSystemInfo
    if (-not $device.hostname) {
        Write-MTAutoDrawDiagnostic -Device $device -Severity Error -Message "CRITICAL: Palo Alto '$($HostID.HOSTID)' has no usable 'show system info' capture; skipping host."
        return $null
    }
    Write-MTAutoDrawLog -Level Info -Phase Parse -Device $device -Message "Processing Palo Alto Host: $($device.hostname)"

    # 2. CAPTURES - one line per slot, in dependency order. Routes and ARP both resolve against the
    # interface subnets, so interfaces come first.
    Update-PaloAltoInterfaces     -Device $device -Path $HostID.ShowInterfaceAll
    Update-PaloAltoRoutes         -Device $device -Path $HostID.ShowRouteAll
    Update-PaloAltoArp            -Device $device -Path $HostID.ShowArp
    Update-PaloAltoSecurityPolicy -Device $device -Path $HostID.ShowRunningSecurityPolicy
    Update-PaloAltoNatPolicy      -Device $device -Path $HostID.ShowRunningNatPolicy

    # 3. RECONCILE - zone names come from the policy captures and are needed by the interfaces the
    # interface capture produced, so this can only run once both have been read.
    Resolve-PaloAltoInterfaceZoneNames -Device $device
    return (Complete-MTAutoDrawDevice -Device $device)
}


