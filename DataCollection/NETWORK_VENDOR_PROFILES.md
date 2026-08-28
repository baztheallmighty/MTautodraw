# Network vendor and platform profiles

`NetworkAudit.config.json` contains 50 platform profiles for 28 vendor/project families and 1,785 ordered collection commands. Profiles are intentionally split by operating system and management plane, not just by vendor name. A command that is valid on one family must not be assumed to exist on another family from the same vendor.

The expanded command catalog covers the nearest vendor-documented equivalents for:

- software, boot image, licenses, uptime, clock, running configuration, and hardware inventory;
- chassis, modules, power supplies, fans, temperature, CPU, memory, storage, logs, and alarms;
- physical and logical interfaces, counters/errors, descriptions, optics/transceivers, PoE, LAG/LACP, VLANs, MAC/FDB, STP, ARP/NDP, and LLDP/CDP;
- IPv4/IPv6 interfaces and routes, VRFs, BGP, OSPF/OSPFv3, IS-IS, RIP, multicast, BFD, VRRP, and high availability where the platform supports them;
- firewall policies/ACLs, sessions/connections, NAT, VPN/IKE/IPsec, clustering/failover, and security-gateway state;
- controller/AP inventory, radios, WLANs/SSIDs, clients, associations, joins, roaming, RF/ARM, licensing, and HA for documented Wi-Fi CLIs.

Every command-capable profile has at least 25 collection commands except `UbiquitiUniFiNetwork`, which deliberately contains only the officially documented `info` command. `CiscoSG200Web` deliberately contains none because those SG200 models do not provide a usable audit CLI. These exceptions are not padded with unsupported Linux or community-only commands.

Every profile added by the multi-vendor expansion includes these optional metadata fields:

- `vendor` and `platform` identify the exact command family.
- `deviceClasses` records whether the profile applies to switches, routers, firewalls, Wi-Fi controllers, or access points.
- `loginNotes` records privilege, shell, menu, transport, and controller-specific caveats.
- `loginHandler`, when present, names collector logic required before commands can run.
- `documentation` contains the official vendor pages from which the command set and session behavior were derived.

The command lists remain the executable source of truth. Always run **Safe Preflight** and confirm the resolved profile before a full audit. Automatic detection is best effort because OEM strings, virtual appliances, and compatibility shells can overlap.

## Platform coverage

### Cisco and Cisco-derived families

| Profile | Platform and use |
|---|---|
| `CiscoIOS` | IOS and IOS-XE switches and routers. |
| `CiscoIOSXR` | IOS XR routers; separate operational CLI and task-based permissions. |
| `CiscoNXOS` | Nexus NX-OS switches. |
| `CiscoASA` | ASA firewall CLI. |
| `CiscoFTD` | Secure Firewall Threat Defense diagnostic CLI. Do not substitute ASA or FXOS commands. |
| `CiscoFXOS` | Firepower chassis/FXOS CLI. Do not substitute FTD diagnostic commands. |
| `CiscoAireOSWLC` | AireOS wireless controllers; uses `config paging disable` and AireOS commands. |
| `CiscoCatalyst9800WLC` | Catalyst 9800 IOS-XE wireless controllers; uses IOS-XE-style paging but controller-specific commands. |
| `CiscoSMBNew` | SG350/SG550/CBS normal CLI. |
| `CiscoSMBOld` | Older Small Business 200/300 normal CLI. |
| `CiscoLegacy` | Historical SGE menu and LCLI with a second login. |
| `CiscoSG200Web` | Web-only SG200 family marker; deliberately runs no CLI commands. |

### Other switch and router platforms

| Profile | Platform and use |
|---|---|
| `Juniper` / `JuniperSRX` | General Junos and the SRX security-specific command set. Both support XML or text capture. |
| `AristaEOS` | Arista EOS. |
| `ArubaCX` / `ArubaAOSSwitch` | AOS-CX versus the older ProVision/ArubaOS-Switch CLI. |
| `DellOS10` / `DellOS9` | Dell OS10 versus the older FTOS/OS9 family. |
| `HPEComware` / `H3C` / `Huawei` | Related-looking but separate Comware, H3C, and Huawei command families. |
| `ExtremeEXOS` / `ExtremeVOSS` / `ExtremeSLXOS` | EXOS, VOSS, and SLX-OS are kept separate. |
| `NokiaSROS` | Nokia SR OS classic/model-driven operational CLI. |
| `NvidiaCumulusLinux` | Cumulus Linux 5.x using the NVUE `nv show` interface. |
| `VyOS` | VyOS operational CLI. Configuration capture uses the documented private-value stripping option. |
| `SONiC` | Community SONiC operational `show` commands. |
| `RuckusFastIron` | RUCKUS ICX/FastIron. |
| `AlliedTelesisAWPlus` | AlliedWare Plus. |
| `TPLinkJetStream` | TP-Link JetStream/Omada managed-switch CLI. |
| `NetgearManagedSwitch` | NETGEAR M4250/M4300/M4350 fully managed CLI. |
| `SonicWallSwitch` | SonicWall Switch CLI; distinct from SonicWall firewall appliances. |
| `CambiumcnMatrix` | Cambium cnMatrix switch/router CLI. |
| `MikroTik` | RouterOS. |
| `UbiquitiEdgeSwitch` | EdgeSwitch/EdgeOS-style CLI; distinct from UniFi. |

### Firewall, security, and application-delivery platforms

| Profile | Platform and use |
|---|---|
| `PaloAlto` | PAN-OS operational CLI. |
| `CheckPoint` | Gaia clish, with automatic transition from Expert shell when detected. |
| `FortiGate` / `FortiSwitch` | FortiOS firewall/router commands versus FortiSwitch commands. |
| `F5BIGIPTMSH` / `F5BIGIPBash` | Native tmsh versus an advanced shell where every command must be prefixed with `tmsh`. |
| `WatchGuardFireware` | Firebox/Fireware CLI. |
| `SophosFirewall` | Sophos Firewall Device Console reached through the SSH admin menu. |
| `BlueCoat` | Broadcom/Symantec ProxySG CLI. |

### Wireless platforms

| Profile | Platform and use |
|---|---|
| `CiscoAireOSWLC` / `CiscoCatalyst9800WLC` | Separate AireOS and IOS-XE controller command families. |
| `ArubaAOS8Controller` | ArubaOS 8 Mobility Conductor/controller CLI. |
| `ArubaInstantAOS8` | Instant AOS-8 virtual controller or standalone AP. |
| `UbiquitiUniFiNetwork` | Adoptable UniFi Network AP, switch, or gateway SSH CLI. |
| `CambiumEnterpriseWiFi` | Cambium enterprise Wi-Fi access-point CLI. |

## Login and session exceptions

| Profile | Required treatment |
|---|---|
| `CiscoLegacy` | Telnet only. The collector completes the first full-screen menu login, sends Ctrl+Z, runs `lcli`, then performs a second username/password login. This is implemented by `CiscoSmallBusinessLegacyMenu`. Cisco support described this hidden CLI as unsupported and not recommended, so it requires explicit operational approval and is restricted here to read-only `show` commands. |
| `CiscoSMBOld` / `CiscoSMBNew` | Normal SSH or Telnet CLI. Do not select `CiscoLegacy` unless the full-screen menu and second LCLI login really exist. |
| `CiscoSG200Web` | No usable audit CLI. The collector records the web-only limitation and sends no commands. |
| `UbiquitiUniFiNetwork` | Device SSH credentials are distinct from the UniFi console account and may be controlled by the Network application. Direct-console SSH and adoptable-device SSH are different workflows. The conservative audit command is the officially documented `info`. |
| `SophosFirewall` | The `admin` SSH login lands on a numbered menu. The collector selects option 4, **Device Console**, before it runs commands. The Advanced Shell is intentionally not entered. |
| `Juniper` / `JuniperSRX` | Some accounts land in the Junos Unix shell. The collector runs `cli` before collection when that shell prompt is detected. |
| `CheckPoint` | An account in Expert shell is moved into Gaia clish with `clish` before collection. |
| `F5BIGIPTMSH` / `F5BIGIPBash` | Select the profile that matches the account's default shell. Native tmsh commands omit the prefix; advanced-shell commands include it. |
| `CiscoIOSXR` | Access is governed by IOS XR task permissions rather than an IOS-style enable step. Use a read-capable account. |
| Profiles with `enable: true` | The collector may enter enable mode. The credential set must supply the privilege secret where the device requires one. |

## Official command references used for the added profiles

The following are vendor-owned or official project documentation pages. The exact links are also stored next to each added profile in `NetworkAudit.config.json`.

- Cisco: [IOS/IOS-XE fundamentals](https://www.cisco.com/c/en/us/td/docs/ios-xml/ios/fundamentals/command/cf_command_ref/cf_command_ref_CLT_chapter.html), [Nexus NX-OS show commands](https://www.cisco.com/c/en/us/td/docs/dcn/nx-os/nexus9000/105x/command-reference/show/b_n9k_show_commands_1051/m_r_showcmds.html), [ASA command reference](https://www.cisco.com/c/en/us/td/docs/security/asa/asa-command-reference/A-H/asa-command-ref-A-H.html), [IOS XR show commands](https://www.cisco.com/c/en/us/td/docs/iosxr/asr9000/system-setup/cumulative/command/reference/b-system-setup-cr-asr9000/m-show-commands.html), [IOS XR task permissions](https://www.cisco.com/c/en/us/td/docs/ios_xr_sw/iosxr_r4-1/task_ids/reference/guide/task_id_41/td41tid.html), [AireOS 8.10 command reference](https://www.cisco.com/c/en/us/td/docs/wireless/controller/8-10/cmd-ref/b-cr810.html), [Catalyst 9800 show commands](https://www.cisco.com/c/en/us/td/docs/wireless/controller/9800/command-reference/b_wireless_cr/show-commands.html), [FTD command reference](https://www.cisco.com/c/en/us/td/docs/security/firepower/command_ref/b_Command_Reference_for_Firepower_Threat_Defense/Command_Reference_for_Firepower_Threat_Defense_CLT_chapter.html), [FXOS CLI reference](https://www.cisco.com/c/en/us/td/docs/security/firepower/fxos/CLI_Reference_Guide/b_FXOS_CLI_reference/b_CLI_reference_chapter_0100.html), [SGE command reference](https://www.cisco.com/c/dam/en/us/td/docs/switches/lan/csbms/sge2000/reference/guide/sge_refguide.pdf), and [Cisco support's LCLI warning](https://community.cisco.com/t5/switches-small-business/cli-for-se2010/m-p/1964721).
- Juniper: [Junos operational-mode overview](https://www.juniper.net/documentation/us/en/software/junos/cli/topics/topic-map/junos-cli-operational-overview.html), [Junos operational command index](https://www.juniper.net/documentation/us/en/software/junos/cli-reference/topics/topic-map/operational-commands.html), [SRX security policies](https://www.juniper.net/documentation/us/en/software/junos/cli-reference/topics/ref/command/show-security-policies.html), and [chassis-cluster status](https://www.juniper.net/documentation/us/en/software/junos/cli-reference/topics/ref/command/show-chassis-cluster-status.html).
- Arista: [EOS command-line interface](https://www.arista.com/en/um-eos/eos-command-line-interface-cli) and [EOS user manual](https://www.arista.com/en/assets/data/pdf/user-manual/um-books/EOS-User-Manual.pdf).
- HPE Aruba Networking: [AOS-CX CLI guide](https://arubanetworking.hpe.com/techdocs/AOS-CX/10.15/PDF/cli_6000-6100.pdf), [ArubaOS-Switch management guide](https://www.arubanetworks.com/techdocs/AOS-Switch/16.09/Aruba%203810%20_%205400R%20Management%20and%20Configuration%20Guide%20for%20ArubaOS-Switch%2016.09.pdf), [ArubaOS 8 CLI reference](https://arubanetworking.hpe.com/techdocs/ArubaOS-8.x-Books/ArubaOS-8.x-CLI-Reference-Guide.pdf), [ArubaOS 8 paging](https://arubanetworking.hpe.com/techdocs/CLI-Bank/Content/aos8/paging.htm), and [Instant AOS-8 API/CLI command guide](https://arubanetworking.hpe.com/techdocs/Aruba-Instant-8.x-Books/812/Aruba-Instant-8.12.0.0-REST-API-Guide.pdf).
- Fortinet: [FortiGate CLI troubleshooting commands](https://docs.fortinet.com/document/fortigate/7.4.0/cli-troubleshooting-cheat-sheet/420966), [FortiOS CLI basics](https://docs.fortinet.com/document/fortigate/7.2.2/administration-guide/896276/cli-basics), [FortiSwitch get reference](https://docs.fortinet.com/document/fortiswitch/7.6.4/fortiswitchos-cli-reference/896953/get), and [FortiSwitch diagnose reference](https://docs.fortinet.com/document/fortiswitch/7.6.2/fortiswitchos-cli-reference/452179/diagnose).
- Palo Alto Networks: [PAN-OS operational command hierarchy](https://docs.paloaltonetworks.com/ngfw/pan-os-cli-quick-start/cli-command-hierarchy/pan-os-11-1-cli-ops-command-hierarchy) and [device-management CLI cheat sheet](https://docs.paloaltonetworks.com/ngfw/pan-os-cli-quick-start/cli-cheat-sheet-device-management).
- Check Point: [Gaia Clish command summary](https://sc1.checkpoint.com/documents/R81.20/WebAdminGuides/EN/CP_R81.20_Gaia_AdminGuide/Content/Topics-GAG/Gaia-Clish-Commands.htm), [interface CLI reference](https://sc1.checkpoint.com/documents/R81.20/WebAdminGuides/EN/CP_R81.20_Gaia_AdminGuide/Content/Topics-GAG/CLI-Reference-_interface_.htm), and [role/command matrix](https://sc1.checkpoint.com/documents/R81.20/WebAdminGuides/EN/CP_R81.20_Gaia_AdminGuide/Content/Topics-GAG/Roles-Available-Features.htm).
- Broadcom/Symantec: [ProxySG version](https://knowledge.broadcom.com/external/article/398917/how-to-check-proxysg-version-via-comman.html), [incident show commands](https://knowledge.broadcom.com/external/article/384560/commands-to-run-for-incident-tickets-reg.html), and [policy viewing](https://knowledge.broadcom.com/external/article/167669/how-to-view-policy-on-proxysg-via-cli.html).
- Ubiquiti: [EdgeSwitch CLI reference](https://dl.ui.com/guides/edgemax/EdgeSwitch_CLI_Command_Reference_UG.pdf) and [UniFi SSH/debug access and credentials](https://help.ui.com/hc/en-us/articles/204909374-Connecting-to-UniFi-with-Debug-Tools-SSH).
- MikroTik: [RouterOS CLI](https://help.mikrotik.com/docs/spaces/ROS/pages/328134/Command+Line+Interface), [IP routing](https://help.mikrotik.com/docs/spaces/ROS/pages/328084/IP+Routing), and [bridge VLAN table](https://help.mikrotik.com/docs/spaces/ROS/pages/28606465/Bridge+VLAN+Table).
- RUCKUS: [FastIron command reference](https://support.ruckuswireless.com/documents/4694-fastiron-10-0-20-ga-command-reference-guide).
- Nokia: [SR OS show commands](https://documentation.nokia.com/sr/26-7/7750-sr/books/services-configuration-reference/show-commands.html) and [classic CLI overview](https://documentation.nokia.com/sar-gen-2/26-3/7705-sar/books/classic-cli-command-reference/classic-cli-overview.html).
- NVIDIA: [Cumulus Linux quick start](https://docs.nvidia.com/networking-ethernet-software/cumulus-linux-58/Quick-Start-Guide/) and [NVUE CLI](https://docs.nvidia.com/networking-ethernet-software/cumulus-linux/System-Configuration/NVIDIA-User-Experience-NVUE/NVUE-CLI/).
- VyOS: [operational information commands](https://docs.vyos.io/en/latest/operation/information.html), [CLI usage](https://docs.vyos.io/en/1.4/cli.html), and [LLDP](https://docs.vyos.io/en/1.5/configuration/service/lldp.html).
- F5: [tmsh reference](https://clouddocs.f5.com/cli/tmsh-reference/v15/general/tmsh.html) and [BIG-IP tmsh reference PDF](https://techdocs.f5.com/content/kb/en-us/products/big-ip_ltm/manuals/product/bigip-tmsh-reference-12-0-0/_jcr_content/pdfAttach/download/file.res/bigip-tmsh-reference-12-0-0.pdf).
- Dell: [SmartFabric OS10 user guide](https://dl.dell.com/manuals/common/SmartFabricOS-10-5-0-UG-en-us.pdf), [OS10 MAC-table command](https://www.dell.com/support/manuals/en-us/smartfabric-os10-emp-partner/smartfabric-os-user-guide-10-5-5/show-mac-address-table?guid=guid-6839c482-101d-4fe1-9bfc-af1e2e49c04e&lang=en-us), [OS9 show tech-support](https://www.dell.com/support/manuals/en-us/dell-emc-os-9/s4048-on-9.14.2.4-cli/show-tech-support?guid=guid-e76b2a24-0f5d-43b3-848e-ac09e6f18927&lang=en-us), and [OS9 show version](https://www.dell.com/support/manuals/en-us/dell-emc-os-9/s5048f-on-9.14.2.8-cli-pub/show-version?guid=guid-c13e3d17-f476-4c42-9c71-414d38b56915&lang=en-us).
- HPE: [Comware 5140 HI command reference](https://arubanetworking.hpe.com/techdocs/comware/5140hi_switches/HPEFlexNetwork5140HISwitchFundamentalsCRG.pdf) and [Comware 5960 command reference](https://arubanetworking.hpe.com/techdocs/comware/5960/HPENtwrkCmwr5960FundamentalsCR_R9126P01.pdf).
- Allied Telesis: [AlliedWare Plus x230 command reference](https://www.alliedtelesis.com/sites/default/files/documents/manuals/x230_command_ref.4.7-0.x_revc.pdf).
- TP-Link: [managed-switch system management guide](https://www.tp-link.com/us/configuration-guides/managing_system/).
- NETGEAR: [M4350 CLI manual](https://www.downloads.netgear.com/files/GDC/M4350/M4350_CLI_Manual_EN.pdf) and [M4300 CLI manual](https://www.downloads.netgear.com/files/GDC/M4300/M4300-M4300-96X_CLI_EN.pdf).
- Huawei/H3C: [Huawei status-check commands](https://info.support.huawei.com/enterprise/en/doc/EDOC1100333828/91652f17/device-status-checking-commands), [Huawei interface commands](https://info.support.huawei.com/enterprise/en/doc/EDOC1100333403/cdd85713/basic-interface-configuration-commands), and [H3C Comware command references](https://www.h3c.com/en/d_202511/2698935_294551_0.htm).
- Extreme Networks: [EXOS command reference](https://documentation.extremenetworks.com/exos_commands_32.7.1/downloads/EXOS_Command_Reference_32.7.1.pdf), [VOSS command references](https://documentation.extremenetworks.com/VOSS%20v9.2%20Command%20References/downloads/VOSS_9_2_Command_References.pdf), [SLX-OS command reference](https://documentation.extremenetworks.com/slxos/sw/20xx/20.3.2b/commands/GUID-55E5DBC9-B10E-4E09-92B2-6B8D52041F5E.shtml), and [supported SLX show commands](https://documentation.extremenetworks.com/slxos/sw/20xx/20.1.1/commands/GUID-AD3115F3-F140-4DFB-A54C-EC26674644F6.shtml).
- SONiC: [official source and component index](https://github.com/sonic-net/SONiC/blob/master/sourcecode.md) and [technical FAQ](https://github.com/sonic-net/SONiC/wiki/Technical-FAQs).
- WatchGuard: [Fireware CLI reference](https://www.watchguard.com/help/docs/fireware/12/en-US/CLI/CLI_Reference_v12_7.pdf).
- SonicWall: [Switch CLI reference](https://www.sonicwall.com/techdocs/pdf/switch-cli_reference_guide.pdf).
- Cambium Networks: [cnMatrix CLI user guide](https://www.cambiumnetworks.com/resource/cnmatrix-user-guide-cli/), [cnMatrix command reference](https://www.cambiumnetworks.com/resource/cnmatrix-cli-commands-and-parameters/), and [enterprise Wi-Fi AP CLI reference](https://brandcentral.cambiumnetworks.com/m/3842e11240844eac/original/Enterprise-Wi-Fi-Access-Point-Command-Line-Interface-Reference-Guide.pdf).
- Sophos: [Device Console](https://docs.sophos.com/nsg/sophos-firewall/21.5/help/en-us/webhelp/onlinehelp/CommandLineHelp/DeviceConsole/index.html) and [system diagnostics commands](https://docs.sophos.com/nsg/sophos-firewall/21.0/help/en-us/webhelp/onlinehelp/CommandLineHelp/DeviceConsole/SystemCommands/Diagnostics/index.html).

## Deliberate limitations

- UniFi exposes different access paths for consoles and adopted devices, and firmware families differ. The profile therefore uses only the officially documented, conservative `info` command instead of importing community command lists.
- Meraki Dashboard-managed devices are not represented as a pretend SSH profile; their supported management surface is API/dashboard based.
- pfSense and OPNsense are not added as generic shell profiles. Their menu and underlying shell commands require a different safety model from this read-only CLI collector.
- Vendor command availability can still vary by release, license, hardware capabilities, and account permissions. Unsupported-command output is captured without stopping the rest of the profile, but it must not be interpreted as proof that a feature is absent.
