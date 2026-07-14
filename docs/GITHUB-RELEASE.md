# GitHub release handoff

## Repository metadata

**Description**

> Native macOS menu-bar monitor with separate Thermals, CPU, Memory, Network, Battery, and Disk items, compact SwiftUI popovers, and WidgetKit widgets.

**Topics**

`macos`, `apple-silicon`, `menubar`, `swift`, `swiftui`, `temperature`, `fan`, `cpu-monitor`, `memory-monitor`, `network-monitor`, `battery`, `disk-space`, `iokit`, `widgetkit`

## Push and review flow

The public release starts from a sanitized root commit on `main`, containing only the reviewed MacVitals tree and no earlier local history. To publish a new copy, create an empty GitHub repository, replace `<account>`, and run:

```bash
git remote add origin git@github.com:<account>/MacVitals.git
git push -u origin main
```

Let hosted CI pass on the exact public commit before tagging. Signed App Group/widget verification and current screenshots remain explicitly tracked follow-ups for binary distribution and broader release polish.

## Draft v1.0 release notes

### MacVitals 1.0

Initial source release of MacVitals, a native macOS menu-bar thermals and system monitor.

Highlights:

- CPU, GPU, and SoC/other temperature summaries
- Per-fan RPM and load indicators on Macs with fans
- CPU/GPU power sampling on supported Apple Silicon Macs
- 30-minute temperature history
- Readable HID sensor browser
- Separate CPU status item with total/user/system/idle usage, load, core counts,
  temperature, power, and a five-minute chart
- Separate Memory status item with capacity, pressure, breakdown, and history
- Separate Network status item with local active-interface rates and session totals
- Separate Battery status item with charge, state, source, time estimate, Low Power
  Mode, and public condition when available
- Separate Disk status item with startup-volume used, available, and total capacity
- Fixed CPU temperature plus the optional CPU item by default; all optional system
  items remain individually hideable and restorable from the fixed bottom Menu bar
  modules section
- Optional overheat notifications and CSV logging
- Small and medium WidgetKit widgets with compact thermal and system metrics
- Fahrenheit, polling, battery, and launch-at-login settings

The system modules share one sampler: CPU, memory, and network use the selected app
interval; battery and disk are cached for 30 and 60 seconds. The new modules use
public local APIs. The Network item reads an interface name and aggregate counters
only—it makes no request and does not inspect packets, hosts, or connections. MacVitals
does not collect public IP, SSID, MAC addresses, serial numbers, private battery data,
top processes, GPU clocks, SMART data, or disk throughput.

This is a **source-only release**. Clone the repository, set your own Apple Team,
bundle identifiers, and App Group, then build with Xcode 16 or later. Sensor access
uses undocumented macOS interfaces, so readings vary by model and macOS release.
MacVitals reads sensors and local system counters only and never controls fans or sends
data off-device.

### Verification recorded for this source revision

- 36/36 unit tests passed on arm64 macOS 26.5.1
- arm64 Debug build and clean unsigned universal Release build passed
- Six Release runtime samples at a 10-second interval: 0.0% CPU except one 0.5%
  polling wake, about 19 MB private memory, and roughly 77 MB RSS

These are development checks, not a completed hardware matrix. The locked/clean-Mac
visual pass, Intel/additional-hardware coverage, signed App Group/widget run, and all
signing/notarization gates remain open in the release checklist.

## Tagging after merge

From an updated `main` branch:

```bash
git tag -a v1.0 -m "MacVitals 1.0"
git push origin v1.0
```

Do not create the tag until CI passes and the final README screenshots match the
merged code.
