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
	write-host "Press CTRL - C to exit. "
	read-host
    Stop-Transcript
}

#
# This function iterates through a device's routes. If a route is local, connected, or direct
# and is missing an interface, it attempts to find the correct egress interface by matching
# the route's destination network with the configured interface subnets.
#
function Update-LocalRoutesWithInterfaces {
    param (
        [parameter(Mandatory=$true)]
        [PSObject]$device
    )

    # Ensure we have the necessary data to proceed.
    if (-not $device.RoutingTable -or -not $device.interfaces) {
        Add-HostDebugText -HostObject $device "Skipping local route update; routing table or interfaces not found." -BackgroundColor Yellow
        return $device
    }

    # Filter for interfaces that have a network address (CIDR) for efficient searching.
    $routableInterfaces = $device.interfaces | Where-Object { -not [string]::IsNullOrEmpty($_.Cidr) }

    if ($routableInterfaces.Count -eq 0) {
        Add-HostDebugText -HostObject $device "Skipping local route update; no routable interfaces with CIDR found." -BackgroundColor Yellow
        return $device
    }

    # Iterate directly through each route that needs an interface assigned.
    # Changes to $route will modify the object within $device.RoutingTable.
    foreach ($route in $device.RoutingTable | Where-Object {
        ('connect','host','local', 'connected', 'direct' -contains $_.RouteProtocol) -and [string]::IsNullOrEmpty($_.interface)
    }) {
        # The destination subnet of the route we need to match.
        $destinationSubnet = $route.Subnet

        # Find the first interface whose network contains the route's destination.
        foreach ($interface in $routableInterfaces) {
            # Use the existing Find-Subnet utility to check if the destination is within the interface's network.
            if ((Find-Subnet -addr1 $interface.Cidr -addr2 $destinationSubnet).condition) {
                $route.interface = $interface.Interface
                # Once found, we can stop searching for this route.
                break
            }
        }
    }

    # Return the device object, now with updated routes.
    return $device
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
    if (-not $String) { return $null }
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

function Remove-DevicePrompt {
    param(
        [string]$Text
    )

    $Clean = $Text -split "`n" |
        Where-Object { $_ -notmatch '^[A-Za-z0-9._-]+[#>]\s*$' } |
        Out-String

    return $Clean
}

function Execute-PythonTextFSM() {
    param (
        $TextFSTETemplate,
        $ShowFile,
        $ReturnArray,
        $HostObject
    )

    $HostObject.ProcessOutputObjects = @()

    # Python doesn't like UTF-8, UTF16 or UTF16LE. Convert it to ASCII file.
    if ((Get-Encoding $ShowFile).encoding.EncodingName -ne "US-ASCII") {
        Add-HostDebugText -HostObject $HostObject "Converting $ShowFile to Ascii"
        $TempFileAscii = Get-Content $ShowFile | Where-Object { $_ -cmatch '[\x20-\x7F]' }
        Set-Content -Value $TempFileAscii -Encoding Ascii -Path $ShowFile
    }

    # Run TextFSM the first time
    $ProcessOutput = & $GPathToPythonExe $GPathToPythonTextFSMScript $TextFSTETemplate $ShowFile

    $ErrorDetected = (
        $ProcessOutput -like "Traceback*" -or
        $ProcessOutput -like "An exception occurred*" -or
        $ProcessOutput -eq "`[`]" -or
        [string]::IsNullOrEmpty($ProcessOutput)
    )

    if ($ErrorDetected) {

        Add-HostDebugText -HostObject $HostObject "Primary TextFSM run failed. Attempting cleanup and retry."

        # Create a temporary cleaned file
        $TempCleanedFile = [System.IO.Path]::GetTempFileName()

        # Clean the prompt out using your function
        $CleanedText = Remove-DevicePrompt -Text (Get-Content $ShowFile -Raw)

        # Write cleaned text to the temp file
        Set-Content -Path $TempCleanedFile -Value $CleanedText -Encoding Ascii

        # Try running TextFSM again on cleaned file
        $RetryOutput = & $GPathToPythonExe $GPathToPythonTextFSMScript $TextFSTETemplate $TempCleanedFile

        # Remove temp file no matter what
        Remove-Item -Path $TempCleanedFile -Force -ErrorAction Ignore

        $RetryError = (
            $RetryOutput -like "Traceback*" -or
            $RetryOutput -like "An exception occurred*" -or
            $RetryOutput -eq "`[`]" -or
            [string]::IsNullOrEmpty($RetryOutput)
        )

        if ($RetryError) {
            Add-HostDebugText -HostObject $HostObject "Retry also failed: $RetryOutput"
            $HostObject.ProcessOutputObjects = "ERROR"
            return $HostObject
        }

        # Retry succeeded
        $Objects = $RetryOutput | ConvertFrom-Json -Depth 10
        $HostObject.ProcessOutputObjects = $Objects
        return $HostObject
    }

    # First run succeeded
    $Objects = $ProcessOutput | ConvertFrom-Json -Depth 10
    $HostObject.ProcessOutputObjects = $Objects
    return $HostObject
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
    if (-not $GruntimePortChannelStyles.ContainsKey($channelNumber)) {

        # If not, generate a new random style object.
        $r = Get-Random -Minimum 30 -Maximum 200 # Avoid very bright/dark colors
        $g = Get-Random -Minimum 30 -Maximum 200
        $b = Get-Random -Minimum 30 -Maximum 200
        $hexColor = Convert-RgbToHex -RgbString "rgb($r,$g,$b)"

        # Store the style object (color and width) in the global cache.
        $GruntimePortChannelStyles[$channelNumber] = @{
            strokeColor = $hexColor
            strokeWidth = "5" # Use a consistent thick stroke for all Port-Channels
        }
    }

    # Return the style object from the cache.
    return $GruntimePortChannelStyles[$channelNumber]
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

# Checks if a file exists, is not empty, and does not contain common CLI errors.
function Test-FileHasValidData {
    param(
        [parameter(Mandatory=$true)]
        [string]$FilePath
    )

    # Check if file exists and has content
    if (-not (Test-Path -Path $FilePath) -or (Get-Item $FilePath).Length -lt 10) {
        return $false
    }

    # Check for common error strings
    $Content = Get-Content -raw $FilePath
    if (($Content | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Ambiguous command:|% Unrecognized command)").Matches.Success) {
        return $false
    }

    # If all checks pass, the file is considered valid
    return $true
}