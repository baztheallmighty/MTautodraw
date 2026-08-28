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

# MTAutoDraw - Parser runtime
#
# The contract a capture on disk follows to become a device in memory: file-readable guards, the
# MTAutoDraw-Standard v1 reader scaffolding described in
# PARSER_STANDARD.md, and the shared field-normalization helpers (regex groups, MAC/IPv4 formats)
# every vendor reader calls into. Nothing here knows about the .drawio document, layout, or export -
# only how a raw capture becomes normalized device/interface/network data.
#
# Depends on: Logging.ps1 (Write-MTAutoDrawLog, Write-MTAutoDrawDiagnostic, Test-FileHasValidData)
# Loaded by:  AutoDraw.ps1 ($GLibrariesToLoad); StartProcessingConfig.ps1 (parallel workers)
#
# This function iterates through a device's routes. If a route is local, connected, or direct
# and is missing an interface, it attempts to find the correct egress interface by matching
# the route's destination network with the configured interface subnets.
#
function Update-LocalRoutesWithInterfaces {
    param (
        [parameter(Mandatory=$true)]
        [PSObject]$device
    )

    # Ensure we have the necessary data to proceed.
    if (-not $device.RoutingTable -or -not $device.interfaces) {
        Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $device -Message "Skipping local route update; routing table or interfaces not found."
        return $device
    }

    # Filter for interfaces that have a network address (CIDR) for efficient searching.
    $routableInterfaces = @($device.interfaces | Where-Object {
        [string]$_.Cidr -match '^\d{1,3}(?:\.\d{1,3}){3}/(?:[0-9]|[12][0-9]|3[0-2])$'
    })

    if ($routableInterfaces.Count -eq 0) {
        Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $device -Message "Skipping local route update; no routable interfaces with CIDR found."
        return $device
    }

    # Iterate directly through each route that needs an interface assigned.
    # Changes to $route will modify the object within $device.RoutingTable.
    foreach ($route in $device.RoutingTable | Where-Object {
        ('connect','host','local', 'connected', 'direct' -contains $_.RouteProtocol) -and [string]::IsNullOrEmpty($_.interface)
    }) {
        # The destination subnet of the route we need to match.
        $destinationSubnet = $route.Subnet
        if ([string]$destinationSubnet -notmatch '^\d{1,3}(?:\.\d{1,3}){3}/(?:[0-9]|[12][0-9]|3[0-2])$') {
            Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $device -Message "Skipping local route interface lookup for non-IPv4 or malformed destination '$destinationSubnet'."
            continue
        }

        # Find the first interface whose network contains the route's destination.
        foreach ($interface in $routableInterfaces) {
            # Use the existing Find-Subnet utility to check if the destination is within the interface's network.
            if ((Find-Subnet -addr1 ([string]$interface.Cidr) -addr2 ([string]$destinationSubnet)).condition) {
                $route.interface = $interface.Interface
                # Once found, we can stop searching for this route.
                break
            }
        }
    }

    # Return the device after route interfaces have been reconciled.
    return $device
}

#This Checks if the interface is a known valid interface type
#It returns true if so
#and false if not
function Check-InterfaceType{
    param
    (
        $String
    )
    switch -Regex ($String){
        'vlan(\d+.*)'                   {return $true}
        'Serial(\d+.*)'                 {return $true}
        'Ethernet(\d+.*)'               {return $true}
        'Port-channel(\d+.*)'           {return $true}
        'GigabitEthernet(\d+.*)'        {return $true}
        'TwentyFiveGigE(\d+.*)'         {return $true}
        'TenGigabitEthernet(\d+.*)'     {return $true}
        'FastEthernet(\d+.*)'           {return $true}
        'FortyGigabitEthernet(\d+.*)'   {return $true}
        'AppGigabitEthernet(\d+.*)'     {return $true}
        'vl(\d+.*)'                     {return $true}
        'Se(\d+.*)'                     {return $true}
        'Eth(\d+.*)'                    {return $true}
        'Po(\d+)'                       {return $true}
        'Gi(\d+.*)'                     {return $true}
        'Twe(\d+.*)'                    {return $true}
        'Te(\d+.*)'                     {return $true}
        'fa(\d+.*)'                     {return $true}
        'Fo(\d+.*)'                     {return $true}
        'Lo(\d+.*)'                     {return $true}
        'Ap(\d+.*)'                     {return $true}
        ''                              {return $false}
        $null                           {return $false}
        default{
            return $false
        }
    }
}



# Expands vendor-specific interface shorthand into its full name (Gi -> GigabitEthernet, Te -> TenGigabitEthernet, Po -> Port-channel, Lo -> Loopback, etc.). Used to normalise interface text before identity matching.
function Replace-InterfaceShortName {
    param (
        $String
    )
    if (-not $String) { return $null }
    # Falsy input returns above, so trimming and normalization operate on a string value.
    $String = $String.Trim() -replace "^vl(\d+.*)", 'Vlan$1' `
        -replace "Se(\d+.*)", 'Serial$1' `
        -replace "^Et(\d+.*)", 'Ethernet$1' `
        -replace "Eth(\d+.*)", 'Ethernet$1' `
        -replace "^Ma(\d+.*)", 'Management$1' `
        -replace "^Po(\d+)", 'Port-channel$1' `
        -replace "Gi(\d+.*)", 'GigabitEthernet$1' `
        -replace 'Twe(\d+.*)', 'TwentyFiveGigE$1' `
        -replace "Te(\d+.*)", 'TenGigabitEthernet$1' `
        -replace "fa(\d+.*)", 'FastEthernet$1' `
        -replace "Fo(\d+.*)", 'FortyGigabitEthernet$1' `
        -replace "Ap(\d+.*)", 'AppGigabitEthernet$1' `
        -replace "Lo(\d+.*)", 'Loopback$1'

    return $String
}





# Strips CLI prompt banners and echo lines (e.g. 'RP/0/RP0:sw-01# show ...', '--More--', 'Last switch-over') from raw show-command output so only real device data remains for parsing.
function Remove-DevicePrompt {
    param(
        [string]$Text
    )

    $Clean = foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*Last switch-over\b.*$' -or $line -match '^\s*--More--\s*$') { continue }
        $withoutPrompt = $line -replace '^\s*(?:RP/\d+/\S+:\S+|[A-Za-z0-9._:/()\-]+)\s*[#>]\s*', ''
        if ($withoutPrompt -match '^\s*(?:show|get)\s+.+$' -and $line -match '[#>]') { continue }
        $withoutPrompt
    }
    $Clean = $Clean | Out-String

    return $Clean
}



#Import mac to vendor mapping or get the MAC address xml file from devtools360.com and make a hash table with it.
function Get-MacAddressToVendorMapping(){
    $GMacAddressToVendorMapping=@{}
    if(Test-Path -Path .\MacAddressToVendorsMapping.csv){
        Write-MTAutoDrawLog -Level Info -Phase Load -Message "MacAddressToVendorsMapping.csv exists; importing MAC-address-to-vendor mapping."
        $MacAddressFile=import-csv MacAddressToVendorsMapping.csv
        foreach ($line in $MacAddressFile){
            $GMacAddressToVendorMapping.add($line.MacAddress,$line.Company)
        }
        return $GMacAddressToVendorMapping
    }
    Write-MTAutoDrawLog -Level Warn -Phase Load -Message "MacAddressToVendorsMapping.csv not found; downloading from https://devtools360.com."
    $XMLFile = (Invoke-WebRequest https://devtools360.com/en/macaddress/vendorMacs.xml?download=true).RawContent -split "`n"

    foreach ($line in $XMLFile){
        if($line -like "*mac_prefix*" -and $line -like "*vendor_name*"){
            $temp=$null
            $Temp=$line -replace "<VendorMapping mac_prefix=",'' -replace " vendor_name=",',' -replace '/>','' -replace '"','' -split ","

            $GMacAddressToVendorMapping.add($Temp[0],$Temp[1])
        }
    }
    Write-MTAutoDrawLog -Level Info -Phase Load -Message "Writing MacAddressToVendorsMapping.csv to disk."
    "MacAddress,Company" >> MacAddressToVendorsMapping.csv;
    foreach ( $b in $GMacAddressToVendorMapping.GetEnumerator() ){
        "$($b.key),$($b.value)"  >> MacAddressToVendorsMapping.csv
    }
    return $GMacAddressToVendorMapping
}

#region Parser standard - shared scaffolding
# ------------------------------------------------------------------------------------------------
# The contract every capture reader in a module marked "MTAutoDraw-Standard: v1" follows. See
# PARSER_STANDARD.md. These are additive: modules not yet on the standard keep calling
# Test-FileHasValidData and Execute-PythonTextFSM directly.
# ------------------------------------------------------------------------------------------------

# Step 1 of the four-step reader body: GUARD.
# A reader is called unconditionally for its slot, so an uncollected capture arrives here as $null and
# is not an error. Everything else defers to Test-FileHasValidData, which is the single place the CLI
# failure patterns live.
function Test-MTAutoDrawCaptureReadable {
    [CmdletBinding()]
    param(
        [AllowNull()]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)][string]$Capture
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-MTAutoDrawDiagnostic -Device $Device -Severity Warning -Message "$Capture capture is mapped but missing: $Path"
        return $false
    }
    if (-not (Test-FileHasValidData -FilePath $Path)) {
        Write-MTAutoDrawDiagnostic -Device $Device -Severity Warning -Message "$Capture capture is empty or holds a CLI error response, skipping: $Path"
        return $false
    }
    return $true
}

# Step 2: EXTRACT, for readers that parse with regex rather than TextFSM.
# Always -LiteralPath (capture paths contain [ ] and other glob characters) and never mutates source.
function Get-MTAutoDrawCaptureText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AsLines
    )

    if ($AsLines) { return @(Get-Content -LiteralPath $Path) }
    return (Get-Content -LiteralPath $Path -Raw)
}

# Step 2: EXTRACT, for readers that parse with TextFSM.
# Returns rows as PSCustomObjects keyed by the template's Value names, so callers never index by
# position. Returns an empty array on every failure - there is no 'ERROR' sentinel and
# $Device.ProcessOutputObjects is not touched.
function Invoke-MTAutoDrawTextFSM {
    [CmdletBinding()]
    param(
        [AllowNull()]$Device,
        [Parameter(Mandatory = $true)][string]$Template,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $templatePath = $GTextFSMTemplates[$Template]
    if (-not $templatePath) {
        Write-MTAutoDrawDiagnostic -Device $Device -Severity Error -Message "TextFSM template '$Template' is not present in Templates\."
        return @()
    }
    foreach ($required in $GPathToPythonExe, $GPathToPythonTextFSMScript) {
        if (-not $required -or -not (Test-Path -LiteralPath $required)) {
            Write-MTAutoDrawDiagnostic -Device $Device -Severity Error -Message "TextFSM runtime is not available: '$required'"
            return @()
        }
    }

    # Same two-pass behaviour as Execute-PythonTextFSM: parse the capture as collected, and only if
    # that fails retry against a prompt-stripped copy in the temp directory. The source is read-only.
    $rows = Convert-MTAutoDrawTextFSMOutput -Device $Device -TemplatePath $templatePath -InputPath $Path -Template $Template
    if ($null -ne $rows) { return $rows }

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        $cleaned = Remove-DevicePrompt -Text (Get-Content -LiteralPath $Path -Raw)
        [System.IO.File]::WriteAllText($tempFile, $cleaned, [System.Text.UTF8Encoding]::new($false))
        $rows = Convert-MTAutoDrawTextFSMOutput -Device $Device -TemplatePath $templatePath -InputPath $tempFile -Template $Template
        if ($null -ne $rows) { return $rows }
        # Warning, not Error: a template that does not match a capture is a coverage gap in the
        # template or an oddity in the capture, not a fault in this run. Severity Error counts into
        # RunSummary.ParserErrors and fails the whole run, which is far too blunt for one optional
        # capture on one device - and is not what the legacy Execute-PythonTextFSM path did either.
        Write-MTAutoDrawDiagnostic -Device $Device -Severity Warning -Message "TextFSM template '$Template' could not parse $Path, even after prompt cleanup."
        return @()
    }
    finally { Remove-Item -LiteralPath $tempFile -Force -ErrorAction Ignore }
}

# Runs one TextFSM pass. Returns $null when the pass failed (so the caller can retry) and an array -
# possibly empty, which is a legitimate "template matched nothing" result - when it succeeded.
function Convert-MTAutoDrawTextFSMOutput {
    [CmdletBinding()]
    param(
        [AllowNull()]$Device,
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)][string]$Template
    )

    $native = @(& $GPathToPythonExe $GPathToPythonTextFSMScript '--objects' $TemplatePath $InputPath 2>&1)
    if ($LASTEXITCODE -ne 0) { return $null }

    $text = (($native | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    try { $parsed = $text | ConvertFrom-Json -Depth 20 -ErrorAction Stop }
    catch { return $null }
    if (-not $parsed.PSObject.Properties.Name.Contains('header')) { return $null }

    $header = @($parsed.header)
    $records = @(foreach ($row in @($parsed.rows)) {
        $values = @($row)
        $record = [ordered]@{}
        for ($index = 0; $index -lt $header.Count; $index++) {
            # A List value arrives as a nested array; everything else is a scalar string.
            $record[$header[$index]] = if ($index -lt $values.Count) { $values[$index] } else { '' }
        }
        [PSCustomObject]$record
    })
    # The comma is load-bearing. Returning a bare empty array unrolls to nothing on the way out, so
    # the caller's $rows would be $null - indistinguishable from the failure signal above, and a
    # template that correctly matched no rows would be retried and then reported as unparseable.
    return , $records
}

# Every platform builds its device the same way, so DeviceIdentifier stops being derived by stripping
# the command back off the capture filename with a per-module regex.
function New-MTAutoDrawDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Platform,
        [Parameter(Mandatory = $true)]$HostID
    )

    $device = Create-HostObject
    $device.DeviceType       = $Platform
    $device.Origin           = 'File'
    $device.DeviceIdentifier = $HostID.HOSTID
    return $device
}

# Find-or-create by interface name. Vendors that need name normalisation wrap this rather than
# reimplementing the lookup.
function Resolve-MTAutoDrawInterface {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$NoCreate
    )

    $interface = $Device.interfaces | Where-Object { $_.Interface -ieq $Name } | Select-Object -First 1
    if ($interface) { return $interface }
    if ($NoCreate) { return $null }

    $interface = Create-InterfaceObject
    $interface.Interface = $Name
    $interface.shutdown  = $false
    $Device.interfaces += $interface
    return $interface
}

# Canonical network creation path: deduplicate by CIDR and assign deterministic presentation data.
function Add-MTAutoDrawNetwork {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Cidr,
        [AllowNull()][AllowEmptyString()][string]$RoutedVlan,
        [AllowNull()][AllowEmptyString()][string]$NetworkName,
        [AllowNull()][AllowEmptyString()][string]$IPAddress
    )

    if ($IPAddress -and $IPAddress -notin $Device.ArrayOfIPAddresses) { $Device.ArrayOfIPAddresses += $IPAddress }
    if ([string]::IsNullOrWhiteSpace($Cidr)) { return $null }

    $network = $Device.ArrayOfNetworks | Where-Object { $_.Cidr -eq $Cidr } | Select-Object -First 1
    if (-not $network) {
        $network = Create-NetworkObject
        $network.Cidr       = $Cidr
        $network.RoutedVlan = if ($RoutedVlan) { $RoutedVlan } else { 'no vlan' }
        $network.Color      = Get-DeterministicRgbColor -Seed $Cidr
        $Device.ArrayOfNetworks += $network
    }
    if ($NetworkName -and -not $network.NetworkName) { $network.NetworkName = $NetworkName }
    return $network
}

# Common tail for every Process-<Platform>HostFiles: deduplicate model collections and back-fill
# egress interfaces on local routes.
function Complete-MTAutoDrawDevice {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Device)

    $Device.interfaces      = @($Device.interfaces      | Sort-Object Interface -Unique)
    $Device.ArrayOfNetworks = @($Device.ArrayOfNetworks | Sort-Object Cidr -Unique)
    return (Update-LocalRoutesWithInterfaces -device $Device)
}

#endregion Parser standard - shared scaffolding


<#
.SYNOPSIS
Safely extracts a capture group value from a string using a regular expression.

.DESCRIPTION
Get-RegexGroupValue performs a regex match against an input string and returns 
the value of a specified capture group.

Unlike many common Select-String chaining patterns such as:

    (($text | Select-String -Pattern 'regex').Matches.Groups[1].Value).Trim()

This function prevents terminating errors when:
- The pattern does not match
- The Matches collection is empty
- The requested capture group does not exist
- The captured value is null or empty

PowerShell will throw:
    "You cannot call a method on a null-valued expression"
or
    "Cannot index into a null array"
if those edge cases are not guarded.

This helper eliminates that risk.

If no match is found, the function returns $null.
This mirrors the effective behavior of Select-String when no match is found.

.PARAMETER InputString
The string to search.

.PARAMETER Pattern
The regex pattern to apply.

.PARAMETER GroupIndex
The numeric capture group index to return.
Defaults to 1.

.PARAMETER Trim
If specified, trims whitespace from the returned value.

.OUTPUTS
System.String or $null

.EXAMPLE
$hostname = Get-RegexGroupValue `
    -InputString $config `
    -Pattern '(?m)^\s*hostname\s+(.+?)\s*$' `
    -GroupIndex 1 `
    -Trim

Returns the hostname if present, otherwise $null.

.EXAMPLE
$bgpAs = Get-RegexGroupValue `
    -InputString $config `
    -Pattern '(?m)^\s*router\s+bgp\s+(\d+)\s*$'

Returns the BGP ASN or $null if not configured.

.NOTES
This function is intentionally defensive.

It should be used anywhere a regex extraction is optional.
It prevents null indexing and method invocation failures in
parallel execution environments.
#>
function Get-RegexGroupValue {
    param (
        [Parameter(Mandatory = $true)]
        [string]$InputText,

        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [int]$GroupIndex = 1,

        [switch]$Trim
    )

    # Perform regex match using .NET engine
    $match = [regex]::Match($InputText, $Pattern)

    # If no match, return $null (safe behavior)
    if (-not $match.Success) {
        return $null
    }

    # Ensure requested group exists
    if ($GroupIndex -ge $match.Groups.Count) {
        return $null
    }

    $value = $match.Groups[$GroupIndex].Value

    # If value is null or empty, return $null
    if ([string]::IsNullOrEmpty($value)) {
        return $null
    }

    if ($Trim) {
        return $value.Trim()
    }

    return $value
}


# Reduces a MAC address to one canonical form: lower-case, colon separated.
# Vendors disagree on presentation - Cisco IOS writes 5052.0ddd.3972, Junos and Cisco Small
# Business write 50:52:0d:dd:39:72, others use hyphens or no separator at all. Any comparison
# between two platforms' MACs has to go through here first or it silently fails.
# Input that is not 12 hex digits (for example 'N/A', or a hostname standing in for a MAC) is
# returned untouched rather than mangled, so callers can pass anything safely.
function ConvertTo-NormalizedMacAddress {
    [CmdletBinding()]
    param([string]$MacAddress)

    if ([string]::IsNullOrWhiteSpace($MacAddress)) { return $MacAddress }

    $hex = $MacAddress -replace '[.:\-\s]', ''
    if ($hex -notmatch '^[0-9A-Fa-f]{12}$') { return $MacAddress }

    return ((0..5 | ForEach-Object { $hex.Substring($_ * 2, 2) }) -join ':').ToLowerInvariant()
}

# Builds a canonical 'ip/prefix' string from an address plus prefix-length or subnet-mask, validating that the address is a valid IPv4. Returns $null when invalid.
function Get-NormalizedIPv4Cidr {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$IPAddress,
        [AllowNull()][string]$PrefixLength,
        [AllowNull()][string]$SubnetMask
    )

    if ([string]::IsNullOrWhiteSpace($IPAddress)) { return $null }
    $address = $IPAddress.Trim()
    if ($address.Contains('/')) {
        $parts = $address.Split('/', 2)
        $address = $parts[0]
        if (-not $PrefixLength) { $PrefixLength = $parts[1] }
    }

    $parsedAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($address, [ref]$parsedAddress) -or
        $parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return $null
    }

    try {
        if ($PrefixLength -match '^\d{1,2}$' -and [int]$PrefixLength -ge 0 -and [int]$PrefixLength -le 32) {
            $subnet = Get-IPv4Subnet -IPAddress $address -PrefixLength ([int]$PrefixLength) -ErrorAction Stop
        }
        elseif ($SubnetMask -match '^\d{1,3}(?:\.\d{1,3}){3}$') {
            $subnet = Get-IPv4Subnet -IPAddress $address -SubnetMask $SubnetMask -ErrorAction Stop
        }
        else { return $null }
    }
    catch { return $null }

    if (-not $subnet -or -not $subnet.CIDRId) { return $null }
    return [pscustomobject]@{
        IPAddress    = $address
        PrefixLength = [string]$subnet.PrefixLength
        SubnetMask   = [string]$subnet.SubnetMask
        Cidr         = [string]$subnet.CIDRId
    }
}

# Normalises and appends one de-duplicated interface address record.
function Add-MTAutoDrawInterfaceAddressRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Records,
        [Parameter(Mandatory = $true)][hashtable]$Seen,
        [AllowNull()][string]$IPAddress,
        [AllowNull()][string]$SubnetMask,
        [AllowNull()][string]$Cidr,
        [Parameter(Mandatory = $true)][string]$AddressType
    )

    if ([string]::IsNullOrWhiteSpace($IPAddress)) { return }
    $prefixLength = $SubnetMask
    if (-not $prefixLength -and $Cidr -match '/(?<prefix>\d{1,2})$') { $prefixLength = $Matches['prefix'] }

    $normalized = if ($prefixLength -match '^\d{1,2}$') {
        Get-NormalizedIPv4Cidr -IPAddress $IPAddress -PrefixLength $prefixLength
    }
    elseif ($prefixLength -match '^\d{1,3}(?:\.\d{1,3}){3}$') {
        Get-NormalizedIPv4Cidr -IPAddress $IPAddress -SubnetMask $prefixLength
    }
    else { $null }

    $record = [pscustomobject]@{
        AddressType = $AddressType
        IPAddress = if ($normalized) { $normalized.IPAddress } else { $IPAddress.Trim() }
        PrefixLength = if ($normalized) { $normalized.PrefixLength } else { $prefixLength }
        Cidr = if ($normalized) { $normalized.Cidr } else { $Cidr }
    }
    $key = '{0}|{1}' -f $record.IPAddress, $record.Cidr
    if (-not $Seen.ContainsKey($key)) {
        $Seen[$key] = $true
        $Records.Add($record)
    }
}

# Collects all IPv4 address records (primary, secondary, standby, cluster, HSRP) for an interface, normalised and de-duplicated.
function Get-MTAutoDrawInterfaceIPv4Address {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()]$Interface)

    if ($null -eq $Interface) { return @() }

    $records = [System.Collections.Generic.List[object]]::new()
    $seen = @{}

    Add-MTAutoDrawInterfaceAddressRecord -Records $records -Seen $seen -IPAddress ([string]$Interface.IPAddress) `
        -SubnetMask ([string]$Interface.SubnetMask) -Cidr ([string]$Interface.Cidr) -AddressType 'Primary'

    $secondaryAddresses = @($Interface.SecondaryIPAddress | Where-Object { $_ })
    $secondaryMasks = @($Interface.SecondarySubnetMask)
    $secondaryCidrs = @($Interface.SecondaryCidr)
    for ($index = 0; $index -lt $secondaryAddresses.Count; $index++) {
        $mask = if ($index -lt $secondaryMasks.Count) { [string]$secondaryMasks[$index] } else { $null }
        $cidr = if ($index -lt $secondaryCidrs.Count) { [string]$secondaryCidrs[$index] } else { $null }
        Add-MTAutoDrawInterfaceAddressRecord -Records $records -Seen $seen -IPAddress ([string]$secondaryAddresses[$index]) `
            -SubnetMask $mask -Cidr $cidr -AddressType 'Secondary'
    }

    return @($records)
}
