# MacVitals

A lightweight menu-bar thermals and system monitor for macOS, focused on Apple
Silicon.

MacVitals provides separate menu-bar items for Thermals, CPU, Memory, Network, Battery,
and Disk. Each item has its own compact value and SwiftUI popover; all six share one
lightweight sampler. The app also includes temperature history, a sensor browser,
overheat alerts, CSV logging, and small/medium Notification Center widgets. It has
no third-party runtime or package dependencies.

> **Status:** thermal sensors are working end-to-end on tested M-series Pro/Max
> hardware. The new system readers pass unit/build/runtime sampling on the development
> Mac; the final popover/widget visual matrix remains an explicit release gate.
> Other Mac models remain community-tested; see the support levels below.
> Reads sensors and local system counters only — it never controls fans, makes no
> network requests, and sends no data off-device. See [Privacy & Security](SECURITY.md).

---

## Features

- **Separate menu-bar modules** — Thermals, CPU, Memory, Network, Battery, and Disk,
  each with a native icon, compact live value, and its own SwiftUI popover.
- **Live temperatures** — CPU, GPU, and SoC, refreshed as often as every 2 seconds.
- **Fan RPM** — per-fan speed with a load bar (Left / Right on dual-fan Macs).
- **Power draw** — CPU and GPU watts, sampled from Apple's energy counters.
- **History graph** — rolling CPU/GPU temperature chart in the dropdown, plus a
  sparkline in the widget.
- **Sensor browser** — a de-duplicated "All sensors" list of readable HID
  temperature sensors (die zones, NAND, battery…).
- **Overheat alerts** — optional notification when CPU crosses a threshold you set.
- **CSV logging** — appends sampled readings to the existing compatibility path
  `~/Documents/MacVitals/macvitals-log.csv`;
  the bounded persistence worker coalesces to the newest sample if storage falls behind.
- **CPU** — total/user/system/idle usage, load averages, core counts, temperature,
  power, and a five-minute chart.
- **Memory** — used/available/total memory, pressure, wired/compressed/cache detail,
  and a five-minute chart.
- **Network** — local active-interface download/upload rates and session totals.
  MacVitals does not inspect packets, hosts, connections, public IP, Wi-Fi SSID, or MAC
  addresses, and it makes no network request.
- **Battery** — charge, power source, state, remaining-time estimate, Low Power Mode,
  and the public condition value when macOS provides one.
- **Disk** — used, available, and total capacity for the startup volume.
- **Menu-bar customization** — Thermals always shows CPU temperature; optional
  modules can be shown or hidden. New installs start with only the CPU module enabled,
  and Thermals always remains available as the settings item.
- **Adaptive polling** — 2 / 5 / 10 / 30 s, with an optional "slow down on battery."
- **Launch at login** and **°C / °F** toggles.
- **Notification Center widget** — small and medium sizes compactly include thermal
  and system metrics; the app requests a refresh at most once per minute, while
  macOS controls delivery.

---

## Supported Macs & macOS

| | Support | Notes |
|---|---|---|
| **Tested M-series Pro / Max Macs** | ✅ Verified | Temperatures, fans, and power have been exercised end-to-end on the development hardware. |
| **Other Apple Silicon Macs** | ⚠️ Expected | The common `tdie`/`tcal` and `Tp`/`Te`/`Tg`/`Ts` families are supported, but private sensor names vary. Please report model-specific results. |
| **Fanless Apple Silicon (MacBook Air)** | ✅ Temps & power | No fans exist, so the fan section is empty by design. |
| **Intel Macs** | ⚠️ Experimental | The project cross-compiles for x86_64 and handles classic `TC`/`TG` temperatures and fan encodings, but runtime behavior is not part of the release test matrix. CPU/GPU power is unavailable. |
| **Public system modules** | ✅ Development Mac / ⚠️ broader matrix pending | CPU, memory, network, and startup-disk metrics use local macOS APIs. Battery requires a Mac with an internal battery. |
| **macOS 14 (Sonoma) and later** | ✅ Build target | Minimum deployment target is macOS 14.0. Undocumented sensor APIs and names can shift between releases (see [Compatibility](docs/COMPATIBILITY.md)). |

Requires **Xcode 16+** to build.

---

## Build & run

1. Open `MacVitals.xcodeproj` in Xcode 16 on an Apple Silicon Mac.
2. Select each target → **Signing & Capabilities** → set your **Team**. The
   repository intentionally does not include the maintainer's Team ID. A Team and
   valid App Group are needed to exercise the widget/shared-container path.
3. If you're forking, replace the bundle ID `com.macvitals.app` and App Group
   `group.com.macvitals.shared` with your own (project build settings, both
   `.entitlements` files, and `SharedStore.appGroupID`).
4. Select the **MacVitals** scheme → **Run**. MacVitals appears as Thermals plus the CPU
   module by default; Memory, Network, Battery, and Disk can be enabled in the
   bottom **Menu bar modules** section.
5. Widget: run the app once, then **Notification Center → Edit Widgets → MacVitals**.

For a compile-only check without signing or App Group access:

```bash
xcodebuild -project MacVitals.xcodeproj -scheme MacVitals \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

For a downloadable, double-clickable build, see [Releasing](docs/RELEASE-CHECKLIST.md).

---

## How it works

MacVitals uses one shared polling loop. CPU, memory, and network statistics refresh at
the selected 2/5/10/30-second interval; battery is cached for 30 seconds and disk
capacity for 60 seconds.

| Data | API | Notes |
|---|---|---|
| **Temperatures** | `IOHIDEventSystemClient` (HID, usage page `0xFF00` / usage `0x0005`) **and** AppleSMC keys | HID exposes readable sensors (`PMU tdie*`, `NAND`, battery). SMC exposes per-core/cluster keys (`Tp*`/`Te*` CPU, `Tg*` GPU, `Ts*` SoC). CPU/GPU/SoC show the hottest matching sensor. |
| **Fan RPM** | AppleSMC user client — keys `FNum`, `F%dAc/Mn/Mx/Tg` | IOReport has no fan tachometer. Fans are SMC-only. |
| **CPU / GPU power** | IOReport, channel group `Energy Model` | Energy counters sampled via `IOReportCreateSamplesDelta`, scaled by unit and elapsed time. |
| **CPU usage / load** | Mach host statistics + `getloadavg` / `sysctl` | Local aggregate tick deltas, load averages, and core counts; no process inspection. |
| **Memory** | Mach VM statistics + `ProcessInfo` + dispatch memory pressure | Activity Monitor-style used/available accounting that excludes reclaimable file-backed and purgeable cache; sampling time and private Apple accounting can still cause small differences. |
| **Network** | `getifaddrs` + SystemConfiguration | Active interface name, aggregate byte counters, and rates only; no requests or traffic inspection. |
| **Battery** | IOKit power-source APIs + `ProcessInfo` | Public charge/state/time/condition and Low Power Mode values, cached for 30 seconds. |
| **Disk** | Foundation volume resource values | Startup-volume capacity, cached for 60 seconds; no SMART data or throughput monitoring. |

The **main app is intentionally not sandboxed** — inside the App Sandbox,
`IOServiceOpen("AppleSMC")` and HID enumeration are blocked. The **widget is
always sandboxed** (a WidgetKit rule), so it never touches hardware; it only
reads a snapshot the app writes into a shared **App Group** container.

Full architecture, per-chip behavior, and error handling: **[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)**.

## Testing

The `MacVitalsTests` target has 36 tests covering the sensor ABI/decoders, temperature
classification, system-metric delta math and bounds, menu presentation, history,
persisted-snapshot compatibility, and formatting.
Run it with:

```bash
xcodebuild -project MacVitals.xcodeproj -scheme MacVitals \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
```

The same tests plus a Release build run in GitHub Actions.

---

## Documentation

- **[Compatibility & error handling](docs/COMPATIBILITY.md)** — what works on which Mac, and how failures degrade.
- **[Support / troubleshooting](docs/SUPPORT.md)** — fixes for "no temps," "no fans," high temps, widget staleness, CSV, etc.
- **[Security & privacy](SECURITY.md)** — data handling, attack surface, how to report an issue.
- **[Release checklist](docs/RELEASE-CHECKLIST.md)** — everything needed before publishing.
- **[Review prompts](docs/REVIEW-PROMPTS.md)** — reusable prompts to audit security and functionality.
- **[Release audit ledger](docs/AUDIT-REPORT.md)** — findings, fixes, verification, and remaining manual gates.
- **[GitHub release handoff](docs/GITHUB-RELEASE.md)** — repository setup, push flow, and v1.0 release copy.

---

## Privacy

MacVitals makes **no network requests** and sends **no telemetry**. Its Network module
reads only the active interface name and aggregate local counters/rates; it does not
inspect traffic or discover public IP, SSID, MAC addresses, hosts, or connections.
Readings and timestamps stay on your Mac. It stores settings in standard app
preferences, snapshot/history files in its App Group container, and—only if
enabled—a CSV log in `~/Documents/MacVitals`. macOS manages notification permission and
login-item registration. See [SECURITY.md](SECURITY.md).

---

## Known limitations

- **Fan control is not supported** — read-only by design (writing SMC fan keys
  needs root and is out of scope).
- **High temperatures under sustained load can be normal.** macOS manages thermal
  pressure and throttling; use Activity Monitor and the power reading when
  investigating an unexpected value (see [Support](docs/SUPPORT.md)).
- **GPU temperature** may be blank on chips that expose only generic die zones
  with no GPU-specific sensor.
- **Undocumented APIs** (HID / SMC / IOReport) can change between macOS releases;
  their symbols are resolved defensively and classification is centralized in
  `SensorReader`, but each new macOS release still needs hardware testing.
- **Widget freshness** is roughly once per minute — WidgetKit budgets timeline
  reloads; the menu bar itself is always live.
- **No process or deep hardware inspection:** MacVitals does not show top processes,
  per-connection traffic, private battery/manufacturing data, serial numbers, GPU
  clocks, SMART status, or disk throughput.

---

## License

[MIT](LICENSE) © 2026 MacVitals contributors. Do whatever you like; keep the copyright notice; no warranty.

## Credits

Modeled on the classic Mac fan/temperature-monitor genre (Macs Fan Control, TG Pro,
`exelban/stats`). Built with Swift, SwiftUI, and WidgetKit.
