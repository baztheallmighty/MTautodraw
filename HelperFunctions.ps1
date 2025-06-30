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


#This contains helper functions used by the script.

#This function is used to exit the script cleanly.
function Start-CleanupAndExit {
    Stop-Transcript
}


#This Checks if the interface is a known valid interface type
#It returns true if so
#and false if not
function Check-InterfaceType{
    param
    (
        $String
    )
    switch -Regex ($String){
        'vlan(\d+.*)'                   {return $true}
        'Serial(\d+.*)'                 {return $true}
        'Ethernet(\d+.*)'               {return $true}
        'Port-channel(\d+.*)'           {return $true}
        'GigabitEthernet(\d+.*)'        {return $true}
        'TwentyFiveGigE(\d+.*)'         {return $true}
        'TenGigabitEthernet(\d+.*)'     {return $true}
        'FastEthernet(\d+.*)'           {return $true}
        'FortyGigabitEthernet(\d+.*)'   {return $true}
        'AppGigabitEthernet(\d+.*)'     {return $true}
        'vl(\d+.*)'                     {return $true}
        'Se(\d+.*)'                     {return $true}
        'Eth(\d+.*)'                    {return $true}
        'Po(\d+)'                       {return $true}
        'Gi(\d+.*)'                     {return $true}
        'Twe(\d+.*)'                    {return $true}
        'Te(\d+.*)'                     {return $true}
        'fa(\d+.*)'                     {return $true}
        'Fo(\d+.*)'                     {return $true}
        'Lo(\d+.*)'                     {return $true}
        'Ap(\d+.*)'                     {return $true}
        ''                              {return $false}
        $null                           {return $false}
        default{
            return $false
        }
    }
}



function Replace-InterfaceShortName {
    param (
        $String
    )
    
    # This code will now ONLY run if the .Trim() method in the 'try' block succeeds.
    $String = $String.Trim() -replace "vl(\d+.*)", 'Vlan$1' `
        -replace "Se(\d+.*)", 'Serial$1' `
        -replace "Eth(\d+.*)", 'Ethernet$1' `
        -replace "Po(\d+)", 'Port-channel$1' `
        -replace "Gi(\d+.*)", 'GigabitEthernet$1' `
        -replace 'Twe(\d+.*)', 'TwentyFiveGigE$1' `
        -replace "Te(\d+.*)", 'TenGigabitEthernet$1' `
        -replace "fa(\d+.*)", 'FastEthernet$1' `
        -replace "Fo(\d+.*)", 'FortyGigabitEthernet$1' `
        -replace "Ap(\d+.*)", 'AppGigabitEthernet$1' `
        -replace "Lo(\d+.*)", 'Loopback$1'
    
    return $String
}



#This function takes a string input and replace the long name with the short name version of the interface
function Replace-InterfaceLongName{
    param
    (
        $String
    )
  
    $String=$String -replace "Vlan",'vl'`
                    -replace "Serial",'Se'`
                    -replace 'Port-channel','Po'`
                    -replace "FortyGigabitEthernet",'Fo'`
                    -replace "AppGigabitEthernet",'Ap'`
                    -replace 'TenGigabitEthernet','Te'`
                    -replace 'TwentyFiveGigE','Twe'`
                    -replace 'GigabitEthernet','Gi'`
                    -replace 'FastEthernet','Fa'`
                    -replace 'Ethernet','Eth'`
                    -replace 'Loopback','Lo'
    return ($string.trim())
}


#This gets the encoding of a file. work around because Python doesn't like UTF16 files.
#Taken from here:
#https://community.idera.com/database-tools/powershell/powertips/b/tips/posts/get-text-file-encoding
function Get-Encoding{
    param
    (
        [Parameter(Mandatory,ValueFromPipeline,ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]
        $Path
    )
    process
    {
        $bom = New-Object -TypeName System.Byte[](4)
        $file = New-Object System.IO.FileStream($Path, 'Open', 'Read')
        $null = $file.Read($bom,0,4)
        $file.Close()
        $file.Dispose()
        $enc = [Text.Encoding]::ASCII
        if ($bom[0] -eq 0x2b -and $bom[1] -eq 0x2f -and $bom[2] -eq 0x76){ $enc =  [Text.Encoding]::UTF7 }
        if ($bom[0] -eq 0xff -and $bom[1] -eq 0xfe) { $enc =  [Text.Encoding]::Unicode }
        if ($bom[0] -eq 0xfe -and $bom[1] -eq 0xff) { $enc =  [Text.Encoding]::BigEndianUnicode }
        if ($bom[0] -eq 0x00 -and $bom[1] -eq 0x00 -and $bom[2] -eq 0xfe -and $bom[3] -eq 0xff) { $enc =  [Text.Encoding]::UTF32}
        if ($bom[0] -eq 0xef -and $bom[1] -eq 0xbb -and $bom[2] -eq 0xbf) { $enc =  [Text.Encoding]::UTF8}
        [PSCustomObject]@{
            Encoding = $enc
            Path = $Path
        }
    }
}

# This is used to run the python TextFSM library. It takes a paths to the various files and returns a json copy of the config or an error.
# MODIFIED: This function now caches the output in a .json sub-folder. If a cached file exists, it loads it instead of re-processing.
function Execute-PythonTextFSM() {
    param (
        $TextFSTETemplate,
        $ShowFile,
        $ReturnArray,
        $HostObject
    )

    #region --- Define Cache Paths ---
    # Construct the path for the cached JSON file in a '.json' subdirectory.
    $FileBaseName = [System.IO.Path]::GetFileNameWithoutExtension($ShowFile)
    $FileDirectory = Split-Path -Path $ShowFile -Parent
    $JsonCacheFolder = Join-Path -Path $FileDirectory -ChildPath ".json"
    $JsonCacheFile = Join-Path -Path $JsonCacheFolder -ChildPath "$($FileBaseName).json"
    #endregion

    # Check if the JSON file already exists.
    if (Test-Path -Path $JsonCacheFile) {
        # If it exists, load the content from the file instead of re-processing.
        Add-HostDebugText -HostObject $HostObject   "Cache hit. Loading from: $JsonCacheFile"
        $Objects = Get-Content -Path $JsonCacheFile -Raw | ConvertFrom-Json -Depth 10
    }
    else {
        # If it does not exist, run the original processing logic.
        Add-HostDebugText -HostObject $HostObject   "Cache miss. Processing file: $($ShowFile)"

        # Python doesn't like UTF-8, UTF16 or UTF16LE. Convert it to ASCII file.
        if ((Get-Encoding $ShowFile).encoding.EncodingName -ne "US-ASCII") {
            Add-HostDebugText -HostObject $HostObject   "Converting $($ShowFile) to Ascii"
            $TempFile = Get-Content $ShowFile | Where-Object { $_ -cmatch '[\x20-\x7F]' } #Trim out non-ascii Char's
            Set-Content -Value $TempFile -Encoding Ascii -Path $ShowFile #rewrite the file as Ascii.
        }

        # Execute the Python TextFSM script.
        $ProcessOutput = & $GPathToPythonExe $GPathToPythonTextFSMScript $TextFSTETemplate $ShowFile

        # Error handling for the script output.
        if (($ProcessOutput -like "Traceback*") -or ($ProcessOutput -like "An exception occurred*") -or ($ProcessOutput -eq "`[`]") -or ([string]::IsNullOrEmpty($ProcessOutput))) {
            Add-HostDebugText -HostObject $HostObject   "Error with TextFSM Processing $($ProcessOutput)."
            return "ERROR",$HostObject
        }

        # Convert the JSON output from the script into PowerShell objects.
        $Objects = $ProcessOutput | ConvertFrom-Json -Depth 10

        #region --- Save to Cache ---
        # Ensure the .json directory exists before saving the file.
        if (-not (Test-Path -Path $JsonCacheFolder)) {
            Add-HostDebugText -HostObject $HostObject   "Creating cache directory: $JsonCacheFolder"
            New-Item -Path $JsonCacheFolder -ItemType Directory -Force | Out-Null
        }

        # Convert the PowerShell object back to a formatted JSON string and write it to the cache file.
        # Using -Depth 10 to handle potentially nested objects.
        $Objects | ConvertTo-Json -Depth 10 | Out-File -FilePath $JsonCacheFile -Encoding utf8
        Add-HostDebugText -HostObject $HostObject   "Saved new cache file to: $JsonCacheFile"
        #endregion
    }
	return $Objects,$HostObject
    #region --- Return Logic ---
    # This logic ensures the function returns the object in the desired format (single object or array).
    #if ($ReturnArray) {
    #    # If an array is requested and the result is not already a collection, wrap it in an ArrayList.
    #    if ($Objects -isnot [System.Collections.ICollection] -or $Objects[0] -is "string") {
    #        # It's a single object, so we create a new collection and add our single object to it.
	#		write-host "single object converting to array"
    #        $myarray = [System.Collections.ArrayList]::new()
    #        [void]$myarray.Add($Objects)
    #        return ,$myarray
    #    }
    #    else {
    #        # It's already null, empty, or a collection. Return it as is.
    #        return $Objects
    #    }
    #}
    #else {
    #    # Return the single object or array as is.
    #    return $Objects
    #}
    #endregion
}

#Import mac to vendor mapping or get the MAC address xml file from devtools360.com and make a hash table with it.
function Get-MacAddressToVendorMapping(){
    $GMacAddressToVendorMapping=@{}
    if(Test-Path -Path .\MacAddressToVendorsMapping.csv){
        write-HostDebugText "MacAddressToVendorsMapping.csv exists importing mac address to vendor mapping"
        $MacAddressFile=import-csv MacAddressToVendorsMapping.csv
        foreach ($line in $MacAddressFile){
            $GMacAddressToVendorMapping.add($line.MacAddress,$line.Company)
        }
        return $GMacAddressToVendorMapping
    }
    write-HostDebugText "MacAddressToVendorsMapping.csv File not found downloading from https://devtools360.com"
    $XMLFile = (Invoke-WebRequest https://devtools360.com/en/macaddress/vendorMacs.xml?download=true).RawContent -split "`n"

    foreach ($line in $XMLFile){
        if($line -like "*mac_prefix*" -and $line -like "*vendor_name*"){
            $temp=$null
            $Temp=$line -replace "<VendorMapping mac_prefix=",'' -replace " vendor_name=",',' -replace '/>','' -replace '"','' -split ","

            $GMacAddressToVendorMapping.add($Temp[0],$Temp[1])
        }
    }
    write-HostDebugText "Writing MacAddressToVendorsMapping.csv to disk"
    "MacAddress,Company" >> MacAddressToVendorsMapping.csv;
    foreach ( $b in $GMacAddressToVendorMapping.GetEnumerator() ){
        "$($b.key),$($b.value)"  >> MacAddressToVendorsMapping.csv
    }
    return $GMacAddressToVendorMapping
}


#If the string is blank set it to null
function Compare-ToEmptyString(){
    param (
		[parameter(Mandatory=$true)]
		$string
    )
    if ($string -eq "" ){
        return $null
    }else{
        return $string
    }
}


########### Drawio functions to create and save files. ###########

function Initialize-DrawioFile {
    [CmdletBinding()]
    param (
        [string]$FileHost = "PowerShell",
        [string]$Agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) draw.io/27.0.9 Chrome/134.0.6998.205 Electron/35.4.0 Safari/537.36",
        [string]$Version = "27.0.9",
        [int]$Pages = 1
    )
    $global:itemCounter = 0
    $global:drawioXml = "<mxfile host=`"$FileHost`" agent=`"$Agent`" version=`"$Version`" pages=`"$Pages`">`n"
}

function Start-DrawioDiagram {
    [CmdletBinding()]
    param (
        [string]$Name = "Page-$($global:itemCounter + 1)",
        [string]$Id = (-join (([char[]]([guid]::NewGuid().ToString())) | ForEach-Object {if ("abcdefghijklmnopqrstuvwxyz0123456789".Contains($_)) {$_}}))
    )
    $global:itemCounter++
    $global:drawioXml += "  <diagram name=`"$Name`" id=`"$Id`">`n"
    $global:drawioXml += "    <mxGraphModel dx=`"1731`" dy=`"927`" grid=`"1`" gridSize=`"10`" guides=`"1`" tooltips=`"1`" connect=`"1`" arrows=`"1`" fold=`"1`" page=`"1`" pageScale=`"1`" pageWidth=`"850`" pageHeight=`"1100`" math=`"0`" shadow=`"0`">`n"
    $global:drawioXml += "      <root>`n"
    $global:drawioXml += "        <mxCell id=`"0`" />`n"
    $global:drawioXml += "        <mxCell id=`"1`" parent=`"0`" />`n"
}

function End-DrawioDiagram {
    [CmdletBinding()]
    param ()
    $global:drawioXml += "      </root>`n"
    $global:drawioXml += "    </mxGraphModel>`n"
    $global:drawioXml += "  </diagram>`n"
}

function Finalize-DrawioFile {
    [CmdletBinding()]
    param ()
    $global:drawioXml += "</mxfile>"
}

function Save-DrawioFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $global:drawioXml | Out-File -FilePath $Path -Encoding utf8
}

# This is the single source of truth for Port-Channel styles.
# It creates a random style if one doesn't exist for a channel, or returns the cached style.
function Get-OrSet-PortChannelStyle {
    [CmdletBinding()]
    param(
        [parameter(Mandatory=$true)]
        $channelNumber
    )

    # Check the global cache to see if we've already created a style for this channel.
    if (-not $global:runtimePortChannelStyles.ContainsKey($channelNumber)) {
        
        # If not, generate a new random style object.
        $r = Get-Random -Minimum 30 -Maximum 200 # Avoid very bright/dark colors
        $g = Get-Random -Minimum 30 -Maximum 200
        $b = Get-Random -Minimum 30 -Maximum 200
        $hexColor = Convert-RgbToHex -RgbString "rgb($r,$g,$b)"
        
        # Store the style object (color and width) in the global cache.
        $global:runtimePortChannelStyles[$channelNumber] = @{
            strokeColor = $hexColor
            strokeWidth = "5" # Use a consistent thick stroke for all Port-Channels
        }
    }
    
    # Return the style object from the cache.
    return $global:runtimePortChannelStyles[$channelNumber]
}

# Determines the connector style by calling the new central style function.
function Get-ConnectorStyle {
    [CmdletBinding()]
    param(
        [parameter(Mandatory=$true)]
        $fromInterface
    )

    if ($fromInterface.ChannelGroup) {
        $channelNumber = $fromInterface.ChannelGroup -replace '\D',''
        # Get the cached style object for this channel.
        $styleObject = Get-OrSet-PortChannelStyle -channelNumber $channelNumber
        
        # Format the style object into a full Draw.io style string for the connector.
        return "endArrow=none;html=1;strokeWidth=$($styleObject.strokeWidth);strokeColor=$($styleObject.strokeColor);"
    } else {
        # It's a regular link, so use the default style.
        return $GDefaultConnectorStyle
    }
}


#function Get-BGPSummaryFromText {
#    param (
#        [parameter(Mandatory=$true)]
#        $BGPSummaryFile,
#        $Device
#    )
#    $BGPSummaryText = Get-Content -raw $BGPSummaryFile
#    $AllBGPSummaryObjects=@()
#
#    if(($BGPSummaryText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing)").Matches.Success){
#        write-HostDebugText "BGP Summary file contains invalid data or is empty: $BGPSummaryFile" -BackgroundColor Red
#        return $device
#    }
#
#    $Template = $null
#    switch ($Device.version.type) {
#        "NXOS" { $Template = $GTemplate.NexusShowIPBGPSummaryTemplate }
#        "IOS" { $Template = $GTemplate.IOSShowIPBGPSummaryTemplate }
#        "XE-IOS" { $Template = $GTemplate.IOSShowIPBGPSummaryTemplate }
#        "CiscoASA" { $Template = $GTemplate.ASAShowBGPSummaryTemplate }
#        default {
#            write-HostDebugText "BGP Summary parsing not supported for device type $($Device.version.type)" -BackgroundColor Yellow
#            return $device
#        }
#    }
#
#    $ProcessOutputObjects = Execute-PythonTextFSM -TextFSTETemplate $Template -ShowFile $BGPSummaryFile -ReturnArray $true
#    if($ProcessOutputObjects -eq "ERROR"){
#        write-HostDebugText "Error with TextFSM processing for BGP Summary on file: $BGPSummaryFile" -BackgroundColor Red
#        return $device
#    }
#
#    foreach ($BGPSummaryEntry in $ProcessOutputObjects){
#        $BGPSummaryObject=Create-BGPSummaryObject
#        $BGPSummaryObject.BGP_ID = $BGPSummaryEntry[0]
#        $BGPSummaryObject.LOCAL_AS = $BGPSummaryEntry[1]
#        $BGPSummaryObject.NEIGHBOR = $BGPSummaryEntry[2]
#        $BGPSummaryObject.VRF = $BGPSummaryEntry[3]
#        $BGPSummaryObject.REMOTE_AS = $BGPSummaryEntry[4]
#        $BGPSummaryObject.UP_DOWN = $BGPSummaryEntry[8]
#        $BGPSummaryObject.STATE_PFX = $BGPSummaryEntry[9]
#        $AllBGPSummaryObjects += $BGPSummaryObject
#    }
#    
#    $device.BGPSummary = $AllBGPSummaryObjects
#    return $device
#}
#
#function Get-BGPNeighborsFromText {
#    param (
#        [parameter(Mandatory=$true)]
#        $BGPNeighborsFile,
#        $Device
#    )
#    $BGPNeighborsText = Get-Content -raw $BGPNeighborsFile
#    $AllBGPNeighborObjects=@()
#
#    if(($BGPNeighborsText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing)").Matches.Success){
#        write-HostDebugText "BGP Neighbors file contains invalid data or is empty: $BGPNeighborsFile" -BackgroundColor Red
#        return $device
#    }
#
#    $Template = $null
#    if ($Device.version.type -eq "NXOS") {
#        $Template = $GTemplate.NexusShowIPBGPNeighborsTemplate
#    } else { # Covers IOS and XE-IOS as they use the same template
#        $Template = $GTemplate.IOSShowIPBGPNeighborsTemplate
#    }
#
#    $ProcessOutputObjects = Execute-PythonTextFSM -TextFSTETemplate $Template -ShowFile $BGPNeighborsFile -ReturnArray $true
#    if($ProcessOutputObjects -eq "ERROR"){
#        write-HostDebugText "Error with TextFSM processing for BGP Neighbors on file: $BGPNeighborsFile" -BackgroundColor Red
#        return $device
#    }
#
#    foreach ($BGPNeighborEntry in $ProcessOutputObjects){
#        $BGPNeighborObject = Create-BGPNeighborObject
#        if ($Device.version.type -eq "NXOS") {
#            $BGPNeighborObject.VRF = $BGPNeighborEntry[0]
#            $BGPNeighborObject.NEIGHBOR = $BGPNeighborEntry[1]
#            $BGPNeighborObject.REMOTE_AS = $BGPNeighborEntry[2]
#            $BGPNeighborObject.BGP_STATE = $BGPNeighborEntry[3]
#            $BGPNeighborObject.REMOTE_ROUTER_ID = $BGPNeighborEntry[4]
#            $BGPNeighborObject.INBOUND_ROUTEMAP = $BGPNeighborEntry[5]
#            $BGPNeighborObject.OUTBOUND_ROUTEMAP = $BGPNeighborEntry[6]
#            $BGPNeighborObject.PEER_GROUP = $BGPNeighborEntry[7]
#            $BGPNeighborObject.SOURCE_IFACE = $BGPNeighborEntry[8]
#            $BGPNeighborObject.LOCALHOST_IP = $BGPNeighborEntry[9]
#            $BGPNeighborObject.LOCALHOST_PORT = $BGPNeighborEntry[10]
#            $BGPNeighborObject.REMOTE_IP = $BGPNeighborEntry[11]
#            $BGPNeighborObject.REMOTE_PORT = $BGPNeighborEntry[12]
#        } else { # IOS and XE-IOS
#            $BGPNeighborObject.NEIGHBOR = $BGPNeighborEntry[0]
#            $BGPNeighborObject.REMOTE_AS = $BGPNeighborEntry[1]
#            $BGPNeighborObject.BGP_STATE = $BGPNeighborEntry[2]
#            $BGPNeighborObject.REMOTE_ROUTER_ID = $BGPNeighborEntry[3]
#            $BGPNeighborObject.LOCALHOST_IP = $BGPNeighborEntry[4]
#            $BGPNeighborObject.LOCALHOST_PORT = $BGPNeighborEntry[5]
#            $BGPNeighborObject.REMOTE_IP = $BGPNeighborEntry[6]
#            $BGPNeighborObject.REMOTE_PORT = $BGPNeighborEntry[7]
#        }
#        $AllBGPNeighborObjects += $BGPNeighborObject
#    }
#
#    $device.BGPNeighbors = $AllBGPNeighborObjects
#    return $device
#}