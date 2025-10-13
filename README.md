# MTAudotDraw

## What is it?
MTAudotDraw is a powerful PowerShell-based tool designed to automate the creation of detailed network diagrams by parsing configuration files from various network devices. It intelligently processes device configs, discovers network topology using protocols like CDP and LLDP, and generates diagrams in the **.drawio (diagrams.net)** format. It can also perform **Network Path Analysis**, exporting a **Route Analysis Report** (Currently in development) in `HTML` format for hop-by-hop routing insights.

---
# Table of Contents

1. [What is MTAudotDraw](#what-is-it)
2. [Key Features](#-key-features)
3. [Use Cases](#-use-cases)
4. [How It Works](#️-how-it-works)
5. [Supported Platforms](#️-supported-platforms)
6. [Prerequisites](#-prerequisites)
7. [How to Use](#-how-to-use)
8. [Outbound Network Connections](#-outbound-network-connections)
9. [Output](#️-output)
10. [Troubleshooting & Limitations](#-troubleshooting--limitations)
11. [Best Practices](#-best-practices)
12. [Acknowledgements](#-acknowledgements)
13. [Copyright and License](#-copyright-and-license)
14. [Application Workflow](#how-the-application-works)
15. [Host Object Structure](#what-is-inside-the-host-object)


---
## ✨ Key Features

* **Automated Diagram Generation**: Automatically creates multi-page `.drawio` files from your device configuration backups.
* **Multi-Vendor Support**: Parses configurations from a variety of vendors.
* **Multiple Diagram Types**: Generates several types of diagrams to visualize different aspects of your network:

  * Physical L2 Topology (from CDP/LLDP)
  * Logical L3 Topology (SVIs, Routed Ports)
  * Focused Routed Link and High-Level Routes-Only views
  * Individual diagrams for each device's configuration.
* **Data Export**: Exports discovered network data into structured `CSV`, `JSON`, and `HTML` formats for further analysis.
* **Routing Path Analysis**: Traces end-to-end paths, performs symmetry checks, and generates a full **Route Analysis Report**.
* **Highly Configurable**: Uses simple toggles in the `configurationVariables.ps1` file to control which diagrams are generated and what information is included.
* **Intelligent Neighbor Discovery**: Discovers and links devices via CDP, LLDP, and ARP data, providing a more complete picture of your network.

## ✅ Use Cases

This tool is incredibly useful for a variety of tasks:

* **Network Audits & Discovery**: Quickly get a visual inventory of a new or undocumented network.
* **Documentation**: Create a solid baseline for your network documentation with minimal effort.
* **Change Validation**: Generate "before" and "after" diagrams to visually confirm the impact of network changes.
* **Routing & Path Analysis**: Trace routing paths, detect asymmetric routing, and export full route analysis reports.
* **Operational Insight**: Gain a better general understanding of network topology and routing.


## Screenshots Example networks
## **CDP-LLDP brief**
<img width="4344" height="2564" alt="image" src="https://github.com/user-attachments/assets/9354a623-15cf-4347-8dfb-a2d5bfed993a" />



## **Layer 3 Routes only Diagram**
<img width="4064" height="4284" alt="image" src="https://github.com/user-attachments/assets/ba4e1a39-dac2-4ed7-87a0-871db056de9b" />

## **Layer 3 Routes only Diagram**

<img width="8368" height="7324" alt="image" src="https://github.com/user-attachments/assets/9d0d0c07-23e8-4ddf-92df-d3fbc74e0759" />




## ⚙️ How It Works

The script operates in a series of logical steps:

0. **Configuration data collection**: **This is not done by MTAUTODRAW** You must collect all of your configuration data from your switches, routers, firewalls. If you don't know how to do this here is a very simple way of doing it: [https://github.com/baztheallmighty/MTautodraw/blob/main/How%20to%20collect%20the%20show%20commands%20from%20multiple%20devices.md](https://github.com/baztheallmighty/MTautodraw/blob/main/How%20to%20collect%20the%20show%20commands%20from%20multiple%20devices.md)
1. **File Discovery**: It scans the specified input directory for configuration files, identifying unique devices based on a `hostname.show version.txt` file.
2. **Parsing with TextFSM**: It leverages **Python** and the **TextFSM** library to parse the raw text from configuration files (`show run`, `show ip interface`, etc.) into structured data. A cache of parsed data is created in a `.json` subfolder to speed up subsequent runs.
3. **Building the Data Model**: The script constructs a rich PowerShell object model of the network, creating objects for each device, interface, VLAN, and route. It links these objects together to build a comprehensive map of the network topology.
4. **Generating Draw\.io XML**: Based on the data model and user configuration, the script programmatically generates the raw XML required to build a `.drawio` file, defining every shape, connector, and style.
5. **Network Path Analysis**: Using `Network Path Analysis.ps1`, the tool builds radix trees for efficient route lookups, traces hop-by-hop paths, checks for forward/reverse path symmetry, and saves a **Route Analysis Report** `HTML` format.
6. **Saving Output**: The final `.drawio` file, the **Route Analysis Report**, along with any exported data and a log file, is saved to the specified output directory.

## 🖥️ Supported Platforms

MTAudotDraw has explicit support for parsing configurations from the following platforms:

---

### **Cisco IOS / IOS-XE / NX-OS**

* `show version` **(Required)**
* `show run` **(Required)**
* `show interface` or `show ip interface brief`
* `show interface status`
* `show cdp neighbors detail`
* `show lldp neighbors detail`
* `show spanning-tree`
* `show mac address-table`
* `show ip arp`
* `show ip route`
* `show ip route vrf *` → Saved as `show ip route vrf star.txt`

---

### **Cisco ASA**

* `show version`
* `show run` or `show config`
* `show route`
* `show interface`

---

### **Check Point Gaia**

* `show version`
* `show configuration` or `show config`
* `show route all`
* `show interfaces all`

---

### **Juniper Junos** *(XML format required)*

* `show configuration | display xml`
* `show version | display xml`
* `show interfaces detail | display xml`
* `show lldp neighbors | display xml`
* `show route all | display xml`
* `show spanning-tree bridge | display xml`
* `show spanning-tree interface | display xml`

---

### **Palo Alto Networks** *(Work in progress)*

* Parsing logic is **implemented and functional** for the following core commands.  

  * `show system info`
  * `show routing route`
  * `show interface all`

---

### **Additional Data Used if Available**

* `MacAddressToVendorsMapping.csv` → Downloaded automatically if missing (for MAC vendor lookup)

## 🔧 Prerequisites

Before running the script, ensure your environment meets the following requirements:

1. **PowerShell**: Version 7 or later.
2. **Python**: Python 3.x must be installed.
3. **Python `textfsm` Library**: This is a critical dependency. Install it using pip:

   ```bash
   pip install textfsm
   ```

## 🚀 How to Use

### 1. Project File Structure

Place all the script files (`.ps1`, `.py`) and the `Templates` directory together. The script relies on this structure to find its modules and templates.

```
MTAudotDraw/
├── MTAudotDraw.ps1

# --- Configuration ---
├── configurationVariables.ps1

# --- Core Logic & Function Libraries ---
├── StartProcessingConfig.ps1
├── ObjectFunctions.ps1
├── HelperFunctions.ps1
├── DrawLogic_drawio.ps1
├── Network Path Analysis.ps1

# --- Vendor-Specific Parsing Logic ---
├── CiscoConfigProcessingFunctions.ps1
├── CiscoASAConfigProcessingFunctions.ps1
├── CheckPointConfigProcessingFunctions.ps1
├── JunosConfigProcessingFunctions.ps1
├── PaloAltoConfigProcessingFunctions.ps1  (WIP)

# --- Python Dependency ---
├── TextFSM.py

# --- TextFSM Templates Dependency ---
├── Templates
    └──...

# --- GETIPV4Subnet Dependency ---
├── GETIPV4Subnet
    └──GETIPV4Subnet.psm1

# --- Python Environment ---
└── python/
    └── python.exe
```

### 2. Prepare Configuration Files

**The script does not collect data itself.** You must run the required commands on your devices and save the complete, raw output to individual text files.
If you don't know how to do this here is a very simple way of doing it: [https://github.com/baztheallmighty/MTautodraw/blob/main/How%20to%20collect%20the%20show%20commands%20from%20multiple%20devices.md](https://github.com/baztheallmighty/MTautodraw/blob/main/How%20to%20collect%20the%20show%20commands%20from%20multiple%20devices.md)

#### Required Commands

* **Cisco IOS / IOS-XE / NX-OS:**

  * `show version` **(Required)**
  * `show run` **(Required)**
  * `show interface` or `show ip interface brief`
  * `show interface status`
  * `show cdp neighbors detail`
  * `show lldp neighbors detail`
  * `show spanning-tree`
  * `show mac address-table`
  * `show ip arp`
  * `show ip route`
  * `show ip route vrf *` (see file naming note below)

* **Cisco ASA:**

  * `show version`
  * `show run` (or `show config`)
  * `show route`
  * `show interface`

* **Check Point Gaia:**

  * `show version`
  * `show configuration` (or `show config`)
  * `show route all`
  * `show interfaces all`

* **Juniper Junos (XML format is required):**

  * `show configuration | display xml`
  * `show version | display xml`
  * `show interfaces detail | display xml`
  * `show lldp neighbors | display xml`
  * `show route all | display xml`
  * `show spanning-tree bridge | display xml`
  * `show spanning-tree interface | display xml`

#### File Naming Convention

This is the most important step. All files must follow the format: **`Identifier.Command-Name.txt`**

* The `Identifier` is a unique name or IP for a device and must be consistent for all files from that device.
* The `Command-Name` is the command that was run.

**Examples:**

```
# For a switch named "core-switch-01"
core-switch-01.show version.txt
core-switch-01.show run.txt
core-switch-01.show cdp neighbors detail.txt

# For a router identified by IP
10.1.1.254.show version.txt
10.1.1.254.show ip route.txt
```

> **Special Case:** Since `*` is not a valid character in Windows filenames, save the output of `show ip route vrf *` as:
> `Identifier.show ip route vrf star.txt`

> **File Cleanliness:** Ensure your output files contain **only** the command output. Remove any login banners, command prompts (`switch#`), or `--more--` lines, as they will cause parsing errors.

### 3. Configure the Script (Optional)

Open `configurationVariables.ps1` in a text editor to customize the script's behavior. You can enable or disable diagrams, route analysis, exclude certain devices like phones, and toggle data exports.

### 4. Run the Script

Open a PowerShell terminal, navigate to the script's folder, and run it with the following parameters:

```powershell
.\MTAudotDraw.ps1 -GDirectory "C:\path\to\configs" -GOutPutDirectory "C:\path\to\output" -GPathToScript "C:\mtautodraw\"
```

* **`-GDirectory`**: The full path to the folder containing your collected `.txt` files.
* **`-GOutPutDirectory`**: The folder where the `.drawio` files, route analysis reports, and other outputs will be saved.
* **`-GPathToScript`**: (Optional) The path to the script folder. Defaults to the current directory.

### 5. Arrange the diagram

The diagrams come out pretty flat and need to be arranged and quite often resized to be of use. This is a manual task at this stage.

---

## 🔒 Outbound Network Connections

For security and operational transparency, it's important to know what network connections a script makes. MTAudotDraw is designed to work primarily on local files and does not require an active internet connection to perform its main functions, provided one file is present.

MAC Address to Vendor Mapping

* **`Purpose:`** To provide more useful information in diagrams and data exports, the script maps MAC addresses to their respective hardware vendors (e.g., Cisco, Juniper, Dell). To do this, it needs a list of Organizationally Unique Identifiers (OUIs).
* **` Trigger:`** This connection is only attempted if the file MacAddressToVendorsMapping.csv is not present in the script's root directory.
* **` Process:`** On its first run (or if the file is deleted), **the script will attempt to download** the OUI list from devtools360.com. Once downloaded, it saves the data locally as MacAddressToVendorsMapping.csv.

---

## 🖼️ Output

The script will generate the following files in your output directory:

* **`MTAudotDraw-MultiDevice-YYYYMMDD-HHMM.drawio`**: The main diagram file with multi-device physical and logical views.
* **`MTAudotDraw-Singles-YYYYMMDD-HHMM.drawio`**: A diagram where each page is dedicated to a single device's L3 layout.
* **`RouteAnalysis-YYYYMMDD-HHMM.html`**: Full routing analysis including hop-by-hop paths and symmetry checks.
* **`LogYYYYMMDDHHMMSS.txt`**: A transcript of the script's execution, useful for debugging.
* **(If `$GExportData` is `$true`)**: `vlans.csv`, `cidr.csv`, `CDPNeighbors.csv`, `LLDPNeighbors.csv`, and `Objects.json`.

---

## 💡 Troubleshooting & Limitations

#### Common Issues

* **TextFSM Errors**: If the log shows errors related to TextFSM, it is almost always because of extra text in your output files (banners, prompts, etc.). Ensure the files are clean.
* **"File doesn't exist" or "No show version files found"**: This error means there is a problem with your file naming. Double-check that every device has a `Identifier.show version.txt` file and that the identifier is consistent.
* **Duplicate hostnames**: All hostnames must be unique.

#### Known Limitations

* **"The script outputs a lot of errors at the moment. Most of these can be ignored."**
* Duplicate hostnames are not supported and will cause the script to stop with an error.
* Junos LLDP neighbor matching may rely on interface descriptions, which could be inaccurate if not standardized.
* Parsing `show ip arp` from devices with VRFs is not fully implemented.
* `show mac address` throws errors when multiple interfaces share the same MAC address.
* Logging is very noisy.
* Collection of configuration files/data is not done by the script.
* Diagrams have to be manually arranged.
* If you have lots of routes or arp addresses processing can be very slow

---

## 👍 Best Practices

* **File Encoding**: The script attempts to clean files, but starting with **ASCII** encoding is recommended.
* **Break Up the Work**: For large networks, process devices in logical groups (e.g., by building or function) to keep diagrams clean. A diagram with more than 25-30 devices can become very cluttered.

---

## 🙏 Acknowledgements

This tool stands on the shoulders of giants. Thank you to the following for their libraries and hard work:

* **Brians worth** for the `GetIPv4Subnet.psm1` module.
* **The Network to Code (NTC) community and Jason Edelman** for the extensive `ntc-templates` for TextFSM, which do the heavy lifting of configuration parsing.

---

## 📜 Copyright and License

Copyright (C) 2022 Myles Treadwell

This program is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version**.

This program is distributed in the hope that it will be useful, but **WITHOUT ANY WARRANTY**; without even the implied warranty of **MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE**. See the GNU General Public License for more details.

-----

## How the Application works:

```

Input Files (e.g., show run, show cdp neighbors, show ip route, show spanning-tree)
│
└───> AutoDraw.ps1 (Main Entry Point)
      │
      ├───> configurationVariables.ps1
      │        - Loads config settings (file paths, feature flags, debug options)
      │        - Controls diagrams, path analysis, parallelism, logging levels
      │
      ├───> StartProcessingConfig.ps1
      │        │
      │        ├───> Create-FileHostObjects()
      │        │        - Maps raw files → devices
      │        │        - Produces FileObject per device with all config/discovery files
      │        │
      │        └───> Start-ProcessingFiles()
      │              │
      │              ├─── Parallel Processing Loop (ForEach-Object -Parallel)
      │              │      │
      │              │      ├─── Per-device processing:
      │              │      │      - Process-*HostFiles() → Cisco, Junos, PaloAlto, CheckPoint, ASA
      │              │      │      - Get-*FromText() / Get-*FromXML() → Parse raw CLI / XML
      │              │      │      - Python TextFSM (optional) → Structured tables
      │              │      │
      │              │      ├─── Object creation:
      │              │      │      - Create-HostObject() → Main container for device
      │              │      │      - Create-RouteObject() → Routing tables (OSPF/BGP/Static)
      │              │      │      - Create-NeighborObject() → CDP/LLDP neighbors
      │              │      │      - Create-SpanningTreeObject() → STP roles & root bridges
      │              │      │      - Create-NetworkObject() → L3 subnets & networks
      │              │      │
      │              │      ├─── Validation:
      │              │      │      - Missing routing tables? → Mark partial device
      │              │      │      - Incomplete neighbor data? → Warning logs
      │              │      │
      │              │      └─── Returns → One HostObject per device → $processedDevices
      │              │
      │              ├─── Post-Processing (Sequential)
      │              │      │
      │              │      ├─── Neighbor Linking:
      │              │      │      - Link CDPNeighborObjects → Partner HostObjects
      │              │      │      - Link LLDPNeighborObjects → Partner HostObjects
      │              │      │      - PartnerEthernetInterface ensures both ends reference each other
      │              │      │
      │              │      ├─── Gateway & External Subnets:
      │              │      │      - Create Gateway Hosts → Synthetic devices for ARP/routes-only subnets
      │              │      │      - External subnets → IsExternal = $true
      │              │      │      - GatewayLink connects RouteObjects to next-hop devices
      │              │      │
      │              │      ├─── Route Linking:
      │              │      │      - Map RouteObjects → exit interfaces on local devices
      │              │      │      - Map RouteObjects → remote devices via gateway IP
      │              │      │
      │              │      ├─── STP Linking:
      │              │      │      - Mark RootBridge = $true for STP root devices
      │              │      │      - Assign port roles: Root, Designated, Alternate
      │              │      │
      │              │      └─── Final Object Arrays:
      │              │            - $GArrayOfObjects → All fully processed HostObjects
      │              │            - $GArrayOfNetworks → All unique NetworkObjects
      │              │            - $GArrayOfCDPDeviceIDs → CDP neighbor-only hosts
      │              │            - $GArrayOfLLDPDeviceIDs → LLDP neighbor-only hosts
      │              │            - $GArrayOfGatewayHosts → Synthetic gateway hosts
      │              │
      │              └─── Returns → All objects for diagrams & path analysis
      │
      ├───> DrawFunctions_drawio.ps1 / DrawLogic_drawio.ps1
      │        │
      │        ├─── Initialize-DrawioFile() → Create XML headers
      │        │
      │        ├─── Multi-Device Diagrams (if $GDrawMultipleDevicesDiagram):
      │        │      - Draw-AllNeighborsDrawio() → Physical topology (CDP/LLDP)
      │        │      - Draw-AllLayer3Drawio() → L3 topology
      │        │      - Draw-SpanningTreeDiagram() → STP root bridges & port roles
      │        │
      │        ├─── Single-Device Diagrams (if $GDrawSingles):
      │        │      - Draw-SinglesLayer3Drawio() → Per-device L3 diagrams
      │        │      - Draw-SingleHostPhysicalDrawio() → Per-device physical diagrams
      │        │
      │        └─── Finalize-DrawioFile() + Save-DrawioFile() → Write final .drawio file
      │
      ├───> Network Path Analysis.ps1
      │        │
      │        ├─── Create-RouteRadixTrees() → Build radix trees per device for O(log n) lookups
      │        ├─── Find-BestRouteInRadixTree() → Fast LPM route selection per hop
      │        ├─── Trace-FullPath() → Forward path tracing (source → destination)
      │        ├─── Test-PathSymmetry() → Reverse path comparison (destination → source)
      │        ├─── Create-HopObject() → Per-hop data structure for each hop
      │        ├─── Create-PairObject() → Source/destination pair representation
      │        └─── **Outputs: Generates a full Route Analysis Report**
      │                - All traced paths (forward & reverse)
      │                - Hop-by-hop routing decisions
      │                - Symmetry and reachability metrics
      │                - Saved as analysis output file (e.g., .CSV, .HTML, or .TXT)
      │
      └───> HelperFunctions.ps1 / ObjectFunctions.ps1
               - Logging utilities (Write-HostDebugText, warnings, errors)
               - Object builders for Host, Route, Neighbor, Network objects
               - IP normalization, string cleanup, table utilities

```


### What is inside the host object
```

**HostObject** ($Device)
└───
    ├─── .hostname: "CORE-SW-01"
    ├─── .DeviceType: "Cisco"
    ├─── .Origin: "config", "CDP", "LLDP", "ARP", etc.
    ├─── .Description: "System description from CDP/LLDP"
    ├─── .Platform: "cisco C9300-48U" (from CDP)
    ├─── .Capabilities: "Router, Switch, IGMP" (from CDP)
    ├─── .DeviceIdentifier: "CORE-SW-01.show run.txt"
    ├─── .BGP_AS_Number: "65001"
    ├─── .HostTypeIfCDPorLLDP: "HP" (Vendor name if hostname is a MAC)
    ├─── .ArrayOfIPAddresses: [array] of "10.1.1.1", "172.16.0.1", ...
    │
    ├─── .Version: (ShowVersionObject)
    │    ├─── .OS: "15.2(7)E4"
    │    ├─── .Type: "IOS", "XE-IOS", "NXOS", etc.
    │    ├─── .Hardware: [array] of "C9300-48U", "C9300-NM-8X"
    │    ├─── .Serial: [array] of "FOC12345678", "FOC87654321"
    │    ├─── .ROMMON: "16.12.1r"
    │    ├─── .Image: "bootflash:packages.conf"
    │    ├─── .ReasonForRelod: "Reload Command"
    │    ├─── .ConfigRegister: "0x102"
    │    ├─── .MacAddressArray: [array] of "00:00:DE:AD:BE:EF"
    │    ├─── .Uptime: "3 years, 2 weeks, 4 days, 5 hours, 3 minutes"
    │    └─── .LastRestarted: "10:00:00 UTC Fri Aug 1 2022"
    │
    ├─── .interfaces: [array] of InterfaceObject
    │    └─── InterfaceObject {
    │         ├── .Interface: "GigabitEthernet1/0/1"
    │         ├── .Description: "Link to WEB-FW-A"
    │         ├── .shutdown: $false
    │         ├── .IntStatus: "up"
    │         ├── .INTProtocolStatus: "up"
    │         ├── .Speed: "1000Mb/s"
    │         ├── .Duplex: "full"
    │         ├── .macaddress: "aabb.cc00.0100"
    │         ├── .HardwareType: "Gigabit Ethernet"
    │         ├── .MediaType: "10/100/1000BaseTX"
    │         ├── .SwitchPortType: "switched" | "routed"
    │         ├── .SwitchportMode: "access" | "trunk"
    │         ├── .SwitchportAccessVlan: "100" ──> (Links to a VlanObject by its .number)
    │         ├── .SwitchportTrunkVlan: "10,20,30-40"
    │         ├── .NativeVlan: "1"
    │         ├── .IPAddress: "10.1.1.1"
    │         ├── .SubnetMask: "30"
    │         ├── .Cidr: "10.1.1.0/30" ───────────> (Creates a NetworkObject)
    │         ├── .SecondaryIPAddress: "10.1.1.5"
    │         ├── .SecondaryCidr: "10.1.1.4/30"
    │         ├── .Standbyip: "10.1.1.3" (HSRP/VRRP VIP)
    │         ├── .ClusterIP: "10.1.1.4" (CheckPoint Cluster IP)
    │         ├── .vrf: "MGMT"
    │         ├── .Zone: "inside" (ASA specific)
    │         ├── .ChannelGroup: "1"
    │         ├── .STRole: "Root" <───────────────── (Updated by SpanningTreeObject)
    │         ├── .STState: "FWD"
    │         ├── .STDesgnInterfaceForVlans: [array] of "101", "102"
    │         ├── .HasCPDNieghbor: $true
    │         ├── .HasLLDPNeighbor: $true
    │         ├── .IsLinkedToByCDPorLLDP: $true
    │         ├── .RoutesForInterface: [array] of RouteObject
    │         ├── .MacAddressArray: [array] of MacAddressObject
    │         │    └─── MacAddressObject {
    │         │         ├── .MacAddress: "0000.dead.beef"
    │         │         ├── .Vlan: "100"
    │         │         ├── .Type: "DYNAMIC"
    │         │         ├── .VendorCompanyName: "VMware, Inc."
    │         │         └── .protocols: "-"
    │         │         }
    │         └── .DrawOnRoutesOnlyDiagram: $true
    │         }
    │
    ├─── .vlans: [array] of VlanObject
    │    └─── VlanObject {
    │         ├── .number: "100"
    │         ├── .name: "SERVERS" ───────────────> (Used to name the NetworkObject)
    │         └── .description: "Main Server VLAN"
    │         }
    │
    ├─── .ArrayOfNetworks: [array] of NetworkObject
    │    └─── NetworkObject {
    │         ├── .Cidr: "10.1.1.0/30"
    │         ├── .NetworkName: "SERVERS"
    │         ├── .RoutedVlan: "vlan100"
    │         ├── .NumberOfConnectors: 2
    │         ├── .NumberOfRoutedConnectors: 1
    │         └── .ARPEntries: [array] <──────────── (Populated with matching ShowIPArpObjects)
    │         }
    │
    ├─── .RoutingTable: [array] of RouteObject
    │    └─── RouteObject {
    │         ├── .Subnet: "0.0.0.0/0"
    │         ├── .gateway: "10.1.1.2"
    │         ├── .interface: "GigabitEthernet1/0/1" -> (References an InterfaceObject)
    │         ├── .RouteProtocol: "static"
    │         ├── .VRF: "MGMT"
    │         ├── .DISTANCE: "1"
    │         ├── .METRIC: "0"
    │         └── .GatewayLink: [ref]──────────────> (🔗 A link to the actual gateway InterfaceObject)
    │         }
    │
    ├─── .IPArpEntries: [array] of ShowIPArpObject
    │    └─── ShowIPArpObject {
    │         ├── .ipaddress: "10.1.1.2"
    │         ├── .MAC: "aabb.cc00.0200"
    │         ├── .INTERFACE: "Vlan100"
    │         ├── .Cidr: "10.1.1.0/30"
    │         ├── .VendorCompanyName: "Cisco"
    │         ├── .PROTOCOL: "Internet"
    │         ├── .AGE: "120"
    │         └── .TYPE: "ARPA"
    │         }
    │
    ├─── .CDPNeighbors: [array] of CDPNeighborObject
    │    └─── CDPNeighborObject {
    │         ├── .InterfaceLocalDevice: "GigabitEthernet1/0/1" -> (References an InterfaceObject)
    │         ├── .DeviceID: "WEB-FW-A"
    │         ├── .SystemName: "WEB-FW-A.domain.local"
    │         ├── .InterfaceRemoteDevice: "GigabitEthernet0/1"
    │         ├── .Platform: "Cisco ASA 5525-X"
    │         ├── .Version: "Cisco Adaptive Security Appliance Software Version 9.12(2)"
    │         ├── .Capabilities: "Router"
    │         ├── .InterfaceIPAddresses: "10.1.1.2"
    │         └── .PartnerEthernetInterface: [ref]──> (🔗 A link to the InterfaceObject on the neighbor HostObject)
    │         }
    │
    ├─── .LLDPNeighbors: [array] of LLDPNeighborObject
    │    └─── LLDPNeighborObject {
    │         ├── .InterfaceLocalDevice: "GigabitEthernet1/0/2" -> (References an InterfaceObject)
    │         ├── .Hostname: "ESXI-HOST-01"
    │         ├── .ChassisID: "aabb.cc00.0300"
    │         ├── .InterfaceRemoteDevice: "vmnic0"
    │         ├── .NeighborInterfaceDescription: "Uplink 1"
    │         ├── .SystemDescription: "VMware ESXi, 7.0.3, 20328353"
    │         ├── .ManagementIP: "172.16.100.50"
    │         ├── .HasCDPNeighborEntry: $false
    │         └── .PartnerEthernetInterface: [ref]──> (🔗 A link to the InterfaceObject on the neighbor HostObject)
    │         }
    │
    ├─── .BGPNeighbors: [array] of BGPNeighborObject
    │    └─── BGPNeighborObject {
    │         ├── .NEIGHBOR: "192.168.1.2"
    │         ├── .REMOTE_AS: "65002"
    │         ├── .BGP_STATE: "Established"
    │         ├── .VRF: "default"
    │         ├── .DESCRIPTION: "Peer to ISP-A"
    │         ├── .INBOUND_ROUTEMAP: "ALLOW-ALL-IN"
    │         └── .OUTBOUND_ROUTEMAP: "ALLOW-ALL-OUT"
    │         }
    │
    └─── .SpanningTree: (SpanningTreeObject)
         ├─── .SpanningTreeMode: "rstp"
         ├─── .SpanningTreeExtended: $true
         ├─── .RootBridgeForVlans: [array] of "10", "20"
         └─── .SpanningTreeArray: [array] of SpanningTreeVlan
              └─── SpanningTreeVlan {
                   ├── .VlanID: "100"
                   ├── .protocol: "rstp"
                   ├── .RootBridge: $false
                   ├── .RootIDPriority: "32768"
                   ├── .Address: "0000.1111.2222"
                   ├── .BridgeIDPriority: "32868"
                   ├── .BridgeIDPriorityaddress: "aabb.cc00.0100"
                   └─── .SpanningTreeInterfaces: [array] of SpanningTreeInterface
                        └─── SpanningTreeInterface {
                             ├── .Interface: "Po1"
                             ├── .Role: "Root"
                             ├── .Status: "FWD"
                             ├── .Cost: "3"
                             ├── .PrioNbr: "128.1281"
                             └── .Type: "P2p"
                             }
                   }
