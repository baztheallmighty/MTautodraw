# MTAutoDraw-Standard: v1
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

# This file contains all of the functions that process Cisco config.
#
# Cisco is the only platform with two complete template sets. Nearly every reader below branches on
# $Device.Version.Type - IOS/XE-IOS against NXOS - and picks a cisco_ios_* or cisco_nxos_* template.
# That branch is deliberate: the two operating systems format the same command differently, and
# collapsing the two halves would break one of them. Update-CiscoVersion therefore has to run first,
# because every later branch reads the type it sets.

# --- Orchestrator ---------------------------------------------------------------------------------

# Turns one host's captures into a device object. Input: a HostID with the capture paths. Output: the
# device, or $null when the running config yields no usable hostname.
function Process-CiscoHostFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$HostID,
        $ArrayOfObjects   # Kept for dispatcher signature compatibility; duplicate detection is sequential.
    )

    # 1. IDENTITY - the running configuration is the only capture with a hostname, and it also creates
    # the interfaces, VLANs and networks every reader below merges onto.
    $device = New-MTAutoDrawDevice -Platform 'Cisco' -HostID $HostID
    Update-CiscoRunningConfig -Device $device -Path $HostID.ShowRun
    if ([string]::IsNullOrEmpty($device.hostname) -or $device.hostname -like '*NoHostNameFound*') {
        Write-MTAutoDrawDiagnostic -Device $device -Severity Warning -Message "Cisco '$($HostID.HOSTID)' has no usable hostname; skipping host."
        return $null
    }
    Write-MTAutoDrawLog -Level Info -Phase Parse -Device $device -Message "Processing Cisco Host: $($device.hostname)"

    # 2. CAPTURES - one line per slot, in dependency order.
    #  - the version reader chooses the template set for everything after it;
    #  - CDP is processed before LLDP, so an LLDP neighbour can be marked as already drawn by CDP;
    #  - the interface captures are mutually exclusive, which is what Select-CiscoInterfaceCapture
    #    decides: the brief table and the status table would otherwise overwrite the richer
    #    'show interface' data with their own coarser status strings.
    Update-CiscoVersion      -Device $device -Path $HostID.ShowVersion
    Update-CiscoCdpNeighbors -Device $device -Path $HostID.ShowCDPNeighborsDetails
    Resolve-CiscoLldpNeighbors -Device $device -HostID $HostID

    $interfaceCapture = Select-CiscoInterfaceCapture -Device $device -HostID $HostID
    Update-CiscoInterfaces      -Device $device -Path $interfaceCapture.Detail
    Update-CiscoInterfaceBrief  -Device $device -Path $interfaceCapture.Brief
    Update-CiscoInterfaceStatus -Device $device -Path $interfaceCapture.Status

    Update-CiscoSpanningTree -Device $device -Path $HostID.ShowSpanningTree
    Update-CiscoRoutes       -Device $device -Path (Select-CiscoRouteCapture -Device $device -HostID $HostID)
    if ($GDrawAprEntries) { Update-CiscoArp -Device $device -Path $HostID.ShowIPArp }
    # GDrawCDP is the "draw layer 2 links" toggle, which is what the MAC table feeds; parsing it is
    # slow, so it is skipped outright when those links will not be drawn.
    if ($GDrawPortsWithMacs -ne 0 -and $GDrawCDP) { Update-CiscoMacAddressTable -Device $device -Path $HostID.ShowMacAddressTable }

    # 3. RECONCILE
    return (Complete-MTAutoDrawDevice -Device $device)
}

# Decides which of the three interface captures each interface reader gets, and returns the other two
# as $null so those readers return immediately. Not an Update-* reader: it consumes no capture
# content, only decides which path goes where.
#
# 'show interface' is the richest of the three and is preferred. 'show ip interface brief' is its
# fallback and is read only when 'show interface' is absent or unusable. 'show interface status' is
# read on NX-OS regardless - it is the only capture there that reports the media type and the
# transceiver-absent state - and on IOS only when 'show interface' was not usable.
function Select-CiscoInterfaceCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [Parameter(Mandatory = $true)]$HostID
    )

    $hasDetail = Test-MTAutoDrawCaptureReadable -Device $Device -Path $HostID.ShowInterface -Capture 'ShowInterface'
    return [pscustomobject]@{
        Detail = if ($hasDetail) { $HostID.ShowInterface } else { $null }
        Brief  = if ($hasDetail) { $null } else { $HostID.ShowIPInterfaceBrief }
        Status = if ($Device.Version.Type -eq 'NXOS' -or -not $hasDetail) { $HostID.ShowInterfaceStatus } else { $null }
    }
}

# LLDP is one subject spread over two captures. 'show lldp neighbors detail' is authoritative, but on
# some IOS trains it omits the "Local Intf" line, and the local interface is the one field the
# drawing layer cannot do without. Only in that case is the summary table read first, to supply the
# skeleton the detail reader then enriches in place.
#
# Reading the summary unconditionally would not be equivalent: it sets HasLLDPNeighbor on every port
# it names, including ports the detail capture never mentions.
function Resolve-CiscoLldpNeighbors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [Parameter(Mandatory = $true)]$HostID
    )

    if (Test-MTAutoDrawCaptureReadable -Device $Device -Path $HostID.ShowLLDPNeighborsDetails -Capture 'ShowLLDPNeighborsDetails') {
        $detailText = Get-MTAutoDrawCaptureText -Path $HostID.ShowLLDPNeighborsDetails
        if ($detailText -notmatch 'Local Intf') {
            Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message 'No local interface in show lldp neighbors detail; reading the summary table first.'
            Update-CiscoLldpNeighbors -Device $Device -Path $HostID.ShowLLDPNeighbors
        }
    }
    Update-CiscoLldpNeighborDetails -Device $Device -Path $HostID.ShowLLDPNeighborsDetails
}

# Picks the one route capture Update-CiscoRoutes will parse. Three slots can hold a routing table and
# they overlap; the VRF-aware ones are preferred because they carry the VRF column, and a capture
# whose body says the VRF has no table is not a routing table at all. Not an Update-* reader: it
# selects a path rather than merging anything onto the device.
function Select-CiscoRouteCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [Parameter(Mandatory = $true)]$HostID
    )

    $candidates = @(
        [pscustomobject]@{ Path = $HostID.ShowIPRouteVRFstar; Capture = 'ShowIPRouteVRFstar' }
        [pscustomobject]@{ Path = $HostID.ShowIPRouteVRFAll;  Capture = 'ShowIPRouteVRFAll' }
        [pscustomobject]@{ Path = $HostID.ShowIPRoute;        Capture = 'ShowIPRoute' }
    )

    foreach ($candidate in $candidates) {
        if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $candidate.Path -Capture $candidate.Capture)) { continue }
        $text = Get-MTAutoDrawCaptureText -Path $candidate.Path
        if ($text -match '(?im)^\s*(?:No IP Route Table for VRF|%\s*IP routing table vrf .+ does not exist)') {
            Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "Skipping $($candidate.Capture) capture, which reports no routing table: $($candidate.Path)"
            continue
        }
        return $candidate.Path
    }
    return $null
}

# --- Identity -------------------------------------------------------------------------------------

# Parses a Cisco 'show running-config' capture into the device's identity, spanning-tree mode, VLAN
# list, interface list and the networks derived from the interface addresses.
function Update-CiscoRunningConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowRun')) { return }

    # --- EXTRACT ---
    $Lconfig = Get-MTAutoDrawCaptureText -Path $Path

    # --- MAP + MERGE ---
    # 'config' rather than the shared default: the drawing layer distinguishes a device recovered from
    # a running configuration from one recovered only from show output.
    $Device.Origin = 'config'

    $hostname = (($Lconfig | Select-String -Pattern "(hostname ).+").Matches.Value -replace "hostname ", '').trim()
    if ([string]::IsNullOrEmpty($hostname)) {
        # NX-OS spells it 'switchname'.
        $hostname = (($Lconfig | Select-String -Pattern "(switchname ).+").Matches.Value -replace "switchname ", '').trim()
    }
    if ([string]::IsNullOrEmpty($hostname)) {
        $hostname = "NoHostNameFoundCheckForConfigProblems"
    }
    $Device.hostname = $hostname

    $Device.SpanningTree = Create-SpanningTreeObject
    $Device.SpanningTree.SpanningTreeMode = (($Lconfig | Select-String -Pattern "(spanning-tree mode ).+").Matches.Value -replace "spanning-tree mode ", '').trim()
    $Device.SpanningTree.SpanningTreeExtended = (($Lconfig | Select-String -Pattern "(spanning-tree extend ).+").Matches.Value -replace "spanning-tree extend ", '').trim()

    $AllInterfaces = ($Lconfig -replace '(?smi)^\s+interface', 'interface' | Select-String -Pattern "(?smi)^\s*interface.+?((?=^[^\s])|^\s*interface)" -AllMatches).Matches.Value
    $Allvlans = ($Lconfig | Select-String -Pattern "(?smi)^vlan.+?((?=^[^\s]))" -AllMatches).Matches.Value

    $ArrayOfHostNetworks = @()
    $interfaces, $ArrayOfHostNetworks, $Device.ArrayOfIPAddresses = Get-CiscoInterfacesFromConfigText -AllInterfaces $AllInterfaces -ArrayOfHostNetworks $ArrayOfHostNetworks

    $vlans = @()
    foreach ($vlan in $Allvlans) {
        if ( $vlan -like "*internal allocation policy ascending*" `
                -or $vlan -like "vlan access-log ratelimit*" `
                -or $vlan -like "vlan access-map*" `
                -or $vlan -like "vlan configuration*" ) {
            continue
        }
        $vlanExpression = (($vlan -split "(?smi)$")[0] -replace "vlan ", '').trim()
        $vlanName = if ((($vlan -split "(?smi)$")[1]) -like "*name*") { ((($vlan -split "(?smi)$")[1]) -replace "name ", '' ).trim() } else { 'No name' }
        foreach ($vlanNumber in @(Expand-CiscoVlanExpression -Expression $vlanExpression)) {
            $vlanObject = Create-vlanObject
            $vlanObject.number = [string]$vlanNumber
            $vlanObject.name = $vlanName
            $vlans += $vlanObject
        }
    }
    $Device.vlans = $vlans

    $BGPSection = ($Lconfig | Select-String -Pattern '(?smi)^router bgp.*?(?=^!|^\S)' -AllMatches).Matches.Value
    if ($BGPSection) {
        $Device.BGP_AS_Number = (($BGPSection | Select-String 'router bgp \d+').Matches.Value -replace 'router bgp\s+', '' -replace '\s.*', '').Trim()
    }

    $Device.interfaces = $interfaces
    $ArrayOfHostNetworks | ForEach-Object { $_.color = Get-DeterministicRgbColor -Seed "network|$($_.cidr)" }
    $Device.ArrayOfNetworks = $ArrayOfHostNetworks
}

# Expands a VLAN expression such as "10,20,30-32" into the individual VLAN ids it names.
function Expand-CiscoVlanExpression {
    param([AllowNull()][string]$Expression)
    $result=[System.Collections.Generic.List[int]]::new()
    foreach($token in @($Expression -split ',')){
        $token=$token.Trim()
        if($token -match '^(\d+)-(\d+)$'){
            $start=[int]$Matches[1];$end=[int]$Matches[2]
            if($start -le $end -and $start -ge 1 -and $end -le 4094){foreach($number in $start..$end){$result.Add($number)}}
        }elseif($token -match '^\d+$'){
            $number=[int]$token;if($number -ge 1 -and $number -le 4094){$result.Add($number)}
        }
    }
    return @($result|Sort-Object -Unique)
}

# Extracts every interface stanza of a running config into interface objects, together with the
# networks and IP addresses those stanzas imply. Shared by IOS, IOS-XE and NX-OS: the three spell VRF
# membership, HSRP and port-channel membership differently, and each spelling is tried in turn.
function Get-CiscoInterfacesFromConfigText(){
    param (
		[parameter(Mandatory=$true)]
		$AllInterfaces,
        $ArrayOfHostNetworks
    )
    [array]$ArrayOfIPAddresses=@()
    [array]$interfaces = @()
    Foreach($interface in $AllInterfaces) {
        $interfaceObject = Create-InterfaceObject
        $interfaceObject.shutdown=$false
        #Get interface with vlan
        if(($interface | Select-String "(interface.).+").Matches.Success){
            if( ($interface | Select-String "(interface).+?vlan").Matches.Value ){
                $interfaceObject.Routedvlan = (($interface | Select-String "(interface.).+").Matches.Value  -replace ".*?(\d+).*?",'$1').trim()
            }elseif( ($interface | Select-String "interface.*?\/\d+\.\d+.*").Matches.Success ){
                $interfaceObject.Routedvlan = (($interface | Select-String "(interface.).+").Matches.Value  -replace "interface.*?\/\d+\.(\d+).*",'$1').trim()
            }else{
                $interfaceObject.Routedvlan = "no vlan"
            }
            $interfaceObject.Interface = (($interface | Select-String "(interface.).+").Matches.Value -replace "interface ",''  -replace ' l2transport','').trim()
        }
        $interfaceObject.Description = (($interface | Select-String "(description.).+").Matches.Value -replace "description ",'').trim()


        if((($interface | Select-String "(hsrp \d+).+").Matches.Value -replace "hsrp ",'' ).trim()){#Nexus
            $interfaceObject.Standbyip = (($interface | Select-String "(ip \d+\.\d+\.\d+\.\d+)\s*").Matches.Value -replace "ip ",'').trim()
            $interfaceObject.StandbyNumber = (($interface | Select-String "(hsrp \d+).+").Matches.Value -replace "hsrp \d+",'').trim()
            $interfaceObject.StandbyPriority = (($interface | Select-String "(priority \d+).+").Matches.Value -replace "priority \d+",'').trim()
        }else{#IOS
            $interfaceObject.Standbyip = (($interface | Select-String "(standby \d+ ip).+").Matches.Value -replace "standby \d+ ip ",'').trim()
            $interfaceObject.StandbyNumber = (($interface | Select-String "(standby \d+ ip).+").Matches.Value -replace "standby ",'' -replace " ip.*",'' ).trim()
            $interfaceObject.StandbyPriority = (($interface | Select-String "(standby \d+ priority).+").Matches.Value -replace "standby \d+ priority ",'').trim()
        }
        if($interfaceObject.Standbyip){
            $ArrayOfIPAddresses+=$interfaceObject.Standbyip
        }
        # IOS permits any number of "ip address ... secondary" lines on one interface. Every one is
        # captured here as a parallel array entry - Get-MTAutoDrawInterfaceIPv4Address, the CSV/JSON
        # exports and NeighborResolution.ps1 already read Secondary(IPAddress|SubnetMask|Cidr) as
        # arrays, and Palo Alto's continuation-line reader (PaloAltoConfigProcessingFunctions.ps1)
        # uses the same shape.
        if ( ($interface | Select-String "(?m)^(\s*ip|\s*ipv4) address.+$").Matches.Success){
            $secondaryPattern = '(?m)^\s*(?:ip|ipv4) address (?<ip>\d+(?:\.\d+){3})(?:/(?<prefix>\d{1,2})|\s+(?<mask>\d+(?:\.\d+){3}))\s+secondary\s*$'
            $secondaryLineMatch = $interface | Select-String -Pattern $secondaryPattern -AllMatches
            $secondaryAddresses = [System.Collections.Generic.List[string]]::new()
            $secondaryMasks = [System.Collections.Generic.List[string]]::new()
            $secondaryCidrs = [System.Collections.Generic.List[string]]::new()
            if ($secondaryLineMatch) {
                foreach ($match in $secondaryLineMatch.Matches) {
                    $address = $match.Groups['ip'].Value
                    $subnet = if ($match.Groups['prefix'].Success) {
                        Get-IPv4Subnet -IPAddress $address -PrefixLength $match.Groups['prefix'].Value
                    } else {
                        Get-IPv4Subnet -IPAddress $address -SubnetMask $match.Groups['mask'].Value
                    }
                    $secondaryAddresses.Add($address)
                    $secondaryMasks.Add([string]$subnet.PrefixLength)
                    $secondaryCidrs.Add([string]$subnet.cidrid)
                }
            }
            if ($secondaryAddresses.Count -gt 0) {
                $interfaceObject.SecondaryIPAddress = @($secondaryAddresses)
                $interfaceObject.SecondarySubnetMask = @($secondaryMasks)
                $interfaceObject.SecondaryCidr = @($secondaryCidrs)
                $ArrayOfIPAddresses += $interfaceObject.SecondaryIPAddress
            }


            #Normal ip address selection
            if(($interface | Select-String "((ip|ipv4) address.).+?\/.*?").Matches.Success){
                $interfaceObject.IPAddress =  (($interface | Select-String "(ip|ipv4) address (\d+(\.\d+){3})/\d+[^ secondary]").Matches.Value -replace "(ip|ipv4) address (\d+(\.\d+){3})/\d+.*",'$2').trim()
                if ($interfaceObject.IPAddress -eq ""){ $interfaceObject.IPAddress = $null }
                $interfaceObject.SubnetMask = (($interface | Select-String "(ip|ipv4) address (\d+(\.\d+){3})/\d+[^ secondary]").Matches.Value -replace "(ip|ipv4) address .*?/(\d+)",'$2').trim()
                if ($interfaceObject.SubnetMask -eq ""){ $interfaceObject.SubnetMask = $null }
                if($null -ne $interfaceObject.IPAddress  -and  $null -ne $interfaceObject.SubnetMask ){
                    $interfaceObject.Cidr = (Get-IPv4Subnet -IPAddress $interfaceObject.IPAddress -PrefixLength $interfaceObject.SubnetMask).cidrid
                }
            }else{
                $interfaceObject.IPAddress =  (($interface | Select-String "(ip|ipv4) address \d+(\.\d+){3} \d+(\.\d+){3}[^ secondary]").Matches.Value -replace "(ip|ipv4) address (\d+(\.\d+){3}) .*",'$2').trim()
                if ($interfaceObject.IPAddress -eq ""){ $interfaceObject.IPAddress = $null }
                $interfaceObject.SubnetMask = (($interface | Select-String "(ip|ipv4) address \d+(\.\d+){3} \d+(\.\d+){3}[^ secondary]").Matches.Value -replace "(ip|ipv4) address .*? ((\d+(\.\d+){3}))",'$2').trim()
                if ($interfaceObject.SubnetMask -eq ""){ $interfaceObject.SubnetMask = $null }
                if($null -ne $interfaceObject.IPAddress  -and $null -ne $interfaceObject.SubnetMask ){

                    $interfaceObject.Cidr = (Get-IPv4Subnet -IPAddress $interfaceObject.IPAddress  -SubnetMask $interfaceObject.SubnetMask).cidrid

                }
            }
        }
        if($interfaceObject.IPAddress){
            $ArrayOfIPAddresses+=$interfaceObject.IPAddress
        }
        $interfaceObject.vrf = (($interface | Select-String "(ip vrf forwarding .).+").Matches.Value -replace "ip vrf forwarding ",'').trim() #Assume IOS VRF, returns a blank string.
        if($interfaceObject.vrf -eq ""){
            $interfaceObject.vrf = (($interface | Select-String "(vrf forwarding .).+").Matches.Value -replace "vrf forwarding ",'').trim() #IOSX VRF
        }
        if($interfaceObject.vrf -eq ""){
            $interfaceObject.vrf = (($interface | Select-String "(vrf member .).+").Matches.Value -replace "vrf member ",'').trim() #NXOS VRF
        }

        if ( ($interface | Select-String " vpc \d+").Matches.success ){
            $interfaceObject.vpc = (($interface | Select-String " vpc \d+").Matches.Value -replace " vpc ",'').trim()
        }
        if ( ($interface | Select-String " vpc peer-link").Matches.success ){
            $interfaceObject.vpc = "peer-link"
        }
        if ( ($interface | Select-String "channel-group \d+ mode active").Matches.success ){
            $interfaceObject.ChannelGroup = (($interface | Select-String "(channel-group .).+").Matches.Value -replace "channel-group ",'' -replace ' mode active','').trim()
            $interfaceObject.ChannelGroupMode="Active"
        }
        if ( ($interface | Select-String "channel-group \d+ mode passive").Matches.success ){
            $interfaceObject.ChannelGroup = (($interface | Select-String "(channel-group .).+").Matches.Value -replace "channel-group ",'' -replace ' mode passive','').trim()
            $interfaceObject.ChannelGroupMode="passive"
        }
        if ( ($interface | Select-String "channel-group \d+ mode on").Matches.success ){
            $interfaceObject.ChannelGroup = (($interface | Select-String "(channel-group .).+").Matches.Value -replace "channel-group ",'' -replace ' mode on','').trim()
            $interfaceObject.ChannelGroupMode="on"
        }
        if ( ($interface | Select-String "channel-group \d+ mode desirable").Matches.success ){
            $interfaceObject.ChannelGroup = (($interface | Select-String "(channel-group .).+").Matches.Value -replace "channel-group ",'' -replace ' mode desirable','').trim()
            $interfaceObject.ChannelGroupMode="desirable"
        }
        $interfaceObject.Nativevlan = (($interface | Select-String "(switchport trunk native vlan .).+").Matches.Value -replace "switchport trunk native vlan ",'').trim()
        $interfaceObject.SpanningTreePortType = (($interface | Select-String "(spanning-tree port type .).+").Matches.Value -replace "spanning-tree port type ",'').trim()
        $interfaceObject.bpdufilter = (($interface | Select-String "(spanning-tree bpdufilter.).+").Matches.Value -replace "spanning-tree bpdufilter",'').trim()
        $interfaceObject.SwitchportMode = (($interface | Select-String "(switchport mode.).+").Matches.Value -replace "switchport mode ",'').trim()
        $interfaceObject.SwitchportAccessvlan = (($interface | Select-String "(switchport access vlan.).+").Matches.Value -replace "switchport access vlan ",'').trim()
        if($null -eq $interfaceObject.SwitchportMode -or "" -eq $interfaceObject.SwitchportMode){#Nexus switches don't display the mode if they are in access mode.
            if($interfaceObject.SwitchportAccessvlan){
                $interfaceObject.SwitchportMode="access"
            }
        }

        #switchport trunk allowed vlan 1,200,203,206,308,310,318,322,330,340,341,370
        $interfaceObject.SwitchportTrunkvlan = (($interface | Select-String "(switchport trunk allowed vlan.).+").Matches.Value -replace "switchport trunk allowed vlan ",'').trim()
        #switchport trunk allowed vlan add 701
        if(($interface | Select-String "(switchport trunk allowed vlan add.).+").Matches.Value){
            $interfaceObject.SwitchportTrunkvlan += " $((($interface | Select-String "(switchport trunk allowed vlan add.).+").Matches.Value -replace "switchport trunk allowed vlan add ",'').trim())"
        }
        if( (-not $interfaceObject.SwitchportMode) -and $interfaceObject.SwitchportTrunkvlan){
            $interfaceObject.SwitchportMode = "Probably Trunk mode"
        }
        if ($interface -match '(?m)^\s*shutdown\s*$') {
            $interfaceObject.shutdown = $true
        } else {
            $interfaceObject.shutdown = $false
        }
        if($null -ne $interfaceObject.Cidr){
            $NetworkObject = Create-NetworkObject
            $NetworkObject.Cidr = $interfaceObject.Cidr
            if( $interfaceObject.Interface -like "*vlan*"){
                $NetworkObject.Routedvlan = $interfaceObject.Interface
            }else {
                $NetworkObject.Routedvlan = "no vlan"
            }
            $ArrayOfHostNetworks += $NetworkObject
        }
        foreach($secondaryCidrEntry in @($interfaceObject.SecondaryCidr)){
            if($null -eq $secondaryCidrEntry -or $secondaryCidrEntry -eq ''){ continue }
            $NetworkObject = Create-NetworkObject
            $NetworkObject.Cidr = $secondaryCidrEntry
            if( $interfaceObject.Interface -like "*vlan*"){
                $NetworkObject.Routedvlan = $interfaceObject.Interface
            }else {
                $NetworkObject.Routedvlan = "no vlan"
            }
            $ArrayOfHostNetworks += $NetworkObject
        }
        if($interfaceObject.SubnetMask -like "*.*"){ #Just use CIDR notation
            $interfaceObject.SubnetMask = Covert-NetMaskToCIDR -SubnetMask $interfaceObject.SubnetMask
        }
        if ( ($interface | Select-String "no switchport").Matches.success -or ($null -ne $interfaceObject.IPAddress ) ){
            $interfaceObject.SwitchPortType = 'Routed'
        }
        $interfaces += $interfaceObject
    }
    #Add colors to port-channel interfaces
    foreach($PortChannel in ($interfaces | where { $_.interface -like "port-channel*"})){
        $PortChannel.ShapeColor = Get-DeterministicRgbColor -Seed "port-channel|$($PortChannel.Interface)"
        $interfaces | where { $_.ChannelGroup -eq ($PortChannel.interface -replace "(p|P)ort\-channel\s*",'')} | % { $_.ShapeColor = $PortChannel.ShapeColor }
    }
    #Add colors to VRF interfaces
    $LastVRFInterface=$null
    foreach($VRFInterface in ($interfaces | where { $_.vrf } | sort vrf )){
        if ($VRFInterface.vrf -ne $LastVRFInterface.vrf){
            $Color=Get-DeterministicRgbColor -Seed "vrf|$($VRFInterface.vrf)"
        }
        $VRFInterface.VRFColor =  $Color
        $LastVRFInterface=$VRFInterface
    }
    return $interfaces,$ArrayOfHostNetworks,$ArrayOfIPAddresses
}

# --- Capture readers ------------------------------------------------------------------------------

# Parses 'show version' into the device's version object, and sets Version.Type, which every reader
# below branches on to choose between the cisco_ios_* and cisco_nxos_* template sets.
function Update-CiscoVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowVersion')) { return }

    # --- EXTRACT ---
    # The banner is the only reliable discriminator: NX-OS and IOS both answer 'show version'.
    $text = Get-MTAutoDrawCaptureText -Path $Path
    $isIos = ($text | Select-String 'Cisco IOS Software').Matches.Success
    $isNexus = ($text | Select-String 'Cisco Nexus Operating System').Matches.Success
    if (-not $isIos -and -not $isNexus) {
        Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message 'show version names neither IOS nor NX-OS; leaving the device type unset.'
        return
    }

    $template = if ($isIos) { 'cisco_ios_show_version' } else { 'cisco_nxos_show_version' }
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template $template -Path $Path
    if (@($rows).Count -eq 0) { return }
    $row = @($rows)[0]

    # --- MAP + MERGE ---
    $VersionObject = Create-ShowVersionObject
    if ($isIos) {
        $VersionObject.OS              = $row.SOFTWARE_IMAGE
        $VersionObject.ROMMON          = $row.ROMMON
        $VersionObject.Hostname        = $row.HOSTNAME
        $VersionObject.Uptime          = $row.UPTIME
        $VersionObject.UptimeYear      = $row.UPTIME_YEARS
        $VersionObject.UptimeWeeks     = $row.UPTIME_WEEKS
        $VersionObject.UptimeDays      = $row.UPTIME_DAYS
        $VersionObject.UpdateHours     = $row.UPTIME_HOURS
        $VersionObject.UptimeMinutes   = $row.UPTIME_MINUTES
        $VersionObject.ReasonForRelod  = $row.RELOAD_REASON
        $VersionObject.Image           = $row.RUNNING_IMAGE
        # HARDWARE, SERIAL and MAC_ADDRESS are List values, so they arrive as arrays; the pipe
        # unwraps a single-element one to the scalar every consumer of these fields expects.
        $VersionObject.Hardware        = $row.HARDWARE    | ForEach-Object { $_ }
        $VersionObject.Serial          = $row.SERIAL      | ForEach-Object { $_ }
        $VersionObject.ConfigRegister  = $row.CONFIG_REGISTER
        $VersionObject.MacAddressArray = $row.MAC_ADDRESS | ForEach-Object { $_ }
        $VersionObject.LastRestarted   = $row.RESTARTED
        # IOS-XE runs the same command set but reports its own transceiver and media data.
        if (($text | Select-String 'IOS-XE').Matches.Success) {
            $VersionObject.type = 'XE-IOS'
        } else {
            $VersionObject.type = 'IOS'
        }
    } else {
        $VersionObject.Uptime          = $row.UPTIME
        $VersionObject.ReasonForRelod  = $row.LAST_REBOOT_REASON
        $VersionObject.ROMMON          = $row.BIOS
        $VersionObject.OS              = $row.OS
        $VersionObject.Image           = $row.BOOT_IMAGE
        $VersionObject.Hardware        = $row.PLATFORM
        $VersionObject.Hostname        = $row.HOSTNAME
        $VersionObject.Serial          = $row.SERIAL
        $VersionObject.type            = 'NXOS'
    }
    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Device Type:$($VersionObject.type)"
    $Device.Version = $VersionObject
}

# Parses 'show cdp neighbors detail' into the device's CDP neighbour objects and marks each local
# interface as having one, which is how the LLDP readers avoid drawing the same link twice.
function Update-CiscoCdpNeighbors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowCDPNeighborsDetails')) { return }

    # --- EXTRACT ---
    $isNexus = $Device.Version.Type -eq 'NXOS'
    if (-not $isNexus -and $Device.Version.Type -notin @('IOS', 'XE-IOS')) {
        Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message 'Unknown device type; skipping CDP neighbours.'
        return
    }
    $template = if ($isNexus) { 'cisco_nxos_show_cdp_neighbors_detail' } else { 'cisco_ios_show_cdp_neighbors_detail' }
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template $template -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    $ArrayOfNeighborObjects = @()
    foreach ($neighbor in $rows) {
        if ($GSkipCDPLLDPPhones) {
            # A Nexus switch can advertise the capability phrase "phone port". Capabilities alone
            # therefore cannot identify an endpoint as a phone, so the name and platform are tested.
            if ("$($neighbor.NEIGHBOR_NAME) $($neighbor.PLATFORM)" -match '(?i)\b(?:ip\s*)?phone\b|telephone') { continue }
        }
        $NeighborObject = Create-CDPNeighborObject
        if ($isNexus) {
            # The NX-OS template splits what IOS calls the device id into a chassis id and a system
            # name, and reports the neighbour's interface address separately from its management one.
            $NeighborObject.DeviceID              = $neighbor.CHASSIS_ID.trim()
            $NeighborObject.SystemName            = $neighbor.NEIGHBOR_NAME.trim()
            $NeighborObject.InterfaceIPAddresses  = $neighbor.INTERFACE_IP.trim()
            $NeighborObject.InterfaceAddress      = $neighbor.MGMT_ADDRESS.trim()
        } else {
            $NeighborObject.DeviceID              = $neighbor.NEIGHBOR_NAME.trim()
            $NeighborObject.InterfaceIPAddresses  = $neighbor.MGMT_ADDRESS.trim()
        }
        $NeighborObject.Platform              = $neighbor.PLATFORM.trim()
        $NeighborObject.InterfaceRemoteDevice = $neighbor.NEIGHBOR_INTERFACE.trim()
        $NeighborObject.InterfaceLocalDevice  = $neighbor.LOCAL_INTERFACE.trim()
        $NeighborObject.Version               = $neighbor.NEIGHBOR_DESCRIPTION.trim()
        $NeighborObject.Capabilities          = $neighbor.CAPABILITIES.trim()
        $NeighborObject.ParentObject          = $Device.hostname
        #note that the interface has a CDP nieghbor
        $Device.interfaces | Where-Object { $_.interface -eq $NeighborObject.InterfaceLocalDevice } | ForEach-Object { $_.HasCPDNieghbor = $true }
        $ArrayOfNeighborObjects += $NeighborObject
    }

    #Sort the object correctly so we get minimal crossed lines when drawing the objects.
    $Device.CDPNeighbors = $ArrayOfNeighborObjects | Sort-Object -Property @{
        Expression = { [int]($_.InterfaceLocalDevice -replace '[a-zA-Z-]+', '' -replace "/", '') }
    }
}

# Parses the 'show lldp neighbors' summary table. Only IOS is handled: this reader exists to supply
# the local interface when the detail capture omits it, and only IOS produces such a capture.
function Update-CiscoLldpNeighbors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if ($Device.Version.Type -notin @('IOS', 'XE-IOS')) { return }
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowLLDPNeighbors')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'cisco_ios_show_lldp_neighbors' -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    $AllLLDPDetailsObjects = @()
    foreach ($LLDPNeighbor in $rows) {
        # (T) is the LLDP telephone capability.
        if ($GSkipCDPLLDPPhones -and ($LLDPNeighbor.CAPABILITIES.trim()) -like "*T*") { continue }

        $LLDPObject = Create-LLDPNeighborObject
        $LLDPObject.Hostname = $LLDPNeighbor.NEIGHBOR_NAME.trim()
        $LLDPObject.InterfaceLocalDevice = (Replace-InterfaceShortName -string $LLDPNeighbor.LOCAL_INTERFACE)
        $LLDPObject.InterfaceRemoteDevice = (Replace-InterfaceShortName -string $LLDPNeighbor.NEIGHBOR_INTERFACE)
        if ([string]::IsNullOrEmpty($LLDPObject.InterfaceRemoteDevice)) {
            $LLDPObject.InterfaceRemoteDevice = "Unknown Interface"
        }
        if ($LLDPObject.Hostname -eq "" -or $LLDPObject.Hostname -eq "null") {
            $LLDPObject.Hostname = $LLDPObject.ChassisID
        }
        $LLDPObject.CAPABILITIES = $LLDPNeighbor.CAPABILITIES.trim()
        $LLDPObject.PortID = (Replace-InterfaceShortName -string $LLDPNeighbor.NEIGHBOR_INTERFACE).trim()
        #record that the interface has a LLDP nieghbor
        $TempInterface = $Device.interfaces | Where-Object { $_.interface -eq $LLDPObject.InterfaceLocalDevice }
        $TempInterface.HasLLDPNeighbor = $true
        if ($TempInterface.HasCPDNieghbor) { #If we have a CDP nieghbor object already note it on this object. This is used so we don't draw duplicate objects with CDP and LLDP.
            $LLDPObject.HasCDPNeighborEntry = $true
        }
        $AllLLDPDetailsObjects += $LLDPObject
    }

    $Device.LLDPNeighbors = $AllLLDPDetailsObjects | Sort-Object -Property @{
        Expression = { [int]($_.InterfaceLocalDevice -replace '[a-zA-Z-]+', '' -replace "/", '') }
    }
}

# Parses 'show lldp neighbors detail' into the device's LLDP neighbour objects. When the summary
# table has already been read - which happens only when this capture omits the local interface -
# each row enriches the matching existing entry instead of creating a new one.
function Update-CiscoLldpNeighborDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowLLDPNeighborsDetails')) { return }
    $isNexus = $Device.Version.Type -eq 'NXOS'
    if (-not $isNexus -and $Device.Version.Type -notin @('IOS', 'XE-IOS')) {
        Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message 'Unknown device type; skipping LLDP neighbour details.'
        return
    }
    # Anything already in the list came from Update-CiscoLldpNeighbors, which Resolve-CiscoLldpNeighbors
    # runs only when this capture cannot name the local interface itself.
    $DetailsProcessed = @($Device.LLDPNeighbors).Count -gt 0

    # --- EXTRACT ---
    # The NX-OS template accepts both a numeric VLAN and "not advertised". Never rewrite captures.
    $template = if ($isNexus) { 'cisco_nxos_show_lldp_neighbors_detail' } else { 'cisco_ios_show_lldp_neighbors_detail' }
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template $template -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    $AllLLDPDetailsObjects = @()
    foreach ($LLDPNeighbor in $rows) {
        $LLDPObject = $null
        if ($isNexus) {
            $LLDPObject = Create-LLDPNeighborObject
            $LLDPObject.SystemDescription = $LLDPNeighbor.NEIGHBOR_DESCRIPTION.trim()
            if ($GSkipCDPLLDPPhones -and ($LLDPObject.SystemDescription) -like "*Phone*") { continue }
            $LLDPObject.Hostname = $LLDPNeighbor.NEIGHBOR_NAME.trim()
            $LLDPObject.InterfaceLocalDevice = (Replace-InterfaceShortName -string $LLDPNeighbor.LOCAL_INTERFACE)
            $LLDPObject.InterfaceRemoteDevice = (Replace-InterfaceShortName -string $LLDPNeighbor.NEIGHBOR_INTERFACE)
            $LLDPObject.ChassisID = $LLDPNeighbor.CHASSIS_ID.trim()
            $LLDPObject.ManagementIP = $LLDPNeighbor.MGMT_ADDRESS.trim()
            $LLDPObject.CAPABILITIES = $LLDPNeighbor.CAPABILITIES.trim()
            $LLDPObject.VLAN = $LLDPNeighbor.VLAN_ID.trim()
        } else {
            if ($GSkipCDPLLDPPhones -and ($LLDPNeighbor.NEIGHBOR_DESCRIPTION.trim()) -like "*Phone*") { continue }

            if ($DetailsProcessed) {
                # Match this row against the skeleton the summary table produced. The system name is
                # preferred and the chassis id is the fallback, because a device that advertises no
                # name appears under its chassis id in both captures.
                $TempHostname = $LLDPNeighbor.NEIGHBOR_NAME.trim()
                if ([string]::IsNullOrEmpty($TempHostname)) { $TempHostname = $LLDPNeighbor.CHASSIS_ID.trim() }
                $TempLLDPNeighbor = $Device.LLDPNeighbors | Where-Object {
                    $TempHostname -like "*$($_.Hostname)*" -and $_.PortID -eq (Replace-InterfaceShortName -string $LLDPNeighbor.NEIGHBOR_PORT_ID)
                }
                if (-not $TempLLDPNeighbor) { continue }
                $LLDPObject = $TempLLDPNeighbor
            } else {
                $LLDPObject = Create-LLDPNeighborObject
                $LLDPObject.Hostname = $LLDPNeighbor.NEIGHBOR_NAME.trim()
                $LLDPObject.CAPABILITIES = $LLDPNeighbor.CAPABILITIES.trim()
                $LLDPObject.InterfaceLocalDevice = (Replace-InterfaceShortName -string $LLDPNeighbor.LOCAL_INTERFACE)
                $LLDPObject.InterfaceRemoteDevice = (Replace-InterfaceShortName -string $LLDPNeighbor.NEIGHBOR_PORT_ID)
            }

            $LLDPObject.SystemDescription = $LLDPNeighbor.NEIGHBOR_DESCRIPTION.trim()
            $LLDPObject.ChassisID = $LLDPNeighbor.CHASSIS_ID.trim()
            # A Junos neighbour advertises its logical unit - ge-0/1/1.0 where the device itself calls
            # the interface ge-0/1/1. The remote name is stored exactly as advertised, because that is
            # what the neighbour said; the trailing unit is stripped during matching by
            # ConvertTo-NormalizedInterfaceIdentity, which is the only place it matters.
            if ([string]::IsNullOrEmpty($LLDPObject.InterfaceRemoteDevice)) {
                $LLDPObject.InterfaceRemoteDevice = "Unknown Interface"
            }
            $LLDPObject.NeighborInterfaceDescription = $LLDPNeighbor.NEIGHBOR_INTERFACE.trim()
            $LLDPObject.ManagementIP = $LLDPNeighbor.MGMT_ADDRESS.trim()
            $LLDPObject.VLAN = $LLDPNeighbor.VLAN_ID.trim()
            $LLDPObject.SERIAL = $LLDPNeighbor.SERIAL.trim()
        }

        $LLDPObject.ParentObject = $Device.hostname
        if ($LLDPObject.Hostname -eq "" -or $LLDPObject.Hostname -eq "null") {
            $LLDPObject.Hostname = $LLDPObject.ChassisID
        }
        #record that the interface has a LLDP nieghbor
        $TempInterface = $Device.interfaces | Where-Object { $_.interface -eq $LLDPObject.InterfaceLocalDevice }
        $TempInterface.HasLLDPNeighbor = $true
        if ($TempInterface.HasCPDNieghbor) { #If we have a CDP nieghbor object already note it on this object. This is used so we don't draw duplicate objects with CDP and LLDP.
            $LLDPObject.HasCDPNeighborEntry = $true
        }
        $AllLLDPDetailsObjects += $LLDPObject
    }

    $Device.LLDPNeighbors = $AllLLDPDetailsObjects | Sort-Object -Property @{
        Expression = { [int]($_.InterfaceLocalDevice -replace '[a-zA-Z-]+', '' -replace "/", '') }
    }
}

# Parses 'show interface' into the device's interface list. An interface already recovered from the
# running config is updated in place; when none of them were, the whole list is built from this
# capture instead.
#
# The update and create paths are not the same set of fields, and the two dialects do not agree on
# which column feeds which property. Those differences are reproduced here rather than unified,
# because existing output depends on them. Some are genuine defects; unifying the two paths is a
# behaviour change and needs to be treated as one.
function Update-CiscoInterfaces {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowInterface')) { return }
    $isNexus = $Device.Version.Type -eq 'NXOS'
    if (-not $isNexus -and $Device.Version.Type -notin @('IOS', 'XE-IOS')) { return }

    # --- EXTRACT ---
    $template = if ($isNexus) { 'cisco_nxos_show_interface' } else { 'cisco_ios_show_interfaces' }
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template $template -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    [array]$AllInterfaces = @()
    $UpdateOnly = $false #This is used to ensure we don't add duplicate interfaces due to naming differences between show run and show interface.
    foreach ($int in $rows) {
        $Interface = $Device.interfaces | Where-Object { $_.interface -eq $int.INTERFACE }
        if ($Interface) { #We already have the interface from show run. Just update some variables.
            $UpdateOnly = $true
        } else {
            if ($UpdateOnly) { #We are only updating. Skip. This should really never happen.
                Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Tried to create a interface we can't find in show run skipping."
                continue
            }
            Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Creating Interface:$($int.INTERFACE)"
            $Interface = Create-InterfaceObject
            $Interface.Interface = $int.INTERFACE
        }

        if ($isNexus) {
            # NX-OS reports an administrative state where IOS reports a protocol status, and only the
            # create path strips the "administratively " prefix from the link status.
            $Interface.IntStatus = if ($UpdateOnly) { $int.LINK_STATUS -replace "\s*\(.*", '' } else { $int.LINK_STATUS -replace "administratively ", '' -replace "\s*\(.*", '' }
            $Interface.INTProtocolStatus = $int.ADMIN_STATE -replace "\s*\(.*", '' -replace ",.*", ''
        } else {
            $Interface.IntStatus = $int.LINK_STATUS -replace "administratively ", '' -replace "\s*\(.*", ''
            $Interface.INTProtocolStatus = $int.PROTOCOL_STATUS -replace "\s*\(.*", '' -replace ",.*", ''
        }
        #Is the interface shutdown. Default is $false.
        if ($Interface.IntStatus -eq "down" -or $Interface.INTProtocolStatus -eq "down") {
            $Interface.shutdown = $true
        }
        $Interface.macaddress = $int.MAC_ADDRESS

        if ($isNexus) {
            $Interface.Duplex = $int.DUPLEX
            $Interface.Speed = Convert-CiscoInterfaceSpeed -Value $int.SPEED
        } else {
            $Interface.Duplex = $int.DUPLEX
            $Interface.Speed = Convert-CiscoInterfaceSpeed -Value $int.SPEED
            if ($int.MEDIA_TYPE) { $Interface.MediaType = $int.MEDIA_TYPE }
        }
        if ($int.HARDWARE_TYPE) { $Interface.HardwareType = $int.HARDWARE_TYPE }

        if (-not $UpdateOnly) {
            $Interface.Description = $int.DESCRIPTION
            # IP_ADDRESS carries no prefix - both templates put that in PREFIX_LENGTH - so both halves
            # of this pair end up holding the address itself and no usable CIDR comes out of it. The
            # running config is what actually supplies addressing for these interfaces.
            $Interface.IPAddress = $int.IP_ADDRESS -replace "\/.*", ''
            $Interface.SubnetMask = $int.IP_ADDRESS -replace ".*\/", ''
            if ($Interface.IPAddress -and $Interface.SubnetMask) {
                $Interface.Cidr = (Get-IPv4Subnet -IPAddress $Interface.IPAddress -PrefixLength $Interface.SubnetMask).cidrid
            }
            # NX-OS names the encapsulation here; on IOS the same position is the queueing strategy,
            # which never says 802.1Q, so only an address marks an IOS interface as routed.
            $tagged = if ($isNexus) { $int.ENCAPSULATION } else { $int.QUEUE_STRATEGY }
            if ($tagged -like "*802.1Q*" -or $Interface.IPAddress) {
                $Interface.RoutedVlan = $true
            }
            $AllInterfaces += $Interface
        }
    }

    if (-not $UpdateOnly) { $Device.interfaces = $AllInterfaces }
}

# Normalises the handful of speed spellings the two dialects emit.
function Convert-CiscoInterfaceSpeed {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Value
    )

    if ($Value -eq '1000Mb/s') { return '1000Mb/s' }
    switch ($Value) {
        '1Gb/s'   { return '1000Mb/s' }
        '100Mb/s' { return '100Mb/s' }
        '10Mb/s'  { return '10Mb/s' }
        '10Gb/s'  { return '10Gb/s' }
    }
    return $Value
}
# Parses 'show ip interface brief' onto the interfaces already known to the device. This is the
# fallback for a host whose 'show interface' was not collected, so it only refreshes link state.
function Update-CiscoInterfaceBrief {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowIPInterfaceBrief')) { return }
    $isNexus = $Device.Version.Type -eq 'NXOS'
    if (-not $isNexus -and $Device.Version.Type -notin @('IOS', 'XE-IOS')) {
        Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message 'Unknown device type; skipping the interface brief table.'
        return
    }

    # --- EXTRACT ---
    $template = if ($isNexus) { 'cisco_nxos_show_ip_interface_brief' } else { 'cisco_ios_show_ip_interface_brief' }
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template $template -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    foreach ($int in $rows) {
        # The NX-OS table abbreviates the port name but is matched unexpanded, so only a device whose
        # interfaces are already stored abbreviated will match. Preserved from the positional version.
        $name = if ($isNexus) { $int.INTERFACE } else { Replace-InterfaceShortName -string $int.INTERFACE }
        $Interface = $Device.interfaces | Where-Object { $_.interface -eq $name } | Select-Object -First 1
        if (-not $Interface) {
            Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "$($int.INTERFACE) not found in list of interfaces. Replace-InterfaceShortName is probably the cause."
            continue
        }
        $Interface.IntStatus = $int.STATUS
        $Interface.INTProtocolStatus = $int.PROTO
    }
}

# Parses 'show interface status' onto the interfaces already known to the device. This is the only
# capture that reports the media type and the transceiver-absent state, so NX-OS always reads it.
function Update-CiscoInterfaceStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowInterfaceStatus')) { return }
    $isNexus = $Device.Version.Type -eq 'NXOS'
    if (-not $isNexus -and $Device.Version.Type -notin @('IOS', 'XE-IOS')) {
        Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message 'Unknown device type; skipping the interface status table.'
        return
    }

    # --- EXTRACT ---
    $template = if ($isNexus) { 'cisco_nxos_show_interface_status' } else { 'cisco_ios_show_interfaces_status' }
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template $template -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    foreach ($int in $rows) {
        $name = Replace-InterfaceShortName -string $int.PORT
        $Interface = $Device.interfaces | Where-Object { $_.interface -eq $name } | Select-Object -First 1
        if (-not $Interface) {
            Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "$($int.PORT) not found in list of interfaces. Replace-InterfaceShortName is probably the cause."
            continue
        }
        if ($int.STATUS -eq "connected") {
            $Interface.IntStatus = "Up"
        } elseif (($int.STATUS | Select-String "xcvrAbsen|sfpAbsent").Matches.Success) {
            $Interface.IntStatus = "xcvrAbsen"
        } else {
            $Interface.IntStatus = "Down"
        }
        if ($int.TYPE -ne "--") { $Interface.MediaType = $int.TYPE }
    }
}

# Parses 'show spanning-tree' into the device's per-VLAN spanning-tree instances, and records each
# port's role back onto the interface it belongs to.
function Update-CiscoSpanningTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowSpanningTree')) { return }

    # --- EXTRACT ---
    $ShowSpanningTreeText = Get-MTAutoDrawCaptureText -Path $Path
    if ([string]::IsNullOrWhiteSpace($ShowSpanningTreeText)) { return }

    if (-not $Device.SpanningTree) { $Device.SpanningTree = Create-SpanningTreeObject }
    $Device.SpanningTree.SpanningTreeArray = @()

    if ($ShowSpanningTreeText -match "No spanning tree instances exist") {
        Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "No spanning tree instances found."
        return
    }

    # --- MAP + MERGE ---
    # Split before any line beginning with "VLAN <number>"
    $SpanningTreeVlans = @([regex]::split([string]$ShowSpanningTreeText, '(?mi)(?=^VLAN\s*\d+)') | Where-Object { $_ -match '(?mi)^VLAN\s*\d+' })

    foreach ($vlan in $SpanningTreeVlans) {
        if ([string]::IsNullOrWhiteSpace($vlan)) { continue }
        if (-not ($vlan | Select-String "^vlan.*").matches) { continue }

        $vlanMatch = [regex]::Match([string]$vlan, '(?mi)^VLAN\s*(\d+)')
        if (-not $vlanMatch.Success) {
            Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "Skipping an unrecognized spanning-tree section without a VLAN identifier."
            continue
        }
        [int]$vlanId = 0
        if (-not [int]::TryParse($vlanMatch.Groups[1].Value, [ref]$vlanId)) {
            Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "Skipping spanning-tree section with invalid VLAN '$($vlanMatch.Groups[1].Value)'."
            continue
        }
        $SpanningTreevlanObject = Create-SpanningTreeVlan
        $SpanningTreevlanObject.vlanID = $vlanId

        # Capture the Root ID block
        $rootIDBlock = [regex]::Match([string]$vlan, '(?si)Root ID\s+Priority.+?(?=Bridge ID)').Value
        if ($rootIDBlock) {
            $rootPriorityMatch = [regex]::Match($rootIDBlock, 'Priority\s+(\S+)')
            $rootAddressMatch = [regex]::Match($rootIDBlock, 'Address\s+(\S+)')
            $rootHelloMatch = [regex]::Match($rootIDBlock, 'Hello Time\s+(\S+)')
            if ($rootPriorityMatch.Success) { $SpanningTreevlanObject.RootIDPriority = $rootPriorityMatch.Groups[1].Value }
            if ($rootAddressMatch.Success) { $SpanningTreevlanObject.Address = ConvertTo-NormalizedMacAddress $rootAddressMatch.Groups[1].Value }
            if ($rootHelloMatch.Success) { $SpanningTreevlanObject.RootBridgeHelloTime = $rootHelloMatch.Groups[1].Value }

            # Cost and Port are absent on the bridge that is itself the root.
            $costMatch = $rootIDBlock | Select-String 'Cost\s+(\S+)'
            if ($costMatch) {
                $SpanningTreevlanObject.RootBridgeCost = $costMatch.Matches.Groups[1].Value
            }
            $portMatch = $rootIDBlock | Select-String 'Port\s+(\S+)\s+\((.+?)\)'
            if ($portMatch) {
                $SpanningTreevlanObject.RootBridgePort = $portMatch.Matches.Groups[2].Value
            }
        }

        # Capture the Bridge ID block
        $bridgeIDBlock = [regex]::Match([string]$vlan, '(?si)Bridge ID\s+Priority.+?(?=Interface\s+Role|Interface\s+----|\z)').Value
        if ($bridgeIDBlock) {
            $bridgePriorityMatch = [regex]::Match($bridgeIDBlock, 'Priority\s+(\S+)')
            $bridgeAddressMatch = [regex]::Match($bridgeIDBlock, 'Address\s+(\S+)')
            $bridgeHelloMatch = [regex]::Match($bridgeIDBlock, 'Hello Time\s+(\S+)')
            if ($bridgePriorityMatch.Success) { $SpanningTreevlanObject.BridgeIDPriority = $bridgePriorityMatch.Groups[1].Value }
            if ($bridgeAddressMatch.Success) { $SpanningTreevlanObject.BridgeIDPriorityAddress = ConvertTo-NormalizedMacAddress $bridgeAddressMatch.Groups[1].Value }
            if ($bridgeHelloMatch.Success) { $SpanningTreevlanObject.BridgeIDPriorityHelloTime = $bridgeHelloMatch.Groups[1].Value }

            $agingTimeMatch = $bridgeIDBlock | Select-String 'Aging Time\s+(\S+)'
            if ($agingTimeMatch) {
                $SpanningTreevlanObject.RootBridgeAgingTime = $agingTimeMatch.Matches.Groups[1].Value
            }
        }

        # On the root bridge the Root ID block repeats the bridge's own identity, so it is copied
        # across rather than parsed from a block that is not printed.
        if (($vlan | Select-String "This bridge is the root").Matches.Success) {
            $SpanningTreevlanObject.RootBridge = $true
            $SpanningTreevlanObject.RootIDPriority = $SpanningTreevlanObject.BridgeIDPriority
            $SpanningTreevlanObject.Address = $SpanningTreevlanObject.BridgeIDPriorityAddress
            $SpanningTreevlanObject.RootBridgeHelloTime = $SpanningTreevlanObject.BridgeIDPriorityHelloTime
        }

        if (($vlan | Select-String "Spanning tree enabled").Matches.Success) {
            $SpanningTreevlanObject.protocol = ($vlan | Select-String "Spanning tree enabled(.+)").matches.value -replace "Spanning tree enabled\s+protocol\s+", ''
        }

        $SpanningTreevlanObject.SpanningTreeInterfaces = @()
        $interfaceSections = @([regex]::split($vlan, "(?smi)^\-+"))
        $interfaceBlock = if ($interfaceSections.Count -gt 1) { $interfaceSections[1] -replace "-", '' } else { $null }

        if (-not [string]::IsNullOrWhiteSpace($interfaceBlock)) {
            $Interfaces = $interfaceBlock.Trim().Split([Environment]::NewLine, [StringSplitOptions]::RemoveEmptyEntries)
            foreach ($interfaceLine in $Interfaces) {
                if ([string]::IsNullOrWhiteSpace($interfaceLine)) { continue }

                $SpanningTreeInterface = Create-SpanningTreeInterface
                $TextArray = $interfaceLine.Trim() -split '\s+'
                if ($TextArray.Length -lt 5) { continue }

                $SpanningTreeInterface.Interface = $TextArray[0]
                $SpanningTreeInterface.Role = $TextArray[1]
                $SpanningTreeInterface.Status = $TextArray[2]
                $SpanningTreeInterface.Cost = $TextArray[3]
                $SpanningTreeInterface.PrioNbr = $TextArray[4]

                if ($TextArray.Length -gt 5) {
                    $SpanningTreeInterface.Type = ($TextArray[5..($TextArray.Length - 1)]) -join " "
                }

                $SpanningTreevlanObject.SpanningTreeInterfaces += $SpanningTreeInterface

                # Spanning tree information for each port
                $currentInterface = $SpanningTreeInterface.Interface
                $foundInterfaces = $Device.interfaces | Where-Object {
                    $_.interface -eq $currentInterface -or
                    ($_.ChannelGroup -and ("port-channel" + $_.ChannelGroup) -eq $currentInterface)
                }
                foreach ($DeviceInterface in $foundInterfaces) {
                    Switch ($SpanningTreeInterface.Role) {
                        "Root" { $DeviceInterface.STRootInterfaceForvlans += , $SpanningTreevlanObject.vlanID }
                        "Desg" { $DeviceInterface.STDesgnInterfaceForvlans += , $SpanningTreevlanObject.vlanID }
                        "Altn" { $DeviceInterface.STALTnInterfaceForvlans += , $SpanningTreevlanObject.vlanID }
                    }
                    $DeviceInterface.STState = $SpanningTreeInterface.Status
                    $DeviceInterface.STRole = $SpanningTreeInterface.Role
                }
            }
        }
        $Device.SpanningTree.SpanningTreeArray += $SpanningTreevlanObject
    }
}

# Parses the routing table into the device's route objects. Select-CiscoRouteCapture has already
# chosen which of the three route slots this is; a recursive next hop is resolved back to the
# directly connected interface that reaches it.
function Update-CiscoRoutes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowIPRoute')) { return }

    # --- EXTRACT ---
    $ShowRouteText = Get-MTAutoDrawCaptureText -Path $Path
    # An NX-OS routing table is recognisable from the capture itself, which matters for a host whose
    # 'show version' was never collected.
    $isNexus = $Device.Version.Type -eq 'NXOS' -or $ShowRouteText -match '(?im)^IP Route Table for VRF\s+"'
    $template = if ($isNexus) { 'cisco_nxos_show_ip_route' } else { 'cisco_ios_show_ip_route' }
    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "This is a $(if ($isNexus) { 'Nexus' } else { 'IOS' }) device"
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template $template -Path $Path

    # A device that answers 'show ip route' with nothing but a default gateway is still telling us
    # where its traffic goes, and that single route is worth more than an empty routing table.
    if (@($rows).Count -eq 0) {
        $gatewayMatch = $ShowRouteText | Select-String "Default gateway is \d+.\d+.\d+.\d+"
        if (-not $gatewayMatch.Matches.Success) {
            Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "Error processing show ip route file '$Path'. TextFSM returned an error or the file is empty/invalid."
            return
        }
        Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "TextFSM failed for routing table, but found a default gateway as a fallback."
        $RouteObject = Create-RouteObject
        $RouteObject.gateway = $gatewayMatch.matches.value -replace "Default gateway is ", ''
        $RouteObject.Subnet = "0.0.0.0/0"
        $RouteObject.RouteProtocol = "Default gateway"
        foreach ($Interface in ($Device.interfaces | Where-Object { $_.cidr -and $_.IntStatus -ne "down" })) {
            if ((Find-Subnet -addr1 $Interface.cidr -addr2 $RouteObject.gateway).condition) {
                $RouteObject.Interface = $Interface.Interface
                break
            }
        }
        Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Found default gateway:$($RouteObject)"
        $Device.RoutingTable += $RouteObject
        return
    }

    # --- MAP + MERGE ---
    # Filtered once: the recursive-gateway search below runs per route, and a large table would
    # otherwise re-walk every interface for every one of them.
    $ActiveInterfaces = $Device.interfaces | Where-Object { $_.cidr -and $_.IntStatus -ne "down" }
    $lastGateway = $null
    $lastInterface = $null

    $AllRouteObjects = foreach ($Route in ($rows | Sort-Object { $_.NEXTHOP_IP })) {
        $RouteObject = Create-RouteObject
        if ($isNexus) {
            $RouteObject.VRF = $Route.VRF
            $RouteObject.RouteProtocol = $Route.PROTOCOL
            if ($RouteObject.RouteProtocol -eq "hsrp" -and $GSkipHSRPRoutes) { #HSRP is not a routing protocol we want to have included.
                continue
            }
            if ($null -eq $RouteObject.RouteProtocol) { #something went wrong, we have a route without a routing protocol
                Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "Error No routing protocol:$($Route)"
                continue
            }
        } else {
            if ($Route.VRF) { $RouteObject.vrf = $Route.VRF }
            switch ($Route.PROTOCOL) {
                C { $RouteObject.RouteProtocol = "connected" }
                L { $RouteObject.RouteProtocol = "local" }
                S { $RouteObject.RouteProtocol = "static" }
                R { $RouteObject.RouteProtocol = "RIP" }
                BGP { $RouteObject.RouteProtocol = "BGP" }
                D { $RouteObject.RouteProtocol = "EIGRP" }
                O { $RouteObject.RouteProtocol = "OSPF" }
                i { $RouteObject.RouteProtocol = "IS-IS" }
                default { #No idea lets just assign it.
                    $RouteObject.RouteProtocol = $Route.PROTOCOL
                }
            }
        }
        if ($Route.TYPE -ne "" -and $null -ne $Route.TYPE) {
            $RouteObject.RouteSubType = $Route.TYPE
        }
        $RouteObject.Subnet = "$($Route.NETWORK)/$($Route.PREFIX_LENGTH)"
        $RouteObject.DISTANCE = $Route.DISTANCE
        $RouteObject.METRIC = $Route.METRIC
        if ($isNexus) {
            if ([string]::IsNullOrEmpty($Route.NEXTHOP_IP)) {
                #This is the case of Null0
                $RouteObject.gateway = $Route.NEXTHOP_IF
            } else {
                $RouteObject.gateway = $Route.NEXTHOP_IP
            }
            $RouteObject.Interface = $Route.NEXTHOP_IF
        } else {
            $RouteObject.gateway = $Route.NEXTHOP_IP
            # The route line's own trailing interface, when the template captured one. Recursive
            # gateways are resolved below by subnet match and connected routes are back-filled later
            # by Update-LocalRoutesWithInterfaces, so this mostly matters for the routes neither path
            # reaches: a recursive next-hop that isn't on any locally-known subnet.
            $RouteObject.Interface = $Route.NEXTHOP_IF
            if ($null -eq $RouteObject.RouteProtocol) { continue }
        }

        if ($RouteObject.gateway -and ($RouteObject.gateway -ne "Null0") -and ($RouteObject.RouteProtocol -ne "local") -and ($RouteObject.RouteProtocol -ne "connected") -and ($RouteObject.RouteProtocol -ne "direct")) {
            if ($RouteObject.gateway -eq $lastGateway) {
                $RouteObject.Interface = $lastInterface
            } else {
                $found = $false
                foreach ($Interface in $ActiveInterfaces) {
                    if ((Find-Subnet -addr1 $Interface.cidr -addr2 $RouteObject.gateway).condition) {
                        $RouteObject.Interface = $Interface.Interface
                        $lastGateway = $RouteObject.gateway
                        $lastInterface = $Interface.Interface
                        $found = $true
                        break
                    }
                }
                if (-not $found) {
                    Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "No directly connected interface found for recursive gateway $($RouteObject.gateway)."
                }
            }
        }

        $RouteObject
    }
    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "$(@($AllRouteObjects).count) routes found"
    $Device.RoutingTable = $AllRouteObjects
}

# Parses 'show ip arp' into the device's ARP entries, associating each with the most specific of the
# device's own connected subnets that contains it.
function Update-CiscoArp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowIPArp')) { return }
    $isNexus = $Device.Version.Type -eq 'NXOS'
    if (-not $isNexus -and $Device.Version.Type -notin @('IOS', 'XE-IOS')) {
        Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "Error with show ip arp. Unable to find device type"
        return
    }

    # --- EXTRACT ---
    $template = if ($isNexus) { 'cisco_nxos_show_ip_arp' } else { 'cisco_ios_show_ip_arp' }
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template $template -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    # A hashtable of the device's own subnets, so the longest-prefix search below is a lookup rather
    # than a walk of the interface list for each of 32 candidate prefixes per entry.
    $subnetLookup = @{}
    $Device.interfaces | Where-Object { $_.Cidr } | ForEach-Object { $subnetLookup[$_.Cidr] = $true }

    $Device.IPArpEntries = foreach ($IPArpEntry in $rows) {
        $IPArpObject = Create-ShowIPArpObject
        # The NX-OS table has no protocol or type column; IOS reports both.
        if (-not $isNexus) {
            $IPArpObject.PROTOCOL = $IPArpEntry.PROTOCOL.trim()
            $IPArpObject.TYPE     = $IPArpEntry.TYPE.trim()
        }
        $IPArpObject.ipaddress = $IPArpEntry.IP_ADDRESS.trim()
        $IPArpObject.AGE       = $IPArpEntry.AGE.trim()
        $IPArpObject.MAC       = $IPArpEntry.MAC_ADDRESS.trim()
        if ($isNexus) {
            if ($IPArpEntry.INTERFACE.trim() -ne "") { #keep it as $null don't fill with a empty string.
                $IPArpObject.INTERFACE = $IPArpEntry.INTERFACE.trim()
            }
        } else {
            $IPArpObject.INTERFACE = $IPArpEntry.INTERFACE.trim()
        }

        $MacInOtherFormat = ($IPArpObject.MAC -replace '\.', '').insert(2, ":").insert(5, ":").insert(8, ":").insert(11, ":").insert(14, ":")
        if ($GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 8)]) {
            $IPArpObject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 8)]
        } elseif ($GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 5)]) {
            $IPArpObject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 5)]
        } else {
            $IPArpObject.VendorCompanyName = "UNKNOWN Vendor"
        }

        # Most specific subnet first: /32 down to /1.
        for ($prefix = 32; $prefix -ge 1; $prefix--) {
            $candidateCidr = (Get-IPv4Subnet -IPAddress $IPArpObject.ipaddress -PrefixLength $prefix).CIDRId
            if ($subnetLookup.ContainsKey($candidateCidr)) {
                $IPArpObject.cidr = $candidateCidr
                break
            }
        }

        $IPArpObject
    }
}

# Parses 'show mac address-table' onto the interfaces that learned each address. Three table layouts
# are in use, and the header - not the device type - is what tells them apart, because an IOS-XE
# switch prints the "Unicast Entries" form while still reporting itself as IOS.
function Update-CiscoMacAddressTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowMacAddressTable')) { return }

    # --- EXTRACT ---
    $ShowMacAddressTableText = Get-MTAutoDrawCaptureText -Path $Path
    $TypeOfDevice = $null
    if (($ShowMacAddressTableText | Select-String "vlan\s*Mac\s*Address\s*Type\s*Ports").Matches.Success -or ($ShowMacAddressTableText | Select-String "vlan\s*mac\s*address\s*type\s*learn").Matches.Success) {
        $TypeOfDevice = "IOS"
    }
    if (($ShowMacAddressTableText | Select-String "primary\s*entry\,\s*G\s*\-\s*Gateway\s*MAC,\s*\(R\)\s*\-\s*Routed\s*MAC").Matches.Success) {
        $TypeOfDevice = "Nexus"
    }
    if (($ShowMacAddressTableText | Select-String "Unicast Entries").Matches.Success) {
        $TypeOfDevice = "IOSX"
    }
    if ($null -eq $TypeOfDevice) {
        Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "Unrecognised MAC address-table layout; skipping: $Path"
        return
    }

    $template = switch ($TypeOfDevice) {
        'IOS'   { 'cisco_ios_show_mac-address-table' }
        'Nexus' { 'cisco_nxos_show_mac_address-table' }
        'IOSX'  { 'cisco_xeios_show_mac-address-table' }
    }
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template $template -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    # The three templates use different names for the same four fields. Normalize those names here;
    # the branches below contain only genuine platform-schema differences.
    foreach ($Mac in $rows) {
        switch ($TypeOfDevice) {
            'IOS'   { $port = $Mac.DESTINATION_PORT; $address = $Mac.DESTINATION_ADDRESS; $vlan = $Mac.VLAN_ID; $type = $Mac.TYPE; $protocols = $null }
            'Nexus' { $port = $Mac.PORTS;            $address = $Mac.MAC_ADDRESS;         $vlan = $Mac.VLAN_ID; $type = $Mac.TYPE; $protocols = $null }
            'IOSX'  { $port = $Mac.PORTS;            $address = $Mac.MAC;                 $vlan = $Mac.VLAN;    $type = $Mac.TYPE; $protocols = $Mac.PROTOCOLS }
        }
        if ([string]::IsNullOrEmpty($port)) { continue }
        if ($port -eq "CPU" -or $port -eq "switch" -or $port -eq "sup-Ethernet1(R)") { continue } #Skip switch and CPU interfaces.

        $MacAddressobject = Create-MacAddressObject
        $MacAddressobject.MacAddress = ($address).trim()
        # IPv6 all-nodes multicast: not a real neighbor, on any device type.
        if ("3333.0000.000d" -eq $MacAddressobject.MacAddress) { continue }

        $MacAddressobject.Interface = (Replace-InterfaceShortName -string $port)
        if ($MacAddressobject.Interface -eq "CPU" -or $MacAddressobject.Interface -eq "switch" -or $MacAddressobject.Interface -eq "sup-Ethernet1(R)") { continue }
        # The IOS-XE table lists ports the switch does not otherwise own, so it alone skips the
        # interface-shape check that would reject them.
        if ($TypeOfDevice -ne 'IOSX' -and -not (Check-InterfaceType -string $MacAddressobject.Interface)) { continue }

        $MacAddressobject.type = ($type).trim()
        $MacAddressobject.vlan = ($vlan).trim()
        if ($null -ne $protocols) { $MacAddressobject.protocols = ($protocols).trim() }

        $MacInOtherFormat = ($MacAddressobject.MacAddress -replace "\.", '').insert(2, ":").insert(5, ":").insert(8, ":").insert(11, ":").insert(14, ":")
        if ($GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 5)]) {
            $MacAddressobject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 5)]
        } elseif ($GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 8)]) {
            $MacAddressobject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 8)]
        } else {
            # Two different spellings of "not found", one per table layout. Both reach the exports.
            $MacAddressobject.VendorCompanyName = if ($TypeOfDevice -eq 'IOS') { "UNKNOWN Vendor" } else { "UNKNWON Not Found in database" }
        }

        $DeviceInterface = $Device.interfaces | Where-Object { $_.interface -eq $MacAddressobject.Interface }
        if ($null -eq $DeviceInterface) {
            Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "We could not find the interface $($MacAddressobject.Interface) on the switch. Replace-InterfaceShortName might be the problem."
            continue
        }
        $DeviceInterface.MacAddressArray += , $MacAddressobject
    }
}
