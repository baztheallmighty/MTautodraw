# Asymmetric Route Analysis Script
# Last Updated: September 6, 2025 - Toulouse, France

# =================================================================================
# --- Function: Create Virtual Devices for External Gateways ---
# =================================================================================
function Create-VirtualDevices {
    <# .SYNOPSIS Scans all routes to create virtual device objects for unknown next-hops. #>
    param (
        [Parameter(Mandatory=$true)][array]$GArrayOfObjects,
        [Parameter(Mandatory=$true)][hashtable]$DeviceLookupTable
    )

    Write-Verbose "Identifying external gateways and creating virtual devices."
    $virtualDevices = [System.Collections.Generic.List[pscustomobject]]::new()
    $uniqueExternalRoutes = @{}

    # Step 1: Find all unique external gateways for each device and the subnets they serve
    foreach ($device in $GArrayOfObjects) {
        if ($null -eq $device.RoutingTable) { continue }

        foreach ($route in $device.RoutingTable) {
            if ([string]::IsNullOrWhiteSpace($route.Gateway) -or $route.Interface -like 'Null*' -or $route.Gateway -eq '0.0.0.0') {
                continue
            }

            # If the gateway is NOT a known IP, it's an external gateway
            if (-not $DeviceLookupTable.ContainsKey($route.Gateway)) {
                $key = "$($device.hostname)_$($route.Gateway)"
                if (-not $uniqueExternalRoutes.ContainsKey($key)) {
                    $uniqueExternalRoutes[$key] = [System.Collections.Generic.List[string]]::new()
                }
                # Add subnet if it's not already in the list for that gateway
                if (-not $uniqueExternalRoutes[$key].Contains($route.Subnet)) {
                    $uniqueExternalRoutes[$key].Add($route.Subnet)
                }
            }
        }
    }

    # Step 2: Create a virtual device for each unique external gateway found
    foreach ($key in $uniqueExternalRoutes.Keys) {
        # Find the position of the last underscore in the key
        $lastUnderscoreIndex = $key.LastIndexOf('_')

        if ($lastUnderscoreIndex -gt -1) {
            # The hostname is everything BEFORE the last underscore
            $hostname = $key.Substring(0, $lastUnderscoreIndex)

            # The gateway is everything AFTER the last underscore
            $gateway  = $key.Substring($lastUnderscoreIndex + 1)
        } else {
            # Add a fallback in case the key format is unexpected
            $hostname = $key
            $gateway  = ""
        }
        $subnets = $uniqueExternalRoutes[$key]

        $sanitizedGateway = $gateway.Replace('.', '_')
        $virtualDeviceName = "EX_$($hostname)_$($sanitizedGateway)"

        $virtualInterfaces = [System.Collections.Generic.List[pscustomobject]]::new()
        foreach($subnet in $subnets){
            $virtualInterfaces.Add([PSCustomObject]@{
                Interface = "virtual_route_to_$($subnet.Replace('/', '_'))"
                Cidr      = $subnet
            })
        }

        $virtualDevice = [PSCustomObject]@{
            hostname     = $virtualDeviceName
            interfaces   = $virtualInterfaces
            RoutingTable = @() # Virtual devices have no known routes
        }
        $virtualDevices.Add($virtualDevice)
        Write-Verbose "Created virtual device '$virtualDeviceName' with $($virtualInterfaces.Count) interface(s)."
    }

    return $virtualDevices
}

# =================================================================================
# --- Function 1: Create Subnet Pairs from Interfaces (MODIFIED WITH BOTH FILTERS) ---
# =================================================================================
function Create-SubnetPairs {
    <# .SYNOPSIS Creates a hashtable of all unique subnet pairs from a combined list of real and virtual devices. #>
    param ( [Parameter(Mandatory = $true)][array]$GArrayOfObjects )
    Write-Verbose "Starting to create all unique inter-device subnet pairs from device interfaces."
    $SubnetPairs = @{}

    foreach ($outerDevice in $GArrayOfObjects) {
        if ($null -eq $outerDevice.interfaces) { continue }
        foreach ($outerInterface in $outerDevice.interfaces) {
            if (-not [string]::IsNullOrEmpty($outerInterface.Cidr)) {
                foreach ($innerDevice in $GArrayOfObjects) {
                    if ($outerDevice.hostname -eq $innerDevice.hostname) { continue }
                    if ($null -eq $innerDevice.interfaces) { continue }
                    foreach ($innerInterface in $innerDevice.interfaces) {
                        if (-not [string]::IsNullOrEmpty($innerInterface.Cidr)) {

                            # ---> FIX 1: Prevent a device from being paired with its own external representation
                            if ($innerDevice.hostname.StartsWith("EX_$($outerDevice.hostname)_") -or $outerDevice.hostname.StartsWith("EX_$($innerDevice.hostname)_")) {
                                continue
                            }
                            if ($outerDevice.hostname.StartsWith("EX_") -and $innerDevice.hostname.StartsWith("EX_")) {
                                continue
                            }


                            if ($outerInterface.Cidr -eq $innerInterface.Cidr) { continue }
                            $sortedCidrs = @($outerInterface.Cidr, $innerInterface.Cidr) | Sort-Object
                            $pairKey = $sortedCidrs -join '_'

                            if (-not $SubnetPairs.ContainsKey($pairKey)) {
                                $pairObject = [PSCustomObject]@{
                                    HostnamePathFrom1To2       = @(); GatewayPathFrom1To2        = @(); HostnamePathFrom1To2Result = ''
                                    HostnamePathFrom2To1       = @(); GatewayPathFrom2To1        = @(); HostnamePathFrom2To1Result = ''
                                    HostnamePathFrom1To2_Alt   = $null; GatewayPathFrom1To2_Alt    = $null; HostnamePathFrom1To2Result_Alt = ''
                                    HostnamePathFrom2To1_Alt   = $null; GatewayPathFrom2To1_Alt    = $null; HostnamePathFrom2To1Result_Alt = ''
                                    Subnet1                    = $sortedCidrs[0]; DeviceA  = $null; SourceInterface1       = $null
                                    Subnet2                    = $sortedCidrs[1]; DeviceB  = $null; SourceInterface2       = $null
                                }
                                if ($outerInterface.Cidr -eq $pairObject.Subnet1) {
                                    $pairObject.DeviceA = $outerDevice.hostname; $pairObject.SourceInterface1 = $outerInterface.Interface
                                    $pairObject.DeviceB = $innerDevice.hostname; $pairObject.SourceInterface2 = $innerInterface.Interface
                                } else {
                                    $pairObject.DeviceA = $innerDevice.hostname; $pairObject.SourceInterface1 = $innerInterface.Interface
                                    $pairObject.DeviceB = $outerDevice.hostname; $pairObject.SourceInterface2 = $outerInterface.Interface
                                }
                                $SubnetPairs.Add($pairKey, $pairObject)
                            }
                        }
                    }
                }
            }
        }
    }
    Write-Verbose "Finished creating $($SubnetPairs.Count) unique inter-device subnet pairs."
    return $SubnetPairs
}

# =================================================================================
# --- Function 2: Build LPM Routing Table ---
# =================================================================================
function Create-RouteLookupTableLPM {
    <# .SYNOPSIS Creates a nested hashtable of all routes for LPM lookups. #>
    param ( [Parameter(Mandatory = $true)][array]$GArrayOfObjects )
    Write-Verbose "Starting to build the LPM-structured route lookup hashtable."
    $RouteLookupTable = @{}
    foreach ($device in $GArrayOfObjects) {
        if ($null -eq $device.hostname -or $null -eq $device.RoutingTable) { continue }
        $deviceRoutesByPrefix = @{}
        foreach ($route in $device.RoutingTable) {
            if (-not [string]::IsNullOrEmpty($route.Subnet) -and $route.Subnet -like '*/*') {
                try {
                    $prefixLength = [int]($route.Subnet.Split('/')[1])
                    if (-not $deviceRoutesByPrefix.ContainsKey($prefixLength)) { $deviceRoutesByPrefix[$prefixLength] = @{} }
                    $deviceRoutesByPrefix[$prefixLength][$route.Subnet] = $route
                } catch { Write-Warning "Could not parse prefix from subnet '$($route.Subnet)' on '$($device.hostname)'." }
            }
        }
        if ($deviceRoutesByPrefix.Count -gt 0) { $RouteLookupTable[$device.hostname] = $deviceRoutesByPrefix }
    }
    Write-Verbose "Finished building the LPM route lookup table for $($RouteLookupTable.Keys.Count) devices."
    return $RouteLookupTable
}

# =================================================================================
# --- Function 3: Filter Redundant Pairs ---
# =================================================================================
function Filter-RedundantPairs {
    <# .SYNOPSIS Filters out pairs where a direct route already exists (e.g., in HA setups). #>
    param( [Parameter(Mandatory=$true)][hashtable]$SubnetPairs, [Parameter(Mandatory=$true)][hashtable]$RouteLookupTable )
    Write-Verbose "Filtering out redundant pairs where a direct route already exists..."
    $filteredPairs = $SubnetPairs.Clone()
    $directProtocols = @('local', 'connected', 'direct')
    function Has-DirectRoute { param($Hostname, $TargetSubnet)
        # Virtual devices have no routes, so they can't have a direct route.
        if ($Hostname.StartsWith("EX_")) { return $false }
        if ($RouteLookupTable.ContainsKey($Hostname)) {
            $deviceRoutesByPrefix = $RouteLookupTable[$Hostname]
            foreach ($prefixTable in $deviceRoutesByPrefix.Values) {
                if ($prefixTable.ContainsKey($TargetSubnet)) {
                    $route = $prefixTable[$TargetSubnet]
                    $baseProtocol = $route.RouteProtocol.Split('-')[0].Trim()
                    if ($directProtocols -contains $baseProtocol) { return $true }
                }
            }
        }
        return $false
    }
    $keysToRemove = [System.Collections.ArrayList]::new()
    foreach ($key in $filteredPairs.Keys) {
        $pair = $filteredPairs[$key]
        if ((Has-DirectRoute -Hostname $pair.DeviceA -TargetSubnet $pair.Subnet2) -or
            (Has-DirectRoute -Hostname $pair.DeviceB -TargetSubnet $pair.Subnet1)) {
            $keysToRemove.Add($key) > $null
        }
    }
    if ($keysToRemove.Count -gt 0) {
        Write-Verbose "Removing $($keysToRemove.Count) redundant pairs."
        foreach($key in $keysToRemove){ $filteredPairs.Remove($key) }
    } else { Write-Verbose "No redundant pairs found." }
    return $filteredPairs
}

# =================================================================================
# --- Function 4: Trace All Paths (NOW HANDLES HA) ---
# =================================================================================
function Trace-AllSubnetPairPaths {
    <# .SYNOPSIS Traces the L3 path for every subnet pair, handling HA branching, and populates the results. #>
    param (
        [Parameter(Mandatory=$true)] [hashtable]$SubnetPairs,
        [Parameter(Mandatory=$true)] [hashtable]$RouteLookupTable,
        [Parameter(Mandatory=$true)] [array]$GArrayOfObjects, # This MUST be the combined (real + virtual) list
        [Parameter(Mandatory=$true)] [hashtable]$DeviceLookupTable,
        [int]$MaxHops = 30
    )

    # --- Recursive inner function to trace a path, which can branch for HA devices ---
    function Get-TracePaths {
        param (
            [string]$CurrentDeviceName,
            [string]$EndSubnet,
            [System.Collections.ArrayList]$HostnamePath,
            [System.Collections.ArrayList]$GatewayPath
        )

        # --- Handle tracing from a virtual device: it's a dead end. ---
        if ($CurrentDeviceName.StartsWith("EX_")) {
            $HostnamePath.Add($CurrentDeviceName) > $null
            return @([PSCustomObject]@{ Hostnames = $HostnamePath; Gateways = $GatewayPath; Result = "!!! NO ROUTE TO DESTINATION !!!" })
        }

        # --- Check for routing loop ---
        if ($HostnamePath.Contains($CurrentDeviceName)) {
            $HostnamePath.Add($CurrentDeviceName) > $null
            return @([PSCustomObject]@{ Hostnames = $HostnamePath; Gateways = $GatewayPath; Result = "!!! ROUTING LOOP -> $CurrentDeviceName !!!" })
        }

        # --- Check for max hops ---
        if ($HostnamePath.Count -ge $MaxHops) {
            return @([PSCustomObject]@{ Hostnames = $HostnamePath; Gateways = $GatewayPath; Result = "!!! MAX HOPS REACHED !!!" })
        }

        $HostnamePath.Add($CurrentDeviceName) > $null
        $destIpForLookup = $EndSubnet.Split('/')[0]
        $bestRoute = Get-BestRoute -Hostname $CurrentDeviceName -DestIP $destIpForLookup -RoutingTables $RouteLookupTable

        # --- Check for no route ---
        if ($null -eq $bestRoute) {
            return @([PSCustomObject]@{ Hostnames = $HostnamePath; Gateways = $GatewayPath; Result = "!!! NO ROUTE TO DESTINATION !!!" })
        }
        if (-not [string]::IsNullOrEmpty($bestRoute.gateway)) { $GatewayPath.Add($bestRoute.gateway) > $null }

        # --- Check for path termination (direct route) ---
        $directProtocols = @('local', 'connected', 'direct')
        $baseProtocol = $bestRoute.RouteProtocol.Split('-')[0].Trim()
        if ($directProtocols -contains $baseProtocol) {
            $destinationDevice = Find-DeviceBySubnet -Cidr $EndSubnet -GArrayOfObjects $GArrayOfObjects
            if ($null -ne $destinationDevice -and $destinationDevice.hostname -ne $CurrentDeviceName) {
                $HostnamePath.Add($destinationDevice.hostname) > $null
                # Add the destination device's IP to the gateway path to ensure path lengths are consistent.
                $finalInterface = $destinationDevice.interfaces | Where-Object { $_.Cidr -eq $EndSubnet } | Select-Object -First 1
                if ($null -ne $finalInterface -and -not [string]::IsNullOrEmpty($finalInterface.IPAddress)) {
                    $GatewayPath.Add($finalInterface.IPAddress) > $null
                }                
            }
            return @([PSCustomObject]@{ Hostnames = $HostnamePath; Gateways = $GatewayPath; Result = "Destination Reached" })
        }

        # --- Find next hop device(s) ---
        $nextHopInfo = Find-DeviceByIp -IpAddress $bestRoute.gateway -DeviceLookupTable $DeviceLookupTable
        if ($null -eq $nextHopInfo) {
            $result = if ($bestRoute.gateway -eq '0.0.0.0' -or $bestRoute.interface -like 'Null*') {
                "Path terminated via route to $($bestRoute.interface)"
            } else { "!!! NEXT HOP ($($bestRoute.gateway)) NOT FOUND !!!" }
            return @([PSCustomObject]@{ Hostnames = $HostnamePath; Gateways = $GatewayPath; Result = $result })
        }

        # --- Recursive Step: Call this function for each potential next device ---
        $finalPaths = [System.Collections.ArrayList]::new()
        foreach ($nextHostname in $nextHopInfo.hostnames) {
            $pathsFromBranch = Get-TracePaths -CurrentDeviceName $nextHostname -EndSubnet $EndSubnet -HostnamePath ($HostnamePath.Clone()) -GatewayPath ($GatewayPath.Clone())
            $finalPaths.AddRange(@($pathsFromBranch))
        }
        return $finalPaths
    }

    foreach ($pairKey in $SubnetPairs.Keys) {
        $pair = $SubnetPairs[$pairKey]

        # --- Trace Path 1 -> 2 ---
        $allPaths1to2 = Get-TracePaths -CurrentDeviceName $pair.DeviceA -EndSubnet $pair.Subnet2 -HostnamePath ([System.Collections.ArrayList]::new()) -GatewayPath ([System.Collections.ArrayList]::new())
        if ($allPaths1to2.Count -gt 0) {
            $pair.HostnamePathFrom1To2 = $allPaths1to2[0].Hostnames; $pair.GatewayPathFrom1To2 = $allPaths1to2[0].Gateways; $pair.HostnamePathFrom1To2Result = $allPaths1to2[0].Result
            if ($allPaths1to2.Count -gt 1) {
                $primaryPathStr = $allPaths1to2[0].Hostnames -join ' -> '
                $altPath = $allPaths1to2 | Where-Object { ($_.Hostnames -join ' -> ') -ne $primaryPathStr } | Select-Object -First 1
                if ($altPath) {
                    $pair.HostnamePathFrom1To2_Alt = $altPath.Hostnames; $pair.GatewayPathFrom1To2_Alt = $altPath.Gateways; $pair.HostnamePathFrom1To2Result_Alt = $altPath.Result
                }
            }
        }

        # --- Trace Path 2 -> 1 ---
        $allPaths2to1 = Get-TracePaths -CurrentDeviceName $pair.DeviceB -EndSubnet $pair.Subnet1 -HostnamePath ([System.Collections.ArrayList]::new()) -GatewayPath ([System.Collections.ArrayList]::new())
        if ($allPaths2to1.Count -gt 0) {
            $pair.HostnamePathFrom2To1 = $allPaths2to1[0].Hostnames; $pair.GatewayPathFrom2To1 = $allPaths2to1[0].Gateways; $pair.HostnamePathFrom2To1Result = $allPaths2to1[0].Result
            if ($allPaths2to1.Count -gt 1) {
                $primaryPathStr = $allPaths2to1[0].Hostnames -join ' -> '
                $altPath = $allPaths2to1 | Where-Object { ($_.Hostnames -join ' -> ') -ne $primaryPathStr } | Select-Object -First 1
                if ($altPath) {
                    $pair.HostnamePathFrom2To1_Alt = $altPath.Hostnames; $pair.GatewayPathFrom2To1_Alt = $altPath.Gateways; $pair.HostnamePathFrom2To1Result_Alt = $altPath.Result
                }
            }
        }
    }
    return $SubnetPairs
}

# =================================================================================
# --- Helper Functions ---
# =================================================================================
function Get-BestRoute { <# .SYNOPSIS Finds the most specific route for a destination IP on a given host. #> param ([string]$Hostname, [string]$DestIP, [hashtable]$RoutingTables)
    if ($Hostname.StartsWith("EX_")) { return $null } # Virtual devices have no routes.
    if (-not $RoutingTables.ContainsKey($Hostname)) { return $null }
    $deviceRoutes = $RoutingTables[$Hostname]
    $prefixLengths = $deviceRoutes.Keys | Sort-Object -Descending
    foreach ($pLen in $prefixLengths) { foreach ($subnet in $deviceRoutes[$pLen].Keys) { if (Test-IpInSubnet -Ip $DestIP -Cidr $subnet) { return $deviceRoutes[$pLen][$subnet] } } }
    return $null
}
function Test-IpInSubnet { <# .SYNOPSIS Checks if a given IPv4 address is within a specified subnet. #> param ([string]$Ip, [string]$Cidr)
    try {
        $ipAddress = [System.Net.IPAddress]::Parse($Ip); $ipBytes = $ipAddress.GetAddressBytes()
        if ([System.BitConverter]::IsLittleEndian) { [System.Array]::Reverse($ipBytes) }
        $ipInt = [System.BitConverter]::ToUInt32($ipBytes, 0)
        $networkParts = $Cidr.Split('/'); $networkAddress = [System.Net.IPAddress]::Parse($networkParts[0]); $prefixLength = [int]$networkParts[1]
        $networkBytes = $networkAddress.GetAddressBytes()
        if ([System.BitConverter]::IsLittleEndian) { [System.Array]::Reverse($networkBytes) }
        $networkInt = [System.BitConverter]::ToUInt32($networkBytes, 0)
        $maskInt = if ($prefixLength -eq 0) { [uint32]0 } else { [uint32]::MaxValue -shl (32 - $prefixLength) }
        return ($ipInt -band $maskInt) -eq ($networkInt -band $maskInt)
    } catch { return $false }
}
function Create-DeviceLookupTable {
    <# .SYNOPSIS Creates a hashtable of all devices based on their IP address for fast HA-aware lookups. #>
    param ( [Parameter(Mandatory = $true)][array]$GArrayOfObjects )
    Write-Verbose "Building IP-to-Device lookup table for HA analysis."
    $deviceLookup = @{}
    foreach ($device in $GArrayOfObjects) {
        if ($null -eq $device.interfaces) { continue }
        foreach ($interface in $device.interfaces) {
            $processIp = {
                param($ip, $isStandby)
                if ([string]::IsNullOrEmpty($ip)) { return }
                if (-not $deviceLookup.ContainsKey($ip)) {
                    $deviceLookup[$ip] = [PSCustomObject]@{ hostnames = @($device.hostname); standby = $isStandby }
                } else {
                    if (-not ($deviceLookup[$ip].hostnames -contains $device.hostname)) {
                        $deviceLookup[$ip].hostnames += $device.hostname
                    }
                    if ($isStandby) { $deviceLookup[$ip].standby = $true }
                }
            }
            & $processIp $interface.IPAddress $false
            & $processIp $interface.SecondaryIPAddress $false
            & $processIp $interface.Standbyip $true
            & $processIp $interface.ClusterIP $true
        }
    }
    Write-Verbose "Finished building lookup table with $($deviceLookup.Count) unique IPs."
    return $deviceLookup
}
function Find-DeviceByIp {
    <# .SYNOPSIS Finds device info from a pre-built lookup table. #>
    param (
        [Parameter(Mandatory = $true)] [string]$IpAddress,
        [Parameter(Mandatory = $true)] [hashtable]$DeviceLookupTable
    )
    return $DeviceLookupTable[$IpAddress]
}
function Find-DeviceBySubnet { <# .SYNOPSIS Finds a device object that owns a specific subnet. #> param ([string]$Cidr, [array]$GArrayOfObjects)
    foreach ($device in $GArrayOfObjects) {
        if ($null -ne $device.interfaces) {
            foreach ($interface in $device.interfaces) {
                if ($interface.Cidr -eq $Cidr) { return $device }
            }
        }
    }
    return $null
}

#region Helper Functions
function Format-Result {
    param([string]$ResultText)
    if ($ResultText -like "*!!! NO ROUTE*") { return "No Route" }
    if ($ResultText -like "*!!! ROUTING LOOP*") { return "Loop" }
    if ($ResultText -like "*!!! NEXT HOP*NOT FOUND*") { return "Next Hop?" }
    if ($ResultText -like "*!!! MAX HOPS*") { return "Max Hops" }
    if ($ResultText -like "*Path terminated*") { return "Terminated" }
    return "Reached"
}
function Format-Column {
    param([string]$Text, [int]$Width)
    if ($Text.Length -gt $Width) { return $Text.Substring(0, $Width - 3) + "..." }
    else { return $Text.PadRight($Width) }
}
#endregion


# =================================================================================
# --- Function 7: Export Asymmetric Route Analysis to HTML (with Help Modal) ---
# =================================================================================
function Export-AsymmetricRouteAnalysisHTML {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]$PopulatedPairs,

        [Parameter(Mandatory=$true)]
        [string]$OutputPath
    )

    # Step 1: Convert the complex hashtable into a simple array of objects
    $exportData = @()
    foreach ($pair in $PopulatedPairs.Values | Sort-Object DeviceA, DeviceB) {
        $path1StrForCheck = $pair.HostnamePathFrom1To2 -join ' -> '
        $path2StrForCheck = $pair.HostnamePathFrom2To1 -join ' -> '
        $reversedPath2Hops = $path2StrForCheck.Split(' -> ')
        [array]::Reverse($reversedPath2Hops)
        $reversedPath2Str = $reversedPath2Hops -join ' -> '
        $isPathAsymmetric = ($path1StrForCheck -ne $reversedPath2Str)
        $isResultAsymmetric = (Format-Result -ResultText $pair.HostnamePathFrom1To2Result) -ne (Format-Result -ResultText $pair.HostnamePathFrom2To1Result)
        $isAsymmetric = $isPathAsymmetric -or $isResultAsymmetric

        $exportObject = [PSCustomObject]@{
            DeviceA       = $pair.DeviceA
            DeviceB       = $pair.DeviceB
            SubnetA       = $pair.Subnet1
            SubnetB       = $pair.Subnet2
            IsAsymmetric  = $isAsymmetric
            PathAtoB      = $pair.HostnamePathFrom1To2 -join ' -> '
            PathAtoB_IP   = ($pair.DeviceA.ToString()) + ' -> ' + ($pair.GatewayPathFrom1To2 -join ' -> ')
            ResultAtoB    = Format-Result -ResultText $pair.HostnamePathFrom1To2Result
            PathBtoA      = $pair.HostnamePathFrom2To1 -join ' -> '
            PathBtoA_IP   = ($pair.DeviceB.ToString()) + ' -> ' + ($pair.GatewayPathFrom2To1 -join ' -> ')
            ResultBtoA    = Format-Result -ResultText $pair.HostnamePathFrom2To1Result
        }
        $exportData += $exportObject
    }

    # Step 2: Convert the array of objects to a compressed JSON string
    $jsonData = $exportData | ConvertTo-Json -Depth 5 -Compress

    # Step 3: Define the HTML template with a placeholder.
    $htmlTemplate = @'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Asymmetric Route Analysis</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background-color: #1e1e1e; color: #d4d4d4; margin: 0; padding: 20px; }
        h1 { text-align: center; color: #4ec9b0; }
        #controls { background-color: #252526; padding: 15px; border-radius: 8px; margin-bottom: 20px; display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 15px; align-items: center; border: 1px solid #333; }
        #controls div { display: flex; flex-direction: column; }
        #controls input, #controls select { width: 100%; box-sizing: border-box; background-color: #3c3c3c; color: #d4d4d4; border: 1px solid #555; padding: 8px; border-radius: 4px; }
        #controls label { margin-bottom: 5px; font-size: 0.9em; color: #aaa; }
        #dataTable { width: 100%; border-collapse: collapse; table-layout: fixed; }
        #dataTable th, #dataTable td { border: 1px solid #333; padding: 10px; text-align: left; word-wrap: break-word; }
        #dataTable th { background-color: #333333; color: #4ec9b0; position: sticky; top: 0; z-index: 1; }
        #pagination-controls { text-align: center; margin: 20px 0; }
        #pagination-controls button { margin: 0 10px; background-color: #3c3c3c; color: #d4d4d4; border: 1px solid #555; padding: 8px 16px; border-radius: 4px; cursor: pointer; }
        #pagination-controls button:disabled { background-color: #2d2d2d; color: #666; cursor: not-allowed; }
        .row-asymmetric { background-color: #4d2121; }
        .row-symmetric { background-color: #214221; }
        .result-Reached { color: #8fce00; }
        .result-Loop, .result-No-Route { color: #f44747; font-weight: bold; }
        .result-Next-Hop_ { color: #f9d64f; }
        .path-toggle { align-self: end; }
        #helpBtn { position: fixed; top: 20px; right: 20px; width: 40px; height: 40px; border-radius: 50%; background-color: #4ec9b0; color: #1e1e1e; border: none; font-size: 1.5em; font-weight: bold; cursor: pointer; z-index: 1001; }
        .modal-overlay { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background-color: rgba(0,0,0,0.7); display: flex; justify-content: center; align-items: center; z-index: 1000; }
        .modal-content { background-color: #2d2d2d; padding: 20px 40px; border-radius: 8px; max-width: 800px; max-height: 80vh; overflow-y: auto; position: relative; border: 1px solid #444; }
        .modal-close { position: absolute; top: 10px; right: 20px; font-size: 2em; font-weight: bold; cursor: pointer; color: #aaa; }
        .modal-content h2 { color: #4ec9b0; border-bottom: 1px solid #4ec9b0; padding-bottom: 10px; }
        .modal-content h3 { color: #c5c5c5; }
        .modal-content dt { font-weight: bold; color: #9cdcfe; }
        .modal-content dd { margin-left: 20px; margin-bottom: 10px; }
        .hidden { display: none !important; }
    </style>
</head>
<body>
    <button id="helpBtn" onclick="openHelpModal()">?</button>
    <div id="helpModal" class="modal-overlay hidden">
        <div class="modal-content">
            <span class="modal-close" onclick="closeHelpModal()">&times;</span>
            <h2>Help: Asymmetric Route Analysis</h2>
            <p>This page displays the results of a network-wide routing analysis. It traces the Layer 3 path between every pair of subnets on all devices to identify routing asymmetries, loops, and dead ends.</p>
            
            <h3>Filters Explained</h3>
            <dl>
                <dt>Search All Fields</dt>
                <dd>A case-insensitive text search that filters for rows containing your query in any of the columns.</dd>
                <dt>Device A / Device B</dt>
                <dd>Filters for rows where the respective device name matches. Supports the asterisk `*` as a wildcard (e.g., `core-*`).</dd>
                <dt>Status</dt>
                <dd>Filters based on the symmetry of the path. "Asymmetric" means the forward path is different from the reverse path.</dd>
                <dt>Result</dt>
                <dd>Filters based on the final outcome of the path trace for either direction.</dd>
                <dt>Pair Type</dt>
                <dd>Filters the type of device pairing. "Internal" pairs involve two internal devices. "External" pairs involve at least one external gateway (a device name starting with `EX_`).</dd>
            </dl>

            <h3>Result Definitions</h3>
            <dl>
                <dt>Reached</dt>
                <dd>A valid route was found and the destination subnet is connected to the final device in the path.</dd>
                <dt>No Route</dt>
                <dd>A device in the path had no route (including a default route) for the destination IP. The path is a dead end.</dd>
                <dt>Next Hop?</dt>
                <dd>A device has a route, but the next-hop IP address is not a known interface on any other device in the dataset. This often points to an unmonitored device or an internet gateway.</dd>
                <dt>Loop</dt>
                <dd>The trace detected that it visited the same device twice while trying to reach the destination, indicating a routing loop.</dd>
            </dl>
        </div>
    </div>

    <h1>Asymmetric Route Analysis</h1>
    <div id="controls">
        <div><label for="genericFilter">Search All Fields</label><input type="text" id="genericFilter" oninput="debouncedFilter()"></div>
        <div><label for="deviceAFilter">Device A</label><input type="text" id="deviceAFilter" oninput="debouncedFilter()"></div>
        <div><label for="deviceBFilter">Device B</label><input type="text" id="deviceBFilter" oninput="debouncedFilter()"></div>
        <div><label for="asymmetricFilter">Status</label><select id="asymmetricFilter" onchange="applyFilters()"></select></div>
        <div><label for="resultFilter">Result</label><select id="resultFilter" onchange="applyFilters()"></select></div>
        <div>
            <label for="interfaceTypeFilter">Pair Type</label>
            <select id="interfaceTypeFilter" onchange="applyFilters()">
                <option value="all">All Pairs</option>
                <option value="external">External</option>
                <option value="internal">Internal</option>
            </select>
        </div>
        <div class="path-toggle"><label><input type="checkbox" id="showIpPath" onchange="togglePathView()"> Show IP Path</label></div>
    </div>
    <div id="pagination-controls">
        <button id="prevPageBtn" onclick="goToPreviousPage()">Previous</button>
        <span id="pageInfo"></span>
        <button id="nextPageBtn" onclick="goToNextPage()">Next</button>
    </div>
    <table id="dataTable">
        <thead>
            <tr>
                <th>Device A</th><th>Device B</th><th>Subnet A</th><th>Subnet B</th><th>Asymmetric</th>
                <th class="path-col">Path A -> B</th><th>Result A -> B</th><th class="path-col">Path B -> A</th><th>Result B -> A</th>
            </tr>
        </thead>
        <tbody></tbody>
    </table>

    <script>
        const routeData = ##JSON_DATA##;
        let showIp = false;
        let currentPage = 1;
        const rowsPerPage = 200;
        let currentFilteredData = [];

        routeData.forEach(row => {
            row.searchableString = [ row.DeviceA, row.DeviceB, row.SubnetA, row.SubnetB, row.PathAtoB, row.PathBtoA ].join(' ').toLowerCase();
        });

        function renderTable(data) {
            const tableBody = document.querySelector("#dataTable tbody");
            tableBody.innerHTML = "";
            const fragment = document.createDocumentFragment();
            const createCell = (text, className = '') => {
                const td = document.createElement('td');
                td.textContent = text;
                if (className) td.className = className;
                return td;
            };
            const createPathCell = (hostname, ip) => {
                const td = document.createElement('td');
                td.className = 'path-col';
                td.dataset.hostname = hostname;
                td.dataset.ip = ip;
                td.textContent = showIp ? ip : hostname;
                return td;
            };
            data.forEach(row => {
                const tr = document.createElement("tr");
                tr.className = row.IsAsymmetric ? 'row-asymmetric' : 'row-symmetric';
                const resultAtoBClass = "result-" + row.ResultAtoB.replace(/ /g, '-').replace('?','_');
                const resultBtoAClass = "result-" + row.ResultBtoA.replace(/ /g, '-').replace('?','_');
                tr.appendChild(createCell(row.DeviceA));
                tr.appendChild(createCell(row.DeviceB));
                tr.appendChild(createCell(row.SubnetA));
                tr.appendChild(createCell(row.SubnetB));
                tr.appendChild(createCell(row.IsAsymmetric));
                tr.appendChild(createPathCell(row.PathAtoB, row.PathAtoB_IP));
                tr.appendChild(createCell(row.ResultAtoB, resultAtoBClass));
                tr.appendChild(createPathCell(row.PathBtoA, row.PathBtoA_IP));
                tr.appendChild(createCell(row.ResultBtoA, resultBtoAClass));
                fragment.appendChild(tr);
            });
            tableBody.appendChild(fragment);
        }
        
        function renderPage() {
            const totalRecords = currentFilteredData.length;
            let totalPages = Math.ceil(totalRecords / rowsPerPage);
            totalPages = totalPages > 0 ? totalPages : 1;
            if (currentPage > totalPages) currentPage = totalPages;
            if (currentPage < 1) currentPage = 1;
            const start = (currentPage - 1) * rowsPerPage;
            const end = start + rowsPerPage;
            renderTable(currentFilteredData.slice(start, end));
            document.getElementById('pageInfo').textContent = `Page ${currentPage} of ${totalPages} (${totalRecords} records)`;
            document.getElementById('prevPageBtn').disabled = currentPage === 1;
            document.getElementById('nextPageBtn').disabled = currentPage === totalPages;
        }

        function applyFilters() {
            const genericFilter = document.getElementById("genericFilter").value.toLowerCase();
            const deviceAFilter = document.getElementById("deviceAFilter").value.toLowerCase().replace(/\*/g, '.*');
            const deviceBFilter = document.getElementById("deviceBFilter").value.toLowerCase().replace(/\*/g, '.*');
            const reA = new RegExp(deviceAFilter);
            const reB = new RegExp(deviceBFilter);
            const asymmetricFilter = document.getElementById("asymmetricFilter").value;
            const resultFilter = document.getElementById("resultFilter").value;
            const interfaceTypeFilter = document.getElementById("interfaceTypeFilter").value;

            currentFilteredData = routeData.filter(row => {
                const asymMatch = (asymmetricFilter === 'all') || (asymmetricFilter === 'asymmetric' && row.IsAsymmetric) || (asymmetricFilter === 'symmetric' && !row.IsAsymmetric);
                const resultMatch = (resultFilter === 'all') || (row.ResultAtoB === resultFilter) || (row.ResultBtoA === resultFilter);
                const genericMatch = genericFilter === '' || row.searchableString.includes(genericFilter);
                const deviceAMatch = reA.test(row.DeviceA.toLowerCase());
                const deviceBMatch = reB.test(row.DeviceB.toLowerCase());
                const typeMatch = interfaceTypeFilter === 'all' ||
                    (interfaceTypeFilter === 'external' && (row.DeviceA.startsWith('EX_') || row.DeviceB.startsWith('EX_'))) ||
                    (interfaceTypeFilter === 'internal' && !row.DeviceA.startsWith('EX_') && !row.DeviceB.startsWith('EX_'));
                return deviceAMatch && deviceBMatch && asymMatch && resultMatch && genericMatch && typeMatch;
            });
            currentPage = 1;
            renderPage();
        }

        function debounce(func, delay) {
            let timeout;
            return function(...args) {
                clearTimeout(timeout);
                timeout = setTimeout(() => func.apply(this, args), delay);
            };
        }
        const debouncedFilter = debounce(applyFilters, 300);

        function togglePathView() {
            showIp = document.getElementById("showIpPath").checked;
            renderPage();
        }

        function goToNextPage() {
            currentPage++;
            renderPage();
        }
        function goToPreviousPage() {
            currentPage--;
            renderPage();
        }

        function openHelpModal() { document.getElementById('helpModal').classList.remove('hidden'); }
        function closeHelpModal() { document.getElementById('helpModal').classList.add('hidden'); }

        document.addEventListener('DOMContentLoaded', () => {
            const resultValues = [...new Set(routeData.flatMap(r => [r.ResultAtoB, r.ResultBtoA]))];
            const resultFilterEl = document.getElementById('resultFilter');
            resultFilterEl.innerHTML = '<option value="all">All Results</option>' + resultValues.map(v => `<option value="${v}">${v}</option>`).join('');

            const asymmetricFilterEl = document.getElementById('asymmetricFilter');
            asymmetricFilterEl.innerHTML = '<option value="all">All Statuses</option><option value="asymmetric">Asymmetric</option><option value="symmetric">Symmetric</option>';

            document.getElementById('genericFilter').addEventListener('input', debouncedFilter);
            document.getElementById('deviceAFilter').addEventListener('input', debouncedFilter);
            document.getElementById('deviceBFilter').addEventListener('input', debouncedFilter);
            
            document.getElementById('helpModal').addEventListener('click', function(event) {
                if (event.target === this) { closeHelpModal(); }
            });

            currentFilteredData = routeData;
            renderPage();
        });
    </script>
</body>
</html>
'@

    # Step 4: Use a verbatim here-string (@'') and replace the placeholder.
    $htmlContent = $htmlTemplate.Replace('##JSON_DATA##', $jsonData)

    # Step 5: Write the final content to the specified output file
    try {
        Set-Content -Path $OutputPath -Value $htmlContent -Encoding UTF8
        Write-Host "Successfully exported analysis to '$OutputPath'" -ForegroundColor Green
    } catch {
        Write-Error "Failed to write to '$OutputPath'. Error: $_"
    }
}




# =================================================================================
# --- SCRIPT WORKFLOW & TEST ---
# =================================================================================

# Assuming $GArrayOfObjects is already populated with your device configuration data.

# --- CORRECTED AND FINAL WORKFLOW ---

# 1. Build the IP-to-Device lookup table from the original, read-only device array.
$DeviceLookupTable = Create-DeviceLookupTable -GArrayOfObjects $GArrayOfObjects

# 2. Create virtual device objects for all routes pointing to unknown gateways.
$virtualDevices = Create-VirtualDevices -GArrayOfObjects $GArrayOfObjects -DeviceLookupTable $DeviceLookupTable

# 3. Create a NEW, temporary array containing both original and virtual devices.
$AllDevices = $GArrayOfObjects + $virtualDevices
Write-Verbose "Total devices (real + virtual) to process: $($AllDevices.Count)"

# 4. Create pairs using the combined device list. The modified function now correctly skips self-referential pairs.
$SubnetPairs = Create-SubnetPairs -GArrayOfObjects $AllDevices

# 5. Build the route table and filter any remaining redundant pairs.
$RouteLookupTable = Create-RouteLookupTableLPM -GArrayOfObjects $AllDevices
$FilteredPairs = Filter-RedundantPairs -SubnetPairs $SubnetPairs -RouteLookupTable $RouteLookupTable

# 6. Trace all paths using the fully filtered list.
#    It's CRITICAL to pass the combined '$AllDevices' list here so the tracer can find the virtual devices as destinations.
$PopulatedPairs = Trace-AllSubnetPairPaths -SubnetPairs $FilteredPairs -RouteLookupTable $RouteLookupTable -GArrayOfObjects $AllDevices -DeviceLookupTable $DeviceLookupTable

# 7. Display the final, comprehensive results.
Export-AsymmetricRouteAnalysisHTML -PopulatedPairs $PopulatedPairs -OutputPath "./route_analysis.html"

