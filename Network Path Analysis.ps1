# Helper to create a new node for the Radix Tree.
function New-RadixTreeNode {
    return [PSCustomObject]@{
        # Children nodes for bit 0 and bit 1. Using a hashtable for clarity.
        Children = @{ '0' = $null; '1' = $null }
        # The actual route object if this node represents a prefix terminus.
        Route = $null
    }
}

# Helper to convert an IPv4 address string to its 32-bit unsigned integer representation.
# This is crucial for efficient bitwise operations.
function Convert-IpToUInt32 {
    param ([string]$Ip)
    # Using .NET methods for robust IP parsing and conversion.
    $ipAddress = [System.Net.IPAddress]::Parse($Ip)
    $ipBytes = $ipAddress.GetAddressBytes()
    # .NET's GetAddressBytes returns in network byte order (big-endian).
    # BitConverter respects the system's architecture (usually little-endian).
    # We must reverse the byte array on little-endian systems to get the correct integer value.
    if ([System.BitConverter]::IsLittleEndian) {
        [System.Array]::Reverse($ipBytes)
    }
    return [System.BitConverter]::ToUInt32($ipBytes, 0)
}

# Inserts a single route into a device's radix tree.
function Add-RouteToRadixTree {
    param(
        [psobject]$RootNode,
        [psobject]$Route,
        [string]$DeviceName,
        [string]$LogLevel = "Normal"
    )

    if ([string]::IsNullOrEmpty($Route.Subnet) -or $Route.Subnet -notlike '*/*') {
        return # Skip routes with invalid subnet formats.
    }

    try {
        $subnetParts = $Route.Subnet.Split('/')
        $networkIp = $subnetParts[0]
        $prefixLength = [int]$subnetParts[1]
    }
    catch {
        if ($LogLevel -eq 'Debug') {
            Write-Host "[DEBUG][Radix] Skipping invalid CIDR '$($Route.Subnet)' on device '$DeviceName'." -ForegroundColor Gray
        }
        return
    }

    if ($LogLevel -eq 'Debug') {
        Write-Host "[DEBUG][Radix] Inserting route '$($Route.Subnet)' for device '$DeviceName'." -ForegroundColor DarkGray
    }

    # Convert the network IP to an integer for bitwise operations.
    $ipInt = Convert-IpToUInt32 -Ip $networkIp
    $currentNode = $RootNode

    # For a /24 prefix, we traverse 24 levels deep into the tree.
    for ($i = 0; $i -lt $prefixLength; $i++) {
        # Check the bit at the current depth (from most significant to least).
        # A right shift by (31 - $i) moves the bit we care about to the rightmost position.
        # A bitwise AND with 1 isolates it, giving either 0 or 1.
        $bit = ($ipInt -shr (31 - $i)) -band 1
        
        if ($null -eq $currentNode.Children[$bit]) {
            # If the path doesn't exist, create a new node.
            $currentNode.Children[$bit] = New-RadixTreeNode
        }
        # Move to the next node in the path.
        $currentNode = $currentNode.Children[$bit]
    }

    # After traversing to the correct depth, attach the full route object to the node.
    # If a route already exists for this exact prefix, it will be overwritten.
    $currentNode.Route = $Route
}

# Main function to build a radix tree for each device.
# This function REPLACES the old Create-RouteLookupTableLPM function.
function Create-RouteRadixTrees {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [array]$AllDeviceObjects,
        [Parameter(Mandatory=$false)]
        [ValidateSet("Normal", "Debug")]
        [string]$LogLevel = "Normal"
    )

    Write-Host "[INFO] Building Radix Tree route lookup tables..." -ForegroundColor Green
    $RouteRadixTrees = @{}

    foreach ($device in $AllDeviceObjects) {
        if ([string]::IsNullOrEmpty($device.hostname) -or $null -eq $device.RoutingTable) {
            continue
        }

        # Each device gets its own brand-new root node.
        $rootNode = New-RadixTreeNode

        foreach ($route in $device.RoutingTable) {
            # Precompute NetInt and MaskInt for faster subnet matching later
            try {
                if ($route.Subnet -and $route.Subnet -like "*/*") {
                    $parts   = $route.Subnet.Split('/')
                    $netInt  = Convert-IpToUInt32 $parts[0]
                    $prefix  = [int]$parts[1]
                    $maskInt = if ($prefix -eq 0) { [uint32]0 } else { [uint32]::MaxValue -shl (32 - $prefix) }

                    $route | Add-Member -NotePropertyName NetInt  -NotePropertyValue $netInt  -Force
                    $route | Add-Member -NotePropertyName MaskInt -NotePropertyValue $maskInt -Force
                }
            } catch {
                if ($LogLevel -eq 'Debug') {
                    Write-Host "[DEBUG][Radix] Skipping invalid subnet '$($route.Subnet)' on device '$($device.hostname)'." -ForegroundColor Gray
                }
                continue
            }

            Add-RouteToRadixTree -RootNode $rootNode -Route $route -DeviceName $device.hostname -LogLevel $LogLevel
        }

        $RouteRadixTrees[$device.hostname] = $rootNode

        if ($LogLevel -eq 'Debug') {
            $routeCount = $device.RoutingTable.Count
            Write-Host "[DEBUG] Processed $($device.hostname), built radix tree with $routeCount routes." -ForegroundColor Gray
        }
    }

    Write-Host "[INFO] Radix Tree route lookup table created for $($RouteRadixTrees.Keys.Count) devices." -ForegroundColor Green
    return $RouteRadixTrees
}


function Find-BestRouteInRadixTree {
    param (
        [psobject]$RootNode,
        [string]$DestIP,
        [string]$Hostname,
        [string]$LogLevel = "Normal"
    )

    if ($null -eq $RootNode) { return $null }

    # Convert once, avoid string parsing later
    $ipInt = Convert-IpToUInt32 -Ip $DestIP
    $currentNode = $RootNode
    $bestMatch = $null

    # Use StringBuilder only if debugging, to avoid extra allocations
    $pathBuilder = if ($LogLevel -eq 'Debug') { [System.Text.StringBuilder]::new() } else { $null }

    # Check for default route at root node
    if ($null -ne $RootNode.Route) {
        $bestMatch = $RootNode.Route
        if ($LogLevel -eq 'Debug') {
            Write-Host "[DEBUG][Radix] Lookup on '$Hostname' for '$DestIP': Initial best match is default route '$($bestMatch.Subnet)'." -ForegroundColor DarkGray
        }
    }

    # Traverse the radix tree for all 32 bits of the destination IP
    for ($i = 31; $i -ge 0; $i--) {
        $bit = ($ipInt -shr $i) -band 1
        if ($pathBuilder) { [void]$pathBuilder.Append($bit) }

        # Stop if no further path exists
        if ($null -eq $currentNode.Children[$bit]) {
            if ($LogLevel -eq 'Debug') {
                $bitDepth = 31 - $i + 1
                $pathString = if ($pathBuilder) { $pathBuilder.ToString() } else { "" }
                Write-Host "[DEBUG][Radix] Traversal for '$DestIP' stopped at bit depth $bitDepth. Path '$pathString' does not exist." -ForegroundColor DarkGray
            }
            break
        }

        $currentNode = $currentNode.Children[$bit]

        # Update best match if a more specific prefix exists
        if ($null -ne $currentNode.Route) {
            # If route has NetInt/MaskInt, validate it directly here
            if ($currentNode.Route.PSObject.Properties.Match('NetInt') -and $currentNode.Route.PSObject.Properties.Match('MaskInt')) {
                if (($ipInt -band $currentNode.Route.MaskInt) -eq $currentNode.Route.NetInt) {
                    $bestMatch = $currentNode.Route
                }
            }
            else {
                # Fallback: slower string-based check
                if (Test-IpInSubnet -Ip $DestIP -Cidr $currentNode.Route.Subnet) {
                    $bestMatch = $currentNode.Route
                }
            }

            if ($LogLevel -eq 'Debug') {
                $bitDepth = 31 - $i + 1
                $pathString = if ($pathBuilder) { $pathBuilder.ToString() } else { "" }
                Write-Host "[DEBUG][Radix] Found potential match at depth $bitDepth : '$($bestMatch.Subnet)' (Path: $pathString)." -ForegroundColor DarkGray
            }
        }
    }

    if ($LogLevel -eq 'Debug') {
        if ($null -ne $bestMatch) {
            Write-Host "[DEBUG][Radix] Final best match for '$DestIP' on '$Hostname' is '$($bestMatch.Subnet)'." -ForegroundColor Gray
        } else {
            Write-Host "[DEBUG][Radix] No match found for '$DestIP' on '$Hostname'." -ForegroundColor Gray
        }
    }

    return $bestMatch
}



# ===================================================================
# ========= END: NEW RADIX TREE CORE FUNCTIONS            =========
# ===================================================================



function Create-HopObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Device,

        [Parameter(Mandatory=$true)]
        [ValidateSet('Reached', 'NoRoute', 'Terminated')]
        [string]$Status,

        [string]$Interface = $null,
        [string]$Subnet = $null,
        [string]$Gateway = $null
    )

    # This function creates a standardized 'Hop' object which represents a single step in a path trace.
    return [PSCustomObject]@{
        # The hostname or unique identifier of the device at this hop.
        Device    = $Device
        # The egress interface used to leave the device;
        Interface = $Interface
        # The subnet of the egress interface;
        Subnet    = $Subnet
        # The next-hop IP address for the route;
        Gateway   = $Gateway
        # The trace result at this hop ('Reached', 'NoRoute', 'Terminated').
        Status    = $Status
    }
}

function Create-PairObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$DeviceA,

        [Parameter(Mandatory=$true)]
        [string]$DeviceIdentifierA,

        [Parameter(Mandatory=$true)]
        [string]$SubnetA,

        [Parameter(Mandatory=$true)]
        [string]$DeviceB,

        [Parameter(Mandatory=$true)]
        [string]$DeviceIdentifierB,

        [Parameter(Mandatory=$true)]
        [string]$SubnetB
    )

    return [PSCustomObject]@{
        DeviceA           = $DeviceA
        DeviceIdentifierA = $DeviceIdentifierA
        SubnetA           = $SubnetA
        DeviceB           = $DeviceB
        DeviceIdentifierB = $DeviceIdentifierB
        SubnetB           = $SubnetB
        Symmetry          = $null
        PathType          = $null

        # --- NEW Path Properties (replaces the 8 old properties) ---
        # An array to hold structured 'Path' objects for the A->B direction.
        PathsForward      = @()
        # An array to hold structured 'Path' objects for the B->A direction.
        PathsReverse      = @()
    }
}

function Create-PathObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [array]$HopArray,

        [Parameter(Mandatory=$true)]
        [int]$PathNumber
    )

    # Determine the final status of the path from its very last hop.
    $finalStatus = if ($HopArray.Count -gt 0) { $HopArray[-1].Status } else { 'Unknown' }

    # ✅ This is already the fast, recommended way to create an object.
    $pathObject = [PSCustomObject]@{
        PathNumber    = $PathNumber
        Status        = $finalStatus
        DevicePath    = $HopArray.Device      # Extracts all 'Device' properties into a simple array
        InterfacePath = $HopArray.Interface  # Extracts all 'Interface' properties
        SubnetPath    = $HopArray.Subnet     # Extracts all 'Subnet' properties
        HopDetails    = $HopArray            # The original, full array of Hop objects for deep inspection
    }

    return $pathObject
}
# This version stores a richer object (Hostname + Interface) in the lookup table.
function Add-IpToDeviceLookup {
    # This is a private helper function for Create-DeviceLookupTable.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Ip,
        [Parameter(Mandatory=$true)]
        [psobject]$CurrentDevice,
        [Parameter(Mandatory=$true)]
        [psobject]$CurrentInterface,
        [Parameter(Mandatory=$true)]
        [hashtable]$DeviceLookup,
        [Parameter(Mandatory=$true)]
        [array]$AllDeviceObjects,
        [Parameter(Mandatory=$true)]
        [string]$LogLevel
    )

    # Skip if the IP is null or empty
    if ([string]::IsNullOrEmpty($Ip)) {
        return
    }

    $newEntry = [PSCustomObject]@{
        Hostname  = $CurrentDevice.hostname
        Interface = $CurrentInterface.Interface
    }

    if (-not $DeviceLookup.ContainsKey($Ip)) {
        # This is the first time we've seen this IP. Add a new entry.
        # Store an array of objects, each containing the Hostname AND the Interface.
        # OPTIMIZATION: Initialize the value as a generic list for future fast additions.
        $list = [System.Collections.Generic.List[object]]::new()
        $list.Add($newEntry)
        $DeviceLookup[$Ip] = $list
    }
    else {
        # This IP already exists.
        # OPTIMIZATION: Use the fast .Add() method instead of the slow `+=` operator on an array.
        $DeviceLookup[$Ip].Add($newEntry)

        if ($LogLevel -eq 'Debug') {
            $deviceAndInterfaceLog = $DeviceLookup[$Ip] | ForEach-Object { "$($_.Hostname)($($_.Interface))" } | Sort-Object -Unique
            Write-Host "[WARN] Shared IP $Ip detected on devices: $($deviceAndInterfaceLog -join ', ')" -ForegroundColor Yellow
        }
    }
}

# --- OPTIMIZED: Add-ConnectedInterfaceRoutes ---
function Add-ConnectedInterfaceRoutes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [array]$DeviceObjects
    )

    Write-Host "[PRE-FLIGHT] Ensuring all active interfaces have a connected route..." -ForegroundColor Cyan
    $addedRoutesCount = 0

    foreach ($device in $DeviceObjects) {
        # Skip if there are no interfaces on this device
        if ($null -eq $device.interfaces) { continue }

        # --- OPTIMIZATION: Use a generic list to collect new routes efficiently ---
        $newRoutes = [System.Collections.Generic.List[object]]::new()

        $existingSubnets = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

        if ($null -ne $device.RoutingTable) {
            foreach ($route in $device.RoutingTable) {
                if (-not [string]::IsNullOrEmpty($route.Subnet)) {
                    $existingSubnets.Add($route.Subnet) | Out-Null
                }
            }
        }

        foreach ($interface in $device.interfaces) {
            # We only care about active interfaces that have a valid CIDR subnet
            if ((-not $interface.shutdown) -and (-not [string]::IsNullOrEmpty($interface.Cidr))) {

                # Now this check is safe because $existingSubnets is guaranteed to be a valid object
                if (-not $existingSubnets.Contains($interface.Cidr)) {
                    # Create a new route object that matches the existing schema
                    $newRoute = [PSCustomObject]@{
                        RouteProtocol = 'connected'
                        Subnet        = $interface.Cidr
                        interface     = $interface.Interface
                        gateway       = ''
                        DISTANCE      = 0
                        METRIC        = 0
                    }
                    # OPTIMIZATION: Add to the temporary list instead of modifying the main array inside the loop.
                    $newRoutes.Add($newRoute)
                }
            }
        }

        # OPTIMIZATION: If new routes were found, add them to the device's table in a single, efficient operation.
        if ($newRoutes.Count -gt 0) {
            $device.RoutingTable += $newRoutes
            $addedRoutesCount += $newRoutes.Count
        }
    }
    Write-Host "[INFO] Added $addedRoutesCount missing connected routes to the data model." -ForegroundColor Green
    return $DeviceObjects
}



function Create-DeviceLookupTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [array]$GArrayOfObjectsFilter,

        [Parameter(Mandatory=$false)]
        [ValidateSet("Normal", "Debug")]
        [string]$LogLevel = "Normal"
    )

    Write-Host "[INFO] Building IP-to-Device lookup table..." -ForegroundColor Green

    $deviceLookup = @{}

    foreach ($device in $GArrayOfObjectsFilter) {
        if ($null -ne $device.interfaces) {
            foreach ($interface in $device.interfaces) {
                # FIX: Check for a valid IP before calling the helper function for each property.
                if (-not [string]::IsNullOrEmpty($interface.IPAddress)) {
                    Add-IpToDeviceLookup -Ip $interface.IPAddress -CurrentDevice $device -CurrentInterface $interface -DeviceLookup $deviceLookup -AllDeviceObjects $GArrayOfObjectsFilter -LogLevel $LogLevel
                }
                if (-not [string]::IsNullOrEmpty($interface.SecondaryIPAddress)) {
                    Add-IpToDeviceLookup -Ip $interface.SecondaryIPAddress -CurrentDevice $device -CurrentInterface $interface -DeviceLookup $deviceLookup -AllDeviceObjects $GArrayOfObjectsFilter -LogLevel $LogLevel
                }
                if (-not [string]::IsNullOrEmpty($interface.Standbyip)) {
                    Add-IpToDeviceLookup -Ip $interface.Standbyip -CurrentDevice $device -CurrentInterface $interface -DeviceLookup $deviceLookup -AllDeviceObjects $GArrayOfObjectsFilter -LogLevel $LogLevel
                }
                if (-not [string]::IsNullOrEmpty($interface.ClusterIP)) {
                    Add-IpToDeviceLookup -Ip $interface.ClusterIP -CurrentDevice $device -CurrentInterface $interface -DeviceLookup $deviceLookup -AllDeviceObjects $GArrayOfObjectsFilter -LogLevel $LogLevel
                }
            }
        }
    }

    Write-Host "[INFO] IP lookup table created with $($deviceLookup.Count) unique IPs." -ForegroundColor Green

    return $deviceLookup
}


function Create-RouteLookupTableLPM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [array]$AllDeviceObjects,

        [Parameter(Mandatory=$false)]
        [ValidateSet("Normal", "Debug")]
        [string]$LogLevel = "Normal"
    )

    Write-Host "[INFO] Building optimized LPM route lookup table..." -ForegroundColor Green
    $RouteLookupTable = @{}

    foreach ($device in $AllDeviceObjects) {
        if ([string]::IsNullOrEmpty($device.hostname) -or $null -eq $device.RoutingTable) {
            continue
        }

        $deviceRoutesByPrefix = @{}
        foreach ($route in $device.RoutingTable) {
            if (-not ([string]::IsNullOrEmpty($route.Subnet)) -and $route.Subnet -like '*/*') {
                try {
                    $prefixLength = [int]($route.Subnet.Split('/')[1])
                    if (-not $deviceRoutesByPrefix.ContainsKey($prefixLength)) {
                        $deviceRoutesByPrefix[$prefixLength] = @{}
                    }
                    $deviceRoutesByPrefix[$prefixLength][$route.Subnet] = $route
                }
                catch {
                    Write-Warning "[WARN] Could not parse prefix length from subnet '$($route.Subnet)' on device '$($device.hostname)'. Skipping."
                }
            }
        }

        if ($deviceRoutesByPrefix.Count -gt 0) {
            # --- START MODIFICATION ---
            # Sort the prefix keys ONCE and store them.
            $sortedPrefixes = $deviceRoutesByPrefix.Keys | Sort-Object -Descending

            # Store an object containing both the routes and the pre-sorted keys.
            $RouteLookupTable[$device.hostname] = [PSCustomObject]@{
                RoutesByPrefix = $deviceRoutesByPrefix
                SortedPrefixes = $sortedPrefixes
            }
            # --- END MODIFICATION ---

            if ($LogLevel -eq 'Debug') {
                $routeCount = ($deviceRoutesByPrefix.Values | ForEach-Object { $_.Count }) | Measure-Object -Sum | Select-Object -ExpandProperty Sum
                Write-Host "[DEBUG] Processed $($device.hostname), found $routeCount routes." -ForegroundColor Gray
            }
        }
    }

    Write-Host "[INFO] Route lookup table created for $($RouteLookupTable.Keys.Count) devices." -ForegroundColor Green
    return $RouteLookupTable


}







# This function is refactored from Create-ExternalVirtualDevices.
# Instead of creating fake devices, it identifies external routes and attaches
# metadata about them directly to the real edge devices. It also flags the
# routes themselves for easier lookup during tracing.
# --- OPTIMIZED: Attach-ExternalSubnets ---
function Attach-ExternalSubnets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [array]$AllDeviceObjects,
        [Parameter(Mandatory=$true)]
        [hashtable]$DeviceLookupTable,
        [Parameter(Mandatory=$false)]
        [ValidateSet("Normal", "Debug")]
        [string]$LogLevel = "Normal"
    )

    Write-Host "[INFO] Identifying external subnets and attaching to edge devices..." -ForegroundColor Green
    $externalSubnetCount = 0

    foreach ($device in $AllDeviceObjects) {
        # OPTIMIZATION: Use a temporary generic list to efficiently gather the external subnets for this device.
        $deviceExternalSubnets = [System.Collections.Generic.List[object]]::new()

        if ($null -ne $device.RoutingTable) {
            foreach ($route in $device.RoutingTable) {
                if (-not ([string]::IsNullOrEmpty($route.Gateway)) -and -not $DeviceLookupTable.ContainsKey($route.Gateway)) {
                    $route | Add-Member -MemberType NoteProperty -Name IsExternal -Value $true -Force
                    $externalSubnet = [PSCustomObject]@{
                        Subnet     = $route.Subnet
                        Gateway    = $route.Gateway
                        IsExternal = $true
                    }

                    # OPTIMIZATION: Add to the temporary list instead of modifying the main array inside the loop.
                    $deviceExternalSubnets.Add($externalSubnet)
                }
                else {
                    $route | Add-Member -MemberType NoteProperty -Name IsExternal -Value $false -Force
                }
            }
        }

        # Now, add the collected subnets to the device.
        $device | Add-Member -MemberType NoteProperty -Name ExternalSubnets -Value @($deviceExternalSubnets) -Force
        $externalSubnetCount += $deviceExternalSubnets.Count

        # Deduplicate the list of external subnets on the device (this logic is unchanged)
        if ($device.ExternalSubnets.Count -gt 0) {
            $device.ExternalSubnets = $device.ExternalSubnets | Sort-Object -Property Subnet, Gateway -Unique
        }
    }

    Write-Host "[INFO] Finished. Identified and attached $externalSubnetCount external subnet references." -ForegroundColor Green
    return $AllDeviceObjects
}

function Generate-InternalPairs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [array]$InternalDeviceObjects,

        [Parameter(Mandatory=$false)]
        [ValidateSet("Normal", "Debug")]
        [string]$LogLevel = "Normal"
    )

    Write-Host "[INFO] Generating internal-to-internal pairs..." -ForegroundColor Green

    $internalPairs = @{}
    $pairCounter = 0

    # Create a flattened master list of all valid interfaces to avoid nested loops over devices.
    $allInterfaces = [System.Collections.Generic.List[object]]::new()
    foreach ($device in $InternalDeviceObjects) {
        if ($null -ne $device.interfaces) {
            foreach ($interface in $device.interfaces) {
                # Check for a valid CIDR AND that the interface is not shut down.
                if ((-not ([string]::IsNullOrEmpty($interface.Cidr))) -and (-not $interface.shutdown)) {
                    # --- CHANGE: Add DeviceIdentifier to the object ---
                    $allInterfaces.Add([PSCustomObject]@{
                        Hostname         = $device.hostname
                        DeviceIdentifier = $device.DeviceIdentifier
                        Cidr             = $interface.Cidr
                    })
                }
            }
        }
    }

    # Iterate through the master list to create unique pairs
    for ($i = 0; $i -lt ($allInterfaces.Count - 1); $i++) {
        for ($j = $i + 1; $j -lt $allInterfaces.Count; $j++) {
            $interfaceA = $allInterfaces[$i]
            $interfaceB = $allInterfaces[$j]

            if ($interfaceA.Hostname -eq $interfaceB.Hostname) {
                continue
            }

            $identifierA = "$($interfaceA.Hostname):$($interfaceA.Cidr)"
            $identifierB = "$($interfaceB.Hostname):$($interfaceB.Cidr)"
            $sortedIdentifiers = @($identifierA, $identifierB) | Sort-Object
            $pairKey = $sortedIdentifiers -join '_'

            if (-not $internalPairs.ContainsKey($pairKey)) {
                # --- CHANGE: Add DeviceIdentifierA and DeviceIdentifierB to the pair object ---
                $internalPairs[$pairKey] = Create-PairObject -DeviceA $interfaceA.Hostname `
                    -DeviceIdentifierA $interfaceA.DeviceIdentifier -SubnetA $interfaceA.Cidr `
                    -DeviceB $interfaceB.Hostname -DeviceIdentifierB $interfaceB.DeviceIdentifier `
                    -SubnetB $interfaceB.Cidr

                $pairCounter++
                if ($LogLevel -eq 'Debug' -and $pairCounter % 5000 -eq 0) {
                    Write-Host "[DEBUG] Generated $pairCounter internal pairs..." -ForegroundColor Gray
                }
            }
        }
    }

    Write-Host "[INFO] Generated $($internalPairs.Count) internal pairs." -ForegroundColor Green
    return $internalPairs
}

function Generate-EgressPairs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [array]$InternalDeviceObjects, # No longer need a separate external device list

        [Parameter(Mandatory=$false)]
        [ValidateSet("Normal", "Debug")]
        [string]$LogLevel = "Normal"
    )

    Write-Host "[INFO] Generating internal-to-egress pairs..." -ForegroundColor Green




    $egressPairs = @{}
    $pairCounter = 0

    # Create a flattened list of all valid internal interfaces first.
    $allInternalInterfaces = [System.Collections.Generic.List[object]]::new()
    foreach ($device in $InternalDeviceObjects) {
        if ($null -ne $device.interfaces) {
            foreach ($interface in $device.interfaces) {
                if ((-not ([string]::IsNullOrEmpty($interface.Cidr))) -and (-not $interface.shutdown)) {
                    $allInternalInterfaces.Add( [PSCustomObject]@{
                        Hostname         = $device.hostname
                        DeviceIdentifier = $device.DeviceIdentifier
                        Cidr             = $interface.Cidr
                    })
                }
            }
        }
    }

    # Now, iterate through all internal interfaces and pair them with every discovered external subnet.
    foreach ($internalInt in $allInternalInterfaces) {
        foreach ($edgeDevice in $InternalDeviceObjects) {
            # Check if this device has any external subnets attached
            if ($null -ne $edgeDevice.ExternalSubnets -and $edgeDevice.ExternalSubnets.Count -gt 0) {
                foreach ($externalSubnet in $edgeDevice.ExternalSubnets) {

                    # Do not pair an edge device's internal interface with its own external subnet.
                    # This is typically not a valid or useful path to trace.
                    if ($internalInt.Hostname -eq $edgeDevice.hostname) {
                        continue
                    }

                    # Define unique identifiers for the pair
                    $identifierA = "$($internalInt.Hostname):$($internalInt.Cidr)"
                    # The "endpoint" for an external subnet is the edge device itself and the subnet CIDR.
                    $identifierB = "$($edgeDevice.hostname):$($externalSubnet.Subnet)"

                    $sortedIdentifiers = @($identifierA, $identifierB) | Sort-Object
                    $pairKey = $sortedIdentifiers -join '_'

                    if (-not $egressPairs.ContainsKey($pairKey)) {
                        # Create the pair object.
                        # DeviceB is the REAL edge device. SubnetB is the EXTERNAL subnet.
                        $egressPairs[$pairKey] = Create-PairObject -DeviceA $internalInt.Hostname `
                            -DeviceIdentifierA $internalInt.DeviceIdentifier -SubnetA $internalInt.Cidr `
                            -DeviceB $edgeDevice.hostname -DeviceIdentifierB $edgeDevice.DeviceIdentifier `
                            -SubnetB $externalSubnet.Subnet

                        $pairCounter++
                        if ($LogLevel -eq 'Debug' -and $pairCounter % 5000 -eq 0) {
                            Write-Host "[DEBUG] Generated $pairCounter egress pairs..." -ForegroundColor Gray
                        }
                    }
                }
            }
        }
    }



    Write-Host "[INFO] Generated $($egressPairs.Count) egress pairs." -ForegroundColor Green
    return $egressPairs






}



function Test-IpInSubnet {
    param ([string]$Ip, $Cidr)

    try {
        # If route object has precomputed NetInt/MaskInt, use them
        if ($Cidr -is [psobject] -and $Cidr.PSObject.Properties.Match('NetInt') -and $Cidr.PSObject.Properties.Match('MaskInt')) {
            $ipInt = Convert-IpToUInt32 -Ip $Ip
            return ($ipInt -band $Cidr.MaskInt) -eq $Cidr.NetInt
        }

        # Fallback: handle raw "a.b.c.d/prefix" strings
        if ($Cidr -is [string] -and $Cidr -like "*/*") {
            $ipInt   = Convert-IpToUInt32 -Ip $Ip
            $parts   = $Cidr.Split('/')
            $netInt  = Convert-IpToUInt32 -Ip $parts[0]
            $prefix  = [int]$parts[1]
            $maskInt = if ($prefix -eq 0) { [uint32]0 } else { [uint32]::MaxValue -shl (32 - $prefix) }

            return ($ipInt -band $maskInt) -eq ($netInt -band $maskInt)
        }

        return $false
    }
    catch {
        return $false
    }
}





# ===================================================================
# ========= START: COPY AND REPLACE/ADD THE 4 FUNCTIONS BELOW =========
# ===================================================================

# --- FUNCTION 1 of 4: Get-NextHopInfo (Updated) ---
# Note: The only change is adding 'MatchedRoute' to the $hopInfo object.
function Get-NextHopInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$CurrentDeviceName,

        [Parameter(Mandatory=$true)]
        [string]$DestinationSubnet,

        [Parameter(Mandatory=$true)]
        [hashtable]$DeviceLookupTable,

        # MODIFIED: This parameter now expects the hashtable of Radix Trees.
        [Parameter(Mandatory=$true)]
        [hashtable]$RouteRadixTrees,

        # This parameter is still used by logic in Trace-FullPath
        [Parameter(Mandatory=$true)]
        [string]$EndDeviceName,

        # NEW: LogLevel parameter to enable debug output in the lookup function.
        [Parameter(Mandatory=$false)]
        [ValidateSet("Normal", "Debug")]
        [string]$LogLevel = "Normal"
    )

    try {
        # Using a representative IP from the subnet for the lookup.
        $destIpForLookup = $DestinationSubnet.Split('/')[0]
    } catch {
        # Fallback for invalid CIDR which might be just an IP.
        $destIpForLookup = $DestinationSubnet
    }
    
    # --- START REPLACEMENT ---
    # Find the root node for the current device's routing table.
    $deviceRootNode = if ($RouteRadixTrees.ContainsKey($CurrentDeviceName)) { $RouteRadixTrees[$CurrentDeviceName] } else { $null }

    # The old call to Get-BestRoute is replaced with the new, efficient radix tree lookup.
    $bestRoute = Find-BestRouteInRadixTree -RootNode $deviceRootNode -DestIP $destIpForLookup -Hostname $CurrentDeviceName -LogLevel $LogLevel
    # --- END REPLACEMENT ---

    if ($null -eq $bestRoute) {
        return [PSCustomObject]@{ Status = "No Route"; HopInfo = $null; NextHopDevices = $null }
    }

    $hopInfo = [PSCustomObject]@{
        EgressInterface = $bestRoute.interface
        GatewayUsed     = $bestRoute.gateway
        RouteProtocol   = $bestRoute.RouteProtocol
        MatchedRoute    = $bestRoute.Subnet
    }

    # ========================== REFACTORED LOGIC BLOCK ==========================
    # Check the flag set by Attach-ExternalSubnets. This is the new termination
    # condition for paths leaving the internal network.
    # Check the flag set by Attach-ExternalSubnets only if $bestRoute exists.
    if ($bestRoute -and $bestRoute.IsExternal) {
        return [PSCustomObject]@{ Status = "Reached (External)"; HopInfo = $hopInfo; NextHopDevices = $null }
    }
    # ======================== END REFACTORED LOGIC BLOCK ========================

    $directProtocols = @('local', 'connected', 'direct')
    if ($directProtocols -contains $bestRoute.RouteProtocol) {
        return [PSCustomObject]@{ Status = "Reached"; HopInfo = $hopInfo; NextHopDevices = $null }
    }
    if ($bestRoute.interface -like 'Null*') {
        return [PSCustomObject]@{ Status = "Terminated"; HopInfo = $hopInfo; NextHopDevices = $null }
    }
    if ([string]::IsNullOrEmpty($bestRoute.Gateway)) {
        return [PSCustomObject]@{ Status = "No Route"; HopInfo = $hopInfo; NextHopDevices = $null }
    }

    $nextHopLookup = if ($DeviceLookupTable.ContainsKey($bestRoute.Gateway)) { $DeviceLookupTable[$bestRoute.Gateway] } else { $null }

    if ($null -eq $nextHopLookup) {
        # The new model makes this an error state. If a route has a gateway, but that gateway isn't internal,
        # it should have been flagged as 'IsExternal'. If we get here, it means there's a next-hop
        # to an IP we don't know about, and it's not a configured external route.
        return [PSCustomObject]@{ Status = "Unknown Next Hop"; HopInfo = $hopInfo; NextHopDevices = $null }
    }

    $nextHopDevices = [System.Collections.Generic.List[object]]::new()
    foreach ($hopDetail in $nextHopLookup) {
        $nextHopDevices.Add([PSCustomObject]@{
            DeviceName       = $hopDetail.Hostname
            IngressInterface = $hopDetail.Interface
        })
    }

    return [PSCustomObject]@{ Status = "Continue"; HopInfo = $hopInfo; NextHopDevices = $nextHopDevices }
}

function Create-TransitSubnetLookup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [array]$AllDeviceObjects
    )

    Write-Host "[INFO] Identifying transit subnets..." -ForegroundColor Green

    # Use a hashtable to count device members for each subnet
    $subnetMembership = @{}

    foreach ($device in $AllDeviceObjects) {
        if ($null -ne $device.interfaces) {
            foreach ($interface in $device.interfaces) {
                # Only consider active interfaces with a CIDR
                if ((-not $interface.shutdown) -and (-not [string]::IsNullOrEmpty($interface.Cidr))) {
                    $subnet = $interface.Cidr
                    if (-not $subnetMembership.ContainsKey($subnet)) {
                        $subnetMembership[$subnet] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    }
                    $subnetMembership[$subnet].Add($device.hostname) | Out-Null
                }
            }
        }
    }

    # Create a final, fast-lookup HashSet containing only the transit subnets
    $transitSubnets = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($subnet in $subnetMembership.Keys) {
        # A transit subnet is defined as having more than one device member
        if ($subnetMembership[$subnet].Count -gt 1) {
            $transitSubnets.Add($subnet) | Out-Null
        }
    }

    Write-Host "[INFO] Found $($transitSubnets.Count) transit subnets." -ForegroundColor Green
    return $transitSubnets






}




















# --- FUNCTION 2 of 4: Trace-FullPath (Updated with Verbose Logging) ---

function Trace-FullPath { # V2 with structured objects
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$StartDeviceName,
        [Parameter(Mandatory=$true)]
        [string]$EndDeviceName,
        [Parameter(Mandatory=$true)]
        [string]$EndSubnet,
        [Parameter(Mandatory=$true)]
        [hashtable]$DeviceLookupTable,
        [Parameter(Mandatory=$true)]
        [hashtable]$RouteRadixTrees,
        [Parameter(Mandatory=$true)]
        [array]$AllDeviceObjects,
        [Parameter(Mandatory=$false)]
        [int]$MaxHops = 30,
        [Parameter(Mandatory=$false)]
        [ValidateSet("Normal", "Debug", "Specific")]
        [string]$LogLevel = "Normal",
        [Parameter(Mandatory=$false)]
        [array]$DebugTargets = @()
    )

    $finalizedPaths = [System.Collections.Generic.List[PSCustomObject]]::new()
    $forksToExplore = [System.Collections.Generic.Stack[PSCustomObject]]::new()
    $forksToExplore.Push(
        [PSCustomObject]@{
            PathHistory       = @()
            CurrentDeviceName = $StartDeviceName
            IngressInterface  = "" # The starting point has no ingress interface
        }
    )

    # Explore forks until none are left, but cap at 2 found paths for performance.
    while ($forksToExplore.Count -gt 0 -and $finalizedPaths.Count -lt 2) {
        $currentTrace = $forksToExplore.Pop() # PathHistory on this is a list of temporary hop objects
        $path = [PSCustomObject]@{ Status = "In Progress"; Hops = [System.Collections.Generic.List[object]]::new($currentTrace.PathHistory) }
        $currentDeviceName = $currentTrace.CurrentDeviceName
        $ingressInterface = $currentTrace.IngressInterface

        for ($hopCount = $path.Hops.Count; $hopCount -lt $MaxHops; $hopCount++) {
            $logThisTrace = ($LogLevel -eq 'Debug') -or ($LogLevel -eq 'Specific' -and ($DebugTargets -contains $StartDeviceName -or $DebugTargets -contains $EndSubnet.Split(':')[0]))

            # The old block for handling 'virtual-*' devices is now removed.
            # The trace terminates naturally when Get-NextHopInfo returns 'Reached (External)'.

            # Prevent routing loops
            if ($path.Hops.DeviceName -contains $currentDeviceName) {
                $path.Status = "Loop"
                if ($logThisTrace) { Write-Host "  [FAIL] Loop detected at $($currentDeviceName)" -ForegroundColor Red }
                break
            }

            # Create the basic hop object. It will be enriched with more data after the routing decision.

            $currentHopObject = [PSCustomObject]@{ DeviceName = $currentDeviceName; IngressInterface = $ingressInterface }
            $path.Hops.Add($currentHopObject)






            # Determine the log level for the lookup based on the current trace's debug status.
            $lookupLogLevel = if ($logThisTrace) { 'Debug' } else { 'Normal' }

            $decision = Get-NextHopInfo -CurrentDeviceName $currentDeviceName `
                -DestinationSubnet $EndSubnet `
                -DeviceLookupTable $DeviceLookupTable `
                -RouteRadixTrees $RouteRadixTrees `
                -EndDeviceName $EndDeviceName `
                -LogLevel $lookupLogLevel




            if ($logThisTrace) {
                $ingressLog = if ([string]::IsNullOrEmpty($ingressInterface)) { "(Start of Trace)" } else { $ingressInterface }
                Write-Host "-----------------------------------------------------" -ForegroundColor DarkGray
                Write-Host "[TRACE] Hop $($path.Hops.Count): $currentDeviceName" -ForegroundColor White
                Write-Host "  - Ingress: $ingressLog"
                Write-Host "  - Destination: $EndSubnet"
                if ($null -ne $decision.HopInfo) {
                    Write-Host "  - Decision: Found best route '$($decision.HopInfo.MatchedRoute)' via [$($decision.HopInfo.RouteProtocol)]"
                    if ($decision.Status -eq 'Continue') {
                        $nextDeviceNames = $decision.NextHopDevices.DeviceName -join ', '
                        Write-Host "  - Action: Exiting via interface '$($decision.HopInfo.EgressInterface)' towards gateway '$($decision.HopInfo.GatewayUsed)'"
                        Write-Host "  - Next Device(s): $nextDeviceNames"
                    }
                } else {
                    Write-Host "  - Decision: No route found."
                }
                 Write-Host "  - Path Status: $($decision.Status)"
            }

            # Enrich the current hop object with the decision details
            if ($null -ne $decision.HopInfo) {
                $currentHopObject | Add-Member -MemberType NoteProperty -Name EgressInterface -Value $decision.HopInfo.EgressInterface -Force
                $currentHopObject | Add-Member -MemberType NoteProperty -Name GatewayUsed -Value $decision.HopInfo.GatewayUsed -Force
                $currentHopObject | Add-Member -MemberType NoteProperty -Name RouteProtocol -Value $decision.HopInfo.RouteProtocol -Force
                $currentHopObject | Add-Member -MemberType NoteProperty -Name MatchedRoute -Value $decision.HopInfo.MatchedRoute -Force
            }

            if ($decision.Status -ne "Continue") {
                $path.Status = $decision.Status
                # If we reached the destination subnet on an intermediate device, add the actual endpoint device to the path.
                if ($decision.Status -eq 'Reached' -and $currentDeviceName -ne $EndDeviceName -and $decision.HopInfo.MatchedRoute -eq $EndSubnet) {
                    $finalHopObject = [PSCustomObject]@{
                        DeviceName       = $EndDeviceName
                        IngressInterface = $decision.HopInfo.EgressInterface
                        EgressInterface  = ''
                        GatewayUsed      = ''
                        RouteProtocol    = 'connected'
                        MatchedRoute     = $EndSubnet
                    }
                    $path.Hops.Add($finalHopObject)
                }
                break
            }



            # Handle ECMP or other path forks by queuing them for later exploration
            if ($decision.NextHopDevices.Count -gt 1) {
                for ($i = 1; $i -lt $decision.NextHopDevices.Count; $i++) {
                    $nextHopInfo = $decision.NextHopDevices[$i]
                    if ($logThisTrace) { Write-Host "  [FORK] Queuing alternate path to $($nextHopInfo.DeviceName)" -ForegroundColor Magenta }
                    $forksToExplore.Push(
                        [PSCustomObject]@{
                            PathHistory       = @($path.Hops)
                            CurrentDeviceName = $nextHopInfo.DeviceName
                            IngressInterface  = $nextHopInfo.IngressInterface
                        }
                    )
                }
            }

            # Continue the trace to the next hop
            $currentDeviceName = $decision.NextHopDevices[0].DeviceName
            $ingressInterface = $decision.NextHopDevices[0].IngressInterface
        }

        if ($path.Status -eq "In Progress") { $path.Status = "Max Hops" }
















        # --- CONVERT THE TEMPORARY PATH INTO FINAL, STRUCTURED OBJECTS ---
        $hopObjectArray = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $path.Hops.Count; $i++) {
            $tempHop = $path.Hops[$i]
            $isLastHop = ($i -eq ($path.Hops.Count - 1))
            $hopStatus = ''









            if ($isLastHop) {
                # Map the final path status to a valid Hop status
                switch ($path.Status) {
                    'Reached'             { $hopStatus = 'Reached' }
                    'Reached (External)'{ $hopStatus = 'Reached' }
                    'Terminated'          { $hopStatus = 'Terminated' }
                    'No Route'            { $hopStatus = 'NoRoute' }
                    'Unknown Next Hop'    { $hopStatus = 'NoRoute' } # Treat as a dead end
                    default               { $hopStatus = 'Terminated' } # Loop, Max Hops etc.
                }
            } else {
                # Use a placeholder status for intermediate hops to satisfy the function's mandatory parameter.
                # The overall path status is derived from the LAST hop only, so this is safe.
                $hopStatus = 'Reached'
            }

            $newHop = Create-HopObject -Device $tempHop.DeviceName -Status $hopStatus `
                -Interface $tempHop.EgressInterface -Subnet $tempHop.MatchedRoute -Gateway $tempHop.GatewayUsed

            $hopObjectArray.Add($newHop)
        }


        if ($hopObjectArray.Count -gt 0) {
            $pathNumber = $finalizedPaths.Count + 1
            $finalPathObject = Create-PathObject -HopArray $hopObjectArray -PathNumber $pathNumber
            $finalizedPaths.Add($finalPathObject)
        }
    }
    return $finalizedPaths








}























# --- FUNCTION 3 of 4: Format-PathForConsole (New Helper Function) ---
function Format-PathForConsole {
    param(
        [Parameter(Mandatory=$true)]
        [array]$PathArray,

        [Parameter(Mandatory=$true)]
        [string]$Title
    )

    Write-Host "`n--- $($Title) ---" -ForegroundColor Green
    if ($null -eq $PathObject) {

    if ($null -eq $PathArray -or $PathArray.Count -eq 0) {
        Write-Host "Path has no hops."
        return
    }

    foreach ($path in $PathArray) {
        Write-Host "`n  Path #$($path.PathNumber) | Status: $($path.Status)" -ForegroundColor Cyan
        $hopCounter = 0
        foreach ($hop in $path.HopDetails) {
            $hopCounter++
            Write-Host "     [Hop $hopCounter] Device: $($hop.Device)" -ForegroundColor Yellow
            Write-Host "       - Egress Interface : $($hop.Interface)"
            Write-Host "       - Matched Subnet   : $($hop.Subnet)"
            Write-Host "       - Next-Hop Gateway : $($hop.Gateway)"
        }
    }
    }
}





# --- FUNCTION 4 of 4: Debug-SpecificPair (New Top-Level Debug Function) ---

function Debug-SpecificPair {
    <#
    .SYNOPSIS
        Re-runs a full trace and symmetry analysis for a single, specific pair of devices/subnets.
    .DESCRIPTION
        This function is designed for interactive debugging. It relies on the global/script
        variables ($DeviceLookupTable, etc.) being populated by the main script first.
    .EXAMPLE
        Debug-SpecificPair -DeviceA 'Router-A' -SubnetA '10.1.1.0/24' -DeviceB 'Firewall-B' -SubnetB '10.2.2.0/24'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$DeviceA,
        [Parameter(Mandatory=$true)] [string]$SubnetA,
        [Parameter(Mandatory=$true)] [string]$DeviceB,
        [Parameter(Mandatory=$true)] [string]$SubnetB
    )

    # --- Prerequisite Check ---
    $requiredVars = @('DeviceLookupTable', 'RouteRadixTrees', 'AllDevices', 'MaxHops')
    foreach ($varName in $requiredVars) {
        if (-not (Get-Variable -Name $varName -Scope Script -ErrorAction SilentlyContinue)) {
            Write-Error "Error: Required data table '$($varName)' is not loaded. Please run the main script analysis first."
            return
        }
    }

    # --- Header ---
    Write-Host "========================================================================" -ForegroundColor Magenta
    Write-Host "  DEBUGGING PAIR: $($DeviceA)($($SubnetA)) <-> $($DeviceB)($($SubnetB))"
    Write-Host "========================================================================" -ForegroundColor Magenta

    # --- Trace Forward Path (A -> B) ---
    Write-Host "`n[PHASE] Tracing Forward Path (A -> B)..." -ForegroundColor Cyan
    $forwardPaths = Trace-FullPath -StartDeviceName $DeviceA -EndDeviceName $DeviceB -EndSubnet $SubnetB `
        -DeviceLookupTable $Script:DeviceLookupTable -RouteRadixTrees $Script:RouteRadixTrees `
        -AllDeviceObjects $Script:AllDevices -MaxHops $Script:MaxHops -LogLevel 'Debug'

    # --- Trace Reverse Path (B -> A) ---
    Write-Host "`n[PHASE] Tracing Reverse Path (B -> A)..." -ForegroundColor Cyan
    $reversePaths = Trace-FullPath -StartDeviceName $DeviceB -EndDeviceName $DeviceA -EndSubnet $SubnetA `
        -DeviceLookupTable $Script:DeviceLookupTable -RouteRadixTrees $Script:RouteRadixTrees `
        -AllDeviceObjects $Script:AllDevices -MaxHops $Script:MaxHops -LogLevel 'Debug'

    # --- Build Pair Object for Symmetry Test ---
    # The DeviceIdentifier properties are not available here, so we pass the hostname again.
    $pairObject = Create-PairObject -DeviceA $DeviceA -DeviceIdentifierA $DeviceA -SubnetA $SubnetA `
        -DeviceB $DeviceB -DeviceIdentifierB $DeviceB -SubnetB $SubnetB
    $pairObject.PathsForward = $forwardPaths
    $pairObject.PathsReverse = $reversePaths

    # --- Perform Symmetry Check ---
    Write-Host "`n[PHASE] Performing Symmetry Check..." -ForegroundColor Cyan
    $pairObject.Symmetry = if (Test-PathSymmetry -PairObject $pairObject -LogLevel 'Debug') { "Asymmetric" } else { "Symmetric" }

    # --- Display Formatted Results ---
    Write-Host "`n========================================================================" -ForegroundColor Magenta
    Write-Host "                                  DETAILED PATH ANALYSIS"
    Write-Host "========================================================================" -ForegroundColor Magenta
    Format-PathForConsole -PathArray $pairObject.PathsForward -Title "FORWARD Paths (A -> B)"
    Format-PathForConsole -PathArray $pairObject.PathsReverse -Title "REVERSE Paths (B -> A)"

    # --- Final Verdict ---
    $verdictColor = if ($pairObject.Symmetry -eq 'Asymmetric') { "Red" } else { "Green" }
    Write-Host "`n========================================================================" -ForegroundColor Magenta
    Write-Host "  Final Verdict: " -NoNewline; Write-Host $pairObject.Symmetry -ForegroundColor $verdictColor
    Write-Host "========================================================================" -ForegroundColor Magenta
}

# ===================================================================
# ========================= END OF FUNCTIONS ========================
# ===================================================================


function Get-BestRoute {
    param ([string]$Hostname, [string]$DestIP, [hashtable]$RoutingTables)

    # Your optimization for virtual devices is good, let's keep it.
    # Note: Ensure your virtual device names match this pattern (e.g., 'virtual-*')
    if ($Hostname.StartsWith("virtual-")) { return $null }

    if (-not $RoutingTables.ContainsKey($Hostname)) { return $null }

    # Retrieve the object containing both routes and the pre-sorted keys.
    $deviceRouteInfo = $RoutingTables[$Hostname]

    # The expensive Sort-Object command is now GONE.
    # We iterate directly over the pre-sorted array.
    foreach ($pLen in $deviceRouteInfo.SortedPrefixes) {
        # We now access the routes through the nested property.
        $routesInPrefix = $deviceRouteInfo.RoutesByPrefix[$pLen]
        foreach ($subnet in $routesInPrefix.Keys) {
            if (Test-IpInSubnet -Ip $DestIP -Cidr $subnet) {
                return $routesInPrefix[$subnet]
            }
        }
    }

    return $null
}





function Test-PathSymmetry { # V2 with structured objects
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$PairObject,

        [Parameter(Mandatory=$false)]
        [ValidateSet("Normal", "Debug", "Specific")]
        [string]$LogLevel = "Normal",

        [Parameter(Mandatory=$false)]
        [array]$DebugTargets = @()
    )

    # Helper function to compare two path objects based on their device sequence.
    function Compare-DevicePaths {
        param($pathA, $pathB)
        # The sequence of devices in path A should be the exact reverse of path B.
        $reversedDevicePathB = [string[]]$pathB.DevicePath
        [array]::Reverse($reversedDevicePathB)
        return (Compare-Object -ReferenceObject $pathA.DevicePath -DifferenceObject $reversedDevicePathB -SyncWindow 0) -eq $null
    }

    $logThisCheck = ($LogLevel -eq 'Debug') -or `
                         ($LogLevel -eq 'Specific' -and ($DebugTargets -contains $PairObject.DeviceA -or $DebugTargets -contains $PairObject.DeviceB))

    if ($logThisCheck) {
        Write-Host "[DEBUG] Checking symmetry for $($PairObject.DeviceA) <-> $($PairObject.DeviceB)" -ForegroundColor Gray
    }

    # Simplified Same-Subnet Check
    if ($PairObject.SubnetA -eq $PairObject.SubnetB) {
        # If two devices are in the same subnet, communication is assumed to be symmetric.
        if ($logThisCheck) { Write-Host "[DEBUG] Symmetric: Overridden due to same-subnet communication." -ForegroundColor Gray }
        return $false # Not asymmetric
    }

    # --- Check 1: Outcome Asymmetry ---
    $forwardPrimary = @($PairObject.PathsForward) | Select-Object -First 1
    $reversePrimary = @($PairObject.PathsReverse) | Select-Object -First 1

    # Case: One path was traced, the other was not. Per the new rule, this is Symmetric.
    if (($null -eq $forwardPrimary) -ne ($null -eq $reversePrimary)) {
        if ($logThisCheck) { Write-Host "[DEBUG] Symmetric: Overridden as one path was successful while the other was not traced." }
        return $false # Not Asymmetric
    }

    # Case: Both paths were traced, but their outcomes differ. This is Asymmetric.
    # This check is safe because the above 'if' ensures that if one path is $null, the other must also be $null.
    if ($null -ne $forwardPrimary -and $forwardPrimary.Status -ne $reversePrimary.Status) {
        if ($logThisCheck) { Write-Host "[DEBUG] Asymmetric: Primary path statuses do not match ('$($forwardPrimary.Status)' vs '$($reversePrimary.Status)')." }
        return $true # Asymmetric
    }

    # --- Check 2: Redundancy Asymmetry ---
    $forwardPaths = @($PairObject.PathsForward)
    $reversePaths = @($PairObject.PathsReverse)
    if ($forwardPaths.Count -ne $reversePaths.Count) {
        if ($logThisCheck) { Write-Host "[DEBUG] Asymmetric: Path counts do not match ($($forwardPaths.Count) vs $($reversePaths.Count))." }
        return $true # Asymmetric
    }

    # --- Check 3: Path Set Cross-Comparison ---
    $availableReversePaths = [System.Collections.Generic.List[object]]::new()
    $availableReversePaths.AddRange($reversePaths)
    foreach ($fwdPath in $forwardPaths) {
        $foundMatch = $false
        $matchIndex = -1

        for ($i = 0; $i -lt $availableReversePaths.Count; $i++) {
            $revPath = $availableReversePaths[$i]
            if (Compare-DevicePaths -pathA $fwdPath -pathB $revPath) {
                $foundMatch = $true
                $matchIndex = $i
                if ($logThisCheck) { Write-Host "[DEBUG] Found symmetric match for forward path ($($fwdPath.DevicePath -join '->'))" }
                break
            }
        }

        if ($foundMatch) {
            # Remove the matched path so it can't be used again
            $availableReversePaths.RemoveAt($matchIndex)
        }
        else {
            # This forward path has no symmetric partner in the reverse set
            if ($logThisCheck) { Write-Host "[DEBUG] Asymmetric: No symmetric partner found for forward path ($($fwdPath.DevicePath -join '->'))." }
            return $true # Asymmetric
        }
    }

    # If all forward paths found a unique partner, the connection is symmetric
    if ($logThisCheck) { Write-Host "[DEBUG] Symmetric: All path sets match." -ForegroundColor Gray }
    return $false # Symmetric
}







function Export-TraceAnalysisToHTML {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$PopulatedPairs,
        [Parameter(Mandatory=$true)]
        [string]$OutputPath,
        [Parameter(Mandatory=$true)]
        [System.Collections.Generic.HashSet[string]]$TransitSubnets,
        [Parameter(Mandatory=$true)]
        [array]$AllDeviceObjects
    )

    $exportData = [System.Collections.Generic.List[object]]::new()

    # Create a fast lookup table of all known external subnets.
    $allExternalSubnets = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($device in $AllDeviceObjects) {
        if ($null -ne $device.ExternalSubnets) {
            foreach ($extSubnet in $device.ExternalSubnets) {
                $allExternalSubnets.Add($extSubnet.Subnet) | Out-Null
            }
        }
    }

    # Helper function to generate the detailed Device+Interface path string
    $formatPathWithInterfaces = {
        param($PathObject)
        if ($null -eq $PathObject) { return $PathObject.Status }
        $hops = $PathObject.HopDetails
        $pathParts = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $hops.Count; $i++) {
            $currentHop = $hops[$i]
            $ingressInterface = if ($i -gt 0) { $hops[$i - 1].Interface } else { $null }
            $deviceSpan = "<span class=`"device-hover`" data-device-name=`"$($currentHop.Device)`" data-matched-route=`"$($currentHop.Subnet)`">$($currentHop.Device)</span>"
            $interfaceParts = @()
            if (-not [string]::IsNullOrEmpty($ingressInterface)) { $interfaceParts += "In: $ingressInterface" }
            if (-not [string]::IsNullOrEmpty($currentHop.Interface)) { $interfaceParts += "Out: $($currentHop.Interface)" }
            $displayString = $deviceSpan
            if ($interfaceParts.Count -gt 0) {
                $displayString += " ($($interfaceParts -join ', '))"
            }
            $pathParts.Add($displayString)
        }
        return $pathParts -join ' -> '
    }

    # --- NEW HELPER: Generate Host-Only path with hover pop-ups ---
    $formatPathAsHostOnly = {
        param($PathObject)
        if ($null -eq $PathObject) { return "N/A" }
        $pathParts = [System.Collections.Generic.List[string]]::new()
        foreach ($hop in $PathObject.HopDetails) {
            $pathParts.Add("<span class=`"device-hover`" data-device-name=`"$($hop.Device)`" data-matched-route=`"$($hop.Subnet)`">$($hop.Device)</span>")
        }
        return $pathParts -join ' -> '
    }

    # --- MODIFIED HELPER: Generate IP path with hover pop-ups on gateways ---
    $formatPathWithIPs = {
        param($PathObject, $startSubnet)
        if ($null -eq $PathObject) { return $PathObject.Status }
        $ipParts = @($startSubnet)
        foreach ($hop in $PathObject.HopDetails) {
            if (-not [string]::IsNullOrEmpty($hop.Gateway)) {
                $ipParts += "<span class=`"device-hover`" data-device-name=`"$($hop.Device)`" data-matched-route=`"$($hop.Subnet)`">$($hop.Gateway)</span>"
            }
        }
        return $ipParts -join ' -> '
    }

    foreach ($key in $PopulatedPairs.Keys) {
        $pair = $PopulatedPairs[$key]
        $pathType = if ($allExternalSubnets.Contains($pair.SubnetA) -or $allExternalSubnets.Contains($pair.SubnetB)) { 'External' } else { 'Internal' }
        $pair.PathType = $pathType
        $maxPathCount = [Math]::Max($pair.PathsForward.Count, $pair.PathsReverse.Count)
        if ($maxPathCount -eq 0) { $maxPathCount = 1 }

        for ($i = 0; $i -lt $maxPathCount; $i++) {
            $fwdPath = $pair.PathsForward[$i]
            $revPath = $pair.PathsReverse[$i]
            $row = [PSCustomObject]@{
                PairKey              = $key
                PathRole             = if ($i -eq 0) { "Primary" } else { "Alternate" }
                PathType             = $pathType
                DeviceA              = "<span class='device-info-hover' data-device-name='$($pair.DeviceA)'>$($pair.DeviceA)</span>"
                DeviceA_Identifier   = $pair.DeviceIdentifierA
                SubnetA              = $pair.SubnetA
                SubnetA_IsTransit    = $TransitSubnets.Contains($pair.SubnetA)
                DeviceB              = "<span class='device-info-hover' data-device-name='$($pair.DeviceB)'>$($pair.DeviceB)</span>"
                DeviceB_Identifier   = $pair.DeviceIdentifierB
                SubnetB              = $pair.SubnetB
                SubnetB_IsTransit    = $TransitSubnets.Contains($pair.SubnetB)
                PathAtoB_Interface   = & $formatPathWithInterfaces $fwdPath
                PathAtoB_Host        = & $formatPathAsHostOnly $fwdPath
                PathAtoB_IP          = & $formatPathWithIPs $fwdPath $pair.SubnetA
                ResultAtoB           = if ($fwdPath) { $fwdPath.Status } else { "Not Traced" }
                PathBtoA_Interface   = & $formatPathWithInterfaces $revPath
                PathBtoA_Host        = & $formatPathAsHostOnly $revPath
                PathBtoA_IP          = & $formatPathWithIPs $revPath $pair.SubnetB
                ResultBtoA           = if ($revPath) { $revPath.Status } else { "Not Traced" }
                Symmetry             = $pair.Symmetry
                DeviceA_Raw          = $pair.DeviceA
                DeviceB_Raw          = $pair.DeviceB
            }
            $exportData.Add($row)
        }
    }

    $jsonData = $exportData | ConvertTo-Json -Depth 50 -Compress
    write-host "aaaaaaaaaaaaa"
    # Create a targeted array of objects for the device data.
    $deviceDataForJson = foreach ($device in $AllDeviceObjects) {
        # Create a NEW, clean array of routes by selecting only the properties the tooltip needs.
        # This breaks the reference to the complex radix tree nodes, solving the memory/depth issue.
        # FIX: Create a clean copy of interfaces to remove problematic [REF] properties.
        # Select only the specific, simple properties needed for the report's tooltip.
        $cleanInterfaces = $device.interfaces | Select-Object Interface, Description, IPAddress, SecondaryIPAddress, Cidr, shutdown

        [PSCustomObject]@{
            hostname     = $device.hostname
            interfaces   = $cleanInterfaces   # Use the sanitized interface objects
            RoutingTable = $cleanRoutingTable # Use the clean copy
        }
    }
    
    $jsonDeviceData = $deviceDataForJson | ConvertTo-Json -Depth 50 -Compress

$htmlTemplate = @'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Network Path Analysis</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background-color: #1e1e1e; color: #d4d4d4; margin: 20px; }
        h1 { display: inline-block; }
        .header-container { display: flex; justify-content: center; align-items: center; gap: 20px; margin-bottom: 20px;}
        #controls, #legend { background-color: #252526; padding: 15px; border-radius: 8px; margin-bottom: 20px; display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 15px; align-items: center; border: 1px solid #333; }
        #controls div { display: flex; flex-direction: column; }
        #controls input, #controls select, #controls button { background-color: #3c3c3c; color: #d4d4d4; border: 1px solid #555; padding: 8px; border-radius: 4px; width: 100%; box-sizing: border-box;}
        #controls button { cursor: pointer; text-align: center; }
        #controls button.active { background-color: #007acc; border-color: #007acc; font-weight: bold; }
        #controls label { margin-bottom: 5px; font-size: 0.9em; color: #aaa; }
        #pagination { text-align: center; margin-bottom: 20px; }
        #pagination button { margin: 0 10px; background-color: #3c3c3c; color: #d4d4d4; border: 1px solid #555; padding: 8px 16px; border-radius: 4px; cursor: pointer; }
        #pagination button:disabled { background-color: #2d2d2d; color: #666; cursor: not-allowed; }
        table { width: 100%; border-collapse: collapse; table-layout: fixed; }
        th, td { border: 1px solid #333; padding: 10px; text-align: left; word-break: break-word; font-size: 0.9em; vertical-align: middle; }
        th { background-color: #333333; color: #4ec9b0; position: sticky; top: 0; z-index: 1;}
        .row-asymmetric { background-color: #4d2121; }
        .row-symmetric { background-color: #1a3a1a; }
        .subnet-transit { background-color: #003366; }
        .result-Reached, .result-Reached-External { color: #8fce00; }
        .result-Loop, .result-No-Route { color: #f44747; font-weight: bold; }
        .result-Unknown-Next-Hop, .result-Terminated, .result-Max-Hops { color: #f9d64f; }
        #legend { grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); }
        .legend-item { display: flex; align-items: center; }
        .legend-color-box { width: 15px; height: 15px; border: 1px solid #555; margin-right: 10px; }
        #helpBtn { font-size: 1.2em; font-weight: bold; width: 30px; height: 30px; border-radius: 50%; border: 1px solid #555; background-color: #3c3c3c; color: #d4d4d4; cursor: pointer; }
        .modal-overlay { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background-color: rgba(0,0,0,0.7); display: flex; justify-content: center; align-items: center; z-index: 1000; }
        .modal-content { background-color: #252526; padding: 20px 40px; border-radius: 8px; max-width: 800px; max-height: 80vh; overflow-y: auto; position: relative; border: 1px solid #555;}
        .modal-close { position: absolute; top: 10px; right: 20px; font-size: 2em; cursor: pointer; color: #aaa; }
        .hidden { display: none; }
        dl { display: grid; grid-template-columns: 150px 1fr; gap: 10px 20px; }
        dt { font-weight: bold; color: #4ec9b0; }
        dd { margin: 0; }
        .device-hover, .device-info-hover { cursor: help; text-decoration: underline; text-decoration-style: dotted; }
        #routeTooltip { display: none; position: absolute; z-index: 1001; width: auto; }
        .tooltip-content { position: relative; background-color: #2d2d2d; border: 1px solid #555; border-radius: 5px; padding: 10px; max-width: 850px; max-height: 400px; overflow: auto; box-shadow: 0 5px 15px rgba(0,0,0,0.5); }
        #routeTooltip.pinned .tooltip-content { border: 2px solid #007acc; }
        #routeTooltip table { table-layout: auto; width: 100%; }
        #routeTooltip th, #routeTooltip td { font-size: 0.8em; padding: 5px; border-bottom: 1px solid #444; white-space: nowrap; }
        #routeTooltip .highlight-route td { background-color: #005a9e; color: #fff; }
        .tooltip-close { position: absolute; top: -12px; right: -8px; font-size: 1.5em; color: #ccc; cursor: pointer; font-weight: bold; background-color: #3c3c3c; border-radius: 50%; width: 25px; height: 25px; line-height: 23px; text-align: center; border: 1px solid #555; z-index: 1002; }
        .tooltip-close:hover { color: #fff; background-color: #f44747; }
    </style>
</head>
<body>
    <div class="header-container">
        <h1>Network Path Analysis</h1>
        <button id="helpBtn" onclick="openHelpModal()">?</button>
    </div>
    <div id="controls">
        <div><label for="searchText">Search All Fields</label><input type="text" id="searchText"></div>
        <div><label for="pathTypeFilter">Path Type</label><select id="pathTypeFilter"></select></div>
        <div><label for="symmetryFilter">Symmetry Status</label><select id="symmetryFilter"></select></div>
        <div><label for="transitFilter">Subnet Type</label><select id="transitFilter"></select></div>
        <div><label for="resultFilter">Trace Result</label><select id="resultFilter"></select></div>
        <div><label for="deviceAFilter">Device A</label><select id="deviceAFilter"></select></div>
        <div><label for="subnetAFilter">Subnet A</label><select id="subnetAFilter"></select></div>
        <div><label for="deviceBFilter">Device B</label><select id="deviceBFilter"></select></div>
        <div><label for="subnetBFilter">Subnet B</label><select id="subnetBFilter"></select></div>
        <div><label for="pathViewFilter">Path Display Format</label><select id="pathViewFilter">
            <option value="Interface" selected>Host + Interface</option>
            <option value="Host">Host Only</option>
            <option value="IP">IP Only</option>
        </select></div>
        <div><label for="toggleRouteViewBtn">Interface/Routing Table Pop-up</label><button id="toggleRouteViewBtn">Disabled</button></div>
    </div>
    <div id="pagination">
        <button id="prevBtn">Previous</button>
        <span id="pageInfo"></span>
        <button id="nextBtn">Next</button>
    </div>
    <table id="dataTable">
        <thead>
            <tr>
                <th style="width: 8%;">Path Type</th>
                <th style="width: 15%;">Device A</th>
                <th style="width: 10%;">Subnet A</th>
                <th style="width: 15%;">Device B</th>
                <th style="width: 10%;">Subnet B</th>
                <th style="width: 20%;">Path A -> B</th>
                <th style="width: 7%;">Result A->B</th>
                <th style="width: 20%;">Path B -> A</th>
                <th style="width: 7%;">Result B->A</th>
                <th style="width: 8%;">Symmetry</th>
                <th style="width: 8%;">Path Role</th>
            </tr>
        </thead>
        <tbody></tbody>
    </table>

    <div id="routeTooltip"><div class="tooltip-content"></div></div>

    <div id="helpModal" class="modal-overlay hidden" onclick="if (event.target === this) closeHelpModal()">
        <div class="modal-content">
            <span class="modal-close" onclick="closeHelpModal()">&times;</span>
            <h2>Help: Asymmetric Route Analysis</h2>
            <p>This page displays the results of a network-wide routing analysis. It traces the Layer 3 path between every pair of subnets on all devices to identify routing asymmetries, loops, and dead ends.</p>

            <h3>Filters Explained</h3>
            <dl>
                <dt>Search All Fields</dt>
                <dd>A case-insensitive text search that filters for rows containing your query in any of the columns.</dd>
                <dt>Device/Subnet A/B</dt>
                <dd>Filters the report to show only pairs that match the selected device or subnet.</dd>
                <dt>Symmetry Status</dt>
                <dd>Filters based on the symmetry of the path. "Asymmetric" means the forward path is different from the reverse path in some way (hops, devices, or outcome).</dd>
                <dt>Subnet Type</dt>
                <dd>Filters for pairs that involve a transit link (a subnet with active interfaces on more than one device).</dd>
                <dt>Trace Result</dt>
                <dd>Filters based on the final outcome of the path trace for either direction.</dd>
                <dt>Path Type</dt>
                <dd>Filters the type of device pairing. "Internal" pairs involve two internal devices. "External" pairs involve at least one external (virtual) gateway.</dd>
                <dt>Interface/Routing Table Pop-up</dt>
                <dd>Enables or disables the feature to show a device's routing table (in the path columns) or its interface list (in the Device A/B columns) when you hover over its name.</dd>
            </dl>

            <h3>Result Definitions</h3>
            <dl>
                <dt>Reached</dt>
                <dd>A valid route was found and the destination subnet is connected to the final device in the path.</dd>
                <dt>No Route</dt>
                <dd>A device in the path had no route (including a default route) for the destination IP. The path is a dead end.</dd>
                <dt>Unknown Next Hop</dt>
                <dd>A device has a route, but the next-hop IP address is not a known interface on any other device in the dataset. This often points to an unmonitored device or an internet gateway.</dd>
                <dt>Loop</dt>
                <dd>The trace detected that it visited the same device twice while trying to reach the destination, indicating a routing loop.</dd>
                <dt>Max Hops</dt>
                <dd>The trace exceeded the maximum number of hops before finding the destination.</dd>
            </dl>

            <h3>Legend</h3>
            <div id="legend">
                <div class="legend-item"><div class="legend-color-box row-symmetric"></div> Symmetric Pair</div>
                <div class="legend-item"><div class="legend-color-box row-asymmetric"></div> Asymmetric Pair</div>
                <div class="legend-item"><div class="legend-color-box subnet-transit"></div> Transit Subnet</div>
            </div>
        </div>
    </div>

    <script>
        const allData = ##JSON_DATA##;
        const allDeviceData = ##JSON_DEVICE_DATA##;
        const deviceMap = new Map(allDeviceData.map(d => [d.hostname, d]));
        let currentFilteredData = [];
        let currentPage = 1;
        const rowsPerPage = 200;
        let debounceTimer;
        let isRouteViewEnabled = false;
        let hideTooltipTimer = null;
        let pinnedTooltip = false;

        allData.forEach(row => {
            // Add raw device names to searchable string, since the display properties now contain HTML
            row.searchableString = Object.values(row).join(' ').toLowerCase() + ` ${row.DeviceA_Raw} ${row.DeviceB_Raw}`;
        });

        const helpModal = document.getElementById('helpModal');
        function openHelpModal() { helpModal.classList.remove('hidden'); }
        function closeHelpModal() { helpModal.classList.add('hidden'); }

        const searchText = document.getElementById('searchText');
        const pathTypeFilter = document.getElementById('pathTypeFilter');
        const symmetryFilter = document.getElementById('symmetryFilter');
        const transitFilter = document.getElementById('transitFilter');
        const resultFilter = document.getElementById('resultFilter');
        const deviceAFilter = document.getElementById('deviceAFilter');
        const subnetAFilter = document.getElementById('subnetAFilter');
        const deviceBFilter = document.getElementById('deviceBFilter');
        const subnetBFilter = document.getElementById('subnetBFilter');
        const pathViewFilter = document.getElementById('pathViewFilter');
        const tableBody = document.querySelector("#dataTable tbody");
        const toggleBtn = document.getElementById('toggleRouteViewBtn');
        const tooltip = document.getElementById('routeTooltip');
        const tooltipContent = tooltip.querySelector('.tooltip-content');

        toggleBtn.addEventListener('click', () => {
            isRouteViewEnabled = !isRouteViewEnabled;
            toggleBtn.textContent = isRouteViewEnabled ? 'Enabled' : 'Disabled';
            toggleBtn.classList.toggle('active', isRouteViewEnabled);
            if (!isRouteViewEnabled && pinnedTooltip) {
                unpinTooltip();
            }
        });

        const showRoutingTooltip = (target, isClick) => {
            const deviceName = target.dataset.deviceName;
            const matchedRoute = target.dataset.matchedRoute;
            const device = deviceMap.get(deviceName);

            let contentHtml = '';
            if (!device || !device.RoutingTable || device.RoutingTable.length === 0) {
                contentHtml = `No routing data for <b>${deviceName}</b>`;
            } else {
                let tableHtml = `<b>Routing Table: ${deviceName}</b><table><thead><tr><th>Subnet</th><th>Gateway</th><th>Interface</th><th>Protocol</th></tr></thead><tbody>`;
                device.RoutingTable.forEach(route => {
                    const highlightClass = route.Subnet === matchedRoute ? 'class="highlight-route"' : '';
                    tableHtml += `<tr ${highlightClass}>
                        <td>${route.Subnet || ''}</td>
                        <td>${route.gateway || ''}</td>
                        <td>${route.interface || ''}</td>
                        <td>${route.RouteProtocol || ''}</td>
                    </tr>`;
                });
                tableHtml += `</tbody></table>`;
                contentHtml = tableHtml;
            }
            return contentHtml;
        };

        const showInterfaceTooltip = (target, isClick) => {
            const deviceName = target.dataset.deviceName;
            const device = deviceMap.get(deviceName);

            let contentHtml = '';
            if (!device || !device.interfaces || device.interfaces.length === 0) {
                contentHtml = `No interface data for <b>${deviceName}</b>`;
            } else {
                let listHtml = `<b>Interfaces: ${deviceName}</b><ul style="margin: 5px 0 0 15px; padding: 0; list-style-type: none;">`;
                device.interfaces.forEach(intf => {
                    if (!intf.shutdown && intf.Cidr) {
                        listHtml += `<li>${intf.Interface}: ${intf.Cidr}</li>`;
                    }
                });
                listHtml += '</ul>';
                contentHtml = listHtml;
            }
            return contentHtml;
        };

        const showTooltip = (target, isClick, contentGenerator) => {
            if (!isRouteViewEnabled) return;
            if (pinnedTooltip && !isClick) return;

            clearTimeout(hideTooltipTimer);
            if (pinnedTooltip) unpinTooltip();

            tooltipContent.innerHTML = contentGenerator(target, isClick);
            tooltip.style.display = 'block';

            if (isClick) {
                tooltip.classList.add('pinned');
                pinnedTooltip = true;
                const closeButton = document.createElement('span');
                closeButton.className = 'tooltip-close';
                closeButton.innerHTML = '&times;';
                tooltip.appendChild(closeButton);
                closeButton.addEventListener('click', unpinTooltip);
            }

            const highlightedRow = tooltipContent.querySelector('.highlight-route');
            if (highlightedRow) {
                const scroller = tooltipContent;
                scroller.scrollTop = highlightedRow.offsetTop - (scroller.clientHeight / 2) + (highlightedRow.offsetHeight / 2);
            }
        };

        const hideTooltip = () => {
            if (pinnedTooltip) return;
            tooltip.style.display = 'none';
        };

        const unpinTooltip = () => {
            tooltip.classList.remove('pinned');
            pinnedTooltip = false;
            tooltip.style.display = 'none';
            const closeBtn = tooltip.querySelector('.tooltip-close');
            if(closeBtn) closeBtn.remove();
        }

        tableBody.addEventListener('mouseover', (e) => {
            let contentGenerator = null;
            if (e.target.matches('.device-hover')) contentGenerator = showRoutingTooltip;
            if (e.target.matches('.device-info-hover')) contentGenerator = showInterfaceTooltip;

            if (contentGenerator) {
                showTooltip(e.target, false, contentGenerator);
                tooltip.style.left = `${e.pageX + 15}px`;
                tooltip.style.top = `${e.pageY + 15}px`;
            }
        });

        tableBody.addEventListener('mouseout', (e) => {
            if (e.target.matches('.device-hover') || e.target.matches('.device-info-hover')) {
                clearTimeout(hideTooltipTimer);
                hideTooltipTimer = setTimeout(hideTooltip, 200);
            }
        });

        tableBody.addEventListener('click', (e) => {
            let contentGenerator = null;
            if (e.target.matches('.device-hover')) contentGenerator = showRoutingTooltip;
            if (e.target.matches('.device-info-hover')) contentGenerator = showInterfaceTooltip;

            if (contentGenerator) {
                e.preventDefault();
                showTooltip(e.target, true, contentGenerator);
                tooltip.style.left = `${e.pageX + 15}px`;
                tooltip.style.top = `${e.pageY + 15}px`;
            }
        });

        tooltip.addEventListener('mouseover', () => clearTimeout(hideTooltipTimer));
        tooltip.addEventListener('mouseout', () => {
            clearTimeout(hideTooltipTimer);
            hideTooltipTimer = setTimeout(hideTooltip, 200);
        });

        function applyFilters() {
            const search = searchText.value.toLowerCase();
            const pathType = pathTypeFilter.value;
            const symmetry = symmetryFilter.value;
            const transit = transitFilter.value;
            const result = resultFilter.value;
            const deviceA_val = deviceAFilter.value;
            const subnetA_val = subnetAFilter.value;
            const deviceB_val = deviceBFilter.value;
            const subnetB_val = subnetBFilter.value;

            const pairs = new Map();
            allData.forEach(row => {
                if (!pairs.has(row.PairKey)) {
                    pairs.set(row.PairKey, []);
                }
                pairs.get(row.PairKey).push(row);
            });

            const filteredRows = [];
            for (const [pairKey, rows] of pairs.entries()) {
                const isMatch = rows.some(row => {
                    const searchMatch = search === '' || row.searchableString.includes(search);
                    const pathTypeMatch = (pathType === 'all') || (row.PathType === pathType);
                    const symmetryMatch = (symmetry === 'all') || (row.Symmetry.toLowerCase().startsWith(symmetry));
                    const transitMatch = (transit === 'all') ||
                                         (transit === 'transit' && (row.SubnetA_IsTransit || row.SubnetB_IsTransit)) ||
                                         (transit === 'nontransit' && !row.SubnetA_IsTransit && !row.SubnetB_IsTransit);
                    const resultMatch = (result === 'all') || (row.ResultAtoB === result) || (row.ResultBtoA === result);

                    // --- NEW FILTERING LOGIC ---
                    const deviceA_isSet = deviceA_val !== 'all';
                    const deviceB_isSet = deviceB_val !== 'all';
                    let deviceMatch = false;
                    if (!deviceA_isSet && !deviceB_isSet) {
                        deviceMatch = true;
                    } else if (deviceA_isSet && !deviceB_isSet) {
                        deviceMatch = row.DeviceA_Raw === deviceA_val || row.DeviceB_Raw === deviceA_val;
                    } else if (!deviceA_isSet && deviceB_isSet) {
                        deviceMatch = row.DeviceA_Raw === deviceB_val || row.DeviceB_Raw === deviceB_val;
                    } else { // Both are set
                        deviceMatch = (row.DeviceA_Raw === deviceA_val && row.DeviceB_Raw === deviceB_val) ||
                                      (row.DeviceA_Raw === deviceB_val && row.DeviceB_Raw === deviceA_val);
                    }

                    const subnetA_isSet = subnetA_val !== 'all';
                    const subnetB_isSet = subnetB_val !== 'all';
                    let subnetMatch = false;
                    if (!subnetA_isSet && !subnetB_isSet) {
                        subnetMatch = true;
                    } else if (subnetA_isSet && !subnetB_isSet) {
                        subnetMatch = row.SubnetA === subnetA_val || row.SubnetB === subnetA_val;
                    } else if (!subnetA_isSet && subnetB_isSet) {
                         subnetMatch = row.SubnetA === subnetB_val || row.SubnetB === subnetB_val;
                    } else { // Both are set
                         subnetMatch = (row.SubnetA === subnetA_val && row.SubnetB === subnetB_val) ||
                                       (row.SubnetA === subnetB_val && row.SubnetB === subnetA_val);

                    }
                    // --- END NEW FILTERING LOGIC ---

                    return searchMatch && pathTypeMatch && symmetryMatch && transitMatch && resultMatch && deviceMatch && subnetMatch;
                });

                if (isMatch) {
                    filteredRows.push(...rows);
                }
            }

            currentFilteredData = filteredRows;
            currentPage = 1;
            renderPage();
        }

        function renderPage() {
            const start = (currentPage - 1) * rowsPerPage;
            const end = start + rowsPerPage;
            const paginatedData = currentFilteredData.slice(start, end);

            tableBody.innerHTML = "";
            let lastPairKey = null;

            for (let i = 0; i < paginatedData.length; i++) {
                const row = paginatedData[i];
                let isFirstInPair = (row.PairKey !== lastPairKey);
                let rowSpan = 1;

                if (isFirstInPair) {
                    const pairRows = currentFilteredData.filter(r => r.PairKey === row.PairKey);
                    rowSpan = pairRows.length;
                }

                const tr = document.createElement('tr');
                tr.className = row.Symmetry === 'Asymmetric' ? 'row-asymmetric' : 'row-symmetric';

                const resultAtoB_class = "result-" + (row.ResultAtoB || "unknown").replace(/\s/g, '-').replace(/[()]/g, '');
                const resultBtoA_class = "result-" + (row.ResultBtoA || "unknown").replace(/\s/g, '-').replace(/[()]/g, '');

                let deviceADisplay = row.DeviceA; // Already contains HTML span
                if (row.DeviceA_Identifier && row.DeviceA_Identifier !== row.DeviceA_Raw) {
                    deviceADisplay += ` (${row.DeviceA_Identifier})`;
                }
                let deviceBDisplay = row.DeviceB; // Already contains HTML span
                if (row.DeviceB_Identifier && row.DeviceB_Identifier !== row.DeviceB_Raw) {
                    deviceBDisplay += ` (${row.DeviceB_Identifier})`;
                }

                const subnetA_class = row.SubnetA_IsTransit ? 'subnet-transit' : '';
                const subnetB_class = row.SubnetB_IsTransit ? 'subnet-transit' : '';

                const pathViewKeyA = 'PathAtoB_' + pathViewFilter.value;
                const pathViewKeyB = 'PathBtoA_' + pathViewFilter.value;

                let html = '';
                if (isFirstInPair) {
                    html += `<td rowspan="${rowSpan}">${row.PathType}</td>`;
                    html += `<td rowspan="${rowSpan}">${deviceADisplay}</td>`;
                    html += `<td class="${subnetA_class}" rowspan="${rowSpan}">${row.SubnetA}</td>`;
                    html += `<td rowspan="${rowSpan}">${deviceBDisplay}</td>`;
                    html += `<td class="${subnetB_class}" rowspan="${rowSpan}">${row.SubnetB}</td>`;
                }

                html += `<td>${row[pathViewKeyA] || ''}</td>`;
                html += `<td class="${resultAtoB_class}">${row.ResultAtoB}</td>`;
                html += `<td>${row[pathViewKeyB] || ''}</td>`;
                html += `<td class="${resultBtoA_class}">${row.ResultBtoA}</td>`;

                if (isFirstInPair) {
                    html += `<td rowspan="${rowSpan}">${row.Symmetry}</td>`;
                }

                html += `<td>${row.PathRole}</td>`;

                tr.innerHTML = html;
                tableBody.appendChild(tr);
                lastPairKey = row.PairKey;
            }
            updatePagination();
        }

        function updatePagination() {
            const totalPages = Math.ceil(currentFilteredData.length / rowsPerPage);
            document.getElementById('pageInfo').textContent = `Page ${currentPage} of ${totalPages || 1}`;
            document.getElementById('prevBtn').disabled = currentPage === 1;
            document.getElementById('nextBtn').disabled = currentPage === totalPages || totalPages === 0;
        }

        function populateFilters() {
            const populateSelect = (element, dataKey, label) => {
                const uniqueValues = [...new Set(allData.map(r => r[dataKey]))].filter(Boolean).sort();
                element.innerHTML = `<option value="all">All ${label}</option>` + uniqueValues.map(v => `<option value="${v}">${v}</option>`).join('');
            };

            pathTypeFilter.innerHTML = '<option value="all">All Path Types</option><option value="Internal">Internal Only</option><option value="External">External Only</option>';
            symmetryFilter.innerHTML = '<option value="all">All Symmetries</option><option value="asymmetric">Asymmetric Only</option><option value="symmetric">Symmetric Only</option>';
            transitFilter.innerHTML = '<option value="all">All Subnet Types</option><option value="transit">Transit Only</option><option value="nontransit">Non-Transit Only</option>';
            populateSelect(resultFilter, 'ResultAtoB', 'Results');
            populateSelect(deviceAFilter, 'DeviceA_Raw', 'Device A');
            populateSelect(subnetAFilter, 'SubnetA', 'Subnet A');
            populateSelect(deviceBFilter, 'DeviceB_Raw', 'Device B');
            populateSelect(subnetBFilter, 'SubnetB', 'Subnet B');
        }

        document.addEventListener('DOMContentLoaded', () => {
            populateFilters();
            applyFilters();

            const allFilters = [searchText, pathTypeFilter, symmetryFilter, transitFilter, resultFilter, deviceAFilter, subnetAFilter, deviceBFilter, subnetBFilter, pathViewFilter];
            allFilters.forEach(el => {
                const eventType = el.tagName === 'INPUT' ? 'input' : 'change';
                const eventHandler = el.id === 'pathViewFilter' ? renderPage : applyFilters;
                el.addEventListener(eventType, () => {
                    clearTimeout(debounceTimer);
                    debounceTimer = setTimeout(eventHandler, 300);
                });
            });

            document.getElementById('prevBtn').addEventListener('click', () => { if (currentPage > 1) { currentPage--; renderPage(); } });
            document.getElementById('nextBtn').addEventListener('click', () => { if (currentPage * rowsPerPage < currentFilteredData.length) { currentPage++; renderPage(); } });
        });
    </script>
</body>
</html>
'@

    $finalHtml = $htmlTemplate.Replace('##JSON_DATA##', $jsonData).Replace('##JSON_DEVICE_DATA##', $jsonDeviceData)


    try {
        Set-Content -Path $OutputPath -Value $finalHtml -Encoding UTF8
        Write-Host "[INFO] Successfully exported analysis to '$OutputPath'" -ForegroundColor Green
    }
    catch {
        Write-Error "[ERROR] Failed to write to '$OutputPath'. Error: $_"
    }
}

function Invoke-NetworkPathAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [array]$DeviceData,

        [Parameter(Mandatory = $false)]
        [string]$ReportPath = ".\$((Get-Date).ToString('yyyyMMdd-HHmmss'))-Analysis.html",

        [Parameter(Mandatory = $false)]
        [int]$MaxHops = 30,

        [Parameter(Mandatory = $false)]
        [hashtable]$LoggingConfiguration = @{},

        [Parameter(Mandatory = $false)]
        [array]$DebugTargets = @(),

        [Parameter(Mandatory = $false)]
        [switch]$Passthru
    )

    $totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Helper to get the configured log level for a function, defaulting to "Normal"
    $getLogLevel = {
        param($functionName)
        if ($LoggingConfiguration.ContainsKey($functionName)) {
            return $LoggingConfiguration[$functionName]
        }
        return "Normal"
    }

    # =================================================================
    # PHASE 1: Data Preparation
    # =================================================================
    $phase1Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Verbose "[PHASE 1] Starting data preparation..."

    Write-Verbose "[PRE-FLIGHT] Filtering out devices with no routing table..."
    $initialDeviceCount = $DeviceData.Count
    $GArrayOfObjectsFilter = $DeviceData | Where-Object { $null -ne $_.RoutingTable -and $_.RoutingTable.Count -gt 0 }
    $finalDeviceCount = $GArrayOfObjectsFilter.Count
    $removedCount = $initialDeviceCount - $finalDeviceCount
    Write-Verbose "[INFO] Removed $removedCount devices with no routing information. Continuing with $finalDeviceCount devices."

    # This ensures data integrity by adding 'connected' routes for any active interfaces.
    $GArrayOfObjectsFilter = Add-ConnectedInterfaceRoutes -DeviceObjects $GArrayOfObjectsFilter

    $deviceLookupLogLevel = & $getLogLevel "DeviceLookup"
    $DeviceLookupTable = Create-DeviceLookupTable -GArrayOfObjectsFilter $GArrayOfObjectsFilter -LogLevel $deviceLookupLogLevel

    # The 'Attach-ExternalSubnets' function now handles external route discovery.
    $externalSubnetLogLevel = & $getLogLevel "ExternalSubnet"
    $GArrayOfObjectsFilter = Attach-ExternalSubnets -AllDeviceObjects $GArrayOfObjectsFilter -DeviceLookupTable $DeviceLookupTable -LogLevel $externalSubnetLogLevel

    # All devices are the real devices from the filtered list.
    $AllDevices = $GArrayOfObjectsFilter

    # --- Call the function to identify transit subnets ---
    $transitSubnets = Create-TransitSubnetLookup -AllDeviceObjects $AllDevices

    $routeLookupLogLevel = & $getLogLevel "RouteLookup"
    $RouteRadixTrees = Create-RouteRadixTrees -AllDeviceObjects $AllDevices -LogLevel $routeLookupLogLevel

    Write-Verbose "[INFO] Data preparation complete. Processed $($GArrayOfObjectsFilter.Count) devices and their external routes."
    $phase1Stopwatch.Stop()
    Write-Host "[BENCHMARK] Phase 1 (Data Preparation) took $($phase1Stopwatch.Elapsed.TotalSeconds) seconds." -ForegroundColor Magenta

    # =================================================================
    # PHASE 2: Pair Generation
    # =================================================================
    $phase2Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Verbose "[PHASE 2] Starting pair generation..."
    $pairGenLogLevel = & $getLogLevel "PairGeneration"

    $internalPairs = Generate-InternalPairs -InternalDeviceObjects $GArrayOfObjectsFilter -LogLevel $pairGenLogLevel
    $egressPairs = Generate-EgressPairs -InternalDeviceObjects $GArrayOfObjectsFilter -LogLevel $pairGenLogLevel

    # Combine the two hashtables of pairs into one master hashtable
    $allPairs = $internalPairs.Clone()
    foreach ($key in $egressPairs.Keys) {
        if (-not $allPairs.ContainsKey($key)) {
            $allPairs[$key] = $egressPairs[$key]
        }
    }

    Write-Verbose "[INFO] Pair generation complete. Found $($allPairs.Count) total unique pairs to trace."
    $phase2Stopwatch.Stop()
    Write-Host "[BENCHMARK] Phase 2 (Pair Generation) took $($phase2Stopwatch.Elapsed.TotalSeconds) seconds." -ForegroundColor Magenta

    # =================================================================
    # PHASE 3: Path Tracing and Symmetry Analysis (Parallel Version)
    # =================================================================
    $phase3Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Verbose "[PHASE 3] Starting path tracing for all $($allPairs.Count) pairs..."
    $traceLogLevel = & $getLogLevel "PathTrace"
    $symmetryLogLevel = & $getLogLevel "SymmetryCheck"

    $ThrottleLimit = [System.Environment]::ProcessorCount
    
    $pairKeys = $allPairs.Keys | ForEach-Object { $_ }

    # Capture the output from all parallel threads into a single variable.
    $processedResults = $pairKeys | ForEach-Object -Parallel {
        # Inside a parallel script block, we must pass in variables using the '$using:' scope.
        $GPathToScript                = $using:GPathToScript
        Import-Module "$($GPathToScript)Network Path Analysis.ps1" -Force
        $key = $_
        $pair = ($using:allPairs)[$key]

        # --- Trace Forward Path (A -> B) ---
        $forwardPaths = Trace-FullPath -StartDeviceName $pair.DeviceA -EndDeviceName $pair.DeviceB -EndSubnet $pair.SubnetB `
            -DeviceLookupTable $using:DeviceLookupTable -RouteRadixTrees $using:RouteRadixTrees `
            -AllDeviceObjects $using:AllDevices -MaxHops $using:MaxHops -LogLevel $using:traceLogLevel -DebugTargets $using:DebugTargets

        # --- Trace Reverse Path (B -> A) ---
        $reversePaths = Trace-FullPath -StartDeviceName $pair.DeviceB -EndDeviceName $pair.DeviceA -EndSubnet $pair.SubnetA `
            -DeviceLookupTable $using:DeviceLookupTable -RouteRadixTrees $using:RouteRadixTrees `
            -AllDeviceObjects $using:AllDevices -MaxHops $using:MaxHops -LogLevel $using:traceLogLevel -DebugTargets $using:DebugTargets

        $pair.PathsForward = $forwardPaths
        $pair.PathsReverse = $reversePaths

        $isAsymmetric = Test-PathSymmetry -PairObject $pair -LogLevel $using:symmetryLogLevel -DebugTargets $using:DebugTargets
        $pair.Symmetry = if ($isAsymmetric) { "Asymmetric" } else { "Symmetric" }

        [PSCustomObject]@{
            Key   = $key
            Value = $pair
        }

    } -ThrottleLimit $ThrottleLimit

    # After the parallel loop finishes, update the original hashtable with the collected results.
    foreach ($result in $processedResults) {
        $allPairs[$result.Key] = $result.Value
    }

    Write-Verbose "[INFO] Path tracing and analysis complete."
    $phase3Stopwatch.Stop()
    Write-Host "[BENCHMARK] Phase 3 (Path Tracing) took $($phase3Stopwatch.Elapsed.TotalSeconds) seconds." -ForegroundColor Magenta

    # =================================================================
    # PHASE 4: Reporting
    # =================================================================
    $phase4Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Verbose "[PHASE 4] Generating HTML report at '$ReportPath'..."

    Export-TraceAnalysisToHTML -PopulatedPairs $allPairs -OutputPath $ReportPath -TransitSubnets $transitSubnets -AllDeviceObjects $AllDevices

    Write-Verbose "[INFO] Analysis complete."
    $phase4Stopwatch.Stop()
    Write-Host "[BENCHMARK] Phase 4 (Reporting) took $($phase4Stopwatch.Elapsed.TotalSeconds) seconds." -ForegroundColor Magenta
    
    $totalStopwatch.Stop()
    Write-Host "[BENCHMARK] Total execution time took $($totalStopwatch.Elapsed.TotalSeconds) seconds." -ForegroundColor Green


    if ($Passthru) {
        $result = [PSCustomObject]@{
            ReportPath   = $ReportPath
            AnalysisData = $allPairs
        }
        return $result
    }
}













