# MTAutoDraw-Standard: v1
# --- Orchestrator ---------------------------------------------------------------------------------

function Process-ArubaHostFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$HostID,
        $ArrayOfObjects   # Kept for dispatcher signature compatibility; duplicate detection is sequential.
    )

    # 1. IDENTITY - the running configuration is the only capture with a hostname, and it also creates
    # the interfaces every reader below merges onto.
    $device = New-MTAutoDrawDevice -Platform 'ArubaOS-CX' -HostID $HostID
    Update-ArubaRunningConfig -Device $device -Path $HostID.ShowRun
    if ([string]::IsNullOrEmpty($device.hostname) -or $device.hostname -like '*NoHostNameFound*') {
        Write-MTAutoDrawDiagnostic -Device $device -Severity Warning -Message "Aruba '$($HostID.HOSTID)' has no usable hostname; skipping host."
        return $null
    }
    Write-MTAutoDrawLog -Level Info -Phase Parse -Device $device -Message "Processing Aruba Host: $($device.hostname)"

    # 2. CAPTURES - one line per slot, in dependency order. The neighbour readers run before the
    # interface ones, as they always have. Update-ArubaInterfaceBrief and Update-ArubaLldpNeighbors
    # are fallbacks: each returns immediately when the richer capture already produced data.
    Update-ArubaVersion             -Device $device -Path $HostID.ShowVersion
    Update-ArubaLldpNeighborDetails -Device $device -Path $HostID.ShowLLDPNeighborsDetails
    Update-ArubaLldpNeighbors       -Device $device -Path $HostID.ShowLLDPNeighbors
    Update-ArubaInterfaces          -Device $device -Path $HostID.ShowInterface
    Update-ArubaInterfaceBrief      -Device $device -Path $HostID.ShowInterfaceBrief
    Update-ArubaSpanningTree        -Device $device -Path $HostID.ShowSpanningTreeDetails
    Update-ArubaRoutes              -Device $device -Path $HostID.ShowIPRoute
    if ($GDrawAprEntries) { Update-ArubaArp -Device $device -Path $HostID.ShowIPArp }
    # GDrawCDP is the "draw layer 2 links" toggle on this platform, which is what the MAC table feeds.
    if ($GDrawPortsWithMacs -ne 0 -and $GDrawCDP) { Update-ArubaMacAddressTable -Device $device -Path $HostID.ShowMacAddressTable }

    # 3. RECONCILE - the networks are derived from the interfaces once every reader has had its say,
    # because an address can arrive from the running config, 'show interface' or the brief table.
    Resolve-ArubaInterfaceNetworks -Device $device
    return (Complete-MTAutoDrawDevice -Device $device)
}

# Builds ArrayOfIPAddresses and ArrayOfNetworks from the finalised interface list. Not an Update-*
# reader: it consumes no capture, only what the readers have already produced.
function Resolve-ArubaInterfaceNetworks {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Device)

    $Device.ArrayOfIPAddresses = @()
    $Device.ArrayOfNetworks = @()

    foreach ($int in $Device.interfaces) {
        foreach ($address in $int.IPAddress, $int.SecondaryIPAddress) {
            if ($address) { $Device.ArrayOfIPAddresses += $address }
        }
        foreach ($cidr in $int.Cidr, $int.SecondaryCidr) {
            if (-not $cidr) { continue }
            $NetworkObject = Create-NetworkObject
            $NetworkObject.Cidr = $cidr
            $NetworkObject.Routedvlan = if ($int.Interface -like "*vlan*") { $int.Interface } else { "no vlan" }
            $NetworkObject.color = Get-DeterministicRgbColor -Seed "network|$($NetworkObject.Cidr)"
            $Device.ArrayOfNetworks += $NetworkObject
        }
    }

    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Resolve-ArubaInterfaceNetworks : Final IP Count=$(@($Device.ArrayOfIPAddresses).Count), Final Network Count=$(@($Device.ArrayOfNetworks).Count)"
}


# Parses an Aruba 'show lldp neighbors' capture into the device's LLDP neighbour objects, with per-neighbour local/remote interface and capability details. Logs a warning and returns the device unchanged if the capture is invalid or empty.
function Update-ArubaLldpNeighbors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (@($Device.LLDPNeighbors).Count -gt 0) { return }   # the detail capture is richer
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowLLDPNeighbors')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'aruba_aoscx_show_lldp_neighbors' -Path $Path
    if (@($rows).Count -eq 0) { return }

    $AllLLDPObjects = @()

    foreach ($LLDPNeighbor in $rows) {
        # Expected output order depends on your TextFSM template.
        # Based on the sample table, you typically want:
        # 0 LOCAL_INTERFACE (LOCAL-PORT)
        # 1 CHASSIS_ID
        # 2 NEIGHBOR_PORT_ID (PORT-ID)
        # 3 NEIGHBOR_INTERFACE (PORT-DESC)
        # 4 NEIGHBOR_NAME (SYS-NAME)
        #
        # If your template outputs a different order, update indexes here.

        $LLDPObject = Create-LLDPNeighborObject

        $localIf   = ([string]$LLDPNeighbor.LOCAL_INTERFACE).Trim()
        $chassisId = ([string]$LLDPNeighbor.CHASSIS_ID).Trim()
        $portId    = ([string]$LLDPNeighbor.NEIGHBOR_PORT_ID).Trim()
        $portDesc  = ([string]$LLDPNeighbor.NEIGHBOR_INTERFACE).Trim()
        $sysName   = ([string]$LLDPNeighbor.NEIGHBOR_NAME).Trim()

        # Only populate fields required by Create-LLDPNeighborObject()
        $LLDPObject.InterfaceLocalDevice = Replace-InterfaceShortName -string $localIf
        $LLDPObject.ChassisID            = $chassisId
        $LLDPObject.Hostname             = $sysName

        # For table format we usually only have Port-ID + Port-Desc, not mgmt IP / capabilities / sys desc
        $LLDPObject.InterfaceRemoteDevice        = Replace-InterfaceShortName -string $portId
        $LLDPObject.PortID                       = $portId
        $LLDPObject.NeighborInterfaceDescription = $portDesc

        $LLDPObject.ParentObject = $Device.hostname

        if ([string]::IsNullOrEmpty($LLDPObject.Hostname)) {
            $LLDPObject.Hostname = $LLDPObject.ChassisID
        }

        # Mark the local interface as having an LLDP neighbor
        $TempInterface = $Device.interfaces | Where-Object { $_.interface -eq $LLDPObject.InterfaceLocalDevice }
        if ($TempInterface) {
            $TempInterface.HasLLDPNeighbor = $true
            if ($TempInterface.HasCPDNieghbor) {
                $LLDPObject.HasCDPNeighborEntry = $true
            }
        }

        $AllLLDPObjects += $LLDPObject
    }

    $Device.LLDPNeighbors = $AllLLDPObjects | Sort-Object -Property @{
        Expression = { [int](($_.InterfaceLocalDevice -replace '[a-zA-Z-]+', '' -replace "/", '') ) }
    }

}


# Parses an Aruba 'show lldp neighbors detail' capture to enrich the device's LLDP neighbours with detail fields (system description, management address, chassis id). Logs a warning and returns the device unchanged on invalid/empty input.
function Update-ArubaLldpNeighborDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowLLDPNeighborsDetails')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'aruba_aoscx_show_lldp_neighbors-info_detail' -Path $Path
    if (@($rows).Count -eq 0) { return }

    $AllLLDPDetailsObjects = @()

    foreach ($LLDPNeighbor in $rows) {
        # Expected output order from your TextFSM:
        # 0 LOCAL_INTERFACE
        # 1 CHASSIS_ID
        # 2 NEIGHBOR_NAME
        # 3 NEIGHBOR_DESCRIPTION
        # 4 CAPABILITIES_SUPPORTED
        # 5 CAPABILITIES
        # 6 MGMT_ADDRESS
        # 7 NEIGHBOR_PORT_ID
        # 8 NEIGHBOR_INTERFACE (Port-Desc)

        if ($GSkipCDPLLDPPhones) {
            $desc = [string]$LLDPNeighbor.NEIGHBOR_DESCRIPTION
            if ($desc -like "*Phone*" -or $desc -like "*Endpoint*") {
                continue
            }
        }

        $LLDPObject = Create-LLDPNeighborObject

        # Only populate fields required by Create-LLDPNeighborObject()
        $LLDPObject.InterfaceLocalDevice = Replace-InterfaceShortName -string (([string]$LLDPNeighbor.LOCAL_INTERFACE).Trim())
        $LLDPObject.ChassisID            = ([string]$LLDPNeighbor.CHASSIS_ID).Trim()
        $LLDPObject.Hostname             = ([string]$LLDPNeighbor.NEIGHBOR_NAME).Trim()
        $LLDPObject.SystemDescription    = ([string]$LLDPNeighbor.NEIGHBOR_DESCRIPTION).Trim()
        $LLDPObject.Capabilities         = ([string]$LLDPNeighbor.CAPABILITIES).Trim()
        $LLDPObject.ManagementIP         = ([string]$LLDPNeighbor.MGMT_ADDRESS).Trim()

        $remotePortIdRaw = ([string]$LLDPNeighbor.NEIGHBOR_PORT_ID).Trim()
        $LLDPObject.InterfaceRemoteDevice        = Replace-InterfaceShortName -string $remotePortIdRaw
        $LLDPObject.PortID                       = $remotePortIdRaw
        $LLDPObject.NeighborInterfaceDescription = ([string]$LLDPNeighbor.NEIGHBOR_INTERFACE).Trim()

        $LLDPObject.ParentObject = $Device.hostname

        if ([string]::IsNullOrEmpty($LLDPObject.Hostname)) {
            $LLDPObject.Hostname = $LLDPObject.ChassisID
        }

        $TempInterface = $Device.interfaces | Where-Object { $_.interface -eq $LLDPObject.InterfaceLocalDevice }
        if ($TempInterface) {
            $TempInterface.HasLLDPNeighbor = $true
            if ($TempInterface.HasCPDNieghbor) {
                $LLDPObject.HasCDPNeighborEntry = $true
            }
        }

        $AllLLDPDetailsObjects += $LLDPObject
    }

    $Device.LLDPNeighbors = $AllLLDPDetailsObjects | Sort-Object -Property @{
        Expression = { [int](($_.InterfaceLocalDevice -replace '[a-zA-Z-]+', '' -replace "/", '') ) }
    }

}

# Process an ArubaOS-CX "show running-config" / "show configuration" blob.
# Extract only generic config-driven data (avoid anything you will later parse via TextFSM sections).
function Update-ArubaRunningConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowRun')) { return }

    # --- EXTRACT ---
    $Lconfig = Get-MTAutoDrawCaptureText -Path $Path
    $HostObject = $Device

    # Hostname
    $hostname = Get-RegexGroupValue -InputText $Lconfig -Pattern '(?m)^\s*hostname\s+(.+?)\s*$'
    if ($null -eq $hostname -or $hostname -eq "") {
        $hostname = "NoHostNameFoundCheckForConfigProblems"
    }
    $HostObject.hostname = $hostname

    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $HostObject -Message "New-ArubaDeviceFromShowRun : Parsed hostname='$($HostObject.hostname)'"

    # Version
    $version = Get-RegexGroupValue -InputText $Lconfig -Pattern '(?m)^\s*!Version\s+(.+?)\s*$'
    if ($null -eq $version -or $version -eq "") {
        $version = Get-RegexGroupValue -InputText $Lconfig -Pattern '(?m)^\s*Version\s+(.+?)\s*$'
    }
    if ($version) {
        $HostObject.Version = $version
        Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $HostObject -Message "New-ArubaDeviceFromShowRun : Parsed Version='$($HostObject.Version)'"
    }
    else {
        Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $HostObject -Message "New-ArubaDeviceFromShowRun : No version found in config"
    }

    # Spanning-tree
    $HostObject.SpanningTree = Create-SpanningTreeObject
    if (($Lconfig | Select-String -Pattern '(?m)^\s*spanning-tree\s*$').Matches.Success) {
        $HostObject.SpanningTree.SpanningTreeMode = "enabled"
    }

    # VLANs
    $AllVlans = ($Lconfig | Select-String -Pattern '(?smi)^\s*vlan\s+\d+.*?(?=^\s*(vlan\s+\d+|interface\s+|router\s+|vsx\s*$|spanning-tree\s*$|!|\Z))' -AllMatches).Matches.Value

    $vlans = @()
    foreach ($vlanBlock in $AllVlans) {

        $vlanObject = Create-VlanObject

        $vlanNumber = Get-RegexGroupValue -InputText $vlanBlock -Pattern '(?m)^\s*vlan\s+(\d+)\s*$'
        if (-not $vlanNumber) { continue }

        $vlanObject.number = $vlanNumber

        $vlanName = Get-RegexGroupValue -InputText $vlanBlock -Pattern '(?m)^\s*name\s+(.+?)\s*$'
        $vlanObject.name = if ($vlanName) { $vlanName } else { "No name" }

        $vlans += $vlanObject
    }

    $HostObject.vlans = $vlans

    # BGP AS
    $bgpAs = Get-RegexGroupValue -InputText $Lconfig -Pattern '(?m)^\s*router\s+bgp\s+(\d+)\s*$'
    if ($bgpAs) {
        $HostObject.BGP_AS_Number = $bgpAs
    }

    # OSPF Router-ID
    $OspfSection = ($Lconfig | Select-String -Pattern '(?smi)^\s*router\s+ospf\s+\d+.*?(?=^!|^\S|\Z)' -AllMatches).Matches.Value
    if ($OspfSection) {
        $OspfRouterId = Get-RegexGroupValue -InputText $OspfSection -Pattern '(?m)^\s*router-id\s+(\d+(?:\.\d+){3})\s*$'
        if ($OspfRouterId) {
            $HostObject | Add-Member -MemberType NoteProperty -Name "OSPF_RouterId" -Value $OspfRouterId -Force
        }
    }

    # BGP Router-ID
    $BgpSection = ($Lconfig | Select-String -Pattern '(?smi)^\s*router\s+bgp\s+\d+.*?(?=^!|^\S|\Z)' -AllMatches).Matches.Value
    if ($BgpSection) {
        $BgpRouterId = Get-RegexGroupValue -InputText $BgpSection -Pattern '(?m)^\s*bgp\s+router-id\s+(\d+(?:\.\d+){3})\s*$'
        if ($BgpRouterId) {
            $HostObject | Add-Member -MemberType NoteProperty -Name "BGP_RouterId" -Value $BgpRouterId -Force
        }
    }

    # VSX
    $VsxSection = ($Lconfig | Select-String -Pattern '(?smi)^\s*vsx\s*$.*?(?=^!|^\S|\Z)' -AllMatches).Matches.Value
    if ($VsxSection) {

        $vsx = [PSCustomObject]@{
            Role            = Get-RegexGroupValue -InputText $VsxSection -Pattern '(?m)^\s*role\s+(\S+)\s*$'
            InterSwitchLink = Get-RegexGroupValue -InputText $VsxSection -Pattern '(?m)^\s*inter-switch-link\s+lag\s+(\d+)\s*$'
            KeepalivePeer   = Get-RegexGroupValue -InputText $VsxSection -Pattern '(?m)^\s*keepalive\s+peer\s+(\d+(?:\.\d+){3})\s+source\s+\d+(?:\.\d+){3}\s*$'
            KeepaliveSource = Get-RegexGroupValue -InputText $VsxSection -Pattern '(?m)^\s*keepalive\s+peer\s+\d+(?:\.\d+){3}\s+source\s+(\d+(?:\.\d+){3})\s*$'
        }

        $HostObject | Add-Member -MemberType NoteProperty -Name "VSX" -Value $vsx -Force
    }

    # Interfaces
    $AllInterfaces = ($Lconfig | Select-String -Pattern '(?smi)^\s*interface\s+.+?(?=^\s*interface\s+|\Z)' -AllMatches).Matches.Value

    # The interface parser accepts the extracted configuration blocks directly.
    $HostObject.interfaces = Get-ArubaInterfacesFromConfigText -HostObject $HostObject -AllInterfaces $AllInterfaces
}


# Parse ArubaOS-CX interface blocks from running config
function Get-ArubaInterfacesFromConfigText {
    param (
        [parameter(Mandatory = $true)]
        $AllInterfaces,
        $HostObject
    )
    
    $interfaces = @()
    
    foreach ($interfaceBlock in $AllInterfaces) {
        $Interface = Create-InterfaceObject
        
        # Interface name
        $ifName = Get-RegexGroupValue -InputText $interfaceBlock -Pattern '(?m)^\s*interface\s+(.+?)\s*$'
        if (-not $ifName) { continue }

        # STRATEGIC FIX: Normalize spaces in 'lag 1', 'loopback 0', 'vlan 30' to match FSM output
        $ifName = $ifName -replace '(?i)^(lag|loopback|vlan)\s+(\d+)$', '$1$2'

        $Interface.Interface = $ifName
        
        # Detect Routed VLAN interface (SVI)
        if ($ifName -match '(?i)^vlan\s*(\d+)$') {
            $Interface.RoutedVlan = $Matches[1]
            $Interface.SwitchPortType = "Routed"
        }
        
        # Description
        $desc = Get-RegexGroupValue -InputText $interfaceBlock -Pattern '(?m)^\s*description\s+(.+?)\s*$'
        if ($desc) {
            $Interface.Description = $desc
        }
        
        # Shutdown
        if ($interfaceBlock -match '(?m)^\s*shutdown\s*$') {
            $Interface.shutdown = $true
        }
        else {
            $Interface.shutdown = $false
        }
        
        # VRF attach
        $vrf = Get-RegexGroupValue -InputText $interfaceBlock -Pattern '(?m)^\s*vrf\s+attach\s+(\S+)\s*$'
        if ($vrf) {
            $Interface.vrf = $vrf
        }
        
        # Primary IPv4 address
        $ipCidr = Get-RegexGroupValue -InputText $interfaceBlock -Pattern '(?m)^\s*ip\s+address\s+(\d+\.\d+\.\d+\.\d+\/\d+)\s*$'
        if ($ipCidr) {
            $Interface.IPAddress   = $ipCidr -replace '\/.*', ''
            $Interface.SubnetMask  = $ipCidr -replace '.*\/', ''
            if ($Interface.IPAddress -and $Interface.SubnetMask) {
                $Interface.Cidr = (Get-IPv4Subnet -IPAddress $Interface.IPAddress -PrefixLength $Interface.SubnetMask).cidrid
                $Interface.SwitchPortType = "Routed"
            }
        }
        
        # Secondary IPv4
        $secondaryCidr = Get-RegexGroupValue -InputText $interfaceBlock -Pattern '(?m)^\s*ip\s+address\s+(\d+\.\d+\.\d+\.\d+\/\d+)\s+secondary\s*$'
        if ($secondaryCidr) {
            $Interface.SecondaryIPAddress  = $secondaryCidr -replace '\/.*', ''
            $Interface.SecondarySubnetMask = $secondaryCidr -replace '.*\/', ''
            if ($Interface.SecondaryIPAddress -and $Interface.SecondarySubnetMask) {
                $Interface.SecondaryCidr = (Get-IPv4Subnet -IPAddress $Interface.SecondaryIPAddress -PrefixLength $Interface.SecondarySubnetMask).cidrid
            }
        }
        
        # no routing (L2 interface)
        if ($interfaceBlock -match '(?m)^\s*no\s+routing\s*$') {
            $Interface.SwitchPortType = "Switched"
        }
        
        # Access VLAN
        $accessVlan = Get-RegexGroupValue -InputText $interfaceBlock -Pattern '(?m)^\s*vlan\s+access\s+(\d+)\s*$'
        if ($accessVlan) {
            $Interface.SwitchportMode = "access"
            $Interface.SwitchportAccessVlan = $accessVlan
            $Interface.SwitchPortType = "Switched"
        }
        
        # Trunk Native VLAN
        $nativeVlan = Get-RegexGroupValue -InputText $interfaceBlock -Pattern '(?m)^\s*vlan\s+trunk\s+native\s+(\d+)\s*$'
        if ($nativeVlan) {
            $Interface.SwitchportMode = "trunk"
            $Interface.NativeVlan = $nativeVlan
            $Interface.SwitchPortType = "Switched"
        }
        
        # Trunk Allowed VLANs
        $trunkAllowed = Get-RegexGroupValue -InputText $interfaceBlock -Pattern '(?m)^\s*vlan\s+trunk\s+allowed\s+(.+?)\s*$'
        if ($trunkAllowed) {
            $Interface.SwitchportMode = "trunk"
            $Interface.SwitchportTrunkVlan = $trunkAllowed
            $Interface.SwitchPortType = "Switched"
        }
        
        # Channel group membership (physical ports)
        $lagMember = Get-RegexGroupValue -InputText $interfaceBlock -Pattern '(?m)^\s*lag\s+(\d+)\s*$'
        if ($lagMember) {
            $Interface.ChannelGroup = $lagMember
        }
        
        # LACP mode (LAG interfaces)
        $lagMode = Get-RegexGroupValue -InputText $interfaceBlock -Pattern '(?m)^\s*lacp\s+mode\s+(\S+)\s*$'
        if ($lagMode) {
            $Interface.ChannelGroupMode = $lagMode
        }
        
        # Spanning-tree port type
        $stPortType = Get-RegexGroupValue -InputText $interfaceBlock -Pattern '(?m)^\s*spanning-tree\s+port-type\s+(.+?)\s*$'
        if ($stPortType) {
            $Interface.SpanningTreePortType = $stPortType
        }
        
        # BPDU guard
        if ($interfaceBlock -match '(?m)^\s*spanning-tree\s+bpdu-guard\s*$') {
            $Interface.bpdufilter = $true
        }
        
        $interfaces += $Interface
    }
     
    return $interfaces
}









#Process the ArubaOS-CX show interfaces file and update existing interfaces created from show run.
function Update-ArubaInterfaces {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowInterface')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'aruba_aoscx_show_interface' -Path $Path
    if (@($rows).Count -eq 0) { return }

    $updatedCount = 0
    
    foreach ($int in $rows) {
        
        $ifName = Replace-InterfaceShortName -string $int.INTERFACE

        $Interface = $Device.interfaces | Where-Object { $_.Interface -eq $ifName } | Select-Object -First 1

        if (!($Interface)) {
            # Create new interface object
            $Interface = Create-InterfaceObject
            $Interface.Interface = $ifName

            # Add to device
            $Device.interfaces += $Interface
        }

        $updatedCount++

        # Status
        $linkStatus = $int.LINK_STATUS
        $adminState = $int.LINK_ADMIN
        $stateInfo  = $int.LINK_STATE_INFO

        if ($linkStatus) {
            if (($linkStatus | Select-String "xcvrAbsen|sfpAbsent").Matches.Success) {
                $Interface.IntStatus = "xcvrAbsen"
            } else {
                $Interface.IntStatus = $linkStatus -replace "\s*\(.*", ''
            }
            $Interface.INTProtocolStatus = $Interface.IntStatus
        }

        if ($adminState -eq "down" -or ($stateInfo -and $stateInfo -match "Administratively down")) {
            $Interface.shutdown = $true
        }
        elseif ($adminState -eq "up") {
            $Interface.shutdown = $false
        }

        # Description
        if ($int.INTERFACE_DESC -and $int.INTERFACE_DESC.Trim() -ne "") {
            $Interface.Description = $int.INTERFACE_DESC.Trim()
        }

        # Hardware / MAC / Duplex / Speed
        if ($int.HW_TYPE) { $Interface.HardwareType = $int.HW_TYPE }
        if ($int.MAC_ADDRESS) { $Interface.macaddress   = $int.MAC_ADDRESS }
        if ($int.DUPLEX) { $Interface.Duplex      = $int.DUPLEX }

        if ($int.SPEED) {
            $speed = $int.SPEED.Trim()
            if ($speed -match '^(?<n>\d+)\s*Mb/s$') {
                $Interface.Speed = "$($Matches.n)Mb/s"
            }
            elseif ($speed -match '^(?<n>\d+)\s*Gb/s$') {
                $Interface.Speed = "$($Matches.n)Gb/s"
            }
            else {
                $Interface.Speed = $speed
            }
        }

        if ($int.IF_TYPE -and $int.IF_TYPE.Trim() -ne "" -and $int.IF_TYPE.Trim() -ne "--") {
            $Interface.MediaType = $int.IF_TYPE.Trim()
        }

        if ($int.IP_ADDRESS -and $int.IP_ADDRESS.Trim() -ne "" -and $int.IP_ADDRESS.Trim() -ne "n/a") {
            $ipCidr = $int.IP_ADDRESS.Trim()
            $Interface.IPAddress   = $ipCidr -replace "\/.*", ''
            $Interface.SubnetMask  = $ipCidr -replace ".*\/", ''
            
            if ($Interface.IPAddress -and $Interface.SubnetMask) {
                $Interface.Cidr = (Get-IPv4Subnet -IPAddress $Interface.IPAddress -PrefixLength $Interface.SubnetMask).cidrid
                $Interface.SwitchPortType = "Routed"
                if (-not $Interface.RoutedVlan) {
                    $Interface.RoutedVlan = $true
                }
            }
        }

        if ($int.VLAN_MODE) {
            $vlanMode = $int.VLAN_MODE.Trim().ToLower()

            if ($vlanMode -eq "access") {
                $Interface.SwitchportMode = "access"
                $Interface.SwitchPortType = "Switched"
                if ($int.VLAN_ACCESS -and $int.VLAN_ACCESS.Trim() -ne "") {
                    $Interface.SwitchportAccessVlan = $int.VLAN_ACCESS.Trim()
                }
            }
            elseif ($vlanMode -eq "trunk") {
                $Interface.SwitchportMode = "trunk"
                $Interface.SwitchPortType = "Switched"

                if ($int.VLAN_NATIVE -and $int.VLAN_NATIVE.Trim() -ne "") {
                    $Interface.NativeVlan = $int.VLAN_NATIVE.Trim()
                }

                $trunks = $int.VLAN_TRUNK
                if ($trunks) {
                    if ($trunks -is [System.Collections.IEnumerable] -and !($trunks -is [string])) {
                        $Interface.SwitchportTrunkVlan = (($trunks | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne "" }) -join ",")
                    }
                    else {
                        $Interface.SwitchportTrunkVlan = $trunks.ToString().Trim()
                    }
                }
            }
        }

        $aggList = $int.AGGREGATED_INTERFACES
        if ($aggList) {
            $aggItems = @()
            if ($aggList -is [System.Collections.IEnumerable] -and !($aggList -is [string])) {
                $aggItems = @($aggList | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne "" })
            }
            else {
                $aggItems = @($aggList.ToString().Trim())
            }

            foreach ($agg in $aggItems) {
                if ($agg -match '(?i)\blag\s*(\d+)\b') {
                    $Interface.ChannelGroup = $Matches[1]
                }
            }

            if ($ifName -match '(?i)^(lag)\s*(\d+)$') {
                $lagNumber = $Matches[2]

                foreach ($member in $aggItems) {
                    $memberInterface = $Device.interfaces | Where-Object { $_.Interface -eq $member }
                    if ($memberInterface) {
                        $memberInterface.ChannelGroup = $lagNumber
                    }
                    else {
                        Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "Update-ArubaInterfaces: Member '$member' not found in show run interfaces"
                    }
                }
            }
        }
    }
    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Update-ArubaInterfaces: END updatedCount=$updatedCount"
}

#Process ArubaOS-CX "show version" output using regex (no TextFSM template for OS-CX).
function Update-ArubaVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowVersion')) { return }

    # --- EXTRACT ---
    $ShowVersionText = Get-MTAutoDrawCaptureText -Path $Path

    $VersionObject = Create-ShowVersionObject
    $VersionObject.Type = "ArubaOS-CX"

    # Detect OS banner if present
    if ($ShowVersionText -match '(?m)^\s*ArubaOS-CX\s*$') {
        $VersionObject.OS = "ArubaOS-CX"
    }

    # Version line: "Version      : Virtual.10.13.0005"
    $m = [regex]::Match($ShowVersionText, '(?m)^\s*Version\s*:\s*(?<v>.+?)\s*$')
    if ($m.Success) {
        $ver = $m.Groups['v'].Value.Trim()
        if (-not [string]::IsNullOrWhiteSpace($ver)) {
            $VersionObject.Image = $ver
        }
    }

    # Uptime (not in your sample, but harmless if present in other variants)
    $m = [regex]::Match($ShowVersionText, '(?m)^\s*(Uptime|Up Time)\s*:\s*(?<u>.+?)\s*$')
    if ($m.Success) {
        $up = $m.Groups['u'].Value.Trim()
        if (-not [string]::IsNullOrWhiteSpace($up)) {
            $VersionObject.Uptime = $up
        }
    }

    # Hardware / Model (not in your sample, but common in other outputs)
    $hw = $null

    $m = [regex]::Match($ShowVersionText, '(?m)^\s*(Model|Product\s+Name|Platform)\s*:\s*(?<h>.+?)\s*$')
    if ($m.Success) {
        $hw = $m.Groups['h'].Value.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($hw)) {
        $VersionObject.Hardware = @($hw)
    }

    # Serial number (optional)
    $ser = $null
    $m = [regex]::Match($ShowVersionText, '(?m)^\s*(Serial(\s+Number)?|Chassis\s+Serial(\s+Number)?)\s*:\s*(?<s>\S+)\s*$')
    if ($m.Success) {
        $ser = $m.Groups['s'].Value.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($ser)) {
        $VersionObject.Serial = @($ser)
    }

    # System MAC (optional)
    $mac = $null
    $m = [regex]::Match($ShowVersionText, '(?m)^\s*(System\s+MAC|Base\s+MAC|MAC(\s+Address)?)\s*:\s*(?<m>[0-9A-Fa-f:\.-]{11,})\s*$')
    if ($m.Success) {
        $mac = $m.Groups['m'].Value.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($mac)) {
        $VersionObject.MacAddressArray = @($mac)
    }

    # Final assignment (no new properties created)
    $Device.Version = $VersionObject

    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Update-ArubaVersion: Parsed Type='$($VersionObject.Type)' OS='$($VersionObject.OS)' Image='$($VersionObject.Image)' HardwareCount=$(@($VersionObject.Hardware).Count) SerialCount=$(@($VersionObject.Serial).Count) MacCount=$(@($VersionObject.MacAddressArray).Count)"
    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Update-ArubaVersion: END"
}




# Parses an Aruba 'show ip arp' capture into the device's ARP entries, resolving each to its interface. Logs a warning and returns the device unchanged if the capture is invalid or empty.
function Update-ArubaArp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowIPArp')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'aruba_aoscx_show_arp_all-vrfs' -Path $Path
    if (@($rows).Count -eq 0) { return }

    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Update-ArubaArp: Building subnet lookup from interfaces"
    $subnetLookup = @{}
    $Device.interfaces | Where-Object { $_.Cidr } | ForEach-Object { $subnetLookup[$_.Cidr] = $true }
    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Update-ArubaArp: subnetLookupCount=$($subnetLookup.Count)"

    $builtCount = 0
    $Device.IPArpEntries = foreach ($entry in $rows) {

        $IPArpObject = Create-ShowIPArpObject

        $IPArpObject.PROTOCOL  = "IPv4"
        $IPArpObject.ipaddress = $entry.IP_ADDRESS.Trim()
        $IPArpObject.MAC       = $entry.MAC_ADDRESS.Trim()

        $physicalPort = $entry.PHYSICAL_PORT.Trim()
        $portId       = $entry.PORT_ID.Trim()

        if ($physicalPort -ne "") {
            $IPArpObject.INTERFACE = $physicalPort
        }
        elseif ($portId -ne "") {
            $IPArpObject.INTERFACE = $portId
        }

        $state = $entry.STATE.Trim()
        if ($state -ne "") {
            $IPArpObject.TYPE = $state
        }

        $MacInOtherFormat = $IPArpObject.MAC
        if ($MacInOtherFormat -and $MacInOtherFormat.Length -ge 8) {
            if ($GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,8)]) {
                $IPArpObject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,8)]
            }
            elseif ($MacInOtherFormat.Length -ge 5 -and $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,5)]) {
                $IPArpObject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0,5)]
            }
            else {
                $IPArpObject.VendorCompanyName = "UNKNOWN Vendor"
            }
        }
        else {
            $IPArpObject.VendorCompanyName = "UNKNOWN Vendor"
        }

        for ($prefix = 32; $prefix -ge 1; $prefix--) {
            $candidateCidr = (Get-IPv4Subnet -IPAddress $IPArpObject.ipaddress -PrefixLength $prefix).CIDRId
            if ($subnetLookup.ContainsKey($candidateCidr)) {
                $IPArpObject.cidr = $candidateCidr
                break
            }
        }

        $builtCount++
        if (($builtCount % 50) -eq 0) {
            Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Update-ArubaArp: Built ARP entries so far=$builtCount"
        }

        $IPArpObject
    }

    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Update-ArubaArp: END builtCount=$builtCount"
}





# Parses an Aruba 'show ip route' capture into the device's routing table (code, subnet, gateway, interface). Logs a warning and returns the device unchanged if the capture is invalid or empty.
function Update-ArubaRoutes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowIPRoute')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'aruba_aoscx_show_ip_route' -Path $Path
    if (@($rows).Count -eq 0) { return }

    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Update-ArubaRoutes : Building ActiveInterfaces cache"
    $ActiveInterfaces = $Device.interfaces | Where-Object { $_.cidr -and $_.IntStatus -ne "down" }
    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Update-ArubaRoutes : ActiveInterfaces count=$(@($ActiveInterfaces).Count)"

    $routeRecordCount = 0
    $routeObjectCount = 0

    $AllRouteObjects = foreach ($route in $rows) {

        $routeRecordCount++

        $vrf             = $route.VRF
        $subnet          = $route.PREFIX
        $nexthop         = $route.NEXTHOP
        $interface       = $route.INTERFACE
        $origin_type     = $route.ORIGIN_TYPE
        $distance_metric = $route.DISTANCE_METRIC

        

        $RouteObject = Create-RouteObject
        $RouteObject.Subnet = $subnet
        $RouteObject.VRF = $vrf
        $RouteObject.RouteProtocol = $origin_type

        # Parse distance/metric, e.g., [110/20]
        if ($distance_metric -match '^\[(\d+)\/(\d+)\]$') {
            $RouteObject.DISTANCE = $Matches[1]
            $RouteObject.METRIC   = $Matches[2]
        } elseif ($distance_metric -ne '-') {
            $RouteObject.METRIC = $distance_metric
        }

       

        # Handle Gateway vs Directly Connected Routes
        if ($nexthop -match '^\d+\.\d+\.\d+\.\d+$') {
            $RouteObject.gateway = $nexthop
            $RouteObject.interface = $interface
            
            # The traditional attempt to validate the interface out using subnet math
            foreach ($intf in $ActiveInterfaces) {
                if ((Find-Subnet -addr1 $intf.cidr -addr2 $RouteObject.gateway).condition) {
                    $RouteObject.interface = $intf.Interface
                    break
                }
            }
            
        }
        else {
            # Nexthop is a hyphen (e.g. connected or local route), use the interface column directly
            $RouteObject.interface = $interface
        }

        if ($RouteObject.Subnet -eq "0.0.0.0/0") {
            $RouteObject.defaultgateway = $true
        }

        $routeObjectCount++
        $RouteObject
    }

    $Device.RoutingTable = $AllRouteObjects
    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Update-ArubaRoutes : END routeRecordCount=$routeRecordCount routeObjectCount=$routeObjectCount"
}

# Parses an Aruba 'show spanning-tree details' capture into the device's spanning-tree object (root bridge, priority, per-VLAN interface state). Logs a warning and returns the device unchanged if the file is missing or invalid.
function Update-ArubaSpanningTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowSpanningTreeDetails')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'aruba_aoscx_show_spanning-tree_detail' -Path $Path
    if (@($rows).Count -eq 0) { return }

    $Rows = @($rows)

    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Update-ArubaSpanningTree : Raw row count=$(@($Rows).Count)"

    # The template's Filldown values repeat the instance header on every port row, so the instance
    # fields are read off the first row of each group and the port fields off every row.
    $First = $Rows | Select-Object -First 1
    if ($First -and $First.PROTOCOL) {
        $Device.SpanningTree.SpanningTreeMode = $First.PROTOCOL
    }

    $Groups = $Rows | Group-Object -Property { $_.INSTANCE }

    foreach ($G in $Groups) {
        if (-not $G.Name) { continue }

        $InstanceRows = @($G.Group)
        $Head = $InstanceRows | Select-Object -First 1

        $StInstance = Create-SpanningTreeVlan
        $StInstance.VlanID = $G.Name
        $StInstance.protocol = $Head.PROTOCOL

        # Root bridge fields
        if ($Head.ROOT_PRIORITY) { $StInstance.RootIDPriority = [int]$Head.ROOT_PRIORITY }
        if ($Head.ROOT_MAC)      { $StInstance.Address = ConvertTo-NormalizedMacAddress $Head.ROOT_MAC }
        if ($Head.ROOT_HELLO)    { $StInstance.RootBridgeHelloTime = [int]$Head.ROOT_HELLO }

        # ROOT_SELF only matches when the capture says "This bridge is the root".
        $StInstance.RootBridge = -not [string]::IsNullOrWhiteSpace([string]$Head.ROOT_SELF)

        # Local bridge fields
        if ($Head.BRIDGE_PRIORITY) { $StInstance.BridgeIDPriority = [int]$Head.BRIDGE_PRIORITY }
        if ($Head.BRIDGE_MAC)      { $StInstance.BridgeIDPriorityaddress = ConvertTo-NormalizedMacAddress $Head.BRIDGE_MAC }
        if ($Head.BRIDGE_HELLO)    { $StInstance.BridgeIDPriorityHelloTime = [int]$Head.BRIDGE_HELLO }

        if (-not $StInstance.SpanningTreeInterfaces) {
            $StInstance.SpanningTreeInterfaces = @()
        }
        elseif ($StInstance.SpanningTreeInterfaces -isnot [System.Collections.IList]) {
            $StInstance.SpanningTreeInterfaces = @($StInstance.SpanningTreeInterfaces)
        }

        # Port table -> SpanningTreeInterfaces
        foreach ($R in $InstanceRows) {
            if (-not $R -or [string]::IsNullOrWhiteSpace([string]$R.PORT)) { continue }

            $If = Create-SpanningTreeInterface
            $If.Interface = $R.PORT
            $If.Role      = $R.ROLE
            $If.Status    = $R.STATE

            if ($R.COST)     { $If.Cost = [int]$R.COST }
            if ($R.PRIORITY) { $If.PrioNbr = [int]$R.PRIORITY }
            if ($R.TYPE)     { $If.Type = ([string]$R.TYPE).Trim() }

            $StInstance.SpanningTreeInterfaces += $If
        }

        # Add to device spanning-tree collection
        $Device.SpanningTree.SpanningTreeArray += $StInstance

        if ($StInstance.RootBridge -eq $true) {
            $Device.SpanningTree.RootBridgeForVlans += $StInstance.VlanID
        }
    }

    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Update-ArubaSpanningTree : Parsed instances $(@($Device.SpanningTree.SpanningTreeArray).Count)"
}


# Parses an Aruba 'show interfaces brief' capture to set per-interface admin/oper status and description on the device's interface objects. Logs a warning and returns the device unchanged if the file is missing or invalid.
function Update-ArubaInterfaceBrief {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (@($Device.interfaces | Where-Object IntStatus).Count -gt 0) { return }   # 'show interface' is richer
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowInterfaceBrief')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'aruba_aoscx_show_ip_interface_brief' -Path $Path
    if (@($rows).Count -eq 0) { return }

    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Update-ArubaInterfaceBrief: Raw records count=$(@($rows).Count)"

    $updatedCount = 0
    $createdCount = 0

    foreach ($row in $rows) {

        if (-not $row) { continue }

        $port     = ([string]$row.PORT).Trim()
        if ([string]::IsNullOrWhiteSpace($port)) { continue }

        $native   = ([string]$row.NATIVE_VLAN).Trim()
        $mode     = ([string]$row.MODE).Trim()
        $type     = ([string]$row.TYPE).Trim()
        $enabled  = ([string]$row.ENABLED).Trim()
        $status   = ([string]$row.STATUS).Trim()
        $reason   = ([string]$row.REASON).Trim()
        $speedRaw = ([string]$row.SPEED).Trim()
        $descRaw  = ([string]$row.DESCRIPTION).Trim()

        $ifName = Replace-InterfaceShortName -string $port

        $createdThisRecord = $false
        $Interface = $Device.interfaces | Where-Object { $_.Interface -eq $ifName } | Select-Object -First 1

        if (-not $Interface) {
            $Interface = Create-InterfaceObject
            $Interface.Interface = $ifName
            $Device.interfaces += $Interface
            $createdCount++
            $createdThisRecord = $true
        }

        $updatedCount++

        # Determine "down / shut" based on the brief output
        $parsedIsDown = $false
        if ($status -and $status.ToLower() -eq "down") { $parsedIsDown = $true }
        if ($enabled -and $enabled.ToLower() -eq "no") { $parsedIsDown = $true }
        if ($reason -match '(?i)Administratively\s+down') { $parsedIsDown = $true }
        if ($reason -match '(?i)No\s+XCVR\s+installed') { $parsedIsDown = $true }

        # Status fields
        if ($status) {
            $Interface.IntStatus = $status
            $Interface.INTProtocolStatus = $status
        }

        # No transceiver marker (match your other Aruba behavior)
        if ($reason -match '(?i)No\s+XCVR\s+installed') {
            $Interface.IntStatus = "xcvrAbsen"
            $Interface.INTProtocolStatus = "xcvrAbsen"
        }

        # Requirement:
        # If we CREATED the interface here and it is down or no-xcvr, force shutdown + down.
        if ($createdThisRecord -and $parsedIsDown) {
            $Interface.shutdown = $true

            if (($Interface.IntStatus -eq "up") -or [string]::IsNullOrWhiteSpace($Interface.IntStatus)) {
                $Interface.IntStatus = "down"
                $Interface.INTProtocolStatus = "down"
            }
        }
        else {
            # For existing interfaces, only mark shutdown when admin says so
            if ($enabled -and $enabled.ToLower() -eq "no") {
                $Interface.shutdown = $true
            }
            elseif ($reason -match '(?i)Administratively\s+down') {
                $Interface.shutdown = $true
            }
        }

        # Speed is Mb/s in this output
        if ($speedRaw -and $speedRaw -ne "--") {
            $Interface.Speed = "$speedRaw" + "Mb/s"
        }

        # Description
        if ($descRaw -and $descRaw -ne "--") {
            $Interface.Description = $descRaw
        }

        # Switchport mode + VLAN hints
        $modeLower = $mode.ToLower()

        if ($modeLower -eq "trunk") {
            $Interface.SwitchportMode = "trunk"
            $Interface.SwitchPortType = "Switched"

            if ($native -and $native -ne "--") {
                $Interface.NativeVlan = $native
            }
        }
        elseif ($modeLower -eq "access") {
            $Interface.SwitchportMode = "access"
            $Interface.SwitchPortType = "Switched"

            if ($native -and $native -ne "--") {
                $Interface.SwitchportAccessVlan = $native
            }
        }
        elseif ($modeLower -eq "routed") {
            $Interface.SwitchPortType = "Routed"

            if ($ifName -match '(?i)^vlan\s*(\d+)$') {
                $Interface.RoutedVlan = $Matches[1]
            }
            elseif ($ifName -match '(?i)^vlan(\d+)$') {
                $Interface.RoutedVlan = $Matches[1]
            }
            else {
                if (-not $Interface.RoutedVlan) {
                    $Interface.RoutedVlan = $true
                }
            }
        }
        else {
            if (-not [string]::IsNullOrWhiteSpace($mode)) {
                $Interface.SwitchportMode = $modeLower
            }
        }

        # Type column is usually "--"; store if meaningful
        if ($type -and $type -ne "--") {
            $Interface.MediaType = $type
        }
    }

    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Update-ArubaInterfaceBrief: END updatedCount=$updatedCount createdCount=$createdCount"
}




# Process the ArubaOS-CX "show mac-address-table" file
function Update-ArubaMacAddressTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowMacAddressTable')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'aruba_aoscx_show_mac-address-table' -Path $Path
    if (@($rows).Count -eq 0) { return }

    $addedCount = 0
    foreach ($MacRow in $rows) {
        $mac  = ([string]$MacRow.MAC_ADDRESS).Trim()
        $vlan = ([string]$MacRow.VLAN_ID).Trim()
        $type = ([string]$MacRow.TYPE).Trim()
        $port = ([string]$MacRow.PORT).Trim()

        if ([string]::IsNullOrWhiteSpace($port)) { continue }
        if ($port -in @("CPU","Router","Switch")) { continue }

        $MacAddressobject = Create-MacAddressObject
        $MacAddressobject.Interface = (Replace-InterfaceShortName -string $port)

        if (!(Check-InterfaceType -string $MacAddressobject.Interface)) {
            continue
        }

        $MacAddressobject.MacAddress = $mac
        $MacAddressobject.type = $type
        $MacAddressobject.vlan = $vlan

        # Vendor lookup normalization:
        # - if Cisco-style xxxx.xxxx.xxxx, convert to xx:xx:xx:xx:xx:xx
        # - if aa-bb-cc-dd-ee-ff, convert to aa:bb:cc:dd:ee:ff
        # - if already aa:bb:..., leave it
        $MacInOtherFormat = $mac
        if ($MacInOtherFormat -match "\.") {
            $MacInOtherFormat = ($MacInOtherFormat -replace "\.", "")
            if ($MacInOtherFormat.Length -ge 12) {
                $MacInOtherFormat = $MacInOtherFormat.Insert(2,":").Insert(5,":").Insert(8,":").Insert(11,":").Insert(14,":")
            }
        }
        $MacInOtherFormat = ($MacInOtherFormat -replace "-", ":").ToLower()

        if ($MacInOtherFormat.Length -ge 8 -and $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 8)]) {
            $MacAddressobject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 8)]
        }
        elseif ($MacInOtherFormat.Length -ge 5 -and $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 5)]) {
            $MacAddressobject.VendorCompanyName = $GMacAddressToVendorMapping[$MacInOtherFormat.Substring(0, 5)]
        }
        else {
            $MacAddressobject.VendorCompanyName = "UNKNOWN Vendor"
        }

        $DeviceInterface = $Device.interfaces | Where-Object { $_.interface -eq $MacAddressobject.Interface }
        if ($null -eq $DeviceInterface) {
            Write-MTAutoDrawLog -Level Warn -Phase Parse -Device $Device -Message "Update-ArubaMacAddressTable: Could not find interface '$($MacAddressobject.Interface)' for port '$port'. Replace-InterfaceShortName might be the problem."
            continue
        }

        $DeviceInterface.MacAddressArray += ,$MacAddressobject
        $addedCount++

        if (($addedCount % 100) -eq 0) {
            Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Update-ArubaMacAddressTable: Added MACs so far=$addedCount"
        }
    }

    Write-MTAutoDrawLog -Level Debug -Phase Parse -Device $Device -Message "Update-ArubaMacAddressTable: END addedCount=$addedCount"
}
