# Alternative placements for the Topology Overview, and the scaffolding that lets them be compared.
#
# WHY THIS FILE EXISTS. Layout quality is not reliably predictable by reasoning about it. A variant
# that looks decisive on page size can quadruple the number of links running through unrelated
# cards, and one that looks marginal on a small synthetic graph can improve size and readability
# together on a real topology. Since a placement can be generated and scored in about a second,
# trying many of them is cheaper than arguing about a few.
#
# THE CONTRACT. Every strategy takes the same three inputs - an adjacency map, the keys to place, and
# a footprint per key - and returns absolute top-left positions plus the page size. That is exactly
# the shape Get-DrawioRadialPlacement already had, which is what makes them interchangeable.
#
# WHAT THE WRAPPER OWNS, so no strategy has to re-implement it:
#   * splitting into connected components and packing them (Get-DrawioClusterPacking)
#   * checking the result for overlapping cards. That is the one hard invariant, and a strategy
#     that breaks it is reported as failed rather than silently accepted.

# ============================================================================
# Cluster packing - shared by every strategy
# ============================================================================
# Places independently-laid-out components on the page. Extracted from Get-DrawioRadialPlacement so
# alternative strategies are judged on their own layout rather than on whether they happen to pack
# components as well as the radial one does - Corner packing alone was worth about 1.1x, which is
# enough to decide a comparison on its own if only one side has it.
#
# $Clusters entries need .Positions (0-based, per key), .Width, .Height, and may carry .Rings and
# .Centers for callers that track them. $HeightScale is for a strategy that solved in a vertically
# stretched space: the radial one does, so its $SizeOf heights are inflated and have to be divided
# back down to get the drawn height. Everything else passes 1.
function Get-DrawioClusterPacking {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Clusters,
        [parameter(Mandatory = $true)] [hashtable]$SizeOf,
        [double]$HeightScale = 1.0,
        [ValidateSet('Shelf', 'Corner')] [string]$Packing = 'Corner',
        [double]$ClusterGap = 140,
        [double]$StartX = 100,
        [double]$StartY = 100,
        [double]$MaxRowWidth = 4000
    )

    $positions = @{}
    $rings = @{}
    $centers = [System.Collections.Generic.List[string]]::new()
    if (@($Clusters).Count -eq 0) {
        return [pscustomobject]@{ Positions = $positions; Rings = $rings; Centers = @(); Width = 0.0; Height = 0.0 }
    }

    # Each cluster's cards in its own coordinates.
    $clusterRects = @{}
    for ($c = 0; $c -lt $Clusters.Count; $c++) {
        $rects = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in $Clusters[$c].Positions.GetEnumerator()) {
            $size = $SizeOf[[string]$entry.Key]
            $rects.Add([pscustomobject]@{
                Left = $entry.Value.X; Top = $entry.Value.Y
                Right = $entry.Value.X + $size.Width
                Bottom = $entry.Value.Y + ($size.Height / $HeightScale)
            })
        }
        $clusterRects[$c] = $rects
    }

    # A starburst's bounding box is mostly empty - the rings are ellipses, so the corners hold nothing
    # at all, and on a large site only a few percent of the box is covered by cards. Stacking the
    # other components underneath it therefore grows the page for no reason: a second component can
    # add a thousand pixels of HEIGHT, and height is the dimension that decides how far the reader
    # has to zoom out on a 16:9 screen.
    #
    # 'Corner' drops those components into space the main cluster already owns but does not use.
    # Candidates are scored by the page they would produce, so one that fits in a corner beats one
    # that extends the page - which also keeps islands reading as off to the side rather than sitting
    # in the middle of the topology.
    #
    # Occupancy is answered from a summed-area table over a coarse grid rather than by testing every
    # card against every other: a few thousand candidate positions times a hundred cards would be
    # millions of rectangle tests per site, while the table answers any rectangle in constant time.
    $cellSize = 40.0
    $placements = @{}
    $placements[0] = [pscustomobject]@{ X = 0.0; Y = 0.0 }

    if ($Packing -eq 'Corner' -and $Clusters.Count -gt 1) {
        $marginX = 0.0; $marginY = 0.0
        for ($c = 1; $c -lt $Clusters.Count; $c++) {
            if ($Clusters[$c].Width -gt $marginX) { $marginX = $Clusters[$c].Width }
            if ($Clusters[$c].Height -gt $marginY) { $marginY = $Clusters[$c].Height }
        }
        $marginX += $ClusterGap; $marginY += $ClusterGap
        $originX = -$marginX; $originY = -$marginY
        $columns = [int][Math]::Ceiling(($Clusters[0].Width + (2 * $marginX)) / $cellSize) + 2
        $rowsCount = [int][Math]::Ceiling(($Clusters[0].Height + (2 * $marginY)) / $cellSize) + 2

        $occupancy = New-Object 'int[]' ($columns * $rowsCount)
        $markRects = {
            param($Rects, [double]$OffsetX, [double]$OffsetY)
            foreach ($rect in $Rects) {
                $c0 = [int][Math]::Floor((($rect.Left + $OffsetX - ($ClusterGap / 2.0)) - $originX) / $cellSize)
                $c1 = [int][Math]::Floor((($rect.Right + $OffsetX + ($ClusterGap / 2.0)) - $originX) / $cellSize)
                $r0 = [int][Math]::Floor((($rect.Top + $OffsetY - ($ClusterGap / 2.0)) - $originY) / $cellSize)
                $r1 = [int][Math]::Floor((($rect.Bottom + $OffsetY + ($ClusterGap / 2.0)) - $originY) / $cellSize)
                for ($r = [Math]::Max(0, $r0); $r -le [Math]::Min($rowsCount - 1, $r1); $r++) {
                    for ($c = [Math]::Max(0, $c0); $c -le [Math]::Min($columns - 1, $c1); $c++) {
                        $occupancy[($r * $columns) + $c] = 1
                    }
                }
            }
        }
        & $markRects $clusterRects[0] 0.0 0.0

        # The page box as it stands, which is what a candidate has to be scored against. Scoring
        # against the MAIN cluster alone looks right and is not: once one component has been placed
        # below, the next is judged as though that space were still free and can be dropped above
        # instead, growing the page in both directions at once.
        $pageLeft = 0.0; $pageTop = 0.0
        $pageRight = $Clusters[0].Width; $pageBottom = $Clusters[0].Height

        for ($index = 1; $index -lt $Clusters.Count; $index++) {
            $cluster = $Clusters[$index]

            $summed = New-Object 'int[]' (($columns + 1) * ($rowsCount + 1))
            for ($r = 0; $r -lt $rowsCount; $r++) {
                $rowSum = 0
                for ($c = 0; $c -lt $columns; $c++) {
                    $rowSum += $occupancy[($r * $columns) + $c]
                    $summed[(($r + 1) * ($columns + 1)) + ($c + 1)] = $summed[($r * ($columns + 1)) + ($c + 1)] + $rowSum
                }
            }

            $bestScore = [double]::PositiveInfinity
            $bestSpot = $null
            $stepX = [Math]::Max($cellSize, $cluster.Width / 6.0)
            $stepY = [Math]::Max($cellSize, $cluster.Height / 6.0)
            for ($y = $originY; $y -le ($Clusters[0].Height + $marginY); $y += $stepY) {
                for ($x = $originX; $x -le ($Clusters[0].Width + $marginX); $x += $stepX) {
                    $c0 = [int][Math]::Floor(($x - $originX) / $cellSize)
                    $c1 = [int][Math]::Floor((($x + $cluster.Width) - $originX) / $cellSize)
                    $r0 = [int][Math]::Floor(($y - $originY) / $cellSize)
                    $r1 = [int][Math]::Floor((($y + $cluster.Height) - $originY) / $cellSize)
                    if ($c0 -lt 0 -or $r0 -lt 0 -or $c1 -ge $columns -or $r1 -ge $rowsCount) { continue }
                    $covered = $summed[(($r1 + 1) * ($columns + 1)) + ($c1 + 1)] -
                               $summed[($r0 * ($columns + 1)) + ($c1 + 1)] -
                               $summed[(($r1 + 1) * ($columns + 1)) + $c0] +
                               $summed[($r0 * ($columns + 1)) + $c0]
                    if ($covered -ne 0) { continue }

                    # Scored in screen terms: a 16:9 reader cares about whichever of width or height
                    # forces the bigger zoom-out.
                    $left = [Math]::Min($pageLeft, $x); $top = [Math]::Min($pageTop, $y)
                    $right = [Math]::Max($pageRight, $x + $cluster.Width)
                    $bottom = [Math]::Max($pageBottom, $y + $cluster.Height)
                    $score = [Math]::Max(($right - $left) / 16.0, ($bottom - $top) / 9.0)
                    if ($score -lt ($bestScore - 0.5)) { $bestScore = $score; $bestSpot = [pscustomobject]@{ X = $x; Y = $y } }
                }
            }

            if (-not $bestSpot) { $bestSpot = [pscustomobject]@{ X = $pageLeft; Y = $pageBottom + $ClusterGap } }
            $placements[$index] = $bestSpot
            & $markRects $clusterRects[$index] $bestSpot.X $bestSpot.Y
            if ($bestSpot.X -lt $pageLeft) { $pageLeft = $bestSpot.X }
            if ($bestSpot.Y -lt $pageTop) { $pageTop = $bestSpot.Y }
            if (($bestSpot.X + $cluster.Width) -gt $pageRight) { $pageRight = $bestSpot.X + $cluster.Width }
            if (($bestSpot.Y + $cluster.Height) -gt $pageBottom) { $pageBottom = $bestSpot.Y + $cluster.Height }
        }
    }
    else {
        $bandX = 0.0; $bandY = 0.0; $bandHeight = 0.0
        for ($index = 0; $index -lt $Clusters.Count; $index++) {
            $cluster = $Clusters[$index]
            if ($bandX -gt 0 -and ($bandX + $cluster.Width) -gt $MaxRowWidth) {
                $bandX = 0.0
                $bandY += $bandHeight + $ClusterGap
                $bandHeight = 0.0
            }
            $placements[$index] = [pscustomobject]@{ X = $bandX; Y = $bandY }
            $bandX += $cluster.Width + $ClusterGap
            if ($cluster.Height -gt $bandHeight) { $bandHeight = $cluster.Height }
        }
    }

    # Corner packing can place a cluster at a negative offset, so rebase everything to the margin.
    $minOffsetX = 0.0; $minOffsetY = 0.0
    foreach ($spot in $placements.Values) {
        if ($spot.X -lt $minOffsetX) { $minOffsetX = $spot.X }
        if ($spot.Y -lt $minOffsetY) { $minOffsetY = $spot.Y }
    }

    $pageWidth = 0.0; $pageHeight = 0.0
    for ($index = 0; $index -lt $Clusters.Count; $index++) {
        $cluster = $Clusters[$index]
        $spot = $placements[$index]
        $offsetX = $StartX + $spot.X - $minOffsetX
        $offsetY = $StartY + $spot.Y - $minOffsetY
        foreach ($entry in $cluster.Positions.GetEnumerator()) {
            $positions[$entry.Key] = [pscustomobject]@{ X = $offsetX + $entry.Value.X; Y = $offsetY + $entry.Value.Y }
        }
        if ($cluster.Rings) { foreach ($entry in $cluster.Rings.GetEnumerator()) { $rings[$entry.Key] = $entry.Value } }
        foreach ($center in @($cluster.Centers)) { if ($center) { $centers.Add([string]$center) } }
        if (($spot.X - $minOffsetX + $cluster.Width) -gt $pageWidth) { $pageWidth = $spot.X - $minOffsetX + $cluster.Width }
        if (($spot.Y - $minOffsetY + $cluster.Height) -gt $pageHeight) { $pageHeight = $spot.Y - $minOffsetY + $cluster.Height }
    }

    return [pscustomobject]@{
        Positions = $positions; Rings = $rings; Centers = @($centers)
        Width = $pageWidth; Height = $pageHeight
    }
}


# ============================================================================
# Shared scaffolding for per-component strategies
# ============================================================================

# Normalised card sizes, with a sane default for a key the caller forgot.
function Get-DrawioStrategySizes {
    param([object[]]$Keys, [hashtable]$FootprintOf)
    $sizeOf = @{}
    foreach ($key in $Keys) {
        $footprint = $FootprintOf[$key]
        $width = if ($footprint -and $footprint.Width) { [double]$footprint.Width } else { 200.0 }
        $height = if ($footprint -and $footprint.Height) { [double]$footprint.Height } else { 70.0 }
        $sizeOf[$key] = [pscustomobject]@{ Width = $width; Height = $height }
    }
    return $sizeOf
}

# Runs $ClusterBuilder once per connected component and packs the results. The builder is called with
# (Members, Neighbors, SizeOf) and returns a hashtable of 0-based positions; bounding box and packing
# are handled here so no strategy has to think about either.
function Invoke-DrawioPerComponent {
    [CmdletBinding()]
    param(
        [hashtable]$Adjacency, [object[]]$Keys, [hashtable]$SizeOf,
        [scriptblock]$ClusterBuilder,
        [string]$Packing = 'Corner', [double]$ClusterGap = 140,
        [double]$StartX = 100, [double]$StartY = 100, [double]$MaxRowWidth = 4000
    )

    $components = Get-DrawioConnectedComponents -Adjacency $Adjacency -Keys $Keys
    $clusters = [System.Collections.Generic.List[object]]::new()
    foreach ($component in $components) {
        $members = @($component.Members | Sort-Object)
        $raw = & $ClusterBuilder $members $component.Neighbors $SizeOf
        if (-not $raw -or $raw.Count -eq 0) { continue }

        $minX = [double]::PositiveInfinity; $minY = [double]::PositiveInfinity
        $maxX = [double]::NegativeInfinity; $maxY = [double]::NegativeInfinity
        foreach ($key in $members) {
            $point = $raw[$key]; $size = $SizeOf[$key]
            if ($null -eq $point) { continue }
            if ($point.X -lt $minX) { $minX = $point.X }
            if ($point.Y -lt $minY) { $minY = $point.Y }
            if (($point.X + $size.Width) -gt $maxX) { $maxX = $point.X + $size.Width }
            if (($point.Y + $size.Height) -gt $maxY) { $maxY = $point.Y + $size.Height }
        }
        if ([double]::IsInfinity($minX)) { continue }

        $relative = @{}
        foreach ($key in $members) {
            if ($null -eq $raw[$key]) { continue }
            $relative[$key] = [pscustomobject]@{ X = $raw[$key].X - $minX; Y = $raw[$key].Y - $minY }
        }
        $clusters.Add([pscustomobject]@{
            Positions = $relative; Width = ($maxX - $minX); Height = ($maxY - $minY)
            Rings = @{}; Centers = @()
        })
    }

    # Largest first, so the site's real topology is the thing at the top left and the long tail of
    # unlinked devices collects around it rather than pushing it around.
    $ordered = @($clusters | Sort-Object { -($_.Width * $_.Height) })
    return Get-DrawioClusterPacking -Clusters $ordered -SizeOf $SizeOf -HeightScale 1.0 `
        -Packing $Packing -ClusterGap $ClusterGap -StartX $StartX -StartY $StartY -MaxRowWidth $MaxRowWidth
}

# The node a component should be built around: the one whose furthest peer is closest (graph centre),
# broken by total distance and then by degree. Deliberately NOT highest degree - a switch with thirty
# access ports has the biggest link count and can still sit at the edge of a site.
function Get-DrawioComponentCentre {
    param([object[]]$Members, [hashtable]$Neighbors)
    $members = @($Members)
    if ($members.Count -le 2) { return $members[0] }
    $memberSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($m in $members) { [void]$memberSet.Add($m) }

    $best = $members[0]; $bestEcc = [int]::MaxValue; $bestFar = [int]::MaxValue
    foreach ($source in $members) {
        $distance = @{ $source = 0 }
        $queue = [System.Collections.Generic.Queue[string]]::new()
        $queue.Enqueue($source)
        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            foreach ($peer in @($Neighbors[$current])) {
                if (-not $memberSet.Contains($peer) -or $distance.ContainsKey($peer)) { continue }
                $distance[$peer] = $distance[$current] + 1
                $queue.Enqueue($peer)
            }
        }
        $ecc = 0; $far = 0
        foreach ($value in $distance.Values) { $far += $value; if ($value -gt $ecc) { $ecc = $value } }
        if ($ecc -lt $bestEcc -or ($ecc -eq $bestEcc -and $far -lt $bestFar)) { $best = $source; $bestEcc = $ecc; $bestFar = $far }
    }
    return $best
}

# Hop distance from a source, restricted to a component.
function Get-DrawioHopDistance {
    param([string]$Source, [object[]]$Members, [hashtable]$Neighbors)
    $memberSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($m in $Members) { [void]$memberSet.Add($m) }
    $distance = @{ $Source = 0 }
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($Source)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        foreach ($peer in @($Neighbors[$current] | Sort-Object)) {
            if (-not $memberSet.Contains($peer) -or $distance.ContainsKey($peer)) { continue }
            $distance[$peer] = $distance[$current] + 1
            $queue.Enqueue($peer)
        }
    }
    return $distance
}


# ============================================================================
# Strategy: Layered
# ============================================================================
# Sugiyama-style rows by BFS depth - the layout the starburst replaced, kept as a measured control so
# every later claim of improvement is against a known-bad as well as a known-good. Reuses
# Get-DrawioTierAssignment and Get-DrawioTierPlacement unchanged; the detail pages still use both.
function Invoke-DrawioLayeredPlacement {
    param([hashtable]$Adjacency, [object[]]$Keys, [hashtable]$SizeOf, [hashtable]$Options)

    $blocks = Get-DrawioTierAssignment -Adjacency $Adjacency -Keys $Keys -BarycenterSweeps 2
    $footprintOf = @{}
    foreach ($key in $Keys) { $footprintOf[$key] = [pscustomobject]@{ Width = $SizeOf[$key].Width; Height = $SizeOf[$key].Height } }
    $startX = [double]$Options.StartX
    $positions = Get-DrawioTierPlacement -Blocks $blocks -FootprintOf $footprintOf `
        -StartX $startX -StartY ([double]$Options.StartY) -ColumnGap 40 -RowGap 40 -BlockGap 80 `
        -MaxRowWidth ([double]$Options.MaxRowWidth - $startX)

    $width = 0.0; $height = 0.0
    foreach ($key in $Keys) {
        if (-not $positions[$key]) { continue }
        $right = $positions[$key].X + $SizeOf[$key].Width
        $bottom = $positions[$key].Y + $SizeOf[$key].Height
        if ($right -gt $width) { $width = $right }
        if ($bottom -gt $height) { $height = $bottom }
    }
    return [pscustomobject]@{ Positions = $positions; Rings = @{}; Centers = @(); Width = $width; Height = $height }
}


# ============================================================================
# Strategy: DegreeRings
# ============================================================================
# Concentric rings ordered by DEGREE rather than hop distance: busiest device in the middle, then the
# next busiest around it, and so on. This is the intuition the very first version of this page ran on
# - "core, distribution, access, by link count" - rebuilt properly as rings, so the question of
# whether hop distance or link count is the better organiser gets a real answer rather than an
# assumption. Rings are sized to what they hold, and members ordered by the average angle of the
# neighbours already placed inside them so a link stays short where it can.
function Invoke-DrawioDegreeRingsPlacement {
    param([hashtable]$Adjacency, [object[]]$Keys, [hashtable]$SizeOf, [hashtable]$Options)

    $builder = {
        param([object[]]$Members, [hashtable]$Neighbors, [hashtable]$SizeOf)
        $members = @($Members)
        $positions = @{}
        if ($members.Count -eq 1) { $positions[$members[0]] = [pscustomobject]@{ X = 0.0; Y = 0.0 }; return $positions }

        $memberSet = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($m in $members) { [void]$memberSet.Add($m) }
        $degreeOf = @{}
        foreach ($m in $members) { $degreeOf[$m] = @($Neighbors[$m] | Where-Object { $memberSet.Contains($_) }).Count }
        $ranked = @($members | Sort-Object @{Expression = { -$degreeOf[$_] }}, @{Expression = { $_ }})

        $centre = $ranked[0]
        $positions[$centre] = [pscustomobject]@{ X = 0.0; Y = 0.0 }
        $placedAngle = @{ $centre = 0.0 }

        $index = 1
        $ring = 1
        $radius = 320.0
        while ($index -lt $ranked.Count) {
            # How many fit on this ring at this radius, given a card needs roughly its diagonal of arc.
            $slot = 290.0
            $capacity = [Math]::Max(3, [int][Math]::Floor((2.0 * [Math]::PI * $radius) / $slot))
            $take = [Math]::Min($capacity, $ranked.Count - $index)
            $onRing = @($ranked[$index..($index + $take - 1)])

            # Order by where each node's already-placed neighbours sit, so links stay short.
            $desire = @{}
            foreach ($m in $onRing) {
                $sumSin = 0.0; $sumCos = 0.0; $seen = 0
                foreach ($peer in @($Neighbors[$m])) {
                    if (-not $placedAngle.ContainsKey($peer)) { continue }
                    $sumSin += [Math]::Sin($placedAngle[$peer]); $sumCos += [Math]::Cos($placedAngle[$peer]); $seen++
                }
                $desire[$m] = if ($seen -gt 0 -and ($sumSin -ne 0 -or $sumCos -ne 0)) { [Math]::Atan2($sumSin, $sumCos) } else { 0.0 }
            }
            $ordered = @($onRing | Sort-Object @{Expression = { $desire[$_] }}, @{Expression = { $_ }})

            for ($i = 0; $i -lt $ordered.Count; $i++) {
                $angle = ($i / [double]$ordered.Count) * 2.0 * [Math]::PI
                $key = $ordered[$i]
                $size = $SizeOf[$key]
                # Squashed vertically for the same reason the starburst is: a landscape page fits a
                # 16:9 screen with far less zooming out than a circular one of the same area.
                $positions[$key] = [pscustomobject]@{
                    X = ($radius * [Math]::Cos($angle)) - ($size.Width / 2.0)
                    Y = (($radius / 1.8) * [Math]::Sin($angle)) - ($size.Height / 2.0)
                }
                $placedAngle[$key] = $angle
            }

            $index += $take
            $ring++
            $radius += 300.0
        }
        return $positions
    }

    return Invoke-DrawioPerComponent -Adjacency $Adjacency -Keys $Keys -SizeOf $SizeOf -ClusterBuilder $builder `
        -Packing $Options.Packing -ClusterGap $Options.ClusterGap -StartX $Options.StartX -StartY $Options.StartY -MaxRowWidth $Options.MaxRowWidth
}


# ============================================================================
# Strategy: Spiral
# ============================================================================
# Every device on one Archimedean spiral, in breadth-first order from the centre. Included as the low
# bar for size rather than as a serious candidate: a spiral packs about as tightly as anything can
# while saying almost nothing about structure, so it puts a number on what pure compactness costs in
# readability. If a structured layout gets close to the spiral's page size, that layout is done.
function Invoke-DrawioSpiralPlacement {
    param([hashtable]$Adjacency, [object[]]$Keys, [hashtable]$SizeOf, [hashtable]$Options)

    $builder = {
        param([object[]]$Members, [hashtable]$Neighbors, [hashtable]$SizeOf)
        $members = @($Members)
        $positions = @{}
        $centre = Get-DrawioComponentCentre -Members $members -Neighbors $Neighbors
        $distance = Get-DrawioHopDistance -Source $centre -Members $members -Neighbors $Neighbors
        $ordered = @($members | Sort-Object @{Expression = { if ($distance.ContainsKey($_)) { $distance[$_] } else { [int]::MaxValue } }}, @{Expression = { $_ }})

        # r = b*theta with the angular step falling as 1/r, which keeps the spacing along the spiral
        # roughly constant instead of bunching near the middle.
        $spacing = 250.0
        $b = $spacing / (2.0 * [Math]::PI)
        $theta = 2.0
        for ($i = 0; $i -lt $ordered.Count; $i++) {
            $key = $ordered[$i]
            $size = $SizeOf[$key]
            $r = $b * $theta
            $positions[$key] = [pscustomobject]@{
                X = ($r * [Math]::Cos($theta) * 1.8) - ($size.Width / 2.0)
                Y = ($r * [Math]::Sin($theta)) - ($size.Height / 2.0)
            }
            $theta += $spacing / [Math]::Max($spacing, $r)
        }
        return $positions
    }

    return Invoke-DrawioPerComponent -Adjacency $Adjacency -Keys $Keys -SizeOf $SizeOf -ClusterBuilder $builder `
        -Packing $Options.Packing -ClusterGap $Options.ClusterGap -StartX $Options.StartX -StartY $Options.StartY -MaxRowWidth $Options.MaxRowWidth
}


# ============================================================================
# Strategy: Spine
# ============================================================================
# Finds the component's longest shortest path and draws it as a horizontal backbone, hanging
# everything else off the spine node it attaches to, alternating above and below.
#
# This is the one strategy that exploits a property the others treat as a problem. A deep topology -
# say nine hops - costs nine rings of radius in a starburst, but only nine columns of width drawn as
# a spine, and a 16:9 screen has far more width than height. It is also the shape a network engineer
# draws by hand, which is worth something on its own.
function Invoke-DrawioSpinePlacement {
    param([hashtable]$Adjacency, [object[]]$Keys, [hashtable]$SizeOf, [hashtable]$Options)

    $builder = {
        param([object[]]$Members, [hashtable]$Neighbors, [hashtable]$SizeOf)
        $members = @($Members)
        $positions = @{}
        if ($members.Count -eq 1) { $positions[$members[0]] = [pscustomobject]@{ X = 0.0; Y = 0.0 }; return $positions }
        $memberSet = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($m in $members) { [void]$memberSet.Add($m) }

        # Double sweep for the diameter: furthest node from any start, then furthest from that. The
        # standard trick, and exact on a tree - which most of these components nearly are.
        $farthest = {
            param([string]$From)
            $distance = Get-DrawioHopDistance -Source $From -Members $members -Neighbors $Neighbors
            $best = $From; $bestD = -1
            foreach ($entry in $distance.GetEnumerator()) {
                if ($entry.Value -gt $bestD -or ($entry.Value -eq $bestD -and [string]$entry.Key -lt [string]$best)) {
                    $best = [string]$entry.Key; $bestD = $entry.Value
                }
            }
            return [pscustomobject]@{ Node = $best; Distance = $distance }
        }
        $endA = (& $farthest $members[0]).Node
        $sweepB = & $farthest $endA
        $endB = $sweepB.Node
        $distanceFromA = $sweepB.Distance
        $distanceFromB = Get-DrawioHopDistance -Source $endB -Members $members -Neighbors $Neighbors

        # Walk back from B to A along any shortest path.
        $spine = [System.Collections.Generic.List[string]]::new()
        $current = $endB
        $spine.Add($current)
        while ($current -ne $endA) {
            $next = $null
            foreach ($peer in @($Neighbors[$current] | Sort-Object)) {
                if (-not $memberSet.Contains($peer)) { continue }
                if ($distanceFromA.ContainsKey($peer) -and $distanceFromA[$peer] -eq ($distanceFromA[$current] - 1)) { $next = $peer; break }
            }
            if (-not $next) { break }
            $spine.Add($next)
            $current = $next
        }
        $spineSet = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($s in $spine) { [void]$spineSet.Add($s) }

        # Everything else attaches to whichever spine node it is closest to.
        $ownerOf = @{}
        foreach ($m in $members) {
            if ($spineSet.Contains($m)) { continue }
            $best = $null; $bestD = [int]::MaxValue
            for ($i = 0; $i -lt $spine.Count; $i++) {
                $d = Get-DrawioHopDistance -Source $spine[$i] -Members $members -Neighbors $Neighbors
                if ($d.ContainsKey($m) -and $d[$m] -lt $bestD) { $bestD = $d[$m]; $best = $spine[$i] }
            }
            if (-not $best) { $best = $spine[0] }
            if (-not $ownerOf.ContainsKey($best)) { $ownerOf[$best] = [System.Collections.Generic.List[string]]::new() }
            $ownerOf[$best].Add($m)
        }

        $columnGap = 60.0
        $rowGap = 40.0
        $x = 0.0
        $spineY = 0.0
        foreach ($spineNode in $spine) {
            $hangers = @(if ($ownerOf.ContainsKey($spineNode)) { $ownerOf[$spineNode] } else { @() })
            $columnWidth = $SizeOf[$spineNode].Width
            foreach ($h in $hangers) { if ($SizeOf[$h].Width -gt $columnWidth) { $columnWidth = $SizeOf[$h].Width } }

            $positions[$spineNode] = [pscustomobject]@{ X = $x; Y = $spineY }
            $above = 0.0; $below = 0.0
            for ($i = 0; $i -lt $hangers.Count; $i++) {
                $h = $hangers[$i]
                if ($i % 2 -eq 0) {
                    $below += $SizeOf[$spineNode].Height + $rowGap
                    $positions[$h] = [pscustomobject]@{ X = $x; Y = $spineY + $below }
                    $below += $SizeOf[$h].Height - $SizeOf[$spineNode].Height
                }
                else {
                    $above += $SizeOf[$h].Height + $rowGap
                    $positions[$h] = [pscustomobject]@{ X = $x; Y = $spineY - $above }
                }
            }
            $x += $columnWidth + $columnGap
        }
        return $positions
    }

    return Invoke-DrawioPerComponent -Adjacency $Adjacency -Keys $Keys -SizeOf $SizeOf -ClusterBuilder $builder `
        -Packing $Options.Packing -ClusterGap $Options.ClusterGap -StartX $Options.StartX -StartY $Options.StartY -MaxRowWidth $Options.MaxRowWidth
}


# ============================================================================
# Strategy: Balloon
# ============================================================================
# The classic balloon tree: every subtree is drawn inside its own disc, and a parent's children are
# discs packed around it. The appeal is that a subtree is self-contained rather than sharing a global
# ring with unrelated branches, so a dense branch grows its own disc instead of pushing every other
# branch's ring outward - exactly the coupling that lets one crowded ring inflate a whole page.
#
# It does not survive contact with these topologies, and the reason is structural rather than a
# tuning problem. A parent's disc has to CONTAIN its children's discs, so its radius is at least
# (its own half-size) + twice (the largest child's radius): every level of depth roughly doubles the
# radius. On a shallow, bushy graph that is fine, but on a deep one - nine hops or so - doubling
# nine times is the difference between a page and a wall. The measured result is a page several
# times larger than any other strategy.
#
# The standard cure is to limit each subtree to an angular wedge so its radius scales with the wedge
# rather than with the whole circle - at which point it has become the starburst in
# Get-DrawioRadialPlacement. So balloon offers nothing here that the radial layout does not already
# do, and its distinguishing feature is the thing that breaks it.
function Invoke-DrawioBalloonPlacement {
    param([hashtable]$Adjacency, [object[]]$Keys, [hashtable]$SizeOf, [hashtable]$Options)

    $builder = {
        param([object[]]$Members, [hashtable]$Neighbors, [hashtable]$SizeOf)
        $members = @($Members)
        $positions = @{}
        if ($members.Count -eq 1) { $positions[$members[0]] = [pscustomobject]@{ X = 0.0; Y = 0.0 }; return $positions }
        $memberSet = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($m in $members) { [void]$memberSet.Add($m) }

        $centre = Get-DrawioComponentCentre -Members $members -Neighbors $Neighbors
        $distance = Get-DrawioHopDistance -Source $centre -Members $members -Neighbors $Neighbors
        $degreeOf = @{}
        foreach ($m in $members) { $degreeOf[$m] = @($Neighbors[$m] | Where-Object { $memberSet.Contains($_) }).Count }

        # Spanning tree, each node hung off its best-connected neighbour one hop closer in.
        $childrenOf = @{}
        foreach ($m in $members) { $childrenOf[$m] = [System.Collections.Generic.List[string]]::new() }
        foreach ($m in $members) {
            if ($m -eq $centre -or -not $distance.ContainsKey($m)) { continue }
            $candidates = @($Neighbors[$m] | Where-Object { $memberSet.Contains($_) -and $distance.ContainsKey($_) -and $distance[$_] -eq ($distance[$m] - 1) })
            if ($candidates.Count -eq 0) { continue }
            $parent = @($candidates | Sort-Object @{Expression = { -$degreeOf[$_] }}, @{Expression = { $_ }})[0]
            $childrenOf[$parent].Add($m)
        }

        # Radius of each subtree's disc, deepest first so a parent knows how big its children are.
        $radiusOf = @{}
        $byDepth = @($members | Where-Object { $distance.ContainsKey($_) } | Sort-Object @{Expression = { -$distance[$_] }})
        foreach ($m in $byDepth) {
            $own = [Math]::Sqrt([Math]::Pow($SizeOf[$m].Width, 2) + [Math]::Pow($SizeOf[$m].Height, 2)) / 2.0
            $children = @($childrenOf[$m])
            if ($children.Count -eq 0) { $radiusOf[$m] = $own; continue }
            # Children sit on a circle big enough that their own discs do not touch.
            $sum = 0.0; $largest = 0.0
            foreach ($child in $children) { $sum += $radiusOf[$child]; if ($radiusOf[$child] -gt $largest) { $largest = $radiusOf[$child] } }
            $ringRadius = [Math]::Max($own + $largest + 30.0, (($sum * 2.2) / [Math]::PI))
            $radiusOf[$m] = $ringRadius + $largest
        }

        # Place outward from the centre, each node given the wedge its own disc needs.
        $place = {
            param([string]$Key, [double]$CentreX, [double]$CentreY, [double]$FacingAngle)
            $size = $SizeOf[$Key]
            $positions[$Key] = [pscustomobject]@{ X = $CentreX - ($size.Width / 2.0); Y = $CentreY - ($size.Height / 2.0) }
            $children = @($childrenOf[$Key])
            if ($children.Count -eq 0) { return }
            $own = [Math]::Sqrt([Math]::Pow($size.Width, 2) + [Math]::Pow($size.Height, 2)) / 2.0
            $sum = 0.0; $largest = 0.0
            foreach ($child in $children) { $sum += $radiusOf[$child]; if ($radiusOf[$child] -gt $largest) { $largest = $radiusOf[$child] } }
            $ringRadius = [Math]::Max($own + $largest + 30.0, (($sum * 2.2) / [Math]::PI))

            # The root owns the whole circle; everything else keeps a gap facing its parent so the
            # link back in has somewhere to go.
            $span = if ($Key -eq $centre) { 2.0 * [Math]::PI } else { 1.5 * [Math]::PI }
            $cursor = $FacingAngle - ($span / 2.0)
            foreach ($child in $children) {
                $share = if ($sum -gt 0) { $span * ($radiusOf[$child] / $sum) } else { $span / $children.Count }
                $angle = $cursor + ($share / 2.0)
                # No horizontal stretch here, unlike the starburst. A balloon subtree reserves a
                # CIRCLE of a computed radius, and stretching only the X coordinate puts the drawing
                # somewhere the radius calculation never agreed to - the discs stop matching the space
                # they were sized for, and the page runs away horizontally. Squashing a balloon tree
                # for screen shape would mean scaling the radii too, which is a different design.
                & $place $child ($CentreX + ($ringRadius * [Math]::Cos($angle))) ($CentreY + ($ringRadius * [Math]::Sin($angle))) $angle
                $cursor += $share
            }
        }
        & $place $centre 0.0 0.0 0.0
        return $positions
    }

    return Invoke-DrawioPerComponent -Adjacency $Adjacency -Keys $Keys -SizeOf $SizeOf -ClusterBuilder $builder `
        -Packing $Options.Packing -ClusterGap $Options.ClusterGap -StartX $Options.StartX -StartY $Options.StartY -MaxRowWidth $Options.MaxRowWidth
}


# ============================================================================
# Overlap removal - needed by any strategy that treats cards as points
# ============================================================================
# Force-directed layouts optimise the positions of dimensionless points, so cards routinely land on
# top of each other. Without this they would fail the overlap gate on every site and the run would
# say nothing about whether the layout was any good. Pushes overlapping pairs apart along the line
# between them, a few passes, preserving the shape the forces found.
function Resolve-DrawioOverlaps {
    param([hashtable]$Positions, [object[]]$Keys, [hashtable]$SizeOf, [int]$Passes = 60, [double]$Padding = 24.0)

    $keys = @($Keys | Where-Object { $Positions[$_] })
    for ($pass = 0; $pass -lt $Passes; $pass++) {
        $moved = $false
        for ($i = 0; $i -lt $keys.Count; $i++) {
            for ($j = $i + 1; $j -lt $keys.Count; $j++) {
                $a = $Positions[$keys[$i]]; $sizeA = $SizeOf[$keys[$i]]
                $b = $Positions[$keys[$j]]; $sizeB = $SizeOf[$keys[$j]]
                $overlapX = (($sizeA.Width + $sizeB.Width) / 2.0 + $Padding) - [Math]::Abs(($a.X + $sizeA.Width / 2.0) - ($b.X + $sizeB.Width / 2.0))
                $overlapY = (($sizeA.Height + $sizeB.Height) / 2.0 + $Padding) - [Math]::Abs(($a.Y + $sizeA.Height / 2.0) - ($b.Y + $sizeB.Height / 2.0))
                if ($overlapX -le 0 -or $overlapY -le 0) { continue }
                $moved = $true
                # Separate along whichever axis needs the smaller push, which disturbs the layout least.
                if ($overlapX -lt $overlapY) {
                    $shift = ($overlapX / 2.0) + 0.5
                    if (($a.X) -le ($b.X)) { $a.X -= $shift; $b.X += $shift } else { $a.X += $shift; $b.X -= $shift }
                }
                else {
                    $shift = ($overlapY / 2.0) + 0.5
                    if (($a.Y) -le ($b.Y)) { $a.Y -= $shift; $b.Y += $shift } else { $a.Y += $shift; $b.Y -= $shift }
                }
            }
        }
        if (-not $moved) { break }
    }
    return $Positions
}


# ============================================================================
# Strategy: Force and Force-Seeded
# ============================================================================
# Fruchterman-Reingold: linked cards attract, all cards repel, the whole thing cools. This is the
# standard answer for drawing a network and the obvious thing to be asked "why didn't you just use a
# force layout?", so it is measured rather than argued about.
#
# Force-Seeded starts from the starburst instead of from random noise. A force layout finds a local
# minimum and nothing more, so where it starts decides where it ends: seeding it keeps the branch
# structure the starburst found and lets the forces pull the slack out.
function Invoke-DrawioForcePlacement {
    param([hashtable]$Adjacency, [object[]]$Keys, [hashtable]$SizeOf, [hashtable]$Options, [switch]$Seeded)

    $seedPositions = $null
    if ($Seeded) {
        $seed = Get-DrawioRadialPlacement -Adjacency $Adjacency -Keys $Keys -FootprintOf $SizeOf `
            -StartX 0 -StartY 0 -NodeGap $Options.NodeGap -RingGap $Options.RingGap `
            -AspectRatio $Options.AspectRatio -Sweeps $Options.Sweeps -MaxStagger $Options.MaxStagger `
            -RingSpacing $Options.RingSpacing -ClusterPacking $Options.Packing -MaxRowWidth $Options.MaxRowWidth
        $seedPositions = $seed.Positions
    }

    $builder = {
        param([object[]]$Members, [hashtable]$Neighbors, [hashtable]$SizeOf)
        $members = @($Members)
        $positions = @{}
        if ($members.Count -eq 1) { $positions[$members[0]] = [pscustomobject]@{ X = 0.0; Y = 0.0 }; return $positions }
        $memberSet = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($m in $members) { [void]$memberSet.Add($m) }

        # Ideal edge length, from the area the cards need. The classic k = sqrt(area / n).
        $cardArea = 0.0
        foreach ($m in $members) { $cardArea += ($SizeOf[$m].Width + 60.0) * ($SizeOf[$m].Height + 60.0) }
        $k = [Math]::Sqrt($cardArea / $members.Count) * 1.4
        $span = [Math]::Sqrt($cardArea) * 1.2

        $random = [System.Random]::new(20260822)
        $pos = @{}
        foreach ($m in $members) {
            if ($seedPositions -and $seedPositions[$m]) {
                $pos[$m] = [pscustomobject]@{ X = [double]$seedPositions[$m].X; Y = [double]$seedPositions[$m].Y }
            }
            else {
                $pos[$m] = [pscustomobject]@{ X = ($random.NextDouble() - 0.5) * $span; Y = ($random.NextDouble() - 0.5) * $span }
            }
        }

        $iterations = 300
        $temperature = $span / 8.0
        $cooling = $temperature / ($iterations + 1)
        for ($step = 0; $step -lt $iterations; $step++) {
            $dispX = @{}; $dispY = @{}
            foreach ($m in $members) { $dispX[$m] = 0.0; $dispY[$m] = 0.0 }

            for ($i = 0; $i -lt $members.Count; $i++) {
                for ($j = $i + 1; $j -lt $members.Count; $j++) {
                    $a = $members[$i]; $b = $members[$j]
                    $dx = $pos[$a].X - $pos[$b].X; $dy = $pos[$a].Y - $pos[$b].Y
                    $d = [Math]::Sqrt(($dx * $dx) + ($dy * $dy))
                    if ($d -lt 0.01) { $d = 0.01; $dx = 0.01 }
                    $force = ($k * $k) / $d
                    $dispX[$a] += ($dx / $d) * $force; $dispY[$a] += ($dy / $d) * $force
                    $dispX[$b] -= ($dx / $d) * $force; $dispY[$b] -= ($dy / $d) * $force
                }
            }
            foreach ($m in $members) {
                foreach ($peer in @($Neighbors[$m])) {
                    if (-not $memberSet.Contains($peer) -or $peer -le $m) { continue }
                    $dx = $pos[$m].X - $pos[$peer].X; $dy = $pos[$m].Y - $pos[$peer].Y
                    $d = [Math]::Sqrt(($dx * $dx) + ($dy * $dy))
                    if ($d -lt 0.01) { continue }
                    $force = ($d * $d) / $k
                    $dispX[$m] -= ($dx / $d) * $force; $dispY[$m] -= ($dy / $d) * $force
                    $dispX[$peer] += ($dx / $d) * $force; $dispY[$peer] += ($dy / $d) * $force
                }
            }
            foreach ($m in $members) {
                $d = [Math]::Sqrt(($dispX[$m] * $dispX[$m]) + ($dispY[$m] * $dispY[$m]))
                if ($d -lt 0.01) { continue }
                $limit = [Math]::Min($d, $temperature)
                $pos[$m].X += ($dispX[$m] / $d) * $limit
                $pos[$m].Y += ($dispY[$m] / $d) * $limit
            }
            $temperature -= $cooling
        }

        foreach ($m in $members) {
            $positions[$m] = [pscustomobject]@{ X = $pos[$m].X - ($SizeOf[$m].Width / 2.0); Y = $pos[$m].Y - ($SizeOf[$m].Height / 2.0) }
        }
        return Resolve-DrawioOverlaps -Positions $positions -Keys $members -SizeOf $SizeOf
    }

    return Invoke-DrawioPerComponent -Adjacency $Adjacency -Keys $Keys -SizeOf $SizeOf -ClusterBuilder $builder `
        -Packing $Options.Packing -ClusterGap $Options.ClusterGap -StartX $Options.StartX -StartY $Options.StartY -MaxRowWidth $Options.MaxRowWidth
}


# ============================================================================
# Strategy: SwapAnneal
# ============================================================================
# Keeps the starburst's positions exactly and only decides WHICH card goes in which slot, by
# simulated annealing against total link length. Swapping two same-sized cards cannot create an
# overlap, so the geometry stays valid for free and the search is purely about assignment - the one
# thing the constructive layout does with a heuristic (barycenter sweeps) rather than a search.
function Invoke-DrawioSwapAnnealPlacement {
    param([hashtable]$Adjacency, [object[]]$Keys, [hashtable]$SizeOf, [hashtable]$Options)

    $base = Get-DrawioRadialPlacement -Adjacency $Adjacency -Keys $Keys -FootprintOf $SizeOf `
        -StartX $Options.StartX -StartY $Options.StartY -NodeGap $Options.NodeGap -RingGap $Options.RingGap `
        -AspectRatio $Options.AspectRatio -Sweeps $Options.Sweeps -MaxStagger $Options.MaxStagger `
        -RingSpacing $Options.RingSpacing -ClusterPacking $Options.Packing -MaxRowWidth $Options.MaxRowWidth

    $positions = $base.Positions
    # SORTED, not in whatever order the keys arrived. The search below walks a seeded random sequence
    # over this list, so its order decides which swaps are tried - and the keys reach here in hashtable
    # enumeration order, which is not stable between processes. Left unsorted this produced a different
    # layout on every run - a different count of links through cards and of crossings on each sweep,
    # from identical inputs. For a tool whose output gets saved and compared, a layout that moves on
    # its own is a defect regardless of how good the numbers are.
    $placed = @($Keys | Where-Object { $positions[$_] } | Sort-Object)
    if ($placed.Count -lt 4) { return $base }

    # Only same-size cards may trade places; a swap between different sizes could overlap.
    $centreOf = {
        param([string]$Key)
        [pscustomobject]@{ X = $positions[$Key].X + ($SizeOf[$Key].Width / 2.0); Y = $positions[$Key].Y + ($SizeOf[$Key].Height / 2.0) }
    }
    $neighborsOf = @{}
    foreach ($key in $placed) { $neighborsOf[$key] = @($Adjacency[$key] | Where-Object { $positions[$_] }) }
    foreach ($key in $placed) {
        foreach ($peer in @($Adjacency[$key])) {
            if ($positions[$peer] -and $neighborsOf.ContainsKey($peer) -and $neighborsOf[$peer] -notcontains $key) { $neighborsOf[$peer] += $key }
        }
    }

    $costOf = {
        param([string]$Key)
        $total = 0.0
        $a = & $centreOf $Key
        foreach ($peer in $neighborsOf[$Key]) {
            $b = & $centreOf $peer
            $total += [Math]::Sqrt([Math]::Pow($a.X - $b.X, 2) + [Math]::Pow($a.Y - $b.Y, 2))
        }
        return $total
    }

    $random = [System.Random]::new(20260822)
    $attempts = [Math]::Min(20000, $placed.Count * 400)
    for ($step = 0; $step -lt $attempts; $step++) {
        $a = $placed[$random.Next($placed.Count)]
        $b = $placed[$random.Next($placed.Count)]
        if ($a -eq $b) { continue }
        if ($SizeOf[$a].Width -ne $SizeOf[$b].Width -or $SizeOf[$a].Height -ne $SizeOf[$b].Height) { continue }

        $before = (& $costOf $a) + (& $costOf $b)
        $swap = $positions[$a]; $positions[$a] = $positions[$b]; $positions[$b] = $swap
        $after = (& $costOf $a) + (& $costOf $b)
        # Strictly downhill. A proper annealing schedule would sometimes accept a worse swap to escape
        # a local minimum, but the starting point here is already a considered layout rather than
        # noise, so the useful question is whether local repair helps at all.
        if ($after -ge $before) { $swap = $positions[$a]; $positions[$a] = $positions[$b]; $positions[$b] = $swap }
    }

    return [pscustomobject]@{ Positions = $positions; Rings = $base.Rings; Centers = $base.Centers; Width = $base.Width; Height = $base.Height }
}


# ============================================================================
# Strategies: Community and Prefix
# ============================================================================
# Both lay the site out as groups-of-starbursts rather than one starburst: partition the devices,
# draw each partition on its own, then pack the partitions. They differ only in where the grouping
# comes from - Community reads it off the graph by label propagation, Prefix reads it off the
# hostnames, which is the one place in this whole exercise that domain knowledge gets used.
#
# The bet is that a site is really several small topologies that happen to be connected. The risk is
# the same fact from the other side: every link BETWEEN groups becomes long, because neither group
# was laid out knowing the other existed.
function Get-DrawioLabelCommunities {
    param([object[]]$Keys, [hashtable]$Adjacency)
    $label = @{}
    foreach ($key in $Keys) { $label[$key] = $key }
    for ($round = 0; $round -lt 12; $round++) {
        $changed = $false
        foreach ($key in @($Keys | Sort-Object)) {
            $counts = @{}
            foreach ($peer in @($Adjacency[$key])) {
                if (-not $label.ContainsKey($peer)) { continue }
                $peerLabel = $label[$peer]
                if (-not $counts.ContainsKey($peerLabel)) { $counts[$peerLabel] = 0 }
                $counts[$peerLabel]++
            }
            if ($counts.Count -eq 0) { continue }
            $best = @($counts.Keys | Sort-Object @{Expression = { -$counts[$_] }}, @{Expression = { $_ }})[0]
            if ($best -ne $label[$key]) { $label[$key] = $best; $changed = $true }
        }
        if (-not $changed) { break }
    }
    return $label
}

# Derives the hostname prefix (site/facility group) from a placement key, stripping trailing numeric suffixes; keys for peers/evidence/end-units map to the 'other' group. Used to cluster nodes by site in layout.
function Get-DrawioHostnamePrefix {
    param([string]$Key)
    # Peers and blocks are not devices and have no meaningful hostname prefix.
    if ($Key -like 'peer:*' -or $Key -like 'evidence:*' -or $Key -like 'endunit:*') { return 'other' }
    # Trim the trailing instance number and any separator before it, so CORE-SW01 groups with
    # CORE-SW02: 'CORE-SW01' -> 'core-sw', 'accessw07' -> 'accessw'.
    $trimmed = [regex]::Replace($Key, '[-_]?\d+$', '')
    if (-not $trimmed) { return 'other' }
    return $trimmed.ToLowerInvariant()
}

# Lays out nodes in radial clusters grouped by site (via GroupOf), running a radial placement within each group and composing the per-group clusters into one position map. Returns the updated positions.
function Invoke-DrawioGroupedRadialPlacement {
    param([hashtable]$Adjacency, [object[]]$Keys, [hashtable]$SizeOf, [hashtable]$Options, [hashtable]$GroupOf)

    $byGroup = @{}
    foreach ($key in $Keys) {
        $group = if ($GroupOf.ContainsKey($key)) { [string]$GroupOf[$key] } else { 'other' }
        if (-not $byGroup.ContainsKey($group)) { $byGroup[$group] = [System.Collections.Generic.List[string]]::new() }
        $byGroup[$group].Add($key)
    }

    $clusters = [System.Collections.Generic.List[object]]::new()
    foreach ($group in @($byGroup.Keys | Sort-Object)) {
        $members = @($byGroup[$group])
        $memberSet = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($m in $members) { [void]$memberSet.Add($m) }
        # Intra-group links only: that is what makes this a group layout rather than one big one.
        $subAdjacency = @{}
        foreach ($m in $members) { $subAdjacency[$m] = @($Adjacency[$m] | Where-Object { $memberSet.Contains($_) }) }
        $footprints = @{}
        foreach ($m in $members) { $footprints[$m] = $SizeOf[$m] }

        $sub = Get-DrawioRadialPlacement -Adjacency $subAdjacency -Keys $members -FootprintOf $footprints `
            -StartX 0 -StartY 0 -NodeGap $Options.NodeGap -RingGap $Options.RingGap `
            -AspectRatio $Options.AspectRatio -Sweeps $Options.Sweeps -MaxStagger $Options.MaxStagger `
            -RingSpacing $Options.RingSpacing -ClusterPacking $Options.Packing -MaxRowWidth $Options.MaxRowWidth
        if (@($sub.Positions.Keys).Count -eq 0) { continue }
        $clusters.Add([pscustomobject]@{ Positions = $sub.Positions; Width = $sub.Width; Height = $sub.Height; Rings = @{}; Centers = @() })
    }

    $ordered = @($clusters | Sort-Object { -($_.Width * $_.Height) })
    return Get-DrawioClusterPacking -Clusters $ordered -SizeOf $SizeOf -HeightScale 1.0 `
        -Packing $Options.Packing -ClusterGap $Options.ClusterGap -StartX $Options.StartX -StartY $Options.StartY -MaxRowWidth $Options.MaxRowWidth
}


# ============================================================================
# Strategy: SpineRadial
# ============================================================================
# The backbone idea from Spine, without the failure it exposed. Spine hangs each backbone node's
# dependants in a vertical column, which routes a large number of links through cards they do not
# connect to - a column of cards is a wall, and the next branch's links have to cross it. Here each
# backbone node gets a small starburst of its own instead, so its dependants surround it rather than
# stack above and below it. If the backbone shape is worth anything, this is the version that shows
# it; if this fails too, the shape is the problem rather than the hanging.
function Invoke-DrawioSpineRadialPlacement {
    param([hashtable]$Adjacency, [object[]]$Keys, [hashtable]$SizeOf, [hashtable]$Options)

    $builder = {
        param([object[]]$Members, [hashtable]$Neighbors, [hashtable]$SizeOf)
        $members = @($Members)
        $positions = @{}
        if ($members.Count -le 2) {
            $x = 0.0
            foreach ($m in $members) { $positions[$m] = [pscustomobject]@{ X = $x; Y = 0.0 }; $x += $SizeOf[$m].Width + 60.0 }
            return $positions
        }
        $memberSet = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($m in $members) { [void]$memberSet.Add($m) }

        $farthest = {
            param([string]$From)
            $distance = Get-DrawioHopDistance -Source $From -Members $members -Neighbors $Neighbors
            $best = $From; $bestD = -1
            foreach ($entry in $distance.GetEnumerator()) {
                if ($entry.Value -gt $bestD -or ($entry.Value -eq $bestD -and [string]$entry.Key -lt [string]$best)) {
                    $best = [string]$entry.Key; $bestD = $entry.Value
                }
            }
            return [pscustomobject]@{ Node = $best; Distance = $distance }
        }
        $endA = (& $farthest $members[0]).Node
        $sweepB = & $farthest $endA
        $distanceFromA = $sweepB.Distance
        $spine = [System.Collections.Generic.List[string]]::new()
        $current = $sweepB.Node
        $spine.Add($current)
        while ($current -ne $endA) {
            $next = $null
            foreach ($peer in @($Neighbors[$current] | Sort-Object)) {
                if (-not $memberSet.Contains($peer)) { continue }
                if ($distanceFromA.ContainsKey($peer) -and $distanceFromA[$peer] -eq ($distanceFromA[$current] - 1)) { $next = $peer; break }
            }
            if (-not $next) { break }
            $spine.Add($next); $current = $next
        }
        $spineSet = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($s in $spine) { [void]$spineSet.Add($s) }

        $ownerOf = @{}
        foreach ($s in $spine) { $ownerOf[$s] = [System.Collections.Generic.List[string]]::new() }
        $distanceFromSpine = @{}
        foreach ($s in $spine) {
            $d = Get-DrawioHopDistance -Source $s -Members $members -Neighbors $Neighbors
            foreach ($entry in $d.GetEnumerator()) {
                $key = [string]$entry.Key
                if ($spineSet.Contains($key)) { continue }
                if (-not $distanceFromSpine.ContainsKey($key) -or $entry.Value -lt $distanceFromSpine[$key].Distance) {
                    $distanceFromSpine[$key] = [pscustomobject]@{ Distance = $entry.Value; Owner = $s }
                }
            }
        }
        foreach ($entry in $distanceFromSpine.GetEnumerator()) { $ownerOf[$entry.Value.Owner].Add([string]$entry.Key) }

        # Each backbone node plus its dependants laid out as a little starburst, then those starbursts
        # threaded left to right along the backbone.
        $x = 0.0
        foreach ($spineNode in $spine) {
            $group = @(@($spineNode) + @($ownerOf[$spineNode]))
            $subAdjacency = @{}
            $groupSet = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($g in $group) { [void]$groupSet.Add($g) }
            foreach ($g in $group) { $subAdjacency[$g] = @($Neighbors[$g] | Where-Object { $groupSet.Contains($_) }) }
            $footprints = @{}
            foreach ($g in $group) { $footprints[$g] = $SizeOf[$g] }

            $sub = Get-DrawioRadialPlacement -Adjacency $subAdjacency -Keys $group -FootprintOf $footprints `
                -StartX 0 -StartY 0 -NodeGap 35 -RingGap 35 -AspectRatio 1.8 -Sweeps 4 -MaxStagger 3 `
                -RingSpacing 'Bound' -ClusterPacking 'Corner' -MaxRowWidth 4000
            foreach ($g in $group) {
                if (-not $sub.Positions[$g]) { continue }
                $positions[$g] = [pscustomobject]@{ X = $x + $sub.Positions[$g].X; Y = $sub.Positions[$g].Y - ($sub.Height / 2.0) }
            }
            $x += $sub.Width + 80.0
        }
        return $positions
    }

    return Invoke-DrawioPerComponent -Adjacency $Adjacency -Keys $Keys -SizeOf $SizeOf -ClusterBuilder $builder `
        -Packing $Options.Packing -ClusterGap $Options.ClusterGap -StartX $Options.StartX -StartY $Options.StartY -MaxRowWidth $Options.MaxRowWidth
}


# ============================================================================
# Strategy: Treemap
# ============================================================================
# Recursive rectangular subdivision by subtree size: the most space-efficient way to put a tree on a
# page, and the natural upper bound on how densely these devices could possibly be packed while still
# grouping branches together. Its weakness is structural and known in advance - a treemap encodes
# containment, not adjacency, so nothing about a rectangle's position says where its links go. It is
# here to put a number on that trade rather than because it is expected to win.
function Invoke-DrawioTreemapPlacement {
    param([hashtable]$Adjacency, [object[]]$Keys, [hashtable]$SizeOf, [hashtable]$Options)

    $builder = {
        param([object[]]$Members, [hashtable]$Neighbors, [hashtable]$SizeOf)
        $members = @($Members)
        $positions = @{}
        if ($members.Count -eq 1) { $positions[$members[0]] = [pscustomobject]@{ X = 0.0; Y = 0.0 }; return $positions }
        $memberSet = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($m in $members) { [void]$memberSet.Add($m) }

        $centre = Get-DrawioComponentCentre -Members $members -Neighbors $Neighbors
        $distance = Get-DrawioHopDistance -Source $centre -Members $members -Neighbors $Neighbors
        $degreeOf = @{}
        foreach ($m in $members) { $degreeOf[$m] = @($Neighbors[$m] | Where-Object { $memberSet.Contains($_) }).Count }
        $childrenOf = @{}
        foreach ($m in $members) { $childrenOf[$m] = [System.Collections.Generic.List[string]]::new() }
        foreach ($m in $members) {
            if ($m -eq $centre -or -not $distance.ContainsKey($m)) { continue }
            $candidates = @($Neighbors[$m] | Where-Object { $memberSet.Contains($_) -and $distance.ContainsKey($_) -and $distance[$_] -eq ($distance[$m] - 1) })
            if ($candidates.Count -eq 0) { continue }
            $childrenOf[@($candidates | Sort-Object @{Expression = { -$degreeOf[$_] }}, @{Expression = { $_ }})[0]].Add($m)
        }

        $countOf = @{}
        foreach ($m in @($members | Where-Object { $distance.ContainsKey($_) } | Sort-Object @{Expression = { -$distance[$_] }})) {
            $total = 1
            foreach ($child in $childrenOf[$m]) { $total += $countOf[$child] }
            $countOf[$m] = $total
        }

        $cellW = 260.0; $cellH = 130.0
        $place = {
            param([string]$Key, [double]$X, [double]$Y, [double]$Width, [double]$Height)
            $positions[$Key] = [pscustomobject]@{ X = $X; Y = $Y }
            $children = @($childrenOf[$Key])
            if ($children.Count -eq 0) { return }
            # The parent keeps the first row; children divide what is left, split along whichever
            # axis is currently longer so the rectangles stay near square.
            $restY = $Y + $cellH
            $restH = $Height - $cellH
            if ($restH -lt $cellH) { $restH = $cellH * [Math]::Ceiling($countOf[$Key] / 2.0) }
            $totalWeight = 0.0
            foreach ($child in $children) { $totalWeight += $countOf[$child] }
            if ($Width -ge $restH) {
                $cursor = $X
                foreach ($child in $children) {
                    $share = $Width * ($countOf[$child] / $totalWeight)
                    & $place $child $cursor $restY $share $restH
                    $cursor += $share
                }
            }
            else {
                $cursor = $restY
                foreach ($child in $children) {
                    $share = $restH * ($countOf[$child] / $totalWeight)
                    & $place $child $X $cursor $Width $share
                    $cursor += $share
                }
            }
        }
        $side = [Math]::Sqrt($members.Count)
        & $place $centre 0.0 0.0 ($cellW * [Math]::Max(2.0, $side * 1.6)) ($cellH * [Math]::Max(2.0, $side * 1.6))
        return Resolve-DrawioOverlaps -Positions $positions -Keys $members -SizeOf $SizeOf
    }

    return Invoke-DrawioPerComponent -Adjacency $Adjacency -Keys $Keys -SizeOf $SizeOf -ClusterBuilder $builder `
        -Packing $Options.Packing -ClusterGap $Options.ClusterGap -StartX $Options.StartX -StartY $Options.StartY -MaxRowWidth $Options.MaxRowWidth
}


# ============================================================================
# Strategy: HTree
# ============================================================================
# The recursive H: a node's children go left and right, their children up and down, the offset
# halving each level. It is the textbook compact tree drawing and produces beautifully regular
# pictures of balanced binary trees. Real network topologies are neither balanced nor binary, so what
# is being measured here is how much of that regularity survives contact with a lopsided graph.
function Invoke-DrawioHTreePlacement {
    param([hashtable]$Adjacency, [object[]]$Keys, [hashtable]$SizeOf, [hashtable]$Options)

    $builder = {
        param([object[]]$Members, [hashtable]$Neighbors, [hashtable]$SizeOf)
        $members = @($Members)
        $positions = @{}
        if ($members.Count -eq 1) { $positions[$members[0]] = [pscustomobject]@{ X = 0.0; Y = 0.0 }; return $positions }
        $memberSet = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($m in $members) { [void]$memberSet.Add($m) }

        $centre = Get-DrawioComponentCentre -Members $members -Neighbors $Neighbors
        $distance = Get-DrawioHopDistance -Source $centre -Members $members -Neighbors $Neighbors
        $degreeOf = @{}
        foreach ($m in $members) { $degreeOf[$m] = @($Neighbors[$m] | Where-Object { $memberSet.Contains($_) }).Count }
        $childrenOf = @{}
        foreach ($m in $members) { $childrenOf[$m] = [System.Collections.Generic.List[string]]::new() }
        foreach ($m in $members) {
            if ($m -eq $centre -or -not $distance.ContainsKey($m)) { continue }
            $candidates = @($Neighbors[$m] | Where-Object { $memberSet.Contains($_) -and $distance.ContainsKey($_) -and $distance[$_] -eq ($distance[$m] - 1) })
            if ($candidates.Count -eq 0) { continue }
            $childrenOf[@($candidates | Sort-Object @{Expression = { -$degreeOf[$_] }}, @{Expression = { $_ }})[0]].Add($m)
        }

        $depthOf = @{}
        foreach ($m in $members) { $depthOf[$m] = if ($distance.ContainsKey($m)) { $distance[$m] } else { 0 } }
        $maxDepth = 0
        foreach ($m in $members) { if ($depthOf[$m] -gt $maxDepth) { $maxDepth = $depthOf[$m] } }
        $baseSpan = 300.0 * [Math]::Pow(2, [Math]::Min(5, [Math]::Max(1, [Math]::Ceiling($maxDepth / 2.0))))

        $place = {
            param([string]$Key, [double]$X, [double]$Y, [double]$Span, [bool]$Horizontal)
            $positions[$Key] = [pscustomobject]@{ X = $X - ($SizeOf[$Key].Width / 2.0); Y = $Y - ($SizeOf[$Key].Height / 2.0) }
            $children = @($childrenOf[$Key])
            if ($children.Count -eq 0) { return }
            # Children alternate sides; with more than two they fan out along the same axis.
            for ($i = 0; $i -lt $children.Count; $i++) {
                $offset = $Span * (1 + [Math]::Floor($i / 2.0))
                $sign = if ($i % 2 -eq 0) { -1 } else { 1 }
                if ($Horizontal) { & $place $children[$i] ($X + ($sign * $offset)) $Y ($Span / 2.0) (-not $Horizontal) }
                else             { & $place $children[$i] $X ($Y + ($sign * $offset)) ($Span / 2.0) (-not $Horizontal) }
            }
        }
        & $place $centre 0.0 0.0 $baseSpan $true
        return Resolve-DrawioOverlaps -Positions $positions -Keys $members -SizeOf $SizeOf
    }

    return Invoke-DrawioPerComponent -Adjacency $Adjacency -Keys $Keys -SizeOf $SizeOf -ClusterBuilder $builder `
        -Packing $Options.Packing -ClusterGap $Options.ClusterGap -StartX $Options.StartX -StartY $Options.StartY -MaxRowWidth $Options.MaxRowWidth
}


# ============================================================================
# Post-passes: GridSnap and Gravity
# ============================================================================
# Applied on top of a base layout rather than replacing one.
#
# GridSnap lines cards up on a coarse grid. Nothing about the graph changes; the bet is purely that a
# reader follows a line more easily when the cards it runs between share an edge, and that the tidier
# picture costs nothing.
#
# Gravity pulls every card toward the middle as far as it can go without touching anything, repeated
# until nothing moves. It is the cheapest possible answer to "is there slack left in this layout?" -
# if the answer is no, the constructive spacing was already tight and no amount of compaction work
# will help.
function Invoke-DrawioGridSnap {
    param([hashtable]$Positions, [object[]]$Keys, [hashtable]$SizeOf, [double]$Cell = 40.0)
    foreach ($key in $Keys) {
        if (-not $Positions[$key]) { continue }
        $Positions[$key] = [pscustomobject]@{
            X = [Math]::Round($Positions[$key].X / $Cell) * $Cell
            Y = [Math]::Round($Positions[$key].Y / $Cell) * $Cell
        }
    }
    return Resolve-DrawioOverlaps -Positions $Positions -Keys $Keys -SizeOf $SizeOf -Passes 30 -Padding 8.0
}

# Refines a set of node positions with a simple gravity/packing pass: repeatedly nudges nodes toward the group centroid while respecting a minimum padding, so boxes settle without overlapping. Returns the adjusted positions.
function Invoke-DrawioGravity {
    param([hashtable]$Positions, [object[]]$Keys, [hashtable]$SizeOf, [int]$Passes = 40, [double]$Padding = 24.0)
    $keys = @($Keys | Where-Object { $Positions[$_] })
    if ($keys.Count -lt 2) { return $Positions }

    $sumX = 0.0; $sumY = 0.0
    foreach ($key in $keys) { $sumX += $Positions[$key].X + ($SizeOf[$key].Width / 2.0); $sumY += $Positions[$key].Y + ($SizeOf[$key].Height / 2.0) }
    $centreX = $sumX / $keys.Count; $centreY = $sumY / $keys.Count

    $fits = {
        param([string]$Key, [double]$X, [double]$Y)
        foreach ($other in $keys) {
            if ($other -eq $Key) { continue }
            $b = $Positions[$other]; $sizeB = $SizeOf[$other]
            if ($X -lt ($b.X + $sizeB.Width + $Padding) -and $b.X -lt ($X + $SizeOf[$Key].Width + $Padding) -and
                $Y -lt ($b.Y + $sizeB.Height + $Padding) -and $b.Y -lt ($Y + $SizeOf[$Key].Height + $Padding)) { return $false }
        }
        return $true
    }

    for ($pass = 0; $pass -lt $Passes; $pass++) {
        $moved = $false
        # Furthest out first: an outer card that comes in frees the space the next one wants.
        foreach ($key in @($keys | Sort-Object {
            -([Math]::Pow($Positions[$_].X - $centreX, 2) + [Math]::Pow($Positions[$_].Y - $centreY, 2))
        })) {
            $point = $Positions[$key]
            $dx = $centreX - ($point.X + ($SizeOf[$key].Width / 2.0))
            $dy = $centreY - ($point.Y + ($SizeOf[$key].Height / 2.0))
            $d = [Math]::Sqrt(($dx * $dx) + ($dy * $dy))
            if ($d -lt 1.0) { continue }
            $step = [Math]::Min(40.0, $d)
            $newX = $point.X + (($dx / $d) * $step)
            $newY = $point.Y + (($dy / $d) * $step)
            if (& $fits $key $newX $newY) { $Positions[$key] = [pscustomobject]@{ X = $newX; Y = $newY }; $moved = $true }
        }
        if (-not $moved) { break }
    }
    return $Positions
}


# ============================================================================
# Dispatcher
# ============================================================================
function Get-DrawioTopologyPlacement {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $true)] [string]$Strategy,
        [parameter(Mandatory = $true)] [hashtable]$Adjacency,
        [parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Keys,
        [parameter(Mandatory = $true)] [hashtable]$FootprintOf,
        # Everything the radial strategy needs, plus the few shared placement settings. Strategies
        # ignore what they do not use.
        [hashtable]$Options = @{}
    )

    $allKeys = @($Keys | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
    if ($allKeys.Count -eq 0) {
        return [pscustomobject]@{ Positions = @{}; Rings = @{}; Centers = @(); Width = 0.0; Height = 0.0; Overlaps = 0 }
    }

    $defaults = @{
        StartX = 100.0; StartY = 100.0; ClusterGap = 140.0; MaxRowWidth = 4000.0; Packing = 'Corner'
        NodeGap = 35.0; RingGap = 35.0; AspectRatio = 1.8; Sweeps = 4; MaxStagger = 3; RingSpacing = 'Bound'
    }
    foreach ($key in $defaults.Keys) { if (-not $Options.ContainsKey($key)) { $Options[$key] = $defaults[$key] } }

    $sizeOf = Get-DrawioStrategySizes -Keys $allKeys -FootprintOf $FootprintOf

    $result = switch ($Strategy) {
        'Radial' {
            Get-DrawioRadialPlacement -Adjacency $Adjacency -Keys $allKeys -FootprintOf $FootprintOf `
                -StartX $Options.StartX -StartY $Options.StartY -NodeGap $Options.NodeGap -RingGap $Options.RingGap `
                -AspectRatio $Options.AspectRatio -ClusterGap $Options.ClusterGap -Sweeps $Options.Sweeps `
                -MaxStagger $Options.MaxStagger -RingSpacing $Options.RingSpacing -ClusterPacking $Options.Packing `
                -MaxRowWidth $Options.MaxRowWidth -PreferredCenters @($Options.PreferredCenters)
        }
        'Layered'     { Invoke-DrawioLayeredPlacement     -Adjacency $Adjacency -Keys $allKeys -SizeOf $sizeOf -Options $Options }
        'DegreeRings' { Invoke-DrawioDegreeRingsPlacement -Adjacency $Adjacency -Keys $allKeys -SizeOf $sizeOf -Options $Options }
        'Spiral'      { Invoke-DrawioSpiralPlacement      -Adjacency $Adjacency -Keys $allKeys -SizeOf $sizeOf -Options $Options }
        'Spine'       { Invoke-DrawioSpinePlacement       -Adjacency $Adjacency -Keys $allKeys -SizeOf $sizeOf -Options $Options }
        'Balloon'     { Invoke-DrawioBalloonPlacement     -Adjacency $Adjacency -Keys $allKeys -SizeOf $sizeOf -Options $Options }
        'Force'       { Invoke-DrawioForcePlacement       -Adjacency $Adjacency -Keys $allKeys -SizeOf $sizeOf -Options $Options }
        'ForceSeeded' { Invoke-DrawioForcePlacement       -Adjacency $Adjacency -Keys $allKeys -SizeOf $sizeOf -Options $Options -Seeded }
        'SwapAnneal'  { Invoke-DrawioSwapAnnealPlacement  -Adjacency $Adjacency -Keys $allKeys -SizeOf $sizeOf -Options $Options }
        'Community'   {
            $groupOf = Get-DrawioLabelCommunities -Keys $allKeys -Adjacency $Adjacency
            Invoke-DrawioGroupedRadialPlacement -Adjacency $Adjacency -Keys $allKeys -SizeOf $sizeOf -Options $Options -GroupOf $groupOf
        }
        'Prefix'      {
            $groupOf = @{}
            foreach ($key in $allKeys) { $groupOf[$key] = Get-DrawioHostnamePrefix -Key $key }
            Invoke-DrawioGroupedRadialPlacement -Adjacency $Adjacency -Keys $allKeys -SizeOf $sizeOf -Options $Options -GroupOf $groupOf
        }
        'SpineRadial' { Invoke-DrawioSpineRadialPlacement -Adjacency $Adjacency -Keys $allKeys -SizeOf $sizeOf -Options $Options }
        'Treemap'     { Invoke-DrawioTreemapPlacement     -Adjacency $Adjacency -Keys $allKeys -SizeOf $sizeOf -Options $Options }
        'HTree'       { Invoke-DrawioHTreePlacement       -Adjacency $Adjacency -Keys $allKeys -SizeOf $sizeOf -Options $Options }
        default       { throw "Unknown placement strategy '$Strategy'." }
    }

    # Optional post-passes, applied to whatever the strategy produced. Both are opt-in through
    # -Options so they can be measured on top of any base rather than being baked into one.
    if ($Options.PostPass -and $Options.PostPass -ne 'None') {
        $placedKeys = @($allKeys | Where-Object { $result.Positions[$_] })
        $adjusted = switch ($Options.PostPass) {
            'GridSnap' { Invoke-DrawioGridSnap -Positions $result.Positions -Keys $placedKeys -SizeOf $sizeOf }
            'Gravity'  { Invoke-DrawioGravity  -Positions $result.Positions -Keys $placedKeys -SizeOf $sizeOf }
            default    { $result.Positions }
        }
        # Both passes move cards, so the page box has to be recomputed and rebased to the margin.
        $minX = [double]::PositiveInfinity; $minY = [double]::PositiveInfinity
        $maxX = [double]::NegativeInfinity; $maxY = [double]::NegativeInfinity
        foreach ($key in $placedKeys) {
            $point = $adjusted[$key]; $size = $sizeOf[$key]
            if ($point.X -lt $minX) { $minX = $point.X }
            if ($point.Y -lt $minY) { $minY = $point.Y }
            if (($point.X + $size.Width) -gt $maxX) { $maxX = $point.X + $size.Width }
            if (($point.Y + $size.Height) -gt $maxY) { $maxY = $point.Y + $size.Height }
        }
        if (-not [double]::IsInfinity($minX)) {
            foreach ($key in $placedKeys) {
                $adjusted[$key] = [pscustomobject]@{
                    X = $adjusted[$key].X - $minX + $Options.StartX
                    Y = $adjusted[$key].Y - $minY + $Options.StartY
                }
            }
            $result = [pscustomobject]@{
                Positions = $adjusted; Rings = $result.Rings; Centers = $result.Centers
                Width = ($maxX - $minX); Height = ($maxY - $minY)
            }
        }
    }

    # The one hard invariant, checked centrally so no strategy has to re-implement it and none can
    # quietly skip it. Reported rather than corrected: a strategy that overlaps cards has a bug in its
    # spacing, and silently nudging shapes apart would hide that while producing a layout nobody
    # designed.
    $overlaps = 0
    $placed = @($allKeys | Where-Object { $result.Positions[$_] })
    for ($i = 0; $i -lt $placed.Count; $i++) {
        $a = $result.Positions[$placed[$i]]; $sizeA = $sizeOf[$placed[$i]]
        for ($j = $i + 1; $j -lt $placed.Count; $j++) {
            $b = $result.Positions[$placed[$j]]; $sizeB = $sizeOf[$placed[$j]]
            if ($a.X -lt ($b.X + $sizeB.Width) -and $b.X -lt ($a.X + $sizeA.Width) -and
                $a.Y -lt ($b.Y + $sizeB.Height) -and $b.Y -lt ($a.Y + $sizeA.Height)) { $overlaps++ }
        }
    }

    return [pscustomobject]@{
        Positions = $result.Positions; Rings = $result.Rings; Centers = $result.Centers
        Width = $result.Width; Height = $result.Height; Overlaps = $overlaps
    }
}
