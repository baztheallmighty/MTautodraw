#https://codeandkeep.com/PowerShell-Get-Subnet-NetworkID/
#https://github.com/briansworth/GetIPv4Address
Function Convert-IPv4AddressToBinaryString {
  Param(
    [IPAddress]$IPAddress='0.0.0.0'
  )
  $addressBytes=$IPAddress.GetAddressBytes()

  $strBuilder=New-Object -TypeName Text.StringBuilder
  foreach($byte in $addressBytes){
    $8bitString=[Convert]::ToString($byte,2).PadRight(8,'0')
    [void]$strBuilder.Append($8bitString)
  }
  Write-Output $strBuilder.ToString()
}

Function ConvertIPv4ToInt {
  [CmdletBinding()]
  Param(
    [String]$IPv4Address
  )
  Try{
    $ipAddress=[IPAddress]::Parse($IPv4Address)

    $bytes=$ipAddress.GetAddressBytes()
    [Array]::Reverse($bytes)

    [System.BitConverter]::ToUInt32($bytes,0)
  }Catch{
    Write-Error -Exception $_.Exception  -Category $_.CategoryInfo.Category
  }
}

Function ConvertIntToIPv4 {
  [CmdletBinding()]
  Param(
    [uint32]$Integer
  )
  Try{
    $bytes=[System.BitConverter]::GetBytes($Integer)
    [Array]::Reverse($bytes)
    ([IPAddress]($bytes)).ToString()
  }Catch{
    Write-Error -Exception $_.Exception  -Category $_.CategoryInfo.Category
  }
}

<#
.SYNOPSIS
Add an integer to an IP Address and get the new IP Address.

.DESCRIPTION
Add an integer to an IP Address and get the new IP Address.

.PARAMETER IPv4Address
The IP Address to add an integer to.

.PARAMETER Integer
An integer to add to the IP Address. Can be a positive or negative number.

.EXAMPLE
Add-IntToIPv4Address -IPv4Address 10.10.0.252 -Integer 10

10.10.1.6

Description
-----------
This command will add 10 to the IP Address 10.10.0.1 and return the new IP Address.

.EXAMPLE
Add-IntToIPv4Address -IPv4Address 192.168.1.28 -Integer -100

192.168.0.184

Description
-----------
This command will subtract 100 from the IP Address 192.168.1.28 and return the new IP Address.
#>
Function Add-IntToIPv4Address {
  Param(
    [String]$IPv4Address,

    [int64]$Integer
  )
  Try{
    $ipInt=ConvertIPv4ToInt -IPv4Address $IPv4Address  -ErrorAction Stop
    $ipInt+=$Integer

    ConvertIntToIPv4 -Integer $ipInt
  }Catch{
    Write-Error -Exception $_.Exception  -Category $_.CategoryInfo.Category
  }
}

Function CIDRToNetMask {
  [CmdletBinding()]
  Param(
    [ValidateRange(0,32)]
    [int16]$PrefixLength=0
  )
  $bitString=('1' * $PrefixLength).PadRight(32,'0')

  $strBuilder=New-Object -TypeName Text.StringBuilder

  for($i=0;$i -lt 32;$i+=8){
    $8bitString=$bitString.Substring($i,8)
    [void]$strBuilder.Append("$([Convert]::ToInt32($8bitString,2)).")
  }

  $strBuilder.ToString().TrimEnd('.')
}

Function Covert-NetMaskToCIDR {
  [CmdletBinding()]
  Param(
    [String]$SubnetMask='255.255.255.0'
  )
  $byteRegex='^(0|128|192|224|240|248|252|254|255)$'
  $invalidMaskMsg="Invalid SubnetMask specified [$SubnetMask]"
  Try{
    $netMaskIP=[IPAddress]$SubnetMask
    $addressBytes=$netMaskIP.GetAddressBytes()

    $strBuilder=New-Object -TypeName Text.StringBuilder

    $lastByte=255
    foreach($byte in $addressBytes){

      # Validate byte matches net mask value
      if($byte -notmatch $byteRegex){
        Write-Error -Message $invalidMaskMsg        -Category InvalidArgument          -ErrorAction Stop
      }elseif($lastByte -ne 255 -and $byte -gt 0){
        Write-Error -Message $invalidMaskMsg  -Category InvalidArgument  -ErrorAction Stop
      }

      [void]$strBuilder.Append([Convert]::ToString($byte,2))
      $lastByte=$byte
    }

    ($strBuilder.ToString().TrimEnd('0')).Length
  }Catch{
    Write-Error -Exception $_.Exception  -Category $_.CategoryInfo.Category
  }
}

<#
.SYNOPSIS
Get information about an IPv4 subnet based on an IP Address and a subnet mask or prefix length

.DESCRIPTION
Get information about an IPv4 subnet based on an IP Address and a subnet mask or prefix length

.PARAMETER IPAddress
The IP Address to use for determining subnet information. 

.PARAMETER PrefixLength
The prefix length of the subnet.

.PARAMETER SubnetMask
The subnet mask of the subnet.

.EXAMPLE
Get-IPv4Subnet -IPAddress 192.168.34.76 -SubnetMask 255.255.128.0

CidrID       : 192.168.0.0/17
NetworkID    : 192.168.0.0
SubnetMask   : 255.255.128.0
PrefixLength : 17
HostCount    : 32766
FirstHostIP  : 192.168.0.1
LastHostIP   : 192.168.127.254
Broadcast    : 192.168.127.255

Description
-----------
This command will get the subnet information about the IPAddress 192.168.34.76, with the subnet mask of 255.255.128.0

.EXAMPLE
Get-IPv4Subnet -IPAddress 10.3.40.54 -PrefixLength 25

CidrID       : 10.3.40.0/25
NetworkID    : 10.3.40.0
SubnetMask   : 255.255.255.128
PrefixLength : 25
HostCount    : 126
FirstHostIP  : 10.3.40.1
LastHostIP   : 10.3.40.126
Broadcast    : 10.3.40.127

Description
-----------
This command will get the subnet information about the IPAddress 10.3.40.54, with the subnet prefix length of 25.

#>
Function Get-IPv4Subnet {
  [CmdletBinding(DefaultParameterSetName='PrefixLength')]
  Param(
    [Parameter(Mandatory=$true,Position=0)]
    [IPAddress]$IPAddress,

    [Parameter(Position=1,ParameterSetName='PrefixLength')]
    [Int16]$PrefixLength=24,

    [Parameter(Position=1,ParameterSetName='SubnetMask')]
    [IPAddress]$SubnetMask
  )
  Begin{}
  Process{
    Try{
      if($PSCmdlet.ParameterSetName -eq 'SubnetMask'){
        $PrefixLength=Covert-NetMaskToCIDR -SubnetMask $SubnetMask   -ErrorAction Stop
      }else{
        $SubnetMask=CIDRToNetMask -PrefixLength $PrefixLength   -ErrorAction Stop
      }
      
      $netMaskInt=ConvertIPv4ToInt -IPv4Address $SubnetMask     
      $ipInt=ConvertIPv4ToInt -IPv4Address $IPAddress
      
      $networkID=ConvertIntToIPv4 -Integer ($netMaskInt -band $ipInt)

      $maxHosts=[math]::Pow(2,(32-$PrefixLength)) - 2
      $broadcast=Add-IntToIPv4Address -IPv4Address $networkID  -Integer ($maxHosts+1)

      $firstIP=Add-IntToIPv4Address -IPv4Address $networkID -Integer 1
      $lastIP=Add-IntToIPv4Address -IPv4Address $broadcast -Integer -1

      if($PrefixLength -eq 32){
        $broadcast=$networkID
        $firstIP=$null
        $lastIP=$null
        $maxHosts=0
      }

      $outputObject=New-Object -TypeName PSObject 

      $memberParam=@{
        InputObject=$outputObject;
        MemberType='NoteProperty';
        Force=$true;
      }
      Add-Member @memberParam -Name CidrID -Value "$networkID/$PrefixLength"
      Add-Member @memberParam -Name NetworkID -Value $networkID
      Add-Member @memberParam -Name SubnetMask -Value $SubnetMask
      Add-Member @memberParam -Name PrefixLength -Value $PrefixLength
      Add-Member @memberParam -Name HostCount -Value $maxHosts
      Add-Member @memberParam -Name FirstHostIP -Value $firstIP
      Add-Member @memberParam -Name LastHostIP -Value $lastIP
      Add-Member @memberParam -Name Broadcast -Value $broadcast

      Write-Output $outputObject
    }Catch{
      Write-Error -Exception $_.Exception  -Category $_.CategoryInfo.Category
    }
  }
  End{}
}


<#
.SYNOPSIS
http://www.gi-architects.co.uk/2016/02/powershell-check-if-ip-or-subnet-matchesfits/ 
The Function will check ip to ip, ip to subnet, subnet to ip or subnet to subnet belong to each other and return true or false and the direction of the check


.DESCRIPTION
Is this IP or subnet in another ip or subnet?

.PARAMETER $addr1
The IP Address to use for determining subnet information.

.PARAMETER $addr1
The IP Address to use for determining subnet information.

.EXAMPLE
    Find-Subnet ‘10.185.255.128/26’ ‘10.165.255.166/32’
    Find-Subnet ‘10.125.255.128’ ‘10.125.255.166′
    Find-Subnet ‘10.140.20.0/21’ ‘10.140.20.0/27’


#>
Function Find-Subnet {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        #[ValidateScript({-not ([string]::IsNullOrEmpty($_))})]
        [string]$addr1,
        [Parameter(Mandatory=$true)]
        #[ValidateScript({-not ([string]::IsNullOrEmpty($_))})]
        [string]$addr2
    )
    if($null -eq $addr1 -or $null -eq $addr2 ){
        write-host "Null strings 1: $($addr1) 2:$($addr1)"
        break
    }
    if("" -eq $addr1 -or "" -eq $addr2 ){
        write-host "Null strings 1: $($addr1) 2:$($addr1)"
        break
    }     
    # Separate the network address and lenght
    $network1, [int]$subnetlen1 = $addr1.Split('/')
    $network2, [int]$subnetlen2 = $addr2.Split('/')

 
    #Convert network address to binary
    [uint32] $unetwork1 = NetworkToBinary $network1
 
    [uint32] $unetwork2 = NetworkToBinary $network2
 
 
    #Check if subnet length exists and is less then 32(/32 is host, single ip so no calculation needed) if so convert to binary
    if($subnetlen1 -lt 32){
        [uint32] $mask1 = SubToBinary $subnetlen1
    }
 
    if($subnetlen2 -lt 32){
        [uint32] $mask2 = SubToBinary $subnetlen2
    }
 
    #Compare the results
    if($mask1 -and $mask2){
        # If both inputs are subnets check which is smaller and check if it belongs in the larger one
        if($mask1 -lt $mask2){
            return CheckSubnetToNetwork $unetwork1 $mask1 $unetwork2
        }else{
            return CheckNetworkToSubnet $unetwork2 $mask2 $unetwork1
        }
    }ElseIf($mask1){
        # If second input is address and first input is subnet check if it belongs
        return CheckSubnetToNetwork $unetwork1 $mask1 $unetwork2
    }ElseIf($mask2){
        # If first input is address and second input is subnet check if it belongs
        return CheckNetworkToSubnet $unetwork2 $mask2 $unetwork1
    }Else{
        # If both inputs are ip check if they match
        CheckNetworkToNetwork $unetwork1 $unetwork2
    }
}

Function CheckNetworkToSubnet {
    [CmdletBinding()]
    Param(
        [uint32]$un2,
        [uint32]$ma2,
        [uint32]$un1
    )    
    $ReturnArray = "" | Select-Object -Property Condition,Direction

    if($un2 -eq ($ma2 -band $un1)){
        $ReturnArray.Condition = $True
        $ReturnArray.Direction = "Addr1ToAddr2"
        return $ReturnArray
    }else{
        $ReturnArray.Condition = $False
        $ReturnArray.Direction = "Addr1ToAddr2"
        return $ReturnArray
    }
}

Function CheckSubnetToNetwork {
    [CmdletBinding()]
    Param(
        [uint32]$un1,
        [uint32]$ma1,
        [uint32]$un2
    )     
    $ReturnArray = "" | Select-Object -Property Condition,Direction

    if($un1 -eq ($ma1 -band $un2)){
        $ReturnArray.Condition = $True
        $ReturnArray.Direction = "Addr2ToAddr1"
        return $ReturnArray
    }else{
        $ReturnArray.Condition = $False
        $ReturnArray.Direction = "Addr2ToAddr1"
        return $ReturnArray
    }
}

Function CheckNetworkToNetwork {
    [CmdletBinding()]
    Param(
        [uint32]$un1,
        [uint32]$un2
    )     
    $ReturnArray = "" | Select-Object -Property Condition,Direction

    if($un1 -eq $un2){
        $ReturnArray.Condition = $True
        $ReturnArray.Direction = "Addr1ToAddr2"
        return $ReturnArray
    }else{
        $ReturnArray.Condition = $False
        $ReturnArray.Direction = "Addr1ToAddr2"
        return $ReturnArray
    }
}

Function SubToBinary {
    [CmdletBinding()]
    Param(
        [int]$sub
    ) 
    return ((-bnot [uint32]0) -shl (32 - $sub))
}

Function NetworkToBinary {
    [CmdletBinding()]
    Param(
        $network
    )     
    $a = [uint32[]]$network.split('.')
    return ($a[0] -shl 24) + ($a[1] -shl 16) + ($a[2] -shl 8) + $a[3]
}
#////////////////////////////////////////////////////////////////////////

Export-ModuleMember -Function Find-Subnet,Covert-NetMaskToCIDR, Get-IPv4Subnet, Convert-IPv4AddressToBinaryString, Add-IntToIPv4Address
