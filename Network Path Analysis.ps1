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

    if (-not $DeviceLookup.ContainsKey($Ip)) {
        # This is the first time we've seen this IP. Add a new entry.
        # Store an array of objects, each containing the Hostname AND the Interface.
        $DeviceLookup[$Ip] = @([PSCustomObject]@{
            Hostname  = $CurrentDevice.hostname
            Interface = $CurrentInterface.Interface
        })
    }
    else {
        # This IP already exists. Add the new Hostname/Interface object to the array.
        $DeviceLookup[$Ip] += [PSCustomObject]@{
            Hostname  = $CurrentDevice.hostname
            Interface = $CurrentInterface.Interface
        }
        
        if ($LogLevel -eq 'Debug') {
            $deviceAndInterfaceLog = $DeviceLookup[$Ip] | ForEach-Object { "$($_.Hostname)($($_.Interface))" } | Sort-Object -Unique
            Write-Host "[WARN] Shared IP $Ip detected on devices: $($deviceAndInterfaceLog -join ', ')" -ForegroundColor Yellow
        }
    }
}
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

        # --- FIX: Create and populate the HashSet in two steps for reliability ---
        # 1. Create an empty, case-insensitive HashSet first.
        $existingSubnets = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        
        # 2. Then, safely populate it from the routing table if it exists.
        if ($null -ne $device.RoutingTable) {
            foreach ($route in $device.RoutingTable) {
                if (-not [string]::IsNullOrEmpty($route.Subnet)) {
                    # Add the subnet to our lookup set
                    $existingSubnets.Add($route.Subnet) | Out-Null
                }
            }
        }
        # --- END FIX ---

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
                    # Add the new 'connected' route to this device's routing table
                    $device.RoutingTable += $newRoute
                    $addedRoutesCount++
                }
            }
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



function Create-ExternalVirtualDevices {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [array]$GArrayOfObjectsFilter,

        [Parameter(Mandatory=$true)]
        [hashtable]$DeviceLookupTable,

        [Parameter(Mandatory=$false)]
        [ValidateSet("Normal", "Debug")]
        [string]$LogLevel = "Normal"
    )

    Write-Host "[INFO] Identifying external gateways..." -ForegroundColor Green

    # This hashtable will group all external routes by their unique key: "OriginDeviceIdentifier_GatewayIP"
    $externalRoutesGrouped = @{}

    foreach ($device in $GArrayOfObjectsFilter) {
        # Skip devices that have no routing table or identifier
        if ($null -eq $device.RoutingTable -or [string]::IsNullOrEmpty($device.hostname)) {
            continue
        }

        foreach ($route in $device.RoutingTable) {
            # An external route must have a gateway and that gateway must not be in our internal IP lookup table
            if (-not ([string]::IsNullOrEmpty($route.Gateway)) -and -not $DeviceLookupTable.ContainsKey($route.Gateway)) {
                
                $key = "$($device.hostname)_$($route.Gateway)"

                if (-not $externalRoutesGrouped.ContainsKey($key)) {
                    # This is the first time we see this unique combination of an origin device and an external gateway
                    $externalRoutesGrouped[$key] = @{
                        OriginDevice = $device
                        GatewayIP    = $route.Gateway
                        Subnets      = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    }
                }
                
                # Add the destination subnet for this route to the set (HashSet handles duplicates)
                $externalRoutesGrouped[$key].Subnets.Add($route.Subnet) | Out-Null
            }
        }
    }

    $virtualDevices = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($groupKey in $externalRoutesGrouped.Keys) {
        $group = $externalRoutesGrouped[$groupKey]
        $originDevice = $group.OriginDevice
        $gatewayIp = $group.GatewayIP

        # Create one virtual device object per host for each unique external gateway IP found
        $virtualDevice = Create-HostObject # Use your existing function to get the base schema
        
        # Set the unique hostname and identifier as per the prompt's logic
        $virtualDevice.hostname = "virtual-$($originDevice.hostname)-$($gatewayIp)"
        $virtualDevice.DeviceIdentifier = "virtual-$($originDevice.hostname)-$($gatewayIp)"
        $virtualDevice.DeviceType = "Virtual Gateway"
        $virtualDevice.Origin = "Discovered via $($originDevice.hostname)"

        # For each destination subnet, create a corresponding InterfaceObject
        $virtualInterfaces = @()
        foreach ($subnet in $group.Subnets) {
            $virtualInterface = Create-InterfaceObject # Use your existing function
            $virtualInterface.Interface = "virtual-route-to-$($subnet -replace '/', '_')"
            $virtualInterface.Cidr = $subnet
            $virtualInterface.shutdown = $false
            $virtualInterface.IntStatus = 'up'
            $virtualInterface.INTProtocolStatus = 'up'
            $virtualInterfaces += $virtualInterface
        }
        $virtualDevice.interfaces = $virtualInterfaces

        $virtualDevices.Add($virtualDevice)

        if ($LogLevel -eq 'Debug') {
            Write-Host "[DEBUG] Created virtual device '$($virtualDevice.hostname)' for external gateway $($gatewayIp) (discovered via route on $($originDevice.hostname))." -ForegroundColor Cyan
        }
    }

    Write-Host "[INFO] Finished. Created $($virtualDevices.Count) virtual external devices." -ForegroundColor Green
    
    return $virtualDevices
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
    $allInterfaces = @()
    foreach ($device in $InternalDeviceObjects) {
        if ($null -ne $device.interfaces) {
            foreach ($interface in $device.interfaces) {
                # Check for a valid CIDR AND that the interface is not shut down.
                if ((-not ([string]::IsNullOrEmpty($interface.Cidr))) -and (-not $interface.shutdown)) {
                    # --- CHANGE: Add DeviceIdentifier to the object ---
                    $allInterfaces += [PSCustomObject]@{
                        Hostname         = $device.hostname
                        DeviceIdentifier = $device.DeviceIdentifier
                        Cidr             = $interface.Cidr
                    }
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
                $internalPairs[$pairKey] = [PSCustomObject]@{
                    DeviceA           = $interfaceA.Hostname
                    DeviceIdentifierA = $interfaceA.DeviceIdentifier
                    SubnetA           = $interfaceA.Cidr
                    DeviceB           = $interfaceB.Hostname
                    DeviceIdentifierB = $interfaceB.DeviceIdentifier
                    SubnetB           = $interfaceB.Cidr
                }

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
        [array]$InternalDeviceObjects,

        [Parameter(Mandatory=$true)]
        [array]$ExternalVirtualDevices,

        [Parameter(Mandatory=$false)]
        [ValidateSet("Normal", "Debug")]
        [string]$LogLevel = "Normal"
    )

    Write-Host "[INFO] Generating internal-to-egress pairs..." -ForegroundColor Green

    $egressPairs = @{}
    $pairCounter = 0

    foreach ($internalDevice in $InternalDeviceObjects) {
        if ($null -ne $internalDevice.interfaces) {
            foreach ($internalInterface in $internalDevice.interfaces) {
                if (([string]::IsNullOrEmpty($internalInterface.Cidr)) -or $internalInterface.shutdown) {
                    continue
                }

                foreach ($virtualDevice in $ExternalVirtualDevices) {
                    if ($null -ne $virtualDevice.interfaces) {
                        foreach ($virtualInterface in $virtualDevice.interfaces) {
                            $identifierA = "$($internalDevice.hostname):$($internalInterface.Cidr)"
                            $identifierB = "$($virtualDevice.hostname):$($virtualInterface.Cidr)"
                            $sortedIdentifiers = @($identifierA, $identifierB) | Sort-Object
                            $pairKey = $sortedIdentifiers -join '_'

                            if (-not $egressPairs.ContainsKey($pairKey)) {
                                # --- CHANGE: Add DeviceIdentifierA and DeviceIdentifierB to the pair object ---
                                $egressPairs[$pairKey] = [PSCustomObject]@{
                                    DeviceA           = $internalDevice.hostname
                                    DeviceIdentifierA = $internalDevice.DeviceIdentifier
                                    SubnetA           = $internalInterface.Cidr
                                    DeviceB           = $virtualDevice.hostname
                                    DeviceIdentifierB = $virtualDevice.DeviceIdentifier
                                    SubnetB           = $virtualInterface.Cidr
                                }
                                
                                $pairCounter++
                                if ($LogLevel -eq 'Debug' -and $pairCounter % 5000 -eq 0) {
                                    Write-Host "[DEBUG] Generated $pairCounter egress pairs..." -ForegroundColor Gray
                                }
                            }
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
    param ([string]$Ip, [string]$Cidr)
    try {
        $ipAddress = [System.Net.IPAddress]::Parse($Ip)
        $ipBytes = $ipAddress.GetAddressBytes()
        if ([System.BitConverter]::IsLittleEndian) { [System.Array]::Reverse($ipBytes) }
        $ipInt = [System.BitConverter]::ToUInt32($ipBytes, 0)

        $networkParts = $Cidr.Split('/')
        $networkAddress = [System.Net.IPAddress]::Parse($networkParts[0])
        $prefixLength = [int]$networkParts[1]
        $networkBytes = $networkAddress.GetAddressBytes()
        if ([System.BitConverter]::IsLittleEndian) { [System.Array]::Reverse($networkBytes) }
        $networkInt = [System.BitConverter]::ToUInt32($networkBytes, 0)

        $maskInt = if ($prefixLength -eq 0) { [uint32]0 } else { [System.UInt32]::MaxValue -shl (32 - $prefixLength) }

        return ($ipInt -band $maskInt) -eq ($networkInt -band $maskInt)
    }
    catch {
        # This can happen with invalid CIDR notations, return false.
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
        [Parameter(Mandatory=$true)]
        [hashtable]$RouteLookupTableLPM
    )

    try {
        $destIpForLookup = (Get-IPv4Subnet -CIDR $DestinationSubnet).FirstHost
    } catch {
        $destIpForLookup = $DestinationSubnet.Split('/')[0]
    }

    $bestRoute = Get-BestRoute -Hostname $CurrentDeviceName -DestIP $destIpForLookup -RoutingTables $RouteLookupTableLPM

    if ($null -eq $bestRoute) {
        return [PSCustomObject]@{ Status = "No Route"; HopInfo = $null; NextHopDevices = $null }
    }
    
    $hopInfo = [PSCustomObject]@{
        EgressInterface = $bestRoute.Interface
        GatewayUsed     = $bestRoute.Gateway
        RouteProtocol   = $bestRoute.RouteProtocol
        MatchedRoute    = $bestRoute.Subnet
    }

    $directProtocols = @('local', 'connected', 'direct')
    if ($directProtocols -contains $bestRoute.RouteProtocol) {
        return [PSCustomObject]@{ Status = "Reached"; HopInfo = $hopInfo; NextHopDevices = $null }
    }
    if ($bestRoute.Interface -like 'Null*') {
        return [PSCustomObject]@{ Status = "Terminated"; HopInfo = $hopInfo; NextHopDevices = $null }
    }
    if ([string]::IsNullOrEmpty($bestRoute.Gateway)) {
        return [PSCustomObject]@{ Status = "No Route"; HopInfo = $hopInfo; NextHopDevices = $null }
    }
    $nextHopLookup = if ($DeviceLookupTable.ContainsKey($bestRoute.Gateway)) { $DeviceLookupTable[$bestRoute.Gateway] } else { $null }
    if ($null -eq $nextHopLookup) {
        return [PSCustomObject]@{ Status = "Unknown Next Hop"; HopInfo = $hopInfo; NextHopDevices = $null }
    }
    $nextHopDevices = [System.Collections.Generic.List[object]]::new()
    # The $nextHopLookup is now an array of detailed objects.
    foreach ($hopDetail in $nextHopLookup) {
        $nextHopDevices.Add([PSCustomObject]@{ DeviceName = $hopDetail.Hostname; IngressInterface = $hopDetail.Interface })
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
function Trace-FullPath {
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
        [hashtable]$RouteLookupTableLPM,
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

    $allPaths = [System.Collections.Generic.List[PSCustomObject]]::new()
    $forksToExplore = [System.Collections.Generic.Stack[PSCustomObject]]::new()
    $forksToExplore.Push(
        [PSCustomObject]@{
            PathHistory       = @()
            CurrentDeviceName = $StartDeviceName
            IngressInterface  = ""
        }
    )

    while ($forksToExplore.Count -gt 0 -and $allPaths.Count -lt 2) {
        $currentTrace = $forksToExplore.Pop()
        $path = [PSCustomObject]@{ Status = "In Progress"; Hops = [System.Collections.Generic.List[object]]::new($currentTrace.PathHistory) }
        $currentDeviceName = $currentTrace.CurrentDeviceName
        $ingressInterface = $currentTrace.IngressInterface

        for ($hopCount = $path.Hops.Count; $hopCount -lt $MaxHops; $hopCount++) {
            $logThisTrace = ($LogLevel -eq 'Debug') -or ($LogLevel -eq 'Specific' -and ($DebugTargets -contains $StartDeviceName -or $DebugTargets -contains $EndSubnet.Split(':')[0]))
            
            if ($currentDeviceName -like 'virtual-*') {
                $currentHopObject = [PSCustomObject]@{ DeviceName = $currentDeviceName; IngressInterface = $ingressInterface }
                $path.Hops.Add($currentHopObject)
                $path.Status = "Reached (External)"
                if ($logThisTrace) {
                    Write-Host "-----------------------------------------------------" -ForegroundColor DarkGray
                    Write-Host "[TRACE] Hop $($path.Hops.Count): $currentDeviceName" -ForegroundColor White
                    Write-Host "  - Ingress: $ingressInterface"
                    Write-Host "  - Path Status: $($path.Status)"
                    Write-Host "[TRACE] Path successfully exited to external destination." -ForegroundColor Green
                }
                break
            }
            
            if ($path.Hops.DeviceName -contains $currentDeviceName) {
                $path.Status = "Loop"
                if ($logThisTrace) { Write-Host "  [FAIL] Loop detected at $($currentDeviceName)" -ForegroundColor Red }
                break
            }

            $currentHopObject = [PSCustomObject]@{ DeviceName = $currentDeviceName; IngressInterface = $ingressInterface }
            $path.Hops.Add($currentHopObject)

            $decision = Get-NextHopInfo -CurrentDeviceName $currentDeviceName -DestinationSubnet $EndSubnet -DeviceLookupTable $DeviceLookupTable -RouteLookupTableLPM $RouteLookupTableLPM

            if ($logThisTrace) {
                $ingressLog = if ([string]::IsNullOrEmpty($ingressInterface)) { "(Start of Trace)" } else { $ingressInterface }
                Write-Host "-----------------------------------------------------" -ForegroundColor DarkGray
                Write-Host "[TRACE] Hop $($path.Hops.Count): $currentDeviceName" -ForegroundColor White
                Write-Host "  - Ingress: $ingressLog"
                Write-Host "  - Destination: $EndSubnet"
                if ($null -ne $decision.HopInfo) {
                    Write-Host "  - Decision: Found best route '$($decision.HopInfo.MatchedRoute)' [$($decision.HopInfo.RouteProtocol)]"
                    if ($decision.Status -eq 'Continue') {
                        $nextDeviceNames = $decision.NextHopDevices.DeviceName -join ', '
                        Write-Host "  - Action: Exiting via interface '$($decision.HopInfo.EgressInterface)' towards gateway '$($decision.HopInfo.GatewayUsed)'"
                        Write-Host "  - Next Device(s): $nextDeviceNames"
                    } elseif ($decision.Status -eq 'Reached') {
                        Write-Host "  - Action: Destination is directly connected on interface '$($decision.HopInfo.EgressInterface)'."
                    } elseif ($decision.Status -eq 'Terminated') {
                         Write-Host "  - Action: Route terminates in Null interface '$($decision.HopInfo.EgressInterface)'."
                    }
                } else {
                    Write-Host "  - Decision: No route found."
                }
                Write-Host "  - Path Status: $($decision.Status)"
            }

            if ($null -ne $decision.HopInfo) {
                $currentHopObject | Add-Member -MemberType NoteProperty -Name EgressInterface -Value $decision.HopInfo.EgressInterface -Force
                $currentHopObject | Add-Member -MemberType NoteProperty -Name GatewayUsed -Value $decision.HopInfo.GatewayUsed -Force
                $currentHopObject | Add-Member -MemberType NoteProperty -Name RouteProtocol -Value $decision.HopInfo.RouteProtocol -Force
                $currentHopObject | Add-Member -MemberType NoteProperty -Name MatchedRoute -Value $decision.HopInfo.MatchedRoute -Force
            }

            if ($decision.Status -ne "Continue") {
                $path.Status = $decision.Status
                # If path is 'Reached' on an intermediate device via a 'connected' route,
                # and the subnet of that route is the SAME as the destination's subnet,
                # then we can confidently add the final device as the last hop.
                if ($decision.Status -eq 'Reached' -and $currentDeviceName -ne $EndDeviceName `
                    -and $decision.HopInfo.MatchedRoute -eq $EndSubnet) {
                    
                    $finalHopObject = [PSCustomObject]@{
                        DeviceName       = $EndDeviceName;
                        IngressInterface = $decision.HopInfo.EgressInterface;
                        EgressInterface  = '';
                        GatewayUsed      = '';
                        RouteProtocol    = 'connected';
                        MatchedRoute     = $EndSubnet
                    }
                    $path.Hops.Add($finalHopObject)
                }                
                break
            }

            if ($decision.NextHopDevices.Count -gt 1) {
                for ($i = $decision.NextHopDevices.Count - 1; $i -ge 1; $i--) {
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
            
            # The ingress interface is now provided directly by Get-NextHopInfo.
            # All the complex resolution/inference logic can be removed.
            $currentDeviceName = $decision.NextHopDevices[0].DeviceName
            $ingressInterface = $decision.NextHopDevices[0].IngressInterface
        }
        if ($path.Status -eq "In Progress") { $path.Status = "Max Hops" }
        $allPaths.Add($path)
    }
    return $allPaths
}


# --- FUNCTION 3 of 4: Format-PathForConsole (New Helper Function) ---
function Format-PathForConsole {
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$PathObject,

        [Parameter(Mandatory=$true)]
        [string]$Title
    )

    Write-Host "`n--- $($Title) ---" -ForegroundColor Green
    if ($null -eq $PathObject) {
        Write-Host "Path was not traced (null)." -ForegroundColor Yellow
        return
    }

    Write-Host "Overall Status: $($PathObject.Status)" -ForegroundColor Cyan
    if ($null -eq $PathObject.Hops -or $PathObject.Hops.Count -eq 0) {
        Write-Host "Path has no hops."
        return
    }

    $hopCounter = 0
    foreach ($hop in $PathObject.Hops) {
        $hopCounter++
        Write-Host "  [Hop $hopCounter] Device: $($hop.DeviceName)" -ForegroundColor Yellow
        Write-Host "    - Ingress Interface : $($hop.IngressInterface)"
        Write-Host "    - Egress Interface  : $($hop.EgressInterface)"
        Write-Host "    - Gateway Used      : $($hop.GatewayUsed)"
        Write-Host "    - Matched Route     : $($hop.MatchedRoute)"
        Write-Host "    - Route Protocol    : $($hop.RouteProtocol)"
    }
}


# --- FUNCTION 4 of 4: Debug-SpecificPair (New Top-Level Debug Function) ---
function Debug-SpecificPair {
    <#
    .SYNOPSIS
        Re-runs a full trace and symmetry analysis for a single, specific pair of devices/subnets.
    .DESCRIPTION
        This function is designed for interactive debugging after the main script has run at least once.
        It relies on the global/script variables ($DeviceLookupTable, $AllDevices, etc.) being populated.
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
    $requiredVars = @('DeviceLookupTable', 'RouteLookupTableLPM', 'AllDevices', 'MaxHops')
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
    $forwardPaths = Trace-FullPath -StartDeviceName $DeviceA -EndSubnet $SubnetB `
        -DeviceLookupTable $Script:DeviceLookupTable -RouteLookupTableLPM $Script:RouteLookupTableLPM `
        -AllDeviceObjects $Script:AllDevices -MaxHops $Script:MaxHops -LogLevel 'Debug'

    # --- Trace Reverse Path (B -> A) ---
    Write-Host "`n[PHASE] Tracing Reverse Path (B -> A)..." -ForegroundColor Cyan
    $reversePaths = Trace-FullPath -StartDeviceName $DeviceB -EndSubnet $SubnetA `
        -DeviceLookupTable $Script:DeviceLookupTable -RouteLookupTableLPM $Script:RouteLookupTableLPM `
        -AllDeviceObjects $Script:AllDevices -MaxHops $Script:MaxHops -LogLevel 'Debug'

    # --- Build Pair Object for Symmetry Test ---
    $pairObject = [PSCustomObject]@{
        DeviceA              = $DeviceA
        SubnetA              = $SubnetA
        DeviceB              = $DeviceB
        SubnetB              = $SubnetB
        ForwardPrimaryPath   = $forwardPaths[0]
        ForwardAlternatePath = $forwardPaths[1]
        ReversePrimaryPath   = $reversePaths[0]
        ReverseAlternatePath = $reversePaths[1]
    }

    # --- Perform Symmetry Check ---
    Write-Host "`n[PHASE] Performing Symmetry Check..." -ForegroundColor Cyan
    $isAsymmetric = Test-PathSymmetry -PairObject $pairObject -LogLevel 'Debug'

    # --- Display Formatted Results ---
    Write-Host "`n========================================================================" -ForegroundColor Magenta
    Write-Host "                          DETAILED PATH ANALYSIS"
    Write-Host "========================================================================" -ForegroundColor Magenta

    Format-PathForConsole -PathObject $pairObject.ForwardPrimaryPath -Title "FORWARD Primary Path (A -> B)"
    if ($pairObject.ForwardAlternatePath) {
        Format-PathForConsole -PathObject $pairObject.ForwardAlternatePath -Title "FORWARD Alternate Path (A -> B)"
    }
    Format-PathForConsole -PathObject $pairObject.ReversePrimaryPath -Title "REVERSE Primary Path (B -> A)"
    if ($pairObject.ReverseAlternatePath) {
        Format-PathForConsole -PathObject $pairObject.ReverseAlternatePath -Title "REVERSE Alternate Path (B -> A)"
    }

    # --- Final Verdict ---
    $symmetryResult = if ($isAsymmetric) { "ASYMMETRIC" } else { "SYMMETRIC" }
    $verdictColor = if ($isAsymmetric) { "Red" } else { "Green" }
    Write-Host "`n========================================================================" -ForegroundColor Magenta
    Write-Host "  Final Verdict: " -NoNewline; Write-Host $symmetryResult -ForegroundColor $verdictColor
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

function Test-PathSymmetry {
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

    # Helper function to perform the granular, hop-by-hop comparison
    function Compare-PathsGranularly {
        param($pathA, $pathB)
        
        # Paths must have the same number of hops to be symmetric
        if ($pathA.Hops.Count -ne $pathB.Hops.Count) {
            return $false
        }

        $reversedHopsB = ([array]$pathB.Hops).Clone()
        [array]::Reverse($reversedHopsB)

        for ($i = 0; $i -lt $pathA.Hops.Count; $i++) {
            $hopA = $pathA.Hops[$i]
            $hopB = $reversedHopsB[$i]

            # 1. Device names must always match.
            if ($hopA.DeviceName -ne $hopB.DeviceName) { return $false }

            # 2. The interface used to ENTER a device on the forward path must be the
            #    same one used to EXIT it on the reverse path.
            #    We skip this check for the very first hop (i=0) as its Ingress is not a real interface.
            if ($i -gt 0) {
                if ($hopA.IngressInterface -ne $hopB.EgressInterface) { return $false }
            }

            # 3. The interface used to EXIT a device on the forward path must be the
            #    same one used to ENTER it on the reverse path.
            #    We skip this check for the very last hop, as its Egress is a termination
            #    status, not a physical interface link.
            if ($i -lt ($pathA.Hops.Count - 1)) {
                if ($hopA.EgressInterface -ne $hopB.IngressInterface) { return $false }
            }
        }

        # If all relevant hop comparisons passed, the paths are symmetric
        return $true
    }

    $logThisCheck = ($LogLevel -eq 'Debug') -or `
                    ($LogLevel -eq 'Specific' -and ($DebugTargets -contains $PairObject.DeviceA -or $DebugTargets -contains $PairObject.DeviceB))
    
    if ($logThisCheck) {
        Write-Host "[DEBUG] Checking symmetry for $($PairObject.DeviceA):($($PairObject.SubnetA)) <-> $($PairObject.DeviceB):($($PairObject.SubnetB))" -ForegroundColor Gray
    }
    
    # --- START: NEW INTELLIGENT SAME-SUBNET OVERRIDE ---
    if ($PairObject.SubnetA -eq $PairObject.SubnetB) {
        $fwdPath = $PairObject.ForwardPrimaryPath
        $revPath = $PairObject.ReversePrimaryPath

        # Ensure both paths were traced successfully before checking their properties
        if ($null -ne $fwdPath -and $fwdPath.Hops.Count -gt 0 -and $null -ne $revPath -and $revPath.Hops.Count -gt 0) {
            
            # Get the routing protocol used by the source device in each direction
            $fwdProtocol = $fwdPath.Hops[0].RouteProtocol
            $revProtocol = $revPath.Hops[0].RouteProtocol
            $directProtocols = @('local', 'connected', 'direct')

            # If BOTH devices use a simple connected route, it's definitively symmetric.
            if ($directProtocols -contains $fwdProtocol -and $directProtocols -contains $revProtocol) {
                if ($logThisCheck) {
                    Write-Host "[DEBUG] Symmetric: Overridden due to direct same-subnet communication." -ForegroundColor Gray
                }
                return $false # Return $false, meaning the path is NOT asymmetric.
            }
        }
    }
    # --- END OF NEW LOGIC ---

    # --- Check 1: Outcome Asymmetry ---
    $forwardPrimary = $PairObject.ForwardPrimaryPath
    $reversePrimary = $PairObject.ReversePrimaryPath
    if ($null -eq $forwardPrimary -or $null -eq $reversePrimary -or $forwardPrimary.Status -ne $reversePrimary.Status) {
        if ($logThisCheck) { Write-Host "[DEBUG] Asymmetric: Primary path statuses do not match ('$($forwardPrimary.Status)' vs '$($reversePrimary.Status)')." -ForegroundColor Yellow }
        return $true # Asymmetric
    }

    # --- Check 2: Redundancy Asymmetry ---
    $forwardPaths = @( @($PairObject.ForwardPrimaryPath, $PairObject.ForwardAlternatePath) | Where-Object { $null -ne $_ } )
    $reversePaths = @( @($PairObject.ReversePrimaryPath, $PairObject.ReverseAlternatePath) | Where-Object { $null -ne $_ } )
    if ($forwardPaths.Count -ne $reversePaths.Count) {
        if ($logThisCheck) { Write-Host "[DEBUG] Asymmetric: Path counts do not match ($($forwardPaths.Count) vs $($reversePaths.Count))." -ForegroundColor Yellow }
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
            if (Compare-PathsGranularly -pathA $fwdPath -pathB $revPath) {
                $foundMatch = $true
                $matchIndex = $i
                if ($logThisCheck) { Write-Host "[DEBUG] Found symmetric match for forward path ($($fwdPath.Hops.DeviceName -join '->'))" -ForegroundColor Gray }
                break
            }
        }

        if ($foundMatch) {
            # Remove the matched path so it can't be used again
            $availableReversePaths.RemoveAt($matchIndex)
        }
        else {
            # This forward path has no symmetric partner in the reverse set
            if ($logThisCheck) { Write-Host "[DEBUG] Asymmetric: No symmetric partner found for forward path ($($fwdPath.Hops.DeviceName -join '->'))." -ForegroundColor Yellow }
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
        [System.Collections.Generic.HashSet[string]]$TransitSubnets
    )

    # --- Step 1: Transform Data into a Flat Array for JSON ---
    $exportData = [System.Collections.Generic.List[object]]::new()

    # This helper function builds the detailed interface path string
    $formatPathWithInterfaces = {
        param($pathObject)
        if ($null -eq $pathObject -or $null -eq $pathObject.Hops -or $pathObject.Hops.Count -eq 0) { return "" }
        $hops = $pathObject.Hops
        if ($hops.Count -eq 1) { return $hops[0].DeviceName }
        $pathParts = [System.Collections.Generic.List[string]]::new()
        $pathParts.Add("$($hops[0].DeviceName) (Out: $($hops[0].EgressInterface))")
        for ($i = 1; $i -lt ($hops.Count - 1); $i++) {
            $pathParts.Add("$($hops[$i].DeviceName) (In: $($hops[$i].IngressInterface), Out: $($hops[$i].EgressInterface))")
        }
        $pathParts.Add("$($hops[-1].DeviceName) (In: $($hops[-1].IngressInterface))")
        return $pathParts -join ' -> '
    }

    # This helper function builds the IP/Gateway path string
    $formatPathWithIPs = {
        param($pathObject, $startSubnet)
        if ($null -eq $pathObject -or $null -eq $pathObject.Hops -or $pathObject.Hops.Count -eq 0) { return "" }
        $ipParts = @($startSubnet.Split('/')[0])
        $pathObject.Hops | ForEach-Object { if (-not [string]::IsNullOrEmpty($_.GatewayUsed)) { $ipParts += $_.GatewayUsed } }
        return $ipParts -join ' -> '
    }


    foreach ($key in $PopulatedPairs.Keys) {
        $pair = $PopulatedPairs[$key]
        
        $pathType = if ($pair.DeviceA.StartsWith('virtual-') -or $pair.DeviceB.StartsWith('virtual-')) { 'External' } else { 'Internal' }

        # --- Primary Path Data ---
        $primaryRow = [PSCustomObject]@{
            PairKey            = $key
            PathRole           = "Primary"
            PathType           = $pathType
            DeviceA            = $pair.DeviceA
            DeviceA_Identifier = $pair.DeviceIdentifierA
            SubnetA            = $pair.SubnetA
            SubnetA_IsTransit  = $TransitSubnets.Contains($pair.SubnetA)
            DeviceB            = $pair.DeviceB
            DeviceB_Identifier = $pair.DeviceIdentifierB
            SubnetB            = $pair.SubnetB
            SubnetB_IsTransit  = $TransitSubnets.Contains($pair.SubnetB)
            PathAtoB_Interface = & $formatPathWithInterfaces $pair.ForwardPrimaryPath
            PathAtoB_Host      = if ($pair.ForwardPrimaryPath) { $pair.ForwardPrimaryPath.Hops.DeviceName -join ' -> ' } else { "" }
            PathAtoB_IP        = & $formatPathWithIPs $pair.ForwardPrimaryPath $pair.SubnetA
            ResultAtoB         = if ($pair.ForwardPrimaryPath) { $pair.ForwardPrimaryPath.Status } else { "Not Traced" }
            PathBtoA_Interface = & $formatPathWithInterfaces $pair.ReversePrimaryPath
            PathBtoA_Host      = if ($pair.ReversePrimaryPath) { $pair.ReversePrimaryPath.Hops.DeviceName -join ' -> ' } else { "" }
            PathBtoA_IP        = & $formatPathWithIPs $pair.ReversePrimaryPath $pair.SubnetB
            ResultBtoA         = if ($pair.ReversePrimaryPath) { $pair.ReversePrimaryPath.Status } else { "Not Traced" }
            Symmetry           = if ($pair.IsAsymmetric) { "Asymmetric" } else { "Symmetric" }
        }
        $exportData.Add($primaryRow)

        # --- Secondary Path Data (if it exists) ---
        if ($pair.ForwardAlternatePath -or $pair.ReverseAlternatePath) {
            $secondaryRow = [PSCustomObject]@{
                PairKey            = $key
                PathRole           = "Secondary"
                PathType           = $pathType
                DeviceA            = $pair.DeviceA
                DeviceA_Identifier = $pair.DeviceIdentifierA
                SubnetA            = $pair.SubnetA
                SubnetA_IsTransit  = $TransitSubnets.Contains($pair.SubnetA)
                DeviceB            = $pair.DeviceB
                DeviceB_Identifier = $pair.DeviceIdentifierB
                SubnetB            = $pair.SubnetB
                SubnetB_IsTransit  = $TransitSubnets.Contains($pair.SubnetB)
                PathAtoB_Interface = & $formatPathWithInterfaces $pair.ForwardAlternatePath
                PathAtoB_Host      = if ($pair.ForwardAlternatePath) { $pair.ForwardAlternatePath.Hops.DeviceName -join ' -> ' } else { "" }
                PathAtoB_IP        = & $formatPathWithIPs $pair.ForwardAlternatePath $pair.SubnetA
                ResultAtoB         = if ($pair.ForwardAlternatePath) { $pair.ForwardAlternatePath.Status } else { "Not Traced" }
                PathBtoA_Interface = & $formatPathWithInterfaces $pair.ReverseAlternatePath
                PathBtoA_Host      = if ($pair.ReverseAlternatePath) { $pair.ReverseAlternatePath.Hops.DeviceName -join ' -> ' } else { "" }
                PathBtoA_IP        = & $formatPathWithIPs $pair.ReverseAlternatePath $pair.SubnetB
                ResultBtoA         = if ($pair.ReverseAlternatePath) { $pair.ReverseAlternatePath.Status } else { "Not Traced" }
                Symmetry           = if ($pair.IsAsymmetric) { "Asymmetric" } else { "Symmetric" }
            }
            $exportData.Add($secondaryRow)
        }
    }

    $jsonData = $exportData | ConvertTo-Json -Depth 10 -Compress

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
        #controls input, #controls select { background-color: #3c3c3c; color: #d4d4d4; border: 1px solid #555; padding: 8px; border-radius: 4px; width: 100%; box-sizing: border-box;}
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
        let currentFilteredData = [];
        let currentPage = 1;
        const rowsPerPage = 200;
        let debounceTimer;

        allData.forEach(row => {
            row.searchableString = Object.values(row).join(' ').toLowerCase();
        });

        const helpModal = document.getElementById('helpModal');
        function openHelpModal() {
            helpModal.classList.remove('hidden');
        }
        function closeHelpModal() {
            helpModal.classList.add('hidden');
        }

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

        function applyFilters() {
            const search = searchText.value.toLowerCase();
            const pathType = pathTypeFilter.value;
            const symmetry = symmetryFilter.value;
            const transit = transitFilter.value;
            const result = resultFilter.value;
            const deviceA = deviceAFilter.value;
            const subnetA = subnetAFilter.value;
            const deviceB = deviceBFilter.value;
            const subnetB = subnetBFilter.value;
            
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
                    const deviceAMatch = (deviceA === 'all') || row.DeviceA === deviceA;
                    const subnetAMatch = (subnetA === 'all') || row.SubnetA === subnetA;
                    const deviceBMatch = (deviceB === 'all') || row.DeviceB === deviceB;
                    const subnetBMatch = (subnetB === 'all') || row.SubnetB === subnetB;
                    return searchMatch && pathTypeMatch && symmetryMatch && transitMatch && resultMatch && deviceAMatch && subnetAMatch && deviceBMatch && subnetBMatch;
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
                    if (i + 1 < paginatedData.length && paginatedData[i+1].PairKey === row.PairKey) {
                        rowSpan = 2;
                    }
                }
                
                const tr = document.createElement('tr');
                tr.className = row.Symmetry === 'Asymmetric' ? 'row-asymmetric' : 'row-symmetric';

                const resultAtoB_class = "result-" + (row.ResultAtoB || "unknown").replace(/\s/g, '-').replace(/[()]/g, '');
                const resultBtoA_class = "result-" + (row.ResultBtoA || "unknown").replace(/\s/g, '-').replace(/[()]/g, '');

                let deviceADisplay = row.DeviceA;
                if (row.DeviceA_Identifier && row.DeviceA_Identifier !== row.DeviceA) {
                    deviceADisplay += ` (${row.DeviceA_Identifier})`;
                }
                let deviceBDisplay = row.DeviceB;
                if (row.DeviceB_Identifier && row.DeviceB_Identifier !== row.DeviceB) {
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
            populateSelect(deviceAFilter, 'DeviceA', 'Device A');
            populateSelect(subnetAFilter, 'SubnetA', 'Subnet A');
            populateSelect(deviceBFilter, 'DeviceB', 'Device B');
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

    $htmlContent = $htmlTemplate.Replace('##JSON_DATA##', $jsonData)

    try {
        Set-Content -Path $OutputPath -Value $htmlContent -Encoding UTF8
        Write-Host "[INFO] Successfully exported analysis to '$OutputPath'" -ForegroundColor Green
    }
    catch {
        Write-Error "[ERROR] Failed to write to '$OutputPath'. Error: $_"
    }
}






$MaxHops = 30
$LoggingConfiguration = @{
    #PathTrace     = "Specific"
    #SymmetryCheck = "Specific"
}
$DebugTargets = @('junimmr.fgao.fr','junilte1a.fgao.fr')


# Helper to get the configured log level for a function, defaulting to "Normal"
$getLogLevel = {
    param($functionName)
    if ($LoggingConfiguration.ContainsKey($functionName)) {
        return $LoggingConfiguration[$functionName]
    }
    return "normal"
}

# =================================================================
# PHASE 1: Data Preparation
# =================================================================

Write-Host "`n[PHASE] Starting data preparation..." -ForegroundColor Cyan
# =================================================================
# ============= START: NEW PRE-FLIGHT FILTERING STEP ==============
# =================================================================
Write-Host "`n[PRE-FLIGHT] Filtering out devices with no routing table..." -ForegroundColor Cyan
$initialDeviceCount = $GArrayOfObjects.Count
$GArrayOfObjectsFilter = $GArrayOfObjects | Where-Object { $null -ne $_.RoutingTable -and $_.RoutingTable.Count -gt 0 }
$finalDeviceCount = $GArrayOfObjectsFilter.Count
$removedCount = $initialDeviceCount - $finalDeviceCount
Write-Host "[INFO] Removed $removedCount devices with no routing information. Continuing with $finalDeviceCount devices." -ForegroundColor Green
# =================================================================
# ========================== END OF NEW STEP ======================
# =================================================================
# =================================================================
# ============= START: NEW DATA ENRICHMENT STEP ===================
# =================================================================
# This ensures data integrity by adding 'connected' routes for any active
# interfaces that might have been missing from the collected routing table.
$GArrayOfObjectsFilter = Add-ConnectedInterfaceRoutes -DeviceObjects $GArrayOfObjectsFilter
# =================================================================
# ======================= END OF NEW STEP =========================
# =================================================================

$deviceLookupLogLevel = & $getLogLevel "DeviceLookup"
$DeviceLookupTable = Create-DeviceLookupTable -GArrayOfObjectsFilter $GArrayOfObjectsFilter -LogLevel $deviceLookupLogLevel

$virtualDeviceLogLevel = & $getLogLevel "VirtualDevice"
$virtualDevices = Create-ExternalVirtualDevices -GArrayOfObjectsFilter $GArrayOfObjectsFilter -DeviceLookupTable $DeviceLookupTable -LogLevel $virtualDeviceLogLevel

$AllDevices = $GArrayOfObjectsFilter + $virtualDevices


# --- Call the function to identify transit subnets ---
$transitSubnets = Create-TransitSubnetLookup -AllDeviceObjects $AllDevices

$routeLookupLogLevel = & $getLogLevel "RouteLookup"
$RouteLookupTableLPM = Create-RouteLookupTableLPM -AllDeviceObjects $AllDevices -LogLevel $routeLookupLogLevel

Write-Host "[INFO] Data preparation complete. Found $($GArrayOfObjectsFilter.Count) devices, created $($virtualDevices.Count) virtual devices." -ForegroundColor Green


# =================================================================
# PHASE 2: Pair Generation
# =================================================================
Write-Host "`n[PHASE] Starting pair generation..." -ForegroundColor Cyan
$pairGenLogLevel = & $getLogLevel "PairGeneration"

$internalPairs = Generate-InternalPairs -InternalDeviceObjects $GArrayOfObjectsFilter -LogLevel $pairGenLogLevel
$egressPairs = Generate-EgressPairs -InternalDeviceObjects $GArrayOfObjectsFilter -ExternalVirtualDevices $virtualDevices -LogLevel $pairGenLogLevel

# Combine the two hashtables of pairs into one master hashtable
$allPairs = $internalPairs.Clone()
foreach ($key in $egressPairs.Keys) {
    if (-not $allPairs.ContainsKey($key)) {
        $allPairs[$key] = $egressPairs[$key]
    }
}

Write-Host "[INFO] Pair generation complete. Found $($allPairs.Count) total unique pairs to trace." -ForegroundColor Green


# =================================================================
# PHASE 3: Path Tracing and Symmetry Analysis
# =================================================================
Write-Host "`n[PHASE] Starting path tracing for all $($allPairs.Count) pairs..." -ForegroundColor Cyan
$traceLogLevel = & $getLogLevel "PathTrace"
$symmetryLogLevel = & $getLogLevel "SymmetryCheck"
$pairCounter = 0
$totalPairs = $allPairs.Count

foreach ($key in $allPairs.Keys) {
    $pair = $allPairs[$key]
    $pairCounter++
    
    # Simple progress indicator
    if ($pairCounter % 100 -eq 0) {
        Write-Progress -Activity "Tracing Paths" -Status "Processing pair $pairCounter of $totalPairs" -PercentComplete (($pairCounter / $totalPairs) * 100)
    }
    
    # --- Trace Forward Path (A -> B) ---
    $forwardPaths = Trace-FullPath -StartDeviceName $pair.DeviceA -EndDeviceName $pair.DeviceB -EndSubnet $pair.SubnetB `
        -DeviceLookupTable $DeviceLookupTable -RouteLookupTableLPM $RouteLookupTableLPM `
        -AllDeviceObjects $AllDevices -MaxHops $MaxHops -LogLevel $traceLogLevel -DebugTargets $DebugTargets
    
    # --- Trace Reverse Path (B -> A) ---
    $reversePaths = Trace-FullPath -StartDeviceName $pair.DeviceB -EndDeviceName $pair.DeviceA -EndSubnet $pair.SubnetA `
        -DeviceLookupTable $DeviceLookupTable -RouteLookupTableLPM $RouteLookupTableLPM `
        -AllDeviceObjects $AllDevices -MaxHops $MaxHops -LogLevel $traceLogLevel -DebugTargets $DebugTargets
    
    # Add the results to the pair object
    $pair | Add-Member -MemberType NoteProperty -Name ForwardPrimaryPath -Value $forwardPaths[0] -Force
    $pair | Add-Member -MemberType NoteProperty -Name ForwardAlternatePath -Value $forwardPaths[1] -Force
    $pair | Add-Member -MemberType NoteProperty -Name ReversePrimaryPath -Value $reversePaths[0] -Force
    $pair | Add-Member -MemberType NoteProperty -Name ReverseAlternatePath -Value $reversePaths[1] -Force
    
    # --- Perform Symmetry Check ---
    $isAsymmetric = Test-PathSymmetry -PairObject $pair -LogLevel $symmetryLogLevel -DebugTargets $DebugTargets
    $pair | Add-Member -MemberType NoteProperty -Name IsAsymmetric -Value $isAsymmetric -Force
}

Write-Progress -Activity "Tracing Paths" -Completed
Write-Host "[INFO] Path tracing and analysis complete." -ForegroundColor Green

# =================================================================
# PHASE 4: Reporting
# =================================================================
Write-Host "`n[PHASE] Generating HTML report..." -ForegroundColor Cyan

$OutputPath="$(get-date -Format yyyyMMdd-hhmmss)Analysis.html"
Export-TraceAnalysisToHTML -PopulatedPairs $allPairs -OutputPath $OutputPath -TransitSubnets $transitSubnets

Write-Host "`n[PHASE] Analysis complete." -ForegroundColor Cyan

