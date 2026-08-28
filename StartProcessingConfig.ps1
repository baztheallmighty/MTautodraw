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

#This file contains the starting function for processing config files and other helper functions


#Take a list of files and separate them and create file collections for each host show run, show interface,etc for that host. That way we can process them together.
#Input:List of files
#Output: Array of host object containing the files sorted by hostid.
# Normalize one captured command into the canonical identity object. Shared by the filename-embedded
# host style (192.168.1.10.show.interfaces.status.txt) and the directory-name host style
# (192.168.1.11\show.interfaces.status.txt) so both collapse to the same CommandKey.
function Get-ConfigCaptureIdentityFromParts {
    param(
        [Parameter(Mandatory = $true)][string]$HostID,
        [Parameter(Mandatory = $true)][string]$Verb,
        [Parameter(Mandatory = $true)][string]$Arguments
    )

    $arguments = ($Arguments -replace '[._]+', ' ' -replace '\s+', ' ').Trim().ToLowerInvariant()
    # Collapse the 'sh' abbreviation onto 'show' so both filename styles produce one registry key.
    # A capture set often carries both forms side by side in the same directory.
    $verb = $Verb.ToLowerInvariant()
    if ($verb -eq 'sh') { $verb = 'show' }
    return [pscustomobject]@{
        HostID     = $HostID.Trim()
        CommandKey = (($verb + ' ' + $arguments).Trim())
    }
}

# Parses a capture filename (e.g. 'switch-01.show running-config.txt') to extract the host ID, verb (show/get/diagnose), and command arguments. Returns an identity object, or $null when the name does not follow the convention.
function Get-ConfigCaptureIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        # Optional device id taken from the containing directory's basename, used only when the file
        # name does not embed a host (see the bare-name fallback below).
        [string]$DirectoryBase = $null
    )

    # 'show' before 'sh' so the longer verb wins; 'diagnose' is FortiGate's third verb, used by the
    # LLDP neighbour capture.
    $match = [regex]::Match(
        $FileName,
        '^(?<host>.+?)\.(?<verb>show|sh|get|diagnose)[ ._](?<arguments>.+)\.txt$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($match.Success) {
        return (Get-ConfigCaptureIdentityFromParts -HostID $match.Groups['host'].Value -Verb $match.Groups['verb'].Value -Arguments $match.Groups['arguments'].Value)
    }

    # Bare-name fallback: some collectors (the SGE-LCLI capture set is the known one) name files by
    # command alone - show.version.txt - and put the device's IP in the containing directory name
    # instead of the filename. The anchored regex above can never match those bare names, so this path
    # only fires for them and leaves the prefixed style untouched. We require the directory basename to
    # be an IPv4 address so a stray non-device directory can't be misread as a host id.
    if ($DirectoryBase -and $DirectoryBase -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $bare = [regex]::Match(
            $FileName,
            '^(?<verb>show|sh|get|diagnose)[ ._](?<arguments>.+)\.txt$',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if ($bare.Success) {
            return (Get-ConfigCaptureIdentityFromParts -HostID $DirectoryBase -Verb $bare.Groups['verb'].Value -Arguments $bare.Groups['arguments'].Value)
        }
    }

    return $null
}

# Registry key for one CLI command: lower-cased, with hyphens folded to spaces and runs of whitespace
# collapsed. Applied to both sides of the lookup in Get-ConfigCaptureDefinition, so 'show
# running-config brief' and 'show running config brief' are one entry.
function ConvertTo-ConfigCaptureCommandKey {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Command)

    return ((($Command -replace '-', ' ') -replace '\s+', ' ').Trim().ToLowerInvariant())
}

# Registers one or more capture commands in the script-wide capture-definition cache.
function Add-CaptureDefinition {
    [CmdletBinding()]
    param([string[]]$Commands, [string[]]$Properties, [int]$Priority = 100)

    foreach ($command in $Commands) {
        $script:ConfigCaptureDefinitions[(ConvertTo-ConfigCaptureCommandKey -Command $command)] = [pscustomobject]@{
            Properties = @($Properties)
            Priority = $Priority
        }
    }
}

# Builds the lazy-loaded map of supported CLI capture commands to the host-object property they populate and a priority (lower = preferred when the same property has several captures).
#
# HYPHENS ARE NOT SIGNIFICANT here, on either side of the lookup. Get-ConfigCaptureIdentityFromParts
# collapses '.' and '_' to spaces but deliberately leaves '-' alone. A capture file named
# 'HOST.show.running-config.brief.txt' therefore arrives as the key 'show running-config brief',
# and a registry entry spelt 'show running config brief' would not match it. Because the lookup is
# an exact hashtable hit, such a file is discarded outright - taking the device's hostname with it,
# so the device falls back to being named by its management address. Normalising both the
# registration and the lookup makes the two spellings one key and cannot lose a distinction: every
# pair of registered commands that collapses together already maps to the same property at the same
# priority.
function Get-ConfigCaptureDefinition {
    param([Parameter(Mandatory = $true)][string]$CommandKey)

    if (-not $script:ConfigCaptureDefinitions) {
        $script:ConfigCaptureDefinitions = @{}
        Add-CaptureDefinition @('show running-config','show running config') @('ShowRun') 10
        Add-CaptureDefinition @('show run','show configuration','show config','show config running') @('ShowRun') 20
        Add-CaptureDefinition @('show running config brief') @('ShowRun') 30
        Add-CaptureDefinition @('show full-configuration','show full configuration') @('ShowFullConfig') 10
        Add-CaptureDefinition @('show version') @('ShowVersion')
        Add-CaptureDefinition @('show system') @('ShowSystem')
        Add-CaptureDefinition @('show system info') @('ShowSystemInfo')
        # PAN-OS policy captures. Both the underscore and space filename conventions in the corpora
        # normalize to these keys, because Get-ConfigCaptureIdentity already collapses [._] to spaces.
        Add-CaptureDefinition @('show running security-policy') @('ShowRunningSecurityPolicy')
        Add-CaptureDefinition @('show running nat-policy') @('ShowRunningNatPolicy')
        Add-CaptureDefinition @('show system id') @('ShowSystemId')
        Add-CaptureDefinition @('show hostname') @('ShowHostname')
        Add-CaptureDefinition @('show reload cause','show reloadcause') @('ShowReloadCause')
        Add-CaptureDefinition @('show inventory','show inventory all') @('ShowInventory')
        Add-CaptureDefinition @('show asset all') @('ShowAssetAll')
        Add-CaptureDefinition @('show vlan') @('ShowVlan')
        Add-CaptureDefinition @('show vlan brief') @('ShowVlan') 110
        Add-CaptureDefinition @('show vlans detail') @('ShowVlansDetail')
        Add-CaptureDefinition @('show interface','show interfaces') @('ShowInterface')
        Add-CaptureDefinition @('show interface all','show interfaces all') @('ShowInterfaceAll')
        Add-CaptureDefinition @('show interface brief','show interfaces brief') @('ShowInterfaceBrief')
        Add-CaptureDefinition @('show ip interface') @('ShowIPInterface')
        Add-CaptureDefinition @('show ip interface brief') @('ShowIPInterfaceBrief')
        Add-CaptureDefinition @('show interface status','show interfaces status') @('ShowInterfaceStatus')
        Add-CaptureDefinition @('show interface trunk','show interfaces trunk') @('ShowInterfaceTrunk')
        Add-CaptureDefinition @('show interfaces switchport','show interface switchport') @('ShowInterfaceSwitchport')
        Add-CaptureDefinition @('show interfaces description','show interface description') @('ShowInterfaceDescription')
        Add-CaptureDefinition @('show interfaces terse') @('ShowInterfaceTerse')
        Add-CaptureDefinition @('show interfaces detail') @('ShowInterfaceDetail')
        Add-CaptureDefinition @('show cdp neighbors detail') @('ShowCDPNeighborsDetails')
        Add-CaptureDefinition @('show lldp neighbors detail','show lldp neighbor detail','show lldp neighbors-info detail','show lldp neighbors-info all') @('ShowLLDPNeighborsDetails')
        Add-CaptureDefinition @('show lldp neighbors','show lldp neighbor') @('ShowLLDPNeighbors')
        Add-CaptureDefinition @('show mac address-table','show mac address table','show mac-address-table') @('ShowMacAddressTable')
        Add-CaptureDefinition @('show spanning-tree','show spanning tree') @('ShowSpanningTree')
        Add-CaptureDefinition @('show spanning-tree detail','show spanning tree detail') @('ShowSpanningTreeDetails')
        # Ranked rather than left equal, so a device holding more than one of these spellings resolves
        # by intent instead of by filename sort order. Junos collectors capture the 'detail' form; the
        # plain form is what a Cisco-style collector writes.
        Add-CaptureDefinition @('show spanning-tree interface detail') @('ShowSpanningTreeInterface') 10
        Add-CaptureDefinition @('show spanning-tree interface') @('ShowSpanningTreeInterface') 20
        Add-CaptureDefinition @('show spanning-tree bridge','show spanning tree bridge') @('JunosShowSpanningTreeBridgeFromXML')
        Add-CaptureDefinition @('show ip route') @('ShowIPRoute')
        Add-CaptureDefinition @('show ip route vrf star') @('ShowIPRouteVRFstar')
        Add-CaptureDefinition @('show ip route vrf all') @('ShowIPRouteVRFAll')
        Add-CaptureDefinition @('show route all') @('ShowRouteAll')
        Add-CaptureDefinition @('show routing route','show routing route all') @('ShowRouteAll')
        Add-CaptureDefinition @('show route') @('CiscoASAShowRoute','ShowRouteAll')
        Add-CaptureDefinition @('show ip arp') @('ShowIPArp')
        Add-CaptureDefinition @('show arp','show arp all') @('ShowArp','ShowIPArp')
        # Same again, and here the collision is certain rather than hypothetical: a Junos switch
        # carries BOTH 'detail' and 'extensive'. On Junos 22.4 the two emit the SAME
        # schema - both are <l2ng-l2ald-rtb-macdb> with junos:style="extensive" - so the ranking only
        # has to be stable, not clever; 'detail' is first because it is the narrower request. Note
        # Update-JunosMacAddressTable currently reads the older ELS schema
        # (ethernet-switching-table-information/mac-table-entry) and so parses neither of them; see
        # the plain form below for the shape it does understand.
        Add-CaptureDefinition @('show ethernet-switching table detail') @('ShowEthernetSwitchingTable') 10
        Add-CaptureDefinition @('show ethernet-switching table extensive') @('ShowEthernetSwitchingTable') 20
        Add-CaptureDefinition @('show ethernet-switching table') @('ShowEthernetSwitchingTable') 30
        Add-CaptureDefinition @('show ip bgp summary') @('ShowIPBGPSummary')
        Add-CaptureDefinition @('show ip bgp neighbors') @('ShowIPBGPNeighbors')
        Add-CaptureDefinition @('show ip bgp neighbors advertised','show ip bgp neighbors advertised-routes') @('ShowIPBGPNeighborsAdvertised')
        Add-CaptureDefinition @('show ip bgp vpnv4 all neighbors') @('ShowIPBGPVPNv4Neighbors')
        Add-CaptureDefinition @('get system status') @('SystemStatus')
        Add-CaptureDefinition @('get system ha status') @('HaStatus')
        Add-CaptureDefinition @('get router info bgp summary') @('ShowBgpSummary')
        Add-CaptureDefinition @('get system arp') @('ShowArp')
        Add-CaptureDefinition @('get router info routing-table all','get router info routing table all') @('ShowRoutingTable')
        Add-CaptureDefinition @('get system lldp neighbor details','diagnose lldprx neighbor details') @('LldpNeighborDetails')
        Add-CaptureDefinition @('get system interface') @('SystemInterface')
        Add-CaptureDefinition @('get router info ospf neighbor') @('ShowOspfNeighbor')
        # FortiGate security policy. Its own capture rather than a slice of ShowFullConfig: the
        # full-configuration captures in the corpora do not carry the firewall section.
        Add-CaptureDefinition @('show firewall policy') @('ShowFirewallPolicy')
    }

    return $script:ConfigCaptureDefinitions[(ConvertTo-ConfigCaptureCommandKey -Command $CommandKey)]
}

# Detects the vendor/device type of a capture group by inspecting its 'show version' text and the set of captures present (Fortigate, PaloAlto, CheckPoint, CiscoASA, CiscoIOSXR, Cisco, Junos, AristaEOS, ArubaOS-CX, CiscoSmallBusinessLegacy).
function Get-ConfigDeviceType {
    param([Parameter(Mandatory = $true)]$CaptureGroup)

    if ($CaptureGroup.SystemStatus -or $CaptureGroup.ShowFullConfig) { return 'Fortigate' }
    if ($CaptureGroup.ShowSystemInfo) { return 'PaloAlto' }

    if ($CaptureGroup.ShowVersion -and (Test-FileHasValidData -FilePath $CaptureGroup.ShowVersion)) {
        $versionText = Get-Content -LiteralPath $CaptureGroup.ShowVersion -Raw
        if ($versionText -match '(?i)Check Point Gaia') { return 'CheckPoint' }
        if ($versionText -match '(?i)Cisco Adaptive Security Appliance') { return 'CiscoASA' }
        if ($versionText -match '(?i)Cisco IOS XR Software|IOS XR RELEASE SOFTWARE') { return 'CiscoIOSXR' }
        if ($versionText -match '(?i)Cisco IOS Software|Cisco IOS XE Software|Cisco Nexus Operating System|NX-OS') { return 'Cisco' }
        if ($versionText -match '(?i)Junos|JUNOS Base OS boot') { return 'Junos' }
        if ($versionText -match '(?i)Arista Networks|Arista vEOS|Software image version:\s*\S*EOS') { return 'AristaEOS' }
        if ($versionText -match '(?i)ArubaOS-CX') { return 'ArubaOS-CX' }
        if ($versionText -match '(?im)^\s*SW version\s+\S' -and
            $versionText -match '(?im)^\s*Boot version\s+\S' -and
            $versionText -notmatch '(?i)Active-image:') {
            return 'CiscoSmallBusinessLegacy'
        }
    }

    if ($CaptureGroup.ShowSystem -and (Test-FileHasValidData -FilePath $CaptureGroup.ShowSystem)) {
        $systemText = Get-Content -LiteralPath $CaptureGroup.ShowSystem -Raw
        if ($systemText -match '(?i)System Object ID:[ \t]*1\.3\.6\.1\.4\.1\.9\.6\.1\.' -and
            $systemText -match '(?i)System Description:[ \t]*(?:SG|CBS)\d') {
            return 'CiscoSmallBusiness'
        }
    }
    if ($CaptureGroup.ShowInventory -and (Test-FileHasValidData -FilePath $CaptureGroup.ShowInventory)) {
        $inventoryText = Get-Content -LiteralPath $CaptureGroup.ShowInventory -Raw
        if ($inventoryText -match '(?i)PID:[ \t]*(?:SG|CBS)\d') { return 'CiscoSmallBusiness' }
    }
    return $null
}

# Groups capture files by (directory, host ID) using the filename convention, then builds one capture-group object per device containing its files, identities, and directory. Returns the capture-group array.
function Create-FileHostObjects {
    param([Parameter(Mandatory = $true)]$Files)

    $groups = @{}
    foreach ($file in @($Files | Sort-Object FullName)) {
        $directory = [System.IO.Path]::GetFullPath($file.DirectoryName).TrimEnd('\')
        # The directory basename is the device id for the bare-name collector style (SGE-LCLI) where
        # the filename omits the host. Pass it through so the identity can adopt it on fallback.
        $directoryBase = [System.IO.Path]::GetFileName($directory)
        $identity = Get-ConfigCaptureIdentity -FileName $file.Name -DirectoryBase $directoryBase
        if (-not $identity) { continue }
        $groupKey = ($directory.ToLowerInvariant() + '|' + $identity.HostID.ToLowerInvariant())
        if (-not $groups.ContainsKey($groupKey)) { $groups[$groupKey] = @() }
        $groups[$groupKey] += [pscustomobject]@{ File = $file; Identity = $identity; Directory = $directory }
    }

    if ($groups.Count -eq 0) {
        Write-MTAutoDrawLog -Level Warn -Phase Ingest -Message 'No supported show/get capture files found. Check the filename convention.'
        return @()
    }

    $captureGroups = foreach ($groupKey in @($groups.Keys | Sort-Object)) {
        $entries = @($groups[$groupKey] | Sort-Object @{ Expression = { $_.Identity.CommandKey } }, @{ Expression = { $_.File.FullName } })
        $captureGroup = Create-FileObject
        $captureGroup.HOSTID = $entries[0].Identity.HostID
        $captureGroup.SourceDirectory = $entries[0].Directory
        $captureGroup.CaptureGroupKey = $groupKey
        $captureGroup.CaptureFiles = @($entries.File.FullName)
        $selected = @{}

        foreach ($entry in $entries) {
            $definition = Get-ConfigCaptureDefinition -CommandKey $entry.Identity.CommandKey
            if (-not $definition) {
                $captureGroup.MappingDiagnostics += [pscustomobject]@{
                    Severity = 'Info'; Category = 'UnmappedCommand'; CommandKey = $entry.Identity.CommandKey
                    File = $entry.File.FullName; ExistingFile = $null
                    Message = "Recognized capture filename, but command is not consumed by the parser."
                }
                continue
            }

            foreach ($property in $definition.Properties) {
                $candidate = [pscustomobject]@{ Priority = $definition.Priority; File = $entry.File.FullName; CommandKey = $entry.Identity.CommandKey }
                if (-not $selected.ContainsKey($property)) {
                    $selected[$property] = $candidate
                    $captureGroup.$property = $candidate.File
                    continue
                }

                $existing = $selected[$property]
                $replace = $candidate.Priority -lt $existing.Priority
                if ($replace) {
                    $selected[$property] = $candidate
                    $captureGroup.$property = $candidate.File
                }
                # Two captures wanting one slot is only WORTH a warning when the registry has no
                # opinion about which should win. Where the priorities differ, the registry has
                # already decided and the outcome is the intended one - a Junos switch carries both
                # 'show ethernet-switching table detail' and '... extensive' as a matter of course,
                # and every such switch turning the run's verdict to Warn says nothing a reader can
                # act on. An EQUAL-priority collision is the real ambiguity: nothing but filename
                # sort order picks the winner, so that one stays a Warning.
                $ambiguous = $candidate.Priority -eq $existing.Priority
                $captureGroup.MappingDiagnostics += [pscustomobject]@{
                    Severity = $(if ($ambiguous) { 'Warning' } else { 'Info' })
                    Category = 'CaptureCollision'; CommandKey = $entry.Identity.CommandKey
                    File = $candidate.File; ExistingFile = $existing.File
                    Message = if ($ambiguous) { "Two captures of equal priority map to $property; the first by filename order was kept." }
                        elseif ($replace) { "Higher-priority capture replaced the previous mapping for $property." }
                        else { "Additional capture did not replace the deterministic mapping for $property." }
                }
            }
        }

        $captureGroup.DeviceType = Get-ConfigDeviceType -CaptureGroup $captureGroup
        $captureGroup
    }

    # Say out loud which commands were recognised as captures but consumed by nobody. These were
    # already recorded per file as Info diagnostics and then never printed, which is how a single
    # unmatched hyphen can cost a whole run its hostnames without a line in the log. One line per
    # DISTINCT command with a file count, not one per file: a real capture set is full of
    # 'show logging' and 'show snmp' that genuinely have no parser, and per-file would bury the
    # handful that matter.
    $unmapped = @($captureGroups | ForEach-Object MappingDiagnostics |
        Where-Object { $_.Category -eq 'UnmappedCommand' })
    foreach ($command in @($unmapped | Group-Object -Property CommandKey | Sort-Object Name)) {
        Write-MTAutoDrawLog -Level Info -Phase Ingest -Message "Unmapped capture command '$($command.Name)' ($($command.Count) file(s)); no parser consumes it."
    }

    return @($captureGroups)
}

#helper function
function Set-MacAddressVendor {
    param(
        [Parameter(Mandatory=$true)]
        [PSObject]$HostObject,

        [Parameter(Mandatory=$true)]
        [Hashtable]$VendorMapping
    )

    # Check if the hostname is a MAC address-like string
    if ($HostObject.hostname -notmatch '^[0-9a-fA-F]{4}\.[0-9a-fA-F]{4}\.[0-9a-fA-F]{4}$' -and
        $HostObject.hostname -notmatch '^[0-9a-fA-F]{2}(?:[:-][0-9a-fA-F]{2}){5}$' -and
        $HostObject.hostname -notmatch '^[0-9a-fA-F]{12}$') {
        # If the hostname isn't a likely MAC address format, skip
        return
    }

    # Format the MAC address to a standard format (e.g., 00:00:00:00:00:00)
    $macAddress = ($HostObject.hostname -replace '\.|\-|\:','').ToUpper()
    $macFormatted = ($macAddress.Insert(2,':').Insert(5,':').Insert(8,':').Insert(11,':').Insert(14,':'))

    # Determine the vendor
    $vendorName = "UNKNOWN Vendor"
    if ($VendorMapping.ContainsKey($macFormatted.Substring(0,8))) {
        $vendorName = $VendorMapping[$macFormatted.Substring(0,8)]
    } elseif ($VendorMapping.ContainsKey($macFormatted.Substring(0,5))) {
        # Check for 4-byte OUI
        $vendorName = $VendorMapping[$macFormatted.Substring(0,5)]
    }

    # Update the HostTypeIfCDPorLLDP property with the vendor name
    # We use '=' to set the string value directly.
    $HostObject.HostTypeIfCDPorLLDP = $vendorName
}


# Links every route to the interface that owns its next hop. A next hop that no captured device
# owns becomes a gateway host object built from the ARP entry that knows it, or a bare placeholder,
# and those objects are what this returns; the routes themselves are linked in place.
function Resolve-MTAutoDrawGatewayLinks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Devices,
        [AllowEmptyCollection()][array]$CdpHosts,
        [AllowEmptyCollection()][array]$LldpHosts
    )

    $ArrayOfObjects = $Devices
    $ArrayOfCDPDeviceIDs = $CdpHosts
    $ArrayOfLLDPDeviceIDs = $LldpHosts
    [Array]$ArrayofGatewayHosts = @()

    # Link gateway-bearing interfaces before building route diagrams.
    Write-MTAutoDrawLog -Level Info -Phase Resolve -Message "Linking Layer 3 interfaces to gateways and creating ARP hosts."

    # Pre-build lookup tables for faster searching
    $InterfaceLookup = @{}
    foreach ($device in $ArrayOfObjects) {
        foreach ($intf in $device.interfaces) {
            if (-not $intf.shutdown) {
                $interfaceAddresses = @(Get-MTAutoDrawInterfaceIPv4Address -Interface $intf | Select-Object -ExpandProperty IPAddress)
                foreach ($key in @($interfaceAddresses) + @($intf.ClusterIP) + @($intf.Standbyip)) {
                    if ($key) { $InterfaceLookup[$key] = $intf }
                }
            }
        }
    }

    $GatewayHostsLookup = @{}
    foreach ($gwHost in $ArrayofGatewayHosts) {
        # Filter for non-null IPs before adding to the lookup
        foreach ($ip in ($gwHost.arrayofipaddresses | Where-Object { $_ })) {
            $GatewayHostsLookup[$ip] = $true
        }
    }

    $CDPLookup = @{}
    foreach ($CDPDevice in $ArrayOfCDPDeviceIDs) {
        foreach ($ip in ($CDPDevice.ArrayOfIPAddresses | Where-Object { $_ })) {
            $CDPLookup[$ip] = $CDPDevice
        }
    }

    $LLDPLookup = @{}
    foreach ($LLDPDevice in $ArrayOfLLDPDeviceIDs) {
        foreach ($ip in ($LLDPDevice.ArrayOfIPAddresses | Where-Object { $_ })) {
            $LLDPLookup[$ip] = $LLDPDevice
        }
    }

    # Cache last gateway so we don't reprocess the same one
    $LastGatewayCache = @{}

    foreach ($device in $ArrayOfObjects) {
        foreach ($interface in $device.interfaces | Where-Object { $_.RoutesForInterface }) {
            foreach ($route in ($interface.RoutesForInterface | Where-Object { $_.gateway } | Sort-Object gateway)) {

                if ($LastGatewayCache.ContainsKey($route.gateway)) {
                    $route.GatewayLink = $LastGatewayCache[$route.gateway]
                    continue
                }

                # Step 1: Direct interface match in a device we have config for.
                if ($InterfaceLookup.ContainsKey($route.gateway)) {
                    $route.GatewayLink = [ref]$InterfaceLookup[$route.gateway]
                    $LastGatewayCache[$route.gateway] = $route.GatewayLink
                    continue
                }

                # Step 2: Gateway already created as a gateway host object?
                if ($GatewayHostsLookup.ContainsKey($route.gateway)) {
                    continue
                }

                # Step 3: No direct match, so create a new gateway host from ARP or as a placeholder.
                $HostGatewayObject = $null
                $interfaceObject = $null
                $NewObjectToCreate = $device.IPArpEntries | Where-Object { $_.ipaddress -eq $route.gateway }

                if ($NewObjectToCreate) {
                    $HostGatewayObject = Create-HostObject
                    $HostGatewayObject.Origin = "ARP"
                    [array]$HostGatewayObject.arrayofipaddresses += [array]$NewObjectToCreate.ipaddress
                    $HostGatewayObject.hostname = "$($NewObjectToCreate.VendorCompanyName)`r`n$($NewObjectToCreate.MAC)"
                }
                else {
                    # No ARP entry, create a basic placeholder
                    $HostGatewayObject = Create-HostObject
                    $HostGatewayObject.Origin = "RoutingTable"
                    $HostGatewayObject.hostname = "Unknown`r`n$($route.gateway)"
                    [array]$HostGatewayObject.arrayofipaddresses += [array]$route.gateway
                }

                # Create the interface for the new HostGatewayObject
                $interfaceObject = Create-InterfaceObject
                $interfaceObject.shutdown = $false
                $interfaceObject.interface = "Unknown Interface"
                $interfaceObject.IPAddress = $route.gateway
                $interfaceObject.cidr = $interface.cidr # Inherit CIDR from the source interface
                $HostGatewayObject.interfaces += $interfaceObject


                # Step 4: Enrich the new gateway object with CDP/LLDP info if available.
                # This section does NOT set the GatewayLink, it only adds data to the HostGatewayObject.
                if ($CDPLookup.ContainsKey($route.gateway)) {
                    $CDPDevice = $CDPLookup[$route.gateway]
                    $HostGatewayObject.Description = $CDPDevice.Description
                    [array]$HostGatewayObject.arrayofipaddresses += $CDPDevice.arrayofipaddresses
                }
                elseif ($LLDPLookup.ContainsKey($route.gateway)) {
                    $LLDPDevice = $LLDPLookup[$route.gateway]
                    $HostGatewayObject.Description = $LLDPDevice.Description
                    [array]$HostGatewayObject.arrayofipaddresses += $LLDPDevice.arrayofipaddresses
                }

                # Step 5: finalize the link. Always link to the gateway's INTERFACE object, never
                # to the gateway host itself - callers resolve the owning device from the interface.
                $route.GatewayLink = [ref]$interfaceObject

                # Clean up the IP list and save the new gateway host
                $HostGatewayObject.arrayofipaddresses = $HostGatewayObject.arrayofipaddresses | Where-Object { $_ } | Sort-Object -Unique
                $ArrayofGatewayHosts += $HostGatewayObject

                foreach ($ip in $HostGatewayObject.arrayofipaddresses) {
                    $GatewayHostsLookup[$ip] = $true
                }

                # Cache this gateway result for the next route
                $LastGatewayCache[$route.gateway] = $route.GatewayLink
            }
        }
    }
    Update-MTAutoDrawGatewayHostAsn -Devices $ArrayOfObjects -GatewayHosts $ArrayofGatewayHosts


    # The comma keeps an empty result an empty array rather than letting it unroll to $null on the
    # way out, which is what the six-element return contract has always carried.
    return , $ArrayofGatewayHosts
}

# Stamps each gateway host with the AS number that the devices peering with it advertise, so the
# routing pages can label a next hop with the autonomous system it belongs to.
function Update-MTAutoDrawGatewayHostAsn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Devices,
        [AllowEmptyCollection()][array]$GatewayHosts
    )

    # This loop enriches the gateway host objects with BGP ASN information if available.
    Write-MTAutoDrawLog -Level Info -Phase Resolve -Message "Updating BGP ASN for gateway hosts."
    foreach ($device in $Devices) {
        # Only process devices that have BGP neighbor information.
        if ($device.BGPNeighbors) {
            foreach ($bgpNeighbor in $device.BGPNeighbors) {
                # Find the gateway host object whose IP address matches the BGP neighbor's IP.
                $gatewayHost = $GatewayHosts | Where-Object { $_.ArrayOfIPAddresses -contains $bgpNeighbor.NEIGHBOR } | Select-Object -First 1
               
                # If a corresponding gateway host is found and it has a remote AS number...
                if ($gatewayHost -and $bgpNeighbor.REMOTE_AS) {
                    # ...update the gateway host's BGP_AS_Number property.
                    $gatewayHost.BGP_AS_Number = $bgpNeighbor.REMOTE_AS
                }
            }
        }
    }
}

# Marks the interfaces the "Layer 3 Routes Only" page draws: every interface that sources a route,
# every interface a route points at, and - in a second pass - the HSRP partners of anything already
# marked, so a redundant pair is never drawn half-present.
function Resolve-MTAutoDrawStandbyPartners {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Devices,
        [AllowEmptyCollection()][array]$GatewayHosts
    )

    $ArrayOfObjects = $Devices
    $ArrayofGatewayHosts = $GatewayHosts

    Write-MTAutoDrawLog -Level Info -Phase Resolve -Message "Marking interfaces for the 'Layer 3 Routes Only' diagram."
    $AllRoutableObjects = $ArrayOfObjects + $ArrayofGatewayHosts
    foreach ($device in $AllRoutableObjects) {
        if ($device.interfaces) {
            foreach ($interface in ($device.interfaces | Where-Object { $_.RoutesForInterface })) {
                 if ($interface.RoutesForInterface.Count -gt 0) {
                    # This is a source interface with routes, so it should be drawn.
                    $interface.DrawOnRoutesOnlyDiagram = $true

                    # Find and mark the destination interface for each route.
                    foreach ($route in $interface.RoutesForInterface) {
                        if ($route.GatewayLink) {
                            # GatewayLink is a reference to the target interface object.
                            $targetInterface = $route.GatewayLink.Value
                            if ($targetInterface) {
                                # Mark the target interface to be drawn.

                                $targetInterface.DrawOnRoutesOnlyDiagram = $true
                            }
                        }
                    }
                 }
            }
        }
    }

    Write-MTAutoDrawLog -Level Debug -Phase Resolve -Message "Marking interfaces for the 'Layer 3 Routes Only' diagram (pass 2: HSRP partners)..."

    # --- PASS 2: Find any marked interface that has a standby IP, then find and mark its partners. ---
    # Get a unique list of all standby IPs from interfaces that were marked in Pass 1.
    $activeStandbyIPs = $AllRoutableObjects | ForEach-Object { $_.interfaces } | Where-Object { $_.DrawOnRoutesOnlyDiagram -and $_.standbyip } | Select-Object -ExpandProperty standbyip -Unique

    if ($activeStandbyIPs) {
        # Find every interface across all devices that uses one of these active standby IPs.
        $allPartnerInterfaces = $AllRoutableObjects | ForEach-Object { $_.interfaces } | Where-Object {
            $hasSharedStandbyIp = $false
            # The -contains operator works correctly whether $_.standbyip is a single string or an array.
            foreach($ip in $activeStandbyIPs) {
                if (@($_.standbyip) -contains $ip) {
                    $hasSharedStandbyIp = $true
                    break
                }
            }
            $hasSharedStandbyIp
        }

        # Mark every found partner interface to be drawn.
        foreach ($partner in $allPartnerInterfaces) {
            $partner.DrawOnRoutesOnlyDiagram = $true
        }
    }

    return
}

# Records, per device, which VLANs it is the spanning-tree root for, and recovers the spanning-tree
# mode from a per-instance protocol when the running config never stated one - which is the normal
# case on a Nexus switch, whose default configuration omits the "spanning-tree mode" line.
function Resolve-MTAutoDrawSpanningTreeRoots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Devices
    )

    #Find spanning root bridges for each device.
    Write-MTAutoDrawLog -Level Info -Phase Resolve -Message "Getting Spanning tree root bridge for each device."
    foreach ($Device in $Devices){
        if($Device.SpanningTree){#Does this device have some kindof spanning-tree?
            $Device.SpanningTree.RootBridgeForvlans=@($Device.SpanningTree.SpanningTreeArray | Where-Object { $_.RootBridge -eq $true } | ForEach-Object { [string]$_.vlanid })
            #Do we have a spanning tree mode set. Nexus switches don't have commands like "spanning-tree mode pvst" in show run with a default config.
            #Pull the mode off one of the interfaces if this is the case.
            if($null -eq $Device.SpanningTree.SpanningTreeMode -or $Device.SpanningTree.SpanningTreeMode -eq ""){
                $Device.SpanningTree.SpanningTreeMode = $Device.SpanningTree.SpanningTreeArray | where { $null -ne $_.protocol -or $_.protocol -ne "" } | select -first 1 | % {$_.protocol}
            }
        }
    }

}

# Builds a host object for every LLDP neighbour no capture group covers, so a switch that only
# appears as somebody else's neighbour is still drawn. A neighbour already synthesized from CDP is
# skipped, and when GConsolidateNeighbors is set the interfaces of one neighbour seen from several
# devices collapse onto a single host rather than producing one host per sighting.
function New-MTAutoDrawUnconfiguredLldpHosts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Devices
    )

    [Array]$ArrayOfLLDPDeviceIDs = @()

    Write-MTAutoDrawLog -Level Info -Phase Resolve -Message "Creating host objects for LLDP neighbours we don't have config for."
    #These are LLDP neighbours we don't have a config for but we know a little bit about.
    #This creates an array of host objects so that we can draw them as standard hosts.
    foreach ($Device in $Devices){
        foreach ( $LLDPNeighbor in ($Device.LLDPNeighbors | where { !$_.PartnerEthernetInterface -and !$_.Ignored } | sort -Descending InterfaceLocalDevice)){ #sort order here is important as this is the order in which we will draw them
            if($LLDPNeighbor.HasCDPNeighborEntry ){#Skip objects we have already drawn in CDPNeighbors
                continue
            }
            #If we are consolidating the neighbor so we get one object with multiple interfaces we need to
            #check to see if we have already made a object for this neighbor that we just need to add interfaces to.
            #The order in which to match.
            $MatchField=$null
            if($LLDPNeighbor.HostName){
                $MatchField=($ArrayOfLLDPDeviceIDs | where { $_.HostName -eq $LLDPNeighbor.HostName })
            }else{
                $MatchField=($ArrayOfLLDPDeviceIDs | where { $_.ChassisID -eq $LLDPNeighbor.ChassisID })
            }
            if($GConsolidateNeighbors -and $MatchField){
                $LLDPObject=$MatchField
                $InterfaceObject=Create-InterfaceObject
                $InterfaceObject.interface = if ($LLDPNeighbor.InterfaceRemoteDevice) { $LLDPNeighbor.InterfaceRemoteDevice }
                    elseif ($LLDPNeighbor.PortID) { "Port ID $($LLDPNeighbor.PortID)" }
                    else { 'Remote port unresolved' }
                $InterfaceObject.shutdown = $false
                $LLDPObject.Interfaces+=$InterfaceObject
                [Array]$LLDPObject.ArrayOfIPAddresses+=[Array]$LLDPNeighbor.ManagementIP
            }else{
                $LLDPObject=Create-HostObject
                $LLDPObject.Origin="LLDP"
                $LLDPObject.Interfaces=@()
                [Array]$LLDPObject.ArrayOfIPAddresses=@()
                $LLDPObject.HostName=$LLDPNeighbor.Hostname
                $LLDPObject.ParentObject=$LLDPNeighbor.ParentObject #The first object we have will be the parent object if there are multiple parent objects.
                $InterfaceObject=Create-InterfaceObject
                $InterfaceObject.interface = if ($LLDPNeighbor.InterfaceRemoteDevice) { $LLDPNeighbor.InterfaceRemoteDevice }
                    elseif ($LLDPNeighbor.PortID) { "Port ID $($LLDPNeighbor.PortID)" }
                    else { 'Remote port unresolved' }
                $InterfaceObject.shutdown = $false
                $LLDPObject.Interfaces+=$InterfaceObject
                if($LLDPNeighbor.ManagementIP){
                    [Array]$LLDPObject.ArrayOfIPAddresses+=[Array]$LLDPNeighbor.ManagementIP
                }
                $LLDPObject.Description="`r`n$($LLDPNeighbor.SystemDescription)`r`n$($LLDPNeighbor.CAPABILITIES)`r`n$($LLDPNeighbor.ManagementIP)`r`n$($LLDPNeighbor.$SERIAL)"
                $ArrayOfLLDPDeviceIDs+=$LLDPObject
            }
            $LLDPObject.ArrayOfIPAddresses=$LLDPObject.ArrayOfIPAddresses | sort -Unique
        }
    }

    # Keeps an empty result an array rather than letting it unroll to $null on the way out.
    return , $ArrayOfLLDPDeviceIDs
}

# Builds a host object for every CDP neighbour no capture group covers. The descending interface
# sort is load-bearing: it is the order the neighbours are drawn in. GConsolidateNeighbors collapses
# one neighbour seen from several devices onto a single host with several interfaces.
function New-MTAutoDrawUnconfiguredCdpHosts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Devices
    )

    [Array]$ArrayOfCDPDeviceIDs = @()

    Write-MTAutoDrawLog -Level Info -Phase Resolve -Message "Creating host objects for CDP neighbours we don't have config for."
    #These are cdp neighbors we don't have a config for but we know a little bit about.
    #This creates an array of host objects so that we can draw them as standard hosts.
    foreach ($Device in $Devices){
        foreach ( $cdpneighbor in ($Device.cdpneighbors | where { !$_.PartnerEthernetInterface -and !$_.Ignored } | sort -Descending -property @{Expression={[int]($_.InterfaceLocalDevice -replace '[a-zA-Z-]+','' -replace "/",'')} } )){ #sort order here is important as this is the order in which we will draw them
            if($GConsolidateNeighbors -and ($ArrayOfCDPDeviceIDs | where { $_.hostname -eq $cdpneighbor.DeviceID })){
                $CDPObject=$ArrayOfCDPDeviceIDs | where { $_.hostname -eq $cdpneighbor.DeviceID }
                $InterfaceObject=Create-InterfaceObject
                $InterfaceObject.interface=$cdpneighbor.InterfaceRemoteDevice
                $InterfaceObject.shutdown = $false
                $CDPObject.Interfaces+=$InterfaceObject
                foreach ($ipaddress in $cdpneighbor.InterfaceIPAddresses){
                    [Array]$CDPObject.ArrayOfIPAddresses+=[Array]$ipaddress
                }
            }else{
                $CDPObject=Create-HostObject
                $CDPObject.Origin="CDP"
                [Array]$CDPObject.ArrayOfIPAddresses=@()
                $CDPObject.Interfaces=@()
                $CDPObject.HostName=$cdpneighbor.DeviceID
                $CDPObject.Version=$cdpneighbor.Version
                $CDPObject.Platform=$cdpneighbor.Platform
                $CDPObject.Capabilities=$cdpneighbor.Capabilities
                $CDPObject.ParentObject=$cdpneighbor.ParentObject #The first object we have will be the parent object if there are multiple parent objects.
                $CDPObject.Description="`r`n$($cdpneighbor.Platform)`r`n$($cdpneighbor.Version)`r`n$($SystemName)"
                $InterfaceObject=Create-InterfaceObject
                $InterfaceObject.interface=$cdpneighbor.InterfaceRemoteDevice
                $InterfaceObject.shutdown = $false
                $CDPObject.Interfaces+=$InterfaceObject
                foreach ($ipaddress in $cdpneighbor.InterfaceIPAddresses){
                    [Array]$CDPObject.ArrayOfIPAddresses+=[Array]$ipaddress
                }
                $CDPObject.ArrayOfIPAddresses = $CDPObject.ArrayOfIPAddresses | sort -Unique
                $ArrayOfCDPDeviceIDs+=$CDPObject
            }
        }
    }

    # Keeps an empty result an array rather than letting it unroll to $null on the way out.
    return , $ArrayOfCDPDeviceIDs
}

# Turns each CDP and LLDP neighbour entry into a link to the actual interface object it names, when
# that interface belongs to a device we also have config for. One physical port can only be claimed
# once, so a second link naming the same port loses to whichever claimed it first; an LLDP entry
# whose port already carries a CDP link is skipped so the pair is not drawn twice.
function Resolve-MTAutoDrawConfiguredNeighborLinks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Devices
    )

    $perfStep = Start-MTAutoDrawPerf -Label "Resolve:   New-NeighborResolutionIndex"   # PERF
    $neighborIndex = New-NeighborResolutionIndex -Devices $Devices
    Stop-MTAutoDrawPerf -Token $perfStep -Detail "$(@($Devices).Count) devices"
    # "targetHost|port" -> "sourceHost|port" of whichever link claimed that physical port.
    $portClaims = @{}

    if ($GSuppressFloodedNeighbors) {
        $perfStep = Start-MTAutoDrawPerf -Label "Resolve:   Set-FloodedNeighborEntries"   # PERF
        $suppressedFlooded = Set-FloodedNeighborEntries -Devices $Devices -Index $neighborIndex -MaxDevicesPerPort $GMaxNeighborDevicesPerPort
        Stop-MTAutoDrawPerf -Token $perfStep -Detail "$suppressedFlooded suppressed"
        Write-MTAutoDrawLog -Level Info -Phase Resolve -Message "Suppressed $suppressedFlooded flooded CDP/LLDP neighbour entries on shared segments."
    }

    # PERF: the loop below is the biggest single unexplained gap in a run log - on a large site it
    # can run for well over a minute with nothing printed in between. These four counters split it
    # into the parts that could plausibly own that time. Accumulated, not printed per iteration.
    $perfLoop = Start-MTAutoDrawPerf -Label "Resolve:   neighbour match loop (TOTAL)"   # PERF
    $perfNeighborCount = 0

    foreach ($device in $Devices) {
        foreach ($protocol in @('CDP','LLDP')) {
            $neighbors = if ($protocol -eq 'CDP') { @($device.CDPNeighbors) } else { @($device.LLDPNeighbors) }
            foreach ($neighbor in $neighbors) {
                if ($protocol -eq 'LLDP' -and $neighbor.HasCDPNeighborEntry) {
                    $perfTick = if ($global:GPerfTiming) { [System.Diagnostics.Stopwatch]::GetTimestamp() } else { 0 }   # PERF
                    $linkedCdpOnPort = @($device.CDPNeighbors | Where-Object {
                        $_.PartnerEthernetInterface -and
                        (ConvertTo-NormalizedInterfaceIdentity $_.InterfaceLocalDevice) -eq (ConvertTo-NormalizedInterfaceIdentity $neighbor.InterfaceLocalDevice)
                    }).Count -gt 0
                    if ($global:GPerfTiming) { Add-MTAutoDrawPerf -Label "Resolve:     LLDP already-linked-by-CDP scan (accumulated)" -Milliseconds ((([System.Diagnostics.Stopwatch]::GetTimestamp() - $perfTick) * 1000.0) / [System.Diagnostics.Stopwatch]::Frequency) }   # PERF
                    if ($linkedCdpOnPort) { continue }
                }
                if ($neighbor.PartnerEthernetInterface -or $neighbor.Ignored) { continue }

                $perfNeighborCount++   # PERF
                $perfTick = if ($global:GPerfTiming) { [System.Diagnostics.Stopwatch]::GetTimestamp() } else { 0 }   # PERF
                $resolution = Resolve-ConfiguredNeighborLink -SourceDevice $device -Neighbor $neighbor -Devices $Devices -Protocol $protocol -Index $neighborIndex
                if ($global:GPerfTiming) { Add-MTAutoDrawPerf -Label "Resolve:     Resolve-ConfiguredNeighborLink (accumulated)" -Milliseconds ((([System.Diagnostics.Stopwatch]::GetTimestamp() - $perfTick) * 1000.0) / [System.Diagnostics.Stopwatch]::Frequency) }   # PERF
                $neighbor.MatchMethod = $resolution.MatchMethod
                $neighbor.MatchConfidence = $resolution.MatchConfidence
                $neighbor.TargetHostname = if ($resolution.TargetDevice) { $resolution.TargetDevice.hostname } else { $null }
                $neighbor.TargetInterface = if ($resolution.TargetInterface) { $resolution.TargetInterface.Interface } else { $null }
                if ($resolution.IsSelf) {
                    $neighbor.Ignored = $true
                    $neighbor.IgnoreReason = 'Management/self-neighbor entry'
                    Write-MTAutoDrawLog -Level Debug -Phase Resolve -Message "Ignoring genuine $protocol self-neighbor on $($device.hostname)/$($neighbor.InterfaceLocalDevice)."
                    continue
                }

                if ($resolution.TargetDevice -and $resolution.TargetInterface) {
                    # One physical port carries one physical link. Flood suppression only sees the
                    # port that hears the flooding; the far ends are not themselves flooded, so
                    # several of them can still resolve onto that one port. Whoever claims it first
                    # keeps it, and the rest are recorded rather than drawn.
                    $claimKey = "$($resolution.TargetDevice.hostname)|$(ConvertTo-NormalizedInterfaceIdentity $resolution.TargetInterface.Interface)"
                    $claimant = "$($device.hostname)|$(ConvertTo-NormalizedInterfaceIdentity $neighbor.InterfaceLocalDevice)"
                    if ($portClaims.ContainsKey($claimKey) -and $portClaims[$claimKey] -ne $claimant) {
                        $neighbor.Ignored = $true
                        $neighbor.IgnoreReason = "Target port already linked to $($portClaims[$claimKey] -replace '\|',' ')"
                        $neighbor.MatchMethod = "$($resolution.MatchMethod) + rejected duplicate target port"
                        $neighbor.TargetInterface = $null
                        Write-MTAutoDrawLog -Level Debug -Phase Resolve -Message "$protocol link rejected: $($device.hostname)($($neighbor.InterfaceLocalDevice)) -> $claimKey is already linked to $($portClaims[$claimKey])."
                        continue
                    }
                    $portClaims[$claimKey] = $claimant

                    $perfTick = if ($global:GPerfTiming) { [System.Diagnostics.Stopwatch]::GetTimestamp() } else { 0 }   # PERF
                    $deviceIndex = [array]::IndexOf([array]$Devices, $resolution.TargetDevice)
                    $interfaceIndex = [array]::IndexOf([array]$resolution.TargetDevice.interfaces, $resolution.TargetInterface)
                    if ($global:GPerfTiming) { Add-MTAutoDrawPerf -Label "Resolve:     [array]::IndexOf device+interface (accumulated)" -Milliseconds ((([System.Diagnostics.Stopwatch]::GetTimestamp() - $perfTick) * 1000.0) / [System.Diagnostics.Stopwatch]::Frequency) }   # PERF
                    if ($deviceIndex -ge 0 -and $interfaceIndex -ge 0) {
                        $neighbor.PartnerEthernetInterface = [ref]$Devices[$deviceIndex].interfaces[$interfaceIndex]
                        $Devices[$deviceIndex].interfaces[$interfaceIndex].IsLinkedToByCDPorLLDP = $true
                        $from = "$($device.hostname)($($neighbor.InterfaceLocalDevice))"
                        $to = "$($resolution.TargetDevice.hostname)($($resolution.TargetInterface.Interface))"
                        Write-MTAutoDrawLog -Level Debug -Phase Resolve -Message "LINK [$protocol]: $from -> $to :: SUCCESS - Method: $($resolution.MatchMethod), Confidence: $($resolution.MatchConfidence)"
                    }
                }
                elseif ($resolution.TargetDevice) {
                    $remoteName = if ($neighbor.InterfaceRemoteDevice) { $neighbor.InterfaceRemoteDevice } else { $neighbor.NeighborInterfaceDescription }
                    Write-Warning "$protocol link failed: $($device.hostname)($($neighbor.InterfaceLocalDevice)) -> $($resolution.TargetDevice.hostname)($remoteName); target device found but remote interface was not uniquely resolved."
                }
                else {
                    Write-MTAutoDrawLog -Level Debug -Phase Resolve -Message "$protocol link unresolved: $($device.hostname)($($neighbor.InterfaceLocalDevice)); neighbor is not present in the configured device set."
                }
            }
        }
    }
    Stop-MTAutoDrawPerf -Token $perfLoop -Detail "$perfNeighborCount neighbour entries resolved"   # PERF
}

# Older SG/CBS switches answer only "show system id", a serial, so their own chassis MAC is never
# learned and a neighbour that identifies them by that MAC cannot be matched to them. Their
# neighbours advertise both the MAC and an IP address we can already place, so it is back-filled
# from there - but only onto a device with no MAC of its own, so a real one is never overwritten.
function Update-MTAutoDrawSmallBusinessChassisMac {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Devices
    )

    # Older SG/CBS switches only offer "show system id" (a serial), so we never learn their own MAC
    # and they cannot be matched when a neighbour identifies them by chassis MAC. Their neighbours,
    # however, advertise both that MAC and an IP we can already place, so back-fill it from there.
    $macBackfill = 0
    $addressIndex = (New-NeighborResolutionIndex -Devices $Devices).Address
    foreach ($device in $Devices) {
        foreach ($neighbor in @($device.CDPNeighbors)) {
            if (-not $neighbor) { continue }
            $mac = ConvertTo-NormalizedMacIdentity $neighbor.DeviceID
            $address = ([string]$neighbor.InterfaceIPAddresses).Trim()
            if (-not $mac -or -not $address -or -not $addressIndex.ContainsKey($address)) { continue }
            $target = $addressIndex[$address]
            if (@(Get-DeviceKnownMacAddress -Device $target).Count -gt 0) { continue }
            $target.ManagementMacAddress = $neighbor.DeviceID
            $macBackfill++
        }
    }
    if ($macBackfill) { Write-MTAutoDrawLog -Level Info -Phase Resolve -Message "Back-filled chassis MACs for $macBackfill device(s) from neighbour advertisements." }
}

# Drops the networks nothing is connected to, then gives each survivor the VLAN name its devices
# know it by - concatenated when they disagree - and the ARP entries that fall inside it. Returns
# the filtered list. The ARP half is skipped unless GDrawAprEntries is set, because it is slow.
function Add-MTAutoDrawNetworkArpEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Networks,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Devices,
        [AllowEmptyCollection()][array]$ArpEntries
    )

    #We don't care about vlans that have no layer 3 interface in the array of networks.
    $Networks= $Networks| where {$_.NumberOfConnectors -gt 0}
    Write-MTAutoDrawLog -Level Debug -Phase Resolve -Message "Networks after dropping ones with no Layer 3 interface: $($Networks.count)."
    Write-MTAutoDrawLog -Level Info -Phase Resolve -Message "Processing network Layer 3 ARP entries and VLAN names."
    #Get the name of the vlan and add the ARP entries to the object
    foreach ($network in $Networks){
        foreach ($Device in $Devices){
            foreach ($vlan in ($Device.vlans| where{ $null -ne $_.name -and $_.name -ne "" -and $_.name -ne "No name"})){
                if($vlan.number -eq ($Network.RoutedVlan -replace "vlan",'')){
                    if($Network.NetworkName ){#if there are multiple names for the same vlan concat them.
                        if($Network.NetworkName -like "*$($vlan.name)*"){
                            break
                        }
                        $Network.NetworkName="$($Network.NetworkName)  -  $($vlan.name)"
                    }else{
                        $Network.NetworkName=$vlan.name
                    }
                    break
                }
            }
        }
        #This can be really slow don't process it if we don't need to.
        if($GDrawAprEntries){
            #Get all the ARP entries and attach them to the network object
            $network.ARPEntries=$ArpEntries | where {$_.cidr -eq $Network.cidr }
        }
    }

    # Keeps an empty result an array rather than letting it unroll to $null on the way out.
    return , $Networks
}

# Reduces the per-device network lists to one object per CIDR, gives each a deterministic colour,
# and counts how many interfaces and how many routed interfaces connect to it. Returns the
# deduplicated list; the counts are what the next stage uses to drop networks nothing reaches.
function Set-MTAutoDrawNetworkPresentation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Networks,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Devices
    )

    Write-MTAutoDrawLog -Level Info -Phase Resolve -Message "Processing $($Networks.count) network objects."
    #Create a list of all networks shared across all devices.
    # Deduplicate by CIDR, first device wins. Deliberately not "sort cidr -Unique": Sort-Object's
    # comparison sort is only stable up to 16 elements, so above that it keeps an arbitrary member of
    # each tie group. Only the surviving object receives ARP entries and a connector count, so keep
    # selection independent of device-array ordering to avoid moving Layer 3 data between records.
    $seenCidrs = @{}
    $Networks = @(foreach ($network in $Networks) {
        $cidrKey = [string]$network.cidr
        if ($seenCidrs.ContainsKey($cidrKey)) { continue }
        $seenCidrs[$cidrKey] = $true
        $network
    }) | sort cidr | sort vlan
    #Add a color for every network
    $Networks | ForEach-Object { $_.color = Get-DeterministicRgbColor -Seed ([string]$_.cidr) }
    $Networks = $Networks | sort  NumberOfConnectors,vlan,cidr
    Write-MTAutoDrawLog -Level Debug -Phase Resolve -Message "Networks before the connector-count pass: $($Networks.count)."
    $networkByCidr = @{}
    foreach ($network in $Networks) { $networkByCidr[[string]$network.cidr] = $network }
    #Count the number of connectors to each network.
    foreach ($Device in $Devices){
        foreach ($interface in ($Device.interfaces | Where-Object { $_ -and -not $_.shutdown })){
            $interfaceCidrs = @(Get-MTAutoDrawInterfaceIPv4Address -Interface $interface | Where-Object Cidr | Select-Object -ExpandProperty Cidr -Unique)
            foreach ($interfaceCidr in $interfaceCidrs) {
                if (-not $networkByCidr.ContainsKey([string]$interfaceCidr)) { continue }
                $network = $networkByCidr[[string]$interfaceCidr]
                $network.NumberOfConnectors++
                if($network.Routedvlan -eq "no vlan" -and $interface.Routedvlan -ne "no vlan"){
                    $network.Routedvlan = "vlan$($interface.Routedvlan)"
                }
                if($interface.RoutesForInterface.count -ne 0){
                    $network.NumberOfRoutedConnectors++
                }
            }
        }
    }

    # Keeps an empty result an array rather than letting it unroll to $null on the way out.
    return , $Networks
}

# Hangs each route off the interface it leaves by, sorted, so the drawing layer never has to filter
# a routing table itself. Connected, local and host routes are excluded: they describe the interface
# rather than anything reached through it. Shut and down interfaces are skipped.
function Update-MTAutoDrawInterfaceRoutes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Devices
    )

    #Pre-Calculate all of the routes that flow out from an interface and sort them on the interface.
    #This is put here to reduce the amount of logic in other parts of the scrip
    Write-MTAutoDrawLog -Level Info -Phase Resolve -Message "Calculating routes on each interface."
    foreach ($Device in $Devices){
        foreach ($interface in $Device.interfaces | where { $_.ipaddress -and $_.shutdown -eq $false -and $_.IntStatus -notlike "*down*"}){
            $interface.RoutesForInterface=$Device.RoutingTable| where { $_.interface -eq $interface.Interface -and $_.routeprotocol -notmatch "connect|host|Access-internal|local|connected|direct" } | sort gateway,subnet
        }
    }
}

# A Check Point cluster member answers ARP for the cluster address as well as its own, so the
# cluster IP shows up in the ARP table against the member's own MAC. That is the only place it can
# be recovered from, so it is read back onto the interface here.
function Update-MTAutoDrawCheckPointVirtualInterfaces {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Devices,
        [AllowEmptyCollection()][array]$ArpEntries
    )

    #Find virtual interfaces on checkpoints. This could probably be expanded to other devices as needed if we lack information.
    foreach ($Device in $Devices |where {$_.DeviceType -eq "CheckPoint" }){
        foreach ($interface in $Device.interfaces){
            if($ArpEntries | where { $interface.macaddress -eq $_.mac} | where { $interface.ipaddress -ne $_.ipaddress}){
                $interface.ClusterIP=($ArpEntries | where { $interface.macaddress -eq $_.mac}| where { $interface.ipaddress -ne $_.ipaddress}).ipaddress
            }
        }
    }
}

# Folds the parallel workers' devices into the two arrays the rest of the pipeline works from,
# resolving hostname collisions on the way: two captures of the same serial are the same device and
# the second is dropped, while the same hostname on a different serial is two devices and the second
# is renamed with its serial appended. Duplicate detection has to be sequential, which is why it
# happens here rather than inside a worker.
function Merge-MTAutoDrawWorkerResults {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][array]$ProcessedDevices
    )

    [Array]$ArrayOfObjects = @()
    [Array]$ArrayOfNetworks = @()

    # 2. AGGREGATE RESULTS AND CHECK FOR DUPLICATES SEQUENTIALLY
    # This part runs after all parallel jobs are finished and uses your array definitions.

    $hostnameMap = @{}

    foreach ($device in ($ProcessedDevices | Where-Object { $_ -ne $null } | Sort-Object hostname, DeviceIdentifier)) {

        # --- Safety Check: Ensure the device has a hostname ---
        if ([string]::IsNullOrEmpty($device.hostname)) {
            Write-Warning "A device was found with no hostname. Skipping this entry."
            continue
        }

        # Check if a device with this hostname has already been processed.
        if ($hostnameMap.ContainsKey($device.hostname)) {
            # A repeated hostname is allowed only when the serial proves it is the same device.
            $originalDevice = $hostnameMap[$device.hostname]

            # --- Safety Check: Safely get the primary serial number from both devices ---
            $originalSerial = if ($originalDevice.Version -and $originalDevice.Version.Serial.Count -gt 0) {
                $originalDevice.Version.Serial[0]
            } else {
                $null
            }

            $currentSerial = if ($device.Version -and $device.Version.Serial.Count -gt 0) {
                $device.Version.Serial[0]
            } else {
                $null
            }

            # --- Compare Serial Numbers ---
            if ($originalSerial -eq $currentSerial) {
                Write-MTAutoDrawLog -Level Info -Phase Parse -Message "Duplicate device: skipping '$($device.hostname)' because a device with the same serial ('$($currentSerial)') already exists."
                continue
            }
            else {
                if ([string]::IsNullOrEmpty($currentSerial)) {
                    Write-Warning "DUPLICATE HOSTNAME: '$($device.hostname)'. The new device has no serial number, so a unique name cannot be generated. Skipping."
                    continue
                }

                $originalHostname = $device.hostname
                $device.hostname = "$($originalHostname)_$($currentSerial)"
                Write-MTAutoDrawLog -Level Warn -Phase Parse -Message "Duplicate hostname '$($originalHostname)' found with a different serial number. Renaming device to '$($device.hostname)'."
            }
        }

        # Add the unique device to the map for future checks.
        $hostnameMap[$device.hostname] = $device

        # Add the processed data to the main arrays using the += operator.
        $ArrayOfObjects += $device

        # Safety Check: Ensure the ArrayOfNetworks property exists before adding.
        if ($null -ne $device.ArrayOfNetworks) {
           $ArrayOfNetworks += $device.ArrayOfNetworks
        }
    }

    return [pscustomobject]@{ Devices = $ArrayOfObjects; Networks = $ArrayOfNetworks }
}

# Replays, on the main thread, the diagnostics each worker buffered onto its device. The two
# Write-Host calls here are deliberate and must stay: this is the one place output is attributable
# to a device, which is exactly what writing from inside ForEach-Object -Parallel cannot be.
function Write-MTAutoDrawWorkerDiagnostics {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][array]$Results,
        [Parameter(Mandatory = $true)][datetime]$RunStartedAtUtc
    )

    # Level filtering happens here, once, on the main thread - a worker's Write-MTAutoDrawLog calls
    # always buffer to $Device.DebugLog unconditionally (see that function's doc comment), so this is
    # the only place a device's diagnostics are actually gated by $GLogLevel.
    $flushThreshold = if ($GLogLevel) { $GLogLevel } else { 'Info' }
    foreach ($result in $Results) {
        foreach ($warning in @($result.Warnings)) { Write-Warning "[$($result.HostID)] $warning" }
        if ($result.Failure) {
            Write-Error ("Parser failure [{0}] {1} ({2}:{3}): {4}" -f $result.Failure.Parser,$result.Failure.CapturePath,$result.Failure.ScriptName,$result.Failure.Line,$result.Failure.Message) -ErrorAction Continue
        }
        if (-not $result.Device) { continue }
        # Structured worker records carry Level, so filtering is deterministic on the main thread.
        $visibleLogs = @($result.Device.DebugLog | Where-Object {
            Test-MTAutoDrawLogLevelVisible -Level $_.Level -Threshold $flushThreshold
        })
        if ($visibleLogs.Count -eq 0) { continue }
        Write-Host "`n--- Parser diagnostics for: $($result.Device.hostname) [$($result.HostID)] ---" -ForegroundColor Cyan
        foreach ($log in $visibleLogs) {
            $level = if ($log.Level) { $log.Level } else { 'Info' }
            $phase = if ($log.Phase) { $log.Phase } else { 'Parse' }
            # .ToUniversalTime() rather than a raw subtraction: DateTime subtraction in .NET ignores
            # .Kind, so this has to normalize explicitly. Write-MTAutoDrawLog stores UTC already (a
            # no-op here); the still-present pre-conversion Add-HostDebugText stores Get-Date's local
            # time, and this is what keeps ITS elapsed correct too until it is deleted.
            $elapsed = $log.Timestamp.ToUniversalTime() - $RunStartedAtUtc
            $line = Format-MTAutoDrawLogLine -Elapsed $elapsed -Level $level -Phase $phase -Message $log.Text
            Write-Host $line -ForegroundColor (Get-MTAutoDrawLogLevelColor -Level $level)
        }
    }
}

# Runs one worker per capture group and returns one envelope each, so warnings, buffered per-device
# diagnostics and exceptions can all be replayed in stable order by the parent runspace.
#
# Two lists in here are load-bearing and easy to break. The $using: block is the ONLY channel by
# which a global reaches a worker - a global that is not assigned there is silently $null inside,
# with no error and no warning, just wrong output. The Import-Module list inside the scriptblock is
# the only thing that puts functions in the runspace, and a library missing from it fails at
# runtime rather than at load. Adding either means adding it here.
function Invoke-MTAutoDrawParallelDispatch {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][array]$HostIDs
    )

    # Workers launch TextFSM child processes; a quarter of the logical cores avoids oversubscription.
    $throttleLimit = [Math]::Max(1, [Math]::Ceiling([System.Environment]::ProcessorCount / 4))
    Write-MTAutoDrawPhase -Phase Parse -Message "Starting parallel processing with a throttle limit of $throttleLimit..."

    # 1. PROCESS ALL DEVICES IN PARALLEL. Each worker returns one envelope so warnings,
    # diagnostics, and exceptions can be replayed in stable capture order by the parent runspace.
    $workerResults = $HostIDs | ForEach-Object -Parallel {


        $hostid = $_ # The current item from the pipeline

        # We must explicitly import modules needed by this thread.
        # This ensures all functions are available in the parallel runspace.
        # Runtime-modified variables:
        $GMacAddressToVendorMapping  = $using:GMacAddressToVendorMapping

        # Path variables (determined by params or runtime location):
        $GPathToScript               = $using:GPathToScript
        $GPathToPythonExe            = $using:GPathToPythonExe
        $GPathToPythonTextFSMScript  = $using:GPathToPythonTextFSMScript

        # "Constant" variables (loaded from configurationVariables.ps1 in the main script):
        $GTextFSMTemplates           = $using:GTextFSMTemplates
        $GSkipCDPLLDPPhones          = $using:GSkipCDPLLDPPhones
        $GDrawPortsWithMacs          = $using:GDrawPortsWithMacs
        $GDrawCDP                    = $using:GDrawCDP          # Cisco/Arista/Aruba gate MAC-table parsing on this
        $GSkipHSRPRoutes             = $using:GSkipHSRPRoutes   # Cisco route parsing reads this
        $GDrawAprEntries             = $using:GDrawAprEntries
        $SkipHostnameErrorCheck      = $using:SkipHostnameErrorCheck
        $GDebugingEnabled            = $using:GDebugingEnabled
        $GLastExecutionTime          = $using:GLastExecutionTime
        # Write-MTAutoDrawLog's -Device branch always appends unconditionally - level filtering is
        # centralized on the main thread at the flush loop below, not decided per-worker - so nothing
        # in a reader currently consults $GLogLevel. Marshaled anyway, both for parity with the other
        # globals here and so a reader that wants to skip building an expensive Trace-level message
        # can check it without encountering a silent $null from the runspace boundary.
        $GLogLevel                   = $using:GLogLevel
        # --- END OF THREAD INITIALIZATION ---

        $hostid = $_

        # Import function definitions.
        # DO NOT import configurationVariables.ps1 here; its values are already captured above.
        Import-Module "$($GPathToScript)Logging.ps1" -Force
        Import-Module "$($GPathToScript)ParserRuntime.ps1" -Force
        Import-Module "$($GPathToScript)DrawioDocument.ps1" -Force
        Import-Module "$($GPathToScript)ObjectFunctions.ps1" -Force
        Import-Module "$($GPathToScript)GETIPV4Subnet\GetIPv4Subnet.psm1" -Force -DisableNameChecking
        
         

        # Vendor diagnostics use the parallel-safe append-only -Device path and are flushed by the
        # main runspace after worker aggregation.
        $Device = $null
        $processorName = $null
        $workerWarnings = @()
        $workerFailure = $null

        try {
        # NOTE: We pass $null for ArrayOfObjects because we cannot safely check for duplicates in parallel.
        switch($hostid.DeviceType){
            "Cisco"{
                Import-Module "$($GPathToScript)CiscoConfigProcessingFunctions.ps1" -Force
                $processorName = 'Process-CiscoHostFiles'
            }
            "CiscoIOSXR"{
                Import-Module "$($GPathToScript)CiscoIOSXRConfigProcessingFunctions.ps1" -Force
                $processorName = 'Process-CiscoIOSXRHostFiles'
            }
            "CiscoSmallBusiness"{
                Import-Module "$($GPathToScript)CiscoSmallBusinessConfigProcessingFunctions.ps1" -Force
                $processorName = 'Process-CiscoSmallBusinessHostFiles'
            }
            "CiscoSmallBusinessLegacy"{
                # The legacy module reuses the current Small Business parsers wherever the two CLI
                # generations emit identical tables, so both files have to be in scope.
                Import-Module "$($GPathToScript)CiscoSmallBusinessConfigProcessingFunctions.ps1" -Force
                Import-Module "$($GPathToScript)OldCiscoSmallBusinessConfigProcessingFunctions.ps1" -Force
                $processorName = 'Process-OldCiscoSmallBusinessHostFiles'
            }
            "CiscoASA"{
                Import-Module "$($GPathToScript)CiscoASAConfigProcessingFunctions.ps1" -Force
                $processorName = 'Process-CiscoASAHostFiles'
            }
            "CheckPoint"{
                Import-Module "$($GPathToScript)CheckPointConfigProcessingFunctions.ps1" -Force
                $processorName = 'Process-CheckPointHostFiles'
            }
            "Junos"{
                Import-Module "$($GPathToScript)JunosConfigProcessingFunctions.ps1" -Force
                $processorName = 'Process-JunosHostFiles'
            }
            "PaloAlto"{
                Import-Module "$($GPathToScript)PaloAltoConfigProcessingFunctions.ps1" -Force
                $processorName = 'Process-PaloAltoHostFiles'
            }
            "Fortigate"{
                Import-Module "$($GPathToScript)FortigateConfigProcessingFunctions.ps1" -Force
                $processorName = 'Process-FortiGateHostFiles'
            }
            "AristaEOS"{
                Import-Module "$($GPathToScript)AristaConfigProcessingFunctions.ps1" -Force
                $processorName = 'Process-AristaHostFiles'
            }
            "ArubaOS-CX"{
                Import-Module "$($GPathToScript)ArubaConfigProcessingFunctions.ps1" -Force
                $processorName = 'Process-ArubaHostFiles'
            }
            default{
                $workerWarnings += "Device type for $($hostid.HOSTID) is unknown or unsupported. Skipping."
            }
        }

        if ($processorName) {
            $oldErrorPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Stop'
            try {
                $Device = & $processorName -hostid $hostid -ArrayOfObjects $null -WarningVariable +workerWarnings -WarningAction SilentlyContinue
            }
            finally { $ErrorActionPreference = $oldErrorPreference }
            if ($Device) { $Device.DeviceType = $hostid.DeviceType }
        }
        }
        catch {
            $capturePath = @($hostid.PSObject.Properties | Where-Object { $_.Name -like 'Show*' -and $_.Value } | ForEach-Object Value | Select-Object -First 1)
            $workerFailure = [pscustomobject]@{
                HostID = $hostid.HOSTID
                DeviceType = $hostid.DeviceType
                Parser = $processorName
                CapturePath = if ($capturePath.Count) { [string]$capturePath[0] } else { [string]$hostid.SourceDirectory }
                Message = $_.Exception.Message
                ScriptName = $_.InvocationInfo.ScriptName
                Line = $_.InvocationInfo.ScriptLineNumber
                Position = $_.InvocationInfo.PositionMessage
                StackTrace = $_.ScriptStackTrace
            }
        }
        [pscustomobject]@{
            HostID = $hostid.HOSTID
            CaptureGroupKey = $hostid.CaptureGroupKey
            Device = $Device
            Warnings = @($workerWarnings | ForEach-Object { [string]$_ })
            Failure = $workerFailure
        }

    } -ThrottleLimit $throttleLimit

    return , @($workerResults)
}

# Names the vendor behind each synthesized CDP and LLDP host from the OUI of the MAC address it was
# seen advertising, which for a neighbour we have no config for is the only identification available.
function Set-MTAutoDrawNeighborHostVendors {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][array]$CdpHosts,
        [AllowEmptyCollection()][array]$LldpHosts
    )

    Write-MTAutoDrawLog -Level Info -Phase Resolve -Message "Setting CDP and LLDP vendor type."
    foreach ($neighborHost in @($CdpHosts) + @($LldpHosts)) {
        Set-MacAddressVendor -HostObject $neighborHost -VendorMapping $GMacAddressToVendorMapping
    }
}
# Turns a directory of captures into the object model the drawing layer works from: parses every
# device in parallel, then runs the named resolve stages above, in order. Requires $GDirectory when
# -Files is not supplied. See ObjectFunctions.ps1 for the shape of the objects it returns.
function Start-ProcessingFiles(){
    param(
        $Files,
        $CaptureGroups,
        # Used only to compute elapsed on the flushed per-device diagnostics below. Defaulted rather
        # than mandatory so a caller that does not track a run start still works; the real run start
        # is always passed explicitly from AutoDraw.ps1.
        [datetime]$RunStartedAtUtc = [DateTime]::UtcNow
    )
    if ($null -eq $Files) {
        $Files = @(Get-ChildItem -LiteralPath $GDirectory -File -Recurse -Filter '*.txt')
    }
    $ArrayOfHostIDs = if ($null -ne $CaptureGroups) { @($CaptureGroups) } else { @(Create-FileHostObjects -Files $Files) }


    $perf = Start-MTAutoDrawPerf -Label "Parse: Invoke-MTAutoDrawParallelDispatch (all workers)"   # PERF
    $workerResults = Invoke-MTAutoDrawParallelDispatch -HostIDs $ArrayOfHostIDs
    Stop-MTAutoDrawPerf -Token $perf -Detail "$(@($ArrayOfHostIDs).Count) capture groups"

    Write-MTAutoDrawPhase -Phase Parse -Message "Parallel processing complete. Aggregating results..."

    $perf = Start-MTAutoDrawPerf -Label "Parse: sort and unpack worker envelopes"   # PERF
    $orderedWorkerResults = @($workerResults | Sort-Object CaptureGroupKey,HostID)
    $processedDevices = @($orderedWorkerResults | ForEach-Object Device | Where-Object { $_ })
    $global:GLastProcessingErrors = @($orderedWorkerResults | ForEach-Object Failure | Where-Object { $_ })
    Stop-MTAutoDrawPerf -Token $perf -Detail "$(@($processedDevices).Count) devices"

    $perf = Start-MTAutoDrawPerf -Label "Parse: Write-MTAutoDrawWorkerDiagnostics (flush per-device logs)"   # PERF
    Write-MTAutoDrawWorkerDiagnostics -Results $orderedWorkerResults -RunStartedAtUtc $RunStartedAtUtc
    Stop-MTAutoDrawPerf -Token $perf

    $perf = Start-MTAutoDrawPerf -Label "Resolve: Merge-MTAutoDrawWorkerResults"   # PERF
    $aggregated = Merge-MTAutoDrawWorkerResults -ProcessedDevices $processedDevices
    $ArrayOfObjects = $aggregated.Devices
    $ArrayOfNetworks = $aggregated.Networks
    Stop-MTAutoDrawPerf -Token $perf -Detail "$(@($ArrayOfObjects).Count) devices, $(@($ArrayOfNetworks).Count) networks"

    Write-MTAutoDrawLog -Level Info -Phase Resolve -Message "Processing ARP entries."
    #Create an array of ip ARP entries. This will be used when drawing layer 3 diagrams.
    $perf = Start-MTAutoDrawPerf -Label "Resolve: collect and sort ARP entries"   # PERF
    $ArrayOfIPApr=$ArrayOfObjects | % {$_.IPArpEntries } | sort -Unique mac,ipaddress,interface
    Stop-MTAutoDrawPerf -Token $perf -Detail "$(@($ArrayOfIPApr).Count) ARP entries"

    Write-MTAutoDrawLog -Level Debug -Phase Resolve -Message "Processing Check Point cluster IP addresses, if any."
    $perf = Start-MTAutoDrawPerf -Label "Resolve: Update-MTAutoDrawCheckPointVirtualInterfaces"   # PERF
    Update-MTAutoDrawCheckPointVirtualInterfaces -Devices $ArrayOfObjects -ArpEntries $ArrayOfIPApr
    Stop-MTAutoDrawPerf -Token $perf

    $perf = Start-MTAutoDrawPerf -Label "Resolve: Update-MTAutoDrawInterfaceRoutes"   # PERF
    Update-MTAutoDrawInterfaceRoutes -Devices $ArrayOfObjects
    Stop-MTAutoDrawPerf -Token $perf

    $perf = Start-MTAutoDrawPerf -Label "Resolve: Set-MTAutoDrawNetworkPresentation"   # PERF
    $ArrayOfNetworks = Set-MTAutoDrawNetworkPresentation -Networks $ArrayOfNetworks -Devices $ArrayOfObjects
    Stop-MTAutoDrawPerf -Token $perf -Detail "$(@($ArrayOfNetworks).Count) networks"

    $perf = Start-MTAutoDrawPerf -Label "Resolve: Add-MTAutoDrawNetworkArpEntries"   # PERF
    $ArrayOfNetworks = Add-MTAutoDrawNetworkArpEntries -Networks $ArrayOfNetworks -Devices $ArrayOfObjects -ArpEntries $ArrayOfIPApr
    Stop-MTAutoDrawPerf -Token $perf

    Write-MTAutoDrawLog -Level Info -Phase Resolve -Message "Linking configured CDP and LLDP neighbours with normalized and reciprocal evidence..."

    $perf = Start-MTAutoDrawPerf -Label "Resolve: Update-MTAutoDrawSmallBusinessChassisMac"   # PERF
    Update-MTAutoDrawSmallBusinessChassisMac -Devices $ArrayOfObjects
    Stop-MTAutoDrawPerf -Token $perf

    $perf = Start-MTAutoDrawPerf -Label "Resolve: Resolve-MTAutoDrawConfiguredNeighborLinks (TOTAL)"   # PERF
    Resolve-MTAutoDrawConfiguredNeighborLinks -Devices $ArrayOfObjects
    Stop-MTAutoDrawPerf -Token $perf

    $perf = Start-MTAutoDrawPerf -Label "Resolve: New-MTAutoDrawUnconfiguredCdpHosts"   # PERF
    $ArrayOfCDPDeviceIDs = New-MTAutoDrawUnconfiguredCdpHosts -Devices $ArrayOfObjects
    Stop-MTAutoDrawPerf -Token $perf -Detail "$(@($ArrayOfCDPDeviceIDs).Count) hosts"

    $perf = Start-MTAutoDrawPerf -Label "Resolve: New-MTAutoDrawUnconfiguredLldpHosts"   # PERF
    $ArrayOfLLDPDeviceIDs = New-MTAutoDrawUnconfiguredLldpHosts -Devices $ArrayOfObjects
    Stop-MTAutoDrawPerf -Token $perf -Detail "$(@($ArrayOfLLDPDeviceIDs).Count) hosts"

    $perf = Start-MTAutoDrawPerf -Label "Resolve: Resolve-MTAutoDrawSpanningTreeRoots"   # PERF
    Resolve-MTAutoDrawSpanningTreeRoots -Devices $ArrayOfObjects
    Stop-MTAutoDrawPerf -Token $perf
    $perf = Start-MTAutoDrawPerf -Label "Resolve: Resolve-MTAutoDrawGatewayLinks"   # PERF
    $ArrayofGatewayHosts = Resolve-MTAutoDrawGatewayLinks -Devices $ArrayOfObjects -CdpHosts $ArrayOfCDPDeviceIDs -LldpHosts $ArrayOfLLDPDeviceIDs
    Stop-MTAutoDrawPerf -Token $perf -Detail "$(@($ArrayofGatewayHosts).Count) gateway hosts"
    $perf = Start-MTAutoDrawPerf -Label "Resolve: Resolve-MTAutoDrawStandbyPartners"   # PERF
    Resolve-MTAutoDrawStandbyPartners -Devices $ArrayOfObjects -GatewayHosts $ArrayofGatewayHosts
    Stop-MTAutoDrawPerf -Token $perf
    $perf = Start-MTAutoDrawPerf -Label "Resolve: Set-MTAutoDrawNeighborHostVendors"   # PERF
    Set-MTAutoDrawNeighborHostVendors -CdpHosts $ArrayOfCDPDeviceIDs -LldpHosts $ArrayOfLLDPDeviceIDs
    Stop-MTAutoDrawPerf -Token $perf

    return [pscustomobject]@{
        Networks     = $ArrayOfNetworks
        Devices      = $ArrayOfObjects
        CdpHosts     = $ArrayOfCDPDeviceIDs
        LldpHosts    = $ArrayOfLLDPDeviceIDs
        ArpEntries   = $ArrayOfIPApr
        GatewayHosts = $ArrayofGatewayHosts
    }
}




