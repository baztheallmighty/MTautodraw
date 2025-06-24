#Handles all connection types (Configured-to-Configured and Configured-to-Discovered) for both CDP and LLDP.
# Applies custom styles to Port-Channel connectors by calling the Get-ConnectorStyle helper function.
function Draw-AllNeighborsDrawio {
    [CmdletBinding()]
    param (
        [parameter(Mandatory=$true)]
        $ArrayOfObjects,
        [parameter(Mandatory=$true)]
        $ArrayOfCDPDeviceIDs,
        [parameter(Mandatory=$true)]
        $ArrayOfLLDPDeviceIDs
    )

    # This hashtable will cache the randomly generated styles for each Port-Channel number.
    # It is created here and passed by reference to the helper function.
    $runtimePortChannelStyles = @{}

    # 1. Start the Diagram and Draw the Legend
    Start-DrawioDiagram -Name "CDP-LLDP Physical"
    Add-DrawioInterfaceLegend -Location ([PSCustomObject]@{X = 50; Y = 1400})

    # 2. Draw all hosts.
    $currentX = 100
    foreach ($device in ($ArrayOfObjects | Sort-Object HostName)) {
        $hostWidth = Add-DrawioHostPhysical -Device $device -Location ([PSCustomObject]@{X=$currentX; Y=100})
        $currentX += 950 + $hostWidth
    }

    $currentX = 100
    $currentY = 700
    foreach ($cdpDevice in ($ArrayOfCDPDeviceIDs | Sort-Object HostName)) {
        Add-DrawioNeighborHost -Device $cdpDevice -Location ([PSCustomObject]@{X=$currentX; Y=$currentY}) -DrawType "CDPNeighbor"
        $currentX += 950
    }

    $currentX = 100
    $currentY = 1300
    foreach ($lldpDevice in ($ArrayOfLLDPDeviceIDs | Sort-Object HostName)) {
        Add-DrawioNeighborHost -Device $lldpDevice -Location ([PSCustomObject]@{X=$currentX; Y=$currentY}) -DrawType "LLDPNeighbor"
        $currentX += 950
    }

    # ===================================================================
    # 3. --- Connect all the shapes with custom styling ---
    # ===================================================================
    foreach ($device in $ArrayOfObjects) {
        # --- CDP Connections ---
        if ($device.CDPNeighbors) {
            # Configured <--> Configured (CDP)
            foreach ($cdpNeighbor in ($device.CDPNeighbors | Where-Object { $_.PartnerEthernetInterface -and $_.PartnerEthernetInterface.Value })) {
                $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $cdpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
                $toInterface = $cdpNeighbor.PartnerEthernetInterface.Value
                if ($fromInterface.PhysicalDrawioId -and $toInterface.PhysicalDrawioId) {
                    $style = Get-ConnectorStyle -fromInterface $fromInterface
                    Add-DrawioConnector -SourceId $fromInterface.PhysicalDrawioId -TargetId $toInterface.PhysicalDrawioId -Style $style
                }
            }
            # Configured <--> Discovered (CDP)
            foreach ($cdpNeighbor in ($device.CDPNeighbors | Where-Object { -not $_.PartnerEthernetInterface })) {
                $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $cdpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
                $toDevice = $ArrayOfCDPDeviceIDs | Where-Object { $_.HostName -eq $cdpNeighbor.DeviceID } | Select-Object -First 1
                if ($toDevice) {
                    $toInterface = $toDevice.interfaces | Where-Object { $_.Interface -eq $cdpNeighbor.InterfaceRemoteDevice } | Select-Object -First 1
                    if ($fromInterface.PhysicalDrawioId -and $toInterface.PhysicalDrawioId) {
                        $style = Get-ConnectorStyle -fromInterface $fromInterface
                        Add-DrawioConnector -SourceId $fromInterface.PhysicalDrawioId -TargetId $toInterface.PhysicalDrawioId -Style $style
                    }
                }
            }
        }

        # --- LLDP Connections ---
        if ($device.LLDPNeighbors) {
            # Configured <--> Configured (LLDP)
            foreach ($lldpNeighbor in ($device.LLDPNeighbors | Where-Object { $_.PartnerEthernetInterface -and $_.PartnerEthernetInterface.Value })) {
                $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $lldpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
                $toInterface = $lldpNeighbor.PartnerEthernetInterface.Value
                if ($fromInterface.PhysicalDrawioId -and $toInterface.PhysicalDrawioId) {
                    $style = Get-ConnectorStyle -fromInterface $fromInterface
                    Add-DrawioConnector -SourceId $fromInterface.PhysicalDrawioId -TargetId $toInterface.PhysicalDrawioId -Style $style
                }
            }
            # Configured <--> Discovered (LLDP)
            foreach ($lldpNeighbor in ($device.LLDPNeighbors | Where-Object { (-not $_.PartnerEthernetInterface) -and (-not $_.HasCDPNeighborEntry) })) {
                
                $fromInterface = $device.interfaces | Where-Object { $_.Interface -eq $lldpNeighbor.InterfaceLocalDevice } | Select-Object -First 1
                
                # Use the robust looping logic from the old Visio script to find the remote interface
                $toInterface = $null # Reset for each neighbor

                :outer foreach ($discoveredDevice in $ArrayOfLLDPDeviceIDs) {
                    # Check if the discovered device's hostname matches the neighbor's reported hostname or Chassis ID
                    if (($discoveredDevice.hostname -eq $lldpNeighbor.HostName) -or ($discoveredDevice.hostname -eq $lldpNeighbor.ChassisID)) {
                        
                        # Now loop through the interfaces on the correctly identified device
                        foreach ($remoteInterface in $discoveredDevice.interfaces) {
                            # Check if this interface's name matches the one reported by the neighbor
                            if ($remoteInterface.Interface -eq $lldpNeighbor.InterfaceRemoteDevice) {
                                $toInterface = $remoteInterface # We found the exact interface object
                                break outer # Exit both loops
                            }
                        }
                    }
                }
                
                # Connect the shapes if both local and remote interfaces were successfully found
                if ($fromInterface.PhysicalDrawioId -and $toInterface.PhysicalDrawioId) {
                    #Write-Host "Connecting [LLDP-Discovered]: $($device.HostName)/$($fromInterface.Interface) -> $($lldpNeighbor.HostName)/$($toInterface.Interface)" -ForegroundColor Green
                    $style = Get-ConnectorStyle -fromInterface $fromInterface
                    Add-DrawioConnector -SourceId $fromInterface.PhysicalDrawioId -TargetId $toInterface.PhysicalDrawioId -Style $style
                }
            }
        }
    }
    End-DrawioDiagram
}




function Draw-AllLayer3Drawio {
    [CmdletBinding()]
    param (
        [parameter(Mandatory=$true)] $ArrayOfObjects,
        [parameter(Mandatory=$true)] $ArrayOfNetworks,
        [parameter(Mandatory=$false)] $ArrayOfIPApr,
        [parameter(Mandatory=$true)] $DiagramType,
        [parameter(Mandatory=$true)] $NameOfPage,
        [parameter(Mandatory=$false)] $ArrayofGatewayHosts
    )
    #Write-Host "Drawing Layer 3 Diagram: $NameOfPage" -ForegroundColor Green
    Start-DrawioDiagram -Name $NameOfPage

    # This hashtable will store networks drawn on THIS specific page
    # It's crucial for connecting devices to the correct network shapes.
    $drawableNetworksOnPage = @{}

    # --- Phase 1: Draw all nodes (Hosts and Networks/VLANs with ARP bubbles) ---
    #Write-Host "`nDEBUG: Phase 1 - Drawing all physical nodes and networks..." -ForegroundColor Cyan

    # Draw regular hosts
    $currentX = 50
    foreach ($Device in ($ArrayOfObjects | Sort-Object HostName)) {
        $hostWidth=Add-DrawioHostLayer3 -Device $Device -Location ([PSCustomObject]@{X = $currentX; Y = 500}) -DiagramType $DiagramType
        $currentX += 700
        $currentX += $hostWidth
    }

    # Draw gateway hosts
    if (($DiagramType -eq "RoutesOnly" -or $DiagramType -eq "LinksOnly") -and $ArrayofGatewayHosts) {
        $currentX = 50
        foreach ($GatewayHost in $ArrayofGatewayHosts) {
            # Pass the DiagramType parameter here as well
            $hostWidth=Add-DrawioHostLayer3 -Device $GatewayHost -Location ([PSCustomObject]@{X = $currentX; Y = 1100}) -HostType "GatewayHost" -DiagramType $DiagramType
            $currentX += 700
            $currentX += $hostWidth
        }
    }
    # Draw networks (VLANs) and their associated ARP bubbles
    # Assuming $GDrawioVlanWidth, $GDrawAprEntries, $GDrawioVlanHeight, etc., are defined globally
    if ($DiagramType -eq "Normal" -or $DiagramType -eq "LinksOnly") {
        #Write-Host "`nDEBUG: Drawing networks and ARP entries..." -ForegroundColor Cyan
        $currentY = 50 # Starting Y for networks, adjust as needed relative to hosts
        foreach ($network in $ArrayOfNetworks) {
            # Skip networks that should not be drawn in "LinksOnly" mode
            if($DiagramType -eq "LinksOnly" -and $network.NumberOfRoutedConnectors -eq 0) { continue }
            
            # Draw the network segment
            $netId = Add-DrawioNetworkSegment -Network $network -Location ([PSCustomObject]@{X = 100; Y = $currentY})
            
            # Store the network object in our page-specific map using its CIDR as key
            # This is critical for connecting devices to networks later.
            $drawableNetworksOnPage[$network.cidr] = $network
            
            # Draw ARP entries bubble if enabled and data exists
            if ($GDrawAprEntries -and $network.ARPEntries) {
                $arpId = Add-DrawioArpBubble -Network $network -Location ([PSCustomObject]@{X = 400; Y = $currentY}) # Adjusted X for ARP bubble
                
                # Connect the network to the ARP bubble
                if ($netId -and $arpId) { # Ensure both shapes were drawn
                    Add-DrawioConnector -SourceId $netId -TargetId $arpId -Style "endArrow=none;dashed=1;strokeColor=#9E9E9E;strokeWidth=2;" -Text "ARP"
                }
            }
            $currentY += ($GDrawioVlanHeight + 50) # Increment Y for next network, adjust spacing
        }
    }

    # --- Phase 2: Draw all connectors ---
    Write-Host "Connecting L3 components for page '$NameOfPage'..." -ForegroundColor Cyan
    $allDrawableHosts = $ArrayOfObjects + $ArrayofGatewayHosts
    
    foreach ($device in $allDrawableHosts) {
        foreach ($interface in ($device.interfaces | Where-Object { $_.ipaddress -and (-not $_.shutdown) })) {
            # --- Connect Device Interfaces to Networks/VLANs ---
            if (($DiagramType -eq "Normal" -or $DiagramType -eq "LinksOnly")) {
                $targetNetwork = $drawableNetworksOnPage[$interface.cidr]
                
                if ($interface.LogicalDrawioId -and $targetNetwork -and $targetNetwork.LogicalDrawioId) {
                    #Write-Host "        DEBUG: Connecting device $($device.HostName) interface $($interface.name) to network $($targetNetwork.cidr)." -ForegroundColor DarkGreen
                    Add-DrawioConnector -SourceId $interface.LogicalDrawioId -TargetId $targetNetwork.LogicalDrawioId -Style "endArrow=none;html=1;strokeWidth=2;strokeColor=#4CAF50;" -Text "$($interface.name)<br>$($interface.ipaddress)"
                } elseif ($DiagramType -eq "Normal") {
                    #Write-Warning "Interface $($device.HostName).$($interface.name) (IP: $($interface.ipaddress)) has CIDR $($interface.cidr) but matching network was not drawn or found on this page."
                }
            }

            # --- Handle Primary Gateway Routes (with multiple standby IP fallbacks) ---
            if ($DiagramType -eq "RoutesOnly" -and $interface.RoutesForInterface) {
                $routeGroups = $interface.RoutesForInterface | Where-Object { $_.gateway } | Group-Object -Property gateway
                
                foreach ($group in $routeGroups) {
                    $gatewayIp = $group.Name
                    $targetInterfaces = @()
                    $connectionType = "Primary"

                    #Write-Host "      DEBUG: Processing route from $($interface.name) to Gateway IP: $gatewayIp" -ForegroundColor Magenta

                    # 1. First, search for the Gateway IP among all PHYSICAL hosts as a PRIMARY IP
                    foreach ($deviceToSearch in $allDrawableHosts) {
                        $foundPrimaryInterface = $deviceToSearch.interfaces | Where-Object { $_.ipaddress -eq $gatewayIp }
                        if ($foundPrimaryInterface) {
                            $targetInterfaces += ($foundPrimaryInterface | Select-Object -First 1)
                            #Write-Host "        DEBUG: Gateway IP $gatewayIp found as PRIMARY IP on device $($deviceToSearch.HostName)." -ForegroundColor Green
                            $connectionType = "Primary"
                            break
                        }
                    }

                    # 2. If NOT found as a primary IP, then look for it as a STANDBY IP on other devices.
                    if (-not $targetInterfaces) {
                        #Write-Host "        DEBUG: Gateway IP $gatewayIp not found as primary. Checking ALL standby IPs on other devices..." -ForegroundColor Yellow
                        foreach ($deviceToSearch in $allDrawableHosts) {
                            if ($deviceToSearch.interfaces) {
                                foreach ($otherInterface in $deviceToSearch.interfaces) {
                                    if ($null -ne $otherInterface.standbyip) {
                                        $standbyIpsToCheck = @($otherInterface.standbyip) 
                                        if ($standbyIpsToCheck -contains $gatewayIp) {
                                            $targetInterfaces += $otherInterface
                                            #Write-Host "        DEBUG: Gateway IP $gatewayIp found as STANDBY IP on device $($deviceToSearch.HostName) on interface $($otherInterface.name)." -ForegroundColor Green
                                            $connectionType = "StandbyFallback"
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if (-not $targetInterfaces) {
                        #Write-Host "        DEBUG: Gateway IP $gatewayIp not found on any physical devices (primary or standby). Skipping route connection." -ForegroundColor Red
                        continue
                    }
                    
                    foreach ($targetInterface in $targetInterfaces) {
                        if ($interface.LogicalDrawioId -and $targetInterface.LogicalDrawioId) {
                            #Write-Host "        DEBUG: SUCCESS - Connecting from '$($interface.ipaddress)' to target '$($targetInterface.ipaddress)'. SourceID: $($interface.LogicalDrawioId), TargetID: $($targetInterface.LogicalDrawioId)" -ForegroundColor Green
                            
                            $text = ""
                            $color = ""
                            $strokeWidth = "8"
                            $endArrow = "classic"
                            $endArrowSize = "8"
                            $dashed = "0" 

                            # Logic for determining protocol and route details for text and color
                            $routeCount = $group.Count
                            $protocols = ($group.Group.RouteProtocol | Sort-Object -Unique) -join ', '
                            
                            $primaryProtocol = ($group.Group.RouteProtocol | Select-Object -First 1)
                            if ($protocols -like "*BGP*") { $primaryProtocol = "BGP" }
                            elseif ($protocols -like "*EIGRP*") { $primaryProtocol = "EIGRP" }
                            elseif ($protocols -like "*OSPF*") { $primaryProtocol = "OSPF" }
                            elseif ($protocols -like "*static*") { $primaryProtocol = "static" }

                            # Your exact defined route colors
                            switch -wildcard ($primaryProtocol) {
                                "static"        { $color = "rgb(0,107,60)" }   # Green
                                "RIP"           { $color = "rgb(179,89,0)" }   # Dark orange
                                "BGP"           { $color = "rgb(0,0,179)" }    # blue
                                "BGP-*"         { $color = "rgb(0,0,179)" }    # blue
                                "B"             { $color = "rgb(0,0,179)" }    # blue
                                "EIGRP"         { $color = "rgb(160,32,240)"}  # purple
                                "OSPF"          { $color = "rgb(255,255,51)" } # Yellow
                                "OSPF-*"        { $color = "rgb(255,255,51)" } # Yellow
                                "IS-IS"         { $color = "rgb(204,238,255)"} # Light blue
                                "Default gateway" { $color = "rgb(0,107,60)" } # Green
                                default         { $color = "#000000" }         # black
                            }

                            # Text generation
                            if (($group.Group | select subnet).count -gt 30) {
                                if ($group.Group | where { $_.subnet -like "*0.0.0.0/0*"}) {
                                    $text = "$($protocols)<br>$($gatewayIp)<br>Route Count:$routeCount<br>Routes For: 0.0.0.0/0"
                                } else {
                                    $text = "$($protocols)<br>$($gatewayIp)<br>Route Count:$routeCount"
                                }
                            } else {
                                $text = "$($protocols)<br>$($gatewayIp)<br>"
                                $text += ($group.Group | select -ExpandProperty subnet | sort) -join '<br>'
                            }

                            # Line pattern for default routes
                            if ($text -like "*0.0.0.0/0*") {
                                $dashed = "0" # Solid line
                            } else {
                                $dashed = "1" # Dashed line
                            }

                            # Apply standby specific style adjustments if it's a fallback connection
                            if ($connectionType -eq "StandbyFallback") {
                                $text = "Standby: " + $text # Prepend "Standby: " to the existing route text
                                $color = "#FF8C00" # Dark Orange for standby line color
                                $strokeWidth = "2" # Thinner line for standby
                                $dashed = "1" # Always dashed for standby
                            }

                            # Construct the style string for Draw.io
                            $style = "endArrow=$endArrow;html=1;strokeWidth=$strokeWidth;strokeColor=$color;endSize=$endArrowSize;"
                            if ($dashed -eq "1") {
                                $style += "dashed=1;"
                            }
                            
                            Add-DrawioConnector -SourceId $interface.LogicalDrawioId -TargetId $targetInterface.LogicalDrawioId -Style $style -Text $text 
                            
                        } else {
                            #Write-Host "        DEBUG: FAILED - Missing Shape ID. Source: $($interface.LogicalDrawioId), Target: $($targetInterface.LogicalDrawioId)" -ForegroundColor Red
                        }
                    } # End foreach targetInterface
                } # End foreach group
            } 
        } # End foreach interface
    } # End foreach device
    End-DrawioDiagram
}




function Draw-SinglesLayer3Drawio {
    [CmdletBinding()]
    param (
        [parameter(Mandatory=$true)]
        $Device,
        [parameter(Mandatory=$true)]
        $ArrayOfNetworks
    )

    #Write-Host "Drawing single L3 diagram for: $($Device.hostname)" -ForegroundColor Green
    
    # 1. Filter for networks relevant to only this device
    $DeviceArrayOfNetworks = @()
    foreach ($network1 in $device.ArrayOfNetworks) {
        $foundNetwork = $ArrayOfNetworks | Where-Object { $_.cidr -eq $network1.cidr } | Select-Object -First 1
        if ($foundNetwork) {
            $DeviceArrayOfNetworks += $foundNetwork
        }
    }
    $DeviceArrayOfNetworks = $DeviceArrayOfNetworks | Sort-Object NumberOfConnectors, RoutedVlan, cidr

    if ($DeviceArrayOfNetworks.Count -eq 0) {
        Write-Warning "No connected L3 networks found for $($Device.hostname). Skipping this page."
        return
    }

    # 2. Start a new page for this device
    Start-DrawioDiagram -Name "$($Device.hostname) L3"

    # 3. Draw all network segments and their ARP bubbles
    $currentY = 100
    foreach ($network in $DeviceArrayOfNetworks) {
        $netId = Add-DrawioNetworkSegment -Network $network -Location ([PSCustomObject]@{X = 100; Y = $currentY})
        
        if ($GDrawAprEntries -and $network.ARPEntries) {
            $arpId = Add-DrawioArpBubble -Network $network -Location ([PSCustomObject]@{X = $GDrawioVlanWidth + 150; Y = $currentY})
            Add-DrawioConnector -SourceId $netId -TargetId $arpId -Style "endArrow=none;dashed=1;strokeColor=#9E9E9E;strokeWidth=4;"
        }
        $currentY += 80 
    }

    # 4. Draw the main host, positioned below the networks
    $hostYPos = $currentY + 100
    $hostWidth=Add-DrawioHostLayer3 -Device $Device -Location ([PSCustomObject]@{X = 400; Y = $hostYPos}) -DiagramType "Normal"

    # 5. Draw connectors from host interfaces to network segments
    foreach ($interface in ($Device.interfaces | where { $_.ipaddress -and (-not $_.shutdown)})) {
        $targetNetwork = $DeviceArrayOfNetworks | Where-Object { $_.cidr -eq $interface.cidr } | Select-Object -First 1
        
        if ($interface.LogicalDrawioId -and $targetNetwork.LogicalDrawioId) {
            $routesForInterface = $Device.RoutingTable| where { $_.interface -eq $interface.Interface -and $_.routeprotocol -notmatch "local|connected" } | sort gateway,subnet
            $connectorText = ""
            if ($routesForInterface) {
                $connectorText = "Routes via this link"
            }

            $connectorStyle = "endArrow=none;strokeWidth=4;strokeColor=$(Convert-RgbToHex -RgbString $targetNetwork.color);"
            
            # --- THIS IS THE FIX ---
            # Changed -From and -To to the correct -SourceId and -TargetId
            Add-DrawioConnector -SourceId $interface.LogicalDrawioId -TargetId $targetNetwork.LogicalDrawioId -Style $connectorStyle -Text $connectorText
        }
    }
    
    End-DrawioDiagram
}



