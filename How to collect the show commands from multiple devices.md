# Overview
Here is a very basic way of collecting the show commands from multiple switches,routers,firewalls,etc. There are much better ways of doing this however this one is very easy to do.
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
    "show ip route vrf `*",
    "show ip route vrf all",
    "show snmp",
    "show logging",
    "show license all",
    "show ntp status",
    "show environment all",
    "show environment",
    "show env power all",
    "show switch detail",
    "show interfaces transceiver detail",
    "show vtp status",
    "show interfaces counters errors",
    "show processes cpu history",
    "show processes cpu",
    "show version",
    "show run",
    "show cdp neighbors",
    "show cdp neighbors detail",
    "show lldp neighbors",
    "show lldp neighbors detail",
    "show interface description",
    "show interface status",
    "show interface counter",
    "show interface counter error",
    "show interface trunk",
    "show interface",
    "show ip interface brief",
    "show vlan",
    "show spanning-tree",
    "show spanning-tree summary",
    "show spanning-tree root",
    "show spanning-tree blockedports",
    "show vpc brief",
    "show vpc",
    "show ip bgp summary",
    "show ip bgp",
    "show ip bgp database",
    "show ip bgp neighbors",
    "show ip bgp ipv4 all",
    "show ip bgp ipv6 all",
    "show ip rip database",
    "show eigrp neighbor",
    "show ospf neighbor",
    "show ospf enabled interfaces",
    "show mac address-table",
    "show ip arp",
    "show etherchannel summary",
    "show port-channel summary",
    "show ip route",
    "show standby",
    "show vrf",
    "show inventory",
    "show hsrp all",
    "show hsrp",
    "show bfd sessions",
    "show bfd neighbors details",
    "show ip bgp vpnv4 all neighbors",
    "show forwarding ipv4 route",
    "show forwarding adjacency",
    "show ip eigrp topology",
    "show ip ospf interface brief",
    "show ip ospf database router",
    "show ip ospf database network",
    "show ip ospf database",
    "show policy-map interface input",
    "show policy-map interface output",
    "show policy-map interface brief",
    "show queue",
    "show queueing",
    "show qos",
    "show hqf interface",
    "show table-map",
    "show history",
    "show ntp status",
    "show protocols",
    "show ip nat translations",
    "show standby",
    "show monitor session all",
    "show port-security",
    "show monitor session remote",
    "show monitor session local",
    "show lacp",
    "show lacp counters",
    "show lacp internal",
    "show lacp neighbor detail",
    "show cef interface",
    "show ip cef detail",
    "show cef linecard detail",
    "show mpls traffic-eng forwarding-adjacency",
    "show isis database",
    "show isis adjacency",
    "show clns interface",
    "show isis topology",
    "show clns is-neighbors",
    "show clns is-neighbors detail"
)
```
### CheckPoint
```powershell
$Commands= @(
    "show sysenv all",
    "show asset all",
    "show ospf neighbors detailed",
    "show ospf summary",
    "show rip summary",
    "show ospf interfaces detailed",
    "show bgp summary",
    "show bgp peers detailed",
    "show version all",
    "show interfaces all",
    "show arp dynamic all",
    "show route all",
    "show configuration",
    "show uptime",
    "show pbr summary",
    "show pbr rules",
    "show ntp active",
    "show ntp servers",
    "show vpn tunnels",
    "show vrrp summary",
    "show cluster state"
)
```

### Cisco ASA
```powershell
$Commands= @(
    "show version",
    "show ip",
    "show environment",
    "show failover",
    "show bgp summary",
    "show bgp neighbors",
    "show ospf neighbor detail",
    "show eigrp neighbors",
    "show eigrp topology",
    "show interface",
    "show configuration",
    "show route",
    "show arp",
    "show zone",
    "show vpn-sessiondb summary",
    "show port-channel summary",
    "show port-channel detail",
    "show interface summary",
    "show policy-route",
    "show firewall",
    "show inventory",
    "show ipsec sa summary",
    "show ipsec stats",
    "show ntp status",
    "show cluster info",
    "show traffic",
    "show policy-route",
    "show inventory",
    "show bridge-group",
    "changeto system",
    "show context",
    "show context count"
)
```

### PA firewall
```powershell
$Commands= @(
    "show system info",
    "show lldp neighbors all",
    "show interface all",
    "show routing route",
    "show routing summary",
    "show arp all",
    "show lacp aggregate-ethernet all",
    "show vlan all",
    "show vpn tunnel",
    "show ntp",
    "show mac all",
    "show high-availability all",
    "show chassis inventory",
    "show config running",
    "request license info",
    "show config pushed-shared-policy",
    "show running nat-policy",
    "show running security-policy"
)
```

### WLC
```powershell
$Commands= @(
    "show run-config",
    "show wlan summary",
    "show wlan apgroups",
    "show logging",
    "show rf-profile summary",
    "show mobility summary",
    "show mobility anchor",
    "show mobility ap-list",
    "show guest-lan summary",
    "show cdp entry all",
    "show route summary",
    "show system route",
    "show rules",
    "show sysinfo",
    "show stats switch detailed",
    "show port detailed-info",
    "show port vlan",
    "show network summary",
    "show network profile details",
    "show dhcp summary",
    "show ldap summary",
    "show system interfaces",
    "show license all",
    "show tacacs summary",
    "show network summary",
    "show interface detailed virtual",
    "show interface detailed management",
    "show ap summary",
    "show ap inventory all",
    "show ap cdp all",
    "show run-config commands"
)
```

### Blue coat 
```
show interface all
show version
show routing-domain
show virtual-ip
show accelerated-pac
show bridge
show dns
show dns-forwarding
show failover configuration
show forwarding
show general
show ip-default-gateway 
show ip-route-table
show licenses
show ntp
show policy config
show private-network
show proxy-services
show management-services
show static-routes
show tcp-ip
show wccp status
show arp-table
```

### Juniper (XML Output)
```powershell
$Commands= @(
    "show configuration | display xml | no-more",
    "show spanning-tree bridge | display xml | no-more",
    "show spanning-tree interface detail | display xml | no-more",
    "show lldp neighbors | display xml | no-more",
    "show ethernet-switching table detail | display xml | no-more",
    "show arp | display xml | no-more",
    "show route all | display xml | no-more",
    "show vrrp | display xml | no-more",
    "show virtual-chassis device-topology | display xml | no-more",
    "show virtual-chassis  | display xml | no-more",
    "show system uptime | display xml | no-more",
    "show version  | display xml | no-more",
    "show version detail all-members | display xml | no-more",
    "show interfaces detail | display xml | no-more",
    "show vlans detail | display xml | no-more",
    "show lacp interfaces | display xml | no-more",
    "show chassis | display xml | no-more",
    "show ethernet-switching table extensive | display xml | no-more",
    "show log messages | display xml | no-more"
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

# known issues
* Plink has issues with paging on some devices.
* Plink also doesn't support enable passwords or expert passwords. 
````
