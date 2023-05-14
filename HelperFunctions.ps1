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


#This contains helper functions used by the script.

#This function is used to exit the script cleanly.
function Start-CleanupAndExit {
    Close-VisioDocument
    Close-VisioApplication
    Stop-Transcript
    if($PSScriptRoot){exit}
}


#This Checks if the interface is a known valid interface type
#It returns true if so
#and false if not
function Check-InterfaceType{
    param
    (
        $String
    )
    switch ($String){
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

#This function takes a string input and replace the short name with the long name version of the interface
function Replace-InterfaceShortName{
    param
    (
        $String
    )
    $String=$String -replace "vl(\d+.*)",'Vlan$1'`
                    -replace "Se(\d+.*)",'Serial$1'`
                    -replace "Eth(\d+.*)",'Ethernet$1'`
                    -replace "Po(\d+)",'Port-channel$1'`
                    -replace "Gi(\d+.*)",'GigabitEthernet$1'`
                    -replace 'Twe(\d+.*)','TwentyFiveGigE$1'`
                    -replace "Te(\d+.*)",'TenGigabitEthernet$1'`
                    -replace "fa(\d+.*)",'FastEthernet$1'`
                    -replace "Fo(\d+.*)",'FortyGigabitEthernet$1'`
                    -replace "Ap(\d+.*)",'AppGigabitEthernet$1'`
                    -replace "Lo(\d+.*)",'Loopback$1'
    return $string.trim()
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
    return $string.trim()
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

#This is used to run the python TextFSM library. It takes a paths to the various files and returns a json copy of the config or an error.
function Execute-PythonTextFSM(){
    param (
        [parameter(Mandatory=$true)]
        $TextFSTETemplate,
        $ShowFile,
        $ReturnArray = $false
    )
        #Python doesn't like UTF-8, UTF16 or UTF16LE. Convert it to ASCII file.
        if( (Get-Encoding $ShowFile).encoding.EncodingName -ne "US-ASCII"){
            write-HostDebugText "Converting $($ShowFile) to Ascii"
            $TempFile=get-content $ShowFile | Where-Object {$_ -cmatch '[\x20-\x7F]'} #Trim out non-ascii Char's
            set-content $TempFile -Encoding Ascii -path $ShowFile #rewrite the file as Ascii.
        }
        $ProcessOutput=& $GPathToPythonExe  $GPathToPythonTextFSMScript  $TextFSTETemplate $ShowFile
        if(($ProcessOutput -like "Traceback") -or ($ProcessOutput -like "An exception occurred*") -or ($ProcessOutput -eq "`[`]") -or ($ProcessOutput -eq "")){
            write-HostDebugText "Error with TextFSM Processing $($ProcessOutput)."
            return "ERROR"
        }

        $Objects=$ProcessOutput | convertfrom-json

        if($ReturnArray){#This is used to ensure we return a listarray. If we don't then it returns an array of strings.
            if(!($Objects[0][0].GetType().name -eq "char")){

                $myarray = [System.Collections.ArrayList]::new()
                [void]$myArray.Add($Objects)
                return $myArray
            }
        }else{

            return $Objects
        }
}


#copies one array to another because powershell is retarted.
Function Copy-Array(){
[CmdletBinding()]
param (
    $LOldArray
)
    # Serialize and Deserialize data using BinaryFormatter
    $Lms = New-Object System.IO.MemoryStream
    $Lbf = New-Object System.Runtime.Serialization.Formatters.Binary.BinaryFormatter
    $Lbf.Serialize($Lms, $LOldArray)
    $Lms.Position = 0
    #Deep copied data
    $LNewArray = $Lbf.Deserialize($Lms)
    $Lms.Close()
    return $LNewArray
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
