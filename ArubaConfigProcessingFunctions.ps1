#This functions calls all the other functions to process all of the files for an Aruba device.
#Input: Hostid object.
#Output: $device object.
function Process-ArubaHostFiles {
    param (
        [parameter(Mandatory = $true)]
        $hostid,
        $ArrayOfObjects
    )

    $Device = $null

    Write-Host "Process-ArubaHostFiles : START HostID '$($hostid.HOSTID)'" 
    Write-Host "$($hostid|fl|out-string)" 

    # 1) Create the device object from the config ("show run"/"show configuration") file.
    if ($hostid.showrun -and (Test-Path -Path $hostid.showrun)) {

        Write-Host "Process-ArubaHostFiles : Reading showrun file: $($hostid.showrun)"

        $config = Get-Content -Path $hostid.showrun -Raw

        Write-Host "Process-ArubaHostFiles : Parsing showrun into device object"
        $Device = Get-ArubaShowRunFromText -Lconfig $config
        
        if (-not $Device.interfaces) {
            $Device.interfaces = @()
        }
        elseif ($Device.interfaces -isnot [System.Collections.IList]) {
            #Ensure that it is an array. 
            $Device.interfaces = @($Device.interfaces)
        }
        
        # Keep identifier logic consistent with Cisco (hostid extracted from filename)
        $DeviceIdentifier = ($hostid.showrun -replace "\.show run.*", '' -replace "^.*\\", '' -replace "\.show configuration.*", '')
        if ($Device) {
            $Device.DeviceIdentifier = $DeviceIdentifier
            Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : DeviceIdentifier set to '$DeviceIdentifier'"
        }
        else {
            Write-Host "Process-ArubaHostFiles : Get-ArubaShowRunFromText returned null" -BackgroundColor Red
        }
    }
    else {
        Write-Host "Process-ArubaHostFiles : showrun file missing for hostid '$($hostid.HOSTID)': $($hostid.showrun)" -BackgroundColor Red
        return $null
    }

    # If we still don't have a valid device object, we can't proceed.
    if ($null -eq $Device) {
        Write-Host "Process-ArubaHostFiles : Failed to build Aruba device object, skipping host: $($hostid.showrun)" -BackgroundColor Red
        return $null
    }

    # Hostname validation (same semantics as Cisco)
    if ([string]::IsNullOrEmpty($Device.hostname) -or $Device.hostname -like "*NoHostNameFound*") {
        Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : Hostname missing or invalid. hostname='$($Device.hostname)'" -BackgroundColor Red
        Write-Host "Can't find hostname in file skipping host: $($hostid.showrun)" -BackgroundColor Red
        return $null
    }

    # Now that $Device is a valid object, we can begin logging.
    Add-HostDebugText -HostObject $Device "Processing Aruba Host: $($Device.hostname)"

    Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : START pipeline for host '$($Device.hostname)'"
    Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : showrun='$($hostid.showrun)'"

    # Duplicate hostname check (same behavior as Cisco)
    Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : Checking for duplicate hostname in ArrayOfObjects"
    foreach ($ExistingDevice in $ArrayOfObjects) {
        if ($ExistingDevice.hostname -eq $Device.hostname) {

            Add-HostDebugText -HostObject $Device "Hostname already exists $($ExistingDevice.hostname) - $($Device.hostname). This means you either have the same config twice in the folder or someone has named two devices the same. This script requries unquie hostnames." -BackgroundColor Red
            Add-HostDebugText -HostObject $Device "Found problem at: $($hostid.HOSTID)" -BackgroundColor Red

            # NOTE: This relies on $ArrayOfHostIDs existing in the caller scope, same as Cisco.
            Add-HostDebugText -HostObject $Device "Existing HostID's:$($ArrayOfHostIDs | ft HOSTID,showrun | out-string)"
            Add-HostDebugText -HostObject $Device "$($ArrayOfObjects | ft hostname,DeviceIdentifier | out-string)"

            if (!($SkipHostnameErrorCheck)) {
                Add-HostDebugText -HostObject $Device 'Exiting please manually fix this error.' -BackgroundColor Red
                Start-CleanupAndExit
            }
        }
    }
    Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : Duplicate hostname check complete"
    # 2) Version / platform info
    if ($hostid.ShowVersion) {
        Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : ShowVersion path='$($hostid.ShowVersion)'"
    }
    if ($hostid.ShowVersion -and (Test-Path $hostid.ShowVersion)) {
        Add-HostDebugText -HostObject $Device "Processing show version: $($hostid.ShowVersion)"
        $Device = Get-ArubaShowVersionFromText -ShowVersionFile $hostid.ShowVersion -Device $Device
        Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : Completed show version parsing. Device.Version='$($Device.Version)'"
    }
    else {
        if ($hostid.ShowVersion) {
            Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : ShowVersion file not found, skipping: $($hostid.ShowVersion)" -BackgroundColor Yellow
        }
    }
    # 3) Neighbor discovery (LLDP/CDP equivalents)
    if ($hostid.ShowLLDPNeighborsDetails) {
        Add-HostDebugText -HostObject $Device "Processing show LLDP Details: $($hostid.ShowLLDPNeighborsDetails)"
        $Device = Get-ArubaShowLLDPNeighborsDetailsFromText -ShowLLDPDetailsFile $hostid.ShowLLDPNeighborsDetails -Device $Device
    }
    elseif ($hostid.ShowLLDPNeighbors) {
        Add-HostDebugText -HostObject $Device "Processing show LLDP Neighbors: $($hostid.ShowLLDPNeighbors)"
        $Device = Get-ArubaShowLLDPNeighborsFromText -ShowLLDPNeighborsFile $hostid.ShowLLDPNeighbors -Device $Device
    }
    else {
        Add-HostDebugText -HostObject $Device "No LLDP neighbor files found (details or summary)." -BackgroundColor Yellow
    }
    
    
    # 4) Interfaces (choose one source like Cisco does)
    if ($hostid.ShowInterface) {
        Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : ShowInterface path='$($hostid.ShowInterface)'"
    }
    if ($hostid.ShowInterface -and (Test-Path $hostid.ShowInterface)) {
        Add-HostDebugText -HostObject $Device "Processing Show Interface : $($hostid.ShowInterface)"
        Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : Interfaces before update count=$(@($Device.interfaces).Count)"
        $Device = Get-ArubaShowInterfacesFromTextfsm -ShowInterfaceFile $hostid.ShowInterface -Device $Device
        Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : Interfaces after update count=$(@($Device.interfaces).Count)"
    }
    elseif ($hostid.ShowInterfaceBrief -and (Test-Path $hostid.ShowInterfaceBrief)) {
        Add-HostDebugText -HostObject $Device "Processing Show ip Interface Brief: $($hostid.ShowInterfaceBrief)"
        Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : Interfaces before update count=$(@($Device.interfaces).Count)"
        $Device = Get-ArubaShowInterfaceBriefFromTextfsm -ShowInterfaceBriefFile $hostid.ShowInterfaceBrief -Device $Device
        Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : Interfaces after update count=$(@($Device.interfaces).Count)"
    }
    else {
        Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : No interface source files found (ShowInterface / ShowIPInterfaceBrief), skipping." -BackgroundColor Yellow
    }

    # 5) Interface status (optional)
    if ($hostid.ShowInterfaceStatus) {
        Add-HostDebugText -HostObject $Device "Processing Show Interface status: $($hostid.ShowInterfaceStatus)"
        # TODO: Aruba interface status parser
    }

    # 6) Spanning-tree (optional)
    if ($hostid.ShowSpanningTreeDetails) {
        Add-HostDebugText -HostObject $Device "Processing Show Spanning Tree Details: $($hostid.ShowSpanningTreeDetails)"
        $Device = Get-ArubaShowSpanningTreeDetailsFromText -ShowSpanningTreeDetailsFile $hostid.ShowSpanningTreeDetails -Device $Device
    }
    elseif ($hostid.ShowSpanningTree) {
        Add-HostDebugText -HostObject $Device "Processing Show Spanning Tree: $($hostid.ShowSpanningTree)"
        $Device = Get-ArubaShowSpanningTreeFromText -ShowSpanningTreeFile $hostid.ShowSpanningTree -Device $Device
        # TODO: Aruba spanning-tree (non-detail) parser implementation
    }
    # 7) Routing table (optional)
    if ($hostid.ShowIPRoute) {
        Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : ShowIPRoute path='$($hostid.ShowIPRoute)'"
    }
    if ($hostid.ShowIPRoute -and (Test-Path $hostid.ShowIPRoute)) {
        Add-HostDebugText -HostObject $Device "Processing Show ip route: $($hostid.ShowIPRoute)"
        $Device = Get-ArubaShowIPRouteFromText -ShowIPRouteFile $hostid.ShowIPRoute -Device $Device
        Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : Routing table count=$(@($Device.RoutingTable).Count)"
    }
    elseif ($hostid.ShowIPRouteVRFstar) {
        Add-HostDebugText -HostObject $Device "Processing Show ip route vrf *: $($hostid.ShowIPRouteVRFstar)"
        # $Device = Get-ArubaShowIPRouteallvrfsFromText -ShowIPRouteFile $hostid.ShowIPRouteVRFstar -Device $Device
    }
    else {
        Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : No route file found (ShowIPRoute / ShowIPRouteVRFstar), skipping." -BackgroundColor Yellow
    }

    # 8) ARP (optional)
    if ($hostid.ShowIPArp) {
        Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : ShowIPArp path='$($hostid.ShowIPArp)'"
    }
    if ($hostid.ShowIPArp -and (Test-Path $hostid.ShowIPArp)) {
        if ($GDrawAprEntries) {
            Add-HostDebugText -HostObject $Device "Processing Show ip Arp: $($hostid.ShowIPArp)"
            $Device = Get-ArubaShowIPArpText -ShowIPArpFile $hostid.ShowIPArp -Device $Device
            Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : ARP entries count=$(@($Device.IPArpEntries).Count)"
        }
        else {
            Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : GDrawAprEntries disabled, skipping ARP parsing." -BackgroundColor Yellow
        }
    }
    else {
        if ($hostid.ShowIPArp) {
            Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : ARP file not found, skipping: $($hostid.ShowIPArp)" -BackgroundColor Yellow
        }
    }

	# 9) MAC address table (optional, and keep the same performance guardrails)
	if ($hostid.ShowMacAddressTable -and $GDrawPortsWithMacs -ne 0) {
		if ($GDrawCDP) {
			Add-HostDebugText -HostObject $Device "Processing Show Mac Address Table: $($hostid.ShowMacAddressTable)"
			$Device = Get-ArubaShowMacAddressTableFromText -ShowMacAddressTable $hostid.ShowMacAddressTable -Device $Device
		}
	}

    # 10) Post-processing: Build IP Array and Network Objects from fully populated interfaces
    Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : Building ArrayOfIPAddresses and ArrayOfNetworks from finalized interfaces"
    
    $Device.ArrayOfIPAddresses = @()
    $Device.ArrayOfNetworks = @()

    foreach ($int in $Device.interfaces) {
        # Track Primary IP
        if ($int.IPAddress) {
            $Device.ArrayOfIPAddresses += $int.IPAddress
        }
        # Track Secondary IP
        if ($int.SecondaryIPAddress) {
            $Device.ArrayOfIPAddresses += $int.SecondaryIPAddress
        }

        # Build Primary Network Object
        if ($int.Cidr) {
            $NetworkObject = Create-NetworkObject
            $NetworkObject.Cidr = $int.Cidr
            if ($int.Interface -like "*vlan*") {
                $NetworkObject.Routedvlan = $int.Interface
            } else {
                $NetworkObject.Routedvlan = "no vlan"
            }
            $NetworkObject.color = "$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0)"
            $Device.ArrayOfNetworks += $NetworkObject
        }

        # Build Secondary Network Object
        if ($int.SecondaryCidr) {
            $NetworkObject = Create-NetworkObject
            $NetworkObject.Cidr = $int.SecondaryCidr
            if ($int.Interface -like "*vlan*") {
                $NetworkObject.Routedvlan = $int.Interface
            } else {
                $NetworkObject.Routedvlan = "no vlan"
            }
            $NetworkObject.color = "$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0)"
            $Device.ArrayOfNetworks += $NetworkObject
        }
    }

    Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : Final IP Count=$(@($Device.ArrayOfIPAddresses).Count), Final Network Count=$(@($Device.ArrayOfNetworks).Count)"

    # Final normalization step used across vendors
    Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : Running Update-LocalRoutesWithInterfaces"
    $Device = Update-LocalRoutesWithInterfaces -device $Device
    Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : Completed Update-LocalRoutesWithInterfaces"

    Add-HostDebugText -HostObject $Device "Process-ArubaHostFiles : END pipeline for host '$($Device.hostname)'"
    return $Device
}

function Get-ArubaShowLLDPNeighborsFromText {
    param (
        [parameter(Mandatory = $true)]
        $ShowLLDPNeighborsFile,

        [parameter(Mandatory = $true)]
        $Device
    )

    $ShowLLDPText = Get-Content -Raw $ShowLLDPNeighborsFile

    if (($ShowLLDPText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Ambiguous command:|LLDP is not enabled|not enabled)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$ShowLLDPText" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty" -BackgroundColor Red
        return $Device
    }

    if ($null -eq $GTemplate -or $GTemplate.PSObject.Properties.Name -notcontains "ArubaAoscxLldpNeighbor") {
        Add-HostDebugText -HostObject $Device "Get-ArubaShowLLDPNeighborsFromText : GTemplate.ArubaAoscxLldpNeighbor is not set." -BackgroundColor Red
        return $Device
    }

    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['aruba_aoscx_show_lldp_neighbors'] -ShowFile $ShowLLDPNeighborsFile -ReturnArray $true -HostObject $Device

    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Error running TextFSM for Aruba AOS-CX show lldp neighbors."
        return $Device
    }

    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        $tempArray = @()
        $tempArray += , $Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }

    $AllLLDPObjects = @()

    foreach ($LLDPNeighbor in $Device.ProcessOutputObjects) {
        # Expected output order depends on your TextFSM template.
        # Based on the sample table, you typically want:
        # 0 LOCAL_INTERFACE (LOCAL-PORT)
        # 1 CHASSIS_ID
        # 2 NEIGHBOR_PORT_ID (PORT-ID)
        # 3 NEIGHBOR_INTERFACE (PORT-DESC)
        # 4 NEIGHBOR_NAME (SYS-NAME)
        #
        # If your template outputs a different order, update indexes here.

        if ($LLDPNeighbor.Count -lt 3) {
            Add-HostDebugText -HostObject $Device "Get-ArubaShowLLDPNeighborsFromText : Skipping malformed LLDP record: $($LLDPNeighbor | Out-String)" -BackgroundColor Yellow
            continue
        }

        $LLDPObject = Create-LLDPNeighborObject

        # Safe extraction with bounds checks (since templates vary)
        $localIf   = if ($LLDPNeighbor.Count -ge 1) { $LLDPNeighbor[0].ToString().Trim() } else { "" }
        $chassisId = if ($LLDPNeighbor.Count -ge 2) { $LLDPNeighbor[1].ToString().Trim() } else { "" }
        $portId    = if ($LLDPNeighbor.Count -ge 3) { $LLDPNeighbor[2].ToString().Trim() } else { "" }
        $portDesc  = if ($LLDPNeighbor.Count -ge 4) { $LLDPNeighbor[3].ToString().Trim() } else { "" }
        $sysName   = if ($LLDPNeighbor.Count -ge 5) { $LLDPNeighbor[4].ToString().Trim() } else { "" }

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

    return $Device
}


function Get-ArubaShowLLDPNeighborsDetailsFromText {
    param (
        [parameter(Mandatory = $true)]
        $ShowLLDPDetailsFile,

        [parameter(Mandatory = $true)]
        $Device
    )

    $ShowLLDPDetailText = Get-Content -Raw $ShowLLDPDetailsFile

    if (($ShowLLDPDetailText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Ambiguous command:|LLDP is not enabled|not enabled)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$ShowLLDPDetailText" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "contains invalid data or is empty" -BackgroundColor Red
        return $Device
    }

    if ($null -eq $GTemplate -or $GTemplate.PSObject.Properties.Name -notcontains "ArubaAoscxLldpNeighborDetails") {
        Add-HostDebugText -HostObject $Device "Get-ArubaShowLLDPNeighborsDetailsFromText : GTemplate.ArubaAoscxLldpNeighborDetails is not set." -BackgroundColor Red
        return $Device
    }

    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['aruba_aoscx_show_lldp_neighbors-info_detail'] -ShowFile $ShowLLDPDetailsFile -ReturnArray $true -HostObject $Device

    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Error running TextFSM for Aruba AOS-CX show lldp neighbors details."
        return $Device
    }

    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        $tempArray = @()
        $tempArray += , $Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }

    $AllLLDPDetailsObjects = @()

    foreach ($LLDPNeighbor in $Device.ProcessOutputObjects) {
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

        if ($LLDPNeighbor.Count -lt 9) {
            Add-HostDebugText -HostObject $Device "Get-ArubaShowLLDPNeighborsDetailsFromText : Skipping malformed LLDP record (expected 9 fields): $($LLDPNeighbor | Out-String)" -BackgroundColor Yellow
            continue
        }

        if ($GSkipCDPLLDPPhones) {
            $desc = ($LLDPNeighbor[3] | ForEach-Object { $_.ToString() })
            if ($desc -like "*Phone*" -or $desc -like "*Endpoint*") {
                continue
            }
        }

        $LLDPObject = Create-LLDPNeighborObject

        # Only populate fields required by Create-LLDPNeighborObject()
        $LLDPObject.InterfaceLocalDevice = Replace-InterfaceShortName -string ($LLDPNeighbor[0].ToString().Trim())
        $LLDPObject.ChassisID            = $LLDPNeighbor[1].ToString().Trim()
        $LLDPObject.Hostname             = $LLDPNeighbor[2].ToString().Trim()
        $LLDPObject.SystemDescription    = $LLDPNeighbor[3].ToString().Trim()
        $LLDPObject.Capabilities         = $LLDPNeighbor[5].ToString().Trim()
        $LLDPObject.ManagementIP         = $LLDPNeighbor[6].ToString().Trim()

        $remotePortIdRaw = $LLDPNeighbor[7].ToString().Trim()
        $LLDPObject.InterfaceRemoteDevice        = Replace-InterfaceShortName -string $remotePortIdRaw
        $LLDPObject.PortID                       = $remotePortIdRaw
        $LLDPObject.NeighborInterfaceDescription = $LLDPNeighbor[8].ToString().Trim()

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

    return $Device
}

# Process an ArubaOS-CX "show running-config" / "show configuration" blob.
# Extract only generic config-driven data (avoid anything you will later parse via TextFSM sections).
function Get-ArubaShowRunFromText {
    param (
        [parameter(Mandatory = $true)]
        $Lconfig
    )

    Write-Host "Get-ArubaShowRunFromText : START"

    $HostObject = Create-HostObject
    $HostObject.Origin = "config"

    # Hostname
    $hostname = Get-RegexGroupValue -InputText $Lconfig -Pattern '(?m)^\s*hostname\s+(.+?)\s*$'
    if ($null -eq $hostname -or $hostname -eq "") {
        $hostname = "NoHostNameFoundCheckForConfigProblems"
    }
    $HostObject.hostname = $hostname

    Add-HostDebugText -HostObject $HostObject "Get-ArubaShowRunFromText : Parsed hostname='$($HostObject.hostname)'"

    # Version
    $version = Get-RegexGroupValue -InputText $Lconfig -Pattern '(?m)^\s*!Version\s+(.+?)\s*$'
    if ($null -eq $version -or $version -eq "") {
        $version = Get-RegexGroupValue -InputText $Lconfig -Pattern '(?m)^\s*Version\s+(.+?)\s*$'
    }
    if ($version) {
        $HostObject.Version = $version
        Add-HostDebugText -HostObject $HostObject "Get-ArubaShowRunFromText : Parsed Version='$($HostObject.Version)'"
    }
    else {
        Add-HostDebugText -HostObject $HostObject "Get-ArubaShowRunFromText : No version found in config" -BackgroundColor Yellow
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

    # Array mapping removed from here. The parser now just gives us the interface array natively.
    $HostObject.interfaces = Get-ArubaShowInterfacesFromText -HostObject $HostObject -AllInterfaces $AllInterfaces

    return $HostObject
}


# Parse ArubaOS-CX interface blocks from running config
function Get-ArubaShowInterfacesFromText {
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
function Get-ArubaShowInterfacesFromTextfsm {
    param (
        [parameter(Mandatory = $true)]
        $ShowInterfaceFile,
        $Device
    )

    Add-HostDebugText -HostObject $Device "Get-ArubaShowInterfacesFromTextfsm: START file='$ShowInterfaceFile'"

    #Read the file into one big string
    $ShowInterfaceText = Get-Content -Raw $ShowInterfaceFile

    if (($ShowInterfaceText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Ambiguous command:|LLDP is not enabled)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$($ShowInterfaceText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "Get-ArubaShowInterfacesFromTextfsm: contains invalid data or is empty" -BackgroundColor Red
        return $Device
    }

    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['aruba_aoscx_show_interface'] -ShowFile $ShowInterfaceFile -ReturnArray $true -HostObject $Device
    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Get-ArubaShowInterfacesFromTextfsm: ERROR from Execute-PythonTextFSM" -BackgroundColor Red
        return $Device
    }

    # Normalize single-record return shape
    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        $tempArray = @()
        $tempArray += ,$Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }

    $updatedCount = 0
    
    foreach ($int in $Device.ProcessOutputObjects) {
        
        $ifName = Replace-InterfaceShortName -string $int[0]

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
        $linkStatus = $int[1]
        $adminState = $int[2]
        $stateInfo  = $int[3]

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
        if ($int[5] -and $int[5].Trim() -ne "") {
            $Interface.Description = $int[5].Trim()
        }

        # Hardware / MAC / Duplex / Speed
        if ($int[6]) { $Interface.HardwareType = $int[6] }
        if ($int[7]) { $Interface.macaddress   = $int[7] }
        if ($int[11]) { $Interface.Duplex      = $int[11] }

        if ($int[13]) {
            $speed = $int[13].Trim()
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

        if ($int[9] -and $int[9].Trim() -ne "" -and $int[9].Trim() -ne "--") {
            $Interface.MediaType = $int[9].Trim()
        }

        if ($int[10] -and $int[10].Trim() -ne "" -and $int[10].Trim() -ne "n/a") {
            $ipCidr = $int[10].Trim()
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

        if ($int[17]) {
            $vlanMode = $int[17].Trim().ToLower()

            if ($vlanMode -eq "access") {
                $Interface.SwitchportMode = "access"
                $Interface.SwitchPortType = "Switched"
                if ($int[18] -and $int[18].Trim() -ne "") {
                    $Interface.SwitchportAccessVlan = $int[18].Trim()
                }
            }
            elseif ($vlanMode -eq "trunk") {
                $Interface.SwitchportMode = "trunk"
                $Interface.SwitchPortType = "Switched"

                if ($int[19] -and $int[19].Trim() -ne "") {
                    $Interface.NativeVlan = $int[19].Trim()
                }

                $trunks = $int[20]
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

        $aggList = $int[21]
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
                        Add-HostDebugText -HostObject $Device "Get-ArubaShowInterfacesFromTextfsm: Member '$member' not found in show run interfaces" -BackgroundColor Yellow
                    }
                }
            }
        }
    }
    Add-HostDebugText -HostObject $Device "Get-ArubaShowInterfacesFromTextfsm: END updatedCount=$updatedCount"
    return $Device
}

#Process ArubaOS-CX "show version" output using regex (no TextFSM template for OS-CX).
function Get-ArubaShowVersionFromText {
    param (
        [parameter(Mandatory = $true)]
        $ShowVersionFile,

        [parameter(Mandatory = $true)]
        $Device
    )

    Add-HostDebugText -HostObject $Device "Get-ArubaShowVersionFromText: START file='$ShowVersionFile'"

    if (-not (Test-Path -Path $ShowVersionFile)) {
        Add-HostDebugText -HostObject $Device "Get-ArubaShowVersionFromText: ShowVersion file not found '$ShowVersionFile'" -BackgroundColor Red
        return $Device
    }

    $ShowVersionText = Get-Content -Raw $ShowVersionFile

    if (($ShowVersionText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Ambiguous command:)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$($ShowVersionText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "Get-ArubaShowVersionFromText: contains invalid data or is empty" -BackgroundColor Red
        return $Device
    }

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

    Add-HostDebugText -HostObject $Device "Get-ArubaShowVersionFromText: Parsed Type='$($VersionObject.Type)' OS='$($VersionObject.OS)' Image='$($VersionObject.Image)' HardwareCount=$(@($VersionObject.Hardware).Count) SerialCount=$(@($VersionObject.Serial).Count) MacCount=$(@($VersionObject.MacAddressArray).Count)"
    Add-HostDebugText -HostObject $Device "Get-ArubaShowVersionFromText: END"
    return $Device
}




function Get-ArubaShowIPArpText {
    param (
        [parameter(Mandatory=$true)]
        $ShowIPArpFile,
        $Device
    )

    Add-HostDebugText -HostObject $Device "Get-ArubaShowIPArpText: START file='$ShowIPArpFile'"

    $ShowIPArpText = Get-Content -Raw $ShowIPArpFile

    if (($ShowIPArpText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Ambiguous command:|LLDP is not enabled)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$($ShowIPArpText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "Get-ArubaShowIPArpText: contains invalid data or is empty" -BackgroundColor Red
        return $Device
    }

    Add-HostDebugText -HostObject $Device "Get-ArubaShowIPArpText: Executing TextFSM template ArubaAoscxShowArpAll"
    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTemplate.ArubaAoscxShowArpAll -ShowFile $ShowIPArpFile -ReturnArray $true -HostObject $Device
    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Get-ArubaShowIPArpText: ERROR from Execute-PythonTextFSM" -BackgroundColor Red
        return $Device
    }

    Add-HostDebugText -HostObject $Device "Get-ArubaShowIPArpText: Raw ProcessOutputObjects count=$(@($Device.ProcessOutputObjects).Count)"

    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        Add-HostDebugText -HostObject $Device "Get-ArubaShowIPArpText: Normalizing single record output shape"
        $tempArray = @()
        $tempArray += ,$Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }

    Add-HostDebugText -HostObject $Device "Get-ArubaShowIPArpText: Building subnet lookup from interfaces"
    $subnetLookup = @{}
    $Device.interfaces | Where-Object { $_.Cidr } | ForEach-Object { $subnetLookup[$_.Cidr] = $true }
    Add-HostDebugText -HostObject $Device "Get-ArubaShowIPArpText: subnetLookupCount=$($subnetLookup.Count)"

    $builtCount = 0
    $Device.IPArpEntries = foreach ($entry in $Device.ProcessOutputObjects) {

        $IPArpObject = Create-ShowIPArpObject

        $IPArpObject.PROTOCOL  = "IPv4"
        $IPArpObject.ipaddress = $entry[0].Trim()
        $IPArpObject.MAC       = $entry[1].Trim()

        $physicalPort = $entry[3].Trim()
        $portId       = $entry[2].Trim()

        if ($physicalPort -ne "") {
            $IPArpObject.INTERFACE = $physicalPort
        }
        elseif ($portId -ne "") {
            $IPArpObject.INTERFACE = $portId
        }

        $state = $entry[4].Trim()
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
            Add-HostDebugText -HostObject $Device "Get-ArubaShowIPArpText: Built ARP entries so far=$builtCount"
        }

        $IPArpObject
    }

    Add-HostDebugText -HostObject $Device "Get-ArubaShowIPArpText: END builtCount=$builtCount"
    return $Device
}



function Get-ArubaShowIPRouteallvrfsFromText {
    param (
        [parameter(Mandatory = $true)]
        $ShowIPRouteFile,

        $Device
    )

    Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteallvrfsFromText: START file='$ShowIPRouteFile'"

    $ShowRouteText = Get-Content -Raw $ShowIPRouteFile

    if (($ShowRouteText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Ambiguous command:)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$($ShowRouteText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteallvrfsFromText: contains invalid data or is empty" -BackgroundColor Red
        return $Device
    }

    Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteallvrfsFromText: Executing TextFSM template ArubaAoscxIpRoute"
    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['aruba_aoscx_show_ip_route'] -ShowFile $ShowIPRouteFile -ReturnArray $true -HostObject $Device
    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteallvrfsFromText: ERROR from Execute-PythonTextFSM" -BackgroundColor Red
        return $Device
    }

    Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteallvrfsFromText: Raw ProcessOutputObjects count=$(@($Device.ProcessOutputObjects).Count)"

    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteallvrfsFromText: Normalizing single record output shape"
        $tempArray = @()
        $tempArray += ,$Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }

    Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteallvrfsFromText: Building ActiveInterfaces cache"
    $ActiveInterfaces = $Device.interfaces | Where-Object { $_.cidr -and $_.IntStatus -ne "down" }
    Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteallvrfsFromText: ActiveInterfaces count=$(@($ActiveInterfaces).Count)"

    $routeRecordCount = 0
    $routeObjectCount = 0

    $AllRouteObjects = foreach ($route in $Device.ProcessOutputObjects) {

        $routeRecordCount++

        $ip     = $route[0]
        $prefix = $route[1]
        $vrf    = $route[2]
        $subnet = "$ip/$prefix"

        Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteallvrfsFromText: Record[$routeRecordCount] subnet='$subnet' vrf='$vrf'"

        $interfaces = @()
        $metrics    = @()
        $statuses   = @()

        if ($route[3] -is [System.Collections.IEnumerable] -and !($route[3] -is [string])) {
            $interfaces = @($route[3] | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne "" })
        }
        elseif ($route[3]) {
            $interfaces = @($route[3].ToString().Trim())
        }

        if ($route[4] -is [System.Collections.IEnumerable] -and !($route[4] -is [string])) {
            $metrics = @($route[4] | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne "" })
        }
        elseif ($route[4]) {
            $metrics = @($route[4].ToString().Trim())
        }

        if ($route[5] -is [System.Collections.IEnumerable] -and !($route[5] -is [string])) {
            $statuses = @($route[5] | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne "" })
        }
        elseif ($route[5]) {
            $statuses = @($route[5].ToString().Trim())
        }

        Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteallvrfsFromText: Record[$routeRecordCount] viaCount=$($interfaces.Count) metricCount=$($metrics.Count) statusCount=$($statuses.Count)"

        if ($interfaces.Count -eq 0) {
            $RouteObject = Create-RouteObject
            $RouteObject.Subnet = $subnet
            $RouteObject.VRF = $vrf
            $RouteObject.RouteProtocol = $null

            $routeObjectCount++
            $RouteObject
            continue
        }

        for ($i = 0; $i -lt $interfaces.Count; $i++) {
            $RouteObject = Create-RouteObject
            $RouteObject.Subnet = $subnet
            $RouteObject.VRF = $vrf

            if ($i -lt $statuses.Count -and $statuses[$i]) {
                $RouteObject.RouteProtocol = $statuses[$i]
            }

            if ($i -lt $metrics.Count -and $metrics[$i]) {
                $m = $metrics[$i]
                $RouteObject.METRIC = $m

                if ($m -match '^\[(\d+)\/(\d+)\]$') {
                    $RouteObject.DISTANCE = $Matches[1]
                    $RouteObject.METRIC   = $Matches[2]
                }
            }

            $via = $interfaces[$i]
            Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteallvrfsFromText: Record[$routeRecordCount] viaIndex=$i via='$via'"

            if ($via -match '^\d+\.\d+\.\d+\.\d+$') {
                $RouteObject.gateway = $via

                foreach ($intf in $ActiveInterfaces) {
                    if ((Find-Subnet -addr1 $intf.cidr -addr2 $RouteObject.gateway).condition) {
                        $RouteObject.interface = $intf.Interface
                        break
                    }
                }

                Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteallvrfsFromText: Record[$routeRecordCount] via='$via' resolvedOutInt='$($RouteObject.interface)'"
            }
            else {
                $RouteObject.interface = $via
            }

            if ($RouteObject.Subnet -eq "0.0.0.0/0") {
                $RouteObject.defaultgateway = $true
            }

            $routeObjectCount++
            $RouteObject
        }
    }

    $Device.RoutingTable = $AllRouteObjects
    Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteallvrfsFromText: END routeRecordCount=$routeRecordCount routeObjectCount=$routeObjectCount"
    return $Device
}



function Get-ArubaShowIPRouteFromText {
    param (
        [parameter(Mandatory = $true)]
        $ShowIPRouteFile,

        $Device
    )

    Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteFromText : START file='$ShowIPRouteFile'"

    $ShowRouteText = Get-Content -Raw $ShowIPRouteFile

    if (($ShowRouteText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Ambiguous command:)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$($ShowRouteText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteFromText : contains invalid data or is empty" -BackgroundColor Red
        return $Device
    }

    Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteFromText : Executing TextFSM template ArubaAoscxIpRoute"
    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['aruba_aoscx_show_ip_route'] -ShowFile $ShowIPRouteFile -ReturnArray $true -HostObject $Device
    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteFromText : ERROR from Execute-PythonTextFSM" -BackgroundColor Red
        return $Device
    }

    Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteFromText : Raw ProcessOutputObjects count=$(@($Device.ProcessOutputObjects).Count)"

    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteFromText : Normalizing single record output shape"
        $tempArray = @()
        $tempArray += ,$Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }

    Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteFromText : Building ActiveInterfaces cache"
    $ActiveInterfaces = $Device.interfaces | Where-Object { $_.cidr -and $_.IntStatus -ne "down" }
    Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteFromText : ActiveInterfaces count=$(@($ActiveInterfaces).Count)"

    $routeRecordCount = 0
    $routeObjectCount = 0

    $AllRouteObjects = foreach ($route in $Device.ProcessOutputObjects) {

        $routeRecordCount++

        # Array indices mapped strictly to the new TextFSM tabular output
        $vrf             = $route[0]
        $subnet          = $route[1]
        $nexthop         = $route[2]
        $interface       = $route[3]
        $origin_type     = $route[5]
        $distance_metric = $route[6]

        

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
    Add-HostDebugText -HostObject $Device "Get-ArubaShowIPRouteFromText : END routeRecordCount=$routeRecordCount routeObjectCount=$routeObjectCount"
    return $Device
}

function Get-ArubaShowSpanningTreeDetailsFromText {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$ShowSpanningTreeDetailsFile,

        [parameter(Mandatory = $true)]
        $Device
    )

    if (-not (Test-Path $ShowSpanningTreeDetailsFile)) {
        Add-HostDebugText -HostObject $Device "Get-ArubaShowSpanningTreeDetailsFromText : File not found $ShowSpanningTreeDetailsFile" -BackgroundColor Yellow
        return $Device
    }

    if (-not $Device.SpanningTree) {
        $Device.SpanningTree = Create-SpanningTreeObject
    }

    if (-not $Device.SpanningTree.SpanningTreeArray) {
        $Device.SpanningTree.SpanningTreeArray = @()
    }
    elseif ($Device.SpanningTree.SpanningTreeArray -isnot [System.Collections.IList]) {
        $Device.SpanningTree.SpanningTreeArray = @($Device.SpanningTree.SpanningTreeArray)
    }

    if (-not $Device.SpanningTree.RootBridgeForVlans) {
        $Device.SpanningTree.RootBridgeForVlans = @()
    }
    elseif ($Device.SpanningTree.RootBridgeForVlans -isnot [System.Collections.IList]) {
        $Device.SpanningTree.RootBridgeForVlans = @($Device.SpanningTree.RootBridgeForVlans)
    }

    Add-HostDebugText -HostObject $Device "Get-ArubaShowSpanningTreeDetailsFromText : Executing TextFSM template ArubaAoscxSpanningTreeDetail"
    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['aruba_aoscx_show_spanning-tree_detail'] -ShowFile $ShowSpanningTreeDetailsFile -ReturnArray $true -HostObject $Device

    if ($Device.ProcessOutputObjects -eq "ERROR" -or -not $Device.ProcessOutputObjects) {
        Add-HostDebugText -HostObject $Device "Get-ArubaShowSpanningTreeDetailsFromText : ERROR from Execute-PythonTextFSM" -BackgroundColor Red
        return $Device
    }

    # Normalize single-record output shape (same pattern used elsewhere)
    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        $tempArray = @()
        $tempArray += ,$Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }

    $Rows = @($Device.ProcessOutputObjects)

    Add-HostDebugText -HostObject $Device "Get-ArubaShowSpanningTreeDetailsFromText : Raw ProcessOutputObjects count=$(@($Rows).Count)"

    # TextFSM output is array-of-arrays in this project.
    # Index mapping (matches template Value order):
    # 0  PROTOCOL
    # 1  INSTANCE
    # 2  ROOT_PRIORITY
    # 3  ROOT_MAC
    # 4  ROOT_HELLO
    # 5  ROOT_SELF
    # 6  BRIDGE_PRIORITY
    # 7  BRIDGE_MAC
    # 8  BRIDGE_HELLO
    # 9  PORT
    # 10 ROLE
    # 11 STATE
    # 12 COST
    # 13 PRIORITY
    # 14 TYPE
    # 15 BPDU_TX
    # 16 BPDU_RX
    # 17 TCN_TX
    # 18 TCN_RX

    # Set mode/protocol
    $First = $Rows | Select-Object -First 1
    if ($First -and $First.Count -ge 1 -and $First[0]) {
        $Device.SpanningTree.SpanningTreeMode = $First[0]
    }

    # Group by instance (index 1)
    $Groups = $Rows | Group-Object -Property { $_[1] }

    foreach ($G in $Groups) {
        if (-not $G.Name) { continue }

        $InstanceRows = @($G.Group)
        $Head = $InstanceRows | Select-Object -First 1

        $StInstance = Create-SpanningTreeVlan
        $StInstance.VlanID = $G.Name
        $StInstance.protocol = $Head[0]

        # Root bridge fields
        if ($Head.Count -ge 3 -and $Head[2]) { $StInstance.RootIDPriority = [int]$Head[2] }
        if ($Head.Count -ge 4 -and $Head[3]) { $StInstance.Address = $Head[3] }
        if ($Head.Count -ge 5 -and $Head[4]) { $StInstance.RootBridgeHelloTime = [int]$Head[4] }

        # "This bridge is the root"
        $StInstance.RootBridge = $false
        if ($Head.Count -ge 6 -and $Head[5] -and $Head[5].ToString().Trim() -ne "") {
            $StInstance.RootBridge = $true
        }

        # Local bridge fields
        if ($Head.Count -ge 7 -and $Head[6]) { $StInstance.BridgeIDPriority = [int]$Head[6] }
        if ($Head.Count -ge 8 -and $Head[7]) { $StInstance.BridgeIDPriorityaddress = $Head[7] }
        if ($Head.Count -ge 9 -and $Head[8]) { $StInstance.BridgeIDPriorityHelloTime = [int]$Head[8] }

        if (-not $StInstance.SpanningTreeInterfaces) {
            $StInstance.SpanningTreeInterfaces = @()
        }
        elseif ($StInstance.SpanningTreeInterfaces -isnot [System.Collections.IList]) {
            $StInstance.SpanningTreeInterfaces = @($StInstance.SpanningTreeInterfaces)
        }

        # Port table -> SpanningTreeInterfaces
        foreach ($R in $InstanceRows) {
            if (-not $R -or $R.Count -lt 10) { continue }
            if (-not $R[9] -or $R[9].ToString().Trim() -eq "") { continue }

            $If = Create-SpanningTreeInterface
            $If.Interface = $R[9]
            $If.Role      = if ($R.Count -ge 11) { $R[10] } else { $null }
            $If.Status    = if ($R.Count -ge 12) { $R[11] } else { $null }

            if ($R.Count -ge 13 -and $R[12]) { $If.Cost = [int]$R[12] }
            if ($R.Count -ge 14 -and $R[13]) { $If.PrioNbr = [int]$R[13] }
            if ($R.Count -ge 15 -and $R[14]) { $If.Type = $R[14].ToString().Trim() }

            $StInstance.SpanningTreeInterfaces += $If
        }

        # Add to device spanning-tree collection
        $Device.SpanningTree.SpanningTreeArray += $StInstance

        if ($StInstance.RootBridge -eq $true) {
            $Device.SpanningTree.RootBridgeForVlans += $StInstance.VlanID
        }
    }

    Add-HostDebugText -HostObject $Device "Get-ArubaShowSpanningTreeDetailsFromText : Parsed instances $(@($Device.SpanningTree.SpanningTreeArray).Count)"
    return $Device
}


function Get-ArubaShowInterfaceBriefFromTextfsm {
    param (
        [parameter(Mandatory = $true)]
        $ShowInterfaceBriefFile,

        [parameter(Mandatory = $true)]
        $Device
    )

    Add-HostDebugText -HostObject $Device "Get-ArubaShowInterfaceBriefFromTextfsm: START file='$ShowInterfaceBriefFile'"

    if (-not (Test-Path -Path $ShowInterfaceBriefFile)) {
        Add-HostDebugText -HostObject $Device "Get-ArubaShowInterfaceBriefFromTextfsm: File not found '$ShowInterfaceBriefFile'" -BackgroundColor Yellow
        return $Device
    }

    $text = Get-Content -Raw $ShowInterfaceBriefFile

    if (($text | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Ambiguous command:)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$text" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "Get-ArubaShowInterfaceBriefFromTextfsm: contains invalid data or is empty" -BackgroundColor Red
        return $Device
    }

    if ($null -eq $GTemplate -or $GTemplate.PSObject.Properties.Name -notcontains "ArubaAoscxShowIPInterfaceBrief") {
        Add-HostDebugText -HostObject $Device "Get-ArubaShowInterfaceBriefFromTextfsm: GTemplate.ArubaAoscxShowIPInterfaceBrief is not set." -BackgroundColor Red
        return $Device
    }

    if (-not $Device.interfaces) {
        $Device.interfaces = @()
    }
    elseif ($Device.interfaces -isnot [System.Collections.IList]) {
        $Device.interfaces = @($Device.interfaces)
    }

    Add-HostDebugText -HostObject $Device "Get-ArubaShowInterfaceBriefFromTextfsm: Executing TextFSM template ArubaAoscxShowIPInterfaceBrief"
    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['aruba_aoscx_show_ip_interface_brief'] -ShowFile $ShowInterfaceBriefFile -ReturnArray $true -HostObject $Device

    if ($Device.ProcessOutputObjects -eq "ERROR" -or -not $Device.ProcessOutputObjects) {
        Add-HostDebugText -HostObject $Device "Get-ArubaShowInterfaceBriefFromTextfsm: ERROR from Execute-PythonTextFSM" -BackgroundColor Red
        return $Device
    }

    # Normalize single-record return shape
    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        $tmp = @()
        $tmp += ,$Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tmp
    }

    Add-HostDebugText -HostObject $Device "Get-ArubaShowInterfaceBriefFromTextfsm: Raw records count=$(@($Device.ProcessOutputObjects).Count)"

    $updatedCount = 0
    $createdCount = 0

    foreach ($row in $Device.ProcessOutputObjects) {

        # Template field order:
        # 0 PORT
        # 1 NATIVE_VLAN
        # 2 MODE
        # 3 TYPE
        # 4 ENABLED
        # 5 STATUS
        # 6 REASON
        # 7 SPEED
        # 8 DESCRIPTION

        if (-not $row -or $row.Count -lt 6) { continue }

        $port     = if ($row.Count -ge 1) { $row[0].ToString().Trim() } else { "" }
        if ([string]::IsNullOrWhiteSpace($port)) { continue }

        $native   = if ($row.Count -ge 2) { $row[1].ToString().Trim() } else { "" }
        $mode     = if ($row.Count -ge 3) { $row[2].ToString().Trim() } else { "" }
        $type     = if ($row.Count -ge 4) { $row[3].ToString().Trim() } else { "" }
        $enabled  = if ($row.Count -ge 5) { $row[4].ToString().Trim() } else { "" }
        $status   = if ($row.Count -ge 6) { $row[5].ToString().Trim() } else { "" }
        $reason   = if ($row.Count -ge 7) { $row[6].ToString().Trim() } else { "" }
        $speedRaw = if ($row.Count -ge 8) { $row[7].ToString().Trim() } else { "" }
        $descRaw  = if ($row.Count -ge 9) { $row[8].ToString().Trim() } else { "" }

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

    Add-HostDebugText -HostObject $Device "Get-ArubaShowInterfaceBriefFromTextfsm: END updatedCount=$updatedCount createdCount=$createdCount"
    return $Device
}




# Process the ArubaOS-CX "show mac-address-table" file
function Get-ArubaShowMacAddressTableFromText {
    param (
        [parameter(Mandatory = $true)]
        $ShowMacAddressTable,
        $Device
    )

    Add-HostDebugText -HostObject $Device "Get-ArubaShowMacAddressTableFromText: START file='$ShowMacAddressTable'"

    $ShowMacAddressTableText = Get-Content -Raw $ShowMacAddressTable

    if (($ShowMacAddressTableText | Select-String "(Line has invalid autocommand|Invalid input detected at|Syntax error while parsing|Line has invalid autocommand|Ambiguous command:|LLDP is not enabled)").Matches.Success) {
        Add-HostDebugText -HostObject $Device "$($ShowMacAddressTableText)" -BackgroundColor Magenta
        Add-HostDebugText -HostObject $Device "Get-ArubaShowMacAddressTableFromText: contains invalid data or is empty" -BackgroundColor Red
        return $Device
    }

    Add-HostDebugText -HostObject $Device "Get-ArubaShowMacAddressTableFromText: Executing TextFSM template ArubaAoscxShowMacAddressTable"
    $Device = Execute-PythonTextFSM -TextFSTETemplate $GTextFSMTemplates['aruba_aoscx_show_mac-address-table'] -ShowFile $ShowMacAddressTable -ReturnArray $true -HostObject $Device
    if ($Device.ProcessOutputObjects -eq "ERROR") {
        Add-HostDebugText -HostObject $Device "Get-ArubaShowMacAddressTableFromText: ERROR from Execute-PythonTextFSM" -BackgroundColor Red
        return $Device
    }

    Add-HostDebugText -HostObject $Device "Get-ArubaShowMacAddressTableFromText: Raw ProcessOutputObjects count=$(@($Device.ProcessOutputObjects).Count)"

    # Normalize single-record output shape (TextFSM sometimes returns a single row as a flat array)
    if ($Device.ProcessOutputObjects.Count -gt 0 -and $Device.ProcessOutputObjects[0].GetType().Name -eq "string") {
        Add-HostDebugText -HostObject $Device "Get-ArubaShowMacAddressTableFromText: Normalizing single record output shape"
        $tempArray = @()
        $tempArray += ,$Device.ProcessOutputObjects
        $Device.ProcessOutputObjects = $tempArray
    }

    $addedCount = 0
    foreach ($MacRow in $Device.ProcessOutputObjects) {
        # TextFSM fields (from your template):
        # 0 = MAC_ADDRESS
        # 1 = VLAN_ID
        # 2 = TYPE
        # 3 = PORT
        $mac  = ($MacRow[0]).Trim()
        $vlan = ($MacRow[1]).Trim()
        $type = ($MacRow[2]).Trim()
        $port = ($MacRow[3]).Trim()

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
            Add-HostDebugText -HostObject $Device "Get-ArubaShowMacAddressTableFromText: Could not find interface '$($MacAddressobject.Interface)' for port '$port'. Replace-InterfaceShortName might be the problem." -BackgroundColor Red
            continue
        }

        $DeviceInterface.MacAddressArray += ,$MacAddressobject
        $addedCount++

        if (($addedCount % 100) -eq 0) {
            Add-HostDebugText -HostObject $Device "Get-ArubaShowMacAddressTableFromText: Added MACs so far=$addedCount"
        }
    }

    Add-HostDebugText -HostObject $Device "Get-ArubaShowMacAddressTableFromText: END addedCount=$addedCount"
    return $Device
}