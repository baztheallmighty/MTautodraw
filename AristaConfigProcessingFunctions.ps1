# This file contains all of the functions that process Arista config.

# This function calls all the other functions to process all of the files for an Arista device.
# Input: Hostid object.
# Output: $device object.
function Process-AristaHostFiles {
    param (
        [parameter(Mandatory = $true)]
        $hostid,
        $ArrayOfObjects
    )
    
    $Device = $null
    # First, create the device object from the show run config file.
    # NOTE: This assumes a 'Get-AristaShowRunFromText' function exists, similar to the Cisco example.
    # Since no 'show run' template was provided, this part is based on the Cisco pattern.
    if ($hostid.showrun -and (Test-Path -Path $hostid.showrun)) {
        $config = Get-Content -Path $hostid.showrun -raw
        # $Device = Get-AristaShowRunFromText -Lconfig $config # Assumes this function exists
        
        # --- FALLBACK IF Get-AristaShowRunFromText is not available ---
        # As a fallback, we must create a basic $Device object to proceed.
        # We'll try to get the hostname from 'show hostname' as a starting point.
        if ($null -eq $Device) {
            if ($hostid.ShowHostname -and (Test-Path -Path $hostid.ShowHostname)) {
                Add-HostDebugText -HostObject $Device "No 'show run' parser. Attempting to create Device object from 'show hostname'."
                $Device = Create-HostObject
                # This function is defined below
                $Device = Get-AristaHostname -ShowHostnameFile $hostid.ShowHostname -Device $Device 
            } else {
                 Write-host "File doesn't exist for hostid '$($hostid.HOSTID)': $($hostid.showrun) AND no fallback 'show hostname' found."
                 return $null
            }
        }
        # --- END FALLBACK ---

        $Device.DeviceIdentifier = ($hostid.showrun -replace "\.show run.*", '' -replace "^.*\\", '' -replace "\.show configuration.*", '')
    }
    else {
        Write-host "Show run file doesn't exist for hostid '$($hostid.HOSTID)': $($hostid.showrun)"
        return $null
    }

    if ($null -eq $Device -or [string]::IsNullOrEmpty($Device.hostname) -or $Device.hostname -like "*NoHostNameFound*") {
        Write-host "Can't find hostname in file, skipping host: $($hostid.showrun)" -BackgroundColor red
        return $null
    }

    # Now that $Device is a valid object, we can begin logging.
    Add-HostDebugText -HostObject $Device "Processing Arista Host: $($Device.hostname)"

    # Hostname collision check (copied from Cisco example)
    foreach ($ExistingDevice in $ArrayOfObjects) {
        if ($ExistingDevice.hostname -eq $Device.hostname) {
            Add-HostDebugText -HostObject $Device "Hostname already exists $($ExistingDevice.hostname) - $($Device.hostname). This means you either have the same code twice in the folder or someone has named two devices the same. This script requries unquie hostnames." -BackgroundColor red
            Add-HostDebugText -HostObject $Device "Found problem at: $($hostid.HOSTID)" -BackgroundColor red
            Add-HostDebugText -HostObject $Device "Existing HostID's:$($ArrayOfHostIDs | ft HOSTID,showrun | out-string)"
            Add-HostDebugText -HostObject $Device "$($ArrayOfObjects|ft hostname,DeviceIdentifier| out-string)"
            if (!($SkipHostnameErrorCheck)) {
                Add-HostDebugText -HostObject $Device 'Exiting please manually fix this error.' -BackgroundColor red
                Start-CleanupAndExit
            }
        }
    }

    if ($hostid.ShowVersion) {
        Add-HostDebugText -HostObject $Device "Processing show version: $($hostid.ShowVersion)"
        # Pass ShowReloadCauseFile if it exists
        $Device = Get-AristaShowVersionFromText -ShowVersionFile $hostid.ShowVersion -Device $Device -ShowReloadCauseFile $hostid.ShowReloadCause
    }
    
    # Arista devices typically don't run CDP, so we'll skip the CDP check.
    
    if ($hostid.ShowLLDPNeighborsDetails) {
        Add-HostDebugText -HostObject $Device "Processing show LLDP Details:$($hostid.ShowLLDPNeighborsDetails)"
        $Device = Get-AristaShowLLDPNeighborsDetailsFromText -ShowLLDPDetailsFile $hostid.ShowLLDPNeighborsDetails -Device $Device -ShowLLDPFile $hostid.ShowLLDPNeighbors
    }

    if ($hostid.ShowInterface) {
        Add-HostDebugText -HostObject $Device "Processing Show Interface :$($hostid.ShowInterface)"
        $Device = Get-AristaShowInterfaceFromText -ShowInterfaceFile $hostid.ShowInterface -Device $Device
    }
    elseif ($hostid.ShowIPInterfaceBrief) {
        Add-HostDebugText -HostObject $Device "Processing Show ip Interface Brief:$($hostid.ShowIPInterfaceBrief)"
        $Device = Get-AristaShowIPInterfaceBriefFromText -ShowIPInterfaceBrief $hostid.ShowIPInterfaceBrief -Device $Device
    }
    else {
        #Do nothing
    }

    if ($hostid.ShowInterfaceStatus) {
        # This is useful for populating media type, duplex, speed, etc.
        Add-HostDebugText -HostObject $Device "Processing Show Interface status:$($hostid.ShowInterfaceStatus)"
        $Device = Get-AristaShowInterfaceStatusFromText -ShowInterfaceStatusFile $hostid.ShowInterfaceStatus -Device $Device
    }

    if ($hostid.ShowIPBGPSummary) {
        Add-HostDebugText -HostObject $Device "Processing BGP Summary: $($hostid.ShowIPBGPSummary)"
        $Device = Get-AristaShowIPBGPSummaryFromText -BGPSummaryFile $hostid.ShowIPBGPSummary -Device $Device
    }
    
    # No Spanning Tree template was provided that maps to the desired object.

    if ($hostid.ShowIPRoute -or $hostid.ShowIPRouteVRFstar) {
        Add-HostDebugText -HostObject $Device "Processing Show ip route:$($hostid.ShowIPRoute)"
        # Pass both files; the function will decide which to use.
        $Device = Get-AristaShowIPRouteFromText -ShowIPRouteFile $hostid.ShowIPRoute -ShowIPRouteVRFstar $hostid.ShowIPRouteVRFstar -Device $Device
    }

    if ($hostid.ShowIPArp) {
        if ($GDrawAprEntries) {
            Add-HostDebugText -HostObject $Device "Processing Show ip Arp:$($hostid.ShowIPArp)"
            $Device = Get-AristaShowIPArpFromText -ShowIPArpFile $hostid.ShowIPArp -Device $Device
        }
    }

    if ($hostid.ShowMacAddressTable -and $GDrawPortsWithMacs -ne 0) {
        if ($GDrawCDP) { # Using GDrawCDP as a proxy for "draw L2 links"
            Add-HostDebugText -HostObject $Device "Processing Show Mac Address Table:$($hostid.ShowMacAddressTable)"
            $Device = Get-AristaShowMacAddressTableFromText -ShowMacAddressTable $hostid.ShowMacAddressTable -Device $Device
        }
    }
    
    $Device = Update-LocalRoutesWithInterfaces -device $Device
    return $Device
}

# This is a helper function to create the $Device object if 'show run' isn't used.
function Get-AristaHostname {
    param (
        [parameter(Mandatory = $true)]
        $ShowHostnameFile,
        [parameter(Mandatory = $true)]
        $Device
    )
    
    $ShowHostnameText = Get-Content -raw $ShowHostnameFile
    if (($ShowHostnameText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$($ShowHostnameText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty" -BackgroundColor red
        return $Device
    }

    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['arista_eos_show_hostname'] -ShowFile $ShowHostnameFile -HostObject $Device
    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Error with show hostname on Arista."
        return $Device
    }

    $Device.hostname = $Device.ProcessOutputObjects[0]
    return $Device
}

#Process the show version file
function Get-AristaShowVersionFromText {
    param (
        [parameter(Mandatory = $true)]
        $ShowVersionFile,
        [parameter(Mandatory = $true)]
        $Device,
        $ShowReloadCauseFile # Optional
    )
    
    $ShowVersionText = Get-Content -raw $ShowVersionFile
    if (($ShowVersionText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$($ShowVersionText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty" -BackgroundColor red
        return $Device
    }

    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['arista_eos_show_version'] -ShowFile $ShowVersionFile -HostObject $Device
    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Error with show version on Arista."
        return $Device
    }

    $VersionObject = Create-ShowVersionObject
    $VersionObject.OS = $Device.ProcessOutputObjects[5] # IMAGE
    $VersionObject.Uptime = $Device.ProcessOutputObjects[7] # UPTIME
    $VersionObject.Image = $Device.ProcessOutputObjects[5] # IMAGE
    $VersionObject.Hardware = @($Device.ProcessOutputObjects[0]) # MODEL
    $VersionObject.Serial = @($Device.ProcessOutputObjects[2]) # SERIAL_NUMBER
    $VersionObject.MacAddressArray = @($Device.ProcessOutputObjects[3]) # SYS_MAC
    $VersionObject.Type = "Arista-EOS"

    # If a reload cause file is provided, process it
    if ($ShowReloadCauseFile -and (Test-Path -Path $ShowReloadCauseFile)) {
        $ShowReloadCauseText = Get-Content -raw $ShowReloadCauseFile
        if (-not ($ShowReloadCauseText | Select-String "(Line has invalid autocommand|Invalid input detected at)").Matches.Success) {
            
            # Use a *temporary* variable for the TextFSM output, so we don't overwrite the 'show version' output
            $TempDevice = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['arista_eos_show_reload_cause'] -ShowFile $ShowReloadCauseFile -HostObject $Device

            
            if ($TempDevice.ProcessOutputObjects -ne "ERROR") {
                $VersionObject.ReasonForRelod = $TempDevice.ProcessOutputObjects[0] # RELOAD_CAUSE
            } else {
                Add-HostDebugText -HostObject $Device "Error processing reload cause file." -BackgroundColor Yellow
            }
        }
    }

    $Device.Version = $VersionObject
    return $Device
}

#Process the Show LLDP Details file
function Get-AristaShowLLDPNeighborsDetailsFromText {
    param (
        [parameter(Mandatory = $true)]
        $ShowLLDPDetailsFile,
        [parameter(Mandatory = $true)]
        $Device,
        $ShowLLDPFile #Optional fix for missing lldp neighbors
    )
    
    $ShowLLDPDetailText = Get-Content -raw $ShowLLDPDetailsFile
    $AllLLDPDetailsObjects = @() 
    if (($ShowLLDPDetailText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:|LLDP is not enabled)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$($ShowLLDPDetailText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty" -BackgroundColor red
        return $Device
    }

    # Arista's 'show lldp neighbors detail' template is reliable and includes the local interface.
    # We will prioritize it.
    
    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['arista_eos_show_lldp_neighbors_detail'] -ShowFile $ShowLLDPDetailsFile -ReturnArray $true -HostObject $Device

    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Error with show lldp neighbors details on Arista."
        return $Device
    }
    
    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        $tempArray = @()
        $tempArray += , $Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }

    foreach ($LLDPNeighbor in $Device.ProcessOutputObjects) {
        # $LLDPNeighbor[0] = NEIGHBOR_NAME
        # $LLDPNeighbor[1] = CHASSIS_ID
        # $LLDPNeighbor[2] = MGMT_ADDRESS
        # $LLDPNeighbor[3] = NEIGHBOR_DESCRIPTION
        # $LLDPNeighbor[4] = NEIGHBOR_INTERFACE
        # $LLDPNeighbor[5] = LOCAL_INTERFACE
        # $LLDPNeighbor[6] = NEIGHBOR_COUNT
        # $LLDPNeighbor[7] = AGE
        
        # Skip phones if configured
        if ($GSkipCDPLLDPPhones) {
            if (($LLDPNeighbor[3] -like "*Phone*") -or ($LLDPNeighbor[3] -like "*Endpoint*")) {
                continue
            }
        }

        $LLDPObject = Create-LLDPNeighborObject
        $LLDPObject.Hostname = $LLDPNeighbor[0].trim()
        $LLDPObject.ChassisID = $LLDPNeighbor[1].trim()
        $LLDPObject.ManagementIP = $LLDPNeighbor[2].trim()
        $LLDPObject.SystemDescription = $LLDPNeighbor[3].trim()
        $LLDPObject.InterfaceRemoteDevice = (Replace-InterfaceShortName -string $LLDPNeighbor[4])
        $LLDPObject.PortID = $LLDPNeighbor[4].trim() # Use the raw port ID for matching
        $LLDPObject.InterfaceLocalDevice = (Replace-InterfaceShortName -string $LLDPNeighbor[5])
        $LLDPObject.ParentObject = $Device.hostname

        if ([string]::IsNullOrEmpty($LLDPObject.Hostname)) {
            $LLDPObject.Hostname = $LLDPObject.ChassisID
        }

        # Find the local interface on the $Device object and update it
        $TempInterface = $device.interfaces | where { $_.interface -eq $LLDPObject.InterfaceLocalDevice }
        if ($TempInterface) {
            $TempInterface.HasLLDPNeighbor = $true
            # Check if it also has a CDP neighbor (unlikely on Arista, but good practice)
            if ($TempInterface.HasCPDNieghbor) { 
                $LLDPObject.HasCDPNeighborEntry = $true
            }
        }

        $AllLLDPDetailsObjects += $LLDPObject
    }

    $device.LLDPNeighbors = $AllLLDPDetailsObjects | sort -property @{Expression = {[int]($_.InterfaceLocalDevice -replace '[a-zA-Z-]+', '' -replace "/", '')}}
    return $Device
}

#Process the show interfaces file.
function Get-AristaShowInterfaceFromText {
    param (
        [parameter(Mandatory = $true)]
        $ShowInterfaceFile,
        $Device
    )
    
    $ShowInterfaceText = Get-Content -raw $ShowInterfaceFile
    if (($ShowInterfaceText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$($ShowInterfaceText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty" -BackgroundColor red
        return $Device
    }

    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['arista_eos_show_interfaces'] -ShowFile $ShowInterfaceFile -ReturnArray $true -HostObject $Device

    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Error with show interfaces on Arista."
        return $Device
    }

    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        $tempArray = @()
        $tempArray += , $Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }
    
    $UpdateOnly = $false # Flag to track if we are only updating existing interfaces
    if ($Device.interfaces.Count -gt 0) {
        $UpdateOnly = $true
    }
    
    $AllInterfaces = @() # Used if we are creating interfaces from scratch

    foreach ($int in $Device.ProcessOutputObjects) {
        # $int[0] = INTERFACE
        # $int[1] = LINK_STATUS
        # $int[2] = PROTOCOL_STATUS
        # $int[3] = HARDWARE_TYPE
        # $int[4] = MAC_ADDRESS
        # $int[5] = BIA
        # $int[6] = DESCRIPTION
        # $int[7] = IP_ADDRESS (e.g., 10.1.1.1/24)
        # $int[8] = MTU
        # $int[9] = BANDWIDTH (e.g., 10 Gbit/s)
        
        $InterfaceName = (Replace-InterfaceShortName -string $int[0])
        $Interface = $Device.interfaces | where { $_.interface -eq $InterfaceName }

        if ($Interface) { #We already have the interface from show run. Just update some variables.
            $UpdateOnly = $true # Confirm we are in update mode
            
            $Interface.IntStatus = $int[1] -replace "administratively ", '' -replace "\s*\(.*", ''
            $Interface.INTProtocolStatus = $int[2] -replace "\s*\(.*", '' -replace ",.*", ''
            $Interface.HardwareType = $int[3]
            $interface.macaddress = $int[4]
            
            # Only update description if it's not already set (show run is preferred)
            if ([string]::IsNullOrEmpty($Interface.Description)) {
                $Interface.Description = $int[6]
            }

            # Only update IP if not already set (show run is preferred)
            if ([string]::IsNullOrEmpty($Interface.IPAddress) -and -not [string]::IsNullOrEmpty($int[7])) {
                $IPFields = $int[7].Split('/')
                $Interface.IPAddress = $IPFields[0]
                $Interface.SubnetMask = $IPFields[1]
                if ($Interface.IPAddress -and $Interface.SubnetMask) {
                    $Interface.Cidr = (Get-IPv4Subnet -IPAddress $Interface.IPAddress -PrefixLength $Interface.SubnetMask).cidrid
                }
            }
            
            $Interface.Speed = $int[9] -replace "bit/s", "b/s" # Standardize format
        }
        else {
            # If we are in 'UpdateOnly' mode, it means we found an interface
            # in 'show interface' that wasn't in 'show run'. Log it.
            if ($UpdateOnly) {
                Add-HostDebugText -HostObject $Device "Found interface '$($InterfaceName)' in 'show interfaces' but not in 'show run'. Skipping." -BackgroundColor Yellow
                continue
            }
            
            # We are creating interfaces from scratch (no 'show run' data)
            $Interface = Create-InterfaceObject
            $Interface.Interface = $InterfaceName
            $Interface.IntStatus = $int[1] -replace "administratively ", '' -replace "\s*\(.*", ''
            $Interface.INTProtocolStatus = $int[2] -replace "\s*\(.*", '' -replace ",.*", ''
            
            if ($Interface.IntStatus -eq "down" -or $Interface.INTProtocolStatus -eq "down") {
                $Interface.shutdown = $true
            }

            $Interface.HardwareType = $int[3]
            $interface.macaddress = $int[4]
            $Interface.Description = $int[6]

            if (-not [string]::IsNullOrEmpty($int[7])) {
                $IPFields = $int[7].Split('/')
                $Interface.IPAddress = $IPFields[0]
                $Interface.SubnetMask = $IPFields[1]
                if ($Interface.IPAddress -and $Interface.SubnetMask) {
                    $Interface.Cidr = (Get-IPv4Subnet -IPAddress $Interface.IPAddress -PrefixLength $Interface.SubnetMask).cidrid
                }
            }
            $Interface.Speed = $int[9] -replace "bit/s", "b/s" # Standardize format
            $AllInterfaces += $Interface
        }
    }

    if (-not $UpdateOnly) {
        $device.interfaces = $AllInterfaces
    }
    
    return $device
}

#Process the show ip interface brief file
function Get-AristaShowIPInterfaceBriefFromText {
    param (
        [parameter(Mandatory = $true)]
        $ShowIPInterfaceBriefFile,
        $Device
    )
    
    $ShowIPInterfaceBriefText = Get-Content -raw $ShowIPInterfaceBriefFile
    if (($ShowIPInterfaceBriefText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$($ShowIPInterfaceBriefText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty" -BackgroundColor red
        return $Device
    }

    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['arista_eos_show_ip_interface_brief'] -ShowFile $ShowIPInterfaceBriefFile -ReturnArray $true -HostObject $Device

    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Error with Show IP Int Brief on Arista."
        return $Device
    }

    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        $tempArray = @()
        $tempArray += , $Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }

    foreach ($int in $Device.ProcessOutputObjects) {
        # $int[0] = INTERFACE
        # $int[1] = IP_ADDRESS
        # $int[2] = STATUS
        # $int[3] = PROTOCOL
        # $int[4] = MTU
        
        $InterfaceName = (Replace-InterfaceShortName -string $int[0])
        $Interface = $Device.interfaces | where { $_.interface -eq $InterfaceName } | select -first 1

        if ($Interface) {
            # Only update if 'show interface' (more detailed) hasn't already
            if ([string]::IsNullOrEmpty($Interface.IntStatus)) {
                $Interface.IntStatus = $int[2]
            }
            if ([string]::IsNullOrEmpty($Interface.INTProtocolStatus)) {
                $Interface.INTProtocolStatus = $int[3]
            }
            # Only update IP if not already set (show run is preferred)
            if ([string]::IsNullOrEmpty($Interface.IPAddress) -and $int[1] -ne "unassigned") {
                 $Interface.IPAddress = $int[1]
                 # Note: This template doesn't provide a subnet mask.
            }
        }
        else {
            Add-HostDebugText -HostObject $Device "$($int) not found in list of interfaces $($InterfaceName). Replace-InterfaceShortName is probably the cause."
        }
    }
    return $Device
}

#Process 'show interface status'
function Get-AristaShowInterfaceStatusFromText {
    param (
        [parameter(Mandatory = $true)]
        $ShowInterfaceStatusFile,
        $Device
    )
    
    $ShowInterfaceStatusText = Get-Content -raw $ShowInterfaceStatusFile
    if (($ShowInterfaceStatusText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$($ShowInterfaceStatusText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty" -BackgroundColor red
        return $Device
    }

    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['arista_eos_show_interfaces_status'] -ShowFile $ShowInterfaceStatusFile -ReturnArray $true -HostObject $Device
    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Error with Show Interface status Arista."
        return $Device
    }

    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        $tempArray = @()
        $tempArray += , $Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }

    foreach ($int in $Device.ProcessOutputObjects) {
        # $int[0] = PORT
        # $int[1] = NAME (Description)
        # $int[2] = STATUS
        # $int[3] = VLAN_ID
        # $int[4] = DUPLEX
        # $int[5] = SPEED
        # $int[6] = TYPE (Media Type)
        
        $InterfaceName = (Replace-InterfaceShortName -string $int[0])
        $Interface = $Device.interfaces | where { $_.interface -eq $InterfaceName } | select -first 1

        if ($Interface) {
            if ([string]::IsNullOrEmpty($Interface.Description)) {
                 $Interface.Description = $int[1]
            }
            if ([string]::IsNullOrEmpty($Interface.IntStatus)) {
                $Interface.IntStatus = $int[2]
            }
            if ([string]::IsNullOrEmpty($Interface.SwitchportAccessVlan) -and $int[3] -ne "trunk" -and $int[3] -ne "routed") {
                $Interface.SwitchportAccessVlan = $int[3]
            }
            if ([string]::IsNullOrEmpty($Interface.Duplex)) {
                 $Interface.Duplex = $int[4]
            }
             if ([string]::IsNullOrEmpty($Interface.Speed)) {
                 $Interface.Speed = $int[5]
            }
             if ([string]::IsNullOrEmpty($Interface.MediaType)) {
                 $Interface.MediaType = $int[6]
            }
        }
        else {
            Add-HostDebugText -HostObject $Device "$($int) not found in list of interfaces $($InterfaceName). Replace-InterfaceShortName is probably the cause."
        }
    }
    return $Device
}

#Process the 'show ip bgp summary' file to populate BGP neighbors
function Get-AristaShowIPBGPSummaryFromText {
    param (
        [parameter(Mandatory = $true)]
        $BGPSummaryFile,
        $Device
    )

    $BGPSummaryText = Get-Content -raw $BGPSummaryFile
    if (($BGPSummaryText | Select-String "(BGP not active|Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Ambiguous command:)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$($BGPSummaryText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "BGP Summary file contains invalid data or is empty." -BackgroundColor red
        return $Device
    }

    $AllBGPNeighbors = @()

    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['arista_eos_show_ip_bgp_summary'] -ShowFile $BGPSummaryFile -ReturnArray $true -HostObject $Device
    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Error processing Arista BGP summary file: $($BGPSummaryFile)" -BackgroundColor Red
        return $device
    }

    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        $tempArray = @()
        $tempArray += , $Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }

    foreach ($SummaryData in $Device.ProcessOutputObjects) {
        # $SummaryData[0] = ROUTER_ID
        # $SummaryData[1] = LOCAL_AS
        # $SummaryData[2] = VRF
        # $SummaryData[3] = DESCRIPTION
        # $SummaryData[4] = BGP_NEIGH
        # $SummaryData[5] = NEIGH_AS
        # $SummaryData[6] = MSG_RCVD
        # $SummaryData[7] = MSG_SENT
        # $SummaryData[8] = IN_QUEUE
        # $SummaryData[9] = OUT_QUEUE
        # $SummaryData[10] = UP_DOWN
        # $SummaryData[11] = STATE
        # $SummaryData[12] = STATE_PFXRCD
        # $SummaryData[13] = STATE_PFXACC
        
        $NeighborObject = Create-BGPNeighborObject
        $NeighborObject.LOCAL_AS = $SummaryData[1]
        $NeighborObject.VRF = $SummaryData[2]
        $NeighborObject.DESCRIPTION = $SummaryData[3]
        $NeighborObject.NEIGHBOR = $SummaryData[4]
        $NeighborObject.REMOTE_AS = $SummaryData[5]
        $NeighborObject.BGP_STATE = $SummaryData[11]

        $AllBGPNeighbors += $NeighborObject
    }

    $device.BGPNeighbors = $AllBGPNeighbors
    Add-HostDebugText -HostObject $Device " -> Populated $($AllBGPNeighbors.Count) BGP neighbors from summary file."
    return $device
}

#Process the show ip route file
function Get-AristaShowIPRouteFromText {
    param (
        [parameter(Mandatory = $true)]
        $ShowIPRouteFile,
        $ShowIPRouteVRFstar, # Arista uses 'show ip route vrf all' or just 'show ip route'
        $Device
    )

    $AllRouteObjects = @()
    $FileToProcess = $null
    
    # Prioritize the 'vrf all' file if it exists and is valid
    if ($ShowIPRouteVRFstar -and (Test-Path $ShowIPRouteVRFstar)) {
        $ShowRouteText = Get-Content -raw $ShowIPRouteVRFstar
        if (-not ($ShowRouteText | Select-String "(Line has invalid autocommand|Invalid input detected at)").Matches.Success) {
            $FileToProcess = $ShowIPRouteVRFstar
            Add-HostDebugText -HostObject $Device "Using 'show ip route vrf all' file."
        }
    }

    # Fall back to the standard 'show ip route' file
    if ($null -eq $FileToProcess -and $ShowIPRouteFile -and (Test-Path $ShowIPRouteFile)) {
         $ShowRouteText = Get-Content -raw $ShowIPRouteFile
         if (-not ($ShowRouteText | Select-String "(Line has invalid autocommand|Invalid input detected at)").Matches.Success) {
            $FileToProcess = $ShowIPRouteFile
            Add-HostDebugText -HostObject $Device "Using standard 'show ip route' file."
        }
    }
    
    if ($null -eq $FileToProcess) {
        Add-HostDebugText -HostObject $Device "No valid 'show ip route' file found." -BackgroundColor red
        return $Device
    }

    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['arista_eos_show_ip_route'] -ShowFile $FileToProcess -ReturnArray $true -HostObject $Device
    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Error with show ip route on Arista." -BackgroundColor red
        return $Device
    }
    
    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        $tempArray = @()
        $tempArray += , $Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }
    
    # OPTIMIZATION: Cache active interfaces
    $ActiveInterfaces = $Device.interfaces | Where-Object { $_.cidr -and $_.IntStatus -ne "down" }
    $lastGateway = $null
    $lastInterface = $null

    $AllRouteObjects = foreach ($Route in ($Device.ProcessOutputObjects | Sort-Object { $_[7] })) {
        # $Route[0] = VRF
        # $Route[1] = PROTOCOL
        # $Route[2] = NETWORK
        # $Route[3] = PREFIX_LENGTH
        # $Route[4] = DISTANCE
        # $Route[5] = METRIC
        # $Route[6] = DIRECT
        # $Route[7] = NEXT_HOP (List)
        # $Route[8] = INTERFACE (List)
        
        $RouteObject = Create-RouteObject
        $RouteObject.VRF = $Route[0]
        $RouteObject.RouteProtocol = $Route[1]
        $RouteObject.Subnet = "$($Route[2])/$($Route[3])"
        $RouteObject.DISTANCE = $Route[4]
        $RouteObject.METRIC = $Route[5]
        $RouteObject.gateway = $Route[7]  # This is a List, but we'll take the first one
        $RouteObject.Interface = $Route[8] # This is a List, but we'll take the first one

        # Handle default gateway
        if ($RouteObject.Subnet -eq "0.0.0.0/0") {
            $RouteObject.defaultgateway = $true
        }

        # Find the outbound interface for non-connected routes
        if ($RouteObject.gateway -and ($RouteObject.gateway -ne "Null0") -and ($RouteObject.RouteProtocol -ne "local") -and ($RouteObject.RouteProtocol -ne "connected") -and ($RouteObject.RouteProtocol -ne "direct")) {
            if ($RouteObject.gateway -eq $lastGateway) {
                $RouteObject.Interface = $lastInterface
            }
            else {
                $found = $false
                foreach ($Interface in $ActiveInterfaces) {
                    if ((Find-Subnet -addr1 $Interface.cidr -addr2 $RouteObject.gateway).condition) {
                        $RouteObject.Interface = $Interface.Interface
                        $lastGateway = $RouteObject.gateway
                        $lastInterface = $Interface.Interface
                        $found = $true
                        break
                    }
                }
                if (-not $found) {
                    Add-HostDebugText -HostObject $Device "No matching interface found for gateway $($RouteObject.gateway)" -BackgroundColor Yellow
                }
            }
        }
        $RouteObject # Output to the collection
    }
    
    Add-HostDebugText -HostObject $Device "$($AllRouteObjects.count) routes found"
    $device.RoutingTable = $AllRouteObjects
    return $Device
}

#Process the show ip arp file
function Get-AristaShowIPArpFromText {
    param (
        [parameter(Mandatory = $true)]
        $ShowIPArpFile,
        $Device
    )
    
    $ShowIPArpText = Get-Content -raw $ShowIPArpFile
    if (($ShowIPArpText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$($ShowIPArpText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty" -BackgroundColor red
        return $Device
    }

    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['arista_eos_show_ip_arp'] -ShowFile $ShowIPArpFile -ReturnArray $true -HostObject $Device
    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Error with show ip arp on Arista."
        return $Device
    }

    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        $tempArray = @()
        $tempArray += , $Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }
    
    # --- OPTIMIZATION START ---
    $subnetLookup = @{}
    $device.interfaces | Where-Object { $_.Cidr } | ForEach-Object { $subnetLookup[$_.Cidr] = $true }
    # --- OPTIMIZATION END ---

    $device.IPArpEntries = foreach ($IPArpEntry in $Device.ProcessOutputObjects) {
        # $IPArpEntry[0] = IP_ADDRESS
        # $IPArpEntry[1] = AGE
        # $IPArpEntry[2] = MAC_ADDRESS
        # $IPArpEntry[3] = INTERFACE
        # $IPArpEntry[4] = VRF
        
        $IPArpObject = Create-ShowIPArpObject
        $IPArpObject.ipaddress = $IPArpEntry[0].trim()
        $IPArpObject.AGE = $IPArpEntry[1].trim()
        $IPArpObject.MAC = $IPArpEntry[2].trim()
        $IPArpObject.INTERFACE = $IPArpEntry[3].trim()
        
        # Get Vendor from MAC
        $MacInOtherFormat = ($IPArpObject.MAC -replace '\.', '').insert(2, ":").insert(5, ":").insert(8, ":").insert(11, ":").insert(14, ":")
        if ($GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 8)]) {
            $IPArpObject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 8)]
        }
        elseif ($GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 5)]) {
            $IPArpObject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 5)]
        }
        else {
            $IPArpObject.VendorCompanyName = "UNKNOWN Vendor"
        }
        
        # --- OPTIMIZATION START ---
        for ($prefix = 32; $prefix -ge 1; $prefix--) {
            $candidateCidr = (Get-IPv4Subnet -IPAddress $IPArpObject.ipaddress -PrefixLength $prefix).CIDRId
            if ($subnetLookup.ContainsKey($candidateCidr)) {
                $IPArpObject.cidr = $candidateCidr
                break 
            }
        }
        # --- OPTIMIZATION END ---

        $IPArpObject # Output the object
    }
    return $Device
}

#Process the show mac address-table file
function Get-AristaShowMacAddressTableFromText {
    param (
        [parameter(Mandatory = $true)]
        $ShowMacAddressTable,
        $Device
    )
    
    $ShowMacAddressTableText = Get-Content -raw $ShowMacAddressTable
    if (($ShowMacAddressTableText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$($ShowMacAddressTableText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty" -BackgroundColor red
        return $Device
    }

    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['arista_eos_show_mac_address-table'] -ShowFile $ShowMacAddressTable -ReturnArray $true -HostObject $Device
    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Error with show mac address-table on Arista processing."
        return $Device
    }

    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        $tempArray = @()
        $tempArray += , $Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }

    foreach ($Mac in $Device.ProcessOutputObjects) {
        # $Mac[0] = MAC_ADDRESS
        # $Mac[1] = TYPE
        # $Mac[2] = VLAN_ID
        # $Mac[3] = DESTINATION_PORT (List)
        # $Mac[4] = MOVES
        # $Mac[5] = LAST_MOVE
        
        # Process each port in the DESTINATION_PORT list
        foreach ($Port in $Mac[3]) {
            if ($Port -eq $null -or $Port -eq "" -or $Port -eq "CPU" -or $Port -eq "Router" -or $Port -eq "Switch") {
                continue
            }

            $MacAddressobject = Create-MacAddressObject
            $MacAddressobject.Interface = (Replace-InterfaceShortName -string $Port)

            if (!(Check-InterfaceType -string $MacAddressobject.Interface)) {
                continue #Skip if we don't have a valid interface.
            }

            $MacAddressobject.MacAddress = ($Mac[0]).trim()
            $MacAddressobject.type = ($Mac[1]).trim()
            $MacAddressobject.vlan = ($Mac[2]).trim()
            
            # Get Vendor
            $MacInOtherFormat = ($Mac[0] -replace '\.', '').insert(2, ":").insert(5, ":").insert(8, ":").insert(11, ":").insert(14, ":")
            if ($GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 8)]) {
                $MacAddressobject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 8)]
            }
            elseif ($GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 5)]) {
                $MacAddressobject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 5)]
            }
            else {
                $MacAddressobject.VendorCompanyName = "UNKNOWN Vendor"
            }
            
            # Find the interface on the device and add this MAC
            $DeviceInterface = $device.interfaces | where { $_.interface -eq $MacAddressobject.Interface }
            if ($null -eq $DeviceInterface) {
                Add-HostDebugText -HostObject $Device "We could not find the interface $($MacAddressobject.Interface) on the switch. Replace-InterfaceShortName might be the problem." -BackgroundColor red
                continue
            }
            $DeviceInterface.MacAddressArray += , $MacAddressobject
        }
    }
    return $Device
}