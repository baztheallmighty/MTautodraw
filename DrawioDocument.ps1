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

# MTAutoDraw - Drawio document
#
# The .drawio document itself: deterministic ID/colour generation, VLAN range notation used in
# labels, the document lifecycle (Initialize-DrawioFile / Start-DrawioDiagram / End-DrawioDiagram /
# Finalize-DrawioFile / Save-DrawioFile), and the two shared styles (port-channel, connector) every
# page draws from. No layout math, no device model, no parser knowledge - only the document's own
# identity and the styles/IDs every shape function pulls from.
#
# Depends on: nothing
# Loaded by:  AutoDraw.ps1 ($GLibrariesToLoad)
########### Drawio functions to create and save files. ###########

function New-DrawioId {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Prefix)

    if ($null -eq $global:GDrawioIdCounter) { $global:GDrawioIdCounter = 0 }
    $global:GDrawioIdCounter++
    $id = '{0}-{1:D8}' -f $Prefix, $global:GDrawioIdCounter
    Register-DrawioShapeId -Id $id | Out-Null
    return $id
}

# Tracks a freshly-created draw.io shape ID in the current page's shape set (for dedup/lookup). Returns the ID unchanged so it can be used inline.
function Register-DrawioShapeId {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Id)

    if ($global:GCurrentPageShapeIds) {
        [void]$global:GCurrentPageShapeIds.Add($Id)
    }
    return $Id
}

# Derives a stable RGB triplet from a seed string by hashing it and mapping the first bytes into a 48-208 range. Guarantees the same seed always yields the same colour.
function Get-DeterministicRgbColor {
    [CmdletBinding()]
    param([AllowNull()][string]$Seed)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$Seed))
        return '{0},{1},{2}' -f (48 + ($bytes[0] % 160)), (48 + ($bytes[1] % 160)), (48 + ($bytes[2] % 160))
    }
    finally { $sha256.Dispose() }
}

# Compresses a sorted list of VLAN IDs into range notation, e.g. 1,2,3,5,7,8,9 -> "1-3, 5, 7-9".
# Used anywhere a device's VLAN membership would otherwise print as a long raw comma list -
# the Spanning-Tree page and the Spanning-Tree Root Overview page both share this.
function ConvertTo-VlanRangeNotation {
    [CmdletBinding()]
    param(
        # VLAN IDs (int or numeric string). Duplicates and non-numeric entries are ignored.
        [AllowNull()][object[]]$VlanIds
    )

    $numericIds = @($VlanIds | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    if ($numericIds.Count -eq 0) { return "" }

    # Walk the sorted, deduplicated list and collapse consecutive runs into "start-end" spans.
    $ranges = [System.Collections.Generic.List[string]]::new()
    $rangeStart = $numericIds[0]
    $rangeEnd = $numericIds[0]
    for ($i = 1; $i -lt $numericIds.Count; $i++) {
        if ($numericIds[$i] -eq ($rangeEnd + 1)) {
            $rangeEnd = $numericIds[$i]
            continue
        }
        $ranges.Add($(if ($rangeStart -eq $rangeEnd) { "$rangeStart" } else { "$rangeStart-$rangeEnd" }))
        $rangeStart = $numericIds[$i]
        $rangeEnd = $numericIds[$i]
    }
    $ranges.Add($(if ($rangeStart -eq $rangeEnd) { "$rangeStart" } else { "$rangeStart-$rangeEnd" }))

    return ($ranges -join ", ")
}

# Initialises the in-memory draw.io document: resets global counters/page state and opens the root <mxfile> element. Must be called before any Start-DrawioDiagram.
function Initialize-DrawioFile {
    [CmdletBinding()]
    param (
        [string]$FileHost = "PowerShell",
        [string]$Agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) draw.io/27.0.9 Chrome/134.0.6998.205 Electron/35.4.0 Safari/537.36",
        [string]$Version = "27.0.9",
        [int]$Pages = 1
    )
    $global:itemCounter = 0
    $global:GDrawioIdCounter = 0
    $global:GCurrentPageShapeIds = $null
    $global:GCurrentPageEdgeKeys = $null
    # One StringBuilder owns the document buffer. Repeated immutable-string concatenation would copy
    # the complete accumulated XML for every cell and scale poorly on large diagrams.
    # $global:drawioXml remains the reader contract and is materialized in Finalize-DrawioFile.
    $global:GDrawioBuilder = [System.Text.StringBuilder]::new()
    [void]$global:GDrawioBuilder.Append("<mxfile host=`"$FileHost`" agent=`"$Agent`" version=`"$Version`" pages=`"$Pages`">`n")
    $global:drawioXml = ""

}

# Begins a new draw.io page: increments the page counter, opens the <diagram>/<mxGraphModel>/<root> elements and registers the page's shape/edge sets. Pair with End-DrawioDiagram.
function Start-DrawioDiagram {
    [CmdletBinding()]
    param (
        [string]$Name = "Page-$($global:itemCounter + 1)",
        [string]$Id
    )
    $global:itemCounter++
    $global:GCurrentPageShapeIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    # One pair of interface shapes can only be joined by one physical link, but several neighbour
    # entries can resolve to that same pair. Without this the diagram stacks identical edges.
    $global:GCurrentPageEdgeKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ([string]::IsNullOrWhiteSpace($Id)) { $Id = New-DrawioId -Prefix 'page' }
    # Where this page starts in the accumulated XML. Add-DrawioConnector uses it to confirm that
    # both endpoints of a link were actually drawn on THIS page. Shape ids such as
    # $Interface.PhysicalDrawioId are overwritten each time a shape is redrawn, so a page that
    # skips some shapes (for example "CDP-LLDP brief") would otherwise emit links pointing at ids
    # left behind by an earlier page, which draw.io renders as detached stubs at the origin.
    $global:GCurrentPageStart = $global:GDrawioBuilder.Length
    $global:GCurrentPageName = $Name
    [void]$global:GDrawioBuilder.Append("  <diagram name=`"$Name`" id=`"$Id`">`n")
    [void]$global:GDrawioBuilder.Append("    <mxGraphModel dx=`"1731`" dy=`"927`" grid=`"1`" gridSize=`"10`" guides=`"1`" tooltips=`"1`" connect=`"1`" arrows=`"1`" fold=`"1`" page=`"1`" pageScale=`"1`" pageWidth=`"850`" pageHeight=`"1100`" math=`"0`" shadow=`"0`">`n")
    [void]$global:GDrawioBuilder.Append("      <root>`n")
    [void]$global:GDrawioBuilder.Append("        <mxCell id=`"0`" />`n")
    [void]$global:GDrawioBuilder.Append("        <mxCell id=`"1`" parent=`"0`" />`n")
}

# Closes the current draw.io page: appends the </root>, </mxGraphModel>, </diagram> elements and clears the page's shape/edge tracking sets.
function End-DrawioDiagram {
    [CmdletBinding()]
    param ()
    [void]$global:GDrawioBuilder.Append("      </root>`n")
    [void]$global:GDrawioBuilder.Append("    </mxGraphModel>`n")
    [void]$global:GDrawioBuilder.Append("  </diagram>`n")
    $global:GCurrentPageShapeIds = $null
    $global:GCurrentPageEdgeKeys = $null
}

# Closes the root <mxfile> element, marking the in-memory draw.io document as complete. Call once, after the last End-DrawioDiagram.
function Finalize-DrawioFile {
    [CmdletBinding()]
    param ()
    [void]$global:GDrawioBuilder.Append("</mxfile>")
    # The one place the document becomes a string. Save-DrawioFile, layout measurement, and
    # presentation tests consume this finalized representation.
    $global:drawioXml = $global:GDrawioBuilder.ToString()
}

# Writes the accumulated draw.io XML to a file at $Path using UTF-8 encoding.
function Save-DrawioFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $global:drawioXml | Out-File -FilePath $Path -Encoding utf8
}

# This is the single source of truth for stable Port-Channel styles.
function Get-OrSet-PortChannelStyle {
    [CmdletBinding()]
    param(
        [parameter(Mandatory=$true)]
        $channelNumber
    )

    # Check the global cache to see if we've already created a style for this channel.
    if (-not $GruntimePortChannelStyles.ContainsKey($channelNumber)) {

        $rgbColor = Get-DeterministicRgbColor -Seed "port-channel:$channelNumber"
        $hexColor = Convert-RgbToHex -RgbString "rgb($rgbColor)"

        # Store the style object (color and width) in the global cache.
        $GruntimePortChannelStyles[$channelNumber] = @{
            strokeColor = $hexColor
            strokeWidth = "5" # Use a consistent thick stroke for all Port-Channels
        }
    }

    # Return the style object from the cache.
    return $GruntimePortChannelStyles[$channelNumber]
}

# Determines the connector style by calling the new central style function.
function Get-ConnectorStyle {
    [CmdletBinding()]
    param(
        [parameter(Mandatory=$true)]
        $fromInterface,
        # Match confidence of the neighbour entry this connector came from. Anything below an exact
        # hostname/port match is drawn dashed so an inferred link is never mistaken for a verified one.
        [AllowNull()][string]$MatchConfidence
    )

    if ($fromInterface.ChannelGroup) {
        $channelNumber = $fromInterface.ChannelGroup -replace '\D',''
        # Get the cached style object for this channel.
        $styleObject = Get-OrSet-PortChannelStyle -channelNumber $channelNumber

        # Format the style object into a full Draw.io style string for the connector.
        $style = "endArrow=none;html=1;strokeWidth=$($styleObject.strokeWidth);strokeColor=$($styleObject.strokeColor);"
    } else {
        # It's a regular link, so use the default style.
        $style = $GDefaultConnectorStyle
    }

    if ($MatchConfidence -in @('Medium','Low')) {
        $dash = if ($MatchConfidence -eq 'Low') { 'dashed=1;dashPattern=1 3;' } else { 'dashed=1;dashPattern=8 8;' }
        $style = "$style$dash"
    }
    return $style
}
