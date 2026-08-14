# VizioControl

VizioControl is a local-first Windows desktop controller for compatible Vizio SmartCast TVs. It combines immediate manual controls, device discovery and pairing, protected standby and wake behavior, reusable local commands, an in-memory TV viewport, and optional bounded GPT-5.6 Luna navigation.

> VizioControl is an unofficial independent project. It is not affiliated with or endorsed by VIZIO.

## Highlights

- Discovers and pairs with compatible SmartCast TVs over the local network.
- Provides power, volume, mute, input, navigation, text-entry, and app-launch controls without requiring AI.
- Verifies Quick Start before network standby and fails closed when wakeability cannot be confirmed.
- Turns verified TV-setting requests into local macros that replay without a model or screenshots.
- Streams compatible SmartCast Chromium surfaces to an optional in-memory viewport at up to 24 FPS.
- Runs optional visual navigation in a fresh, time-bounded Luna session with only host-validated `tv_*` tools.
- Requires confirmation for purchases, rentals, subscriptions, account changes, and destructive actions.

## Privacy and security boundaries

- Pairing tokens are protected with Windows credential encryption.
- The continuous viewport remains in memory on the PC and is not sent to OpenAI, logged, or saved.
- Separate observations are sent to OpenAI only during an explicitly active Luna request and are not persisted by the app.
- The renderer receives a narrow preload API; unrestricted Node, shell, filesystem, browser, MCP, plugin, connector, and Windows-control capabilities are not exposed to Luna.
- Real device names, LAN addresses, hardware identifiers, pairing material, account data, runtime captures, and machine-specific logs are excluded from this repository.

## Requirements

- Windows 10 x64 or later
- Node.js 22 or later
- A compatible Vizio SmartCast TV on the same local network
- For optional AI navigation: a ChatGPT account that exposes the exact configured Luna model with image input

## Develop

```powershell
npm ci
npm test
npm run build
npm run dev
```

`npm run dev` starts Vite on loopback and launches the Electron shell. Manual controls remain usable when the optional AI runtime is unavailable.

## Package for Windows

```powershell
npm run package
```

The package command creates installer and portable builds under `release/`. Builds are unsigned unless a code-signing certificate is supplied; verify generated hashes before distribution.

## Known limits

- SmartCast app surfaces must expose a compatible Chromium debugging target for visual navigation or viewport capture.
- Native TV menus, HDMI inputs, and DRM-protected video pixels may be unavailable to the viewport.
- Phone access, remote access, cloud sync, automatic updates, and multi-user support are outside version 1.0.0.
