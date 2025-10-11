
# ===================================================================
# ========= START: C# PERFORMANCE ACCELERATOR             =========
# ===================================================================
Add-Type @"
using System;
using System.Collections.Generic;
using System.Linq;
using System.Management.Automation;
using System.Net;

namespace NetworkAnalysisTools{
    
    // --- CLASSES FOR PAIR GENERATION ---
    #region Pair Generation
    public class PSInterface
    {
        public string Hostname { get; set; }
        public string DeviceIdentifier { get; set; }
        public string Cidr { get; set; }
        public string IpAddress { get; set; }   // NEW: actual interface IP
    }

    public class PSExternalSubnet
    {
        public string EdgeHostname { get; set; }
        public string EdgeDeviceIdentifier { get; set; }
        public string Subnet { get; set; }
        public string IpAddress { get; set; }   // NEW: edge/gateway IP
    }

    public static class PairGenerator
    {
        public static Dictionary<string, PSObject> GenerateInternalPairs(List<PSInterface> interfaces)
        {
            var pairs = new Dictionary<string, PSObject>();
            if (interfaces == null || interfaces.Count < 2) return pairs;

            for (int i = 0; i < interfaces.Count - 1; i++)
            {
                for (int j = i + 1; j < interfaces.Count; j++)
                {
                    var interfaceA = interfaces[i];
                    var interfaceB = interfaces[j];
                    if (interfaceA.Hostname == interfaceB.Hostname) continue;

                    string identifierA = $"{interfaceA.Hostname}:{interfaceA.Cidr}";
                    string identifierB = $"{interfaceB.Hostname}:{interfaceB.Cidr}";
                    string pairKey = string.CompareOrdinal(identifierA, identifierB) < 0 ? identifierA + "_" + identifierB : identifierB + "_" + identifierA;

                    if (!pairs.ContainsKey(pairKey))
                    {
                        var pairObject = new PSObject();
                        // CORRECTED: Using .Members.Add() instead of .Properties.Add()
                        pairObject.Members.Add(new PSNoteProperty("DeviceA", interfaceA.Hostname));
                        pairObject.Members.Add(new PSNoteProperty("DeviceIdentifierA", interfaceA.DeviceIdentifier));
                        pairObject.Members.Add(new PSNoteProperty("IpA", interfaceA.IpAddress));
                        pairObject.Members.Add(new PSNoteProperty("SubnetA", interfaceA.Cidr));
                        pairObject.Members.Add(new PSNoteProperty("IpA", interfaceA.IpAddress));
                        pairObject.Members.Add(new PSNoteProperty("DeviceB", interfaceB.Hostname));
                        pairObject.Members.Add(new PSNoteProperty("DeviceIdentifierB", interfaceB.DeviceIdentifier));
                        pairObject.Members.Add(new PSNoteProperty("SubnetB", interfaceB.Cidr));
                        pairObject.Members.Add(new PSNoteProperty("IpB", interfaceB.IpAddress));
                        pairObject.Members.Add(new PSNoteProperty("IpB", interfaceB.IpAddress));                        
                        pairObject.Members.Add(new PSNoteProperty("Symmetry", null));
                        pairObject.Members.Add(new PSNoteProperty("PathType", "Internal"));
                        pairObject.Members.Add(new PSNoteProperty("PathsForward", new object[0]));
                        pairObject.Members.Add(new PSNoteProperty("PathsReverse", new object[0]));
                        pairs.Add(pairKey, pairObject);
                    }
                }
            }
            return pairs;
        }

        public static Dictionary<string, PSObject> GenerateEgressPairs(List<PSInterface> internalInterfaces, List<PSExternalSubnet> externalSubnets)
        {
            var pairs = new Dictionary<string, PSObject>();
            if (internalInterfaces == null || externalSubnets == null) return pairs;
            // Helper: compute the first usable host IP from a CIDR subnet
            string GetFirstHostIp(string cidr)
            {
                if (string.IsNullOrEmpty(cidr)) return null;
                var parts = cidr.Split('/');
                if (parts.Length != 2) return null;
                if (!IPAddress.TryParse(parts[0], out IPAddress baseIp)) return null;
                if (!int.TryParse(parts[1], out int prefixLength)) return null;

                byte[] bytes = baseIp.GetAddressBytes();
                if (BitConverter.IsLittleEndian) Array.Reverse(bytes);
                uint ipInt = BitConverter.ToUInt32(bytes, 0);
                if (prefixLength < 31) ipInt += 1;  // skip network address
                byte[] ipBytes = BitConverter.GetBytes(ipInt);
                if (BitConverter.IsLittleEndian) Array.Reverse(ipBytes);
                return new IPAddress(ipBytes).ToString();
            }
            foreach (var internalInt in internalInterfaces)
            {
                foreach (var externalSub in externalSubnets)
                {
                    if (internalInt.Hostname == externalSub.EdgeHostname) continue;

                    string identifierA = $"{internalInt.Hostname}:{internalInt.Cidr}";
                    string identifierB = $"{externalSub.EdgeHostname}:{externalSub.Subnet}";
                    string pairKey = string.CompareOrdinal(identifierA, identifierB) < 0 ? identifierA + "_" + identifierB : identifierB + "_" + identifierA;

                    if (!pairs.ContainsKey(pairKey))
                    {
                        var pairObject = new PSObject();
                        // CORRECTED: Using .Members.Add() instead of .Properties.Add()
                        pairObject.Members.Add(new PSNoteProperty("DeviceA", internalInt.Hostname));
                        pairObject.Members.Add(new PSNoteProperty("DeviceIdentifierA", internalInt.DeviceIdentifier));
                        pairObject.Members.Add(new PSNoteProperty("IpA", internalInt.IpAddress));                        
                        pairObject.Members.Add(new PSNoteProperty("SubnetA", internalInt.Cidr));
                        pairObject.Members.Add(new PSNoteProperty("IpA", internalInt.IpAddress));
                        pairObject.Members.Add(new PSNoteProperty("DeviceB", externalSub.EdgeHostname));
                        pairObject.Members.Add(new PSNoteProperty("DeviceIdentifierB", externalSub.EdgeDeviceIdentifier));
                        pairObject.Members.Add(new PSNoteProperty("SubnetB", externalSub.Subnet));
                        pairObject.Members.Add(new PSNoteProperty("IpB", GetFirstHostIp(externalSub.Subnet)));
                        pairObject.Members.Add(new PSNoteProperty("Symmetry", null));
                        pairObject.Members.Add(new PSNoteProperty("PathType", "External"));
                        pairObject.Members.Add(new PSNoteProperty("PathsForward", new object[0]));
                        pairObject.Members.Add(new PSNoteProperty("PathsReverse", new object[0]));
                        pairs.Add(pairKey, pairObject);
                    }
                }
            }
            return pairs;
        }
    }
    #endregion

    // --- CLASSES FOR RADIX TREE ---
    #region Radix Tree
    public class RadixTreeNode
    {
        public Dictionary<char, RadixTreeNode> Children { get; set; }
        public PSObject Route { get; set; }

        public RadixTreeNode()
        {
            Children = new Dictionary<char, RadixTreeNode>();
            Route = null;
        }
    }

    public class RadixTree
    {
        private readonly RadixTreeNode _root;
        public RadixTree() { _root = new RadixTreeNode(); }

        private static bool TryIpToUint(string ip, out uint ipInt)
        {
            ipInt = 0;
            if (!IPAddress.TryParse(ip, out IPAddress ipAddress)) return false;
            byte[] ipBytes = ipAddress.GetAddressBytes();
            if (BitConverter.IsLittleEndian) { Array.Reverse(ipBytes); }
            ipInt = BitConverter.ToUInt32(ipBytes, 0);
            return true;
        }

        public void AddRoute(string cidr, PSObject route)
        {
            if (string.IsNullOrEmpty(cidr) || route == null) return;
            var parts = cidr.Split('/');
            if (parts.Length != 2) return;
            if (!TryIpToUint(parts[0], out uint ipInt)) return;
            if (!int.TryParse(parts[1], out int prefixLength)) return;

            var currentNode = _root;
            for (int i = 0; i < prefixLength; i++)
            {
                char bit = ((ipInt >> (31 - i)) & 1) == 1 ? '1' : '0';
                if (!currentNode.Children.ContainsKey(bit))
                {
                    currentNode.Children[bit] = new RadixTreeNode();
                }
                currentNode = currentNode.Children[bit];
            }
            currentNode.Route = route;
        }

        public PSObject FindBestMatch(string destinationIp)
        {
            if (!TryIpToUint(destinationIp, out uint ipInt)) return null;
            PSObject bestMatch = null;
            var currentNode = _root;

            if (currentNode.Route != null) bestMatch = currentNode.Route;

            for (int i = 0; i < 32; i++)
            {
                char bit = ((ipInt >> (31 - i)) & 1) == 1 ? '1' : '0';
                if (!currentNode.Children.ContainsKey(bit)) break;
                
                currentNode = currentNode.Children[bit];
                if (currentNode.Route != null) bestMatch = currentNode.Route;
            }
            return bestMatch;
        }
    }
    #endregion
     // --- NEW: PATH TRACING ENGINE ---
        #region Path Tracer
        public class Hop
        {
            public string DeviceName { get; set; }
            public string IngressInterface { get; set; }
            public string EgressInterface { get; set; }
            public string GatewayUsed { get; set; }
            public string MatchedRoute { get; set; }
        }

        // FIX #2: Changed from 'private' to 'internal' to make it accessible
        internal class TraceState
        {
            public List<Hop> PathHistory { get; set; }
            public string CurrentDeviceName { get; set; }
            public string IngressInterface { get; set; }
        }

        public static class PathTracer
        {
        private static PSObject CreatePathObject(List<Hop> hopDetails, int pathNumber, string finalStatus, string terminationReason){
                var pathObject = new PSObject();
                pathObject.Members.Add(new PSNoteProperty("PathNumber", pathNumber));
                pathObject.Members.Add(new PSNoteProperty("Status", finalStatus));
                pathObject.Members.Add(new PSNoteProperty("DevicePath", hopDetails.Select(h => h.DeviceName).ToArray()));
                pathObject.Members.Add(new PSNoteProperty("InterfacePath", hopDetails.Select(h => h.EgressInterface).ToArray()));
                pathObject.Members.Add(new PSNoteProperty("SubnetPath", hopDetails.Select(h => h.MatchedRoute).ToArray()));
                
                var hopObjects = new List<PSObject>();
                string[] statuses = { "Reached", "NoRoute", "Terminated" };

                for (int i = 0; i < hopDetails.Count; i++)
                {
                    var hop = hopDetails[i];
                    var hopObj = new PSObject();
                    hopObj.Members.Add(new PSNoteProperty("Device", hop.DeviceName));
                    hopObj.Members.Add(new PSNoteProperty("Interface", hop.EgressInterface));
                    hopObj.Members.Add(new PSNoteProperty("Subnet", hop.MatchedRoute));
                    hopObj.Members.Add(new PSNoteProperty("Gateway", hop.GatewayUsed));
                    
                    string hopStatus = (i == hopDetails.Count - 1) ? finalStatus : "Reached";
                    if (finalStatus == "Reached (External)") hopStatus = "Reached";
                    if (!statuses.Contains(hopStatus)) hopStatus = "Terminated";
                    
                    hopObj.Members.Add(new PSNoteProperty("Status", hopStatus));
                    hopObjects.Add(hopObj);
                }
                pathObject.Members.Add(new PSNoteProperty("HopDetails", hopObjects.ToArray()));
                pathObject.Members.Add(new PSNoteProperty("TerminationReason", terminationReason));
                
                return pathObject;
            }

            public static List<PSObject> Trace(
                string startDevice, string startIp,
                string endDevice, string endIp, string endSubnet, int maxHops,
                Dictionary<string, object> deviceLookupTable,
                Dictionary<string, RadixTree> routeRadixTrees)
            {
                var finalizedPaths = new List<PSObject>();
                var forksToExplore = new Stack<TraceState>();

                forksToExplore.Push(new TraceState {
                    PathHistory = new List<Hop>(),
                    CurrentDeviceName = startDevice,
                    IngressInterface = ""
                });

                while (forksToExplore.Count > 0 && finalizedPaths.Count < 8)
                {
                    var currentTrace = forksToExplore.Pop();
                    var path = currentTrace.PathHistory;
                    var currentDeviceName = currentTrace.CurrentDeviceName;
                    var ingressInterface = currentTrace.IngressInterface;
                    string pathStatus = "In Progress";
                    string terminationReason = null;   // track why a path ended

                    for (int hopCount = path.Count; hopCount < maxHops; hopCount++)
                    {
                        if (path.Any(h => h.DeviceName == currentDeviceName))
                        {
                            pathStatus = "Loop";
                            terminationReason = $"Loop detected at {currentDeviceName}";
                            break;
                        }

                        var currentHop = new Hop { DeviceName = currentDeviceName, IngressInterface = ingressInterface };
                        path.Add(currentHop);

                        // Require a real destination host IP
                        if (string.IsNullOrWhiteSpace(endIp)) {
                            pathStatus = "Invalid Destination";
                            terminationReason = $"No destination IP for {endDevice} in {endSubnet}";
                            break;
                        }
                        string destIpForLookup = endIp;

                        RadixTree deviceTree = routeRadixTrees.ContainsKey(currentDeviceName) ? routeRadixTrees[currentDeviceName] : null;
                        PSObject bestRoute = deviceTree?.FindBestMatch(destIpForLookup);

                        if (bestRoute == null) {
                            pathStatus = "No Route";
                            terminationReason = $"No route on {currentDeviceName} for {destIpForLookup}";
                            break;
                        }

                        currentHop.EgressInterface = bestRoute.Properties["interface"]?.Value as string;
                        currentHop.GatewayUsed = bestRoute.Properties["gateway"]?.Value as string;
                        currentHop.MatchedRoute = bestRoute.Properties["Subnet"]?.Value as string;

                        // ----- External/Internal decision rules -----
                        bool isExternal   = bestRoute.Properties["IsExternal"]?.Value as bool? == true;
                        string routeSubnet = bestRoute.Properties["Subnet"]?.Value as string;
                        string edgeHostOnRoute = bestRoute.Properties["EdgeHostname"]?.Value as string;
                        bool endIsInternal = !string.IsNullOrEmpty(endDevice) && routeRadixTrees != null && routeRadixTrees.ContainsKey(endDevice);

                        if (isExternal)
                        {
                            bool subnetMatches = false;

                            // Allow reaching internal edge devices that own the external subnet
                            if (string.Equals(currentDeviceName, endDevice, StringComparison.OrdinalIgnoreCase))
                            {
                                subnetMatches = string.Equals(routeSubnet, endSubnet, StringComparison.OrdinalIgnoreCase);
                                if (subnetMatches)
                                {
                                    pathStatus = "Reached (External)";
                                    terminationReason = $"Destination external subnet {endSubnet} owned by internal edge {currentDeviceName}";
                                    break;
                                }
                            }

                            string expectedEdge = endDevice; // expected edge host
                            bool deviceMatches =
                                !string.IsNullOrEmpty(expectedEdge) &&
                                (string.Equals(currentDeviceName, expectedEdge, StringComparison.OrdinalIgnoreCase) ||
                                 (!string.IsNullOrEmpty(edgeHostOnRoute) &&
                                  string.Equals(edgeHostOnRoute, expectedEdge, StringComparison.OrdinalIgnoreCase)));

                            if (!deviceMatches)
                            {
                                pathStatus = "Wrong External Host";
                                terminationReason = $"Edge {currentDeviceName} reached but wrong subnet {routeSubnet}";
                                break;
                            }

                            subnetMatches = string.Equals(routeSubnet, endSubnet, StringComparison.OrdinalIgnoreCase);
                            if (!subnetMatches)
                            {
                                pathStatus = "External Mismatch";
                                terminationReason = $"Edge {currentDeviceName} subnet mismatch (expected {endSubnet}, got {routeSubnet})";
                                break;
                            }

                            pathStatus = "Reached (External)";
                            terminationReason = "Destination subnet reached via external edge";
                            break;
                        }


                        string routeProto = (bestRoute.Properties["RouteProtocol"]?.Value as string)?.ToLowerInvariant();
                        bool isLoopback = currentHop.EgressInterface != null &&
                                          currentHop.EgressInterface.StartsWith("Loopback", StringComparison.OrdinalIgnoreCase);

                        if (isLoopback ||
                            routeProto == "access-internal" ||
                            routeProto == "connect" ||
                            routeProto == "host" ||
                            routeProto == "connected" ||
                            routeProto == "local" ||
                            routeProto == "direct")
                        {
                            if (!string.Equals(currentDeviceName, endDevice, StringComparison.OrdinalIgnoreCase))
                            {
                                // Append final hop for the destination device so symmetry checks align
                                var destHop = new Hop {
                                    DeviceName      = endDevice,
                                    IngressInterface = currentHop.EgressInterface,
                                    EgressInterface = null,
                                    GatewayUsed     = null,
                                    MatchedRoute    = endSubnet
                                };
                                path.Add(destHop);
                            }

                            pathStatus = "Reached";
                            terminationReason = isLoopback
                                ? $"Destination {endDevice} reached via loopback {currentHop.EgressInterface}"
                                : $"Destination subnet {endSubnet} directly connected on {currentDeviceName}";
                            break;
                        }
                        if (currentHop.EgressInterface != null && currentHop.EgressInterface.StartsWith("Null")) { 
                            pathStatus = "Terminated";
                            terminationReason = $"Traffic to {endSubnet} dropped via {currentHop.EgressInterface}";                            
                            break; 
                        }
                        if (string.IsNullOrEmpty(currentHop.GatewayUsed)) { 
                            pathStatus = "No Route";
                            terminationReason = $"No gateway for {endSubnet} on {currentDeviceName}";                            
                            break; 
                        }

                        if (!deviceLookupTable.ContainsKey(currentHop.GatewayUsed)) { 
                            pathStatus = "Unknown Next Hop";
                            terminationReason = $"Gateway {currentHop.GatewayUsed} unknown in device lookup table";                            
                            break; 
                        }

                        // --- Extract next-hop targets (may be multiple if HA/cluster IP) ---
                        object raw = deviceLookupTable[currentHop.GatewayUsed];
                        if (raw is PSObject pso) raw = pso.BaseObject;

                        List<object> nextHopList = raw as List<object>;
                        if (nextHopList == null && raw is System.Collections.IEnumerable ie)
                        {
                            nextHopList = ie.Cast<object>().ToList();
                        }

                        if (nextHopList == null || nextHopList.Count == 0)
                        {
                            pathStatus = "Unknown Next Hop";
                            terminationReason = $"No device claimed gateway {currentHop.GatewayUsed}";
                            break;
                        }

                        // If multiple devices share this IP, fork paths for HA peers
                        for (int i = 1; i < nextHopList.Count; i++)
                        {
                            var forkHop = nextHopList[i] as PSObject;
                            forksToExplore.Push(new TraceState {
                                PathHistory = new List<Hop>(path),
                                CurrentDeviceName = forkHop.Properties["Hostname"].Value as string,
                                IngressInterface = forkHop.Properties["Interface"].Value as string
                            });
                        }

                        // Continue tracing down the first device
                        var firstHop = nextHopList[0] as PSObject ?? new PSObject(nextHopList[0]);
                        currentDeviceName = firstHop.Properties["Hostname"]?.Value as string;
                        ingressInterface = firstHop.Properties["Interface"]?.Value as string;

                        if (string.IsNullOrEmpty(currentDeviceName))
                        {
                            pathStatus = "Unknown Next Hop";
                            terminationReason = $"Empty hostname for gateway {currentHop.GatewayUsed}";
                            break;
                        }
                    }

                    if (pathStatus == "In Progress") pathStatus = "Max Hops";
                    
                    finalizedPaths.Add(CreatePathObject(path, finalizedPaths.Count + 1, pathStatus, terminationReason));
                }
                return finalizedPaths;
            }

        }
        #endregion    
}
"@



# ===================================================================
# ========= END: C# PERFORMANCE ACCELERATOR               =========
# ===================================================================




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
        # Null-safe symmetry check
        if (-not $pathA -or -not $pathB -or -not $pathA.DevicePath -or -not $pathB.DevicePath) {
            return $false
        }
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
    if ($null -ne $forwardPrimary -and $null -ne $reversePrimary) {
        $statusA = $forwardPrimary.Status -replace '\s*\(External\)', ''
        $statusB = $reversePrimary.Status -replace '\s*\(External\)', ''
        if ($statusA -ne $statusB) {
            if ($logThisCheck) { Write-Host "[DEBUG] Asymmetric: Primary path statuses do not match ('$statusA' vs '$statusB')." }
            return $true # Asymmetric
        }
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
        return $pathParts -join '<br>-> '
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
    
    $formatPathWithFullDetails = {
        param($PathObject)
        if ($null -eq $PathObject) { return $PathObject.Status }

        $hops = $PathObject.HopDetails
        $pathParts = [System.Collections.Generic.List[string]]::new()

        foreach ($hop in $hops) {
            $details = @()
            if ($hop.Interface) { $details += "Out: $($hop.Interface)" }
            if ($hop.Gateway)   { $details += "GW: $($hop.Gateway)" }
            if ($hop.Subnet)    { $details += "Route: $($hop.Subnet)" }

            $deviceSpan = "<span class=`"device-hover`" data-device-name=`"$($hop.Device)`" data-matched-route=`"$($hop.Subnet)`">$($hop.Device)</span>"

            if ($details.Count -gt 0) {
                $pathParts.Add("$deviceSpan ($($details -join ', '))")
            } else {
                $pathParts.Add($deviceSpan)
            }
        }

        return $pathParts -join ' -> '
    }
    foreach ($key in $PopulatedPairs.Keys) {
        $pair = $PopulatedPairs[$key]
        $maxPathCount = [Math]::Max($pair.PathsForward.Count, $pair.PathsReverse.Count)
        if ($maxPathCount -eq 0) { $maxPathCount = 1 }

        for ($i = 0; $i -lt $maxPathCount; $i++) {
            $fwdPath = $pair.PathsForward[$i]
            $revPath = $pair.PathsReverse[$i]

            # capture termination reason before adding row
            $terminationReasonA = if ($fwdPath) { $fwdPath.TerminationReason } else { "N/A" }
            $terminationReasonB = if ($revPath) { $revPath.TerminationReason } else { "N/A" }

            $row = [PSCustomObject]@{
                PairKey              = $key
                PathRole             = if ($i -eq 0) { "Primary" } else { "Alternate" }
                PathType             = $pair.PathType
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
                PathAtoB_Full        = & $formatPathWithFullDetails $fwdPath
                ResultAtoB           = if ($fwdPath) { $fwdPath.Status } else { "Not Traced" }
                TerminationReasonA    = $terminationReasonA
                PathBtoA_Interface   = & $formatPathWithInterfaces $revPath
                PathBtoA_Host        = & $formatPathAsHostOnly $revPath
                PathBtoA_IP          = & $formatPathWithIPs $revPath $pair.SubnetB
                PathBtoA_Full        = & $formatPathWithFullDetails $revPath
                ResultBtoA           = if ($revPath) { $revPath.Status } else { "Not Traced" }
                TerminationReasonB    = $terminationReasonB
                Symmetry             = $pair.Symmetry
                DeviceA_Raw          = $pair.DeviceA
                DeviceB_Raw          = $pair.DeviceB
            }
            $exportData.Add($row)
        }

    }

    $jsonData = $exportData | ConvertTo-Json -Depth 50 -Compress
    # Create a targeted array of objects for the device data.
    $deviceDataForJson = foreach ($device in $AllDeviceObjects) {
        $cleanInterfaces = $device.interfaces | Select-Object Interface, Description, IPAddress, SecondaryIPAddress, Cidr, SubnetMask, shutdown

        # FIX: Build a clean routing table from the original routes
        $cleanRoutingTable = @()
        if ($device.RoutingTable) {
            $cleanRoutingTable = $device.RoutingTable | Select-Object Subnet, gateway, RouteProtocol, interface, DISTANCE, METRIC
        }

        [PSCustomObject]@{
            hostname     = $device.hostname
            interfaces   = $cleanInterfaces
            RoutingTable = $cleanRoutingTable
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
        table { width: 100%; border-collapse: collapse; table-layout: auto; }
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
        .shrink-col { 
            white-space: nowrap;
            width: 1%;      /* let it shrink down */
        }
        td.shrink-col, th.shrink-col {
            white-space: nowrap;
        }        
    </style>
</head>
<body>
    <div class="header-container">
        <h1>Network Path Analysis</h1>
        <button id="helpBtn" onclick="openHelpModal()">?</button>
    </div>
    <div id="controls">
        <div>
            <label for="searchText">Search All Fields</label>
            <input type="text" id="searchText">
            <label style="margin-top:4px; font-size:0.8em;">
                <input type="checkbox" id="invertSearch"> Invert
            </label>
        </div>
        <div><label>&nbsp;</label><button id="resetFiltersBtn" style="width:50%; font-size:0.8em; padding:4px 8px;">Reset</button></div>
        <div><label for="pathTypeFilter">Path Type</label><select id="pathTypeFilter"></select></div>
        <div><label for="symmetryFilter">Symmetry Status</label><select id="symmetryFilter"></select></div>
        <div><label for="transitFilter">Subnet Type</label><select id="transitFilter"></select></div>
        <div><label for="resultFilter">Trace Result</label><select id="resultFilter"></select></div>
        <div><label for="firstDeviceFilter">First Device</label><select id="firstDeviceFilter"></select></div>
        <div><label for="firstSubnetFilter">First Subnet</label><select id="firstSubnetFilter"></select></div>
        <div><label for="secondDeviceFilter">Second Device</label><select id="secondDeviceFilter" disabled></select></div>
        <div><label for="secondSubnetFilter">Second Subnet</label><select id="secondSubnetFilter" disabled></select></div>
        <div><label for="pathViewFilter">Path Display Format</label><select id="pathViewFilter">
            <option value="Interface" selected>Host + Interface</option>
            <option value="Host">Host Only</option>
            <option value="IP">IP Only</option>
            <option value="Full">Full Details</option>
        </select></div>
        <div><label for="toggleRouteViewBtn">Interface/Routing Table Pop-up</label><button id="toggleRouteViewBtn" class="active">Enabled</button></div>
    </div>
    <div id="pagination">
        <button id="prevBtn">Previous</button>
        <span id="pageInfo"></span>
        <button id="nextBtn">Next</button>
    </div>
    <table id="dataTable">
        <thead>
            <tr>
                <th class="shrink-col">Path Type</th>
                <th class="shrink-col">Device A</th>
                <th class="shrink-col">Subnet A</th>
                <th class="shrink-col">Device B</th>
                <th class="shrink-col">Subnet B</th>
                <th style="width: 20%;">Path A -> B</th>
                <th style="width: 7%;">Result A->B</th>
                <th style="width: 20%;">Path B -> A</th>
                <th style="width: 7%;">Result B->A</th>
                <th class="shrink-col">Symmetry</th>
                <th class="shrink-col">Path Role</th>
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
        let isRouteViewEnabled = true;
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
        const firstDeviceFilter = document.getElementById('firstDeviceFilter');
        const firstSubnetFilter = document.getElementById('firstSubnetFilter');
        const secondDeviceFilter = document.getElementById('secondDeviceFilter');
        const secondSubnetFilter = document.getElementById('secondSubnetFilter');
        
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
                    if (!intf.shutdown) {
                        const ips = [];
                        if (intf.IPAddress) {
                            const primaryDisplay = intf.SubnetMask ? `${intf.IPAddress}/${intf.SubnetMask}` : intf.IPAddress;
                            ips.push(primaryDisplay);
                        }
                        if (intf.SecondaryIPAddress) ips.push(intf.SecondaryIPAddress);
                        if (intf.StandbyIP) ips.push(intf.StandbyIP);
                        if (intf.ClusterIP) ips.push(intf.ClusterIP);
        
                        // Only add interfaces that have at least one IP
                        if (ips.length > 0) {
                            listHtml += `<li>${intf.Interface}: ${ips.join(', ')}</li>`;
                        }
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
            const invertSearch = document.getElementById('invertSearch').checked;
            const pathType = pathTypeFilter.value;
            const symmetry = symmetryFilter.value;
            const transit = transitFilter.value;
            const result = resultFilter.value;
            const deviceA_val = firstDeviceFilter.value;
            const subnetA_val = firstSubnetFilter.value;
            const deviceB_val = secondDeviceFilter.value;
            const subnetB_val = secondSubnetFilter.value;

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
                    let searchMatch = true;
                    if (search !== '') {
                        const contains = row.searchableString.includes(search);
                        searchMatch = contains; // raw search result only, invert will be applied globally
                    }
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
                        // enforce opposite sides
                        subnetMatch = (row.SubnetA === subnetA_val && row.SubnetB === subnetB_val) ||
                                      (row.SubnetA === subnetB_val && row.SubnetB === subnetA_val);
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
                // --- Column Resizing ---
                document.querySelectorAll('#dataTable th').forEach(th => {
                    const resizer = document.createElement('div');
                    resizer.style.width = '5px';
                    resizer.style.cursor = 'col-resize';
                    resizer.style.position = 'absolute';
                    resizer.style.top = 0;
                    resizer.style.right = 0;
                    resizer.style.bottom = 0;
                    th.style.position = 'relative';
                    th.appendChild(resizer);
        
                    let startX, startWidth;
                    resizer.addEventListener('mousedown', e => {
                        startX = e.pageX;
                        startWidth = th.offsetWidth;
                        document.addEventListener('mousemove', resize);
                        document.addEventListener('mouseup', stopResize);
                    });
                    function resize(e) {
                        th.style.width = (startWidth + (e.pageX - startX)) + 'px';
                    }
                    function stopResize() {
                        document.removeEventListener('mousemove', resize);
                        document.removeEventListener('mouseup', stopResize);
                    }
                });
                if ((isMatch && !invertSearch) || (!isMatch && invertSearch)) {
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
                    html += `<td class="shrink-col" rowspan="${rowSpan}">${row.PathType}</td>`;
                    html += `<td class="shrink-col" rowspan="${rowSpan}">${deviceADisplay}</td>`;
                    html += `<td class="shrink-col ${subnetA_class}" rowspan="${rowSpan}">${row.SubnetA}</td>`;
                    html += `<td class="shrink-col" rowspan="${rowSpan}">${deviceBDisplay}</td>`;
                    html += `<td class="shrink-col ${subnetB_class}" rowspan="${rowSpan}">${row.SubnetB}</td>`;
                }

                html += `<td>${row[pathViewKeyA] || ''}</td>`;
                html += `<td class="${resultAtoB_class}" title="${row.TerminationReasonA || ''}">${row.ResultAtoB}</td>`;
                html += `<td>${row[pathViewKeyB] || ''}</td>`;
                html += `<td class="${resultBtoA_class}" title="${row.TerminationReasonB || ''}">${row.ResultBtoA}</td>`;

                if (isFirstInPair) {
                    html += `<td class="shrink-col" rowspan="${rowSpan}">${row.Symmetry}</td>`;
                }

                html += `<td class="shrink-col">${row.PathRole}</td>`;

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

            // Populate First Device + all First Subnets immediately
            populateSelect(firstDeviceFilter, 'DeviceA_Raw', 'First Device');
            const allSubnets = [...new Set(allData.flatMap(r => [r.SubnetA, r.SubnetB]))].filter(Boolean).sort();
            firstSubnetFilter.innerHTML = '<option value="all">All First Subnets</option>' + allSubnets.map(s => `<option value="${s}">${s}</option>`).join('');
 

            // Second filters disabled until first device OR first subnet chosen
            secondDeviceFilter.innerHTML = '<option value="all">All Second Devices</option>';
            secondSubnetFilter.innerHTML = '<option value="all">All Second Subnets</option>';
            secondDeviceFilter.disabled = true;
            secondSubnetFilter.disabled = true;
        }
        // --- New Filter Logic ---
        firstDeviceFilter.addEventListener('change', () => {
            const firstDevice = firstDeviceFilter.value;

            // Reset dependent filters to ALL subnets if no device
            const allSubnets = [...new Set(allData.flatMap(r => [r.SubnetA, r.SubnetB]))].filter(Boolean).sort();
            firstSubnetFilter.innerHTML = '<option value="all">All First Subnets</option>' + allSubnets.map(s => `<option value="${s}">${s}</option>`).join('');

            secondDeviceFilter.innerHTML = '<option value="all">All Second Devices</option>';
            secondSubnetFilter.innerHTML = '<option value="all">All Second Subnets</option>';

            firstSubnetFilter.disabled = false; // Always stays enabled
            secondDeviceFilter.disabled = (firstDevice === 'all' && firstSubnetFilter.value === 'all');
            secondSubnetFilter.disabled = true;

            if (firstDevice !== 'all') {
                // Populate First Subnets with all subnets for this device
                const subnets = [...new Set(allData
                    .filter(r => r.DeviceA_Raw === firstDevice || r.DeviceB_Raw === firstDevice)
                    .flatMap(r => [r.SubnetA, r.SubnetB])
                )].filter(Boolean).sort();

                subnets.forEach(s => firstSubnetFilter.innerHTML += `<option value="${s}">${s}</option>`);

                // Populate Second Devices list
                const secondDevices = [...new Set(allData
                    .filter(r => (r.SubnetA === firstSubnetFilter.value || r.SubnetB === firstSubnetFilter.value) &&
                                (r.DeviceA_Raw !== firstDevice && r.DeviceB_Raw !== firstDevice))
                    .flatMap(r => [r.DeviceA_Raw, r.DeviceB_Raw])
                )].filter(Boolean).sort();

                secondDevices.forEach(d => secondDeviceFilter.innerHTML += `<option value="${d}">${d}</option>`);
            }

            applyFilters();
        });
        
        // Reset Filters Button
        document.getElementById('resetFiltersBtn').addEventListener('click', () => {
            searchText.value = '';
            pathTypeFilter.value = 'all';
            symmetryFilter.value = 'all';
            transitFilter.value = 'all';
            resultFilter.value = 'all';
            firstDeviceFilter.value = 'all';
            firstSubnetFilter.value = 'all';
            secondDeviceFilter.value = 'all';
            secondSubnetFilter.value = 'all';
            pathViewFilter.value = 'Interface';

            // restore full subnet/device lists
            const allSubnets = [...new Set(allData.flatMap(r => [r.SubnetA, r.SubnetB]))].filter(Boolean).sort();
            firstSubnetFilter.innerHTML = '<option value="all">All First Subnets</option>' + allSubnets.map(s => `<option value="${s}">${s}</option>`).join('');
            secondDeviceFilter.innerHTML = '<option value="all">All Second Devices</option>';
            secondSubnetFilter.innerHTML = '<option value="all">All Second Subnets</option>';
            secondDeviceFilter.disabled = true;
            secondSubnetFilter.disabled = true;

            applyFilters();
        });

        // Enable second subnet when second device or first subnet selected
        firstSubnetFilter.addEventListener('change', () => {
            const firstDevice = firstDeviceFilter.value;
            const firstSubnet = firstSubnetFilter.value;

            // Enable/disable Second Device based on either first picker being set
            secondDeviceFilter.disabled = (firstDevice === 'all' && firstSubnet === 'all');

            // Refresh Second Device options when First Subnet changes
            secondDeviceFilter.innerHTML = '<option value="all">All Second Devices</option>';
            if (firstSubnet !== 'all') {
                const candidateRows = allData.filter(r => r.SubnetA === firstSubnet || r.SubnetB === firstSubnet);
                const secondDevices = new Set();
                candidateRows.forEach(r => {
                    if (r.DeviceA_Raw && (firstDevice === 'all' || r.DeviceA_Raw !== firstDevice)) secondDevices.add(r.DeviceA_Raw);
                    if (r.DeviceB_Raw && (firstDevice === 'all' || r.DeviceB_Raw !== firstDevice)) secondDevices.add(r.DeviceB_Raw);
                });
                [...secondDevices].sort().forEach(d => secondDeviceFilter.innerHTML += `<option value="${d}">${d}</option>`);
            }

            // Second Subnet remains disabled until a Second Device is chosen
            secondSubnetFilter.disabled = (secondDeviceFilter.value === 'all');
            applyFilters();
        });

        secondDeviceFilter.addEventListener('change', () => {
            const secondDevice = secondDeviceFilter.value;
            secondSubnetFilter.innerHTML = '<option value="all">All Second Subnets</option>';

            if (secondDevice !== 'all') {
                // Populate Second Subnets only from this device
                const subnets = [...new Set(allData
                    .filter(r => r.DeviceA_Raw === secondDevice || r.DeviceB_Raw === secondDevice)
                    .flatMap(r => [r.SubnetA, r.SubnetB])
                )].filter(Boolean).sort();

                subnets.forEach(s => secondSubnetFilter.innerHTML += `<option value="${s}">${s}</option>`);
                secondSubnetFilter.disabled = false;
            } else {
                // If user clears Second Device, lock Second Subnet again
                secondSubnetFilter.disabled = true;
             }

            applyFilters();
        });

        secondSubnetFilter.addEventListener('change', applyFilters);
        document.addEventListener('DOMContentLoaded', () => {
            populateFilters();
            applyFilters();

            // Wire listeners to the correct (current) filter elements
            const allFilters = [searchText, pathTypeFilter, symmetryFilter, transitFilter, resultFilter,
                                firstDeviceFilter, firstSubnetFilter, secondDeviceFilter, secondSubnetFilter,
                                pathViewFilter];
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
    # 2. Construct a full, unique file path for the report
    $reportFileName = "$((Get-Date).ToString('yyyyMMdd-HHmmss'))-AnalysisTable.html"
    $AnalysisTablePath = Join-Path -Path $GOutPutDirectory -ChildPath $reportFileName
    $reportFileName = "$((Get-Date).ToString('yyyyMMdd-HHmmss'))-AnalysisGraph.html"
    $AnalysisGraphPath = Join-Path -Path $GOutPutDirectory -ChildPath $reportFileName    


    
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

    # --- Build Radix Trees directly in C# ---
    $RouteRadixTrees = @{}
    foreach ($device in $AllDevices) {
        if ([string]::IsNullOrEmpty($device.hostname) -or $null -eq $device.RoutingTable) { continue }
        $tree = [NetworkAnalysisTools.RadixTree]::new()
        foreach ($route in $device.RoutingTable) {
            $tree.AddRoute($route.Subnet, $route)
        }
        $RouteRadixTrees[$device.hostname] = $tree
    }

    Write-Verbose "[INFO] Data preparation complete. Processed $($GArrayOfObjectsFilter.Count) devices and their external routes."
    $phase1Stopwatch.Stop()
    Write-Host "[BENCHMARK] Phase 1 (Data Preparation) took $($phase1Stopwatch.Elapsed.TotalSeconds) seconds." -ForegroundColor Magenta

    # =================================================================
    # PHASE 2: Pair Generation
    # =================================================================
    $phase2Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Verbose "[PHASE 2] Starting pair generation..."


    # Build internal interfaces for pair generation
    $allInterfaces = [System.Collections.Generic.List[NetworkAnalysisTools.PSInterface]]::new()
    foreach ($device in $GArrayOfObjectsFilter) {
        if ($null -ne $device.interfaces) {
            foreach ($intf in $device.interfaces) {
                if (-not $intf.shutdown -and -not [string]::IsNullOrEmpty($intf.Cidr)) {
                    $psInt = [NetworkAnalysisTools.PSInterface]::new()
                    $psInt.Hostname = $device.hostname
                    $psInt.DeviceIdentifier = $device.DeviceIdentifier
                    $psInt.Cidr = $intf.Cidr
                    $psInt.IpAddress = $intf.IPAddress   # NEW: capture real interface IP
                    $allInterfaces.Add($psInt)
                }
            }
        }
    }

    $internalPairs = [NetworkAnalysisTools.PairGenerator]::GenerateInternalPairs($allInterfaces)

    # Build external subnets for egress pair generation
    $allExternalSubs = [System.Collections.Generic.List[NetworkAnalysisTools.PSExternalSubnet]]::new()
    foreach ($device in $GArrayOfObjectsFilter) {
        if ($null -ne $device.ExternalSubnets) {
            foreach ($ext in $device.ExternalSubnets) {
                $psExt = [NetworkAnalysisTools.PSExternalSubnet]::new()
                $psExt.EdgeHostname = $device.hostname
                $psExt.EdgeDeviceIdentifier = $device.DeviceIdentifier
                $psExt.Subnet = $ext.Subnet
                $psExt.IpAddress = $ext.Gateway        # NEW: use edge’s gateway IP as target
                $allExternalSubs.Add($psExt)
            }
        }
    }

    $egressPairs = [NetworkAnalysisTools.PairGenerator]::GenerateEgressPairs($allInterfaces, $allExternalSubs)

    # Combine the two hashtables of pairs into one master hashtable
    $allPairs = [hashtable]::new($internalPairs)
    foreach ($key in $egressPairs.Keys) {
        if (-not $allPairs.ContainsKey($key)) {
            $allPairs[$key] = $egressPairs[$key]
        }
    }

    Write-Verbose "[INFO] Pair generation complete. Found $($allPairs.Count) total unique pairs to trace."
    $phase2Stopwatch.Stop()
    Write-Host "[BENCHMARK] Phase 2 (Pair Generation) took $($phase2Stopwatch.Elapsed.TotalSeconds) seconds." -ForegroundColor Magenta


    # =================================================================
    # PHASE 3: Path Tracing and Symmetry Analysis (C# Accelerated)
    # =================================================================
    $phase3Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Verbose "[PHASE 3] Starting path tracing for all $($allPairs.Count) pairs (using C# accelerator)..."
    $traceLogLevel = & $getLogLevel "PathTrace"
    $symmetryLogLevel = & $getLogLevel "SymmetryCheck"
    # Convert PowerShell hashtables into typed dictionaries
    $deviceLookupDict = [System.Collections.Generic.Dictionary[string,object]]::new()
    foreach ($k in $DeviceLookupTable.Keys) {
        $deviceLookupDict[$k] = $DeviceLookupTable[$k]
    }

    $routeRadixDict = [System.Collections.Generic.Dictionary[string,NetworkAnalysisTools.RadixTree]]::new()
    foreach ($k in $RouteRadixTrees.Keys) {
        $routeRadixDict[$k] = $RouteRadixTrees[$k]
    }

    Write-Host "[DEBUG] DeviceLookup count = $($deviceLookupDict.Count)"
    Write-Host "[DEBUG] RouteRadix count   = $($routeRadixDict.Count)"
    $totalPairs = $allPairs.Count
    $currentPairIndex = 0

    foreach ($key in $allPairs.Keys) {
        $currentPairIndex++
        $pair = $allPairs[$key]

        # Update progress bar for Phase 3
        $percentComplete = [math]::Round(($currentPairIndex / $totalPairs) * 100, 2)
        Write-Progress -Activity "Phase 3: Path Tracing and Symmetry Analysis" `
                       -Status "Processing pair $currentPairIndex of $totalPairs" `
                       -PercentComplete $percentComplete

        # --- Trace Forward Path (A -> B) using real interface IPs ---
        $forwardPaths = [NetworkAnalysisTools.PathTracer]::Trace(
            $pair.DeviceA, $pair.IpA,
            $pair.DeviceB, $pair.IpB, $pair.SubnetB, $MaxHops,
            $deviceLookupDict, $routeRadixDict
        )

        # --- Trace Reverse Path (B -> A) using real interface IPs ---
        $reversePaths = [NetworkAnalysisTools.PathTracer]::Trace(
            $pair.DeviceB, $pair.IpB,
            $pair.DeviceA, $pair.IpA, $pair.SubnetA, $MaxHops,
            $deviceLookupDict, $routeRadixDict
        )

        $pair.PathsForward = $forwardPaths
        $pair.PathsReverse = $reversePaths

        $isAsymmetric = Test-PathSymmetry -PairObject $pair -LogLevel $symmetryLogLevel -DebugTargets $DebugTargets
        $pair.Symmetry = if ($isAsymmetric) { "Asymmetric" } else { "Symmetric" }
    }
    Write-Progress -Completed
    Write-Verbose "[INFO] Path tracing and analysis complete."
    $phase3Stopwatch.Stop()
    Write-Host "[BENCHMARK] Phase 3 (Path Tracing) took $($phase3Stopwatch.Elapsed.TotalSeconds) seconds." -ForegroundColor Magenta

    # =================================================================
    # PHASE 4: Reporting
    # =================================================================
    $phase4Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Verbose "[PHASE 4] Generating HTML report at '$AnalysisTablePath'..."

    Export-TraceAnalysisToHTML -PopulatedPairs $allPairs -OutputPath $AnalysisTablePath -TransitSubnets $transitSubnets -AllDeviceObjects $AllDevices

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





