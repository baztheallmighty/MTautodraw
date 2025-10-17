#MTAudotDraw - FortiGate Module Stub
#Copyright (C) 2022  Myles Treadwell
#
#This is a stub file for processing FortiGate device outputs.
#It includes function skeletons for parsing the necessary commands
#to generate L2 and L3 network diagrams.

# This function calls all the other functions to process the files for a FortiGate device.
# Input: $hostid object containing file paths, $ArrayOfObjects for existing devices.
# Output: A populated $Device object.
function Process-FortiGateHostFiles {
    param (
        [parameter(Mandatory=$true)]
        $hostid,
        [parameter(Mandatory=$true)]
        $ArrayOfObjects
    )
    
    $Device = $null
    
    # 1. Create the base device object from the full configuration file first.
    if ($hostid.ShowFullConfig -and (Test-Path -Path $hostid.ShowFullConfig)) {
        $config = Get-Content -Path $hostid.ShowFullConfig -raw
        $Device = Get-ShowFullConfigurationFromText -Lconfig $config
        $Device.DeviceIdentifier = ($hostid.ShowFullConfig -replace "\.show full-configuration.*", '' -replace "^.*\\", '')
    } else {
        Write-Warning "Required 'show full-configuration' file not found for hostid '$($hostid.HOSTID)': $($hostid.ShowFullConfig)"
        return $null
    }

    # 2. Populate basic device info from 'get system status'. This is critical for getting the correct hostname.
    if ($hostid.SystemStatus -and (Test-Path -Path $hostid.SystemStatus)) {
         $Device = Get-SystemStatusFromText -SystemStatusFile $hostid.SystemStatus -Device $Device
    }

    if ($null -eq $Device -or [string]::IsNullOrEmpty($Device.hostname) -or $Device.hostname -like "*NoHostNameFound*") {
        Write-Warning "Could not find a valid hostname from config or status files. Skipping host."
        return $null
    }

    Add-HostDebugText -HostObject $Device "Processing FortiGate Host: $($Device.hostname)"

    # TODO: Add duplicate hostname check logic here.

    # 3. Update interface properties from 'get system interface' (Operational Status)
    if ($hostid.SystemInterface) {
        Add-HostDebugText -HostObject $Device "Processing 'get system interface': $($hostid.SystemInterface)"
        $Device = Get-SystemInterfaceFromText -SystemInterfaceFile $hostid.SystemInterface -Device $Device
    }

    # 4. Process LLDP neighbors for L2 diagramming.
    if ($hostid.LldpNeighborDetails) {
        Add-HostDebugText -HostObject $Device "Processing LLDP neighbors: $($hostid.LldpNeighborDetails)"
        $Device = Get-LldpNeighborsDetailsFromText -LldpDetailsFile $hostid.LldpNeighborDetails -Device $Device
    }

    # 5. Process ARP table for L2/L3 mapping.
    if ($hostid.ShowArp) {
        Add-HostDebugText -HostObject $Device "Processing ARP table: $($hostid.ShowArp)"
        $Device = Get-SystemArpFromText -SystemArpFile $hostid.ShowArp -Device $Device
    }

    # 6. Process the routing table for L3 diagramming.
    if ($hostid.ShowRoutingTable) {
        Add-HostDebugText -HostObject $Device "Processing routing table: $($hostid.ShowRoutingTable)"
        $Device = Get-RoutingTableFromText -RoutingTableFile $hostid.ShowRoutingTable -Device $Device
    }
    
    # 7. Process BGP neighbors if the file exists.
    if ($hostid.ShowBgpSummary) {
        Add-HostDebugText -HostObject $Device "Processing BGP summary: $($hostid.ShowBgpSummary)"
        $Device = Get-BgpSummaryFromText -BgpSummaryFile $hostid.ShowBgpSummary -Device $Device
    }

    # 8. Process OSPF neighbors if the file exists.
    if ($hostid.ShowOspfNeighbor) {
        Add-HostDebugText -HostObject $Device "Processing OSPF neighbors: $($hostid.ShowOspfNeighbor)"
        $Device = Get-OspfNeighborFromText -OspfNeighborFile $hostid.ShowOspfNeighbor -Device $Device
    }

    # TODO: Add any final processing steps, like linking routes to interfaces.
    
    return $Device
}

function Get-SystemStatusFromText {
    param (
        [parameter(Mandatory = $true)]
        $SystemStatusFile,
        $Device
    )

    Add-HostDebugText -HostObject $Device "Parsing 'get system status' file: $($SystemStatusFile)"
    
    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTemplate.FortiGateSystemStatus -ShowFile $SystemStatusFile -HostObject $Device
    
    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Error parsing 'get system status'." -BackgroundColor Red
        return $Device
    }

    $Status = $Device.ProcessOutputObjects
    
    # Set the primary hostname from this command, as it's the most reliable source.
    $Device.hostname = $Status[15] # HOSTNAME

    # Initialize the .Version object if it doesn't exist
    if ($null -eq $Device.Version) {
        $Device.Version = Create-ShowVersionObject
    }

    # Map the parsed data to the correct properties in the .Version object
    # FSM Index: 0=VERSION, 10=SERIAL_NUMBER, 15=HOSTNAME, 23=CLUSTER_UPTIME
    $Device.Version.OS = $Status[0]
    $Device.Version.Serial = @($Status[10]) # Serial is an array in the object definition
    $Device.Version.Hostname = $Status[15]
    $Device.Version.Uptime = $Status[23]
    
    Add-HostDebugText -HostObject $Device "Successfully parsed system status. Hostname set to: $($Device.hostname)"

    return $Device
}

function Get-SystemInterfaceFromText {
    param (
        [parameter(Mandatory = $true)]
        $SystemInterfaceFile,
        $Device
    )

    Add-HostDebugText -HostObject $Device "Parsing 'get system interface' file: $($SystemInterfaceFile)"

    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTemplate.FortiGateSystemInterface -ShowFile $SystemInterfaceFile -ReturnArray $true -HostObject $Device

    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Error parsing 'get system interface'." -BackgroundColor Red
        return $Device
    }

    foreach ($intData in $Device.ProcessOutputObjects) {
        $Interface = $Device.interfaces | Where-Object { $_.Interface -eq $intData[0] }
        if (-not $Interface) {
            $Interface = Create-InterfaceObject
            $Interface.Interface = $intData[0] # NAME
            $Device.interfaces += $Interface
        }
        
        # FSM Index: 4=IP, 5=NETMASK, 6=STATUS, 8=TYPE
        $Interface.IPAddress = $intData[4]
        $Interface.SubnetMask = $intData[5]
        $Interface.IntStatus = $intData[6]
        $Interface.SwitchPortType = $intData[8]

        # ✨ Added: Calculate CIDR, a required field in your object
        if ($Interface.IPAddress -and $Interface.SubnetMask -and $Interface.IPAddress -ne "0.0.0.0") {
            try {
                $Interface.Cidr = (Get-IPv4Subnet -IPAddress $Interface.IPAddress -SubnetMask $Interface.SubnetMask).CidrId
            }
            catch {
                Add-HostDebugText -HostObject $Device "Could not calculate CIDR for $($Interface.IPAddress)/$($Interface.SubnetMask)." -BackgroundColor Yellow
            }
        }
    }
    
    Add-HostDebugText -HostObject $Device "Processed $($Device.ProcessOutputObjects.Count) interfaces."

    return $Device
}


function Get-SystemArpFromText {
    param (
        [parameter(Mandatory = $true)]
        $SystemArpFile,
        $Device
    )
    
    Add-HostDebugText -HostObject $Device "Parsing 'get system arp' file: $($SystemArpFile)"

    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTemplate.FortiGateSystemArp -ShowFile $SystemArpFile -ReturnArray $true -HostObject $Device
    
    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Error parsing 'get system arp'." -BackgroundColor Red
        return $Device
    }

    $Device.IPArpEntries = foreach ($arp in $Device.ProcessOutputObjects) {
        $ArpObject = Create-ShowIPArpObject
        $ArpObject.ipaddress = $arp[0] # ADDRESS
        $ArpObject.AGE = $arp[1] # AGE
        $ArpObject.MAC = $arp[2] # MAC
        $ArpObject.INTERFACE = $arp[3] # INTERFACE
        $ArpObject
    }

    Add-HostDebugText -HostObject $Device "Found $($Device.IPArpEntries.Count) ARP entries."

    return $Device
}




function Get-BgpSummaryFromText {
    param (
        [parameter(Mandatory = $true)]
        $BgpSummaryFile,
        $Device
    )

    Add-HostDebugText -HostObject $Device "Parsing 'get router info bgp summary' file: $($BgpSummaryFile)"
    
    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTemplate.FortiGateBgpSummary -ShowFile $BgpSummaryFile -ReturnArray $true -HostObject $Device

    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Error parsing BGP summary." -BackgroundColor Red
        return $Device
    }

    # Your main object has a BGPNeighbors property. Let's assume you have a Create-BGPNeighborObject function.
    $Device.BGPNeighbors = foreach ($neighbor in $Device.ProcessOutputObjects) {
        $BgpObject = Create-BGPNeighborObject 
        
        # FSM Index: 0=BGP_NEIGH, 1=NEIGH_AS, 2=UP_DOWN, 3=STATE_PFXRCD
        # This mapping depends on your Create-BGPNeighborObject definition.
        # Assuming a structure similar to Cisco's.
        $BgpObject.DeviceID = $neighbor[0] # Mapping Neighbor IP to DeviceID
        $BgpObject.RemoteAS = $neighbor[1] # A property for Remote AS would be needed
        $BgpObject.State = $neighbor[3] # A property for State would be needed
        
        $BgpObject
    }

    Add-HostDebugText -HostObject $Device "Found $($Device.BGPNeighbors.Count) BGP neighbors."
    
    return $Device
}