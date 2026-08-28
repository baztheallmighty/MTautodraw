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

# MTAutoDraw - Logging
#
# The one diagnostic channel: file-validity gating and the structured Write-MTAutoDrawLog contract
# (level, phase, elapsed, and the -Device append-only path parallel workers use). Nothing that
# derives a model, lays out a page, or writes a document belongs here - only what turns a run's
# events into readable, ordered output.
#
# Depends on: nothing
# Loaded by:  AutoDraw.ps1 ($GLibrariesToLoad); StartProcessingConfig.ps1 (parallel workers)

# Checks if a file exists, is not empty, and does not contain common CLI errors.
function Test-FileHasValidData {
    param(
        [parameter(Mandatory=$true)]
        [string]$FilePath
    )

    # Check if file exists and has content
    if (-not (Test-Path -Path $FilePath) -or (Get-Item $FilePath).Length -lt 10) {
        return $false
    }

    # Reject collector/device error responses before a parser treats them as valid data.
    $Content = Get-Content -LiteralPath $FilePath -Raw
    $invalidPatterns = @(
        '(?im)^\s*Line has invalid autocommand',
        '(?im)^\s*%?\s*Invalid input(?: detected)?',
        '(?im)^\s*%?\s*Unrecognized command',
        '(?im)^\s*%?\s*Unknown command',
        '(?im)^\s*Invalid command',
        '(?im)^\s*Invalid syntax\.?\s*$',
        '(?im)^\s*Incomplete command',
        '(?im)^\s*Ambiguous command:',
        '(?im)^\s*Syntax error while parsing',
        '(?im)^\s*syntax error, expecting',
        '(?im)^\s*Command fail(?:ed)?(?:\.|:)',
        '(?im)^\s*Return code\s+-?\d+',
        '(?im)^\s*%\s+.+\s+is not enabled\s*$',
        '(?im)^\s*%\s+No matching .+ found\s*$',
        # Cisco Small Business firmware 1.x rejects an unsupported command with these two rather than
        # any of the wordings above.
        '(?im)^\s*%\s*missing mandatory parameter',
        '(?im)^\s*%\s*Wrong number of parameters'
    )
    if ($invalidPatterns | Where-Object { $Content -match $_ } | Select-Object -First 1) {
        return $false
    }

    # If all checks pass, the file is considered valid
    return $true
}


# ------------------------------------------------------------------------------------------------
# Run output. Write-MTAutoDrawLog is the contract every other output helper uses. A record carries a
# Level (Error|Warn|Info|Debug|Trace) as data; console colour is derived from Level. Verdict logic must
# never infer severity from presentation fields that a transcript may not preserve.
# ------------------------------------------------------------------------------------------------

# Ascending verbosity. Every threshold comparison walks this by index rather than compares strings,
# so there is exactly one place that knows the ordering.
$script:MTAutoDrawLogLevels = @('Error', 'Warn', 'Info', 'Debug', 'Trace')

# Returns $true when a log level is at or above the configured visibility threshold (Error > Warn > Info > Debug > Trace).
function Test-MTAutoDrawLogLevelVisible {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Error', 'Warn', 'Info', 'Debug', 'Trace')][string]$Level,
        [string]$Threshold = 'Info'
    )
    $levelIndex = $script:MTAutoDrawLogLevels.IndexOf($Level)
    $thresholdIndex = $script:MTAutoDrawLogLevels.IndexOf($Threshold)
    if ($thresholdIndex -lt 0) { $thresholdIndex = $script:MTAutoDrawLogLevels.IndexOf('Info') }
    return ($levelIndex -ge 0 -and $levelIndex -le $thresholdIndex)
}

# The only place colour is derived. Never stored, never read back as the source of truth.
function Get-MTAutoDrawLogLevelColor {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Level)
    switch ($Level) {
        'Error' { 'Red' }
        'Warn'  { 'Yellow' }
        'Info'  { 'White' }
        'Debug' { 'Gray' }
        'Trace' { 'DarkGray' }
        default { 'White' }
    }
}

# Renders the shared log-line shape: [mm:ss.ff] LEVEL   phase    message
# Fixed-width level/phase columns so the eye can scan straight down them. The one formatter behind
# both the live console path (Write-MTAutoDrawLog with no -Device) and the post-aggregation DebugLog
# flush in Start-ProcessingFiles, so a line buffered from a worker and one printed live from the main
# thread are visually identical - only when they appear differs, never how they look.
function Format-MTAutoDrawLogLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][TimeSpan]$Elapsed,
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message
    )
    $totalMinutes = [Math]::Floor($Elapsed.TotalMinutes)
    $elapsedText = '{0:00}:{1:00}.{2:00}' -f $totalMinutes, $Elapsed.Seconds, [Math]::Floor($Elapsed.Milliseconds / 10)
    return '[{0}] {1,-5} {2,-7} {3}' -f $elapsedText, $Level.ToUpperInvariant(), $Phase.ToLowerInvariant(), $Message
}

# The single output function. Two mutually exclusive behaviours, chosen by whether -Device is given:
#
#   -Device given    Append to $Device.DebugLog and return. Never prints. This is what makes it safe
#                     to call from inside ForEach-Object -Parallel: Write-Host from a worker
#                     interleaves unattributably across threads, so per-device output always goes
#                     through the device's own buffer and is rendered later, on the main thread, once
#                     results are aggregated (the flush loop in Start-ProcessingFiles).
#   -Device omitted  Gated by $GLogLevel and printed immediately via Write-Host. Only call it this way
#                     from the main thread - there is nowhere for the output to interleave safely from
#                     a worker, which is exactly the scenario the -Device branch exists to avoid.
#
# Elapsed comes from the same run-wide stopwatch the old write-HostDebugText always used
# ($global:GLastExecutionTime), so timing semantics are unchanged - only the presentation is, from a
# separate "Time Total:" line before every message to inline elapsed on the message itself.
function Write-MTAutoDrawLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Error', 'Warn', 'Info', 'Debug', 'Trace')][string]$Level,
        [Parameter(Mandatory = $true)][ValidateSet('Load', 'Ingest', 'Parse', 'Resolve', 'Draw', 'Export', 'Summary')][string]$Phase,
        [AllowNull()]$Device,
        # AllowEmptyString: several call sites forward raw capture text verbatim as the message (e.g.
        # "here is the invalid data we rejected"), and that text is sometimes genuinely empty - the
        # untyped $text parameter on the old write-HostDebugText/Add-HostDebugText tolerated this
        # silently; a bare [string] Mandatory parameter does not, and rejects "" as if it were missing.
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message
    )

    if ($Device) {
        # UTC, not Get-Date's local time: the flush loop in Start-ProcessingFiles subtracts this from
        # a UTC run-start to get elapsed, and DateTime subtraction in .NET is a raw tick difference -
        # it does not look at .Kind - so a local timestamp against a UTC run-start would be silently
        # wrong by the machine's timezone offset.
        $Device.DebugLog += [PSCustomObject]@{
            Timestamp = [DateTime]::UtcNow
            Text      = $Message.Trim()
            Level     = $Level
            Phase     = $Phase
        }
        return
    }

    $threshold = if ($global:GLogLevel) { $global:GLogLevel } else { 'Info' }
    if (-not (Test-MTAutoDrawLogLevelVisible -Level $Level -Threshold $threshold)) { return }

    $elapsed = if ($global:GLastExecutionTime) { $global:GLastExecutionTime.Elapsed } else { [TimeSpan]::Zero }
    $line = Format-MTAutoDrawLogLine -Elapsed $elapsed -Level $Level -Phase $Phase -Message $Message.Trim()
    Write-Host $line -ForegroundColor (Get-MTAutoDrawLogLevelColor -Level $Level)
}

# --- TEMPORARY PERF INSTRUMENTATION ----------------------------------------------------------
# Diagnostic output only: nothing in this region changes what the tool produces or decides. It is
# silent unless $GPerfTiming is true (configurationVariables.ps1 sets it from MTAUTODRAW_PERF=1),
# and when it is on, every instrumented step prints one [perf] line as it finishes and the run ends
# with a table sorted by total time.
#
# Start-MTAutoDrawPerf returns $null when timing is off and Stop-MTAutoDrawPerf ignores a $null
# token, so an instrumented call site costs one null check when the switch is off.
#
# MAIN THREAD ONLY. These print through Write-Host, which interleaves unattributably from inside
# ForEach-Object -Parallel - the same reason Write-MTAutoDrawLog has its per-device buffer branch.
# Instrument the dispatch from the parent, never the worker body.
$global:GPerfTotals = [ordered]@{}

function Start-MTAutoDrawPerf {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Label)

    if (-not $global:GPerfTiming) { return $null }
    return [pscustomobject]@{ Label = $Label; Watch = [System.Diagnostics.Stopwatch]::StartNew() }
}

function Stop-MTAutoDrawPerf {
    [CmdletBinding()]
    param(
        [AllowNull()]$Token,
        # Free text appended in parentheses - a row count, a device count, whatever makes the number
        # interpretable. "820 ms" alone does not say whether that is fast.
        [AllowEmptyString()][string]$Detail = ''
    )

    if (-not $Token) { return }
    $Token.Watch.Stop()
    Add-MTAutoDrawPerf -Label $Token.Label -Milliseconds $Token.Watch.Elapsed.TotalMilliseconds

    $elapsed = if ($global:GLastExecutionTime) { $global:GLastExecutionTime.Elapsed } else { [TimeSpan]::Zero }
    $suffix = if ($Detail) { "  ($Detail)" } else { "" }
    $message = "{0,10:N1} ms  {1}{2}" -f $Token.Watch.Elapsed.TotalMilliseconds, $Token.Label, $suffix
    Write-Host (Format-MTAutoDrawLogLine -Elapsed $elapsed -Level "PERF" -Phase "perf" -Message $message) -ForegroundColor DarkCyan
}

# Adds time to a label without its own start/stop pair, and without printing. For accumulating the
# cost of something called inside a hot loop, where a line per iteration would bury the run log.
function Add-MTAutoDrawPerf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][double]$Milliseconds,
        [int]$Count = 1
    )

    if (-not $global:GPerfTiming) { return }
    if ($null -eq $global:GPerfTotals) { $global:GPerfTotals = [ordered]@{} }
    if ($global:GPerfTotals.Contains($Label)) {
        $global:GPerfTotals[$Label].TotalMs += $Milliseconds
        $global:GPerfTotals[$Label].Count += $Count
    }
    else {
        $global:GPerfTotals[$Label] = [pscustomobject]@{ Label = $Label; TotalMs = $Milliseconds; Count = $Count }
    }
}

# The report. Sorted by total time descending, because the question this instrumentation exists to
# answer is "what should I fix first". Percentages are of the run-wide stopwatch, not of the sum of
# the rows: the rows nest (a page total contains its own sub-steps), so they deliberately overlap.
function Write-MTAutoDrawPerfSummary {
    [CmdletBinding()]
    param([int]$Top = 40)

    if (-not $global:GPerfTiming) { return }
    $rows = @($global:GPerfTotals.Values | Sort-Object -Property TotalMs -Descending)
    if ($rows.Count -eq 0) { return }

    $wall = if ($global:GLastExecutionTime) { $global:GLastExecutionTime.Elapsed.TotalMilliseconds } else { 0 }
    Write-Host ""
    Write-Host ("=== PERF SUMMARY (wall clock {0:N1} s) ===" -f ($wall / 1000.0)) -ForegroundColor Cyan
    Write-Host ("{0,12}  {1,7}  {2,6}  {3}" -f "total ms", "calls", "% wall", "step") -ForegroundColor Cyan
    foreach ($row in ($rows | Select-Object -First $Top)) {
        $percent = if ($wall -gt 0) { 100.0 * $row.TotalMs / $wall } else { 0 }
        Write-Host ("{0,12:N1}  {1,7}  {2,5:N1}%  {3}" -f $row.TotalMs, $row.Count, $percent, $row.Label)
    }
    Write-Host ""
}

# Marks a stage boundary - what is happening when, made explicit rather than inferred from prose.
# Always Info: a run's phase sequence is exactly the kind of thing that should survive -Quiet (which
# is the Warn threshold), matching today's tested behaviour where phase-flavoured lines like
# "Starting parallel processing..." are visible by default and suppressed under -Quiet.
function Write-MTAutoDrawPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Load', 'Ingest', 'Parse', 'Resolve', 'Draw', 'Export', 'Summary')][string]$Phase,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message
    )
    Write-MTAutoDrawLog -Level Info -Phase $Phase -Message $Message
}

# One diagnostic channel for capture readers. Thin wrapper over Write-MTAutoDrawLog: maps the
# reader-facing Severity vocabulary (Info|Warning|Error) onto the run-wide Level vocabulary and fixes
# Phase to Parse, since every existing call site is inside a parser reader. Vendor modules run inside
# ForEach-Object -Parallel, where Write-Host from a worker interleaves unattributably - unlike
# Write-MTAutoDrawLog's no-device branch, this tolerates (and requires, for the no-device case) being
# called from either thread, which is the case a parser hits when a required capture is missing and
# there is no device to log against yet.
function Write-MTAutoDrawDiagnostic {
    [CmdletBinding()]
    param(
        [AllowNull()]$Device,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Severity = 'Info'
    )

    if (-not $Device) {
        # No device to attach to, and possibly called from inside a worker - Warning stream rather
        # than Write-MTAutoDrawLog's immediate-print path, which is main-thread only. The worker
        # captures this via -WarningVariable and the parent replays it against the capture group.
        if ($Severity -ne 'Info') { Write-Warning $Message }
        return
    }

    $level = switch ($Severity) { 'Error' { 'Error' } 'Warning' { 'Warn' } default { 'Info' } }
    Write-MTAutoDrawLog -Level $level -Phase Parse -Device $Device -Message $Message
}
