# MTAutoDraw

MTAutoDraw is a PowerShell tool that parses command captures from network devices, discovers topology
from CDP, LLDP, routing, ARP, MAC, and spanning-tree data, and generates `.drawio`
(diagrams.net) diagrams plus structured exports.


-----

> **Contributing?** Start with the [documentation index](docs/SUMMARY.md) and
> [architecture guide](docs/ARCHITECTURE.md). This README focuses on installing and running the tool.

## ✨ Key Features

  * **Automated Diagram Generation**: Automatically creates multi-page `.drawio` files from your device configuration backups.
  * **Multi-Vendor Support**: Parses configurations from a variety of vendors.
  * **Multiple Diagram Types**: Generates several types of diagrams to visualize different aspects of your network:
      * Physical L2 Topology (from CDP/LLDP)
      * Logical L3 Topology (SVIs, Routed Ports)
      * Focused Routed Link and High-Level Routes-Only views
      * Individual diagrams for each device's configuration.
  * **Data Export**: Exports discovered network data into structured `CSV` and `JSON` formats for further analysis.
  * **Highly Configurable**: Uses simple toggles in the `configurationVariables.ps1` file to control which diagrams are generated and what information is included.
  * **Intelligent Neighbor Discovery**: Discovers and links devices via CDP, LLDP, and ARP data, providing a more complete picture of your network.
  * **Evidence-Based Topology Gaps**: Adds visibly dashed inferred nodes/paths when STP, exact MAC/CAM, ARP/CAM, or strict port-description evidence identifies infrastructure that CDP/LLDP did not reveal.
  * **Bundled Capture Collector**: [`DataCollection/NetworkAudit.ps1`](DataCollection/) logs into your devices over SSH or Telnet, runs the read-only commands this tool needs across 23 platform profiles, and writes them out already named correctly. Passwords are held in memory only and never reach disk.

## ✅ Use Cases

This tool is incredibly useful for a variety of tasks:

  * **Network Audits & Discovery**: Quickly get a visual inventory of a new or undocumented network.
  * **Documentation**: Create a solid baseline for your network documentation with minimal effort.
  * **Change Validation**: Generate "before" and "after" diagrams to visually confirm the impact of network changes.
  * **Operational Insight**: Gain a better general understanding of network topology and routing.

## ⚙️ How It Works

The script operates in a series of logical steps:

0.  **Capture collection**: `AutoDraw.ps1` never connects to a device; it reads saved command output.
    The collector in [`DataCollection/`](DataCollection/) gathers that output for you over SSH or
    Telnet, or bring captures you already have. Either way, start with the
    [capture collection guide](How%20to%20collect%20the%20show%20commands%20from%20multiple%20devices.md).
1.  **File Discovery**: It scans the specified input directory for supported `show`/`get` capture files and groups them by their device identifier.
2.  **Parsing with TextFSM**: It leverages **Python** and the **TextFSM** library to parse the raw text from configuration files (`show run`, `show ip interface`, etc.) into structured data. Captures are parsed from their current contents on every run; no parser cache is used.
3.  **Building the Data Model**: The script constructs a rich PowerShell object model of the network, creating objects for each device, interface, VLAN, and route. It links these objects together to build a comprehensive map of the network topology.
4.  **Generating Draw.io XML**: Based on the data model and user configuration, the script programmatically generates the raw XML required to build a `.drawio` file, defining every shape, connector, and style.
5.  **Saving Output**: The final `.drawio` file, along with any exported data and a log file, is saved to the specified output directory.

## 🖥️ Supported Platforms

All eleven vendor modules conform to **parser standard v1** ([`PARSER_STANDARD.md`](PARSER_STANDARD.md)),
which is enforced mechanically against every module. One module reads like the next, and adding a
platform is one new file plus a dispatcher entry - start from
[`Templates/_NewPlatformTemplate.ps1`](Templates/_NewPlatformTemplate.ps1).

MTAutoDraw has explicit support for parsing configurations from the following platforms:

  * **Cisco Systems**
      * Cisco NX-OS (Nexus)
      * Cisco IOS and IOS-XE
      * Cisco IOS XR (version, running configuration, interfaces, networks, ARP, CDP, and LLDP)
      * Cisco ASA
      * Cisco Small Business SG and CBS switches
      * Cisco Small Business legacy CLI (the older SG firmware, detected and dispatched separately)
  * **Arista Networks**
      * EOS
  * **Aruba Networks**
      * ArubaOS-CX
  * **Fortinet**
      * FortiGate / FortiOS
  * **Palo Alto Networks**
      * PAN-OS
  * **Check Point**
      * Check Point Gaia
  * **Juniper Networks**
      * Junos (in XML format)

> **Cisco IOS XR note:** Core parsing is covered by a sanitized real capture. IOS XR route parsing remains gated until a real sanitized `show route` capture is available; the tool does not claim that path as verified yet.

## 🔧 Prerequisites

Before running the script, ensure your environment meets the following requirements.

> The GUI checks all of these for you and offers the fix for each one. Double-click
> `MTAutoDraw.cmd` and open its **Setup** tab rather than working through this list by hand.

1.  **PowerShell**: Version 7 or later. The parser runs devices in parallel with `ForEach-Object -Parallel`, which is 7+ only.
2.  **Python with `textfsm`**: required, and **not in the repository** - it is 167 MB of binaries that do
    not belong in git history, so `.gitignore` excludes the `python\` folder. A fresh clone therefore has
    no interpreter, and `AutoDraw.ps1` stops on its first check with `Bundled Python executable not
    found`. Fix it either way:
    - **Let the GUI do it.** Double-click `MTAutoDraw.cmd`, open the **Setup** tab, and press
      **Set up Python**. It downloads an embeddable interpreter, installs `textfsm` into it, and writes
      only to the gitignored `python\` folder. The download is confirmed first by URL, filename and size.
    - **Do it by hand.** Install Python 3, run `pip install textfsm`, and point `$GPathToPythonExe` in
      `configurationVariables.ps1` at your `python.exe`.
3.  **TextFSM templates**: `TextFSM.py` and the `Templates\` directory are tracked and need nothing done
    to them. `AutoDraw.ps1` also fails immediately if `TextFSM.py` is missing.
4.  **Posh-SSH** 3.2.7 or newer - **only** if you use the bundled collector to gather captures over SSH.
    Nothing in `AutoDraw.ps1` needs it. See [`DataCollection/README.md`](DataCollection/README.md).

## 🚀 How to Use

### 1\. Project File Structure

Place all the script files (`.ps1`, `.py`) and the `Templates` directory together. The script relies on this structure to find its modules and templates.

```
MTAudotDraw/
├── AutoDraw.ps1                  # entry point

# --- The GUI: a launcher for the above, not part of the pipeline ---
├── MTAutoDraw.cmd                # double-click this
├── MTAutoDrawGui.ps1             # the window
├── GuiSettings.ps1               # settings model, profiles, prerequisite checks

# --- Configuration ---
├── configurationVariables.ps1

# --- Ingestion: captures on disk become device objects ---
├── StartProcessingConfig.ps1     # classify, dispatch in parallel, aggregate, resolve
├── ParserRuntime.ps1             # the contract every vendor reader follows
├── NeighborResolution.ps1        # which sighting refers to which captured device
├── ObjectFunctions.ps1           # the shape of every object in the model

# --- Drawing: device objects become a .drawio file ---
├── DiagramModels.ps1             # what each page shows, decided without drawing anything
├── DiagramModels.Layer3.ps1      # the L3 connectivity/routes/topology page models
├── DiagramModels.Pages.ps1       # the remaining per-page models
├── DrawLogic_drawio.ps1          # one function per page: place, connect, footnote
├── DrawFunctions_drawio.ps1      # every shape, and the only XML emission in the repository
├── DrawioDocument.ps1            # page and document boundaries
├── LayoutMath.ps1                # geometry: grids, tiers, bearings, slots
├── PlacementStrategies.ps1       # pluggable topology placement

# --- Output and support ---
├── Exports.ps1                   # the CSV and JSON exports
├── Logging.ps1                   # Write-MTAutoDrawLog, the one output contract
├── HelperFunctions.ps1           # what belongs to no single subsystem
├── Network Path Analysis.ps1     # experimental; disabled by default

# --- Parser standard ---
├── PARSER_STANDARD.md            # the shape every vendor module follows
├── Templates/_NewPlatformTemplate.ps1

# --- Vendor-Specific Parsing Logic ---
├── CiscoConfigProcessingFunctions.ps1
├── CiscoIOSXRConfigProcessingFunctions.ps1
├── CiscoSmallBusinessConfigProcessingFunctions.ps1
├── OldCiscoSmallBusinessConfigProcessingFunctions.ps1
├── CiscoASAConfigProcessingFunctions.ps1
├── CheckPointConfigProcessingFunctions.ps1
├── JunosConfigProcessingFunctions.ps1
├── AristaConfigProcessingFunctions.ps1
├── ArubaConfigProcessingFunctions.ps1
├── FortigateConfigProcessingFunctions.ps1
├── PaloAltoConfigProcessingFunctions.ps1

# --- Python Dependency ---
├── TextFSM.py

# --- TextFSM Templates Dependency ---
├── Templates
    └──...

# --- GETIPV4Subnet Dependency ---
├── GETIPV4Subnet
    └──GETIPV4Subnet.psm1

# --- Capture collection: gets the show output off the devices in the first place ---
├── DataCollection
    ├── NetworkAudit.ps1          # the collector GUI and its collection engine
    ├── NetworkAudit.config.json  # devices, sites, and the command profile per platform
    └── README.md

# --- Python interpreter: required, gitignored, supply your own (see Prerequisites) ---
└── python/
    └── python.exe
```

### 2\. Prepare Configuration Files

**The script does not collect data itself.** It reads the raw output of `show` commands: one file per
command per device.

The collector in [`DataCollection/`](DataCollection/) does that part. It logs into a device list over
SSH or Telnet, runs the read-only commands listed below, writes them out already named the way this
section requires, and can hand the result straight to `AutoDraw.ps1`:

```powershell
pwsh.exe -STA -NoProfile -File .\DataCollection\NetworkAudit.ps1
```

The [capture collection guide](How%20to%20collect%20the%20show%20commands%20from%20multiple%20devices.md)
walks through a run end to end. If you collect the output some other way, the command list and naming
rules below are the whole contract.

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

  * **Cisco Small Business SG / CBS:**

      * `show running-config` **(Required)**
      * `show system`
      * `show version`
      * `show inventory`
      * `show vlan`
      * `show interfaces status`
      * `show interfaces switchport`
      * `show interfaces description`
      * `show cdp neighbors detail`
      * `show lldp neighbors`
      * `show spanning-tree`
      * `show ip route`
      * `show arp` (or `show ip arp`)
      * `show mac address-table`

  * **Arista EOS:**

      * `show version` **(Required)**
      * `show run` (or `show hostname` as a hostname fallback)
      * `show interface` or `show ip interface brief`
      * `show interfaces status`
      * `show vlan` (or `show vlan brief`)
      * `show interfaces trunk`
      * `show lldp neighbors detail` (or `show lldp neighbors`)
      * `show spanning-tree`
      * `show mac address-table`
      * `show ip arp`
      * `show ip route` (or `show ip route vrf all`)

  * **Cisco ASA:**

      * `show version`
      * `show run` (or `show config`)
      * `show route`
      * `show interface`
      * `show arp`

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
      * `show ethernet-switching table detail | display xml` (or `extensive`; both the pre-ELS and the ELS `l2ng-*` schemas are read)

#### File Naming Convention

This is the most important step. All files must follow the format: **`Identifier.Command-Name.txt`**

  * The `Identifier` is a unique name or IP for a device and must be consistent for all files from that device.
  * The `Command-Name` is the command that was run.
  * Cisco Small Business discovery files may also replace spaces in the command with dots, for example `switch-01.show.running-config.txt`.

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

> **File Cleanliness:** Cleaner captures parse more reliably, but stripping them by hand is no longer required. When a TextFSM parse fails, the tool retries against a prompt-stripped copy made in the temp directory — device prompts (`switch#`), echoed commands and `--more--` lines are removed on that copy. Your capture files are never modified.

### 3\. Run it from the GUI

Double-click **`MTAutoDraw.cmd`**. This is the easiest way to run the tool and needs no terminal.

```
Run        capture folder, output folder, and the settings that change what you get
Advanced   every remaining setting, with the explanation from configurationVariables.ps1
Log        the run as it happens, coloured by level, with the phase it has reached
Results    Pass/Warn/Fail, the counts, anything that went wrong, and the files produced
Setup      what is missing and how to fix it - start here on a fresh clone
```

**On a fresh clone, open the Setup tab first.** The Python interpreter is not in the repository, so
it will show as missing. Either press **Set up Python** to download an embeddable interpreter and
install `textfsm` into it, or **Use my own python.exe** to point at one you already have. The
download is confirmed first, by URL, filename and size, and only writes to the gitignored `python\`
folder.

Settings can be saved as named **profiles**, so a site you diagram regularly is one dropdown away.
Profiles live in `%APPDATA%\MTAutoDraw\Profiles`, not in the repository, so `git pull` never
overwrites them.

### 4\. Configure the Script (Optional)

The GUI's Run and Advanced tabs cover every setting, so this section is only needed if you prefer to
work from a terminal. Open `configurationVariables.ps1` in a text editor to customize the script's
behavior: you can enable or disable diagrams, exclude certain devices like phones, and toggle data
exports.

To change settings without editing the file, pass `-SettingsPath` a JSON file of overrides:

```powershell
.\AutoDraw.ps1 -GDirectory "C:\configs" -GOutPutDirectory "C:\out" -SettingsPath "C:\profiles\site.json"
```

```json
{ "GdrawSingles": false, "GDrawioTopologyEndUnitMode": "Grid" }
```

Only names that already exist in `configurationVariables.ps1` are applied; anything else is reported
and ignored. A profile saved by the GUI can be passed to `-SettingsPath` directly. `-LogLevel` and
`-Quiet` still win over anything the file says.

### 5\. Run the Script

Open a PowerShell terminal, navigate to the script's folder, and run it with the following parameters:

```powershell
.\AutoDraw.ps1 -GDirectory "C:\path\to\configs" -GOutPutDirectory "C:\path\to\output" -GPathToScript "C:\mtautodraw\"
```

  * **`-GDirectory`**: The full path to the folder containing your collected `.txt` files.
  * **`-GOutPutDirectory`**: The folder where the `.drawio` files and other outputs will be saved.
  * **`-GPathToScript`**: (Optional) The path to the script folder. Defaults to the current directory.
  * **`-Quiet`**: (Optional) Suppresses detailed loading, parsing, linking, drawing, and timing messages. Warnings, errors, saved-run verdict, and summary path remain visible. Detailed diagnostics are the default.

### 6\. Review the diagram

The layout engine places devices automatically. Dense or unusually connected networks may still
benefit from manual spacing or resizing in diagrams.net.

-----
## 🔒 Outbound Network Connections

MTAutoDraw processes local capture files and does not otherwise require internet access when
`MacAddressToVendorsMapping.csv` is present.

If that file is missing, `Get-MacAddressToVendorMapping` downloads an Organizationally Unique
Identifier (OUI) list from `devtools360.com` and saves it as `MacAddressToVendorsMapping.csv` in the
project directory. The mapping adds hardware-vendor names to diagrams and exports.


-----
## 🖼️ Output

The script will generate the following files in your output directory:

  * **`MTAudotDraw-MultiDevice-YYYYMMDD-HHMM.drawio`**: The main diagram file with multi-device physical and logical views.
  * **`MTAudotDraw-Singles-YYYYMMDD-HHMM.drawio`**: A diagram where each page is dedicated to a single device's L3 layout.
  * **`LogYYYYMMDDHHMMSS.txt`**: A transcript of the script's execution, useful for debugging.
  * **(If `$GExportData` is `$true`)**: `vlans.csv`, `cidr.csv`, `devices.csv`, `interfaces.csv`, `routes.csv`, `layer3-interfaces.csv`, `topology-evidence.csv`, `CDPNeighbors.csv`, `LLDPNeighbors.csv`, and `Objects.json`.
  * **`RunSummary.json`**: A machine-readable `Pass`, `Warn`, or `Fail` verdict with parser counts, unsupported capture groups, artifacts, and the process exit code. `0` means pass/warn, `1` means captures could not be processed into the required device model, and `2` means a fatal run error.

`Objects.json` is a reference-free output model. It intentionally excludes drawing state, parser scratch output, debug logs, and live PowerShell object references such as route gateway links. It is never read as a cache; every run parses the current captures.

`routes.csv` contains every parsed route, including connected/local entries, and resolves usable next hops to captured devices or external gateway identities where possible. `layer3-interfaces.csv` contains one row per routed or IP-bearing interface, with primary/secondary addressing, descriptions, and both raw and normalized operational state.

`topology-evidence.csv` audits every inferred topology candidate and records its source device/port, evidence type, confidence, directness, candidate count, and whether it was drawn. Unknown STP roots and other drawn evidence appear on **Topology Overview**, **CDP-LLDP All**, and **CDP-LLDP brief**. MAC-table (CAM) and ARP+CAM sightings are reachability evidence only: they remain audit rows and never create physical links. Any local port with a CDP/LLDP observation is reserved from lower-level inference, including unresolved or suppressed observations.

Junos LLDP exports retain the raw chassis/port IDs and their advertised subtypes. A MAC-address port ID is not treated as a remote interface name. Unresolved LLDP peers are shown on **Topology Overview** only when the local port is network-facing (trunk/port-channel/STP root or alternate) or the peer advertises bridge/router capabilities; obvious access endpoints remain on the detailed LLDP outputs.

**Topology Overview** includes an embedded legend for every node fill/outline and connector style. Solid blue links are CDP, solid teal links are LLDP, and solid indigo links were observed by both protocols. Dashed protocol-colored links indicate lower-confidence resolution; dashed purple, orange, or grey links are inferred STP, gateway, or other possible paths. Observed LLDP peers use smaller cyan cards so they remain visually distinct from configured devices. Every device MTAutoDraw parsed gets its own card, however few links it has. Where several neighbours we have NO config for all terminate on the same device, they are collapsed into one dashed "N uncaptured neighbours" box per parent (`$GDrawioTopologyEndUnitMode`); a parsed device is never inside one.

**Layer 3 Topology Overview** is the L3 analogue of Topology Overview: devices are tiered into Border (holds the default route out, or is a firewall), Transit (other devices route through it), and Gateway (owns subnets/SVIs only) - a role derived purely from routing, not vendor config. A subnet shared by 3+ devices is drawn as its own chip with a spoke to each member; a subnet shared by exactly 2 devices becomes the label on the edge between them instead, so the page never turns into a wall of subnet rows. Every fact about a device pair - the shared subnet, any routing between them, and any HSRP/VRRP pairing - is merged onto one edge. ARP host-count and vendor detail is available in `cidr.csv` and `Objects.json`; per-route detail is available on **Layer 3 Connectivity**, **Layer 3 Routes Summary**, and in the route exports.

**Layer 3 All** and **Layer 3 Routed Links Only** use two-pass, size-aware radial component
placement. The first pass decides which side of a device faces each subnet; the measured pass then
places the real host/interface footprints, keeps subnet branches together, aims interface chips at
their peers, and leaves ARP annotations on the outside. Hosts collapse only when their complete
routed behavior and the CIDRs visible on that page are identical. A summary lists every hostname and
every interface/IP row, so compression never hides membership or addressing.

**Layer 3 Routes Only** contains only route-bearing groups and nodes used as route endpoints. A
captured next hop with no routes of its own gets a compact endpoint card; unrelated route-less
devices are not drawn as disconnected host boxes and are instead counted in one small footer with a
hostname sample. A summarized member is never repeated as an individual card.

**Layer 3 Connectivity** and **Layer 3 Routes Summary** use measured landscape radial placement.
The centre is selected from the Layer 3 routing model: a captured firewall/Border device first,
then Transit, then Gateway, with visible route-arrow count used only to break ties. A comparable,
directly connected redundant pair may share the centre. Tall summary leaves — including large
grouped ones — remain outside it with every hostname visible. Route arrows are straight, point from the route
user to its next hop, and use staggered labels. On Routes Summary,
`$GDrawioRoutesSummaryMaxNamesPerGroup = 0` means unlimited and is the default; a positive value is
still available for intentionally capped preview profiles.

Connectivity gives each configured upstream/transit device one outer container. The next-hop
addresses through which other devices reach it and its own outbound routing are child panels inside
that container, eliminating the old duplicate hub/dependant cards. Relationships attach to the
outer boundary so they do not cut through those child panels. Identical non-hub leaf devices still
share a routing-signature node; external next hops remain separate orange cards.

**FW NAT and Interfaces** reads left to right in three labelled stages: **1. Original source**,
**2. Firewall rule match**, and **3. Translation result**. Solid incoming arrows count rules that
match a source; dashed outgoing arrows count rules that produce the translation. The legend and
footer clarify that this is NAT processing order, not return-traffic direction. Translation cards
continue to show mode, address, and egress interface. Unrelated interfaces are left to
`interfaces.csv`; a firewall with no parsed NAT gets a note-only page.
**FW Zone Hub** uses direct straight arrows while retaining policy counts, direction, color, and
weight.

-----

## 💡 Troubleshooting & Limitations

#### Common Issues

  * **TextFSM Errors**: Check that the capture contains the expected command output and is not truncated. The parser automatically retries a failed TextFSM parse against a temporary copy with prompts, echoed commands, and pagination markers removed.
  * **"File doesn't exist" or "No show version files found"**: This error means there is a problem with your file naming. Double-check that every device has a `Identifier.show version.txt` file and that the identifier is consistent.
  * **Duplicate hostnames**: Every captured device must have a unique hostname.

#### Known Limitations

  * Duplicate hostnames are not supported and will cause the script to stop with an error.
  * Junos LLDP neighbor matching may rely on interface descriptions, which could be inaccurate if not standardized.
  * Parsing `show ip arp` from devices with VRFs is not fully implemented.
  * Some MAC-table outputs that associate one address with several interfaces are not fully supported.
  * `AutoDraw.ps1` never connects to network devices. Capture collection is a separate step, handled by the bundled `DataCollection\NetworkAudit.ps1` or by any method of your own.
  * Very dense diagrams may need manual layout adjustments.

-----

## 👍 Best Practices

  * **File Encoding**: ASCII or UTF-8 capture files are recommended.
  * **Break Up the Work**: For large networks, process devices in logical groups (e.g., by building or function) to keep diagrams clean. A diagram with more than 25-30 devices can become very cluttered.

-----

## 🙏 Acknowledgements

This tool stands on the shoulders of giants. Thank you to the following for their libraries and hard work:

  * **Brians worth** for the `GetIPv4Subnet.psm1` module.
  * **The Network to Code (NTC) community and Jason Edelman** for the extensive `ntc-templates` for TextFSM, which do the heavy lifting of configuration parsing.
  * **Carlos Perez** for `Posh-SSH`, which the bundled capture collector uses for every SSH session.

-----

## 📜 Copyright and License

Copyright (C) 2022 Myles Treadwell

This program is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version**.

This program is distributed in the hope that it will be useful, but **WITHOUT ANY WARRANTY**; without even the implied warranty of **MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE**. See the GNU General Public License for more details.
