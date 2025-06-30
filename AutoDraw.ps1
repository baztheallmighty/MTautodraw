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
    "DrawFunctions_drawio.ps1", 
    "CiscoConfigProcessingFunctions.ps1",
    "DrawLogic_drawio.ps1",    
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


# --- Global drawio Variables ---
$global:itemCounter = 0
$global:drawioXml = ""


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


if($GDrawMultipleDevicesDiagram){
    write-HostDebugText "Initializing Multi-Device Draw.io file..." -ForegroundColor Cyan
    Initialize-DrawioFile
    
    if($GDrawCDP){
        Draw-AllNeighborsDrawio -ArrayOfObjects $GArrayOfObjects -ArrayOfCDPDeviceIDs $GArrayOfCDPDeviceIDs -ArrayOfLLDPDeviceIDs $GArrayOfLLDPDeviceIDs
    }
    if($GDrawLayer3){
        Draw-AllLayer3Drawio -ArrayOfObjects $GArrayOfObjects -ArrayOfNetworks $GArrayOfNetworks -ArrayOfIPApr $GArrayOfIPApr -DiagramType "Normal" -NameOfPage "Layer 3 All"
    }
    if($GDrawLayer3RoutedLinksOnly){
        Draw-AllLayer3Drawio -ArrayOfObjects $GArrayOfObjects -ArrayOfNetworks $GArrayOfNetworks -ArrayOfIPApr $GArrayOfIPApr -DiagramType "LinksOnly" -NameOfPage "Layer 3 Routed Links Only" -ArrayofGatewayHosts $GArrayofGatewayHosts
    }
    if($GDrawLayer3RoutesOnly){
        Draw-AllLayer3Drawio -ArrayOfObjects $GArrayOfObjects -ArrayOfNetworks $GArrayOfNetworks -ArrayOfIPApr $GArrayOfIPApr -DiagramType "RoutesOnly" -NameOfPage "Layer 3 Routes Only" -ArrayofGatewayHosts $GArrayofGatewayHosts
    }

    Finalize-DrawioFile
    $multiDeviceFilePath = "$($GOutPutDirectory)MTAudotDraw-MultiDevice-$(get-date -Format yyyyMMdd-hhmm).drawio"
    Save-DrawioFile -Path $multiDeviceFilePath
    write-HostDebugText "Multi-Device Diagram saved to $multiDeviceFilePath" -ForegroundColor Green
}

# Draw Single-Device Diagrams
if($GdrawSingles){
    write-HostDebugText "Initializing Singles Draw.io file..." -ForegroundColor Cyan
    Initialize-DrawioFile

    foreach ($Device in $GArrayOfObjects){
        if($GDrawLayer3){
            Draw-SinglesLayer3Drawio -Device $Device -ArrayOfNetworks $GArrayOfNetworks
        }
    }

    Finalize-DrawioFile
    $singlesFilePath = "$($GOutPutDirectory)MTAudotDraw-Singles-$(get-date -Format yyyyMMdd-hhmm).drawio"
    Save-DrawioFile -Path $singlesFilePath
    write-HostDebugText "Single-Device Diagrams saved to $singlesFilePath" -ForegroundColor Green
}


Stop-Transcript
