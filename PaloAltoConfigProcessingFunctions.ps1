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

# This file contains all of the functions that process Palo Alto config.

# This is the main function for processing a single Palo Alto device's files.
function Process-PaloAltoHostFiles {
    param (
        [parameter(Mandatory=$true)]
        $hostid,
        $ArrayOfObjects # Included for signature consistency with other processing functions
    )

    # For Palo Alto, all initial processing relies on the 'show system info' command.
    if ($hostid.ShowSystemInfo -and (Test-Path -Path $hostid.ShowSystemInfo)) {
        # The helper function creates and populates the entire device object.
        $Device = Get-PaloAltoSystemInfoFromText -ShowSystemInfoFile $hostid.ShowSystemInfo

        # If the device object was successfully created, add the DeviceIdentifier from the filename.
        if ($Device) {
            $Device.DeviceIdentifier = ($hostid.ShowSystemInfo -replace "\.show system info.*", '' -replace "^.*\\", '')
            Add-HostDebugText -HostObject $Device "Processing Palo Alto Host: $($Device.hostname)"
        } else {
            # The parsing function will have already logged a critical error.
            return $null
        }
    } else {
        Add-HostDebugText -HostObject $Device "Required file 'show system info' was not found for hostid '$($hostid.HOSTID)'"
        return $null
    }

    # Process the 'show interface all' file if it was found for this host.
    if ($hostid.ShowInterfaceAll) {
        Add-HostDebugText -HostObject $Device "Processing Palo Alto show interface all: $($hostid.ShowInterfaceAll)"
        $Device = Get-PaloAltoShowInterfaceAllFromText -ShowInterfaceFile $hostid.ShowInterfaceAll -Device $Device
    }

    if($hostid.ShowRouteAll){
        $Device = Get-PaloAltoRouteFromText -ShowRouteAllFile $hostid.ShowRouteAll -Device $Device
    }
    $Device = Update-LocalRoutesWithInterfaces -device $Device
    return $Device
}

# Processes 'show system info' output to create and populate a complete host object.
function Get-PaloAltoSystemInfoFromText {
    param (
        [parameter(Mandatory=$true)]
        $ShowSystemInfoFile
    )

    # Create the base host object to be populated.
    $Device = Create-HostObject
    $Device.Origin = "show system info"
    $Device.DeviceType = "PaloAlto"

    # Read the file content and perform basic validation.
    $SystemInfoText = Get-Content -raw $ShowSystemInfoFile
    if ([string]::IsNullOrWhiteSpace($SystemInfoText) -or ($SystemInfoText | Select-String "(Invalid input|Command fail|Unknown command)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "File '$ShowSystemInfoFile' contains invalid data or is empty." -BackgroundColor Red
        return $null # Return null on critical failure
    }

    # Split the command output into individual lines for processing.
    $lines = $SystemInfoText -split '[\r\n]+'

    foreach ($line in $lines) {
        # Match lines that follow the 'key: value' format.
        if ($line -match '^\s*([^:]+):\s*(.*)') {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim()

            # Assign the extracted value to the correct property on the main Device object.
            switch ($key) {
                'hostname'          { $Device.hostname = $value }
                'model'             { $Device.Platform = $value } # The 'model' maps to the 'Platform' property.
                'ip-address'        { $Device | Add-Member -MemberType NoteProperty -Name 'ManagementIP' -Value $value -Force }
                'public-ip-address' { $Device | Add-Member -MemberType NoteProperty -Name 'ManagementPublicIP' -Value $value -Force }
                'netmask'           { $Device | Add-Member -MemberType NoteProperty -Name 'ManagementNetmask' -Value $value -Force }
                'default-gateway'   { $Device | Add-Member -MemberType NoteProperty -Name 'ManagementGateway' -Value $value -Force }
                'mac-address'       { $Device | Add-Member -MemberType NoteProperty -Name 'ManagementMacAddress' -Value $value -Force }
            }
        }
    }

    # A hostname is critical for the rest of the script. If it wasn't found, fail processing for this device.
    if ([string]::IsNullOrWhiteSpace($Device.hostname)) {
        Add-HostDebugText -HostObject $Device "CRITICAL: No hostname found in '$ShowSystemInfoFile'." -BackgroundColor Red
        return $null
    }

    return $Device
}

# Processes the 'show interface all' command output using two TextFSM templates to build a complete interface list.
function Get-PaloAltoShowInterfaceAllFromText {
    param (
        [parameter(Mandatory=$true)]
        $ShowInterfaceFile,
        [parameter(Mandatory=$true)]
        $Device
    )
    
    [array]$AllInterfaces=@()
    # --- Step 1: Process HARDWARE interface details first to create base objects ---
    Add-HostDebugText -HostObject $Device "  -> Processing hardware interfaces..."
    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTemplate.PaloAltoShowInterfaceHardware -ShowFile $ShowInterfaceFile -ReturnArray $true -HostObject $Device
    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Error processing hardware interfaces from '$($ShowInterfaceFile)'." -BackgroundColor Red
        return $Device # Return the device as-is on failure
    }

    # Handle cases where only one result is returned
    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        $tempArray = @()
        $tempArray += ,$Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }

    # Create an interface object for each physical/hardware entry found
    foreach ($hardwareInt in $Device.ProcessOutputObjects) {
        $interfaceObject = Create-InterfaceObject
        $interfaceObject.Interface = $hardwareInt[0]
        $interfaceObject.Speed = $hardwareInt[2]
        $interfaceObject.Duplex = $hardwareInt[3]
        $interfaceObject.IntStatus = ($hardwareInt[4] -replace 'down\(autoneg\)',"down")
        $interfaceObject.macaddress = $hardwareInt[5]

        # Set the shutdown status based on the interface state
        if ($interfaceObject.IntStatus -ne "up") {
            $interfaceObject.shutdown = $true
        } else {
            $interfaceObject.shutdown = $false
        }

        $AllInterfaces += $interfaceObject
    }
    
    # --- Step 2: Process LOGICAL interface details and merge them with existing objects ---
    Add-HostDebugText -HostObject $Device "  -> Processing and merging logical interfaces..."
    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTemplate.PaloAltoShowInterfaceLogical -ShowFile $ShowInterfaceFile -ReturnArray $true -HostObject $Device
    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Error processing logical interfaces from '$($ShowInterfaceFile)'." -BackgroundColor Red
        return $Device # Return the device with any hardware data that was processed
    }

    # Handle cases where only one result is returned
    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        $tempArray = @()
        $tempArray += ,$Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }

    foreach ($logicalInt in $Device.ProcessOutputObjects) {
        # Find the corresponding interface object we created in the hardware step
        $interfaceToUpdate = $AllInterfaces | Where-Object { $_.Interface -eq $logicalInt[0] } | Select-Object -First 1

        if ($interfaceToUpdate) {
            # If it exists, UPDATE it with the logical details
            $interfaceToUpdate.Zone = $logicalInt[3]

            # Check for and process IP address information
            if ($logicalInt[6] -and $logicalInt[6].tolower() -ne "[n/a]" -and $logicalInt[6] -ne "N/A") {
                $interfaceToUpdate.IPAddress = ($logicalInt[6] -split "/")[0]
                $interfaceToUpdate.SubnetMask = ($logicalInt[6] -split "/")[1]
                $interfaceToUpdate.SwitchPortType = "Routed"

                if ($interfaceToUpdate.IPAddress -and $interfaceToUpdate.SubnetMask) {
                    $interfaceToUpdate.Cidr = (Get-IPv4Subnet -IPAddress $interfaceToUpdate.IPAddress -PrefixLength $interfaceToUpdate.SubnetMask).cidrid
                    if ($null -ne $interfaceToUpdate.Cidr) {
                        $NetworkObject = Create-NetworkObject
                        $NetworkObject.Cidr = $interfaceToUpdate.Cidr
                        $NetworkObject.Routedvlan = "vlan$($logicalInt[5])"
                        $Device.ArrayOfNetworks += $NetworkObject
                    }
                }
            }
        } else {
            # If it doesn't exist, it's a purely logical interface (e.g., vlan, loopback). Create a new object for it.
            $interfaceObject = Create-InterfaceObject
            $interfaceObject.Interface = $logicalInt[0]
            $interfaceObject.Zone = $logicalInt[3]
            $interfaceObject.shutdown = $false # Logical interfaces are assumed to be up unless otherwise specified

            if ($logicalInt[6] -and $logicalInt[6] -ne "[n/a]") {
                $interfaceObject.IPAddress = ($logicalInt[6] -split "/")[0]
                $interfaceObject.SubnetMask = ($logicalInt[6] -split "/")[1]
                $interfaceObject.SwitchPortType = "Routed"

                if ($interfaceObject.IPAddress -and $interfaceObject.SubnetMask) {
                    $interfaceObject.Cidr = (Get-IPv4Subnet -IPAddress $interfaceObject.IPAddress -PrefixLength $interfaceObject.SubnetMask).cidrid
                    if ($null -ne $interfaceObject.Cidr) {
                        $NetworkObject = Create-NetworkObject
                        $NetworkObject.Cidr = $interfaceObject.Cidr
                        $NetworkObject.Routedvlan = "vlan$($logicalInt[5])"
                        $Device.ArrayOfNetworks += $NetworkObject
                    }
                }
            }
            $AllInterfaces += $interfaceObject
        }
    }
    $Device.interfaces = $AllInterfaces
    return $Device
}





# Main function to parse the Palo Alto routing table text.
# Main function to parse the Palo Alto routing table text.
function Get-PaloAltoRouteFromText {
    param (
        [parameter(Mandatory=$true)]
        [string]$ShowRouteAllFile,

        [parameter(Mandatory=$true)]
        $Device
    )
    Add-HostDebugText -HostObject $Device "  -> Processing Palo Alto show route all..."
    if (-not (Test-Path -Path $ShowRouteAllFile -PathType Leaf)) {
        Add-HostDebugText -HostObject $Device "Error processing Palo Alto show route all from '$($ShowRouteAllFile)'." -BackgroundColor Red
        return $Device 
    }
    $ShowRouteText = Get-Content -Raw -Path $ShowRouteAllFile
    if ([string]::IsNullOrWhiteSpace($ShowRouteText) -or ($ShowRouteText | Select-String "(Invalid input|Command fail|Unknown command)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "File '$ShowRouteAllFile' contains invalid data or is empty." -BackgroundColor Red
        return $Device 
    }

    $AllRouteObjects = [System.Collections.Generic.List[object]]::new()
    $currentVRF = "default" 

    $lines = $ShowRouteText -split '\r?\n'

    foreach ($line in $lines) {
        # Capture the current Virtual Router (VRF) name
        if ($line -match 'VIRTUAL ROUTER: (.*) \(id \d+\)') {
            $currentVRF = $matches[1].Trim()
            continue 
        }

        # Basic check to see if it looks like a route line before splitting
        if ($line -notmatch '^\s*(\d{1,3}\.|\S+/)') {
            continue
        }

        # --- CORRECTED LOGIC: Tokenize the line instead of using a single complex regex ---
        $tokens = $line.Trim() -split '\s+'
        
        # A valid route must have at least the destination, nexthop, metric, and one flag.
        if ($tokens.Count -lt 4) {
            continue
        }

        $RouteObject = Create-RouteObject
        $RouteObject.VRF = $currentVRF

        # Handle routes where the nexthop is another VR (e.g., "vr VR-vsys1")
        if ($tokens[1] -eq 'vr') {
            $RouteObject.Subnet    = $tokens[0]
            $RouteObject.gateway   = "$($tokens[1]) $($tokens[2])" # Combine "vr" and its name
            $RouteObject.DISTANCE  = [int]$tokens[3]
            $startIndexForFlags = 4 # Flags start at the 5th token
        } else {
            # Handle standard routes with an IP nexthop
            $RouteObject.Subnet    = $tokens[0]
            $RouteObject.gateway   = $tokens[1]
            $RouteObject.DISTANCE  = [int]$tokens[2]
            $startIndexForFlags = 3 # Flags start at the 4th token
        }
        
        if ($RouteObject.Subnet -eq "0.0.0.0/0") {
            $RouteObject.defaultgateway = $true
        }

        $interface = $null
        $flagAndAgeTokens = @()

        # Reliably determine if an interface exists by checking the last token's pattern.
        if ($tokens[-1] -match '[\/\.]') {
            $interface = $tokens[-1]
            $flagAndAgeTokens = $tokens[$startIndexForFlags..($tokens.Count - 2)]
        } else {
            # NO interface exists (e.g., host route), so all remaining tokens are flags/age
            $flagAndAgeTokens = $tokens[$startIndexForFlags..($tokens.Count - 1)]
        }
        
        $RouteObject.interface = $interface
        
        $actualFlags = $flagAndAgeTokens | Where-Object { $_ -notmatch '^\d+$' }
        
        if ($actualFlags.Count -gt 0) {
            $primaryFlag = $actualFlags[-1]
            $RouteObject.RouteSubType = $primaryFlag

            switch ($primaryFlag[0]) {
                'S' { $RouteObject.RouteProtocol = "static" }
                'O' { $RouteObject.RouteProtocol = "OSPF" }
                'C' { $RouteObject.RouteProtocol = "connect" }
                'B' { $RouteObject.RouteProtocol = "BGP" }
                'R' { $RouteObject.RouteProtocol = "RIP" }
                'H' { $RouteObject.RouteProtocol = "host" }
                default { $RouteObject.RouteProtocol = "unknown" }
            }
        }
        
        $AllRouteObjects.Add($RouteObject)
    }

    Add-HostDebugText -HostObject $Device "Found $($AllRouteObjects.Count) Palo Alto routes."
    $device.RoutingTable = $AllRouteObjects
    return $device
}


