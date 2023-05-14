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


#This is the main function. It calls all the other functions.



Param(
    [Parameter(Mandatory = $true)]
    [string] $GDirectory,
    [Parameter(Mandatory = $false)]
    [string] $GPathToScript,
    [Parameter(Mandatory = $true)]
    [string] $GOutPutDirectory   
)

function write-HostDebugText(){
        param (
		[parameter(Mandatory=$true)]
		$text,
        $BackgroundColor,
        $ForegroundColor
    )
    if($GDebugingEnabled -ne $false){
        if(!($ForegroundColor)){
            $ForegroundColor="white"
        }
        write-Host "Time Total:$($global:GLastExecutionTime.ElapsedMilliseconds/1000) - Lap:$(($global:GLastExecutionTime.ElapsedMilliseconds-$global:GLapTime)/1000)"
        if($BackgroundColor){
            write-Host $text -BackgroundColor $BackgroundColor -ForegroundColor $ForegroundColor
        }else{
            write-Host $text -ForegroundColor $ForegroundColor
        }
        $global:GLapTime=$global:GLastExecutionTime.ElapsedMilliseconds
    }
}


if(!$GDirectory){
    write-HostDebugText "No Directory given. Using Current directory"
    $GDirectory =(Get-Location).path
}
if(!$GPathToScript){
    write-HostDebugText "No PathToScript given. Using Current directory"
    $GPathToScript =(Get-Location).path
}
if(!$GOutPutDirectory){
    write-HostDebugText "No OutPutDirectory given. Using Current directory"
    $GOutPutDirectory =(Get-Location).path
}
#Make sure we have a trailing slash.
if($GOutPutDirectory -notmatch "\\$"){
    $GOutPutDirectory="$($GOutPutDirectory)`\"
}
if($GPathToScript -notmatch "\\$"){
    $GPathToScript="$($GPathToScript)`\"
}
if($GDirectory -notmatch "\\$"){
    $GDirectory="$($GDirectory)`\"
}

Start-Transcript -Path "$($GOutPutDirectory)Log$(get-date -Format "yyyyMMddhhmmss").txt" -NoClobber
###############################################    load libraries and error checking     ###############################################

#Used to print measure how long the script runs for.
$global:GLastExecutionTime=[System.Diagnostics.Stopwatch]::StartNew()
$global:GLapTime=$global:GLastExecutionTime.ElapsedMilliseconds


$GLibrariesToLoad=@(
"ObjectFunctions.ps1",
"DrawFunctions.ps1",
"CiscoConfigProcessingFunctions.ps1",
"DrawLogic.ps1",
"HelperFunctions.ps1",
"configurationVariables.ps1",
"CheckPointConfigProcessingFunctions.ps1",
"CiscoASAConfigProcessingFunctions.ps1",
"StartProcessingConfig.ps1",
"JunosConfigProcessingFunctions.ps1"
)

#Check all the templates exist
foreach ($template in $GTemplate.PSObject.Properties){
    if(!( test-path $template.value)){
        write-HostDebugText "Missing Template $($template). Exiting"
        return
    }
}
foreach ($libary in $GLibrariesToLoad){
    if(test-path ($GPathToScript+$libary)){
        Import-Module "$($GPathToScript)$($libary)" -force
        write-HostDebugText "loading:$($GPathToScript)$($libary)"
    }else{
        write-HostDebugText "Could not find $($libary) exiting"
        return
    }
}

if(test-path "$($GPathToScript)GETIPV4Subnet\GetIPv4Subnet.psm1"){
    Import-Module -Name "$($GPathToScript)GETIPV4Subnet\GetIPv4Subnet.psm1" -Verbose -force
}else{
    write-HostDebugText "Could not find GetIPv4Subnet.psm1 exiting"
    return
}

if( ! (test-path $GPathToPythonExe)){
    write-HostDebugText "Could not find Python.exe in $($GPathToPythonExe) exiting"
    return
}

if( ! (test-path $GPathToPythonTextFSMScript)){
    write-HostDebugText "Could not find $($GPathToPythonTextFSMScript) exiting"
    return
}

#Do we have the visio module installed?
while(! (Get-Module -ListAvailable -Name visio)) {
    write-HostDebugText "Visio Module not installed"
    $GInstall="NOTSET"
    $GInstall= Read-Host -Prompt "Try and install visio module from PSGallery Y=yes, N=No? (Powershell must run as administrator to install modules)"
    if($GInstall -eq "y" -or $GInstall -eq "Y" -or $GInstall -eq "yes" -or $GInstall -eq "Yes"){
        Install-Module visio
        sleep 1
    }else{
        return
    }
}
Import-Module Visio
if(!(Get-Module visio)){
    write-HostDebugText "Visio module not loaded. Do you have it installed? Install-Module visio will install the module. https://saveenr.gitbook.io/visiopowershell/installation/install-visiops"
    return
}
#Python check

if($GPathToPythonExe){

    if(!(test-path $GPathToPythonExe)){
        write-HostDebugText "Python.exe location not defined. $GPathToPythonExe is required. Cannot continue. exiting."
        return
    }
}else{
    
    if ((get-childitem env:path).value -split ";" | where { $_ -like "*python*" } |select -First 1){
       $GPathToPythonExe="$((get-childitem env:path).value -split ";" | where { $_ -like "*python*" } |select -First 1)python.exe"
    }
    if(!(test-path $GPathToPythonExe)){
        write-HostDebugText "Python.exe location not defined. $($GPathToPythonExe) is required. Cannot continue. exiting."
        return
    }    
}
#Python version check 

#if(!(((& $GPathToPythonExe -V) -replace "Python ",'' -replace "\.",'') -lt 395)){
#    write-HostDebugText "Python.exe $GPathToPythonExe needs to be version 3.9.5 or higher. Untested on lower versions, might work?? Exiting. "
#    return
#}
##Is textfsm installed???
##TODO FIX this it's hardcoded???
#try{
#    if(!(& pip list | where { $_ -like "textfsm*" })){
#        write-HostDebugText "Textfsm not installed. This is required. Cannot continue. exiting."
#        return
#    }
#}
#catch{
#   write-HostDebugText  "Pip not installed. Python not install????. Textfsm check failed. exiting"
#   return
#}

###############################################    MAIN     ###############################################
#Load known mac to vendor mapping of mac addresses into a hash table for quick lookup.
#Also downloads the mapping if not present on disk.
$GMacAddressToVendorMapping=Get-MacAddressToVendorMapping
#Process all config files
$GArrayOfObjects=@() #Array of all the devices,their networks, bgp,cdp,etc
$GArrayOfNetworks=@() #List of unquie networks shared across all devices.
$GArrayOfLLDPDeviceIDs=@() #Array of all LLDP Objects we have processed across all hosts.
$GArrayOfCDPDeviceIDs=@() #Array of all CDP Objects we have processed across all hosts.
$GArrayOfIPApr=@() #Create an array of ip ARP entries. This will be used when drawing layer 3 diagrams.
$GArrayofGatewayHosts=@() #An Array of LLDP,CDP or ARP gateway hosts we know about. This is used to draw the layer 3 link diagram.

$GArrayOfNetworks,$GArrayOfObjects,$GArrayOfCDPDeviceIDs,$GArrayOfLLDPDeviceIDs,$GArrayOfIPApr,$GArrayofGatewayHosts = Start-ProcessingFiles


#Output data to csv and json
if($GExportData){
    write-HostDebugText "Exporting data to files"
    $GArrayOfObjects | where { $_.vlans} | % { $t=$_.vlans; $t |Add-Member -Name partentobject -Type NoteProperty -Value $_.hostname -Force; $t } | export-csv "$($GOutPutDirectory)vlans.csv" -NoTypeInformation
    $GArrayOfObjects | % { $_.CDPNeighbors } | select DeviceID,SystemName,Platform,InterfaceLocalDevice,InterfaceRemoteDevice,Version,InterfaceIPAddresses,Capabilities,ParentObject | Export-Csv -Path "$($GOutPutDirectory)CDPNeighbors.csv" -NoTypeInformation
    $GArrayOfObjects | % { $_.LLDPNeighbors } | select PartnerEthernetInterface,InterfaceLocalDevice,ChassisID,InterfaceRemoteDevice,NeighborInterfaceDescription,Hostname,SystemDescription,Capabilities,ManagementIP,VLAN,SERIAL,PortID,ParentObject | Export-Csv -Path "$($GOutPutDirectory)LLDPNeighbors.csv" -NoTypeInformation

    $GArrayOfObjects | % {
        $t=$_.ArrayOfNetworks;
        $t |Add-Member -Name partentobject -Type NoteProperty -Value $_.hostname -Force;
        $t |Add-Member -Name DeviceIdentifier -Type NoteProperty -Value $_.DeviceIdentifier -Force;
        $t |Add-Member -Name DeviceInVlan -Type NoteProperty -Value $null -Force;
        $t | % { $_.DeviceInVlan = (($_.ARPEntries | group VendorCompanyName | select count,name | sort count -Descending | ft -HideTableHeaders | out-string) -replace "(?smi)^\s+",""  ).trim() }
        $t
    } | select DeviceIdentifier,cidr,routedvlan,networkname,partentobject,DeviceInVlan | export-csv "$($GOutPutDirectory)cidr.csv" -NoTypeInformation

    $GArrayOfObjects | ConvertTo-Json | Out-File "$($GOutPutDirectory)Objects.json" -Encoding utf8
}

$GApplication=New-VisioApplication
$GDocument=New-VisioDocument
#Get some basic constants
$Gbasic_u = Open-VisioDocument "basic_u.vss"
$GAnnotations = Open-VisioDocument "Annotations.vss"

#This is none open source and would need to be replaced in the event of distributing the code.
#This would need to be change to create two templates one for Ethernet and one for a CiscoAP.
$GMTAutoStencil = Open-VisioDocument "$($GPathToScript)Visiostencil\MTAutoDefaultDefault.vssx"


$Gdyncon_m = Get-VisioMaster -Name "Dynamic Connector" -Document $Gbasic_u

if($GDrawMultipleDevicesDiagram){
    if($GDrawLayer3RoutesOnly){#Set this to true to draw a diagram of only the routes.
        Draw-AllLayer3 -ArrayOfObjects $GArrayOfObjects -ArrayOfNetworks $GArrayOfNetworks -ArrayOfIPApr $GArrayOfIPApr -DiagramType "RoutesOnly" -NameOfPage "Layer 3 Routes only" -ArrayofGatewayHosts $GArrayofGatewayHosts
    }
    if($GDrawCDP){
        Draw-AllNeighbors -ArrayOfObjects $GArrayOfObjects -ArrayOfCDPDeviceIDs $GArrayOfCDPDeviceIDs -ArrayOfLLDPDeviceIDs $GArrayOfLLDPDeviceIDs
    }
    if($GDrawEthernet){
        Draw-AllEthernet -ArrayOfObjects $GArrayOfObjects
    }

    if($GDrawLayer3RoutedLinksOnly){#Set this to true to link a interface to a vlan only if it has routes.
        Draw-AllLayer3 -ArrayOfObjects $GArrayOfObjects -ArrayOfNetworks $GArrayOfNetworks -ArrayOfIPApr $GArrayOfIPApr -DiagramType "LinksOnly" -NameOfPage "Layer 3 Routed links only" -ArrayofGatewayHosts $GArrayofGatewayHosts
    }
    if($GDrawLayer3){
        Draw-AllLayer3 -ArrayOfObjects $GArrayOfObjects -ArrayOfNetworks $GArrayOfNetworks -ArrayOfIPApr $GArrayOfIPApr -DiagramType "Normal" -NameOfPage "Layer 3 all"
    }
}

if($GdrawSingles){
    write-HostDebugText "Drawing all singles: $($NameOfPage)" -ForegroundColor green
    foreach ($Device in $GArrayOfObjects){
        if($GDrawCDP){
        }
        if($GDrawLayer3){
            Draw-SinglesLayer3 -Device $Device -ArrayOfNetworks $GArrayOfNetworks
        }
    }
}



try{
    save-VisioDocument "$($GOutPutDirectory)$(get-date -Format yyyy-MM-dd-hh-mm).vsdx"
}
catch{
        write-HostDebugText "----------------------Error saving file ----------------------" -BackgroundColor red
        write-HostDebugText "$($GOutPutDirectory)$(get-date -Format yyyy-MM-dd-hh-mm)" -BackgroundColor red
        write-HostDebugText "----------------------" -BackgroundColor red
}


Close-VisioDocument
Close-VisioApplication
Stop-Transcript
