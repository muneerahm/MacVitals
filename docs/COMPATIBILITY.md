# Compatibility, Error Handling & Functional Review

This document covers how MacVitals behaves across different Macs and macOS versions,
how it handles failure, and a review of whether each feature works as intended.

---

## 1. Cross-Mac compatibility

MacVitals reads thermal sensors and public local system statistics independently, so
support degrades feature by feature rather than all-or-nothing. Thermals is always
visible; CPU, Memory, Network, Battery, and Disk are separate optional status items,
with CPU visible by default and the others restorable from Thermals › Settings.

### Apple Silicon — primary target

| Feature | Works? | Detail |
|---|---|---|
| CPU / GPU / SoC temps | ✅ Tested hardware / ⚠️ other models | From HID (`PMU tdie*`/`tcal`) and SMC (`Tp/Te/Tg/Ts/Tm`). The app shows the hottest matching sensor. Names vary by model. |
| Fan RPM | ✅ Tested hardware / ⚠️ other models | SMC `FNum` + `F%dAc`. Dual-fan Macs → "Left/Right"; single-fan → "Fan"; fanless Macs report no fans. |
| CPU / GPU power | ✅ Tested hardware / ⚠️ other models | IOReport `Energy Model`; unknown units and implausible samples are rejected. |
| CPU usage / load | ✅ Development Mac | Public Mach tick deltas, load averages, and core counts. First sample is intentionally unavailable. |
| Memory | ✅ Development Mac | Public VM statistics, physical memory, and dispatch memory pressure. Used memory excludes reclaimable file-backed and purgeable cache to approximate Activity Monitor; small timing/private-accounting differences remain possible. |
| Network | ✅ Development Mac | Active-interface aggregate counters/rates from local APIs. Interface changes reset the rate baseline instead of producing a spike. |
| Battery | ⚠️ Hardware-dependent | Public IOKit power-source data, cached for 30 seconds. Desktop Macs correctly show no internal battery. Additional battery hardware remains unverified. |
| Startup disk | ✅ Development Mac | Public volume capacity values, cached for 60 seconds. No disk throughput or SMART monitoring. |

Sensor **names differ per chip**. Classification is centralized in
`SensorReader.isCPUSensor / isGPUSensor / isSoCSensor` and the SMC family filter in
`readSMCTemperatures()`. If a future chip uses new names, patch those two places.

### Fanless Apple Silicon (MacBook Air)

Temperatures and power are expected to work. When `FNum` returns 0, the UI says
"No fans reported (fanless Mac)"; an unreadable SMC gets a separate unavailable
message. Runtime validation on a fanless model is still requested.

### Intel Macs — not an official target

| Feature | Works? | Detail |
|---|---|---|
| Temps | ⚠️ Experimental | Intel `TC`/`TG` families are classified and decoder tests pass, but no Intel runtime test is recorded. |
| Fan RPM | ⚠️ Experimental | SMC fan keys and `fpe2`/`sp78` decoders are included; x86_64 cross-build and decoder tests pass, not hardware validation. |
| CPU / GPU power | ❌ | The `Energy Model` IOReport group is Apple-Silicon-only; watts will be blank. |

The deployment target (macOS 14) already excludes most Intel-era Macs. Treat Intel
as "may partially work," not supported.

### macOS versions

- **Minimum:** macOS 14.0 (Sonoma). Uses AppKit status items, Swift Charts,
  `SMAppService`, WidgetKit, UserNotifications — all 13+/14+ APIs.
- **Build verification:** Debug/Release builds, static analysis, unit tests, and an
  x86_64 cross-build pass in the current development environment. GitHub Actions
  repeats unit tests and a Release build on `macos-15`.
- **Runtime verification:** tested development hardware only. Undocumented API
  symbols, signatures, sensor names, and availability can change between macOS
  releases. Re-test every claimed hardware/OS combination before broadening support.

### System-module scope

- CPU, memory, and network sample in the one existing app loop at the selected
  2/5/10/30-second interval. Battery and disk do not add timers; they use 30- and
  60-second caches respectively.
- All six modules use independent `NSStatusItem`s with compact values and SwiftUI
  popovers. Thermals is created first, nearest the system status area, so optional
  modules yield first when menu-bar space is constrained. Optional-item visibility
  is controlled centrally in Thermals › Settings. Thermals cannot be hidden.
- Network observes only the active interface name and aggregate byte counters/rates.
  It makes no request and does not inspect packets, endpoints, connections, public
  IP, SSID, or MAC addresses.
- Battery avoids serial numbers and private manufacturing data. Disk avoids SMART
  data and throughput. CPU does not enumerate top processes, and no GPU clocks are read.

---

## 2. Error handling review

MacVitals is defensive: nearly every hardware call returns an optional or an empty
collection on failure, so missing data shows as "—" rather than crashing.

**Handled gracefully:**

- HID client creation and service enumeration — guarded; empty list → no temps,
  no crash.
- SMC connection — failable initializer; `IOServiceOpen` failure → `nil` → fans and
  SMC temps simply absent.
- SMC struct size — fixed at the kernel-required 80 bytes (`SMCKeyData_t`); a
  mismatch previously caused `kIOReturnBadArgument`; a unit test locks size, stride,
  and alignment.
- HID/IOReport availability — private symbols are dynamically resolved from fixed
  system paths. Missing symbols or channels yield unavailable data rather than a
  launch-time linker failure.
- Backend recovery — missing HID, SMC, and IOReport backends retry every 30 seconds.
- SMC boundary validation — key/fan counts and numeric values are bounded before
  allocation or integer conversion.
- Reading bogus values — temperatures outside `0 < t < 150 °C` are filtered.
- File reads/writes — JSON is size/range validated; CSV uses a no-follow regular-file
  append. Writes run off the main actor and failures produce an in-app warning.
- Widget — missing snapshot → placeholder view.
- System readers — unavailable or invalid module data is isolated to that module;
  first-sample CPU/network deltas and interface changes show unavailable/zero-rate
  states rather than fabricated activity.

**Remaining hardening opportunity:** polling continues at the selected cadence when
sensor reads repeatedly fail. The backend retry is bounded, but a broader failure
backoff could further reduce work on unsupported Macs.

---

## 3. Functional review — does everything work as expected?

| Feature | Status | Notes |
|---|---|---|
| Thermals status item | ✅ | Always enabled, always shows CPU temperature, and contains module visibility controls. |
| CPU status item + popover | ✅ code/test + rendered-view verified; live matrix pending | Compact usage; total/user/system/idle, load, cores, temperature/power, five-minute chart. |
| Memory status item + popover | ✅ code/test + rendered-view verified; live matrix pending | Compact used percentage; aggregate capacity, pressure, breakdown, five-minute chart. |
| Network status item + popover | ✅ code/test + rendered-view verified; live matrix pending | Compact up/down rate; local interface and session totals, five-minute chart. |
| Battery status item + popover | ✅ rendered-view verified / ⚠️ hardware matrix pending | Charge/state/source/time/condition; no-battery state is implemented. Refreshed at most every 30 seconds. |
| Disk status item + popover | ✅ code/test + rendered-view verified; live matrix pending | Startup-volume used/available/capacity. Refreshed at most every 60 seconds. |
| CPU / GPU / SoC temps | ✅ tested model / ⚠️ others | Fed by HID + SMC; shows hottest per category. GPU blank on chips with no GPU-specific sensor. |
| Fan RPM + load bars | ✅ tested model / ⚠️ others | 80-byte ABI is unit-tested. Labels are positional (Left/Right). |
| CPU / GPU power | ✅ tested model / ⚠️ others | Apple Silicon only; unit and range validated. |
| History graph | ✅ | Time-based 30-minute window; auto-scaling can look dramatic at idle. |
| Sensor browser | ✅ | Shows readable HID sensors, de-duplicated and averaged. SMC per-core keys are excluded from the list but still drive the headline temps. |
| Overheat alert | ✅ | Fires once on upward crossing with a 10-minute cooldown; rejected permission disables the toggle and delivery errors are shown. |
| CSV logging | ✅ | Writes to `~/Documents/MacVitals/macvitals-log.csv`; failures are shown and symlink appends are rejected. |
| °C / °F, launch at login, slow-on-battery | ✅ | Settings persist in `UserDefaults.standard`; the °C/°F choice is also stamped into the snapshot so the sandboxed widget honors it. |
| Widget (small / medium) | ⚠️ Runtime-dependent | Compactly includes thermal and system metrics. The app requests reloads no more than once per minute after saving; WidgetKit controls actual delivery. |
| Thermal pressure badge | ✅ | From public `ProcessInfo.thermalState`. |

**Open items / future polish**

1. Capture both widget sizes after signed App Group testing; current app-popover
   screenshots are now in the README.
2. Optional fixed history-graph range.
3. GPU temperature is hardware-dependent; consider labeling the CPU row "Die
   (hottest)" on chips that only expose generic die zones, to avoid implying a
   dedicated CPU-core reading.
4. Complete the visual matrix on a locked/clean Mac and runtime coverage on Intel,
   fanless, desktop/no-battery, and additional battery hardware.
