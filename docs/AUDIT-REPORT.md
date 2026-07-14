# MacVitals release audit ledger

- Audit date: **2026-07-14**
- Reviewed path: **Path A — source-only GitHub release**
- Review branch: **`main`**
- Reviewed implementation: **sanitized MacVitals release tree**

This ledger records the repeated security, functionality, performance, and
release-readiness exercise after MacVitals’ system-module expansion. It does not claim
hardware or visual coverage beyond the evidence listed below.

## Outcome

No known Critical, High, or Medium severity source issue remains. MacVitals now exposes
separate Thermals, CPU, Memory, Network, Battery, and Disk menu-bar items while all
six views share one sampler. The reviewed source passes 34 unit tests, a clean
universal Release build, and Xcode static analysis.

Path A source verification is complete. Current screenshots, a locked/clean-Mac visual pass, signed App Group/widget verification, hosted CI, GitHub publication, and broader hardware runtime checks remain release or post-publication gates. Path B remains entirely gated on Developer ID
signing and notarization.

## Expansion findings and disposition

| Severity | Area | Finding | Disposition |
|---|---|---|---|
| High | Menu lifecycle | Six SwiftUI `MenuBarExtra` scenes caused an AttributeGraph/main-menu rebuild loop during the first integrated test, reaching about 4.9 GB before cancellation. | Resolved: all six modules use retained AppKit `NSStatusItem` + transient `NSPopover` controllers hosting SwiftUI views. Thermals is created first so it stays nearest the system status area. Tests launch normally. |
| Medium | Sampling architecture | A model or polling loop per menu item would multiply sensor work and persistence. | Avoided: one process-long `SensorViewModel` owns one `SensorReader` and one `SystemReader`; status items receive the merged snapshot. Battery and disk are cached for 30/60 seconds. |
| Medium | Persisted input | New aggregate values needed validation before the widget consumed a shared snapshot. | Resolved: CPU coherence/load bounds, memory arithmetic, network rate/name bounds, battery estimates, and disk capacity are validated. Legacy snapshots remain decodable. |
| Low | Numeric safety | Extreme finite battery time could trap a live `Double` → `Int` duration conversion. | Resolved: sampled time is capped at seven days and the formatter rejects values outside safe integer conversion. |
| Low | Widget resilience | Extremely distant but finite tampered history dates could trap the widget minute conversion. | Resolved: the displayed history span is checked for finiteness and clamped to the actual 30-minute history window before conversion. |
| Low | CPU topology | `activeProcessorCount` could temporarily be lower than the physical-core count and fail snapshot coherence. | Resolved: the module reports the stable logical `processorCount`. |
| Low | Network routing | IPv4-only primary-interface lookup degraded on IPv6-only routing. | Resolved: IPv4 remains primary with an IPv6 global-route fallback; interface changes rebuild the baseline. |
| Low | Polling preference | A same-user non-finite or extreme `UserDefaults` poll interval could reach duration conversion. | Resolved: intervals must be finite and within 1–3,600 seconds or fall back to five seconds. |
| Low | Shared-file race | Path metadata and the subsequent read were separate operations, allowing a same-user replacement race. | Resolved: shared files are opened once with `O_NOFOLLOW`, then type/size checked and read through that same descriptor. |
| Medium | Power availability | IOReport accumulated absent CPU/GPU channels from zero and could present an unavailable channel as `0 W`. | Resolved: channel presence is tracked independently; an absent or invalid CPU/GPU channel remains unavailable instead of becoming zero. |
| Medium | Network availability | With no primary route, the fallback could select an unrelated UP peer/AWDL-style interface. | Resolved: only the IPv4/IPv6 primary-route interface is accepted; otherwise Network reports unavailable. |
| Medium | Persistence backpressure | One chained task per poll could grow without bound if local storage stayed slower than sampling. | Resolved: one worker retains at most the newest pending snapshot and carries forward widget/CSV intent. Intermediate CSV samples may be coalesced under sustained storage delay and this is documented. |
| Info | Scope/privacy | Stats-like breadth can invite process, connection, identifier, and private-hardware collection. | Intentionally omitted: top processes, endpoints/connections, public IP, SSID/BSSID/MAC, serials, private battery/manufacturing fields, GPU clocks, SMART, and disk throughput. |
| Info | Disk privacy policy | Apple's disk-capacity APIs are listed in its required-reason API catalog. | Current release paths are source-only or direct Developer ID, not App Store. The value is displayed locally and never transmitted, matching Apple's display-disk-space reason. Re-check policy if an App Store path is ever reconsidered. |

Earlier thermal/SMC/storage hardening findings remain recorded in repository history
and continue to pass their regression tests.

## Feature review

| Feature | Result | Evidence / limitation |
|---|---|---|
| Thermals | Works | Existing temperatures, fans, power, history, sensors, settings, CSV, and alerts preserved; always visible for recovery. |
| CPU | Works in development environment | Aggregate total/user/system/idle, load, cores, thermal/power detail, compact value, and five-minute chart. First sample intentionally shows unavailable. |
| Memory | Works in development environment | Aggregate used/available/total, pressure, wired/compressed/cached-files detail, and chart. Reclaimable file-backed and purgeable pages are excluded from used memory to approximate Activity Monitor. |
| Network | Works in development environment | Local active-interface aggregate rates/session counters and chart. No request or packet/connection inspection. Baseline resets safely. |
| Battery | Hardware-dependent | Public percentage/state/source/time/condition/Low Power Mode only; desktop Macs degrade to no internal battery. |
| Disk | Works in development environment | Startup-volume used/available/total, refreshed at most once per minute. No SMART or I/O throughput. |
| Visibility | Works by code/test review | Thermals always shows CPU temperature; new installs enable only the optional CPU item. Optional-item visibility is in a fixed bottom Menu bar modules section, and Thermals cannot be removed. Final click-through visual matrix remains open because the Mac was locked. |
| Widget | Builds / signed runtime open | Small and medium layouts now include compact system metrics. Unsigned compile runs cannot verify App Group sharing; signed runtime and screenshots remain open. |

Accepted Low follow-ups: live-but-unhealthy sensor handles are only retried when the
backend becomes `nil`; the widget shows its timestamp but has no explicit stale badge;
and AppKit visibility/lifecycle plus 30/60-second cache behavior lack injected unit
tests. These are documented robustness/test-matrix gaps, not observed failures.

## Security review

- No outbound network connection, listener/server, packet capture, process
  enumeration, helper/subprocess/shell, downloaded code, telemetry, analytics,
  embedded credential, or app runtime/package dependency was found. GitHub CI uses
  the external `actions/checkout@v4` action and remains part of the CI supply chain.
- The Network module reads a selected BSD interface name and aggregate counters from
  local APIs. Latest values may be written to `snapshot.json`; they are never added
  to CSV or transmitted.
- Direct writes remain app preferences, App Group snapshot/history, and the opt-in
  `~/Documents/MacVitals/macvitals-log.csv`; macOS owns notification/login-item state.
- Shared reads are regular-file and size bounded. Counter resets, invalid elapsed
  intervals, overflow, corrupt capacity relationships, and implausible values fail
  closed to unavailable data.
- The widget is sandboxed. The main app remains deliberately unsandboxed because
  AppleSMC/HID sensor access is unavailable in App Sandbox. A compromised build
  therefore retains normal user access; source review and Developer ID notarization
  are the distribution mitigations.

## Verification record

Executed on arm64 macOS 26.5.1 with Xcode 26.6:

| Gate | Result |
|---|---|
| `MacVitalsTests` | Passed — **36/36** |
| Clean unsigned Release build | Passed — universal arm64 + x86_64 |
| Xcode Release static analysis | Passed |
| Debug app-host regression | Passed; prior six-scene launch loop eliminated |
| Release runtime samples | Six 5-second observations at a configured 10-second poll interval: 0.0% CPU except one 0.5% wake; 4–5 threads; about 19 MB private memory and roughly 77 MB RSS |
| Release bundle size | About 7.4 MiB; main universal executable about 3.09 MB (exact bytes vary between otherwise equivalent clean builds) |
| Entitlement source review | Main app: App Group only, unsandboxed; widget: App Sandbox + App Group; no network entitlements |
| Source privacy scan | Current files contain no former-brand, Team ID, personal path/name/email, credential, network connection/listener, process enumeration, helper/shell, or app dependency match; the documented BSD interface name remains local. Existing Git history still needs sanitizing before publication. |
| UI automation | Blocked: the Mac remained locked, so status-item clicking, VoiceOver, popover sizing, crowding, and widget screenshots are not marked complete |

## Remaining manual/external gates

1. Review and commit the renamed tree, then publish from sanitized/squashed history
   so old commit authors and messages are not exposed.
2. Unlock and run the visual matrix: six compact status items, all popovers and
   disclosures, hide/restore, menu-bar crowding/notch behavior, VoiceOver labels,
   and both widget sizes.
3. Run a signed build with final Team, bundle IDs, and registered App Group; verify
   current thermal/system data reaches the widget.
4. Exercise a clean Mac plus fanless, desktop/no-battery, additional battery, and
   Intel hardware before broadening claims.
5. Add current screenshots to the README, publish the GitHub repository/branch,
   require hosted CI, review the final diff, merge, and only then tag `v1.0`.
6. For Path B, complete every Developer ID sign/notarize/staple/Gatekeeper step in
   `RELEASE-CHECKLIST.md`; none is inferred from an unsigned build.

## Defaults and alternatives

- **Chosen:** fixed CPU temperature plus the optional CPU item on first launch, with
  Memory, Network, Battery, and Disk opt-in. **Alternative:** enable CPU, Memory, and Network by default for
  more Stats-like at-a-glance coverage at the cost of menu-bar space.
- **Chosen:** concise totals in the menu bar and progressive disclosure in popovers.
  **Alternative:** icon-only items reduce crowding but make at-a-glance comparison
  weaker.
- **Chosen omissions:** no top-process, connection, identity, private battery, GPU
  clock, SMART, or disk-throughput collection. **Alternative:** add narrowly scoped,
  opt-in advanced views later, each with a separate privacy/performance review.
- **Chosen disk metric:** capacity only, refreshed once per minute. **Alternative:**
  opt-in disk throughput would need a new reader, chart, energy test, and clearer
  distinction from SMART/health data.
- **Distribution:** source-only Path A is the reasonable current release. Path B is
  a better non-developer experience after paid signing, notarization, stapling, and
  clean-Mac Gatekeeper verification.
