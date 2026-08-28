# MTAutoDraw-Standard: v1
#
# TEMPLATE - copy to <Platform>ConfigProcessingFunctions.ps1 in the repository root and replace every
# occurrence of the token "MyPlatform". See PARSER_STANDARD.md, and read
# CiscoIOSXRConfigProcessingFunctions.ps1 as the worked reference.
#
# This file lives in Templates\ next to the .textfsm files but is never loaded at runtime -
# configurationVariables.ps1 only globs *.textfsm, and Test-ModuleLoading.ps1 loads by explicit name.
#
# Checklist once copied (PARSER_STANDARD.md section 7):
#   1. Add-CaptureDefinition lines in Get-ConfigCaptureDefinition for any unmapped commands
#   2. New capture slots on Create-FileObject in ObjectFunctions.ps1
#   3. A detection branch in Get-ConfigDeviceType - more specific platforms first
#   4. A dispatch branch in the switch in StartProcessingConfig.ps1 setting $processorName
#   5. This module added to Testing\Test-ModuleLoading.ps1
#   6. A corpus fixture plus an assertion in Testing\Test-SanitizedVendorCorpus.ps1

# --- Platform helpers -----------------------------------------------------------------------------

# Only needed when the platform's captures disagree about interface naming - for example one command
# printing "lag 1" and another "lag1". If they agree, call Resolve-MTAutoDrawInterface directly and
# delete this.
function Resolve-MyPlatformInterface {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $canonical = $Name.Trim() -replace '(?i)^(lag|vlan|loopback)\s+(\d+)$', '$1$2'
    return (Resolve-MTAutoDrawInterface -Device $Device -Name $canonical)
}

# --- Capture readers ------------------------------------------------------------------------------
# One per capture. Always -Device and -Path, always the four steps, always returns nothing, always
# safe to call with a $null path.

# Example: a TextFSM-backed reader.
function Update-MyPlatformInterfaces {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD --- never hand-roll a CLI-error regex; this is the only accepted guard.
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowInterface')) { return }

    # --- EXTRACT --- rows are objects keyed by the template's Value names, never indexed by position.
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'myvendor_myos_show_interfaces' -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    foreach ($row in $rows) {
        $interface = Resolve-MyPlatformInterface -Device $Device -Name $row.INTERFACE
        $interface.Description       = $row.DESCRIPTION
        $interface.IntStatus         = $row.LINK_STATUS
        $interface.INTProtocolStatus = $row.PROTOCOL_STATUS
        $interface.macaddress        = ConvertTo-NormalizedMacAddress $row.MAC_ADDRESS

        if ($row.IP_ADDRESS) {
            $addressInfo = Get-NormalizedIPv4Cidr -IPAddress $row.IP_ADDRESS -PrefixLength $row.PREFIX_LENGTH
            if ($addressInfo) {
                $interface.IPAddress      = $addressInfo.IPAddress
                $interface.SubnetMask     = $addressInfo.PrefixLength
                $interface.Cidr           = $addressInfo.Cidr
                $interface.SwitchPortType = 'Routed'
                $null = Add-MTAutoDrawNetwork -Device $Device -Cidr $addressInfo.Cidr `
                    -RoutedVlan $interface.RoutedVlan -IPAddress $addressInfo.IPAddress
            }
        }
    }
}

# Example: a regex-backed reader, for platforms with no usable ntc-template.
function Update-MyPlatformVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowVersion')) { return }

    # --- EXTRACT ---
    $text = Get-MTAutoDrawCaptureText -Path $Path

    # --- MAP --- named capture groups, never $Matches[1] positional soup.
    $version = Create-ShowVersionObject
    $version.Type = 'MyPlatform'
    if ($text -match '(?im)^\s*Version\s*:\s*(?<os>\S+)')        { $version.OS       = $Matches['os'] }
    if ($text -match '(?im)^\s*Hostname\s*:\s*(?<host>\S+)')     { $version.Hostname = $Matches['host'] }
    if ($text -match '(?im)^\s*Serial\s*:\s*(?<serial>\S+)')     { $version.Serial   = @($Matches['serial']) }

    # --- MERGE ---
    $Device.Version = $version
    if (-not $Device.hostname) { $Device.hostname = $version.Hostname }
}

# --- Orchestrator ---------------------------------------------------------------------------------

function Process-MyPlatformHostFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$HostID,
        $ArrayOfObjects   # Kept for dispatcher signature compatibility; duplicate detection is sequential.
    )

    # 1. IDENTITY - reject here and only here. A device with no name cannot be drawn or linked.
    $device = New-MTAutoDrawDevice -Platform 'MyPlatform' -HostID $HostID
    Update-MyPlatformVersion -Device $device -Path $HostID.ShowVersion
    if (-not $device.hostname) {
        Write-MTAutoDrawDiagnostic -Device $device -Severity Error `
            -Message "MyPlatform '$($HostID.HOSTID)' has no usable hostname; skipping."
        return $null
    }

    # 2. CAPTURES - one line per slot, in dependency order. No if-wrappers: a reader handed a $null
    #    path returns immediately, which is what keeps this readable as a list.
    Update-MyPlatformInterfaces -Device $device -Path $HostID.ShowInterface

    # 3. RECONCILE - sorts, dedupes, and back-fills egress interfaces onto connected routes.
    return (Complete-MTAutoDrawDevice -Device $device)
}
