# Overview
Here is a very basic way of collecting the show commands from multiple switches,routers,firewalls,etc. This process allows you to run one or serval commands on a device and collect the output. 

There are much better ways of doing this however this one is very easy to do.
It could also be modified to run any command you wish via ssh. 


# Step 1
Open powershell so the commands below can be copy and pasted in and run manually

# Step 2
Fill in the details below and run this section. 

```powershell
$Pass="xxxx"
$username="xxx"

# If you have multiple creds you can create multiple variables like this.
$AnotherPass = "yyyy"
```

# Step 3 
Edit the following array adding and removing devices as required.
You can use different passwords like example number 2 with `$AnotherPass`

```powershell
$NetworkDevices=@(
    @("10.147.224.67", $username, $Pass),
    @("10.147.224.66", $username, $Pass),
    @("10.147.224.6", $username, $AnotherPass),
    @("10.147.224.68", $username, $Pass)
)
```

# Step 4
Copy and paste the above code into powershell manually. 
You will need to press Y and then enter to accept the key. 
It is necessary to accept the Host key. Unfortunately it is not possible to bypass this step as plink.exe / putty doesn't permit it. 
This is only necessary to do once per ip address as the key is save into the registry. 
This should display the out of show version or give a error that will need to be resolved. 
Note: You may wish to change the command below if the device is not a cisco. 

```powershell
# Cisco
$Commands = @("show version")
# Junos
# $Commands = @("show version|no-more")
# Palo alto
# $Commands = @("show sysinfo")

foreach ($Device in $NetworkDevices){
	write-host $Device[0] -ForegroundColor green
	foreach ($command in $Commands){
		$CommandResults=""
		write-host $command -ForegroundColor red
		# This now correctly uses the password associated with the device in the array
		$CommandResults = .\plink.exe -a "$($Device[1])@$($Device[0])" -pw "$($Device[2])" "$($command)"
		write-host $CommandResults -ForegroundColor green
	}
	write-host (get-date) -ForegroundColor red
}
```

# Step 5 
Change the folder where you want to store the config. Note this must have a trailing `\`

```powershell
$Folder="C:\code\2022-05-05-2\" #Folder where you want to save the files
```

# Step 6
Create a array of commands you want to run on the switch / router / firewall. Here are some examples.

### Cisco
```powershell
$Commands= @(
    # --- System, Hardware & Configuration ---
    "show version",
    "show run",
    "show logging",
    "show history",
    "show inventory",
    "show license all",
    "show switch detail",
    "show processes cpu",
    "show processes cpu history",
    "show environment",
    "show environment all",
    "show env power all",

    # --- Interfaces ---
    "show interface",
    "show ip interface brief",
    "show interface status",
    "show interface description",
    "show interface trunk",
    "show interface counter",
    "show interfaces counters errors",
    "show interfaces transceiver detail",

    # --- Layer 2 Switching ---
    "show vlan",
    "show mac address-table",
    "show etherchannel summary",
    "show port-channel summary",
    "show vpc brief",
    "show vpc",
    "show lldp neighbors",
    "show lldp neighbors detail",
    "show cdp neighbors",
    "show cdp neighbors detail",
    "show vtp status",
    "show spanning-tree",
    "show spanning-tree summary",
    "show spanning-tree root",
    "show spanning-tree blockedports",
    "show lacp",
    "show lacp counters",
    "show lacp internal",
    "show lacp neighbor detail",
    
    # --- Layer 3 & General Routing ---
    "show ip route",
    "show ip route vrf `*",
    "show ip route vrf all",
    "show vrf",
    "show protocols",
    "show ip arp",
    "show standby",
    "show hsrp",
    "show hsrp all",
    "show bfd sessions",
    "show bfd neighbors details",

    # --- BGP Routing Protocol ---
    "show ip bgp",
    "show ip bgp summary",
    "show ip bgp neighbors",
    "show ip bgp database",
    "show ip bgp ipv4 all",
    "show ip bgp ipv6 all",
    "show ip bgp vpnv4 all neighbors",

    # --- OSPF Routing Protocol ---
    "show ospf neighbor",
    "show ospf enabled interfaces",
    "show ip ospf interface brief",
    "show ip ospf database",
    "show ip ospf database router",
    "show ip ospf database network",

    # --- EIGRP Routing Protocol ---
    "show eigrp neighbor",
    "show ip eigrp topology",

    # --- ISIS & RIP Routing Protocols ---
    "show isis adjacency",
    "show isis database",
    "show isis topology",
    "show clns interface",
    "show clns is-neighbors",
    "show clns is-neighbors detail",
    "show ip rip database",

    # --- Forwarding, QoS & Policy ---
    "show cef interface",
    "show ip cef detail",
    "show cef linecard detail",
    "show forwarding ipv4 route",
    "show forwarding adjacency",
    "show qos",
    "show queue",
    "show queueing",
    "show policy-map interface input",
    "show policy-map interface output",
    "show policy-map interface brief",
    "show hqf interface",
    "show table-map",

    # --- Security & Services ---
    "show ntp status",
    "show snmp",
    "show ip nat translations",
    "show port-security",
    "show monitor session all",
    "show monitor session local",
    "show monitor session remote",

    # --- MPLS ---
    "show mpls traffic-eng forwarding-adjacency"
)
```
### CheckPoint
```powershell
$Commands= @(
    # --- System, Hardware & Configuration ---
    "show version all",
    "show configuration",
    "show uptime",
    "show sysenv all",
    "show asset all",
    "show ntp active",
    "show ntp servers",

    # --- Interfaces & Layer 2 ---
    "show interfaces all",
    "show arp dynamic all",

    # --- Routing & Layer 3 ---
    "show route all",
    "show ospf summary",
    "show ospf neighbors detailed",
    "show ospf interfaces detailed",
    "show bgp summary",
    "show bgp peers detailed",
    "show rip summary",
    "show pbr summary",
    "show pbr rules",

    # --- High Availability & VPN ---
    "show cluster state",
    "show vrrp summary",
    "show vpn tunnels"
)
```

### Cisco ASA
```powershell
$Commands= @(
    # --- System & Configuration ---
    "show version",
    "show configuration",
    "show inventory",
    "show environment",
    "show context",
    "show context count",
    "changeto system",

    # --- Interfaces & Layer 2 ---
    "show interface",
    "show interface summary",
    "show port-channel summary",
    "show port-channel detail",
    "show bridge-group",
    
    # --- Routing & Layer 3 ---
    "show ip",
    "show route",
    "show arp",
    "show policy-route",
    "show bgp summary",
    "show bgp neighbors",
    "show ospf neighbor detail",
    "show eigrp neighbors",
    "show eigrp topology",

    # --- High Availability & Clustering ---
    "show failover",
    "show cluster info",

    # --- Security, Services & VPN ---
    "show firewall",
    "show zone",
    "show traffic",
    "show vpn-sessiondb summary",
    "show ipsec sa summary",
    "show ipsec stats",
    "show ntp status"
)
```

### PA firewall
```powershell
$Commands = @(
    # --- System, Hardware & Configuration ---
    "show system info",
    "show config running",
    "request license info",
    "show system environment", # More detailed than chassis inventory
    "show running resource-monitor",
    "show ntp",
    "show running snmp-server",

    # --- Interfaces & Layer 2 ---
    "show interface all",      # Shows both physical and logical with status
    "show interface logical",  # Best for getting IP, Zone, and VRF info
    "show lldp neighbors-info all",
    "show cdp neighbors-info all",
    "show lacp aggregate-ethernet all",
    "show mac all",            # For interfaces in L2/v-wire mode

    # --- Routing & Layer 3 ---
    "show routing route all",  # 'all' is crucial for multi-VRF environments
    "show routing virtual-router",
    "show arp all",
    "show routing fib",        # The actual hardware forwarding table
    "show routing protocol bgp summary",
    "show routing protocol ospf neighbor",
    
    # --- High Availability ---
    "show high-availability all",
    "show high-availability state", # Concise summary of HA status

    # --- Security, Policy & VPN ---
    "show zone",
    "show session info",
    "show running security-policy",
    "show running nat-policy",
    "show vpn ike-gateway all",
    "show vpn ipsec-sa all"
)
```

### WLC
```powershell
$Commands= @(
    # --- System & Configuration ---
    "show run-config",
    "show run-config commands",
    "show sysinfo",
    "show logging",
    "show license all",
    
    # --- AP & Wireless Management ---
    "show ap summary",
    "show ap inventory all",
    "show ap cdp all",
    "show wlan summary",
    "show wlan apgroups",
    "show rf-profile summary",
    "show guest-lan summary",

    # --- Mobility & Roaming ---
    "show mobility summary",
    "show mobility anchor",
    "show mobility ap-list",
    
    # --- Interfaces & Ports ---
    "show network summary",
    "show system interfaces",
    "show interface detailed virtual",
    "show interface detailed management",
    "show port detailed-info",
    "show port vlan",
    "show cdp entry all",
    
    # --- Network Services & Routing ---
    "show route summary",
    "show system route",
    "show dhcp summary",
    "show ldap summary",
    "show tacacs summary",
    "show rules"
)
```

### Blue coat 
```
--- System & Configuration ---
show version
show general
show licenses
show tcp-ip

--- Interfaces & Network ---
show interface all
show bridge
show virtual-ip
show private-network

--- Routing & Layer 3 ---
show routing-domain
show ip-default-gateway
show ip-route-table
show static-routes
show arp-table

--- Proxy Services & Policy ---
show accelerated-pac
show proxy-services
show management-services
show policy config
show forwarding

--- High Availability & Services ---
show failover configuration
show dns
show dns-forwarding
show ntp
show wccp status
```

### Juniper (XML Output)
```powershell
$Commands= @(
# --- System, Hardware & Configuration ---
"show version | display xml | no-more",
"show configuration | display xml | no-more",
"show protocols | display xml | no-more",
"show system license | display xml | no-more",
"show chassis hardware | display xml | no-more",
"show chassis environment | display xml | no-more",
"show chassis power | display xml | no-more",
"show virtual-chassis | display xml | no-more",

# --- Interfaces ---
"show interfaces | display xml | no-more",
"show interfaces terse | display xml | no-more",
"show interfaces detail | display xml | no-more",
"show interfaces extensive | display xml | no-more",
"show interfaces descriptions | display xml | no-more",
"show interfaces diagnostics optics | display xml | no-more",

# --- Layer 2 Switching ---
"show vlans | display xml | no-more",
"show ethernet-switching table | display xml | no-more",
"show ethernet-switching interfaces | display xml | no-more",
"show spanning-tree bridge | display xml | no-more",
"show spanning-tree interface | display xml | no-more",
"show lldp neighbors | display xml | no-more",
"show lacp interfaces | display xml | no-more",
"show multi-chassis mc-lag | display xml | no-more",
"show ethernet-switching-options secure-access-port | display xml | no-more",

# --- Layer 3 & General Routing ---
"show route | display xml | no-more",
"show route instance | display xml | no-more",
"show arp no-resolve | display xml | no-more",
"show vrrp | display xml | no-more",
"show bfd session detail | display xml | no-more",
"show route forwarding-table | display xml | no-more",
"show route forwarding-table detail | display xml | no-more",

# --- BGP Routing Protocol ---
"show bgp summary | display xml | no-more",
"show bgp summary family inet-vpn | display xml | no-more",
"show bgp neighbor | display xml | no-more",
"show route protocol bgp | display xml | no-more",
"show route advertising-protocol bgp | display xml | no-more",
"show route table inet.0 protocol bgp | display xml | no-more",
"show route table inet6.0 protocol bgp | display xml | no-more",

# --- OSPF Routing Protocol ---
"show ospf neighbor | display xml | no-more",
"show ospf interface | display xml | no-more",
"show ospf database | display xml | no-more",

# --- ISIS Routing Protocol ---
"show isis interface | display xml | no-more",
"show isis adjacency | display xml | no-more",
"show isis database | display xml | no-more",
"show isis topology | display xml | no-more",

# --- Other Routing Protocols ---
"show route protocol rip | display xml | no-more",

# --- Services, Policy & Advanced Features ---
"show ntp status | display xml | no-more",
"show snmp statistics | display xml | no-more",
"show policy | display xml | no-more",
"show class-of-service interface | display xml | no-more",
"show security nat source rule all | display xml | no-more",
"show forwarding-options port-mirroring | display xml | no-more",
"show ted database | display xml | no-more"
)
```

### Juniper (Set/Text Output)
```powershell
$Commands= @(
    "show log messages  | no-more",
    "show configuration  | no-more",
    "show configuration | display set | no-more",
    "show spanning-tree bridge  | no-more",
    "show spanning-tree interface  | no-more",
    "show spanning-tree interface detail | no-more",
    "show lldp neighbors  | no-more",
    "show ethernet-switching table detail  | no-more",
    "show arp  | no-more",
    "show route all  | no-more",
    "show vrrp  | no-more",
    "show virtual-chassis device-topology  | no-more",
    "show virtual-chassis   | no-more",
    "show system uptime  | no-more",
    "show version   | no-more",
    "show version detail all-members  | no-more",
    "show interfaces detail  | no-more",
    "show vlans detail  | no-more",
    "show lacp interfaces  | no-more",
    "show chassis  | no-more"
)
```

### Fortigate 
```powershell
diagnose lldprx neighbor summary 
diagnose lldprx neighbor details 
diagnose lldprx port details
diagnose lldprx port summary 
diagnose lldprx port neighbor 
get system status
show full-configuration
get system fortiguard
get system performance status
get system ntp
show system snmp sysinfo
show system interface     
get router info routing-table all 
get system arp
get router info kernel  
get router info bgp summary
get router info ospf neighbor
get system ha status
diagnose sys session stat
show firewall policy
show firewall central-snat-map   
get vpn ipsec tunnel summary
show vpn ipsec phase1-interface
show vpn ipsec phase2-interface
```



# Step 7
Run the below and the output of the show commands will be put into files for you. 

```powershell
foreach ($Device in $NetworkDevices){
    write-host $Device[0] -BackgroundColor Red
	foreach ($command in $Commands){
		$CommandResults=""
		write-host $command -BackgroundColor Red
        # This now correctly uses the password associated with the device in the array
		$CommandResults= .\plink.exe -batch -a "$($Device[1])@$($Device[0])" -pw "$($Device[2])" "$($command)"
		$CommandResults | out-file "$($Folder)$($Device[0]).$($command -replace "\*","star" -replace  "\s*\|\s*display\s*xml\s*",'' -replace    "\s*\|\s*no-more\s*",'' -replace "\s*\|\s*display set\s*","displayset").txt"
	}
	write-host (get-date) -BackgroundColor Red
}
```

# Step 7 V2
If you have powershell 7 you can do Parallel. This will do 10 devices at a time. 
Run the below and the output of the show commands will be put into files for you. 

```powershell
$NetworkDevices | ForEach-Object -Parallel {
    $Device = $_
    Write-Host $Device[0] -BackgroundColor Red

    foreach ($command in $using:Commands) {
        Write-Host $command -BackgroundColor Red
        $CommandResults = .\plink.exe -batch -a "$($Device[1])@$($Device[0])" -pw "$($Device[2])" "$command"

        $SafeCommand = $command -replace "\*", "star" `
                                -replace "\s*\|\s*display\s*xml\s*", "" `
                                -replace "\s*\|\s*no-more\s*", "" `
                                -replace "\s*\|\s*display set\s*", "displayset"

        $OutFile = Join-Path $using:Folder "$($Device[0]).$SafeCommand.txt"
        $CommandResults | Out-File $OutFile -Force
    }

    Write-Host (Get-Date) -BackgroundColor Red
} -ThrottleLimit 10
```






# known issues
* Plink has issues with paging on some devices.
* Plink also doesn't support enable passwords or expert passwords. 
````
