# Reusable Review Prompts

Copy-paste these into a fresh session that has access to the MacVitals project folder.
Each is self-contained.

---

## 1. Security / vulnerability audit

```
You are a macOS application security reviewer. Audit the MacVitals project (a menu-bar
thermals/system monitor with separate Thermals, CPU, Memory, Network, Battery, and
Disk items; unsandboxed Swift app + sandboxed WidgetKit extension sharing an App
Group). Read the actual source before concluding — don't assume.

Assess and report on:
1. Data exposure — what does it read, write, or transmit? Confirm the Network module
   only reads the local active-interface name and aggregate counters/rates, makes no
   request, and does not inspect packets, hosts, connections, public IP, SSID, or MAC
   addresses. Confirm there is no telemetry or personal-data logging. List every
   file/state write and why.
2. Attack surface — any open ports, servers, IPC, URL handlers, or external input?
   Any use of NSTask/shell, dynamic library loading, eval, or downloaded/executed
   code? Evaluate the fixed-path dlopen/dlsym private-symbol wrappers.
3. Privilege & sandboxing — the main app is unsandboxed by design. Explain the risk
   this creates and confirm the code does not abuse that access. Check entitlements
   in SupportingFiles/*.entitlements.
4. Malicious-use potential — could installing this app enable an attacker (as a
   vector, privilege escalation, persistence, data exfiltration)? Consider the
   Launch-at-login (SMAppService) and notification permissions.
5. Secrets & identity — scan for hardcoded secrets, tokens, API keys, personal
   names/emails, and the Apple DEVELOPMENT_TEAM ID.
6. Supply chain — confirm the app has no runtime/package dependencies, then separately
   inventory CI actions (including floating tags) and any remote URLs.
7. Input validation & crash safety — force-unwraps, unchecked buffers, struct-size
   assumptions in the SMC/IOKit code, counter wrap/reset, invalid deltas, byte-count
   overflow, and unavailable CPU/memory/network/battery/disk values.
8. Scope boundaries — confirm there are no top-process lists, per-connection data,
   private battery/manufacturing details, serials, GPU clocks, SMART data, or disk
   throughput, and that system metrics use public local APIs.

Output: a findings table (severity: Critical/High/Medium/Low/Info, location, fix),
then a short overall risk verdict, then concrete remediations ranked by priority.
Cite file paths and line numbers.
```

---

## 2. Functionality / correctness review

```
Review the MacVitals project for functional correctness and expected behavior. Read the
source, then verify each feature end-to-end and report what works, what's fragile,
and what's missing.

Check:
1. Sensor reading — HID temperatures, SMC fans, IOReport power. Are the three paths
   wired correctly? Is the SMCParamStruct exactly 80 bytes (SMCKeyData_t)? Does the
   CPU/GPU/SoC classification cover the sensor families a modern Apple Silicon chip
   exposes (tdie/tcal, Tp/Te/Tg/Ts/TC/TG/Tm)?
2. System reading — verify CPU tick deltas/load/core counts, VM memory accounting and
   pressure, active-interface counter/rate math, battery state/time/condition, and
   startup-volume capacity. Confirm CPU/memory/network use the selected app interval,
   battery is cached 30 s, disk 60 s, and all share one sampler.
3. UI — Thermals remains always enabled and is created first; all six retained
   `NSStatusItem`s have icons, compact values, SwiftUI popovers, accessibility
   labels and visibility toggles. Confirm Thermals always shows CPU temperature,
   CPU is the only fresh-install optional module, and Thermals provides settings.
4. Module popovers — verify CPU usage/load/cores/history, memory capacity/pressure/
   breakdown/history, network up/down/interface/session/history, battery charge/state/
   source/time/condition, and disk used/available/capacity. Missing data must degrade
   clearly instead of displaying a fabricated zero.
5. Settings persistence — UserDefaults.standard for app-local settings; the °C/°F
   value stamped into the snapshot for the sandboxed widget. Confirm nothing relies
   on an App-Group UserDefaults suite (which doesn't share reliably from an
   unsandboxed app).
6. Widget — reads the App Group snapshot; small/medium compact system metrics,
   refresh cadence, backward-compatible snapshots, and placeholder handling.
7. Opt-in features — overheat alerts (upward-crossing + cooldown), CSV logging to
   ~/Documents/MacVitals, launch at login, slow-on-battery polling.
8. Edge cases — fanless/no-battery Mac, chip with no GPU-specific sensor, first CPU/
   network sample, counter/interface reset, VPN, sleep/wake, unavailable volume data,
   sensor failure, unwritable CSV path, and first-run empty snapshot.
9. Lightweight behavior — prove one polling task, bounded histories, no new timer per
   status item, no network request or process enumeration, and no sustained resource
   regression. Compare with the recorded six-sample Release run at a 10-second
   interval (0.0% CPU except one 0.5% wake, ~19 MB private / ~77 MB RSS) without
   treating one machine as universal.

Output: a feature-by-feature status table (Works / Fragile / Broken / Missing) with
notes and file references, then a prioritized list of fixes and polish items.
```

---

## 3. "What do I need to do before publishing this?" (release readiness)

```
I want to publish the MacVitals macOS app. Act as a release engineer and walk me through
everything needed, tailored to whether I distribute (a) source-only on GitHub or
(b) a notarized downloadable build. Read docs/RELEASE-CHECKLIST.md and the project,
then:

1. Tell me exactly what's still incomplete for each path (app icon, version numbers,
   .gitignore, leftover debug files, DEVELOPMENT_TEAM, App Group registration,
   signing, notarization).
   Include the six-module visual matrix, clean Release build, 34-test result, hosted
   CI, locked/clean-Mac behavior, widget/App Group runtime, Intel and additional
   hardware coverage, and idle CPU/memory evidence.
2. Give me the precise commands to sign, notarize, staple, and package a DMG, and
   how to verify Gatekeeper acceptance on a clean Mac.
3. Draft the GitHub release: repo description, topics, README screenshots for the
   Thermals and five optional module items/popovers plus widget, and release notes
   for v1.0.
4. Confirm licensing (MIT) and privacy statements are present and accurate.
5. Flag any legal/expectation items (private-API caveat, "reads not controls fans,"
   warranty disclaimer).
6. Recommend the simplest path for reaching non-developer users, and whether I need
   a website or if the GitHub README suffices.

Give me a concrete, ordered TODO list I can execute, and note which steps require a
paid Apple Developer account.
```
