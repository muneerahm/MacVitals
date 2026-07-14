# MacVitals — Support & Troubleshooting

Common questions and fixes. If none of these help, open a GitHub issue with your
**Mac model**, **macOS version**, and a screenshot of the relevant MacVitals popover.

---

## Temperatures show "—" or "No temperature sensors matched"

- **Make sure you're running the app, not just the widget.** The widget can't read
  hardware; it only mirrors what the app reads.
- **The app must not be sandboxed.** If you enabled the App Sandbox, HID sensor
  enumeration returns nothing. Remove `com.apple.security.app-sandbox` from
  `MacVitals.entitlements` (the widget stays sandboxed — that's required).
- **Unusual chip / new macOS:** your Mac may name its sensors differently. Open
  "All sensors" — if you see readable entries there but the top rows are blank, the
  name classifier needs those names added (`SensorReader.isCPUSensor` etc.).

## GPU temperature is blank but CPU/SoC work

Expected on some chips: Apple exposes generic numbered die zones with no
GPU-specific sensor. GPU **power** still works. Nothing is broken.

## Fans show "unavailable" but my Mac has fans

- Rebuild with the latest code — an SMC struct-size bug (`kIOReturnBadArgument`)
  blocked all fan reads until the `SMCParamStruct` was corrected to 80 bytes.
- If it persists, your SMC may be restricted; confirm the app is unsandboxed.
- On a **MacBook Air (fanless)**, the app should say "No fans reported
  (fanless Mac)." If it says SMC is inaccessible instead, include diagnostics in
  your bug report.

## Temperatures look very high (85–100 °C)

Usually **not a bug and not dangerous.** Check **CPU Power** in the dropdown:

- **High watts (20 W+):** something is loading the CPU — often a background process
  (a stuck helper, indexing, a browser tab). Open **Activity Monitor → CPU**, sort
  by **% CPU**, and quit the offender. Brief high temperatures and fans spinning up
  can be normal under sustained load; macOS manages thermal pressure and throttling.
- **Low watts (2–5 W) but still hot:** that's worth investigating — check Activity
  Monitor, and make sure vents aren't blocked (soft surfaces like a bed or blanket
  reduce airflow and raise temps several degrees). Use a hard, flat surface.

## A CPU, Memory, Network, Battery, or Disk item disappeared

Open the always-visible **Thermals** item, expand **Settings**, and control optional
items under **Menu bar modules**.
CPU is visible by default on a fresh preferences domain. Memory, Network, Battery,
and Disk are opt-in.

## CPU says it is waiting for a second sample

CPU percentage is calculated from the difference between two host tick samples.
After launch, wait one selected polling interval. The baseline is also rebuilt after
a counter reset rather than showing a false spike.

## Memory differs from Activity Monitor

MacVitals derives an aggregate used-memory value from public VM page statistics. Activity
Monitor applies its own presentation and accounting rules, so the numbers may not
match exactly. The pressure badge is usually the better signal of memory stress.

## Network shows no interface, zero, or an unexpected interface name

- MacVitals follows macOS's active IPv4 route, with IPv6 as a fallback, and reads
  aggregate local byte counters. It does not make a test request or inspect traffic.
- The first sample has no rate baseline. Switching Wi-Fi/Ethernet, enabling a VPN,
  or waking from sleep resets the baseline to prevent a false throughput spike.
- VPNs and unusual routing can cause the displayed interface to differ from the
  physical Wi-Fi/Ethernet device. Loopback is not selected as the primary interface.

MacVitals does not show hosts, connections, public IP, SSID, or MAC addresses.

## Battery says "No internal battery reported"

That is expected on desktop Macs. On a laptop, wait up to 30 seconds, verify macOS
itself shows the battery, and relaunch MacVitals. Remaining-time and condition values may
show as unavailable when macOS does not publish them. MacVitals does not collect serial
numbers or private battery/manufacturing details.

## Disk capacity looks stale or differs from Finder

Startup-disk capacity is cached for up to 60 seconds. The available value includes
space macOS reports as available for important usage, including reclaimable capacity,
so it can differ from another utility. MacVitals does not read SMART status, disk health,
or disk throughput.

## The widget doesn't update / looks stale

WidgetKit limits how often widgets refresh. MacVitals requests a reload at most once a
minute after successfully saving a snapshot, but macOS decides when the widget is
actually refreshed. The menu-bar readout is live at the selected polling interval.
If the widget is blank, run the signed app once and check for an App Group warning.
Small and medium widgets now compactly include system metrics as well as thermal data;
missing individual metrics should degrade to `—` rather than blanking the widget.

## MacVitals seems to use too many resources

All modules share one sampler. CPU, memory, and network use the selected app interval;
battery and disk are cached for 30 and 60 seconds. In the recorded development run
at a 10-second interval, six Release-build samples showed 0.0% CPU except for one
0.5% polling wake, about 19 MB private memory in `top`, and roughly 77 MB RSS in
`ps`. Compare on the same interval and include an Activity Monitor sample plus your
Mac/macOS details when reporting a regression.

## CSV logging — "sandbox extension" error, or I can't find the file

The log is written to **`~/Documents/MacVitals/macvitals-log.csv`** and "Show log file"
reveals it in Finder. (It used to live in the App Group container, which triggered a
`public.file-url … failed to obtain` error when Finder tried to open it — that's
fixed.) Columns: `timestamp, cpu_c, gpu_c, soc_c, cpu_w, gpu_w, fan_rpms,
thermal_pressure`.

If the directory is unwritable, the path is a symbolic link, or the file is not a
regular file, MacVitals rejects the append and shows a warning in the dropdown.

## "Launch at login" doesn't stick

It's registered via `SMAppService`; confirm it in **System Settings → General →
Login Items**. If macOS shows it as "not verified," sign the app with your Developer
ID (see the release checklist).

## App won't open: "unidentified developer" / "damaged"

For **"unidentified developer"**, use a notarized release or build the source in
Xcode. For a trusted local unsigned build, right-click the app → **Open** → **Open**.

**"The app is damaged" is different:** re-download/rebuild it and verify its code
signature. Do not work around that message by stripping quarantine attributes; it
can indicate an incomplete archive or invalid signature.

## Overheat alerts never fire

- Enable them in Settings and grant the notification permission on first enable.
- If permission is denied, MacVitals turns the toggle back off and points you to System
  Settings → Notifications.
- They fire only on the **upward** crossing of your threshold, at most once per
  ~10 minutes, to avoid spam.

---

### Reporting a bug

Include: Mac model + chip, macOS version, whether you built it yourself or used a
release, what you expected vs. saw, and the relevant module-popover screenshot
(expand "All sensors" if it's a temperature issue). For performance issues, include
the selected polling interval and an Activity Monitor sample.
