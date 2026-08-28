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

# MTAutoDraw - Cross-subsystem helpers
#
# New-MTAutoDrawRunSummary depends on totals from parsing, resolution, drawing, exports, and timing,
# so it intentionally sits outside those focused modules. Do not use this file as a catch-all; place
# new helpers with the subsystem that owns their behavior.
#
# Depends on: nothing
# Loaded by:  AutoDraw.ps1 ($GLibrariesToLoad)

# Builds the summary object for a run: totals of devices, interfaces, neighbours, routes, evidence nodes/edges, and timing.
function New-MTAutoDrawRunSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][int]$TextFileCount,
        $CaptureGroups = @(),
        $Devices = @(),
        [string[]]$Artifacts = @(),
        [datetime]$StartedAtUtc = [DateTime]::UtcNow,
        $ProcessingErrors = @(),
        [AllowNull()][string]$FatalError
    )

    $groups = @($CaptureGroups)
    $processedDevices = @($Devices | Where-Object { $_ })
    $supportedGroups = @($groups | Where-Object DeviceType)
    $unsupportedGroups = @($groups | Where-Object { -not $_.DeviceType })
    $mappingDiagnostics = @($groups | ForEach-Object MappingDiagnostics)
    $mappingWarnings = @($mappingDiagnostics | Where-Object Severity -eq 'Warning')
    $parserLogs = @($processedDevices | ForEach-Object DebugLog)
    # Parser exceptions are returned structurally by Start-ProcessingFiles. Level is authoritative
    # diagnostic data; console colour is only a presentation derived from it. Custom or older parser
    # extensions can omit Level, so classify their BackgroundColor/Text fields only as a fallback.
    $parserErrors = @($parserLogs | Where-Object {
        if ($_.Level) { $_.Level -eq 'Error' } else { $_.Text -match '(?i)^(?:CRITICAL:|Unhandled parser exception:)' }
    })
    $parserWarnings = @($parserLogs | Where-Object {
        if ($_ -in $parserErrors) { return $false }
        if ($_.Level) { $_.Level -eq 'Warn' } else { $_.BackgroundColor -match '(?i)yellow|red|magenta' }
    })
    $lowConfidenceLinks = @($processedDevices | ForEach-Object LLDPNeighbors | Where-Object MatchConfidence -eq 'Low')
    $processingFailures = [Math]::Max(0, $supportedGroups.Count - $processedDevices.Count)

    $workerErrors = @($ProcessingErrors | Where-Object { $_ })

    if ($FatalError) {
        $verdict = 'Fail'; $exitCode = 2
    }
    elseif ($supportedGroups.Count -eq 0 -or $processedDevices.Count -eq 0 -or $processingFailures -gt 0 -or $workerErrors.Count -gt 0 -or $parserErrors.Count -gt 0) {
        $verdict = 'Fail'; $exitCode = 1
    }
    elseif ($unsupportedGroups.Count -gt 0 -or $mappingWarnings.Count -gt 0 -or $parserWarnings.Count -gt 0 -or $lowConfidenceLinks.Count -gt 0) {
        $verdict = 'Warn'; $exitCode = 0
    }
    else {
        $verdict = 'Pass'; $exitCode = 0
    }

    return [ordered]@{
        SchemaVersion = '1.0'
        # Which build produced this file. SchemaVersion above describes the shape of the summary and
        # moves only when that shape changes; this moves with every release.
        Version = $(if ($GMTAutoDrawVersion) { $GMTAutoDrawVersion } else { 'unknown' })
        Verdict = $verdict; ExitCode = $exitCode
        StartedAtUtc = $StartedAtUtc.ToUniversalTime().ToString('o')
        FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
        SourceDirectory = [System.IO.Path]::GetFullPath($SourceDirectory)
        Counts = [ordered]@{
            TextFiles = $TextFileCount; CaptureGroups = $groups.Count
            SupportedCaptureGroups = $supportedGroups.Count; UnsupportedCaptureGroups = $unsupportedGroups.Count
            ProcessedDevices = $processedDevices.Count; ProcessingFailures = $processingFailures
            MappingWarnings = $mappingWarnings.Count; ParserWarnings = $parserWarnings.Count; ParserErrors = $parserErrors.Count
            ProcessingErrors = $workerErrors.Count
            LowConfidenceLinks = $lowConfidenceLinks.Count
        }
        UnsupportedGroups = @($unsupportedGroups | Select-Object HOSTID,SourceDirectory,CaptureGroupKey)
        ProcessingErrors = @($workerErrors)
        Artifacts = @($Artifacts | Sort-Object -Unique)
        FatalError = $FatalError
    }
}
