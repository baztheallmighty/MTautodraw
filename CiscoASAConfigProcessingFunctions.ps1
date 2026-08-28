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

# Cisco ASA capture processing. Follows PARSER_STANDARD.md v1; the orchestrator is at the foot of the
# file, after the readers it calls.

# --- Capture readers ------------------------------------------------------------------------------
# Each one: GUARD, EXTRACT, MAP, MERGE. Each takes -Device and -Path, returns nothing, and is safe to
# call with a $null path - so the orchestrator needs no per-slot if-wrappers.

# Reads the running configuration for the device identity. The rest of the config is read by the two
# policy readers further down; this one only answers "which box is this".
function Update-CiscoASARunningConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowRun')) { return }

    # --- EXTRACT / MAP / MERGE ---
    $match = [regex]::Match((Get-MTAutoDrawCaptureText -Path $Path), '(?i)hostname .+')
    if ($match.Success) {
        $Device.hostname = ($match.Value -replace '(?i)hostname ', '').Trim()
        return
    }

    # A readable config with no hostname line is still a device; it is flagged rather than dropped so
    # the diagram shows the collection problem instead of silently losing the firewall.
    Write-MTAutoDrawDiagnostic -Device $Device -Severity Warning -Message "No hostname found in Cisco ASA configuration: $Path"
    $Device.hostname = 'NoHostNameFoundCheckForConfigProblems'
}

# Parses a Cisco ASA 'show version' (via TextFSM) into the device's version object, setting type 'ASA', OS, hostname, hardware, and serial.
function Update-CiscoASAVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowVersion')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'cisco_asa_show_version' -Path $Path
    $row = @($rows) | Select-Object -First 1
    if (-not $row -or [string]::IsNullOrWhiteSpace([string]$row.VERSION)) { return }

    # --- MAP + MERGE ---
    $version = Create-ShowVersionObject
    $version.Type = 'ASA'
    $version.OS = ([string]$row.VERSION).Trim()
    $version.Hostname = ([string]$row.HOSTNAME).Trim()
    $version.Uptime = ([string]$row.UPTIME).Trim()
    $version.Image = ([string]$row.IMAGE).Trim()
    $version.Serial = @($row.SERIAL | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)

    $hardware = ([string]$row.HARDWARE).Trim()
    $platform = ([string]$row.MODEL).Trim()
    if (-not $platform -and $hardware) { $platform = (($hardware -split ',')[0]).Trim() }
    if ($hardware) { $version.Hardware = @($hardware) }
    elseif ($platform) { $version.Hardware = @($platform) }
    if ($platform) {
        $Device.Platform = $platform
    }

    $Device.Version = $version
    if (-not $Device.hostname -and $version.Hostname) { $Device.hostname = $version.Hostname }
}

# Looks up the vendor for a MAC address by matching its OUI prefix (8 or 5 hex digits) against the global MAC->vendor map. Returns 'UNKNOWN Vendor' when not found.
function Get-CiscoASAMacVendor {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$MacAddress)

    if ([string]::IsNullOrWhiteSpace($MacAddress) -or -not $GMacAddressToVendorMapping) { return 'UNKNOWN Vendor' }
    foreach ($length in 8, 5) {
        if ($MacAddress.Length -lt $length) { continue }
        $prefix = $MacAddress.Substring(0, $length).ToUpperInvariant()
        if ($GMacAddressToVendorMapping.ContainsKey($prefix)) { return $GMacAddressToVendorMapping[$prefix] }
    }
    return 'UNKNOWN Vendor'
}

# Parses a Cisco ASA 'show arp' (via TextFSM) into the device's ARP entries, resolving each to its owning interface/subnet.
function Update-CiscoASAArp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowArp')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'cisco_asa_show_arp' -Path $Path
    if (@($rows).Count -eq 0) { return }

    $networkCandidates = foreach ($interface in @($Device.interfaces)) {
        foreach ($cidr in @($interface.Cidr, $interface.SecondaryCidr) | Where-Object { $_ -match '/\d{1,2}$' }) {
            [pscustomobject]@{ Cidr = [string]$cidr; Prefix = [int](($cidr -split '/')[1]) }
        }
    }
    $knownNetworks = @($networkCandidates | Sort-Object Prefix -Descending -Unique)

    # --- MAP + MERGE ---
    $Device.IPArpEntries = @(foreach ($row in @($rows)) {
        $arp = Create-ShowIPArpObject
        $arp.PROTOCOL = 'Internet'
        $arp.ipaddress = ([string]$row.IP_ADDRESS).Trim()
        $arp.AGE = ([string]$row.AGE).Trim()
        $arp.MAC = ConvertTo-NormalizedMacAddress ([string]$row.MAC_ADDRESS).Trim()
        $arp.TYPE = 'dynamic'
        $arp.INTERFACE = ([string]$row.INTERFACE).Trim()
        $arp.VendorCompanyName = Get-CiscoASAMacVendor -MacAddress $arp.MAC

        foreach ($network in $knownNetworks) {
            $candidate = Get-NormalizedIPv4Cidr -IPAddress $arp.ipaddress -PrefixLength ([string]$network.Prefix)
            if ($candidate -and $candidate.Cidr -eq $network.Cidr) { $arp.Cidr = $network.Cidr; break }
        }
        $arp
    })
}


# Parses 'show interface' (via TextFSM) into the device's interfaces and the networks they front.
function Update-CiscoASAInterfaces {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowInterface')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'cisco_asa_show_interface' -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    foreach ($row in $rows) {
        $interface = Resolve-MTAutoDrawInterface -Device $Device -Name $row.INTERFACE
        $interface.zone              = $row.INTERFACE_ZONE
        $interface.IntStatus         = $row.LINK_STATUS
        $interface.INTProtocolStatus = $row.PROTOCOL_STATUS
        $interface.speed             = $row.SPEED
        $interface.Description       = $row.DESCRIPTION

        # Only administratively down counts as shutdown; an operationally down interface is still
        # configured, and treating it as shutdown would drop it off the diagram. break on every arm:
        # switch -regex runs EVERY matching branch, so without it 'administratively down' was set
        # $true and then overwritten by the 'down' arm below.
        switch -regex ([string]$row.LINK_STATUS.Trim().ToLower()) {
            '^up$'                    { $interface.shutdown = $false; break }
            'administratively\s*down' { $interface.shutdown = $true;  break }
            'down'                    { $interface.shutdown = $false; break }
            default                   { $interface.shutdown = $false }
        }

        if (-not $row.IP_ADDRESS) { continue }
        $address = Get-NormalizedIPv4Cidr -IPAddress $row.IP_ADDRESS -SubnetMask $row.NETMASK
        if (-not $address) { continue }
        $interface.IPAddress      = $address.IPAddress
        $interface.SubnetMask     = [int]$address.PrefixLength
        $interface.Cidr           = $address.Cidr
        $interface.SwitchPortType = 'Routed'

        # The description is the closest thing to a network name the ASA offers. It reads poorly on a
        # diagram - it is a description, not a name - but it beats an unlabelled subnet.
        $routedVlan = if ($interface.Interface -like '*.*') { "vlan$(($interface.Interface -split '\.')[1])" } else { $null }
        $null = Add-MTAutoDrawNetwork -Device $Device -Cidr $address.Cidr -RoutedVlan $routedVlan `
            -NetworkName $interface.Description -IPAddress $address.IPAddress
    }
}


# Parses 'show route' (via TextFSM) into the device's routing table.
function Update-CiscoASARoutes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'CiscoASAShowRoute')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'cisco_asa_show_route' -Path $Path
    if (@($rows).Count -eq 0) { return }

    # Candidate egress interfaces for the next-hop match below. Down interfaces are excluded so a
    # stale address on a dead interface cannot claim a live route.
    $liveInterfaces = @($Device.interfaces | Where-Object { $_.cidr -and $_.IntStatus -ne 'down' })

    # --- MAP + MERGE ---
    # The ASA prints the one-letter code from the legend rather than a protocol name.
    $protocols = @{ C = 'connected'; L = 'local'; S = 'static'; R = 'RIP'; BGP = 'BGP'; D = 'EIGRP'; O = 'OSPF'; i = 'IS-IS' }
    $Device.RoutingTable = @(foreach ($row in $rows) {
        $route = Create-RouteObject
        $route.RouteProtocol = if ($protocols.ContainsKey([string]$row.PROTOCOL)) { $protocols[[string]$row.PROTOCOL] } else { $row.PROTOCOL }
        if ($row.TYPE) { $route.RouteSubType = $row.TYPE }
        $route.Subnet   = "$($row.NETWORK)/$(Covert-NetMaskToCIDR -SubnetMask $row.NETMASK)"
        $route.DISTANCE = $row.DISTANCE
        $route.METRIC   = $row.METRIC
        $route.gateway  = $row.NEXTHOPIP

        # The ASA names a zone, not an interface, so the egress interface is found by matching the
        # next hop into a connected subnet. Connected and local routes have no next hop to match.
        if ($route.gateway -and $route.gateway -ne 'Null0' -and $route.RouteProtocol -notin 'local', 'connected', 'direct') {
            foreach ($interface in $liveInterfaces) {
                if ((Find-Subnet -addr1 $interface.cidr -addr2 $route.gateway).condition) {
                    $route.Interface = $interface.Interface
                    break
                }
            }
        }
        $route
    })
}


#region Security policy
# The two readers below follow the parser-standard four-step body and the fixed -Device/-Path
# signature. They return no pipeline output and mutate the supplied device object.
#
# Both read the running config, because that is where ASA policy lives. 'show access-list' is not a
# capture this tool collects, and there is no zone object either: an ASA's segmentation is its nameif
# values, and its policy is ACLs bound inbound to those nameifs by 'access-group'.


# Consumes one ASA address specification from a token list, returning the text and the index to
# resume at. ASA address specs are variable-width, which is why this cannot be one regex over the
# line: 'any4' is one token, 'host 10.0.0.1' and '10.0.0.0 255.0.0.0' are two, and 'object-group
# PARTNERS' is two more that look nothing like an address. Source and destination are read by calling
# this twice, and whatever is left over is the service - which is what makes the rest of the ACE
# grammar tractable.
function Read-CiscoASAAddressSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Tokens,
        [Parameter(Mandatory = $true)][int]$Index
    )

    if ($Index -ge $Tokens.Count) {
        return [pscustomobject]@{ Value = ''; NextIndex = $Index }
    }

    $first = $Tokens[$Index]
    $twoTokenKeywords = @('host', 'object', 'object-group', 'interface')

    if ($first -in $twoTokenKeywords -and ($Index + 1) -lt $Tokens.Count) {
        return [pscustomobject]@{ Value = "$first $($Tokens[$Index + 1])"; NextIndex = $Index + 2 }
    }
    if ($first -match '^any[46]?$') {
        return [pscustomobject]@{ Value = $first; NextIndex = $Index + 1 }
    }
    # A dotted quad followed by another dotted quad is address + mask. A dotted quad followed by
    # anything else is a bare host (ASA accepts this), and a bare word is a 'name' alias.
    if ($first -match '^\d{1,3}(\.\d{1,3}){3}$' -and ($Index + 1) -lt $Tokens.Count -and $Tokens[$Index + 1] -match '^\d{1,3}(\.\d{1,3}){3}$') {
        return [pscustomobject]@{ Value = "$first $($Tokens[$Index + 1])"; NextIndex = $Index + 2 }
    }
    return [pscustomobject]@{ Value = $first; NextIndex = $Index + 1 }
}


# Reads 'object-group network|service' and 'object network|service' blocks out of the running config.
#
# Members are stored exactly as written; this is not a resolver. The one derived answer is
# ContainsAny, because 'permit ip any object-group PARTNERS' reads as scoped until you discover
# PARTNERS holds 0.0.0.0/0, and that is precisely the rule the risk page exists to surface.
function Update-CiscoASAObjectGroups {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowRun')) { return }

    # --- EXTRACT ---
    # Blocks are a header at column 0 followed by indented members, so the header regex ends the
    # previous block implicitly - no lookahead needed.
    $lines = @(Get-MTAutoDrawCaptureText -Path $Path -AsLines)
    $groups = [System.Collections.Generic.List[object]]::new()
    $current = $null

    foreach ($line in $lines) {
        if ($line -match '^(?<kind>object-group|object)\s+(?<type>network|service)\s+(?<name>\S+)') {
            $current = Create-PolicyObjectGroupObject
            $current.Name = $Matches['name']
            $current.Type = $Matches['type']
            $groups.Add($current)
            continue
        }
        # Any other line at column 0 closes the block we were in.
        if ($line -notmatch '^\s') { $current = $null; continue }
        if (-not $current) { continue }

        $member = $line.Trim()
        if (-not $member -or $member -match '^description\b') { continue }
        $current.Members += $member
    }

    # --- MAP: resolve ContainsAny ---
    foreach ($group in $groups) {
        foreach ($member in $group.Members) {
            if ($group.Type -eq 'network') {
                # 'any', an explicit default route, or a /0 in either notation.
                if ($member -match '\bany[46]?\b' -or
                    $member -match '\b0\.0\.0\.0\s+0\.0\.0\.0\b' -or
                    $member -match '\b0\.0\.0\.0/0\b') { $group.ContainsAny = $true }
            }
            else {
                # A service group that permits bare 'ip' or the whole port range is unrestricted in
                # the same way an 'any' network is.
                if ($member -match '^service-object\s+ip\b' -or
                    $member -match '^service\s+ip\b' -or
                    $member -match '\brange\s+1\s+65535\b') { $group.ContainsAny = $true }
            }
        }
    }

    # Nested groups: propagate ContainsAny up through 'group-object' references. Iterating to a
    # fixpoint rather than recursing is both simpler and inherently safe against a config that
    # references a group in a cycle - the loop stops when a pass changes nothing.
    $byName = @{}
    foreach ($group in $groups) { $byName[$group.Name] = $group }
    for ($pass = 0; $pass -lt 10; $pass++) {
        $changed = $false
        foreach ($group in $groups) {
            if ($group.ContainsAny) { continue }
            foreach ($member in $group.Members) {
                if ($member -match '^group-object\s+(?<name>\S+)' -and
                    $byName.ContainsKey($Matches['name']) -and $byName[$Matches['name']].ContainsAny) {
                    $group.ContainsAny = $true
                    $changed = $true
                    break
                }
            }
        }
        if (-not $changed) { break }
    }

    # --- MERGE ---
    $Device.PolicyObjectGroups = @($groups)
    Write-MTAutoDrawDiagnostic -Device $Device -Message "Parsed $($groups.Count) ASA object groups, $(@($groups | Where-Object { $_.ContainsAny }).Count) of which resolve to 'any'."
}


# Reads the interface security policy out of the running config: 'access-group <acl> in interface
# <nameif>' says which ACL governs traffic entering a segment, and the ACEs of that ACL are the rules.
#
# Only ACLs actually bound by an access-group become SecurityPolicy. An ASA typically defines far
# more ACLs than it binds - the remainder being VPN split-tunnel, nat0, vpn-filter and capture
# lists. Those are not interface policy, and counting them would inflate every rule total on the
# diagrams with rules that filter nothing.
#
# ToZones is deliberately left empty. An ASA ACL is bound inbound on one interface, so the capture
# says where traffic enters and nothing at all about where it leaves; deriving a destination zone
# would mean matching each ACE destination against the routing table, which is a guess this tool does
# not need. Per-zone rule counts are exact without it.
function Update-CiscoASAAccessLists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowRun')) { return }

    # --- EXTRACT ---
    $lines = @(Get-MTAutoDrawCaptureText -Path $Path -AsLines)

    # Pass 1: which nameif each ACL is bound to.
    $aclZone = @{}
    foreach ($line in $lines) {
        if ($line -match '^access-group\s+(?<acl>\S+)\s+(?<dir>in|out)\s+interface\s+(?<nameif>\S+)') {
            $aclZone[$Matches['acl']] = $Matches['nameif']
        }
    }
    if ($aclZone.Count -eq 0) {
        Write-MTAutoDrawDiagnostic -Device $Device -Message 'No ASA access-group bindings found; no interface security policy to parse.'
        return
    }

    # Pass 2: the ACEs of those ACLs, in file order.
    $rules = [System.Collections.Generic.List[object]]::new()
    $indexByAcl = @{}
    $unboundAcls = @{}

    foreach ($line in $lines) {
        if ($line -notmatch '^access-list\s+(?<acl>\S+)\s+extended\s+(?<action>permit|deny)\s+(?<rest>.+)$') {
            # Remark and standard-ACL lines are not rules; note unbound ACLs so the count is honest.
            if ($line -match '^access-list\s+(?<acl>\S+)\s' -and -not $aclZone.ContainsKey($Matches['acl'])) {
                $unboundAcls[$Matches['acl']] = $true
            }
            continue
        }
        $acl = $Matches['acl']
        $action = $Matches['action']
        $rest = $Matches['rest']
        if (-not $aclZone.ContainsKey($acl)) { $unboundAcls[$acl] = $true; continue }

        $tokens = @($rest -split '\s+' | Where-Object { $_ })
        if ($tokens.Count -lt 3) { continue }

        # protocol, then source, then destination - each consumed by its own width.
        $cursor = 0
        if ($tokens[$cursor] -in @('object', 'object-group') -and ($cursor + 1) -lt $tokens.Count) {
            $protocol = "$($tokens[$cursor]) $($tokens[$cursor + 1])"
            $cursor += 2
        }
        else {
            $protocol = $tokens[$cursor]
            $cursor++
        }
        $source = Read-CiscoASAAddressSpec -Tokens $tokens -Index $cursor
        $destination = Read-CiscoASAAddressSpec -Tokens $tokens -Index $source.NextIndex
        # Guard before slicing, not after. When NextIndex has run past the end, $tokens[N..(N-1)] is a
        # DESCENDING range in PowerShell, so it silently yields the last destination token back as if
        # it were a service instead of yielding nothing.
        $remainder = if ($destination.NextIndex -ge $tokens.Count) { @() }
                     else { @($tokens[$destination.NextIndex..($tokens.Count - 1)] | Where-Object { $_ }) }

        # Everything from the first trailing keyword onwards is metadata, not service.
        $disabled = ($remainder -contains 'inactive')
        $serviceTokens = [System.Collections.Generic.List[string]]::new()
        foreach ($token in $remainder) {
            if ($token -in @('log', 'inactive', 'time-range', 'disable')) { break }
            $serviceTokens.Add($token)
        }

        if (-not $indexByAcl.ContainsKey($acl)) { $indexByAcl[$acl] = 0 }
        $indexByAcl[$acl]++

        # --- MAP ---
        $rule = Create-SecurityPolicyRuleObject
        $rule.Name        = $acl
        $rule.Index       = $indexByAcl[$acl]
        $rule.FromZones   = @($aclZone[$acl])
        $rule.ToZones     = @()
        $rule.Source      = @($source.Value)
        $rule.Destination = @($destination.Value)
        $rule.Application = @((@($protocol) + $serviceTokens) -join ' ')
        # Normalised to the PAN-OS vocabulary so no downstream model branches per vendor.
        $rule.Action      = if ($action -eq 'permit') { 'allow' } else { 'deny' }
        $rule.RuleType    = 'acl'
        $rule.Disabled    = $disabled
        $rules.Add($rule)
    }

    # --- MERGE ---
    $Device.SecurityPolicy = @($rules)
    Write-MTAutoDrawDiagnostic -Device $Device -Message "Parsed $($rules.Count) ASA security rules across $($aclZone.Count) bound ACLs."
    if ($unboundAcls.Count -gt 0) {
        Write-MTAutoDrawDiagnostic -Device $Device -Message "Skipped $($unboundAcls.Count) ACLs bound to no interface (VPN, NAT or capture lists): $((@($unboundAcls.Keys) | Sort-Object) -join ', ')"
    }
}
#endregion


# --- Orchestrator ---------------------------------------------------------------------------------

function Process-CiscoASAHostFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$HostID,
        $ArrayOfObjects   # Kept for dispatcher signature compatibility; duplicate detection is sequential.
    )

    # 1. IDENTITY - the running configuration is the only capture carrying the hostname, and the
    # version reader only fills it in as a fallback, so it has to run first.
    $device = New-MTAutoDrawDevice -Platform 'CiscoASA' -HostID $HostID
    Update-CiscoASARunningConfig -Device $device -Path $HostID.ShowRun
    if (-not $device.hostname) {
        Write-MTAutoDrawDiagnostic -Device $device -Severity Warning -Message "Cisco ASA '$($HostID.HOSTID)' has no usable running configuration; skipping host."
        return $null
    }
    Update-CiscoASAVersion -Device $device -Path $HostID.ShowVersion
    Write-MTAutoDrawLog -Level Info -Phase Parse -Device $device -Message "Processing Cisco ASA Host: $($device.hostname)"

    # 2. CAPTURES - one line per slot, in dependency order. Routes and ARP both resolve against the
    # interface subnets, so interfaces come first. The two policy readers take the running config
    # again: ASA policy lives there, and 'show access-list' is not one of the collected captures.
    Update-CiscoASAInterfaces   -Device $device -Path $HostID.ShowInterface
    Update-CiscoASAArp          -Device $device -Path ($HostID.ShowArp ?? $HostID.ShowIPArp)
    Update-CiscoASARoutes       -Device $device -Path $HostID.CiscoASAShowRoute
    Update-CiscoASAObjectGroups -Device $device -Path $HostID.ShowRun
    Update-CiscoASAAccessLists  -Device $device -Path $HostID.ShowRun

    # 3. RECONCILE
    return (Complete-MTAutoDrawDevice -Device $device)
}
