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

# MTAutoDraw - Neighbor resolution
#
# Deciding which neighbour sighting (CDP/LLDP/ARP/MAC-table) refers to which captured device: name
# and interface-identity normalization, MAC-based matching, flooded-segment suppression, and the
# reciprocal-evidence and configured-link resolution that turn raw sightings into a topology. This
# is the hardest correctness logic in the repository - kept in one file so it can be read whole.
#
# Depends on: Logging.ps1 (Write-MTAutoDrawLog)
# Loaded by:  AutoDraw.ps1 ($GLibrariesToLoad)
# Resolves a configured neighbour name (hostname, FQDN, or IP) to an exact matching device hostname from the known device set. Returns $null for bare IPs or when no match is found.
function Resolve-ConfiguredNeighborName {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$NeighborName,
        [Parameter(Mandatory = $true)]$Devices,
        # A resolution index from New-NeighborResolutionIndex. It is optional for external callers,
        # but repository callers pass it because this lookup sits inside reciprocal-evidence loops;
        # the hostname hashtable avoids repeated scans of the complete device array.
        $Index = $null
    )

    if ([string]::IsNullOrWhiteSpace($NeighborName)) { return $null }
    $candidate = (($NeighborName -split '\(')[0]).Trim().TrimEnd('.')

    # Hostnames are unique across $Devices by the time anything calls this - Start-ProcessingFiles
    # drops same-hostname duplicates before resolution - so the index's last-wins insertion and the
    # scan's first-wins Select-Object cannot disagree about which device a name refers to.
    if ($Index -and $Index.Hostname) {
        $exactDevice = $null
        $key = $candidate.ToLowerInvariant()
        if ($Index.Hostname.ContainsKey($key)) { $exactDevice = $Index.Hostname[$key] }
        if ($exactDevice) { return $exactDevice.hostname }

        $isIpAddress = $null
        if ([System.Net.IPAddress]::TryParse($candidate, [ref]$isIpAddress)) { return $null }
        if ($candidate.Contains('.')) {
            $shortKey = $candidate.Split('.')[0].ToLowerInvariant()
            if ($Index.Hostname.ContainsKey($shortKey)) { return $Index.Hostname[$shortKey].hostname }
        }
        return $null
    }

    $exact = $Devices | Where-Object { $_.hostname -ieq $candidate } | Select-Object -First 1
    if ($exact) { return $exact.hostname }

    $isIpAddress = $null
    if ([System.Net.IPAddress]::TryParse($candidate, [ref]$isIpAddress)) { return $null }
    if ($candidate.Contains('.')) {
        $shortName = $candidate.Split('.')[0]
        $shortMatch = $Devices | Where-Object { $_.hostname -ieq $shortName } | Select-Object -First 1
        if ($shortMatch) { return $shortMatch.hostname }
    }
    return $null
}

# Normalises an interface name (strips trailing '.0', expands shorthand, collapses whitespace, lowercases) into a canonical key for cross-vendor matching.
function ConvertTo-NormalizedInterfaceIdentity {
    [CmdletBinding()]
    param([AllowNull()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $normalized = ($Name.Trim() -replace '\.0$', '')
    $normalized = Replace-InterfaceShortName -String $normalized
    return (($normalized -replace '\s+', '')).ToLowerInvariant()
}

# Finds the single interface on a device whose normalised name or description matches one of the supplied interface names. Returns that interface object or $null.
function Find-NeighborInterfaceOnDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][string[]]$Names,
        $Index = $null
    )

    $keys = @($Names | ForEach-Object { ConvertTo-NormalizedInterfaceIdentity $_ } | Where-Object { $_ } | Select-Object -Unique)
    $deviceKey = ([string]$Device.hostname).ToLowerInvariant()
    foreach ($key in $keys) {
        $match = if ($Index -and $Index.Interface.ContainsKey($deviceKey) -and $Index.Interface[$deviceKey].ContainsKey($key)) {
            @($Index.Interface[$deviceKey][$key])
        } else {
            @($Device.interfaces | Where-Object {
                (ConvertTo-NormalizedInterfaceIdentity $_.Interface) -eq $key -or
                (ConvertTo-NormalizedInterfaceIdentity $_.Description) -eq $key
            })
        }
        if ($match.Count -eq 1) { return $match[0] }
    }
    return $null
}

# Normalises a MAC address by stripping separators and lowercasing. Returns the 12-hex-digit string, or $null when the input is not a valid MAC.
function ConvertTo-NormalizedMacIdentity {
    [CmdletBinding()]
    param([AllowNull()][string]$Mac)

    if ([string]::IsNullOrWhiteSpace($Mac)) { return $null }
    $normalized = ([string]$Mac).Trim().ToLowerInvariant() -replace '[^0-9a-f]', ''
    if ($normalized.Length -ne 12) { return $null }
    return $normalized
}

# True when two MAC addresses look like they came off the same chassis: identical OUI, and NIC
# halves within $Threshold of each other. A switch numbers its ports consecutively from a base
# address, so a neighbour advertising a chassis MAC near one we already know is very likely it.
function Test-MacProximity {
    param(
        [string]$Mac1,
        [string]$Mac2,
        [int]$Threshold = 256
    )
    $normMac1 = $Mac1.ToLower() -replace "[\:\-\.]"; $normMac2 = $Mac2.ToLower() -replace "[\:\-\.]"

    if ($normMac1.Length -ne 12 -or $normMac2.Length -ne 12) { return $false }
    if ($normMac1.Substring(0, 6) -ne $normMac2.Substring(0, 6)) { return $false }
    try {
        $val1 = [System.Convert]::ToInt64($normMac1.Substring(6, 6), 16)
        $val2 = [System.Convert]::ToInt64($normMac2.Substring(6, 6), 16)
        return [Math]::Abs($val1 - $val2) -le $Threshold
    } catch { return $false }
}

# Collects the set of known MAC addresses for a device (version, interface, and management MACs), normalised and de-duplicated.
function Get-DeviceKnownMacAddress {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Device)

    $macs = @($Device.Version.MacAddressArray) + @($Device.interfaces.macaddress) + @($Device.ManagementMacAddress)
    return @($macs | ForEach-Object { ConvertTo-NormalizedMacIdentity $_ } | Where-Object { $_ } | Select-Object -Unique)
}

# Built once per run. The neighbour loop is O(devices x neighbours), so re-deriving these
# lookups per neighbour is what made large sites slow.
function New-NeighborResolutionIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Devices)

    $hostnameIndex = @{}
    $addressIndex = @{}
    $macIndex = @{}
    $addressDeviceNames = @{}
    $interfaceIndex = @{}
    $ambiguousAddresses = [System.Collections.Generic.HashSet[string]]::new()
    $ambiguousMacs = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($device in @($Devices)) {
        if (-not $device) { continue }
        $hostname = [string]$device.hostname
        if ($hostname) { $hostnameIndex[$hostname.ToLowerInvariant()] = $device }

        $addresses = @($device.ManagementIP) + @($device.ArrayOfIPAddresses)
        foreach ($interface in @($device.interfaces)) {
            $addresses += @($interface.IPAddress) + @($interface.ClusterIP) + @($interface.StandbyIP) + @($interface.SecondaryIPAddress)
        }
        foreach ($address in @($addresses | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)) {
            if (-not $addressDeviceNames.ContainsKey($address)) {
                $addressDeviceNames[$address] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            }
            [void]$addressDeviceNames[$address].Add($hostname)
            if ($addressIndex.ContainsKey($address)) {
                if ($addressIndex[$address].hostname -ine $hostname) { [void]$ambiguousAddresses.Add($address) }
            } else { $addressIndex[$address] = $device }
        }
        foreach ($mac in (Get-DeviceKnownMacAddress -Device $device)) {
            if ($macIndex.ContainsKey($mac)) {
                if ($macIndex[$mac].hostname -ine $hostname) { [void]$ambiguousMacs.Add($mac) }
            } else { $macIndex[$mac] = $device }
        }

        $deviceInterfaces = @{}
        foreach ($interface in @($device.interfaces | Where-Object { $_ })) {
            $identities = @(
                ConvertTo-NormalizedInterfaceIdentity $interface.Interface
                ConvertTo-NormalizedInterfaceIdentity $interface.Description
            ) | Where-Object { $_ } | Select-Object -Unique
            foreach ($identity in $identities) {
                if (-not $deviceInterfaces.ContainsKey($identity)) {
                    $deviceInterfaces[$identity] = [System.Collections.Generic.List[object]]::new()
                }
                $deviceInterfaces[$identity].Add($interface)
            }
        }
        if ($hostname) { $interfaceIndex[$hostname.ToLowerInvariant()] = $deviceInterfaces }
    }

    # A shared address or MAC (HSRP/VRRP/cluster/stack) cannot identify one device, so it must
    # not be used as evidence at all.
    foreach ($key in $ambiguousAddresses) { [void]$addressIndex.Remove($key) }
    foreach ($key in $ambiguousMacs) { [void]$macIndex.Remove($key) }

    $index = [pscustomobject]@{
        Devices  = @($Devices)
        Hostname = $hostnameIndex
        Address  = $addressIndex
        Mac      = $macIndex
        Interface = $interfaceIndex
        Reciprocal = @{}
    }

    # Reverse neighbour lookup: target hostname + advertised remote port -> sightings that point
    # there. Find-ReciprocalNeighborEvidence can now read one bucket instead of rescanning the site.
    foreach ($candidate in @($Devices | Where-Object { $_ })) {
        foreach ($neighbor in @($candidate.CDPNeighbors) + @($candidate.LLDPNeighbors)) {
            if (-not $neighbor) { continue }
            $targetNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($name in @($neighbor.SystemName, $neighbor.DeviceID, $neighbor.Hostname) | Where-Object { $_ }) {
                $resolved = Resolve-ConfiguredNeighborName -NeighborName ([string]$name) -Devices $index.Devices -Index $index
                if ($resolved) { [void]$targetNames.Add(([string]$resolved).ToLowerInvariant()) }
            }
            foreach ($address in @($neighbor.ManagementIP, $neighbor.InterfaceIPAddresses) | Where-Object { $_ }) {
                $addressKey = ([string]$address).Trim()
                if (-not $addressDeviceNames.ContainsKey($addressKey)) { continue }
                foreach ($targetName in $addressDeviceNames[$addressKey]) { [void]$targetNames.Add($targetName.ToLowerInvariant()) }
            }
            if ($targetNames.Count -eq 0) { continue }

            $remoteKeys = @($neighbor.InterfaceRemoteDevice, $neighbor.NeighborInterfaceDescription, $neighbor.PortID) |
                ForEach-Object { ConvertTo-NormalizedInterfaceIdentity $_ } | Where-Object { $_ } | Select-Object -Unique
            foreach ($targetName in $targetNames) {
                foreach ($remoteKey in $remoteKeys) {
                    $lookupKey = "$targetName|$remoteKey"
                    if (-not $index.Reciprocal.ContainsKey($lookupKey)) {
                        $index.Reciprocal[$lookupKey] = [System.Collections.Generic.List[object]]::new()
                    }
                    $index.Reciprocal[$lookupKey].Add([pscustomobject]@{ Device = $candidate; Neighbor = $neighbor })
                }
            }
        }
    }
    return $index
}

# Resolves a neighbour device by matching candidate MAC addresses against a resolution index. Returns {Device, Exact=$true} for the first match, else $null.
function Resolve-NeighborDeviceByMac {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Index,[AllowNull()][string[]]$Candidates)

    # Exact matches only. Test-MacProximity is fine for corroborating a device we already
    # identified, but it cannot establish identity: switches bought together have adjacent MACs,
    # so proximity happily resolves an uncaptured neighbour onto the device sitting next to it in
    # the rack - two switches from one purchase order are indistinguishable to it.
    foreach ($candidate in @($Candidates | Where-Object { $_ })) {
        $key = ConvertTo-NormalizedMacIdentity $candidate
        if ($key -and $Index.Mac.ContainsKey($key)) {
            return [pscustomobject]@{ Device = $Index.Mac[$key]; Exact = $true }
        }
    }
    return $null
}

# $true / $false when the capture tells us, $null when the state is unknown.
function Test-InterfaceIsOperational {
    [CmdletBinding()]
    param($Interface)

    if (-not $Interface) { return $null }
    if ($Interface.shutdown -eq $true) { return $false }
    $values = @([string]$Interface.IntStatus, [string]$Interface.INTProtocolStatus) | Where-Object { $_ }
    if (@($values).Count -eq 0) { return $null }
    foreach ($value in $values) {
        if ($value -match '(?i)(down|notconnect|disabled|absent|err)') { return $false }
    }
    foreach ($value in $values) {
        if ($value -match '(?i)(up|connected)') { return $true }
    }
    return $null
}

# Finds a candidate device whose CDP/LLDP neighbour list points back at the source device, establishing a reciprocal link. Returns the reciprocal neighbour record or $null.
function Find-ReciprocalNeighborEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$SourceDevice,
        [Parameter(Mandatory = $true)]$Neighbor,
        [Parameter(Mandatory = $true)]$Index,
        [Parameter(Mandatory = $true)]$CandidateDevices
    )

    $sourceLocalKey = ConvertTo-NormalizedInterfaceIdentity $Neighbor.InterfaceLocalDevice
    if (-not $sourceLocalKey) { return $null }

    $lookupKey = '{0}|{1}' -f ([string]$SourceDevice.hostname).ToLowerInvariant(), $sourceLocalKey
    if (-not $Index.Reciprocal.ContainsKey($lookupKey)) { return $null }
    $candidateNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @($CandidateDevices | Where-Object { $_ })) { [void]$candidateNames.Add([string]$candidate.hostname) }
    foreach ($sighting in $Index.Reciprocal[$lookupKey]) {
        if (-not $candidateNames.Contains([string]$sighting.Device.hostname) -or $sighting.Device.hostname -ieq $SourceDevice.hostname) { continue }
        $candidateInterface = Find-NeighborInterfaceOnDevice -Device $sighting.Device -Names @($sighting.Neighbor.InterfaceLocalDevice) -Index $Index
        if ($candidateInterface) {
            return [pscustomobject]@{ Device = $sighting.Device; Neighbor = $sighting.Neighbor; Interface = $candidateInterface }
        }
    }
    return $null
}

# Identity phase only: which configured device is this neighbour, ignoring ports. Shared by the
# link resolver and by the flooded-segment detector.
function Resolve-NeighborTargetDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Neighbor,
        [ValidateSet('CDP','LLDP')][string]$Protocol,
        [Parameter(Mandatory = $true)]$Index
    )

    $nameValues = if ($Protocol -eq 'CDP') {
        @($Neighbor.SystemName, $Neighbor.DeviceID)
    } else {
        @($Neighbor.Hostname)
    }
    # CDP carries the neighbour address in InterfaceIPAddresses; only LLDP populates ManagementIP.
    $addressValues = @($Neighbor.ManagementIP, $Neighbor.InterfaceIPAddresses)
    $macValues = @($Neighbor.ChassisID, $Neighbor.DeviceID, $Neighbor.Hostname)

    foreach ($name in ($nameValues | Where-Object { $_ })) {
        $resolvedName = Resolve-ConfiguredNeighborName -NeighborName ([string]$name) -Devices $Index.Devices -Index $Index
        if ($resolvedName) {
            $device = $Index.Hostname[$resolvedName.ToLowerInvariant()]
            if ($device) { return [pscustomobject]@{ Device = $device; Method = 'Hostname' } }
        }
    }

    foreach ($address in ($addressValues | Where-Object { $_ })) {
        $key = ([string]$address).Trim()
        if ($key -and $Index.Address.ContainsKey($key)) {
            return [pscustomobject]@{ Device = $Index.Address[$key]; Method = 'Management IP' }
        }
    }

    # SG/CBS switches identify neighbours only by MAC (CDP Device-ID, LLDP Chassis ID).
    $macMatch = Resolve-NeighborDeviceByMac -Index $Index -Candidates $macValues
    if ($macMatch) { return [pscustomobject]@{ Device = $macMatch.Device; Method = 'Chassis MAC' } }
    return $null
}

# Resolves a configured CDP/LLDP neighbour to a concrete target device + interface using the resolution index. Returns a structured {TargetDevice, TargetInterface, Method, ...} link record.
function Resolve-ConfiguredNeighborLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$SourceDevice,
        [Parameter(Mandatory = $true)]$Neighbor,
        [Parameter(Mandatory = $true)]$Devices,
        [ValidateSet('CDP','LLDP')][string]$Protocol,
        $Index
    )

    if (-not $Index) { $Index = New-NeighborResolutionIndex -Devices $Devices }

    $remoteNames = @($Neighbor.InterfaceRemoteDevice, $Neighbor.NeighborInterfaceDescription, $Neighbor.PortID)
    $targetInterface = $null
    $method = $null

    $perfTick = if ($global:GPerfTiming) { [System.Diagnostics.Stopwatch]::GetTimestamp() } else { 0 }   # PERF
    $identity = Resolve-NeighborTargetDevice -Neighbor $Neighbor -Protocol $Protocol -Index $Index
    if ($global:GPerfTiming) { Add-MTAutoDrawPerf -Label "Resolve:       Resolve-NeighborTargetDevice" -Milliseconds ((([System.Diagnostics.Stopwatch]::GetTimestamp() - $perfTick) * 1000.0) / [System.Diagnostics.Stopwatch]::Frequency) }   # PERF
    $targetDevice = if ($identity) { $identity.Device } else { $null }
    if ($identity) { $method = $identity.Method }

    if ($targetDevice -and $targetDevice.hostname -ieq $SourceDevice.hostname) {
        return [pscustomobject]@{
            TargetDevice = $null; TargetInterface = $null; MatchMethod = 'Ignored self/management neighbor'
            MatchConfidence = 'Ignored'; IsSelf = $true; Reciprocal = $false; AmbiguousPort = $false
        }
    }

    if ($targetDevice) {
        $perfTick2 = if ($global:GPerfTiming) { [System.Diagnostics.Stopwatch]::GetTimestamp() } else { 0 }   # PERF
        $targetInterface = Find-NeighborInterfaceOnDevice -Device $targetDevice -Names $remoteNames -Index $Index
        if ($global:GPerfTiming) { Add-MTAutoDrawPerf -Label "Resolve:       Find-NeighborInterfaceOnDevice" -Milliseconds ((([System.Diagnostics.Stopwatch]::GetTimestamp() - $perfTick2) * 1000.0) / [System.Diagnostics.Stopwatch]::Frequency) }   # PERF
        if ($targetInterface) { $method += ' + interface' }
    }

    $ambiguousPort = $false
    if ($targetDevice -and -not $targetInterface -and $Neighbor.NeighborInterfaceDescription -and $Neighbor.ChassisID) {
        $perfTick5 = if ($global:GPerfTiming) { [System.Diagnostics.Stopwatch]::GetTimestamp() } else { 0 }   # PERF
        $descriptionKey = ConvertTo-NormalizedInterfaceIdentity $Neighbor.NeighborInterfaceDescription
        $descriptionMatches = @($targetDevice.interfaces | Where-Object { (ConvertTo-NormalizedInterfaceIdentity $_.Description) -eq $descriptionKey })
        $knownDeviceMacs = Get-DeviceKnownMacAddress -Device $targetDevice
        $chassisMatchesDevice = @($knownDeviceMacs | Where-Object { Test-MacProximity -Mac1 $Neighbor.ChassisID -Mac2 $_ }).Count -gt 0
        if ($descriptionMatches.Count -gt 0 -and $chassisMatchesDevice) {
            # A shared port description (every uplink described "NETWORK-TRUNK") cannot single out a
            # port. Narrow by operational state and by ports no other link has already claimed,
            # rather than always taking the lowest-numbered one - that collapsed parallel uplinks
            # from two different cores onto the same target port.
            $candidates = @($descriptionMatches)
            $operational = @($candidates | Where-Object { (Test-InterfaceIsOperational -Interface $_) -eq $true })
            if ($operational.Count -gt 0) { $candidates = $operational }
            $unclaimed = @($candidates | Where-Object { -not $_.IsLinkedToByCDPorLLDP })
            if ($unclaimed.Count -gt 0) { $candidates = $unclaimed }

            if ($candidates.Count -ge 1) {
                $targetInterface = $candidates | Sort-Object Interface | Select-Object -First 1
                $method += ' + chassis/description fallback'
                if ($candidates.Count -gt 1) { $ambiguousPort = $true; $method += ' + ambiguous port' }
            }
        }
        if ($global:GPerfTiming) { Add-MTAutoDrawPerf -Label "Resolve:       chassis/description fallback block" -Milliseconds ((([System.Diagnostics.Stopwatch]::GetTimestamp() - $perfTick5) * 1000.0) / [System.Diagnostics.Stopwatch]::Frequency) }   # PERF
    }

    # An exact remote-port match is the strongest evidence we have. Reciprocal evidence may
    # confirm it (raising confidence) but must never replace it.
    $reciprocal = $null
    $hasDefiniteInterface = [bool]$targetInterface -and -not $ambiguousPort
    $advertisesHostname = $false
    $advertisedNames = if ($Protocol -eq 'CDP') { @($Neighbor.SystemName, $Neighbor.DeviceID) } else { @($Neighbor.Hostname) }
    foreach ($name in ($advertisedNames | Where-Object { $_ })) {
        if (-not (ConvertTo-NormalizedMacIdentity $name)) { $advertisesHostname = $true; break }
    }
    if ($targetDevice) {
        $perfTick3 = if ($global:GPerfTiming) { [System.Diagnostics.Stopwatch]::GetTimestamp() } else { 0 }   # PERF
        $reciprocal = Find-ReciprocalNeighborEvidence -SourceDevice $SourceDevice -Neighbor $Neighbor -Index $Index -CandidateDevices @($targetDevice)
        if ($global:GPerfTiming) { Add-MTAutoDrawPerf -Label "Resolve:       Find-ReciprocalNeighborEvidence (1 candidate device)" -Milliseconds ((([System.Diagnostics.Stopwatch]::GetTimestamp() - $perfTick3) * 1000.0) / [System.Diagnostics.Stopwatch]::Frequency) }   # PERF
    }
    elseif (-not $advertisesHostname) {
        # Only a MAC-only neighbour may be identified purely by who points back at us. A neighbour
        # that advertised a real name we cannot place is a genuine third-party device.
        $perfTick4 = if ($global:GPerfTiming) { [System.Diagnostics.Stopwatch]::GetTimestamp() } else { 0 }   # PERF
        $reciprocal = Find-ReciprocalNeighborEvidence -SourceDevice $SourceDevice -Neighbor $Neighbor -Index $Index -CandidateDevices $Index.Devices
        if ($global:GPerfTiming) { Add-MTAutoDrawPerf -Label "Resolve:       Find-ReciprocalNeighborEvidence (ALL devices)" -Milliseconds ((([System.Diagnostics.Stopwatch]::GetTimestamp() - $perfTick4) * 1000.0) / [System.Diagnostics.Stopwatch]::Frequency) }   # PERF
    }

    if ($reciprocal) {
        if (-not $targetDevice) { $targetDevice = $reciprocal.Device }
        if ($reciprocal.Device.hostname -ieq $targetDevice.hostname) {
            if (-not $hasDefiniteInterface) {
                $targetInterface = $reciprocal.Interface
                if ($ambiguousPort) { $method = $method -replace ' \+ ambiguous port', ''; $ambiguousPort = $false }
            }
            $method = if ($method) { "$method + reciprocal $Protocol" } else { "Reciprocal $Protocol" }
        }
        else { $reciprocal = $null }
    }

    if ($targetDevice -and $targetDevice.hostname -ieq $SourceDevice.hostname) {
        return [pscustomobject]@{
            TargetDevice = $null; TargetInterface = $null; MatchMethod = 'Ignored self/management neighbor'
            MatchConfidence = 'Ignored'; IsSelf = $true; Reciprocal = $false; AmbiguousPort = $false
        }
    }

    if (-not $targetDevice -or -not $targetInterface) {
        return [pscustomobject]@{
            TargetDevice = $targetDevice; TargetInterface = $null; MatchMethod = $(if ($method) { $method } else { 'None' })
            MatchConfidence = 'None'; IsSelf = $false; Reciprocal = $false; AmbiguousPort = $false
        }
    }

    $macProximate = $false
    if ($Neighbor.ChassisID) {
        foreach ($mac in (Get-DeviceKnownMacAddress -Device $targetDevice)) {
            if (Test-MacProximity -Mac1 $Neighbor.ChassisID -Mac2 $mac) { $macProximate = $true; break }
        }
    }
    $confidence = if ($ambiguousPort) { 'Low' }
        elseif ($reciprocal -or $macProximate) { 'High' }
        elseif ($method -match '^Hostname \+ interface') { 'High' }
        else { 'Medium' }

    return [pscustomobject]@{
        TargetDevice = $targetDevice; TargetInterface = $targetInterface; MatchMethod = $method
        MatchConfidence = $confidence; IsSelf = $false; Reciprocal = [bool]$reciprocal; AmbiguousPort = $ambiguousPort
    }
}

# A physical port has exactly one physical neighbour. When a port reports several different
# configured devices - or reports the source device itself - the protocol frames are being flooded
# across a transparent segment rather than terminating on the link. Junos does not consume CDP, so
# every Cisco switch hanging off a Junos core hears every other one and the resulting entries would
# otherwise be drawn as a full mesh of links that do not exist.
function Set-FloodedNeighborEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Devices,
        [Parameter(Mandatory = $true)]$Index,
        [int]$MaxDevicesPerPort = 1
    )

    $suppressed = 0
    foreach ($device in @($Devices)) {
        if (-not $device) { continue }
        $ports = @{}
        foreach ($protocol in @('CDP','LLDP')) {
            $neighbors = if ($protocol -eq 'CDP') { @($device.CDPNeighbors) } else { @($device.LLDPNeighbors) }
            foreach ($neighbor in $neighbors) {
                if (-not $neighbor -or $neighbor.Ignored) { continue }
                $portKey = ConvertTo-NormalizedInterfaceIdentity $neighbor.InterfaceLocalDevice
                if (-not $portKey) { continue }
                if (-not $ports.ContainsKey($portKey)) {
                    $ports[$portKey] = [pscustomobject]@{
                        Entries     = [System.Collections.Generic.List[object]]::new()
                        Targets     = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                        CdpTargets  = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                        LldpTargets = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                        SawSelf     = $false
                    }
                }
                $slot = $ports[$portKey]
                $identity = Resolve-NeighborTargetDevice -Neighbor $neighbor -Protocol $protocol -Index $Index
                $targetName = if ($identity) { [string]$identity.Device.hostname } else { $null }
                $isSelf = [bool]($targetName -and $targetName -ieq [string]$device.hostname)
                if ($isSelf) { $slot.SawSelf = $true }
                elseif ($targetName) {
                    [void]$slot.Targets.Add($targetName)
                    if ($protocol -eq 'CDP') { [void]$slot.CdpTargets.Add($targetName) } else { [void]$slot.LldpTargets.Add($targetName) }
                }
                $slot.Entries.Add([pscustomobject]@{ Neighbor = $neighbor; Protocol = $protocol; Target = $targetName; IsSelf = $isSelf })
            }
        }

        foreach ($portKey in $ports.Keys) {
            $slot = $ports[$portKey]
            # The two protocols observing the same port should name the same neighbour. When they
            # disagree, CDP is the one that travelled: a device that does not consume CDP forwards
            # it, while LLDP is consumed hop-by-hop by every vendor in these captures. This catches
            # a port that heard exactly one foreign CDP sighting, where counting devices cannot.
            $protocolsDisagree = $slot.CdpTargets.Count -gt 0 -and $slot.LldpTargets.Count -gt 0 -and
                @($slot.CdpTargets | Where-Object { -not $slot.LldpTargets.Contains($_) }).Count -gt 0

            # Seeing only yourself is a local cable loop (Junos me0 patched into the front panel),
            # which the self-neighbour path already handles. Seeing yourself *and* someone else, or
            # several different devices, means frames are crossing a shared segment.
            $isFlooded = ($slot.Targets.Count -gt $MaxDevicesPerPort) -or ($slot.SawSelf -and $slot.Targets.Count -ge 1) -or $protocolsDisagree
            if (-not $isFlooded) { continue }

            # LLDP is consumed hop-by-hop by every vendor in these captures, so an LLDP sighting on a
            # flooded port is the real adjacency even when its chassis ID only resolves later via
            # reciprocal evidence. With no LLDP the far side is only knowable from the other
            # device's own capture, so claim nothing here.
            $lldpEntries = @($slot.Entries | Where-Object { $_.Protocol -eq 'LLDP' -and -not $_.IsSelf })
            $keep = @($lldpEntries | Where-Object { $_.Target }) | Select-Object -First 1
            if (-not $keep) { $keep = $lldpEntries | Select-Object -First 1 }

            foreach ($entry in $slot.Entries) {
                if ($entry.IsSelf) { continue }
                if ($keep -and [object]::ReferenceEquals($entry, $keep)) { continue }
                $entry.Neighbor.Ignored = $true
                $entry.Neighbor.IgnoreReason = 'Flooded CDP/LLDP on shared segment'
                $entry.Neighbor.MatchMethod = 'Ignored flooded segment'
                $entry.Neighbor.MatchConfidence = 'Ignored'
                $entry.Neighbor.PartnerEthernetInterface = $null
                $suppressed++
            }
            $reason = if ($protocolsDisagree) {
                "CDP says $(($slot.CdpTargets) -join '/'), LLDP says $(($slot.LldpTargets) -join '/')"
            } else {
                "$($slot.Targets.Count) distinct devices$(if($slot.SawSelf){' plus self'})"
            }
            $kept = if ($keep) { "LLDP -> $(if($keep.Target){$keep.Target}else{'(resolved later)'})" } else { 'nothing' }
            Write-MTAutoDrawLog -Level Warn -Phase Resolve -Message "Flooded segment on $($device.hostname)/$portKey ($reason); kept $kept."
        }
    }
    return $suppressed
}
