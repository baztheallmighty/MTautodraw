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


#This file contains the functions to draw items in visio. It contains a little bit of logic regarding how to draw them.





#TODO Fix hardcoded values here. 
#This function draws the Interface legend box. 
function Draw-InterfaceLegend(){
    param (
		[parameter(Mandatory=$true)]
		$Location
    )    
    $TextBoxMaster = Get-VisioMaster -Name "12pt. text" -Document $GAnnotations
    $SquareMaster2 = Get-VisioMaster "Square" -Document $Gbasic_u
    $SquareMaster = Get-VisioMaster "Square" -Document $Gbasic_u

    $SquareShape_cells = New-VisioShapeCells
    $SquareShape_cells.XFormWidth = 3
    $SquareShape_cells.XFormHeight = 15.5  
    $square=New-VisioShape -Master $SquareMaster -Position (New-Object VisioAutomation.Geometry.Point(($Location[0]+1),($Location[1]-7.3))) -Cells $SquareShape_cells
    $square2=New-VisioShape -Master $SquareMaster -Position (New-Object VisioAutomation.Geometry.Point(($Location[0]+1),($Location[1]-7.3))) -Cells $SquareShape_cells

    $TextBox=New-VisioShape -Master $TextBoxMaster -Position (New-Object VisioAutomation.Geometry.Point(($Location[0]-0.2),$Location[1]))
    Set-VisioText -Text "Interface Legend" -Shape $TextBox
    $Location = ($Location[0],($Location[1]-0.3))


    $TextBox=New-VisioShape -Master $TextBoxMaster -Position (New-Object VisioAutomation.Geometry.Point(($Location[0]-0.2),$Location[1]))
    Set-VisioText -Text "Color   |   Interface cisco type name" -Shape $TextBox
    $Location = ($Location[0],($Location[1]-0.5))


    foreach ($LegandLine in $GArrayOfInterfaceTypes){
        $TextBox=New-VisioShape -Master $TextBoxMaster -Position (New-Object VisioAutomation.Geometry.Point(($Location[0]+0.5),$Location[1]))
        Set-VisioText -Text $LegandLine[1] -Shape $TextBox
        $SquareShape2_Cells = New-VisioShapeCells
        $SquareShape2_Cells.XFormWidth = $GInterfaceCircleXFormWidth
        $SquareShape2_Cells.XFormHeight = $GInterfaceCircleXFormHeight  
        $SquareShape2_Cells.FillForeground = $LegandLine[2]
        if($LegandLine[0] -eq "RJ45"){#Is this a SPF and we want to mark it as such
            #Do nothing
        }elseif($LegandLine[0] -eq "RJ45-SFP"){
            $SquareShape2_Cells.LineWeight = $GInterfaceCircleLineWidth
            $SquareShape2_Cells.LineColor = $GInterfaceCircleLineColorRed  
        }else{
            $SquareShape2_Cells.LineWeight = $GInterfaceCircleLineWidth
            $SquareShape2_Cells.LineColor = $GInterfaceCircleLineColorNormal        
        }
        $square = New-VisioShape -Master $SquareMaster2 -Position (New-Object VisioAutomation.Geometry.Point($Location[0],($Location[1]+0.1))) -Cells $SquareShape2_Cells
        $Location = ($Location[0],($Location[1]-0.5)) 
    }
}



#Draws a vrf
function Draw-Vrf(){
    param (
		[parameter(Mandatory=$true)]
		$VRFName,
        $Location #example (0,0)
    )
    #Create a shape
    $master = Get-VisioMaster "Rounded rectangle" -Document $Gbasic_u
    #Where are we putting it
    $points = New-Object VisioAutomation.Geometry.Point($Location)
    #Color,size and other parameters
    $shape_cells = New-VisioShapeCells
    $shape_cells.XFormWidth = $GVRFXFormWidth
    $shape_cells.XFormHeight = $GVRFXFormHeight
    $shape_cells.FillForeground = "rgb(93,93,93)"
    $shape_cells.LineWeight = "2 pt"
    $VRFShape= New-VisioShape -Master $master -Position $points -Cells $shape_cells
    Set-VisioText "$($VRFName.name)`r`n$($VRFName.rd)`r`n$($VRFName.RouteTarget)`r`n$($VRFName.export)" -Shape $VRFShape
    return $VRFShape
}

#Draws the physical Interface on a device
function Draw-PhysicalInterface(){
    param (
		[parameter(Mandatory=$true)]
		$Interface,
        $Location, #example (0,0)
        $DrawType
    )
    #Create a shape
    $master = Get-VisioMaster "Rounded Rectangle" -Document $Gbasic_u
    #Text 
    if($GShortenInterfacesNames){
        $text="$(Replace-InterfaceLongName -string $Interface.Interface  )`r`n"
    }else{
        $text="$($Interface.Interface)`r`n"
    }
    if($Interface.Description){
        $text+="$($Interface.Description)`r`n"
    }
    if($Interface.SwitchportMode -like "trunk"){
        if($Interface.SwitchportTrunkVlan){
            $text+="trunk vlans:$($Interface.SwitchportTrunkVlan)"
        }else{
            $text+="trunk vlans:all"
        }
    }elseif($Interface.SwitchportMode -eq "Probably Trunk mode"){
        if($Interface.SwitchportTrunkVlan){
            $text+="Most likely trunk mode vlans:$($Interface.SwitchportTrunkVlan)"
        }else{
            $text+="Most likely trunk mode vlans:all"
        }
    }elseif($Interface.SwitchportMode -eq "access"){
        $text+="Access mode vlan:$($Interface.SwitchportAccessVlan)"
    }elseif($Interface.SwitchPortType -eq "Routed"){
        $text+="Routed Switch port:$($Interface.ipaddress)`/$($Interface.subnetmask)`r`n"
    }else{
        $text+="No configuration AVAILABLE. (CDP / LLDP) or Sub-Interfaces?"
    }
    if ($interface.ChannelGroup){
        if($interface.ChannelGroup -like "*ae*"){
            $text+="`r`n$($Interface.ChannelGroup)"
        }else{
            $text+="`r`nPort-Channel$($Interface.ChannelGroup)"
        }
    }
    #Color,size and other parameters
    $shape_cells = New-VisioShapeCells
    $shape_cells.XFormWidth = $GPhysicalInterfaceFormWidth
    $shape_cells.XFormHeight = $GPhysicalInterfaceFormHeight
    $shape_cells.CharSize=$GPhysicalInterfaceFontSize
    
    if($DrawType -eq "neighbors"){
        if($Interface.STRootInterfaceForVlans ){
            $Location = ($Location[0],($Location[1]-2*$GPhysicalHostInterfaceOffsetY))
            $text+="`r`nSpanningTree Root Port VLANS:$($Interface.STRootInterfaceForVlans|%{"$($_),"})" -replace ",$",""
            $shape_cells.XFormHeight= $GPhysicalInterfaceFormHeight + $GSpanningTreeInterfaceSize

        }elseif($Interface.STRole -eq "Root"){
            $Location = ($Location[0],($Location[1]-2*$GPhysicalHostInterfaceOffsetY))
            $text+="`r`nSpanningTree Root Port"
            $shape_cells.XFormHeight= $GPhysicalInterfaceFormHeight + $GSpanningTreeInterfaceSize
        }
        if($Interface.STALTnInterfaceForVlans){
            $Location = ($Location[0],($Location[1]-2*$GPhysicalHostInterfaceOffsetY))
            $text+="`r`nSpanningTree ALTN Port VLANS:$($Interface.STALTnInterfaceForVlans|%{"$($_),"})" -replace ",$",""
            $shape_cells.XFormHeight= $GPhysicalInterfaceFormHeight + $GSpanningTreeInterfaceSize
        }elseif($Interface.STRole -eq "ALT"){
            $Location = ($Location[0],($Location[1]-2*$GPhysicalHostInterfaceOffsetY))
            $text+="`r`nSpanningTree ALTN Port"
            $shape_cells.XFormHeight= $GPhysicalInterfaceFormHeight + $GSpanningTreeInterfaceSize
        }
    }
    foreach ($type in $GArrayOfInterfaceTypes){
        if($Interface.MediaType -eq $type[1]){
            $MediaType=$type
        }
    }
    if($MediaType){#Does this interface match a type we know about???
        $shape_cells.FillForeground = $MediaType[2]
        if($MediaType[0] -eq "RJ45"){#Is this a SPF and we want to mark it as such
            $shape_cells.CharColor = "rgb(255,255,255)" #Black interface so we change the text to white
            $shape_cells.FillPattern = 26
            $shape_cells.FillBackground = "rgb(128,128,105)"            
        }
        if($MediaType[0] -eq "RJ45-SFP"){
            $shape_cells.CharColor = "rgb(255,255,255)"
            $shape_cells.FillPattern = 26
            $shape_cells.FillBackground = "rgb(255,0,0)"            
        }
    }else{#we don't know what type of interfaces this is so we do the default. 
        $shape_cells.FillForeground = $GDefaultInterfacesColor
    }    
    
    if($Interface.shutdown -or ($Interface.IntStatus -like "*down*")){
        $shape_cells.FillForeground = "rgb(255,0,0)"
        write-HostDebugText "Changed to red"
    }else{
        if ($interface.ChannelGroup){
            $shape_cells.LineColor = "rgb(" + $interface.ShapeColor + ")"
            $Shape_cells.LineWeight = "4 pt"
        }else{
            $shape_cells.LineColor = "rgb(0,0,0)"
            $shape_cells.LineWeight = "2 pt"
        }
    }    
        
    $points = New-Object VisioAutomation.Geometry.Point($Location)
    $InterfaceShape= New-VisioShape -Master $master -Position $points -Cells $shape_cells
    #Create a shape group so it's easier to move them around. 
    $PhysicalshapeGroup=@()
    $PhysicalshapeGroup+=$InterfaceShape

    if($DrawType -eq "neighbors" -and $Interface.STState -eq "BLK"){
        $text+="`r`nSpanningTree Blocked Port"
        Set-VisioText $text -Shape $InterfaceShape
        $TempShape=Draw-CustomShapeFromMTAutoStencil  -shapetype "RedCross" -Location ($Location[0],($Location[1]+1))
        $PhysicalshapeGroup+=$TempShape
    }else {
        Set-VisioText $text -Shape $InterfaceShape
    }
    $JoinedPhysicalshapeGroup=Join-VisioShape -Shape $PhysicalshapeGroup 
    return $InterfaceShape,$JoinedPhysicalshapeGroup

}


#This draws a host we have a config for. This is called from lldp and cdp neighbors for drawing physical diagrams.
function Draw-HostPhysical(){
    param (
		[parameter(Mandatory=$true)]
		$Device,
        $Location #example (0,0)
    )
    #Create a shape
    $master = Get-VisioMaster "Rounded rectangle" -Document $Gbasic_u

    #Color,size and other parameters
    $shape_cells = New-VisioShapeCells
    #Create an array of interfaces that are not in CDP neighbours and we have a spanning tree entry for them
    $SPTInterfaces=$null
    #Find root or altn ports that don't have a CDP neighbour entry so we can add them to and array and draw them further down.
    if(($Device.interfaces | where {  $_.STState -ne $null -and $_.STRole -ne $null -and $_.STRole -ne "DESG" -and $_.interface -notmatch "port-channel\d+|vlan\d+|mgmt|ae\d+" -and $_.shutdown -eq $false}).count -ne 0){
        foreach ( $SPTInterface in ($Device.interfaces| where { ($_.HasCPDNieghbor -eq $false) -and ($_.HasLLDPNeighbor -eq $false)} | where { $_.STState -ne $null -and $_.STRole -ne $null -and $_.STRole -ne "DESG" -and $_.interface -notmatch "port-channel\d+|vlan\d+|mgmt" -and $_.shutdown -eq $false })){
            if(($SPTInterface.HasCPDNieghbor -eq $false) -and ($SPTInterface.HasLLDPNeighbor -eq $false)){
                $SPTInterfaces+=,$SPTInterface
            }
        }
    }
    $InterfacesWithMacsDoDraw=@()
    #We need to draw ports with multiple mac addresses attached to them.
    if($GDrawPortsWithMacs -ne 0){
        foreach( $MacInterface in ($Device.interfaces | where { ($_.HasCPDNieghbor -eq $false) -and ($_.HasLLDPNeighbor -eq $false)}  | where {  (($_.MacAddressArray| sort -Unique macaddress).Count -ge $GDrawPortsWithMacs) -and ($_.interface -notmatch "port-channel\d+|vlan\d+|mgmt")} )){
            $InterfacesWithMacsDoDraw+=,$MacInterface
        }
    }
    if($device.DeviceType -eq "Cisco" -or $device.DeviceType -eq "Junos" ){#limit the interfaces we are drawing
        $InterfaceCount=($Device.interfaces | where { $_.HasCPDNieghbor -or $_.HasLLDPNeighbor -or $_.IsLinkedToByCDPorLLDP} ).count +$SPTInterfaces.count+$InterfacesWithMacsDoDraw.count+2
    }else{#Draw all interfaces.
        $InterfaceCount=$Device.interfaces.count+2
    }
    #Set the width of the object.
    $hostwidth=(($InterfaceCount+1)*$GPhysicalInterfaceFormWidth) + (($InterfaceCount+1)*$GEthernetSpacingPhysical)


    $shape_cells.XFormWidth=$hostwidth

    if($Device.SpanningTree.RootBridgeForVlans.count -eq 0){
        $HostNameText="$($Device.DeviceIdentifier) : $($Device.HostName) : $($Device.SpanningTree.SpanningTreeMode)"
    }else{
        $HostNameText="$($Device.DeviceIdentifier) : $($Device.HostName) : $($Device.SpanningTree.SpanningTreeMode) : Root for vlans:$($Device.SpanningTree.RootBridgeForVlans|%{"$($_),"})" -replace ",$",""
    }

    if($Device.version.hardware -is [array]){
        write-HostDebugText "Array:$($Device.version.hardware[0])"
        $HostNameText="$($Device.version.hardware[0]) : $($HostNameText)"
    }else{
        write-HostDebugText "String:$($Device.version.hardware)"
        $HostNameText="$($Device.version.hardware) : $($HostNameText)"
    }

    if([int]$shape_cells.XFormWidth -lt $GHostCDPXFormWidth){#Fix form width if it is lower then the minumum
        write-HostDebugText "$($shape_cells.XFormWidt)" -BackgroundColor red
        $shape_cells.XFormWidth=$GHostCDPXFormWidth
        $hostwidth=$GHostCDPXFormWidth
    }
    #Where are we putting it
    $Location=(($Location[0]+$hostwidth/2),$Location[1])
    $points = New-Object VisioAutomation.Geometry.Point($Location)
    $shape_cells.XFormHeight = $GHostCDPXFormHeight
    $shape_cells.FillForeground = "rgb(93,138,168)"
    $shape_cells.LineWeight = "2 pt"
    $shape_cells.CharSize=$GCDPHostFontSize
    try{
        $Device.shape= New-VisioShape -Master $master -Position $points -Cells $shape_cells
    }catch{
        write-HostDebugText "----------------------" -BackgroundColor red
        write-HostDebugText $Device.hostname -BackgroundColor red
        write-HostDebugText "----------------------" -BackgroundColor red
    }
    Set-VisioText $HostNameText  -Shape $Device.shape | out-null
    if($device.DeviceType -ne "Cisco" -and $device.DeviceType -ne "Junos"){#Draw all the interfaces.
        $i=0
        foreach ($interface in ($Device.interfaces| sort ChannelGroup,Interface -Descending)){
            $Interface.Physicalshape,$Interface.PhysicalshapeGroup=Draw-PhysicalInterface -Interface $Interface -Location (($Location[0]+$i-$InterfaceDrawingLocationOffset),($Location[1]+$GPhysicalHostInterfaceOffsetY))
            write-HostDebugText "CDP:$($interface.HasCPDNieghbor) LLDP:$($interface.HasLLDPNeighbor) Drawn:$($Interface.InterfaceAlreadyDrawn)-$($Interface.interface)"
            $Interface.InterfaceAlreadyDrawn=$true #we set this so we know that it's a cdp neighbour. This is used later to check if we should draw the mac addresses.
            $i=$i+$GPhysicalInterfaceFormWidth+$GEthernetSpacingPhysical
        }
    }else{
        $InterfaceDrawingLocationOffset=($shape_cells.XFormWidth/2)-$GPhysicalInterfaceFormWidth
        if($Device.CDPNeighbors -or $Device.LLDPNeighbors){
            $i=0
            foreach ($interface in ($Device.interfaces| sort ChannelGroup,Interface -Descending)){
                if(($interface.HasCPDNieghbor -or $interface.HasLLDPNeighbor -or $interface.IsLinkedToByCDPorLLDP) ){
                    if($Interface.InterfaceAlreadyDrawn -eq $false){#We have already drawn the interface. This can happen if you have multiple devices connected to one port. E.G VM's
                       $Interface.Physicalshape,$Interface.PhysicalshapeGroup=Draw-PhysicalInterface -Interface $Interface -Location (($Location[0]+$i-$InterfaceDrawingLocationOffset),($Location[1]+$GPhysicalHostInterfaceOffsetY)) -DrawType neighbors

                        write-HostDebugText "CDP:$($interface.HasCPDNieghbor) LLDP:$($interface.HasLLDPNeighbor) Drawn:$($Interface.InterfaceAlreadyDrawn)-$($Interface.interface)"
                        $Interface.InterfaceAlreadyDrawn=$true #we set this so we know that it's a cdp neighbour. This is used later to check if we should draw the mac addresses.
                        $i=$i+$GPhysicalInterfaceFormWidth+$GEthernetSpacingPhysical
                    }
                }
            }
        }
        #Draw Spanning tree ROOT/ALTN interfaces that don't have a cdp neighbour record.
        if($SPTInterfaces.count -ne 0){
            foreach ($SPTInterface in $SPTInterfaces){
                if($SPTInterface.InterfaceAlreadyDrawn -eq $false){
                    $name=$null
                    $SPTInterface.Physicalshape,$SPTInterface.PhysicalshapeGroup=Draw-PhysicalInterface -Interface $SPTInterface -Location (($Location[0]+$i-$InterfaceDrawingLocationOffset),($Location[1]+$GPhysicalHostInterfaceOffsetY)) -DrawType neighbors
                    write-HostDebugText "SPT-$($SPTInterface.interface)"
                    $i=$i+$GPhysicalInterfaceFormWidth+$GEthernetSpacingPhysical
                    #Draw the mac addresses connected to this root port.
                    if($SPTInterface.MacAddressArray -ge 1){#Do we have any mac addresses to draw for this one. Might be a shutdown port.
                        $SPTInterface.MacAddressArray | Group-Object VendorCompanyName | sort -Unique macaddress |sort count  |select count,name |% { $name += "$($_.Count) $($_.name)`r`n" }
                        $SPTInterface.MacAddressShape=Draw-Shape -shapetype "circle" -ShapeText $name -Location (($Location[0]+$i-$InterfaceDrawingLocationOffset),($Location[1]+$GMacAddressOffSetY)) -color $SPTInterface.ShapeColor
                        Connect-VisioShape -From $SPTInterface.Physicalshape -To $SPTInterface.MacAddressShape -Master $Gdyncon_m | out-null
                    }
                    $SPTInterface.InterfaceAlreadyDrawn=$true
                }
            }
        }
        #Draw interfaces that have more than $GDrawPortsWithMacs count on them.
        if($GDrawPortsWithMacs -ne 0){
            foreach( $MacInterface in $InterfacesWithMacsDoDraw){
                if($MacInterface.InterfaceAlreadyDrawn -eq $false){
                    $name=$null
                    $MacInterface.Physicalshape,$MacInterface.PhysicalshapeGroup=Draw-PhysicalInterface -Interface $MacInterface -Location (($Location[0]+$i-$InterfaceDrawingLocationOffset),($Location[1]+$GPhysicalHostInterfaceOffsetY)) -DrawType neighbors
                    write-HostDebugText "MAC-$($MacInterface.interface)"
                    $i=$i+$GPhysicalInterfaceFormWidth+$GEthernetSpacingPhysical
                    $MacInterface.MacAddressArray | Group-Object VendorCompanyName |sort count  |select count,name |% { $name += "$($_.Count) $($_.name)`r`n" }
                    $MacInterface.MacAddressShape=Draw-Shape -shapetype "circle" -ShapeText $name -Location (($Location[0]+$i-$InterfaceDrawingLocationOffset),($Location[1]+$GMacAddressOffSetY)) -color $MacInterface.ShapeColor
                    Connect-VisioShape -From $MacInterface.Physicalshape -To $MacInterface.MacAddressShape -Master $Gdyncon_m | out-null
                    $MacInterface.InterfaceAlreadyDrawn=$true
                }
            }
            $name=$null
        }
    }
    $ShapeGroup=@()
    $ShapeGroup+= ($device.interfaces | where { $_.InterfaceAlreadyDrawn }|select PhysicalshapeGroup | % { $_.PhysicalshapeGroup } )
    $ShapeGroup+=$device.shape
    Join-VisioShape -Shape $ShapeGroup | out-null
    #return the device and the width of the host also. This is used for spacing of visio objects.
    return $Device,$hostwidth
}


#Draws a layer 3 host.
function Draw-HostLayer3(){
    param (
		[parameter(Mandatory=$true)]
		$Device,
        $Location,
        $HostType
    )
    write-HostDebugText "Drawing L3host: $($Device.hostname)"
    #Create a shape
    $master = Get-VisioMaster "Rounded rectangle" -Document $Gbasic_u

    #Color,size and other parameters
    $shape_cells = New-VisioShapeCells
    #Interfaces
    $LogicalInterfaces=($Device.interfaces | where { $_.ipaddress })
    #$hostwidth is the width of the host. This is passed back to the draw host function so that we can put better spacing between hosts.
    [int]$hostwidth= (($LogicalInterfaces.count+1)*$GLogicalInterfaceFormWidth) + (($LogicalInterfaces.count+1)*$GEthernetSpacingLogical)
    $shape_cells.XFormWidth = $hostwidth

    if([int]$shape_cells.XFormWidth -lt $GLayer3HostFormWidth){#Fix form width if it is lower then the minumum
        $shape_cells.XFormWidth=$GLayer3HostFormWidth
        [int]$hostwidth=$GLayer3HostFormWidth
    }
    $shape_cells.XFormHeight = $GLayer3HostFormHeight
    if($HostType -eq "GatewayHost"){
        $HostNameText="$($Device.HostName)"
        $shape_cells.FillForeground = $Layer3ARPHostColour
    }else{
        $HostNameText="$($Device.DeviceIdentifier) : $($Device.HostName)"
        $shape_cells.FillForeground = $Layer3HostColour
    }
    $shape_cells.LineWeight = "2 pt"
    $shape_cells.CharSize=$GCDPHostFontSize
    #Where are we putting it
    $Location=(($Location[0]+$hostwidth/2),$Location[1])
    $points = New-Object VisioAutomation.Geometry.Point($Location)
    try{
        $Device.shape= New-VisioShape -Master $master -Position $points -Cells $shape_cells
    }catch{
        write-HostDebugText "----------------------" -BackgroundColor red
        write-HostDebugText "Failed to draw Layer3 host:" -BackgroundColor red
        write-HostDebugText $Device.hostname -BackgroundColor red
        write-HostDebugText "----------------------" -BackgroundColor red
    }
    Set-VisioText $HostNameText  -Shape $Device.shape | out-null
    $i=0
    $InterfaceDrawingLocationOffset=($shape_cells.XFormWidth/2)-$GLogicalInterfaceFormWidth
    foreach ($Interface in $LogicalInterfaces | sort vrf,interface){
        $Interface.Logicalshape=Draw-LogicalInterface -Interface $Interface -Location (($Location[0]+$i-$InterfaceDrawingLocationOffset),($Location[1]+$GLogicalInterfacesOffsetY))
        write-HostDebugText "Logical-$($Interface.interface)"
        $i=$i+$GLogicalInterfaceFormWidth+$GEthernetSpacingLogical
    }
    $ShapeGroup=@()
    $ShapeGroup+= ($device.interfaces | where { $_.Logicalshape }|select Logicalshape | % { $_.Logicalshape } )
    $ShapeGroup+=$device.shape
    if($HostType -eq "GatewayHost"){
        $TempShape=Draw-CustomShapeFromMTAutoStencil  -shapetype "Router" -Location ($Location[0],($Location[1]-$GCDPARPIconOffsetDown))
         $ShapeGroup+=$TempShape
    }
    Join-VisioShape -Shape $ShapeGroup | out-null
    return $Device,$hostwidth
}

#Draw IP address interface e.g vlan 1 192.168.0.1/24
function Draw-LogicalInterface(){
    param (
		[parameter(Mandatory=$true)]
		$Interface,
        $Location #example (0,0)
    )
    #Create a shape
    $master = Get-VisioMaster "Rounded Rectangle" -Document $Gbasic_u
    #Color,size and other parameters
    $shape_cells = New-VisioShapeCells
    $shape_cells.XFormWidth = $GLogicalInterfaceFormWidth
    $shape_cells.XFormHeight = $GLogicalInterfaceFormHeight
    $shape_cells.CharSize=$GLogicalInterfaceFontSize
    if($GShortenInterfacesNames){
        $text="$( Replace-InterfaceLongName -string $Interface.Interface  )`r`n"
    }
    else{
        $text="$($Interface.Interface)`r`n"
    }
    if($Interface.subnetmask){
    $text+="$($Interface.ipaddress)`/$($Interface.subnetmask)"
    }else{
        $text+="$($Interface.ipaddress)"
    }
    if($Interface.Description){
        $text+="`r`n$($Interface.Description)`r`n"
    }
    if($Interface.standbyip){#HSRP address.
        $text+="`r`nHSRP:$($Interface.standbyip)`r`n"
        $shape_cells.XFormHeight =  $GLogicalInterfaceFormHeight + $GVRFTextSizeExtension
    }
    if($Interface.ClusterIP){#ClusterIP address for a checkpoint.
        $text+="`r`ClusterIP:$($Interface.ClusterIP)`r`n"
        $shape_cells.XFormHeight =  $GLogicalInterfaceFormHeight + $GVRFTextSizeExtension
    }

    if($Interface.shutdown -or ($Interface.IntStatus -like "*down*" -and $Interface.INTProtocolStatus -like "*down*")){
        if ($interface.vrf){
            $text+="`r`nVRF:$($interface.vrf)"
        }
        $text+="`r`nSHUTDOWN"
        $shape_cells.FillForeground = "rgb(255,0,0)"
        $Location[1]=$Location[1]-$GLayer3HostFormHeight
    }else{
        if ($interface.vrf){
            $shape_cells.FillForeground = "rgb(" + $interface.VRFColor + ")"
            $text+="`r`nVRF:$($interface.vrf)"
            if($Interface.standbyip){
                $shape_cells.XFormHeight =  $GLogicalInterfaceFormHeight*2 + $GVRFTextSizeExtension
            }else{
                $shape_cells.XFormHeight =  $GLogicalInterfaceFormHeight + $GVRFTextSizeExtension
            }
        }else{
            $shape_cells.FillForeground = "rgb(255,255,255)"
        }
    }
    $shape_cells.LineWeight = "2 pt"
    $points = New-Object VisioAutomation.Geometry.Point($Location)
    $InterfaceShape= New-VisioShape -Master $master -Position $points -Cells $shape_cells
    Set-VisioText $text -Shape $InterfaceShape
    return $InterfaceShape
}



#Get Phyiscal Interfaces on a device.
#Exclude Vlans,mgmt and sub interfaces
function Get-PhysicalInterfaces(){
    param (
		[parameter(Mandatory=$true)]
		$Device
    )
    $Interfaces=$Device.interfaces | where { $_.Interface -notlike "Port-channel*" -and $_.Interface -notlike "Vlan*" -and $_.Interface -notmatch "^(G|T|E|F).*?\..*?" }
    if($Interfaces.count -eq 0){
        #if we don't have any interfaces just return them all. This will create larger objects with interfaces that are not needed. But it is better
        #then having a device with no interfaces.
        $Interfaces=$Device.interfaces
    }
    return $Interfaces
}


#This is used to draw a Ethernet device and it's ports.
#This is used to Draw CDP or LLDP neighbors we don't have a config for.
#Note this function can be very slow because it may draw lots of interfaces.
function Draw-HostEthernet(){
    param (
		[parameter(Mandatory=$true)]
		$Device,
        $Location, #example (0,0)
        $DrawType
    )
    #Create a shape
    $master = Get-VisioMaster "Rounded rectangle" -Document $Gbasic_u
    #Where are we putting it
    $points = New-Object VisioAutomation.Geometry.Point($Location)
    #Color,size and other parameters
    $shape_cells = New-VisioShapeCells
    $HostNameText=""
    $PhysicalInterfaces=Get-PhysicalInterfaces -Device $Device


    $shape_cells.XFormWidth = ($PhysicalInterfaces.Count*$GEthernetSpacingPhysical) + ($PhysicalInterfaces.Count*$GPhysicalInterfaceFormWidth)
    if($DrawType -eq "CDPNeighbor" -or $DrawType -eq "LLDPNeighbor"){
        $HostNameText="$($Device.HostName)`r`n$($Device.Description)`r`n$($Device.ArrayOfIPAddresses| sort -unique | out-string)"
        $shape_cells.XFormHeight = $GEthernetHostFormHeight + $GNeighborHightExtension
    }else{
        $HostNameText=$Device.HostName
        $shape_cells.XFormHeight = $GEthernetHostFormHeight
    }
    if([int]$shape_cells.XFormWidth -lt $GEthernetHostFormWidth){#Fix form width if it is lower then the minumum
        $shape_cells.XFormWidth=$GEthernetHostFormWidth + $GPhysicalInterfaceFormWidth
    }
    if($DrawType -eq "CDPNeighbor" ){
        $shape_cells.FillForeground = "rgb(100,100,100)"
    }elseif ($DrawType -eq "LLDPNeighbor"){
        $shape_cells.FillForeground = "rgb(200,200,100)"
    }else{
        $shape_cells.FillForeground = "rgb(100,100,100)"
    }
    $shape_cells.LineWeight = "2 pt"
    $shape_cells.CharSize=$GHostEthernetFontSize
    try{
        $Device.shape= New-VisioShape -Master $master -Position $points -Cells $shape_cells

    }catch{
        write-HostDebugText "----------------------" -BackgroundColor red
        write-HostDebugText "Unable to draw Ethernet Host" -BackgroundColor red
        write-HostDebugText $Device.hostname -BackgroundColor red
        write-HostDebugText "----------------------" -BackgroundColor red
        return $Device
    }
    Set-VisioText $HostNameText  -Shape $Device.shape

    if($DrawType -eq "CDPNeighbor" -or $DrawType -eq "LLDPNeighbor"){
        try{
            switch -wildcard ($Device.Capabilities){
                "*Trans-Bridge*"{
                    $TempShape=Draw-CustomShapeFromMTAutoStencil  -shapetype "Wireless" -Location ($Location[0],($Location[1]-$GCDPLLDPIconOffsetDown))
                    write-HostDebugText "Wireless"
                    break
                    }
                "*Host*"{
                    if($Device.version -like "*Cisco Controller*"){
                        $TempShape=Draw-CustomShapeFromMTAutoStencil  -shapetype "WirelessController" -Location ($Location[0],($Location[1]-$GCDPLLDPIconOffsetDown))
                        write-HostDebugText "Cisco Controller"
                        break
                    }else{
                        $TempShape=Draw-CustomShapeFromMTAutoStencil  -shapetype "Host" -Location ($Location[0],($Location[1]-$GCDPLLDPIconOffsetDown))
                        write-HostDebugText "Host"
                        break
                    }
                    }
                "*Router*"{
                    $TempShape=Draw-CustomShapeFromMTAutoStencil  -shapetype "Router" -Location ($Location[0],($Location[1]-$GCDPLLDPIconOffsetDown))
                    write-HostDebugText "Router"
                    break
                    }
                "*Switch*"{
                    $TempShape=Draw-CustomShapeFromMTAutoStencil  -shapetype "Switch" -Location ($Location[0],($Location[1]-$GCDPLLDPIconOffsetDown))
                    write-HostDebugText "Switch"
                    break
                    }
                default{
                    write-HostDebugText "Not adding icon. We don't have a icon to representation for this type of device. "
                }
            }
        }catch{
            write-HostDebugText "----------------------" -BackgroundColor red
            write-HostDebugText "Unable to draw CustomShapeFromMTAutoStencil" -BackgroundColor red
            write-HostDebugText $Device.hostname
            write-HostDebugText "----------------------" -BackgroundColor red
        }
    }


    if($PhysicalInterfaces){
        $i=0
        #TODO:Fix this physical interfaces array issue
        foreach ($PhysicalInterface in $PhysicalInterfaces ){

            $Interface=$null
            $Interface=$Device.interfaces | where { $_.interface -eq $PhysicalInterface.interface }

            if(!($interface)){
                write-HostDebugText "Not interface found for:$($PhysicalInterface) moving to next interface."
                continue
            }
            if($DrawType -eq "CDPNeighbor" -or $DrawType -eq "LLDPNeighbor"){#Need to move the interface up a little because it is slightly larger.
                $Interface.Physicalshape,$Interface.PhysicalshapeGroup=Draw-PhysicalInterface -Interface $Interface -Location (($Location[0]+$i-($shape_cells.XFormWidth/2-$GPhysicalInterfaceFormWidth+$GEthernetSpacingPhysical)),($Location[1]+$GPhysicalInterfaceOffSetUP))
            }else{
                $Interface.Physicalshape,$Interface.PhysicalshapeGroup=Draw-PhysicalInterface -Interface $Interface -Location (($Location[0]+$i-($shape_cells.XFormWidth/2-$GPhysicalInterfaceFormWidth+$GEthernetSpacingPhysical)),($Location[1]+$GPhysicalInterfaceOffSetUP))
            }
            $i=$i+($GEthernetSpacingPhysical*3)
            write-HostDebugText "$($Interface.interface)   ---- $($Interface)"
        }
        $ShapeGroup=@()
        if(($device.interfaces | where { $_.PhysicalshapeGroup }|select PhysicalshapeGroup | % { $_.PhysicalshapeGroup } ).count -ne 0){
            $ShapeGroup+=($device.interfaces | where { $_.PhysicalshapeGroup }|select PhysicalshapeGroup | % { $_.PhysicalshapeGroup } )
            $ShapeGroup+=$device.shape
            if($TempShape){
                $ShapeGroup+=$TempShape
            }
            write-HostDebugText $ShapeGroup
            Join-VisioShape -Shape $ShapeGroup | out-null
        }else{
            write-HostDebugText "error you cant' have a count of 0 ethernet interfaces" -BackgroundColor red
        }
    }else{
        write-HostDebugText "No PhysicalInterfaces something went wrong" -BackgroundColor red
    }
    return $Device
}

#Draw a shape. These are used for vlans, gateways and other basic shapes.
#Draw vlan
#Draw gateways for static routes
function Draw-Shape(){
    param (
		[parameter(Mandatory=$true)]
        $ShapeType,
		$ShapeText,
        $Location,        #example (0,0)
        $color,
        $size
    )
    #Create a shape
    $master = Get-VisioMaster $ShapeType -Document $Gbasic_u
    #Where are we putting it
    $points = New-Object VisioAutomation.Geometry.Point($Location)
    #Color,size and other parameters
    $shape_cells = New-VisioShapeCells
    if($size){
        $shape_cells.XFormWidth = $size[0]
        $shape_cells.XFormHeight = $size[1]
    }else{
        $shape_cells.XFormWidth = 2
        $shape_cells.XFormHeight = 1
    }
    if($color){
        $shape_cells.FillForeground = "rgb(" +"$($color)" + ")"
    }else{
        $shape_cells.FillForeground = "rgb(" + "$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0)" + ")"
    }
    $shape_cells.LineWeight = "2 pt"
    try{
        $Shape= New-VisioShape -Master $master -Position $points -Cells $shape_cells
    }
    Catch{
        write-HostDebugText "Error Creating device:$($_.Exception)" -ForegroundColor green
        write-HostDebugText write-HostDebugText "$($ShapeText),$($Location),$($color),$($ShapeType),$($size),$($shape_cells),$($points)" -BackgroundColor red
        return $null #If there is an error don't stuff up the text of another object just move on.
    }
    if($ShapeText){
        Set-VisioText $ShapeText -Shape $Shape
    }
    return $Shape
}






#Draw a Ethernet VLAN. This is used to draw the ethernet shapre for vlans.

function Draw-CustomShapeFromMTAutoStencil(){
    param (
		[parameter(Mandatory=$true)]
        $ShapeType,
		$ShapeText,
        $Location,        #example (0,0)
        $color,
        $size
    )
    #Create a shape
    $master = Get-VisioMaster $ShapeType -Document $GMTAutoStencil
    #Where are we putting it
    $points = New-Object VisioAutomation.Geometry.Point($Location)
    #Color,size and other parameters
    $shape_cells = New-VisioShapeCells
    if($size){
        $shape_cells.XFormWidth = $size[0]
        $shape_cells.XFormHeight = $size[1]
    }
    if($color){#If we don't have color leave as default
        $shape_cells.FillForeground = "rgb(" +"$($color)" + ")"
    }
    $shape_cells.LineWeight = "2 pt"
    try{
        $Shape= New-VisioShape -Master $master -Position $points -Cells $shape_cells
    }
    Catch{
        write-HostDebugText "Error Creating device:$($_.Exception)" -ForegroundColor green
        write-HostDebugText write-HostDebugText "$($ShapeText),$($Location),$($color),$($ShapeType),$($size),$($shape_cells),$($points)" -BackgroundColor red
        return $null #If there is an error don't stuff up the text of another object just move on.
    }
    if($ShapeText){
        Set-VisioText $ShapeText -Shape $Shape
    }
    return $Shape
}
