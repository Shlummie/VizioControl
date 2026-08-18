# VizioControl

VizioControl is a local-first controller for compatible Vizio SmartCast TVs. The repository contains the original Windows desktop client—with its optional in-memory viewport and bounded GPT-5.6 Luna navigation—and a separate native iPhone client for direct LAN control without a PC, cloud service, viewport, or AI runtime.

> VizioControl is an unofficial independent project. It is not affiliated with or endorsed by VIZIO.

## Highlights

- Discovers and pairs with compatible SmartCast TVs over the local network.
- Provides power, volume, mute, input, navigation, text-entry, and app-launch controls without requiring AI.
- Verifies Quick Start before network standby and fails closed when wakeability cannot be confirmed.
- Turns verified TV-setting requests into local macros that replay without a model or screenshots.
- Includes a native iPhone remote with PIN pairing, Keychain-protected credentials, full broadcast Wake-on-LAN, and a dedicated swipeable Macros tab with ordered actions, explicit waits, bounded definitions, current-step progress, and foreground cancellation.
- Streams compatible SmartCast Chromium surfaces to an optional in-memory viewport at up to 24 FPS.
- Runs optional visual navigation in a fresh, time-bounded Luna session with only host-validated `tv_*` tools.
- Requires confirmation for purchases, rentals, subscriptions, account changes, and destructive actions.

## Privacy and security boundaries

- Pairing tokens use Windows credential encryption in the desktop client and this iPhone's Keychain in the native client.
- The continuous viewport remains in memory on the PC and is not sent to OpenAI, logged, or saved.
- Separate observations are sent to OpenAI only during an explicitly active Luna request and are not persisted by the app.
- The renderer receives a narrow preload API; unrestricted Node, shell, filesystem, browser, MCP, plugin, connector, and Windows-control capabilities are not exposed to Luna.
- Real device names, LAN addresses, hardware identifiers, pairing material, account data, runtime captures, and machine-specific logs are excluded from this repository.

## Requirements

### Windows desktop

- Windows 10 x64 or later
- Node.js 22 or later
- A compatible Vizio SmartCast TV on the same local network
- For optional AI navigation: a ChatGPT account that exposes the exact configured Luna model with image input

### Native iPhone

- iOS 17 or later
- Xcode 26 or later for direct installation
- A compatible Vizio SmartCast TV on the same private LAN
- For full broadcast Wake-on-LAN, a paid Apple Developer Program team whose explicit App ID `com.shlummie.viziocontrol` has the approved Multicast Networking capability

## Develop the Windows client

```powershell
npm ci
npm test
npm run build
npm run dev
```

`npm run dev` starts Vite on loopback and launches the Electron shell. Manual controls remain usable when the optional AI runtime is unavailable.

## Build and install the native iPhone client

Open `ios/VizioControl.xcodeproj`, select the `VizioControl` target, choose the approved Apple development team under **Signing & Capabilities**, connect and unlock the iPhone, select it as the run destination, and press **Run**. Automatic signing must produce a device profile containing `com.apple.developer.networking.multicast`; do not treat an entitlement-free profile as a complete full-Wake build.

On first launch, keep the iPhone and TV on the same private LAN, tap **Find TVs**, allow Local Network access, select the verified TV, and enter the four-digit PIN shown on the TV. A manual private hostname/IP is only a rediscovery hint. Enter the TV's unicast MAC address when Bonjour does not provide one and broadcast wake is required.

The native client provides protected Standby/Wake, navigation, playback, input, volume/mute, ASCII TV text entry, built-in Hulu/YouTube/Netflix launchers, deterministic typed commands, and persistent saved-command editing. It intentionally does not include the Windows viewport, Luna, semantic content navigation, or AI-taught settings.

## Package for Windows

```powershell
npm run package
```

The package command creates installer and portable builds under `release/`. Builds are unsigned unless a code-signing certificate is supplied; verify generated hashes before distribution.

## Known limits

- SmartCast app surfaces must expose a compatible Chromium debugging target for visual navigation or viewport capture.
- Native TV menus, HDMI inputs, and DRM-protected video pixels may be unavailable to the viewport.
- Remote access, cloud sync, automatic updates, and multi-user support are outside version 1.0.0.
- The native iPhone client intentionally has no TV viewport or Luna/AI navigation; those remain Windows-only.
