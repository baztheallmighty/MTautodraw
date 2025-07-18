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


# Handles all connection types (Configured-to-Configured and Configured-to-Discovered) for both CDP and LLDP.
# Applies custom styles to Port-Channel connectors by calling the Get-ConnectorStyle helper function.
function Draw-AllNeighborsDrawio {
    [CmdletBinding()]
    param (
        # An array of PSObjects, where each object represents a configured network device with its interfaces and neighbor data.
        [parameter(Mandatory = $true)]
        $ArrayOfObjects,
        # An array of PSObjects for devices discovered via CDP but not part of the primary configured device set.
        [parameter(Mandatory = $true)]
        $ArrayOfCDPDeviceIDs,
        # An array of PSObjects for devices discovered via LLDP but not part of the primary configured device set.
        [parameter(Mandatory = $true)]
        $ArrayOfLLDPDeviceIDs
    )

    # This hashtable will cache the randomly generated styles for each Port-Channel number.
    # It is created here and passed by reference to the helper function.
    # This ensures that all segments of the same Port-Channel have a consistent visual style (e.g., color, pattern).
    $runtimePortChannelStyles = @{}

    # 1. Start the Diagram and Draw the Legend
    # Initializes a new Draw.io diagram page with a specific name for the physical layout.
    Start-DrawioDiagram -Name "CDP-LLDP Physical"
    # Adds a pre-defined interface legend to the diagram at a specified X/Y coordinate.
    Add-DrawioInterfaceLegend -Location ([PSCustomObject]@{X = -500; Y = 1400})

    # 2. Draw all hosts.
    # Set the initial X coordinate for the first host.
    $currentX = 100
    # Iterate through each configured device, sorted by hostname, to draw it on the diagram.
    foreach ($device in ($ArrayOfObjects | Sort-Object HostName)) {


        $hostWidth = $null
        # Calls a helper function to draw the host's physical chassis and interfaces.
        # The function returns the width of the drawn host, which is used for horizontal positioning.
        $hostWidth = Add-DrawioHostPhysical -Device $device -Location ([PSCustomObject]@{X = $currentX; Y = 100})
        # Update the X coordinate for the next host, adding a fixed padding plus the width of the host just drawn.
        $currentX += 950 + $hostWidth
    }

    # Reset coordinates to draw the discovered CDP neighbor devices in a new row.
    $currentX = 100
    $currentY = 700
    # Iterate through each device discovered via CDP.
    foreach ($cdpDevice in ($ArrayOfCDPDeviceIDs | Sort-Object ParentObject)) {
        # Calls a helper function to draw a simplified representation of a discovered neighbor.
        Add-DrawioNeighborHost -Device $cdpDevice -Location ([PSCustomObject]@{X = $currentX; Y = $currentY}) -DrawType "CDPNeighbor"
        # Increment the X coordinate for the next discovered device.
        $currentX += 950
    }

    # Reset coordinates again to draw the discovered LLDP neighbor devices in a third row.
    $currentX = 100
    $currentY = 1300
    # Iterate through each device discovered via LLDP.
    foreach ($lldpDevice in ($ArrayOfLLDPDeviceIDs | Sort-Object ParentObject)) {
        # Draw the discovered LLDP neighbor.
        Add-DrawioNeighborHost -Device $lldpDevice -Location ([PSCustomObject]@{X = $currentX; Y = $currentY}) -DrawType "LLDPNeighbor"
        # Increment the X coordinate.
        $currentX += 950
    }

    # ===================================================================
    # 3. --- Connect all the shapes with custom styling ---
    # ===================================================================
    # Loop through each of the primary configured devices to draw its connections.
    foreach ($device in $ArrayOfObjects) {
        # --- CDP Connections ---
        # Check if the device has any CDP neighbors.
        if ($device.CDPNeighbors) {
            # This block handles connections where the partner device is also a fully configured device in our dataset.
            # We identify these by checking if the 'PartnerEthernetInterface' property has been successfully populated.
            foreach ($cdpNeighbor in ($device.CDPNeighbors | Where-Object { $_.PartnerEthernetInterface -and $_.PartnerEthernetInterface.Value })) {
                # Find the local interface object on the source device.
                $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $cdpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
                # The remote interface object is already linked in the neighbor data.
                $toInterface = $cdpNeighbor.PartnerEthernetInterface.Value
                # Ensure both the source and target interface shapes were drawn and have IDs.
                if ($fromInterface.PhysicalDrawioId -and $toInterface.PhysicalDrawioId) {
                    # Get a consistent style for the connector, especially important for Port-Channels.
                    $style = Get-ConnectorStyle -fromInterface $fromInterface
                    # Draw the connector between the two interface shapes.
                    Add-DrawioConnector -SourceId $fromInterface.PhysicalDrawioId -TargetId $toInterface.PhysicalDrawioId -Style $style
                }
            }
            # This block handles connections to "discovered" neighbors, which are not in the main configured device list.
            # These are identified by having no 'PartnerEthernetInterface' populated.
            foreach ($cdpNeighbor in ($device.CDPNeighbors | Where-Object { -not $_.PartnerEthernetInterface })) {
                # Find the local interface object.
                $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $cdpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
                # Find the full device object for the discovered neighbor by matching its DeviceID.
                $toDevice = $ArrayOfCDPDeviceIDs | Where-Object { $_.HostName -eq $cdpNeighbor.DeviceID } | Select-Object -First 1
                if ($toDevice) {
                    # Now find the specific remote interface on that discovered device.
                    $toInterface = $toDevice.interfaces | Where-Object { $_.Interface -eq $cdpNeighbor.InterfaceRemoteDevice } | Select-Object -First 1
                    # If both interfaces are valid, draw the connector.
                    if ($fromInterface.PhysicalDrawioId -and $toInterface.PhysicalDrawioId) {
                        $style = Get-ConnectorStyle -fromInterface $fromInterface
                        Add-DrawioConnector -SourceId $fromInterface.PhysicalDrawioId -TargetId $toInterface.PhysicalDrawioId -Style $style
                    }
                }
            }
        }

        # --- LLDP Connections ---
        # Check if the device has any LLDP neighbors.
        if ($device.LLDPNeighbors) {
            # Handles connections between two fully configured devices.
            foreach ($lldpNeighbor in ($device.LLDPNeighbors | Where-Object { $_.PartnerEthernetInterface -and $_.PartnerEthernetInterface.Value })) {
                # Find the local and remote interface objects.
                $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $lldpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
                $toInterface = $lldpNeighbor.PartnerEthernetInterface.Value
                # If both shapes exist, get a style and draw the connector.
                if ($fromInterface.PhysicalDrawioId -and $toInterface.PhysicalDrawioId) {
                    $style = Get-ConnectorStyle -fromInterface $fromInterface
                    Add-DrawioConnector -SourceId $fromInterface.PhysicalDrawioId -TargetId $toInterface.PhysicalDrawioId -Style $style
                }
            }
            # Handles connections to discovered-only devices.
            # The 'HasCDPNeighborEntry' check prevents drawing a duplicate LLDP link if an equivalent CDP link already exists.
            foreach ($lldpNeighbor in ($device.LLDPNeighbors | Where-Object { (-not $_.PartnerEthernetInterface) -and (-not $_.HasCDPNeighborEntry) })) {

                # Get the local interface object.
                $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $lldpNeighbor.InterfaceLocalDevice } | Select-Object -First 1

                # Use the robust looping logic from the old Visio script to find the remote interface.
                $toInterface = $null # Reset for each neighbor

                # Use a labeled loop to allow breaking out from a nested loop.
                :outer foreach ($discoveredDevice in $ArrayOfLLDPDeviceIDs) {
                    # Check if the discovered device's hostname matches the neighbor's reported hostname or Chassis ID. LLDP can use either.
                    if (($discoveredDevice.hostname -eq $lldpNeighbor.HostName) -or ($discoveredDevice.hostname -eq $lldpNeighbor.ChassisID)) {

                        # Now loop through the interfaces on the correctly identified device.
                        foreach ($remoteInterface in $discoveredDevice.interfaces) {
                            # Check if this interface's name matches the one reported by the neighbor.
                            if ($remoteInterface.Interface -eq $lldpNeighbor.InterfaceRemoteDevice) {
                                $toInterface = $remoteInterface # We found the exact interface object.
                                break outer # Exit both loops since the target has been found.
                            }
                        }
                    }
                }

                # Connect the shapes if both local and remote interfaces were successfully found.
                if ($fromInterface.PhysicalDrawioId -and $toInterface.PhysicalDrawioId) {
                    #Write-Host "Connecting [LLDP-Discovered]: $($device.HostName)/$($fromInterface.Interface) -> $($lldpNeighbor.HostName)/$($toInterface.Interface)" -ForegroundColor Green
                    $style = Get-ConnectorStyle -fromInterface $fromInterface
                    Add-DrawioConnector -SourceId $fromInterface.PhysicalDrawioId -TargetId $toInterface.PhysicalDrawioId -Style $style
                }
            }
        }
    }
    # Finalizes and saves the XML for the current Draw.io diagram page.
    End-DrawioDiagram
}


function Draw-AllLayer3Drawio {
    [CmdletBinding()]
    param (
        # An array of all configured device objects.
        [parameter(Mandatory = $true)] $ArrayOfObjects,
        # An array of all discovered network segment (VLAN/subnet) objects.
        [parameter(Mandatory = $true)] $ArrayOfNetworks,
        # An optional array of ARP table entries.
        [parameter(Mandatory = $false)] $ArrayOfIPApr,
        # Defines the type of L3 diagram to create: "Normal", "RoutesOnly", or "LinksOnly".
        [parameter(Mandatory = $true)] $DiagramType,
        # The name to be displayed on the Draw.io page tab.
        [parameter(Mandatory = $true)] $NameOfPage,
        # An optional array of gateway-only devices (e.g., firewalls, routers not in the main set).
        [parameter(Mandatory = $false)] $ArrayofGatewayHosts
    )
    #Write-Host "Drawing Layer 3 Diagram: $NameOfPage" -ForegroundColor Green
    # Start a new diagram page with the specified name.
    Start-DrawioDiagram -Name $NameOfPage

    # This hashtable will store networks drawn on THIS specific page.
    # It's crucial for connecting devices to the correct network shapes.
    # The key is the network CIDR, and the value is the network object.
    $drawableNetworksOnPage = @{}

    # --- Phase 1: Draw all nodes (Hosts and Networks/VLANs with ARP bubbles) ---
    #Write-Host "`nDEBUG: Phase 1 - Drawing all physical nodes and networks..." -ForegroundColor Cyan

    # Draw regular hosts
    $currentX = 50
    # Loop through each configured device to draw its logical representation.
    foreach ($Device in ($ArrayOfObjects | Sort-Object HostName)) {
        # Calls a helper function to draw the L3 view of the host.
        $hostWidth = Add-DrawioHostLayer3 -Device $Device -Location ([PSCustomObject]@{X = $currentX; Y = 500}) -DiagramType $DiagramType
        # Increment X position for the next host.
        $currentX += 700
        $currentX += $hostWidth
    }

    # Draw gateway hosts, if provided and if the diagram type requires them.
    if (($DiagramType -eq "RoutesOnly" -or $DiagramType -eq "LinksOnly") -and $ArrayofGatewayHosts) {
        $currentX = 50
        foreach ($GatewayHost in $ArrayofGatewayHosts) {
            # Pass the DiagramType parameter here as well.
            # Draws a host specifically marked as a "GatewayHost".
            $hostWidth = Add-DrawioHostLayer3 -Device $GatewayHost -Location ([PSCustomObject]@{X = $currentX; Y = 1100}) -HostType "GatewayHost" -DiagramType $DiagramType
            $currentX += 700
            $currentX += $hostWidth
        }
    }
    # Draw networks (VLANs) and their associated ARP bubbles.
    # Check if the diagram type is "Normal" or "LinksOnly", as "RoutesOnly" does not show network segments.
    if ($DiagramType -eq "Normal" -or $DiagramType -eq "LinksOnly") {
        #Write-Host "`nDEBUG: Drawing networks and ARP entries..." -ForegroundColor Cyan
        $currentY = 50 # Starting Y for networks, adjust as needed relative to hosts.
        foreach ($network in $ArrayOfNetworks) {
            # Skip networks that have no routed connectors when in "LinksOnly" mode to reduce clutter.
            if ($DiagramType -eq "LinksOnly" -and $network.NumberOfRoutedConnectors -eq 0) { continue }

            # Draw the network segment shape (e.g., a cloud or a line).
            $netId = Add-DrawioNetworkSegment -Network $network -Location ([PSCustomObject]@{X = 100; Y = $currentY})

            # Store the network object in our page-specific map using its CIDR as key.
            # This is critical for connecting devices to networks later.
            $drawableNetworksOnPage[$network.cidr] = $network

            # Draw ARP entries bubble if enabled and data exists for this network.
            if ($GDrawAprEntries -and $network.ARPEntries) {
                $arpId = Add-DrawioArpBubble -Network $network -Location ([PSCustomObject]@{X = 400; Y = $currentY}) # Adjusted X for ARP bubble

                # Connect the network to the ARP bubble with a dashed line.
                if ($netId -and $arpId) { # Ensure both shapes were drawn.
                    Add-DrawioConnector -SourceId $netId -TargetId $arpId -Style "endArrow=none;dashed=1;strokeColor=#9E9E9E;strokeWidth=2;" -Text "ARP"
                }
            }
            # Increment Y position for the next network shape.
            $currentY += ($GDrawioVlanHeight + 50) # Increment Y for next network, adjust spacing
        }
    }

    # --- Phase 2: Draw all connectors ---
    Write-Host "Connecting L3 components for page '$NameOfPage'..." -ForegroundColor Cyan
    # Combine the main devices and gateway devices into a single list for searching.
    $allDrawableHosts = $ArrayOfObjects + $ArrayofGatewayHosts

    # Iterate through every device that was drawn on the page.
    foreach ($device in $allDrawableHosts) {
        # Iterate through each active interface with an IP address on the device.
        foreach ($interface in ($device.interfaces | Where-Object { $_.ipaddress -and (-not $_.shutdown) })) {
            # --- Connect Device Interfaces to Networks/VLANs ---
            # This connection type is only drawn for "Normal" or "LinksOnly" diagrams.
            if (($DiagramType -eq "Normal" -or $DiagramType -eq "LinksOnly")) {
                # Find the target network shape from the hashtable using the interface's CIDR.
                $targetNetwork = $drawableNetworksOnPage[$interface.cidr]

                # If the interface shape and the network shape both exist, draw a connector.
                if ($interface.LogicalDrawioId -and $targetNetwork -and $targetNetwork.LogicalDrawioId) {
                    #Write-Host "       DEBUG: Connecting device $($device.HostName) interface $($interface.name) to network $($targetNetwork.cidr)." -ForegroundColor DarkGreen
                    Add-DrawioConnector -SourceId $interface.LogicalDrawioId -TargetId $targetNetwork.LogicalDrawioId -Style "endArrow=none;html=1;strokeWidth=2;strokeColor=#4CAF50;" -Text "$($interface.name)<br>$($interface.ipaddress)"
                }
                elseif ($DiagramType -eq "Normal") {
                    #Write-Warning "Interface $($device.HostName).$($interface.name) (IP: $($interface.ipaddress)) has CIDR $($interface.cidr) but matching network was not drawn or found on this page."
                }
            }

            # --- Handle Primary Gateway Routes (with multiple standby IP fallbacks) ---
            # This logic is only for "RoutesOnly" diagrams.
            if ($DiagramType -eq "RoutesOnly" -and $interface.RoutesForInterface) {
                # Group all routes for this interface by their next-hop gateway IP address.
                $routeGroups = $interface.RoutesForInterface | Where-Object { $_.gateway } | Group-Object -Property gateway

                # Process each group of routes (all routes pointing to the same next-hop).
                foreach ($group in $routeGroups) {
                    $gatewayIp = $group.Name
                    $targetInterfaces = @()
                    $connectionType = "Primary"

                    #Write-Host "       DEBUG: Processing route from $($interface.name) to Gateway IP: $gatewayIp" -ForegroundColor Magenta

                    # 1. First, search for the Gateway IP among all PHYSICAL hosts as a PRIMARY IP.
                    foreach ($deviceToSearch in $allDrawableHosts) {
                        # Find an interface where the main IP address matches the gateway IP.
                        $foundPrimaryInterface = $deviceToSearch.interfaces | Where-Object { $_.ipaddress -eq $gatewayIp }
                        if ($foundPrimaryInterface) {
                            $targetInterfaces += ($foundPrimaryInterface | Select-Object -First 1)
                            #Write-Host "         DEBUG: Gateway IP $gatewayIp found as PRIMARY IP on device $($deviceToSearch.HostName)." -ForegroundColor Green
                            $connectionType = "Primary"
                            break # Found the primary, no need to search further.
                        }
                    }

                    # 2. If NOT found as a primary IP, then look for it as a STANDBY IP on other devices.
                    # This handles cases like HSRP/VRRP where the gateway is a virtual IP.
                    if (-not $targetInterfaces) {
                        #Write-Host "         DEBUG: Gateway IP $gatewayIp not found as primary. Checking ALL standby IPs on other devices..." -ForegroundColor Yellow
                        foreach ($deviceToSearch in $allDrawableHosts) {
                            if ($deviceToSearch.interfaces) {
                                foreach ($otherInterface in $deviceToSearch.interfaces) {
                                    if ($null -ne $otherInterface.standbyip) {
                                        # Ensure standbyip is treated as an array for the -contains operator.
                                        $standbyIpsToCheck = @($otherInterface.standbyip)
                                        if ($standbyIpsToCheck -contains $gatewayIp) {
                                            $targetInterfaces += $otherInterface
                                            #Write-Host "         DEBUG: Gateway IP $gatewayIp found as STANDBY IP on device $($deviceToSearch.HostName) on interface $($otherInterface.name)." -ForegroundColor Green
                                            $connectionType = "StandbyFallback"
                                            # We don't break here, as multiple devices could have the same standby IP.
                                        }
                                    }
                                }
                            }
                        }
                    }

                    # If no device has this gateway IP (as primary or standby), we can't draw the route.
                    if (-not $targetInterfaces) {
                        #Write-Host "         DEBUG: Gateway IP $gatewayIp not found on any physical devices (primary or standby). Skipping route connection." -ForegroundColor Red
                        continue
                    }

                    # Loop through all found target interfaces (usually one, but standby could be multiple).
                    foreach ($targetInterface in $targetInterfaces) {
                        # Check that both the source and target shapes have valid Draw.io IDs.
                        if ($interface.LogicalDrawioId -and $targetInterface.LogicalDrawioId) {
                            #Write-Host "         DEBUG: SUCCESS - Connecting from '$($interface.ipaddress)' to target '$($targetInterface.ipaddress)'. SourceID: $($interface.LogicalDrawioId), TargetID: $($targetInterface.LogicalDrawioId)" -ForegroundColor Green

                            # Initialize connector style properties.
                            $text = ""
                            $color = ""
                            $strokeWidth = "8"
                            $endArrow = "classic"
                            $endArrowSize = "8"
                            $dashed = "0"

                            # Logic for determining protocol and route details for text and color.
                            $routeCount = $group.Count
                            $protocols = ($group.Group.RouteProtocol | Sort-Object -Unique) -join ', '

                            # Determine the primary protocol to decide the connector color.
                            $primaryProtocol = ($group.Group.RouteProtocol | Select-Object -First 1)
                            if ($protocols -like "*BGP*") { $primaryProtocol = "BGP" }
                            elseif ($protocols -like "*EIGRP*") { $primaryProtocol = "EIGRP" }
                            elseif ($protocols -like "*OSPF*") { $primaryProtocol = "OSPF" }
                            elseif ($protocols -like "*static*") { $primaryProtocol = "static" }

                            # Set the connector color based on the routing protocol.
                            switch -wildcard ($primaryProtocol) {
                                "static" { $color = "rgb(0,107,60)" } # Green
                                "RIP" { $color = "rgb(179,89,0)" } # Dark orange
                                "BGP" { $color = "rgb(0,0,179)" } # blue
                                "BGP-*" { $color = "rgb(0,0,179)" } # blue
                                "B" { $color = "rgb(0,0,179)" } # blue
                                "EIGRP" { $color = "rgb(160,32,240)" } # purple
                                "OSPF" { $color = "rgb(255,255,51)" } # Yellow
                                "OSPF-*" { $color = "rgb(255,255,51)" } # Yellow
                                "IS-IS" { $color = "rgb(204,238,255)" } # Light blue
                                "Default gateway" { $color = "rgb(0,107,60)" } # Green
                                default { $color = "#000000" } # black
                            }

                            # Text generation: If there are too many routes, summarize them. Otherwise, list them.
                            if (($group.Group | select subnet).count -gt 30) {
                                if ($group.Group | where { $_.subnet -like "*0.0.0.0/0*" }) {
                                    $text = "$($protocols)<br>$($gatewayIp)<br>Route Count:$routeCount<br>Routes For: 0.0.0.0/0"
                                }
                                else {
                                    $text = "$($protocols)<br>$($gatewayIp)<br>Route Count:$routeCount"
                                }
                            }
                            else {
                                $text = "$($protocols)<br>$($gatewayIp)<br>"
                                $text += ($group.Group | select -ExpandProperty subnet | sort) -join '<br>'
                            }

                            # Line pattern for default routes vs other routes.
                            if ($text -like "*0.0.0.0/0*") {
                                $dashed = "0" # Solid line for default route.
                            }
                            else {
                                $dashed = "1" # Dashed line for specific routes.
                            }

                            # Apply standby specific style adjustments if it's a fallback connection.
                            if ($connectionType -eq "StandbyFallback") {
                                $text = "Standby: " + $text # Prepend "Standby: " to the existing route text.
                                $color = "#FF8C00" # Dark Orange for standby line color.
                                $strokeWidth = "2" # Thinner line for standby.
                                $dashed = "1" # Always dashed for standby.
                            }

                            # Construct the final style string for the Draw.io connector.
                            $style = "endArrow=$endArrow;html=1;strokeWidth=$strokeWidth;strokeColor=$color;endSize=$endArrowSize;"
                            if ($dashed -eq "1") {
                                $style += "dashed=1;"
                            }

                            # Add the connector to the diagram with the calculated style and text.
                            Add-DrawioConnector -SourceId $interface.LogicalDrawioId -TargetId $targetInterface.LogicalDrawioId -Style $style -Text $text

                        }
                        else {
                            #Write-Host "         DEBUG: FAILED - Missing Shape ID. Source: $($interface.LogicalDrawioId), Target: $($targetInterface.LogicalDrawioId)" -ForegroundColor Red
                        }
                    } # End foreach targetInterface
                } # End foreach group
            }
        } # End foreach interface
    } # End foreach device
    # Finalize and save the diagram page.
    End-DrawioDiagram
}




function Draw-SinglesLayer3Drawio {
    [CmdletBinding()]
    param (
        # The single device object for which to create a diagram.
        [parameter(Mandatory = $true)]
        $Device,
        # The complete list of all network segments in the environment.
        [parameter(Mandatory = $true)]
        $ArrayOfNetworks
    )

    #Write-Host "Drawing single L3 diagram for: $($Device.hostname)" -ForegroundColor Green

    # 1. Filter for networks relevant to only this device.
    $DeviceArrayOfNetworks = @()
    # Iterate through the networks associated with the specific device.
    foreach ($network1 in $device.ArrayOfNetworks) {
        # Find the full network object from the global list.
        $foundNetwork = $ArrayOfNetworks | Where-Object { $_.cidr -eq $network1.cidr } | Select-Object -First 1
        if ($foundNetwork) {
            # Add the found network to a new array specific to this device's diagram.
            $DeviceArrayOfNetworks += $foundNetwork
        }
    }
    # Sort the filtered networks for a clean layout.
    $DeviceArrayOfNetworks = $DeviceArrayOfNetworks | Sort-Object NumberOfConnectors, RoutedVlan, cidr

    # If the device isn't connected to any L3 networks, there's nothing to draw.
    if ($DeviceArrayOfNetworks.Count -eq 0) {
        Write-Warning "No connected L3 networks found for $($Device.hostname). Skipping this page."
        return
    }

    # 2. Start a new page for this device.
    Start-DrawioDiagram -Name "$($Device.hostname) L3"

    # 3. Draw all network segments and their ARP bubbles.
    $currentY = 100
    # Loop through only the networks relevant to this device.
    foreach ($network in $DeviceArrayOfNetworks) {
        # Draw the network segment shape.
        $netId = Add-DrawioNetworkSegment -Network $network -Location ([PSCustomObject]@{X = 100; Y = $currentY})

        # If ARP drawing is enabled and entries exist, draw the ARP bubble.
        if ($GDrawAprEntries -and $network.ARPEntries) {
            $arpId = Add-DrawioArpBubble -Network $network -Location ([PSCustomObject]@{X = $GDrawioVlanWidth + 150; Y = $currentY})
            # Connect the network to its ARP bubble.
            Add-DrawioConnector -SourceId $netId -TargetId $arpId -Style "endArrow=none;dashed=1;strokeColor=#9E9E9E;strokeWidth=4;"
        }
        # Increment the Y coordinate for the next network.
        $currentY += 80
    }

    # 4. Draw the main host, positioned below the networks.
    # Calculate a Y position that places the host below the drawn network shapes.
    $hostYPos = $currentY + 100
    # Draw the logical representation of the single host.
    $hostWidth = Add-DrawioHostLayer3 -Device $Device -Location ([PSCustomObject]@{X = 400; Y = $hostYPos}) -DiagramType "Normal"

    # 5. Draw connectors from host interfaces to network segments.
    # Loop through the device's active, IP-enabled interfaces.
    foreach ($interface in ($Device.interfaces | where { $_.ipaddress -and (-not $_.shutdown) })) {
        # Find the matching network object that was drawn on the page.
        $targetNetwork = $DeviceArrayOfNetworks | Where-Object { $_.cidr -eq $interface.cidr } | Select-Object -First 1

        # Ensure both the interface shape and the network shape exist.
        if ($interface.LogicalDrawioId -and $targetNetwork.LogicalDrawioId) {
            # Check if this interface has any non-local, non-connected routes to add a label.
            $routesForInterface = $Device.RoutingTable | where { $_.interface -eq $interface.Interface -and $_.routeprotocol -notmatch "local|connected" } | sort gateway, subnet
            $connectorText = ""
            if ($routesForInterface) {
                # Add a simple text label indicating routes exist via this link.
                $connectorText = "Routes via this link"
            }
            # Set the connector style, using the network's pre-defined color.
            $connectorStyle = "endArrow=none;strokeWidth=4;strokeColor=$(Convert-RgbToHex -RgbString $targetNetwork.color);"

            # --- THIS IS THE FIX ---
            # Changed -From and -To to the correct -SourceId and -TargetId
            # Draw the final connector from the host interface to the network segment.
            Add-DrawioConnector -SourceId $interface.LogicalDrawioId -TargetId $targetNetwork.LogicalDrawioId -Style $connectorStyle -Text $connectorText
        }
    }

    # Finalize and save the diagram.
    End-DrawioDiagram
}




# This function creates a physical diagram for a single host, leveraging pre-processed neighbor references.
function Draw-SingleHostPhysicalDrawio {
    [CmdletBinding()]
    param (
        # The primary device object to be the center of the diagram.
        [parameter(Mandatory = $true)]
        $Device,
        # The full array of all configured device objects.
        [parameter(Mandatory = $true)]
        $ArrayOfObjects,
        # An array of PSObjects for devices discovered only via CDP.
        [parameter(Mandatory = $true)]
        $ArrayOfCDPDeviceIDs,
        # An array of PSObjects for devices discovered only via LLDP.
        [parameter(Mandatory = $true)]
        $ArrayOfLLDPDeviceIDs
    )

    # 1. Initialize the diagram page and layout variables.
    Start-DrawioDiagram -Name "$($Device.hostname) Physical"
    Add-DrawioInterfaceLegend -Location ([PSCustomObject]@{X = 100; Y = 1300})
    $drawnNeighbors = @{}
    
    # 2. Draw the primary host in a central location.
    Add-DrawioHostPhysical -Device $Device -Location ([PSCustomObject]@{X = 800; Y = 100})

    # 3. Initialize layout for neighbor devices.
    $currentX = 100
    $currentY = 700
    $horizontalPadding = 200 # The fixed space between neighbor shapes.

    # 4. Process all CDP Neighbors.
    if ($Device.CDPNeighbors) {
        foreach ($cdpNeighbor in $Device.CDPNeighbors) {
            $partnerHost = $null
            $partnerInterface = $null
            
            # Check the pre-populated reference to determine neighbor type.
            if ($cdpNeighbor.PartnerEthernetInterface -and $cdpNeighbor.PartnerEthernetInterface.Value) {
                # --- This is a CONFIGURED Neighbor ---
                $partnerInterface = $cdpNeighbor.PartnerEthernetInterface.Value
                # Find the parent Host Object for this interface.
                $partnerHost = $ArrayOfObjects | Where-Object { $_.interfaces -contains $partnerInterface } | Select-Object -First 1
                
                if (-not $partnerHost) { continue } # Should not happen if pre-processing is correct.

                if (-not $drawnNeighbors.ContainsKey($partnerHost.HostName)) {
                    $neighborWidth = Add-DrawioHostPhysical -Device $partnerHost -Location ([PSCustomObject]@{X = $currentX; Y = $currentY})
                    $drawnNeighbors[$partnerHost.HostName] = $partnerHost
                    $currentX += $neighborWidth + $horizontalPadding
                }
            } else {
                # --- This is a DISCOVERED-ONLY Neighbor ---
                $partnerHost = $ArrayOfCDPDeviceIDs | Where-Object { $_.HostName -eq $cdpNeighbor.DeviceID } | Select-Object -First 1
                
                if (-not $partnerHost) { continue } # Discovered device object was not created.

                if (-not $drawnNeighbors.ContainsKey($partnerHost.HostName)) {
                    Add-DrawioNeighborHost -Device $partnerHost -Location ([PSCustomObject]@{X = $currentX; Y = $currentY}) -DrawType "CDPNeighbor"
                    $drawnNeighbors[$partnerHost.HostName] = $partnerHost
                    $currentX += 800 + $horizontalPadding # Use an estimated width for discovered hosts
                }
                # Find the specific interface object on the discovered host.
                $partnerInterface = $partnerHost.interfaces | Where-Object { $_.interface -eq $cdpNeighbor.InterfaceRemoteDevice } | Select-Object -First 1
            }

            # --- Draw the Connector ---
            $fromInterface = $Device.interfaces | Where-Object { $_.Interface -eq $cdpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
            if ($fromInterface -and $fromInterface.PhysicalDrawioId -and $partnerInterface -and $partnerInterface.PhysicalDrawioId) {
                $style = Get-ConnectorStyle -fromInterface $fromInterface
                Add-DrawioConnector -SourceId $fromInterface.PhysicalDrawioId -TargetId $partnerInterface.PhysicalDrawioId -Style $style
            }
        }
    }

    # 5. Process all LLDP Neighbors (using the same logic as CDP).
    if ($Device.LLDPNeighbors) {
        foreach ($lldpNeighbor in ($Device.LLDPNeighbors | Where-Object { -not $_.HasCDPNeighborEntry })) {
            $partnerHost = $null
            $partnerInterface = $null
            
            if ($lldpNeighbor.PartnerEthernetInterface -and $lldpNeighbor.PartnerEthernetInterface.Value) {
                # --- CONFIGURED Neighbor ---
                $partnerInterface = $lldpNeighbor.PartnerEthernetInterface.Value
                $partnerHost = $ArrayOfObjects | Where-Object { $_.interfaces -contains $partnerInterface } | Select-Object -First 1
                
                if (-not $partnerHost) { continue }

                if (-not $drawnNeighbors.ContainsKey($partnerHost.HostName)) {
                    $neighborWidth = Add-DrawioHostPhysical -Device $partnerHost -Location ([PSCustomObject]@{X = $currentX; Y = $currentY})
                    $drawnNeighbors[$partnerHost.HostName] = $partnerHost
                    $currentX += $neighborWidth + $horizontalPadding
                }
            } else {
                # --- DISCOVERED-ONLY Neighbor ---
                $neighborId = $lldpNeighbor.HostName
                $chassisId = $lldpNeighbor.ChassisID
                $partnerHost = $ArrayOfLLDPDeviceIDs | Where-Object { $_.HostName -eq $neighborId -or $_.HostName -eq $chassisId } | Select-Object -First 1

                if (-not $partnerHost) { continue }

                if (-not $drawnNeighbors.ContainsKey($partnerHost.HostName)) {
                    Add-DrawioNeighborHost -Device $partnerHost -Location ([PSCustomObject]@{X = $currentX; Y = $currentY}) -DrawType "LLDPNeighbor"
                    $drawnNeighbors[$partnerHost.HostName] = $partnerHost
                    $currentX += 800 + $horizontalPadding
                }
                $partnerInterface = $partnerHost.interfaces | Where-Object { $_.interface -eq $lldpNeighbor.InterfaceRemoteDevice } | Select-Object -First 1
            }

            # --- Draw the Connector ---
            $fromInterface = $Device.interfaces | Where-Object { $_.Interface -eq $lldpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
            if ($fromInterface -and $fromInterface.PhysicalDrawioId -and $partnerInterface -and $partnerInterface.PhysicalDrawioId) {
                $style = Get-ConnectorStyle -fromInterface $fromInterface
                Add-DrawioConnector -SourceId $fromInterface.PhysicalDrawioId -TargetId $partnerInterface.PhysicalDrawioId -Style $style
            }
        }
    }

    # 6. Finalize the diagram page.
    End-DrawioDiagram
}




