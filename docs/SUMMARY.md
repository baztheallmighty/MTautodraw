# MTAutoDraw documentation

This page is the entry point for project documentation. User instructions, contributor contracts,
generated source indexes, and release history are kept separate so each document has one purpose.

## Start here

| Document | Audience | Purpose |
|---|---|---|
| [`README.md`](../README.md) | Users | Requirements, capture files, configuration, running the tool, outputs, and troubleshooting |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Contributors | Runtime flow, subsystem boundaries, parallel parsing, and drawing contracts |
| [`PARSER_STANDARD.md`](../PARSER_STANDARD.md) | Parser authors | Required structure for vendor modules and capture readers |
| [`PERFORMANCE.md`](PERFORMANCE.md) | Maintainers | Reproducible performance baseline, known hotspots, and profiling guidance |
| [`CHANGELOG.md`](../CHANGELOG.md) | Users and maintainers | Release history and compatibility notes |
| [Capture collection guide](../How%20to%20collect%20the%20show%20commands%20from%20multiple%20devices.md) | Users | Example commands for collecting device output |

## Source map

### Entry point and configuration

| File | Responsibility |
|---|---|
| `AutoDraw.ps1` | Command-line entry point, dependency loading, pipeline orchestration, output files, and final verdict |
| `configurationVariables.ps1` | User-facing settings, feature toggles, parser paths, layout tuning, and palette values |
| `MTAutoDraw.cmd` | Double-clickable launcher for the GUI; reports a missing PowerShell 7 rather than closing silently |
| `MTAutoDrawGui.ps1` | The WinForms window. Runs `AutoDraw.ps1` as a child process and streams its output; never loads the pipeline itself |
| `GuiSettings.ps1` | The GUI's headless half: the settings model parsed out of `configurationVariables.ps1`, profile storage, prerequisite checks, and log-line parsing |

### Ingestion and parsing

| File | Responsibility |
|---|---|
| `StartProcessingConfig.ps1` | Capture discovery, command-to-slot mapping, vendor classification, parallel dispatch, aggregation, and resolution stages |
| `ParserRuntime.ps1` | Capture guards, TextFSM invocation, normalization, and the shared vendor-parser contract |
| `ObjectFunctions.ps1` | Factories that define the device, interface, route, neighbor, policy, and evidence object shapes |
| `NeighborResolution.ps1` | CDP/LLDP identity matching, reciprocal link evidence, flooded-segment filtering, and resolution indexes |
| `Logging.ps1` | Structured diagnostics, phase logging, timing instrumentation, and parallel-safe buffered records |
| `HelperFunctions.ps1` | Cross-cutting helpers that do not belong to a single subsystem, including run-summary construction |

Vendor-specific parsing lives in the eleven `*ConfigProcessingFunctions.ps1` files. Every vendor
module follows [`PARSER_STANDARD.md`](../PARSER_STANDARD.md), which is enforced mechanically against
every module.

### Diagram model and rendering

| File | Responsibility |
|---|---|
| `DiagramModels.ps1` | Shared page models, topology evidence, unresolved peers, end-unit grouping, and firewall-policy models |
| `DiagramModels.Layer3.ps1` | Layer 3 topology, connectivity, and routes-summary models |
| `DiagramModels.Pages.ps1` | Models for the remaining overview and detail pages |
| `DrawLogic_drawio.ps1` | Page orchestration: obtain a model, place nodes, connect them, add scope notes, and close the page |
| `DrawFunctions_drawio.ps1` | Shape and connector presentation; `Add-DrawioCell` is the only Draw.io XML emitter |
| `DrawioDocument.ps1` | Document/page lifecycle, deterministic IDs, page-local shape registration, and XML buffering |
| `LayoutMath.ps1` | Text measurement, grids, tiers, perimeter ports, radial geometry, and collision avoidance |
| `PlacementStrategies.ps1` | Selectable topology-placement strategies |

### Output and optional analysis

| File | Responsibility |
|---|---|
| `Exports.ps1` | CSV and JSON export models and writers |
| `Network Path Analysis.ps1` | Experimental path analysis; disabled by default |
| `GETIPV4Subnet/GetIPv4Subnet.psm1` | Vendored IPv4 subnet calculations |
| `TextFSM.py` and `Templates/` | TextFSM wrapper and parsing templates |

## Documentation rules

- Describe the current behavior and the reason for non-obvious constraints. Put release history in
  `CHANGELOG.md` and implementation history in version control.
- Keep source comments close to the invariant they protect. Avoid comments that only say what a
  previous implementation did.
- Do not maintain hand-written copies of every function or line number. Read them from the source.

- Update `ARCHITECTURE.md` when subsystem ownership or runtime flow changes, and update
  `PARSER_STANDARD.md` when the vendor-module contract changes.
- Run the regression suite after documentation examples or comments that contain executable names,
  flags, or contracts are changed.
