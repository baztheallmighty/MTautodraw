# Collecting the captures

MTAutoDraw does not talk to your devices. It reads text files that hold the raw output of `show`
commands, one file per command per device, and turns them into a diagram. This guide covers getting
those files.

Use the collector that ships in this repository: **[`DataCollection/NetworkAudit.ps1`](DataCollection/NetworkAudit.ps1)**.
It is a Windows PowerShell 7 and WinForms application that logs into a list of devices over SSH or
Telnet, runs the read-only commands MTAutoDraw needs, writes them out in the expected layout, and can
hand the result straight to `AutoDraw.ps1`.

[`DataCollection/README.md`](DataCollection/README.md) is the full reference for the collector — every
tab, setting, profile, and troubleshooting entry. What follows is the short path from a clean checkout
to a diagram.

## What you need

- Windows 10 or 11.
- PowerShell 7 or newer (`pwsh.exe`).
- [Posh-SSH](https://www.powershellgallery.com/packages/Posh-SSH) 3.2.7 or newer, for SSH targets.
- Network reach from this machine to the devices, and read-only credentials for them.

Check Posh-SSH with:

```powershell
Get-Module -ListAvailable Posh-SSH | Sort-Object Version -Descending
```

The collector checks for it at the start of a run and tells you what is missing. It installs nothing
by itself.

## Step 1 — Launch

From the repository root:

```powershell
pwsh.exe -STA -NoProfile -File .\DataCollection\NetworkAudit.ps1
```

`-STA` is required; WinForms will not start without it.

## Step 2 — Enter your password sets

On the **Devices** tab choose **Enter / manage passwords...**.

A password set is a name, a username, a login password, and optionally an enable password. The name is
a label — `SWITCHES`, `FIREWALL`, `JUNIPER` — that device rows point at, so one credential can serve
many devices and you never type it twice.

Passwords live in memory for the life of the process. They are never written to the JSON, the CSVs,
the manifest, the logs, or the error files, and closing the window discards them.

## Step 3 — Enter your devices

`DataCollection/NetworkAudit.config.json` ships with six **disabled example rows**. They exist to show
the shape of a device entry; replace them with your own.

Each row is:

| Field | Meaning |
|---|---|
| `Run` | Include this device when its site is selected. |
| `Device / IP address` | DNS name or IP used to connect. |
| `Site` | Free-text grouping. One site becomes one diagram. |
| `Credential name` | The name of a password set — not a username. |
| `Device type` | A forced profile, or `Auto` to detect it. |

For a whole site at once, paste one target per line into the large box, pick the default site, type,
and password set, then choose **Add pasted switches to device list**. Existing targets are left alone,
so per-device overrides survive a re-paste.

**Save configuration** writes the edits atomically — a temporary file is written and then swapped in,
so an interrupted save cannot leave you with half a config.

Leave `Device type` on `Auto` unless detection gets it wrong. Forcing a profile skips detection, which
is what you want for gear that answers `show version` ambiguously, and what you do not want otherwise.

## Step 4 — Run Safe Preflight

On the **Run** tab pick one site (or **All Sites**), then **1. Safe Preflight**.

Preflight is the cheap version of the run. Offline it looks for duplicate targets, missing sites or
password sets, unknown or empty profiles, edited commands that are no longer read-only, and gaps
between a forced profile and the commands MTAutoDraw needs. Online it tests the port, authenticates,
validates the host key, learns the prompt, and runs the minimum read-only commands needed to identify
the device.

It does not enter enable mode, disable paging, run collection commands, or write capture files.

| Result | Meaning |
|---|---|
| `Pass` | Authentication, prompt handling, and device detection all worked. |
| `Warning` | Reachable but wants attention — Telnet, a profile disagreement, unrecognized detection output. |
| `Fail` | Connectivity, authentication, host key, prompt handling, or detection failed. |

Read the detail messages on anything that is not a `Pass`. They name the commands attempted, the ones
rejected, and where the session stopped, which is usually enough to fix it without a packet capture.

## Step 5 — Run the full audit

**2. Run Full Audit**.

If preflight is missing, stale, or was not clean, you get one consolidated confirmation listing the
affected devices — informative, not blocking. Workers run concurrently up to `settings.throttleLimit`
(25 by default) and the grid reports each device through Connecting, Detecting, Preparing, Running
command X/Y, and Complete.

Output lands in a timestamped folder:

```text
NetworkAudit_yyyyMMdd_HHmmss\
├── Summary.csv
├── RunManifest.json
├── Debug.log
└── SiteName\
    └── DeviceName\
        ├── device-info.txt
        ├── fingerprint.txt
        ├── paging.txt
        └── DeviceName.show.version.txt
```

The per-device folder is what MTAutoDraw reads. File naming already matches the
`Identifier.Command-Name.txt` convention described in the main [README](README.md#file-naming-convention),
so nothing needs renaming.

The manifest records requested devices, requested and resolved types, site scope, preflight state,
final status, and the commands actually executed. It never contains passwords.

## Step 6 — Generate the diagram

**3. Generate Site Diagram**, once a site has finished.

The collector checks the captures against the devices it expected, warns you before drawing a partial
site, validates the MTAutoDraw script, Python runtime, templates, and TextFSM wrapper, then runs
`AutoDraw.ps1` in a separate process and reports Pass, Warn, or Fail with device and parser-error
counts.

MTAutoDraw is never invoked on its own — you ask for it explicitly.

`settings.mtautoDrawRoot` defaults to `..`, which is correct while `DataCollection/` sits inside this
repository. Point it elsewhere if you move the collector.

## If you cannot run the collector

You do not have to use it. MTAutoDraw only cares about the files, not how they were produced — so any
method works: a terminal emulator's session logging, your existing automation, or your NMS's archive
of `show` output.

Two things must be true of whatever you use:

1. **One command's complete raw output per file**, unpaged and untruncated.
2. **Files named `Identifier.Command-Name.txt`**, with the `Identifier` identical across every file
   from a given device.

The main [README](README.md#required-commands) lists the required commands per platform and the naming
rules in full. `DataCollection/NetworkAudit.config.json` is also readable on its own: its `profiles`
section holds the exact command list this project runs against each of the 23 supported platforms.

## Known issues

- **Junos must be captured as XML.** Use `| display xml` on every Junos command. The text output of
  several Junos commands is ambiguous enough that it cannot be parsed reliably. The collector's
  `juniperOutputMode` setting handles this and defaults to `XML`.
- **Paging must be off.** A capture containing `--More--` is a truncated capture. The collector
  disables paging per profile; if you collect by hand, set `terminal length 0` or the platform's
  equivalent first.
- **The device identifier must be stable.** If half a device's files say `SW1` and the other half say
  `10.0.0.1`, MTAutoDraw sees two devices with half the data each.
