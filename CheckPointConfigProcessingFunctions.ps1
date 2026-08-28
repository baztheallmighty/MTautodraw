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

# Check Point Gaia capture processing. Follows PARSER_STANDARD.md v1; read
# CiscoIOSXRConfigProcessingFunctions.ps1 alongside it for the reference implementation.

# --- Platform helpers -----------------------------------------------------------------------------

# Gaia reports two things about the box in two different captures, so both readers merge into one
# version object rather than each replacing it. Whichever runs first creates it.
function Get-CheckPointVersionObject {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Device)

    if (-not $Device.Version) { $Device.Version = Create-ShowVersionObject }
    return $Device.Version
}

# Interface MACs are held in Cisco dotted-quad form because that is what the Check Point cluster-IP
# pass in StartProcessingConfig.ps1 compares against. Deliberately not ConvertTo-NormalizedMacAddress.
function ConvertTo-CheckPointMacAddress {
    [CmdletBinding()]
    param([AllowNull()][string]$MacAddress)

    $hex = [string]$MacAddress -replace '[.:\-\s]', ''
    if ($hex -notmatch '^[0-9A-Fa-f]{12}$') { return $null }
    return $hex.Insert(4, '.').Insert(9, '.')
}

# --- Capture readers ------------------------------------------------------------------------------
# Each one: GUARD, EXTRACT, MAP, MERGE. Each takes -Device and -Path, returns nothing, and is safe to
# call with a $null path - so the orchestrator needs no per-slot if-wrappers.

# Reads the Gaia running configuration for the device identity. Nothing else in the config is parsed
# yet; the interface and route captures carry richer data than 'set interface' lines do.
function Update-CheckPointRunningConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowRun')) { return }

    # --- EXTRACT / MAP / MERGE ---
    $config = Get-MTAutoDrawCaptureText -Path $Path
    if ($config -match '(?im)^\s*set hostname\s+(?<hostname>\S+)') {
        $Device.hostname = $Matches['hostname'].Trim()
        return
    }

    # A readable config with no hostname is still a device: the capture group exists, so something
    # answered. It is flagged rather than dropped so the diagram shows the collection problem.
    Write-MTAutoDrawDiagnostic -Device $Device -Severity Warning -Message "No hostname found in Check Point configuration: $Path"
    $Device.hostname = 'NoHostNameFoundCheckForConfigProblems'
}

# Reads 'show asset all' for the chassis platform, model and serial number.
function Update-CheckPointAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowAssetAll')) { return }

    # --- EXTRACT ---
    # 'show asset all' is a flat 'Key: value' list, so it parses to a lookup rather than rows.
    $asset = @{}
    foreach ($line in (Get-MTAutoDrawCaptureText -Path $Path -AsLines)) {
        if ($line -notmatch '^(?<key>[^:]+):(?<value>.*)$') { continue }
        $asset[$Matches['key'].Trim()] = $Matches['value'].Trim()
    }

    # --- MAP + MERGE ---
    $version = Get-CheckPointVersionObject -Device $Device
    if (-not $version.Type) { $version.Type = 'Checkpoint' }
    foreach ($key in 'Platform', 'Model') {
        if ($asset.ContainsKey($key)) { $version.Hardware += $asset[$key] }
    }
    if ($asset.ContainsKey('Serial Number')) { $version.Serial += $asset['Serial Number'] }
}

# Reads 'show version all' for the Gaia release.
function Update-CheckPointVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowVersion')) { return }

    # --- EXTRACT / MAP / MERGE ---
    $version = Get-CheckPointVersionObject -Device $Device
    $version.Type = 'Checkpoint Gaia'
    $version.OS = $null
    if ((Get-MTAutoDrawCaptureText -Path $Path) -match 'Product version .*?(?<release>R\d+\.\d+)') {
        $version.OS = $Matches['release']
    }
}

# Reads 'show interfaces all' into the device's interfaces and the networks they front.
function Update-CheckPointInterfaces {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowInterface')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'checkpoint_gaia_show_interfaces_all' -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    foreach ($row in $rows) {
        $interface = Resolve-MTAutoDrawInterface -Device $Device -Name $row.INTERFACE

        # Gaia reports a VLAN sub-interface's link state as "not available" even when it is carrying
        # traffic, so its administrative state is the only signal that it is up.
        $interface.shutdown = -not ($row.LINK_STATE -eq 'link up' -or
            ($row.STATE -eq 'on' -and $row.TYPE -eq 'vlan' -and $row.LINK_STATE -eq 'not available'))
        $interface.speed       = $row.SPEED
        $interface.Description = $row.COMMENT
        $interface.macaddress  = ConvertTo-CheckPointMacAddress -MacAddress $row.MAC_ADDRESS

        # IPV4_ADDRESS is 'a.b.c.d/prefix' when configured, and a word such as 'Not Configured' when not.
        $address = Get-NormalizedIPv4Cidr -IPAddress $row.IPV4_ADDRESS
        if (-not $address) { continue }
        $interface.IPAddress      = $address.IPAddress
        $interface.SubnetMask     = $address.PrefixLength
        $interface.Cidr           = $address.Cidr
        $interface.SwitchPortType = 'Routed'

        # The comment is the closest thing Gaia has to a network name. It is a description rather than
        # a name, so it reads poorly on a diagram, but it is better than an unlabelled subnet.
        $routedVlan = $null
        if ($row.TYPE -eq 'vlan') {
            $routedVlan = if ($interface.Interface -like '*.*') { "vlan$(($interface.Interface -split '\.')[1])" } else { $interface.Interface }
        }
        $null = Add-MTAutoDrawNetwork -Device $Device -Cidr $address.Cidr -RoutedVlan $routedVlan `
            -NetworkName $interface.Description -IPAddress $address.IPAddress
    }
}

# Reads 'show route all' into the device's routing table.
function Update-CheckPointRoutes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowRouteAll')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'checkpoint_gaia_show_route' -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    # Gaia prints the one-letter code from the legend at the top of the capture rather than a protocol
    # name. An unrecognised code is carried through as-is rather than dropped.
    $protocols = @{ C = 'connected'; L = 'local'; S = 'static'; R = 'RIP'; B = 'BGP'; D = 'BGP'; O = 'OSPF' }
    $Device.RoutingTable = @(foreach ($row in $rows) {
        $route = Create-RouteObject
        $route.RouteProtocol = if ($protocols.ContainsKey([string]$row.PROTOCOL)) { $protocols[[string]$row.PROTOCOL] } else { $row.PROTOCOL }
        $route.Subnet        = "$($row.NETWORK)/$($row.MASK)"
        $route.gateway       = $row.NEXTHOPIP
        $route.Interface     = $row.INTERFACE
        $route
    })
}

# --- Orchestrator ---------------------------------------------------------------------------------

function Process-CheckPointHostFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$HostID,
        $ArrayOfObjects   # Kept for dispatcher signature compatibility; duplicate detection is sequential.
    )

    # 1. IDENTITY - the running configuration is the only capture carrying the hostname.
    $device = New-MTAutoDrawDevice -Platform 'CheckPoint' -HostID $HostID
    Update-CheckPointRunningConfig -Device $device -Path $HostID.ShowRun
    if (-not $device.hostname) {
        Write-MTAutoDrawDiagnostic -Device $device -Severity Warning -Message "Check Point '$($HostID.HOSTID)' has no usable running configuration; skipping host."
        return $null
    }
    Write-MTAutoDrawLog -Level Info -Phase Parse -Device $device -Message "Processing CheckPoint Host: $($device.hostname)"

    # 2. CAPTURES - one line per slot, in dependency order. Asset runs before version because it is
    # the coarser of the two: version then refines Type from 'Checkpoint' to the Gaia release line.
    Update-CheckPointAsset      -Device $device -Path $HostID.ShowAssetAll
    Update-CheckPointVersion    -Device $device -Path $HostID.ShowVersion
    Update-CheckPointInterfaces -Device $device -Path $HostID.ShowInterface
    Update-CheckPointRoutes     -Device $device -Path $HostID.ShowRouteAll

    # 3. RECONCILE
    return (Complete-MTAutoDrawDevice -Device $device)
}
