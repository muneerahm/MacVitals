# Security & Privacy

## Summary

MacVitals is a local, read-only sensor and system monitor. It makes **no outbound
network connections**, sends no telemetry, and executes no external or downloaded
code. Its Network module reads only local BSD interface counters. Operational
device data stays on your Mac.

## What it accesses

| Resource | Access | Why |
|---|---|---|
| IOKit sensors (HID, SMC, IOReport) | Read | Temperatures, fan RPM, power. |
| Public local system APIs (Mach, Dispatch, BSD `getifaddrs`, System Configuration, IOPowerSources, Foundation volume resources) | Read | Aggregate CPU use, memory and pressure, local interface byte counters, public battery state, and startup-disk capacity. |
| App Group container (`group.com.macvitals.shared`) | Read/write | `snapshot.json`, `history.json` shared with the widget. |
| Standard app preferences | Read/write | Display, polling, alert, and logging settings. |
| `~/Documents/MacVitals/macvitals-log.csv` | Write (opt-in) | CSV logging, only when you enable it. |
| Notifications | OS-managed state (opt-in) | Permission and overheat-alert delivery. |
| Login Items (`SMAppService`) | OS-managed state (opt-in) | Launch at login, only when enabled. |
| AppKit status items and popovers | Local UI | Show the optional CPU, memory, network, battery, and disk menu-bar modules. |

It does **not** transmit network traffic or inspect packets, connections, remote
hosts, process lists, IP or MAC addresses, Wi-Fi SSIDs/BSSIDs, the keychain,
contacts, calendars, camera/mic, browser data, or unrelated user documents. Its
only direct Documents-folder access is creating/appending its own opt-in CSV file.
It does not collect hardware serial numbers, private battery manufacturing data,
or other private battery fields.

## Data handling

- No telemetry, analytics, crash reporting, advertising, or "phone home."
- All readings stay on-device. `snapshot.json` contains the latest thermal readings
  plus aggregate CPU, memory, network, battery, and disk values used by the app and
  widget. The network value includes the selected interface's BSD name (for example,
  `en0`), current byte rates, and counters accumulated during the MacVitals session. It
  does not contain addresses, Wi-Fi names, packet contents, hosts, or connections.
- `history.json` contains the bounded thermal/fan history used for charts. The
  opt-in CSV contains timestamps, temperatures, power, fan RPM, and thermal state;
  it does not currently contain the new aggregate system metrics.
- Battery information is limited to public IOPowerSources values: percentage,
  charging/power state, time estimate, health text, and Low Power Mode state.
- Disk information is limited to aggregate startup-volume capacity and available
  space. MacVitals does not enumerate files or collect file names.
- Standard preferences store settings; macOS stores notification/login-item state.
- The CSV is a plain local file you control.
- No secrets, tokens, or credentials are stored or transmitted (there are none).

## Validation and sampling safeguards

- Shared reads open with `O_NOFOLLOW`, then validate and read the same file
  descriptor to avoid path-replacement races. They accept only regular files and are size-bounded (`snapshot.json` to
  1 MiB and `history.json` to 4 MiB). Decoded array/string sizes, date finiteness, sensor values,
  counters, rates, capacities, battery estimates, and the system-metric fields the
  widget consumes are validated before use.
- Memory page-to-byte multiplication uses overflow-reporting arithmetic. Snapshot
  validation first proves `availableBytes <= totalBytes`, then checks the coherent
  subtraction-based relationship `usedBytes == totalBytes - availableBytes`; the
  ordering makes the unsigned subtraction safe from underflow.
- CPU and network rates are derived from cumulative local counters. Counter resets,
  interface changes, invalid elapsed intervals, and non-finite values discard the
  rate sample instead of producing an unchecked result. Session-byte addition is
  saturating rather than wrapping.
- Battery and startup-disk values are cached and refreshed at slower 30-second and
  60-second intervals, respectively. This reduces system calls and avoids turning
  slowly changing data into unnecessary high-frequency work.

## Trust & sandboxing notes for reviewers

- **The main app is unsandboxed by necessity** — Apple's sandbox blocks the IOKit
  calls this kind of utility needs (`AppleSMC`, HID enumeration). An unsandboxed
  app *can* in principle touch the wider filesystem. MacVitals reads startup-volume
  capacity metadata but does not enumerate or read unrelated file contents, and its
  direct writes remain narrowly scoped — audit `SensorReader`, `SystemReader`,
  `SharedStore`, and `SensorViewModel` to confirm. The public system-statistics APIs
  require no helper or elevated privileges.
- **The widget is fully sandboxed** and never touches hardware — it only reads the
  bounded, validated snapshot and history files.
- **Undocumented APIs:** HID and IOReport symbols are resolved from fixed system
  library paths with `dlopen`/`dlsym`; AppleSMC uses IOKit. Missing symbols degrade
  to unavailable readings, but ABI or sensor-name changes still require testing.
  This is why the app is **not** Mac App Store eligible; Developer ID +
  notarization is the binary-distribution path.
- **Public system APIs:** CPU, memory, network counters, battery, and disk capacity
  use local public APIs. `getifaddrs` and System Configuration read interface state;
  they do not send traffic or enumerate connections. AppKit `NSStatusItem` and
  `NSPopover` objects are presentation-only and accept no remote input.
- **No dynamic code execution:** no helper process, `NSTask`/shell, plugin loading,
  eval, downloaded executable code, or remote content.
- Build artifacts and any temporary debug dumps are excluded from the repo via
  `.gitignore`; verify none ship in a release.
- The app has no third-party runtime or package dependencies. Hosted CI uses
  GitHub's `actions/checkout@v4`, which remains part of the CI supply chain.

## Could installing this enable malicious use?

The current code opens no listening ports, initiates no outbound connections, runs
no server or helper, downloads no content, and performs no privileged writes; it
cannot control fans. Its AppKit status items and popovers expose only fixed local UI
actions. The stored aggregate readings can reveal broad local activity patterns
(for example, CPU load or network volume), and a BSD interface name can identify a
local interface, but MacVitals neither associates those values with processes or remote
hosts nor transmits them.

The residual risk is that the main process is **unsandboxed** and can register
itself as a user-approved login item. A malicious or compromised build would
therefore have the current user's normal filesystem access even though the reviewed
code does not use that access broadly. Review source changes and install binaries
only from a trusted, preferably notarized release.

## Reporting a vulnerability

Once the GitHub repository is live, report suspected issues through its private
**Security → Advisories → New draft advisory** flow rather than a public issue,
and allow reasonable time to respond before disclosure.
