# MTAutoDraw parser standard, v1

Every `*ConfigProcessingFunctions.ps1` module does the same job: read a capture, reject junk, extract
rows, build objects, attach them to a device. This document says how, so that a new platform is one
new file plus a dispatcher entry, and so a reader who knows one module can read all of them.

A module declares conformance by carrying this on line 1:

```powershell
# MTAutoDraw-Standard: v1
```

The marker is an explicit module-level contract, and **all eleven vendor modules carry it.** It is
what a conformance check keys off: a marked module is held to sections 2 to 4 of this document, and a
module without the marker is reported as unmarked and skipped, which is what lets a twelfth platform
be added before it conforms.

**Reference implementation: [`CiscoIOSXRConfigProcessingFunctions.ps1`](CiscoIOSXRConfigProcessingFunctions.ps1).**
Read it alongside this document. To start a new platform, copy
[`Templates/_NewPlatformTemplate.ps1`](Templates/_NewPlatformTemplate.ps1).

---

## 1. Where a module sits

```
AutoDraw.ps1                        entry / CLI
└─ StartProcessingConfig.ps1        ingest → classify → dispatch → aggregate
   └─ <Platform>ConfigProcessingFunctions.ps1
      ├─ Process-<Platform>HostFiles    orchestrator — exactly one per module
      ├─ Update-<Platform><Subject>     capture reader — one per capture
      └─ private <Platform>-prefixed helpers
```

Ingestion has already run before your module is called. `Get-ConfigCaptureIdentity` parsed the
filename, `Get-ConfigCaptureDefinition` mapped the command to a slot, and `Create-FileHostObjects`
built the capture group. **Your module never touches the filesystem beyond the paths handed to it** —
there is not a single `.txt` literal in any vendor module, and it must stay that way.

## 2. Naming

| Kind | Shape | Example |
|---|---|---|
| Orchestrator | `Process-<Platform>HostFiles` | `Process-CiscoIOSXRHostFiles` |
| Capture reader | `Update-<Platform><Subject>` | `Update-CiscoIOSXRArp` |
| Device constructor | `New-<Platform>DeviceFrom<Source>` | `New-JunosDeviceFromShowRun` |
| Anything else | `<Verb>-<Platform><Thing>` | `Resolve-CiscoIOSXRInterface` |

**Every function in the module carries the platform token, without exception.** All nineteen modules
load into a single PowerShell session, so an unprefixed `Get-ShowInterfaceFromText` is a live
collision, not a style preference.

*Subject* is the domain noun — `Interfaces`, `InterfaceBrief`, `Version`, `Routes`, `Arp`,
`MacAddressTable`, `CdpNeighbors`, `LldpNeighbors`, `SpanningTree` — not the capture slot, because
several readers consume more than one slot. `Update-CiscoRoutes` takes the plain, `vrf *` and
`vrf all` captures together.

The orchestrator name is invoked by string from
[`StartProcessingConfig.ps1`](StartProcessingConfig.ps1), so it cannot be renamed casually.

## 3. The orchestrator is a flat list

```powershell
function Process-CiscoIOSXRHostFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$HostID,
        $ArrayOfObjects   # dispatcher signature compatibility; duplicate detection is sequential
    )

    # 1. IDENTITY
    $device = New-MTAutoDrawDevice -Platform 'CiscoIOSXR' -HostID $HostID
    Update-CiscoIOSXRVersion -Device $device -Path $HostID.ShowVersion
    if (-not $device.Version) { Write-MTAutoDrawDiagnostic ... ; return $null }
    Update-CiscoIOSXRRunningConfig -Device $device -Path $HostID.ShowRun
    if (-not $device.hostname) { Write-MTAutoDrawDiagnostic ... ; return $null }

    # 2. CAPTURES — one line per slot, in dependency order
    Update-CiscoIOSXRInterfaceBrief -Device $device -Path $HostID.ShowIPInterfaceBrief
    Update-CiscoIOSXRArp            -Device $device -Path ($HostID.ShowArp ?? $HostID.ShowIPArp)
    Update-CiscoIOSXRCdpNeighbors   -Device $device -Path $HostID.ShowCDPNeighborsDetails
    ...

    # 3. RECONCILE
    return (Complete-MTAutoDrawDevice -Device $device)
}
```

Rules:

- **`New-MTAutoDrawDevice` always creates the device.** Not the show-run parser, not the
  show-system-info parser. One answer to "who builds the host object".
- **No `if ($HostID.X)` wrappers.** Readers are called unconditionally; a reader handed `$null`
  returns immediately. This is what makes the capture list readable as a list.
- **No duplicate-hostname check.** The dispatcher always passes `-ArrayOfObjects $null` because it
  cannot be done safely in parallel; the real check is sequential, after aggregation.
- **No `Write-Host`, no `Start-CleanupAndExit`.** Both are hostile inside `ForEach-Object -Parallel`.
- **Return `$null` to reject a device**, only for genuine identity failures.

## 4. Every capture reader has the same four-step body

```powershell
function Update-CiscoIOSXRCdpNeighbors {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Device,
        [AllowNull()][AllowEmptyString()][string]$Path
    )

    # --- GUARD ---
    if (-not (Test-MTAutoDrawCaptureReadable -Device $Device -Path $Path -Capture 'ShowCDPNeighborsDetails')) { return }

    # --- EXTRACT ---
    $rows = Invoke-MTAutoDrawTextFSM -Device $Device -Template 'cisco_xr_show_cdp_neighbors_detail' -Path $Path
    if (@($rows).Count -eq 0) { return }

    # --- MAP + MERGE ---
    $Device.CDPNeighbors = @(foreach ($row in $rows) {
        $neighbor = Create-CDPNeighborObject
        $neighbor.DeviceID             = $row.CHASSIS_ID
        $neighbor.InterfaceLocalDevice = $row.LOCAL_INTERFACE
        $neighbor.ParentObject         = $Device.hostname
        $neighbor
    })
}
```

| Step | Rule |
|---|---|
| **Guard** | `Test-MTAutoDrawCaptureReadable` only. A shared guard keeps CLI-error and missing-capture handling consistent across platforms. |
| **Extract** | `Invoke-MTAutoDrawTextFSM` for TextFSM, or `Get-MTAutoDrawCaptureText` + `[regex]::Matches` with **named** groups. Never positional TextFSM indices. |
| **Map** | `Create-*Object` factories from `ObjectFunctions.ps1`. Normalise through `ConvertTo-NormalizedMacAddress`, `Get-NormalizedIPv4Cidr`, `Replace-InterfaceShortName`. |
| **Merge** | `Resolve-MTAutoDrawInterface` / `Add-MTAutoDrawNetwork`. Never a blind `+=` that can duplicate an interface. |

**Signature is fixed**: `-Device` (mandatory) and `-Path` (nullable string). **Readers return nothing.**
`PSCustomObject` is a reference type, so `$Device = Get-X -Device $Device` is ceremony that also
silently swallows stray pipeline output. Suppress incidental output with `$null =`.

**Diagnostics go to `Write-MTAutoDrawDiagnostic`.** It tolerates a `$null` device — the case a parser
hits when a required capture is missing and there is no device yet.

## 5. Shared scaffolding

In [`ParserRuntime.ps1`](ParserRuntime.ps1), under `#region Parser standard`:

| Helper | Purpose |
|---|---|
| `Test-MTAutoDrawCaptureReadable -Device -Path -Capture` | The guard. Null path = not collected, not an error. Wraps `Test-FileHasValidData`, logs why it skipped. |
| `Get-MTAutoDrawCaptureText -Path [-AsLines]` | Read a capture. Always `-LiteralPath`; never mutates the source. |
| `Invoke-MTAutoDrawTextFSM -Device -Template -Path` | TextFSM rows as objects keyed by the template's `Value` names. Returns `@()` on any failure. |
| `Resolve-MTAutoDrawInterface -Device -Name [-NoCreate]` | Find-or-create by interface name. |
| `Add-MTAutoDrawNetwork -Device -Cidr [-RoutedVlan] [-NetworkName] [-IPAddress]` | Create/dedupe a network and seed its deterministic colour. |
| `New-MTAutoDrawDevice -Platform -HostID` | Build the host object with `DeviceType`, `Origin`, `DeviceIdentifier` set. |
| `Complete-MTAutoDrawDevice -Device` | The common tail: sort/unique interfaces and networks, then `Update-LocalRoutesWithInterfaces`. |
| `Write-MTAutoDrawDiagnostic -Device -Message [-Severity]` | The one diagnostic channel. Null-device tolerant. |

### TextFSM by name, not by position

`TextFSM.py --objects` emits `{"header": [...], "rows": [...]}` and
`Invoke-MTAutoDrawTextFSM` maps each row to named properties. Readers use properties such as
`$row.INTERFACE` and `$row.ADDRESS`; positional access such as `$row[7]` is prohibited because a
template can reorder its `Value` declarations while still returning plausible data in the wrong
fields.

`Invoke-MTAutoDrawTextFSM` normalizes single-row and multi-row results to the same object-array
shape. Failure returns an empty array and records a diagnostic; readers do not inspect sentinel
strings or mutate parser scratch properties.

## 6. Globals a module may read

Only those marshalled into the parallel runspace at
[`StartProcessingConfig.ps1`](StartProcessingConfig.ps1) — currently `$GMacAddressToVendorMapping`,
`$GPathToScript`, `$GPathToPythonExe`, `$GPathToPythonTextFSMScript`, `$GTextFSMTemplates`,
`$GSkipCDPLLDPPhones`, `$GDrawPortsWithMacs`, `$GDrawCDP`, `$GSkipHSRPRoutes`, `$GDrawAprEntries`,
`$SkipHostnameErrorCheck`, `$GDebugingEnabled`, `$GLastExecutionTime`, `$GLogLevel`.

> Reading any other main-runspace value silently yields `$null` in a worker. Adding a global to a
> vendor module therefore requires adding it to the `$using:` initialization list in the same change.

## 7. Adding a platform

1. Copy `Templates/_NewPlatformTemplate.ps1` to `<Platform>ConfigProcessingFunctions.ps1`.
2. Add `Add-CaptureDefinition` lines for any commands not already mapped, in
   `Get-ConfigCaptureDefinition`.
3. Add any genuinely new capture slots to `Create-FileObject` in `ObjectFunctions.ps1`.
4. Add a detection branch to `Get-ConfigDeviceType` — ordering matters, more specific first.
5. Add a dispatch branch to the `switch` in `StartProcessingConfig.ps1` setting `$processorName`.
6. Load every module into one session and confirm the new file introduces no name collisions.
7. Run the new parser against a sanitized capture from the platform and confirm the objects it
   produces match what the drawing layer expects.
