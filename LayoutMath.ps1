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

# MTAutoDraw - Layout math
#
# Pure geometry and graph maths: text measurement, grid/radial positioning, connected components,
# barycenter/tier ordering, perimeter and radial placement. No .drawio document knowledge, no device
# model knowledge - every function here takes plain data in and returns plain data out. Sits beside
# PlacementStrategies.ps1, which consumes it.
#
# Depends on: nothing
# Loaded by:  AutoDraw.ps1 ($GLibrariesToLoad)
# ============================================================================
# Text measurement - the single source of truth for "how big does this box need to be"
# ============================================================================
# Shared text estimator for every detail-page shape. Centralizing the approximation keeps the
# footprint used for placement consistent with the box drawn around the content.
#
# It works from a plain-text CHARACTER COUNT, not pixel-accurate font metrics - draw.io's HTML
# rendering (bold spans, <br> tags, nbsp) makes true measurement impractical from PowerShell, and an
# approximation that is consistently a little generous is exactly what a "floor, not fixed size" box
# needs: it only has to guarantee text does not overflow its box, not draw it precisely.
function Measure-DrawioTextBlock {
    [CmdletBinding()]
    param(
        # One string per intended line. A single element longer than fits $MaxWidth wraps into
        # additional lines; each element is otherwise never merged with another.
        # AllowEmptyString matters here, not just AllowEmptyCollection: PowerShell's Mandatory check
        # on a [string[]] parameter rejects the whole array if ANY element is an empty string, not
        # just if the array itself has zero elements - and a device with a blank description or no
        # discovered IPs legitimately produces label lines that are "".
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [AllowEmptyString()] [string[]]$Lines,
        [parameter(Mandatory = $true)] [double]$FontSize,
        [parameter(Mandatory = $true)] [double]$MaxWidth,
        # Vertical pixels per line at this font size. 1.5x the font size matches draw.io's default
        # line-height for wrapped HTML labels closely enough for a floor estimate.
        [double]$LineHeightFactor = 1.5,
        # Horizontal padding (both sides combined) subtracted from $MaxWidth before wrapping.
        [double]$HorizontalPadding = 8
    )

    $usableWidth = [Math]::Max(10, $MaxWidth - $HorizontalPadding)
    # An HTML/sans-serif glyph averages roughly 0.58x its font size in width. Bold text (host names,
    # interface names) runs wider than this, but those are also usually the shortest strings in a
    # label, so the overshoot on long body text - where accuracy actually matters - stays small.
    $charsPerLine = [Math]::Max(1, [Math]::Floor($usableWidth / ($FontSize * 0.58)))

    $lineCount = 0
    foreach ($line in $Lines) {
        # HtmlEncode has usually already run on these strings by the time a caller measures them;
        # strip the common entities back to their single-character length so the estimate reflects
        # what actually renders, not the encoded byte count.
        $plain = [string]$line -replace '&lt;br&gt;|<br>', '' -replace '&amp;nbsp;', ' ' -replace '&(?:lt|gt|amp);', '.'
        $lineCount += [Math]::Max(1, [Math]::Ceiling($plain.Length / $charsPerLine))
    }
    if ($lineCount -eq 0) { $lineCount = 1 }

    return [PSCustomObject]@{
        Height = [Math]::Ceiling($lineCount * $FontSize * $LineHeightFactor)
        LineCount = $lineCount
    }
}

# Creates the starting cursor for Get-DrawioWrappedGridPosition.
function New-DrawioGridCursor {
    [CmdletBinding()]
    param(
        [double]$StartX = 100,
        [double]$StartY = 100,
        # How many items to place before wrapping to a new row.
        [int]$ItemsPerRow = 5,
        [double]$HorizontalPadding = 150,
        [double]$VerticalPadding = 100
    )
    return [PSCustomObject]@{
        X = $StartX; Y = $StartY; StartX = $StartX
        ItemsPerRow = $ItemsPerRow; HorizontalPadding = $HorizontalPadding; VerticalPadding = $VerticalPadding
        Column = 0; RowHeight = 0
    }
}

# Advances a wrapping-grid cursor by one item. Every Add-Drawio* shape function in this file draws
# at a given Location and only reports back the size it actually used once it's done (box sizes are
# usually text-driven, not fixed) - so the idiom throughout this codebase is "draw at the cursor's
# current X/Y, then advance the cursor using the size that was actually drawn", never a pre-measure
# step. This helper is exactly that advance step, generalizing the itemsPerRow wrap pattern so the
# overview pages and the Spanning-Tree rework share one
# implementation instead of copy-pasting the row/column math. Typical use:
#   $cursor = New-DrawioGridCursor -ItemsPerRow 7
#   foreach ($thing in $things) {
#       $dimensions = Add-DrawioSomeShape -Thing $thing -Location ([PSCustomObject]@{X=$cursor.X; Y=$cursor.Y})
#       $cursor = Get-DrawioWrappedGridPosition -Cursor $cursor -DrawnWidth $dimensions.Width -DrawnHeight $dimensions.Height
#   }
function Get-DrawioWrappedGridPosition {
    [CmdletBinding()]
    param(
        # Cursor state from the previous call, or a fresh one from New-DrawioGridCursor.
        [parameter(Mandatory = $true)] [PSCustomObject]$Cursor,
        # The size of the item that was just drawn at $Cursor.X / $Cursor.Y.
        [parameter(Mandatory = $true)] [double]$DrawnWidth,
        [parameter(Mandatory = $true)] [double]$DrawnHeight
    )

    $nextColumn = $Cursor.Column + 1
    $rowHeight = [Math]::Max($Cursor.RowHeight, $DrawnHeight)
    if ($nextColumn -ge $Cursor.ItemsPerRow) {
        # Row is full - wrap to a new row under the tallest item seen in the row just finished.
        return [PSCustomObject]@{
            X = $Cursor.StartX; Y = $Cursor.Y + $rowHeight + $Cursor.VerticalPadding
            StartX = $Cursor.StartX; ItemsPerRow = $Cursor.ItemsPerRow
            HorizontalPadding = $Cursor.HorizontalPadding; VerticalPadding = $Cursor.VerticalPadding
            Column = 0; RowHeight = 0
        }
    }
    return [PSCustomObject]@{
        X = $Cursor.X + $DrawnWidth + $Cursor.HorizontalPadding; Y = $Cursor.Y
        StartX = $Cursor.StartX; ItemsPerRow = $Cursor.ItemsPerRow
        HorizontalPadding = $Cursor.HorizontalPadding; VerticalPadding = $Cursor.VerticalPadding
        Column = $nextColumn; RowHeight = $rowHeight
    }
}


# Evenly spaces $Count items around a circle centered on ($CenterX, $CenterY), returning the
# top-left (X, Y) each item should be drawn at. Unlike Get-DrawioWrappedGridPosition, this cannot
# measure-then-advance - draw.io shapes need a Location before they exist, and a real per-item
# size isn't known until after Add-Drawio* draws it - so the caller passes a conservative
# (largest-case) $ItemWidth/$ItemHeight footprint used only to size the radius. Actual boxes are
# never larger than that estimate, so nothing overlaps; the same "guess the footprint, draw,
# accept minor slop" idiom Draw-FirewallZoneHubDiagram already uses for its hub's Y position.
function Get-DrawioRadialPositions {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] [double]$CenterX,
        [parameter(Mandatory = $true)] [double]$CenterY,
        [parameter(Mandatory = $true)] [int]$Count,
        [double]$ItemWidth = 200,
        [double]$ItemHeight = 70,
        [double]$Padding = 40,
        [double]$MinRadius = 260,
        # Angle of the first item, degrees clockwise from the top (12 o'clock). Items are then
        # spread evenly clockwise from there.
        [double]$StartAngleDegrees = -90
    )

    if ($Count -le 0) {
        return [PSCustomObject]@{ Positions = @(); Radius = 0; Bounds = [PSCustomObject]@{ Left = $CenterX; Top = $CenterY; Right = $CenterX; Bottom = $CenterY } }
    }

    # Radius large enough that $Count items, spaced by their diagonal plus padding, fit around the
    # circumference without their bounding boxes overlapping.
    $spacing = [Math]::Sqrt(($ItemWidth * $ItemWidth) + ($ItemHeight * $ItemHeight)) + $Padding
    $radius = [Math]::Max($MinRadius, ($spacing * $Count) / (2 * [Math]::PI))

    $positions = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Count; $i++) {
        $angle = ($StartAngleDegrees + (360.0 * $i / $Count)) * [Math]::PI / 180.0
        $positions.Add([PSCustomObject]@{
            X = [Math]::Round($CenterX + ($radius * [Math]::Cos($angle)) - ($ItemWidth / 2))
            Y = [Math]::Round($CenterY + ($radius * [Math]::Sin($angle)) - ($ItemHeight / 2))
        })
    }

    return [PSCustomObject]@{
        Positions = @($positions)
        Radius    = $radius
        Bounds    = [PSCustomObject]@{
            Left   = $CenterX - $radius - ($ItemWidth / 2)
            Top    = $CenterY - $radius - ($ItemHeight / 2)
            Right  = $CenterX + $radius + ($ItemWidth / 2)
            Bottom = $CenterY + $radius + ($ItemHeight / 2)
        }
    }
}


# ============================================================================
# Tiered placement - straight lines by construction
# ============================================================================
# Straight connectors are a layout property: two ports need facing sides and matching coordinates.
# The detail pages arrange that through these helpers, used together:
#
#   $components = Get-DrawioConnectedComponents -Adjacency $adj -Keys $keys
#   $blocks     = Get-DrawioTierAssignment       -Adjacency $adj -Components $components
#   ... place each block's tiers as rows, left to right, tier 0 at the top ...
#   $slots      = Get-DrawioAlignedSlotPositions -Items $portDesiredPositions -Gap $gap
#
# A device connected to a device above it and a device below it lands in the tier between them, so
# the link to each is a short vertical hop; two devices in the same tier connect with a short
# horizontal hop. Get-DrawioAlignedSlotPositions then nudges each port's position along its side to
# match its peer's, which is what turns "roughly vertical" into "exactly vertical".
#
# CALLER CONTRACT for the collection-returning helpers here (Get-DrawioConnectedComponents,
# Get-DrawioTierAssignment): they `return ,@(...)` so an empty result stays an empty array instead
# of collapsing to $null - PowerShell unrolls a returned collection, and unrolling zero elements
# emits nothing at all. Assign the result directly, as shown above; wrapping the call in @() would
# re-wrap the already-wrapped array and yield a one-element array containing the real array.

# Splits a graph into its connected components. A component with one member (nothing points at it,
# it points at nothing captured) is exactly as valid as a large one - it becomes a single-tier
# block on its own.
function Get-DrawioConnectedComponents {
    [CmdletBinding()]
    param(
        # key -> @(neighbour keys). Keys with no entry are treated as isolated.
        [parameter(Mandatory = $true)] [hashtable]$Adjacency,
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Keys
    )

    $allKeys = @($Keys | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
    if ($allKeys.Count -eq 0) { return , @() }

    $keySet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($key in $allKeys) { [void]$keySet.Add($key) }

    # Symmetric neighbour map restricted to keys actually being placed - an edge is a relationship
    # regardless of which side reported it, and a caller may build adjacency from one direction only.
    $neighbors = @{}
    foreach ($key in $allKeys) { $neighbors[$key] = [System.Collections.Generic.HashSet[string]]::new() }
    foreach ($key in @($Adjacency.Keys)) {
        $from = [string]$key
        if (-not $keySet.Contains($from)) { continue }
        foreach ($peer in @($Adjacency[$key])) {
            $to = [string]$peer
            if (-not $to -or $to -eq $from -or -not $keySet.Contains($to)) { continue }
            [void]$neighbors[$from].Add($to)
            [void]$neighbors[$to].Add($from)
        }
    }

    $visited = [System.Collections.Generic.HashSet[string]]::new()
    $components = [System.Collections.Generic.List[object]]::new()
    # Deterministic seed order (degree desc, then key asc) so the same input always produces the
    # same component order, which is what makes two renders of one capture set byte-comparable.
    foreach ($seedKey in @($allKeys | Sort-Object -Property @{Expression = { $neighbors[$_].Count }; Descending = $true}, @{Expression = { $_ }; Descending = $false})) {
        if ($visited.Contains($seedKey)) { continue }
        $members = [System.Collections.Generic.List[string]]::new()
        $queue = [System.Collections.Generic.Queue[string]]::new()
        $queue.Enqueue($seedKey)
        [void]$visited.Add($seedKey)
        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            $members.Add($current)
            foreach ($peer in @($neighbors[$current] | Sort-Object)) {
                if ($visited.Contains($peer)) { continue }
                [void]$visited.Add($peer)
                $queue.Enqueue($peer)
            }
        }
        $components.Add([PSCustomObject]@{ Members = @($members); Seed = $seedKey; Neighbors = $neighbors })
    }

    return , @($components | Sort-Object -Property @{Expression = { $_.Members.Count }; Descending = $true}, @{Expression = 'Seed'; Descending = $false})
}


# Reorders the members of each tier so connected nodes end up at similar positions, which is the
# standard barycenter heuristic for reducing edge crossings in a layered graph.
#
# Both layered pages need this and neither can use a plain alphabetical order: the Topology
# Overview's tiers are fixed by device degree (Core/Distribution/Access) and its bands wrap into
# several visual rows, while the detail pages' tiers come from BFS depth. Ordering by hostname
# instead - which the Topology Overview did - puts a core switch's access switches wherever the
# alphabet happens to place them, so nearly every link becomes a long diagonal across the page.
#
# Position is the member's INDEX within its tier, which works for both layouts: on a single-row
# tier the index is the column, and on a tier that wraps into a grid, adjacent indices are still
# adjacent on screen for all but one pair per row.
#
# -AdjacentTiersOnly restricts each node's barycenter to neighbours exactly one tier away, the
# classic Sugiyama formulation - correct when tiers come from BFS depth, because a link that skips
# a tier cannot exist. The Topology Overview leaves it off: its tiers are degree buckets, so
# core-to-core and access-to-access links are entirely normal and should still pull their endpoints
# together.
function Get-DrawioBarycenterOrder {
    [CmdletBinding()]
    param(
        # @( @(keysInTier0), @(keysInTier1), ... ) - order within each tier is the starting point.
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Tiers,
        # key -> @(neighbour keys). Treated as symmetric; keys not in $Tiers are ignored.
        [parameter(Mandatory = $true)] [hashtable]$Adjacency,
        [int]$Sweeps = 2,
        [switch]$AdjacentTiersOnly
    )

    $working = [System.Collections.Generic.List[object]]::new()
    foreach ($tier in $Tiers) { $working.Add([System.Collections.Generic.List[string]]::new([string[]]@($tier))) }
    if ($working.Count -eq 0) { return , @() }

    $tierOf = @{}
    for ($t = 0; $t -lt $working.Count; $t++) {
        foreach ($key in $working[$t]) { $tierOf[$key] = $t }
    }

    # Symmetric neighbour map restricted to keys actually being ordered - callers commonly build
    # adjacency from one direction only, and a link is a relationship regardless of which end
    # reported it.
    $neighbors = @{}
    foreach ($key in $tierOf.Keys) { $neighbors[$key] = [System.Collections.Generic.HashSet[string]]::new() }
    foreach ($key in @($Adjacency.Keys)) {
        $from = [string]$key
        if (-not $tierOf.ContainsKey($from)) { continue }
        foreach ($peer in @($Adjacency[$key])) {
            $to = [string]$peer
            if (-not $to -or $to -eq $from -or -not $tierOf.ContainsKey($to)) { continue }
            [void]$neighbors[$from].Add($to)
            [void]$neighbors[$to].Add($from)
        }
    }

    for ($sweep = 0; $sweep -lt $Sweeps; $sweep++) {
        $indexOf = @{}
        for ($t = 0; $t -lt $working.Count; $t++) {
            for ($i = 0; $i -lt $working[$t].Count; $i++) { $indexOf[$working[$t][$i]] = $i }
        }

        for ($t = 0; $t -lt $working.Count; $t++) {
            $scored = [System.Collections.Generic.List[object]]::new()
            for ($i = 0; $i -lt $working[$t].Count; $i++) {
                $key = $working[$t][$i]
                $peers = if ($AdjacentTiersOnly) {
                    @($neighbors[$key] | Where-Object { $tierOf[$_] -eq ($tierOf[$key] - 1) -or $tierOf[$_] -eq ($tierOf[$key] + 1) })
                }
                else {
                    @($neighbors[$key])
                }
                # A node with nothing to be pulled toward keeps its current index, which pins it in
                # place rather than letting it drift to the front and split a run of connected nodes.
                if ($peers.Count -eq 0) {
                    $score = [double]$i
                }
                else {
                    $sum = 0.0
                    foreach ($peer in $peers) { $sum += [double]$indexOf[$peer] }
                    $score = $sum / $peers.Count
                }
                $scored.Add([PSCustomObject]@{ Key = $key; Score = $score; Original = $i })
            }
            # Sorting on Original as the tiebreak is what makes this STABLE - without it two nodes
            # sharing a barycenter swap on every sweep and the order never settles.
            $ordered = @($scored | Sort-Object -Property @{Expression = 'Score'}, @{Expression = 'Original'})
            $working[$t] = [System.Collections.Generic.List[string]]::new()
            foreach ($entry in $ordered) { $working[$t].Add($entry.Key) }
        }
    }

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($tier in $working) { $result.Add(@($tier)) }
    return , @($result)
}


# Assigns every key in a component to a tier (row) by BFS depth from its highest-degree member, then
# orders each tier's members left-to-right with barycenter sweeps so that a device's neighbours in
# the tier above/below end up roughly above/below it - minimising the horizontal jog a connecting
# line has to make even before the slot-alignment pass runs.
function Get-DrawioTierAssignment {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] [hashtable]$Adjacency,
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Keys,
        [int]$BarycenterSweeps = 2
    )

    $components = Get-DrawioConnectedComponents -Adjacency $Adjacency -Keys $Keys
    $blocks = [System.Collections.Generic.List[object]]::new()

    foreach ($component in $components) {
        $neighbors = $component.Neighbors
        $depthOf = @{}
        $queue = [System.Collections.Generic.Queue[string]]::new()
        $queue.Enqueue($component.Seed)
        $depthOf[$component.Seed] = 0
        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            $depth = $depthOf[$current]
            foreach ($peer in @($neighbors[$current] | Sort-Object)) {
                if ($depthOf.ContainsKey($peer)) { continue }
                $depthOf[$peer] = $depth + 1
                $queue.Enqueue($peer)
            }
        }

        $maxDepth = 0
        foreach ($key in $component.Members) { if ($depthOf[$key] -gt $maxDepth) { $maxDepth = $depthOf[$key] } }
        $tiers = [System.Collections.Generic.List[object]]::new()
        for ($d = 0; $d -le $maxDepth; $d++) { $tiers.Add([System.Collections.Generic.List[string]]::new()) }
        foreach ($key in ($component.Members | Sort-Object)) { $tiers[$depthOf[$key]].Add($key) }

        # Barycenter ordering, shared with the Topology Overview page. -AdjacentTiersOnly is right
        # here specifically because these tiers are BFS depths: a link that skips a tier cannot
        # exist, so restricting each node's pull to the tiers immediately above and below loses
        # nothing and matches the classic Sugiyama formulation.
        $componentAdjacency = @{}
        foreach ($key in $component.Members) { $componentAdjacency[$key] = @($neighbors[$key]) }
        $orderedTiers = Get-DrawioBarycenterOrder -Tiers @($tiers | ForEach-Object { , @($_) }) -Adjacency $componentAdjacency -Sweeps $BarycenterSweeps -AdjacentTiersOnly

        # A plain loop, not `$orderedTiers | ForEach-Object { @($_) }` - piping a multi-element tier
        # through ForEach-Object unrolls it back onto the pipeline as separate objects, which
        # silently shatters every tier with more than one member into several single-member tiers.
        $tiersArray = [System.Collections.Generic.List[object]]::new()
        foreach ($tier in $orderedTiers) { $tiersArray.Add(@($tier)) }
        $blocks.Add([PSCustomObject]@{ Tiers = @($tiersArray) })
    }

    return , @($blocks)
}

# Nudges a set of items along one axis towards their individually desired positions, keeping a
# minimum gap between neighbours and preserving the order desire implies.
#
# This is what converts "the tiered layout put these two devices roughly above each other" into an
# exact match: a port's desired position is its peer's own position on the matching side, so when
# nothing is crowded every such pair ends up with identical coordinates and the connecting line is
# perfectly straight. Where multiple ports compete for the same space, order is preserved by
# desired position and the minimum gap is enforced by a single forward sweep - the standard
# constant-time technique for this, at the cost of drift accumulating one direction along a long
# crowded run. That trade-off is fine here: a page dense enough to crowd one side of one device is
# already dense enough that a few degrees of slope on a handful of lines is the least of it.
function Get-DrawioAlignedSlotPositions {
    [CmdletBinding()]
    param(
        # @( @{Key; Desired; Size} ... ) - Desired is the item's target CENTER coordinate; Size is
        # its extent along the axis being solved (chip Width when stacking horizontally on a N/S
        # side, chip Height when stacking vertically on an E/W side).
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Items,
        [double]$Gap = 6,
        # Length of the axis being packed. Results are guaranteed to land inside [0, AxisLength].
        # 0 means unbounded. The caller must size the axis to at least the minimum packing span
        # (sum of sizes plus one gap between each pair) - Get-DrawioPerimeterLayout does.
        [double]$AxisLength = 0
    )

    $entries = @($Items | Where-Object { $_ })
    if ($entries.Count -eq 0) { return @{} }

    $ordered = @($entries | Sort-Object -Property @{Expression = 'Desired'}, @{Expression = 'Key'})

    # Three sweeps, which is what makes the result both ordered and guaranteed in-bounds:
    #   forward  - push right to open up the minimum gap after each item
    #   backward - pull left so the last item ends at AxisLength, cascading to earlier items
    #   forward  - push right again from 0, in case the backward pass drove the first item negative
    # A single forward sweep alone (what this did originally) leaves the tail overhanging whenever
    # several items want the same spot, which put port chips outside their own host's border.
    $starts = [double[]]::new($ordered.Count)
    $cursor = [double]::NegativeInfinity
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        $start = [double]$ordered[$i].Desired - ([double]$ordered[$i].Size / 2.0)
        if ($cursor -ne [double]::NegativeInfinity -and $start -lt $cursor) { $start = $cursor }
        $starts[$i] = $start
        $cursor = $start + [double]$ordered[$i].Size + $Gap
    }

    if ($AxisLength -gt 0) {
        $limit = $AxisLength
        for ($i = $ordered.Count - 1; $i -ge 0; $i--) {
            $maxStart = $limit - [double]$ordered[$i].Size
            if ($starts[$i] -gt $maxStart) { $starts[$i] = $maxStart }
            $limit = $starts[$i] - $Gap
        }
        $cursor = 0.0
        for ($i = 0; $i -lt $ordered.Count; $i++) {
            if ($starts[$i] -lt $cursor) { $starts[$i] = $cursor }
            $cursor = $starts[$i] + [double]$ordered[$i].Size + $Gap
        }
    }

    $positions = @{}
    for ($i = 0; $i -lt $ordered.Count; $i++) { $positions[[string]$ordered[$i].Key] = $starts[$i] }
    return $positions
}

# Which side of a box, viewed from its center, a point in the given direction falls on. Screen
# coordinates: Y increases downward, so "N" (up) is the smaller-Y direction.
#
# The N/S vs E/W split uses the box's own aspect ratio, not a flat 45 degrees: a box's N/S faces
# span its full WIDTH, so the wider the box relative to its height, the larger the range of angles
# that resolve to N/S - only a link within roughly atan(height/width) of dead horizontal exits via
# E/W. A 200x20 card (AspectRatio 10) sends all but the shallowest links out its top or bottom.
function Get-DrawioBearingSide {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] [double]$DeltaX,
        [parameter(Mandatory = $true)] [double]$DeltaY,
        [double]$AspectRatio = 1.0
    )

    if ($DeltaX -eq 0 -and $DeltaY -eq 0) { return 'S' }
    # Normalize so the comparison below is a plain |dy| vs |dx| test regardless of box shape.
    $normalizedDx = $DeltaX
    $normalizedDy = if ($AspectRatio -gt 0) { $DeltaY * $AspectRatio } else { $DeltaY }

    if ([Math]::Abs($normalizedDy) -ge [Math]::Abs($normalizedDx)) {
        return $(if ($normalizedDy -lt 0) { 'N' } else { 'S' })
    }
    return $(if ($normalizedDx -lt 0) { 'W' } else { 'E' })
}

# ============================================================================
# Perimeter port layout - the shape of one device card
# ============================================================================
# Turns a host label size plus a per-side list of port chips into a complete geometry: the host
# box's own width/height (grown past its text-driven floor only as far as a crowded side needs),
# the group's total footprint including the chips sticking out of it, and every chip's position.
#
# Returns the natural span required by one side of a perimeter layout.
function Get-DrawioSideSpan {
    [CmdletBinding()]
    param([object[]]$Ports, [string]$SizeProperty, [double]$Gap)

    $items = @($Ports | Where-Object { $_ })
    if ($items.Count -eq 0) { return 0.0 }
    $total = 0.0
    foreach ($item in $items) { $total += [double]$item.$SizeProperty }
    return $total + ([Math]::Max(0, $items.Count - 1) * $Gap)
}

# Returns collision-free starting coordinates for the ports on one side of a box.
function Get-DrawioSlotStarts {
    [CmdletBinding()]
    param([object[]]$Ports, [string]$SizeProperty, [double]$AxisLength, [double]$Gap)

    $items = @($Ports | Where-Object { $_ })
    if ($items.Count -eq 0) { return @{} }
    $slotItems = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $items.Count; $i++) {
        $item = $items[$i]
        $size = [double]$item.$SizeProperty
        $half = $size / 2.0
        $desired = if ($null -ne $item.Desired) {
            [Math]::Min([Math]::Max([double]$item.Desired, $half), [Math]::Max($half, $AxisLength - $half))
        }
        else { (($i + 0.5) / $items.Count) * $AxisLength }
        $slotItems.Add([pscustomobject]@{ Key = [string]$item.Key; Desired = $desired; Size = $size })
    }
    return Get-DrawioAlignedSlotPositions -Items @($slotItems) -Gap $Gap -AxisLength $AxisLength
}

# Ports never grow the box outward past what their own side's stack needs. A chip's position along
# its side is free to sit anywhere in the box width or height, so passing a $Desired slot
# (typically the peer device's own coordinate, converted into this box's local frame) pulls the chip
# toward whatever makes the connecting line straight, without changing how big the box is.
function Get-DrawioPerimeterLayout {
    [CmdletBinding()]
    param(
        [double]$BoxMinWidth,
        [double]$BoxMinHeight,
        # hashtable: 'N'/'E'/'S'/'W' -> @( @{Key; Width; Height; Desired} ... ). Desired is optional
        # (omit or $null for an even spread) - the chip's target slot coordinate along the side's
        # axis (box-relative X for N/S, box-relative Y for E/W), BEFORE clamping to the box.
        [parameter(Mandatory = $true)] [hashtable]$PortsBySide,
        [double]$Gap = 6
    )

    foreach ($side in @('N', 'E', 'S', 'W')) { if (-not $PortsBySide.ContainsKey($side)) { $PortsBySide[$side] = @() } }

    $northSpan = Get-DrawioSideSpan -Ports $PortsBySide['N'] -SizeProperty 'Width' -Gap $Gap
    $southSpan = Get-DrawioSideSpan -Ports $PortsBySide['S'] -SizeProperty 'Width' -Gap $Gap
    $eastSpan  = Get-DrawioSideSpan -Ports $PortsBySide['E'] -SizeProperty 'Height' -Gap $Gap
    $westSpan  = Get-DrawioSideSpan -Ports $PortsBySide['W'] -SizeProperty 'Height' -Gap $Gap

    $boxWidth  = [Math]::Max($BoxMinWidth, [Math]::Max($northSpan, $southSpan))
    $boxHeight = [Math]::Max($BoxMinHeight, [Math]::Max($eastSpan, $westSpan))

    $northSlots = Get-DrawioSlotStarts -Ports $PortsBySide['N'] -SizeProperty 'Width'  -AxisLength $boxWidth -Gap $Gap
    $southSlots = Get-DrawioSlotStarts -Ports $PortsBySide['S'] -SizeProperty 'Width'  -AxisLength $boxWidth -Gap $Gap
    $eastSlots  = Get-DrawioSlotStarts -Ports $PortsBySide['E'] -SizeProperty 'Height' -AxisLength $boxHeight -Gap $Gap
    $westSlots  = Get-DrawioSlotStarts -Ports $PortsBySide['W'] -SizeProperty 'Height' -AxisLength $boxHeight -Gap $Gap

    # The box is NOT resized from the slot results, deliberately. Slots are already bounded to the
    # box by Get-DrawioAlignedSlotPositions -AxisLength, so nothing can overhang; and growing the
    # box here would make the drawn size differ from the size the page measured to place this
    # device (the footprint pass has no Desired values to work from, the draw pass does), which
    # showed up directly as overlapping device cards.

    # ExtraDepth (optional, defaults to 0) is for something that trails a chip further out the SAME
    # side without taking its own slot along the side - a MAC-address summary bubble hanging off an
    # interface chip is the one user of this today. It adds to how far the side protrudes without
    # adding to the along-side span the slot solver packs.
    $maxHeight = { param($Ports) $h = 0.0; foreach ($p in @($Ports | Where-Object { $_ })) { $depth = [double]$p.Height + $(if ($p.ExtraDepth) { [double]$p.ExtraDepth } else { 0.0 }); if ($depth -gt $h) { $h = $depth } }; return $h }
    $maxWidth  = { param($Ports) $w = 0.0; foreach ($p in @($Ports | Where-Object { $_ })) { $depth = [double]$p.Width + $(if ($p.ExtraDepth) { [double]$p.ExtraDepth } else { 0.0 }); if ($depth -gt $w) { $w = $depth } }; return $w }

    $topProtrusion    = if (@($PortsBySide['N']).Count -gt 0) { (& $maxHeight $PortsBySide['N']) + $Gap } else { 0.0 }
    $bottomProtrusion = if (@($PortsBySide['S']).Count -gt 0) { (& $maxHeight $PortsBySide['S']) + $Gap } else { 0.0 }
    $leftProtrusion   = if (@($PortsBySide['W']).Count -gt 0) { (& $maxWidth  $PortsBySide['W']) + $Gap } else { 0.0 }
    $rightProtrusion  = if (@($PortsBySide['E']).Count -gt 0) { (& $maxWidth  $PortsBySide['E']) + $Gap } else { 0.0 }

    $chipPositions = @{}
    foreach ($port in @($PortsBySide['N'])) {
        $key = [string]$port.Key
        # Bottom-aligned against the box's top edge: the tallest N chip touches Y=0, shorter ones
        # start lower, leaving blank space above rather than a ragged gap against the box.
        $chipPositions[$key] = [PSCustomObject]@{ X = $leftProtrusion + $northSlots[$key]; Y = $topProtrusion - $Gap - [double]$port.Height }
    }
    foreach ($port in @($PortsBySide['S'])) {
        $key = [string]$port.Key
        $chipPositions[$key] = [PSCustomObject]@{ X = $leftProtrusion + $southSlots[$key]; Y = $topProtrusion + $boxHeight + $Gap }
    }
    foreach ($port in @($PortsBySide['W'])) {
        $key = [string]$port.Key
        $chipPositions[$key] = [PSCustomObject]@{ X = $leftProtrusion - $Gap - [double]$port.Width; Y = $topProtrusion + $westSlots[$key] }
    }
    foreach ($port in @($PortsBySide['E'])) {
        $key = [string]$port.Key
        $chipPositions[$key] = [PSCustomObject]@{ X = $leftProtrusion + $boxWidth + $Gap; Y = $topProtrusion + $eastSlots[$key] }
    }

    return [PSCustomObject]@{
        BoxWidth = $boxWidth
        BoxHeight = $boxHeight
        BoxOrigin = [PSCustomObject]@{ X = $leftProtrusion; Y = $topProtrusion }
        TotalWidth = $leftProtrusion + $boxWidth + $rightProtrusion
        TotalHeight = $topProtrusion + $boxHeight + $bottomProtrusion
        ChipPositions = $chipPositions
    }
}

# Lays out the tier blocks from Get-DrawioTierAssignment on the page: each block (connected
# component) becomes a column region, its tiers stacked top to bottom as rows, its members within a
# tier placed left to right in the order Get-DrawioTierAssignment already chose. Row height is the
# tallest footprint in that row; block width is its widest row, so the next block starts clear of
# everything in this one.
#
# Every row is CENTERED within its block, not left-aligned. A device's footprint here is its full
# perimeter-port bounding box, and a wide top-tier hub (say a 12-port switch, protrusions on every
# side) can easily be wider than the handful of narrow leaves below it - left-aligning would then
# leave the hub's actual usable port range sitting well to the right of where its children ended up,
# which the later slot-alignment pass can only partly claw back through clamping. Centering keeps a
# block's rows roughly concentric, so a hub's ports start out close to the X range its children
# already occupy, and the alignment pass finishes the job of making a link exactly straight rather
# than fighting a systematic offset first.
#
# Returns absolute TOP-LEFT page coordinates per key - the same coordinate a group's own mxGeometry
# x/y needs, since a device's footprint (from Get-DrawioPerimeterLayout) already IS the group's full
# bounding box including any protruding ports.
function Get-DrawioTierPlacement {
    [CmdletBinding()]
    param(
        # From Get-DrawioTierAssignment.
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Blocks,
        # key -> @{Width;Height}, one entry per key appearing anywhere in $Blocks.
        [parameter(Mandatory = $true)] [hashtable]$FootprintOf,
        [double]$StartX = 100,
        [double]$StartY = 100,
        [double]$ColumnGap = 90,
        [double]$RowGap = 110,
        [double]$BlockGap = 150,
        # Nothing is allowed to run past this width: a tier wider than it wraps onto further
        # sub-rows, and blocks that no longer fit beside each other wrap onto a further band.
        [double]$MaxRowWidth = 4000
    )

    $positions = @{}

    # --- Pass 1: lay each block out relative to its own (0,0), learning its width and height. ---
    # Two things can make a page unbounded, and both are capped here. A single tier can hold more
    # devices than fit across (one switch reporting ~100 LLDP endpoints puts all 100 in tier 1), and
    # a page can hold more blocks than fit across - every discovered device with no resolved link is
    # its own single-node connected component, and a big site has hundreds of them. Capping only the
    # first still leaves the page tens of thousands of pixels wide.
    $blockLayouts = [System.Collections.Generic.List[object]]::new()
    foreach ($block in $Blocks) {
        $rows = [System.Collections.Generic.List[object]]::new()
        $blockWidth = 0.0
        $y = 0.0

        foreach ($tier in $block.Tiers) {
            $tierMembers = @($tier)
            $rowItems = [System.Collections.Generic.List[object]]::new()
            $rowHeight = 0.0
            $x = 0.0

            for ($i = 0; $i -lt $tierMembers.Count; $i++) {
                $key = [string]$tierMembers[$i]
                $footprint = $FootprintOf[$key]
                $width = [double]$footprint.Width
                $height = [double]$footprint.Height

                # Wrap before placing, never after, so the first item of a sub-row always goes down
                # even when it is wider than the cap on its own.
                if ($rowItems.Count -gt 0 -and ($x + $width) -gt $MaxRowWidth) {
                    $rowWidth = $x - $ColumnGap
                    if ($rowWidth -gt $blockWidth) { $blockWidth = $rowWidth }
                    $rows.Add([PSCustomObject]@{ Items = $rowItems; Width = $rowWidth })
                    $y += $rowHeight + $RowGap
                    $rowItems = [System.Collections.Generic.List[object]]::new()
                    $rowHeight = 0.0
                    $x = 0.0
                }

                $rowItems.Add([PSCustomObject]@{ Key = $key; RelativeX = $x; RelativeY = $y })
                $x += $width + $ColumnGap
                if ($height -gt $rowHeight) { $rowHeight = $height }
            }

            if ($rowItems.Count -gt 0) {
                $rowWidth = $x - $ColumnGap
                if ($rowWidth -gt $blockWidth) { $blockWidth = $rowWidth }
                $rows.Add([PSCustomObject]@{ Items = $rowItems; Width = $rowWidth })
                $y += $rowHeight + $RowGap
            }
        }

        # $y overshoots by one RowGap after the final row.
        $blockHeight = [Math]::Max(0.0, $y - $RowGap)
        $blockLayouts.Add([PSCustomObject]@{ Rows = $rows; Width = $blockWidth; Height = $blockHeight })
    }

    # --- Pass 2: shelf-pack the blocks, wrapping to a new band when one no longer fits across. ---
    $bandX = 0.0
    $bandY = 0.0
    $bandHeight = 0.0
    foreach ($layout in $blockLayouts) {
        if ($bandX -gt 0 -and ($bandX + $layout.Width) -gt $MaxRowWidth) {
            $bandX = 0.0
            $bandY += $bandHeight + $BlockGap
            $bandHeight = 0.0
        }

        # Each of the block's own sub-rows is centered within the block's widest sub-row, so a wide
        # top tier and the narrower rows under it stay concentric - that keeps a hub's ports near
        # the X range its children occupy, which is what the later slot-alignment pass needs to be
        # able to make a link straight rather than fighting a systematic offset first.
        foreach ($row in $layout.Rows) {
            $offsetX = $StartX + $bandX + (($layout.Width - $row.Width) / 2.0)
            foreach ($item in $row.Items) {
                $positions[$item.Key] = [PSCustomObject]@{ X = $item.RelativeX + $offsetX; Y = $item.RelativeY + $StartY + $bandY }
            }
        }

        $bandX += $layout.Width + $BlockGap
        if ($layout.Height -gt $bandHeight) { $bandHeight = $layout.Height }
    }

    return $positions
}


# ============================================================================
# Radial ("starburst") placement
# ============================================================================
# Places a graph as concentric rings around the device that is most central to it: the centre sits
# in the middle, everything one hop away fans out around it, everything two hops away fans out
# again inside the wedge its own parent occupies, and so on.
#
# This exists because the row-and-band layout Get-DrawioTierPlacement produces is the wrong shape
# for a whole-site map. Bands are read left to right, but a network has no left and no right - it
# has a middle and a periphery. Flattening that into rows forces every link between two devices in
# the same band to run sideways past whatever else the band happens to contain, which is what turns
# a large overview into a hairball: hundreds of edges running straight through unrelated device
# cards, and a thousand or more edge crossings.
#
# What makes the radial form work is that hop distance becomes RADIUS and subtree membership
# becomes ANGLE. A link between a device and its parent is then a short, roughly radial line, and
# two devices in different branches are separated by angle rather than by whatever else is in the
# row - so a line from one branch physically cannot pass through another branch's cards on its way
# in. Crossings that remain come from genuine cross-links (a dual-homed access switch reaching two
# distribution switches), which no planar layout could remove either.
#
# Geometry contract - both of these are proved, not tuned, and both rest on the same observation:
# if |dx| < A and |dy| < B then the centre distance is strictly less than sqrt(A^2 + B^2), so a
# centre distance of at least sqrt(A^2 + B^2) is sufficient for two axis-aligned boxes to clear
# each other whatever direction they lie in.
#   * BETWEEN RINGS - consecutive ring radii differ by at least sqrt((W+NodeGap)^2 + (H+RingGap)^2).
#     Two nodes on different rings differ in radius by at least that step, and centre distance is
#     at least the radius difference, so they cannot overlap.
#   * WITHIN A RING - each node is allocated an arc at least as long as the separation its own
#     neighbours on that ring need. That requirement is direction-aware: two cards side by side
#     (tangent horizontal, i.e. at the top or bottom of the ring) need the full card width apart,
#     but two cards stacked (tangent vertical, at the left or right of the ring) only need the card
#     HEIGHT apart - which for a 200x70 card is less than half as much, and is where most of this
#     layout's compactness comes from.
# A final verification pass re-checks every pair and grows the radii before recalculating positions
# if any overlap remains. This protects the one approximation above: arc length is used where
# chord length is what geometrically matters, which is exact in the limit and slightly optimistic
# on a ring holding only two or three nodes.
function Get-DrawioSafeSeparation {
    [CmdletBinding()]
    param([double]$Width, [double]$Height, [double]$GapX, [double]$GapY)
    return [Math]::Sqrt([Math]::Pow($Width + $GapX, 2) + [Math]::Pow($Height + $GapY, 2))
}

function Get-DrawioTangentialDemand {
    [CmdletBinding()]
    param([double]$Width, [double]$Height, [double]$GapX, [double]$GapY, [System.Nullable[double]]$Angle)

    $diagonal = Get-DrawioSafeSeparation -Width $Width -Height $Height -GapX $GapX -GapY $GapY
    if ($null -eq $Angle) { return $diagonal }
    $sine = [Math]::Abs([Math]::Sin($Angle))
    $cosine = [Math]::Abs([Math]::Cos($Angle))
    $byWidth = if ($sine -gt 1e-6) { ($Width + $GapX) / $sine } else { [double]::PositiveInfinity }
    $byHeight = if ($cosine -gt 1e-6) { ($Height + $GapY) / $cosine } else { [double]::PositiveInfinity }
    return [Math]::Min($diagonal, [Math]::Min($byWidth, $byHeight))
}

function Get-DrawioSubtreeWeights {
    [CmdletBinding()]
    param(
        [object[]]$Members, [hashtable]$RingOf, [hashtable]$ChildrenOf, [hashtable]$SizeOf,
        [int]$MaxRing, [double]$NodeGap, [double]$RingGap, [AllowNull()][hashtable]$AngleOf
    )

    $weightOf = @{}
    for ($ring = $MaxRing; $ring -ge 0; $ring--) {
        foreach ($member in @($Members | Where-Object { $RingOf[$_] -eq $ring })) {
            $size = $SizeOf[$member]
            $angle = if ($AngleOf -and $AngleOf.ContainsKey($member)) { [System.Nullable[double]]$AngleOf[$member] } else { $null }
            $own = Get-DrawioTangentialDemand -Width $size.Width -Height $size.Height -GapX $NodeGap -GapY $RingGap -Angle $angle
            $childSum = 0.0
            foreach ($child in $ChildrenOf[$member]) { $childSum += $weightOf[$child] }
            $weightOf[$member] = [Math]::Max($own, $childSum)
        }
    }
    return $weightOf
}

function Set-DrawioRadialBranchAngles {
    [CmdletBinding()]
    param(
        [string]$Key, [double]$From, [double]$To,
        [hashtable]$AngleOf, [hashtable]$WedgeOf, [hashtable]$ChildrenOf, [hashtable]$WeightOf
    )

    $AngleOf[$Key] = ($From + $To) / 2.0
    $WedgeOf[$Key] = $To - $From
    $children = @($ChildrenOf[$Key])
    if ($children.Count -eq 0) { return }
    $childTotal = 0.0
    foreach ($child in $children) { $childTotal += $WeightOf[$child] }
    if ($childTotal -le 0) { return }
    $cursor = $From
    foreach ($child in $children) {
        $span = ($To - $From) * ($WeightOf[$child] / $childTotal)
        Set-DrawioRadialBranchAngles -Key $child -From $cursor -To ($cursor + $span) `
            -AngleOf $AngleOf -WedgeOf $WedgeOf -ChildrenOf $ChildrenOf -WeightOf $WeightOf
        $cursor += $span
    }
}

function Get-DrawioRadialAngles {
    [CmdletBinding()]
    param([hashtable]$WeightOf, [object[]]$Centers, [hashtable]$ChildrenOf, [hashtable]$PeersOf)

    $angleOf = @{}
    $wedgeOf = @{}
    $twoPi = 2.0 * [Math]::PI
    if ($Centers.Count -eq 1) {
        $angleOf[$Centers[0]] = 0.0
        $wedgeOf[$Centers[0]] = $twoPi
        $children = @($ChildrenOf[$Centers[0]])
        $childTotal = 0.0
        foreach ($child in $children) { $childTotal += $WeightOf[$child] }
        $cursor = -[Math]::PI
        foreach ($child in $children) {
            $span = if ($childTotal -gt 0) { $twoPi * ($WeightOf[$child] / $childTotal) } else { 0.0 }
            Set-DrawioRadialBranchAngles -Key $child -From $cursor -To ($cursor + $span) `
                -AngleOf $angleOf -WedgeOf $wedgeOf -ChildrenOf $ChildrenOf -WeightOf $WeightOf
            $cursor += $span
        }
    }
    else {
        $leftKey = $Centers[0]; $rightKey = $Centers[1]
        $ringOneOrder = @(@($ChildrenOf[$rightKey]) + @($ChildrenOf[$leftKey]))
        $rightOnly = [System.Collections.Generic.List[string]]::new()
        $leftOnly = [System.Collections.Generic.List[string]]::new()
        $shared = [System.Collections.Generic.List[string]]::new()
        foreach ($child in $ringOneOrder) {
            $touchesLeft = $PeersOf[$child] -contains $leftKey
            $touchesRight = $PeersOf[$child] -contains $rightKey
            if ($touchesLeft -and $touchesRight) { $shared.Add($child) }
            elseif ($touchesLeft) { $leftOnly.Add($child) }
            else { $rightOnly.Add($child) }
        }

        $sharedWeight = 0.0
        foreach ($child in $shared) { $sharedWeight += $WeightOf[$child] }
        $sharedBelow = [System.Collections.Generic.List[string]]::new()
        $sharedAbove = [System.Collections.Generic.List[string]]::new()
        $running = 0.0
        foreach ($child in $shared) {
            if ($running -lt ($sharedWeight / 2.0)) { $sharedBelow.Add($child) } else { $sharedAbove.Add($child) }
            $running += $WeightOf[$child]
        }

        $sectors = foreach ($members in @(@($rightOnly), @($sharedBelow), @($leftOnly), @($sharedAbove))) {
            $weight = 0.0
            foreach ($child in $members) { $weight += $WeightOf[$child] }
            [pscustomobject]@{ Members = $members; Weight = $weight }
        }
        $totalWeight = 0.0
        foreach ($sector in $sectors) { $totalWeight += $sector.Weight }
        if ($totalWeight -le 0) { $totalWeight = 1.0 }

        $rightArc = $twoPi * ($sectors[0].Weight / $totalWeight)
        $angleOf[$leftKey] = [Math]::PI; $wedgeOf[$leftKey] = $twoPi * ($sectors[2].Weight / $totalWeight)
        $angleOf[$rightKey] = 0.0; $wedgeOf[$rightKey] = $rightArc
        $cursor = -($rightArc / 2.0)
        foreach ($sector in $sectors) {
            foreach ($child in $sector.Members) {
                $span = $twoPi * ($WeightOf[$child] / $totalWeight)
                Set-DrawioRadialBranchAngles -Key $child -From $cursor -To ($cursor + $span) `
                    -AngleOf $angleOf -WedgeOf $wedgeOf -ChildrenOf $ChildrenOf -WeightOf $WeightOf
                $cursor += $span
            }
        }
    }
    return [pscustomobject]@{ AngleOf = $angleOf; WedgeOf = $wedgeOf }
}

function Optimize-DrawioRadialSiblingOrder {
    [CmdletBinding()]
    param([hashtable]$AngleOf, [object[]]$Members, [hashtable]$PeersOf, [hashtable]$ChildrenOf)

    $desiredOf = @{}
    foreach ($member in $Members) {
        $sumSin = 0.0; $sumCos = 0.0; $count = 0
        foreach ($peer in $PeersOf[$member]) {
            if (-not $AngleOf.ContainsKey($peer)) { continue }
            $sumSin += [Math]::Sin($AngleOf[$peer]); $sumCos += [Math]::Cos($AngleOf[$peer]); $count++
        }
        $desiredOf[$member] = if ($count -gt 0 -and ($sumSin -ne 0 -or $sumCos -ne 0)) { [Math]::Atan2($sumSin, $sumCos) } else { $AngleOf[$member] }
    }
    foreach ($member in $Members) {
        $children = @($ChildrenOf[$member])
        if ($children.Count -lt 2) { continue }
        $anchor = $AngleOf[$member]
        $ordered = @($children | Sort-Object @{Expression = {
            $delta = $desiredOf[$_] - $anchor
            while ($delta -le -[Math]::PI) { $delta += 2.0 * [Math]::PI }
            while ($delta -gt [Math]::PI) { $delta -= 2.0 * [Math]::PI }
            $delta
        }}, @{Expression = { $_ }})
        $ChildrenOf[$member] = [System.Collections.Generic.List[string]]::new()
        foreach ($child in $ordered) { $ChildrenOf[$member].Add($child) }
    }
}

function Get-DrawioRingRadiusForStagger {
    [CmdletBinding()]
    param([object[]]$Ordered, [hashtable]$DemandOf, [hashtable]$AngleOf, [int]$Stagger)

    $required = 0.0
    for ($offset = 0; $offset -lt $Stagger; $offset++) {
        $group = @()
        for ($index = $offset; $index -lt $Ordered.Count; $index += $Stagger) { $group += $Ordered[$index] }
        if ($group.Count -le 1) { continue }
        for ($index = 0; $index -lt $group.Count; $index++) {
            $a = $group[$index]; $b = $group[($index + 1) % $group.Count]
            $gap = $AngleOf[$b] - $AngleOf[$a]
            while ($gap -le 0) { $gap += 2.0 * [Math]::PI }
            $need = [Math]::Max($DemandOf[$a], $DemandOf[$b]) / $gap
            if ($need -gt $required) { $required = $need }
        }
    }
    return $required
}

function Get-DrawioRadialPlacement {
    [CmdletBinding()]
    param(
        # key -> @(neighbour keys). Treated as undirected; a link reported from one side is enough.
        [parameter(Mandatory = $true)] [hashtable]$Adjacency,
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Keys,
        # key -> @{Width;Height}. Missing entries fall back to the overview card size.
        [parameter(Mandatory = $true)] [hashtable]$FootprintOf,
        [double]$StartX = 100,
        [double]$StartY = 100,
        # Clearance between two cards sitting side by side, and between two cards stacked. Kept
        # separate because the cards are much wider than they are tall, so the same visual density
        # needs a bigger horizontal number than vertical.
        [double]$NodeGap = 60,
        [double]$RingGap = 60,
        # How much wider than tall the rings are drawn. 1 gives true circles; above 1 gives
        # ellipses, which fit a screen better - a square page has to be shrunk to its HEIGHT to be
        # seen whole on a 16:9 display, so squashing a circular starburst into a landscape one is
        # close to free readability. See the note on $aspect below for why this costs nothing in
        # correctness: it is an exact coordinate scaling, applied to the cards as well as to the
        # rings, so a layout that does not overlap before the squash does not overlap after it.
        [double]$AspectRatio = 1.0,
        # Space left between two independent starbursts (separate connected components).
        [double]$ClusterGap = 140,
        # Optional ordered center preference. A matching key becomes the centre of its connected
        # component; a second matching key is used only when it is directly connected to the first.
        # Components with no preferred key retain the normal graph-centre selection.
        [AllowEmptyCollection()][string[]]$PreferredCenters = @(),
        # Passes of the crossing-reduction refinement (see Optimize-RadialSiblingOrder below).
        [int]$Sweeps = 4,
        # Most concentric sub-rings a single ring may be split into. 1 keeps every ring one clean
        # circle; higher lets a crowded ring trade thickness for radius (see the costing loop in
        # New-RadialCluster). Only an upper bound - each ring still picks the cheapest split for
        # itself, so raising this cannot make a sparse ring worse.
        [int]$MaxStagger = 4,
        # How far apart consecutive rings are placed. 'Bound' charges the distance that clears two
        # cards from any direction; 'Exact' bisects down to the smallest radius at which this ring's
        # cards genuinely clear the ones inside it. See the note in the ring loop for why the
        # difference is most of a large site's page.
        [ValidateSet('Bound', 'Exact')]
        [string]$RingSpacing = 'Bound',
        # Where independent starbursts go. 'Shelf' lays them out in rows below the main one;
        # 'Corner' drops them into space the main starburst's bounding box already owns but does not
        # use - see the note at the packing loop.
        [ValidateSet('Shelf', 'Corner')]
        [string]$ClusterPacking = 'Shelf',
        # Independent starbursts wrap onto a new band rather than run past this width.
        [double]$MaxRowWidth = 4000
    )

    $allKeys = @($Keys | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
    if ($allKeys.Count -eq 0) {
        return [pscustomobject]@{ Positions = @{}; Rings = @{}; Centers = @(); Width = 0.0; Height = 0.0 }
    }

    # The whole layout is solved in a vertically STRETCHED space and squashed back at the end. Every
    # card's height and the vertical clearance are multiplied by $aspect going in, and every Y
    # coordinate is divided by it coming out - so the solver still only ever reasons about circles,
    # and the drawing comes out elliptical. Because the squash is a single affine scale applied to
    # the cards and their positions alike, two boxes that were disjoint in the stretched space are
    # still disjoint after it (their X ranges are untouched and their Y ranges shrink by the same
    # factor), which is what lets the placement guarantees survive the change of shape.
    $aspect = if ($AspectRatio -gt 0) { [double]$AspectRatio } else { 1.0 }
    $stretchedRingGap = $RingGap * $aspect

    $sizeOf = @{}
    foreach ($key in $allKeys) {
        $footprint = $FootprintOf[$key]
        $width = if ($footprint -and $footprint.Width) { [double]$footprint.Width } else { 200.0 }
        $height = if ($footprint -and $footprint.Height) { [double]$footprint.Height } else { 70.0 }
        $sizeOf[$key] = [pscustomobject]@{ Width = $width; Height = ($height * $aspect) }
    }

    return Invoke-DrawioRadialPlacementCore -Adjacency $Adjacency -AllKeys $allKeys -SizeOf $sizeOf `
        -NodeGap $NodeGap -StretchedRingGap $stretchedRingGap -Sweeps $Sweeps -Aspect $aspect `
        -MaxStagger $MaxStagger -RingSpacing $RingSpacing -ClusterPacking $ClusterPacking `
        -ClusterGap $ClusterGap -StartX $StartX -StartY $StartY -MaxRowWidth $MaxRowWidth `
        -PreferredCenters $PreferredCenters
}

# Solves one connected component around one or two central nodes.
function New-DrawioRadialCluster {
    [CmdletBinding()]
        param([object[]]$Members, [hashtable]$Neighbors, [hashtable]$SizeOf,
              [double]$NodeGap, [double]$RingGap, [int]$Sweeps, [double]$AspectRatio = 1.0,
              [int]$MaxStagger = 4, [string]$RingSpacing = 'Bound',
              [AllowEmptyCollection()][string[]]$PreferredCenters = @())

        $members = @($Members | Sort-Object)
        $memberSet = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($m in $members) { [void]$memberSet.Add($m) }

        $peersOf = @{}
        foreach ($m in $members) { $peersOf[$m] = @($Neighbors[$m] | Where-Object { $memberSet.Contains($_) } | Sort-Object) }
        $degreeOf = @{}
        foreach ($m in $members) { $degreeOf[$m] = @($peersOf[$m]).Count }

        # --- Centre selection --------------------------------------------------------------
        # "The middle of the network" is the graph centre: the device whose furthest peer is as
        # close as possible (minimum eccentricity), broken by total distance to everything else.
        # That is deliberately NOT just the highest-degree device - a switch with thirty access
        # ports hanging off it has the biggest degree but can still sit at the edge of the site,
        # and putting it in the middle pushes the actual backbone out to a ring.
        #
        # All-pairs BFS is O(V*E), which is nothing at the sizes this page draws; the fallback
        # exists only so a pathological input cannot make the run quadratic in a big way.
        $centers = @()
        if ($members.Count -le 250) {
            $eccentricityOf = @{}
            $farnessOf = @{}
            foreach ($source in $members) {
                $distance = @{}
                $distance[$source] = 0
                $queue = [System.Collections.Generic.Queue[string]]::new()
                $queue.Enqueue($source)
                while ($queue.Count -gt 0) {
                    $current = $queue.Dequeue()
                    foreach ($peer in $peersOf[$current]) {
                        if ($distance.ContainsKey($peer)) { continue }
                        $distance[$peer] = $distance[$current] + 1
                        $queue.Enqueue($peer)
                    }
                }
                $ecc = 0; $sum = 0
                foreach ($value in $distance.Values) { $sum += $value; if ($value -gt $ecc) { $ecc = $value } }
                $eccentricityOf[$source] = $ecc
                $farnessOf[$source] = $sum
            }
            $ranked = @($members | Sort-Object `
                @{Expression = { $eccentricityOf[$_] }}, `
                @{Expression = { $farnessOf[$_] }}, `
                @{Expression = { -$degreeOf[$_] }}, `
                @{Expression = { $_ }})
        }
        else {
            $eccentricityOf = @{}
            foreach ($m in $members) { $eccentricityOf[$m] = 0 }
            $ranked = @($members | Sort-Object @{Expression = { -$degreeOf[$_] }}, @{Expression = { $_ }})
        }
        $preferred = @($PreferredCenters | Where-Object { $memberSet.Contains([string]$_) } |
            ForEach-Object { [string]$_ } | Select-Object -Unique)
        if ($preferred.Count -gt 0) {
            $primary = $preferred[0]
            $centers = @($primary)
            if ($preferred.Count -gt 1 -and $peersOf[$primary] -contains $preferred[1]) {
                $centers = @($primary, $preferred[1])
            }
        }
        else {
            $primary = $ranked[0]
            $centers = @($primary)

            # A redundant core pair - two switches that are each other's neighbour, both as central as
            # the site gets, both carrying comparable numbers of links - is drawn as TWO middles side
            # by side rather than one middle with the other demoted to ring 1. That is the common
            # small-site shape the single-centre form draws badly: with everything dual-homed to both
            # members of the pair, demoting one of them puts half the site's links across a ring
            # boundary for no reason.
            foreach ($candidate in @($ranked | Select-Object -Skip 1)) {
                if ($eccentricityOf[$candidate] -ne $eccentricityOf[$primary]) { break }
                if ($peersOf[$primary] -notcontains $candidate) { continue }
                if ($degreeOf[$candidate] -lt ($degreeOf[$primary] * 0.5)) { continue }
                $centers = @($primary, $candidate)
                break
            }
        }

        # --- BFS tree from the centre(s) ----------------------------------------------------
        # Ring = hop distance. Parent = whichever already-placed neighbour has the most links, so a
        # leaf hangs off the hub it is really attached to rather than off whichever sibling the
        # traversal happened to reach first.
        $ringOf = @{}
        $parentOf = @{}
        $queue = [System.Collections.Generic.Queue[string]]::new()
        foreach ($center in $centers) { $ringOf[$center] = 0; $parentOf[$center] = $null; $queue.Enqueue($center) }
        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            foreach ($peer in $peersOf[$current]) {
                if ($ringOf.ContainsKey($peer)) { continue }
                $ringOf[$peer] = $ringOf[$current] + 1
                $parentOf[$peer] = $current
                $queue.Enqueue($peer)
            }
        }
        # Re-home each node onto its best-connected eligible parent. The BFS above fixes the ring
        # correctly but hands out parents in queue order; this second pass picks, among the peers
        # one ring closer to the centre, the one with the most links.
        foreach ($m in $members) {
            if ($ringOf[$m] -eq 0) { continue }
            $candidates = @($peersOf[$m] | Where-Object { $ringOf[$_] -eq ($ringOf[$m] - 1) })
            if ($candidates.Count -eq 0) { continue }
            $parentOf[$m] = @($candidates | Sort-Object @{Expression = { -$degreeOf[$_] }}, @{Expression = { $_ }})[0]
        }

        $childrenOf = @{}
        foreach ($m in $members) { $childrenOf[$m] = [System.Collections.Generic.List[string]]::new() }
        foreach ($m in $members) {
            if ($ringOf[$m] -eq 0) { continue }
            if ($parentOf[$m]) { $childrenOf[$parentOf[$m]].Add($m) }
        }
        $maxRing = 0
        foreach ($m in $members) { if ($ringOf[$m] -gt $maxRing) { $maxRing = $ringOf[$m] } }

        # --- Weights ------------------------------------------------------------------------
        # A node's weight is the arc its whole subtree needs, in pixels of circumference. Computed
        # deepest-ring-first so a child is always weighed before its parent. $AngleOf is optional:
        # the first pass has no angles yet and uses each node's worst-case demand, the refinement
        # passes feed the previous pass's angles back in and get the direction-aware (much smaller,
        # on the left and right of the ring) demand instead.
        # --- Angles -------------------------------------------------------------------------
        # Each node owns a wedge; its children split that wedge between them in proportion to their
        # weights and in the order $childrenOf holds. Because a node's weight is at least its own
        # demand and at most the sum of its children's, every node's wedge is at least
        # 2*pi * weight / total - which is what makes one global radius enough for every ring.
        # --- Crossing reduction --------------------------------------------------------------
        # Reorders each node's children so a child that also links to something outside its own
        # branch is put on the side of the wedge that thing is on. This is the barycenter heuristic
        # Get-DrawioBarycenterOrder applies to rows, done on a circle: a node's desired direction is
        # the circular mean of its neighbours' current directions, and siblings are then sorted by
        # where that desire falls inside their parent's wedge.
        #
        # Only the ORDER of siblings changes - never which wedge a subtree belongs to - so the
        # branch structure that keeps a branch's links inside its own sector is preserved intact.
        # Ring membership, needed by both the re-spacing pass below and the radius solve after it.
        $ringMembers = @{}
        for ($ring = 0; $ring -le $maxRing; $ring++) { $ringMembers[$ring] = [System.Collections.Generic.List[string]]::new() }
        foreach ($m in $members) { $ringMembers[$ringOf[$m]].Add($m) }

        # A variant tried here and rejected, recorded so it is not retried: re-spacing each ring from
        # its OWN population instead of inheriting a share of the circle from the centre. It is very
        # tempting on paper - a nested share shrinks multiplicatively at every level, so one device
        # deep in a lopsided branch ends up with a sliver of arc, and a ring is only as tight as its
        # tightest member. Re-spacing fixed exactly that, roughly halving both page dimensions and
        # nearly tripling the fraction of the box actually covered by cards.
        #
        # It was still wrong. Sizing a ring's arcs from that ring alone breaks the alignment between a
        # device and its parent, so links stop being short and radial and become long chords across
        # the middle. Measured across a range of topologies it quadrupled both failures the starburst
        # exists to prevent: links through unrelated cards 29 -> 147, crossings 51 -> 227. The size
        # was real and the page was worse, which is the whole reason those two numbers are measured
        # alongside size rather than after it.
        # --- Solve ---------------------------------------------------------------------------
        $weights = Get-DrawioSubtreeWeights -Members $members -RingOf $ringOf -ChildrenOf $childrenOf `
            -SizeOf $SizeOf -MaxRing $maxRing -NodeGap $NodeGap -RingGap $RingGap -AngleOf $null
        $angles = Get-DrawioRadialAngles -WeightOf $weights -Centers $centers -ChildrenOf $childrenOf -PeersOf $peersOf
        for ($sweep = 0; $sweep -lt $Sweeps; $sweep++) {
            Optimize-DrawioRadialSiblingOrder -AngleOf $angles.AngleOf -Members $members -PeersOf $peersOf -ChildrenOf $childrenOf
            $weights = Get-DrawioSubtreeWeights -Members $members -RingOf $ringOf -ChildrenOf $childrenOf `
                -SizeOf $SizeOf -MaxRing $maxRing -NodeGap $NodeGap -RingGap $RingGap -AngleOf $angles.AngleOf
            $angles = Get-DrawioRadialAngles -WeightOf $weights -Centers $centers -ChildrenOf $childrenOf -PeersOf $peersOf
        }
        $angleOf = $angles.AngleOf

        # --- Radii ---------------------------------------------------------------------------
        # Each ring gets the smallest radius that works for the nodes ON THAT RING, subject only to
        # clearing the ring inside it. Sizing every ring from the whole tree's circumference demand
        # instead - the obvious first implementation - pushes the inner rings out to whatever the
        # widest ring needs, which is where nearly all of this layout's wasted space came from: a
        # site whose outer ring holds fifty access switches drew its four distribution switches on a
        # circle sized for fifty.
        #
        # A node needs its allocated wedge, times the ring's radius, to be at least the separation
        # its neighbours on that ring require - so the ring's radius must be at least
        # max(demand / wedge) over its members.
        #
        # How far apart two rings have to be is set by the biggest card on either of them, not by
        # the biggest card anywhere - a ring of small observed-peer chips packs closer than a ring
        # of full device cards.
        $ringClearance = @{}
        for ($ring = 0; $ring -le $maxRing; $ring++) {
            $largest = 0.0
            foreach ($m in $ringMembers[$ring]) {
                $separation = Get-DrawioSafeSeparation -Width $SizeOf[$m].Width -Height $SizeOf[$m].Height -GapX $NodeGap -GapY $RingGap
                if ($separation -gt $largest) { $largest = $separation }
            }
            $ringClearance[$ring] = $largest
        }

        # Where the centre card(s) sit, and how big a box they jointly occupy.
        $centerPosition = @{}
        if ($centers.Count -eq 1) {
            $centerPosition[$centers[0]] = [pscustomobject]@{ X = 0.0; Y = 0.0 }
            $coreHalfWidth = $SizeOf[$centers[0]].Width / 2.0
            $coreHalfHeight = $SizeOf[$centers[0]].Height / 2.0
        }
        else {
            $leftSize = $SizeOf[$centers[0]]; $rightSize = $SizeOf[$centers[1]]
            $centerPosition[$centers[0]] = [pscustomobject]@{ X = -(($NodeGap / 2.0) + ($leftSize.Width / 2.0)); Y = 0.0 }
            $centerPosition[$centers[1]] = [pscustomobject]@{ X = (($NodeGap / 2.0) + ($rightSize.Width / 2.0)); Y = 0.0 }
            $coreHalfWidth = ($leftSize.Width + $NodeGap + $rightSize.Width) / 2.0
            $coreHalfHeight = [Math]::Max($leftSize.Height, $rightSize.Height) / 2.0
        }

        $demandOf = @{}
        foreach ($m in $members) {
            $size = $SizeOf[$m]
            $demandOf[$m] = Get-DrawioTangentialDemand -Width $size.Width -Height $size.Height -GapX $NodeGap -GapY $RingGap `
                -Angle ([System.Nullable[double]]$angleOf[$m])
        }

        $ringRadius = @{}
        $ringStagger = @{}
        $ringThickness = @{}
        $subRingOf = @{}
        foreach ($m in $members) { $subRingOf[$m] = 0 }
        $ringRadius[0] = 0.0; $ringStagger[0] = 1; $ringThickness[0] = 0.0

        # Every card already placed on an inner ring, in this cluster's own coordinates. Rings are
        # solved outward, so this is what a candidate radius for the next ring is tested against.
        $placedBoxes = [System.Collections.Generic.List[object]]::new()
        foreach ($center in $centers) {
            $point = $centerPosition[$center]; $size = $SizeOf[$center]
            $placedBoxes.Add([pscustomobject]@{
                Left = $point.X - ($size.Width / 2.0); Top = $point.Y - ($size.Height / 2.0)
                Right = $point.X + ($size.Width / 2.0); Bottom = $point.Y + ($size.Height / 2.0)
            })
        }

        for ($ring = 1; $ring -le $maxRing; $ring++) {
            if ($ring -eq 1) {
                # Ring 1 has to clear the core box rather than a circle.
                $widest = 0.0; $tallest = 0.0
                foreach ($m in $ringMembers[1]) {
                    if ($SizeOf[$m].Width -gt $widest) { $widest = $SizeOf[$m].Width }
                    if ($SizeOf[$m].Height -gt $tallest) { $tallest = $SizeOf[$m].Height }
                }
                $floor = [Math]::Sqrt([Math]::Pow($coreHalfWidth + ($widest / 2.0) + $NodeGap, 2) +
                                      [Math]::Pow($coreHalfHeight + ($tallest / 2.0) + $RingGap, 2))
            }
            else {
                $floor = $ringRadius[$ring - 1] + $ringThickness[$ring - 1] +
                    [Math]::Max($ringClearance[$ring - 1], $ringClearance[$ring])
            }

            # A ring holding a lot of nodes is the thing that makes a big site's page enormous: its
            # circumference has to fit every one of them, so its radius - and with it the whole
            # page - grows linearly with how many devices sit that many hops out. Splitting the ring
            # into two or three concentric sub-rings, with consecutive nodes alternating between
            # them, buys back most of that: nodes sharing a sub-ring are then two or three angular
            # slots apart, so the radius they need falls by roughly the same factor while the ring
            # only gets one or two clearances thicker. On a large topology that is the difference
            # between a 7,000px page and a 4,000px one.
            #
            # Which is worth it is decided by measurement, not assumed: every stagger up to four is
            # costed as (radius it needs) + (extra thickness it adds) and the cheapest wins, so a
            # sparse ring stays a single clean circle.
            $ordered = @($ringMembers[$ring] | Sort-Object @{Expression = { $angleOf[$_] }}, @{Expression = { $_ }})
            $bestOuter = [double]::PositiveInfinity
            $bestRadius = $floor
            $bestStagger = 1
            $bestNeeded = 0.0
            $maxStagger = [Math]::Min([Math]::Max(1, $MaxStagger), [Math]::Max(1, $ordered.Count))
            for ($stagger = 1; $stagger -le $maxStagger; $stagger++) {
                $needed = Get-DrawioRingRadiusForStagger -Ordered $ordered -DemandOf $demandOf -AngleOf $angleOf -Stagger $stagger
                $radius = [Math]::Max($floor, $needed)
                $thickness = ($stagger - 1) * $ringClearance[$ring]
                $outer = $radius + $thickness
                if ($outer -lt ($bestOuter - 1.0)) {
                    $bestOuter = $outer; $bestRadius = $radius; $bestStagger = $stagger; $bestNeeded = $needed
                }
            }
            $ringStagger[$ring] = $bestStagger
            $ringThickness[$ring] = ($bestStagger - 1) * $ringClearance[$ring]
            for ($i = 0; $i -lt $ordered.Count; $i++) { $subRingOf[$ordered[$i]] = $i % $bestStagger }

            # $floor above is a SUFFICIENT gap, not a necessary one: it is the distance that clears
            # two cards whatever direction they lie in, so it is the diagonal - about 350px for a
            # 200x70 card once the aspect stretch is applied. Charge that per ring and depth alone
            # decides the page. A deep topology - nine rings out - therefore spends roughly 3,150px
            # of radius, or 6,300px of width, on ring separation before a single device is placed.
            # That, not angular crowding, is what makes such a page enormous.
            #
            # The necessary gap is far smaller, because two cards only need to clear each other if
            # they are at similar angles, and the ones on adjacent rings usually are not. So rather
            # than trust the bound, pull the ring inward and TEST: bisect between the tightest the
            # angles allow and the conservative floor, keeping the smallest radius at which no card
            # on this ring touches any card already placed inside it. That is an exact answer about
            # these particular devices at these particular angles, not a bound over all possible
            # ones.
            #
            # Bisection assumes the ring is free above the radius it first becomes free at, which is
            # true whenever the bad region is one interval - the usual case, since sliding a card
            # radially outward past an obstacle does not bring it back. The whole-layout
            # verification below is the backstop if it ever is not.
            if ($RingSpacing -eq 'Exact' -and $placedBoxes.Count -gt 0) {
                $ringFits = {
                    param([double]$Candidate)
                    foreach ($m in $ordered) {
                        $size = $SizeOf[$m]
                        $r = $Candidate + ($subRingOf[$m] * $ringClearance[$ring])
                        $left = ($r * [Math]::Cos($angleOf[$m])) - ($size.Width / 2.0)
                        $top = ($r * [Math]::Sin($angleOf[$m])) - ($size.Height / 2.0)
                        $right = $left + $size.Width; $bottom = $top + $size.Height
                        foreach ($box in $placedBoxes) {
                            if ($left -lt $box.Right -and $box.Left -lt $right -and
                                $top -lt $box.Bottom -and $box.Top -lt $bottom) { return $false }
                        }
                    }
                    return $true
                }
                $low = [Math]::Max($bestNeeded, $ringRadius[$ring - 1] + $ringThickness[$ring - 1] + 1.0)
                if ($low -lt $bestRadius -and (& $ringFits $low)) {
                    $bestRadius = $low
                }
                elseif ($low -lt $bestRadius) {
                    $high = $bestRadius
                    for ($step = 0; $step -lt 12; $step++) {
                        $mid = ($low + $high) / 2.0
                        if (& $ringFits $mid) { $high = $mid } else { $low = $mid }
                    }
                    $bestRadius = $high
                }
            }

            $ringRadius[$ring] = $bestRadius
            foreach ($m in $ordered) {
                $size = $SizeOf[$m]
                $r = $bestRadius + ($subRingOf[$m] * $ringClearance[$ring])
                $left = ($r * [Math]::Cos($angleOf[$m])) - ($size.Width / 2.0)
                $top = ($r * [Math]::Sin($angleOf[$m])) - ($size.Height / 2.0)
                $placedBoxes.Add([pscustomobject]@{ Left = $left; Top = $top; Right = $left + $size.Width; Bottom = $top + $size.Height })
            }
        }

        # --- Place, verify, and grow if anything still touches --------------------------------
        $positions = @{}
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            $scale = [Math]::Pow(1.06, $attempt)
            $positions = @{}
            foreach ($m in $members) {
                $size = $SizeOf[$m]
                if ($ringOf[$m] -eq 0) {
                    $point = $centerPosition[$m]
                    $positions[$m] = [pscustomobject]@{ X = $point.X - ($size.Width / 2.0); Y = $point.Y - ($size.Height / 2.0) }
                    continue
                }
                $r = ($ringRadius[$ringOf[$m]] + ($subRingOf[$m] * $ringClearance[$ringOf[$m]])) * $scale
                $centerX = $r * [Math]::Cos($angleOf[$m])
                $centerY = $r * [Math]::Sin($angleOf[$m])
                $positions[$m] = [pscustomobject]@{ X = $centerX - ($size.Width / 2.0); Y = $centerY - ($size.Height / 2.0) }
            }

            $overlap = $false
            for ($i = 0; $i -lt $members.Count -and -not $overlap; $i++) {
                $a = $positions[$members[$i]]; $sizeA = $SizeOf[$members[$i]]
                for ($j = $i + 1; $j -lt $members.Count; $j++) {
                    $b = $positions[$members[$j]]; $sizeB = $SizeOf[$members[$j]]
                    if ($a.X -lt ($b.X + $sizeB.Width) -and $b.X -lt ($a.X + $sizeA.Width) -and
                        $a.Y -lt ($b.Y + $sizeB.Height) -and $b.Y -lt ($a.Y + $sizeA.Height)) { $overlap = $true; break }
                }
            }
            if (-not $overlap) { break }
        }

        # Squash back out of the stretched space: every Y (and, with it, every card height) divides
        # by the same factor, so the rings become ellipses and nothing that was clear of anything
        # else stops being clear of it.
        foreach ($m in $members) {
            $positions[$m] = [pscustomobject]@{ X = $positions[$m].X; Y = ($positions[$m].Y / $AspectRatio) }
        }

        # Normalise to a 0-based bounding box so the caller can pack clusters without knowing that
        # any of this was ever polar.
        $minX = [double]::PositiveInfinity; $minY = [double]::PositiveInfinity
        $maxX = [double]::NegativeInfinity; $maxY = [double]::NegativeInfinity
        foreach ($m in $members) {
            $point = $positions[$m]; $size = $SizeOf[$m]
            $drawnHeight = $size.Height / $AspectRatio
            if ($point.X -lt $minX) { $minX = $point.X }
            if ($point.Y -lt $minY) { $minY = $point.Y }
            if (($point.X + $size.Width) -gt $maxX) { $maxX = $point.X + $size.Width }
            if (($point.Y + $drawnHeight) -gt $maxY) { $maxY = $point.Y + $drawnHeight }
        }
        $relative = @{}
        foreach ($m in $members) {
            $point = $positions[$m]
            $relative[$m] = [pscustomobject]@{ X = $point.X - $minX; Y = $point.Y - $minY }
        }

        return [pscustomobject]@{
            Positions = $relative
            Rings = $ringOf
            Centers = @($centers)
            Width = ($maxX - $minX)
            Height = ($maxY - $minY)
        }
}

function Invoke-DrawioRadialPlacementCore {
    [CmdletBinding()]
    param(
        [hashtable]$Adjacency, [object[]]$AllKeys, [hashtable]$SizeOf,
        [double]$NodeGap, [double]$StretchedRingGap, [int]$Sweeps, [double]$Aspect,
        [int]$MaxStagger, [string]$RingSpacing, [string]$ClusterPacking,
        [double]$ClusterGap, [double]$StartX, [double]$StartY, [double]$MaxRowWidth,
        [AllowEmptyCollection()][string[]]$PreferredCenters = @()
    )

    # --- Build every cluster, then shelf-pack them ------------------------------------------
    $components = Get-DrawioConnectedComponents -Adjacency $Adjacency -Keys $allKeys
    $clusters = [System.Collections.Generic.List[object]]::new()
    foreach ($component in $components) {
        $clusters.Add((New-DrawioRadialCluster -Members @($component.Members) -Neighbors $component.Neighbors `
            -SizeOf $sizeOf -NodeGap $NodeGap -RingGap $stretchedRingGap -Sweeps $Sweeps -AspectRatio $aspect `
            -MaxStagger $MaxStagger -RingSpacing $RingSpacing -PreferredCenters $PreferredCenters))
    }

    # Components are packed by the shared placer in PlacementStrategies.ps1, so every alternative
    # strategy inherits the same packing and is judged on its own layout rather than on whether it
    # happens to pack as well. HeightScale undoes the vertical stretch this function solved in.
    $clusterRecords = [System.Collections.Generic.List[object]]::new()
    foreach ($cluster in $clusters) { $clusterRecords.Add($cluster) }
    return Get-DrawioClusterPacking -Clusters @($clusterRecords) -SizeOf $sizeOf -HeightScale $aspect `
        -Packing $ClusterPacking -ClusterGap $ClusterGap -StartX $StartX -StartY $StartY -MaxRowWidth $MaxRowWidth
}
