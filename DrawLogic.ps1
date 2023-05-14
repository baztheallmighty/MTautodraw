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


#This file has all the logic for drawing devices and connecting them.





#Draw all of the shared layer 3 networks between devices.
function Draw-AllLayer3(){
        param (
		[parameter(Mandatory=$true)]
		$ArrayOfObjects,
        $ArrayOfNetworks,
        $ArrayOfIPApr,
        $DiagramType,
        $NameOfPage,
        $ArrayofGatewayHosts
    )
    write-HostDebugText "Gateway objects:"
    write-HostDebugText $ArrayofGatewayHosts
    $ArrayOfConnectors=@()
    write-HostDebugText "Drawing all Layer3: $($NameOfPage)" -ForegroundColor green
    New-VisioPage -Name $NameOfPage

    write-HostDebugText "Drawing Layer 3 hosts" -ForegroundColor green
    $i=0 #counter host spacing
    $hostwidth=0
    foreach ($Device in $ArrayOfObjects){
        $Device,$hostwidth=Draw-HostLayer3 -Device $Device  -Location (($GStartLocationHosts[0]+$i),$GStartLocationHosts[1])
        $i=$i + $GHostLayer3Step + $hostwidth
    }


    if($DiagramType -eq "Normal" -or $DiagramType -eq "LinksOnly"){
        write-HostDebugText "Drawing networks" -ForegroundColor green
        #draw
        $i=0 #counter host spacing
        foreach ($network in $ArrayOfNetworks ){
            if($DiagramType -eq "LinksOnly" -and $network.NumberOfRoutedConnectors -eq 0){ #skip all vlans we don't want to draw.
                continue
            }
            if($network.RoutedVlan -eq "no vlan"){
                $network.shape= Draw-CustomShapeFromMTAutoStencil -shapetype "Ethernet" -ShapeText "$($network.RoutedVlan) - ($($network.cidr)`)" -Location (($GStartLocationNetwork[0]-$GNOVlanSubnetOffset),($GStartLocationNetwork[1]+$i)) -color  $network.color -size @($GVlanWidth,$GVlanHight)
            }else{
                $network.shape= Draw-CustomShapeFromMTAutoStencil -shapetype "Ethernet" -ShapeText "$($network.RoutedVlan) - $($network.NetworkName) - ($($network.cidr)`)" -Location (($GStartLocationNetwork[0]),($GStartLocationNetwork[1]+$i)) -color  $network.color -size @($GVlanWidth,$GVlanHight)
            }
            #Create a box and attach it to the vlan. This will contain a list of all the IP arp entries.
            if($GDrawAprEntries -and $network.ARPEntries){
                $ShapeText=$null
                $ShapeText="$($network.NetworkName)`r`n$($network.RoutedVlan)`r`n"
                if($GDrawAprEntriesDetails){
                    $ShapeText+="IPaddress           MAC       VendorCompanyName`r`n"
                    foreach($Entry in ($network.ARPEntries|sort VendorCompanyName)){
                        $ShapeText+="$($Entry.ipaddress)   $($Entry.mac)   $($Entry.VendorCompanyName)`r`n"
                    }
                }else{#Add summary only
                    $ShapeText+="$($network.ARPEntries | group VendorCompanyName | select count,name | sort count -Descending |  % { "$($_.name) $($_.count)`r`n"} )"
                }

                $ArpEntries=$null
                $ArpEntries=Draw-Shape -shapetype "circle" -ShapeText $ShapeText -Location (($GStartLocationNetwork[0]+$GARPEntriesOffsetX),($GStartLocationNetwork[1]+$i+$GARPEntriesSpacingHeigh)) -color  $network.color -size @(($GARPWidth),($GARPHight + ($ShapeText.count)))
                if($ArpEntries){
                    Connect-VisioShape -From $ArpEntries -To $network.shape -Master $Gdyncon_m | out-null
                }
            }
            $i=$i+$GVlanStep
            $j=$j+$VlanColorStep
        }
    }

    if($DiagramType -eq "RoutesOnly" -or $DiagramType -eq "LinksOnly"){
        write-HostDebugText "Drawing GatewayHost hosts that we have routes to" -ForegroundColor green
        $i=0 #counter host spacing
        $hostwidth=0
        foreach ($GatewayHost in $ArrayofGatewayHosts ){
            $GatewayHost,$hostwidth=Draw-HostLayer3 -Device $GatewayHost  -Location (($GStartARPLocationHosts[0]+$i),$GStartARPLocationHosts[1])  -HostType "GatewayHost"
            $i=$i + $GHostLayer3Step + $hostwidth
        }
    }
    if($DiagramType -eq "Normal" -or $DiagramType -eq "LinksOnly"){
        write-HostDebugText "Drawing connections between GatewayHosts hosts and vlans" -ForegroundColor green
        #Draw connectors between Gateway LLDP,cdp and ARP HOSTS and vlans
        foreach ($Device in $ArrayofGatewayHosts){
            write-HostDebugText "$Device.hostname"
            foreach ($interface in ($Device.interfaces | where { $null -ne $_.ipaddress -and $_.Logicalshape})){ #Don't link interfaces without a ip address and that don't have a shape object.
                if($Interface.shutdown -or $Interface.IntStatus -like "*down*"){ #Don't link shutdown interfaces
                    continue
                }

                $NetworkToConnectTo=$null
                $FromDevice=$null
                #Find vlan to connect to
                foreach ($network in $ArrayOfNetworks){
                    if($interface.cidr -eq $network.cidr){
                        $NetworkToConnectTo=$network
                        break
                    }
                }
                if(!($NetworkToConnectTo) -or $null -eq $NetworkToConnectTo.Shape){
                    if(($DiagramType -ne "LinksOnly")){
                        write-HostDebugText "Error connecting devices vlans:$($_.Exception)" -ForegroundColor green
                        write-HostDebugText "From:$($FromDevice.name) to:$($NetworkToConnectTo.cidr)" -BackgroundColor red
                    }
                    continue
                }

                #Draw connection
                try{
                    $ArrayOfConnectors+=Connect-VisioShape -From $interface.Logicalshape -To $NetworkToConnectTo.Shape -Master $Gdyncon_m
                }
                Catch{
                    write-HostDebugText "Error connecting devices vlans:$($_.Exception)" -ForegroundColor green
                    write-HostDebugText "From:$($FromDevice.name) to:$($NetworkToConnectTo.cidr)" -BackgroundColor red
                    $NetworkToConnectTo=$null
                    $FromDevice=$null
                    continue #If there is an error don't stuff up the text of another object just move on.
                }
                write-HostDebugText "From:$($interface.interface) TO:$($NetworkToConnectTo.cidr)"
                #write-HostDebugText "`rFrom:$($FromDevice) to:$($NetworkToConnectTo)"


                $shape_cells = New-VisioShapeCells
                $shape_cells.LineColor = $GColourBlack
                $shape_cells.LineWeight = "4 pt"
                $shape_cells.CharSize=$GRouteFontSize
                Set-VisioShapeCells -Shape $ArrayOfConnectors[$ArrayOfConnectors.count-1] -Cells $shape_cells
            }
        }
    }

    write-HostDebugText "Drawing connectors for Layer3" -ForegroundColor green
    #Draw connectors between hosts and vlans
    foreach ($Device in $ArrayOfObjects){
        write-HostDebugText $Device.hostname
        foreach ($interface in ($Device.interfaces | where { $null -ne $_.ipaddress -and $_.Logicalshape})){ #Don't link interfaces without a ip address and that don't have a shape object.
            if($Interface.shutdown -or $Interface.IntStatus -like "*down*"){ #Don't link shutdown interfaces
                continue
            }
            if($DiagramType -eq "Normal" -or $DiagramType -eq "LinksOnly"){
                $NetworkToConnectTo=$null
                $FromDevice=$interface.Logicalshape
                #Find vlan to connect to
                foreach ($network in $ArrayOfNetworks){
                    if($interface.cidr -eq $network.cidr){
                        $NetworkToConnectTo=$network
                        break
                    }
                }
                if(!($NetworkToConnectTo) -or $null -eq $NetworkToConnectTo.Shape){
                    if(!($DiagramType)){
                        write-HostDebugText "Error connecting devices vlans:$($_.Exception)" -ForegroundColor green
                        write-HostDebugText "From:$($FromDevice.name) to:$($NetworkToConnectTo.cidr)" -BackgroundColor red
                    }
                    continue
                }

                #Draw connection
                try{
                    $ArrayOfConnectors+=Connect-VisioShape -From $FromDevice -To $NetworkToConnectTo.Shape -Master $Gdyncon_m
                }
                Catch{
                    write-HostDebugText "Error connecting devices vlans:$($_.Exception)" -ForegroundColor green
                    write-HostDebugText "From:$($FromDevice.name) to:$($NetworkToConnectTo.cidr)" -BackgroundColor red
                    $NetworkToConnectTo=$null
                    $FromDevice=$null
                    continue #If there is an error don't stuff up the text of another object just move on.
                }
                write-HostDebugText "From:$($interface.interface) TO:$($NetworkToConnectTo.cidr)"

                #write-HostDebugText "`rFrom:$($FromDevice) to:$($NetworkToConnectTo)"
                $shape_cells = New-VisioShapeCells
                $shape_cells.LineColor = $GColourBlack
                $shape_cells.LineWeight = "4 pt"
                $shape_cells.CharSize=$GRouteFontSize
                Set-VisioShapeCells -Shape $ArrayOfConnectors[$ArrayOfConnectors.count-1] -Cells $shape_cells
            }


            if($interface.RoutesForInterface.count -ne 0 -and $DiagramType -eq "RoutesOnly"){ #Do we have routes that need to be drawn.
                foreach ($link in ($interface.RoutesForInterface |where { $_.gateway} | group-object routeprotocol,gateway)){
                    $GatewayToConnectTo=$null
                    $FromDevice=$interface
                    $protocol=($link.Name -replace " ",'' -split ",")[0]
                    $gateway=($link.Name -replace " ",'' -split ",")[1]

                    #TODO Fix this to use the REF. This if statement shouldn't need to exist. The else line should be all that is needed.
                    #This seems to reference and old object or something like that.
                    if(($GArrayofGatewayHosts | % { $_.interfaces} | where { $_.ipaddress -eq $gateway}).logicalshape){#Host is located in gateway objects.
                        #TODO:Put code in here to handle duplicates and HSRP
                        $GatewayToConnectTo=($GArrayofGatewayHosts | % { $_.interfaces} | where { $_.ipaddress -eq $gateway} | select -first 1) #Note: Select -first 1 is required as multiple interfaces can have the same ip address because of hsrp or miss-config.
                    }else{
                        $GatewayToConnectTo=$link.Group[0].gatewaylink.value
                    }

                    write-HostDebugText "From:$($FromDevice)`r`n to:$($GatewayToConnectTo)"
                    #Draw connection
                    try{
                        $ArrayOfConnectors+=Connect-VisioShape -From $FromDevice.Logicalshape -To $GatewayToConnectTo.Logicalshape -Master $Gdyncon_m
                    }
                    Catch{
                        write-HostDebugText "Error connecting devices routing:$($_.Exception)" -ForegroundColor green
                        write-HostDebugText "From:$($FromDevice) to:$($GatewayToConnectTo)" -BackgroundColor red
                        $GatewayToConnectTo=$null
                        $FromDevice=$null
                        continue #If there is an error don't stuff up the text of another object just move on.
                    }
                    $shape_cells = New-VisioShapeCells

                    
                    $shape_cells.LineWeight = "8 pt"
                    $shape_cells.LineEndArrow=1
                    $shape_cells.LineEndArrowSize=8
                    $shape_cells.LineRounding="3 mm"
                    
                    $shape_cells.CharSize=$GRouteFontSize
                    if(($link.Group | select subnet).count -gt 30){
                        if($link.Group | where { $_.subnet -like "*0.0.0.0/0*"}){
                            $RoutesString="$($protocol)`r`n$($gateway)`r`nRoute Count:$(($link.Group | select subnet).count)`r`nRoutes For: 0.0.0.0/0"
                        }else{
                            $RoutesString="$($protocol)`r`n$($gateway)`r`nRoute Count:$(($link.Group | select subnet).count)"
                        }

                    }else{
                        $RoutesString="$($protocol)`r`n$($gateway)`r`n"
                        $RoutesString+=$link.Group | select subnet | sort | ft -HideTableHeaders | out-string
                        $RoutesString.trim()
                    }
                    switch -wildcard ($protocol){
                        "static"{          $shape_cells.LineColor = "rgb(0,107,60)" } #Green
                        "RIP"{             $shape_cells.LineColor =  "rgb(179,89,0)" } #Dark orange
                        "BGP"{             $shape_cells.LineColor = "rgb(0,0,179)" } #blue
                        "BGP-*"{             $shape_cells.LineColor = "rgb(0,0,179)" } #blue
                        "B"{               $shape_cells.LineColor = "rgb(0,0,179)" } #blue
                        "EIGRP"{           $shape_cells.LineColor = "rgb(160,32,240)"} #purple
                        "OSPF"{            $shape_cells.LineColor = "rgb(255,255,51)" } #Yellow
                        "OSPF-*"{            $shape_cells.LineColor = "rgb(255,255,51)" } #Yellow
                        "IS-IS"{           $shape_cells.LineColor = "rgb(204,238,255)" } #Light blue
                        "Default gateway"{ $shape_cells.LineColor = "rgb(0,107,60)" } #Green
                        default{           $shape_cells.LineColor = $GColourBlack }  #black         
                    }
                    #red         "rgb(255,25,25)"
                    #Default routes will always be straight. 
                    if($RoutesString -like "*0.0.0.0/0*"){ 
                        $shape_cells.LinePattern=1 
                    }else{
                        $shape_cells.LinePattern=2
                    }
                    
                    Set-VisioShapeCells -Shape $ArrayOfConnectors[$ArrayOfConnectors.count-1] -Cells $shape_cells


                    Set-VisioText "$($RoutesString)" -Shape $ArrayOfConnectors[$ArrayOfConnectors.count-1]
                }

            }

        }
    }
}




function Draw-SinglesLayer3(){
        param (
		[parameter(Mandatory=$true)]
		$Device,
        $ArrayOfNetworks
    )

    write-HostDebugText "Drawing vlans for:$($Device.hostname)"
    $i=0 #counter for spacing
    $j=0 #counter for color
    $DeviceArrayOfNetworks=@() #Array of network we need to draw.
    foreach ($network1 in $device.ArrayOfNetworks){
        foreach ($network2 in $ArrayOfNetworks){
            if($network1.cidr -eq $network2.cidr){
                $DeviceArrayOfNetworks+=$network2
            }
        }
    }
    $DeviceArrayOfNetworks = $DeviceArrayOfNetworks | sort  NumberOfConnectors,vlan,cidr
    $GStartLocationNetwork[0]+=(-$DeviceArrayOfNetworks.count*$GVlanStep/2)
    ################################################# Draw Layer 3 Vlans and connectors for this device #################################
    New-VisioPage -Name "$($Device.hostname) Layer 3"
    #$ArrayOfVlansShapes=@() #Array to store all the vlan shapes
    foreach ($network in ($DeviceArrayOfNetworks | where {$_.NumberOfConnectors -gt 0})){
        if($network.RoutedVlan -eq "no vlan"){
            $network.shape= Draw-CustomShapeFromMTAutoStencil -shapetype "Ethernet" -ShapeText "$($network.RoutedVlan)`r`n`($($network.cidr)`)" -Location (($GStartLocationNetwork[0]+$i),($GStartLocationNetwork[1]-$GNOVlanSubnetOffset)) -color  $network.color -size @($GVlanWidth,$GVlanHight)
        }else{
            $network.shape= Draw-CustomShapeFromMTAutoStencil -shapetype "Ethernet" -ShapeText "$($network.NetworkName)`r`n$($network.RoutedVlan)`r`n`($($network.cidr)`)" -Location (($GStartLocationNetwork[0]+$i),$GStartLocationNetwork[1]) -color  $network.color -size @($GVlanWidth,$GVlanHight)
        }
        #Create a box and attach it to the vlan. This will contain a list of all the IP arp entries.
        if($GDrawAprEntries -and $network.ARPEntries){
            $ShapeText=$null
            $ShapeText="$($network.NetworkName)`r`n$($network.RoutedVlan)`r`n"
            if($GDrawAprEntriesDetails){
                $ShapeText+="IPaddress           MAC       VendorCompanyName`r`n"
                foreach($Entry in ($network.ARPEntries|sort VendorCompanyName)){
                    $ShapeText+="$($Entry.ipaddress)   $($Entry.mac)   $($Entry.VendorCompanyName)`r`n"
                }
            }else{#Add summary only
                $ShapeText+="$($network.ARPEntries | group VendorCompanyName | select count,name | sort count -Descending |  % { "$($_.name) $($_.count)`r`n"} )"
            }

            $ArpEntries=$null
            $ArpEntries=Draw-Shape -shapetype "circle" -ShapeText $ShapeText -Location (($GStartLocationNetwork[0]+$i+$GARPEntriesOffsetX),($GStartLocationNetwork[1]+$GARPEntriesSpacingHeigh)) -color  $network.color -size @(($GARPWidth),($GARPHight + ($ShapeText.count)))
            if($ArpEntries){
                Connect-VisioShape -From $ArpEntries -To $network.shape -Master $Gdyncon_m | out-null
            }
        }
        $i=$i+$GVlanStep
        $j=$j+$VlanColorStep
    }
    $Device=Draw-HostLayer3 -Device $Device -Location ($GStartLocationHosts[0],$GStartLocationHosts[1])
    $ArrayOfConnectors=@()
    #Draw connectors between hosts and vlans
    foreach ($interface in ($Device.interfaces | where { $null -ne $_.ipaddress -and $_.shutdown -eq $false})){
        $NetworkToConnectTo=$null
        #Find vlan to connect to
        foreach ($network in $DeviceArrayOfNetworks){
            if($interface.cidr -eq $network.cidr){
                $NetworkToConnectTo=$network
                break
            }
        }

        #Draw connection
        try{
            $ArrayOfConnectors+=Connect-VisioShape -From $interface.Logicalshape -To $NetworkToConnectTo.Shape -Master $Gdyncon_m
        }
        Catch{
                write-HostDebugText "Error connecting devices vlans:$($_.Exception)" -ForegroundColor green
                write-HostDebugText "From:$($interface) to:$($NetworkToConnectTo.name)" -BackgroundColor red
                $NetworkToConnectTo=$null
                continue #If there is an error don't stuff up the text of another object just move on.
        }
        write-HostDebugText "From:$($interface.interface) TO:$($NetworkToConnectTo.name)"
        $RoutesForInterface=$Device.RoutingTable| where { $_.interface -eq $interface.Interface -and $_.routeprotocol -notmatch "local|connected" } | sort gateway,subnet
        if($interface.RoutesForInterface.count -ne 0){ #We don't have routes there is no need for text on this connection.
            $link=$interface.RoutesForInterface |where { $_.gateway} | group-object routeprotocol,gateway
             if(($link.Group | select subnet).count -gt 30){
                $RoutesString="$($protocol)`r`n$($gateway)`r`nRoute Count:$(($link.Group | select subnet).count)"

            }else{
                $RoutesString="$($protocol)`r`n$($gateway)`r`n"
                $RoutesString+=$link.Group | select subnet | sort | ft -HideTableHeaders | out-string
                $RoutesString.trim()
            }
            Set-VisioText "$($RoutesString)" -Shape $ArrayOfConnectors[$ArrayOfConnectors.count-1]
        }

        $shape_cells = New-VisioShapeCells
        $shape_cells.LineColor = "rgb(" +"$($NetworkToConnectTo.Color)" + ")"
        $shape_cells.LineWeight = "4 pt"
        #$shape_cells.LinePattern = 2
        Set-VisioShapeCells -Shape $ArrayOfConnectors[$ArrayOfConnectors.count-1] -Cells $shape_cells
    }
}


function Draw-AllEthernet(){
        param (
		[parameter(Mandatory=$true)]
		$ArrayOfObjects
    )
    write-HostDebugText "Drawing all Ethernet Diagram:"
    New-VisioPage -Name "Ethernet - all"
     $i=0 #counter host spacing
    foreach ($Device in $ArrayOfObjects){
        write-HostDebugText "$($Device.hostname):"
        if($i -gt 0){
            $i=$i+(Get-PhysicalInterfaces -Device $Device).count
        }
        $Device=Draw-HostEthernet -Device $Device  -Location (($GStartLocationHosts[0]+$i),$GStartLocationHosts[1])
        $i=$i+$GHostEthernetStep+(((Get-PhysicalInterfaces -Device $Device).count+1)*2)
    }
}

#Draws all of the neighbor objects and links them together.
#This is the logic section of the code. It calls other parts of the code to do the actual drawing.
function Draw-AllNeighbors(){
        param (
		[parameter(Mandatory=$true)]
		$ArrayOfObjects,
        $ArrayOfCDPDeviceIDs,
        $ArrayOfLLDPDeviceIDs
    )
	write-HostDebugText "Drawing all CDP Diagram" -ForegroundColor green
	$ArrayOfConnectors=@()
	New-VisioPage -Name "CDP - LLDP"
    
    write-HostDebugText "Drawing Interface legend box." -ForegroundColor green 
    Draw-InterfaceLegend -location (($GStartLocationHosts[0]-10),$GStartLocationHosts[1])
    
    
	#Draw all standAlone CDP neighbors that we don't have config for.
    write-HostDebugText "Drawing cdp neighbors we have no configuration files for:" -ForegroundColor green
	$i=0
    $j=0
	foreach ($cdpDevice in ($ArrayOfCDPDeviceIDs ) ){
        if($lastHostname -ne $cdpDevice.ParentObject){#Drop each host down 4 units so it's easy to move them around.
            switch ($j){
                10 { $j=0}
                0 { $j=10}
            }

        }
        write-HostDebugText "$($cdpDevice.hostname):"
		if($cdpDevice.interfaces.Count -gt 10){
			$i=$i+$cdpDevice.interfaces.Count
		}
		$cdpDevice=Draw-HostEthernet -Device $cdpDevice  -Location (($GStartLocationCDPHosts[0]+$i),($GStartLocationCDPHosts[1]-$j)) -DrawType "CDPNeighbor"
		$i=$i+$GHostEthernetStep+($cdpDevice.interfaces.Count*2)
        $lastHostname=$cdpDevice.ParentObject
	}
    write-HostDebugText "Drawing all hosts we have config for:" -ForegroundColor green
	$i=0 #counter host spacing
    $hostwidth=0
	foreach ($Device in ($ArrayOfObjects|sort hostname)){
        write-HostDebugText "$($Device.hostname):"
        $Device,$hostwidth=Draw-HostPhysical -Device $Device  -Location (($GStartLocationHosts[0]+$i),$GStartLocationHosts[1])
        #HostWidth is how wide the host is. This is used to calculate the distance between hosts.
        $i= $i + $GHostEthernetStep + $hostwidth
	}
	write-HostDebugText "Connecting CDP Objects we have config for" -ForegroundColor green
	foreach ($Device in $ArrayOfObjects){
        write-HostDebugText $device.hostname
		foreach ( $cdpneighbor in ($Device.cdpneighbors | where { $_.PartnerEthernetInterface } )){
			$DeviceToConnectTo=$null
			$FromDevice=$null
			$DeviceToConnectTo=$cdpneighbor.PartnerEthernetInterface.value
            if($DeviceToConnectTo.ConnectedCDPnieghbors){#We have already connected this device.
                #write-HostDebugText "Skipping we have already connected $($DeviceToConnectTo.interface)"
                continue
            }
			$FromDevice= ( $Device.interfaces | where { $_.interface -eq  $cdpneighbor.InterfaceLocalDevice })
            $FromDevice.ConnectedCDPnieghbors=$true
            write-HostDebugText "From:$($FromDevice.interface) to:$($DeviceToConnectTo.interface)"
			#Draw connection
			try{
				$ArrayOfConnectors+=Connect-VisioShape -From $FromDevice.Physicalshape -To $DeviceToConnectTo.Physicalshape -Master $Gdyncon_m
			}
			Catch{
                write-HostDebugText "-----------------------------" -BackgroundColor red
				write-HostDebugText "Error connecting devices CDP:$($_.Exception)" -ForegroundColor green
                write-HostDebugText "From:$($Device.hostname)`r`nto:$($DeviceToConnectTo.hostname)" -BackgroundColor red
				write-HostDebugText "From:$($FromDevice.interface)`r`nto:$($DeviceToConnectTo.interface)" -BackgroundColor red
                write-HostDebugText "-----------------------------" -BackgroundColor red
                #read-host
				$DeviceToConnectTo=$null
				$FromDevice=$null
				continue #If there is an error don't stuff up the text of another object just move on.
			}

			#Set-VisioText "" -Shape $ArrayOfConnectors[$ArrayOfConnectors.count-1]
			$shape_cells = New-VisioShapeCells
            if($FromDevice.ShapeColor){
                $shape_cells.LineColor = "rgb(" +"$($FromDevice.ShapeColor)" + ")"
            }
			$shape_cells.LineWeight = "8 pt"
			Set-VisioShapeCells -Shape $ArrayOfConnectors[$ArrayOfConnectors.count-1] -Cells $shape_cells
		}
	}
    write-HostDebugText "Connecting CDP Objects we do not have config for" -ForegroundColor green
	foreach ($Device in $ArrayOfObjects){
        write-HostDebugText $device.hostname
		foreach ( $cdpneighbor in ($Device.cdpneighbors | where { !$_.PartnerEthernetInterface } )){
			$DeviceToConnectTo=$null
			$FromDevice=$null
			:outer foreach ($cdpDevice in $ArrayOfCDPDeviceIDs ){
				if($cdpDevice.hostname -eq $cdpneighbor.DeviceID){
					foreach ($interface in $cdpDevice.interfaces){
						if($interface.interface -eq $cdpneighbor.InterfaceRemoteDevice){
							$DeviceToConnectTo=$interface
							break outer
						}
					}
				}
			}
			if($null -eq $DeviceToConnectTo){
				write-HostDebugText "Can't find $($cdpneighbor.DeviceID) skipping" -BackgroundColor red
				continue
			}
			$FromDevice= ( $Device.interfaces | where { $_.interface -eq  $cdpneighbor.InterfaceLocalDevice })
            $FromDevice.ConnectedCDPnieghbors=$true
			#Draw connection
			try{
				$ArrayOfConnectors+=Connect-VisioShape -From $FromDevice.Physicalshape -To $DeviceToConnectTo.Physicalshape -Master $Gdyncon_m
			}
			Catch{
				write-HostDebugText "Error connecting devices CDP:$($_.Exception)" -ForegroundColor green
				write-HostDebugText "From:$($FromDevice.interface)`r`nto:$($DeviceToConnectTo)" -BackgroundColor red
				$DeviceToConnectTo=$null
				$FromDevice=$null
				continue #If there is an error don't stuff up the text of another object just move on.
			}
            write-HostDebugText "From:$($FromDevice.interface) to:$($DeviceToConnectTo.interface)"
			#Set-VisioText "$($interface.Interface) - $($interface.Description) - $($interface.IPAddress)" -Shape $ArrayOfConnectors[$ArrayOfConnectors.count-1]
			$shape_cells = New-VisioShapeCells
			#$shape_cells.LineColor = "rgb(255,255,255)"
			$shape_cells.LineWeight = "8 pt"
			Set-VisioShapeCells -Shape $ArrayOfConnectors[$ArrayOfConnectors.count-1] -Cells $shape_cells
			$DeviceToConnectTo=$null
			$FromDevice=$null
		}
	}

    write-HostDebugText "Drawing LLDP Objects we do not have config for" -ForegroundColor green
    $i=0
    $j=0
	foreach ($LLDPDevice in ($ArrayOfLLDPDeviceIDs |sort ParentObject) ){
        if($lastHostname -ne $LLDPDevice.ParentObject){#Drop each host down x units so it's easy to move them around.
            switch ($j){
                10 { $j=0}
                0 { $j=10}
            }
        }
        write-HostDebugText "$($LLDPDevice.hostname):"
		if($LLDPDevice.interfaces.Count -gt 10){
			$i=$i+$LLDPDevice.interfaces.Count
		}
		$LLDPDevice=Draw-HostEthernet -Device $LLDPDevice -Location (($GStartLocationLLDPHosts[0]+$i),($GStartLocationLLDPHosts[1]+$j)) -DrawType "LLDPNeighbor"
		$i=$i+$GHostEthernetStep+($LLDPDevice.interfaces.Count*2)
        $lastHostname=$LLDPDevice.ParentObject
	}

	write-HostDebugText "Connecting LLDP Objects we have config for" -ForegroundColor green
	foreach ($Device in $ArrayOfObjects){
        write-HostDebugText $device.hostname
		foreach ( $LLDPNeighbor in ($Device.LLDPNeighbors | where { $_.PartnerEthernetInterface } )){
			$DeviceToConnectTo=$null
			$FromDevice=$null
			$DeviceToConnectTo=$LLDPNeighbor.PartnerEthernetInterface.value
            if($DeviceToConnectTo.ConnectedCDPnieghbors){#We have already connected this device.
                #write-HostDebugText "Skipping we have already connected $($DeviceToConnectTo.interface)"
                continue
            }
			$FromDevice= ( $Device.interfaces | where { $_.interface -eq  $LLDPNeighbor.InterfaceLocalDevice })
            $FromDevice.ConnectedCDPnieghbors=$true
            write-HostDebugText "From:$($FromDevice.interface)`r`nto:$($DeviceToConnectTo.interface)"
			#Draw connection
			try{
				$ArrayOfConnectors+=Connect-VisioShape -From $FromDevice.Physicalshape -To $DeviceToConnectTo.Physicalshape -Master $Gdyncon_m
			}
			Catch{
                write-HostDebugText "-----------------------------" -BackgroundColor red
				write-HostDebugText "Error connecting devices LLDP:$($_.Exception)" -ForegroundColor green
                write-HostDebugText "From:$($Device.hostname)`r`nto:$($DeviceToConnectTo.hostname)" -BackgroundColor red
				write-HostDebugText "From:$($FromDevice.interface)`r`nto:$($DeviceToConnectTo.interface)" -BackgroundColor red
                write-HostDebugText "-----------------------------" -BackgroundColor red
                #read-host
				$DeviceToConnectTo=$null
				$FromDevice=$null
				continue #If there is an error don't stuff up the text of another object just move on.
			}

			#Set-VisioText "" -Shape $ArrayOfConnectors[$ArrayOfConnectors.count-1]
			$shape_cells = New-VisioShapeCells
            if($FromDevice.ShapeColor){
                $shape_cells.LineColor = "rgb(" +"$($FromDevice.ShapeColor)" + ")"
            }
			$shape_cells.LineWeight = "8 pt"
			Set-VisioShapeCells -Shape $ArrayOfConnectors[$ArrayOfConnectors.count-1] -Cells $shape_cells
		}
	}

    write-HostDebugText "Connecting LLDP Objects we do not have config for" -ForegroundColor green
	foreach ($Device in $ArrayOfObjects){
        write-HostDebugText $device.hostname
		foreach ( $LLDPNeighbor in ($Device.LLDPNeighbors | where { !$_.PartnerEthernetInterface } )){
            if($LLDPNeighbor.HasCDPNeighborEntry ){#Skip objects we have already drawn in CDPNeighbors
                continue
            }
			$DeviceToConnectTo=$null
			$FromDevice=$null
			:outer foreach ($LLDPDevice in $ArrayOfLLDPDeviceIDs ){
				if(($LLDPDevice.hostname -eq $LLDPNeighbor.Hostname) -or ($LLDPDevice.hostname -eq $LLDPNeighbor.ChassisID) ){
					foreach ($interface in $LLDPDevice.interfaces){
						if($interface.interface -eq $LLDPNeighbor.InterfaceRemoteDevice){
							$DeviceToConnectTo=$interface
							break outer
						}
					}
				}
			}
			if($null -eq $DeviceToConnectTo){
				write-HostDebugText "Can't find $($LLDPNeighbor.Hostname) skipping" -BackgroundColor red
				continue
			}
			$FromDevice= ( $Device.interfaces | where { $_.interface -eq  $LLDPNeighbor.InterfaceLocalDevice })
            $FromDevice.ConnectedCDPnieghbors=$true
			#Draw connection
			try{
				$ArrayOfConnectors+=Connect-VisioShape -From $FromDevice.Physicalshape -To $DeviceToConnectTo.Physicalshape -Master $Gdyncon_m
			}
			Catch{
				write-HostDebugText "Error connecting devices LLDP:$($_.Exception)" -ForegroundColor green
				write-HostDebugText "From:$($FromDevice.interface)`r`nto:$($DeviceToConnectTo)" -BackgroundColor red
				$DeviceToConnectTo=$null
				$FromDevice=$null
				continue #If there is an error don't stuff up the text of another object just move on.
			}
            write-HostDebugText "From:$($FromDevice.interface)`r`nto:$($DeviceToConnectTo.interface)"
			#Set-VisioText "$($interface.Interface) - $($interface.Description) - $($interface.IPAddress)" -Shape $ArrayOfConnectors[$ArrayOfConnectors.count-1]
			$shape_cells = New-VisioShapeCells
			#$shape_cells.LineColor = "rgb(255,255,255)"
			$shape_cells.LineWeight = "8 pt"
			Set-VisioShapeCells -Shape $ArrayOfConnectors[$ArrayOfConnectors.count-1] -Cells $shape_cells
			$DeviceToConnectTo=$null
			$FromDevice=$null
		}
	}
}