#The MIT License (MIT)
#
#Copyright © 2023 Myles Treadwell
#
#Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#
#The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
#
#THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#

#This file contains the starting function for processing config files and other helper functions


#Take a list of files and separate them and create file collections for each host show run, show interface,etc for that host. That way we can process them together.
#Input:List of files
#Output: Array of host object containing the files sorted by hostid.
function Create-FileHostObjects{
        param (
		[parameter(Mandatory=$true)]
		$files
    )
    #Find all the show run or show config files
    $HostIDs = $files | where { $_ -like "*.show ver*" -or $_ -like "*.show version*" } | % { ($_.name -split ".show*")[0] }
    if($HostIDs.count -eq 0){
        write-HostDebugText "No show verion files found. Please check the name of your files. e.g HostID.show run.txt" -BackgroundColor red
        Write-host 'Exiting.' -BackgroundColor red
        Start-CleanupAndExit
    }
        #Create a object to hold all the files for each host
    $ArrayOfHostIDs = $HostIDs | % { $TempHost=Create-FileObject;$TempHost.hostid=$_; $TempHost}
    foreach ($file in $files){
        foreach ( $hostid in $ArrayOfHostIDs){
            if($file.name -like "$($hostid.hostid).*"){
                if($file.name -like "*show run*" -or $file.name -like "*show config*" ){ #Checkpoint and cisco show run or show config.
                    $hostid.showrun=$file.fullname
                }

                if($file.name -like "*show cdp neighbors detail*"){
                    $hostid.ShowCDPNeighborsDetails=$file.fullname
                    break
                }
                if($file.name -like "*show ip interface brief*"){
                    $hostid.ShowIPInterfaceBrief=$file.fullname
                    break
                }
                if($file.name -like "*show interface status*"){
                    $hostid.ShowInterfaceStatus=$file.fullname
                    break
                }
                if($file.name -like "*show interfaces detail*"){
                    $hostid.ShowInterfaceDetail=$file.fullname
                    break
                }
                if($file.name -like "*show interface.txt" ){
                    $hostid.ShowInterface=$file.fullname
                    break
                }
                if($file.name -like "*show mac address-table*"){
                    $hostid.ShowMacAddressTable=$file.fullname
                    break
                }
                if($file.name -like "*show spanning-tree interface*"){
                    $hostid.ShowSpanningTreeInterface=$file.fullname
                    break
                }
                if($file.name -like "*show spanning-tree bridge*"){
                    $hostid.JunosShowSpanningTreeBridgeFromXML=$file.fullname
                    break
                }                
                if($file.name -like "*show spanning-tree*"){
                    $hostid.ShowSpanningTree=$file.fullname
                    break
                }
                if($file.name -like "*show ip route vrf*"){
                    $hostid.ShowIPRouteVRFstar=$file.fullname
                    break
                }
                if($file.name -like "*show ip route*"){
                    $hostid.ShowIPRoute=$file.fullname
                    break
                }
                if($file.name -like "*show route all*"){ #Checkpoint routing table
                    $hostid.ShowRouteAll=$file.fullname
                    break
                }
                if($file.name -like "*show route*" ){ #Cisco routing table
                    $hostid.CiscoASAShowRoute=$file.fullname
                    break
                }
                if($file.name -like "*show lldp neighbors detail*"){
                    $hostid.ShowLLDPNeighborsDetails=$file.fullname
                    break
                }
                if($file.name -like "*show lldp neighbors*"){
                    $hostid.ShowLLDPNeighbors=$file.fullname
                    break
                }

                if($file.name -like "*show version*"){
                    $ShowVersionText=get-content $file.fullname -raw  
                    
                    
                    $hostid.ShowVersion=$file.fullname
                    if(($ShowVersionText | Select-String "Check Point Gaia").Matches.Success){
                        $hostid.DeviceType="CheckPoint"
                        break
                    }elseif(($ShowVersionText | Select-String "Cisco Adaptive Security Appliance").Matches.Success){
                        $hostid.DeviceType="CiscoASA"
                        break
                    }elseif(($ShowVersionText | Select-String "Cisco IOS Software").Matches.Success -or ($ShowVersionText | Select-String "Cisco Nexus Operating System").Matches.Success){
                        $hostid.DeviceType="Cisco"
                        break
                    }elseif(($ShowVersionText | Select-String "Junos").Matches.Success -or ($ShowVersionText | Select-String "junos").Matches.Success -or ($ShowVersionText | Select-String "JUNOS Base OS boot").Matches.Success){
                        $hostid.DeviceType="Junos"
                        break
                    }else{
                        write-HostDebugText "Could not find type of device or unsupported device type."
                        write-host "Exiting. You need to fix this manually by either removing theses files $($file.fullname) or fixing them so the show version file is supported by this script."  -BackgroundColor red
                        Start-CleanupAndExit
                        break
                    }
                }
                if($file.name -like "*show ip arp*"){
                    $hostid.ShowIPArp=$file.fullname
                    break
                }
                #if($file.name -like "*show interface*"){ #Checkpoint and cisco show interfaces
                #    $hostid.ShowInterface=$file.fullname
                #    break
                #}
            }
        }
    }
    return $ArrayOfHostIDs
}

#This functions start the processing of files. This function requires the global variable $GDirectory to start.
#Input:Global variables.
#Output: A series of objects containing the processed config from the show commands. See ObjectFunctions.ps1 for the definitions of each object.
function Start-ProcessingFiles(){
    $files = Get-ChildItem $GDirectory -File -Recurse
    [Array]$ArrayOfObjects=@() #Array of hosts all their networks,interfaces, bgp,cdp,etc
    [Array]$ArrayOfNetworks=@() #List of unique networks shared across all devices.
    [Array]$ArrayOfCDPDeviceIDs=@() #List of all cdp neighbor in host object form.
    [Array]$ArrayOfLLDPDeviceIDs=@() #List of LLDP neighbors in host object form
    [Array]$ArrayOfIPApr=@() #List on unique ip arp entries.
    [Array]$ArrayofGatewayHosts=@() #List of gateway objects. These are all of the endpoints for all routes.



    $ArrayOfHostIDs = Create-FileHostObjects -files $files

    foreach ( $hostid in $ArrayOfHostIDs){
        write-HostDebugText "$($hostid.HOSTID):" -ForegroundColor "green"

        switch($hostid.DeviceType){
            "Cisco"{
                $Device=Process-CiscoHostFiles -hostid $hostid -ArrayOfObjects $ArrayOfObjects
                $Device.DeviceType="Cisco"
            }
            "CiscoASA"{
                $Device=Process-CiscoASAHostFiles -hostid $hostid -ArrayOfObjects $ArrayOfObjects
                $Device.DeviceType="CiscoASA"
            }
            "CheckPoint"{
                $Device=Process-CheckPointHostFiles -hostid $hostid -ArrayOfObjects $ArrayOfObjects
                $Device.DeviceType="CheckPoint"
            }
            "Junos"{
                $Device=Process-JunosHostFiles -hostid $hostid -ArrayOfObjects $ArrayOfObjects
                $Device.DeviceType="Junos"
            }
            default{
                write-host "We dont have a device type skipping. This should never happen. Either you broke the universe or i made a programming error. $($hostid)" -BackgroundColor red
            }
        }
        $ArrayOfObjects+=,$Device
        $ArrayOfNetworks+=$Device.ArrayOfNetworks
    }
    write-HostDebugText "Processing Arp Entries" -ForegroundColor green
    #Create an array of ip ARP entries. This will be used when drawing layer 3 diagrams.
    $ArrayOfIPApr=$ArrayOfObjects | % {$_.IPArpEntries } | sort -Unique mac,ipaddress,interface


    write-HostDebugText "Processing Cluster ip addresses for checkpoint if any. " -ForegroundColor green
    #Find virtual interfaces on checkpoints. This could probably be expanded to other devices as needed if we lack information.
    foreach ($Device in $ArrayOfObjects |where {$_.DeviceType -eq "CheckPoint" }){
        foreach ($interface in $Device.interfaces){
            if($ArrayOfIPApr | where { $interface.macaddress -eq $_.mac} | where { $interface.ipaddress -ne $_.ipaddress}){
                $interface.ClusterIP=($ArrayOfIPApr | where { $interface.macaddress -eq $_.mac}| where { $interface.ipaddress -ne $_.ipaddress}).ipaddress
            }
        }
    }



    #Pre-Calculate all of the routes that flow out from an interface and sort them on the interface.
    #This is put here to reduce the amount of logic in other parts of the scrip
    write-HostDebugText "Calculating routes on each interface." -ForegroundColor green
    foreach ($Device in $ArrayOfObjects){
        foreach ($interface in $Device.interfaces | where { $_.ipaddress -and $_.shutdown -eq $false -and $_.IntStatus -notlike "*down*"}){
            $interface.RoutesForInterface=$Device.RoutingTable| where { $_.interface -eq $interface.Interface -and $_.routeprotocol -notmatch "local|connected|direct" } | sort gateway,subnet
            #$Device.RoutingTable| where { !($_.interface) -and $_.routeprotocol -notmatch "local|connected|direct"} 
        }
    }


    write-HostDebugText "Processing Network Objects" -ForegroundColor green
    #Create a list of all networks shared across all devices.
    #Remove duplicates
    $ArrayOfNetworks = $ArrayOfNetworks | sort cidr -Unique |sort vlan
    #Add a color for every network
    $ArrayOfNetworks | % { $_.color = "$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0)" }
    $ArrayOfNetworks = $ArrayOfNetworks | sort  NumberOfConnectors,vlan,cidr
    #Count the number of connectors to each network.
    foreach ($Device in $ArrayOfObjects){
        foreach ($interface in ($Device.interfaces | where { $null -ne $_.ipaddress   -and $_.shutdown -eq $false})){
            #Find vlan to connect to
            foreach ($network in $ArrayOfNetworks){
                if($interface.cidr -eq $network.cidr){
                    $network.NumberOfConnectors++
                    if($network.Routedvlan -eq "no vlan" -and $interface.Routedvlan -ne "no vlan"){
                        $network.Routedvlan = "vlan$($interface.Routedvlan)"
                    }
                    if($interface.RoutesForInterface.count -ne 0){
                        $network.NumberOfRoutedConnectors++
                    }
                    break
                }
            }
        }
    }


    #We don't care about vlans that have no layer 3 interface in the array of networks.
    $ArrayOfNetworks= $ArrayOfNetworks| where {$_.NumberOfConnectors -gt 0}
    write-HostDebugText "Processing network layer 3 ARP Entries and VLAN names" -ForegroundColor green
    #Get the name of the vlan and add the ARP entries to the object
    foreach ($network in $ArrayOfNetworks){
        foreach ($Device in $ArrayOfObjects){
            foreach ($vlan in ($Device.vlans| where{ $null -ne $_.name -and $_.name -ne "" -and $_.name -ne "No name"})){
                if($vlan.number -eq ($Network.RoutedVlan -replace "vlan",'')){
                    if($Network.NetworkName ){#if there are multiple names for the same vlan concat them.
                        if($Network.NetworkName -like "*$($vlan.name)*"){
                            break
                        }
                        $Network.NetworkName="$($Network.NetworkName)  -  $($vlan.name)"
                    }else{
                        $Network.NetworkName=$vlan.name
                    }
                    break
                }
            }
        }
        #This can be really slow don't process it if we don't need to.
        if($GDrawAprEntries){
            #Get all the ARP entries and attach them to the network object
            $network.ARPEntries=$ArrayOfIPApr | where {$_.cidr -eq $Network.cidr }
        }
    }


    write-HostDebugText "Linking cdp neighbours we have config for together" -ForegroundColor green
    foreach ($Device in $ArrayOfObjects){
        foreach ( $cdpneighbor in $Device.cdpneighbors){
            if($null -eq $cdpneighbor.SystemName   -or $cdpneighbor.SystemName -eq ""){
                if($ArrayOfObjects | where { $_.hostname -eq ($cdpneighbor.DeviceID -replace "\(.*?\)",'' -replace "(.*?)\..*",'$1').trim() } | %{ $_.interfaces} | where { $_.interface -eq  $cdpneighbor.InterfaceRemoteDevice }){
                #($LLDPNeighbor.Hostname -replace "\(.*?\)",''
                #Remove serial numbers that get put into hostnames in CDP or LLDP
                #-replace "(.*?)\..*",'$1')
                #Remove domain names.
                    $cdpneighbor.PartnerEthernetInterface = [ref]($ArrayOfObjects | where { $_.hostname -eq ($cdpneighbor.DeviceID -replace "\(.*?\)",'' -replace "(.*?)\..*",'$1').trim() } | %{ $_.interfaces} | where { $_.interface -eq  $cdpneighbor.InterfaceRemoteDevice })
                    ($ArrayOfObjects | where { $_.hostname -eq ($cdpneighbor.DeviceID -replace "\(.*?\)",'' -replace "(.*?)\..*",'$1').trim() } | %{ $_.interfaces} | where { $_.interface -eq  $cdpneighbor.InterfaceRemoteDevice } ).IsLinkedToByCDPorLLDP = $true
                    #write-HostDebugText "My Host:$(($ArrayOfObjects | where { $_.hostname -eq ($cdpneighbor.DeviceID -replace "\(.*?\)",'' -replace "(.*?)\..*",'$1').trim() } ).hostname)"
                    #write-HostDebugText "My partner interface:$($ArrayOfObjects | where { $_.hostname -eq ($cdpneighbor.DeviceID -replace "\(.*?\)",'' -replace "(.*?)\..*",'$1').trim() } | %{ $_.interfaces} | where { $_.interface -eq  $cdpneighbor.InterfaceRemoteDevice })"
                    #write-HostDebugText "My interface:$($cdpneighbor.PartnerEthernetInterface|ft|out-string)"
                    #write-HostDebugText "Match DeviceID: $($Device.hostname) - $($cdpneighbor.DeviceID) - $($cdpneighbor.InterfaceRemoteDevice) ---- $(($ArrayOfObjects | where { $_.hostname -eq ($cdpneighbor.DeviceID -replace "\(.*?\)",'' -replace "(.*?)\..*",'$1').trim() } | %{ $_.interfaces} | where { $_.interface -eq  $cdpneighbor.InterfaceRemoteDevice }).interface)"
                }
            }else{
                if( $ArrayOfObjects | where { $_.hostname -eq $cdpneighbor.SystemName} | %{ $_.interfaces} | where { $_.interface -eq  $cdpneighbor.InterfaceRemoteDevice } ){
                    $cdpneighbor.PartnerEthernetInterface = [ref]($ArrayOfObjects | where { $_.hostname -eq $cdpneighbor.SystemName} | %{ $_.interfaces} | where { $_.interface -eq  $cdpneighbor.InterfaceRemoteDevice } )
                    ($ArrayOfObjects | where { $_.hostname -eq $cdpneighbor.SystemName} | %{ $_.interfaces} | where { $_.interface -eq  $cdpneighbor.InterfaceRemoteDevice } ).IsLinkedToByCDPorLLDP = $true
                    #write-HostDebugText $cdpneighbor.PartnerEthernetInterface
                    #write-HostDebugText "Match SystemName: $($Device.hostname) - $($cdpneighbor.SystemName) - $($cdpneighbor.InterfaceRemoteDevice) ---- $(($ArrayOfObjects | where { $_.hostname -eq $cdpneighbor.SystemName} | %{ $_.interfaces} | where { $_.interface -eq  $cdpneighbor.InterfaceRemoteDevice }).interface)"
                }
            }
        }
    }

    write-HostDebugText "Linking LLDP neighbours we have config for together" -ForegroundColor green
    #This links all of the interfaces on the LLDP nieghbors to devices we currently have config for.
    foreach ($Device in $ArrayOfObjects){
        foreach ( $LLDPNeighbor in $Device.LLDPNeighbors){
            if($null -ne $LLDPNeighbor.Hostname   -or $LLDPNeighbor.Hostname -ne ""){ #Match based on hostname
                #($LLDPNeighbor.Hostname -replace "\(.*?\)",''
                #Remove serial numbers that get put into hostnames in CDP or LLDP
                #-replace "(.*?)\..*",'$1')
                #Remove domain names.
                #Match based on interface name. 
                if($ArrayOfObjects | where { $_.hostname -eq ($LLDPNeighbor.Hostname -replace "\(.*?\)",'' -replace "(.*?)\..*",'$1').trim() } | %{ $_.interfaces} | where { $_.interface -eq  $LLDPNeighbor.InterfaceRemoteDevice }){
                    $LLDPNeighbor.PartnerEthernetInterface = [ref]($ArrayOfObjects | where { $_.hostname -eq ($LLDPNeighbor.Hostname -replace "\(.*?\)",'' -replace "(.*?)\..*",'$1').trim() } | %{ $_.interfaces} | where { $_.interface -eq  $LLDPNeighbor.InterfaceRemoteDevice })
                    #write-HostDebugText $LLDPNeighbor.PartnerEthernetInterface
                    write-HostDebugText "Match Hostname: FROM:$($Device.hostname) - to:$($LLDPNeighbor.DeviceID) - $($LLDPNeighbor.InterfaceRemoteDevice) ---- $(($ArrayOfObjects | where { $_.hostname -eq ($LLDPNeighbor.DeviceID -replace "\(.*?\)",'' -replace "(.*?)\..*",'$1').trim() } | %{ $_.interfaces} | where { $_.interface -eq  $LLDPNeighbor.InterfaceRemoteDevice }).interface)"
                    continue
                }
                #Junos advertises the description rather then the port if there is a port description. So we can match on the port description if we have one and if we have the config of the device.
                #duplicates will result in multiple matches.
                if($ArrayOfObjects | where { $_.hostname -eq ($LLDPNeighbor.Hostname -replace "\(.*?\)",'' -replace "(.*?)\..*",'$1').trim() } | %{ $_.interfaces} | where { $_.description -eq  $LLDPNeighbor.InterfaceRemoteDevice}){
                    $LLDPNeighbor.PartnerEthernetInterface = [ref]($ArrayOfObjects | where { $_.hostname -eq ($LLDPNeighbor.Hostname -replace "\(.*?\)",'' -replace "(.*?)\..*",'$1').trim() } | %{ $_.interfaces} | where { $_.description -eq  $LLDPNeighbor.InterfaceRemoteDevice})
                    write-HostDebugText "Match Desciption Hostname from: $($Device.hostname) - to: "
                    write-HostDebugText "$($LLDPNeighbor.Hostname) - "
                    write-HostDebugText "$($LLDPNeighbor.InterfaceRemoteDevice) ---- "
                    write-HostDebugText "$($ArrayOfObjects | where { $_.hostname -eq ($LLDPNeighbor.Hostname -replace "\(.*?\)",'' -replace "(.*?)\..*",'$1').trim() } | %{ $_.interfaces} | where { $_.description -eq  $LLDPNeighbor.InterfaceRemoteDevice})"
                    continue
                }
            }else{
                #Search for management ip on hosts. Maybe we will get a match. 
                $HostnameWithManagementIP=$ArrayOfObjects | %{
                    $found=$false
                    foreach ($IP in $_.ArrayOfIPAddresses){
                        if ($IP -eq $LLDPNeighbor.ManagementIP){
                            $found=$true
                            break
                        }
                    }
                }

                if( $HostnameWithManagementIP ){
                    $LLDPNeighbor.PartnerEthernetInterface = [ref]($ArrayOfObjects | where { $_.hostname -eq $HostnameWithManagementIP} | %{ $_.interfaces} | where { $_.interface -eq  $LLDPNeighbor.InterfaceRemoteDevice } )
                    #write-HostDebugText $LLDPNeighbor.PartnerEthernetInterface
                    #write-HostDebugText "Match ManagementIPs Hostname: $($LLDPNeighbor.ManagementIP) FROM:$($Device.hostname) - to:$($LLDPNeighbor.Hostname) - $($LLDPNeighbor.InterfaceRemoteDevice) ---- $(($ArrayOfObjects | where { $_.hostname -eq $LLDPNeighbor.Hostname} | %{ $_.interfaces} | where { $_.interface -eq  $LLDPNeighbor.InterfaceRemoteDevice }).interface)"
                }
            }          
        }
    }

    write-HostDebugText "Creating host objects for cdpneighbors we don't have config for" -ForegroundColor green
    #These are cdp neighbors we don't have a config for but we know a little bit about.
    #This creates an array of host objects so that we can draw them as standard hosts.
    foreach ($Device in $ArrayOfObjects){
        foreach ( $cdpneighbor in ($Device.cdpneighbors | where { !$_.PartnerEthernetInterface } | sort -Descending -property @{Expression={[int]($_.InterfaceLocalDevice -replace '[a-zA-Z-]+','' -replace "/",'')} } )){ #sort order here is important as this is the order in which we will draw them
            if($GConsolidateNeighbors -and ($ArrayOfCDPDeviceIDs | where { $_.hostname -eq $cdpneighbor.DeviceID })){
                $CDPObject=$ArrayOfCDPDeviceIDs | where { $_.hostname -eq $cdpneighbor.DeviceID }
                $InterfaceObject=Create-InterfaceObejct
                $InterfaceObject.interface=$cdpneighbor.InterfaceRemoteDevice
                $InterfaceObject.shutdown = $false
                $CDPObject.Interfaces+=$InterfaceObject
                foreach ($ipaddress in $cdpneighbor.InterfaceIPAddresses){
                    [Array]$CDPObject.ArrayOfIPAddresses+=[Array]$ipaddress
                }
            }else{
                $CDPObject=Create-HostObject
                $CDPObject.Origin="CDP"
                [Array]$CDPObject.ArrayOfIPAddresses=@()
                $CDPObject.Interfaces=@()
                $CDPObject.HostName=$cdpneighbor.DeviceID
                $CDPObject.Version=$cdpneighbor.Version
                $CDPObject.Platform=$cdpneighbor.Platform
                $CDPObject.Capabilities=$cdpneighbor.Capabilities
                $CDPObject.ParentObject=$cdpneighbor.ParentObject #The first object we have will be the parent object if there are multiple parent objects.
                $CDPObject.Description="`r`n$($cdpneighbor.Platform)`r`n$($cdpneighbor.Version)`r`n$($SystemName)"
                $InterfaceObject=Create-InterfaceObejct
                $InterfaceObject.interface=$cdpneighbor.InterfaceRemoteDevice
                $InterfaceObject.shutdown = $false
                $CDPObject.Interfaces+=$InterfaceObject
                foreach ($ipaddress in $cdpneighbor.InterfaceIPAddresses){
                    [Array]$CDPObject.ArrayOfIPAddresses+=[Array]$ipaddress
                }
                $CDPObject.ArrayOfIPAddresses = $CDPObject.ArrayOfIPAddresses | sort -Unique
                $ArrayOfCDPDeviceIDs+=$CDPObject
            }
        }
    }

    write-HostDebugText "Creating host objects for LLDP neighbours we don't have config for" -ForegroundColor green
    #These are LLDP neighbours we don't have a config for but we know a little bit about.
    #This creates an array of host objects so that we can draw them as standard hosts.
    foreach ($Device in $ArrayOfObjects){
        foreach ( $LLDPNeighbor in ($Device.LLDPNeighbors | where { !$_.PartnerEthernetInterface } | sort -Descending InterfaceLocalDevice)){ #sort order here is important as this is the order in which we will draw them
            if($LLDPNeighbor.HasCDPNeighborEntry ){#Skip objects we have already drawn in CDPNeighbors
                continue
            }
            #If we are consolidating the neighbor so we get one object with multiple interfaces we need to
            #check to see if we have already made a object for this neighbor that we just need to add interfaces to.
            #The order in which to match.
            $MatchField=$null
            if($LLDPNeighbor.HostName){
                $MatchField=($ArrayOfLLDPDeviceIDs | where { $_.HostName -eq $LLDPNeighbor.HostName })
            }else{
                $MatchField=($ArrayOfLLDPDeviceIDs | where { $_.ChassisID -eq $LLDPNeighbor.ChassisID })
            }
            if($GConsolidateNeighbors -and $MatchField){
                $LLDPObject=$MatchField
                $InterfaceObject=Create-InterfaceObejct
                $InterfaceObject.interface=$LLDPNeighbor.InterfaceRemoteDevice
                $InterfaceObject.shutdown = $false
                $LLDPObject.Interfaces+=$InterfaceObject
                [Array]$LLDPObject.ArrayOfIPAddresses+=[Array]$LLDPNeighbor.ManagementIP
            }else{
                $LLDPObject=Create-HostObject
                $LLDPObject.Origin="LLDP"
                $LLDPObject.Interfaces=@()
                [Array]$LLDPObject.ArrayOfIPAddresses=@()
                $LLDPObject.HostName=$LLDPNeighbor.Hostname
                $LLDPObject.ParentObject=$LLDPNeighbor.ParentObject #The first object we have will be the parent object if there are multiple parent objects.
                $InterfaceObject=Create-InterfaceObejct
                $InterfaceObject.interface=$LLDPNeighbor.InterfaceRemoteDevice
                $InterfaceObject.shutdown = $false
                $LLDPObject.Interfaces+=$InterfaceObject
                if($LLDPNeighbor.ManagementIP){
                    [Array]$LLDPObject.ArrayOfIPAddresses+=[Array]$LLDPNeighbor.ManagementIP
                }
                $LLDPObject.Description="`r`n$($LLDPNeighbor.SystemDescription)`r`n$($LLDPNeighbor.CAPABILITIES)`r`n$($LLDPNeighbor.ManagementIP)`r`n$($LLDPNeighbor.$SERIAL)"
                $ArrayOfLLDPDeviceIDs+=$LLDPObject
            }
            $LLDPObject.ArrayOfIPAddresses=$LLDPObject.ArrayOfIPAddresses | sort -Unique
        }
    }

    #Find spanning root bridges for each device.
    write-HostDebugText "Getting Spanning tree root bridge for each device." -ForegroundColor green
    foreach ($Device in $ArrayOfObjects){
        if($Device.SpanningTree){#Does this device have some kindof spanning-tree?
            $Device.SpanningTree.RootBridgeForvlans=$Device.SpanningTree.SpanningTreeArray | where { $null -ne $_.rootbridge } | %{[int]$_.vlanid}
            #Do we have a spanning tree mode set. Nexus switches don't have commands like "spanning-tree mode pvst" in show run with a default config.
            #Pull the mode off one of the interfaces if this is the case.
            if($null -eq $Device.SpanningTree.SpanningTreeMode -or $Device.SpanningTree.SpanningTreeMode -eq ""){
                $Device.SpanningTree.SpanningTreeMode = $Device.SpanningTree.SpanningTreeArray | where { $null -ne $_.protocol -or $_.protocol -ne "" } | select -first 1 | % {$_.protocol}
            }
        }
    }

    #This is the matching logic behind linking interfaces which have a gateway so we can draw a route diagram.
    #This bit of code is used to search for the matching interfaces of hosts we know about to enable the linking of a route from one interface to another.
    #If we don't find a interface we then search cdp/lldp and then the arp table to find out where the gateway is.
    #We then create ARP host object entries so we can draw them.
    #This enables us to lastly draw the route link and the gateway device.
    write-HostDebugText "Linking Layer 3 interfaces to Gateways and creating ARP hosts." -ForegroundColor green
    $LastGateway=$null
    foreach ($device in $ArrayOfObjects){
        foreach ($interface in $device.interfaces |where { $_.RoutesForInterface}){
            :Outer foreach ($route in ($interface.RoutesForInterface|where { $_.gateway}| sort gateway)){
                if($LastGateway.gateway -eq $Route.gateway){#We have already found this gateway. Just assign it.
                    $Route.GatewayLink=$LastGateway.GatewayLink
                    continue #We can skip because we already have
                }
                $LastGateway=$Route

                #Find the interface we need to connect to
                if($ArrayOfObjects | % {$_.interfaces }  | where { $_.IPaddress -eq $route.gateway }){
                    $Route.GatewayLink=[ref]($ArrayOfObjects | % {$_.interfaces }  | where { $_.IPaddress -eq $route.gateway })
                    continue #We can skip because we already have

                }
                if($ArrayOfObjects | % {$_.interfaces }  | where { $_.ClusterIP -eq $route.gateway }){
                    $Route.GatewayLink=[ref]($ArrayOfObjects | % {$_.interfaces }  | where { $_.ClusterIP -eq $route.gateway }|select -first 1)
                    continue #We can skip because we already have

                }
                if($ArrayOfObjects | % {$_.interfaces }  | where { $_.Standbyip -eq $route.gateway }){
                    $Route.GatewayLink=[ref]($ArrayOfObjects | % {$_.interfaces }  | where { $_.Standbyip -eq $route.gateway }|select -first 1)
                    continue #We can skip because we already have

                }
                if($ArrayOfObjects | % {$_.interfaces }  | where { $_.SecondaryIPAddress -eq $route.gateway }){
                    $Route.GatewayLink=[ref]($ArrayOfObjects | % {$_.interfaces }  | where { $_.SecondaryIPAddress -eq $route.gateway })
                    continue #We can skip because we already have

                }


                #Search for the gateway in the $ArrayofGatewayHosts list and skip it if we have already created it.
                if($ArrayofGatewayHosts | % {$_.arrayofipaddresses} | where { $_ -eq $Route.gateway }){
                    write-HostDebugText "$($ipaddress) -- $($Route.gateway)"
                    continue
                }
                #Create a entry in $ArrayofGatewayHosts.
                $NewObjectToCreate= $device.IPArpEntries | where { $Route.gateway -eq $_.ipaddress}
                if($NewObjectToCreate){
                    $HostGatewayObject=Create-HostObject
                    $HostGatewayObject.Origin="ARP"
                    [array]$HostGatewayObject.arrayofipaddresses+=[array]$NewObjectToCreate.ipaddress
                    $HostGatewayObject.hostname="$($NewObjectToCreate.VendorCompanyName)`r`n$($NewObjectToCreate.MAC)"
                    if($NewObjectToCreate.INTERFACE -like "*vlan*"){
                        $interfaceObject = Create-InterfaceObejct
                        $interfaceObject.shutdown=$false
                        $interfaceObject.interface="Unknown Interface using:`r`n$($NewObjectToCreate.INTERFACE)"
                        $interfaceObject.IPAddress=$NewObjectToCreate.ipaddress
                        $interfaceObject.cidr=$interface.cidr #Use the parent hosts CIDR as we don't have that information.
                        $HostGatewayObject.interfaces+=$interfaceObject
                    }else{
                        $interfaceObject = Create-InterfaceObejct
                        $interfaceObject.shutdown=$false
                        $interfaceObject.interface="Unknown Interface"
                        $interfaceObject.IPAddress=$NewObjectToCreate.ipaddress
                        $interfaceObject.cidr=$interface.cidr #Use the parent hosts CIDR as we don't have that information.
                        $HostGatewayObject.interfaces+=$interfaceObject
                    }
                }else{#We don't have any details. So just create a host object.
                    $HostGatewayObject=Create-HostObject
                    $HostGatewayObject.Origin="RoutingTable"
                    $HostGatewayObject.hostname="Unknown`r`n$($Route.gateway)"
                    [array]$HostGatewayObject.arrayofipaddresses+=[array]$Route.gateway
                    $interfaceObject = Create-InterfaceObejct
                    $interfaceObject.shutdown=$false
                    $interfaceObject.interface="Unknown Interface"
                    $interfaceObject.IPAddress=$Route.gateway
                    $interfaceObject.cidr=$interface.cidr #Use the parent hosts CIDR as we don't have that information.
                    $HostGatewayObject.interfaces+=$interfaceObject
                }
                #Search for the gateway in the list of devices that are in CDP/lldp for or if this interface is attached directly to a device we have lldp or cdp for. AKA routed ports.
                :CDP foreach ($CDPDevice in $ArrayOfCDPDeviceIDs){
                    foreach ($ip in $CDPDevice.ArrayOfIPAddresses){
                        if($route.gateway -eq $ip){
                            $Route.GatewayLink=[ref]$CDPDevice
                            $HostGatewayObject.Description =$CDPDevice.Description
                            [array]$HostGatewayObject.arrayofipaddresses+=$CDPDevice.arrayofipaddresses| %{ $_.ipaddress }
                            break :CDP
                        }
                    }
                }
                :LLDP foreach ($LLDPDevice in $ArrayOfLLDPDeviceIDs){
                    foreach ($ip in $LLDPDevice.ArrayOfIPAddresses){
                        if($route.gateway -eq $ip){
                            $Route.GatewayLink=[ref]$LLDPDevice
                            $HostGatewayObject.Description=$LLDPDevice.Description
                            [array]$HostGatewayObject.arrayofipaddresses+=$LLDPDevice.arrayofipaddresses| %{ $_.ipaddress }
                            break :LLDP
                        }
                    }
                }
                #write-HostDebugText "Created host: $($HostGatewayObject.arrayofipaddresses) - $($HostGatewayObject.hostname)"
                $ArrayofGatewayHosts+=$HostGatewayObject
                $Route.GatewayLink=[ref]$interfaceObject
            }
        }
    }




    return $ArrayOfNetworks,$ArrayOfObjects,$ArrayOfCDPDeviceIDs,$ArrayOfLLDPDeviceIDs,$ArrayOfIPApr,$ArrayofGatewayHosts
}




