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


# Measures a fixed-width stacked-text card without drawing it so placement and rendering share the
# same height formula. Emits nothing. Returns: { Width; Height }.
# Emits: nothing. Returns: { Width; Height }.
# Reads globals: none
function Get-DrawioCardFootprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Lines,
        [Parameter(Mandatory = $true)][int]$Width,
        # Padding above and below the text, and the height one line occupies.
        [Parameter(Mandatory = $true)][int]$BaseHeight,
        [Parameter(Mandatory = $true)][int]$LineHeight,
        # A card never draws shorter than this, however little it has to say.
        [Parameter(Mandatory = $true)][int]$MinHeight
    )

    return [PSCustomObject]@{
        Width  = $Width
        Height = [Math]::Max($MinHeight, $BaseHeight + (@($Lines).Count * $LineHeight))
    }
}
# ------------------------------------------------------------------------------------------------
# The one place a cell is written into the Draw.io document.
#
# Escaping is not optional and there is no switch to skip it. HtmlEncode here does double duty - it
# turns < into &lt;, which is also correct XML attribute escaping - so a label carrying deliberate
# <b> or <br> markup is rendered correctly BECAUSE it is encoded exactly once: the XML parser hands
# draw.io back the tag and html=1 renders it. Encoding anywhere else would double-encode it.
#
# The emitted whitespace is uniform, and nothing downstream depends on it: a .drawio file is
# compared by parsing it - style, value, vertex/edge flag and rounded geometry, in document order -
# rather than by comparing the raw text.
# ------------------------------------------------------------------------------------------------

# Writes one <mxCell> into the document StringBuilder ($global:GDrawioBuilder, materialised into
# $global:drawioXml by Finalize-DrawioFile). Emits 1 cell. Returns: nothing - the caller owns its
# own return contract. Reads globals: none (writes $global:GDrawioBuilder).
# Emits: the cell it is given. Returns: nothing.
# Reads globals: none
function Add-DrawioCell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        # Escaped here, always. Pass the label as the reader should see it.
        [AllowNull()][AllowEmptyString()][string]$Value = '',
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Style,
        # Anything with X / Y / Width / Height; each is written only if present. An edge normally
        # has none, and a group child often has no X/Y.
        [AllowNull()]$Geometry,
        [string]$Parent = '1',
        # Draws an edge rather than a vertex. Source and target are cell ids.
        [switch]$Edge,
        [AllowEmptyString()][string]$SourceId,
        [AllowEmptyString()][string]$TargetId,
        # Group and container cells set connectable="0" so an edge cannot terminate on the wrapper.
        [switch]$NotConnectable,
        # relative="1" on the geometry: an edge's own coordinate space, or a label positioned along
        # one.
        [switch]$RelativeGeometry,
        # Raw XML nested inside <mxGeometry>, for the mxPoint waypoints and offsets an edge needs.
        # Already-formed XML by definition, so it is written through untouched.
        [AllowEmptyString()][string]$GeometryChildXml,
        # Extra attributes on the geometry element itself, e.g. ' x="0.5"' on an edge label.
        [AllowEmptyString()][string]$GeometryAttributes
    )

    $attributes = [System.Text.StringBuilder]::new()
    [void]$attributes.Append(' id="').Append($Id).Append('"')
    [void]$attributes.Append(' value="').Append([System.Web.HttpUtility]::HtmlEncode($Value)).Append('"')
    [void]$attributes.Append(' style="').Append($Style).Append('"')
    if ($Edge) { [void]$attributes.Append(' edge="1"') } else { [void]$attributes.Append(' vertex="1"') }
    if ($NotConnectable) { [void]$attributes.Append(' connectable="0"') }
    [void]$attributes.Append(' parent="').Append($Parent).Append('"')
    if ($PSBoundParameters.ContainsKey('SourceId')) { [void]$attributes.Append(' source="').Append($SourceId).Append('"') }
    if ($PSBoundParameters.ContainsKey('TargetId')) { [void]$attributes.Append(' target="').Append($TargetId).Append('"') }

    # Not $geometryAttributes: that is the parameter, and PowerShell would coerce a StringBuilder
    # assigned to a [string] parameter into a string.
    $geometryBuilder = [System.Text.StringBuilder]::new()
    if ($RelativeGeometry) { [void]$geometryBuilder.Append(' relative="1"') }
    foreach ($name in 'X', 'Y', 'Width', 'Height') {
        if ($null -eq $Geometry) { break }
        $measurement = $Geometry.$name
        # A missing attribute and a zero one are different things to draw.io and to the golden
        # digest, and "$measurement -eq ''" would conflate them: PowerShell coerces the empty string
        # to 0 before comparing, so an x of 0 would silently stop being written.
        if ($null -eq $measurement) { continue }
        if ($measurement -is [string] -and $measurement.Length -eq 0) { continue }
        [void]$geometryBuilder.Append(' ').Append($name.ToLowerInvariant()).Append('="').Append($measurement).Append('"')
    }
    if ($GeometryAttributes) { [void]$geometryBuilder.Append($GeometryAttributes) }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('        <mxCell').Append($attributes.ToString()).Append(">`n")
    if ($GeometryChildXml) {
        [void]$builder.Append('            <mxGeometry').Append($geometryBuilder.ToString()).Append(" as=`"geometry`">`n")
        [void]$builder.Append($GeometryChildXml)
        [void]$builder.Append("            </mxGeometry>`n")
    }
    else {
        [void]$builder.Append('            <mxGeometry').Append($geometryBuilder.ToString()).Append(" as=`"geometry`" />`n")
    }
    [void]$builder.Append("        </mxCell>`n")

    # The single emit path for the whole tool. It appends to the document StringBuilder rather than
    # to a growing string - see Initialize-DrawioFile for why that mattered.
    if ($global:GPerfTiming) {
        $perfCellStart = [System.Diagnostics.Stopwatch]::GetTimestamp()
        [void]$global:GDrawioBuilder.Append($builder)
        Add-MTAutoDrawPerf -Label "Draw: Add-DrawioCell append (accumulated)" `
            -Milliseconds ((([System.Diagnostics.Stopwatch]::GetTimestamp() - $perfCellStart) * 1000.0) / [System.Diagnostics.Stopwatch]::Frequency)
    }
    else {
        [void]$global:GDrawioBuilder.Append($builder)
    }
}
# This function creates a visual legend on the diagram to explain the meaning of different interface colors and styles.
# Emits: 6 cell site(s), some in loops. Returns: { Id; Width; Height }.
# Reads globals: $GArrayOfInterfaceTypes, $GDrawioArrayOfInterfaceTypes, $GDrawioInterfaceLegend_LineColorSFP, $GDrawioInterfaceLegend_LineColorSFP_RJ45, $GDrawioInterfaceLegend_LineWidth, $GDrawioInterfaceLegend_SwatchHeight, $GDrawioInterfaceLegend_SwatchWidth
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
    $legendSurface = (Get-MTAutoDrawPalette -Scope Shared).Surface.Default

    # --- Create the main group to hold all legend parts ---
    # A group allows all elements of the legend to be moved together in the Draw.io editor.
    $legendGroupId = New-DrawioId -Prefix 'legend-group'
    Add-DrawioCell -Id "$legendGroupId" -Value '' -Style "group" -NotConnectable -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$boxWidth"; Height = "$boxHeight" })
    # --- Create the background rectangle for the legend ---
    $backgroundId = New-DrawioId -Prefix 'legend-bg'
    # This cell is the visible box with a white fill and shadow effect. It is a child of the group cell.
    Add-DrawioCell -Id "$backgroundId" -Value '' -Style "rounded=1;whiteSpace=wrap;html=1;fillColor=$($legendSurface.Fill);strokeColor=$($legendSurface.Stroke);shadow=1;" -Parent "$legendGroupId" -Geometry ([pscustomobject]@{ Width = "$boxWidth"; Height = "$boxHeight" })
    # --- Add Title and Header ---
    $currentY = $padding; $titleId = New-DrawioId -Prefix 'legend-title'; $headerId = New-DrawioId -Prefix 'legend-header'
    # HTML-encode the title text to ensure it's valid XML.
    Add-DrawioCell -Id "$titleId" -Value ("<div style=`"font-size: 14px; font-weight: bold;`">$Title</div>") -Style "text;html=1;align=center;verticalAlign=middle;resizable=0;points=[];" -Parent "$legendGroupId" -Geometry ([pscustomobject]@{ Y = "$currentY"; Width = "$boxWidth"; Height = "20" })
    # Move the Y-coordinate down for the next element.
    $currentY += $lineHeight
    # Create the column header text.
    Add-DrawioCell -Id "$headerId" -Value ("<b>Color&nbsp;&nbsp;&nbsp;&nbsp;|&nbsp;&nbsp;&nbsp;&nbsp;Interface Cisco Type Name</b>") -Style "text;html=1;align=left;verticalAlign=middle;resizable=0;points=[];" -Parent "$legendGroupId" -Geometry ([pscustomobject]@{ X = "$padding"; Y = "$currentY"; Width = "$boxWidth"; Height = "20" })
    $currentY += $lineHeight
    # --- Loop through interface types and create entries ---
    # Iterate through a global array containing the definitions for each interface type (e.g., RJ45, Fibre).
    foreach ($legendLine in $GDrawioArrayOfInterfaceTypes) {
        # Deconstruct the array into named variables for clarity.
        $interfaceFamily = $legendLine[0]; $interfaceName = $legendLine[1]; $fillColorRgb = $legendLine[2]; $fillColorHex = Convert-RgbToHex -RgbString $fillColorRgb
        $strokeColor = (Get-MTAutoDrawPalette -Scope Shared).Text.Default; $strokeWidth = 1
        # Apply special border styles for certain interface families to indicate media type.
        if ($interfaceFamily -eq "RJ45-SFP") { $strokeWidth = $GDrawioInterfaceLegend_LineWidth; $strokeColor = $GDrawioInterfaceLegend_LineColorSFP_RJ45 }
        elseif ($interfaceFamily -eq "Fibre") { $strokeWidth = $GDrawioInterfaceLegend_LineWidth; $strokeColor = $GDrawioInterfaceLegend_LineColorSFP }
        # Create the small colored rectangle (the "swatch").
        $swatchId = New-DrawioId -Prefix 'swatch'; $swatchStyle = "rounded=0;whiteSpace=wrap;html=1;fillColor=$fillColorHex;strokeColor=$strokeColor;strokeWidth=$strokeWidth;"
        Add-DrawioCell -Id "$swatchId" -Value '' -Style "$swatchStyle" -Parent "$legendGroupId" -Geometry ([pscustomobject]@{ X = "$padding"; Y = "$currentY"; Width = "$GDrawioInterfaceLegend_SwatchWidth"; Height = "$GDrawioInterfaceLegend_SwatchHeight" })
        # Create the text label next to the color swatch.
        $labelId = New-DrawioId -Prefix 'label'; $labelX = $padding + $GDrawioInterfaceLegend_SwatchWidth + 10
        Add-DrawioCell -Id "$labelId" -Value ($interfaceName) -Style "text;html=1;align=left;verticalAlign=middle;resizable=0;points=[];" -Parent "$legendGroupId" -Geometry ([pscustomobject]@{ X = "$labelX"; Y = "$currentY"; Width = "220"; Height = "$GDrawioInterfaceLegend_SwatchHeight" })
        # Move Y-coordinate down for the next legend entry.
        $currentY += $lineHeight
    }
    return [PSCustomObject]@{ Id = $legendGroupId; Width = $boxWidth; Height = $boxHeight }
}


# Helper function to prevent errors with malformed RGB strings.
# Converts a string like "rgb(213, 232, 212)" into a hex code like "#D5E8D4".
# Emits: nothing. Returns: a value.
# Reads globals: none
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
    # White rather than a guess: an unparseable rgb() string renders as an uncoloured shape, which
    # looks like the mistake it is, instead of a plausible wrong colour.
    return (Get-MTAutoDrawPalette -Scope Shared).Fallback.Unparseable
}



# ============================================================================
# Physical interface: label, footprint and the port chip itself
# ============================================================================
# Split into pure text/footprint helpers plus a draw function, the same shape as every other
# perimeter-port piece in this file: a page has to know every port chip's size BEFORE it can decide
# which side of its host it belongs on, so the size cannot be computed only as a side effect of
# drawing.
#
# A port can sit on any side of a host, so geometry cannot encode STP importance. Root/alternate/
# backup state is shown through the extra text line and the red blocked overlay instead.

# The label lines for one physical interface port, in display order.
# Emits: nothing. Returns: a value.
# Reads globals: $GDrawioShortenInterfacesNames
function Get-DrawioPhysicalPortTextElements {
    [CmdletBinding()]
    param([parameter(Mandatory = $true)] $Interface)

    $textElements = [System.Collections.ArrayList]::new()

    if ($GDrawioShortenInterfacesNames) {
        $ifaceName = $Interface.Interface -replace "GigabitEthernet", "Gi" -replace "TenGigabitEthernet", "Te" -replace "FastEthernet", "Fa"
        $null = $textElements.Add("<b>$ifaceName</b>")
    }
    else {
        $null = $textElements.Add("<b>$($Interface.Interface)</b>")
    }
    if ($Interface.Description) { $null = $textElements.Add($Interface.Description) }

    if ($Interface.SwitchportMode -like "trunk") {
        $vlans = if ($Interface.SwitchportTrunkVlan) { $Interface.SwitchportTrunkVlan -replace ',', ', ' } else { "all" }
        $null = $textElements.Add("Trunk VLANs: $vlans")
    }
    elseif ($Interface.SwitchportMode -eq "Probably Trunk mode") {
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
    if ($Interface.ChannelGroup) {
        if ($interface.ChannelGroup -like "*ae*") {
            $null = $textElements.Add($Interface.ChannelGroup)
        }
        else {
            $null = $textElements.Add("Port-Channel $($Interface.ChannelGroup)")
        }
    }

    if ($Interface.STRootInterfaceForVlans -or $Interface.STRole -eq "Root") { $null = $textElements.Add("STP Root Port") }
    if ($Interface.STALTnInterfaceForVlans -or $Interface.STRole -eq "ALT") { $null = $textElements.Add("STP ALTN Port") }
    if ($Interface.STState -eq "BLK") { $null = $textElements.Add("STP Blocked Port") }

    return , @($textElements)
}

# Draws one physical interface as a port chip at an explicit position (relative to its parent host
# group - the caller, not this function, decides where that is; see Get-DrawioPerimeterLayout).
# Emits: 2 cells. Returns: { Id; Width; Height }.
# Reads globals: $GDrawioArrayOfInterfaceTypes, $GDrawioDefaultInterfacesColor, $GDrawioPhysicalInterfaceFontSize
function Add-DrawioPhysicalPort {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $Port,
        [parameter(Mandatory = $true)] [PSCustomObject]$Location,
        [parameter(Mandatory = $true)] [string]$ParentId
    )

    $interface = $Port.Interface
    $footprint = $Port.Footprint
    $finalText = $Port.Text -join "<br>"

    # --- Styling (fill by media type, border by Port-Channel membership) ---
    $style = "rounded=1;whiteSpace=wrap;html=1;arcSize=10;align=center;verticalAlign=middle;fontSize=$($GDrawioPhysicalInterfaceFontSize);"
    $portPalette = (Get-MTAutoDrawPalette -Scope Physical).Port
    $fontColor = (Get-MTAutoDrawPalette -Scope Shared).Text.Default

    $mediaType = $GDrawioArrayOfInterfaceTypes | Where-Object { $_[1] -eq $Interface.MediaType } | Select-Object -First 1
    if ($mediaType) {
        $style += "fillColor=$(Convert-RgbToHex -RgbString $mediaType[2]);"
        if ($mediaType[0] -eq "RJ45" -or $mediaType[0] -eq "RJ45-SFP") {
            $fontColor = $portPalette.Absent.Font
            $style += "gradientColor=$($portPalette.Absent.Fill);"
        }
    }
    else {
        $style += "fillColor=$GDrawioDefaultInterfacesColor;"
    }

    if ($Interface.shutdown -or ($Interface.IntStatus -like "*down*")) {
        $style += "fillColor=$($portPalette.Error.Fill);"
        $fontColor = $portPalette.Error.Font
    }
    $style += "fontColor=$fontColor;"

    if ($Interface.ChannelGroup) {
        $channelNumber = $Interface.ChannelGroup -replace '\D', ''
        $styleObject = Get-OrSet-PortChannelStyle -channelNumber $channelNumber
        $style += "strokeColor=$($styleObject.strokeColor);strokeWidth=$($styleObject.strokeWidth);"
    }
    else {
        $style += "strokeColor=$($portPalette.Absent.Stroke);strokeWidth=1;"
    }

    $interfaceId = New-DrawioId -Prefix 'iface'
    $Interface.PhysicalDrawioId = $interfaceId
    Add-DrawioCell -Id "$interfaceId" -Value ($finalText) -Style "$style" -Parent "$ParentId" -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$($footprint.Width)"; Height = "$($footprint.Height)" })

    if ($Interface.STState -eq "BLK") {
        $crossId = New-DrawioId -Prefix 'cross'
        $crossStyle = "shape=mxgraph.basic.cross;strokeColor=$($portPalette.Error.Stroke);strokeWidth=4;rotation=20;"
        Add-DrawioCell -Id "$crossId" -Value '' -Style "$crossStyle" -Parent "$interfaceId" -RelativeGeometry -Geometry ([pscustomobject]@{ X = "0.125"; Y = "0.125"; Width = "90"; Height = "90" })
    }

    return [PSCustomObject]@{ Id = $interfaceId; Width = $footprint.Width; Height = $footprint.Height }
}

# ============================================================================
# Configured host card (physical / CDP-LLDP pages) - perimeter-port model
# ============================================================================
# A host is a label box with interface chips attached to the side facing each peer. The page owns side
# and slot selection because it can see every device position; this file provides:
#
#   Get-DrawioHostPhysicalInterfaces - which configured ports the page needs to consider
#   Get-DrawioPhysicalHostFootprint  - the full device footprint for a GIVEN side assignment
#   Add-DrawioPhysicalHost           - draws that same layout
#
# The page calls the footprint function twice (see Draw-AllNeighborsDrawio's comment for why) and
# the draw function once, always with the exact same $PortsBySide, so measuring and drawing can
# never disagree about size.

# The ports that WOULD be drawn on this device, before anything about layout is decided. Selection
# rules: "All" shows every port with a CDP/LLDP neighbour, an
# inferred-evidence link, or an interesting STP role; "brief" narrows that to ports whose neighbour
# resolved to another device actually held in this run's config. Both then add ports carrying at
# least $GDrawPortsWithMacs learned MACs. Non-physical and shutdown ports are excluded either way.
# Emits: nothing. Returns: { All; MacBubbleInterfaces }.
# Reads globals: $GDrawPortsWithMacs
function Get-DrawioHostPhysicalInterfaces {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $Device,
        [parameter(Mandatory = $true)] $DrawAllNeighbors,
        [AllowNull()] $TopologyEvidenceModel = $null
    )

    $evidenceInterfaceKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($TopologyEvidenceModel) {
        $evidenceInterfaceNames = @($TopologyEvidenceModel.Edges |
            Where-Object { $_.Drawn -and $_.SourceHostname -ieq $Device.hostname } |
            Select-Object -ExpandProperty SourceInterface -Unique)
        foreach ($name in $evidenceInterfaceNames) {
            $key = ConvertTo-NormalizedInterfaceIdentity $name
            if ($key) { [void]$evidenceInterfaceKeys.Add($key) }
        }
    }

    if ($DrawAllNeighbors) {
        $neighborAndStpInterfaces = @($Device.interfaces | Where-Object {
            (
                $_.HasCPDNieghbor -or
                $_.HasLLDPNeighbor -or
                ($evidenceInterfaceKeys.Count -gt 0 -and $evidenceInterfaceKeys.Contains((ConvertTo-NormalizedInterfaceIdentity $_.Interface))) -or
                ($_.STRole -eq 'Root' -or $_.STRole -eq 'ALT' )) -and ($_.interface -notmatch 'vlan|loopback|port-channel|ae' -and (-not $_.shutdown))
        })
    }
    else {
        $cdpLinkedInterfaceNames = $Device.CDPNeighbors |
            Where-Object { $_.PartnerEthernetInterface -and $_.PartnerEthernetInterface.Value } |
            Select-Object -ExpandProperty InterfaceLocalDevice
        $lldpLinkedInterfaceNames = $Device.LLDPNeighbors |
            Where-Object { $_.PartnerEthernetInterface -and $_.PartnerEthernetInterface.Value } |
            Select-Object -ExpandProperty InterfaceLocalDevice
        $allLinkedInterfaceNames = [System.Collections.Generic.HashSet[string]]::new([string[]]@($cdpLinkedInterfaceNames + $lldpLinkedInterfaceNames), [StringComparer]::OrdinalIgnoreCase)

        $neighborAndStpInterfaces = @($Device.interfaces | Where-Object {
            ($allLinkedInterfaceNames.Contains([string]$_.Interface) -or $_.IsLinkedToByCDPorLLDP -or
                ($evidenceInterfaceKeys.Count -gt 0 -and $evidenceInterfaceKeys.Contains((ConvertTo-NormalizedInterfaceIdentity $_.Interface)))) -and
            $_.interface -notmatch 'vlan|loopback|port-channel|ae' -and
            (-not $_.shutdown)
        })
    }

    $macInterfacesToDraw = @()
    if ($GDrawPortsWithMacs -gt 0) {
        $macInterfacesToDraw = @($Device.interfaces | Where-Object {
            ($_.Interface -notin $neighborAndStpInterfaces.Interface) -and
            ($_.interface -notmatch 'vlan|loopback|port-channel|ae' -and (-not $_.shutdown)) -and
            ($_.MacAddressArray) -and
            (($_.MacAddressArray).Count -ge $GDrawPortsWithMacs)
        })
    }

    return [PSCustomObject]@{
        All = @(($neighborAndStpInterfaces + $macInterfacesToDraw) | Sort-Object Interface)
        MacBubbleInterfaces = @($macInterfacesToDraw)
    }
}

# The host box's header text and the minimum size it needs, independent of how many ports end up
# around it.
# Emits: nothing. Returns: { Text; MinWidth; MinHeight }.
# Reads globals: $GDrawioHostFontSize, $GDrawioHostPhysicalHeight, $GDrawioLayer3HostFormWidth
function Get-DrawioHostPhysicalLabel {
    [CmdletBinding()]
    param([parameter(Mandatory = $true)] $Device)

    $hostTextElements = [System.Collections.ArrayList]::new()
    if ($Device.Version -and $Device.Version.Hardware) {
        $hardwareInfo = if ($Device.Version.Hardware -is [array]) { $Device.Version.Hardware[0] } else { $Device.Version.Hardware }
        $null = $hostTextElements.Add($hardwareInfo)
    }
    $hostnametext = if ($Device.HostTypeIfCDPorLLDP) { "$($Device.HostName) : $($Device.HostTypeIfCDPorLLDP)" } else { "$($Device.HostName)" }
    $stText = if ($Device.SpanningTree) {
        $text = "$($Device.DeviceIdentifier) : $($hostnametext) : $($Device.SpanningTree.SpanningTreeMode)"
        if ($Device.SpanningTree.RootBridgeForVlans.count -gt 15) {
            $text += "<br><b>Root for VLANs:</b> " + (($Device.SpanningTree.RootBridgeForVlans) -join ', ')
        }
        elseif ($Device.SpanningTree.RootBridgeForVlans.count -gt 0) {
            $text += " : Root for VLANs: " + (($Device.SpanningTree.RootBridgeForVlans) -join ', ')
        }
        $text
    }
    else {
        "$($Device.DeviceIdentifier) : $($hostnametext)"
    }
    $null = $hostTextElements.Add($stText)
    $measured = Measure-DrawioTextBlock -Lines @($hostTextElements) -FontSize $GDrawioHostFontSize -MaxWidth $GDrawioLayer3HostFormWidth
    return [PSCustomObject]@{
        Text = $hostTextElements -join '<br>'
        MinWidth = 130
        MinHeight = [Math]::Max($GDrawioHostPhysicalHeight, $measured.Height + 10)
    }
}

# Builds the PortsBySide structure Get-DrawioPerimeterLayout needs, given the caller's own side
# decision for each interface. Shared by the footprint and draw functions so they can never measure
# one layout and draw another.
# Emits: nothing. Returns: a value.
# Reads globals: $GDrawioPortGap
function Get-DrawioPhysicalPortsBySide {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Interfaces,
        # Interface.Interface (port name) -> 'N'/'E'/'S'/'W'. A name with no entry defaults to 'S'.
        [parameter(Mandatory = $true)] [hashtable]$SideOf,
        # Interface.Interface (port name) -> desired box-relative slot coordinate. Optional.
        [hashtable]$DesiredOf = @{},
        [ValidateSet('N', 'S')][string]$DefaultSide,
        # Interface.Interface (port name) of every interface that also carries a MAC bubble.
        [string[]]$MacBubbleInterfaceNames = @()
    )

    $portsBySide = @{ 'N' = @(); 'E' = @(); 'S' = @(); 'W' = @() }
    $macNames = [System.Collections.Generic.HashSet[string]]::new([string[]]@($MacBubbleInterfaceNames))
    foreach ($interface in $Interfaces) {
        $name = [string]$interface.Interface
        $side = if ($SideOf.ContainsKey($name)) { $SideOf[$name] } else { $DefaultSide }
        $chipText = Get-DrawioPhysicalPortTextElements -Interface $interface
        $chipMeasurement = Measure-DrawioTextBlock -Lines $chipText -FontSize $GDrawioPhysicalInterfaceFontSize -MaxWidth $GDrawioPhysicalInterfaceWidth
        $chipFootprint = [pscustomobject]@{
            Width = $GDrawioPhysicalInterfaceWidth
            Height = [Math]::Max($GDrawioPhysicalInterfaceHeight, $chipMeasurement.Height + 6)
        }
        $extraDepth = 0.0
        $bubbleText = $null
        $bubbleFootprint = $null
        if ($macNames.Contains($name)) {
            $bubbleText = [System.Collections.ArrayList]::new()
            [void]$bubbleText.Add("<b>MACs on $($interface.Interface)</b>")
            $summary = $interface.MacAddressArray | Group-Object VendorCompanyName | Select-Object Count, Name | Sort-Object Count -Descending
            foreach ($item in @($summary)) { [void]$bubbleText.Add("$($item.Name) ($($item.Count))") }
            $bubbleMeasurement = Measure-DrawioTextBlock -Lines $bubbleText -FontSize 8 -MaxWidth 140 -HorizontalPadding 20
            $bubbleFootprint = [pscustomobject]@{ Width = 140; Height = [Math]::Max(34, $bubbleMeasurement.Height + 14) }
            $extraDepth = $GDrawioPortGap + $(if ($side -eq 'N' -or $side -eq 'S') { $bubbleFootprint.Height } else { $bubbleFootprint.Width })
        }
        $desired = if ($DesiredOf.ContainsKey($name)) { $DesiredOf[$name] } else { $null }
        $portsBySide[$side] += , ([PSCustomObject]@{
            Key = $name; Interface = $interface; Width = $chipFootprint.Width; Height = $chipFootprint.Height
            Desired = $desired; ExtraDepth = $extraDepth; Text = $chipText; Footprint = $chipFootprint
            BubbleText = $bubbleText; BubbleFootprint = $bubbleFootprint
        })
    }
    return $portsBySide
}

# The full footprint Add-DrawioPhysicalHost will occupy for a GIVEN side assignment. Called twice by
# the page per device (see Draw-AllNeighborsDrawio): once with an assignment guessed before anything
# is placed, to get a footprint good enough to place devices by; once more after real neighbour
# positions are known, to get the size that will actually be drawn.
# Emits: nothing. Returns: { Width; Height }.
# Reads globals: $GDrawioPortGap
function Get-DrawioPhysicalHostFootprint {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $Device,
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Interfaces,
        [parameter(Mandatory = $true)] [hashtable]$SideOf,
        [parameter(Mandatory = $true)] [ValidateSet('Configured', 'CDPNeighbor', 'LLDPNeighbor')] [string]$Variant,
        [string[]]$MacBubbleInterfaceNames = @()
    )

    $configured = $Variant -eq 'Configured'
    $label = if ($configured) { Get-DrawioHostPhysicalLabel -Device $Device } else { Get-DrawioNeighborHostLabel -Device $Device }
    $defaultSide = if ($configured) { 'S' } else { 'N' }
    $bubbleNames = if ($configured) { $MacBubbleInterfaceNames } else { @() }
    $portsBySide = Get-DrawioPhysicalPortsBySide -Interfaces $Interfaces -SideOf $SideOf `
        -DefaultSide $defaultSide -MacBubbleInterfaceNames $bubbleNames
    $layout = Get-DrawioPerimeterLayout -BoxMinWidth $label.MinWidth -BoxMinHeight $label.MinHeight -PortsBySide $portsBySide -Gap $GDrawioPortGap
    return [PSCustomObject]@{ Width = $layout.TotalWidth; Height = $layout.TotalHeight; BoxOrigin = $layout.BoxOrigin; BoxWidth = $layout.BoxWidth; BoxHeight = $layout.BoxHeight }
}

# Draws the host box and every port chip at the position Get-DrawioPerimeterLayout computes for the
# given side assignment (and, on the page's final pass, the given per-port desired slot - see
# $DesiredOf on Get-DrawioPhysicalPortsBySide - which is what pulls a chip into line with its
# peer so the connecting edge comes out straight).
# Emits: 2 cells. Returns: { Id; Width; Height }.
# Reads globals: $GDrawioHostFontSize, $GDrawioPortGap
function Add-DrawioPhysicalHost {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $Device,
        # Top-left of the device's FULL footprint (including any protruding ports), not of the host
        # box itself - the same value Get-DrawioPhysicalHostFootprint measured.
        [parameter(Mandatory = $true)] [PSCustomObject]$Location,
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Interfaces,
        [parameter(Mandatory = $true)] [hashtable]$SideOf,
        [hashtable]$DesiredOf = @{},
        [parameter(Mandatory = $true)] [ValidateSet('Configured', 'CDPNeighbor', 'LLDPNeighbor')] [string]$Variant,
        [string[]]$MacBubbleInterfaceNames = @()
    )

    $configured = $Variant -eq 'Configured'
    $label = if ($configured) { Get-DrawioHostPhysicalLabel -Device $Device } else { Get-DrawioNeighborHostLabel -Device $Device }
    $defaultSide = if ($configured) { 'S' } else { 'N' }
    $bubbleNames = if ($configured) { $MacBubbleInterfaceNames } else { @() }
    $portsBySide = Get-DrawioPhysicalPortsBySide -Interfaces $Interfaces -SideOf $SideOf -DesiredOf $DesiredOf `
        -DefaultSide $defaultSide -MacBubbleInterfaceNames $bubbleNames
    $layout = Get-DrawioPerimeterLayout -BoxMinWidth $label.MinWidth -BoxMinHeight $label.MinHeight -PortsBySide $portsBySide -Gap $GDrawioPortGap

    $hostGroupId = New-DrawioId -Prefix 'host-group'
    Add-DrawioCell -Id "$hostGroupId" -Value '' -Style "group" -NotConnectable -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$($layout.TotalWidth)"; Height = "$($layout.TotalHeight)" })

    if ($configured) {
        $role = (Get-MTAutoDrawPalette -Scope Physical).Node.Host
        $hostStyle = "rounded=1;whiteSpace=wrap;html=1;fillColor=$($role.Fill);strokeColor=$($role.Stroke);fontSize=$($GDrawioHostFontSize);fontStyle=1;"
    }
    else {
        $neighbour = (Get-MTAutoDrawPalette -Scope Physical).Neighbour
        $role = if ($Variant -eq 'CDPNeighbor') { $neighbour.Cdp } else { $neighbour.Lldp }
        $hostStyle = "rounded=1;whiteSpace=wrap;html=1;fontSize=$($GDrawioHostFontSize);fontStyle=1;fillColor=$($role.Fill);strokeColor=$($role.Stroke);"
    }
    $hostId = New-DrawioId -Prefix 'host-box'
    $Device.PhysicalHostDrawioId = $hostId
    Add-DrawioCell -Id $hostId -Value $label.Text -Style $hostStyle -Parent $hostGroupId -Geometry ([pscustomobject]@{
        X = $layout.BoxOrigin.X; Y = $layout.BoxOrigin.Y; Width = $layout.BoxWidth; Height = $layout.BoxHeight
    })

    foreach ($side in @('N', 'E', 'S', 'W')) {
        foreach ($port in @($portsBySide[$side])) {
            $chipLocation = $layout.ChipPositions[$port.Key]
            $chipShape = Add-DrawioPhysicalPort -Port $port -Location $chipLocation -ParentId $hostGroupId

            if ($configured -and $port.BubbleFootprint) {
                # The bubble trails further out the SAME side the chip is already on, centered on
                # the chip so the pair reads as one unit.
                $bubbleFootprint = $port.BubbleFootprint
                $bubbleLocation = switch ($side) {
                    'N' { [PSCustomObject]@{ X = $chipLocation.X + ($chipShape.Width / 2) - ($bubbleFootprint.Width / 2); Y = $chipLocation.Y - $GDrawioPortGap - $bubbleFootprint.Height } }
                    'S' { [PSCustomObject]@{ X = $chipLocation.X + ($chipShape.Width / 2) - ($bubbleFootprint.Width / 2); Y = $chipLocation.Y + $chipShape.Height + $GDrawioPortGap } }
                    'W' { [PSCustomObject]@{ X = $chipLocation.X - $GDrawioPortGap - $bubbleFootprint.Width; Y = $chipLocation.Y + ($chipShape.Height / 2) - ($bubbleFootprint.Height / 2) } }
                    default { [PSCustomObject]@{ X = $chipLocation.X + $chipShape.Width + $GDrawioPortGap; Y = $chipLocation.Y + ($chipShape.Height / 2) - ($bubbleFootprint.Height / 2) } }
                }
                $bubbleStyle = 'shape=cloud;whiteSpace=wrap;html=1;align=center;verticalAlign=middle;fontSize=8;padding=4;'
                $bubbleRole = (Get-MTAutoDrawPalette -Scope Physical).Bubble.Mac
                $bubbleStyle += "fillColor=$($bubbleRole.Fill);strokeColor=$($bubbleRole.Stroke);shadow=1;"
                $bubbleId = New-DrawioId -Prefix 'mac-bubble'
                Add-DrawioCell -Id $bubbleId -Value (($port.BubbleText -join '<br>')) -Style $bubbleStyle -Parent $hostGroupId `
                    -Geometry ([pscustomobject]@{ X = "$($bubbleLocation.X)"; Y = "$($bubbleLocation.Y)"; Width = "$($bubbleFootprint.Width)"; Height = "$($bubbleFootprint.Height)" })
                if ($port.Interface.PhysicalDrawioId -and $bubbleId) {
                    $null = Add-DrawioConnector -SourceId $port.Interface.PhysicalDrawioId -TargetId $bubbleId -Style "endArrow=none;dashed=1;strokeColor=$((Get-MTAutoDrawPalette -Scope Shared).Text.Muted);strokeWidth=1;"
                }
            }
        }
    }

    return [PSCustomObject]@{ Id = $hostGroupId; Width = $layout.TotalWidth; Height = $layout.TotalHeight }
}















# This function creates the XML for a connector (an edge or line) between two shapes.
# Emits: 1 cell. Returns: { Id; Width; Height }.
# Reads globals: none
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
        # The palette cannot be called in a parameter default, so this one value is stated here. It
        # is Firewall.Node.Zone's stroke, the repository's plain "a link" blue.
        [string]$Style = "endArrow=none;html=1;strokeWidth=4;strokeColor=#6C8EBF;",
        # Optional text to display as a label on the connector.
        [string]$Text = "",
        # Where along the edge the label sits, -1 (source end) to 1 (target end), 0 being the
        # midpoint draw.io uses by default. Callers that draw several labelled edges out of one
        # device stagger this so the labels spread along their edges instead of stacking at the
        # midpoints.
        [AllowNull()][System.Nullable[double]]$LabelPosition = $null,
        # Optional pixel nudge for the label, as a .X / .Y object.
        [AllowNull()][PSCustomObject]$LabelOffset = $null
    )
    if ($SourceId -eq $TargetId) {
        Write-MTAutoDrawLog -Level Debug -Phase Draw -Message "Skipping self-referencing connector on page '$($global:GCurrentPageName)' for shape '$SourceId'."
        return [PSCustomObject]@{ Id = $null; Width = 0; Height = 0 }
    }
    # Both endpoints must be shapes on the page currently being written. Shape ids are stored on
    # the interface objects and overwritten every time a shape is redrawn, so on a page that draws
    # only a subset of the shapes (for example "CDP-LLDP brief") an id can still hold the value it
    # was given on an earlier page. Emitting that produces an edge draw.io cannot attach, which it
    # dumps at the page origin as a stray line.
    if ($global:GCurrentPageShapeIds) {
        foreach ($endpointId in @($SourceId, $TargetId)) {
            if (-not $global:GCurrentPageShapeIds.Contains($endpointId)) {
                Write-MTAutoDrawLog -Level Debug -Phase Draw -Message "Skipping connector on page '$($global:GCurrentPageName)': shape '$endpointId' was not drawn on this page."
                return [PSCustomObject]@{ Id = $null; Width = 0; Height = 0 }
            }
        }
    }

    # Several neighbour entries can resolve to the same pair of interface shapes (both directions of
    # one link, or two CDP sightings of the same port). Draw the edge once.
    if ($global:GCurrentPageEdgeKeys) {
        $endpoints = @($SourceId, $TargetId) | Sort-Object
        $edgeKey = "$($endpoints[0])|$($endpoints[1])"
        if (-not $global:GCurrentPageEdgeKeys.Add($edgeKey)) {
            Write-MTAutoDrawLog -Level Debug -Phase Draw -Message "Skipping duplicate connector on page '$($global:GCurrentPageName)' between '$SourceId' and '$TargetId'."
            return [PSCustomObject]@{ Id = $null; Width = 0; Height = 0 }
        }
    }

    # Generate a unique ID for the connector itself.
    $connectorId = New-DrawioId -Prefix 'edge'
    # HTML-encode the text to ensure it's valid within the XML value attribute.

    # On a relative edge geometry, x is the label's position along the edge and the "offset" point
    # nudges it off the line. Both are omitted unless asked for, so an unlabelled or unstaggered
    # connector emits exactly the XML it always did.
    $positionAttribute = if ($null -ne $LabelPosition) { " x=`"$([Math]::Round([double]$LabelPosition, 3))`"" } else { "" }
    $offsetElement = if ($null -ne $LabelOffset) {
        "`n                <mxPoint as=`"offset`" x=`"$([Math]::Round([double]$LabelOffset.X))`" y=`"$([Math]::Round([double]$LabelOffset.Y))`" />"
    } else { "" }

    # A connector is an edge: it needs source and target ids, and a geometry carrying the empty
    # sourcePoint/targetPoint pair draw.io expects even when the endpoints are cells.
    Add-DrawioCell -Id $connectorId -Value $Text -Style $style -Edge -SourceId $SourceId -TargetId $TargetId `
        -RelativeGeometry -GeometryAttributes $positionAttribute -GeometryChildXml @"
                <mxPoint as="sourcePoint" />
                <mxPoint as="targetPoint" />$offsetElement
"@

    return [PSCustomObject]@{ Id = $connectorId; Width = 0; Height = 0 }
}


# ============================================================================
# Discovered neighbour card (CDP/LLDP device with no local config) - perimeter-port model
# ============================================================================
# The discovered-device variant draws every
# interface it has (no "All"/"brief" selection - there is no config to select from), and never
# carries a MAC bubble (MAC learning is derived from a configured device's own tables).

# The header text and minimum box size for a discovered neighbour.
# Emits: nothing. Returns: { Text; MinWidth; MinHeight }.
# Reads globals: $GDrawioHostFontSize, $GDrawioHostPhysicalHeight, $GDrawioLayer3HostFormWidth
function Get-DrawioNeighborHostLabel {
    [CmdletBinding()]
    param([parameter(Mandatory = $true)] $Device)

    $lines = @("<b>$($Device.HostName)</b>", [string]$Device.Description, ($Device.ArrayOfIPAddresses | Out-String).Trim())
    $measured = Measure-DrawioTextBlock -Lines $lines -FontSize $GDrawioHostFontSize -MaxWidth $GDrawioLayer3HostFormWidth
    return [PSCustomObject]@{
        Text = $lines -join '<br>'
        MinWidth = 130
        MinHeight = [Math]::Max($GDrawioHostPhysicalHeight, $measured.Height + 10)
    }
}






# Converts an IP address into a unique and visually distinct hex color code.
# Emits: nothing. Returns: a value.
# Reads globals: none
function Get-ColorFromIp {
    param(
        [parameter(Mandatory = $true)]
        [string]$IpAddress
    )

    try {
        # String.GetHashCode() is randomized between PowerShell processes, so use
        # the shared SHA-256 color helper for byte-for-byte repeatable diagrams.
        return Convert-RgbToHex -RgbString (Get-DeterministicRgbColor -Seed "ip|$IpAddress")
    }
    catch {
        Write-MTAutoDrawLog -Level Error -Phase Draw -Message "Could not generate a colour for IP address '$IpAddress'; falling back to grey."
        return (Get-MTAutoDrawPalette -Scope Shared).Fallback.Unknown
    }
}


# ============================================================================
# Layer 3 host card - perimeter-port model
# ============================================================================
# Same shape as the physical-page pipeline (Get-DrawioHostPhysicalInterfaces /
# Get-DrawioPhysicalHostFootprint / Add-DrawioPhysicalHost): logical interfaces (SVIs, routed
# ports, loopbacks) attach as chips on whichever side of the host box faces their peer, instead of
# lining up underneath it regardless of where that peer is.

# The label lines for one logical interface port, in display order.
# Emits: nothing. Returns: a value.
# Reads globals: $GDrawioShortenInterfacesNames
function Get-DrawioLogicalPortTextElements {
    [CmdletBinding()]
    param([parameter(Mandatory = $true)] $Interface)

    $textElements = [System.Collections.ArrayList]::new()
    $ifaceName = if ($GDrawioShortenInterfacesNames) { $Interface.Interface -replace "Vlan", "vl" -replace "Loopback", "Lo" } else { $Interface.Interface }
    $null = $textElements.Add("<b>$ifaceName</b>")

    $addressRecords = @(Get-MTAutoDrawInterfaceIPv4Address -Interface $Interface)
    $primaryAddress = $addressRecords | Where-Object AddressType -eq 'Primary' | Select-Object -First 1
    if ($primaryAddress) {
        $primaryText = if ($primaryAddress.PrefixLength) { "$($primaryAddress.IPAddress)/$($primaryAddress.PrefixLength)" } else { $primaryAddress.IPAddress }
        $null = $textElements.Add($primaryText)
    }
    foreach ($secondaryAddress in @($addressRecords | Where-Object AddressType -eq 'Secondary')) {
        $secondaryText = if ($secondaryAddress.PrefixLength) { "$($secondaryAddress.IPAddress)/$($secondaryAddress.PrefixLength)" } else { $secondaryAddress.IPAddress }
        $null = $textElements.Add("Secondary: $secondaryText")
    }

    if ($Interface.Description) { $null = $textElements.Add($Interface.Description) }
    if ($Interface.standbyip) { $null = $textElements.Add("HSRP: $($Interface.standbyip)") }
    if ($Interface.ClusterIP) { $null = $textElements.Add("ClusterIP: $($Interface.ClusterIP)") }

    $isDown = $Interface.shutdown -or ($Interface.IntStatus -like "*down*" -and $Interface.INTProtocolStatus -like "*down*")
    if ($isDown) {
        if ($Interface.vrf) { $null = $textElements.Add("VRF: $($Interface.vrf)") }
        $null = $textElements.Add("<b>SHUTDOWN</b>")
    }
    elseif ($Interface.vrf) {
        $null = $textElements.Add("VRF: $($Interface.vrf)")
    }

    return , @($textElements)
}

# Computes the width/height of a logical (Layer-3) port box by measuring its text against the configured font size and max width. Returns {Width, Height}.
# Emits: nothing. Returns: { Width; Height }.
# Reads globals: $GDrawioLogicalInterfaceFontSize, $GDrawioLogicalInterfaceHeight, $GDrawioLogicalInterfaceWidth
function Get-DrawioLogicalPortFootprint {
    [CmdletBinding()]
    param([parameter(Mandatory = $true)] $Interface)

    $textElements = Get-DrawioLogicalPortTextElements -Interface $Interface
    $measured = Measure-DrawioTextBlock -Lines $textElements -FontSize $GDrawioLogicalInterfaceFontSize -MaxWidth $GDrawioLogicalInterfaceWidth
    return [PSCustomObject]@{
        Width = $GDrawioLogicalInterfaceWidth
        Height = [Math]::Max($GDrawioLogicalInterfaceHeight, $measured.Height + 6)
    }
}

# Draws one logical interface as a port chip at an explicit position (relative to its parent host
# group).
# Emits: 1 cell. Returns: { Id; Width; Height }.
# Reads globals: $GDrawioLogicalInterfaceFontSize
function Add-DrawioLogicalPort {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $Interface,
        [parameter(Mandatory = $true)] [PSCustomObject]$Location,
        [parameter(Mandatory = $true)] [string]$ParentId
    )

    $textElements = Get-DrawioLogicalPortTextElements -Interface $Interface
    $footprint = Get-DrawioLogicalPortFootprint -Interface $Interface

    $style = "rounded=1;whiteSpace=wrap;html=1;arcSize=20;align=center;verticalAlign=middle;fontSize=$($GDrawioLogicalInterfaceFontSize);"
    $isDown = $Interface.shutdown -or ($Interface.IntStatus -like "*down*" -and $Interface.INTProtocolStatus -like "*down*")
    $port = (Get-MTAutoDrawPalette -Scope Physical).Port
    if ($isDown) {
        $style += "fillColor=$($port.Down.Fill);strokeColor=$($port.Down.Stroke);fontColor=$($port.Down.Font);"
    }
    elseif ($Interface.vrf) {
        # A VRF gets its own deterministic colour where one was assigned; the palette role is the
        # fallback for a VRF that never got one.
        $vrfColor = if ($Interface.VRFColor) { Convert-RgbToHex -RgbString $Interface.VRFColor } else { $port.Vrf.Fill }
        $style += "fillColor=$vrfColor;strokeColor=$($port.Vrf.Stroke);"
    }
    else {
        $style += "fillColor=$($port.Normal.Fill);strokeColor=$($port.Normal.Stroke);"
    }

    $targetIp = if ($Interface.standbyip) { $Interface.standbyip } elseif ($Interface.ClusterIP) { $Interface.ClusterIP } else { $null }
    if ($targetIp) {
        $borderColor = Get-ColorFromIp -IpAddress $targetIp
        $style += "strokeWidth=4;strokeColor=$borderColor;"
    }

    $interfaceId = New-DrawioId -Prefix 'l3-iface'
    $Interface.LogicalDrawioId = $interfaceId
    Add-DrawioCell -Id "$interfaceId" -Value ($textElements -join "<br>") -Style "$style" -Parent "$ParentId" -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$($footprint.Width)"; Height = "$($footprint.Height)" })

    return [PSCustomObject]@{ Id = $interfaceId; Width = $footprint.Width; Height = $footprint.Height }
}

# Which interfaces a Layer 3 host card draws:
# a gateway host (ARP-discovered, no local config) shows every IP-bearing interface; "RoutesOnly"
# narrows to interfaces the resolve phase flagged as part of a drawn route
# (see StartProcessingConfig.ps1's DrawOnRoutesOnlyDiagram passes); everything else shows every
# IP-bearing interface.
# Emits: nothing. Returns: a value.
# Reads globals: none
function Get-DrawioHostLayer3Interfaces {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $Device,
        [string]$HostType,
        [parameter(Mandatory = $true)] [string]$DiagramType
    )

    # The leading comma is load-bearing, not a typo. `return @($x)` where $x is EMPTY hands the
    # caller $null, not an empty array - PowerShell unrolls a returned collection onto the pipeline,
    # and unrolling zero elements emits nothing. Wrapping in a single-element outer array with the
    # comma operator makes that unroll yield the (empty) inner array intact.
    #
    # This is not theoretical: an access switch whose interfaces all lack an IPv4 address makes this
    # return $null, and the render then dies on
    # "Cannot bind argument to parameter 'Interfaces' because it is null."
    #
    # CALLER CONTRACT: assign the result directly - `$x = Get-DrawioHostLayer3Interfaces ...`.
    # Do NOT wrap the call in @(), which would re-wrap the already-wrapped array and hand you a
    # one-element array containing the real array. Every comma-returning helper here works this way.
    if ($HostType -eq "GatewayHost") {
        return , @($Device.interfaces | Where-Object { @(Get-MTAutoDrawInterfaceIPv4Address -Interface $_).Count -gt 0 } | Sort-Object vrf, interface)
    }
    if ($DiagramType -eq "RoutesOnly") {
        return , @($Device.interfaces | Where-Object { $_.DrawOnRoutesOnlyDiagram } | Sort-Object vrf, interface)
    }
    return , @($Device.interfaces | Where-Object { @(Get-MTAutoDrawInterfaceIPv4Address -Interface $_).Count -gt 0 } | Sort-Object vrf, interface)
}

# The header text and minimum box size for a Layer 3 host.
# Emits: nothing. Returns: { Text; FillColor; MinWidth; MinHeight }.
# Reads globals: $GCDPHostFontSize, $GDrawioLayer3HostFormHeight, $GDrawioLayer3HostFormWidth
function Get-DrawioHostLayer3Label {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $Device,
        [string]$HostType
    )

    $asNumberText = if ($Device.BGP_AS_Number) { "<br><b>AS:</b> $($Device.BGP_AS_Number)" } else { "" }
    $isGateway = $HostType -eq "GatewayHost"
    $hostText = if ($isGateway) { "<b>$($Device.HostName)</b>$asNumberText" } else { "<b>$($Device.DeviceIdentifier)</b><br>$($Device.HostName)$asNumberText" }
    $plainLines = $hostText -split '<br>'
    $measured = Measure-DrawioTextBlock -Lines $plainLines -FontSize $GCDPHostFontSize -MaxWidth $GDrawioLayer3HostFormWidth

    return [PSCustomObject]@{
        Text = $hostText
        FillColor = Convert-RgbToHex -RgbString $(if ($isGateway) { $Layer3ARPHostColour } else { $Layer3HostColour })
        MinWidth = 130
        MinHeight = [Math]::Max($GDrawioLayer3HostFormHeight, $measured.Height + 10)
    }
}

# Groups a host's Layer-3 interfaces by compass side (N/E/S/W) for layout, computing each logical port's footprint and any desired-side hint. Returns a side->ports map.
# Emits: nothing. Returns: a value.
# Reads globals: none
function Get-DrawioHostLayer3PortsBySide {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Interfaces,
        [parameter(Mandatory = $true)] [hashtable]$SideOf,
        [hashtable]$DesiredOf = @{}
    )

    $portsBySide = @{ 'N' = @(); 'E' = @(); 'S' = @(); 'W' = @() }
    foreach ($interface in $Interfaces) {
        $name = [string]$interface.Interface
        $side = if ($SideOf.ContainsKey($name)) { $SideOf[$name] } else { 'S' }
        $footprint = Get-DrawioLogicalPortFootprint -Interface $interface
        $desired = if ($DesiredOf.ContainsKey($name)) { $DesiredOf[$name] } else { $null }
        $portsBySide[$side] += , ([PSCustomObject]@{ Key = $name; Interface = $interface; Width = $footprint.Width; Height = $footprint.Height; Desired = $desired })
    }
    return $portsBySide
}

# The footprint Add-DrawioHostLayer3 will occupy for a given side assignment. Called twice per
# device by the page (estimate, then real - see Draw-AllNeighborsDrawio's header comment for why).
# Emits: nothing. Returns: { Width; Height }.
# Reads globals: $GDrawioPortGap
function Get-DrawioHostLayer3Footprint {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $Device,
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Interfaces,
        [string]$HostType,
        [parameter(Mandatory = $true)] [hashtable]$SideOf
    )

    $label = Get-DrawioHostLayer3Label -Device $Device -HostType $HostType
    $portsBySide = Get-DrawioHostLayer3PortsBySide -Interfaces $Interfaces -SideOf $SideOf
    $layout = Get-DrawioPerimeterLayout -BoxMinWidth $label.MinWidth -BoxMinHeight $label.MinHeight -PortsBySide $portsBySide -Gap $GDrawioPortGap
    return [PSCustomObject]@{ Width = $layout.TotalWidth; Height = $layout.TotalHeight; BoxOrigin = $layout.BoxOrigin; BoxWidth = $layout.BoxWidth; BoxHeight = $layout.BoxHeight }
}

# Creates the XML for a Layer 3 host and its logical interfaces, using the side assignment and
# (on the page's final pass) desired slot positions the caller already worked out.
# Emits: 3 cells. Returns: { Id; Width; Height }.
# Reads globals: $GCDPHostFontSize, $GDrawioPortGap
function Add-DrawioHostLayer3 {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $Device,
        # Top-left of the device's FULL footprint (including protruding ports).
        [parameter(Mandatory = $true)] [PSCustomObject]$Location,
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Interfaces,
        [string]$HostType,
        [parameter(Mandatory = $true)] [hashtable]$SideOf,
        [hashtable]$DesiredOf = @{}
    )

    $label = Get-DrawioHostLayer3Label -Device $Device -HostType $HostType
    $portsBySide = Get-DrawioHostLayer3PortsBySide -Interfaces $Interfaces -SideOf $SideOf -DesiredOf $DesiredOf
    $layout = Get-DrawioPerimeterLayout -BoxMinWidth $label.MinWidth -BoxMinHeight $label.MinHeight -PortsBySide $portsBySide -Gap $GDrawioPortGap

    $hostGroupId = New-DrawioId -Prefix 'l3-host-group'
    Add-DrawioCell -Id "$hostGroupId" -Value '' -Style "group" -NotConnectable -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$($layout.TotalWidth)"; Height = "$($layout.TotalHeight)" })

    $hostStyle = "rounded=1;whiteSpace=wrap;html=1;fontSize=$($GCDPHostFontSize);fontStyle=1;strokeWidth=2;fillColor=$($label.FillColor);"
    $hostId = New-DrawioId -Prefix 'l3-host-box'
    Add-DrawioCell -Id $hostId -Value $label.Text -Style $hostStyle -Parent $hostGroupId -Geometry ([pscustomobject]@{
        X = $layout.BoxOrigin.X; Y = $layout.BoxOrigin.Y; Width = $layout.BoxWidth; Height = $layout.BoxHeight
    })

    if ($HostType -eq "GatewayHost") {
        $iconId = New-DrawioId -Prefix 'icon'
        $iconStyle = "shape=mxgraph.cisco.routers.router;fillColor=$((Get-MTAutoDrawPalette -Scope Shared).Text.Inverse);strokeColor=none;"
        Add-DrawioCell -Id "$iconId" -Value '' -Style "$iconStyle" -Parent "$hostGroupId" -Geometry ([pscustomobject]@{ X = "$($layout.BoxOrigin.X + 10)"; Y = "$($layout.BoxOrigin.Y - 20)"; Width = "50"; Height = "35" })
    }

    foreach ($side in @('N', 'E', 'S', 'W')) {
        foreach ($port in @($portsBySide[$side])) {
            $chipLocation = $layout.ChipPositions[$port.Key]
            $null = Add-DrawioLogicalPort -Interface $port.Interface -Location $chipLocation -ParentId $hostGroupId
        }
    }

    return [PSCustomObject]@{ Id = $hostGroupId; Width = $layout.TotalWidth; Height = $layout.TotalHeight; BoxOrigin = $layout.BoxOrigin; BoxWidth = $layout.BoxWidth; BoxHeight = $layout.BoxHeight }
}


# Creates the XML for a network segment (e.g., a VLAN or subnet) in an L3 diagram.
# Emits: 1 cell. Returns: { Id; Width; Height }.
# Reads globals: $GDrawioVlanHeight, $GDrawioVlanWidth
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

    # This style creates a square-edged rectangle, replacing a previous line-based shape.
    $style = "rounded=0;whiteSpace=wrap;html=1;align=center;verticalAlign=middle;fontSize=11;strokeWidth=2;"
    # Use the network's pre-defined color for the fill.
    $style += "fillColor=$(Convert-RgbToHex -RgbString $network.color);strokeColor=$((Get-MTAutoDrawPalette -Scope Physical).Bubble.Arp.Stroke);"

    $networkId = New-DrawioId -Prefix 'net'
    # Store the generated ID on the network object for later use in creating connectors.
    $Network.LogicalDrawioId = $networkId

    Add-DrawioCell -Id "$networkId" -Value ($text) -Style "$style" -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$GDrawioVlanWidth"; Height = "$GDrawioVlanHeight" })
    return [PSCustomObject]@{ Id = $networkId; Width = $GDrawioVlanWidth; Height = $GDrawioVlanHeight }
}

# Protocol edge color for the Layer 3 Topology Overview page - identical to
# Get-MTAutoDrawRouteProtocolColor for every protocol except OSPF (see the palette comment above).
# Always returns a hex string, so callers never need to know which representation the underlying
# helper used for a given protocol.
# Emits: nothing. Returns: a value.
# Reads globals: none
function Get-MTAutoDrawL3TopoProtocolColor {
    [CmdletBinding()]
    param([AllowNull()][string]$Protocol)

    if (([string]$Protocol).Trim() -ieq 'OSPF') { return (Get-MTAutoDrawPalette -Scope L3Topology).Link.OspfOverride }
    $raw = Get-MTAutoDrawRouteProtocolColor -Protocol $Protocol
    if ($raw -match '^#') { return $raw }
    return (Convert-RgbToHex -RgbString $raw)
}

#-----------------------------------------------------------------------------------------
# Helper Function: Add-DrawioL3TopologyNode
#-----------------------------------------------------------------------------------------
# Fixed 220x92 device card for the Layer 3 Topology Overview page - fixed footprint for the same
# reason as Add-DrawioTopologyNode above: it is what lets the draw function plan a predictable
# nodes-per-row grid. Deliberately summary-only: subnet/SVI COUNTS not a per-interface list, VRF
# NAMES not per-interface VRF tags, an HSRP/VRRP GROUP COUNT not one line per redundant VLAN. Full
# per-interface detail stays on the detailed Layer 3 pages and in layer3-interfaces.csv.
# Emits: 1 cell. Returns: { Id; Width; Height }.
# Reads globals: $GDrawioL3TopoMaxVrfsPerCard
function Add-DrawioL3TopologyNode {
    [CmdletBinding()]
    param(
        # One entry from Get-MTAutoDrawL3TopologyModel.Nodes.
        [parameter(Mandatory = $true)] $Node,
        [parameter(Mandatory = $true)] [PSCustomObject]$Location
    )

    $nodeWidth = 220
    $nodeHeight = 92

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>$($Node.HostName)</b>")
    $typeText = if ($Node.Device.DeviceType) { "$($Node.Device.DeviceType) . $($Node.Role)" } else { [string]$Node.Role }
    $lines.Add($typeText)

    if ($Node.SubnetCount -gt 0) {
        $subnetSuffix = if ($Node.SubnetCount -eq 1) { '' } else { 's' }
        $sviSuffix = if ($Node.SviCount -eq 1) { '' } else { 's' }
        $lines.Add("gw: $($Node.SubnetCount) subnet$subnetSuffix / $($Node.SviCount) SVI$sviSuffix")
    }

    if (@($Node.Vrfs).Count -gt 0) {
        $vrfCap = if ($GDrawioL3TopoMaxVrfsPerCard -gt 0) { [int]$GDrawioL3TopoMaxVrfsPerCard } else { 3 }
        $shownVrfs = @($Node.Vrfs | Select-Object -First $vrfCap)
        $vrfText = "VRF: " + ($shownVrfs -join ', ')
        if (@($Node.Vrfs).Count -gt $vrfCap) { $vrfText += " (+$(@($Node.Vrfs).Count - $vrfCap))" }
        $lines.Add($vrfText)
    }

    $protoParts = [System.Collections.Generic.List[string]]::new()
    if (@($Node.Protocols).Count -gt 0) { $protoParts.Add(((@($Node.Protocols) | Sort-Object) -join '/')) }
    if ($Node.BgpAs) { $protoParts.Add("AS $($Node.BgpAs)") }
    if ($protoParts.Count -gt 0) { $lines.Add(($protoParts -join ' . ')) }

    if ($Node.FhrpGroupCount -gt 0) {
        $grpSuffix = if ($Node.FhrpGroupCount -eq 1) { '' } else { 's' }
        $lines.Add("HSRP: $($Node.FhrpGroupCount) grp$grpSuffix")
    }

    $palette = Get-MTAutoDrawPalette -Scope L3Topology
    $roleName = [string]$Node.Role
    $presentation = if ($Node.IsSecurity) { $palette.Node.Security } else { $palette.Node.$roleName }
    $nodeStyle = "rounded=1;whiteSpace=wrap;html=1;fillColor=$($presentation.Fill);strokeColor=$($presentation.Stroke);fontColor=$($presentation.Font);strokeWidth=1;fontSize=10;align=center;verticalAlign=middle;"

    $nodeId = New-DrawioId -Prefix 'l3topo-node'
    # Distinct from TopologyOverviewDrawioId/RoutesSummaryDrawioId - this page must not clobber (or
    # be clobbered by) the shape ids those two pages rely on.
    $Node.Device.L3TopologyDrawioId = $nodeId
    Add-DrawioCell -Id "$nodeId" -Value (($lines -join '<br>')) -Style "$nodeStyle" -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$nodeWidth"; Height = "$nodeHeight" })
    return [PSCustomObject]@{ Id = $nodeId; Width = $nodeWidth; Height = $nodeHeight }
}

#-----------------------------------------------------------------------------------------
# Helper Function: Add-DrawioL3SegmentChip
#-----------------------------------------------------------------------------------------
# Small fixed 150x44 chip for a shared L3 segment with 3+ attached devices (a VLAN trunked across a
# stack of routing switches). A 2-device segment never gets one of these - it becomes the label on
# the edge between those two devices instead, keeping the page device-centric rather than splitting
# it into separate subnet and device halves.
# Emits: 1 cell. Returns: { Id; Width; Height }.
# Reads globals: none
function Add-DrawioL3SegmentChip {
    [CmdletBinding()]
    param(
        # One entry from Get-MTAutoDrawL3TopologyModel.Segments.
        [parameter(Mandatory = $true)] $Segment,
        [parameter(Mandatory = $true)] [PSCustomObject]$Location,
        # Get-MTAutoDrawL3TopologyModel.Vrfs (VRF name -> assigned hex color). Optional so a caller
        # without VRF data still gets the plain grey chip.
        [AllowNull()] $VrfColorMap = $null
    )

    $chipWidth = 150
    $chipHeight = 44

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($(if ($Segment.Vlan) { "<b>Vlan $($Segment.Vlan)</b>" } else { "<b>Segment</b>" }))
    $lines.Add([string]$Segment.Cidr)

    $palette = Get-MTAutoDrawPalette -Scope L3Topology
    $fill = $palette.Node.SegmentChip.Fill
    $stroke = $palette.Node.SegmentChip.Stroke
    $font = $palette.Node.SegmentChip.Font
    $vrfName = [string]$Segment.Vrf
    if ($vrfName -and $vrfName -ne 'default' -and $VrfColorMap -and $VrfColorMap.ContainsKey($vrfName)) {
        # The fill becomes the VRF's own colour, so the outline darkens and the text inverts to stay
        # readable against whatever that colour turns out to be.
        $fill = $VrfColorMap[$vrfName]
        $stroke = $palette.Node.SegmentChipVrf.Stroke
        $font = $palette.Node.SegmentChipVrf.Font
    }
    $style = "rounded=1;whiteSpace=wrap;html=1;fillColor=$fill;strokeColor=$stroke;fontColor=$font;fontSize=9;align=center;verticalAlign=middle;"
    $chipId = New-DrawioId -Prefix 'l3topo-segment'
    Add-DrawioCell -Id "$chipId" -Value (($lines -join '<br>')) -Style "$style" -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$chipWidth"; Height = "$chipHeight" })
    return [PSCustomObject]@{ Id = $chipId; Width = $chipWidth; Height = $chipHeight }
}

#-----------------------------------------------------------------------------------------
# Helper Function: Add-DrawioL3TopologyLegend
#-----------------------------------------------------------------------------------------
# Embedded legend for the Layer 3 Topology Overview page, built on the same group/background/swatch
# construction as Add-DrawioTopologyOverviewLegend above. Unlike that legend, the VRF section here is
# variable length (zero VRFs on a site with none configured, up to a handful otherwise), so the box
# height is computed from the actual entry counts rather than a literal constant.
# Emits: 9 cell site(s), some in loops. Returns: { Id; Width; Height }.
# Reads globals: none
function Add-DrawioL3TopologyLegend {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] [PSCustomObject]$Location,
        # Get-MTAutoDrawL3TopologyModel.Vrfs (VRF name -> assigned hex color). Optional: a site with
        # no non-default VRFs configured simply omits the VRF section.
        [AllowNull()] $VrfColorMap = $null
    )

    $legendSurface = (Get-MTAutoDrawPalette -Scope Shared).Surface.Default
    $legendSwatchStroke = (Get-MTAutoDrawPalette -Scope Shared).Swatch.Stroke
    $legendL3 = Get-MTAutoDrawPalette -Scope L3Topology

    $palette = Get-MTAutoDrawPalette -Scope L3Topology
    $boxWidth = 1420
    $padding = 20
    $columnWidth = 455
    $rowHeight = 32
    $sectionGap = 20
    $headerHeight = 24

    $nodeEntries = @(
        [pscustomobject]@{ Label = 'Border device (default route leaves the site here)'; Fill = $palette.Node.Border.Fill; Stroke = $palette.Node.Border.Stroke }
        [pscustomobject]@{ Label = 'Transit device (other devices route through it)'; Fill = $palette.Node.Transit.Fill; Stroke = $palette.Node.Transit.Stroke }
        [pscustomobject]@{ Label = 'Gateway device (owns subnets/SVIs only)'; Fill = $palette.Node.Gateway.Fill; Stroke = $palette.Node.Gateway.Stroke }
        [pscustomobject]@{ Label = 'Firewall / security device'; Fill = $palette.Node.Security.Fill; Stroke = $palette.Node.Security.Stroke }
        [pscustomobject]@{ Label = 'External next hop (not captured)'; Fill = $palette.Node.ExternalHop.Fill; Stroke = $palette.Node.ExternalHop.Stroke }
        [pscustomobject]@{ Label = 'Shared subnet (3+ devices)'; Fill = $palette.Node.SegmentChip.Fill; Stroke = $palette.Node.SegmentChip.Stroke }
    )
    $linkEntries = @(
        [pscustomobject]@{ Label = 'L3 adjacency - shared segment (subnet on the label)'; Color = $palette.Link.Adjacency.Color; Dashed = $false }
        [pscustomobject]@{ Label = 'Routed adjacency (arrow colored by protocol below)'; Color = $legendL3.Link.Adjacency.Color; Dashed = $false }
        [pscustomobject]@{ Label = 'Indirect routing - no shared segment'; Color = $palette.Link.Indirect.Color; Dashed = $true }
        [pscustomobject]@{ Label = 'HSRP / VRRP pair'; Color = $palette.Link.Fhrp.Color; Dashed = $false }
    )
    $protocolEntries = @(
        [pscustomobject]@{ Label = 'Static / default route'; Color = (Get-MTAutoDrawL3TopoProtocolColor -Protocol 'static') }
        [pscustomobject]@{ Label = 'OSPF'; Color = (Get-MTAutoDrawL3TopoProtocolColor -Protocol 'OSPF') }
        [pscustomobject]@{ Label = 'EIGRP'; Color = (Get-MTAutoDrawL3TopoProtocolColor -Protocol 'EIGRP') }
        [pscustomobject]@{ Label = 'BGP'; Color = (Get-MTAutoDrawL3TopoProtocolColor -Protocol 'BGP') }
        [pscustomobject]@{ Label = 'RIP'; Color = (Get-MTAutoDrawL3TopoProtocolColor -Protocol 'RIP') }
        [pscustomobject]@{ Label = 'IS-IS'; Color = (Get-MTAutoDrawL3TopoProtocolColor -Protocol 'IS-IS') }
    )
    $vrfEntries = @()
    if ($VrfColorMap -and @($VrfColorMap.Keys).Count -gt 0) {
        $vrfEntries = @($VrfColorMap.Keys | Sort-Object | Select-Object -First 6 | ForEach-Object {
            [pscustomobject]@{ Label = "VRF: $_"; Fill = $VrfColorMap[$_]; Stroke = $legendSwatchStroke }
        })
    }

    $rowsFor = { param($Count) [Math]::Max(1, [Math]::Ceiling($Count / 3.0)) }
    $nodeRows = & $rowsFor $nodeEntries.Count
    $linkRows = & $rowsFor $linkEntries.Count
    $protoRows = & $rowsFor $protocolEntries.Count
    $vrfRows = if ($vrfEntries.Count -gt 0) { & $rowsFor $vrfEntries.Count } else { 0 }

    $titleHeight = 38
    $boxHeight = $titleHeight +
        ($headerHeight + ($nodeRows * $rowHeight)) +
        ($sectionGap + $headerHeight + ($linkRows * $rowHeight)) +
        ($sectionGap + $headerHeight + ($protoRows * $rowHeight)) +
        $padding
    if ($vrfRows -gt 0) { $boxHeight += ($sectionGap + $headerHeight + ($vrfRows * $rowHeight)) }

    $groupId = New-DrawioId -Prefix 'l3topo-legend'
    Add-DrawioCell -Id "$groupId" -Value '' -Style "group" -NotConnectable -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$boxWidth"; Height = "$boxHeight" })
    $backgroundId = New-DrawioId -Prefix 'l3topo-legend-bg'
    Add-DrawioCell -Id "$backgroundId" -Value '' -Style "rounded=1;whiteSpace=wrap;html=1;fillColor=$($legendSurface.Fill);strokeColor=$($legendSurface.Stroke);shadow=1;" -Parent "$groupId" -Geometry ([pscustomobject]@{ Width = "$boxWidth"; Height = "$boxHeight" })
    $titleId = New-DrawioId -Prefix 'l3topo-legend-title'
    Add-DrawioCell -Id "$titleId" -Value ('<b>Layer 3 Topology Overview legend</b>') -Style "text;html=1;align=left;verticalAlign=middle;fontSize=14;resizable=0;points=[];" -Parent "$groupId" -Geometry ([pscustomobject]@{ X = "$padding"; Y = "10"; Width = "600"; Height = "24" })

    # Header text + a row of rounded-box swatches (used for Nodes and VRFs). Written as a script
    # block (not a separate function) so it closes over $groupId/$padding/$columnWidth/$rowHeight
    # the way the rest of this file's Add-Drawio* functions build XML inline.
    $drawBoxSection = {
        param($HeaderText, $Entries, $StartY)
        $headerId = New-DrawioId -Prefix 'l3topo-legend-header'
        Add-DrawioCell -Id "$headerId" -Value ("<b>$HeaderText</b>") -Style "text;html=1;align=left;verticalAlign=middle;fontSize=11;resizable=0;points=[];" -Parent "$groupId" -Geometry ([pscustomobject]@{ X = "$padding"; Y = "$StartY"; Width = "300"; Height = "20" })
        $rowY = $StartY + $headerHeight
        for ($index = 0; $index -lt $Entries.Count; $index++) {
            $column = $index % 3
            $row = [Math]::Floor($index / 3)
            $entryX = $padding + ($column * $columnWidth)
            $entryY = $rowY + ($row * $rowHeight)
            $entry = $Entries[$index]
            $swatchId = New-DrawioId -Prefix 'l3topo-legend-swatch'
            $swatchStyle = "rounded=1;whiteSpace=wrap;html=1;fillColor=$($entry.Fill);strokeColor=$($entry.Stroke);strokeWidth=1;"
            Add-DrawioCell -Id "$swatchId" -Value '' -Style "$swatchStyle" -Parent "$groupId" -Geometry ([pscustomobject]@{ X = "$entryX"; Y = "$entryY"; Width = "38"; Height = "22" })
            $labelId = New-DrawioId -Prefix 'l3topo-legend-label'
            Add-DrawioCell -Id "$labelId" -Value ([string]$entry.Label) -Style "text;html=1;align=left;verticalAlign=middle;fontSize=10;resizable=0;points=[];" -Parent "$groupId" -Geometry ([pscustomobject]@{ X = "$($entryX + 48)"; Y = "$entryY"; Width = "390"; Height = "22" })
        }
        $rowsUsed = [Math]::Max(1, [Math]::Ceiling($Entries.Count / 3.0))
        return ($rowY + ($rowsUsed * $rowHeight))
    }

    # Header text + a row of line swatches (used for Links and Route protocols).
    $drawLineSection = {
        param($HeaderText, $Entries, $StartY)
        $headerId = New-DrawioId -Prefix 'l3topo-legend-header'
        Add-DrawioCell -Id "$headerId" -Value ("<b>$HeaderText</b>") -Style "text;html=1;align=left;verticalAlign=middle;fontSize=11;resizable=0;points=[];" -Parent "$groupId" -Geometry ([pscustomobject]@{ X = "$padding"; Y = "$StartY"; Width = "300"; Height = "20" })
        $rowY = $StartY + $headerHeight
        for ($index = 0; $index -lt $Entries.Count; $index++) {
            $column = $index % 3
            $row = [Math]::Floor($index / 3)
            $entryX = $padding + ($column * $columnWidth)
            $entryY = $rowY + ($row * $rowHeight)
            $entry = $Entries[$index]
            $lineId = New-DrawioId -Prefix 'l3topo-legend-line'
            $dashStyle = if ($entry.Dashed) { 'dashed=1;dashPattern=8 4;' } else { '' }
            $lineStyle = "endArrow=none;html=1;strokeWidth=3;strokeColor=$($entry.Color);$dashStyle"
            Add-DrawioCell -Id $lineId -Value '' -Style $lineStyle -Edge -Parent $groupId -RelativeGeometry -GeometryChildXml @"
                <mxPoint x="$entryX" y="$($entryY + 11)" as="sourcePoint" />
                <mxPoint x="$($entryX + 55)" y="$($entryY + 11)" as="targetPoint" />
"@
            $labelId = New-DrawioId -Prefix 'l3topo-legend-label'
            Add-DrawioCell -Id "$labelId" -Value ([string]$entry.Label) -Style "text;html=1;align=left;verticalAlign=middle;fontSize=10;resizable=0;points=[];" -Parent "$groupId" -Geometry ([pscustomobject]@{ X = "$($entryX + 65)"; Y = "$entryY"; Width = "370"; Height = "22" })
        }
        $rowsUsed = [Math]::Max(1, [Math]::Ceiling($Entries.Count / 3.0))
        return ($rowY + ($rowsUsed * $rowHeight))
    }

    $nextY = & $drawBoxSection 'Nodes' $nodeEntries 38
    $nextY = & $drawLineSection 'Links' $linkEntries ($nextY + $sectionGap)
    $nextY = & $drawLineSection 'Route protocols' $protocolEntries ($nextY + $sectionGap)
    if ($vrfEntries.Count -gt 0) {
        $null = & $drawBoxSection 'VRFs' $vrfEntries ($nextY + $sectionGap)
    }

    return [pscustomobject]@{ Width = $boxWidth; Height = $boxHeight; Id = $groupId }
}

#-----------------------------------------------------------------------------------------
# Helper Function: Add-DrawioRoutesSummaryLegend
#-----------------------------------------------------------------------------------------
# The Layer 3 Routes Summary page's legend: what each device colour means (the same
# Add-DrawioTopologyNode / the TopologyOverview palette scope tiers as the Site Topology
# Overview page, plus the two card shapes specific to this page) and what each route-protocol
# edge colour means. Modeled directly on Add-DrawioL3TopologyLegend's group/background/title +
# box-section/line-section pattern, just with the two sections this page actually needs.
# Emits: 9 cell site(s), some in loops. Returns: { Id; Width; Height }.
# Reads globals: none
function Add-DrawioRoutesSummaryLegend {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] [PSCustomObject]$Location
    )

    $legendSurface = (Get-MTAutoDrawPalette -Scope Shared).Surface.Default
    $legendShared = Get-MTAutoDrawPalette -Scope Shared
    $legendNeutral = $legendShared.Link.Neutral
    $legendL3 = Get-MTAutoDrawPalette -Scope L3Topology

    $palette = Get-MTAutoDrawPalette -Scope TopologyOverview
    $boxWidth = 960
    $padding = 20
    $columnWidth = 300
    $rowHeight = 32
    $sectionGap = 20
    $headerHeight = 24

    $deviceEntries = @(
        [pscustomobject]@{ Label = 'Core device (physical-topology styling)'; Fill = $palette.Node.Core.Fill; Stroke = $palette.Node.Core.Stroke }
        [pscustomobject]@{ Label = 'Distribution device'; Fill = $palette.Node.Distribution.Fill; Stroke = $palette.Node.Distribution.Stroke }
        [pscustomobject]@{ Label = 'Access device'; Fill = $palette.Node.Access.Fill; Stroke = $palette.Node.Access.Stroke }
        [pscustomobject]@{ Label = 'Firewall / security device'; Fill = $palette.Node.Security.Fill; Stroke = $palette.Node.Security.Stroke }
        [pscustomobject]@{ Label = 'External next hop (dashed, not captured)'; Fill = $legendShared.Node.External.Fill; Stroke = $legendShared.Node.External.Stroke }
        [pscustomobject]@{ Label = 'Shared next-hop group (2+ devices, one static route each)'; Fill = $legendL3.Node.Collapsed.Fill; Stroke = $legendL3.Node.Collapsed.Stroke }
    )
    $protocolEntries = @(
        [pscustomobject]@{ Label = 'Static / default route'; Color = (Get-MTAutoDrawRouteProtocolColor -Protocol 'static') }
        [pscustomobject]@{ Label = 'OSPF'; Color = (Get-MTAutoDrawRouteProtocolColor -Protocol 'OSPF') }
        [pscustomobject]@{ Label = 'EIGRP'; Color = (Get-MTAutoDrawRouteProtocolColor -Protocol 'EIGRP') }
        [pscustomobject]@{ Label = 'BGP'; Color = (Get-MTAutoDrawRouteProtocolColor -Protocol 'BGP') }
        [pscustomobject]@{ Label = 'RIP'; Color = (Get-MTAutoDrawRouteProtocolColor -Protocol 'RIP') }
        [pscustomobject]@{ Label = 'IS-IS'; Color = (Get-MTAutoDrawRouteProtocolColor -Protocol 'IS-IS') }
        [pscustomobject]@{ Label = 'Dashed = not the default route (solid = default route)'; Color = $legendNeutral; Dashed = $true }
    )

    $rowsFor = { param($Count) [Math]::Max(1, [Math]::Ceiling($Count / 3.0)) }
    $deviceRows = & $rowsFor $deviceEntries.Count
    $protoRows = & $rowsFor $protocolEntries.Count

    $titleHeight = 38
    $boxHeight = $titleHeight +
        ($headerHeight + ($deviceRows * $rowHeight)) +
        ($sectionGap + $headerHeight + ($protoRows * $rowHeight)) +
        $padding

    $groupId = New-DrawioId -Prefix 'routes-summary-legend'
    Add-DrawioCell -Id "$groupId" -Value '' -Style "group" -NotConnectable -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$boxWidth"; Height = "$boxHeight" })
    $backgroundId = New-DrawioId -Prefix 'routes-summary-legend-bg'
    Add-DrawioCell -Id "$backgroundId" -Value '' -Style "rounded=1;whiteSpace=wrap;html=1;fillColor=$($legendSurface.Fill);strokeColor=$($legendSurface.Stroke);shadow=1;" -Parent "$groupId" -Geometry ([pscustomobject]@{ Width = "$boxWidth"; Height = "$boxHeight" })
    $titleId = New-DrawioId -Prefix 'routes-summary-legend-title'
    Add-DrawioCell -Id "$titleId" -Value ('<b>Layer 3 Routes Summary legend</b>') -Style "text;html=1;align=left;verticalAlign=middle;fontSize=14;resizable=0;points=[];" -Parent "$groupId" -Geometry ([pscustomobject]@{ X = "$padding"; Y = "10"; Width = "600"; Height = "24" })

    # Header text + a row of rounded-box swatches. Closes over $groupId/$padding/$columnWidth/
    # $rowHeight, same idiom as Add-DrawioL3TopologyLegend.
    $drawBoxSection = {
        param($HeaderText, $Entries, $StartY)
        $headerId = New-DrawioId -Prefix 'routes-summary-legend-header'
        Add-DrawioCell -Id "$headerId" -Value ("<b>$HeaderText</b>") -Style "text;html=1;align=left;verticalAlign=middle;fontSize=11;resizable=0;points=[];" -Parent "$groupId" -Geometry ([pscustomobject]@{ X = "$padding"; Y = "$StartY"; Width = "300"; Height = "20" })
        $rowY = $StartY + $headerHeight
        for ($index = 0; $index -lt $Entries.Count; $index++) {
            $column = $index % 3
            $row = [Math]::Floor($index / 3)
            $entryX = $padding + ($column * $columnWidth)
            $entryY = $rowY + ($row * $rowHeight)
            $entry = $Entries[$index]
            $swatchId = New-DrawioId -Prefix 'routes-summary-legend-swatch'
            $swatchStyle = "rounded=1;whiteSpace=wrap;html=1;fillColor=$($entry.Fill);strokeColor=$($entry.Stroke);strokeWidth=1;"
            Add-DrawioCell -Id "$swatchId" -Value '' -Style "$swatchStyle" -Parent "$groupId" -Geometry ([pscustomobject]@{ X = "$entryX"; Y = "$entryY"; Width = "32"; Height = "22" })
            $labelId = New-DrawioId -Prefix 'routes-summary-legend-label'
            Add-DrawioCell -Id "$labelId" -Value ([string]$entry.Label) -Style "text;html=1;align=left;verticalAlign=middle;fontSize=10;resizable=0;points=[];" -Parent "$groupId" -Geometry ([pscustomobject]@{ X = "$($entryX + 42)"; Y = "$entryY"; Width = "250"; Height = "22" })
        }
        $rowsUsed = [Math]::Max(1, [Math]::Ceiling($Entries.Count / 3.0))
        return ($rowY + ($rowsUsed * $rowHeight))
    }

    # Header text + a row of line swatches (used for Route protocols).
    $drawLineSection = {
        param($HeaderText, $Entries, $StartY)
        $headerId = New-DrawioId -Prefix 'routes-summary-legend-header'
        Add-DrawioCell -Id "$headerId" -Value ("<b>$HeaderText</b>") -Style "text;html=1;align=left;verticalAlign=middle;fontSize=11;resizable=0;points=[];" -Parent "$groupId" -Geometry ([pscustomobject]@{ X = "$padding"; Y = "$StartY"; Width = "300"; Height = "20" })
        $rowY = $StartY + $headerHeight
        for ($index = 0; $index -lt $Entries.Count; $index++) {
            $column = $index % 3
            $row = [Math]::Floor($index / 3)
            $entryX = $padding + ($column * $columnWidth)
            $entryY = $rowY + ($row * $rowHeight)
            $entry = $Entries[$index]
            $lineId = New-DrawioId -Prefix 'routes-summary-legend-line'
            $dashStyle = if ($entry.Dashed) { 'dashed=1;dashPattern=8 4;' } else { '' }
            $lineStyle = "endArrow=none;html=1;strokeWidth=3;strokeColor=$($entry.Color);$dashStyle"
            Add-DrawioCell -Id $lineId -Value '' -Style $lineStyle -Edge -Parent $groupId -RelativeGeometry -GeometryChildXml @"
                <mxPoint x="$entryX" y="$($entryY + 11)" as="sourcePoint" />
                <mxPoint x="$($entryX + 40)" y="$($entryY + 11)" as="targetPoint" />
"@
            $labelId = New-DrawioId -Prefix 'routes-summary-legend-label'
            Add-DrawioCell -Id "$labelId" -Value ([string]$entry.Label) -Style "text;html=1;align=left;verticalAlign=middle;fontSize=10;resizable=0;points=[];" -Parent "$groupId" -Geometry ([pscustomobject]@{ X = "$($entryX + 50)"; Y = "$entryY"; Width = "245"; Height = "22" })
        }
        $rowsUsed = [Math]::Max(1, [Math]::Ceiling($Entries.Count / 3.0))
        return ($rowY + ($rowsUsed * $rowHeight))
    }

    $nextY = & $drawBoxSection 'Devices' $deviceEntries 38
    $null = & $drawLineSection 'Route protocols' $protocolEntries ($nextY + $sectionGap)

    return [PSCustomObject]@{ Width = $boxWidth; Height = $boxHeight; Id = $groupId }
}

# Draws an informational "cloud" bubble with ARP entry details for a network.
# Emits: nothing. Returns: a value.
# Reads globals: $GDrawAprEntriesDetails, $GDrawArpEntryDetailLimit
function Get-DrawioArpBubbleHeight {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Network)

    $arpEntries = @($Network.ARPEntries)
    $detailLimit = if ($GDrawArpEntryDetailLimit -and $GDrawArpEntryDetailLimit -gt 0) { [int]$GDrawArpEntryDetailLimit } else { 40 }
    $lineCount = if ($GDrawAprEntriesDetails -and $arpEntries.Count -le $detailLimit) {
        2 + $arpEntries.Count
    }
    else {
        2 + @($arpEntries | Group-Object VendorCompanyName).Count
    }
    return [Math]::Min(420, 60 + ($lineCount * 15))
}

# Draws an ARP table 'bubble' for a network at $Location: shows the network name/VLAN and, when within the detail limit, the IP | MAC | Vendor entries; otherwise a count.
# Emits: 1 cell. Returns: { Id; Width; Height }.
# Reads globals: $GDrawAprEntriesDetails, $GDrawArpEntryDetailLimit, $GDrawioArpWidth
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
    $arpEntries = @($network.ARPEntries)
    $detailLimit = if ($GDrawArpEntryDetailLimit -and $GDrawArpEntryDetailLimit -gt 0) { [int]$GDrawArpEntryDetailLimit } else { 40 }
    if ($GDrawAprEntriesDetails -and $arpEntries.Count -le $detailLimit) {
        $null = $textElements.Add("<b>IP Address | MAC | Vendor</b>")
        foreach ($entry in ($arpEntries | Sort-Object VendorCompanyName,ipaddress)) {
            $null = $textElements.Add("$($Entry.ipaddress) | $($Entry.mac) | $($Entry.VendorCompanyName)")
        }
    }
    else {
        # Create a summary by grouping ARP entries by vendor and counting them.
        $null = $textElements.Add("<b>ARP entries: $($arpEntries.Count)</b>")
        $summary = $arpEntries | Group-Object VendorCompanyName | Select-Object Count, Name | Sort-Object Count -Descending | ForEach-Object { "$($_.Name) ($($_.Count))" }
        # Add the summary lines to the text elements.
        $null = $textElements.Add($summary -join "<br>")
    }

    $finalText = $textElements -join "<br>"
    # Style the shape as a cloud with a gradient fill based on the network's color.
    $style = "shape=cloud;whiteSpace=wrap;html=1;align=center;verticalAlign=middle;fontSize=9;"
    $bubble = (Get-MTAutoDrawPalette -Scope Physical).Bubble.Arp
    $style += "fillColor=$(Convert-RgbToHex -RgbString $network.color);gradientColor=$($bubble.Gradient);strokeColor=$($bubble.Stroke);strokeWidth=1;"

    # Dynamically calculate the height of the bubble based on the number of text lines.
    # We split the final text by the <br> tag to get an accurate line count.
    $height = Get-DrawioArpBubbleHeight -Network $Network

    $bubbleId = New-DrawioId -Prefix 'arp'
    Add-DrawioCell -Id "$bubbleId" -Value ($finalText) -Style "$style" -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$GDrawioArpWidth"; Height = "$height" })
    return [PSCustomObject]@{ Id = $bubbleId; Width = $GDrawioArpWidth; Height = $height }
}







# Draws a simplified placeholder for a root bridge that was not found in the input files.
# Emits: 1 cell. Returns: { Id; Width; Height }.
# Reads globals: none
function Add-DrawioDummyRootHost {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)]
        $DummyDevice,
        [parameter(Mandatory = $true)]
        [PSCustomObject]$Location
    )

    $hostWidth = 300
    $hostHeight = 60

    # The text will display "Unknown Root" and the MAC address of that root.
    $hostText = "<b>Unknown Root Bridge</b><br>$($DummyDevice.HostName)"

    # Deliberately the loudest thing on the page: a root bridge nobody has config for is usually a
    # surprise, and the page exists to surface it.
    $role = (Get-MTAutoDrawPalette -Scope TopologyOverview).Node.Security
    $hostStyle = "rounded=1;whiteSpace=wrap;html=1;fillColor=$($role.Fill);fontColor=$($role.Font);strokeColor=$($role.Stroke);fontSize=12;fontStyle=1;verticalAlign=middle;"
    $hostId = "dummy-root-$($DummyDevice.HostName.Replace('.',''))"
    Register-DrawioShapeId -Id $hostId | Out-Null

    # Store the shape ID back on the object so connectors can find it.
    $DummyDevice.SpanningTree.SpanningTreeArray[0].Shape = $hostId

    # Add the XML for the shape to the global variable.
    Add-DrawioCell -Id "$hostId" -Value ($hostText) -Style "$hostStyle" -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$hostWidth"; Height = "$hostHeight" })

    return [PSCustomObject]@{ Id = $hostId; Width = $hostWidth; Height = $hostHeight }
}




# Draws a device's spanning-tree box at $Location: groups VLANs by root bridge, flags whether the device is a root for any VLAN, and lays out per-VLAN STP boxes. Warns and returns $null when there is no STP data.
# Emits: 3 cell site(s), some in loops. Returns: { Id; Width; Height }.
# Reads globals: $GhostHeaderHeight, $GvlanSpacing
function Add-DrawioSpanningTreeHost {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)]
        $Device,
        [parameter(Mandatory = $true)]
        [PSCustomObject]$Location
    )

    if (-not $Device.SpanningTree -or $Device.SpanningTree.SpanningTreeArray.Count -eq 0) {
        Write-Warning "Device $($Device.HostName) has no valid spanning tree data. Skipping."
        return $null
    }

    # --- Section 1: Data Aggregation & Pre-calculation ---
    $vlanGroupsByRootBridge = $Device.SpanningTree.SpanningTreeArray | Group-Object -Property Address
    $isRootForAnyVlan = ($Device.SpanningTree.SpanningTreeArray | Where-Object { $_.RootBridge -eq $true }).Count -gt 0

    Write-MTAutoDrawLog -Level Debug -Phase Draw -Message "Processing spanning-tree host $($Device.HostName). Is root for any VLAN: $isRootForAnyVlan"

    $vlanBoxCalculations = @()

    # First pass: Calculate dimensions for all VLAN boxes to determine the host container size
    foreach ($group in $vlanGroupsByRootBridge) {

        $vlanArray = @($group.Group.VlanID)

        # Compress the VLAN list to range notation ("1-7, 9, 12-14") instead of a raw comma list -
        # a device that is root/non-root for a large contiguous block of VLANs no longer needs one
        # line per 15 raw IDs, which is what made these cards wide enough to flatten the page.
        $vlanRangeText = ConvertTo-VlanRangeNotation -VlanIds $vlanArray
        $rangeSegments = @($vlanRangeText -split ', ')
        $maxCharsPerLine = 60
        $formattedVlanLines = [System.Collections.ArrayList]::new()
        $currentLine = ""
        foreach ($segment in $rangeSegments) {
            $candidateLine = if ($currentLine) { "$currentLine, $segment" } else { $segment }
            if ($currentLine -and $candidateLine.Length -gt $maxCharsPerLine) {
                $null = $formattedVlanLines.Add($currentLine)
                $currentLine = $segment
            }
            else {
                $currentLine = $candidateLine
            }
        }
        if ($currentLine) { $null = $formattedVlanLines.Add($currentLine) }
        if ($formattedVlanLines.Count -eq 0) { $null = $formattedVlanLines.Add("") }
        # Extract Root Priority for this VLAN group (take from first instance)
        $rootPriority = if ($group.Group[0].RootIDPriority) { $group.Group[0].RootIDPriority } else { "N/A" }

        # --- START: Text Formatting Logic ---
        # This section creates the requested format by combining the title with the first line.
        $vlanTitleAndFirstLine = "<b>VLAN(s):</b> " + $formattedVlanLines[0]
        $remainingVlanLines = if ($formattedVlanLines.Count -gt 1) { $formattedVlanLines[1..($formattedVlanLines.Count - 1)] } else { @() }
        $multilineVlans = ($vlanTitleAndFirstLine + $remainingVlanLines) -join "<br>"
        $rootBridgeId = $group.Name
        # Add root priority line before VLAN details
        $vlanBoxText = "<b>Root:</b> $($rootBridgeId)<br><b>Priority:</b> $rootPriority<br><br>$($multilineVlans)"
        
        # --- END: Text Formatting Logic ---

        $baseHeight = 55
        $heightPerVlanLine = 18
        # Add 1 extra line for the new Priority row
        $extraLines = 1
        $calculatedHeight = $baseHeight + (($formattedVlanLines.Count - 1 + $extraLines) * $heightPerVlanLine)

        $firstLineLength = ("VLAN(s): " + $formattedVlanLines[0]).Length
        $otherLinesMaxLength = if ($remainingVlanLines.Count -gt 0) { ($remainingVlanLines | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum } else { 0 }
        $rootLineLength = "Root: $($rootBridgeId)".Length
        $maxLength = @($rootLineLength, $firstLineLength, $otherLinesMaxLength) | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
        $calculatedWidth = ($maxLength * 6.5) + 30

        $vlanBoxCalculations += [PSCustomObject]@{
            Group            = $group
            Width            = $calculatedWidth
            Height           = $calculatedHeight
            Text             = $vlanBoxText
            Identifier       = Register-DrawioShapeId -Id "stp-vlan-$($Device.DeviceIdentifier)-$($rootBridgeId.Replace('.',''))"
        }
    }

    # --- Section 2: Final Host Sizing for Horizontal Layout ---
    $totalVlanBoxesWidth = ($vlanBoxCalculations.Width | Measure-Object -Sum).Sum
    $maxVlanBoxHeight = if ($vlanBoxCalculations.Count -gt 0) { ($vlanBoxCalculations.Height | Measure-Object -Maximum).Maximum } else { 0 }

    $hostWidth = $totalVlanBoxesWidth + (($vlanBoxCalculations.Count + 1) * $GvlanSpacing)
    $hostWidth = [System.Math]::Max($hostWidth, 300)
    $hostHeight = $GhostHeaderHeight + $maxVlanBoxHeight + ($GvlanSpacing * 2)

    $localBridgeId = if ($Device.SpanningTree.SpanningTreeArray[0].BridgeIDPriorityaddress) {
        $Device.SpanningTree.SpanningTreeArray[0].BridgeIDPriorityaddress
    } else { "N/A" }

    $hostText = "<b>$($Device.HostName)</b><br>Bridge ID: $($localBridgeId)<br>Mode: $($Device.SpanningTree.SpanningTreeMode)"

    # --- Section 3: Draw the Host and VLAN Boxes ---
    $hostGroupId = New-DrawioId -Prefix 'stphost-group'
    Add-DrawioCell -Id "$hostGroupId" -Value '' -Style "group" -NotConnectable -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$hostWidth"; Height = "$hostHeight" })

    $verticalAlign = if ($isRootForAnyVlan) { "top" } else { "bottom" }
    $role = (Get-MTAutoDrawPalette -Scope SpanningTree).Node.Host
    $hostStyle = "rounded=1;whiteSpace=wrap;html=1;fillColor=$($role.Fill);strokeColor=$($role.Stroke);fontSize=12;fontStyle=1;verticalAlign=$($verticalAlign);spacingTop=4;spacingBottom=4;"
    $hostId = New-DrawioId -Prefix 'stphost-box'
    Add-DrawioCell -Id "$hostId" -Value ($hostText) -Style "$hostStyle" -Parent "$hostGroupId" -Geometry ([pscustomobject]@{ X = "0"; Y = "0"; Width = "$hostWidth"; Height = "$hostHeight" })

    # Second pass: Draw the VLAN boxes horizontally
    $currentVlanX = $GvlanSpacing
    $vlanBoxesY = if ($isRootForAnyVlan) { $GhostHeaderHeight } else { $GvlanSpacing }

    foreach ($calc in $vlanBoxCalculations) {
        $group = $calc.Group
        $instance = (Get-MTAutoDrawPalette -Scope SpanningTree).Instance
        $role = if ($group.Group[0].RootBridge) { $instance.Root } else { $instance.NonRoot }
        $fillColor = $role.Fill
        $strokeColor = $role.Stroke

        $vlanBoxStyle = "rounded=1;whiteSpace=wrap;html=1;arcSize=10;fillColor=$($fillColor);strokeColor=$($strokeColor);fontSize=11;verticalAlign=top;align=left;spacingLeft=5;spacingTop=5;strokeWidth=2;"

        Add-DrawioCell -Id $calc.Identifier -Value $calc.Text -Style $vlanBoxStyle -Parent $hostId -Geometry ([pscustomobject]@{
            X = $currentVlanX; Y = $vlanBoxesY; Width = $calc.Width; Height = $calc.Height
        })

        $group.Group | ForEach-Object {
            if ($_.PSObject.Properties.Name -notcontains 'Shape') {
                $_ | Add-Member -NotePropertyName Shape -NotePropertyValue $calc.Identifier
            } else {
                $_.Shape = $calc.Identifier
            }
        }
        $currentVlanX += $calc.Width + $GvlanSpacing
    }

    return [PSCustomObject]@{ Id = $hostId; Width = $hostWidth; Height = $hostHeight }
}

#-----------------------------------------------------------------------------------------
# Helper Function: Test-MTAutoDrawUntrustedZoneName
#-----------------------------------------------------------------------------------------
# Name heuristic for "this is the untrusted side". Deliberately a heuristic and nothing more: zone
# naming is a site convention, not something the captures declare, so this only drives colour and
# ordering - never which rules or interfaces are shown.
# Emits: nothing. Returns: a value.
# Reads globals: none
function Test-MTAutoDrawUntrustedZoneName {
    [CmdletBinding()]
    param([AllowNull()][string]$ZoneName)
    if (-not $ZoneName) { return $false }
    return [bool]($ZoneName -match '(?i)outside|untrust|wan|internet|external|dmz|guest')
}

#-----------------------------------------------------------------------------------------
# Helper Function: Add-DrawioFirewallNode
#-----------------------------------------------------------------------------------------
# The firewall itself at the centre of its own pages: identity plus the headline counts that say how
# much policy sits behind it. Fixed footprint - the detail lives on the zone and NAT shapes around it.
# Emits: 1 cell. Returns: { Id; Width; Height }.
# Reads globals: none
function Add-DrawioFirewallNode {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $Device,
        [parameter(Mandatory = $true)] [PSCustomObject]$Location,
        [AllowNull()] $Stats = $null
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>$($Device.HostName)</b>")
    $model = if ($Device.Version -and $Device.Version.Hardware) {
        if ($Device.Version.Hardware -is [array]) { $Device.Version.Hardware[0] } else { $Device.Version.Hardware }
    } else { $Device.DeviceType }
    if ($model) { $lines.Add([string]$model) }
    if ($Stats) {
        $lines.Add("$($Stats.ZoneCount) zones | $($Stats.IpInterfaceCount) L3 interfaces")
        if ($Stats.RuleCount -gt 0) { $lines.Add("$($Stats.RuleCount) security rules | $($Stats.NatCount) NAT") }
        if ($Stats.TunnelCount -gt 0) { $lines.Add("$($Stats.TunnelCount) tunnels") }
    }

    $footprint = Get-DrawioCardFootprint -Lines $lines -Width 300 -BaseHeight 24 -LineHeight 16 -MinHeight 80
    $nodeWidth = $footprint.Width
    $nodeHeight = $footprint.Height
    $role = (Get-MTAutoDrawPalette -Scope Firewall).Node.Firewall
    $style = "rounded=1;whiteSpace=wrap;html=1;fillColor=$($role.Fill);fontColor=$($role.Font);strokeColor=$($role.Stroke);fontSize=12;align=center;verticalAlign=middle;"
    $nodeId = New-DrawioId -Prefix 'fw-node'
    Add-DrawioCell -Id "$nodeId" -Value ($lines -join '<br>') -Style "$style" -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$nodeWidth"; Height = "$nodeHeight" })
    return [PSCustomObject]@{ Id = $nodeId; Width = $nodeWidth; Height = $nodeHeight }
}

#-----------------------------------------------------------------------------------------
# Helper Function: Add-DrawioFirewallZoneNode
#-----------------------------------------------------------------------------------------
# One zone hanging off a firewall. -ShowSubnets controls the two uses: the Overview page draws the
# zone and its interface count only (the segmentation shape of the firewall, nothing more), while the
# NAT & Interfaces page draws each interface with its address. Interface lines are capped with a
# "+N more" tail either way, so a zone with 20 sub-interfaces cannot grow the page.
# Emits: 1 cell. Returns: { Id; Width; Height }.
# Reads globals: none
function Add-DrawioFirewallZoneNode {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] [string]$ZoneName,
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Interfaces,
        [parameter(Mandatory = $true)] [PSCustomObject]$Location,
        [bool]$ShowSubnets = $false,
        [int]$MaxInterfaces = 6
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>$ZoneName</b>")

    $addressed = @($Interfaces | Where-Object { $_.Cidr -or $_.IPAddress })
    if ($ShowSubnets) {
        foreach ($interface in @($Interfaces | Select-Object -First $MaxInterfaces)) {
            $address = if ($interface.Cidr) { [string]$interface.Cidr } elseif ($interface.IPAddress) { [string]$interface.IPAddress } else { 'no address' }
            # Management services reachable on an interface are security-relevant in their own right
            # (FortiGate 'set allowaccess'), so they ride along on the interface line where parsed.
            $access = if ($interface.AllowAccess) { " [$([string]$interface.AllowAccess)]" } else { '' }
            $lines.Add("<font style='font-size:9px'>$($interface.Interface) - $address$access</font>")
        }
        if (@($Interfaces).Count -gt $MaxInterfaces) {
            $lines.Add("<font style='font-size:9px'>+$(@($Interfaces).Count - $MaxInterfaces) more</font>")
        }
        if (@($Interfaces).Count -eq 0) {
            $lines.Add("<font style='font-size:9px'>no matching addressed interface</font>")
        }
    }
    else {
        $suffix = if (@($Interfaces).Count -eq 1) { '' } else { 's' }
        $lines.Add("$(@($Interfaces).Count) interface$suffix")
        if ($addressed.Count -gt 0 -and $addressed.Count -ne @($Interfaces).Count) {
            $lines.Add("$($addressed.Count) addressed")
        }
    }

    $nodeWidth = if ($ShowSubnets) { 260 } else { 220 }
    $nodeHeight = (Get-DrawioCardFootprint -Lines $lines -Width $nodeWidth -BaseHeight 22 -LineHeight 15 -MinHeight 60).Height
    $untrusted = Test-MTAutoDrawUntrustedZoneName -ZoneName $ZoneName
    $palette = Get-MTAutoDrawPalette -Scope Firewall
    $role = if ($untrusted) { (Get-MTAutoDrawPalette -Scope Shared).Node.External } else { $palette.Node.Zone }
    $fill   = $role.Fill
    $stroke = $role.Stroke
    $style = "rounded=1;whiteSpace=wrap;html=1;fillColor=$fill;strokeColor=$stroke;fontSize=10;align=center;verticalAlign=middle;"
    $nodeId = New-DrawioId -Prefix 'fw-zone'
    Add-DrawioCell -Id "$nodeId" -Value ($lines -join '<br>') -Style "$style" -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$nodeWidth"; Height = "$nodeHeight" })
    return [PSCustomObject]@{ Id = $nodeId; Width = $nodeWidth; Height = $nodeHeight }
}

#-----------------------------------------------------------------------------------------
# Helper Function: Add-DrawioNatTranslationNode
#-----------------------------------------------------------------------------------------
# NAT rules collapsed by what they actually translate TO. A typical edge firewall points most of the
# inside at a single public address, so every rule shares one egress interface and one translated
# address; drawing them individually would be N copies of one fact. This draws the translation once and
# lists the source zones feeding it - the same collapse used on the Layer 3 Connectivity page.
# Emits: 1 cell. Returns: { Id; Width; Height }.
# Reads globals: none
function Add-DrawioNatTranslationNode {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $Translation,
        [parameter(Mandatory = $true)] [PSCustomObject]$Location
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $target = if ($Translation.Address) { $Translation.Address } else { 'unresolved translation' }
    $lines.Add("<b>$target</b>")
    if ($Translation.Interface) { $lines.Add([string]$Translation.Interface) }
    if ($Translation.Mode) { $lines.Add("<font style='font-size:9px'>$($Translation.Mode)</font>") }
    $ruleSuffix = if ([int]$Translation.RuleCount -eq 1) { '' } else { 's' }
    $lines.Add("$($Translation.RuleCount) NAT rule$ruleSuffix")
    if (@($Translation.SourceZones).Count -gt 0) {
        $zones = @($Translation.SourceZones)
        $shown = @($zones | Select-Object -First 4) -join ', '
        if ($zones.Count -gt 4) { $shown += ", +$($zones.Count - 4) more" }
        $lines.Add("<font style='font-size:9px'>from: $shown</font>")
    }

    $footprint = Get-DrawioCardFootprint -Lines $lines -Width 280 -BaseHeight 22 -LineHeight 15 -MinHeight 70
    $nodeWidth = $footprint.Width
    $nodeHeight = $footprint.Height
    $role = (Get-MTAutoDrawPalette -Scope Firewall).Node.Nat
    $style = "rounded=1;whiteSpace=wrap;html=1;fillColor=$($role.Fill);strokeColor=$($role.Stroke);fontSize=10;align=center;verticalAlign=middle;"
    $nodeId = New-DrawioId -Prefix 'fw-nat'
    Add-DrawioCell -Id "$nodeId" -Value ($lines -join '<br>') -Style "$style" -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$nodeWidth"; Height = "$nodeHeight" })
    return [PSCustomObject]@{ Id = $nodeId; Width = $nodeWidth; Height = $nodeHeight }
}

#-----------------------------------------------------------------------------------------
# Helper Function: Get-DrawioZoneFlowEdgeStyle
#-----------------------------------------------------------------------------------------
# Edge weight carries how much policy backs a flow, so the dominant paths are visible before any
# label is read. Zone Hub places its two columns around the firewall, so a direct connector is both
# shorter and clearer than draw.io's orthogonal router.
# Emits: nothing. Returns: a value.
# Reads globals: none
function Get-DrawioZoneFlowEdgeStyle {
    [CmdletBinding()]
    param(
        [int]$AllowCount = 1,
        [int]$DenyCount = 0
    )

    $width = if ($AllowCount -ge 20) { 5 } elseif ($AllowCount -ge 10) { 4 } elseif ($AllowCount -ge 5) { 3 } else { 2 }

    # Colour carries the second dimension, since width already carries allow volume: what share of
    # this flow's policy is about blocking rather than permitting.
    #
    # Deny PRESENCE was the original test and it does not survive contact with real data - almost
    # every zone accumulates a deny or two, so 9 of the 10 spokes on the test device came out amber
    # and the colour marked everything. At a quarter of the rules the same device highlights three
    # zones - its two WiFi segments and its cloud-proxy tunnel - which is the set actually worth a
    # second look. Grey where there is no policy at all: an unpoliced segment is an absence of a
    # flow, not a permitted one.
    $total = $AllowCount + $DenyCount
    $link = (Get-MTAutoDrawPalette -Scope Firewall).Link
    $color = if ($total -eq 0) { $link.Allow.Color }
             elseif ($AllowCount -eq 0) { $link.Deny.Color }
             elseif (($DenyCount / [double]$total) -ge 0.25) { $link.Nat.Color }
             else { (Get-MTAutoDrawPalette -Scope Shared).Node.Access.Stroke }
    return "edgeStyle=none;rounded=0;html=1;endArrow=block;strokeWidth=$width;strokeColor=$color;fontSize=9;"
}

#-----------------------------------------------------------------------------------------
# Helper Function: Add-DrawioRiskFindingCard
#-----------------------------------------------------------------------------------------
# One bucket of findings on the FW Rule Risk page: what the finding is, how many rules are in it, and
# enough of their names to go and look them up. Severity drives the colour only - the text always says
# what the finding actually is, because a reader should never have to decode a colour to learn that.
#
# Fixed width, height grows with the (capped) name list, same as the other card families here.
# Emits: 1 cell. Returns: { Id; Width; Height }.
# Reads globals: none
function Add-DrawioRiskFindingCard {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] [string]$Title,
        # Why this bucket matters, in one line. Always drawn - this is what makes the page readable
        # without the documentation next to it.
        [parameter(Mandatory = $true)] [AllowEmptyString()] [string]$Explanation,
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [string[]]$Names,
        [parameter(Mandatory = $true)] [PSCustomObject]$Location,
        [ValidateSet('High', 'Medium', 'Low', 'None')] [string]$Severity = 'Medium',
        [int]$MaxNames = 8
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>$Title</b>")
    if ($Explanation) { $lines.Add("<font style='font-size:9px'>$Explanation</font>") }
    foreach ($name in @($Names | Select-Object -First $MaxNames)) {
        $lines.Add("<font style='font-size:9px'>$name</font>")
    }
    if (@($Names).Count -gt $MaxNames) {
        $lines.Add("<font style='font-size:9px'><i>+$(@($Names).Count - $MaxNames) more - see Objects.json</i></font>")
    }

    $risk = (Get-MTAutoDrawPalette -Scope Firewall).Risk
    $palette = switch ($Severity) {
        'High'   { $risk.High }
        'Medium' { $risk.Medium }
        'Low'    { $risk.Low }
        default  { $risk.Ok }
    }

    $footprint = Get-DrawioCardFootprint -Lines $lines -Width 300 -BaseHeight 20 -LineHeight 15 -MinHeight 70
    $cardWidth = $footprint.Width
    $cardHeight = $footprint.Height
    $style = "rounded=1;whiteSpace=wrap;html=1;fillColor=$($palette.Fill);strokeColor=$($palette.Stroke);fontSize=10;align=left;verticalAlign=top;spacingLeft=8;spacingTop=6;"
    $cardId = New-DrawioId -Prefix 'fw-risk'
    Add-DrawioCell -Id "$cardId" -Value ($lines -join '<br>') -Style "$style" -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$cardWidth"; Height = "$cardHeight" })
    return [PSCustomObject]@{ Id = $cardId; Width = $cardWidth; Height = $cardHeight }
}

#-----------------------------------------------------------------------------------------
# Helper Function: Add-DrawioL3HubNode
#-----------------------------------------------------------------------------------------
# An upstream next hop on the Layer 3 Connectivity page. Shows the next-hop address, the configured
# device that answers for it when one does (resolved through interface, HSRP standby and cluster
# addresses), and how many devices depend on it. A next hop that resolves to nothing configured is
# styled as external - that distinction is the main thing this page is for, since an unresolved hub
# is either a device missing from the capture set or a genuine upstream outside the estate.
# Fixed footprint: the dependant list lives on the dependant nodes, not here.
# Emits: 1 cell. Returns: { Id; Width; Height }.
# Reads globals: none
function Add-DrawioL3HubNode {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $Hub,
        [parameter(Mandatory = $true)] [PSCustomObject]$Location
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($Hub.IsConfigured -and $Hub.DeviceName) {
        $lines.Add("<b>$($Hub.DeviceName)</b>")
        $lines.Add([string]$Hub.Address)
    }
    elseif ($Hub.DeviceName) {
        # External (not captured) next hop that we DID resolve an identity for via ARP - show who
        # it is on the second line, but keep the orange/dashed "not captured" styling below.
        $lines.Add("<b>$($Hub.Address)</b>")
        $lines.Add([string]$Hub.DeviceName)
    }
    else {
        $lines.Add("<b>$($Hub.Address)</b>")
        $lines.Add('external / not captured')
    }
    $suffix = if ([int]$Hub.DependantCount -eq 1) { '' } else { 's' }
    $lines.Add("$($Hub.DependantCount) dependant$suffix")

    $nodeWidth = 240
    $nodeHeight = 70
    $shared = Get-MTAutoDrawPalette -Scope Shared
    $role   = if ($Hub.IsConfigured) { $shared.Node.Access } else { $shared.Node.External }
    $fill   = $role.Fill
    $stroke = $role.Stroke
    $dashed = if ($Hub.IsConfigured) { '' } else { 'dashed=1;' }
    $style = "rounded=1;whiteSpace=wrap;html=1;fillColor=$fill;strokeColor=$stroke;${dashed}fontSize=11;align=center;verticalAlign=middle;"
    $nodeId = New-DrawioId -Prefix 'l3conn-hub'
    Add-DrawioCell -Id $nodeId -Value ($lines -join '<br>') -Style $style -Geometry ([pscustomobject]@{
        X = $Location.X; Y = $Location.Y; Width = $nodeWidth; Height = $nodeHeight
    })
    return [PSCustomObject]@{ Id = $nodeId; Width = $nodeWidth; Height = $nodeHeight }
}

# A configured device that is both depended on and routes upstream is one visual identity. The
# outer container owns one child per next-hop address plus an optional outbound-routing child;
# child panels explain the next-hop identities and outbound behavior; connectors terminate on the
# visible container boundary so a high-degree device reads as one centre instead of lines cutting
# through whichever internal panel happens to name the relationship.
function Get-DrawioL3CompositeDeviceFootprint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Node)

    $panelCount = @($Node.HubPanels).Count + $(if ($Node.Behavior.Signature) { 1 } else { 0 })
    return [pscustomobject]@{ Width = 320; Height = 54 + ($panelCount * 64) + 16 }
}

function Add-DrawioL3CompositeDeviceNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Node,
        [Parameter(Mandatory = $true)][PSCustomObject]$Location
    )

    $fp = Get-DrawioL3CompositeDeviceFootprint -Node $Node
    $groupId = New-DrawioId -Prefix 'l3conn-device'
    Add-DrawioCell -Id $groupId -Value '' -Style 'group' -NotConnectable -Geometry ([pscustomobject]@{
        X = $Location.X; Y = $Location.Y; Width = $fp.Width; Height = $fp.Height
    })

    $palette = Get-MTAutoDrawPalette -Scope Shared
    $backgroundId = New-DrawioId -Prefix 'l3conn-device-box'
    $backgroundStyle = "rounded=1;whiteSpace=wrap;html=1;fillColor=$($palette.Node.Access.Fill);strokeColor=$($palette.Node.Access.Stroke);strokeWidth=2;dashed=1;fontSize=12;fontStyle=1;align=left;verticalAlign=top;spacingLeft=10;spacingTop=8;"
    Add-DrawioCell -Id $backgroundId -Value "<b>$($Node.HostName)</b>" -Style $backgroundStyle -Parent $groupId `
        -Geometry ([pscustomobject]@{ X = 0; Y = 0; Width = $fp.Width; Height = $fp.Height })

    $hubIds = @{}
    $y = 42
    foreach ($hub in @($Node.HubPanels | Sort-Object Address)) {
        $id = New-DrawioId -Prefix 'l3conn-device-hub'
        $style = "rounded=1;whiteSpace=wrap;html=1;fillColor=$($palette.Text.Inverse);strokeColor=$($palette.Node.Access.Stroke);fontSize=10;align=center;verticalAlign=middle;"
        $suffix = if ([int]$hub.DependantCount -eq 1) { '' } else { 's' }
        Add-DrawioCell -Id $id -Value "<b>next hop $($hub.Address)</b><br>$($hub.DependantCount) dependant$suffix" -Style $style -Parent $groupId `
            -Geometry ([pscustomobject]@{ X = 16; Y = $y; Width = 288; Height = 52 })
        $hubIds[[string]$hub.Address] = $id
        $y += 64
    }

    $outboundId = $null
    if ($Node.Behavior.Signature) {
        $outboundId = New-DrawioId -Prefix 'l3conn-device-outbound'
        $collapsed = (Get-MTAutoDrawPalette -Scope L3Topology).Node.Collapsed
        $style = "rounded=1;whiteSpace=wrap;html=1;fillColor=$($collapsed.Fill);strokeColor=$($collapsed.Stroke);fontSize=10;align=center;verticalAlign=middle;"
        $routeCount = @($Node.Behavior.Facts).Count
        $summary = if ($Node.Behavior.HasDefaultRoute -and $routeCount -eq 1) { 'default route only' }
            elseif ($Node.Behavior.HasDefaultRoute) { "default + $($routeCount - 1) other routes" }
            else { "$routeCount routed entries" }
        $protocols = @($Node.Behavior.Protocols) -join ' / '
        Add-DrawioCell -Id $outboundId -Value "<b>routes upstream</b><br>$summary<br>$protocols" -Style $style -Parent $groupId `
            -Geometry ([pscustomobject]@{ X = 16; Y = $y; Width = 288; Height = 52 })
    }

    return [pscustomobject]@{ Id = $groupId; BoundaryId = $backgroundId; Width = $fp.Width; Height = $fp.Height; HubIds = $hubIds; OutboundId = $outboundId }
}

#-----------------------------------------------------------------------------------------
# Helper Function: Add-DrawioL3DependantNode
#-----------------------------------------------------------------------------------------
# Measures an Add-DrawioL3DependantNode card. The draw function uses the same helper, keeping
# placement and rendering on one formula. Emits nothing.
# Returns: { Width; Height }.
#
# Two line heights, not one, which is why this is not Get-DrawioCardFootprint: the member-name list
# is set at 9px and wraps, the rest of the card is 15px and does not. 46 characters is what fits
# across a 260px card at that size.
# Emits: nothing. Returns: { Width; Height }.
# Reads globals: none
function Get-DrawioL3DependantNodeFootprint {
    [CmdletBinding()]
    param([parameter(Mandatory = $true)] $Group, [int]$MaxNames = 0)

    $names = @($Group.Devices)
    $displayNameCount = if ($MaxNames -gt 0) { [Math]::Min($names.Count, $MaxNames) } else { $names.Count }
    $overflowLineCount = if ($MaxNames -gt 0 -and $names.Count -gt $MaxNames) { 1 } else { 0 }
    $lineCount = 2 # headline + summary line
    if ($Group.Protocols -and @($Group.Protocols).Count -gt 0) { $lineCount++ }
    # Every hostname gets its own compact line. These are detail/identity summaries, not overview
    # overflow cards: hiding members behind "+N more" made it impossible to tell what was merged.
    $nameLineCount = if ($names.Count -gt 1) { $displayNameCount + $overflowLineCount } else { 0 }
    $lineCount += $nameLineCount
    $nodeHeight = 46 + (($lineCount - 1 - $nameLineCount) * 15) + ($nameLineCount * 13)
    $nodeHeight = [Math]::Max(60, $nodeHeight)
    return [PSCustomObject]@{ Width = 260; Height = $nodeHeight }
}
# One node per distinct routing signature. When several devices share the exact same significant
# route set they share this node, whose dynamically measured body lists every member hostname.
# Emits: 1 cell. Returns: { Id; Width; Height }.
# Reads globals: none
function Add-DrawioL3DependantNode {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] $Group,
        [parameter(Mandatory = $true)] [PSCustomObject]$Location,
        [int]$MaxNames = 0
    )

    $names = @($Group.Devices)
    $lines = [System.Collections.Generic.List[string]]::new()

    if ($names.Count -eq 1) {
        $lines.Add("<b>$($names[0])</b>")
    }
    else {
        $lines.Add("<b>$($names.Count) devices</b>")
    }

    # What the group has in common is the interesting part - state it once rather than per device.
    $routeSuffix = if ([int]$Group.RouteCount -eq 1) { '' } else { 's' }
    $summary = if ($Group.HasDefaultRoute -and [int]$Group.RouteCount -eq 1) {
        'default route only'
    }
    elseif ($Group.HasDefaultRoute) {
        "default + $($Group.RouteCount - 1) route$(if(($Group.RouteCount - 1) -eq 1){''}else{'s'})"
    }
    else {
        "$($Group.RouteCount) route$routeSuffix"
    }
    $lines.Add($summary)
    if ($Group.Protocols -and @($Group.Protocols).Count -gt 0) {
        $lines.Add((@($Group.Protocols) -join ' / '))
    }

    if ($names.Count -gt 1) {
        $orderedNames = @($names | Sort-Object)
        $shownNames = if ($MaxNames -gt 0) { @($orderedNames | Select-Object -First $MaxNames) } else { $orderedNames }
        foreach ($name in $shownNames) {
            $lines.Add("<font style='font-size:9px'>$name</font>")
        }
        if ($MaxNames -gt 0 -and $orderedNames.Count -gt $MaxNames) {
            $lines.Add("<font style='font-size:9px'>+$($orderedNames.Count - $MaxNames) more</font>")
        }
    }

    $footprint = Get-DrawioL3DependantNodeFootprint -Group $Group -MaxNames $MaxNames
    $nodeWidth = $footprint.Width
    $nodeHeight = $footprint.Height

    # A collapsed group reads as a stack; a single device keeps the plain host colour so the two are
    # never confused at a glance.
    $shared = Get-MTAutoDrawPalette -Scope Shared
    $collapsed = (Get-MTAutoDrawPalette -Scope L3Topology).Node.Collapsed
    $role   = if ($names.Count -gt 1) { $collapsed } else { $shared.Node.Access }
    $fill   = $role.Fill
    $stroke = $role.Stroke
    $style = "rounded=1;whiteSpace=wrap;html=1;fillColor=$fill;strokeColor=$stroke;fontSize=10;align=center;verticalAlign=middle;"
    $nodeId = New-DrawioId -Prefix 'l3conn-dep'
    Add-DrawioCell -Id "$nodeId" -Value ($lines -join '<br>') -Style "$style" -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$nodeWidth"; Height = "$nodeHeight" })
    return [PSCustomObject]@{ Id = $nodeId; Width = $nodeWidth; Height = $nodeHeight }
}

# Measures/draws a summary used by Layer 3 All and Routed Links Only. Each hostname and each
# interface/IP row is emitted in full; the shared behavior is represented by the block's edges.
function Get-DrawioL3DetailSummaryFootprint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Block)

    $lineCount = 2
    foreach ($member in @($Block.Members)) {
        $lineCount++
        $lineCount += @($member.Rows).Count
    }
    return [pscustomobject]@{ Width = 380; Height = [Math]::Max(90, 24 + ($lineCount * 14)) }
}

function Add-DrawioL3DetailSummaryNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Block,
        [Parameter(Mandatory = $true)][PSCustomObject]$Location
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>$(@($Block.HostNames).Count) devices - identical visible L3 behavior</b>")
    $routeCount = @($Block.Behavior.Facts).Count
    $routeText = if ($Block.Behavior.HasDefaultRoute -and $routeCount -eq 1) { 'default route only' }
        elseif ($Block.Behavior.HasDefaultRoute) { "default + $($routeCount - 1) other routes" }
        else { "$routeCount routed entries" }
    $lines.Add($routeText)
    foreach ($member in @($Block.Members | Sort-Object HostName)) {
        $lines.Add("<b>$($member.HostName)</b>")
        foreach ($row in @($member.Rows | Sort-Object Cidr, Interface, IPAddress)) {
            $lines.Add("<font style='font-size:9px'>$($row.Interface) - $($row.IPAddress) ($($row.Cidr))</font>")
        }
    }

    $footprint = Get-DrawioL3DetailSummaryFootprint -Block $Block
    $role = (Get-MTAutoDrawPalette -Scope L3Topology).Node.Collapsed
    $style = "rounded=1;whiteSpace=wrap;html=1;fillColor=$($role.Fill);strokeColor=$($role.Stroke);strokeWidth=2;fontSize=10;align=left;verticalAlign=top;spacingLeft=8;spacingTop=6;"
    $id = New-DrawioId -Prefix 'l3-detail-summary'
    Add-DrawioCell -Id $id -Value ($lines -join '<br>') -Style $style -Geometry ([pscustomobject]@{
        X = $Location.X; Y = $Location.Y; Width = $footprint.Width; Height = $footprint.Height
    })
    return [pscustomobject]@{ Id = $id; Width = $footprint.Width; Height = $footprint.Height }
}

#-----------------------------------------------------------------------------------------
# Helper Function: Add-DrawioOverflowSummaryCard
#-----------------------------------------------------------------------------------------
# Generic "+N more, ranked lowest-first, here are some of their names" bucket card. The ARP Overview
# page needs this cap-and-summarize treatment for both its network column and its gateway-card
# section once a site has more of either than reasonably fits - one fixed-family shape, three
# overflow use cases.
# Emits: 1 cell. Returns: { Id; Width; Height }.
# Reads globals: none
function Add-DrawioOverflowSummaryCard {
    [CmdletBinding()]
    param(
        # e.g. "+33 other networks" or "+35 other multi-homed devices".
        [parameter(Mandatory = $true)] [string]$TitleText,
        # Optional second line, e.g. a total/context count. Pass "" to omit.
        [AllowEmptyString()] [string]$DetailLine = "",
        # Names to list, capped internally with a "+N more" tail past the cap.
        [parameter(Mandatory = $true)] [AllowEmptyString()] [string[]]$Names,
        [parameter(Mandatory = $true)] [PSCustomObject]$Location
    )

    $cardWidth = 240
    $cardHeight = 100
    $displayCap = 12
    $shownNames = @($Names | Select-Object -First $displayCap)
    $overflowCount = [Math]::Max(0, $Names.Count - $displayCap)
    $namesText = ($shownNames -join ", ")
    if ($overflowCount -gt 0) { $namesText += ", +$overflowCount more" }

    $textLines = [System.Collections.ArrayList]::new()
    $null = $textLines.Add("<b>$TitleText</b>")
    if ($DetailLine) { $null = $textLines.Add($DetailLine) }
    $null = $textLines.Add($namesText)

    $surface = (Get-MTAutoDrawPalette -Scope Shared).Surface.Muted
    $cardStyle = "rounded=1;whiteSpace=wrap;html=1;fillColor=$($surface.Fill);strokeColor=$($surface.Stroke);fontSize=10;verticalAlign=top;align=left;spacingLeft=8;spacingTop=6;dashed=1;"
    $cardId = New-DrawioId -Prefix 'overview-overflow'
    Add-DrawioCell -Id "$cardId" -Value (($textLines -join "<br>")) -Style "$cardStyle" -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$cardWidth"; Height = "$cardHeight" })
    return [PSCustomObject]@{ Id = $cardId; Width = $cardWidth; Height = $cardHeight }
}



#-----------------------------------------------------------------------------------------
# Helper Function: Add-DrawioEndUnitBlock
#-----------------------------------------------------------------------------------------
# One card standing for every NEIGHBOUR WE HAVE NO CONFIG FOR that terminates on a single parent -
# the access points, phones and cameras that make up most of a site's node count while carrying no
# topology of their own. A device we parsed is never in here, however few links it has; it gets its
# own card. See Get-MTAutoDrawEndUnitGroups for why the rest are collapsed and
# Get-MTAutoDrawEndUnitBlockLayout for how the size is decided.
#
# Deliberately styled as a container rather than a device: square corners and a dashed border, so it
# reads as "several things live here" and is never mistaken for one more switch.
# Emits: 1 cell. Returns: { Id; Width; Height }.
# Reads globals: none
function Add-DrawioEndUnitBlock {
    [CmdletBinding()]
    param(
        # From Get-MTAutoDrawEndUnitBlockLayout - .Width, .Height and the .Lines to print.
        [parameter(Mandatory = $true)] $Layout,
        [parameter(Mandatory = $true)] [int]$Count,
        [parameter(Mandatory = $true)] [PSCustomObject]$Location
    )

    $noun = if ($Count -eq 1) { 'uncaptured neighbour' } else { 'uncaptured neighbours' }
    $textLines = [System.Collections.ArrayList]::new()
    $null = $textLines.Add("<b>$Count $noun</b>")
    foreach ($line in @($Layout.Lines)) { $null = $textLines.Add($line) }

    # Join first, encode once - the same order every other shape on this page uses. Encoding the
    # lines individually and joining with a raw <br> puts a bare '<' inside an XML attribute value,
    # which is malformed and takes the whole page down when it is parsed back.

    $presentation = (Get-MTAutoDrawPalette -Scope TopologyOverview).Node.ObservedPeer
    $style = "rounded=0;whiteSpace=wrap;html=1;fillColor=$($presentation.Fill);strokeColor=$($presentation.Stroke);" +
        "fontColor=$($presentation.Font);strokeWidth=1;dashed=1;fontSize=10;verticalAlign=top;align=left;spacingLeft=6;spacingTop=4;"

    $nodeId = New-DrawioId -Prefix 'end-unit-block'
    $width = [int][Math]::Round([double]$Layout.Width)
    $height = [int][Math]::Round([double]$Layout.Height)
    Add-DrawioCell -Id "$nodeId" -Value (($textLines -join '<br>')) -Style "$style" -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$width"; Height = "$height" })
    return [pscustomobject]@{ Id = $nodeId; Width = $width; Height = $height }
}


#-----------------------------------------------------------------------------------------
# Helper Function: Add-DrawioOverviewFooterNote
#-----------------------------------------------------------------------------------------
# Small fixed text note placed at the bottom of a one-screen overview page, pointing at where the
# detail that page deliberately dropped still lives (a more detailed page, or a CSV/JSON export).
# This is the default detail-recovery path because it survives PDF export and print, unlike a
# hover tooltip - shapes on the overview pages additionally carry a tooltip on top of this.
# Emits: 1 cell. Returns: { Id; Width; Height }.
# Reads globals: none
function Add-DrawioOverviewFooterNote {
    [CmdletBinding()]
    param(
        # Top-left corner for the note.
        [parameter(Mandatory = $true)]
        [PSCustomObject]$Location,
        # The note text. Wrapped in <i>...</i> so it visually reads as a caption, not diagram data.
        # AllowEmptyString: a plain Mandatory [string] would otherwise reject "" outright, which is
        # a real PowerShell gotcha.
        [parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message
    )

    $noteWidth = 1000
    $noteHeight = 40
    $noteStyle = "text;html=1;align=left;verticalAlign=middle;fontSize=10;fontColor=$((Get-MTAutoDrawPalette -Scope Shared).Text.Muted);whiteSpace=wrap;"
    $noteId = New-DrawioId -Prefix 'overview-note'
    Add-DrawioCell -Id "$noteId" -Value ("<i>$Message</i>") -Style "$noteStyle" -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$noteWidth"; Height = "$noteHeight" })
    return [PSCustomObject]@{ Id = $noteId; Width = $noteWidth; Height = $noteHeight }
}


# One palette drives both Topology Overview rendering and its legend. Keeping
# these values together prevents a renderer color change from leaving the key
# behind.
# Emits: nothing. Returns: { Node; Core; Distribution; Access; Security; RootBridge; ObservedPeer; UnknownSTPRoot; UnknownL3Gateway; PossibleDevice; Link; CDP; LLDP; Dual; LowerConfidence; InferredSTP; InferredGateway; InferredOther }.
# Reads globals: none
# ------------------------------------------------------------------------------------------------
# The one palette. Every colour drawn by this repository resolves through here.
#
# Keyed by ROLE, never by name: Node.External.Fill, not $GOrangeFill. The whole value of a palette is
# that changing how "external / not captured" looks is one edit that reaches every page that draws
# one - including its legend entry, because the Label lives here too. That is what stops a legend
# drifting from the thing it explains, and it is why Label is not separated out into the drawing code.
#
# Two roles may share a hex value and still remain distinct. Node.Access and Risk.Ok both use
# #D5E8D4, but coupling them would make a change to one role silently affect the other.
#
# Scopes inherit from Shared. A scope adds the roles only its own pages draw, and overrides nothing -
# if two scopes want the same role to look different, that is two roles.
# ------------------------------------------------------------------------------------------------

# Returns the colour palette for one family of pages. Emits: nothing. Returns: a role tree of
# { Fill; Stroke; Font; ... } objects. Reads globals: none.
$script:GMTAutoDrawPaletteCache = @{}

function Get-MTAutoDrawPalette {
    [CmdletBinding()]
    param(
        [ValidateSet('TopologyOverview', 'L3Topology', 'Firewall', 'Physical', 'SpanningTree', 'Shared')]
        [string]$Scope = 'Shared'
    )

    if ($script:GMTAutoDrawPaletteCache.ContainsKey($Scope)) {
        return $script:GMTAutoDrawPaletteCache[$Scope]
    }

    # --- Roles every scope shares. ---
    $shared = [pscustomobject]@{
        # A device, coloured by the part it plays in the site.
        Node = [pscustomobject]@{
            Core         = [pscustomobject]@{ Fill = '#FFE0B2'; Stroke = '#E65100'; Font = '#000000'; StrokeWidth = 1; Dashed = $false }
            Distribution = [pscustomobject]@{ Fill = '#BBDEFB'; Stroke = '#0D47A1'; Font = '#000000'; StrokeWidth = 1; Dashed = $false }
            Access       = [pscustomobject]@{ Fill = '#D5E8D4'; Stroke = '#82B366'; Font = '#000000'; StrokeWidth = 1; Dashed = $false }
            Security     = [pscustomobject]@{ Fill = '#9C27B0'; Stroke = '#6A1B9A'; Font = '#FFFFFF'; StrokeWidth = 1; Dashed = $false }
            # Something a neighbour told us about that we have no config for. Dashed, always.
            External     = [pscustomobject]@{ Fill = '#FFE0B2'; Stroke = '#E65100'; Font = '#000000'; StrokeWidth = 1; Dashed = $true }
            Inferred     = [pscustomobject]@{ Fill = '#F5F5F5'; Stroke = '#666666'; Font = '#444444'; StrokeWidth = 1; Dashed = $true }
        }
        # Page furniture: surfaces, borders and text that belong to no particular device.
        Surface = [pscustomobject]@{
            Default = [pscustomobject]@{ Fill = '#FFFFFF'; Stroke = '#36393D'; Font = '#000000' }
            Subtle  = [pscustomobject]@{ Fill = '#F5F5F5'; Stroke = '#424242'; Font = '#000000' }
            Muted   = [pscustomobject]@{ Fill = '#EEEEEE'; Stroke = '#757575'; Font = '#666666' }
        }
        Text = [pscustomobject]@{
            Default = '#000000'
            Muted   = '#666666'
            Inverse = '#FFFFFF'
        }
        # What a colour helper returns when it has nothing to work from. White for a malformed rgb()
        # string, so a bad value renders as an uncoloured shape rather than a wrong one; grey for an
        # address no deterministic colour could be derived from.
        Fallback = [pscustomobject]@{
            Unparseable = '#FFFFFF'
            Unknown     = '#808080'
        }
        # The outline a swatch gets when its fill is supplied from outside the palette - a VRF
        # colour, say. Dark enough to read against anything.
        Swatch = [pscustomobject]@{ Stroke = '#263238' }
        # Edges, by what the line means rather than where it is drawn.
        Link = [pscustomobject]@{
            # A legend line demonstrating a line STYLE rather than a link type. Neutral on purpose,
            # so the eye reads the dashes instead of the colour.
            Neutral    = '#37474F'
            # An annotation tying a shape to something that describes it - an ARP cloud to its
            # network - rather than joining two things that are connected.
            Annotation = '#9E9E9E'
            # A device's own interface attached to a network it owns. Green: this is the one edge
            # type that is always a fact rather than an inference.
            Connected  = '#4CAF50'
            # A route this device has learned to a subnet another device owns.
            Routed     = '#0277BD'
            # A spanning-tree path to a root bridge.
            SpanningTree = '#4A148C'
            # A route whose next hop resolves to nothing captured.
            Unresolved = '#FF8C00'
        }
    }

    if ($Scope -eq 'Shared') {
        $script:GMTAutoDrawPaletteCache[$Scope] = $shared
        return $shared
    }

    $palette = switch ($Scope) {
        'TopologyOverview' {
            [pscustomobject]@{
                Node = [pscustomobject]@{
                    Core             = $shared.Node.Core
                    Distribution     = $shared.Node.Distribution
                    Access           = $shared.Node.Access
                    Security         = $shared.Node.Security
                    RootBridge       = [pscustomobject]@{ Fill = '#FFFFFF'; Stroke = '#B71C1C'; Font = '#000000'; StrokeWidth = 3; Dashed = $false }
                    ObservedPeer     = [pscustomobject]@{ Fill = '#CFFAFE'; Stroke = '#0E7490'; Font = '#155E75'; StrokeWidth = 2; Dashed = $false }
                    UnknownSTPRoot   = [pscustomobject]@{ Fill = '#E1D5E7'; Stroke = '#9673A6'; Font = '#4A235A'; StrokeWidth = 3; Dashed = $false }
                    UnknownL3Gateway = [pscustomobject]@{ Fill = '#FFE6CC'; Stroke = '#D79B00'; Font = '#6B4F00'; StrokeWidth = 2; Dashed = $false }
                    PossibleDevice   = [pscustomobject]@{ Fill = '#F5F5F5'; Stroke = '#666666'; Font = '#444444'; StrokeWidth = 1; Dashed = $true }
                }
                # Label travels with the colour so an edge and its legend entry cannot disagree.
                Link = [pscustomobject]@{
                    CDP             = [pscustomobject]@{ Color = '#1565C0'; Label = 'CDP link'; Dashed = $false; DashPattern = '' }
                    LLDP            = [pscustomobject]@{ Color = '#00897B'; Label = 'LLDP link'; Dashed = $false; DashPattern = '' }
                    Dual            = [pscustomobject]@{ Color = '#5E35B1'; Label = 'CDP + LLDP link'; Dashed = $false; DashPattern = '' }
                    LowerConfidence = [pscustomobject]@{ Color = '#5E35B1'; Label = 'Lower-confidence protocol link'; Dashed = $true; DashPattern = '8 8' }
                    InferredSTP     = [pscustomobject]@{ Color = '#9C27B0'; Label = 'Inferred STP path'; Dashed = $true; DashPattern = '8 4' }
                    InferredGateway = [pscustomobject]@{ Color = '#D79B00'; Label = 'Inferred L3 gateway path'; Dashed = $true; DashPattern = '8 4' }
                    InferredOther   = [pscustomobject]@{ Color = '#666666'; Label = 'Other inferred attachment'; Dashed = $true; DashPattern = '2 6' }
                }
            }
        }
        'L3Topology' {
            [pscustomobject]@{
                # Roles here are routing roles, not switching tiers: who holds the way out, who other
                # devices route through, who just owns subnets.
                Node = [pscustomobject]@{
                    Border      = [pscustomobject]@{ Fill = '#FFCDD2'; Stroke = '#C62828'; Font = '#000000' }
                    Transit     = $shared.Node.Distribution
                    Gateway     = $shared.Node.Access
                    Security    = $shared.Node.Security
                    ExternalHop = [pscustomobject]@{ Fill = '#FFE0B2'; Stroke = '#E65100'; Font = '#000000' }
                    SegmentChip = [pscustomobject]@{ Fill = '#ECEFF1'; Stroke = '#546E7A'; Font = '#000000' }
                    # The same chip drawn with a VRF's own colour as its fill: the outline darkens
                    # and the text inverts so it stays readable against any fill.
                    SegmentChipVrf = [pscustomobject]@{ Stroke = '#263238'; Font = '#FFFFFF' }
                    # Several devices sharing one routing signature, drawn as one node. Blue rather
                    # than the plain host green so a stack is never mistaken for a single device.
                    Collapsed   = [pscustomobject]@{ Fill = '#E1F5FE'; Stroke = '#0277BD'; Font = '#000000' }
                }
                Link = [pscustomobject]@{
                    Adjacency    = [pscustomobject]@{ Color = '#546E7A' }
                    Indirect     = [pscustomobject]@{ Color = '#757575' }
                    Fhrp         = [pscustomobject]@{ Color = '#00838F' }
                    SegmentSpoke = [pscustomobject]@{ Color = '#90A4AE' }
                    OspfOverride = '#F9A825'
                }
            }
        }
        'Firewall' {
            [pscustomobject]@{
                Node = [pscustomobject]@{
                    Firewall = $shared.Node.Security
                    Zone     = [pscustomobject]@{ Fill = '#DAE8FC'; Stroke = '#6C8EBF'; Font = '#000000' }
                    Nat      = [pscustomobject]@{ Fill = '#FFF2CC'; Stroke = '#D6B656'; Font = '#000000' }
                }
                # Risk severity, which is a different axis from device role even where a value
                # repeats: Risk.Ok and Node.Access are both #D5E8D4 and mean unrelated things.
                Risk = [pscustomobject]@{
                    High   = [pscustomobject]@{ Fill = '#F8CECC'; Stroke = '#B85450'; Font = '#000000' }
                    Medium = [pscustomobject]@{ Fill = '#FFE6CC'; Stroke = '#D79B00'; Font = '#000000' }
                    Low    = [pscustomobject]@{ Fill = '#FFF2CC'; Stroke = '#D6B656'; Font = '#000000' }
                    Ok     = [pscustomobject]@{ Fill = '#D5E8D4'; Stroke = '#82B366'; Font = '#000000' }
                }
                Link = [pscustomobject]@{
                    Allow = [pscustomobject]@{ Color = '#B3B3B3' }
                    Deny  = [pscustomobject]@{ Color = '#B85450' }
                    Nat   = [pscustomobject]@{ Color = '#D6B656' }
                }
            }
        }
        'Physical' {
            [pscustomobject]@{
                Node = [pscustomobject]@{
                    Host      = $shared.Node.Access
                    Neighbour = [pscustomobject]@{ Fill = '#FFF9C4'; Stroke = '#FBC02D'; Font = '#000000' }
                }
                Port = [pscustomobject]@{
                    # A port that is shut, or down at both link and protocol level.
                    Down    = [pscustomobject]@{ Fill = '#FFCDD2'; Stroke = '#B71C1C'; Font = '#B71C1C' }
                    # A port in a VRF, when the VRF has no colour of its own to use.
                    Vrf     = [pscustomobject]@{ Fill = '#E1BEE7'; Stroke = '#6A1B9A'; Font = '#000000' }
                    # An ordinary up port: white, because the interesting ones are the ones that are not.
                    Normal  = [pscustomobject]@{ Fill = '#FFFFFF'; Stroke = '#424242'; Font = '#000000' }
                    Error   = [pscustomobject]@{ Fill = '#FF9999'; Stroke = '#D32F2F'; Font = '#000000' }
                    # A port with no transceiver fitted, drawn dark so an empty cage reads as empty.
                    Absent  = [pscustomobject]@{ Fill = '#646464'; Stroke = '#000000'; Font = '#FFFFFF' }
                }
                # ARP and MAC clouds hanging off a network or a port. The fill is per-network and
                # comes from Get-ColorFromIp, so only the outline is a palette decision.
                Bubble = [pscustomobject]@{
                    Arp = [pscustomobject]@{ Stroke = '#424242'; Gradient = '#FFFFFF' }
                    Mac = [pscustomobject]@{ Fill = '#f5f5f5'; Stroke = '#666666' }
                }
                # A neighbour we have no config for, coloured by which protocol reported it.
                Neighbour = [pscustomobject]@{
                    Cdp  = [pscustomobject]@{ Fill = '#f5f5f5'; Stroke = '#666666' }
                    Lldp = [pscustomobject]@{ Fill = '#fff9c4'; Stroke = '#fbc02d' }
                }
            }
        }
        'SpanningTree' {
            [pscustomobject]@{
                # The two states a spanning-tree instance can be in, and nothing else.
                Instance = [pscustomobject]@{
                    Root    = [pscustomobject]@{ Fill = '#FFCDD2'; Stroke = '#B71C1C'; Font = '#000000' }
                    NonRoot = [pscustomobject]@{ Fill = '#BBDEFB'; Stroke = '#0D47A1'; Font = '#000000' }
                }
                Node = [pscustomobject]@{ Host = $shared.Node.Access }
            }
        }
    }
    $script:GMTAutoDrawPaletteCache[$Scope] = $palette
    return $palette
}

# Computes the draw.io style/label/colour for a topology-overview link given its protocol(s) and match confidence; lower confidence yields dashed, thinner, more-transparent connectors.
# Emits: nothing. Returns: {  }.
# Reads globals: none
function Get-MTAutoDrawTopologyOverviewConnectorPresentation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Protocols,
        [AllowNull()][string]$MatchConfidence = 'High'
    )

    $palette = Get-MTAutoDrawPalette -Scope TopologyOverview
    $protocolSet = @($Protocols | Where-Object { $_ } | ForEach-Object { ([string]$_).ToUpperInvariant() } | Sort-Object -Unique)
    $definition = if ($protocolSet.Count -gt 1) { $palette.Link.Dual }
        elseif ($protocolSet -contains 'CDP') { $palette.Link.CDP }
        else { $palette.Link.LLDP }
    $isLowerConfidence = $MatchConfidence -in @('Medium','Low')
    $strokeWidth = if ($isLowerConfidence) { 2 } else { 3 }
    $style = "endArrow=none;html=1;strokeWidth=$strokeWidth;strokeColor=$($definition.Color);fontColor=$($definition.Color);fontSize=10;"
    if ($isLowerConfidence) {
        $dashPattern = if ($MatchConfidence -eq 'Low') { '2 6' } else { '8 8' }
        $style += "dashed=1;dashPattern=$dashPattern;opacity=70;"
    }
    return [pscustomobject]@{ Style=$style; Label=$definition.Label; Color=$definition.Color; Protocols=$protocolSet }
}

# Computes the draw.io style/label/colour for an evidence link based on its evidence source (STP / ARP / CAM / other). Returns {Style, Label, Color, ...}.
# Emits: nothing. Returns: {  }.
# Reads globals: none
function Get-MTAutoDrawEvidenceConnectorPresentation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Edge)

    $palette = Get-MTAutoDrawPalette -Scope TopologyOverview
    if ([string]$Edge.EvidenceSources -like 'STP:*') {
        $color = $palette.Link.InferredSTP.Color
        $label = 'STP root path'
    }
    elseif ([string]$Edge.EvidenceSources -like 'ARP:*') {
        $color = $palette.Link.InferredGateway.Color
        $label = 'ARP + CAM'
    }
    elseif ([string]$Edge.EvidenceSources -like 'CAM:*') {
        $color = $palette.Link.InferredGateway.Color
        $label = 'exact MAC + CAM'
    }
    else {
        $color = $palette.Link.InferredOther.Color
        $label = 'possible attachment'
    }

    if ($Edge.Confidence -eq 'Strong') {
        $style = "endArrow=none;html=1;dashed=1;dashPattern=8 4;strokeWidth=3;strokeColor=$color;fontColor=$color;fontSize=10;"
    }
    else {
        $style = "endArrow=none;html=1;dashed=1;dashPattern=2 6;strokeWidth=2;strokeColor=$color;fontColor=$color;fontSize=10;opacity=65;"
    }
    return [pscustomobject]@{ Style=$style; Label=$label }
}

# Draws a node for an LLDP/CDP-observed peer (hostname + remote interface or port ID) at $Location using the 'observed peer' palette. Returns {Id, Width, Height}.
# Emits: 1 cell. Returns: { Id; Width; Height }.
# Reads globals: none
function Add-DrawioObservedPeerNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Peer,
        [Parameter(Mandatory = $true)][PSCustomObject]$Location
    )

    $width = 180
    $height = 58
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>$($Peer.PeerHostname)</b>")
    if ($Peer.PeerRemoteInterface) { $lines.Add([string]$Peer.PeerRemoteInterface) }
    elseif ($Peer.PeerPortID) { $lines.Add("Port ID $($Peer.PeerPortID)") }
    else { $lines.Add('Remote port unresolved') }
    $presentation = (Get-MTAutoDrawPalette -Scope TopologyOverview).Node.ObservedPeer
    $style = "rounded=1;whiteSpace=wrap;html=1;fillColor=$($presentation.Fill);strokeColor=$($presentation.Stroke);strokeWidth=$($presentation.StrokeWidth);fontColor=$($presentation.Font);fontSize=10;verticalAlign=middle;"
    $nodeId = New-DrawioId -Prefix 'observed-peer'
    Add-DrawioCell -Id "$nodeId" -Value (($lines -join '<br>')) -Style "$style" -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$width"; Height = "$height" })
    return [pscustomobject]@{ Id=$nodeId; Width=$width; Height=$height }
}

# Draws a node for an evidence entity (unknown STP root, unknown L3 gateway, endpoint, etc.) at $Location, showing label, MAC, IP, vendor, and VLANs. Returns the node's geometry.
# Emits: 1 cell. Returns: { Id; Width; Height }.
# Reads globals: none
function Add-DrawioTopologyEvidenceNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Node,
        [Parameter(Mandatory = $true)][PSCustomObject]$Location
    )

    $width = 240
    $height = 82
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("<b>$($Node.Label)</b>")
    $displayMac = ConvertTo-NormalizedMacIdentity $Node.Mac
    if ($displayMac) { $displayMac = ($displayMac -split '(.{2})' | Where-Object { $_ }) -join ':' }
    if ($displayMac) { $lines.Add("MAC: $displayMac") }
    if ($Node.Ip) { $lines.Add("IP: $($Node.Ip)") }
    if ($Node.Vendor) { $lines.Add([string]$Node.Vendor) }
    if (@($Node.Vlans).Count -gt 0) { $lines.Add("VLANs: $(@($Node.Vlans) -join ', ')") }

    $palette = Get-MTAutoDrawPalette -Scope TopologyOverview
    $presentation = switch ([string]$Node.Kind) {
        'UnknownSTPRoot' { $palette.Node.UnknownSTPRoot }
        'UnknownL3Gateway' { $palette.Node.UnknownL3Gateway }
        default { $palette.Node.PossibleDevice }
    }
    $dashStyle = if ($presentation.Dashed) { 'dashed=1;opacity=70;' } else { '' }
    $style = "rounded=1;whiteSpace=wrap;html=1;fillColor=$($presentation.Fill);strokeColor=$($presentation.Stroke);strokeWidth=$($presentation.StrokeWidth);fontColor=$($presentation.Font);fontSize=11;verticalAlign=middle;$dashStyle"

    $nodeId = New-DrawioId -Prefix 'evidence-node'
    Add-DrawioCell -Id "$nodeId" -Value (($lines -join '<br>')) -Style "$style" -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$width"; Height = "$height" })
    return [pscustomobject]@{ Id=$nodeId; Width=$width; Height=$height }
}

# Draws the 'Topology Overview' legend box (title, node/link colour swatches and labels) at $Location. Returns the legend group's geometry.
# Emits: 9 cell site(s), some in loops. Returns: { Id; Width; Height }.
# Reads globals: none
function Add-DrawioTopologyOverviewLegend {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][PSCustomObject]$Location)

    $palette = Get-MTAutoDrawPalette -Scope TopologyOverview
    $boxWidth = 1420
    $boxHeight = 305
    $padding = 20
    $columnWidth = 455
    $rowHeight = 32

    $groupId = New-DrawioId -Prefix 'topology-legend'
    Add-DrawioCell -Id "$groupId" -Value '' -Style "group" -NotConnectable -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$boxWidth"; Height = "$boxHeight" })
    $legendSurface = (Get-MTAutoDrawPalette -Scope Shared).Surface.Default
    $backgroundId = New-DrawioId -Prefix 'topology-legend-bg'
    Add-DrawioCell -Id "$backgroundId" -Value '' -Style "rounded=1;whiteSpace=wrap;html=1;fillColor=$($legendSurface.Fill);strokeColor=$($legendSurface.Stroke);shadow=1;" -Parent "$groupId" -Geometry ([pscustomobject]@{ Width = "$boxWidth"; Height = "$boxHeight" })

    $titleId = New-DrawioId -Prefix 'topology-legend-title'
    Add-DrawioCell -Id "$titleId" -Value ('<b>Topology Overview legend</b>') -Style "text;html=1;align=left;verticalAlign=middle;fontSize=14;resizable=0;points=[];" -Parent "$groupId" -Geometry ([pscustomobject]@{ X = "$padding"; Y = "10"; Width = "500"; Height = "24" })

    $nodeHeaderId = New-DrawioId -Prefix 'topology-legend-header'
    Add-DrawioCell -Id "$nodeHeaderId" -Value ('<b>Nodes</b>') -Style "text;html=1;align=left;verticalAlign=middle;fontSize=11;resizable=0;points=[];" -Parent "$groupId" -Geometry ([pscustomobject]@{ X = "$padding"; Y = "38"; Width = "300"; Height = "20" })

    $nodeEntries = @(
        [pscustomobject]@{ Label='Core device'; Style=$palette.Node.Core },
        [pscustomobject]@{ Label='Distribution device'; Style=$palette.Node.Distribution },
        [pscustomobject]@{ Label='Access device'; Style=$palette.Node.Access },
        [pscustomobject]@{ Label='Firewall / security device'; Style=$palette.Node.Security },
        [pscustomobject]@{ Label='STP root (red outline)'; Style=$palette.Node.RootBridge },
        [pscustomobject]@{ Label='Observed LLDP peer'; Style=$palette.Node.ObservedPeer },
        [pscustomobject]@{ Label='Unknown STP root'; Style=$palette.Node.UnknownSTPRoot },
        [pscustomobject]@{ Label='Unknown L3 gateway'; Style=$palette.Node.UnknownL3Gateway },
        [pscustomobject]@{ Label='Possible inferred device'; Style=$palette.Node.PossibleDevice }
    )
    for ($index = 0; $index -lt $nodeEntries.Count; $index++) {
        $column = $index % 3
        $row = [Math]::Floor($index / 3)
        $entryX = $padding + ($column * $columnWidth)
        $entryY = 62 + ($row * $rowHeight)
        $entry = $nodeEntries[$index]
        $dashStyle = if ($entry.Style.Dashed) { 'dashed=1;' } else { '' }
        $swatchId = New-DrawioId -Prefix 'topology-legend-node'
        $swatchStyle = "rounded=1;whiteSpace=wrap;html=1;fillColor=$($entry.Style.Fill);strokeColor=$($entry.Style.Stroke);strokeWidth=$($entry.Style.StrokeWidth);$dashStyle"
        Add-DrawioCell -Id "$swatchId" -Value '' -Style "$swatchStyle" -Parent "$groupId" -Geometry ([pscustomobject]@{ X = "$entryX"; Y = "$entryY"; Width = "38"; Height = "22" })
        $labelId = New-DrawioId -Prefix 'topology-legend-label'
        Add-DrawioCell -Id "$labelId" -Value ([string]$entry.Label) -Style "text;html=1;align=left;verticalAlign=middle;fontSize=10;resizable=0;points=[];" -Parent "$groupId" -Geometry ([pscustomobject]@{ X = "$($entryX + 48)"; Y = "$entryY"; Width = "390"; Height = "22" })
    }

    $linkHeaderId = New-DrawioId -Prefix 'topology-legend-header'
    Add-DrawioCell -Id "$linkHeaderId" -Value ('<b>Links</b>') -Style "text;html=1;align=left;verticalAlign=middle;fontSize=11;resizable=0;points=[];" -Parent "$groupId" -Geometry ([pscustomobject]@{ X = "$padding"; Y = "166"; Width = "300"; Height = "20" })
    $linkEntries = @($palette.Link.CDP,$palette.Link.LLDP,$palette.Link.Dual,$palette.Link.LowerConfidence,$palette.Link.InferredSTP,$palette.Link.InferredGateway,$palette.Link.InferredOther)
    for ($index = 0; $index -lt $linkEntries.Count; $index++) {
        $column = $index % 3
        $row = [Math]::Floor($index / 3)
        $entryX = $padding + ($column * $columnWidth)
        $entryY = 192 + ($row * $rowHeight)
        $entry = $linkEntries[$index]
        $lineId = New-DrawioId -Prefix 'topology-legend-line'
        $dashStyle = if ($entry.Dashed) { "dashed=1;dashPattern=$($entry.DashPattern);" } else { '' }
        $lineStyle = "endArrow=none;html=1;strokeWidth=3;strokeColor=$($entry.Color);$dashStyle"
        Add-DrawioCell -Id $lineId -Value '' -Style $lineStyle -Edge -Parent $groupId -RelativeGeometry -GeometryChildXml @"
                <mxPoint x="$entryX" y="$($entryY + 11)" as="sourcePoint" />
                <mxPoint x="$($entryX + 55)" y="$($entryY + 11)" as="targetPoint" />
"@
        $labelId = New-DrawioId -Prefix 'topology-legend-label'
        Add-DrawioCell -Id "$labelId" -Value ([string]$entry.Label) -Style "text;html=1;align=left;verticalAlign=middle;fontSize=10;resizable=0;points=[];" -Parent "$groupId" -Geometry ([pscustomobject]@{ X = "$($entryX + 65)"; Y = "$entryY"; Width = "370"; Height = "22" })
    }

    return [pscustomobject]@{ Width=$boxWidth; Height=$boxHeight; Id=$groupId }
}

#-----------------------------------------------------------------------------------------
# Helper Function: Add-DrawioTopologyNode
#-----------------------------------------------------------------------------------------
# Draws one compact, FIXED-size device icon for the Site Topology Overview page. Unlike the
# detailed-page host boxes, this shape's footprint never grows with its text - that's what lets
# Draw-SiteTopologyOverviewDiagram plan a predictable nodes-per-row grid and keep the page inside
# its size budget.
# Emits: 1 cell. Returns: { Id; Width; Height }.
# Reads globals: $GDrawioOverviewNodeWidth
function Add-DrawioTopologyNode {
    [CmdletBinding()]
    param(
        # The full device object.
        [parameter(Mandatory = $true)]
        $Device,
        # A PSCustomObject with .X and .Y for the top-left corner of the shape.
        [parameter(Mandatory = $true)]
        [PSCustomObject]$Location,
        # Core / Distribution / Access - a derived, degree-based display tier (see
        # Draw-SiteTopologyOverviewDiagram). Not a real vendor-reported role.
        [parameter(Mandatory = $true)]
        [ValidateSet('Core', 'Distribution', 'Access')]
        [string]$Tier,
        # Firewall/security-relevant device (by DeviceType or Zone-tagged interfaces). Always drawn
        # purple regardless of tier - "this is a firewall" matters more at a glance than link count.
        [bool]$IsSecurity = $false,
        # Spanning-tree root bridge for at least one VLAN. Always drawn with a red outline,
        # matching the root-bridge color used on the Spanning-Tree pages.
        [bool]$IsRootBridge = $false,
        # Resolved CDP/LLDP neighbour count that decided the tier. Only shown on Core/Distribution
        # nodes, so the tiering (a derived heuristic, not a vendor-reported role) is legible at a
        # glance rather than asserted with no visible evidence.
        [int]$Degree = 0
    )

    $nodeWidth = $GDrawioOverviewNodeWidth
    $nodeHeight = 70

    $textLines = [System.Collections.ArrayList]::new()
    $null = $textLines.Add("<b>$($Device.HostName)</b>")
    if ($Device.DeviceType) { $null = $textLines.Add($Device.DeviceType) }
    if ($Tier -ne 'Access') { $null = $textLines.Add("$Degree links") }
    if ($Device.BGP_AS_Number) { $null = $textLines.Add("AS: $($Device.BGP_AS_Number)") }
    if ($IsRootBridge) { $null = $textLines.Add("STP Root") }

    $palette = Get-MTAutoDrawPalette -Scope TopologyOverview
    $presentation = if ($IsSecurity) { $palette.Node.Security } else { $palette.Node.$Tier }
    $fillColor = $presentation.Fill
    $strokeColor = if ($IsRootBridge) { $palette.Node.RootBridge.Stroke } else { $presentation.Stroke }
    $fontColor = $presentation.Font
    $strokeWidth = if ($IsRootBridge) { $palette.Node.RootBridge.StrokeWidth } else { $presentation.StrokeWidth }

    $nodeStyle = "rounded=1;whiteSpace=wrap;html=1;fillColor=$fillColor;strokeColor=$strokeColor;fontColor=$fontColor;strokeWidth=$strokeWidth;fontSize=11;verticalAlign=middle;"

    $nodeId = New-DrawioId -Prefix 'topo-node'
    # Store the id on the device so the caller's connector-drawing phase can find this shape again.
    $Device.TopologyOverviewDrawioId = $nodeId
    # Parallel id for the Layer 3 Routes Summary page (which reuses this node and draws device-level
    # route edges from it). Distinct property so the two pages never clobber each other's id.
    $Device.RoutesSummaryDrawioId = $nodeId

    Add-DrawioCell -Id "$nodeId" -Value (($textLines -join "<br>")) -Style "$nodeStyle" -Geometry ([pscustomobject]@{ X = "$($Location.X)"; Y = "$($Location.Y)"; Width = "$nodeWidth"; Height = "$nodeHeight" })

    return [PSCustomObject]@{ Id = $nodeId; Width = $nodeWidth; Height = $nodeHeight }
}

