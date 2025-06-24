function Add-DrawioInterfaceLegend {
    [CmdletBinding()]
    param (
        [parameter(Mandatory=$true)]
        [PSCustomObject]$Location,
        [string]$Title = "Interface Legend"
    )
    
    # --- Configuration for the legend box ---
    $lineHeight = 25; $padding = 15; $boxWidth = 300
    $contentHeight = ($GArrayOfInterfaceTypes.Count + 2) * $lineHeight
    $boxHeight = $contentHeight + (2 * $padding)
    # --- Create the main group to hold all legend parts ---
    $legendGroupId = "legend-group-$((New-Guid).ToString().Substring(0,8))"
    $global:drawioXml += "        <mxCell id=`"$legendGroupId`" value=`"`" style=`"group`" vertex=`"1`" connectable=`"0`" parent=`"1`">`n            <mxGeometry x=`"$($Location.X)`" y=`"$($Location.Y)`" width=`"$boxWidth`" height=`"$boxHeight`" as=`"geometry`" />`n        </mxCell>`n"
    # --- Create the background rectangle for the legend ---
    $backgroundId = "legend-bg-$((New-Guid).ToString().Substring(0,8))"
    $global:drawioXml += "        <mxCell id=`"$backgroundId`" value=`"`" style=`"rounded=1;whiteSpace=wrap;html=1;fillColor=#ffffff;strokeColor=#36393d;shadow=1;`" vertex=`"1`" parent=`"$legendGroupId`">`n            <mxGeometry width=`"$boxWidth`" height=`"$boxHeight`" as=`"geometry`" />`n        </mxCell>`n"
    # --- Add Title and Header ---
    $currentY = $padding; $titleId = "legend-title-$((New-Guid).ToString().Substring(0,8))"; $headerId = "legend-header-$((New-Guid).ToString().Substring(0,8))"
    $titleValue = [System.Web.HttpUtility]::HtmlEncode("<div style=`"font-size: 14px; font-weight: bold;`">$Title</div>")
    $global:drawioXml += "        <mxCell id=`"$titleId`" value=`"$titleValue`" style=`"text;html=1;align=center;verticalAlign=middle;resizable=0;points=[];`" vertex=`"1`" parent=`"$legendGroupId`">`n            <mxGeometry y=`"$currentY`" width=`"$boxWidth`" height=`"20`" as=`"geometry`" />`n        </mxCell>`n"
    $currentY += $lineHeight
    $headerValue = [System.Web.HttpUtility]::HtmlEncode("<b>Color&nbsp;&nbsp;&nbsp;&nbsp;|&nbsp;&nbsp;&nbsp;&nbsp;Interface Cisco Type Name</b>")
    $global:drawioXml += "        <mxCell id=`"$headerId`" value=`"$headerValue`" style=`"text;html=1;align=left;verticalAlign=middle;resizable=0;points=[];`" vertex=`"1`" parent=`"$legendGroupId`">`n            <mxGeometry x=`"$padding`" y=`"$currentY`" width=`"$boxWidth`" height=`"20`" as=`"geometry`" />`n        </mxCell>`n"
    $currentY += $lineHeight
    # --- Loop through interface types and create entries ---
    foreach ($legendLine in $GDrawioArrayOfInterfaceTypes) {
        $interfaceFamily = $legendLine[0]; $interfaceName = $legendLine[1]; $fillColorRgb = $legendLine[2]; $fillColorHex = Convert-RgbToHex -RgbString $fillColorRgb
        $strokeColor = "#000000"; $strokeWidth = 1
        if ($interfaceFamily -eq "RJ45-SFP") { $strokeWidth = $GDrawioInterfaceLegend_LineWidth; $strokeColor = $GDrawioInterfaceLegend_LineColorSFP_RJ45 }
        elseif ($interfaceFamily -eq "Fibre") { $strokeWidth = $GDrawioInterfaceLegend_LineWidth; $strokeColor = $GDrawioInterfaceLegend_LineColorSFP }
        $swatchId = "swatch-$((New-Guid).ToString().Substring(0,8))"; $swatchStyle = "rounded=0;whiteSpace=wrap;html=1;fillColor=$fillColorHex;strokeColor=$strokeColor;strokeWidth=$strokeWidth;"
        $global:drawioXml += "        <mxCell id=`"$swatchId`" value=`"`" style=`"$swatchStyle`" vertex=`"1`" parent=`"$legendGroupId`">`n            <mxGeometry x=`"$padding`" y=`"$currentY`" width=`"$GDrawioInterfaceLegend_SwatchWidth`" height=`"$GDrawioInterfaceLegend_SwatchHeight`" as=`"geometry`" />`n        </mxCell>`n"
        $labelId = "label-$((New-Guid).ToString().Substring(0,8))"; $labelValue = [System.Web.HttpUtility]::HtmlEncode($interfaceName); $labelX = $padding + $GDrawioInterfaceLegend_SwatchWidth + 10
        $global:drawioXml += "        <mxCell id=`"$labelId`" value=`"$labelValue`" style=`"text;html=1;align=left;verticalAlign=middle;resizable=0;points=[];`" vertex=`"1`" parent=`"$legendGroupId`">`n            <mxGeometry x=`"$labelX`" y=`"$currentY`" width=`"220`" height=`"$GDrawioInterfaceLegend_SwatchHeight`" as=`"geometry`" />`n        </mxCell>`n"
        $currentY += $lineHeight
    }
}


# Helper function to prevent errors with malformed RGB strings.
function Convert-RgbToHex {
    param([string]$RgbString)
    $matches = [regex]::Matches($RgbString, '\d+')
    if ($matches.Count -ge 3) {
        $r = "{0:X2}" -f [int]$matches[0].Value
        $g = "{0:X2}" -f [int]$matches[1].Value
        $b = "{0:X2}" -f [int]$matches[2].Value
        return "#$r$g$b"
    }
    return "#FFFFFF" # Return white on error
}


# ENHANCED VERSION - A more faithful port of the original Visio function.
function Add-DrawioPhysicalInterface {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)]
        $Interface,
        [parameter(Mandatory = $true)]
        [PSCustomObject]$Location,
        [parameter(Mandatory = $true)]
        [string]$ParentId,
        $DrawType
    )

    # =================================================
    # 1. Text Construction
    # =================================================
    $textElements = [System.Collections.ArrayList]::new()

    if ($GDrawioShortenInterfacesNames) {
        $ifaceName = $Interface.Interface -replace "GigabitEthernet", "Gi" -replace "TenGigabitEthernet", "Te" -replace "FastEthernet", "Fa"
        $null = $textElements.Add("<b>$ifaceName</b>")
    } else {
        $null = $textElements.Add("<b>$($Interface.Interface)</b>")
    }

    if ($Interface.Description) { $null = $textElements.Add($Interface.Description) }

    # --- START OF CHANGES ---

    if ($Interface.SwitchportMode -like "trunk") {
        # CHANGE 1a: Added a replace to add spaces to the VLAN list for better text wrapping.
        $vlans = if ($Interface.SwitchportTrunkVlan) { $Interface.SwitchportTrunkVlan -replace ',', ', ' } else { "all" }
        $null = $textElements.Add("Trunk VLANs: $vlans")
    } elseif ($Interface.SwitchportMode -eq "Probably Trunk mode") {
        # CHANGE 1b: Added a replace to add spaces to the VLAN list for better text wrapping.
        $vlans = if ($Interface.SwitchportTrunkVlan) { $Interface.SwitchportTrunkVlan -replace ',', ', ' } else { "all" }
        $null = $textElements.Add("Probable Trunk: $vlans")
    } elseif ($Interface.SwitchportMode -eq "access") {
        $null = $textElements.Add("Access VLAN: $($Interface.SwitchportAccessVlan)")
    } elseif ($Interface.SwitchPortType -eq "Routed") {
        $null = $textElements.Add("Routed Port: $($Interface.ipaddress)/$($Interface.subnetmask)")
    } else {
        $null = $textElements.Add("No L2/L3 config found.")
    }

    if ($Interface.ChannelGroup) {
        if ($interface.ChannelGroup -like "*ae*") {
            $null = $textElements.Add($Interface.ChannelGroup)
        } else {
            $null = $textElements.Add("Port-Channel $($Interface.ChannelGroup)")
        }
    }

    # =================================================
    # 2. Geometry & Spanning Tree Adjustments
    # =================================================
    $currentX = $Location.X
    $currentY = $Location.Y
    
    # Original Spanning Tree text elements are added first.
    if ($DrawType -eq "neighbors") {
        if ($Interface.STRootInterfaceForVlans -or $Interface.STRole -eq "Root") {
            $null = $textElements.Add("STP Root Port")
        }
        if ($Interface.STALTnInterfaceForVlans -or $Interface.STRole -eq "ALT") {
            $null = $textElements.Add("STP ALTN Port")
        }
    }
    
    if ($Interface.STState -eq "BLK") {
        $null = $textElements.Add("STP Blocked Port")
    }

    # CHANGE 2: Calculate height dynamically *after* all text elements have been added.
    # Start with the base height.
    $currentHeight = $GDrawioPhysicalInterfaceHeight
    # Estimate the number of lines required based on the text elements added.
    $estimatedLines = 0
    foreach($line in $textElements) {
        # Each element is at least one line. Add extra for long lines that will wrap.
        $estimatedLines += [Math]::Max(1, [Math]::Ceiling($line.ToString().Length / 40.0))
    }
    # Add 15px of height for each line beyond the default of 3.
    if ($estimatedLines -gt 3) {
        $currentHeight += ($estimatedLines - 3) * 15
    }
    
    # Now, apply original STP geometry adjustments to the new dynamic height.
    if ($DrawType -eq "neighbors") {
        if ($Interface.STRootInterfaceForVlans -or $Interface.STRole -eq "Root") {
            $currentY -= $GDrawioPhysicalHostInterfaceOffsetY # Move shape up
            $currentHeight += $GDrawioSpanningTreeInterfaceSize
        }
        if ($Interface.STALTnInterfaceForVlans -or $Interface.STRole -eq "ALT") {
            $currentY -= $GDrawioPhysicalHostInterfaceOffsetY # Move shape up
            $currentHeight += $GDrawioSpanningTreeInterfaceSize
        }
    }

    # --- END OF CHANGES ---
    
    # Convert text array to a single HTML string
    $finalText = $textElements -join "<br>"
    $encodedText = [System.Web.HttpUtility]::HtmlEncode($finalText)

    # =================================================
    # 3. Styling (Fill, Font, and Border)
    # =================================================
    $style = "rounded=1;whiteSpace=wrap;html=1;arcSize=10;align=center;verticalAlign=middle;fontSize=$($GDrawioPhysicalInterfaceFontSize);"
    $fontColor = "#000000" # Default to black text
    
    # Find media type to determine fill color
    $mediaType = $GDrawioArrayOfInterfaceTypes | Where-Object { $_[1] -eq $Interface.MediaType } | Select-Object -First 1
    if ($mediaType) {
        $style += "fillColor=$(Convert-RgbToHex -RgbString $mediaType[2]);"
        if ($mediaType[0] -eq "RJ45" -or $mediaType[0] -eq "RJ45-SFP") {
            $fontColor = "#FFFFFF" # Change text to white for dark backgrounds
            $style += "gradientColor=#646464;" # Use gradient as a substitute for Visio's fill patterns
        }
    } else {
        # Apply default color if media type is unknown
        $style += "fillColor=$GDrawioDefaultInterfacesColor;"
    }
    
    # Override fill color if port is down (most important style)
    if ($Interface.shutdown -or ($Interface.IntStatus -like "*down*")) {
        $style += "fillColor=#FF9999;" # Light red for down ports
        $fontColor = "#000000" # Ensure text is black on the light red background
    }

    $style += "fontColor=$fontColor;"

    # --- THIS IS THE CHANGE ---
    # Set border style based on Port-Channel membership by calling the central style function.
    # Set border style based on Port-Channel membership
    if ($Interface.ChannelGroup) {
        $channelNumber = $Interface.ChannelGroup -replace '\D',''
        # Get the cached style object for this channel.
        $styleObject = Get-OrSet-PortChannelStyle -channelNumber $channelNumber
        # Apply the style to the interface's border.
        $style += "strokeColor=$($styleObject.strokeColor);strokeWidth=$($styleObject.strokeWidth);"
    } else {
        # Not a port-channel, use a standard black border.
        $style += "strokeColor=#000000;strokeWidth=1;"
    }

    # =================================================
    # 4. Generate XML
    # =================================================
    $interfaceId = "iface-$((New-Guid).ToString().Substring(0,8))"
    $Interface.PhysicalDrawioId = $interfaceId

    $global:drawioXml += "        <mxCell id=`"$interfaceId`" value=`"$encodedText`" style=`"$style`" vertex=`"1`" parent=`"$ParentId`">`n            <mxGeometry x=`"$currentX`" y=`"$currentY`" width=`"$GDrawioPhysicalInterfaceWidth`" height=`"$currentHeight`" as=`"geometry`" />`n        </mxCell>`n"
    
    # Add a cross for STP blocked ports
    if ($DrawType -eq "neighbors" -and $Interface.STState -eq "BLK") {
        $crossId = "cross-$((New-Guid).ToString().Substring(0,8))"
        $crossStyle = "shape=mxgraph.basic.cross;strokeColor=#D32F2F;strokeWidth=3;rotation=20;"
        $global:drawioXml += "        <mxCell id=`"$crossId`" value=`"`" style=`"$crossStyle`" vertex=`"1`" parent=`"$interfaceId`">`n             <mxGeometry x=`"0.25`" y=`"0.25`" width=`"0.5`" height=`"0.5`" relative=`"1`" as=`"geometry`" />`n        </mxCell>`n"
    }
}

# Creates the XML for a host and all its physical interfaces.
function Add-DrawioHostPhysical {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)]
        $Device,
        [parameter(Mandatory = $true)]
        [PSCustomObject]$Location
    )

    # --- Section 1: Identify Interfaces and Calculate Width ---
    $neighborAndStpInterfaces = @($Device.interfaces | Where-Object {
        (
            $_.HasCPDNieghbor -or
            $_.HasLLDPNeighbor -or
            ($_.STRole -eq 'Root' -or $_.STRole -eq 'ALT')
        ) -and ($_.interface -notmatch 'vlan|loopback|mgmt|port-channel' -and (-not $_.shutdown))
    })

    $macInterfacesToDraw = @()
    if ($GDrawPortsWithMacs -gt 0) {
        $macInterfacesToDraw = @($Device.interfaces | Where-Object {
            ($_.Interface -notin $neighborAndStpInterfaces.Interface) -and
            ($_.interface -notmatch 'vlan|loopback|mgmt|port-channel' -and (-not $_.shutdown)) -and
            ($_.MacAddressArray) -and
            (($_.MacAddressArray).Count -ge $GDrawPortsWithMacs)
        })
    }
    $allInterfaces = ($neighborAndStpInterfaces + $macInterfacesToDraw) | Sort-Object Interface
    $interfaceCount = $allInterfaces.Count
    $hostWidth = ($interfaceCount * $GDrawioPhysicalInterfaceWidth) + (($interfaceCount + 1) * $GDrawioEthernetSpacingPhysical)
    $hostWidth = [System.Math]::Max($hostWidth, 300)

    # --- Section 2: Construct Host Text with Smart Formatting ---
    $hostTextElements = [System.Collections.ArrayList]::new()
    if ($Device.Version -and $Device.Version.Hardware) {
        $hardwareInfo = if ($Device.Version.Hardware -is [array]) { $Device.Version.Hardware[0] } else { $Device.Version.Hardware }
        $null = $hostTextElements.Add($hardwareInfo)
    }

    $stText = if ($Device.SpanningTree) {
            $text = "$($Device.DeviceIdentifier) : $($Device.HostName) : $($Device.SpanningTree.SpanningTreeMode)"
            # =================================================================================
            # --- THIS IS THE FIX ---
            # If the VLAN list is very long, format it with line breaks for better wrapping.
            # =================================================================================
            if ($Device.SpanningTree.RootBridgeForVlans.count -gt 15) {
                # Add a line break and a bolded title for the long list
                $text += "<br><b>Root for VLANs:</b> " + (($Device.SpanningTree.RootBridgeForVlans) -join ', ')
            } elseif ($Device.SpanningTree.RootBridgeForVlans.count -gt 0) {
                # For shorter lists, append it on the same line.
                $text += " : Root for VLANs: " + (($Device.SpanningTree.RootBridgeForVlans) -join ', ')
            }
            $text
    } else { 
        "$($Device.DeviceIdentifier) : $($Device.HostName)" 
    }
    $null = $hostTextElements.Add($stText)
    $encodedHostText = [System.Web.HttpUtility]::HtmlEncode($hostTextElements -join '<br>')

    # --- Section 3: Dynamically Calculate Host and Group Height ---
    $hostHeight = $GDrawioHostPhysicalHeight
    
    # Estimate needed height based on the number of lines in the final text.
    # Each <br> is a line, and we estimate that every 60 characters of text will also need a new line.
    $lineBreaks = ([regex]::Matches($encodedHostText, '&lt;br&gt;')).Count
    $estimatedTextLines = [Math]::Ceiling($encodedHostText.Length / 60)
    $totalLines = $lineBreaks + $estimatedTextLines

    # Add 15px of height for each line beyond the default of 2.
    if ($totalLines -gt 2) {
        $hostHeight += ($totalLines - 2) * 15
    }

    $groupHeight = $hostHeight + $GDrawioPhysicalInterfaceHeight + 150

    # --- Section 4: Draw the Shapes with Dynamic Height ---
    $hostGroupId = "host-group-$((New-Guid).ToString().Substring(0,8))"
    $global:drawioXml += "        <mxCell id=`"$hostGroupId`" value=`"`" style=`"group`" vertex=`"1`" connectable=`"0`" parent=`"1`">
        <mxGeometry x=`"$($Location.X)`" y=`"$($Location.Y)`" width=`"$hostWidth`" height=`"$groupHeight`" as=`"geometry`" />
    </mxCell>`n"

    $hostStyle = "rounded=1;whiteSpace=wrap;html=1;fillColor=#D5E8D4;strokeColor=#82B366;fontSize=$($GDrawioHostFontSize);fontStyle=1;verticalAlign=top;spacingTop=4;"
    $hostId = "host-box-$((New-Guid).ToString().Substring(0,8))"
    $global:drawioXml += "        <mxCell id=`"$hostId`" value=`"$encodedHostText`" style=`"$hostStyle`" vertex=`"1`" parent=`"$hostGroupId`">
        <mxGeometry x=`"0`" y=`"0`" width=`"$hostWidth`" height=`"$hostHeight`" as=`"geometry`" />
    </mxCell>`n"

    # Loop through and draw each interface below the resized host box.
    $currentX = $GDrawioEthernetSpacingPhysical
    $interfaceY = $hostHeight # Interfaces are positioned relative to the new dynamic height

    foreach ($interface in $allInterfaces) {
        $interfaceLocation = [PSCustomObject]@{ X = $currentX; Y = $interfaceY }
        Add-DrawioPhysicalInterface -Interface $interface -Location $interfaceLocation -ParentId $hostGroupId -DrawType "neighbors"

        if ($macInterfacesToDraw.Interface -contains $interface.Interface) {
            $bubbleLocation = [PSCustomObject]@{ X = $currentX - 50; Y = $interfaceY + $GDrawioPhysicalInterfaceHeight + 10 }
            $bubbleId = Add-DrawioMacAddressBubble -Interface $interface -Location $bubbleLocation -ParentId $hostGroupId
            if ($interface.PhysicalDrawioId -and $bubbleId) {
                $connectorStyle = "endArrow=none;dashed=1;strokeColor=#666666;strokeWidth=1;"
                Add-DrawioConnector -SourceId $interface.PhysicalDrawioId -TargetId $bubbleId -Style $connectorStyle
            }
        }
        $currentX += $GDrawioPhysicalInterfaceWidth + $GDrawioEthernetSpacingPhysical
    }
    return $hostWidth
}















function Add-DrawioConnector {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)]
        [string]$SourceId,
        [parameter(Mandatory = $true)]
        [string]$TargetId,
        [string]$Style = "endArrow=none;html=1;strokeWidth=4;strokeColor=#6c8ebf;",
        [string]$Text = ""
    )
    $connectorId = "edge-$((New-Guid).ToString().Substring(0,12))"
    $encodedText = [System.Web.HttpUtility]::HtmlEncode($Text)

    # The XML for a connector must contain the nested mxPoint elements inside mxGeometry.
    $global:drawioXml += "        <mxCell id=`"$connectorId`" value=`"$encodedText`" style=`"$style`" edge=`"1`" parent=`"1`" source=`"$SourceId`" target=`"$TargetId`">
            <mxGeometry relative=`"1`" as=`"geometry`">
                <mxPoint as=`"sourcePoint`" />
                <mxPoint as=`"targetPoint`" />
            </mxGeometry>
        </mxCell>`n"

    return
}



# Creates the XML for a neighbor device (one without a config file). Replaces Draw-HostEthernet.
function Add-DrawioNeighborHost {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)]
        $Device,
        [parameter(Mandatory = $true)]
        [PSCustomObject]$Location,
        [string]$DrawType # "CDPNeighbor" or "LLDPNeighbor"
    )

    # 1. This function returns a map of its interface names to their generated Draw.io IDs
    $interfaceIdMap = @{}

    # 2. Filter and calculate dimensions
    $interfacesToDraw = $Device.interfaces
    $interfaceCount = $interfacesToDraw.Count
    $hostWidth = ($interfaceCount * $GDrawioPhysicalInterfaceWidth) + (($interfaceCount + 1) * $GDrawioEthernetSpacingPhysical)
    $hostWidth = [System.Math]::Max($hostWidth, 200)
    $hostHeight = $GDrawioHostPhysicalHeight + 20 # Extra height for more text

    # 3. Create the top-level group
    $hostGroupId = "host-group-$((New-Guid).ToString().Substring(0,8))"
    $global:drawioXml += "        <mxCell id=`"$hostGroupId`" value=`"`" style=`"group`" vertex=`"1`" connectable=`"0`" parent=`"1`">
            <mxGeometry x=`"$($Location.X)`" y=`"$($Location.Y)`" width=`"$hostWidth`" height=`"$($hostHeight + $GDrawioPhysicalInterfaceHeight + 20)`" as=`"geometry`" />
        </mxCell>`n"

    # 4. Create the main host box with appropriate styling
    $hostText = "<b>$($Device.HostName)</b><br>$($Device.Description)<br>$(($Device.ArrayOfIPAddresses | Out-String).Trim())"
    $encodedHostText = [System.Web.HttpUtility]::HtmlEncode($hostText)

    $hostStyle = "rounded=1;whiteSpace=wrap;html=1;fontSize=$($GDrawioHostFontSize);fontStyle=1;"
    if ($DrawType -eq "CDPNeighbor") {
        $hostStyle += "fillColor=#f5f5f5;strokeColor=#666666;" # Grey for CDP
    } else {
        $hostStyle += "fillColor=#fff9c4;strokeColor=#fbc02d;" # Yellow for LLDP
    }
    $hostId = "host-box-$((New-Guid).ToString().Substring(0,8))"

    $global:drawioXml += "        <mxCell id=`"$hostId`" value=`"$encodedHostText`" style=`"$hostStyle`" vertex=`"1`" parent=`"$hostGroupId`">
            <mxGeometry x=`"0`" y=`"0`" width=`"$hostWidth`" height=`"$hostHeight`" as=`"geometry`" />
        </mxCell>`n"

    # 5. Draw the interfaces for this neighbor host
    $currentX = $GDrawioEthernetSpacingPhysical
    $interfaceY = $hostHeight + 10

    foreach ($interface in $interfacesToDraw) {
        $interfaceLocation = [PSCustomObject]@{ X = $currentX; Y = $interfaceY }
        # The Add-DrawioPhysicalInterface function must be available in your script
        $interfaceId = Add-DrawioPhysicalInterface -Interface $interface -Location $interfaceLocation -ParentId $hostGroupId -DrawType "neighbors"
        $interfaceIdMap[$interface.Interface] = $interfaceId # Store the generated ID
        $currentX += $GDrawioPhysicalInterfaceWidth + $GDrawioEthernetSpacingPhysical
    }

    return 
}












# Creates the XML for a single logical (L3) interface. Replaces Draw-LogicalInterface.
function Add-DrawioLogicalInterface {
    [CmdletBinding()]
    param(
        [parameter(Mandatory=$true)] $Interface,
        [parameter(Mandatory=$true)] [PSCustomObject]$Location,
        [parameter(Mandatory=$true)] [string]$ParentId
    )

    # 1. Text Construction
    $textElements = [System.Collections.ArrayList]::new()
    $height = $GDrawioLogicalInterfaceHeight

    $ifaceName = if ($GDrawioShortenInterfacesNames) {
        $Interface.Interface -replace "Vlan", "vl" -replace "Loopback", "Lo"
    } else {
        $Interface.Interface
    }
    $null = $textElements.Add("<b>$ifaceName</b>")

    $ipAddress = if ($Interface.subnetmask) { "$($Interface.ipaddress)/$($Interface.subnetmask)" } else { $Interface.ipaddress }
    $null = $textElements.Add($ipAddress)

    if ($Interface.Description) { $null = $textElements.Add($Interface.Description) }
    if ($Interface.standbyip)   { $null = $textElements.Add("HSRP: $($Interface.standbyip)"); $height += $GDrawioVrfTextSizeExtension }
    if ($Interface.ClusterIP)   { $null = $textElements.Add("ClusterIP: $($Interface.ClusterIP)"); $height += $GDrawioVrfTextSizeExtension }

    # 2. Styling and Final Text
    $style = "rounded=1;whiteSpace=wrap;html=1;arcSize=20;align=center;verticalAlign=middle;fontSize=$($GDrawioLogicalInterfaceFontSize);"

    if ($Interface.shutdown -or ($Interface.IntStatus -like "*down*" -and $Interface.INTProtocolStatus -like "*down*")) {
        if ($interface.vrf) { $null = $textElements.Add("VRF: $($interface.vrf)") }
        $null = $textElements.Add("<b>SHUTDOWN</b>")
        $style += "fillColor=#FFCDD2;strokeColor=#B71C1C;fontColor=#B71C1C;" # Red for down
    } else {
        if ($interface.vrf) {
            $vrfColor = if ($Interface.VRFColor) { Convert-RgbToHex -RgbString $Interface.VRFColor } else { "#E1BEE7" } # Default purple for VRFs
            $style += "fillColor=$vrfColor;strokeColor=#6A1B9A;"
            $null = $textElements.Add("VRF: $($interface.vrf)")
            $height += $GDrawioVrfTextSizeExtension
        } else {
            $style += "fillColor=#FFFFFF;strokeColor=#424242;" # Default white
        }
    }

    # 3. Generate XML
    $interfaceId = "l3-iface-$((New-Guid).ToString().Substring(0,8))"
    $Interface.LogicalDrawioId = $interfaceId # Add the ID to the object
    $encodedText = [System.Web.HttpUtility]::HtmlEncode($textElements -join "<br>")

    $global:drawioXml += "        <mxCell id=`"$interfaceId`" value=`"$encodedText`" style=`"$style`" vertex=`"1`" parent=`"$ParentId`">
            <mxGeometry x=`"$($Location.X)`" y=`"$($Location.Y)`" width=`"$GDrawioLogicalInterfaceWidth`" height=`"$height`" as=`"geometry`" />
        </mxCell>`n"
}

# Creates the XML for a Layer 3 host and its logical interfaces. Replaces Draw-HostLayer3.
function Add-DrawioHostLayer3 {
    [CmdletBinding()]
    param(
        [parameter(Mandatory=$true)] $Device,
        [parameter(Mandatory=$true)] [PSCustomObject]$Location,
        [string]$HostType,
        [parameter(Mandatory=$true)]
        [string]$DiagramType
    )
    
    $interfacesToDraw = @()
      if ($HostType -eq "GatewayHost") {
        $interfacesToDraw = $Device.interfaces | Where-Object { $_.ipaddress } | Sort-Object vrf, interface
    }
    
    elseif ($DiagramType -eq "RoutesOnly") {
        # For 'RoutesOnly', only draw interfaces that have been explicitly marked.
        
        $interfacesToDraw = $Device.interfaces | Where-Object { $_.DrawOnRoutesOnlyDiagram } | Sort-Object vrf, interface

    } else {
        # For 'Normal' and 'LinksOnly' diagrams, draw all interfaces with an IP address.
        $interfacesToDraw = $Device.interfaces | Where-Object { $_.ipaddress } | Sort-Object vrf, interface
    }

    $interfaceCount = $interfacesToDraw.Count
    $hostWidth = ($interfaceCount * $GDrawioLogicalInterfaceWidth) + (($interfaceCount + 1) * $GDrawioEthernetSpacingLogical)
    $hostWidth = [System.Math]::Max($hostWidth, $GDrawioLayer3HostFormWidth)
    $hostGroupId = "l3-host-group-$((New-Guid).ToString().Substring(0,8))"
    $global:drawioXml += "        <mxCell id=`"$hostGroupId`" value=`"`" style=`"group`" vertex=`"1`" connectable=`"0`" parent=`"1`">
        <mxGeometry x=`"$($Location.X)`" y=`"$($Location.Y)`" width=`"$hostWidth`" height=`"$($GDrawioLayer3HostFormHeight + $GDrawioLogicalInterfaceHeight + 40)`" as=`"geometry`" />
    </mxCell>`n"
    $hostStyle = "rounded=1;whiteSpace=wrap;html=1;fontSize=$($GCDPHostFontSize);fontStyle=1;strokeWidth=2;"
    if ($HostType -eq "GatewayHost") {
        $hostText = "<b>$($Device.HostName)</b>"
        $hostStyle += "fillColor=$(Convert-RgbToHex -RgbString $Layer3ARPHostColour);"
    } else {
        $hostText = "<b>$($Device.DeviceIdentifier)</b><br>$($Device.HostName)"
        $hostStyle += "fillColor=$(Convert-RgbToHex -RgbString $Layer3HostColour);"
    }
    $encodedHostText = [System.Web.HttpUtility]::HtmlEncode($hostText)
    $hostId = "l3-host-box-$((New-Guid).ToString().Substring(0,8))"
    $global:drawioXml += "        <mxCell id=`"$hostId`" value=`"$encodedHostText`" style=`"$hostStyle`" vertex=`"1`" parent=`"$hostGroupId`">
        <mxGeometry x=`"0`" y=`"0`" width=`"$hostWidth`" height=`"$GDrawioLayer3HostFormHeight`" as=`"geometry`" />
    </mxCell>`n"
    if ($HostType -eq "GatewayHost") {
        $iconId = "icon-$((New-Guid).ToString().Substring(0,8))"
        $iconStyle = "shape=mxgraph.cisco.routers.router;fillColor=#FFFFFF;strokeColor=none;"
        $global:drawioXml += "        <mxCell id=`"$iconId`" value=`"`" style=`"$iconStyle`" vertex=`"1`" parent=`"$hostGroupId`">
            <mxGeometry x=`"10`" y=`"-20`" width=`"50`" height=`"35`" as=`"geometry`" />
        </mxCell>`n"
    }
    $currentX = $GDrawioEthernetSpacingLogical
    $interfaceY = $GDrawioLayer3HostFormHeight -10
    foreach ($interface in $interfacesToDraw) {
        $interfaceLocation = [PSCustomObject]@{ X = $currentX; Y = $interfaceY }
        Add-DrawioLogicalInterface -Interface $interface -Location $interfaceLocation -ParentId $hostGroupId
        $currentX += $GDrawioLogicalInterfaceWidth + $GDrawioEthernetSpacingLogical
    }
    return $hostWidth
}


# Updated to use 'LogicalDrawioId'
# Updated to draw a rectangle with square edges instead of a line.
function Add-DrawioNetworkSegment {
    [CmdletBinding()]
    param(
        [parameter(Mandatory=$true)] $Network,
        [parameter(Mandatory=$true)] [PSCustomObject]$Location
    )
    $text = "$($network.RoutedVlan) - $($network.NetworkName) ($($network.cidr))"
    $encodedText = [System.Web.HttpUtility]::HtmlEncode($text)

    # --- CHANGE: Updated style for a square-edged rectangle ---
    $style = "rounded=0;whiteSpace=wrap;html=1;align=center;verticalAlign=middle;fontSize=11;strokeWidth=2;"
    # Use the network color for the fill, with a dark border
    $style += "fillColor=$(Convert-RgbToHex -RgbString $network.color);strokeColor=#424242;"

    $networkId = "net-$((New-Guid).ToString().Substring(0,8))"
    $Network.LogicalDrawioId = $networkId # Set the ID on the object

    $global:drawioXml += "        <mxCell id=`"$networkId`" value=`"$encodedText`" style=`"$style`" vertex=`"1`" parent=`"1`">
            <mxGeometry x=`"$($Location.X)`" y=`"$($Location.Y)`" width=`"$GDrawioVlanWidth`" height=`"$GDrawioVlanHeight`" as=`"geometry`" />
        </mxCell>`n"
    return $networkId
}

# Draws the informational bubble with ARP entry details.
# Updated with correct height calculation based on line count and added debug output.
function Add-DrawioArpBubble {
    [CmdletBinding()]
    param(
        [parameter(Mandatory=$true)] $Network,
        [parameter(Mandatory=$true)] [PSCustomObject]$Location
    )
    $textElements = [System.Collections.ArrayList]::new()
    $null = $textElements.Add("<b>$($network.NetworkName) ($($network.RoutedVlan))</b>")

    if ($GDrawAprEntriesDetails) {
        $null = $textElements.Add("<b>IP Address | MAC | Vendor</b>")
        foreach($entry in ($network.ARPEntries | Sort-Object VendorCompanyName)) {
            $null = $textElements.Add("$($Entry.ipaddress) | $($Entry.mac) | $($Entry.VendorCompanyName)")
        }
    } else {
        $summary = $network.ARPEntries | Group-Object VendorCompanyName | Select-Object Count, Name | Sort-Object Count -Descending | ForEach-Object { "$($_.Name) ($($_.Count))" }
        # The summary itself can contain multiple lines, so we add them correctly.
        $null = $textElements.Add($summary -join "<br>")
    }
    
    $finalText = $textElements -join "<br>"
    $encodedText = [System.Web.HttpUtility]::HtmlEncode($finalText)
    $style = "shape=cloud;whiteSpace=wrap;html=1;align=center;verticalAlign=middle;fontSize=9;"
    $style += "fillColor=$(Convert-RgbToHex -RgbString $network.color);gradientColor=#FFFFFF;strokeColor=#424242;strokeWidth=1;"
    
    # We split the final text by the <br> tag to get an accurate line count.
    $lineCount = ($finalText -split '<br>').Count
    $height = 60 + ($lineCount * 15) # Base height + 15px per line


    $bubbleId = "arp-$((New-Guid).ToString().Substring(0,8))"
    $global:drawioXml += "        <mxCell id=`"$bubbleId`" value=`"$encodedText`" style=`"$style`" vertex=`"1`" parent=`"1`">
            <mxGeometry x=`"$($Location.X)`" y=`"$($Location.Y)`" width=`"$GDrawioArpWidth`" height=`"$height`" as=`"geometry`" />
        </mxCell>`n"
    return $bubbleId
}




# Draws a bubble shape summarizing MAC address vendors for a given interface.
function Add-DrawioMacAddressBubble {
    [CmdletBinding()]
    param(
        [parameter(Mandatory=$true)]
        $Interface,
        [parameter(Mandatory=$true)]
        [PSCustomObject]$Location,
        [parameter(Mandatory=$true)]
        [string]$ParentId
    )

    # 1. Generate the summary text from the interface's MAC address array.
    $textElements = [System.Collections.ArrayList]::new()
    $null = $textElements.Add("<b>MAC Summary for $($Interface.Interface)</b>")

    $summary = $Interface.MacAddressArray |
        Group-Object VendorCompanyName |
        Select-Object Count, Name |
        Sort-Object Count -Descending |
        ForEach-Object { "$($_.Name) ($($_.Count))" }

    if ($summary) {
        # AddRange expects a collection, not an array of strings as individual items
        foreach ($item in $summary) {
            $null = $textElements.Add($item)
        }
    }

    $finalText = $textElements -join "<br>"
    $encodedText = [System.Web.HttpUtility]::HtmlEncode($finalText)

    # 2. Define the style for the bubble.
    $style = "shape=cloud;whiteSpace=wrap;html=1;align=center;verticalAlign=middle;fontSize=9;padding=5;"
    $style += "fillColor=#f5f5f5;strokeColor=#666666;shadow=1;"

    # 3. Calculate bubble dimensions based on text length.
    $width = 180
    $lineCount = ($finalText -split '<br>').Count
    $height = 30 + ($lineCount * 12)

    # 4. Generate the XML for the bubble.
    $bubbleId = "mac-bubble-$((New-Guid).ToString().Substring(0,8))"
    $global:drawioXml += "        <mxCell id=`"$bubbleId`" value=`"$encodedText`" style=`"$style`" vertex=`"1`" parent=`"$ParentId`">
            <mxGeometry x=`"$($Location.X)`" y=`"$($Location.Y)`" width=`"$width`" height=`"$height`" as=`"geometry`" />
        </mxCell>`n"

    return $bubbleId
}
