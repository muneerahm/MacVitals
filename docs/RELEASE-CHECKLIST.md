# Release Checklist — publishing MacVitals

Two paths. Do **Path A** for a free, source-only GitHub release. Add **Path B** when
you want a download non-developers can double-click.

---

## 0. Pre-flight (both paths)

- [x] Remove debug/triage files: `macvitals-sensor-dump.txt`, `macvitals-smc-probe.txt`.
- [x] Add a `.gitignore` (see template below) so `build/`, `*.xcuserstate`, and
      logs never get committed.
- [x] Confirm no personal data in the current working files. `DEVELOPMENT_TEAM` is
      blank, Xcode user state is ignored, and the source/docs contain no personal
      paths, names, emails, credentials, or former-brand identifiers.
- [x] Publish `main` from a fresh root commit containing only the reviewed MacVitals tree; no earlier local author metadata or legacy messages are part of public history.
- [x] Set version/build to **1.0 / 1**. The UI reads the bundle version; bump both
      values per release.
- [x] Add an **app icon** (`MacVitals/Assets.xcassets/AppIcon.appiconset`).
- [ ] Do a clean build on a separate Mac that has never run it, to catch missing files or
      App Group registration issues.
- [x] Re-review `SECURITY.md` after the system-module expansion. It distinguishes
      reading local interface counters from making network requests and inventory
      CPU, memory, network, battery, and disk values without overstating collection.

### System-module expansion verification

- [x] Thermals remains always enabled as the recovery/settings item; all six items
      use retained `NSStatusItem`s with stable autosave identities. Thermals is created
      first so optional CPU, Memory, Network, Battery, and Disk items yield space first.
- [x] Thermals always shows CPU temperature. New installs enable only the CPU module; the other four optional
      modules remain available in the bottom Menu bar modules section. All modules share the existing sampler. CPU,
      memory, and network use the selected app interval; battery is cached 30 seconds
      and disk 60 seconds.
- [x] Scope review: public local APIs only for the new modules; no network requests,
      top-process or connection inspection, public IP/SSID/MAC/serial collection,
      private battery data, GPU clocks, SMART data, or disk throughput.
- [x] Run `MacVitalsTests`: **37/37 passed** on arm64 macOS 26.5.1.
- [x] Run an arm64 **Debug** build after the expansion.
- [x] Run a clean unsigned universal **Release** build (arm64 + x86_64) for the
      reviewed implementation.
- [x] Record six Release runtime samples at a 10-second interval: **0.0% CPU**
      except one **0.5%** polling wake, about **19 MB private memory**, and roughly
      **77 MB RSS**. Treat this as one-machine evidence, not a universal guarantee.
- [x] Render and review the Thermals and five system popovers from the real SwiftUI
      views with privacy-safe sample data. The fresh-install render shows the intended
      minimal default: fixed Thermals plus CPU only.
- [x] Complete the code-level accessibility pass: dynamic status-item labels,
      descriptive unavailable states, labeled charts/timestamps/alert threshold,
      combined metric rows, and named or hidden progress indicators.
- [ ] Complete the interactive VoiceOver and clean-Mac behavior matrix: spoken
      navigation/announcements, compact-value updates, every live popover,
      hide/restore behavior, menu-bar crowding/notch behavior, and small/medium widgets.
- [ ] Complete runtime coverage on Intel and additional hardware: fanless Macs,
      desktops/no-battery Macs, and additional battery models.
- [ ] Run the final signed app with registered App Group and verify shared thermal +
      system metrics in both widget sizes.

## 1. `.gitignore` template

```
build/
DerivedData/
*.xcuserstate
*.profraw
xcuserdata/
.DS_Store
macvitals-*.txt
```

---

## Path A — GitHub source release (no paid developer membership required)

- [x] Ensure `README.md`, `LICENSE`, `SECURITY.md`, and `docs/` are present and current.
- [x] Add privacy-safe README screenshots showing Thermals and the five optional
      popovers with representative sample data.
- [ ] Add both compact widget sizes after signed App Group runtime verification.
- [x] Review the renamed working tree and prepare sanitized `main` from a fresh root commit for the public repository.
- [x] Set the repo's **About**, topics (`macos`, `apple-silicon`, `menubar`,
      `swiftui`, `temperature`, `fan`, `cpu-monitor`, `memory-monitor`,
      `network-monitor`, `battery`, `disk-space`), and license (GitHub auto-detects
      `LICENSE`).
- [x] Cut a release: tag `v1.0`, write release notes.
- [x] In the README build steps, tell users to set their own Team + bundle ID.

Publishing source needs no paid membership, signing, or notarization. A contributor
who wants to run the signed widget/App Group path must select an Apple Team and use
an App Group available to that Team; the unsigned compile check remains available.

---

## Path B — Notarized download (needs Apple Developer Program, ~$99/yr)

Prerequisites: enrolled Apple Developer account, a **Developer ID Application**
certificate, and your **App Group** ID registered to your Team.

- [ ] In Xcode, set the **Team** on both targets; keep **Hardened Runtime ON**
      (required for notarization — it does not block the private APIs used here).
- [ ] Replace the source placeholder `group.com.macvitals.shared` with a unique App
      Group you control, register it in your developer account, and update both
      entitlements plus `SharedStore.appGroupID` consistently.
- [ ] Archive:
      ```bash
      xcodebuild -project MacVitals.xcodeproj -scheme MacVitals -configuration Release \
        archive -archivePath build/MacVitals.xcarchive
      ```
- [ ] Export with Developer ID:
      ```bash
      cat > build/ExportOptions.plist <<'EOF'
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
        <key>method</key><string>developer-id</string>
      </dict></plist>
      EOF
      xcodebuild -exportArchive -archivePath build/MacVitals.xcarchive \
        -exportOptionsPlist build/ExportOptions.plist -exportPath build/export
      ```
- [ ] Verify the exported Developer ID signature and entitlements:
      ```bash
      codesign --verify --deep --strict --verbose=2 build/export/MacVitals.app
      codesign -d --entitlements :- build/export/MacVitals.app
      spctl -a -vvv -t exec build/export/MacVitals.app
      ```
- [ ] Package, notarize, and staple the **final artifact**. For a DMG:
      ```bash
      mkdir -p build/dmg-root
      ditto build/export/MacVitals.app build/dmg-root/MacVitals.app
      hdiutil create -volname MacVitals -srcfolder build/dmg-root \
        -ov -format UDZO build/MacVitals.dmg
      xcrun notarytool submit build/MacVitals.dmg \
        --keychain-profile "AC_PROFILE" --wait
      xcrun stapler staple build/MacVitals.dmg
      xcrun stapler validate build/MacVitals.dmg
      ```
      (Create `AC_PROFILE` once with `xcrun notarytool store-credentials`.)
- [ ] Attach the stapled DMG to the GitHub release. If distributing ZIP instead,
      notarize the ZIP, staple the contained app, then recreate the final ZIP.
- [ ] Verify on a clean Mac: download → double-click → it opens **without** a
      Gatekeeper warning. Verify the DMG and installed app:
      ```bash
      spctl -a -vvv -t open --context context:primary-signature build/MacVitals.dmg
      spctl -a -vvv -t exec /Applications/MacVitals.app
      ```

> **Mac App Store is not an option** — the app uses private sensor APIs and can't be
> sandboxed. Developer ID + notarization is the correct and accepted route.

---

## 3. Optional extras

- [ ] **Auto-updates (Sparkle):** add the `sparkle-project/Sparkle` package,
      generate EdDSA keys, host an appcast, set `SUFeedURL` / `SUPublicEDKey`, and
      sign each update. Only worth it if you're shipping regular builds to others.
- [ ] **Landing page:** a simple GitHub Pages site (or the repo README) with
      screenshots, supported-Mac table, and a download button is plenty — no separate
      website needed to start.
- [x] **CI workflow:** `.github/workflows/ci.yml` is configured to run unit tests and
      a Release build on push/PR.
- [x] **Hosted CI result:** require a passing run for the exact release commit.

---

## 4. Legal / expectation setting

- [x] The MIT `LICENSE` disclaims warranty — keep it.
- [x] State clearly in the README that MacVitals **reads** sensors and does **not**
      control fans, and that temperatures under load are normal (reduces "is my Mac
      broken?" issues).
- [x] Note the undocumented-API caveat so users understand a macOS update could
      temporarily change sensor readings until you patch.
