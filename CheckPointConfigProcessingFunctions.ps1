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

#This file contains all of the functions that process CheckPoint config.


#This functions calls all the other functions to process all of the files for a CheckPoint devices.
#Input: Hostid object.
#Output: $device object.
function Process-CheckPointHostFiles{
        param (
		[parameter(Mandatory=$true)]
		$hostid,
        $ArrayOfObjects
    )
     # First, create the device object from the config file.
     if($hostid.showrun -and (Test-Path -Path $hostid.showrun)){
         $config = Get-Content -Path $hostid.showrun -raw
         # The Get-CheckPointShowRunFromText function now creates and returns the initial $Device object.
         $Device=Get-CheckPointShowRunFromText -Lconfig $config
         $Device.DeviceIdentifier=($hostid.showrun -replace "\.show run.*",'' -replace "^.*\\",'' -replace "\.show configuration.*",'' )
     }else{
         # We can't create a device object to log to, so we can't use Add-HostDebugText here.
         # This will be visible in the main thread's error stream.
         Write-host "File doesn't exist for hostid '$($hostid.HOSTID)': $($hostid.showrun)"
         return $null
     }
 
     # Now that $Device is a valid object, we can log to it.
     Add-HostDebugText -HostObject $Device "Processing CheckPoint Host: $($Device.hostname)"
 
        if($null -eq $Device.hostname ){
            Write-host  "Can't find hostname in file skipping host: $($hostid.showrun)" -BackgroundColor red
            return $null
        }
        foreach ($ExistingDevice in $ArrayOfObjects){
            if($ExistingDevice.hostname -eq $Device.hostname){
                Add-HostDebugText -HostObject $Device  "Hostname already exists $($ExistingDevice.hostname) - $($Device.hostname). This means you either have the same code twice in the folder or someone has named two devices the same. This script requries unquie hostnames." -BackgroundColor red
                Add-HostDebugText -HostObject $Device  "Found problem at: $($hostid.HOSTID)" -BackgroundColor red
                Add-HostDebugText -HostObject $Device  "Existing HostID's:$($ArrayOfHostIDs | ft HOSTID,showrun | out-string)"
                Add-HostDebugText -HostObject $Device  "$($ArrayOfObjects|ft hostname)"
                if(!($SkipHostnameErrorCheck)){
                    Add-HostDebugText -HostObject $Device  'Exiting please manually fix this error.'  -BackgroundColor red
                    Start-CleanupAndExit
                    
                }
            }
        }
        if($hostid.ShowInterface){#
            Add-HostDebugText -HostObject $Device  "Processing checkpoint show interface:$($hostid.ShowInterface)"
            $Device=Get-CheckPointShowInterfaceFromText -CheckPointInterfaceFile $hostid.ShowInterface -Device $Device
        }
        if($hostid.ShowRouteAll){
            Add-HostDebugText -HostObject $Device  "Processing checkpoint show route all:$($hostid.ShowRouteAll)"
            $device=Get-CheckpointShowRouteFromText -device $device -ShowRouteFile $hostid.ShowRouteAll
        }
        return $device
}


#Read in the checkpoint config. and process it.
#Note:These is limited processing of the show config for now. This will be expanded in future as required.
function Get-CheckPointShowRunFromText{
    param (
		[parameter(Mandatory=$true)]
		$Lconfig
    )
    #Create host/device object to hold all the parsed data
    $HostObject=Create-HostObject
    $HostObject.Origin="config"
    $ArrayOfHostNetworks=@()
    $hostname = (($Lconfig| Select-String -Pattern "(set hostname ).+").Matches.Value -replace "set hostname ",'').trim()
    if($null -eq $hostname  -or $hostname -eq "" ){
        $hostname = "NoHostNameFoundCheckForConfigProblems"
        Add-HostDebugText -HostObject $HostObject "No hostname found in checkpoint config" -BackgroundColor red
    }
    $HostObject.hostname = $hostname
    return $HostObject
}


#Get all of the interfaces out of the show interfaces all command.
#Input:show interfaces all file
#Output:Interfaces objects.
function Get-CheckPointShowInterfaceFromText(){
    param (
        [parameter(Mandatory=$true)]
        $CheckPointInterfaceFile,
        $Device
    )
    $ArrayOfHostNetworks=@()
    $interfaces = @()
    #Read the file into one big string
    $CheckPointInterfaceText = Get-Content -raw $CheckPointInterfaceFile
    if(($CheckPointInterfaceText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:|LLDP is not enabled)").Matches.Success){
        Add-HostDebugText -HostObject $Device  "$($CheckPointInterfaceText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device  "contains invalid data or is empty"  -BackgroundColor red
        return $device
    }

    $ProcessOutputObjects,$Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.CheckPointShowInterfaceTemplate -ShowFile $CheckPointInterfaceFile -ReturnArray $true -HostObject $Device
    if($ProcessOutputObjects -eq "ERROR"){
        Add-HostDebugText -HostObject $Device  "Error with Show Interface on checkpoint file:$($CheckPointInterfaceFile)"
        return $device
    }
    foreach ($int in $ProcessOutputObjects){
        $interfaceObject = Create-InterfaceObject
        $interfaceObject.Interface=$int[0]
        if($int[4] -eq "link up"){
            $interfaceObject.shutdown=$false
        }elseif($int[1] -eq "on" -and $int[3] -eq "vlan" -and $int[4] -eq "not available"){
            #We have a sub interface that should in theory be up based on the state.
            $interfaceObject.shutdown=$false
        }else{
            $interfaceObject.shutdown=$true
        }

        $interfaceObject.speed=$int[7]
        $interfaceObject.Description=$int[8]
        if($int[9]){
            $interfaceObject.SubnetMask=($int[9] -split "/")[1]
            $interfaceObject.IPAddress=($int[9] -split "/")[0]
            $interfaceObject.Cidr = (Get-IPv4Subnet -IPAddress $interfaceObject.IPAddress -PrefixLength $interfaceObject.SubnetMask).cidrid
            $interfaceObject.SwitchPortType="Routed"
            if($null -ne $interfaceObject.Cidr){
                $NetworkObject = Create-NetworkObject
                $NetworkObject.Cidr = $interfaceObject.Cidr
                $NetworkObject.NetworkName = $interfaceObject.Description #This is probably not very good from a viewing point of view as this is not really a name but a description.
                if( $int[3] -eq "vlan"){
                    if($interfaceObject.Interface -like "*.*"){#we have a sub interface. Lets split out the vlan.
                        $NetworkObject.Routedvlan = "vlan$(($interfaceObject.Interface -split '\.')[1])"
                    }else{
                        $NetworkObject.Routedvlan = $interfaceObject.Interface
                    }
                }else {
                    $NetworkObject.Routedvlan = "no vlan"
                }
                $ArrayOfHostNetworks += $NetworkObject
            }
        }
        $interfaceObject.macaddress=($int[2] -replace ":",'').insert(4,".").insert(9,".")
        $interfaces += $interfaceObject
        #To make it easier in the future.

        #$interfaceObject.shutdown=$int[3]#TYPE
        #$interfaceObject.shutdown=$int[4]#LINK_STATE
        #$interfaceObject.shutdown=$int[5]#MTU
        #$interfaceObject.shutdown=$int[6]#AUTONEG

        #$interfaceObject.shutdown=$int[10]#IPV6_ADDRESS
        #$interfaceObject.shutdown=$int[11]#IPV6_LL_ADDRESS
        #$interfaceObject.shutdown=$int[12]#IPV6_LL_MASK
    }

    $ArrayOfHostNetworks | % { $_.color = "$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0)" }
    $device.ArrayOfNetworks=$ArrayOfHostNetworks
    $device.interfaces = $interfaces
    return $device
}



#Process the show route all for checkpoint
#Input:Checkpoint show route all file
#Output: Routing table object.
function Get-CheckpointShowRouteFromText(){
    param (
        [parameter(Mandatory=$true)]
        $ShowRouteFile,
        $Device
    )
    #Read the file into one big string
    $ShowRouteText = Get-Content -raw $ShowRouteFile
    $AllRouteObjects=@() #Array of routes(Create-RouteObject) that will be passed back to the host object.
    if(($ShowRouteText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:)").Matches.Success){
        Add-HostDebugText -HostObject $Device  "$($ShowRouteText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device  "contains invalid data or is empty"  -BackgroundColor red
        return $device
    }

    #Add-HostDebugText -HostObject $Device  "Starting Python Processing with TextFSM"
    #Start Python process with TextFSM to convert the Text to a Object
    $ProcessOutputObjects,$Device=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.CheckPointShowRouteTemplate -ShowFile $ShowRouteFile  -ReturnArray $true -HostObject $Device
    if($ProcessOutputObjects -eq "ERROR"){
        Add-HostDebugText -HostObject $Device  "Error with show route on Checkpoint routing." -BackgroundColor red
        return $device
    }


    foreach ($Route in $ProcessOutputObjects){
        $RouteObject=Create-RouteObject
        switch ($Route[0]){
            C{$RouteObject.RouteProtocol="connected"}
            L{$RouteObject.RouteProtocol="local"}
            S{$RouteObject.RouteProtocol="static"}
            R{$RouteObject.RouteProtocol="RIP"}
            B{$RouteObject.RouteProtocol="BGP"}
            D{$RouteObject.RouteProtocol="BGP"} #Default route in bgp
            O{$RouteObject.RouteProtocol="OSPF"}
            default{#No idea lets just assign it.
                $RouteObject.RouteProtocol=$Route[0]
            }
        }
        if($null -eq $RouteObject.RouteProtocol){ #something went wrong, we have a route without a routing protocol
            Add-HostDebugText -HostObject $Device  "Error No routing protocol:$($Route)" -BackgroundColor red
            continue
        }

        $RouteObject.Subnet="$($Route[1])/$($Route[2])"
        $RouteObject.gateway=$Route[3]
        $RouteObject.Interface=$Route[4]
        $AllRouteObjects+=$RouteObject
    }
    $device.RoutingTable=$AllRouteObjects
    return $device
}
