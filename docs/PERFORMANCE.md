# MTAutoDraw performance

This document records a reproducible large-site baseline and the runtime areas most worth profiling.
It is not a release history; use version control and `CHANGELOG.md` for implementation history.

## Baseline and current result

The reference run uses a large capture set - several thousand files across the better part of a
hundred capture groups - on PowerShell 7 and an 8-logical-core machine. Timing instrumentation is
enabled with:

```powershell
$env:MTAUTODRAW_PERF = '1'
.\AutoDraw.ps1 -GDirectory <captures> -GOutPutDirectory <output>
```

Against that capture set the unchanged baseline completed in **193.5 seconds** and the final
flattened build in **185.7 seconds**, a reduction of **7.8 seconds (4.0%)**. All nine CSV exports
and both draw.io files were byte-identical between the two runs. Timing rows are nested: a total can
contain measured sub-steps, so percentages overlap and must not be added.

The absolute figures below are specific to that host and capture set. Treat them as a shape - which
stages dominate - rather than as numbers to reproduce.

| Step | Baseline | Final | Change |
|---|---:|---:|---:|
| Total wall clock | 193.5 s | 185.7 s | -4.0% |
| Parallel parser dispatch | 68.8 s | 55.4 s | -19.5% |
| Parse and resolve total | 85.3 s | 66.9 s | -21.5% |
| Configured-neighbor resolution | 9.4 s | 3.9 s | -58.5% |
| Singles drawing loop | 40.9 s | 41.0 s | +0.3% |
| Per-device Physical pages | 33.0 s | 31.9 s | -3.4% |
| Topology-evidence model | 11.4 s | 10.8 s | -5.3% |

Run-to-run variation of a second or two on one page is normal on a busy workstation. Treat total-run
changes and repeated large differences as meaningful; verify smaller changes across several runs.

## Current hotspots

### Per-device Physical pages

`Draw-SingleHostPhysicalDrawio` and `Get-DrawioHostPhysicalInterfaces` account for most of the
singles loop. Profiling should be added inside these functions before changing their layout or data
model. Page-level timing alone does not identify whether the cost is model construction, text
measurement, placement, or XML emission.

### Parallel parser startup

Each capture group runs in an isolated worker and imports the parser runtime plus its vendor module.
Those workers also launch TextFSM child processes, so using every logical core oversubscribes this
workload. On the reference host, two workers took 53.3 seconds in an isolated dispatch benchmark,
versus 66.5 seconds with eight and 59.1 seconds with one. The production throttle therefore uses
one quarter of the available logical cores, with a minimum of one.

### Topology evidence

`Get-MTAutoDrawTopologyEvidenceModel` remains a significant serial stage. Candidate construction,
identity resolution, and audit-row generation should be timed separately before optimizing it.

## Performance-sensitive design choices

- Neighbor name resolution uses the hashtable indexes from `New-NeighborResolutionIndex`. Avoid
  replacing indexed lookups with repeated scans of the complete device array inside neighbor loops.
- Reciprocal neighbour evidence and normalized interface identities are indexed once per run. Keep
  site-wide scans and interface normalization out of the per-neighbour match loop.
- Draw.io XML accumulates in the `StringBuilder` owned by `DrawioDocument.ps1`. Materialize the full
  string only when a consumer needs it; repeated string concatenation scales poorly in time and
  memory for large documents.
- Physical-page model construction uses lookup tables for interface ownership and normalized CDP/LLDP
  identities. Prefer building a lookup once per page over scanning all devices for every neighbor.
- Palette objects and physical-port text measurements are reused during drawing. Avoid rebuilding
  immutable presentation data for every shape.

## Measuring a change

1. Use the same captures, settings, PowerShell version, and machine.
2. Run once to warm filesystem and antivirus caches, then record several instrumented runs.
3. Compare medians for the affected nested timing row and for total wall-clock time.
4. Re-run the same captures and diff the generated `.drawio` files and CSV exports. A speed
   improvement is invalid if page structure, exports, diagnostics, or parser results change
   unintentionally.
5. For an intentional output change, open the rendered diagrams and look at them.
