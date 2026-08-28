# Network Audit GUI

This project collects read-only operational information from network switches, routers, firewalls, and related devices. It is designed for an operator to audit one site in minutes without having to edit PowerShell code.

The application is a native Windows PowerShell 7 and WinForms program. Posh-SSH is its only collection dependency. Telnet support, the GUI, configuration handling, logging, concurrency, and output processing use PowerShell and .NET directly.

## Start here

The two runtime files are:

- `NetworkAudit.ps1` — the GUI and collection engine.
- `NetworkAudit.config.json` — devices, sites, settings, detection commands, and vendor command profiles.

The inventory shipped in `NetworkAudit.config.json` is a set of disabled examples. Replace it with your own devices on the Devices tab, or by editing the JSON directly.

### Requirements

- Windows 10 or Windows 11.
- PowerShell 7 or newer (`pwsh.exe`).
- Posh-SSH 3.2.7 or newer for SSH connections.
- Network access from the computer running the application to the target devices.
- The MTAutoDraw repository root when diagram generation is required. `DataCollection/` lives inside
  that repository, so the default `mtautoDrawRoot` of `..` already points at it.

The application checks for Posh-SSH at startup of a network operation. It explains what is missing but does not install anything automatically.

To confirm the installed version:

```powershell
Get-Module -ListAvailable Posh-SSH | Sort-Object Version -Descending
```

To launch the application from this folder:

```powershell
pwsh.exe -STA -NoProfile -File .\NetworkAudit.ps1
```

## Normal operator workflow

### 1. Enter password sets

Open the **Devices** tab and select **Enter / manage passwords...**.

A password set contains:

- A descriptive name such as `SWITCHES` or `FIREWALL`.
- Username.
- Login password.
- Optional enable-mode password.

The set name must match the `credential` value assigned to a device. Multiple named sets may be held at once.

Passwords are kept only in memory. Closing the application removes them. They are never saved to JSON, CSV, manifests, logs, or error files.

### 2. Review or add devices

Each device row has these fields:

| Field | Meaning |
|---|---|
| `Run` | Whether the device is included when its site is selected. |
| `Device / IP address` | DNS name or IP address used for the connection. |
| `Site` | Free-text site grouping. Values are trimmed and compared without case sensitivity. |
| `Credential name` | Name of the in-memory password set. This is not a username. |
| `Device type` | A forced profile, or `Auto` for detection. |

To add many devices:

1. Paste one target per line into the large box.
2. Choose the default site, device type, and password set.
3. Select **Add pasted switches to device list**.

Blank lines are ignored. Existing targets are not overwritten, which preserves any per-device site, credential, or profile overrides.

Use **Save configuration** to write device or command edits atomically. A temporary file is written first and then replaces the old JSON so an interrupted save does not leave a partially written configuration.

### 3. Select a site

On the **Run** tab, choose one site or **All Sites**. Only enabled devices in that scope are scheduled.

Site names remain exactly as entered. The application does not silently rename or spell-correct them. Blank and `Unassigned` sites generate a warning that requires confirmation.

### 4. Run Safe Preflight

Select **1. Safe Preflight** before a full audit.

Preflight first performs offline checks, including:

- Duplicate targets.
- Missing site or password-set assignments.
- Unknown profiles.
- Empty command profiles.
- Potentially unsafe edited commands.
- MTAutoDraw command coverage for forced profiles.

Online preflight may:

- Test SSH and Telnet ports.
- Authenticate.
- Validate an SSH host key.
- Learn the CLI prompt.
- Run the minimum read-only commands needed to identify the device.
- Exercise the Cisco Legacy double-login sequence and run `show version`.

Online preflight does **not**:

- Enter enable mode.
- Disable paging.
- Run profile collection commands.
- Run specialized BPDU routines.
- Create command-capture files.
- Call MTAutoDraw.

Preflight results are:

| Result | Meaning |
|---|---|
| `Pass` | Authentication, prompt handling, and supported device detection succeeded. |
| `Warning` | The device is reachable but requires attention, such as Telnet, profile disagreement, or a forced profile with unrecognized detection output. |
| `Fail` | Connectivity, authentication, host-key validation, prompt handling, or safe type detection failed. |
| `Cancelled` | The operator cancelled before completion. |

Detection messages are intentionally detailed. They state which read-only commands were attempted, which were rejected, whether a command failed to return to the prompt, and whether the detected family disagrees with the requested profile.

### 5. Run the full audit

Select **2. Run Full Audit**.

The application compares the current devices, sites, requested types, and in-memory password sets with the last preflight. If preflight is missing, stale, warning, or failed, the operator receives one consolidated confirmation showing the affected devices and risks. This warning is informative and does not prevent an authorized full audit.

Full audit workers run concurrently up to `settings.throttleLimit`. The GUI remains responsive while the status grid shows states such as Connecting, Detecting, Preparing, Running command X/Y, Complete, Failed, or Cancelled.

### 6. Generate a site diagram

After at least part of a site completes successfully, select **3. Generate Site Diagram**.

The application:

1. Lets the operator choose one completed site when the audit covered all sites.
2. Compares expected devices with successful captures.
3. Warns before generating a partial diagram.
4. Validates the MTAutoDraw script, Python runtime, templates, TextFSM wrapper, and required module.
5. Starts `AutoDraw.ps1` in a separate hidden PowerShell 7 process.
6. Reads its exit code and `RunSummary.json`.
7. Reports Pass, Warn, or Fail with device and parser-error counts.

MTAutoDraw is never invoked automatically. Cancelling diagram generation terminates only its child process and marks that diagram output incomplete.

## Cisco Small Business families

These profiles are deliberately separate:

| Profile | Connection behavior | Typical identification |
|---|---|---|
| `CiscoSMBNew` | Normal SSH or Telnet CLI. | Newer SG350/SG550/CBS-style output such as `Active-image`. |
| `CiscoSMBOld` | Normal SSH or Telnet CLI. | Older SMB output beginning with `SW version`. |
| `CiscoLegacy` | Telnet full-screen menu followed by an LCLI second login. | Login Screen → password field → Switch Main Menu → Ctrl+Z → `lcli` → second username/password → `#` prompt. |

`CiscoLegacy` Safe Preflight runs `lcli` as a session-establishment command and then read-only `show version`. The response must contain the expected SGE `SW version` signature. Full Audit enforces the same version safety gate before continuing through the legacy profile. Cisco support described this hidden LCLI as unsupported and not recommended, so use the profile only with explicit operational approval; the collector restricts the resulting session to read-only `show` commands.

## Cisco wireless controller families

Wireless controllers use two separate profiles because their operating systems and command sets are different:

| Profile | Baseline | Paging command | Auto-detection evidence |
|---|---|---|---|
| `CiscoAireOSWLC` | Cisco AireOS 8.10.x | `config paging disable` | `show sysinfo` returns an AireOS controller signature such as `Cisco Controller`, `Product Version`, or `Burned-in MAC Address`. |
| `CiscoCatalyst9800WLC` | Catalyst 9800 IOS-XE | `terminal length 0` | `show version` identifies a Catalyst 9800 or a `C9800` platform. This test runs before the general IOS-XE test. |

The complete ordered command lists are in `NetworkAudit.config.json`. Choose one of these profiles when the controller type is known, or choose `Auto` and confirm the resolved type in Safe Preflight before starting the full audit.

## Multi-vendor platform catalog

The configuration includes 50 platform-specific profiles, 28 vendor/project families, and 1,785 ordered read-only collection commands across switches, routers, firewalls, wireless controllers, and access points. Same-vendor operating systems are deliberately separate—for example IOS/IOS XR/NX-OS/ASA/FTD/FXOS, AireOS/Catalyst 9800, ArubaOS-Switch/AOS-CX/ArubaOS 8/Instant, and Dell OS9/OS10.

See [NETWORK_VENDOR_PROFILES.md](NETWORK_VENDOR_PROFILES.md) for the full platform matrix, official vendor command references, login exceptions, and deliberate limitations.

## Configuration reference

`NetworkAudit.config.json` is versioned by `schemaVersion`.

### Settings

| Setting | Purpose |
|---|---|
| `throttleLimit` | Maximum concurrent device workers. Allowed range: 1–64. |
| `hardTimeoutSeconds` | Maximum duration of a CLI read operation. |
| `idleTimeoutSeconds` | Time without output before a read is treated as idle. Must not exceed the hard timeout. |
| `connectionTimeoutSeconds` | SSH session connection timeout. |
| `outputBase` | Parent folder for timestamped audit folders. |
| `mtautoDrawRoot` | Folder containing `AutoDraw.ps1` and its bundled prerequisites. |
| `juniperOutputMode` | `XML` or `Text`. |
| `hostKeyPolicy` | `TrustOnFirstUse` or `KnownOnly`. |
| `debugLogging` | Whether Debug-level events appear in the GUI and `Debug.log`. |

### Device example

```json
{
  "enabled": true,
  "target": "192.0.2.12",
  "site": "ExampleSite",
  "credential": "SWITCHES",
  "type": "CiscoSMBNew"
}
```

Only the password-set name is saved. Do not add username or password properties.

### Engine commands

`engineCommands` contains named commands used for detection or session establishment. Examples include `show version`, AireOS `show sysinfo`, Juniper `cli`, Check Point `clish`, Cisco Legacy `lcli`, and `enable`.

The keys are protected because the code refers to them by name. The Commands tab permits editing their values, but Safe Preflight applies a fixed safety policy and refuses an unsafe detection command.

### Profile structure

Every profile contains:

| Property | Purpose |
|---|---|
| `paging` | Session-only commands tried before collection to prevent paged output. |
| `commands` | Ordered read-only collection commands. |
| `enable` | Whether the profile may require enable mode. |
| `special` | Protected identifier for a specialized collection routine, or `None`. |
| `specialCommands` | Named templates used by that specialized routine. |
| `vendor`, `platform` | Optional human-readable ownership and exact command family. |
| `deviceClasses` | Optional switch/router/firewall/Wi-Fi applicability list. |
| `loginNotes` | Optional operator-facing login, privilege, shell, or transport caveats. |
| `loginHandler` | Optional named collector behavior required before commands can run. |
| `documentation` | Official vendor sources used to build the profile. |

Juniper and Juniper SRX also contain `textCommands`, used when `juniperOutputMode` is `Text`. Their `commands` lists use `| display xml | no-more` so XML mode produces structured, unpaged output.

Command order matters. Duplicate commands are rejected or removed by the editor. Commands can contain quotes, backslashes, pipes, wildcards, and other JSON-safe text.

## Output folders

### Preflight

Preflight creates a timestamped folder like:

```text
NetworkAudit_Preflight_yyyyMMdd_HHmmss\
├── Preflight.csv
├── Preflight.json
└── Debug.log
```

`Preflight.csv` includes the requested and detected type, protocol, verdict, detection commands, rejected detection commands, and detailed message.

### Full audit

A full audit creates:

```text
NetworkAudit_yyyyMMdd_HHmmss\
├── Summary.csv
├── RunManifest.json
├── Debug.log
├── SiteName\
│   └── DeviceName\
│       ├── device-info.txt
│       ├── fingerprint.txt
│       ├── paging.txt
│       └── DeviceName.show.version.txt
└── MTAutoDraw\
    └── SiteName\
        ├── RunSummary.json
        ├── DiagramStatus.json
        └── ...diagram artifacts...
```

The run manifest contains requested devices, requested and resolved types, site scope, preflight state, final status, and commands actually executed. It never contains passwords.

## Security behavior

- Credentials are represented as in-memory `PSCredential` objects.
- Plain-text passwords are revealed only inside a worker when Telnet or enable-mode input requires them.
- Password strings are redacted from captured initial text and exception messages.
- SSH trust-on-first-use uses Posh-SSH `AcceptKey`; it never uses `Force`.
- Changed or untrusted SSH host keys fail Safe Preflight instead of silently falling back to Telnet.
- Telnet always produces a warning because it is unencrypted.
- The fixed Safe Preflight policy is code-owned, not GUI-editable.

## How the code is organized

### Configuration and validation

- `Read-NetworkAuditConfig` reads JSON and supplies backward-compatible defaults.
- `Get-ConfigErrors` validates schema, settings, device references, profiles, required command keys, and duplicates.
- `Save-NetworkAuditConfig` performs atomic JSON saves.
- `Get-OfflinePreflightIssues` applies offline inventory, command-safety, and MTAutoDraw coverage checks.
- `Get-PreflightSignature` detects stale preflight results without including password values.

### Background collection engine

`$script:DeviceWorker` is a self-contained script block copied into a runspace for each scheduled device. Important helpers inside it include:

- `New-Connection` and `Close-Connection` — SSH/Telnet session lifecycle.
- `Read-Chunk`, `Send-Line`, and `Send-Raw` — protocol-neutral stream operations.
- `Read-ToPrompt` and `Get-PromptInfo` — login, paging prompt, CLI prompt, timeout, and authentication handling.
- `Enter-CiscoSmallBusinessLegacyCli` — the Cisco Legacy menu and double-login connector.
- `Invoke-Command` — sends one command, waits for the expected prompt, and records an observation.
- `Detect-Device` — ordered, read-only vendor identification.
- `Get-CleanCommandOutput` — removes command echo, transport noise, and the final prompt.
- Vendor special handlers — Dell OS10, Extreme EXOS, and MikroTik BPDU routines.

Every device worker closes its connection in `finally`, including failures and cancellation.

### GUI and scheduling

- `Show-CredentialManager` manages in-memory password sets.
- `Sync-DevicesFromGrid` and `Load-DevicesIntoGrid` move inventory between the GUI and configuration model.
- `Update-RunPreview` shows the commands that may execute.

### UI smoke test

Run the real Windows Forms construction and menu/profile traversal without connecting to devices:

```powershell
pwsh -NoProfile -STA -File .\NetworkAudit.ps1 -UiSmokeTest
```

The smoke test visits every device profile, main tab, command-editor tab, and site scope, then rebuilds the Run Preview. It exits with a compact JSON `PASS` result or a nonzero error when a GUI event handler fails.
- `Start-ScopedNetworkAuditRun` validates the selected scope and creates background jobs.
- The WinForms `$Timer` drains worker events and updates rows, logs, and overall progress.
- `Complete-NetworkAuditRun` writes final preflight or audit artifacts and disposes the runspace pool.
- `Start-SiteDiagram` runs MTAutoDraw separately so its `exit` statement cannot close the GUI.

## Adding a new device profile

1. Add the profile to `profiles` in the JSON with ordered read-only commands.
2. Add a detection signature and return type in `Detect-Device` when Auto detection is required.
3. If a special connection sequence is required, implement it as a session handler before detection.
4. Add any required engine-command key to both JSON and `Get-ConfigErrors`.
5. Update the MTAutoDraw support and required-capture lists only if its parser supports the profile.
6. Run Safe Preflight against a representative device.
7. Confirm that preflight creates no capture files.
8. Compare full-audit capture names and ordering with a known-good run.

Do not classify a configuration-changing command as read-only merely to make validation pass. Extend the fixed safety policy only after confirming the command's behavior across the supported platform versions.

## Troubleshooting

### Start buttons remain unavailable or a run will not start

Review the configuration error dialog. Common causes are an unloaded password set, duplicate target, unknown profile, missing required command key, blank output folder, or invalid timeout value.

### Authentication succeeds but detection warns

Read the complete Message column or `Preflight.csv`. It lists the commands attempted and rejected. Compare `show version` formatting with an existing signature. Small differences such as a leading carriage return are significant and should be covered by a narrowly tested pattern.

### Cisco Legacy does not reach LCLI

The log identifies the stage that timed out: first Login Screen, Switch Main Menu, second username, second password, or final LCLI prompt. Confirm that the device really uses the legacy full-screen Telnet interface and is assigned `CiscoLegacy`, not `CiscoSMBOld`.

### SSH host key fails

Do not bypass the warning. Confirm the device was replaced or its key intentionally changed, then correct the stored trusted key through the approved operational process.

### Diagram button is disabled

A Full Audit—not a preflight—must complete at least one device for a site during the current application session.

### MTAutoDraw fails prerequisite validation

Confirm the configured root contains `AutoDraw.ps1`, `configurationVariables.ps1`, `StartProcessingConfig.ps1`, `TextFSM.py`, bundled `python\python.exe`, `Templates`, and `GETIPV4Subnet\GetIPv4Subnet.psm1`.

## Safe change checklist

Before distributing a modified version:

1. Parse `NetworkAudit.ps1` with the PowerShell parser.
2. Load and validate the JSON.
3. Confirm target values are unique and all credential names are expected.
4. Verify profile command order and duplicates.
5. Exercise representative Pass, Warning, Fail, and Cancelled preflight paths.
6. Confirm preflight produces only CSV, JSON, and Debug.log.
7. Run mixed successful and failing full-audit workers concurrently.
8. Search outputs for deliberate password-like test values.
9. Verify every connection closes and every device receives one terminal result.
10. Test MTAutoDraw with a path containing spaces and confirm its summary is fresh for the current run.

## Deliberate limitations

- The first release is GUI-focused and has no separate headless mode.
- Sites are free text and are not automatically corrected.
- Password sets are not persisted between application sessions.
- Safe Preflight is recommended and informative but does not block an authorized Full Audit.
- Diagram generation is manual and handles one completed site per invocation.
- The application validates but does not install Posh-SSH or modify MTAutoDraw.
