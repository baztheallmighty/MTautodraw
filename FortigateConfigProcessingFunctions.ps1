# MTAudotDraw - FortiGate Module Stub
# Copyright (C) 2022 Myles Treadwell

function Process-FortiGateHostFiles {
    param (
        [parameter(Mandatory=$true)]
        $hostid,
        $ArrayOfObjects
    )

    $Device = Create-HostObject
    $Device.DeviceType = "FortiGate"
    $Device.Origin = "File"
    
    # Initialize arrays to hold networks and IPs (Matched to Cisco Logic)
    $Device.ArrayOfNetworks = @()
    $Device.ArrayOfIPAddresses = @()

    Add-HostDebugText -HostObject $Device "DEBUG: [Process-FortiGateHostFiles] Starting for HostID: $($hostid.HOSTID)"

    # ----------------------------------------------------------------------------------
    # 1. Hostname Extraction
    # ----------------------------------------------------------------------------------
    $HostnameFound = $false

    # Check ShowFullConfig
    if ($hostid.ShowFullConfig -and (Test-Path -Path $hostid.ShowFullConfig)) {
        $ConfigContent = Get-Content -Path $hostid.ShowFullConfig -Raw
        if ($ConfigContent -match '(?m)^\s*set hostname\s+"?([^"\r\n]+)"?') {
            $Device.hostname = $Matches[1].Trim()
            $HostnameFound = $true
        }
        $Device.DeviceIdentifier = ($hostid.ShowFullConfig -replace "\.show full-configuration.*", '' -replace "^.*\\", '')
    }

    # Check SystemStatus if needed
    if (-not $HostnameFound -and $hostid.SystemStatus -and (Test-Path -Path $hostid.SystemStatus)) {
        $StatusContent = Get-Content -Path $hostid.SystemStatus -Raw
        if ($StatusContent -match '(?m)^Hostname:\s+(\S+)') {
            $Device.hostname = $Matches[1].Trim()
        }
        if (-not $Device.DeviceIdentifier) {
            $Device.DeviceIdentifier = ($hostid.SystemStatus -replace "\.get system status.*", '' -replace "^.*\\", '')
        }
    }

    if ($null -eq $Device.hostname -or [string]::IsNullOrEmpty($Device.hostname)) {
        Write-Host "Can't find hostname in files for hostid '$($hostid.HOSTID)'" -BackgroundColor Red
        return $null
    }

    # ----------------------------------------------------------------------------------
    # 2. Duplicate Check
    # ----------------------------------------------------------------------------------
    foreach ($ExistingDevice in $ArrayOfObjects) {
        if ($ExistingDevice.hostname -eq $Device.hostname) {
            Write-Host "Hostname already exists $($ExistingDevice.hostname)" -BackgroundColor Red
            if (!($SkipHostnameErrorCheck)) { Start-CleanupAndExit }
        }
    }

    # ----------------------------------------------------------------------------------
    # 3. Process Version
    # ----------------------------------------------------------------------------------
    Add-HostDebugText -HostObject $Device "Processing show FortiGateVersionFromText:$($hostid.SystemStatus)"
    $Device = Get-FortiGateVersionFromText -Device $Device -SystemStatusFile $hostid.SystemStatus -HaStatusFile $hostid.HaStatus -FullConfigFile $hostid.ShowFullConfig
    
    # ----------------------------------------------------------------------------------
    # 4. Process Interfaces 
    # ----------------------------------------------------------------------------------
    
    Add-HostDebugText -HostObject $Device "Processing show ShowFullConfig SystemInterface:$($hostid.SystemInterface)"
    $Device = Get-FortiGateInterfacesFromConfigText -Device $Device -FullConfigFile $hostid.ShowFullConfig 
    
    # ----------------------------------------------------------------------------------
    # 5. extended Process Interfaces 
    # ----------------------------------------------------------------------------------
    
    if ($hostid.SystemInterface) {
        Add-HostDebugText -HostObject $Device "Processing show SystemInterface:$($hostid.SystemInterface)"
        $Device = Get-FortiGateSystemInterfaceFromText -Device $Device -SystemInterfaceFile $hostid.SystemInterface
    }

    # ----------------------------------------------------------------------------------
    # 6. Process Routing Table
    # ----------------------------------------------------------------------------------
    if ($hostid.ShowRoutingTable) {
        Add-HostDebugText -HostObject $Device "Processing show FortiGateRouteFromText:$($hostid.ShowRoutingTable)"
        $Device = Get-FortiGateRouteFromText -Device $Device -ShowRoutingTableFile $hostid.ShowRoutingTable
    }
    # ----------------------------------------------------------------------------------
    # 7. Process ARP Table
    # ----------------------------------------------------------------------------------
    if ($hostid.ShowArp) {
        if ($GDrawAprEntries) {
            Add-HostDebugText -HostObject $Device "Processing get arp:$($hostid.ShowArp)"
            $Device = Get-FortiGateArpFromText -Device $Device -ShowArpFile $hostid.ShowArp
        }
    }
    return $Device
}
function Get-FortiGateInterfacesFromConfigText {
    param (
        [Parameter(Mandatory=$true)]
        $Device,
        [Parameter(Mandatory=$true)]
        [string]$FullConfigFile
    )

    Add-HostDebugText -HostObject $Device "DEBUG: ===== ENTER Get-FortiGateInterfacesFromConfigText ====="
    Add-HostDebugText -HostObject $Device "DEBUG: FullConfigFile path: $FullConfigFile"

    if (-not (Test-Path -Path $FullConfigFile)) {
        Add-HostDebugText -HostObject $Device "DEBUG: File not found."
        return $Device
    }

    $ConfigText = Get-Content -Path $FullConfigFile -Raw
    Add-HostDebugText -HostObject $Device "DEBUG: Config length: $($ConfigText.Length)"

    # ----------------------------------------------------------
    # Extract config system interface block safely (nested aware)
    # ----------------------------------------------------------

    $Lines = $ConfigText -split "`r?`n"
    $InterfaceLines = @()
    $InSection = $false
    $Depth = 0

    foreach ($Line in $Lines) {

        if ($Line -match '^\s*config system interface') {
            Add-HostDebugText -HostObject $Device "DEBUG: Found start of config system interface block."
            $InSection = $true
            $Depth = 1
            continue
        }

        if ($InSection) {

            if ($Line -match '^\s*config ') {
                $Depth++
            }

            if ($Line -match '^\s*end\s*$') {
                $Depth--
                if ($Depth -eq 0) {
                    Add-HostDebugText -HostObject $Device "DEBUG: Reached end of config system interface block."
                    break
                }
            }

            $InterfaceLines += $Line
        }
    }

    if (-not $InterfaceLines.Count) {
        Add-HostDebugText -HostObject $Device "DEBUG: No interface section extracted."
        return $Device
    }

    $InterfaceSection = $InterfaceLines -join "`n"
    Add-HostDebugText -HostObject $Device "DEBUG: InterfaceSection length: $($InterfaceSection.Length)"

    # ----------------------------------------------------------
    # Split interfaces by edit statements
    # ----------------------------------------------------------

    $RawInterfaces = $InterfaceSection -split '(?m)^\s*edit\s+' | Where-Object { $_ -match '\S' }

    Add-HostDebugText -HostObject $Device "DEBUG: RawInterfaces count: $($RawInterfaces.Count)"
    Add-HostDebugText -HostObject $Device "DEBUG: Device.interfaces count BEFORE processing: $($Device.interfaces.Count)"

    foreach ($Block in $RawInterfaces) {

        Add-HostDebugText -HostObject $Device "DEBUG: ----- NEW INTERFACE BLOCK -----"
        Add-HostDebugText -HostObject $Device "DEBUG: Block preview: $($Block.Substring(0, [Math]::Min(200, $Block.Length)))"

        $InterfaceObj = Create-InterfaceObject

        # --------------------------
        # Interface Name
        # --------------------------
        if ($Block -match '^"?(?<name>[^"\s]+)"?') {
            $InterfaceObj.Interface = $Matches['name']
            Add-HostDebugText -HostObject $Device "DEBUG: Interface name: $($InterfaceObj.Interface)"
        } else {
            Add-HostDebugText -HostObject $Device "DEBUG: Could not extract interface name."
            continue
        }

        # --------------------------
        # VRF
        # --------------------------
        if ($Block -match '(?m)^\s*set vrf\s+(?<vrf>\d+)') {
            $InterfaceObj.vrf = $Matches['vrf']
            Add-HostDebugText -HostObject $Device "DEBUG: VRF found: $($InterfaceObj.vrf)"
        } else {
            Add-HostDebugText -HostObject $Device "DEBUG: No VRF found (default assumed)."
        }

        # --------------------------
        # VDOM
        # --------------------------
        if ($Block -match '(?m)^\s*set vdom\s+"?(?<vdom>[^"\r\n]+)"?') {
            $InterfaceObj.VDOM = $Matches['vdom']
            Add-HostDebugText -HostObject $Device "DEBUG: VDOM: $($InterfaceObj.VDOM)"
        }

        # --------------------------
        # Mode
        # --------------------------
        if ($Block -match '(?m)^\s*set mode\s+(?<mode>\w+)') {
            $InterfaceObj.Mode = $Matches['mode']
            Add-HostDebugText -HostObject $Device "DEBUG: Mode: $($InterfaceObj.Mode)"
        }

        # --------------------------
        # IP Address
        # --------------------------
        if ($Block -match '(?m)^\s*set ip\s+(?<ip>\d{1,3}(\.\d{1,3}){3})\s+(?<mask>\d{1,3}(\.\d{1,3}){3})') {

            $ip   = $Matches['ip']
            $mask = $Matches['mask']

            if ($ip -eq "0.0.0.0" -and $mask -eq "0.0.0.0") {

                Add-HostDebugText -HostObject $Device "DEBUG: Interface has no IP configured. Clearing values."

                $InterfaceObj.IPAddress = $null
                $InterfaceObj.SubnetMask = $null
                $InterfaceObj.Cidr = $null
            }
            else {

                $InterfaceObj.IPAddress = $ip
                $InterfaceObj.SubnetMask = $mask

                Add-HostDebugText -HostObject $Device "DEBUG: IP: $ip Mask: $mask"

                $SubnetInfo = Get-IPv4Subnet -IPAddress $ip -SubnetMask $mask
                $InterfaceObj.Cidr = $SubnetInfo.CIDRId

                Add-HostDebugText -HostObject $Device "DEBUG: Calculated CIDR: $($InterfaceObj.Cidr)"

                if ($mask -like "*.*") {
                    $InterfaceObj.SubnetMask = Covert-NetMaskToCIDR -SubnetMask $mask
                }

                if ($Device.ArrayOfIPAddresses -notcontains $ip) {
                    $Device.ArrayOfIPAddresses += $ip
                }
            }
        }


        # --------------------------
        # Status
        # --------------------------
        if ($Block -match '(?m)^\s*set status\s+down') {
            $InterfaceObj.shutdown = $true
            $InterfaceObj.IntStatus = "down"
        } else {
            $InterfaceObj.shutdown = $false
            $InterfaceObj.IntStatus = "up"
        }

        

        $Device.interfaces += $InterfaceObj

        Add-HostDebugText -HostObject $Device "DEBUG: Interface added to device."
    }

    Add-HostDebugText -HostObject $Device "DEBUG: Device.interfaces count AFTER processing: $($Device.interfaces.Count)"
    Add-HostDebugText -HostObject $Device "DEBUG: ===== EXIT Get-FortiGateInterfacesFromConfigText ====="

    return $Device
}


function Get-FortiGateSystemInterfaceFromText {
    param (
        [parameter(Mandatory=$true)]
        $Device,
        [parameter(Mandatory=$true)]
        $SystemInterfaceFile
    )

    Add-HostDebugText -HostObject $Device "DEBUG: ===== ENTER Get-FortiGateSystemInterfaceFromText ====="
    Add-HostDebugText -HostObject $Device "DEBUG: SystemInterfaceFile path: $SystemInterfaceFile"
    Add-HostDebugText -HostObject $Device "DEBUG: Device.interfaces count BEFORE TextFSM: $($Device.interfaces.Count)"

    if (-not (Test-Path $SystemInterfaceFile)) {
        Add-HostDebugText -HostObject $Device "DEBUG: SystemInterface file not found."
        return $Device
    }

    $SystemInterfaceText = Get-Content -Raw $SystemInterfaceFile
    Add-HostDebugText -HostObject $Device "DEBUG: SystemInterfaceText length: $($SystemInterfaceText.Length)"

    $Device = Execute-PythonTextFSM `
        -TextFSTETemplate $GTextFSMTemplates['fortinet_get_system_interface'] `
        -ShowFile $SystemInterfaceFile `
        -ReturnArray $true `
        -HostObject $Device

    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "DEBUG: TextFSM returned ERROR."
        return $Device
    }

    Add-HostDebugText -HostObject $Device "DEBUG: TextFSM rows returned: $($Device.ProcessOutputObjects.Count)"

    $UpdateOnly = $false

    foreach ($int in $Device.ProcessOutputObjects) {

        Add-HostDebugText -HostObject $Device "DEBUG: ---- Processing TextFSM row ----"
        Add-HostDebugText -HostObject $Device "DEBUG: Row content: $($int -join ' | ')"

        $Interface = $Device.interfaces | Where-Object { $_.interface -eq $int[0] }

        if ($Interface) {

            Add-HostDebugText -HostObject $Device "DEBUG: Found existing interface: $($int[0])"
            $UpdateOnly = $true
            Add-HostDebugText -HostObject $Device "DEBUG: UpdateOnly set to TRUE"

            $Interface.IntStatus = $int[6]
        }
        else {

            Add-HostDebugText -HostObject $Device "DEBUG: Interface NOT found in show run: $($int[0])"

            if ($UpdateOnly) {
                Add-HostDebugText -HostObject $Device "DEBUG: Skipping creation because UpdateOnly is TRUE"
                continue
            }

            Add-HostDebugText -HostObject $Device "DEBUG: Creating new interface: $($int[0])"

            $Interface = Create-InterfaceObject
            $Interface.Interface = $int[0]

            $Device.interfaces += $Interface
        }
    }

    Add-HostDebugText -HostObject $Device "DEBUG: Device.interfaces count AFTER processing: $($Device.interfaces.Count)"
    Add-HostDebugText -HostObject $Device "DEBUG: ===== EXIT Get-FortiGateSystemInterfaceFromText ====="

    return $Device
}

#function Get-FortiGateSystemInterfaceFromText {
#    param (
#        [parameter(Mandatory=$true)]
#        $Device,
#        [parameter(Mandatory=$true)]
#        $SystemInterfaceFile
#    )
#
#    # Read the file into one big string
#    $SystemInterfaceText = Get-Content -Raw $SystemInterfaceFile
#    [array]$AllInterfaces = @() # Array of interfaces to hand back to the host object.
#
#    # Basic validation of file content
#    if ([string]::IsNullOrWhiteSpace($SystemInterfaceText)) {
#        Add-HostDebugText -HostObject $Device "System Interface file is empty." -BackgroundColor red
#        return $Device
#    }
#
#    # Start Python process with TextFSM to convert the Text to an Object
#    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['fortinet_get_system_interface'] -ShowFile $SystemInterfaceFile -ReturnArray $true -HostObject $Device
#
#    if ($Device.ProcessOutputObjects -eq "ERROR") {
#        Add-HostDebugText -HostObject $Device "Error with show system interface TextFSM processing." -BackgroundColor red
#        return $Device
#    }
#
#    # Normalize single results into an array if necessary
#    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
#        $tempArray = @()
#        $tempArray += ,$Device.ProcessOutputObjects
#        $Device.ProcessOutputObjects = $tempArray
#    }
#
#    $UpdateOnly = $false 
#
#    foreach ($int in $Device.ProcessOutputObjects) {
#        # TextFSM Index Mapping: [0]NAME [1]MODE [4]IP [5]MASK [6]STATUS [8]TYPE
#
#        $Interface = $Device.interfaces | Where-Object { $_.interface -eq $int[0] }
#
#        if ($Interface) { 
#            # --- UPDATE EXISTING INTERFACE ---
#            $UpdateOnly = $true
#            
#            # Update Status
#            $Interface.IntStatus = $int[6]
#            if ($Interface.IntStatus -eq "down") {
#                $Interface.shutdown = $true
#            } else {
#                $Interface.shutdown = $false
#            }
#
#            # Update Type if missing
#            if (-not $Interface.SwitchPortType -or $Interface.SwitchPortType -eq "physical") {
#                $Interface.SwitchPortType = $int[8]
#            }
#
#            # Update IP if found in TextFSM and valid
#            if ($int[4] -ne "" -and $int[4] -ne "0.0.0.0") {
#                $Interface.IPAddress = $int[4]
#                $Interface.SubnetMask = $int[5]
#                
#                # Update CIDR
#                if ($Interface.IPAddress -and $Interface.SubnetMask) {
#                     $Interface.Cidr = (Get-IPv4Subnet -IPAddress $Interface.IPAddress -SubnetMask $Interface.SubnetMask).cidrid
#                     
#                     # Convert SubnetMask property to /xx format
#                     if($Interface.SubnetMask -like "*.*"){ 
#                        $Interface.SubnetMask = Covert-NetMaskToCIDR -SubnetMask $Interface.SubnetMask
#                     }
#                }
#
#                # Update Device Global IP List
#                if ($Device.ArrayOfIPAddresses -notcontains $Interface.IPAddress) {
#                    $Device.ArrayOfIPAddresses += $Interface.IPAddress
#                }
#                
#                # Check/Add Network Object
#                if ($Interface.Cidr) {
#                     $ExistingNetwork = $Device.ArrayOfNetworks | Where-Object { $_.Cidr -eq $Interface.Cidr }
#                     if (-not $ExistingNetwork) {
#                        try {
#                            $NetworkObject = Create-NetworkObject
#                            $NetworkObject.Cidr = $Interface.Cidr
#                            $NetworkObject.Routedvlan = if ($Interface.RoutedVlan) { $Interface.RoutedVlan } else { "no vlan" }
#                            $Device.ArrayOfNetworks += $NetworkObject
#                        } catch {
#                            # Ignore creation errors
#                        }
#                     }
#                }
#            }
#
#            $AllInterfaces += $Interface
#
#        } else {
#            # --- CREATE NEW INTERFACE ---
#            if ($UpdateOnly) { 
#                Add-HostDebugText -HostObject $Device "Tried to create an interface we can't find in show run skipping: $($int[0])"
#                continue
#            }
#
#            Add-HostDebugText -HostObject $Device "Creating Interface from SystemInterface: $($int[0])"
#            $Interface = Create-InterfaceObject
#            $Interface.Interface = $int[0]
#            
#            # Status
#            $Interface.IntStatus = $int[6]
#            if ($Interface.IntStatus -eq "down") {
#                $Interface.shutdown = $true
#            } else {
#                $Interface.shutdown = $false
#            }
#
#            # Type
#            $Interface.SwitchPortType = $int[8]
#            
#            # Physical ID for drawing
#            $Interface.PhysicalDrawioId = "$($Device.hostname)_$($int[0])"
#
#            # IP Address
#            if ($int[4] -ne "" -and $int[4] -ne "0.0.0.0") {
#                $Interface.IPAddress = $int[4]
#                $Interface.SubnetMask = $int[5]
#                
#                if ($Interface.IPAddress -and $Interface.SubnetMask) {
#                    $Interface.Cidr = (Get-IPv4Subnet -IPAddress $Interface.IPAddress -SubnetMask $Interface.SubnetMask).cidrid
#
#                    # Convert SubnetMask property to /xx format
#                    if($Interface.SubnetMask -like "*.*"){ 
#                       $Interface.SubnetMask = Covert-NetMaskToCIDR -SubnetMask $Interface.SubnetMask
#                    }
#                    
#                    # Update Device Global IP List
#                    if ($Device.ArrayOfIPAddresses -notcontains $Interface.IPAddress) {
#                        $Device.ArrayOfIPAddresses += $Interface.IPAddress
#                    }
#
#                    # Create Network Object
#                    try {
#                        $NetworkObject = Create-NetworkObject
#                        $NetworkObject.Cidr = $Interface.Cidr
#                        $NetworkObject.Routedvlan = "no vlan" 
#                        $Device.ArrayOfNetworks += $NetworkObject
#                    } catch {
#                        # Ignore
#                    }
#                }
#            }
#            $AllInterfaces += $Interface
#        }
#    }
#
#    if ($UpdateOnly) {
#        return $Device
#    } else {
#        $Device.interfaces = $AllInterfaces
#        return $Device
#    }
#}
#

#function Get-FortiGateInterfacesFromConfigText {
#    param (
#        [Parameter(Mandatory=$true)]
#        $Device,
#        [Parameter(Mandatory=$true)]
#        [string]$FullConfigFile
#    )
#
#    if (-not (Test-Path -Path $FullConfigFile)) {
#        return $Device
#    }
#
#    $ConfigText = Get-Content -Path $FullConfigFile -Raw
#
#    # 1. Isolate the "config system interface" block
#    if ($ConfigText -match '(?ms)^\s*config system interface\s*(?<content>.*?)^\s*end\s*$') {
#        $InterfaceSection = $Matches['content']
#    } else {
#        return $Device
#    }
#
#
#
#    # 2. Split the section into individual interface blocks
#    $RawInterfaces = $InterfaceSection -split '(?m)^\s*edit\s+' | Where-Object { $_ -match '\S' }
#
#    foreach ($Block in $RawInterfaces) {
#        $InterfaceObj = Create-InterfaceObject
#
#        # --- Extract Interface Name ---
#        if ($Block -match '(?m)^\s*"?(?<name>[^"\r\n"\s]+)"?\s*$') {
#            $InterfaceObj.Interface = $Matches['name']
#        }
#
#        # --- Extract Standard Properties ---
#        if ($Block -match '(?m)^\s*set vrf\s+(?<vrf>\d+)') {
#            $InterfaceObj.vrf = $Matches['vrf']
#        }
#
#        # --- Extract FortiGate Specific Properties ---
#        
#        # VDOM
#        if ($Block -match '(?m)^\s*set vdom\s+"?(?<vdom>[^"\r\n]+)"?') {
#            $InterfaceObj.VDOM = $Matches['vdom'].Trim('"')
#        }
#
#        # Mode
#        if ($Block -match '(?m)^\s*set mode\s+(?<mode>\w+)') {
#            $InterfaceObj.Mode = $Matches['mode']
#        }
#
#        # Allow Access
#        if ($Block -match '(?m)^\s*set allowaccess\s+(?<access>.*)') {
#            $InterfaceObj.AllowAccess = $Matches['access'].Trim()
#        }
#
#        # Role
#        if ($Block -match '(?m)^\s*set role\s+(?<role>\w+)') {
#            $InterfaceObj.Role = $Matches['role']
#        }
#
#        # Alias
#        if ($Block -match '(?m)^\s*set alias\s+(?<alias>.+)') {
#            $InterfaceObj.Alias = $Matches['alias'].Trim().Trim("'").Trim('"')
#        }
#
#        # FortiLink
#        if ($Block -match '(?m)^\s*set fortilink\s+(?<fl>\w+)') {
#            $InterfaceObj.FortiLink = $Matches['fl']
#        }
#
#        # Security Mode
#        if ($Block -match '(?m)^\s*set security-mode\s+(?<sm>\w+)') {
#            $InterfaceObj.SecurityMode = $Matches['sm']
#        }
#
#        # Device Identification
#        if ($Block -match '(?m)^\s*set device-identification\s+(?<di>\w+)') {
#            $InterfaceObj.DeviceIdentification = $Matches['di']
#        }
#
#        # LLDP Settings
#        if ($Block -match '(?m)^\s*set lldp-transmission\s+(?<lt>\w+)') {
#            $InterfaceObj.LLDPTransmission = $Matches['lt']
#        }
#        if ($Block -match '(?m)^\s*set lldp-reception\s+(?<lr>\w+)') {
#            $InterfaceObj.LLDPReception = $Matches['lr']
#        }
#
#        # SNMP Index
#        if ($Block -match '(?m)^\s*set snmp-index\s+(?<idx>\d+)') {
#            $InterfaceObj.SNMPIndex = $Matches['idx']
#        }
#
#        # Bandwidth Settings
#        if ($Block -match '(?m)^\s*set estimated-upstream-bandwidth\s+(?<bw>\d+)') {
#            $InterfaceObj.EstimatedUpstreamBandwidth = $Matches['bw']
#        }
#        if ($Block -match '(?m)^\s*set estimated-downstream-bandwidth\s+(?<bw>\d+)') {
#            $InterfaceObj.EstimatedDownstreamBandwidth = $Matches['bw']
#        }
#        if ($Block -match '(?m)^\s*set monitor-bandwidth\s+(?<mb>\w+)') {
#            $InterfaceObj.MonitorBandwidth = $Matches['mb']
#        }
#
#        # MTU Override
#        if ($Block -match '(?m)^\s*set mtu-override\s+(?<mtu>\w+)') {
#            $InterfaceObj.MTUOverride = $Matches['mtu']
#        }
#
#        # Speed (Standard Property)
#        if ($Block -match '(?m)^\s*set speed\s+(?<speed>\S+)') {
#            $InterfaceObj.Speed = $Matches['speed']
#        }
#
#        # --- Extract Description ---
#        $Desc = $null
#        if ($Block -match '(?m)^\s*set description\s+(?<desc>.+)') {
#            $Desc = $Matches['desc'].Trim().Trim("'").Trim('"')
#        }
#        
#        # Fallback: If Description is empty, use Alias if it exists
#        if ([string]::IsNullOrWhiteSpace($Desc) -and $InterfaceObj.Alias) {
#            $Desc = $InterfaceObj.Alias
#        }
#        $InterfaceObj.Description = $Desc
#
#        # --- Extract Shutdown Status ---
#        if ($Block -match '(?m)^\s*set status\s+down') {
#            $InterfaceObj.shutdown = $true
#            $InterfaceObj.IntStatus = "down"
#        } elseif ($Block -match '(?m)^\s*set status\s+up') {
#            $InterfaceObj.shutdown = $false
#            $InterfaceObj.IntStatus = "up"
#        } else {
#            $InterfaceObj.shutdown = $false
#            $InterfaceObj.IntStatus = "up" # Default
#        }
#
#        # --- Extract Interface Type ---
#        if ($Block -match '(?m)^\s*set type\s+(?<type>\w+)') {
#            $Type = $Matches['type']
#            if ($Type -eq 'physical') {
#                $InterfaceObj.SwitchPortType = 'Physical'
#            } elseif ($Type -eq 'tunnel') {
#                $InterfaceObj.SwitchPortType = 'Tunnel'
#            } elseif ($Type -eq 'vlan') {
#                $InterfaceObj.SwitchPortType = 'Vlan'
#                if ($Block -match '(?m)^\s*set vlanid\s+(?<vlanid>\d+)') {
#                    $InterfaceObj.RoutedVlan = $Matches['vlanid']
#                }
#            } elseif ($Type -eq 'aggregate') {
#                $InterfaceObj.SwitchPortType = 'Port-Channel'
#                $InterfaceObj.ChannelGroup = $InterfaceObj.Interface
#                $InterfaceObj.ChannelGroupMode = "on" # FortiGate aggregate is typically LACP or static, treating as 'on'/active
#            } elseif ($Type -eq 'loopback') {
#                $InterfaceObj.SwitchPortType = 'Loopback'
#            } else {
#                $InterfaceObj.SwitchPortType = $Type
#            }
#        }
#
#        # --- Extract IP Address and Subnet Mask ---
#        if ($Block -match '(?m)^\s*set ip\s+(?<ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+(?<mask>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})') {
#            $InterfaceObj.IPAddress = $Matches['ip']
#            $InterfaceObj.SubnetMask = $Matches['mask']
#
#            # Calculate CIDR if we have valid data
#            if ($InterfaceObj.IPAddress -ne '0.0.0.0' -and $InterfaceObj.SubnetMask -ne '0.0.0.0') {
#                
#                # 1. Get CIDR ID
#                $SubnetInfo = Get-IPv4Subnet -IPAddress $InterfaceObj.IPAddress -SubnetMask $InterfaceObj.SubnetMask
#                $InterfaceObj.Cidr = $SubnetInfo.cidrid
#
#                # 2. Convert SubnetMask property to /xx format
#                if($InterfaceObj.SubnetMask -like "*.*"){ 
#                    $InterfaceObj.SubnetMask = Covert-NetMaskToCIDR -SubnetMask $InterfaceObj.SubnetMask
#                }
#
#                # 3. Add to Device IP List
#                if ($Device.ArrayOfIPAddresses -notcontains $InterfaceObj.IPAddress) {
#                    $Device.ArrayOfIPAddresses += $InterfaceObj.IPAddress
#                }
#
#                # 4. Create Network Object
#                try {
#                    $NetworkObject = Create-NetworkObject 
#                    $NetworkObject.Cidr = $InterfaceObj.Cidr
#                    if ($InterfaceObj.RoutedVlan) {
#                        $NetworkObject.Routedvlan = $InterfaceObj.RoutedVlan
#                    } else {
#                        $NetworkObject.Routedvlan = "no vlan"
#                    }
#                    $Device.ArrayOfNetworks += $NetworkObject
#                } catch {
#                    Write-Debug "Could not create NetworkObject: $_"
#                }
#            }
#        }
#
#        # --- Extract Secondary IP ---
#        if ($Block -match '(?ms)config secondaryip(?<sec_block>.*?)end') {
#            $SecBlock = $Matches['sec_block']
#            if ($SecBlock -match 'set ip\s+(?<ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+(?<mask>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})') {
#                $InterfaceObj.SecondaryIPAddress = $Matches['ip']
#                $InterfaceObj.SecondarySubnetMask = $Matches['mask']
#                
#                $SubnetInfoSec = Get-IPv4Subnet -IPAddress $InterfaceObj.SecondaryIPAddress -SubnetMask $InterfaceObj.SecondarySubnetMask
#                $InterfaceObj.SecondaryCidr = $SubnetInfoSec.cidrid
#
#                # Convert Secondary SubnetMask
#                if($InterfaceObj.SecondarySubnetMask -like "*.*"){ 
#                    $InterfaceObj.SecondarySubnetMask = Covert-NetMaskToCIDR -SubnetMask $InterfaceObj.SecondarySubnetMask
#                }
#
#                if ($Device.ArrayOfIPAddresses -notcontains $InterfaceObj.SecondaryIPAddress) {
#                    $Device.ArrayOfIPAddresses += $InterfaceObj.SecondaryIPAddress
#                }
#            }
#        }
#
#        $InterfaceObj.PhysicalDrawioId = "$($Device.hostname)_$($InterfaceObj.Interface)"
#        $Device.interfaces += $InterfaceObj
#    }
#
#    # --- Post-Processing: Color Assignment ---
#    $LastVRFInterface = $null
#    foreach ($VRFInterface in ($Device.interfaces | Where-Object { $_.vrf } | Sort-Object vrf)) {
#        if ($null -eq $LastVRFInterface -or $VRFInterface.vrf -ne $LastVRFInterface.vrf) {
#            $Color = "$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0)"
#        }
#        $VRFInterface.VRFColor = $Color
#        $LastVRFInterface = $VRFInterface
#    }
#
#    return $Device
#}
#

function Get-FortiGateRouteFromText {
    param (
        [parameter(Mandatory=$true)]
        $ShowRoutingTableFile,
        $Device
    )

    # 1. Validation
    if (-not $ShowRoutingTableFile -or -not (Test-Path $ShowRoutingTableFile)) {
        return $Device
    }

    $RouteText = Get-Content -Raw $ShowRoutingTableFile
    if (($RouteText | Select-String "(Command parse error|Unknown command|Invalid input detected)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "Routing table file contains invalid data: $ShowRoutingTableFile" -BackgroundColor Red
        return $Device
    }

    # 2. Execute TextFSM
    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['fortinet_get_router_info_routing-table_all'] -ShowFile $ShowRoutingTableFile -ReturnArray $true -HostObject $Device

    if ($Device.ProcessOutputObjects -eq "ERROR" -or $null -eq $Device.ProcessOutputObjects) {
        Add-HostDebugText -HostObject $Device "TextFSM returned ERROR or NULL for routing table." -BackgroundColor Red
        return $Device
    }

    # 3. Cache Optimization
    $ActiveInterfaces = $Device.interfaces | Where-Object { $_.cidr -and $_.IntStatus -ne "down" }
    $lastGateway = $null
    $lastInterface = $null

    # 4. Process Rows
    # NEW TextFSM Columns (VRF is now index 0):
    # [0]VRF [1]TYPE [2]DESTINATION [3]DISTANCE [4]METRIC [5]GATEWAY [6]INTERFACE [7]LAST_TIME_UPDATE
    
    $AllRouteObjects = foreach ($Row in $Device.ProcessOutputObjects) {
        $RouteObject = Create-RouteObject
        
        $Vrf         = $Row[0]
        $RawType     = $Row[1]
        $Destination = $Row[2]
        $Distance    = $Row[3]
        $Metric      = $Row[4]
        $Gateway     = $Row[5]
        $Interface   = $Row[6]

        # --- Assign VRF ---
        $RouteObject.VRF = $Vrf

        # --- Protocol Mapping ---
        switch -Regex ($RawType) {
            "^C"   { $RouteObject.RouteProtocol = "connected" }
            "^S"   { $RouteObject.RouteProtocol = "static" }
            "^R"   { $RouteObject.RouteProtocol = "RIP" }
            "^B"   { $RouteObject.RouteProtocol = "BGP" }
            "^O"   { $RouteObject.RouteProtocol = "OSPF" }
            "^i"   { $RouteObject.RouteProtocol = "IS-IS" }
            default { $RouteObject.RouteProtocol = $RawType } 
        }

        if ($RawType.Length -gt 1) {
            $RouteObject.RouteSubType = $RawType
        }

        $RouteObject.Subnet   = $Destination
        $RouteObject.DISTANCE = $Distance
        $RouteObject.METRIC   = $Metric

        # --- Gateway Logic ---
        if ($Gateway -match "is directly connected") {
            $RouteObject.gateway = "0.0.0.0"
        } else {
            $RouteObject.gateway = $Gateway
        }

        # --- Interface Lookup Logic ---
        if (-not [string]::IsNullOrWhiteSpace($Interface)) {
            $RouteObject.Interface = $Interface
        } elseif ($RouteObject.gateway -and $RouteObject.gateway -ne "0.0.0.0") {
            if ($RouteObject.gateway -eq $lastGateway) {
                $RouteObject.Interface = $lastInterface
            } else {
                $found = $false
                foreach ($IntObj in $ActiveInterfaces) {
                    if ((Find-Subnet -addr1 $IntObj.cidr -addr2 $RouteObject.gateway).condition) {
                        $RouteObject.Interface = $IntObj.Interface
                        $lastGateway = $RouteObject.gateway
                        $lastInterface = $IntObj.Interface
                        $found = $true
                        break
                    }
                }
                if (-not $found) {
                    Add-HostDebugText -HostObject $Device "DEBUG: No local interface found for gateway $($RouteObject.gateway)"
                }
            }
        }

        # Default Gateway Flag
        if ($RouteObject.Subnet -eq "0.0.0.0/0") {
            $RouteObject.defaultgateway = $true
        }

        $RouteObject
    }

    Add-HostDebugText -HostObject $Device "Found $($AllRouteObjects.Count) routes."
    $Device.RoutingTable = $AllRouteObjects
    return $Device
}



function Get-FortiGateVersionFromText {
    param (
        [Parameter(Mandatory=$true)]
        $Device,
        [string]$SystemStatusFile,
        [string]$HaStatusFile,
        [string]$FullConfigFile
    )

    $VersionObject = Create-ShowVersionObject
    $VersionObject.Type = "FortiGate"
    
    # TextFSM: System Status
    if (-not [string]::IsNullOrEmpty($SystemStatusFile) -and (Test-Path $SystemStatusFile)) {
        $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['fortinet_get_system_status'] -ShowFile $SystemStatusFile -HostObject $Device
        
        if ($Device.ProcessOutputObjects -ne "ERROR" -and $Device.ProcessOutputObjects.Count -gt 0) {
            if ($Device.ProcessOutputObjects[0] -is [string]) { $RawData = $Device.ProcessOutputObjects } else { $RawData = $Device.ProcessOutputObjects[0] }
            
            $VersionObject.Hostname       = $RawData[0]
            $VersionObject.OS             = $RawData[1]
            $VersionObject.Serial         += $RawData[12]
            $VersionObject.ROMMON         = $RawData[23]
            $VersionObject.Hardware       = $RawData[24]
            $VersionObject.Uptime         = $RawData[34]
            $VersionObject.ReasonForRelod = $RawData[41]
            
            if ($VersionObject.Hostname) { $Device.hostname = $VersionObject.Hostname }
        }
    }

    # TextFSM: HA Status
    if (-not [string]::IsNullOrEmpty($HaStatusFile) -and (Test-Path $HaStatusFile)) {
        $TempDevice = [PSCustomObject]@{ ProcessOutputObjects = @() }
        $TempHostObj = Create-HostObject
        $TempDevice = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['fortinet_get_system_ha_status'] -ShowFile $HaStatusFile -HostObject $TempHostObj

        if ($TempDevice.ProcessOutputObjects -ne "ERROR" -and $TempDevice.ProcessOutputObjects.Count -gt 0) {
            if ($TempDevice.ProcessOutputObjects[0] -is [string]) { $HAData = $TempDevice.ProcessOutputObjects } else { $HAData = $TempDevice.ProcessOutputObjects[0] }
            
            $MasterSerial = $HAData[11]
            $SlaveSerial  = $HAData[12]
            if ($MasterSerial -and $VersionObject.Serial -notcontains $MasterSerial) { $VersionObject.Serial += $MasterSerial }
            if ($SlaveSerial -and $VersionObject.Serial -notcontains $SlaveSerial) { $VersionObject.Serial += $SlaveSerial }
        }
    }

    # Regex: Full Config
    if (-not [string]::IsNullOrEmpty($FullConfigFile) -and (Test-Path $FullConfigFile)) {
        $ConfigText = Get-Content -Raw $FullConfigFile
        if ($ConfigText -match '#config-version=(?<Model>[A-Za-z0-9]+)-(?<Version>[0-9\.]+)-FW-build(?<Build>\d+)') {
            if (-not $VersionObject.Hardware) { $VersionObject.Hardware = $Matches['Model'] }
            if (-not $VersionObject.OS) { $VersionObject.OS = "v" + $Matches['Version'] + " build " + $Matches['Build'] }
        }
        if ([string]::IsNullOrWhiteSpace($VersionObject.Hostname) -and $ConfigText -match '(?m)^\s*set hostname\s+"?(?<Hostname>[^"\r\n]+)"?') {
            $VersionObject.Hostname = $Matches['Hostname']
            $Device.hostname = $Matches['Hostname']
        }
        if ($ConfigText -match '(?ms)config system ha\s+.*?set mode\s+(?<Mode>\S+)') {
             $VersionObject | Add-Member -MemberType NoteProperty -Name "HAMode" -Value $Matches['Mode'] -Force 
        }

    }

    $VersionObject.Serial = $VersionObject.Serial | Select-Object -Unique | Where-Object { $_ -ne "" }
    $Device.Version = $VersionObject
    return $Device
}


function Get-FortiGateArpFromText {
    param (
        [parameter(Mandatory=$true)]
        $ShowArpFile,
        $Device
    )

    # 1. Validation
    if (-not $ShowArpFile -or -not (Test-Path $ShowArpFile)) {
        return $Device
    }

    $ArpText = Get-Content -Raw $ShowArpFile
    if (($ArpText | Select-String "(Command parse error|Unknown command|Invalid input detected)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "ARP file contains invalid data: $ShowArpFile" -BackgroundColor Red
        return $Device
    }

    Add-HostDebugText -HostObject $Device "Processing FortiGate ARP Table..."

    # 2. Execute TextFSM
    # Template Columns: [0]IP_ADDRESS [1]AGE [2]MAC_ADDRESS [3]INTERFACE
    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['fortinet_get_system_arp'] -ShowFile $ShowArpFile -ReturnArray $true -HostObject $Device

    if ($Device.ProcessOutputObjects -eq "ERROR" -or $null -eq $Device.ProcessOutputObjects) {
        Add-HostDebugText -HostObject $Device "TextFSM returned ERROR or NULL for ARP table." -BackgroundColor Red
        return $Device
    }

    # --- OPTIMIZATION START (Matches Cisco Logic) ---
    # Create a hashtable of available subnets for fast lookups.
    $subnetLookup = @{}
    $Device.interfaces | Where-Object { $_.Cidr } | ForEach-Object { $subnetLookup[$_.Cidr] = $true }
    # --- OPTIMIZATION END ---

    # 3. Process ARP Entries
    $Device.IPArpEntries = foreach ($Row in $Device.ProcessOutputObjects) {
        $IPArpObject = Create-ShowIPArpObject
        
        $IPArpObject.ipaddress = $Row[0].Trim()
        $IPArpObject.AGE       = $Row[1].Trim()
        $IPArpObject.MAC       = $Row[2].Trim()
        $IPArpObject.INTERFACE = $Row[3].Trim()

        # --- Vendor Lookup ---
        # Since input is "50:52:00:...", Substring(0,8) gives "50:52:00" which matches your mapping keys
        if ($IPArpObject.MAC.Length -ge 8) {
            if ($GMacAddressToVendorMapping[$IPArpObject.MAC.Substring(0,8)]) {
                $IPArpObject.VendorCompanyName = $GMacAddressToVendorMapping[$IPArpObject.MAC.Substring(0,8)]
            } 
            # Fallback for shorter prefixes if necessary (rare for OUI)
            elseif ($IPArpObject.MAC.Length -ge 5 -and $GMacAddressToVendorMapping[$IPArpObject.MAC.Substring(0,5)]) {
                $IPArpObject.VendorCompanyName = $GMacAddressToVendorMapping[$IPArpObject.MAC.Substring(0,5)]
            } 
            else {
                $IPArpObject.VendorCompanyName = "UNKNOWN Vendor"
            }
        }

        # --- OPTIMIZATION START (Subnet Matching) ---
        # Find the most specific subnet by checking from /32 down to /1.
        for ($prefix = 32; $prefix -ge 1; $prefix--) {
            try {
                $candidateCidr = (Get-IPv4Subnet -IPAddress $IPArpObject.ipaddress -PrefixLength $prefix).CIDRId
                if ($subnetLookup.ContainsKey($candidateCidr)) {
                    $IPArpObject.cidr = $candidateCidr
                    break # Found the best match
                }
            } catch {}
        }
        # --- OPTIMIZATION END ---

        $IPArpObject
    }

    Add-HostDebugText -HostObject $Device "Found $($Device.IPArpEntries.Count) ARP entries."
    return $Device
}