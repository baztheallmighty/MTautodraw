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

#This file contains the starting function for processing config files and other helper functions


#Take a list of files and separate them and create file collections for each host show run, show interface,etc for that host. That way we can process them together.
#Input:List of files
#Output: Array of host object containing the files sorted by hostid.
function Create-FileHostObjects{
        param (
		[parameter(Mandatory=$true)]
		$files
    )
    #Find all the show run or show config files
    $HostIDs = $files | where { $_ -like "*.show ver*" -or $_ -like "*.show version*" } | % { ($_.name -split ".show*")[0] }
    $HostIDs += Get-ChildItem $GDirectory -File -Recurse -Include "*.show system info.txt" | ForEach-Object { ($_.Name -split ".show system info")[0] } | Select-Object -Unique

    if($HostIDs.count -eq 0){
        write-HostDebugText "No show verion files found. Please check the name of your files. e.g HostID.show run.txt" -BackgroundColor red
        Write-host 'Exiting.' -BackgroundColor red
        Start-CleanupAndExit
    }
        #Create a object to hold all the files for each host
    $ArrayOfHostIDs = $HostIDs | % { $TempHost=Create-FileObject;$TempHost.hostid=$_; $TempHost}
    foreach ($file in $files){
        foreach ( $hostid in $ArrayOfHostIDs){
            if($file.name -like "$($hostid.hostid).*"){

                if($file.name -like "*show run*" -or $file.name -like "*show config*" ){ #Checkpoint and cisco show run or show config.
                    $hostid.showrun=$file.fullname
                }

                if($file.name -like "*show ip bgp summary*"){
                    $hostid.ShowIPBGPSummary=$file.fullname
                    break
                }
                if($file.name -like "*show ip bgp neighbors advertised*"){
                    $hostid.ShowIPBGPNeighborsAdvertised=$file.fullname
                    break
                }
                if($file.name -like "*show ip bgp neighbors*"){
                    $hostid.ShowIPBGPNeighbors=$file.fullname
                    break
                }
                if($file.name -like "*show ip bgp vpnv4 all neighbors*"){
                    $hostid.ShowIPBGPVPNv4Neighbors=$file.fullname
                    break
                }

                if($file.name -like "*show cdp neighbors detail*"){
                    $hostid.ShowCDPNeighborsDetails=$file.fullname
                    break
                }
                if($file.name -like "*show ip interface brief*"){
                    $hostid.ShowIPInterfaceBrief=$file.fullname
                    break
                }
                if($file.name -like "*show interface status*"){
                    $hostid.ShowInterfaceStatus=$file.fullname
                    break
                }
                if($file.name -like "*show interfaces detail*"){
                    $hostid.ShowInterfaceDetail=$file.fullname
                    break
                }
                if($file.name -like "*show interface.txt" ){
                    $hostid.ShowInterface=$file.fullname
                    break
                }
                if($file.name -like "*show interface all*"){
                    $hostid.ShowInterfaceAll=$file.fullname
                    break
                }
                if($file.name -like "*show mac address-table*"){
                    $hostid.ShowMacAddressTable=$file.fullname
                    break
                }
                if($file.name -like "*show spanning-tree interface*"){
                    $hostid.ShowSpanningTreeInterface=$file.fullname
                    break
                }
                if($file.name -like "*show spanning-tree bridge*"){
                    $hostid.JunosShowSpanningTreeBridgeFromXML=$file.fullname
                    break
                }
                if($file.name -like "*show spanning-tree*"){
                    $hostid.ShowSpanningTree=$file.fullname
                    break
                }
                if($file.name -like "*show ip route vrf*"){
                    $hostid.ShowIPRouteVRFstar=$file.fullname
                    break
                }
                if($file.name -like "*show ip route*"){
                    $hostid.ShowIPRoute=$file.fullname
                    break
                }
                if($file.name -like "*show route all*"){ #Checkpoint routing table
                    $hostid.ShowRouteAll=$file.fullname
                    break
                }
                if($file.name -like "*show route*" ){ #Cisco ASA routing table and JUNOS
                    $hostid.CiscoASAShowRoute=$file.fullname  #Cisco ASA
                    $hostid.ShowRouteAll=$file.fullname #JUNOS
                    break
                }
                if($file.name -like "*show lldp neighbors detail*"){
                    $hostid.ShowLLDPNeighborsDetails=$file.fullname
                    break
                }
                if($file.name -like "*show lldp neighbors*"){
                    $hostid.ShowLLDPNeighbors=$file.fullname
                    break
                }

                if($file.name -like "*show version*"){
                    $ShowVersionText=get-content $file.fullname -raw


                    $hostid.ShowVersion=$file.fullname
                    if(($ShowVersionText | Select-String "Check Point Gaia").Matches.Success){
                        $hostid.DeviceType="CheckPoint"
                        break
                    }elseif(($ShowVersionText | Select-String "Cisco Adaptive Security Appliance").Matches.Success){
                        $hostid.DeviceType="CiscoASA"
                        break
                    }elseif(($ShowVersionText | Select-String "Cisco IOS Software").Matches.Success -or ($ShowVersionText | Select-String "Cisco Nexus Operating System").Matches.Success){
                        $hostid.DeviceType="Cisco"
                        break
                    }elseif(($ShowVersionText | Select-String "Junos").Matches.Success -or ($ShowVersionText | Select-String "junos").Matches.Success -or ($ShowVersionText | Select-String "JUNOS Base OS boot").Matches.Success){
                        $hostid.DeviceType="Junos"
                        break
                    }else{
                        write-HostDebugText "Could not find type of device or unsupported device type."
                        write-host "Exiting. You need to fix this manually by either removing theses files $($file.fullname) or fixing them so the show version file is supported by this script."  -BackgroundColor red
                        Start-CleanupAndExit
                        break
                    }
                }
                if($file.name -like "*show ip arp*"){
                    $hostid.ShowIPArp=$file.fullname
                    break
                }

                if ($file.name -like "*show system info*") {
                    $hostid.ShowSystemInfo = $file.fullname
                    $hostid.DeviceType = "PaloAlto" # Set the device type here
                    break
                }
                if($file.name -like "*show arp*"){
                    $hostid.ShowArp=$file.fullname
                    break
                }
                if($file.name -like "*show ethernet-switching table*"){
                    $hostid.ShowEthernetSwitchingTable=$file.fullname
                    break
                }
                if($file.name -like "*show vlans detail*"){
                    $hostid.ShowVlansDetail=$file.fullname
                    break
                }
                if($file.name -like "*show asset all*"){
                    $hostid.ShowAssetAll=$file.fullname
                    break
                }

                #if($file.name -like "*show interface*"){ #Checkpoint and cisco show interfaces
                #    $hostid.ShowInterface=$file.fullname
                #    break
                #}
            }
        }
    }
    return $ArrayOfHostIDs
}

#helper function
function Set-MacAddressVendor {
    param(
        [Parameter(Mandatory=$true)]
        [PSObject]$HostObject,

        [Parameter(Mandatory=$true)]
        [Hashtable]$VendorMapping
    )

    # Check if the hostname is a MAC address-like string
    if ($HostObject.hostname -notmatch '^[0-9a-fA-F]{4}\.[0-9a-fA-F]{4}\.[0-9a-fA-F]{4}$' -and
        $HostObject.hostname -notmatch '^[0-9a-fA-F]{2}(?:[:-][0-9a-fA-F]{2}){5}$' -and
        $HostObject.hostname -notmatch '^[0-9a-fA-F]{12}$') {
        # If the hostname isn't a likely MAC address format, skip
        return
    }

    # Format the MAC address to a standard format (e.g., 00:00:00:00:00:00)
    $macAddress = ($HostObject.hostname -replace '\.|\-|\:','').ToUpper()
    $macFormatted = ($macAddress.Insert(2,':').Insert(5,':').Insert(8,':').Insert(11,':').Insert(14,':'))

    # Determine the vendor
    $vendorName = "UNKNOWN Vendor"
    if ($VendorMapping.ContainsKey($macFormatted.Substring(0,8))) {
        $vendorName = $VendorMapping[$macFormatted.Substring(0,8)]
    } elseif ($VendorMapping.ContainsKey($macFormatted.Substring(0,5))) {
        # Check for 4-byte OUI
        $vendorName = $VendorMapping[$macFormatted.Substring(0,5)]
    }

    # Update the HostTypeIfCDPorLLDP property with the vendor name
    # We use '=' to set the string value directly.
    $HostObject.HostTypeIfCDPorLLDP = $vendorName
}

# Helper function to check if two MAC addresses are from the same device block
function Test-MacProximity {
    param(
        [string]$Mac1,
        [string]$Mac2,
        [int]$Threshold = 256
    )
    # The hyphen '-' is now escaped with a backslash '\'
    $normMac1 = $Mac1.ToLower() -replace "[\:\-\.]"; $normMac2 = $Mac2.ToLower() -replace "[\:\-\.]"

    if ($normMac1.Length -ne 12 -or $normMac2.Length -ne 12) { return $false }
    if ($normMac1.Substring(0, 6) -ne $normMac2.Substring(0, 6)) { return $false }
    try {
        $val1 = [System.Convert]::ToInt64($normMac1.Substring(6, 6), 16)
        $val2 = [System.Convert]::ToInt64($normMac2.Substring(6, 6), 16)
        return [Math]::Abs($val1 - $val2) -le $Threshold
    } catch { return $false }
}


#This functions start the processing of files. This function requires the global variable $GDirectory to start.
#Input:Global variables.
#Output: A series of objects containing the processed config from the show commands. See ObjectFunctions.ps1 for the definitions of each object.
function Start-ProcessingFiles(){
    $files = Get-ChildItem $GDirectory -File -Recurse -Include *.txt
    [Array]$ArrayOfObjects=@() #Array of hosts all their networks,interfaces, bgp,cdp,etc
    [Array]$ArrayOfNetworks=@() #List of unique networks shared across all devices.
    [Array]$ArrayOfCDPDeviceIDs=@() #List of all cdp neighbor in host object form.
    [Array]$ArrayOfLLDPDeviceIDs=@() #List of LLDP neighbors in host object form
    [Array]$ArrayOfIPApr=@() #List on unique ip arp entries.
    [Array]$ArrayofGatewayHosts=@() #List of gateway objects. These are all of the endpoints for all routes.



    $ArrayOfHostIDs = Create-FileHostObjects -files $files


    # Determine a sensible throttle limit based on available processor cores
    $throttleLimit = [System.Environment]::ProcessorCount
    write-HostDebugText "Starting parallel processing with a throttle limit of $throttleLimit..." -ForegroundColor "Cyan"

    # 1. PROCESS ALL DEVICES IN PARALLEL
    # The output of the parallel loop (all the processed $Device objects) is collected into $processedDevices.
    $processedDevices = $ArrayOfHostIDs | ForEach-Object -Parallel {
        # Inside the script block, we use the '$using:' scope to access variables from the main script.
        # This is crucial for passing paths, templates, and other settings to each thread.

        $hostid = $_ # The current item from the pipeline

        # We must explicitly import modules needed by this thread.
        # This ensures all functions are available in the parallel runspace.
        # Runtime-modified variables:
        $GMacAddressToVendorMapping  = $using:GMacAddressToVendorMapping

        # Path variables (determined by params or runtime location):
        $GPathToScript               = $using:GPathToScript
        $GPathToPythonExe            = $using:GPathToPythonExe
        $GPathToPythonTextFSMScript  = $using:GPathToPythonTextFSMScript

        # "Constant" variables (loaded from configurationVariables.ps1 in the main script):
        $GTemplate                   = $using:GTemplate
        $GSkipCDPLLDPPhones          = $using:GSkipCDPLLDPPhones
        $GDrawPortsWithMacs          = $using:GDrawPortsWithMacs
        $GDrawAprEntries             = $using:GDrawAprEntries
        $SkipHostnameErrorCheck      = $using:SkipHostnameErrorCheck
        $GDebugingEnabled            = $using:GDebugingEnabled # For write-HostDebugText
        $GLastExecutionTime          = $using:GLastExecutionTime # For write-HostDebugText
        # --- END OF THREAD INITIALIZATION ---

        $hostid = $_

        # Import function definitions.
        # DO NOT import configurationVariables.ps1 here; its values are already captured above.
        Import-Module "$($GPathToScript)ObjectFunctions.ps1" -Force
        Import-Module "$($GPathToScript)HelperFunctions.ps1" -Force
        Import-Module "$($GPathToScript)CiscoConfigProcessingFunctions.ps1" -Force
        Import-Module "$($GPathToScript)CheckPointConfigProcessingFunctions.ps1" -Force
        Import-Module "$($GPathToScript)CiscoASAConfigProcessingFunctions.ps1" -Force
        Import-Module "$($GPathToScript)JunosConfigProcessingFunctions.ps1" -Force
        Import-Module "$($GPathToScript)PaloAltoConfigProcessingFunctions.ps1" -Force
        Import-Module -Name "$($GPathToScript)GETIPV4Subnet\GetIPv4Subnet.psm1" -Force

        function Add-HostDebugText(){
                param (
                [parameter(Mandatory=$true)]
                $HostObject, # The host object to which the debug log will be added
                [parameter(Mandatory=$true)]
                $text,
                $BackgroundColor,
                $ForegroundColor
            )

            # Set default foreground color if not provided
            if(-not($ForegroundColor)){
                $ForegroundColor="white"
            }
            # Set default BackgroundColor color if not provided
            if(-not($BackgroundColor)){
                $BackgroundColor="Black"
            }

            # Create a log entry object to store all relevant information
            $logEntry = [PSCustomObject]@{
                Timestamp       = Get-Date
                Text            = $text.trim()
                BackgroundColor = $BackgroundColor
                ForegroundColor = $ForegroundColor
            }

            # Add the log entry to the host object's debug log array
            $HostObject.DebugLog += $logEntry

        }
        $Device = $null # Reset device for each loop

        # NOTE: We pass $null for ArrayOfObjects because we cannot safely check for duplicates in parallel.
        # We will perform the duplicate check *after* all jobs are complete.
        switch($hostid.DeviceType){
            "Cisco"{
                $Device=Process-CiscoHostFiles -hostid $hostid -ArrayOfObjects $null
                if ($Device) { $Device.DeviceType="Cisco" }
            }
            "CiscoASA"{
                $Device=Process-CiscoASAHostFiles -hostid $hostid -ArrayOfObjects $null
                if ($Device) { $Device.DeviceType="CiscoASA" }
            }
            "CheckPoint"{
                $Device=Process-CheckPointHostFiles -hostid $hostid -ArrayOfObjects $null
                if ($Device) { $Device.DeviceType="CheckPoint" }
            }
            "Junos"{
                $Device=Process-JunosHostFiles -hostid $hostid -ArrayOfObjects $null
                if ($Device) { $Device.DeviceType="Junos" }
            }
            "PaloAlto"{
                $Device=Process-PaloAltoHostFiles -hostid $hostid -ArrayOfObjects $null
                if ($Device) { $Device.DeviceType="PaloAlto" }
            }
            default{
                # This write will appear in the console from the thread
                Write-Warning "Device type for $($hostid.HOSTID) is unknown or unsupported. Skipping."
            }
        }

        # Return the processed device object. It will be collected by ForEach-Object.
        return $Device

    } -ThrottleLimit $throttleLimit

    write-HostDebugText "Parallel processing complete. Aggregating results..." -ForegroundColor "Cyan"

	# --- Display all collected debug logs ---
	write-HostDebugText "Displaying all collected debug/error logs..." -ForegroundColor Yellow

	# Iterate through the main array of successfully processed devices.
	foreach ($device in $processedDevices) {
	    # Check if this device has any log entries.
	    if ($device.DebugLog.Count -gt 0) {
	        # Print a clear header for the device's logs.
	        Write-Host "`n--- Debug Logs for: $($device.hostname) ---" -BackgroundColor DarkCyan -ForegroundColor White

	        # Loop through each log entry for the current device.
	        foreach ($log in $device.DebugLog) {
	            $logMessage = "$($log.Timestamp) - $($log.Text)"
	            # Write the log to the console, applying the original colors.
	            Write-Host $logMessage -ForegroundColor $log.ForegroundColor -BackgroundColor $log.BackgroundColor
	        }
	    }
	}

    # 2. AGGREGATE RESULTS AND CHECK FOR DUPLICATES SEQUENTIALLY
    # This part runs after all parallel jobs are finished and uses your array definitions.

    $hostnameMap = @{}

    foreach ($device in ($processedDevices | Where-Object { $_ -ne $null })) {

        # --- Safety Check: Ensure the device has a hostname ---
        if ([string]::IsNullOrEmpty($device.hostname)) {
            Write-Warning "A device was found with no hostname. Skipping this entry."
            continue
        }

        # Check if a device with this hostname has already been processed.
        if ($hostnameMap.ContainsKey($device.hostname)) {
            # A device with the same hostname exists. We must now check its serial number.
            $originalDevice = $hostnameMap[$device.hostname]

            # --- Safety Check: Safely get the primary serial number from both devices ---
            $originalSerial = if ($originalDevice.Version -and $originalDevice.Version.Serial.Count -gt 0) {
                $originalDevice.Version.Serial[0]
            } else {
                $null
            }

            $currentSerial = if ($device.Version -and $device.Version.Serial.Count -gt 0) {
                $device.Version.Serial[0]
            } else {
                $null
            }

            # --- Compare Serial Numbers ---
            if ($originalSerial -eq $currentSerial) {
                Write-Host "DUPLICATE DEVICE: Skipping '$($device.hostname)' because a device with the same serial ('$($currentSerial)') already exists." -ForegroundColor Gray
                continue
            }
            else {
                if ([string]::IsNullOrEmpty($currentSerial)) {
                    Write-Warning "DUPLICATE HOSTNAME: '$($device.hostname)'. The new device has no serial number, so a unique name cannot be generated. Skipping."
                    continue
                }

                $originalHostname = $device.hostname
                $device.hostname = "$($originalHostname)_$($currentSerial)"
                Write-Host "Duplicate hostname '$($originalHostname)' found with a different serial number. Renaming device to '$($device.hostname)'." -ForegroundColor Yellow
            }
        }

        # Add the unique device to the map for future checks.
        $hostnameMap[$device.hostname] = $device

        # Add the processed data to the main arrays using the += operator.
        $ArrayOfObjects += $device

        # Safety Check: Ensure the ArrayOfNetworks property exists before adding.
        if ($null -ne $device.ArrayOfNetworks) {
           $ArrayOfNetworks += $device.ArrayOfNetworks
        }
    }

    write-HostDebugText "Processing Arp Entries" -ForegroundColor green
    #Create an array of ip ARP entries. This will be used when drawing layer 3 diagrams.
    $ArrayOfIPApr=$ArrayOfObjects | % {$_.IPArpEntries } | sort -Unique mac,ipaddress,interface


    write-HostDebugText "Processing Cluster ip addresses for checkpoint if any. " -ForegroundColor green
    #Find virtual interfaces on checkpoints. This could probably be expanded to other devices as needed if we lack information.
    foreach ($Device in $ArrayOfObjects |where {$_.DeviceType -eq "CheckPoint" }){
        foreach ($interface in $Device.interfaces){
            if($ArrayOfIPApr | where { $interface.macaddress -eq $_.mac} | where { $interface.ipaddress -ne $_.ipaddress}){
                $interface.ClusterIP=($ArrayOfIPApr | where { $interface.macaddress -eq $_.mac}| where { $interface.ipaddress -ne $_.ipaddress}).ipaddress
            }
        }
    }



    #Pre-Calculate all of the routes that flow out from an interface and sort them on the interface.
    #This is put here to reduce the amount of logic in other parts of the scrip
    write-HostDebugText "Calculating routes on each interface." -ForegroundColor green
    foreach ($Device in $ArrayOfObjects){
        foreach ($interface in $Device.interfaces | where { $_.ipaddress -and $_.shutdown -eq $false -and $_.IntStatus -notlike "*down*"}){
            $interface.RoutesForInterface=$Device.RoutingTable| where { $_.interface -eq $interface.Interface -and $_.routeprotocol -notmatch "Access-internal|local|connected|direct" } | sort gateway,subnet
            #$Device.RoutingTable| where { !($_.interface) -and $_.routeprotocol -notmatch "local|connected|direct"}
        }
    }


    write-HostDebugText "Processing Network Objects" -ForegroundColor green
    #Create a list of all networks shared across all devices.
    #Remove duplicates
    $ArrayOfNetworks = $ArrayOfNetworks | sort cidr -Unique |sort vlan
    #Add a color for every network
    $ArrayOfNetworks | % { $_.color = "$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0),$(Get-Random -Maximum 255 -Minimum 0)" }
    $ArrayOfNetworks = $ArrayOfNetworks | sort  NumberOfConnectors,vlan,cidr
    #Count the number of connectors to each network.
    foreach ($Device in $ArrayOfObjects){
        foreach ($interface in ($Device.interfaces | where { $null -ne $_.ipaddress   -and $_.shutdown -eq $false})){
            #Find vlan to connect to
            foreach ($network in $ArrayOfNetworks){
                if($interface.cidr -eq $network.cidr){
                    $network.NumberOfConnectors++
                    if($network.Routedvlan -eq "no vlan" -and $interface.Routedvlan -ne "no vlan"){
                        $network.Routedvlan = "vlan$($interface.Routedvlan)"
                    }
                    if($interface.RoutesForInterface.count -ne 0){
                        $network.NumberOfRoutedConnectors++
                    }
                    break
                }
            }
        }
    }


    #We don't care about vlans that have no layer 3 interface in the array of networks.
    $ArrayOfNetworks= $ArrayOfNetworks| where {$_.NumberOfConnectors -gt 0}
    write-HostDebugText "Processing network layer 3 ARP Entries and VLAN names" -ForegroundColor green
    #Get the name of the vlan and add the ARP entries to the object
    foreach ($network in $ArrayOfNetworks){
        foreach ($Device in $ArrayOfObjects){
            foreach ($vlan in ($Device.vlans| where{ $null -ne $_.name -and $_.name -ne "" -and $_.name -ne "No name"})){
                if($vlan.number -eq ($Network.RoutedVlan -replace "vlan",'')){
                    if($Network.NetworkName ){#if there are multiple names for the same vlan concat them.
                        if($Network.NetworkName -like "*$($vlan.name)*"){
                            break
                        }
                        $Network.NetworkName="$($Network.NetworkName)  -  $($vlan.name)"
                    }else{
                        $Network.NetworkName=$vlan.name
                    }
                    break
                }
            }
        }
        #This can be really slow don't process it if we don't need to.
        if($GDrawAprEntries){
            #Get all the ARP entries and attach them to the network object
            $network.ARPEntries=$ArrayOfIPApr | where {$_.cidr -eq $Network.cidr }
        }
    }

    # Display a status message for the user.
    write-HostDebugText "Linking cdp neighbours we have config for together" -ForegroundColor green

    # Iterate through each device object that has been created from a config file.
    foreach ($Device in $ArrayOfObjects){
        # For each device, iterate through its list of discovered CDP neighbors.
        foreach ( $cdpneighbor in $Device.cdpneighbors){

            # CASE 1: The neighbor's SystemName is missing. We must rely on the DeviceID, which might be messy.
            if($null -eq $cdpneighbor.SystemName -or $cdpneighbor.SystemName -eq ""){

                # Search for the neighbor device in our master list ($ArrayOfObjects).
                # The pipeline finds a device whose hostname matches the neighbor's DeviceID after cleaning it up.
                # REGEX CLEANUP:
                #   -replace "\(.*?\)",''       -> Removes serial numbers in parentheses, e.g., "device(FOC123456)".
                #   -replace "(.*?)\..*",'$1' -> Removes domain suffixes, e.g., "device.cisco.com".
                #   .trim()                    -> Removes any leading/trailing whitespace.
                # Then, it finds the specific interface on that neighbor that matches the remote port from the CDP data.
                if($ArrayOfObjects | where { $_.hostname -eq ($cdpneighbor.DeviceID -replace "\(.*?\)",'' -replace "(.*?)\..*",'$1').trim() } | %{ $_.interfaces} | where { $_.interface -eq  $cdpneighbor.InterfaceRemoteDevice }){

                    # If a match is found, create a direct REFERENCE to the neighbor's interface object.
                    # This links the two objects in memory for easy traversal later.
                    $cdpneighbor.PartnerEthernetInterface = [ref]($ArrayOfObjects | where { $_.hostname -eq ($cdpneighbor.DeviceID -replace "\(.*?\)",'' -replace "(.*?)\..*",'$1').trim() } | %{ $_.interfaces} | where { $_.interface -eq  $cdpneighbor.InterfaceRemoteDevice })

                    # Also, set a flag on the NEIGHBOR'S interface object to mark it as successfully linked.
                    # This is useful for drawing diagrams, as it confirms this interface is part of a known connection.
                    ($ArrayOfObjects | where { $_.hostname -eq ($cdpneighbor.DeviceID -replace "\(.*?\)",'' -replace "(.*?)\..*",'$1').trim() } | %{ $_.interfaces} | where { $_.interface -eq  $cdpneighbor.InterfaceRemoteDevice } ).IsLinkedToByCDPorLLDP = $true
                }

            # CASE 2: The neighbor's SystemName is available. This is a much cleaner and more reliable match.
            }else{
                # Find the neighbor by its SystemName and remote interface, then perform the same linking as above.
                if( $ArrayOfObjects | where { $_.hostname -eq $cdpneighbor.SystemName} | %{ $_.interfaces} | where { $_.interface -eq  $cdpneighbor.InterfaceRemoteDevice } ){
                    $cdpneighbor.PartnerEthernetInterface = [ref]($ArrayOfObjects | where { $_.hostname -eq $cdpneighbor.SystemName} | %{ $_.interfaces} | where { $_.interface -eq  $cdpneighbor.InterfaceRemoteDevice } )
                    ($ArrayOfObjects | where { $_.hostname -eq $cdpneighbor.SystemName} | %{ $_.interfaces} | where { $_.interface -eq  $cdpneighbor.InterfaceRemoteDevice } ).IsLinkedToByCDPorLLDP = $true
                }
            }
        }
    }

    # ==============================================================================
    # Linking LLDP neighbours with VERBOSE debug output
    # ==============================================================================



    write-HostDebugText "Building lookup tables for efficient neighbor linking..." -ForegroundColor green
    $deviceLookup = @{}
    $ArrayOfObjects.ForEach({ $deviceLookup[$_.hostname] = $_ })

    write-HostDebugText "Linking LLDP neighbours with prioritized matching and confidence scoring..." -ForegroundColor green

    foreach ($device in $ArrayOfObjects) {
        foreach ($lldpNeighbor in $device.LLDPNeighbors) {
            
            if ($lldpNeighbor.HasCDPNeighborEntry -or $lldpNeighbor.PartnerEthernetInterface) { continue }
            
            $foundInterface = $null
            $targetDevice = $null
            $matchMethod = "None"
            

            $cleanedHostname = if (-not [string]::IsNullOrEmpty($lldpNeighbor.Hostname)) {
                ($lldpNeighbor.Hostname -replace "\(.*?\)", '' -replace "(.*?)\..*", '$1').trim()
            }
            $originalHostname = $lldpNeighbor.Hostname
            

            $candidateDevice = $null

            if ($cleanedHostname -and $deviceLookup.ContainsKey($cleanedHostname)) {
                $candidateDevice = $deviceLookup[$cleanedHostname]
            }
            elseif ($originalHostname -and $deviceLookup.ContainsKey($originalHostname)) {
                $candidateDevice = $deviceLookup[$originalHostname]
            }
            else {

            }

            # --- Tier 1 & 2 Logic ---
            if ($candidateDevice) {



                # --- ADDED: Normalize remote interface names ---
                # Remove the trailing '.0' from LLDP data before matching
                $remoteInterfaceName = $lldpNeighbor.InterfaceRemoteDevice -replace '\.0$'
                $remoteInterfaceDesc = $lldpNeighbor.NeighborInterfaceDescription -replace '\.0$'


                
                # --- REPLACEMENT: New Tier 1 & 2 Logic ---
                # Tier 1: Match by Hostname using the NORMALIZED remote interface name
                $foundInterface = $candidateDevice.interfaces | Where-Object { $_.interface -eq $remoteInterfaceName } | Select-Object -First 1
                if ($foundInterface) {
                    $targetDevice = $candidateDevice
                    $matchMethod = "Hostname + Name"

                }
                
                # Tier 2: If Tier 1 fails, use the NORMALIZED description for matching
                elseif (-not [string]::IsNullOrEmpty($remoteInterfaceDesc)) {

                    
                    $foundInterface = $candidateDevice.interfaces | Where-Object {
                        $_.interface -eq $remoteInterfaceDesc -or
                        $_.description -eq $remoteInterfaceDesc
                    } | Select-Object -First 1
                    
                    if ($foundInterface) {
                        $targetDevice = $candidateDevice
                        $matchMethod = "Hostname + Desc"

                    }
                }
            }

            # Tier 3
            if (-not $foundInterface -and -not [string]::IsNullOrEmpty($lldpNeighbor.ManagementIP)) {
     
                $candidateDevice = $ArrayOfObjects | Where-Object { $_.ArrayOfIPAddresses -contains $lldpNeighbor.ManagementIP } | Select-Object -First 1
                if ($candidateDevice) {

                    $foundInterface = $candidateDevice.interfaces | Where-Object { $_.interface -eq $lldpNeighbor.InterfaceRemoteDevice } | Select-Object -First 1
                    if ($foundInterface) {
                        $targetDevice = $candidateDevice
                        $matchMethod = "Management IP"

                    }
                }
            }

            # --- If ANY tier found a link, score confidence and finalize ---
            if ($foundInterface) {
                $candidateMacs = @($targetDevice.Version.MacAddressArray) + @($targetDevice.interfaces.macaddress)
                $isMacProximate = $false
                foreach ($mac in ($candidateMacs | Where-Object { $_ } | Select-Object -Unique)) {
                    if (Test-MacProximity -Mac1 $lldpNeighbor.ChassisID -Mac2 $mac) {
                        $isMacProximate = $true
                        break
                    }
                }
                $confidence = if ($isMacProximate) { "High" } else { "Low" }
                
                # Link the objects by creating a direct reference using array indices
                $deviceIndex = [array]::IndexOf($ArrayOfObjects, $targetDevice)
                $interfaceIndex = [array]::IndexOf([array]$targetDevice.interfaces, $foundInterface)

                if ($deviceIndex -ge 0 -and $interfaceIndex -ge 0) {
                    $lldpNeighbor.PartnerEthernetInterface = [ref]$ArrayOfObjects[$deviceIndex].interfaces[$interfaceIndex]
                    $ArrayOfObjects[$deviceIndex].interfaces[$interfaceIndex].IsLinkedToByCDPorLLDP = $true
                }
                
                $lldpNeighbor | Add-Member -MemberType NoteProperty -Name "MatchConfidence" -Value $confidence -Force
                $lldpNeighbor | Add-Member -MemberType NoteProperty -Name "MatchMethod" -Value $matchMethod -Force
            }

            if ($foundInterface) {
                # SUCCESS CASE: Display the successful link information.
                $fromStr = "$($device.DeviceIdentifier) $($device.hostname)($($lldpNeighbor.InterfaceLocalDevice))"
                $toStr = "$($targetDevice.DeviceIdentifier) $($targetDevice.hostname)($($foundInterface.interface))"
                $confidenceColor = if ($confidence -eq "High") { "Green" } else { "Yellow" }
                
                Write-Host ("LINK: {0} -> {1} :: SUCCESS - Method: {2}, Confidence: {3}" -f $fromStr, $toStr, $matchMethod, $confidence) -ForegroundColor $confidenceColor
                
                if ($confidence -eq "Low") {
                    Write-Host "  └─ WARNING: Low confidence link. Neighbor Chassis ID '$($lldpNeighbor.ChassisID)' is not proximate to any known MAC on target device." -ForegroundColor DarkYellow
                }
            } else {
                # FAILURE CASE: Only show an error if we expected to find the device but couldn't link the interface.
                if ($cleanedHostname -and $deviceLookup.ContainsKey($cleanedHostname)) {
                    # The neighbor's hostname exists in our list of configured devices, but we couldn't find a matching interface.
                    $fromStr = "$($device.DeviceIdentifier) $($device.hostname)($($lldpNeighbor.InterfaceLocalDevice))"
                    $toStr = "$($lldpNeighbor.Hostname)($($lldpNeighbor.InterfaceRemoteDevice))"
                    $failReason = "Device found, but remote interface '$($lldpNeighbor.InterfaceRemoteDevice)' or its description could not be matched."
                    
                    Write-Host ("LINK: {0} -> {1} :: FAILED - {2}" -f $fromStr, $toStr, $failReason) -ForegroundColor Red
                }
                # If the cleanedHostname was not in the deviceLookup, we do nothing.
                # This suppresses messages for neighbors we don't have config files for.
            }

        }
    }

    write-HostDebugText "Creating host objects for cdpneighbors we don't have config for" -ForegroundColor green
    #These are cdp neighbors we don't have a config for but we know a little bit about.
    #This creates an array of host objects so that we can draw them as standard hosts.
    foreach ($Device in $ArrayOfObjects){
        foreach ( $cdpneighbor in ($Device.cdpneighbors | where { !$_.PartnerEthernetInterface } | sort -Descending -property @{Expression={[int]($_.InterfaceLocalDevice -replace '[a-zA-Z-]+','' -replace "/",'')} } )){ #sort order here is important as this is the order in which we will draw them
            if($GConsolidateNeighbors -and ($ArrayOfCDPDeviceIDs | where { $_.hostname -eq $cdpneighbor.DeviceID })){
                $CDPObject=$ArrayOfCDPDeviceIDs | where { $_.hostname -eq $cdpneighbor.DeviceID }
                $InterfaceObject=Create-InterfaceObject
                $InterfaceObject.interface=$cdpneighbor.InterfaceRemoteDevice
                $InterfaceObject.shutdown = $false
                $CDPObject.Interfaces+=$InterfaceObject
                foreach ($ipaddress in $cdpneighbor.InterfaceIPAddresses){
                    [Array]$CDPObject.ArrayOfIPAddresses+=[Array]$ipaddress
                }
            }else{
                $CDPObject=Create-HostObject
                $CDPObject.Origin="CDP"
                [Array]$CDPObject.ArrayOfIPAddresses=@()
                $CDPObject.Interfaces=@()
                $CDPObject.HostName=$cdpneighbor.DeviceID
                $CDPObject.Version=$cdpneighbor.Version
                $CDPObject.Platform=$cdpneighbor.Platform
                $CDPObject.Capabilities=$cdpneighbor.Capabilities
                $CDPObject.ParentObject=$cdpneighbor.ParentObject #The first object we have will be the parent object if there are multiple parent objects.
                $CDPObject.Description="`r`n$($cdpneighbor.Platform)`r`n$($cdpneighbor.Version)`r`n$($SystemName)"
                $InterfaceObject=Create-InterfaceObject
                $InterfaceObject.interface=$cdpneighbor.InterfaceRemoteDevice
                $InterfaceObject.shutdown = $false
                $CDPObject.Interfaces+=$InterfaceObject
                foreach ($ipaddress in $cdpneighbor.InterfaceIPAddresses){
                    [Array]$CDPObject.ArrayOfIPAddresses+=[Array]$ipaddress
                }
                $CDPObject.ArrayOfIPAddresses = $CDPObject.ArrayOfIPAddresses | sort -Unique
                $ArrayOfCDPDeviceIDs+=$CDPObject
            }
        }
    }

    write-HostDebugText "Creating host objects for LLDP neighbours we don't have config for" -ForegroundColor green
    #These are LLDP neighbours we don't have a config for but we know a little bit about.
    #This creates an array of host objects so that we can draw them as standard hosts.
    foreach ($Device in $ArrayOfObjects){
        foreach ( $LLDPNeighbor in ($Device.LLDPNeighbors | where { !$_.PartnerEthernetInterface } | sort -Descending InterfaceLocalDevice)){ #sort order here is important as this is the order in which we will draw them
            if($LLDPNeighbor.HasCDPNeighborEntry ){#Skip objects we have already drawn in CDPNeighbors
                continue
            }
            #If we are consolidating the neighbor so we get one object with multiple interfaces we need to
            #check to see if we have already made a object for this neighbor that we just need to add interfaces to.
            #The order in which to match.
            $MatchField=$null
            if($LLDPNeighbor.HostName){
                $MatchField=($ArrayOfLLDPDeviceIDs | where { $_.HostName -eq $LLDPNeighbor.HostName })
            }else{
                $MatchField=($ArrayOfLLDPDeviceIDs | where { $_.ChassisID -eq $LLDPNeighbor.ChassisID })
            }
            if($GConsolidateNeighbors -and $MatchField){
                $LLDPObject=$MatchField
                $InterfaceObject=Create-InterfaceObject
                $InterfaceObject.interface=$LLDPNeighbor.InterfaceRemoteDevice
                $InterfaceObject.shutdown = $false
                $LLDPObject.Interfaces+=$InterfaceObject
                [Array]$LLDPObject.ArrayOfIPAddresses+=[Array]$LLDPNeighbor.ManagementIP
            }else{
                $LLDPObject=Create-HostObject
                $LLDPObject.Origin="LLDP"
                $LLDPObject.Interfaces=@()
                [Array]$LLDPObject.ArrayOfIPAddresses=@()
                $LLDPObject.HostName=$LLDPNeighbor.Hostname
                $LLDPObject.ParentObject=$LLDPNeighbor.ParentObject #The first object we have will be the parent object if there are multiple parent objects.
                $InterfaceObject=Create-InterfaceObject
                $InterfaceObject.interface=$LLDPNeighbor.InterfaceRemoteDevice
                $InterfaceObject.shutdown = $false
                $LLDPObject.Interfaces+=$InterfaceObject
                if($LLDPNeighbor.ManagementIP){
                    [Array]$LLDPObject.ArrayOfIPAddresses+=[Array]$LLDPNeighbor.ManagementIP
                }
                $LLDPObject.Description="`r`n$($LLDPNeighbor.SystemDescription)`r`n$($LLDPNeighbor.CAPABILITIES)`r`n$($LLDPNeighbor.ManagementIP)`r`n$($LLDPNeighbor.$SERIAL)"
                $ArrayOfLLDPDeviceIDs+=$LLDPObject
            }
            $LLDPObject.ArrayOfIPAddresses=$LLDPObject.ArrayOfIPAddresses | sort -Unique
        }
    }

    #Find spanning root bridges for each device.
    write-HostDebugText "Getting Spanning tree root bridge for each device." -ForegroundColor green
    foreach ($Device in $ArrayOfObjects){
        if($Device.SpanningTree){#Does this device have some kindof spanning-tree?
            $Device.SpanningTree.RootBridgeForvlans=$Device.SpanningTree.SpanningTreeArray | where { $null -ne $_.rootbridge } | %{[int]$_.vlanid}
            #Do we have a spanning tree mode set. Nexus switches don't have commands like "spanning-tree mode pvst" in show run with a default config.
            #Pull the mode off one of the interfaces if this is the case.
            if($null -eq $Device.SpanningTree.SpanningTreeMode -or $Device.SpanningTree.SpanningTreeMode -eq ""){
                $Device.SpanningTree.SpanningTreeMode = $Device.SpanningTree.SpanningTreeArray | where { $null -ne $_.protocol -or $_.protocol -ne "" } | select -first 1 | % {$_.protocol}
            }
        }
    }

    # This is the matching logic behind linking interfaces which have a gateway so we can draw a route diagram.
    write-HostDebugText "Linking Layer 3 interfaces to Gateways and creating ARP hosts." -ForegroundColor green

###################################################################################################################################################

###################################################################################################################################################
# This is the matching logic behind linking interfaces which have a gateway so we can draw a route diagram.
write-HostDebugText "Linking Layer 3 interfaces to Gateways and creating ARP hosts." -ForegroundColor green

# Pre-build lookup tables for faster searching
$InterfaceLookup = @{}
foreach ($device in $ArrayOfObjects) {
    foreach ($intf in $device.interfaces) {
        if (-not $intf.shutdown) {
            foreach ($key in @($intf.IPAddress, $intf.ClusterIP, $intf.Standbyip, $intf.SecondaryIPAddress)) {
                if ($key) { $InterfaceLookup[$key] = $intf }
            }
        }
    }
}

$GatewayHostsLookup = @{}
foreach ($gwHost in $ArrayofGatewayHosts) {
    # Filter for non-null IPs before adding to the lookup
    foreach ($ip in ($gwHost.arrayofipaddresses | Where-Object { $_ })) {
        $GatewayHostsLookup[$ip] = $true
    }
}

$CDPLookup = @{}
foreach ($CDPDevice in $ArrayOfCDPDeviceIDs) {
    foreach ($ip in ($CDPDevice.ArrayOfIPAddresses | Where-Object { $_ })) {
        $CDPLookup[$ip] = $CDPDevice
    }
}

$LLDPLookup = @{}
foreach ($LLDPDevice in $ArrayOfLLDPDeviceIDs) {
    foreach ($ip in ($LLDPDevice.ArrayOfIPAddresses | Where-Object { $_ })) {
        $LLDPLookup[$ip] = $LLDPDevice
    }
}

# Cache last gateway so we don't reprocess the same one
$LastGatewayCache = @{}

foreach ($device in $ArrayOfObjects) {
    foreach ($interface in $device.interfaces | Where-Object { $_.RoutesForInterface }) {
        foreach ($route in ($interface.RoutesForInterface | Where-Object { $_.gateway } | Sort-Object gateway)) {

            if ($LastGatewayCache.ContainsKey($route.gateway)) {
                $route.GatewayLink = $LastGatewayCache[$route.gateway]
                continue
            }

            # Step 1: Direct interface match in a device we have config for.
            if ($InterfaceLookup.ContainsKey($route.gateway)) {
                $route.GatewayLink = [ref]$InterfaceLookup[$route.gateway]
                $LastGatewayCache[$route.gateway] = $route.GatewayLink
                continue
            }

            # Step 2: Gateway already created as a gateway host object?
            if ($GatewayHostsLookup.ContainsKey($route.gateway)) {
                continue
            }

            # Step 3: No direct match, so create a new gateway host from ARP or as a placeholder.
            $HostGatewayObject = $null
            $interfaceObject = $null
            $NewObjectToCreate = $device.IPArpEntries | Where-Object { $_.ipaddress -eq $route.gateway }

            if ($NewObjectToCreate) {
                $HostGatewayObject = Create-HostObject
                $HostGatewayObject.Origin = "ARP"
                [array]$HostGatewayObject.arrayofipaddresses += [array]$NewObjectToCreate.ipaddress
                $HostGatewayObject.hostname = "$($NewObjectToCreate.VendorCompanyName)`r`n$($NewObjectToCreate.MAC)"
            }
            else {
                # No ARP entry, create a basic placeholder
                $HostGatewayObject = Create-HostObject
                $HostGatewayObject.Origin = "RoutingTable"
                $HostGatewayObject.hostname = "Unknown`r`n$($route.gateway)"
                [array]$HostGatewayObject.arrayofipaddresses += [array]$route.gateway
            }

            # Create the interface for the new HostGatewayObject
            $interfaceObject = Create-InterfaceObject
            $interfaceObject.shutdown = $false
            $interfaceObject.interface = "Unknown Interface"
            $interfaceObject.IPAddress = $route.gateway
            $interfaceObject.cidr = $interface.cidr # Inherit CIDR from the source interface
            $HostGatewayObject.interfaces += $interfaceObject


            # Step 4: Enrich the new gateway object with CDP/LLDP info if available.
            # This section does NOT set the GatewayLink, it only adds data to the HostGatewayObject.
            if ($CDPLookup.ContainsKey($route.gateway)) {
                $CDPDevice = $CDPLookup[$route.gateway]
                $HostGatewayObject.Description = $CDPDevice.Description
                [array]$HostGatewayObject.arrayofipaddresses += $CDPDevice.arrayofipaddresses
            }
            elseif ($LLDPLookup.ContainsKey($route.gateway)) {
                $LLDPDevice = $LLDPLookup[$route.gateway]
                $HostGatewayObject.Description = $LLDPDevice.Description
                [array]$HostGatewayObject.arrayofipaddresses += $LLDPDevice.arrayofipaddresses
            }

            # Step 5: Finalize the link. THIS IS THE CRITICAL FIX.
            # Just like the old code, we ALWAYS link to the interface object of the gateway.
            $route.GatewayLink = [ref]$interfaceObject

            # Clean up the IP list and save the new gateway host
            $HostGatewayObject.arrayofipaddresses = $HostGatewayObject.arrayofipaddresses | Where-Object { $_ } | Sort-Object -Unique
            $ArrayofGatewayHosts += $HostGatewayObject

            foreach ($ip in $HostGatewayObject.arrayofipaddresses) {
                $GatewayHostsLookup[$ip] = $true
            }

            # Cache this gateway result for the next route
            $LastGatewayCache[$route.gateway] = $route.GatewayLink
        }
    }
}
###################################################################################################################################################



###################################################################################################################################################
    # This loop enriches the gateway host objects with BGP ASN information if available.
    write-HostDebugText "Updating BGP ASN for gateway hosts." -ForegroundColor green
    foreach ($device in $ArrayOfObjects) {
        # Only process devices that have BGP neighbor information.
        if ($device.BGPNeighbors) {
            foreach ($bgpNeighbor in $device.BGPNeighbors) {
                # Find the gateway host object whose IP address matches the BGP neighbor's IP.
                $gatewayHost = $ArrayofGatewayHosts | Where-Object { $_.ArrayOfIPAddresses -contains $bgpNeighbor.NEIGHBOR } | Select-Object -First 1
               
                # If a corresponding gateway host is found and it has a remote AS number...
                if ($gatewayHost -and $bgpNeighbor.REMOTE_AS) {
                    # ...update the gateway host's BGP_AS_Number property.
                    $gatewayHost.BGP_AS_Number = $bgpNeighbor.REMOTE_AS
                }
            }
        }
    }

    write-HostDebugText "Marking interfaces for 'Layer 3 Routes Only' diagram." -ForegroundColor green
    $AllRoutableObjects = $ArrayOfObjects + $ArrayofGatewayHosts
    foreach ($device in $AllRoutableObjects) {
        if ($device.interfaces) {
            foreach ($interface in ($device.interfaces | Where-Object { $_.RoutesForInterface })) {
                 if ($interface.RoutesForInterface.Count -gt 0) {
                    # This is a source interface with routes, so it should be drawn.
                    $interface.DrawOnRoutesOnlyDiagram = $true

                    # Now, find and mark the destination interface for each route.
                    foreach ($route in $interface.RoutesForInterface) {
                        if ($route.GatewayLink) {
                            # GatewayLink is a reference to the target interface object.
                            $targetInterface = $route.GatewayLink.Value
                            if ($targetInterface) {
                                # Mark the target interface to be drawn.

                                $targetInterface.DrawOnRoutesOnlyDiagram = $true
                            }
                        }
                    }
                 }
            }
        }
    }

    write-HostDebugText "Marking interfaces for 'Layer 3 Routes Only' diagram (Pass 2: HSRP Partners)..." -ForegroundColor green

    # --- PASS 2: Find any marked interface that has a standby IP, then find and mark its partners. ---
    # Get a unique list of all standby IPs from interfaces that were marked in Pass 1.
    $activeStandbyIPs = $AllRoutableObjects | ForEach-Object { $_.interfaces } | Where-Object { $_.DrawOnRoutesOnlyDiagram -and $_.standbyip } | Select-Object -ExpandProperty standbyip -Unique

    if ($activeStandbyIPs) {
        # Find every interface across all devices that uses one of these active standby IPs.
        $allPartnerInterfaces = $AllRoutableObjects | ForEach-Object { $_.interfaces } | Where-Object {
            $hasSharedStandbyIp = $false
            # The -contains operator works correctly whether $_.standbyip is a single string or an array.
            foreach($ip in $activeStandbyIPs) {
                if (@($_.standbyip) -contains $ip) {
                    $hasSharedStandbyIp = $true
                    break
                }
            }
            $hasSharedStandbyIp
        }

        # Mark every found partner interface to be drawn.
        foreach ($partner in $allPartnerInterfaces) {
            $partner.DrawOnRoutesOnlyDiagram = $true
        }
    }
    write-HostDebugText "Setting CDP and LLDP vendor type. " -ForegroundColor green


    # Assume $ArrayOfCDPDeviceIDs and $ArrayOfLLDPDeviceIDs are populated
    # Assume $GMacAddressToVendorMapping is populated

    # Loop through the CDP devices
    foreach ($cdpDevice in $ArrayOfCDPDeviceIDs) {
        Set-MacAddressVendor -HostObject $cdpDevice -VendorMapping $GMacAddressToVendorMapping
    }

    # Loop through the LLDP devices
    foreach ($lldpDevice in $ArrayOfLLDPDeviceIDs) {
        Set-MacAddressVendor -HostObject $lldpDevice -VendorMapping $GMacAddressToVendorMapping
    }

    return $ArrayOfNetworks,$ArrayOfObjects,$ArrayOfCDPDeviceIDs,$ArrayOfLLDPDeviceIDs,$ArrayOfIPApr,$ArrayofGatewayHosts
}




