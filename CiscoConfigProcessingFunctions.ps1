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


#This file contains all of the functions that process cisco config.



#This functions calls all the other functions to process all of the files for a cisco devices.
#Input: Hostid object.
#Output: $device object.
function Process-CiscoHostFiles{
        param (
		[parameter(Mandatory=$true)]
		$hostid,
        $ArrayOfObjects
    )
        $Device = $null
        # First, create the device object from the show run config file.
        if($hostid.showrun -and (Test-Path -Path $hostid.showrun)){
            $config = Get-Content -Path $hostid.showrun -raw
            $Device=Get-ShowRunFromText -Lconfig $config
            $Device.DeviceIdentifier=($hostid.showrun -replace "\.show run.*",'' -replace "^.*\\",'' -replace "\.show configuration.*",'' )
        }else{
            # We can't create an object to log to, so this warning will appear in the main thread's error stream.
            Write-host "File doesn't exist for hostid '$($hostid.HOSTID)': $($hostid.showrun)"
            return $null
        }



        if ($null -eq $Device -or [string]::IsNullOrEmpty($Device.hostname) -or $Device.hostname -like "*NoHostNameFound*") {
            Write-host "Can't find hostname in file skipping host: $($hostid.showrun)" -BackgroundColor red
            return $null
        }

        # Now that $Device is a valid object, we can begin logging.
        Add-HostDebugText -HostObject $Device "Processing Cisco Host: $($Device.hostname)"

        foreach ($ExistingDevice in $ArrayOfObjects){
            if($ExistingDevice.hostname -eq $Device.hostname){
                Add-HostDebugText -HostObject $Device "Hostname already exists $($ExistingDevice.hostname) - $($Device.hostname). This means you either have the same code twice in the folder or someone has named two devices the same. This script requries unquie hostnames." -BackgroundColor red
                Add-HostDebugText -HostObject $Device "Found problem at: $($hostid.HOSTID)" -BackgroundColor red
                Add-HostDebugText -HostObject $Device "Existing HostID's:$($ArrayOfHostIDs | ft HOSTID,showrun | out-string)"
                Add-HostDebugText -HostObject $Device "$($ArrayOfObjects|ft hostname,DeviceIdentifier| out-string)"
                if(!($SkipHostnameErrorCheck)){
                     Add-HostDebugText -HostObject $Device 'Exiting please manually fix this error.'  -BackgroundColor red
                     Start-CleanupAndExit
                }
            }
        }
        if($hostid.ShowVersion){
            Add-HostDebugText -HostObject $Device "Processing show version: $($hostid.ShowVersion)"
            $Device=Get-ShowVersionFromText -ShowVersionFile $hostid.ShowVersion -Device $Device
        }
        if($hostid.ShowCDPNeighborsDetails){ #CDP must be processed before LLDP.
            Add-HostDebugText -HostObject $Device "Processing show cdp:$($hostid.ShowCDPNeighborsDetails)"
            $Device=Get-CdpNeighborsFromText -CdpNeighborFile $hostid.ShowCDPNeighborsDetails -Device $Device
        }
        if($hostid.ShowLLDPNeighborsDetails){#CDP must be processed before LLDP.
            Add-HostDebugText -HostObject $Device "Processing show LLDP Details:$($hostid.ShowLLDPNeighborsDetails)"
            $Device=Get-ShowLLDPDetailsFromText -ShowLLDPDetailsFile $hostid.ShowLLDPNeighborsDetails -Device $Device -ShowLLDPFile $hostid.ShowLLDPNeighbors
        }
        if($hostid.ShowInterface){
            Add-HostDebugText -HostObject $Device "Processing Show Interface :$($hostid.ShowInterface)"
            $Device=Get-ShowInterfaceFromText -ShowInterfaceFile $hostid.ShowInterface -Device $Device
        }elseif($hostid.ShowIPInterfaceBrief){
            Add-HostDebugText -HostObject $Device "Processing Show ip Interface Brief:$($hostid.ShowIPInterfaceBrief)"
            $Device=Get-ShowIPInterfaceBriefFromText -ShowIPInterfaceBrief $hostid.ShowIPInterfaceBrief -Device $Device
        }else{
            #Do nothing
        }
        if($hostid.ShowInterfaceStatus){
            if($Device.version.type -eq "NXOS" -or !($hostid.ShowInterface) ){ #we don't need to run this for devices with show interface however we need it for NXOS.
                Add-HostDebugText -HostObject $Device "Processing Show Interface status:$($hostid.ShowInterfaceStatus)"
                $Device=Get-ShowInterfaceStatusFromText -ShowInterfaceStatusFile $hostid.ShowInterfaceStatus -Device $Device
            }
        }

        # Check if ANY BGP neighbor file property has been populated for this host
        if ($hostid.ShowIPBGPNeighbors -or $hostid.ShowIPBGPVPNv4Neighbors) {
           # Check the OS type determined from 'show version'
           if ($Device.version.type -eq "NXOS") {
               # --- NX-OS LOGIC ---
               Add-HostDebugText -HostObject $Device "Device is NX-OS. Checking NX-OS BGP file."
               if ($hostid.ShowIPBGPNeighbors -and (Test-FileHasValidData -FilePath $hostid.ShowIPBGPNeighbors)) {
                   Add-HostDebugText -HostObject $Device "Processing NX-OS BGP Neighbors: $($hostid.ShowIPBGPNeighbors)"
                   $Device = Get-BGPNeighborsNXOSFromText -BGPNeighborsFile $hostid.ShowIPBGPNeighbors -Device $Device
               }
               else {
                   Add-HostDebugText -HostObject $Device "NX-OS BGP file is not valid or was not found." -BackgroundColor Yellow
               }
           }
           else {
               # --- IOS/IOS-XE LOGIC ---
               Add-HostDebugText -HostObject $Device "Device is IOS/XE. Checking IOS BGP files."
               # Check the more specific VPNv4 neighbors file first for valid data
               if ($hostid.ShowIPBGPVPNv4Neighbors -and (Test-FileHasValidData -FilePath $hostid.ShowIPBGPVPNv4Neighbors)) {
                   Add-HostDebugText -HostObject $Device "Processing IOS BGP VPNv4 Neighbors: $($hostid.ShowIPBGPVPNv4Neighbors)"
                   $Device=Get-BGPNeighborsFromText -BGPNeighborsFile $hostid.ShowIPBGPVPNv4Neighbors -Device $Device
               }
               # If the VPNv4 file is invalid or missing, fall back to the standard neighbors file
               elseif ($hostid.ShowIPBGPNeighbors -and (Test-FileHasValidData -FilePath $hostid.ShowIPBGPNeighbors)) {
                   Add-HostDebugText -HostObject $Device "Processing IOS BGP Neighbors: $($hostid.ShowIPBGPNeighbors)"
                   $Device=Get-BGPNeighborsStandardFromText -BGPNeighborsFile $hostid.ShowIPBGPNeighbors -Device $Device
               }
               else {
                   Add-HostDebugText -HostObject $Device "No valid IOS BGP neighbor files found to process." -BackgroundColor Yellow
               }
           }
        }
        else {
           Add-HostDebugText -HostObject $Device "No BGP neighbor file properties were populated for this host." -BackgroundColor Yellow
        }
        # 2. FALLBACK: If no neighbors were found, use the summary file
        if ($device.BGPNeighbors.Count -eq 0 -and $hostid.ShowIPBGPSummary) {
           Add-HostDebugText -HostObject $Device "No valid BGP neighbor data found. Attempting fallback to summary file." -BackgroundColor Yellow
           if (Test-FileHasValidData -FilePath $hostid.ShowIPBGPSummary) {
               $Device = Get-BGPNeighborsFromSummary -BGPSummaryFile $hostid.ShowIPBGPSummary -Device $Device
           } else {
               Add-HostDebugText -HostObject $Device "BGP Summary file is also invalid, skipping." -BackgroundColor Red
           }
        }

        if($hostid.ShowSpanningTree){
           Add-HostDebugText -HostObject $Device "Processing Show Spanning Tree"
           $Device=Get-ShowSpanningTreeFromText -ShowSpanningTreeFile $hostid.ShowSpanningTree -Device $Device
        }
        if($hostid.ShowIPRoute -or $hostid.ShowIPRouteVRFstar){
           Add-HostDebugText -HostObject $Device "Processing Show ip route:$($hostid.ShowIPRoute)"
           $Device=Get-ShowIPRouteFromText -ShowIPRouteFile $hostid.ShowIPRoute -ShowIPRouteVRFstar $hostid.ShowIPRouteVRFstar -Device $Device
        }
        if($hostid.ShowIPArp){
           if($GDrawAprEntries){
               Add-HostDebugText -HostObject $Device "Processing Show ip Arp:$($hostid.ShowIPArp)"
               $Device=Get-ShowIPArpText -ShowIPArpFile $hostid.ShowIPArp -Device $Device
           }
        }

        if($hostid.ShowMacAddressTable -and $GDrawPortsWithMacs -ne 0){
           if($GDrawCDP){#don't process mac addresses as it's slow if we are not going to use them.
               Add-HostDebugText -HostObject $Device "Processing Show Mac Address Table:$($hostid.ShowMacAddressTable)"
               $Device=Get-ShowMacAddressTableFromText -ShowMacAddressTable $hostid.ShowMacAddressTable -Device $Device
           }
        }
    $Device = Update-LocalRoutesWithInterfaces -device $Device
    return $Device
}

#Process the show interfaces file.
#TODO:Complete this.
function Get-ShowInterfaceFromText(){
    param (
        [parameter(Mandatory=$true)]
        $ShowInterfaceFile,
        $Device
    )
    #Read the file into one big string
    $ShowInterfaceText = Get-Content -raw $ShowInterfaceFile
    [array]$AllInterfaces=@() #Array of interfaces to hand back to the host object.
    if(($ShowInterfaceText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:|LLDP is not enabled)").Matches.Success){
        Add-HostDebugText -HostObject $Device "$($ShowInterfaceText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty"  -BackgroundColor red
        return $device
    }
    if($Device.version.type -eq "NXOS"){
        #Start Python process with TextFSM to convert the Text to a Object
        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.NexusShowInterfaceTemplate -ShowFile $ShowInterfaceFile   -ReturnArray $true -HostObject $Device
        if($Device.ProcessOutputObjects -eq "ERROR"){
            Add-HostDebugText -HostObject $Device "Error with show ip arp on NXOS."
            return $device
        }
        if($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string"){
            $tempArray = @()
            $tempArray += ,$Device.ProcessOutputObjects
            $Device.ProcessOutputObjects = $tempArray
        }
        $UpdateOnly=$false #This is used to ensure we don't add duplicate interfaces due to naming differences between show run and show interface.
        foreach ($int in $Device.ProcessOutputObjects){
            $Interface = $Device.interfaces | where { $_.interface -eq $int[0] }
            if($Interface){#We already have the interface from show run. Just update some variables.
                $UpdateOnly=$true
                $Interface.IntStatus = $int[1] -replace "\s*\(.*",''
                $Interface.INTProtocolStatus = $int[2] -replace "\s*\(.*",'' -replace ",.*",''
                #Is the interface shutdown. Default is $false.
                if($Interface.IntStatus -eq "down" -or $Interface.INTProtocolStatus -eq "down"){
                    $Interface.shutdown = $true
                }
                $interface.macaddress = $int[4]
                $Interface.Duplex = $int[11]
                if($int[12] -eq "1000Mb/s"){
                    $Interface.Speed = "1000Mb/s"
                }elseif($int[12] -eq "1Gb/s"){
                    $Interface.Speed = "1000Mb/s"
                }elseif($int[12] -eq "100Mb/s"){
                    $Interface.Speed = "100Mb/s"
                }elseif($int[12] -eq "10Mb/s"){
                    $Interface.Speed = "10Mb/s"
                }elseif($int[12] -eq "10Gb/s"){
                    $Interface.Speed = "10Gb/s"
                }else{
                    $Interface.Speed = $int[12]
                }
                if($int[3]){
                    $Interface.HardwareType=$int[3]
                }
            }else{
                if($UpdateOnly){ #We are only updating. Skip. This should really never happen.
                    Add-HostDebugText -HostObject $Device "Tried to create a interface we can't find in show run skipping." -BackgroundColor red
                    continue
                }
                $Interface=Create-InterfaceObject
                $Interface.Interface = $int[0]
                $Interface.IntStatus = $int[1] -replace "administratively ",'' -replace "\s*\(.*",''
                $Interface.INTProtocolStatus = $int[2] -replace "\s*\(.*",'' -replace ",.*",''
                #Is the interface shutdown. Default is $false.
                if($Interface.IntStatus -eq "down" -or $Interface.INTProtocolStatus -eq "down"){
                    $Interface.shutdown = $true
                }

                $Interface.Description = $int[6]
                $Interface.IPAddress = $int[7] -replace "\/.*",''
                $Interface.SubnetMask = $int[7] -replace ".*\/",''
                if($Interface.IPAddress -and $Interface.SubnetMask){
                    $Interface.Cidr = (Get-IPv4Subnet -IPAddress $Interface.IPAddress -PrefixLength $Interface.SubnetMask).cidrid
                }
                $Interface.Duplex = $int[11]
                if($int[12] -eq "1000Mb/s"){
                    $Interface.Speed = "1000Mb/s"
                }elseif($int[12] -eq "1Gb/s"){
                    $Interface.Speed = "1000Mb/s"
                }elseif($int[12] -eq "100Mb/s"){
                    $Interface.Speed = "100Mb/s"
                }elseif($int[12] -eq "10Mb/s"){
                    $Interface.Speed = "10Mb/s"
                }elseif($int[12] -eq "10Gb/s"){
                    $Interface.Speed = "10Gb/s"
                }else{
                    $Interface.Speed = $int[12]
                }
                if($int[3]){
                    $Interface.HardwareType=$int[3]
                }
                if($int[19] -like "*802.1Q*" -or $Interface.IPAddress){
                    $Interface.RoutedVlan = $true
                }
                $interface.macaddress = $int[4]
                $AllInterfaces+=$interface
            }
        }
        if($UpdateOnly){
            return $device
        }else{
            $device.interfaces=$AllInterfaces
            return $device
        }
    }
#INTERFACE         #int[0]
#LINK_STATUS       #int[1]
#ADMIN_STATE       #int[2]
#HARDWARE_TYPE     #int[3]
#ADDRESS           #int[4]
#BIA               #int[5]
#DESCRIPTION       #int[6]
#IP_ADDRESS        #int[7]
#MTU               #int[8]
#MODE              #int[9]
#DUPLEX            #int[10]
#SPEED             #int[11]
#INPUT_PACKETS     #int[12]
#OUTPUT_PACKETS    #int[13]
#INPUT_ERRORS      #int[14]
#OUTPUT_ERRORS     #int[15]
#BANDWIDTH         #int[16]
#DELAY             #int[17]
#ENCAPSULATION     #int[18]
#LAST_LINK_FLAPPED #int[19]




    if ($Device.version.type -in @("IOS","XE-IOS")) {
        #Add-HostDebugText -HostObject $Device "This is a XE-IOS or IOS device"
        #Add-HostDebugText -HostObject $Device "Starting Python Processing with TextFSM"
        #Start Python process with TextFSM to convert the Text to a Object
        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.IOSShowInterfaceTemplate -ShowFile $ShowInterfaceFile   -ReturnArray $true -HostObject $Device
        if($Device.ProcessOutputObjects -eq "ERROR"){
            Add-HostDebugText -HostObject $Device "Error with show ip arp on IOS."
            return $device
        }
        if($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string"){
            $tempArray = @()
            $tempArray += ,$Device.ProcessOutputObjects
            $Device.ProcessOutputObjects = $tempArray
        }
        $UpdateOnly=$false #This is used to ensure we don't add duplicate interfaces due to naming differences between show run and show interface.
        foreach ($int in $Device.ProcessOutputObjects){

            $Interface = $Device.interfaces | where { $_.interface -eq $int[0] }
            if($Interface){#We already have the interface from show run. Just update some variables.
                $UpdateOnly=$true
                $Interface.IntStatus = $int[1] -replace "administratively ",'' -replace "\s*\(.*",''
                $Interface.INTProtocolStatus = $int[2] -replace "\s*\(.*",'' -replace ",.*",''
                #Is the interface shutdown. Default is $false.
                if($Interface.IntStatus -eq "down" -or $Interface.INTProtocolStatus -eq "down"){
                    $Interface.shutdown = $true
                }
                $interface.macaddress = $int[4]
                $Interface.Duplex = $int[11]
                if($int[12] -eq "1000Mb/s" -or $int[12] -eq "1000Mbps"){
                    $Interface.Speed = "1000Mb/s"
                }elseif($int[12] -eq "1Gb/s"){
                    $Interface.Speed = "1000Mb/s"
                }elseif($int[12] -eq "100Mb/s"){
                    $Interface.Speed = "100Mb/s"
                }elseif($int[12] -eq "10Mb/s"){
                    $Interface.Speed = "10Mb/s"
                }elseif($int[12] -eq "10Gb/s"){
                    $Interface.Speed = "10Gb/s"
                }else{
                    $Interface.Speed = $int[12]
                }
                if($int[12]){
                    $Interface.MediaType=$int[13]
                }
                if($int[3]){
                    $Interface.HardwareType=$int[3]
                }
            }else{
                if($UpdateOnly){ #We are only updating. Skip. This should really never happen.
                    Add-HostDebugText -HostObject $Device "Tried to create a interface we can't find in show run skipping."
                    continue
                }
                Add-HostDebugText -HostObject $Device "Creating Interface:$($int)"
                $Interface=Create-InterfaceObject
                $Interface.Interface = $int[0]
                $Interface.IntStatus = $int[1] -replace "administratively ",'' -replace "\s*\(.*",''
                $Interface.INTProtocolStatus = $int[2] -replace "\s*\(.*",'' -replace ",.*",''
                #Is the interface shutdown. Default is $false.
                if($Interface.IntStatus -eq "down" -or $Interface.INTProtocolStatus -eq "down"){
                    $Interface.shutdown = $true
                }

                $Interface.Description = $int[6]
                $Interface.IPAddress = $int[7] -replace "\/.*",''
                $Interface.SubnetMask = $int[7] -replace ".*\/",''
                if($Interface.IPAddress -and $Interface.SubnetMask){
                    $Interface.Cidr = (Get-IPv4Subnet -IPAddress $interfaceObject.IPAddress -PrefixLength $interfaceObject.SubnetMask).cidrid
                }
                $Interface.Duplex = $int[11]
                if($int[11] -eq "1000Mb/s"){
                    $Interface.Speed = "1000Mb/s"
                }elseif($int[12] -eq "1Gb/s"){
                    $Interface.Speed = "1000Mb/s"
                }elseif($int[12] -eq "100Mb/s"){
                    $Interface.Speed = "100Mb/s"
                }elseif($int[12] -eq "10Mb/s"){
                    $Interface.Speed = "10Mb/s"
                }elseif($int[12] -eq "10Gb/s"){
                    $Interface.Speed = "10Gb/s"
                }else{
                    $Interface.Speed = $int[12]
                }
                if($int[12]){
                    $Interface.MediaType=$int[13]
                }
                if($int[3]){
                    $Interface.HardwareType=$int[3]
                }
                if($int[19] -like "*802.1Q*" -or $Interface.IPAddress){
                    $Interface.RoutedVlan = $true
                }
                $interface.macaddress = $int[4]
                $AllInterfaces+=$interface
            }
        }
        if($UpdateOnly){
            return $device
        }else{
            $device.interfaces=$AllInterfaces
            return $device
        }
    }



#INTERFACE         = $int[0]
#LINK_STATUS       = $int[1]
#PROTOCOL_STATUS   = $int[2]
#HARDWARE_TYPE     = $int[3]
#ADDRESS           = $int[4]
#BIA               = $int[5]
#DESCRIPTION       = $int[6]
#IP_ADDRESS        = $int[7]
#MTU               = $int[8]
#DUPLEX            = $int[9]
#SPEED             = $int[10]
#MEDIA_TYPE        = $int[11]
#BANDWIDTH         = $int[12]
#DELAY             = $int[13]
#ENCAPSULATION     = $int[14]
#LAST_INPUT        = $int[15]
#LAST_OUTPUT       = $int[16]
#LAST_OUTPUT_HANG  = $int[17]
#QUEUE_STRATEGY    = $int[18]
#INPUT_RATE        = $int[19]
#OUTPUT_RATE       = $int[20]
#INPUT_PACKETS     = $int[21]
#OUTPUT_PACKETS    = $int[22]
#INPUT_ERRORS      = $int[23]
#CRC               = $int[24]
#ABORT             = $int[25]
#OUTPUT_ERRORS     = $int[26]
#$newObject| Add-Member -type NoteProperty -Name Interface -value $null                  #Interface number and type e.g Gi0/0/1
#$newObject| Add-Member -type NoteProperty -Name Description -value $null                #Interface description / port description
#$newObject| Add-Member -type NoteProperty -Name IPAddress -value $null                  #Ipaddress for routed interfaces
#$newObject| Add-Member -type NoteProperty -Name SubnetMask -value $null                 #SubnetMask for routed interfaces
#$newObject| Add-Member -type NoteProperty -Name Cidr -value $null                       #network cidr
#$newObject| Add-Member -type NoteProperty -Name SecondaryIPAddress -value $null         #SecondaryIpaddress for routed interfaces
#$newObject| Add-Member -type NoteProperty -Name SecondarySubnetMask -value $null        #SecondarySubnetMask for routed interfaces
#$newObject| Add-Member -type NoteProperty -Name SecondaryCidr -value $null              #Secondary network cidr
#$newObject| Add-Member -type NoteProperty -Name SwitchportMode -value $null             #switch port mode access,trunk,etc
#$newObject| Add-Member -type NoteProperty -Name SwitchportAccessVlan -value $null       #the access vlan
#$newObject| Add-Member -type NoteProperty -Name SwitchportTrunkVlan -value $null        #the trunk vlans
#$newObject| Add-Member -type NoteProperty -Name shutdown -value $null                   #Is this port shutdown
#$newObject| Add-Member -type NoteProperty -Name vrf -value $null                        #VRF this interface is part of
#$newObject| Add-Member -type NoteProperty -Name RoutedVlan -value $null                 #If this is a routed interfaces and it is a vlan the vlan number will live here
#$newObject| Add-Member -type NoteProperty -Name vpc -value $null                        #Is this part of a vpc
#$newObject| Add-Member -type NoteProperty -Name ChannelGroup -value $null               #is this part of a port channel
#$newObject| Add-Member -type NoteProperty -Name ChannelGroupMode -value $null           #What type of mode is the port channel in
#$newObject| Add-Member -type NoteProperty -Name NativeVlan -value $null                 #What is our native vlan
#$newObject| Add-Member -type NoteProperty -Name SpanningTreePortType -value $null       #The mode of spanning tree
#$newObject| Add-Member -type NoteProperty -Name bpdufilter -value $null                 #Is bpdufilter enabled
#$newObject| Add-Member -type NoteProperty -Name SwitchPortType -value $null             #Is this a routed or switched port
#$newObject| Add-Member -type NoteProperty -Name IntStatus -value $null                  #Interface status from show ip int brief or show interface
#$newObject| Add-Member -type NoteProperty -Name INTProtocolStatus -value $null          #Protocol status from show ip int brief or show interface
#$newObject| Add-Member -type NoteProperty -Name MacAddressArray -value $null            #All mac addresses obtained from show mac address-table
#$newObject| Add-Member -type NoteProperty -Name STRootInterfaceForVlans -value $null    #List of all the vlans this interface is root for in spanning tree.
#$newObject| Add-Member -type NoteProperty -Name STALTnInterfaceForVlans -value $null    #List of all the vlans this interface is ALT for in spanning tree.
#$newObject| Add-Member -type NoteProperty -Name STDesgnInterfaceForVlans -value $null   #List of all the vlans this interface is Desg for in spanning tree.
#$newObject| Add-Member -type NoteProperty -Name Speed -value $null                      #Interface speed
#$newObject| Add-Member -type NoteProperty -Name Duplex -value $null                     #Duplex of the interface
#$newObject| Add-Member -type NoteProperty -Name Zone -value $null                       #Zone of this interface. This is used for the ASA. This just gives extra information.

}



##Process the show version file
function Get-ShowLLDPNeighborsText(){
    param (
        [parameter(Mandatory=$true)]
        $ShowLLDPFile,
        $Device
    )
    #Read the file into one big string
    $ShowLLDPText = Get-Content -raw $ShowLLDPFile
    $AllLLDPDetailsObjects=@() #Array of routes(Create-RouteObject) that will be passed back to the host object.
    if(($ShowLLDPText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:|LLDP is not enabled)").Matches.Success){
        Add-HostDebugText -HostObject $Device "$($ShowLLDPText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty"  -BackgroundColor red
        return $device
    }

    if ($Device.version.type -in @("IOS","XE-IOS")) {
        #Add-HostDebugText -HostObject $Device "This is a  XE-IOS IOS device"
        #Add-HostDebugText -HostObject $Device "Starting Python Processing with TextFSM"
        #Start Python process with TextFSM to convert the Text to a Object
        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.XEIOSShowLLDPNeighborsDetailsTemplate -ShowFile $ShowLLDPFile  -ReturnArray $true -HostObject $Device
        if($Device.ProcessOutputObjects -eq "ERROR"){
            Add-HostDebugText -HostObject $Device "Error with show lldp neighbors on IOS.$($Device.ProcessOutputObjects)"
            return $device
        }
        # Fix for single neighbor results
        if($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string"){
            $tempArray = @()
            $tempArray += ,$Device.ProcessOutputObjects
            $Device.ProcessOutputObjects = $tempArray
        }
        foreach ($LLDPNeighbor in $Device.ProcessOutputObjects){
            if($GSkipCDPLLDPPhones){
                if(($LLDPNeighbor[2].trim()) -like "*T*"){
                    continue
                }
            }
            $LLDPObject=Create-LLDPNeighborObject
            $LLDPObject.Hostname=$LLDPNeighbor[0].trim()
            $LLDPObject.InterfaceLocalDevice=(Replace-InterfaceShortName -string $LLDPNeighbor[1] )
            $LLDPObject.InterfaceRemoteDevice=(Replace-InterfaceShortName -string $LLDPNeighbor[3] )
            if(($LLDPObject.InterfaceRemoteDevice -eq "") -or ($null -eq $LLDPObject.InterfaceRemoteDevice)){
                $LLDPObject.InterfaceRemoteDevice="Unknown Interface"
            }
            if($LLDPObject.Hostname -eq "" -or $LLDPObject.Hostname -eq "null"){
                $LLDPObject.Hostname=$LLDPObject.ChassisID
            }
            $LLDPObject.CAPABILITIES=$LLDPNeighbor[2].trim()
            $LLDPObject.PortID=(Replace-InterfaceShortName -string $LLDPNeighbor[3]).trim()
            #record that the interface has a LLDP nieghbor
            $TempInterface=$null
            $TempInterface=$device.interfaces | where { $_.interface -eq $LLDPObject.InterfaceLocalDevice}
            $TempInterface.HasLLDPNeighbor = $true
            if($TempInterface.HasCPDNieghbor){ #If we have a CDP nieghbor object already note it on this object. This is used so we don't draw duplicate objects with CDP and LLDP.
                $LLDPObject.HasCDPNeighborEntry=$true
            }
            $AllLLDPDetailsObjects+=$LLDPObject
        }

        $device.LLDPNeighbors=$AllLLDPDetailsObjects | sort -property @{Expression={[int]($_.InterfaceLocalDevice -replace '[a-zA-Z-]+','' -replace "/",'')}}
        return $device
    }
}


#Process the Show LLDP Details file
function Get-ShowLLDPDetailsFromText(){
    param (
        [parameter(Mandatory=$true)]
        $ShowLLDPDetailsFile,
        $Device,
        $ShowLLDPFile             #Optional fix for missing lldp neighbors
    )
    #Read the file into one big string
    $ShowLLDPDetailText = Get-Content -raw $ShowLLDPDetailsFile
    $AllLLDPDetailsObjects=@() #Array of routes(Create-RouteObject) that will be passed back to the host object.
    if(($ShowLLDPDetailText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:|LLDP is not enabled)").Matches.Success){
        Add-HostDebugText -HostObject $Device "$($ShowLLDPDetailText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty"  -BackgroundColor red
        return $device
    }
    if((!($ShowLLDPDetailText | Select-String "Local Intf").Matches.Success)){
        if($ShowLLDPFile){
            Add-HostDebugText -HostObject $Device "Processing show lldp neighbors because we don't have local interface in show lldp neighbors details Device"
            $Device=Get-ShowLLDPNeighborsText -ShowLLDPFile $ShowLLDPFile -Device $Device
            $DetailsProcessed=$true
            Add-HostDebugText -HostObject $Device "Finished Processing show lldp neighbors Back to show lldp neighbors details"
        }else{
            Add-HostDebugText -HostObject $Device "Could not find Local Intf in the config and we don't have a show lldp neighbors file." -BackgroundColor Magenta
            Add-HostDebugText -HostObject $Device "contains invalid data or is empty"  -BackgroundColor red
            return $device
        }
    }
    if ($Device.version.type -in @("IOS","XE-IOS")) {
        #Add-HostDebugText -HostObject $Device "This is a IOS or XR IOS device"
        #Add-HostDebugText -HostObject $Device "Starting Python Processing with TextFSM"
        #Start Python process with TextFSM to convert the Text to a Object
        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.IOSShowLLDPNeighborsDetailsTemplate -ShowFile $ShowLLDPDetailsFile -ReturnArray $true -HostObject $Device
        if($Device.ProcessOutputObjects -eq "ERROR"){
            Add-HostDebugText -HostObject $Device "Error with show ip route on Nexus routing."
            return $device
        }
        if($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string"){
            $tempArray = @()
            $tempArray += ,$Device.ProcessOutputObjects
            $Device.ProcessOutputObjects = $tempArray
        }
        foreach ($LLDPNeighbor in $Device.ProcessOutputObjects){
            $LLDPObject=$null
            if($GSkipCDPLLDPPhones){
                if(($LLDPNeighbor[5].trim()) -like "*Phone*"){
                    continue
                }
            }

            if($DetailsProcessed){#We have process details from show lldp neighbors and now we need to match against show lldp neighbors details. This is done because the local interface is missing in show lldp neighbors details.
                $TempLLDPNeighbor=$null
                #Find the hostname to match
                $TempHostname=$LLDPNeighbor[4].trim()
                if($null -eq $TempHostname -or $TempHostname -eq ""){ #If we have a blank name use the chassis name. Hopefully that will match.
                    $TempHostname=$LLDPNeighbor[1].trim()
                }
                $TempLLDPNeighbor=$device.LLDPNeighbors | where {  $TempHostname -like "*$($_.Hostname)*"  -and  $_.PortID -eq (Replace-InterfaceShortName -string $LLDPNeighbor[2])}
                if($TempLLDPNeighbor){
                    #Add-HostDebugText -HostObject $Device "Found device updating $($TempHostname): $(Replace-InterfaceShortName -string $LLDPNeighbor[2])"
                    $LLDPObject=$TempLLDPNeighbor
                }else{
                    #Add-HostDebugText -HostObject $Device "Unable to find neighbor $($LLDPNeighbor) -- $($TempHostname) :  $(Replace-InterfaceShortName -string $LLDPNeighbor[2]) in existing list$($device.LLDPNeighbors|ft hostname,PortID|out-string)"
                    continue
                }
            }else{
                $LLDPObject=Create-LLDPNeighborObject
                $LLDPObject.Hostname=$LLDPNeighbor[4].trim()#The replace is used to remove domain names that are part of the name of the device. This helps matching.
                $LLDPObject.CAPABILITIES=$LLDPNeighbor[6].trim()
                $LLDPObject.InterfaceLocalDevice=(Replace-InterfaceShortName -string $LLDPNeighbor[0] )
                $LLDPObject.InterfaceRemoteDevice=(Replace-InterfaceShortName -string $LLDPNeighbor[2])
            }

            $LLDPObject.SystemDescription=$LLDPNeighbor[5].trim()
            $LLDPObject.ChassisID=$LLDPNeighbor[1].trim()
            #TODO: Fix junos to cisco naming. Probably get ge-0/1/1.0 which should be ge-0/1/1. Convention is to remove all .0 from junos interfaces.
            if(($LLDPObject.InterfaceRemoteDevice -eq "") -or ($null -eq $LLDPObject.InterfaceRemoteDevice)){
                $LLDPObject.InterfaceRemoteDevice="Unknown Interface"
            }
            $LLDPObject.NeighborInterfaceDescription=$LLDPNeighbor[3].trim()
            $LLDPObject.ManagementIP=$LLDPNeighbor[7].trim()
            $LLDPObject.VLAN=$LLDPNeighbor[8].trim()
            $LLDPObject.SERIAL=$LLDPNeighbor[10].trim()
            $LLDPObject.ParentObject=$device.hostname
            if($LLDPObject.Hostname -eq "" -or $LLDPObject.Hostname -eq "null"){
                $LLDPObject.Hostname=$LLDPObject.ChassisID
            }
            #record that the interface has a LLDP nieghbor
            $TempInterface=$null
            $TempInterface=$device.interfaces | where { $_.interface -eq $LLDPObject.InterfaceLocalDevice}
            $TempInterface.HasLLDPNeighbor = $true
            if($TempInterface.HasCPDNieghbor){ #If we have a CDP nieghbor object already note it on this object. This is used so we don't draw duplicate objects with CDP and LLDP.
                $LLDPObject.HasCDPNeighborEntry=$true
            }
            $AllLLDPDetailsObjects+=$LLDPObject
        }
        $device.LLDPNeighbors=$AllLLDPDetailsObjects | sort -property @{Expression={[int]($_.InterfaceLocalDevice -replace '[a-zA-Z-]+','' -replace "/",'')}}
        return $device
    }elseif ($Device.version.type -eq "NXOS"){
        #Add-HostDebugText -HostObject $Device "This is a Nexus device"
        Add-HostDebugText -HostObject $Device "Replacing Vlan ID: not advertised with Vlan ID: 0. This is a work around that needs fixing up later on"
        (get-content -raw $ShowLLDPDetailsFile) -replace "Vlan ID: not advertised","Vlan ID: 0" | set-content $ShowLLDPDetailsFile
        #Add-HostDebugText -HostObject $Device "Starting Python Processing with TextFSM"
        #Start Python process with TextFSM to convert the Text to a Object
        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.NexusShowLLDPNeighborsDetailsTemplate -ShowFile $ShowLLDPDetailsFile  -ReturnArray $true -HostObject $Device
        if($Device.ProcessOutputObjects -eq "ERROR"){
            Add-HostDebugText -HostObject $Device "Error with show ip route on Nexus routing."
            return $device
        }
        if($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string"){
            $tempArray = @()
            $tempArray += ,$Device.ProcessOutputObjects
            $Device.ProcessOutputObjects = $tempArray
        }
        foreach ($LLDPNeighbor in $Device.ProcessOutputObjects){
            $LLDPObject=Create-LLDPNeighborObject
            $LLDPObject.SystemDescription=$LLDPNeighbor[5].trim()
            if($GSkipCDPLLDPPhones){
                if(($LLDPObject.SystemDescription) -like "*Phone*"){
                    continue
                }
            }
            $LLDPObject.Hostname=$LLDPNeighbor[0].trim() #The replace is used to remove domain names that are part of the name of the device. This helps matching.
            $LLDPObject.InterfaceLocalDevice= (Replace-InterfaceShortName -string $LLDPNeighbor[1] )
            $LLDPObject.InterfaceRemoteDevice=(Replace-InterfaceShortName -string $LLDPNeighbor[2] )
            $LLDPObject.ChassisID=$LLDPNeighbor[3].trim()
            $LLDPObject.ManagementIP=$LLDPNeighbor[4].trim()
            $LLDPObject.CAPABILITIES=$LLDPNeighbor[6].trim()
            $LLDPObject.VLAN=$LLDPNeighbor[7].trim()
            if($LLDPObject.Hostname -eq "" -or $LLDPObject.Hostname -eq "null"){
                $LLDPObject.Hostname=$LLDPObject.ChassisID
            }
            #note that the interface has a LLDP nieghbor
            $TempInterface=$device.interfaces | where { $_.interface -eq $LLDPObject.InterfaceLocalDevice}
            $TempInterface.HasLLDPNeighbor = $true
            if($TempInterface.HasCPDNieghbor){ #If we have a CDP nieghbor object already note it on this object. This is used so we don't draw duplicate objects with CDP and LLDP.
                $LLDPObject.HasCDPNeighborEntry=$true
            }
            $LLDPObject.ParentObject=$device.hostname
            #note that the interface has a LLDP nieghbor
            #$device.interfaces | where { $_.interface -eq $LLDPObject.InterfaceLocalDevice} | % { $_.HasLLDPNeighbor = $true}
            $AllLLDPDetailsObjects+=$LLDPObject
        }
        $device.LLDPNeighbors=$AllLLDPDetailsObjects | sort -property @{Expression={[int]($_.InterfaceLocalDevice -replace '[a-zA-Z-]+','' -replace "/",'')}}
        return $device
    }else{
        Add-HostDebugText -HostObject $Device "Unknown device type"
    }
    Add-HostDebugText -HostObject $Device "Filed to process LLDP Details:" -BackgroundColor red
    Add-HostDebugText -HostObject $Device $ShowLLDPDetailText
    return $device
}


#Process the show version file
function Get-ShowVersionFromText(){
    param (
        [parameter(Mandatory=$true)]
        $ShowVersionFile,
        $Device
    )
    #Read the file into one big string
    $ShowVersionText = Get-Content -raw $ShowVersionFile
    if(($ShowVersionText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:|LLDP is not enabled)").Matches.Success){
        Add-HostDebugText -HostObject $Device "$($ShowVersionText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty"  -BackgroundColor red
        return $device
    }
    if(($ShowVersionText | Select-String "Cisco IOS Software").Matches.Success){
        #Add-HostDebugText -HostObject $Device "This is a IOS or XR IOS device"
        #Add-HostDebugText -HostObject $Device "Starting Python Processing with TextFSM"
        #Start Python process with TextFSM to convert the Text to a Object
        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.IOSShowVersionTemplate -ShowFile $ShowVersionFile -HostObject $Device
        if($Device.ProcessOutputObjects -eq "ERROR"){
            Add-HostDebugText -HostObject $Device "Error with show version on IOS."
            return $device
        }

        $VersionObject=Create-ShowVersionObject
        $VersionObject.OS                =  $Device.ProcessOutputObjects[0]
        $VersionObject.ROMMON            =  $Device.ProcessOutputObjects[1]
        $VersionObject.Hostname          =  $Device.ProcessOutputObjects[2]
        $VersionObject.Uptime            =  $Device.ProcessOutputObjects[3]
        $VersionObject.UptimeYear        =  $Device.ProcessOutputObjects[4]
        $VersionObject.UptimeWeeks       =  $Device.ProcessOutputObjects[5]
        $VersionObject.UptimeDays        =  $Device.ProcessOutputObjects[6]
        $VersionObject.UpdateHours       =  $Device.ProcessOutputObjects[7]
        $VersionObject.UptimeMinutes     =  $Device.ProcessOutputObjects[8]
        $VersionObject.ReasonForRelod    =  $Device.ProcessOutputObjects[9]
        $VersionObject.Image             =  $Device.ProcessOutputObjects[10]
        $VersionObject.Hardware          =  $Device.ProcessOutputObjects[11] | % { $_ }
        $VersionObject.Serial            =  $Device.ProcessOutputObjects[12] | % { $_ }
        $VersionObject.ConfigRegister    =  $Device.ProcessOutputObjects[13]
        $VersionObject.MacAddressArray   =  $Device.ProcessOutputObjects[14] | % { $_ }
        $VersionObject.LastRestarted     =  $Device.ProcessOutputObjects[15]
        if(($ShowVersionText | Select-String "IOS-XE").Matches.Success){
            Add-HostDebugText -HostObject $Device "Device Type:XE-IOS"
            $VersionObject.type              =  "XE-IOS"
        }else{
            Add-HostDebugText -HostObject $Device "Device Type:IOS"
            $VersionObject.type              =  "IOS"
        }
        $device.Version=$VersionObject
        return $device
    }
    if(($ShowVersionText | Select-String "Cisco Nexus Operating System").Matches.Success){
        #Add-HostDebugText -HostObject $Device "This is a NXOS device"
        #Add-HostDebugText -HostObject $Device "Starting Python Processing with TextFSM"
        #Start Python process with TextFSM to convert the Text to a Object
        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.NexusShowVersionTemplate -ShowFile $ShowVersionFile -HostObject $Device
        if($Device.ProcessOutputObjects -eq "ERROR"){
            Add-HostDebugText -HostObject $Device "Error with show version on NXOS."
            return $device
        }
        $VersionObject=Create-ShowVersionObject
        $VersionObject.Uptime            =  $Device.ProcessOutputObjects[0]
        $VersionObject.ReasonForRelod    =  $Device.ProcessOutputObjects[1]
        $VersionObject.OS                =  $Device.ProcessOutputObjects[2]
        $VersionObject.Image             =  $Device.ProcessOutputObjects[3]
        $VersionObject.Hardware          =  $Device.ProcessOutputObjects[4]
        $VersionObject.Hostname          =  $Device.ProcessOutputObjects[5]
        $VersionObject.Serial            =  $Device.ProcessOutputObjects[6]
        $VersionObject.type              =  "NXOS"
        $device.Version=$VersionObject
        return $device
    }
}


function Get-ShowMacAddressTableFromText(){
    param (
        [parameter(Mandatory=$true)]
        $ShowMacAddressTable,
        $Device
    )
    $ShowMacAddressTableText = Get-Content -raw $ShowMacAddressTable
    if(($ShowMacAddressTableText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:)").Matches.Success){
        Add-HostDebugText -HostObject $Device "$($ShowMacAddressTableText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty"  -BackgroundColor red

        return $device
    }
    $TypeOfDevice=$null
    if( ($ShowMacAddressTableText| Select-String "vlan\s*Mac\s*Address\s*Type\s*Ports").Matches.Success -or ($ShowMacAddressTableText| Select-String "vlan\s*mac\s*address\s*type\s*learn").Matches.Success){
        $TypeOfDevice="IOS"
    }
    if(($ShowMacAddressTableText| Select-String "primary\s*entry\,\s*G\s*\-\s*Gateway\s*MAC,\s*\(R\)\s*\-\s*Routed\s*MAC").Matches.Success){
        $TypeOfDevice="Nexus"
    }
    if(($ShowMacAddressTableText| Select-String "Unicast Entries").Matches.Success){
        $TypeOfDevice="IOSX"
        #Remove Multicast entries
        $ShowMacAddressTableText = $ShowMacAddressTableText -replace "(?smi)Multicast Entries.*",''
        $ShowMacAddressTableText = $ShowMacAddressTableText -replace ".*?igmp.*",''
    }
    if($null -eq $TypeOfDevice){
        Add-HostDebugText -HostObject $Device "---------No device Type--------"  -BackgroundColor red
        Add-HostDebugText -HostObject $Device "$($ShowMacAddressTableText)"  -BackgroundColor red
        return $device
    }
    if($TypeOfDevice -eq "IOS"){
        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.IOSShowMacAddressTableTemplate -ShowFile $ShowMacAddressTable -ReturnArray $true -HostObject $Device
        if($Device.ProcessOutputObjects -eq "ERROR"){
            Add-HostDebugText -HostObject $Device "Error with show mac address-table on IOS processing."
            return $device
        }
        if($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string"){
            $tempArray = @()
            $tempArray += ,$Device.ProcessOutputObjects
            $Device.ProcessOutputObjects = $tempArray
        }
        foreach ($Mac in $Device.ProcessOutputObjects){
            $DeviceInterface=$null
            $MacAddressobject=Create-MacAddressObject
            if($Mac[3] -eq $null){

                continue
            }
            if($Mac[3] -eq ""){

                continue
            }
            if("3333.0000.000d" -eq $MacAddressobject.MacAddress){ #IPv6 all-nodes multicast. skip this.
                continue
            }
            if($Mac[3] -eq "CPU" -or $Mac[3] -eq "switch" -or $Mac[3] -eq "sup-Ethernet1(R)"){

                continue #Skip switch and CPU interfaces.
            }
            $MacAddressobject.Interface = (Replace-InterfaceShortName -string $Mac[3] )

            if(!(Check-InterfaceType -string $MacAddressobject.Interface)){

                continue #Skip if we don't have a valid interface.
            }
            $MacAddressobject.MacAddress = ($Mac[0]).trim()

            $MacAddressobject.type = ($Mac[1]).trim()
            $MacAddressobject.vlan = ($Mac[2]).trim()
            $MacInOtherFormat=($Mac[0] -replace "\.",'').insert(2,":").insert(5,":").insert(8,":").insert(11,":").insert(14,":")
            if($GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,5)]){
                $MacAddressobject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,5)]
            }elseif($GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,8)]){
                $MacAddressobject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,8)]
            }else{
                $MacAddressobject.VendorCompanyName = "UNKNOWN Vendor"
            }
            $DeviceInterface = $device.interfaces | where { $_.interface -eq $MacAddressobject.Interface }
            if($null -eq $DeviceInterface){
                Add-HostDebugText -HostObject $Device "We could not find the interface $($MacAddressobject) INTERFACE $($MacAddressobject.Interface) on the switch. Replace-InterfaceShortName might be the problem." -BackgroundColor red
                continue
            }
            $DeviceInterface.MacAddressArray+=,$MacAddressobject
        }
    }elseif($TypeOfDevice -eq "Nexus"){
        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.NexusShowMacAddressTableTemplate -ShowFile $ShowMacAddressTable -ReturnArray $true -HostObject $Device
        if($Device.ProcessOutputObjects -eq "ERROR"){
            Add-HostDebugText -HostObject $Device "Error with show mac address-table on IOS processing."
            return $device
        }
        if($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string"){
            $tempArray = @()
            $tempArray += ,$Device.ProcessOutputObjects
            $Device.ProcessOutputObjects = $tempArray
        }
        foreach ($Mac in $Device.ProcessOutputObjects){
            $DeviceInterface=$null
            $MacAddressobject=Create-MacAddressObject
            if($Mac[6] -eq $null){

                continue
            }
            if($Mac[6] -eq ""){

                continue
            }
            if($Mac[6] -eq "CPU" -or $Mac[6] -eq "switch" -or $Mac[6] -eq "sup-Ethernet1(R)"){

                continue #Skip switch and CPU interfaces.
            }
            $MacAddressobject.MacAddress = ($Mac[1]).trim()
            if("3333.0000.000d" -eq $MacAddressobject.MacAddress){ #IPv6 all-nodes multicast. skip this.
                continue
            }
            $MacAddressobject.Interface = ( Replace-InterfaceShortName -string $Mac[6])
            if($MacAddressobject.Interface -eq "CPU" -or $MacAddressobject.Interface -eq "switch" -or $MacAddressobject.Interface -eq "sup-Ethernet1(R)"){

                continue #Skip switch and CPU interfaces.
            }
            if(!(Check-InterfaceType -string $MacAddressobject.Interface)){

                continue #Skip if we don't have a valid interface.
            }

            $MacAddressobject.type = ($Mac[2]).trim()
            $MacAddressobject.vlan = ($Mac[0]).trim()
            $MacInOtherFormat=($MacAddressobject.MacAddress -replace "\.",'').insert(2,":").insert(5,":").insert(8,":").insert(11,":").insert(14,":")
            if($GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,5)]){
                $MacAddressobject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,5)]
            }elseif($GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,8)]){
                $MacAddressobject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,8)]
            }else{
                $MacAddressobject.VendorCompanyName = "UNKNWON Not Found in database"
            }
            $DeviceInterface = $device.interfaces | where { $_.interface -eq $MacAddressobject.Interface }
            if($null -eq $DeviceInterface){
                Add-HostDebugText -HostObject $Device "We could not find the interface $($MacAddressobject) on the switch. Replace-InterfaceShortName might be the problem." -BackgroundColor red
                continue
            }
            $DeviceInterface.MacAddressArray+=,$MacAddressobject
        }
    }elseif($TypeOfDevice -eq "IOSX"){
        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.XEIOSShowMacAddressTableTemplate -ShowFile $ShowMacAddressTable -ReturnArray $true -HostObject $Device
        if($Device.ProcessOutputObjects -eq "ERROR"){
            Add-HostDebugText -HostObject $Device "Error with show mac address-table on IOS processing."
            return $device
        }
        if($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string"){
            $tempArray = @()
            $tempArray += ,$Device.ProcessOutputObjects
            $Device.ProcessOutputObjects = $tempArray
        }
        foreach ($Mac in $Device.ProcessOutputObjects){
            $DeviceInterface=$null
            $MacAddressobject=Create-MacAddressObject
            if($Mac[4] -eq $null){

                continue
            }
            if($Mac[4] -eq ""){

                continue
            }
            if($Mac[4] -eq "CPU" -or $Mac[4] -eq "switch" -or $Mac[4] -eq "sup-Ethernet1(R)"){

                continue #Skip switch and CPU interfaces.
            }
            $MacAddressobject.MacAddress = ($Mac[1]).trim()
            if("3333.0000.000d" -eq $MacAddressobject.MacAddress){ #IPv6 all-nodes multicast. skip this.
                continue
            }
            $MacAddressobject.Interface = (Replace-InterfaceShortName -string $Mac[4] )
            if($MacAddressobject.Interface -eq "CPU" -or $MacAddressobject.Interface -eq "switch" -or $MacAddressobject.Interface -eq "sup-Ethernet1(R)"){

                continue #Skip switch and CPU interfaces.
            }

            $MacAddressobject.type = ($Mac[2]).trim()
            $MacAddressobject.vlan = ($Mac[0]).trim()
            $MacAddressobject.protocols= ($Mac[3]).trim()
            $MacInOtherFormat=($MacAddressobject.MacAddress -replace "\.",'').insert(2,":").insert(5,":").insert(8,":").insert(11,":").insert(14,":")
            if($GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,5)]){
                $MacAddressobject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,5)]
            }elseif($GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,8)]){
                $MacAddressobject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,8)]
            }else{
                $MacAddressobject.VendorCompanyName = "UNKNWON Not Found in database"
            }
            $DeviceInterface = $device.interfaces | where { $_.interface -eq $MacAddressobject.Interface }
            if($null -eq $DeviceInterface){
                Add-HostDebugText -HostObject $Device "We could not find the interface $($MacAddressobject) on the switch. Replace-InterfaceShortName might be the problem." -BackgroundColor red
                continue
            }
            $DeviceInterface.MacAddressArray+=,$MacAddressobject
        }
    }
    else{
        Add-HostDebugText -HostObject $Device "MAC address parsing not yet implemented"
    }
    return $device
}


function Get-ShowIPInterfaceBriefFromText(){
    param (
        [parameter(Mandatory=$true)]
        $ShowIPInterfaceBriefFile,
        $Device
    )
    #Read the file into one big string
    $ShowIPInterfaceBriefText = Get-Content -raw $ShowIPInterfaceBriefFile
    if(($ShowIPInterfaceBriefText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:|LLDP is not enabled)").Matches.Success){
        Add-HostDebugText -HostObject $Device "$($ShowIPInterfaceBriefText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty"  -BackgroundColor red
        return $device
    }
    if ($Device.version.type -in @("IOS","XE-IOS")) {
        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.IOSShowIPIntBrief -ShowFile $ShowIPInterfaceBriefFile -ReturnArray $true -HostObject $Device
        if($Device.ProcessOutputObjects -eq "ERROR"){
            Add-HostDebugText -HostObject $Device "Error with Show IP Int Brief on IOS or XE-IOS."
            return $device
        }
        if($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string"){
            $tempArray = @()
            $tempArray += ,$Device.ProcessOutputObjects
            $Device.ProcessOutputObjects = $tempArray
        }
        foreach ($int in $Device.ProcessOutputObjects){
            $int[0]=Replace-InterfaceShortName -string $int[0]
            $Interface = $Device.interfaces | where { $_.interface -eq $int[0]} | select -first 1
            if($Interface){
                $Interface.IntStatus=$int[2]
                $Interface.INTProtocolStatus=$int[3]
            }else{
                Add-HostDebugText -HostObject $Device "$($int) not found in list of interfaces $($int[0]). Replace-InterfaceShortName is probably the cause.1"
            }
        }
        return $device
    }elseif ($Device.version.type -eq "NXOS"){
        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.NexusShowIPIntBrief -ShowFile $ShowIPInterfaceBriefFile -ReturnArray $true -HostObject $Device
        if($Device.ProcessOutputObjects -eq "ERROR"){
            Add-HostDebugText -HostObject $Device "Error with Show IP Int Brief on NXOS."
            return $device
        }
        foreach ($int in $Device.ProcessOutputObjects){
            $int[0]=Replace-InterfaceShortName -string $int[0]
            $Interface = $Device.interfaces | where { $_.interface -eq $int[1]} | select -first 1
            if($Interface){
                $Interface.IntStatus=$int[3]
                $Interface.INTProtocolStatus=$int[5]
            }else{
                Add-HostDebugText -HostObject $Device "$($int) not found in list of interfaces. Replace-InterfaceShortName is probably the cause.2"
            }
        }
        return $device
    }else{
        Add-HostDebugText -HostObject $Device "Unknown device type"
    }
    Add-HostDebugText -HostObject $Device "Filed to process ShowIPInterfaceBriefFile Details:" -BackgroundColor red
    Add-HostDebugText -HostObject $Device $ShowIPInterfaceBriefText
    return $device
}

#TODO: Replace with TextFSM and ensure that media type comes from this. We can't get media type from show interfaces so it needs to come from here.
function Get-ShowInterfaceStatusFromText(){
    param (
        [parameter(Mandatory=$true)]
        $ShowInterfaceStatusFile,
        $Device
    )
    $ShowInterfaceStatusText = Get-Content -raw $ShowInterfaceStatusFile
    #Invalid data in file or file empty
    if(($ShowInterfaceStatusText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand)").Matches.Success){
        Add-HostDebugText -HostObject $Device "$($ShowInterfaceStatusText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty: $($ShowInterfaceStatusText)"  -BackgroundColor  red
        return $device
    }
    if ($Device.version.type -in @("IOS","XE-IOS")) {
        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.IOSShowInterfaceStatus -ShowFile $ShowInterfaceStatusFile -ReturnArray $true -HostObject $Device
        if($Device.ProcessOutputObjects -eq "ERROR"){
            Add-HostDebugText -HostObject $Device "Error with Show Interface status IOS or XE-IOS."
            return $device
        }
        if($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string"){
            $tempArray = @()
            $tempArray += ,$Device.ProcessOutputObjects
            $Device.ProcessOutputObjects = $tempArray
        }
        foreach ($int in $Device.ProcessOutputObjects){
            $int[0]=Replace-InterfaceShortName -string $int[0]
            $Interface = $Device.interfaces | where { $_.interface -eq $int[0]} | select -first 1
            if($Interface){
                if($int[2] -eq "connected"){
                    $Interface.IntStatus="Up"
                }elseif(($int[2] | Select-String "xcvrAbsen|sfpAbsent").Matches.Success){
                    $Interface.IntStatus="xcvrAbsen"
                }else{
                    $Interface.IntStatus="Down"
                }
                if($int[6] -ne "--"){
                    $Interface.MediaType=$int[6]
                }
            }else{
                Add-HostDebugText -HostObject $Device "$($int) not found in list of interfaces $($int[0]). Replace-InterfaceShortName is probably the cause."
            }
        }

        #PORT     $int[0]
        #NAME     $int[1]
        #STATUS   $int[2]
        #VLAN     $int[3]
        #DUPLEX   $int[4]
        #SPEED    $int[5]
        #TYPE     $int[6]
        #FC_MODE  $int[7]
    }elseif ($Device.version.type -eq "NXOS"){
        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.NexusShowInterfaceStatus -ShowFile $ShowInterfaceStatusFile -ReturnArray $true -HostObject $Device
        if($Device.ProcessOutputObjects -eq "ERROR"){
            Add-HostDebugText -HostObject $Device "Error with Show Interface status NXOS."
            return $device
        }
        foreach ($int in $Device.ProcessOutputObjects){
            $int[0]=Replace-InterfaceShortName -string $int[0]
            $Interface = $Device.interfaces | where { $_.interface -eq $int[0]} | select -first 1
            if($Interface){
                if($int[2] -eq "connected"){
                    $Interface.IntStatus="Up"
                }elseif(($int[2] | Select-String "xcvrAbsen|sfpAbsent").Matches.Success){
                    $Interface.IntStatus="xcvrAbsen"
                }else{
                    $Interface.IntStatus="Down"
                }
                if($int[6] -ne "--"){
                    $Interface.MediaType=$int[6]
                }
            }else{
                Add-HostDebugText -HostObject $Device "$($int) not found in list of interfaces $($int[0]). Replace-InterfaceShortName is probably the cause."
            }
        }
    #PORT    $int[0]
    #NAME    $int[1]
    #STATUS  $int[2]
    #VLAN    $int[3]
    #DUPLEX  $int[4]
    #SPEED   $int[5]
    #TYPE    $int[6]

    }else{
        Add-HostDebugText -HostObject $Device "Unknown device type"

    }
return $Device
}




function Get-CdpNeighborsFromText(){
    param (
        [parameter(Mandatory=$true)]
        $CdpNeighborFile,
        $device
    )

    #Read the file into one big string
    $ShowCdpNeighborText = Get-Content -raw $CdpNeighborFile
    $ArrayOfNeighborObjects=@()
    if(($ShowCdpNeighborText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:|LLDP is not enabled)").Matches.Success){
        Add-HostDebugText -HostObject $Device "$($ShowCdpNeighborText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty"  -BackgroundColor red
        return $device
    }
    if ($Device.version.type -in @("IOS","XE-IOS")) {
        #Add-HostDebugText -HostObject $Device "This is a  NXOS device"
        #Add-HostDebugText -HostObject $Device "Starting Python Processing with TextFSM"
        #Start Python process with TextFSM to convert the Text to a Object

        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.IOSShowCDPNeighborsDetailsTemplate -ShowFile $CdpNeighborFile -ReturnArray $true -HostObject $Device
        if($Device.ProcessOutputObjects -eq "ERROR"){
            Add-HostDebugText -HostObject $Device "Error with show cdp neighbors details on IOS or XE-IOS."
            return $device
        }
        if($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string"){
            $tempArray = @()
            $tempArray += ,$Device.ProcessOutputObjects
            $Device.ProcessOutputObjects = $tempArray
        }
        #We only have 1 CDP neighbor so and it doesn't come back as array.
        #Convert it to an array of arrays.
        if($Device.ProcessOutputObjects[0].GetType().name -eq "string"){
            $array=@()
            $array += ,$Device.ProcessOutputObjects
            $Device.ProcessOutputObjects=$array
        }
        foreach ( $neighbor in $Device.ProcessOutputObjects){

            if($GSkipCDPLLDPPhones){
                if($neighbor[6] -like "*phone*" ){
                    continue
                }
            }
            $NeighborObject=Create-CDPNeighborObject
            $NeighborObject.DeviceID               = $neighbor[0].trim()
            $NeighborObject.InterfaceIPAddresses   = $neighbor[1].trim()
            $NeighborObject.Platform               = $neighbor[2].trim()
            $NeighborObject.InterfaceRemoteDevice  = $neighbor[3].trim()
            $NeighborObject.InterfaceLocalDevice   = $neighbor[4].trim()
            $NeighborObject.Version                = $neighbor[5].trim()
            $NeighborObject.Capabilities		   = $neighbor[6].trim()
            if($neighbor[7]){$NeighborObject.NativeVLAN             = $neighbor[7].trim()}
            $NeighborObject.ParentObject           = $device.hostname
            #note that the interface has a CDP nieghbor
            $device.interfaces | where { $_.interface -eq $NeighborObject.InterfaceLocalDevice} | % { $_.HasCPDNieghbor = $true}
            $ArrayOfNeighborObjects+=$NeighborObject
        }
    }
    if($Device.version.type -eq "NXOS"){
        #Add-HostDebugText -HostObject $Device "This is a  NXOS device"
        #Add-HostDebugText -HostObject $Device "Starting Python Processing with TextFSM"
        #Start Python process with TextFSM to convert the Text to a Object
        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.NexusShowCDPNeighborsDetailsTemplate -ShowFile $CdpNeighborFile -ReturnArray $true -HostObject $Device
        if($Device.ProcessOutputObjects -eq "ERROR"){
            Add-HostDebugText -HostObject $Device "Error with show cdp neighbors details on NXOS."
            return $device
        }
        if($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string"){
            $tempArray = @()
            $tempArray += ,$Device.ProcessOutputObjects
            $Device.ProcessOutputObjects = $tempArray
        }
        #We only have 1 CDP neighbor so and it doesn't come back as array.
        #Convert it to an array of arrays.
        if($Device.ProcessOutputObjects[0].GetType().name -eq "string"){
            $array=@()
            $array += ,$Device.ProcessOutputObjects
            $Device.ProcessOutputObjects=$array
        }
        foreach ( $neighbor in $Device.ProcessOutputObjects){
            if($GSkipCDPLLDPPhones){
                if($neighbor[8] -like "*phone*" ){
                    continue
                }
            }
            $NeighborObject=Create-CDPNeighborObject
            $NeighborObject.DeviceID               = $neighbor[0].trim()
            $NeighborObject.SystemName             = $neighbor[1].trim() 
            $NeighborObject.InterfaceIPAddresses   = $neighbor[7].trim() # Changed from index 2 to 7
            $NeighborObject.Platform               = $neighbor[3].trim() 
            $NeighborObject.InterfaceRemoteDevice  = $neighbor[4].trim() 
            $NeighborObject.InterfaceLocalDevice   = $neighbor[5].trim() 
            $NeighborObject.Version                = $neighbor[6].trim() 
            $NeighborObject.InterfaceAddress       = $neighbor[2].trim() # This is the Mgmt Address
            $NeighborObject.Capabilities           = $neighbor[8].trim()
            if($neighbor[9]){$NeighborObject.NativeVLAN             = $neighbor[9].trim()}
            $NeighborObject.ParentObject           = $device.hostname
            #note that the interface has a CDP nieghbor
            $device.interfaces | where { $_.interface -eq $NeighborObject.InterfaceLocalDevice} | % { $_.HasCPDNieghbor = $true}
            $ArrayOfNeighborObjects+=$NeighborObject
        }
    }


    #Sort the object correctly so we get minimal crossed lines when drawing the objects.
    $device.CDPNeighbors=$ArrayOfNeighborObjects | sort -property @{Expression={[int]($_.InterfaceLocalDevice -replace '[a-zA-Z-]+','' -replace "/",'')}}
    return $device
}


#Extract all the information from the interfaces sections
function Get-InterfacesFromText(){
    param (
		[parameter(Mandatory=$true)]
		$AllInterfaces,
        $ArrayOfHostNetworks
    )
    [array]$ArrayOfIPAddresses=@()
    [array]$interfaces = @()
    Foreach($interface in $AllInterfaces) {
        $interfaceObject = Create-InterfaceObject
        $interfaceObject.shutdown=$false
        #Get interface with vlan
        if(($interface | Select-String "(interface.).+").Matches.Success){
            if( ($interface | Select-String "(interface).+?vlan").Matches.Value ){
                $interfaceObject.Routedvlan = (($interface | Select-String "(interface.).+").Matches.Value  -replace ".*?(\d+).*?",'$1').trim()
            }elseif( ($interface | Select-String "interface.*?\/\d+\.\d+.*").Matches.Success ){
                $interfaceObject.Routedvlan = (($interface | Select-String "(interface.).+").Matches.Value  -replace "interface.*?\/\d+\.(\d+).*",'$1').trim()
            }else{
                $interfaceObject.Routedvlan = "no vlan"
            }
            $interfaceObject.Interface = (($interface | Select-String "(interface.).+").Matches.Value -replace "interface ",''  -replace ' l2transport','').trim()
        }
        $interfaceObject.Description = (($interface | Select-String "(description.).+").Matches.Value -replace "description ",'').trim()


        if((($interface | Select-String "(hsrp \d+).+").Matches.Value -replace "hsrp ",'' ).trim()){#Nexus
            $interfaceObject.Standbyip = (($interface | Select-String "(ip \d+\.\d+\.\d+\.\d+)\s*").Matches.Value -replace "ip ",'').trim()
            $interfaceObject.StandbyNumber = (($interface | Select-String "(hsrp \d+).+").Matches.Value -replace "hsrp \d+",'').trim()
            $interfaceObject.StandbyPriority = (($interface | Select-String "(priority \d+).+").Matches.Value -replace "priority \d+",'').trim()
        }else{#IOS
            $interfaceObject.Standbyip = (($interface | Select-String "(standby \d+ ip).+").Matches.Value -replace "standby \d+ ip ",'').trim()
            $interfaceObject.StandbyNumber = (($interface | Select-String "(standby \d+ ip).+").Matches.Value -replace "standby ",'' -replace " ip.*",'' ).trim()
            $interfaceObject.StandbyPriority = (($interface | Select-String "(standby \d+ priority).+").Matches.Value -replace "standby \d+ priority ",'').trim()
        }
        if($interfaceObject.Standbyip){
            $ArrayOfIPAddresses+=$interfaceObject.Standbyip
        }
        #TODO:Make this an array
        if ( ($interface | Select-String "(?m)^(\s*ip|\s*ipv4) address.+$").Matches.Success){
            if ( ($interface | Select-String "((ip|ipv4) address.).+?secondary").Matches.Success){#Secondary IP address???
                if(($interface | Select-String "((ip|ipv4) address.).+?\/.*?").Matches.Success){
                    $interfaceObject.SecondaryIPAddress =  (($interface | Select-String "((ip|ipv4) address.).+secondary").Matches.Value -replace " secondary",'' -replace "(ip|ipv4) address (\d+(\.\d+){3})/\d+.*",'$2').trim()
                    $interfaceObject.SecondaryIPAddress = Compare-ToEmptyString -string $interfaceObject.SecondaryIPAddress
                    $interfaceObject.SecondarySubnetMask = (($interface | Select-String "((ip|ipv4) address.).+secondary").Matches.Value -replace " secondary",'' -replace "(ip|ipv4) address .*?/(\d+)",'$2').trim()
                    $interfaceObject.SecondarySubnetMask = Compare-ToEmptyString -string $interfaceObject.SecondarySubnetMask
                    if($null -ne $interfaceObject.SecondaryIPAddress ){
                        $interfaceObject.SecondaryCidr = (Get-IPv4Subnet -IPAddress $interfaceObject.SecondaryIPAddress -PrefixLength $interfaceObject.SecondarySubnetMask).cidrid
                    }
                }else{
                    $interfaceObject.SecondaryIPAddress =  (($interface | Select-String "((ip|ipv4) address.).+secondary").Matches.Value -replace " secondary",'' -replace "(ip|ipv4) address (\d+(\.\d+){3}) .*",'$2').trim()
                    $interfaceObject.SecondaryIPAddress = Compare-ToEmptyString -string $interfaceObject.SecondaryIPAddress
                    $interfaceObject.SecondarySubnetMask = (($interface | Select-String "((ip|ipv4) address.).+secondary").Matches.Value -replace " secondary",'' -replace "(ip|ipv4) address .*? ((\d+(\.\d+){3}))",'$2').trim()
                    $interfaceObject.SecondarySubnetMask = Compare-ToEmptyString -string $interfaceObject.SecondarySubnetMask
                    if($null -ne $interfaceObject.SecondaryIPAddress ){
                        $interfaceObject.SecondaryCidr = (Get-IPv4Subnet -IPAddress $interfaceObject.SecondaryIPAddress  -SubnetMask $interfaceObject.SecondarySubnetMask).cidrid
                    }
                }
            }
            if($interfaceObject.SecondaryIPAddress){
                $ArrayOfIPAddresses+=$interfaceObject.SecondaryIPAddress
            }


            #Normal ip address selection
            if(($interface | Select-String "((ip|ipv4) address.).+?\/.*?").Matches.Success){
                $interfaceObject.IPAddress =  (($interface | Select-String "(ip|ipv4) address (\d+(\.\d+){3})/\d+[^ secondary]").Matches.Value -replace "(ip|ipv4) address (\d+(\.\d+){3})/\d+.*",'$2').trim()
                $interfaceObject.IPAddress = Compare-ToEmptyString -string $interfaceObject.IPAddress
                $interfaceObject.SubnetMask = (($interface | Select-String "(ip|ipv4) address (\d+(\.\d+){3})/\d+[^ secondary]").Matches.Value -replace "(ip|ipv4) address .*?/(\d+)",'$2').trim()
                $interfaceObject.SubnetMask = Compare-ToEmptyString -string $interfaceObject.SubnetMask
                if($null -ne $interfaceObject.IPAddress  -and  $null -ne $interfaceObject.SubnetMask ){
                    $interfaceObject.Cidr = (Get-IPv4Subnet -IPAddress $interfaceObject.IPAddress -PrefixLength $interfaceObject.SubnetMask).cidrid
                }
            }else{
                $interfaceObject.IPAddress =  (($interface | Select-String "(ip|ipv4) address \d+(\.\d+){3} \d+(\.\d+){3}[^ secondary]").Matches.Value -replace "(ip|ipv4) address (\d+(\.\d+){3}) .*",'$2').trim()
                $interfaceObject.IPAddress = Compare-ToEmptyString -string $interfaceObject.IPAddress
                $interfaceObject.SubnetMask = (($interface | Select-String "(ip|ipv4) address \d+(\.\d+){3} \d+(\.\d+){3}[^ secondary]").Matches.Value -replace "(ip|ipv4) address .*? ((\d+(\.\d+){3}))",'$2').trim()
                $interfaceObject.SubnetMask = Compare-ToEmptyString -string $interfaceObject.SubnetMask
                if($null -ne $interfaceObject.IPAddress  -and $null -ne $interfaceObject.SubnetMask ){

                    $interfaceObject.Cidr = (Get-IPv4Subnet -IPAddress $interfaceObject.IPAddress  -SubnetMask $interfaceObject.SubnetMask).cidrid

                }
            }
        }
        if($interfaceObject.IPAddress){
            $ArrayOfIPAddresses+=$interfaceObject.IPAddress
        }
        $interfaceObject.vrf = (($interface | Select-String "(ip vrf forwarding .).+").Matches.Value -replace "ip vrf forwarding ",'').trim() #Assume IOS VRF, returns a blank string.
        if($interfaceObject.vrf -eq ""){
            $interfaceObject.vrf = (($interface | Select-String "(vrf forwarding .).+").Matches.Value -replace "vrf forwarding ",'').trim() #IOSX VRF
        }
        if($interfaceObject.vrf -eq ""){
            $interfaceObject.vrf = (($interface | Select-String "(vrf member .).+").Matches.Value -replace "vrf member ",'').trim() #NXOS VRF
        }

        if ( ($interface | Select-String " vpc \d+").Matches.success ){
            $interfaceObject.vpc = (($interface | Select-String " vpc \d+").Matches.Value -replace " vpc ",'').trim()
        }
        if ( ($interface | Select-String " vpc peer-link").Matches.success ){
            $interfaceObject.vpc = "peer-link"
        }
        if ( ($interface | Select-String "channel-group \d+ mode active").Matches.success ){
            $interfaceObject.ChannelGroup = (($interface | Select-String "(channel-group .).+").Matches.Value -replace "channel-group ",'' -replace ' mode active','').trim()
            $interfaceObject.ChannelGroupMode="Active"
        }
        if ( ($interface | Select-String "channel-group \d+ mode passive").Matches.success ){
            $interfaceObject.ChannelGroup = (($interface | Select-String "(channel-group .).+").Matches.Value -replace "channel-group ",'' -replace ' mode passive','').trim()
            $interfaceObject.ChannelGroupMode="passive"
        }
        if ( ($interface | Select-String "channel-group \d+ mode on").Matches.success ){
            $interfaceObject.ChannelGroup = (($interface | Select-String "(channel-group .).+").Matches.Value -replace "channel-group ",'' -replace ' mode on','').trim()
            $interfaceObject.ChannelGroupMode="on"
        }
        if ( ($interface | Select-String "channel-group \d+ mode desirable").Matches.success ){
            $interfaceObject.ChannelGroup = (($interface | Select-String "(channel-group .).+").Matches.Value -replace "channel-group ",'' -replace ' mode desirable','').trim()
            $interfaceObject.ChannelGroupMode="desirable"
        }
        $interfaceObject.Nativevlan = (($interface | Select-String "(switchport trunk native vlan .).+").Matches.Value -replace "switchport trunk native vlan ",'').trim()
        $interfaceObject.SpanningTreePortType = (($interface | Select-String "(spanning-tree port type .).+").Matches.Value -replace "spanning-tree port type ",'').trim()
        $interfaceObject.bpdufilter = (($interface | Select-String "(spanning-tree bpdufilter.).+").Matches.Value -replace "spanning-tree bpdufilter",'').trim()
        $interfaceObject.SwitchportMode = (($interface | Select-String "(switchport mode.).+").Matches.Value -replace "switchport mode ",'').trim()
        $interfaceObject.SwitchportAccessvlan = (($interface | Select-String "(switchport access vlan.).+").Matches.Value -replace "switchport access vlan ",'').trim()
        if($null -eq $interfaceObject.SwitchportMode -or "" -eq $interfaceObject.SwitchportMode){#Nexus switches don't display the mode if they are in access mode.
            if($interfaceObject.SwitchportAccessvlan){
                $interfaceObject.SwitchportMode="access"
            }
        }

        #switchport trunk allowed vlan 1,200,203,206,308,310,318,322,330,340,341,370
        $interfaceObject.SwitchportTrunkvlan = (($interface | Select-String "(switchport trunk allowed vlan.).+").Matches.Value -replace "switchport trunk allowed vlan ",'').trim()
        #switchport trunk allowed vlan add 701
        if(($interface | Select-String "(switchport trunk allowed vlan add.).+").Matches.Value){
            $interfaceObject.SwitchportTrunkvlan += " $((($interface | Select-String "(switchport trunk allowed vlan add.).+").Matches.Value -replace "switchport trunk allowed vlan add ",'').trim())"
        }
        if( (-not $interfaceObject.SwitchportMode) -and $interfaceObject.SwitchportTrunkvlan){
            $interfaceObject.SwitchportMode = "Probably Trunk mode"
        }
        if ($interface -match '(?m)^\s*shutdown\s*$') {
            $interfaceObject.shutdown = $true
        } else {
            $interfaceObject.shutdown = $false
        }
        if($null -ne $interfaceObject.Cidr){
            $NetworkObject = Create-NetworkObject
            $NetworkObject.Cidr = $interfaceObject.Cidr
            if( $interfaceObject.Interface -like "*vlan*"){
                $NetworkObject.Routedvlan = $interfaceObject.Interface
            }else {
                $NetworkObject.Routedvlan = "no vlan"
            }
            $ArrayOfHostNetworks += $NetworkObject
        }
        if($null -ne $interfaceObject.SecondaryCidr){
            $NetworkObject = Create-NetworkObject
            $NetworkObject.Cidr = $interfaceObject.SecondaryCidr
            if( $interfaceObject.Interface -like "*vlan*"){
                $NetworkObject.Routedvlan = $interfaceObject.Interface
            }else {
                $NetworkObject.Routedvlan = "no vlan"
            }
            $ArrayOfHostNetworks += $NetworkObject
        }
        if($interfaceObject.SubnetMask -like "*.*"){ #Just use CIDR notation
            $interfaceObject.SubnetMask = Covert-NetMaskToCIDR -SubnetMask $interfaceObject.SubnetMask
        }
        if($interfaceObject.SecondarySubnetMask -like "*.*"){ #Just use CIDR notation
            $interfaceObject.SecondarySubnetMask = Covert-NetMaskToCIDR -SubnetMask $interfaceObject.SecondarySubnetMask
        }
        if ( ($interface | Select-String "no switchport").Matches.success -or ($null -ne $interfaceObject.IPAddress ) ){
            $interfaceObject.SwitchPortType = 'Routed'
        }
        $interfaces += $interfaceObject
    }
    #Add colors to port-channel interfaces
    foreach($PortChannel in ($interfaces | where { $_.interface -like "port-channel*"})){
        $PortChannel.ShapeColor = "$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0)"
        $interfaces | where { $_.ChannelGroup -eq ($PortChannel.interface -replace "(p|P)ort\-channel\s*",'')} | % { $_.ShapeColor = $PortChannel.ShapeColor }
    }
    #Add colors to VRF interfaces
    $LastVRFInterface=$null
    foreach($VRFInterface in ($interfaces | where { $_.vrf } | sort vrf )){
        if ($VRFInterface.vrf -ne $LastVRFInterface.vrf){
            $Color="$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0)"
        }
        $VRFInterface.VRFColor =  $Color
        $LastVRFInterface=$VRFInterface
    }
    return $interfaces,$ArrayOfHostNetworks,$ArrayOfIPAddresses
}



#convert a cisco config to a series of objects
#Hostname
#Interfaces
#vlans
function Get-ShowRunFromText(){
    param (
		[parameter(Mandatory=$true)]
		$Lconfig
    )
    #Create host/device object to hold all the parsed data
    $HostObject=Create-HostObject
    $HostObject.Origin="config"
    $ArrayOfHostNetworks=@()
    $hostname = (($Lconfig| Select-String -Pattern "(hostname ).+").Matches.Value -replace "hostname ",'').trim()
    if($null -eq $hostname  -or $hostname -eq "" ){
        $hostname = (($Lconfig| Select-String -Pattern "(switchname ).+").Matches.Value -replace "switchname ",'').trim()
    }
    if($null -eq $hostname  -or $hostname -eq "" ){
        $hostname = "NoHostNameFoundCheckForConfigProblems"
    }
    $HostObject.hostname = $hostname

    $HostObject.SpanningTree=Create-SpanningTreeObject
    $HostObject.SpanningTree.SpanningTreeMode = (($Lconfig| Select-String -Pattern "(spanning-tree mode ).+").Matches.Value -replace "spanning-tree mode ",'').trim()
    $HostObject.SpanningTree.SpanningTreeExtended = (($Lconfig| Select-String -Pattern "(spanning-tree extend ).+").Matches.Value -replace "spanning-tree extend ",'').trim()

    $AllInterfaces = ($Lconfig -replace '(?smi)^\s+interface','interface' | Select-String -Pattern "(?smi)^\s*interface.+?((?=^[^\s])|^\s*interface)" -AllMatches).Matches.Value
    $Allvlans=($Lconfig | Select-String -Pattern "(?smi)^vlan.+?((?=^[^\s]))" -AllMatches).Matches.Value

    $interfaces,$ArrayOfHostNetworks,$HostObject.ArrayOfIPAddresses=Get-InterfacesFromText -AllInterfaces $AllInterfaces -ArrayOfHostNetworks $ArrayOfHostNetworks

    #Process vlans
    $vlans=@()
    foreach ( $vlan in $Allvlans){
        if( $vlan -like "*internal allocation policy ascending*"`
        -or $vlan -like "vlan access-log ratelimit*"`
        -or $vlan -like "vlan access-map*"`
        -or $vlan -like "vlan configuration*"`
        -or $vlan -match "vlan \d+,\d+" #Some switches have a list of all vlans comma separated before the real list of vlans and names.
        ){
            continue
        }
        $vlanObject = Create-vlanObject
        $vlanObject.number =(($vlan -split "(?smi)$")[0] -replace "vlan ",'').trim()

        if( (($vlan -split "(?smi)$")[1]) -like "*name*"){
            $vlanObject.name=((($vlan -split "(?smi)$")[1]) -replace "name ",'' ).trim()
        }else {
            $vlanObject.name="No name"
        }
        $vlans+= $vlanObject
    }

    $BGPSection = ($Lconfig | Select-String -Pattern '(?smi)^router bgp.*?(?=^!|^\S)' -AllMatches).Matches.Value
    if ($BGPSection) {
        $HostObject.BGP_AS_Number = (($BGPSection | Select-String 'router bgp \d+').Matches.Value -replace 'router bgp\s+','' -replace '\s.*','').Trim()
    }

    $HostObject.vlans = $vlans
    $HostObject.interfaces = $interfaces
    $ArrayOfHostNetworks | % { $_.color = "$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0)" }
    $HostObject.ArrayOfNetworks=$ArrayOfHostNetworks
    return $HostObject
}

#Process the show ip bgp neighbors file for VPNv4 contexts
function Get-BGPNeighborsFromText(){
    param (
        [parameter(Mandatory=$true)]
        $BGPNeighborsFile,
        $Device
    )

    # --- Validation Check ---
    $BGPNeighborsText = Get-Content -raw $BGPNeighborsFile
    if(($BGPNeighborsText | Select-String "(BGP not active|Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Ambiguous command:|LLDP is not enabled)").Matches.Success){
        Add-HostDebugText -HostObject $Device "$($BGPNeighborsText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty"  -BackgroundColor red
        return $device
    }
    # --- End of Validation Check ---

    $AllBGPNeighbors = @() # Array to hold all neighbor objects


    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTemplate.IOSShowIPBGPVPNv4NeighborsTemplate -ShowFile $BGPNeighborsFile -ReturnArray $true -HostObject $Device

    if($Device.ProcessOutputObjects -eq "ERROR"){
        Add-HostDebugText -HostObject $Device "Error processing BGP VPNv4 neighbors file: $($BGPNeighborsFile)" -BackgroundColor Red
        return $device
    }

    # Handle cases where only one neighbor is returned as a flat array
    if($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string"){
        $tempArray = @()
        $tempArray += ,$Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }

    # Process each neighbor found by TextFSM
    foreach ($NeighborData in $Device.ProcessOutputObjects){
        $NeighborObject = Create-BGPNeighborObject
        $NeighborObject.NEIGHBOR           = $NeighborData[0]
        $NeighborObject.VRF                = $NeighborData[1]
        $NeighborObject.REMOTE_AS          = $NeighborData[2]
        $NeighborObject.LOCAL_AS           = $NeighborData[3]
        $NeighborObject.PEER_GROUP         = $NeighborData[4]
        $NeighborObject.REMOTE_ROUTER_ID   = $NeighborData[5]
        $NeighborObject.BGP_STATE          = $NeighborData[6]
        $NeighborObject.LOCALHOST_IP       = $NeighborData[7]
        $NeighborObject.LOCALHOST_PORT     = $NeighborData[8]
        $NeighborObject.REMOTE_IP          = $NeighborData[9]
        $NeighborObject.REMOTE_PORT        = $NeighborData[10]
        $NeighborObject.INBOUND_ROUTEMAP   = $NeighborData[11]
        $NeighborObject.OUTBOUND_ROUTEMAP  = $NeighborData[12]

        $AllBGPNeighbors += $NeighborObject
    }

    $device.BGPNeighbors = $AllBGPNeighbors
    return $device
}




#Process the standard 'show ip bgp neighbors' file
function Get-BGPNeighborsStandardFromText(){
    param (
        [parameter(Mandatory=$true)]
        $BGPNeighborsFile,
        $Device
    )

    # Read the file to check for errors before processing
    $BGPNeighborsText = Get-Content -raw $BGPNeighborsFile

    if(($BGPNeighborsText | Select-String "(BGP not active|Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:|LLDP is not enabled)").Matches.Success){
        Add-HostDebugText -HostObject $Device "$($BGPNeighborsText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty"  -BackgroundColor red
        return $device
    }

    # Start with any neighbors that may have already been added (e.g., from VPNv4)
    $AllBGPNeighbors = $Device.BGPNeighbors

    # Use the standard IOS BGP Neighbors template
    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTemplate.IOSShowIPBGPNeighborsTemplate -ShowFile $BGPNeighborsFile -ReturnArray $true -HostObject $Device

    if($Device.ProcessOutputObjects -eq "ERROR"){
        Add-HostDebugText -HostObject $Device "Error processing standard BGP neighbors file: $($BGPNeighborsFile)" -BackgroundColor Red
        return $device
    }

    # Handle cases where only one neighbor is returned
    if($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string"){
        $tempArray = @()
        $tempArray += ,$Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }

    # Process each neighbor found by TextFSM
    foreach ($NeighborData in $Device.ProcessOutputObjects){
        $NeighborObject = Create-BGPNeighborObject
        $NeighborObject.NEIGHBOR           = $NeighborData[0] 
        $NeighborObject.VRF                = $NeighborData[1] 
        $NeighborObject.REMOTE_AS          = $NeighborData[2] 
        $NeighborObject.PEER_GROUP         = $NeighborData[3] 
        $NeighborObject.REMOTE_ROUTER_ID   = $NeighborData[4] 
        $NeighborObject.BGP_STATE          = $NeighborData[5] 
        $NeighborObject.LOCALHOST_IP       = $NeighborData[6] 
        $NeighborObject.LOCALHOST_PORT     = $NeighborData[7] 
        $NeighborObject.REMOTE_IP          = $NeighborData[8] 
        $NeighborObject.REMOTE_PORT        = $NeighborData[9] 
        $NeighborObject.INBOUND_ROUTEMAP   = $NeighborData[10]
        $NeighborObject.OUTBOUND_ROUTEMAP  = $NeighborData[11]

        $AllBGPNeighbors += $NeighborObject
    }

    $device.BGPNeighbors = $AllBGPNeighbors
    return $device
}


#Process the 'show ip bgp neighbors' file for NX-OS devices
function Get-BGPNeighborsNXOSFromText {
    param (
        [parameter(Mandatory=$true)]
        $BGPNeighborsFile,
        $Device
    )

    # Standard validation check
    $BGPNeighborsText = Get-Content -raw $BGPNeighborsFile
    if (($BGPNeighborsText | Select-String "(BGP not active|Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Ambiguous command:|% Unrecognized command)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$($BGPNeighborsText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty" -BackgroundColor red
        return $device
    }

    # Start with any existing neighbors
    $AllBGPNeighbors = $Device.BGPNeighbors

    # Use the NX-OS BGP Neighbors template
    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTemplate.NexusShowIPBGPNeighborsTemplate -ShowFile $BGPNeighborsFile -ReturnArray $true -HostObject $Device

    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Error processing NX-OS BGP neighbors file: $($BGPNeighborsFile)" -BackgroundColor Red
        return $device
    }

    # Handle single result
    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        $tempArray = @()
        $tempArray += ,$Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }

    # Process each neighbor, mapping only common fields
    foreach ($NeighborData in $Device.ProcessOutputObjects) {
        $NeighborObject = Create-BGPNeighborObject
        $NeighborObject.NEIGHBOR           = $NeighborData[0]
        $NeighborObject.DESCRIPTION        = $NeighborData[1]
        $NeighborObject.REMOTE_AS          = $NeighborData[2]
        $NeighborObject.BGP_STATE          = $NeighborData[3]
        $NeighborObject.SOURCE_IFACE       = $NeighborData[5]
        $NeighborObject.LOCALHOST_IP       = $NeighborData[17]
        $NeighborObject.LOCALHOST_PORT     = $NeighborData[18]
        $NeighborObject.REMOTE_IP          = $NeighborData[19]
        $NeighborObject.REMOTE_PORT        = $NeighborData[20]
        $NeighborObject.INBOUND_ROUTEMAP   = $NeighborData[52]
        $NeighborObject.OUTBOUND_ROUTEMAP  = $NeighborData[53]

        $AllBGPNeighbors += $NeighborObject
    }

    $device.BGPNeighbors = $AllBGPNeighbors
    return $device
}


#Process the 'show ip bgp summary' file as a fallback to populate BGP neighbors
function Get-BGPNeighborsFromSummary {
    param (
        [parameter(Mandatory=$true)]
        $BGPSummaryFile,
        $Device
    )

    # Standard validation check
    $BGPSummaryText = Get-Content -raw $BGPSummaryFile
    if (($BGPSummaryText | Select-String "(BGP not active|Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Ambiguous command:|% Unrecognized command)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$($BGPSummaryText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "BGP Summary file contains invalid data or is empty." -BackgroundColor red
        return $device
    }

    $AllBGPNeighbors = @()
    $TemplateToUse = $null

    # Determine which TextFSM template to use based on OS type
    if ($Device.version.type -eq "NXOS") {
        $TemplateToUse = $GTemplate.NexusShowIPBGPSummaryTemplate
    } else {
        $TemplateToUse = $GTemplate.IOSShowIPBGPSummaryTemplate
    }

    $Device = Execute-PythonTextFSM -TextFSTETemplate $TemplateToUse -ShowFile $BGPSummaryFile -ReturnArray $true -HostObject $Device
    if ($Device.ProcessOutputObjects -eq "ERROR") { return $device }

    # Handle single result
    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        $tempArray = @()
        $tempArray += ,$Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }

    # Process each summary entry, creating BGPNeighborObjects
    foreach ($SummaryData in $Device.ProcessOutputObjects) {
        $NeighborObject = Create-BGPNeighborObject

        if ($Device.version.type -eq "NXOS") {
            $NeighborObject.NEIGHBOR    = $SummaryData[3]
            $NeighborObject.REMOTE_AS   = $SummaryData[4]
            # Try to determine state from the 'State/PfxRcd' field
            if ($SummaryData[10] -match '^\d+$') {
                $NeighborObject.BGP_STATE = "Established"
            } else {
                $NeighborObject.BGP_STATE = $SummaryData[10]
            }
        }
        else { # IOS/IOS-XE
            $NeighborObject.NEIGHBOR    = $SummaryData[3]
            $NeighborObject.REMOTE_AS   = $SummaryData[4]
            # Try to determine state from the 'State/PfxRcd' field
            if ($SummaryData[6] -match '^\d+$') {
                $NeighborObject.BGP_STATE = "Established"
            } else {
                $NeighborObject.BGP_STATE = $SummaryData[6]
            }
        }
        $AllBGPNeighbors += $NeighborObject
    }

    $device.BGPNeighbors = $AllBGPNeighbors
    Add-HostDebugText -HostObject $Device "  -> Populated $($AllBGPNeighbors.Count) BGP neighbors from summary file."
    return $device
}




#Process the show IP arp file
#Process the show IP arp file
function Get-ShowIPArpText(){
    param (
        [parameter(Mandatory=$true)]
        $ShowIPArpFile,
        $Device
    )
    #Read the file into one big string
    $ShowIPArpText = Get-Content -raw $ShowIPArpFile
    if(($ShowIPArpText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:|LLDP is not enabled)").Matches.Success){
        Add-HostDebugText -HostObject $Device "$($ShowIPArpText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty"  -BackgroundColor red
        return $device
    }
    if($Device.version.type -eq "NXOS"){
        #Start Python process with TextFSM to convert the Text to a Object
        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.NexusShowIPArpTemplate -ShowFile $ShowIPArpFile  -ReturnArray $true -HostObject $Device
        if($Device.ProcessOutputObjects -eq "ERROR"){
            Add-HostDebugText -HostObject $Device "Error with show ip arp on NXOS."
            return $device
        }
        if($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string"){
            $tempArray = @()
            $tempArray += ,$Device.ProcessOutputObjects
            $Device.ProcessOutputObjects = $tempArray
        }

        # --- OPTIMIZATION START ---
        # 1. Create a hashtable of available subnets for fast lookups.
        $subnetLookup = @{}
        $device.interfaces | Where-Object { $_.Cidr } | ForEach-Object { $subnetLookup[$_.Cidr] = $true }
        # --- OPTIMIZATION END ---

        $device.IPArpEntries = foreach ($IPArpEntry in $Device.ProcessOutputObjects){
            $IPArpObject=Create-ShowIPArpObject
            $IPArpObject.ipaddress    =$IPArpEntry[0].trim()
            $IPArpObject.AGE          =$IPArpEntry[1].trim()
            $IPArpObject.MAC          =$IPArpEntry[2].trim()
            if($IPArpEntry[3].trim() -ne ""){#keep it as $null don't fill with a empty string.
                $IPArpObject.INTERFACE    =$IPArpEntry[3].trim()
            }
            $MacInOtherFormat=($IPArpEntry[2].trim() -replace '\.','').insert(2,":").insert(5,":").insert(8,":").insert(11,":").insert(14,":")
            if($GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,8)]){
                $IPArpObject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,8)]
            }elseif($GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,5)]){
                $IPArpObject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,5)]
            }else{
                $IPArpObject.VendorCompanyName = "UNKNOWN Vendor"
            }
            
            # --- OPTIMIZATION START ---
            # 2. Find the most specific subnet by checking from /32 down to /1.
            for ($prefix = 32; $prefix -ge 1; $prefix--) {
                $candidateCidr = (Get-IPv4Subnet -IPAddress $IPArpObject.ipaddress -PrefixLength $prefix).CIDRId
                if ($subnetLookup.ContainsKey($candidateCidr)) {
                    $IPArpObject.cidr = $candidateCidr
                    break # Found the best match, exit the inner loop.
                }
            }
            # --- OPTIMIZATION END ---

            $IPArpObject # Output the object to the pipeline
        }
        return $device
    }

    if ($Device.version.type -in @("IOS","XE-IOS")) {
        #Start Python process with TextFSM to convert the Text to a Object
        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.IOSShowIPArpTemplate -ShowFile $ShowIPArpFile   -ReturnArray $true -HostObject $Device
        if($Device.ProcessOutputObjects -eq "ERROR"){
            Add-HostDebugText -HostObject $Device "Error with show ip arp on IOS."
            return $device
        }
        if($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string"){
            $tempArray = @()
            $tempArray += ,$Device.ProcessOutputObjects
            $Device.ProcessOutputObjects = $tempArray
        }
        
        # --- OPTIMIZATION START ---
        # 1. Create a hashtable of available subnets for fast lookups.
        $subnetLookup = @{}
        $device.interfaces | Where-Object { $_.Cidr } | ForEach-Object { $subnetLookup[$_.Cidr] = $true }
        # --- OPTIMIZATION END ---

        $device.IPArpEntries = foreach ($IPArpEntry in $Device.ProcessOutputObjects){
            $IPArpObject=Create-ShowIPArpObject
            $IPArpObject.PROTOCOL= $IPArpEntry[0].trim()
            $IPArpObject.ipaddress=  $IPArpEntry[1].trim()
            $IPArpObject.AGE=      $IPArpEntry[2].trim()
            $IPArpObject.MAC=      $IPArpEntry[3].trim()
            $IPArpObject.TYPE=     $IPArpEntry[4].trim()
            $IPArpObject.INTERFACE=$IPArpEntry[5].trim()
            $MacInOtherFormat=($IPArpObject.MAC -replace '\.','').insert(2,":").insert(5,":").insert(8,":").insert(11,":").insert(14,":")
            if($GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,8)]){
                $IPArpObject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,8)]
            }elseif($GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,5)]){
                $IPArpObject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,5)]
            }else{
                $IPArpObject.VendorCompanyName = "UNKNOWN Vendor"
            }
            
            # --- OPTIMIZATION START ---
            # 2. Find the most specific subnet by checking from /32 down to /1.
            for ($prefix = 32; $prefix -ge 1; $prefix--) {
                $candidateCidr = (Get-IPv4Subnet -IPAddress $IPArpObject.ipaddress -PrefixLength $prefix).CIDRId
                if ($subnetLookup.ContainsKey($candidateCidr)) {
                    $IPArpObject.cidr = $candidateCidr
                    break # Found the best match, exit the inner loop.
                }
            }
            # --- OPTIMIZATION END ---

            $IPArpObject # Output the object to the pipeline
        }
        return $device
    }
    Add-HostDebugText -HostObject $Device "Error with show ip arp. Unable to find device type"   -BackgroundColor  red
    return $device
}





function Get-ShowSpanningTreeFromText(){
    param (
        [parameter(Mandatory=$true)]
        $ShowSpanningTreeFile,
        $Device
    )
    $ShowSpanningTreeText = Get-Content -raw $ShowSpanningTreeFile
    $Device.SpanningTree.SpanningTreeArray=@()

    if (($ShowSpanningTreeText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Ambiguous command:)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$($ShowSpanningTreeText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty"  -BackgroundColor Red
        return $device
    }

    if ($ShowSpanningTreeText -match "No spanning tree instances exist") {
        Add-HostDebugText -HostObject $Device "No spanning tree instances found." -BackgroundColor Yellow
        return $Device
    }

    # Split before any line beginning with "VLAN <number>"
    $SpanningTreeVlans = [regex]::split($ShowSpanningTreeText,'(?=^VLAN\s*\d+)') |
        Where-Object { $_.Trim() -ne "" }

    foreach ($vlan in $SpanningTreeVlans) {
        if ([string]::IsNullOrWhiteSpace($vlan)) {
            continue
        }
        if (-not ($vlan | Select-String "^vlan.*").matches) {
            continue
        }

        $SpanningTreevlanObject = Create-SpanningTreeVlan
        $SpanningTreevlanObject.vlanID = [int](($vlan | Select-String "^vlan\s*(\d+)").Matches.Groups[1].Value)

        # Capture the Root ID block
        $rootIDBlock = ($vlan | Select-String -Pattern '(?smi)Root ID\s+Priority.+?(?=Bridge ID)' -AllMatches).Matches.Value
        if ($rootIDBlock) {
            $SpanningTreevlanObject.RootIDPriority = ($rootIDBlock | Select-String 'Priority\s+(\S+)').Matches.Groups[1].Value
            $SpanningTreevlanObject.Address = ($rootIDBlock | Select-String 'Address\s+(\S+)').Matches.Groups[1].Value
            $SpanningTreevlanObject.RootBridgeHelloTime = ($rootIDBlock | Select-String 'Hello Time\s+(\S+)').Matches.Groups[1].Value

            # --- FIX: Check if Cost and Port exist before assigning ---
            $costMatch = $rootIDBlock | Select-String 'Cost\s+(\S+)'
            if ($costMatch) {
                $SpanningTreevlanObject.RootBridgeCost = $costMatch.Matches.Groups[1].Value
            }
            $portMatch = $rootIDBlock | Select-String 'Port\s+(\S+)\s+\((.+?)\)'
            if ($portMatch) {
                $SpanningTreevlanObject.RootBridgePort = $portMatch.Matches.Groups[2].Value
            }
        }

        # Capture the Bridge ID block
        $bridgeIDBlock = ($vlan | Select-String -Pattern '(?smi)Bridge ID\s+Priority.+?(?=Interface\s+Role|Interface\s+----)' -AllMatches).Matches.Value
        if ($bridgeIDBlock) {
            $SpanningTreevlanObject.BridgeIDPriority = ($bridgeIDBlock | Select-String 'Priority\s+(\S+)').Matches.Groups[1].Value
            $SpanningTreevlanObject.BridgeIDPriorityAddress = ($bridgeIDBlock | Select-String 'Address\s+(\S+)').Matches.Groups[1].Value
            $SpanningTreevlanObject.BridgeIDPriorityHelloTime = ($bridgeIDBlock | Select-String 'Hello Time\s+(\S+)').Matches.Groups[1].Value

            # --- FIX: Check if Aging Time exists before assigning ---
            $agingTimeMatch = $bridgeIDBlock | Select-String 'Aging Time\s+(\S+)'
            if ($agingTimeMatch) {
                $SpanningTreevlanObject.RootBridgeAgingTime = $agingTimeMatch.Matches.Groups[1].Value
            }
        }

        # Check for Root Bridge status
        if (($vlan | Select-String "This bridge is the root").Matches.Success) {
            $SpanningTreevlanObject.RootBridge = $true
            $SpanningTreevlanObject.RootIDPriority = $SpanningTreevlanObject.BridgeIDPriority
            $SpanningTreevlanObject.Address = $SpanningTreevlanObject.BridgeIDPriorityAddress
            $SpanningTreevlanObject.RootBridgeHelloTime = $SpanningTreevlanObject.BridgeIDPriorityHelloTime
        }

        if (($vlan | Select-String "Spanning tree enabled").Matches.Success) {
            $SpanningTreevlanObject.protocol = ($vlan | Select-String "Spanning tree enabled(.+)").matches.value -replace "Spanning tree enabled\s+protocol\s+",''
        }

        $SpanningTreevlanObject.SpanningTreeInterfaces = @()
        $interfaceBlock = ([regex]::split($vlan, "(?smi)^\-+"))[1] -replace "-", ''

        if (-not [string]::IsNullOrWhiteSpace($interfaceBlock)) {
            $Interfaces = $interfaceBlock.Trim().Split([Environment]::NewLine, [StringSplitOptions]::RemoveEmptyEntries)
            foreach ($interfaceLine in $Interfaces) {
                if ([string]::IsNullOrWhiteSpace($interfaceLine)) { continue }

                $SpanningTreeInterface = Create-SpanningTreeInterface
                $TextArray = $interfaceLine.Trim() -split '\s+'

                $SpanningTreeInterface.Interface = $TextArray[0]
                $SpanningTreeInterface.Role = $TextArray[1]
                $SpanningTreeInterface.Status = $TextArray[2]
                $SpanningTreeInterface.Cost = $TextArray[3]
                $SpanningTreeInterface.PrioNbr = $TextArray[4]

                if ($TextArray.Length -gt 5) {
                    $SpanningTreeInterface.Type = ($TextArray[5..($TextArray.Length - 1)]) -join " "
                }

                $SpanningTreevlanObject.SpanningTreeInterfaces += $SpanningTreeInterface

                # Spanning tree information for each port
                $currentInterface = $SpanningTreeInterface.Interface
                $foundInterfaces = $Device.interfaces | Where-Object {
                    $_.interface -eq $currentInterface -or
                    ($_.ChannelGroup -and ("port-channel" + $_.ChannelGroup) -eq $currentInterface)
                }
                foreach ($DeviceInterface in $foundInterfaces) {
                    Switch ($SpanningTreeInterface.Role) {
                        "Root" { $DeviceInterface.STRootInterfaceForvlans += ,$SpanningTreevlanObject.vlanID }
                        "Desg" { $DeviceInterface.STDesgnInterfaceForvlans += ,$SpanningTreevlanObject.vlanID }
                        "Altn" { $DeviceInterface.STALTnInterfaceForvlans += ,$SpanningTreevlanObject.vlanID }
                    }
                    $DeviceInterface.STState = $SpanningTreeInterface.Status
                    $DeviceInterface.STRole = $SpanningTreeInterface.Role
                }
            }
        }
        $Device.SpanningTree.SpanningTreeArray += $SpanningTreevlanObject
    }
    return $Device
}



#TODO:broken code:foreach ($Interface in $ActiveInterfaces) it's slow.
##Process the show ip route file
function Get-ShowIPRouteFromText(){
    param (
        [parameter(Mandatory=$true)]
        $ShowIPRouteFile,
        $ShowIPRouteVRFstarFile,
        $Device
    )

    # AllRouteObjects is now initialized later, directly from the loop's output.
    $UseShowIPRouteVRFstarFile=$false #should we use the $ShowIPRouteVRFstarFile file or not. Default no.
    if($ShowIPRouteVRFstarFile){#Always default to using ShowIPRouteVRFstarFile but check other file if it fails
        #Read the file into one big string
        $ShowRouteText = Get-Content -raw $ShowIPRouteVRFstarFile
        if(!($ShowRouteText | Select-String "No IP Route Table for VRF").Matches.Success){#The show ip route vrf start is empty use show ip route file.
            if(($ShowRouteText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:)").Matches.Success){

                if($ShowIPRouteFile){#Maybe ShowIPRouteVRFstarFile is invalid. If so try show ip route.
                    $ShowRouteText = Get-Content -raw $ShowIPRouteFile
                    if(($ShowRouteText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:)").Matches.Success){
                        Add-HostDebugText -HostObject $Device "$($ShowRouteText)" -BackgroundColor Magenta
                        Add-HostDebugText -HostObject $Device "contains invalid data or is empty"  -BackgroundColor red

                        return $device
                    }
                }else{#no show ip route file and show ip route vrf * is invalid so error and return.
                    Add-HostDebugText -HostObject $Device "$($ShowRouteText)" -BackgroundColor Magenta
                    Add-HostDebugText -HostObject $Device "contains invalid data or is empty"  -BackgroundColor red

                    return $device
                }
            }
            $UseShowIPRouteVRFstarFile=$true
        }

    }
    if($UseShowIPRouteVRFstarFile -eq $false){#We just have normal show ip route.
        #Read the file into one big string
        $ShowRouteText = Get-Content -raw $ShowIPRouteFile
        if(($ShowRouteText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:)").Matches.Success){
            Add-HostDebugText -HostObject $Device "$($ShowRouteText)" -BackgroundColor Magenta
            Add-HostDebugText -HostObject $Device "contains invalid data or is empty"  -BackgroundColor red
            return $device
        }
    }


    if(($ShowRouteText | Select-String "IP Route Table for VRF `"default`"").Matches.Success){
        Add-HostDebugText -HostObject $Device "This is a Nexus device"
        #Add-HostDebugText -HostObject $Device "Starting Python Processing with TextFSM"
        #Start Python process with TextFSM to convert the Text to a Object
        if($UseShowIPRouteVRFstarFile){
            $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.NexusSHOWIPROUTETemplate -ShowFile $ShowIPRouteVRFstarFile  -ReturnArray $true -HostObject $Device
       }else{

            $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.NexusSHOWIPROUTETemplate -ShowFile $ShowIPRouteFile  -ReturnArray $true -HostObject $Device
        }
        if($Device.ProcessOutputObjects -eq "ERROR"){
            if(($ShowRouteText | Select-String "Default gateway is \d+.\d+.\d+.\d+").Matches.Success){
                Add-HostDebugText -HostObject $Device "TextFSM failed for routing table, but found a default gateway as a fallback."
                $RouteObject=Create-RouteObject
                $RouteObject.gateway=($ShowRouteText | Select-String "Default gateway is \d+.\d+.\d+.\d+").matches.value -replace "Default gateway is ",''
                $RouteObject.Subnet="0.0.0.0/0"
                $RouteObject.RouteProtocol="Default gateway"

                # OPTIMIZATION: Filter interfaces ONCE
                $ActiveInterfaces = $Device.interfaces | Where-Object { $_.cidr -and $_.IntStatus -ne "down" }
                foreach ($Interface in $ActiveInterfaces){
                    if((Find-Subnet -addr1 $Interface.cidr -addr2 $RouteObject.gateway).condition){
                        $RouteObject.Interface=$Interface.Interface
                        break
                    }
                }
                Add-HostDebugText -HostObject $Device "Found default gateway:$($RouteObject)"
                $device.RoutingTable+=$RouteObject
                return $device
            }else{
                # If TextFSM failed AND there's no fallback, log the error and return the UNMODIFIED device.
                Add-HostDebugText -HostObject $Device "Error processing show ip route file '$($ShowIPRouteFile)'. TextFSM returned an error or the file is empty/invalid." -BackgroundColor Red
                return $device # CRUCIAL: Return the original object so the chain doesn't break.
            }
            Add-HostDebugText -HostObject $Device "Error with show ip route on Nexus routing." -BackgroundColor red
            return $device
        }

        # OPTIMIZATION: Filter interfaces ONCE before the loop
        $ActiveInterfaces = $Device.interfaces | Where-Object { $_.cidr -and $_.IntStatus -ne "down" }

        # cache variables
        $lastGateway = $null
        $lastInterface = $null

        # OPTIMIZATION: Efficiently create the array by capturing the loop's output
        $AllRouteObjects = foreach ($Route in ($Device.ProcessOutputObjects | Sort-Object { $_[7] })){
            $RouteObject=Create-RouteObject
            $RouteObject.VRF=$Route[0]
            $RouteObject.RouteProtocol=$Route[1]
            if($RouteObject.RouteProtocol -eq "hsrp" -and $GSkipHSRPRoutes){ #HSRP is not a routing protocol we want to have included.
                continue
            }
            if($null -eq $RouteObject.RouteProtocol){ #something went wrong, we have a route without a routing protocol
                Add-HostDebugText -HostObject $Device "Error No routing protocol:$($Route)" -BackgroundColor red
                continue
            }
            if($Route[2] -ne "" -and $null -ne $Route[2]){
                $RouteObject.RouteSubType=$Route[2]
            }
            $RouteObject.Subnet="$($Route[3])/$($Route[4])"
            $RouteObject.DISTANCE=$Route[5]
            $RouteObject.METRIC=$Route[6]
            if(($Route[7] -eq "") -or ($null -eq $Route[7])){
                #This is the case of Null0
                $RouteObject.gateway=$Route[8]
            }else{
                $RouteObject.gateway=$Route[7]
            }
            $RouteObject.Interface=$Route[8]

            if( $RouteObject.gateway -and ($RouteObject.gateway -ne "Null0") -and ($RouteObject.RouteProtocol -ne "local") -and ($RouteObject.RouteProtocol -ne "connected") -and ($RouteObject.RouteProtocol -ne "direct")){
                # cache check
                if($RouteObject.gateway -eq $lastGateway){
                    $RouteObject.Interface = $lastInterface
                } else {
                    $found = $false
                    foreach ($Interface in $ActiveInterfaces){
                        if((Find-Subnet -addr1 $Interface.cidr -addr2 $RouteObject.gateway).condition){
                            $RouteObject.Interface=$Interface.Interface
                            $lastGateway = $RouteObject.gateway
                            $lastInterface = $Interface.Interface
                            $found = $true
                            break
                        }
                    }
                    if(-not $found){
                        Add-HostDebugText -HostObject $Device "No matching interface found for gateway $($RouteObject.gateway)" -BackgroundColor red
                    }
                }
            }

            # Output the object to be collected by $AllRouteObjects
            $RouteObject
        }
        $device.RoutingTable=$AllRouteObjects
        return $device
    }


    #Add-HostDebugText -HostObject $Device "Starting Python Processing with TextFSM"
    #Start Python process with TextFSM to convert the Text to a Object
    if($UseShowIPRouteVRFstarFile){
        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.IOSSHOWIPROUTETemplate -ShowFile $ShowIPRouteVRFstarFile -ReturnArray $true -HostObject $Device
    }else{
        $Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.IOSSHOWIPROUTETemplate -ShowFile $ShowIPRouteFile -ReturnArray $true -HostObject $Device
    }
    if($Device.ProcessOutputObjects -eq "ERROR"){
        if(($ShowRouteText | Select-String "Default gateway is \d+.\d+.\d+.\d+").Matches.Success){
            if($Device -eq $null){
                write-host $ShowIPRouteFile
            }
            Add-HostDebugText -HostObject $Device "TextFSM failed for routing table, but found a default gateway as a fallback."
            $RouteObject=Create-RouteObject
            $RouteObject.gateway=($ShowRouteText | Select-String "Default gateway is \d+.\d+.\d+.\d+").matches.value -replace "Default gateway is ",''
            $RouteObject.Subnet="0.0.0.0/0"
            $RouteObject.RouteProtocol="Default gateway"

            # OPTIMIZATION: Filter interfaces ONCE
            $ActiveInterfaces = $Device.interfaces | Where-Object { $_.cidr -and $_.IntStatus -ne "down" }
            foreach ($Interface in $ActiveInterfaces){
                if((Find-Subnet -addr1 $Interface.cidr -addr2 $RouteObject.gateway).condition){
                    $RouteObject.Interface=$Interface.Interface
                    break
                }
            }
            Add-HostDebugText -HostObject $Device "Found default gateway:$($RouteObject)"
            $device.RoutingTable+=$RouteObject
            return $device
        }else {
            # If TextFSM failed AND there's no fallback, log the error and return the UNMODIFIED device.
            Add-HostDebugText -HostObject $Device "Error processing show ip route file '$($ShowIPRouteFile)'. TextFSM returned an error or the file is empty/invalid." -BackgroundColor Red
            # CRUCIAL: Return the original object so the chain doesn't break.
            return $device
        }
        Add-HostDebugText -HostObject $Device "Error with show ip route on IOS routing: $($Device.ProcessOutputObjects)" -BackgroundColor red
        return $device
    }
    Add-HostDebugText -HostObject $Device "This is a IOS device"

    # OPTIMIZATION: Filter interfaces ONCE before the loop
    $ActiveInterfaces = $Device.interfaces | Where-Object { $_.cidr -and $_.IntStatus -ne "down" }

    # cache variables
    $lastGateway = $null
    $lastInterface = $null

    # OPTIMIZATION: Efficiently create the array by capturing the loop's output
    $AllRouteObjects = foreach ($Route in ($Device.ProcessOutputObjects | Sort-Object { $_[7] })){
        $RouteObject=Create-RouteObject
        if($Route[0]){
            $RouteObject.vrf=$Route[0]
        }
        switch ($Route[1]){
            C{$RouteObject.RouteProtocol="connected"}
            L{$RouteObject.RouteProtocol="local"}
            S{$RouteObject.RouteProtocol="static"}
            R{$RouteObject.RouteProtocol="RIP"}
            BGP{$RouteObject.RouteProtocol="BGP"}
            D{$RouteObject.RouteProtocol="EIGRP"}
            O{$RouteObject.RouteProtocol="OSPF"}
            i{$RouteObject.RouteProtocol="IS-IS"}
            default{#No idea lets just assign it.
                $RouteObject.RouteProtocol=$Route[1]
            }
        }
        if($Route[2] -ne "" -and $null -ne $Route[2]){
            $RouteObject.RouteSubType=$Route[2]
        }
        $RouteObject.Subnet="$($Route[3])/$($Route[4])"
        $RouteObject.DISTANCE=$Route[5]
        $RouteObject.METRIC=$Route[6]
        $RouteObject.gateway=$Route[7]
        $RouteObject.Interface=$Route[8]
        if($null -eq $RouteObject.RouteProtocol){
            continue
        }
        if($RouteObject.gateway -and ($RouteObject.gateway -ne "Null0") -and ($RouteObject.RouteProtocol -ne "local") -and ($RouteObject.RouteProtocol -ne "connected") -and ($RouteObject.RouteProtocol -ne "direct")){
            if($RouteObject.gateway -eq $lastGateway){
                $RouteObject.Interface = $lastInterface
            } else {
                $found = $false
                foreach ($Interface in $ActiveInterfaces){
                    if((Find-Subnet -addr1 $Interface.cidr -addr2 $RouteObject.gateway).condition){
                        $RouteObject.Interface=$Interface.Interface
                        $lastGateway = $RouteObject.gateway
                        $lastInterface = $Interface.Interface
                        $found = $true
                        break
                    }
                }
                if(-not $found){
                    Add-HostDebugText -HostObject $Device "No matching interface found for gateway $($RouteObject.gateway)" -BackgroundColor red
                }
            }
        }

        # Output the object to be collected by $AllRouteObjects
        $RouteObject
    }
    Add-HostDebugText -HostObject $Device "$($AllRouteObjects.count) routes found"
    $device.RoutingTable=$AllRouteObjects
    return $device
}
