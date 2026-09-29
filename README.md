# Deck — native iOS agentic AI cyberdeck

One app on the iPhone. Uncensored local brain (Dolphin 8B via llama.cpp + Metal),
a real agent loop, and hands (files, memory, tasks, web, notifications) — no
relay, no bridge, no second app, no computer at runtime.

## What it is

- **Brain:** Dolphin 2.9 Llama 3 8B (uncensored), Q4_K_M GGUF, downloaded once on
  first launch (~5 GB, Wi-Fi), then fully offline. Runs in-process via
  [llama.swift](https://github.com/mattt/llama.swift) (llama.cpp XCFramework)
  with full Metal GPU offload.
- **Loop:** ReAct-style agent loop in Swift — THOUGHT → ACTION/ARGS → tool →
  OBSERVATION, up to 8 steps per turn, streaming to the chat UI.
- **Hands:** sandboxed file tools (`Documents/deck/`), SQLite memory with FTS
  search, task list, web fetch, local notifications, open URLs in other apps.
- **Summon:** App Intents — “Hey Siri, ask Deck …” / “Hey Siri, tell Deck to …”
  from any app, via the `deck://` URL scheme.
- **Eyes:** camera + photo-library descriptions are in Info.plist; the model
  side of vision (llava via llama.cpp multimodal) is a planned v1.1 addition.

## Project layout

```
Deck.xcodeproj/          hand-written, validated (38/38 refs consistent)
Deck/
  DeckApp.swift          app entry, deck:// URL handling
  ContentView.swift      chat UI + first-launch model downloader
  Info.plist             URL scheme, camera/photo usage strings
  Engine/
    LlamaEngine.swift    llama.cpp C API wrapper (actor, streaming, sampler)
    AgentLoop.swift      ReAct loop, action parsing, deep-link entry
    DeckTools.swift      14 tools: files, memory, tasks, web, notify, open_url
    MemoryStore.swift    SQLite memory (FTS5) + tasks
    ModelDownloader.swift resumable multi-GB download with progress
  Intents/
    DeckIntents.swift    AskDeckIntent, DoDeckIntent, AppShortcutsProvider
scripts/
  mac-setup.sh           Xcode check + SPM resolution
  build-ipa.sh           archive → dev-signed .ipa → itms-services manifest
```

## Build & sideload (Mac session)

1. Rent a cloud Mac (Macly ~$14.99/day, or Scaleway ~€0.22/hr). Xcode 16+ required
   (Swift 6).
2. Copy this folder to the Mac. Run `./scripts/mac-setup.sh`.
3. **Signing (needs the phone owner's Apple ID — free account is fine):**
   - On the Mac, open Xcode → Settings → Accounts → add the Apple ID.
   - Free accounts sideload to the owner's own devices; no $99 needed, no App Store.
   - Free provisioning profiles expire every **7 days** — re-run the build weekly
     (2 minutes), or enroll in the paid program ($99/yr) for year-long certs.
4. Get the iPhone's UDID (get.udid.io on the phone, 30 seconds) and register it
   in Xcode (Window → Devices and Simulators) or let Xcode register it at install.
5. `./scripts/build-ipa.sh <TEAM_ID> [BUNDLE_ID]`
   - TEAM_ID: Xcode → Settings → Accounts → select team (free accounts have one).
   - BUNDLE_ID must be unique to the signer, e.g. `com.yourname.Deck`.
6. Host `build/ipa/Deck.ipa` + `build/manifest.plist` over HTTPS, replace
   `__IPA_URL__` in the manifest, and open on the iPhone:
   `itms-services://?action=download-manifest&url=<manifest-url>`
7. On the iPhone: Settings → General → VPN & Device Management → trust the
   developer certificate. Launch Deck, download the brain, done.

## Verification checklist (on the Mac)

- [ ] `xcodebuild -list` parses the project (script does this).
- [ ] llama.swift resolves; llama.cpp XCFramework downloads.
- [ ] Confirm the default model URL in `ModelDownloader.swift` still resolves
      (bartowski GGUF filenames change; the URL is editable in-app).
- [ ] Archive succeeds for `generic/platform=iOS`.
- [ ] Install on the real iPhone; first launch downloads the model; chat +
      a tool loop (e.g. “write a file then read it back”) works end to end.

## Honest limits (not re-litigated)

- No third-party app can draw a floating window over other apps or silently
  watch the screen on stock iOS — sideloaded or not. Anywhere-access is via
  Siri (“Hey Siri, ask Deck …”); eyes are camera + screenshots the user shares.
- iOS kills background work aggressively; long agent runs should happen
  with the app in the foreground.
