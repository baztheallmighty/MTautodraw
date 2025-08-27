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
        $ArrayOfLLDPDeviceIDs,
        # Draw all nieghbors or not
        [parameter(Mandatory = $true)]
        $DrawAllNeighbors
    )




    # 1. Start the Diagram and Draw the Legend
    # Initializes a new Draw.io diagram page with a specific name for the physical layout.
    if($DrawAllNeighbors){
        Start-DrawioDiagram -Name "CDP-LLDP All"
    }else{
        Start-DrawioDiagram -Name "CDP-LLDP brief"
    }
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
        $hostWidth = Add-DrawioHostPhysical -Device $device -Location ([PSCustomObject]@{X = $currentX; Y = 100}) -DrawAllNeighbors $DrawAllNeighbors
        #store where we put the object.
        $device.CPDHostLocation = ([PSCustomObject]@{X = $currentX; Y = 100})
        # Update the X coordinate for the next host, adding a fixed padding plus the width of the host just drawn.
        $currentX += 950 + $hostWidth

    }



    if($DrawAllNeighbors){ #do we draw all the CDP nieghbors we have if false just the ones with config. 
        # Iterate through each device discovered via CDP.
        $currentNeighbor=$null
        foreach ($cdpDevice in ($ArrayOfCDPDeviceIDs | Sort-Object ParentObject)) {
            if ($currentNeighbor -ne $cdpDevice.ParentObject){
                # Reset coordinates to draw the discovered CDP neighbor devices in a new row.
                $currentNeighbor=$cdpDevice.ParentObject
                $currentY = 400
            }
            # Calls a helper function to draw a simplified representation of a discovered neighbor.
            $xlocation =
            Add-DrawioNeighborHost -Device $cdpDevice -Location ([PSCustomObject]@{X = ($GArrayOfObjects | where { $_.hostname -eq $cdpDevice.ParentObject}).CPDHostLocation.x; Y = $currentY}) -DrawType "CDPNeighbor"
            # Increment the X coordinate for the next discovered device.
            $currenty += 300
        }

        $currentNeighbor=$null
        # Iterate through each device discovered via LLDP.
        foreach ($lldpDevice in ($ArrayOfLLDPDeviceIDs | Sort-Object ParentObject)) {
            if ($currentNeighbor -ne $lldpDevice.ParentObject){
                # Reset coordinates to draw the discovered CDP neighbor devices in a new row.
                $currentNeighbor=$lldpDevice.ParentObject
                $currentY = 400
            }
            # Draw the discovered LLDP neighbor.
            Add-DrawioNeighborHost -Device $lldpDevice -Location ([PSCustomObject]@{X = (($GArrayOfObjects | where { $_.hostname -eq $lldpDevice.ParentObject}).CPDHostLocation.x + 1000); Y = $currentY}) -DrawType "LLDPNeighbor"
            # Increment the X coordinate.
            $currentY += 300
        }
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
						# --- MODIFICATION START ---
						# Clean the hostname from LLDP data to handle FQDN vs. short name mismatches.
						$cleanedNeighborHostName = if (-not [string]::IsNullOrEmpty($lldpNeighbor.HostName)) {
							($lldpNeighbor.HostName -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim()
						}
						# Also clean the chassis ID, as it can sometimes be a hostname.
						$cleanedChassisId = if (-not [string]::IsNullOrEmpty($lldpNeighbor.ChassisID)) {
							($lldpNeighbor.ChassisID -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim()
						}
						# Check against cleaned/original hostname AND cleaned/original chassis ID.
						if (($discoveredDevice.hostname -eq $cleanedNeighborHostName) -or ($discoveredDevice.hostname -eq $lldpNeighbor.HostName) -or ($discoveredDevice.hostname -eq $cleanedChassisId) -or ($discoveredDevice.hostname -eq $lldpNeighbor.ChassisID)) {
						# --- MODIFICATION END ---

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

				if (-not $toInterface) {
					Write-Host "WARNING [AllNeighbors]: Could not find a matching discovered LLDP device for neighbor '$($lldpNeighbor.HostName)' on interface '$($lldpNeighbor.InterfaceRemoteDevice)'. Skipping connector." -ForegroundColor DarkYellow
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



#function Draw-SinglesLayer3Drawio {
#    [CmdletBinding()]
#    param (
#        # The single device object for which to create a diagram.
#        [parameter(Mandatory = $true)]
#        $Device,
#        # The complete list of all network segments in the environment.
#        [parameter(Mandatory = $true)]
#        $ArrayOfNetworks
#    )
#
#    #Write-Host "Drawing single L3 diagram for: $($Device.hostname)" -ForegroundColor Green
#
#    # 1. Filter for networks relevant to only this device.
#    $DeviceArrayOfNetworks = @()
#    # Iterate through the networks associated with the specific device.
#    foreach ($network1 in $device.ArrayOfNetworks) {
#        # Find the full network object from the global list.
#        $foundNetwork = $ArrayOfNetworks | Where-Object { $_.cidr -eq $network1.cidr } | Select-Object -First 1
#        if ($foundNetwork) {
#            # Add the found network to a new array specific to this device's diagram.
#            $DeviceArrayOfNetworks += $foundNetwork
#        }
#    }
#    # Sort the filtered networks for a clean layout.
#    $DeviceArrayOfNetworks = $DeviceArrayOfNetworks | Sort-Object NumberOfConnectors, RoutedVlan, cidr
#
#    # If the device isn't connected to any L3 networks, there's nothing to draw.
#    if ($DeviceArrayOfNetworks.Count -eq 0) {
#        Write-Warning "No connected L3 networks found for $($Device.hostname). Skipping this page."
#        return
#    }
#
#    # 2. Start a new page for this device.
#    Start-DrawioDiagram -Name "$($Device.hostname) L3"
#
#    # 3. Draw all network segments and their ARP bubbles.
#    $currentY = 100
#    # Loop through only the networks relevant to this device.
#    foreach ($network in $DeviceArrayOfNetworks) {
#        # Draw the network segment shape.
#        $netId = Add-DrawioNetworkSegment -Network $network -Location ([PSCustomObject]@{X = 100; Y = $currentY})
#
#        # If ARP drawing is enabled and entries exist, draw the ARP bubble.
#        if ($GDrawAprEntries -and $network.ARPEntries) {
#            $arpId = Add-DrawioArpBubble -Network $network -Location ([PSCustomObject]@{X = $GDrawioVlanWidth + 150; Y = $currentY})
#            # Connect the network to its ARP bubble.
#            Add-DrawioConnector -SourceId $netId -TargetId $arpId -Style "endArrow=none;dashed=1;strokeColor=#9E9E9E;strokeWidth=4;"
#        }
#        # Increment the Y coordinate for the next network.
#        $currentY += 80
#    }
#
#    # 4. Draw the main host, positioned below the networks.
#    # Calculate a Y position that places the host below the drawn network shapes.
#    $hostYPos = $currentY + 100
#    # Draw the logical representation of the single host.
#    $hostWidth = Add-DrawioHostLayer3 -Device $Device -Location ([PSCustomObject]@{X = 400; Y = $hostYPos}) -DiagramType "Normal"
#
#    # 5. Draw connectors from host interfaces to network segments.
#    # Loop through the device's active, IP-enabled interfaces.
#    foreach ($interface in ($Device.interfaces | where { $_.ipaddress -and (-not $_.shutdown) })) {
#        # Find the matching network object that was drawn on the page.
#        $targetNetwork = $DeviceArrayOfNetworks | Where-Object { $_.cidr -eq $interface.cidr } | Select-Object -First 1
#
#        # Ensure both the interface shape and the network shape exist.
#        if ($interface.LogicalDrawioId -and $targetNetwork.LogicalDrawioId) {
#            # Check if this interface has any non-local, non-connected routes to add a label.
#            $routesForInterface = $Device.RoutingTable | where { $_.interface -eq $interface.Interface -and $_.routeprotocol -notmatch "local|connected" } | sort gateway, subnet
#            $connectorText = ""
#            if ($routesForInterface) {
#                # Add a simple text label indicating routes exist via this link.
#                $connectorText = "Routes via this link"
#            }
#            # Set the connector style, using the network's pre-defined color.
#            $connectorStyle = "endArrow=none;strokeWidth=4;strokeColor=$(Convert-RgbToHex -RgbString $targetNetwork.color);"
#
#            # --- THIS IS THE FIX ---
#            # Changed -From and -To to the correct -SourceId and -TargetId
#            # Draw the final connector from the host interface to the network segment.
#            Add-DrawioConnector -SourceId $interface.LogicalDrawioId -TargetId $targetNetwork.LogicalDrawioId -Style $connectorStyle -Text $connectorText
#        }
#    }
#
#    # Finalize and save the diagram.
#    End-DrawioDiagram
#}

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
    $drawnConnections = @{}

    # 2. Draw the primary host in a central location.
    Add-DrawioHostPhysical -Device $Device -Location ([PSCustomObject]@{X = 800; Y = 100}) -DrawAllNeighbors $true

    # 3. Initialize layout for neighbor devices.
    $currentX = 100
    $currentY = 700
    $horizontalPadding = 200 # The fixed space between neighbor shapes.

    # 4. Identify and draw all direct neighbor shapes
    # =================================================================
    #Write-Host "--- Identifying and drawing all direct neighbors of $($Device.HostName) ---" -ForegroundColor Magenta
    # This list will contain the primary device + all neighbors that are drawn on the canvas.
    $devicesToConnect = [System.Collections.Generic.List[object]]::new()
    $devicesToConnect.Add($Device)

    # --- Find and draw CDP neighbors ---
    if ($Device.CDPNeighbors) {
        foreach ($cdpNeighbor in $Device.CDPNeighbors) {
            $partnerHost = $null
            # Check if it's a pre-linked, configured neighbor
            if ($cdpNeighbor.PartnerEthernetInterface -and $cdpNeighbor.PartnerEthernetInterface.Value) {
                $partnerInterface = $cdpNeighbor.PartnerEthernetInterface.Value
                $partnerHost = $ArrayOfObjects | Where-Object { $_.interfaces -contains $partnerInterface } | Select-Object -First 1
            }
            # Otherwise, check if it's a discovered-only neighbor
            else {
                $cleanedNeighborID = ($cdpNeighbor.DeviceID -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim()
                $partnerHost = $ArrayOfCDPDeviceIDs | Where-Object { ($_.HostName -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim() -eq $cleanedNeighborID } | Select-Object -First 1
            }

            if ($partnerHost -and (-not $drawnNeighbors.ContainsKey($partnerHost.HostName))) {
                #Write-Host "  -> Drawing CDP neighbor shape: $($partnerHost.HostName)" -ForegroundColor Cyan
                # Draw the full host if configured, otherwise draw a simple neighbor box
                if ($partnerHost.DeviceIdentifier) { # A property unique to configured devices
                    $neighborWidth = Add-DrawioHostPhysical -Device $partnerHost -Location ([PSCustomObject]@{X = $currentX; Y = $currentY}) -DrawAllNeighbors $true
                    $currentX += $neighborWidth + $horizontalPadding
                } else {
                    Add-DrawioNeighborHost -Device $partnerHost -Location ([PSCustomObject]@{X = $currentX; Y = $currentY}) -DrawType "CDPNeighbor"
                    $currentX += 800 + $horizontalPadding
                }
                $drawnNeighbors[$partnerHost.HostName] = $partnerHost
                $devicesToConnect.Add($partnerHost)
            }
        }
    }

    # --- Find and draw LLDP neighbors ---
    if ($Device.LLDPNeighbors) {
        foreach ($lldpNeighbor in ($Device.LLDPNeighbors | Where-Object { -not $_.HasCDPNeighborEntry })) {
            $partnerHost = $null
            # Check if it's a pre-linked, configured neighbor
            if ($lldpNeighbor.PartnerEthernetInterface -and $lldpNeighbor.PartnerEthernetInterface.Value) {
                $partnerInterface = $lldpNeighbor.PartnerEthernetInterface.Value
                $partnerHost = $ArrayOfObjects | Where-Object { $_.interfaces -contains $partnerInterface } | Select-Object -First 1
            }
            # Otherwise, check if it's a discovered-only neighbor
            else {
                 :outer foreach ($discoveredDevice in $ArrayOfLLDPDeviceIDs) {
                    $cleanedNeighborHostName = if (-not [string]::IsNullOrEmpty($lldpNeighbor.HostName)) { ($lldpNeighbor.HostName -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim() }
                    $cleanedChassisId = if (-not [string]::IsNullOrEmpty($lldpNeighbor.ChassisID)) { ($lldpNeighbor.ChassisID -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim() }
                    $cleanedDiscoveredHostname = ($discoveredDevice.hostname -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim()
                    if (($cleanedDiscoveredHostname -eq $cleanedNeighborHostName) -or ($cleanedDiscoveredHostname -eq $cleanedChassisId)) {
                        $partnerHost = $discoveredDevice
                        break outer
                    }
                }
            }

            if ($partnerHost -and (-not $drawnNeighbors.ContainsKey($partnerHost.HostName))) {
                #Write-Host "  -> Drawing LLDP neighbor shape: $($partnerHost.HostName)" -ForegroundColor Cyan
                if ($partnerHost.DeviceIdentifier) {
                    $neighborWidth = Add-DrawioHostPhysical -Device $partnerHost -Location ([PSCustomObject]@{X = $currentX; Y = $currentY}) -DrawAllNeighbors $true
                    $currentX += $neighborWidth + $horizontalPadding
                } else {
                    Add-DrawioNeighborHost -Device $partnerHost -Location ([PSCustomObject]@{X = $currentX; Y = $currentY}) -DrawType "LLDPNeighbor"
                    $currentX += 800 + $horizontalPadding
                }
                $drawnNeighbors[$partnerHost.HostName] = $partnerHost
                $devicesToConnect.Add($partnerHost)
            }
        }
    }

    # 5. Draw connectors ONLY for devices present in the diagram
    # =================================================================
    #Write-Host "--- Drawing connectors for on-diagram devices ---" -ForegroundColor Magenta
    # Loop through each of the devices we just drew.
    foreach ($device in $devicesToConnect) {
        # --- CDP Connections ---
        if ($device.CDPNeighbors) {
            # Handles connections to fully configured partners
            foreach ($cdpNeighbor in ($device.CDPNeighbors | Where-Object { $_.PartnerEthernetInterface -and $_.PartnerEthernetInterface.Value })) {
                $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $cdpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
                $toInterface = $cdpNeighbor.PartnerEthernetInterface.Value
                # ADDED: Find the partner host to verify it's on the diagram
                $toHost = $ArrayOfObjects | Where-Object { $_.interfaces -contains $toInterface } | Select-Object -First 1
                # ADDED: Skip if the target device was not drawn in Step 4
                if (-not $devicesToConnect.Contains($toHost)) { continue }

                if ($fromInterface.PhysicalDrawioId -and $toInterface.PhysicalDrawioId) {
                    $key1 = "$($fromInterface.PhysicalDrawioId)--$($toInterface.PhysicalDrawioId)"; $key2 = "$($toInterface.PhysicalDrawioId)--$($fromInterface.PhysicalDrawioId)"
                    if (-not ($drawnConnections.ContainsKey($key1) -or $drawnConnections.ContainsKey($key2))) {
                        $style = Get-ConnectorStyle -fromInterface $fromInterface
                        Add-DrawioConnector -SourceId $fromInterface.PhysicalDrawioId -TargetId $toInterface.PhysicalDrawioId -Style $style
                        $drawnConnections[$key1] = $true
                    }
                }
            }
            # Handles connections to discovered-only partners
            foreach ($cdpNeighbor in ($device.CDPNeighbors | Where-Object { -not $_.PartnerEthernetInterface })) {
                $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $cdpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
                $cleanedNeighborID = ($cdpNeighbor.DeviceID -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim()
                $toDevice = $ArrayOfCDPDeviceIDs | Where-Object { ($_.HostName -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim() -eq $cleanedNeighborID } | Select-Object -First 1
                
                # ADDED: Skip if the target device was not drawn in Step 4
                if (-not $devicesToConnect.Contains($toDevice)) { continue }

                if ($toDevice) {
                    $toInterface = $toDevice.interfaces | Where-Object { $_.Interface -eq $cdpNeighbor.InterfaceRemoteDevice } | Select-Object -First 1
                    if ($fromInterface.PhysicalDrawioId -and $toInterface.PhysicalDrawioId) {
                         $key1 = "$($fromInterface.PhysicalDrawioId)--$($toInterface.PhysicalDrawioId)"; $key2 = "$($toInterface.PhysicalDrawioId)--$($fromInterface.PhysicalDrawioId)"
                        if (-not ($drawnConnections.ContainsKey($key1) -or $drawnConnections.ContainsKey($key2))) {
                            $style = Get-ConnectorStyle -fromInterface $fromInterface
                            Add-DrawioConnector -SourceId $fromInterface.PhysicalDrawioId -TargetId $toInterface.PhysicalDrawioId -Style $style
                            $drawnConnections[$key1] = $true
                        }
                    }
                }
            }
        }

        # --- LLDP Connections ---
        if ($device.LLDPNeighbors) {
            # Handles connections to fully configured partners
            foreach ($lldpNeighbor in ($device.LLDPNeighbors | Where-Object { $_.PartnerEthernetInterface -and $_.PartnerEthernetInterface.Value })) {
                $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $lldpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
                $toInterface = $lldpNeighbor.PartnerEthernetInterface.Value
                # ADDED: Find the partner host to verify it's on the diagram
                $toHost = $ArrayOfObjects | Where-Object { $_.interfaces -contains $toInterface } | Select-Object -First 1
                # ADDED: Skip if the target device was not drawn in Step 4
                if (-not $devicesToConnect.Contains($toHost)) { continue }

                if ($fromInterface.PhysicalDrawioId -and $toInterface.PhysicalDrawioId) {
                    $key1 = "$($fromInterface.PhysicalDrawioId)--$($toInterface.PhysicalDrawioId)"; $key2 = "$($toInterface.PhysicalDrawioId)--$($fromInterface.PhysicalDrawioId)"
                    if (-not ($drawnConnections.ContainsKey($key1) -or $drawnConnections.ContainsKey($key2))) {
                        $style = Get-ConnectorStyle -fromInterface $fromInterface
                        Add-DrawioConnector -SourceId $fromInterface.PhysicalDrawioId -TargetId $toInterface.PhysicalDrawioId -Style $style
                        $drawnConnections[$key1] = $true
                    }
                }
            }
            # Handles connections to discovered-only partners
            foreach ($lldpNeighbor in ($device.LLDPNeighbors | Where-Object { (-not $_.PartnerEthernetInterface) -and (-not $_.HasCDPNeighborEntry) })) {
                $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $lldpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
                $toInterface = $null
                $toDevice = $null
                :outer foreach ($discoveredDevice in $ArrayOfLLDPDeviceIDs) {
                    $cleanedNeighborHostName = if (-not [string]::IsNullOrEmpty($lldpNeighbor.HostName)) { ($lldpNeighbor.HostName -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim() }
                    $cleanedChassisId = if (-not [string]::IsNullOrEmpty($lldpNeighbor.ChassisID)) { ($lldpNeighbor.ChassisID -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim() }
                    $cleanedDiscoveredHostname = ($discoveredDevice.hostname -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim()
                    if (($cleanedDiscoveredHostname -eq $cleanedNeighborHostName) -or ($cleanedDiscoveredHostname -eq $cleanedChassisId)) {
                        $toDevice = $discoveredDevice # Capture the device object
                        foreach ($remoteInterface in $discoveredDevice.interfaces) {
                            if ($remoteInterface.Interface -eq $lldpNeighbor.InterfaceRemoteDevice) {
                                $toInterface = $remoteInterface
                                break outer
                            }
                        }
                    }
                }
                
                # ADDED: Skip if the target device was not drawn in Step 4
                if (-not $devicesToConnect.Contains($toDevice)) { continue }

                if ($fromInterface.PhysicalDrawioId -and $toInterface.PhysicalDrawioId) {
                    $key1 = "$($fromInterface.PhysicalDrawioId)--$($toInterface.PhysicalDrawioId)"; $key2 = "$($toInterface.PhysicalDrawioId)--$($fromInterface.PhysicalDrawioId)"
                    if (-not ($drawnConnections.ContainsKey($key1) -or $drawnConnections.ContainsKey($key2))) {
                        $style = Get-ConnectorStyle -fromInterface $fromInterface
                        Add-DrawioConnector -SourceId $fromInterface.PhysicalDrawioId -TargetId $toInterface.PhysicalDrawioId -Style $style
                        $drawnConnections[$key1] = $true
                    }
                }
            }
        }
    }
    
    # 6. Finalize the diagram page.
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

    $funcStartTime = Get-Date
    Write-Host "Starting function Draw-AllLayer3Drawio for page '$($NameOfPage)'..." -ForegroundColor Yellow

    Start-DrawioDiagram -Name $NameOfPage
    $drawableNetworksOnPage = @{}
    $allDrawableHosts = $ArrayOfObjects + $ArrayofGatewayHosts

    # --- Phase 1: Draw all nodes to assign their Drawio IDs ---
    Write-Host "[BENCHMARK] Starting Phase 1: Node Drawing..." -ForegroundColor Cyan
    $phase1StartTime = Get-Date

    $currentX = 50
    foreach ($Device in ($allDrawableHosts | Where-Object { $_ -in $ArrayOfObjects } | Sort-Object HostName)) {
        $hostWidth = Add-DrawioHostLayer3 -Device $Device -Location ([PSCustomObject]@{X = $currentX; Y = 500}) -DiagramType $DiagramType
        $currentX += 700 + $hostWidth
    }

    if (($DiagramType -eq "RoutesOnly" -or $DiagramType -eq "LinksOnly") -and $ArrayofGatewayHosts) {
        $currentX = 50
        foreach ($GatewayHost in $ArrayofGatewayHosts) {
            $hostWidth = Add-DrawioHostLayer3 -Device $GatewayHost -Location ([PSCustomObject]@{X = $currentX; Y = 1100}) -HostType "GatewayHost" -DiagramType $DiagramType
            $currentX += 700 + $hostWidth
        }
    }
    
    if ($DiagramType -eq "Normal" -or $DiagramType -eq "LinksOnly") {
        $currentY = 50
        foreach ($network in $ArrayOfNetworks) {
            if ($DiagramType -eq "LinksOnly" -and $network.NumberOfRoutedConnectors -eq 0) { continue }
            $netId = Add-DrawioNetworkSegment -Network $network -Location ([PSCustomObject]@{X = 100; Y = $currentY})
            $drawableNetworksOnPage[$network.cidr] = $network
            if ($GDrawAprEntries -and $network.ARPEntries) {
                $arpId = Add-DrawioArpBubble -Network $network -Location ([PSCustomObject]@{X = 400; Y = $currentY})
                if ($netId -and $arpId) {
                    Add-DrawioConnector -SourceId $netId -TargetId $arpId -Style "endArrow=none;dashed=1;strokeColor=#9E9E9E;strokeWidth=2;" -Text "ARP"
                }
            }
            $currentY += ($GDrawioVlanHeight + 50)
        }
    }
    $phase1Duration = (Get-Date) - $phase1StartTime
    Write-Host "[BENCHMARK] Phase 1 (Node Drawing) finished in $($phase1Duration.TotalSeconds) seconds." -ForegroundColor Cyan

    # --- Phase 2: Build Lookup Tables and Draw Connectors ---
    Write-Host "[BENCHMARK] Starting Phase 2: Connector Drawing..." -ForegroundColor Cyan
    $phase2StartTime = Get-Date
    
    # ===================================================================
    # OPTIMIZATION: Create lookup tables for Primary and Standby IPs.
    # The Standby map will store an array of interfaces to handle HSRP/VRRP.
    # ===================================================================
    $ipLookupStartTime = Get-Date
    Write-Host "[OPTIMIZATION] Building Primary and Standby IP lookup tables..." -ForegroundColor Green
    $primaryIpMap = @{}
    $standbyIpMap = @{}

    foreach ($deviceObject in $allDrawableHosts) {
        if ($deviceObject.interfaces) {
            foreach ($iface in $deviceObject.interfaces) {
                if ($iface.LogicalDrawioId) { # Only map interfaces that were actually drawn
                    # Populate the Primary IP map (one IP, one interface)
                    if ($iface.ipaddress -and -not $primaryIpMap.ContainsKey($iface.ipaddress)) {
                        $primaryIpMap[$iface.ipaddress] = $iface
                    }
                    # Populate the Standby IP map (one IP, multiple interfaces)
                    if ($iface.standbyip) {
                        foreach ($standbyIp in @($iface.standbyip)) {
                            if (-not $standbyIpMap.ContainsKey($standbyIp)) {
                                # If the key is new, create a new list with the current interface
                                $standbyIpMap[$standbyIp] = [System.Collections.Generic.List[object]]::new()
                            }
                            # Add the current interface to the list for that IP
                            $standbyIpMap[$standbyIp].Add($iface)
                        }
                    }
                }
            }
        }
    }
    $ipLookupDuration = (Get-Date) - $ipLookupStartTime
    Write-Host "[OPTIMIZATION] IP lookup tables built in $($ipLookupDuration.TotalMilliseconds) ms. (Primary: $($primaryIpMap.Count), Standby: $($standbyIpMap.Count))" -ForegroundColor Green
    # ===================================================================

    foreach ($device in $allDrawableHosts) {
        foreach ($interface in ($device.interfaces | Where-Object { $_.ipaddress -and (-not $_.shutdown) })) {
            if (($DiagramType -eq "Normal" -or $DiagramType -eq "LinksOnly")) {
                $targetNetwork = $drawableNetworksOnPage[$interface.cidr]
                if ($interface.LogicalDrawioId -and $targetNetwork -and $targetNetwork.LogicalDrawioId) {
                    Add-DrawioConnector -SourceId $interface.LogicalDrawioId -TargetId $targetNetwork.LogicalDrawioId -Style "endArrow=none;html=1;strokeWidth=2;strokeColor=#4CAF50;" -Text "$($interface.name)<br>$($interface.ipaddress)"
                }
            }

            if ($DiagramType -eq "RoutesOnly" -and $interface.RoutesForInterface) {
                $routeGroups = $interface.RoutesForInterface | Where-Object { $_.gateway } | Group-Object -Property gateway
                foreach ($group in $routeGroups) {
                    $gatewayIp = $group.Name
                    $matchFound = $false
                    
                    Write-Host "--- [DEBUG] Processing Route from $($device.HostName) via Gateway '$($gatewayIp)'" -ForegroundColor White

                    # --- Check Primary Map ---
                    if ($primaryIpMap.ContainsKey($gatewayIp)) {
                        $matchFound = $true
                        $targetInterface = $primaryIpMap[$gatewayIp]
                        Write-Host "  -> Checking Primary Map... MATCH FOUND on device '$($allDrawableHosts | where {$_.interfaces -contains $targetInterface} | select -ExpandProperty hostname -First 1)' interface '$($targetInterface.Interface)'" -ForegroundColor Cyan
                        
                        if ($interface.LogicalDrawioId -and $targetInterface.LogicalDrawioId) {
                            # ... [Full styling and drawing logic for Primary link]
                            $text = ""
                            $color = ""
                            $strokeWidth = "8"
                            $endArrow = "classic"
                            $endArrowSize = "8"
                            $dashed = "0"
                            $routeCount = $group.Count
                            $protocols = ($group.Group.RouteProtocol | Sort-Object -Unique) -join ', '
                            $primaryProtocol = ($group.Group.RouteProtocol | Select-Object -First 1)
                            if ($protocols -like "*BGP*") { $primaryProtocol = "BGP" }
                            elseif ($protocols -like "*EIGRP*") { $primaryProtocol = "EIGRP" }
                            elseif ($protocols -like "*OSPF*") { $primaryProtocol = "OSPF" }
                            elseif ($protocols -like "*static*") { $primaryProtocol = "static" }

                            switch -wildcard ($primaryProtocol) {
                                "static" { $color = "rgb(0,107,60)" }
                                "RIP" { $color = "rgb(179,89,0)" }
                                "BGP" { $color = "rgb(0,0,179)" }
                                "BGP-*" { $color = "rgb(0,0,179)" }
                                "B" { $color = "rgb(0,0,179)" }
                                "EIGRP" { $color = "rgb(160,32,240)" }
                                "OSPF" { $color = "rgb(255,255,51)" }
                                "OSPF-*" { $color = "rgb(255,255,51)" }
                                "IS-IS" { $color = "rgb(204,238,255)" }
                                "Default gateway" { $color = "rgb(0,107,60)" }
                                default { $color = "#000000" }
                            }

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

                            if ($text -like "*0.0.0.0/0*") { $dashed = "0" } else { $dashed = "1" }

                            $style = "endArrow=$endArrow;html=1;strokeWidth=$strokeWidth;strokeColor=$color;endSize=$endArrowSize;"
                            if ($dashed -eq "1") { $style += "dashed=1;" }

                            Add-DrawioConnector -SourceId $interface.LogicalDrawioId -TargetId $targetInterface.LogicalDrawioId -Style $style -Text $text
                            Write-Host "  ✅ DRAWING [Primary] Link from $($device.HostName)/$($interface.Interface) to target." -ForegroundColor Green
                        }
                    } else {
                        Write-Host "  -> Checking Primary Map... No match for '$($gatewayIp)'." -ForegroundColor Gray
                    }

                    # --- Check Standby Map INDEPENDENTLY ---
                    if ($standbyIpMap.ContainsKey($gatewayIp)) {
                        $targetInterfaces = $standbyIpMap[$gatewayIp]
                        
                        foreach ($targetInterface in $targetInterfaces) {


                            if ($interface.LogicalDrawioId -and $targetInterface.LogicalDrawioId) {
                                $matchFound = $true
                                # ... [Full styling and drawing logic for Standby link]
                                $text = ""
                                $color = ""
                                $strokeWidth = "8"
                                $endArrow = "classic"
                                $endArrowSize = "8"
                                $dashed = "0"
                                $routeCount = $group.Count
                                $protocols = ($group.Group.RouteProtocol | Sort-Object -Unique) -join ', '
                                $primaryProtocol = ($group.Group.RouteProtocol | Select-Object -First 1)
                                if ($protocols -like "*BGP*") { $primaryProtocol = "BGP" }
                                elseif ($protocols -like "*EIGRP*") { $primaryProtocol = "EIGRP" }
                                elseif ($protocols -like "*OSPF*") { $primaryProtocol = "OSPF" }
                                elseif ($protocols -like "*static*") { $primaryProtocol = "static" }

                                switch -wildcard ($primaryProtocol) {
                                    "static" { $color = "rgb(0,107,60)" }
                                    "RIP" { $color = "rgb(179,89,0)" }
                                    "BGP" { $color = "rgb(0,0,179)" }
                                    "BGP-*" { $color = "rgb(0,0,179)" }
                                    "B" { $color = "rgb(0,0,179)" }
                                    "EIGRP" { $color = "rgb(160,32,240)" }
                                    "OSPF" { $color = "rgb(255,255,51)" }
                                    "OSPF-*" { $color = "rgb(255,25s5,51)" }
                                    "IS-IS" { $color = "rgb(204,238,255)" }
                                    "Default gateway" { $color = "rgb(0,107,60)" }
                                    default { $color = "#000000" }
                                }

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

                                $text = "Standby: " + $text
                                $color = "#FF8C00" 
                                $strokeWidth = "2"
                                $dashed = "1"

                                $style = "endArrow=$endArrow;html=1;strokeWidth=$strokeWidth;strokeColor=$color;endSize=$endArrowSize;dashed=1;"

                                Add-DrawioConnector -SourceId $interface.LogicalDrawioId -TargetId $targetInterface.LogicalDrawioId -Style $style -Text $text
                                Write-Host "  ✅ DRAWING [Standby] Link from $($device.HostName)/$($interface.Interface) to target." -ForegroundColor Green
                            }
                        }
                    } else {
                        Write-Host "  -> Checking Standby Map... No match for '$($gatewayIp)'." -ForegroundColor Gray
                    }

                    if (-not $matchFound) {
                        Write-Host "  ⚠️ SKIPPING: Gateway IP '$gatewayIp' not found in any map." -ForegroundColor DarkYellow
                    }
                }
            }
        }
    }

    $phase2Duration = (Get-Date) - $phase2StartTime
    Write-Host "[BENCHMARK] Phase 2 (Connector Drawing) finished in $($phase2Duration.TotalSeconds) seconds." -ForegroundColor Cyan

    End-DrawioDiagram

    $funcEndTime = Get-Date
    $duration = New-TimeSpan -Start $funcStartTime -End $funcEndTime
    Write-Host "Function Draw-AllLayer3Drawio finished for page '$($NameOfPage)' in $($duration.TotalSeconds) seconds." -ForegroundColor Green
}




function Draw-SpanningTreeDiagram {
    [CmdletBinding()]
    param (
        # An array of all parsed host objects with their Spanning Tree data.
        [parameter(Mandatory = $true)]
        $ArrayOfObjects
    )

    # 1. Initialize the diagram and a tracker for dummy hosts.
    Start-DrawioDiagram -Name "Spanning-Tree"
    $dummyHosts = @{} # Used to track created dummy root bridges to avoid duplicates.

    # 2. Separate and draw the main devices.
    $rootHosts = @($ArrayOfObjects | Where-Object { ($_.SpanningTree.SpanningTreeArray | Where-Object { $_.RootBridge -eq $true }).Count -gt 0 } | Sort-Object HostName)
    $nonRootHosts = @($ArrayOfObjects | Where-Object { ($_.SpanningTree.SpanningTreeArray | Where-Object { $_.RootBridge -eq $true }).Count -eq 0 } | Sort-Object HostName)

    # Layout coordinates
    $horizontalPadding = 80
    $verticalPadding = 150
    $dummyRowY = 50 # New top row for unknown roots.
    $topRowY = $dummyRowY + 100 + $verticalPadding # Main hosts are below dummies.
    $bottomRowY = $topRowY + $GhostHeaderHeight + $GvlanSectionHeight + $verticalPadding

    # Draw Top Row (Root Hosts)
    $currentX = 50
    foreach ($device in $rootHosts) {
        $dimensions = Add-DrawioSpanningTreeHost -Device $device -Location ([PSCustomObject]@{X = $currentX; Y = $topRowY})
        if ($null -ne $dimensions) { $currentX += $dimensions.Width + $horizontalPadding }
    }

    # Draw Bottom Row (Non-Root Hosts)
    $currentX = 50
    foreach ($device in $nonRootHosts) {
        $dimensions = Add-DrawioSpanningTreeHost -Device $device -Location ([PSCustomObject]@{X = $currentX; Y = $bottomRowY})
        if ($null -ne $dimensions) { $currentX += $dimensions.Width + $horizontalPadding }
    }

    # 3. Connect all the non-root VLAN groups.
    Write-Host "`n[DEBUG] === DRAWING CONNECTORS ==="
    $dummyX = 50 # X-coordinate for placing new dummy hosts.
    foreach ($device in $ArrayOfObjects) {
        if (-not $device.SpanningTree) { continue }

        $nonRootGroups = $device.SpanningTree.SpanningTreeArray | Where-Object { -not $_.RootBridge } | Group-Object Address

        foreach ($group in $nonRootGroups) {
            $sourceShapeId = $group.Group[0].Shape
            $rootBridgeId = $group.Name

            $connectorLabel = ($group.Group.RootBridgePort | Select-Object -Unique) -join ",`n"

            $targetDevice = $null
            $targetShapeId = $null

            foreach ($potentialTarget in $ArrayOfObjects) {
                $foundRootVlan = $potentialTarget.SpanningTree.SpanningTreeArray | Where-Object { $_.Address -eq $rootBridgeId -and $_.RootBridge -eq $true } | Select-Object -First 1
                if ($foundRootVlan) {
                    $targetDevice = $potentialTarget
                    $targetShapeId = $foundRootVlan.Shape
                    break
                }
            }

            if (-not $targetDevice) {
                Write-Host "[DEBUG]   - Root Bridge $($rootBridgeId) not found. Checking for/creating a dummy host." -ForegroundColor Yellow
                if (-not $dummyHosts.ContainsKey($rootBridgeId)) {
                    $dummy = Create-HostObject
                    $dummy.HostName = $rootBridgeId
                    $dummy.SpanningTree = Create-SpanningTreeObject
                    $stpInstance = Create-SpanningTreeVlan
                    $stpInstance.Address = $rootBridgeId
                    $stpInstance.RootBridge = $true
                    $dummy.SpanningTree.SpanningTreeArray += $stpInstance

                    $dummyDimensions = Add-DrawioDummyRootHost -DummyDevice $dummy -Location ([PSCustomObject]@{X = $dummyX; Y = $dummyRowY})
                    $dummyX += $dummyDimensions.Width + $horizontalPadding
                    $dummyHosts[$rootBridgeId] = $dummy
                }
                $targetShapeId = $dummyHosts[$rootBridgeId].SpanningTree.SpanningTreeArray[0].Shape
            }

            if ($sourceShapeId -and $targetShapeId) {
                Write-Host "[DEBUG]   - Drawing connector from $($device.HostName) to root $($rootBridgeId) with label: $($connectorLabel)" -ForegroundColor Green

                # This style ensures straight lines.
                $style = "endArrow=classic;html=1;rounded=0;strokeColor=#4A148C;strokeWidth=2;dashed=1;whiteSpace=wrap;"

                Add-DrawioConnector -SourceId $sourceShapeId -TargetId $targetShapeId -Style $style -Text $connectorLabel
            }
        }
    }
    Write-Host "[DEBUG] =========================`n"

    # 4. Finalize and save the file.
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
        $ArrayOfNetworks,
        # The type of L3 diagram to create: "Normal" or "RoutesOnly".
        [parameter(Mandatory = $false)]
        [ValidateSet("Normal", "RoutesOnly")]
        [string]$DiagramType = "Normal",
        # An array of ALL device objects. Required when DiagramType is "RoutesOnly".
        [parameter(Mandatory = $false)]
        [array]$ArrayOfObjects,
        # An optional array of gateway-only devices (e.g., firewalls, routers).
        [parameter(Mandatory = $false)]
        [array]$ArrayofGatewayHosts
    )

    # 1. Start a new page for this device.
    Start-DrawioDiagram -Name "$($Device.hostname) L3"

    # ===================================================================
    # --- DRAWING LOGIC FOR 'Normal' DIAGRAM TYPE ---
    # ===================================================================
    if ($DiagramType -eq "Normal") {
        $DeviceArrayOfNetworks = @()
        foreach ($network1 in $device.ArrayOfNetworks) {
            $foundNetwork = $ArrayOfNetworks | Where-Object { $_.cidr -eq $network1.cidr } | Select-Object -First 1
            if ($foundNetwork) { $DeviceArrayOfNetworks += $foundNetwork }
        }
        $DeviceArrayOfNetworks = $DeviceArrayOfNetworks | Sort-Object NumberOfConnectors, RoutedVlan, cidr

        if ($DeviceArrayOfNetworks.Count -eq 0) {
            Write-Warning "No connected L3 networks found for $($Device.hostname). Skipping this page."
            return
        }

        $currentY = 100
        foreach ($network in $DeviceArrayOfNetworks) {
            $netId = Add-DrawioNetworkSegment -Network $network -Location ([PSCustomObject]@{X = 100; Y = $currentY})
            if ($GDrawAprEntries -and $network.ARPEntries) {
                $arpId = Add-DrawioArpBubble -Network $network -Location ([PSCustomObject]@{X = $GDrawioVlanWidth + 150; Y = $currentY})
                Add-DrawioConnector -SourceId $netId -TargetId $arpId -Style "endArrow=none;dashed=1;strokeColor=#9E9E9E;strokeWidth=4;"
            }
            $currentY += 80
        }

        $hostYPos = $currentY + 100
        Add-DrawioHostLayer3 -Device $Device -Location ([PSCustomObject]@{X = 400; Y = $hostYPos}) -DiagramType "Normal"

        foreach ($interface in ($Device.interfaces | where { $_.ipaddress -and (-not $_.shutdown) })) {
            $targetNetwork = $DeviceArrayOfNetworks | Where-Object { $_.cidr -eq $interface.cidr } | Select-Object -First 1
            if ($interface.LogicalDrawioId -and $targetNetwork.LogicalDrawioId) {
                $connectorStyle = "endArrow=none;strokeWidth=4;strokeColor=$(Convert-RgbToHex -RgbString $targetNetwork.color);"
                Add-DrawioConnector -SourceId $interface.LogicalDrawioId -TargetId $targetNetwork.LogicalDrawioId -Style $connectorStyle
            }
        }
    }
    # ===================================================================
    # --- DRAWING LOGIC FOR 'RoutesOnly' DIAGRAM TYPE ---
    # ===================================================================
    elseif ($DiagramType -eq "RoutesOnly") {
        if (-not $ArrayOfObjects) {
            throw "The -ArrayOfObjects parameter, containing all device objects, is required when DiagramType is 'RoutesOnly'."
        }

        # Combine main devices and gateway hosts into one list for processing.
        $allPossiblePeers = $ArrayOfObjects + $ArrayofGatewayHosts

        # 2a. Build IP lookup maps directly.
        $primaryIpMap = @{}
        foreach ($deviceObject in $allPossiblePeers) {
            if ($deviceObject.interfaces) {
                foreach ($iface in $deviceObject.interfaces) {
                    # Add any interface with an IP to the map.
                    if ($iface.ipaddress) {
                        $mapEntry = [PSCustomObject]@{ Interface = $iface; Device = $deviceObject }
                        if (-not $primaryIpMap.ContainsKey($iface.ipaddress)) {
                            $primaryIpMap[$iface.ipaddress] = $mapEntry
                        }
                    }
                    # Reset any previous drawing flags.
                    $iface.DrawOnRoutesOnlyDiagram = $false
                }
            }
        }

        # 2b. Identify peers with a two-way relationship check.
        $peersToDraw = @{}
        if ($Device.RoutingTable) {
            foreach ($route in $Device.RoutingTable | Where-Object Gateway) {
                $targetInfo = $primaryIpMap[$route.gateway]
                if ($targetInfo -and $targetInfo.Device.hostname -ne $Device.hostname) {
                    $peersToDraw[$targetInfo.Device.hostname] = $targetInfo.Device
                }
            }
        }
        foreach ($otherDevice in ($allPossiblePeers | Where-Object { $_.hostname -ne $Device.hostname })) {
            if ($otherDevice.RoutingTable) {
                foreach ($route in $otherDevice.RoutingTable | Where-Object Gateway) {
                    $targetInfo = $primaryIpMap[$route.gateway]
                    if ($targetInfo -and $targetInfo.Device.hostname -eq $Device.hostname) {
                        $peersToDraw[$otherDevice.hostname] = $otherDevice
                        break
                    }
                }
            }
        }

        # 2c. Before drawing, flag all interfaces that will be used for connections.
        $allRelevantDevices = @($Device) + $peersToDraw.Values
        foreach ($sourceDevice in $allRelevantDevices) {
            foreach ($interface in ($sourceDevice.interfaces | Where-Object { $_.RoutesForInterface })) {
                foreach ($group in ($interface.RoutesForInterface | Where-Object Gateway | Group-Object Gateway)) {
                    $targetInfo = $primaryIpMap[$group.Name]
                    if ($targetInfo -and ($targetInfo.Device.hostname -eq $Device.hostname -or $peersToDraw.ContainsKey($targetInfo.Device.hostname))) {
                        # Flag both the source and target interfaces to be drawn.
                        $interface.DrawOnRoutesOnlyDiagram = $true
                        $targetInfo.Interface.DrawOnRoutesOnlyDiagram = $true
                    }
                }
            }
        }

        # 2d. Draw the main host and its identified peers.
        Add-DrawioHostLayer3 -Device $Device -Location ([PSCustomObject]@{X = 800; Y = 500}) -DiagramType "RoutesOnly"
        $peerX = 100
        $drawablePeers = $peersToDraw.Values | Sort-Object hostname
        foreach ($peer in $drawablePeers) {
            Add-DrawioHostLayer3 -Device $peer -Location ([PSCustomObject]@{X = $peerX; Y = 1100}) -DiagramType "RoutesOnly"
            $peerX += 800
        }

        # 2e. Draw connectors now that IDs exist.
        foreach ($sourceDevice in $allRelevantDevices) {
            foreach ($interface in ($sourceDevice.interfaces | Where-Object { $_.LogicalDrawioId -and $_.RoutesForInterface })) {
                foreach ($group in ($interface.RoutesForInterface | Where-Object Gateway | Group-Object Gateway)) {
                    $gatewayIp = $group.Name
                    $targetInfo = $primaryIpMap[$gatewayIp]

                    if ($targetInfo -and $targetInfo.Interface.LogicalDrawioId) {
                        $targetInterface = $targetInfo.Interface
                        
                        $routeCount = $group.Count
                        $protocols = ($group.Group.RouteProtocol | Sort-Object -Unique) -join ', '
                        $primaryProtocol = ($group.Group.RouteProtocol | Select-Object -First 1)
                        if ($protocols -like "*BGP*") { $primaryProtocol = "BGP" }

                        $color = switch -wildcard ($primaryProtocol) {
                            "static" { "rgb(0,107,60)" }
                            "BGP"    { "rgb(0,0,179)" }
                            "EIGRP"  { "rgb(160,32,240)" }
                            "OSPF"   { "rgb(255,165,0)" }
                            default  { "#000000" }
                        }
                        $text = if ($routeCount -gt 15) {
                            "$($protocols)<br>$($gatewayIp)<br>Route Count:$routeCount"
                        } else {
                            "$($protocols)<br>$($gatewayIp)<br>" + (($group.Group | Select-Object -ExpandProperty subnet | Sort-Object) -join '<br>')
                        }
                        $dashed = if ($text -like "*0.0.0.0/0*") { 0 } else { 1 }
                        $style = "endArrow=classic;html=1;strokeWidth=8;strokeColor=$color;endSize=8;dashed=$dashed;"
                        
                        Add-DrawioConnector -SourceId $interface.LogicalDrawioId -TargetId $targetInterface.LogicalDrawioId -Style $style -Text $text
                    }
                }
            }
        }
    }

    # Finalize and save the diagram.
    End-DrawioDiagram
}


