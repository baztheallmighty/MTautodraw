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

#This file contains all of the functions that process Cisco ASA config.


#This functions calls all the other functions to process all of the files for a Cisco ASA devices.
#Input: Hostid object.
#Output: $device object.
function Process-CiscoASAHostFiles{
        param (
		[parameter(Mandatory=$true)]
		$hostid,
        $ArrayOfObjects
    )
        write-HostDebugText "Processing Cisco ASA show config"
        $Device=$null
        if($hostid.showrun -and (Test-Path -Path $hostid.showrun)){
            $config = Get-Content -Path $hostid.showrun -raw
            $Device=Get-CiscoASAShowRunFromText -Lconfig $config
            $Device.DeviceIdentifier=($hostid.showrun -replace "\.show run.*",'' -replace "^.*\\",'' -replace "\.show configuration.*",'' )
        }else{
            write-HostDebugText "File doesn't exist: $($hostid.showrun)" -BackgroundColor red
            return $null
        }
        if($null -eq $Device.hostname ){
            write-HostDebugText "Can't find hostname in file skipping host: $($hostid.showrun)" -BackgroundColor red
            return $null
        }
        foreach ($ExistingDevice in $ArrayOfObjects){
            if($ExistingDevice.hostname -eq $Device.hostname){
                write-HostDebugText "Hostname already exists $($ExistingDevice.hostname) - $($Device.hostname). This means you either have the same code twice in the folder or someone has named two devices the same. This script requries unquie hostnames." -BackgroundColor red
                write-HostDebugText "Found problem at: $($hostid.HOSTID)" -BackgroundColor red
                write-HostDebugText "Existing HostID's:$($ArrayOfHostIDs | ft HOSTID,showrun | out-string)"
                write-HostDebugText "$($ArrayOfObjects|ft hostname)"
                if(!($SkipHostnameErrorCheck)){
                    Write-host 'Exiting please manually fix this error.' -BackgroundColor red
                    Start-CleanupAndExit
                }
            }
        }
        if($hostid.ShowInterface){
            write-HostDebugText "Processing Cisco ASA show interface:$($hostid.ShowInterface)"
            $Device=Get-CiscoASAShowInterfaceFromText -CiscoASAInterfaceFile $hostid.ShowInterface -Device $Device
        }
        if($hostid.CiscoASAShowRoute){
            write-HostDebugText "Processing Cisco ASA show show route:$($hostid.CiscoASAShowRoute)"
            $device=Get-CiscoASAShowRouteFromText -device $device -ShowRouteFile $hostid.CiscoASAShowRoute
        }
        
        if($hostid.ShowIPBGPSummary){
            write-HostDebugText "Processing Cisco ASA show bgp summary:$($hostid.ShowIPBGPSummary)"
            $Device=Get-BGPSummaryFromText -BGPSummaryFile $hostid.ShowIPBGPSummary -Device $Device
        }
        
        return $device
}


#Read in the Cisco ASA config. and process it.
#Note:These is limited processing of the show config for now. This will be expanded in future as required.
function Get-CiscoASAShowRunFromText{
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
        $hostname = "NoHostNameFoundCheckForConfigProblems"
        write-host "No hostname found in Cisco ASA config"  -BackgroundColor red
    }
    $HostObject.hostname = $hostname
    return $HostObject
}


#Get all of the interfaces out of the show interfaces all command.
#Input:show interfaces all file
#Output:Interfaces objects.
#Notes:
#$int[0]=INTERFACE
#$int[1]=INTERFACE_ZONE
#$int[2]=LINK_STATUS
#$int[3]=PROTOCOL_STATUS
#$int[4]=HARDWARE_TYPE
#$int[5]=BANDWIDTH
#$int[6]=DELAY
#$int[7]=DUPLEX
#$int[8]=SPEED
#$int[9]=DESCRIPTION
#$int[10]=ADDRESS
#$int[11]=MTU
#$int[12]=VLAN
#$int[13]=IP_ADDRESS
#$int[14]=NET_MASK
#$int[15]=ONEMIN_IN_PPS
#$int[16]=ONEMIN_IN_RATE
#$int[17]=ONEMIN_OUT_PPS
#$int[18]=ONEMIN_OUT_RATE
#$int[19]=ONEMIN_DROP_RATE
#$int[20]=FIVEMIN_IN_PPS
#$int[21]=FIVEMIN_IN_RATE
#$int[22]=FIVEMIN_OUT_PPS
#$int[23]=FIVEMIN_OUT_RATE
#$int[24]=FIVEMIN_DROP_RATE
function Get-CiscoASAShowInterfaceFromText(){
    param (
        [parameter(Mandatory=$true)]
        $CiscoASAInterfaceFile,
        $Device
    )
    $ArrayOfHostNetworks=@()
    $interfaces = @()
    #Read the file into one big string
    $CiscoASAInterfaceText = Get-Content -raw $CiscoASAInterfaceFile
    if(($CiscoASAInterfaceText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:|LLDP is not enabled)").Matches.Success){
        write-HostDebugText "$($CiscoASAInterfaceText)" -BackgroundColor Magenta
        write-HostDebugText "contains invalid data or is empty"  -BackgroundColor red
        return $device
    }

    $ProcessOutputObjects=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.CiscoASAShowInterfaceTemplate -ShowFile $CiscoASAInterfaceFile -ReturnArray $true
    if($ProcessOutputObjects -eq "ERROR"){
        write-HostDebugText "Error with Show Interface on Cisco ASA file:$($CiscoASAInterfaceFile)"
        return $device
    }
    foreach ($int in $ProcessOutputObjects){
        $interfaceObject = Create-InterfaceObject
        $interfaceObject.Interface=$int[0]
        $interfaceObject.zone=$int[1]
        if($int[2] -eq "up"){
            $interfaceObject.shutdown=$false
        }else{
            $interfaceObject.shutdown=$true
        }
        $interfaceObject.IntStatus=$int[2]
        $interfaceObject.INTProtocolStatus=$int[3]

        $interfaceObject.speed=$int[8]
        $interfaceObject.Description=$int[9]

        if($int[13]){

            $interfaceObject.IPAddress=$int[13]

            $interfaceObject.SubnetMask=Covert-NetMaskToCIDR -SubnetMask $int[14]

            $interfaceObject.Cidr = (Get-IPv4Subnet -IPAddress $interfaceObject.IPAddress -PrefixLength $interfaceObject.SubnetMask).cidrid
            $interfaceObject.SwitchPortType="Routed"
            if($null -ne $interfaceObject.Cidr){
                $NetworkObject = Create-NetworkObject
                $NetworkObject.Cidr = $interfaceObject.Cidr
                $NetworkObject.NetworkName = $interfaceObject.Description #This is probably not very good from a viewing point of view as this is not really a name but a description.
                if($interfaceObject.Interface -like "*.*"){#we have a sub interface. Lets split out the vlan.
                    $NetworkObject.Routedvlan = "vlan$(($interfaceObject.Interface -split '\.')[1])"
                }else{
                    $NetworkObject.Routedvlan = "no vlan"
                }
                $ArrayOfHostNetworks += $NetworkObject
            }
        }
        $interfaces += $interfaceObject

    }

    $ArrayOfHostNetworks | % { $_.color = "$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0)" }
    $device.ArrayOfNetworks=$ArrayOfHostNetworks
    $device.interfaces = $interfaces
    return $device
}



#Process the show route from a Cisco ASA
#Input:Cisco ASA show route all file
#Output: Routing table object.
#Notes:
#$int[0]=PROTOCOL
#$int[1]=TYPE
#$int[2]=NETWORK
#$int[3]=MASK
#$int[4]=DISTANCE
#$int[5]=METRIC
#$int[6]=NEXTHOPIP
#$int[7]=NEXTHOPIF
#$int[8]=UPTIME
function Get-CiscoASAShowRouteFromText(){
    param (
        [parameter(Mandatory=$true)]
        $ShowRouteFile,
        $Device
    )
    #Read the file into one big string
    $ShowRouteText = Get-Content -raw $ShowRouteFile
    $AllRouteObjects=@() #Array of routes(Create-RouteObject) that will be passed back to the host object.
    if(($ShowRouteText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:)").Matches.Success){
        write-HostDebugText "$($ShowRouteText)" -BackgroundColor Magenta
        write-HostDebugText "contains invalid data or is empty"  -BackgroundColor red
        return $device
    }

    #write-HostDebugText "Starting Python Processing with TextFSM"
    #Start Python process with TextFSM to convert the Text to a Object
    $ProcessOutputObjects=Execute-PythonTextFSM -TextFSTETemplate $GTemplate.CiscoASAShowRouteTemplate -ShowFile $ShowRouteFile  -ReturnArray $true
    if($ProcessOutputObjects -eq "ERROR"){
        write-HostDebugText "Error with show route on Cisco ASA routing." -BackgroundColor red
        return $device
    }


    foreach ($Route in $ProcessOutputObjects){
        $RouteObject=Create-RouteObject
        switch ($Route[0]){
            C{$RouteObject.RouteProtocol="connected"}
            L{$RouteObject.RouteProtocol="local"}
            S{$RouteObject.RouteProtocol="static"}
            R{$RouteObject.RouteProtocol="RIP"}
            BGP{$RouteObject.RouteProtocol="BGP"}
            D{$RouteObject.RouteProtocol="EIGRP"}
            O{$RouteObject.RouteProtocol="OSPF"}
            i{$RouteObject.RouteProtocol="IS-IS"}
            default{#No idea lets just assign it.
                $RouteObject.RouteProtocol=$Route[0]
            }
        }
        if($null -eq $RouteObject.RouteProtocol){
            write-HostDebugText "No route protocol this shouldnt happen. Skipping: $($int)" -BackgroundColor red
            continue
        }
        if($Route[1] -ne "" -and $null -ne $Route[1]){
            $RouteObject.RouteSubType=$Route[1]
        }
        $RouteObject.Subnet="$($Route[2])/$(Covert-NetMaskToCIDR -SubnetMask $Route[3])"
        $RouteObject.DISTANCE=$Route[4]
        $RouteObject.METRIC=$Route[5]
        $RouteObject.gateway=$Route[6]
        #Find the interface based on the zone. Because multiple interfaces can be in the same zone match the subnets.
        if( $RouteObject.gateway -and ($RouteObject.gateway -ne "Null0") -and ($RouteObject.RouteProtocol -ne "local") -and ($RouteObject.RouteProtocol -ne "connected") -and ($RouteObject.RouteProtocol -ne "direct")){#these don't have gateways so don't try and find them.
            foreach ($Interface in ($Device.interfaces |where {$null -ne $_.cidr} |where { $_.cidr -ne ""} | where { $_.IntStatus -ne "down" -and $_.IntStatus -ne "down" } )){
                if((Find-Subnet -addr1 $Interface.cidr -addr2 $RouteObject.gateway).condition){
                    $RouteObject.Interface=$Interface.Interface
                    break
                }
            }
        }

        $AllRouteObjects+=$RouteObject
    }
    $device.RoutingTable=$AllRouteObjects
    return $device
}
