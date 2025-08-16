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


# This function creates a visual legend on the diagram to explain the meaning of different interface colors and styles.
function Add-DrawioInterfaceLegend {
    [CmdletBinding()]
    param (
        # A PSCustomObject with .X and .Y properties defining the top-left corner of the legend box.
        [parameter(Mandatory = $true)]
        [PSCustomObject]$Location,
        # The title to be displayed at the top of the legend.
        [string]$Title = "Interface Legend"
    )

    # --- Configuration for the legend box ---
    # Define layout constants for spacing and sizing.
    $lineHeight = 25; $padding = 15; $boxWidth = 300
    # Calculate the total height needed for the content based on the number of interface types.
    $contentHeight = ($GArrayOfInterfaceTypes.Count + 2) * $lineHeight
    # The final box height includes padding.
    $boxHeight = $contentHeight + (2 * $padding)
    # --- Create the main group to hold all legend parts ---
    # A group allows all elements of the legend to be moved together in the Draw.io editor.
    $legendGroupId = "legend-group-$((New-Guid).ToString().Substring(0,8))"
    $global:drawioXml += "        <mxCell id=`"$legendGroupId`" value=`"`" style=`"group`" vertex=`"1`" connectable=`"0`" parent=`"1`">`n            <mxGeometry x=`"$($Location.X)`" y=`"$($Location.Y)`" width=`"$boxWidth`" height=`"$boxHeight`" as=`"geometry`" />`n        </mxCell>`n"
    # --- Create the background rectangle for the legend ---
    $backgroundId = "legend-bg-$((New-Guid).ToString().Substring(0,8))"
    # This cell is the visible box with a white fill and shadow effect. It is a child of the group cell.
    $global:drawioXml += "        <mxCell id=`"$backgroundId`" value=`"`" style=`"rounded=1;whiteSpace=wrap;html=1;fillColor=#ffffff;strokeColor=#36393d;shadow=1;`" vertex=`"1`" parent=`"$legendGroupId`">`n            <mxGeometry width=`"$boxWidth`" height=`"$boxHeight`" as=`"geometry`" />`n        </mxCell>`n"
    # --- Add Title and Header ---
    $currentY = $padding; $titleId = "legend-title-$((New-Guid).ToString().Substring(0,8))"; $headerId = "legend-header-$((New-Guid).ToString().Substring(0,8))"
    # HTML-encode the title text to ensure it's valid XML.
    $titleValue = [System.Web.HttpUtility]::HtmlEncode("<div style=`"font-size: 14px; font-weight: bold;`">$Title</div>")
    $global:drawioXml += "        <mxCell id=`"$titleId`" value=`"$titleValue`" style=`"text;html=1;align=center;verticalAlign=middle;resizable=0;points=[];`" vertex=`"1`" parent=`"$legendGroupId`">`n            <mxGeometry y=`"$currentY`" width=`"$boxWidth`" height=`"20`" as=`"geometry`" />`n        </mxCell>`n"
    # Move the Y-coordinate down for the next element.
    $currentY += $lineHeight
    # Create the column header text.
    $headerValue = [System.Web.HttpUtility]::HtmlEncode("<b>Color&nbsp;&nbsp;&nbsp;&nbsp;|&nbsp;&nbsp;&nbsp;&nbsp;Interface Cisco Type Name</b>")
    $global:drawioXml += "        <mxCell id=`"$headerId`" value=`"$headerValue`" style=`"text;html=1;align=left;verticalAlign=middle;resizable=0;points=[];`" vertex=`"1`" parent=`"$legendGroupId`">`n            <mxGeometry x=`"$padding`" y=`"$currentY`" width=`"$boxWidth`" height=`"20`" as=`"geometry`" />`n        </mxCell>`n"
    $currentY += $lineHeight
    # --- Loop through interface types and create entries ---
    # Iterate through a global array containing the definitions for each interface type (e.g., RJ45, Fibre).
    foreach ($legendLine in $GDrawioArrayOfInterfaceTypes) {
        # Deconstruct the array into named variables for clarity.
        $interfaceFamily = $legendLine[0]; $interfaceName = $legendLine[1]; $fillColorRgb = $legendLine[2]; $fillColorHex = Convert-RgbToHex -RgbString $fillColorRgb
        $strokeColor = "#000000"; $strokeWidth = 1
        # Apply special border styles for certain interface families to indicate media type.
        if ($interfaceFamily -eq "RJ45-SFP") { $strokeWidth = $GDrawioInterfaceLegend_LineWidth; $strokeColor = $GDrawioInterfaceLegend_LineColorSFP_RJ45 }
        elseif ($interfaceFamily -eq "Fibre") { $strokeWidth = $GDrawioInterfaceLegend_LineWidth; $strokeColor = $GDrawioInterfaceLegend_LineColorSFP }
        # Create the small colored rectangle (the "swatch").
        $swatchId = "swatch-$((New-Guid).ToString().Substring(0,8))"; $swatchStyle = "rounded=0;whiteSpace=wrap;html=1;fillColor=$fillColorHex;strokeColor=$strokeColor;strokeWidth=$strokeWidth;"
        $global:drawioXml += "        <mxCell id=`"$swatchId`" value=`"`" style=`"$swatchStyle`" vertex=`"1`" parent=`"$legendGroupId`">`n            <mxGeometry x=`"$padding`" y=`"$currentY`" width=`"$GDrawioInterfaceLegend_SwatchWidth`" height=`"$GDrawioInterfaceLegend_SwatchHeight`" as=`"geometry`" />`n        </mxCell>`n"
        # Create the text label next to the color swatch.
        $labelId = "label-$((New-Guid).ToString().Substring(0,8))"; $labelValue = [System.Web.HttpUtility]::HtmlEncode($interfaceName); $labelX = $padding + $GDrawioInterfaceLegend_SwatchWidth + 10
        $global:drawioXml += "        <mxCell id=`"$labelId`" value=`"$labelValue`" style=`"text;html=1;align=left;verticalAlign=middle;resizable=0;points=[];`" vertex=`"1`" parent=`"$legendGroupId`">`n            <mxGeometry x=`"$labelX`" y=`"$currentY`" width=`"220`" height=`"$GDrawioInterfaceLegend_SwatchHeight`" as=`"geometry`" />`n        </mxCell>`n"
        # Move Y-coordinate down for the next legend entry.
        $currentY += $lineHeight
    }
}


# Helper function to prevent errors with malformed RGB strings.
# Converts a string like "rgb(213, 232, 212)" into a hex code like "#D5E8D4".
function Convert-RgbToHex {
    param([string]$RgbString)
    # Use regex to extract all sequences of digits from the input string.
    $matches = [regex]::Matches($RgbString, '\d+')
    # If we found at least 3 numbers (for Red, Green, and Blue).
    if ($matches.Count -ge 3) {
        # Format each number as a 2-character hexadecimal string (e.g., 255 becomes "FF").
        $r = "{0:X2}" -f [int]$matches[0].Value
        $g = "{0:X2}" -f [int]$matches[1].Value
        $b = "{0:X2}" -f [int]$matches[2].Value
        # Combine them into a standard HTML hex color code.
        return "#$r$g$b"
    }
    # If the input string was not a valid RGB format, return white as a safe default.
    return "#FFFFFF" # Return white on error
}


# ENHANCED VERSION - A more faithful port of the original Visio function.
# This function draws a single physical interface shape.
function Add-DrawioPhysicalInterface {
    [CmdletBinding()]
    param(
        # The interface object, containing all its properties (name, description, VLANs, etc.).
        [parameter(Mandatory = $true)]
        $Interface,
        # A PSCustomObject with .X and .Y coordinates, relative to the parent host.
        [parameter(Mandatory = $true)]
        [PSCustomObject]$Location,
        # The Draw.io ID of the parent shape (usually a host group).
        [parameter(Mandatory = $true)]
        [string]$ParentId,
        # The context in which this interface is being drawn (e.g., "neighbors").
        $DrawType
    )

    # =================================================
    # 1. Text Construction
    # =================================================
    # Use an ArrayList to dynamically build the lines of text that will appear in the shape.
    $textElements = [System.Collections.ArrayList]::new()

    # Add the interface name, optionally shortening it (e.g., "GigabitEthernet" -> "Gi").
    if ($GDrawioShortenInterfacesNames) {
        $ifaceName = $Interface.Interface -replace "GigabitEthernet", "Gi" -replace "TenGigabitEthernet", "Te" -replace "FastEthernet", "Fa"
        $null = $textElements.Add("<b>$ifaceName</b>")
    }
    else {
        $null = $textElements.Add("<b>$($Interface.Interface)</b>")
    }
    # Add the description if it exists.
    if ($Interface.Description) { $null = $textElements.Add($Interface.Description) }

    # --- START OF CHANGES ---
    # Add switchport mode and VLAN information.
    if ($Interface.SwitchportMode -like "trunk") {
        # CHANGE 1a: Added a replace to add spaces to the VLAN list for better text wrapping.
        $vlans = if ($Interface.SwitchportTrunkVlan) { $Interface.SwitchportTrunkVlan -replace ',', ', ' } else { "all" }
        $null = $textElements.Add("Trunk VLANs: $vlans")
    }
    elseif ($Interface.SwitchportMode -eq "Probably Trunk mode") {
        # CHANGE 1b: Added a replace to add spaces to the VLAN list for better text wrapping.
        $vlans = if ($Interface.SwitchportTrunkVlan) { $Interface.SwitchportTrunkVlan -replace ',', ', ' } else { "all" }
        $null = $textElements.Add("Probable Trunk: $vlans")
    }
    elseif ($Interface.SwitchportMode -eq "access") {
        $null = $textElements.Add("Access VLAN: $($Interface.SwitchportAccessVlan)")
    }
    elseif ($Interface.SwitchPortType -eq "Routed") {
        $null = $textElements.Add("Routed Port: $($Interface.ipaddress)/$($Interface.subnetmask)")
    }
    else {
        $null = $textElements.Add("No L2/L3 config found.")
    }
    # Add Port-Channel information if the interface is part of an etherchannel.
    if ($Interface.ChannelGroup) {
        if ($interface.ChannelGroup -like "*ae*") {
            # Handle Juniper's "aggregated ethernet" naming.
            $null = $textElements.Add($Interface.ChannelGroup)
        }
        else {
            $null = $textElements.Add("Port-Channel $($Interface.ChannelGroup)")
        }
    }

    # =================================================
    # 2. Geometry & Spanning Tree Adjustments
    # =================================================
    $currentX = $Location.X
    $currentY = $Location.Y

    # Add Spanning Tree status information to the text.
    if ($DrawType -eq "neighbors") {
        if ($Interface.STRootInterfaceForVlans -or $Interface.STRole -eq "Root") {
            $null = $textElements.Add("STP Root Port")
        }
        if ($Interface.STALTnInterfaceForVlans -or $Interface.STRole -eq "ALT") {
            $null = $textElements.Add("STP ALTN Port")
        }
    }
    # Add a specific note if the port is in a blocking state.
    if ($Interface.STState -eq "BLK") {
        $null = $textElements.Add("STP Blocked Port")
    }

    # CHANGE 2: Calculate height dynamically *after* all text elements have been added.
    # Start with the base height defined in global variables.
    $currentHeight = $GDrawioPhysicalInterfaceHeight
    # Estimate the number of lines required based on the text elements added.
    $estimatedLines = 0
    foreach ($line in $textElements) {
        # Each element is at least one line. Add extra for long lines that will wrap (approximating wrap at 40 chars).
        $estimatedLines += [Math]::Max(1, [Math]::Ceiling($line.ToString().Length / 40.0))
    }
    # Add 15 pixels of height for each line beyond the default of 3 lines.
    if ($estimatedLines -gt 3) {
        $currentHeight += ($estimatedLines - 3) * 15
    }

    # Now, apply original STP geometry adjustments to the new dynamic height.
    # These adjustments make STP root/alt ports taller and shifts them up to visually stand out.
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

    # Convert the array of text lines into a single HTML string with <br> tags.
    $finalText = $textElements -join "<br>"
    $encodedText = [System.Web.HttpUtility]::HtmlEncode($finalText)

    # =================================================
    # 3. Styling (Fill, Font, and Border)
    # =================================================
    # Start with a base style string for a rounded rectangle.
    $style = "rounded=1;whiteSpace=wrap;html=1;arcSize=10;align=center;verticalAlign=middle;fontSize=$($GDrawioPhysicalInterfaceFontSize);"
    $fontColor = "#000000" # Default to black text

    # Find the media type (e.g., RJ45, Fibre) from a global array to determine the fill color.
    $mediaType = $GDrawioArrayOfInterfaceTypes | Where-Object { $_[1] -eq $Interface.MediaType } | Select-Object -First 1
    if ($mediaType) {
        $style += "fillColor=$(Convert-RgbToHex -RgbString $mediaType[2]);"
        # If the background is dark (like for copper ports), switch to white text for contrast.
        if ($mediaType[0] -eq "RJ45" -or $mediaType[0] -eq "RJ45-SFP") {
            $fontColor = "#FFFFFF"
            $style += "gradientColor=#646464;" # Use gradient as a substitute for Visio's fill patterns
        }
    }
    else {
        # Apply a default color if media type is unknown.
        $style += "fillColor=$GDrawioDefaultInterfacesColor;"
    }

    # Override fill color if the port is administratively or operationally down. This style has the highest priority.
    if ($Interface.shutdown -or ($Interface.IntStatus -like "*down*")) {
        $style += "fillColor=#FF9999;" # Light red for down ports
        $fontColor = "#000000" # Ensure text is black on the light red background
    }
    # Add the final font color to the style string.
    $style += "fontColor=$fontColor;"

    # Set the border style based on Port-Channel membership.
    if ($Interface.ChannelGroup) {
        # Extract the channel number (e.g., from "Port-channel12").
        $channelNumber = $Interface.ChannelGroup -replace '\D', ''
        # Get a consistent, cached style (color/width) for this channel number.
        $styleObject = Get-OrSet-PortChannelStyle -channelNumber $channelNumber
        # Apply the style to the interface's border.
        $style += "strokeColor=$($styleObject.strokeColor);strokeWidth=$($styleObject.strokeWidth);"
    }
    else {
        # If not in a Port-Channel, use a standard thin black border.
        $style += "strokeColor=#000000;strokeWidth=1;"
    }

    # =================================================
    # 4. Generate XML
    # =================================================
    # Generate a unique ID for this interface shape.
    $interfaceId = "iface-$((New-Guid).ToString().Substring(0,8))"
    # Store the generated ID back onto the PowerShell object for later reference (e.g., for drawing connectors).
    $Interface.PhysicalDrawioId = $interfaceId
    # Append the final XML for the interface cell to the global XML string.
    $global:drawioXml += "        <mxCell id=`"$interfaceId`" value=`"$encodedText`" style=`"$style`" vertex=`"1`" parent=`"$ParentId`">`n            <mxGeometry x=`"$currentX`" y=`"$currentY`" width=`"$GDrawioPhysicalInterfaceWidth`" height=`"$currentHeight`" as=`"geometry`" />`n        </mxCell>`n"

    # Add a visual "X" overlay if the port is in an STP blocking state.
    if ($DrawType -eq "neighbors" -and $Interface.STState -eq "BLK") {
        $crossId = "cross-$((New-Guid).ToString().Substring(0,8))"
        $crossStyle = "shape=mxgraph.basic.cross;strokeColor=#D32F2F;strokeWidth=3;rotation=20;"
        # This cross shape is a child of the interface shape and is positioned relatively within it.
        $global:drawioXml += "        <mxCell id=`"$crossId`" value=`"`" style=`"$crossStyle`" vertex=`"1`" parent=`"$interfaceId`">`n             <mxGeometry x=`"0.25`" y=`"0.25`" width=`"10`" height=`"10`" relative=`"1`" as=`"geometry`" />`n        </mxCell>`n"
    }
    return $interfaceId
}

# Creates the XML for a host (from a config file) and all its physical interfaces.
function Add-DrawioHostPhysical {
    [CmdletBinding()]
    param(
        # The full device object, containing its properties and a list of all its interfaces.
        [parameter(Mandatory = $true)]
        $Device,
        # A PSCustomObject with .X and .Y for the top-left corner of the entire host group.
        [parameter(Mandatory = $true)]
        [PSCustomObject]$Location
    )

    # --- Section 1: Identify Interfaces to Draw and Calculate Total Width ---
    # First, select high-priority interfaces: those with CDP/LLDP neighbors or important STP roles.
    # Exclude non-physical interfaces and those that are shutdown.
    $neighborAndStpInterfaces = @($Device.interfaces | Where-Object {
        (
            $_.HasCPDNieghbor -or
            $_.HasLLDPNeighbor -or
            ($_.STRole -eq 'Root' -or $_.STRole -eq 'ALT')
        # --- START MODIFICATION ---
        # Added 'ae' to the regex to prevent aggregate interfaces from being drawn as physical ports.
        ) -and ($_.interface -notmatch 'vlan|loopback|mgmt|port-channel|ae' -and (-not $_.shutdown))
        # --- END MODIFICATION ---
    })

    # Optionally, also select interfaces that have a significant number of MAC addresses learned.
    $macInterfacesToDraw = @()
    if ($GDrawPortsWithMacs -gt 0) {
        $macInterfacesToDraw = @($Device.interfaces | Where-Object {
            # Ensure we don't re-select interfaces already chosen above.
            ($_.Interface -notin $neighborAndStpInterfaces.Interface) -and
            # --- START MODIFICATION ---
            # Added 'ae' to this regex as well for consistency.
            ($_.interface -notmatch 'vlan|loopback|mgmt|port-channel|ae' -and (-not $_.shutdown)) -and
            # --- END MODIFICATION ---
            # Check if the MAC address count meets the global threshold.
            ($_.MacAddressArray) -and
            (($_.MacAddressArray).Count -ge $GDrawPortsWithMacs)
        })
    }
    # Combine the lists and sort them by interface name for a consistent layout.
    $allInterfaces = ($neighborAndStpInterfaces + $macInterfacesToDraw) | Sort-Object Interface
    # Calculate the total width needed for the host box based on the number of interfaces and spacing.
    $hostWidth = ($allInterfaces.Count * $GDrawioPhysicalInterfaceWidth) + (($allInterfaces.Count + 1) * $GDrawioEthernetSpacingPhysical)
    # Ensure the host has a minimum width.
    $hostWidth = [System.Math]::Max($hostWidth, 300)

    # --- Section 2: Construct Host Text with Smart Formatting ---
    $hostTextElements = [System.Collections.ArrayList]::new()
    # Add hardware model information if available.
    if ($Device.Version -and $Device.Version.Hardware) {
        # Handle cases where hardware info might be an array.
        $hardwareInfo = if ($Device.Version.Hardware -is [array]) { $Device.Version.Hardware[0] } else { $Device.Version.Hardware }
        $null = $hostTextElements.Add($hardwareInfo)
    }
    # Build the main text line including hostname and Spanning Tree mode.
    $stText = if ($Device.SpanningTree) {
        $text = "$($Device.DeviceIdentifier) : $($Device.HostName) : $($Device.SpanningTree.SpanningTreeMode)"
        # --- THIS IS THE FIX ---
        # If the list of VLANs for which this device is root is very long, format it with line breaks for better readability.
        if ($Device.SpanningTree.RootBridgeForVlans.count -gt 15) {
            # Add a line break and a bolded title for the long list.
            $text += "<br><b>Root for VLANs:</b> " + (($Device.SpanningTree.RootBridgeForVlans) -join ', ')
        }
        elseif ($Device.SpanningTree.RootBridgeForVlans.count -gt 0) {
            # For shorter lists, append it on the same line.
            $text += " : Root for VLANs: " + (($Device.SpanningTree.RootBridgeForVlans) -join ', ')
        }
        $text
    }
    else {
        "$($Device.DeviceIdentifier) : $($Device.HostName)"
    }
    $null = $hostTextElements.Add($stText)
    # Combine all text elements and HTML-encode the result.
    $encodedHostText = [System.Web.HttpUtility]::HtmlEncode($hostTextElements -join '<br>')

    # --- Section 3: Dynamically Calculate Host and Group Height ---
    $hostHeight = $GDrawioHostPhysicalHeight

    # Estimate needed height based on the number of lines in the final text.
    # Count explicit line breaks (<br>) and also estimate breaks from text wrapping.
    $lineBreaks = ([regex]::Matches($encodedHostText, '&lt;br&gt;')).Count
    $estimatedTextLines = [Math]::Ceiling($encodedHostText.Length / 60) # Approx 60 chars per line.
    $totalLines = $lineBreaks + $estimatedTextLines

    # Add 15px of height for each line beyond the default of 2.
    if ($totalLines -gt 2) {
        $hostHeight += ($totalLines - 2) * 15
    }
    # The total group height must accommodate the host box and the interface boxes below it.
    $groupHeight = $hostHeight + $GDrawioPhysicalInterfaceHeight + 150

    # --- Section 4: Draw the Shapes with Dynamic Height ---
    # Create the main group cell that will contain the host and all its interfaces.
    $hostGroupId = "host-group-$((New-Guid).ToString().Substring(0,8))"
    $global:drawioXml += "        <mxCell id=`"$hostGroupId`" value=`"`" style=`"group`" vertex=`"1`" connectable=`"0`" parent=`"1`">
        <mxGeometry x=`"$($Location.X)`" y=`"$($Location.Y)`" width=`"$hostWidth`" height=`"$groupHeight`" as=`"geometry`" />
    </mxCell>`n"
    # Create the visible host box itself, with a green color scheme.
    $hostStyle = "rounded=1;whiteSpace=wrap;html=1;fillColor=#D5E8D4;strokeColor=#82B366;fontSize=$($GDrawioHostFontSize);fontStyle=1;verticalAlign=top;spacingTop=4;"
    $hostId = "host-box-$((New-Guid).ToString().Substring(0,8))"
    $global:drawioXml += "        <mxCell id=`"$hostId`" value=`"$encodedHostText`" style=`"$hostStyle`" vertex=`"1`" parent=`"$hostGroupId`">
        <mxGeometry x=`"0`" y=`"0`" width=`"$hostWidth`" height=`"$hostHeight`" as=`"geometry`" />
    </mxCell>`n"

    # Loop through and draw each interface below the dynamically resized host box.
    $currentX = $GDrawioEthernetSpacingPhysical
    $interfaceY = $hostHeight # Interfaces are positioned relative to the new dynamic height of the host box.

    foreach ($interface in $allInterfaces) {
        $interfaceLocation = [PSCustomObject]@{ X = $currentX; Y = $interfaceY }
        # Call the dedicated function to draw the interface shape.
        $null = Add-DrawioPhysicalInterface -Interface $interface -Location $interfaceLocation -ParentId $hostGroupId -DrawType "neighbors"

        # If this interface was drawn because of its MAC address count...
        if ($macInterfacesToDraw.Interface -contains $interface.Interface) {
            # ...then draw a summary bubble for those MAC addresses.
            $bubbleLocation = [PSCustomObject]@{ X = $currentX - 50; Y = $interfaceY + $GDrawioPhysicalInterfaceHeight + 10 }
            $bubbleId = Add-DrawioMacAddressBubble -Interface $interface -Location $bubbleLocation -ParentId $hostGroupId
            # And connect the interface to its bubble with a dashed line.
            if ($interface.PhysicalDrawioId -and $bubbleId) {
                $connectorStyle = "endArrow=none;dashed=1;strokeColor=#666666;strokeWidth=1;"
                Add-DrawioConnector -SourceId $interface.PhysicalDrawioId -TargetId $bubbleId -Style $connectorStyle
            }
        }
        # Increment the X position for the next interface.
        $currentX += $GDrawioPhysicalInterfaceWidth + $GDrawioEthernetSpacingPhysical
    }
    # Return the calculated width so the main script can position the next host correctly.
    return $hostWidth
}















# This function creates the XML for a connector (an edge or line) between two shapes.
function Add-DrawioConnector {
    [CmdletBinding()]
    param(
        # The unique ID of the source shape.
        [parameter(Mandatory = $true)]
        [string]$SourceId,
        # The unique ID of the target shape.
        [parameter(Mandatory = $true)]
        [string]$TargetId,
        # A string defining the connector's appearance (color, thickness, arrows, etc.).
        [string]$Style = "endArrow=none;html=1;strokeWidth=4;strokeColor=#6c8ebf;",
        # Optional text to display as a label on the connector.
        [string]$Text = ""
    )
    # Generate a unique ID for the connector itself.
    $connectorId = "edge-$((New-Guid).ToString().Substring(0,12))"
    # HTML-encode the text to ensure it's valid within the XML value attribute.
    $encodedText = [System.Web.HttpUtility]::HtmlEncode($Text)

    # The XML for a connector must have edge="1" and specify source and target IDs.
    # It also requires a nested <mxGeometry> element with <mxPoint> children.
    $global:drawioXml += "        <mxCell id=`"$connectorId`" value=`"$encodedText`" style=`"$style`" edge=`"1`" parent=`"1`" source=`"$SourceId`" target=`"$TargetId`">
            <mxGeometry relative=`"1`" as=`"geometry`">
                <mxPoint as=`"sourcePoint`" />
                <mxPoint as=`"targetPoint`" />
            </mxGeometry>
        </mxCell>`n"

    return
}



# Creates the XML for a neighbor device (one discovered via CDP/LLDP, without a local config file).
function Add-DrawioNeighborHost {
    [CmdletBinding()]
    param(
        # The device object for the neighbor.
        [parameter(Mandatory = $true)]
        $Device,
        # The top-left coordinates for the neighbor host group.
        [parameter(Mandatory = $true)]
        [PSCustomObject]$Location,
        # Specifies the discovery protocol: "CDPNeighbor" or "LLDPNeighbor".
        [string]$DrawType
    )

    # 1. This function could return a map of interface names to their IDs, but it's not currently used.
    $interfaceIdMap = @{}

    # 2. Filter interfaces and calculate dimensions for the host box.
    $interfacesToDraw = $Device.interfaces
    $interfaceCount = $interfacesToDraw.Count
    # Calculate width based on the number of interfaces to be drawn.
    $hostWidth = ($interfaceCount * $GDrawioPhysicalInterfaceWidth) + (($interfaceCount + 1) * $GDrawioEthernetSpacingPhysical)
    $hostWidth = [System.Math]::Max($hostWidth, 200) # Enforce a minimum width.
    $hostHeight = $GDrawioHostPhysicalHeight + 20 # Add extra height for more text compared to a configured host.

    # 3. Create the top-level group to contain the host box and its interfaces.
    $hostGroupId = "host-group-$((New-Guid).ToString().Substring(0,8))"
    $global:drawioXml += "        <mxCell id=`"$hostGroupId`" value=`"`" style=`"group`" vertex=`"1`" connectable=`"0`" parent=`"1`">
            <mxGeometry x=`"$($Location.X)`" y=`"$($Location.Y)`" width=`"$hostWidth`" height=`"$($hostHeight + $GDrawioPhysicalInterfaceHeight + 20)`" as=`"geometry`" />
        </mxCell>`n"

    # 4. Create the main host box with text and appropriate styling based on discovery protocol.
    # Combine hostname, description (platform), and IP addresses into a single text block.
    $hostText = "<b>$($Device.HostName)</b><br>$($Device.Description)<br>$(($Device.ArrayOfIPAddresses | Out-String).Trim())"
    $encodedHostText = [System.Web.HttpUtility]::HtmlEncode($hostText)

    $hostStyle = "rounded=1;whiteSpace=wrap;html=1;fontSize=$($GDrawioHostFontSize);fontStyle=1;"
    if ($DrawType -eq "CDPNeighbor") {
        $hostStyle += "fillColor=#f5f5f5;strokeColor=#666666;" # Grey scheme for CDP-discovered neighbors.
    }
    else {
        $hostStyle += "fillColor=#fff9c4;strokeColor=#fbc02d;" # Yellow scheme for LLDP-discovered neighbors.
    }
    $hostId = "host-box-$((New-Guid).ToString().Substring(0,8))"

    $global:drawioXml += "        <mxCell id=`"$hostId`" value=`"$encodedHostText`" style=`"$hostStyle`" vertex=`"1`" parent=`"$hostGroupId`">
            <mxGeometry x=`"0`" y=`"0`" width=`"$hostWidth`" height=`"$hostHeight`" as=`"geometry`" />
        </mxCell>`n"

    # 5. Draw the interfaces for this neighbor host.
    $currentX = $GDrawioEthernetSpacingPhysical
    $interfaceY = $hostHeight + 10 # Position interfaces below the main host box.

    foreach ($interface in $interfacesToDraw) {
        $interfaceLocation = [PSCustomObject]@{ X = $currentX; Y = $interfaceY }
        # Call the standard function to draw a physical interface shape.
        $interfaceId = Add-DrawioPhysicalInterface -Interface $interface -Location $interfaceLocation -ParentId $hostGroupId -DrawType "neighbors"
        $interfaceIdMap[$interface.Interface] = $interfaceId # Store the generated ID (optional).
        $currentX += $GDrawioPhysicalInterfaceWidth + $GDrawioEthernetSpacingPhysical
    }

    return
}












# Creates the XML for a single logical (L3) interface shape (e.g., Vlan, Loopback).
function Add-DrawioLogicalInterface {
    [CmdletBinding()]
    param(
        # The interface object with its L3 properties.
        [parameter(Mandatory = $true)] $Interface,
        # The X/Y coordinates relative to the parent host.
        [parameter(Mandatory = $true)] [PSCustomObject]$Location,
        # The ID of the parent host shape.
        [parameter(Mandatory = $true)] [string]$ParentId
    )

    # 1. Text Construction
    # Build the text content for the shape line by line.
    $textElements = [System.Collections.ArrayList]::new()
    $height = $GDrawioLogicalInterfaceHeight # Start with a default height.

    # Use shortened interface names if configured.
    $ifaceName = if ($GDrawioShortenInterfacesNames) {
        $Interface.Interface -replace "Vlan", "vl" -replace "Loopback", "Lo"
    }
    else {
        $Interface.Interface
    }
    $null = $textElements.Add("<b>$ifaceName</b>")

    # Add IP address with subnet mask if available.
    $ipAddress = if ($Interface.subnetmask) { "$($Interface.ipaddress)/$($Interface.subnetmask)" } else { $Interface.ipaddress }
    $null = $textElements.Add($ipAddress)

    # Add optional details and increase height if they exist.
    if ($Interface.Description) { $null = $textElements.Add($Interface.Description) }
    if ($Interface.standbyip) { $null = $textElements.Add("HSRP: $($Interface.standbyip)"); $height += $GDrawioVrfTextSizeExtension }
    if ($Interface.ClusterIP) { $null = $textElements.Add("ClusterIP: $($Interface.ClusterIP)"); $height += $GDrawioVrfTextSizeExtension }

    # 2. Styling and Final Text
    $style = "rounded=1;whiteSpace=wrap;html=1;arcSize=20;align=center;verticalAlign=middle;fontSize=$($GDrawioLogicalInterfaceFontSize);"

    # Check if the interface is shutdown. This style takes precedence.
    if ($Interface.shutdown -or ($Interface.IntStatus -like "*down*" -and $Interface.INTProtocolStatus -like "*down*")) {
        if ($interface.vrf) { $null = $textElements.Add("VRF: $($interface.vrf)") }
        $null = $textElements.Add("<b>SHUTDOWN</b>")
        $style += "fillColor=#FFCDD2;strokeColor=#B71C1C;fontColor=#B71C1C;" # Red color scheme for 'down' state.
    }
    else {
        # Style based on VRF membership.
        if ($interface.vrf) {
            # Use the VRF's assigned color, or a default purple if none is set.
            $vrfColor = if ($Interface.VRFColor) { Convert-RgbToHex -RgbString $Interface.VRFColor } else { "#E1BEE7" }
            $style += "fillColor=$vrfColor;strokeColor=#6A1B9A;"
            $null = $textElements.Add("VRF: $($interface.vrf)")
            $height += $GDrawioVrfTextSizeExtension # Increase height for the VRF text line.
        }
        else {
            # Default style for a normal, active interface.
            $style += "fillColor=#FFFFFF;strokeColor=#424242;" # Default white fill.
        }
    }

    # 3. Generate XML
    $interfaceId = "l3-iface-$((New-Guid).ToString().Substring(0,8))"
    # Store the generated ID on the object for creating connectors later.
    $Interface.LogicalDrawioId = $interfaceId
    $encodedText = [System.Web.HttpUtility]::HtmlEncode($textElements -join "<br>")

    $global:drawioXml += "        <mxCell id=`"$interfaceId`" value=`"$encodedText`" style=`"$style`" vertex=`"1`" parent=`"$ParentId`">
            <mxGeometry x=`"$($Location.X)`" y=`"$($Location.Y)`" width=`"$GDrawioLogicalInterfaceWidth`" height=`"$height`" as=`"geometry`" />
        </mxCell>`n"
}
# Creates the XML for a Layer 3 host and its logical interfaces.
function Add-DrawioHostLayer3 {
    [CmdletBinding()]
    param(
        # The full device object.
        [parameter(Mandatory = $true)] $Device,
        # The top-left coordinates for the host group.
        [parameter(Mandatory = $true)] [PSCustomObject]$Location,
        # An optional type, e.g., "GatewayHost", for special styling.
        [string]$HostType,
        # The type of diagram being drawn, which affects which interfaces are shown.
        [parameter(Mandatory = $true)]
        [string]$DiagramType
    )

    # Determine which interfaces to draw based on the diagram type.
    $interfacesToDraw = @()
    if ($HostType -eq "GatewayHost") {
        # Gateway hosts always show all interfaces with an IP.
        $interfacesToDraw = $Device.interfaces | Where-Object { $_.ipaddress } | Sort-Object vrf, interface
    }
    elseif ($DiagramType -eq "RoutesOnly") {
        # For 'RoutesOnly' diagrams, only draw interfaces that are actively part of a route being displayed.
        $interfacesToDraw = $Device.interfaces | Where-Object { $_.DrawOnRoutesOnlyDiagram } | Sort-Object vrf, interface

    }
    else {
        # For 'Normal' and 'LinksOnly' diagrams, draw all interfaces that have an IP address configured.
        $interfacesToDraw = $Device.interfaces | Where-Object { $_.ipaddress } | Sort-Object vrf, interface
    }
    # Calculate the required width of the host based on the number of interfaces.
    $interfaceCount = $interfacesToDraw.Count
    $hostWidth = ($interfaceCount * $GDrawioLogicalInterfaceWidth) + (($interfaceCount + 1) * $GDrawioEthernetSpacingLogical)
    $hostWidth = [System.Math]::Max($hostWidth, $GDrawioLayer3HostFormWidth) # Enforce minimum width.
    # Create the main group cell.
    $hostGroupId = "l3-host-group-$((New-Guid).ToString().Substring(0,8))"
    $global:drawioXml += "         <mxCell id=`"$hostGroupId`" value=`"`" style=`"group`" vertex=`"1`" connectable=`"0`" parent=`"1`">
    <mxGeometry x=`"$($Location.X)`" y=`"$($Location.Y)`" width=`"$hostWidth`" height=`"$($GDrawioLayer3HostFormHeight + $GDrawioLogicalInterfaceHeight + 40)`" as=`"geometry`" />
    </mxCell>`n"
    # Style the host box based on its type.
    $hostStyle = "rounded=1;whiteSpace=wrap;html=1;fontSize=$($GCDPHostFontSize);fontStyle=1;strokeWidth=2;"
    
    # Prepare the local AS Number text if it exists on the device.
    $asNumberText = ""
    if ($Device.BGP_AS_Number) {
        $asNumberText = "<br><b>AS:</b> $($Device.BGP_AS_Number)"
    }

    if ($HostType -eq "GatewayHost") {
        # For gateway hosts, the label includes the HostName and the discovered AS number.
        $hostText = "<b>$($Device.HostName)</b>$asNumberText"
        $hostStyle += "fillColor=$(Convert-RgbToHex -RgbString $Layer3ARPHostColour);"
    }
    else {
        # For regular hosts, just show their own AS number.
        $hostText = "<b>$($Device.DeviceIdentifier)</b><br>$($Device.HostName)$asNumberText"
        $hostStyle += "fillColor=$(Convert-RgbToHex -RgbString $Layer3HostColour);"
    }
    $encodedHostText = [System.Web.HttpUtility]::HtmlEncode($hostText)
    # Create the visible host box cell.
    $hostId = "l3-host-box-$((New-Guid).ToString().Substring(0,8))"
    $global:drawioXml += "         <mxCell id=`"$hostId`" value=`"$encodedHostText`" style=`"$hostStyle`" vertex=`"1`" parent=`"$hostGroupId`">
    <mxGeometry x=`"0`" y=`"0`" width=`"$hostWidth`" height=`"$GDrawioLayer3HostFormHeight`" as=`"geometry`" />
    </mxCell>`n"
    # If it's a gateway host, add a small router icon for visual distinction.
    if ($HostType -eq "GatewayHost") {
        $iconId = "icon-$((New-Guid).ToString().Substring(0,8))"
        $iconStyle = "shape=mxgraph.cisco.routers.router;fillColor=#FFFFFF;strokeColor=none;"
        $global:drawioXml += "         <mxCell id=`"$iconId`" value=`"`" style=`"$iconStyle`" vertex=`"1`" parent=`"$hostGroupId`">
            <mxGeometry x=`"10`" y=`"-20`" width=`"50`" height=`"35`" as=`"geometry`" />
        </mxCell>`n"
    }
    # Position and draw each logical interface below the host box.
    $currentX = $GDrawioEthernetSpacingLogical
    $interfaceY = $GDrawioLayer3HostFormHeight - 10 # Slightly overlap interfaces with the host box.
    foreach ($interface in $interfacesToDraw) {
        $interfaceLocation = [PSCustomObject]@{ X = $currentX; Y = $interfaceY }
        Add-DrawioLogicalInterface -Interface $interface -Location $interfaceLocation -ParentId $hostGroupId
        $currentX += $GDrawioLogicalInterfaceWidth + $GDrawioEthernetSpacingLogical
    }
    return $hostWidth
}


# Creates the XML for a network segment (e.g., a VLAN or subnet) in an L3 diagram.
function Add-DrawioNetworkSegment {
    [CmdletBinding()]
    param(
        # The network object, containing its name, CIDR, color, etc.
        [parameter(Mandatory = $true)] $Network,
        # The top-left coordinates for the network shape.
        [parameter(Mandatory = $true)] [PSCustomObject]$Location
    )
    # Construct the text for the network shape.
    $text = "$($network.RoutedVlan) - $($network.NetworkName) ($($network.cidr))"
    $encodedText = [System.Web.HttpUtility]::HtmlEncode($text)

    # This style creates a square-edged rectangle, replacing a previous line-based shape.
    $style = "rounded=0;whiteSpace=wrap;html=1;align=center;verticalAlign=middle;fontSize=11;strokeWidth=2;"
    # Use the network's pre-defined color for the fill.
    $style += "fillColor=$(Convert-RgbToHex -RgbString $network.color);strokeColor=#424242;"

    $networkId = "net-$((New-Guid).ToString().Substring(0,8))"
    # Store the generated ID on the network object for later use in creating connectors.
    $Network.LogicalDrawioId = $networkId

    $global:drawioXml += "        <mxCell id=`"$networkId`" value=`"$encodedText`" style=`"$style`" vertex=`"1`" parent=`"1`">
            <mxGeometry x=`"$($Location.X)`" y=`"$($Location.Y)`" width=`"$GDrawioVlanWidth`" height=`"$GDrawioVlanHeight`" as=`"geometry`" />
        </mxCell>`n"
    return $networkId
}

# Draws an informational "cloud" bubble with ARP entry details for a network.
function Add-DrawioArpBubble {
    [CmdletBinding()]
    param(
        # The network object, which contains an array of its ARP entries.
        [parameter(Mandatory = $true)] $Network,
        # The top-left coordinates for the bubble.
        [parameter(Mandatory = $true)] [PSCustomObject]$Location
    )
    # Build the text content for the bubble.
    $textElements = [System.Collections.ArrayList]::new()
    $null = $textElements.Add("<b>$($network.NetworkName) ($($network.RoutedVlan))</b>")

    # Depending on a global setting, show either full details or a summary.
    if ($GDrawAprEntriesDetails) {
        $null = $textElements.Add("<b>IP Address | MAC | Vendor</b>")
        foreach ($entry in ($network.ARPEntries | Sort-Object VendorCompanyName)) {
            $null = $textElements.Add("$($Entry.ipaddress) | $($Entry.mac) | $($Entry.VendorCompanyName)")
        }
    }
    else {
        # Create a summary by grouping ARP entries by vendor and counting them.
        $summary = $network.ARPEntries | Group-Object VendorCompanyName | Select-Object Count, Name | Sort-Object Count -Descending | ForEach-Object { "$($_.Name) ($($_.Count))" }
        # Add the summary lines to the text elements.
        $null = $textElements.Add($summary -join "<br>")
    }

    $finalText = $textElements -join "<br>"
    $encodedText = [System.Web.HttpUtility]::HtmlEncode($finalText)
    # Style the shape as a cloud with a gradient fill based on the network's color.
    $style = "shape=cloud;whiteSpace=wrap;html=1;align=center;verticalAlign=middle;fontSize=9;"
    $style += "fillColor=$(Convert-RgbToHex -RgbString $network.color);gradientColor=#FFFFFF;strokeColor=#424242;strokeWidth=1;"

    # Dynamically calculate the height of the bubble based on the number of text lines.
    # We split the final text by the <br> tag to get an accurate line count.
    $lineCount = ($finalText -split '<br>').Count
    $height = 60 + ($lineCount * 15) # Base height + 15px per line

    $bubbleId = "arp-$((New-Guid).ToString().Substring(0,8))"
    $global:drawioXml += "        <mxCell id=`"$bubbleId`" value=`"$encodedText`" style=`"$style`" vertex=`"1`" parent=`"1`">
            <mxGeometry x=`"$($Location.X)`" y=`"$($Location.Y)`" width=`"$GDrawioArpWidth`" height=`"$height`" as=`"geometry`" />
        </mxCell>`n"
    return $bubbleId
}




# Draws a bubble shape summarizing MAC address vendors for a given physical interface.
function Add-DrawioMacAddressBubble {
    [CmdletBinding()]
    param(
        # The interface object containing the array of learned MAC addresses.
        [parameter(Mandatory = $true)]
        $Interface,
        # The top-left coordinates for the bubble.
        [parameter(Mandatory = $true)]
        [PSCustomObject]$Location,
        # The ID of the parent shape (the host group).
        [parameter(Mandatory = $true)]
        [string]$ParentId
    )

    # 1. Generate the summary text from the interface's MAC address array.
    $textElements = [System.Collections.ArrayList]::new()
    $null = $textElements.Add("<b>MAC Summary for $($Interface.Interface)</b>")

    # Group the MAC addresses by their vendor, count them, and format the summary lines.
    $summary = $Interface.MacAddressArray |
        Group-Object VendorCompanyName |
        Select-Object Count, Name |
        Sort-Object Count -Descending |
        ForEach-Object { "$($_.Name) ($($_.Count))" }

    if ($summary) {
        # Add each summary line to the text elements array.
        foreach ($item in $summary) {
            $null = $textElements.Add($item)
        }
    }

    $finalText = $textElements -join "<br>"
    $encodedText = [System.Web.HttpUtility]::HtmlEncode($finalText)

    # 2. Define the style for the bubble (a grey cloud with a shadow).
    $style = "shape=cloud;whiteSpace=wrap;html=1;align=center;verticalAlign=middle;fontSize=9;padding=5;"
    $style += "fillColor=#f5f5f5;strokeColor=#666666;shadow=1;"

    # 3. Calculate bubble dimensions based on the amount of text.
    $width = 180
    # Get an accurate line count by splitting the final text string.
    $lineCount = ($finalText -split '<br>').Count
    # Calculate height based on a base size plus an amount for each line.
    $height = 30 + ($lineCount * 12)

    # 4. Generate the XML for the bubble.
    $bubbleId = "mac-bubble-$((New-Guid).ToString().Substring(0,8))"
    $global:drawioXml += "        <mxCell id=`"$bubbleId`" value=`"$encodedText`" style=`"$style`" vertex=`"1`" parent=`"$ParentId`">
            <mxGeometry x=`"$($Location.X)`" y=`"$($Location.Y)`" width=`"$width`" height=`"$height`" as=`"geometry`" />
        </mxCell>`n"

    return $bubbleId
}