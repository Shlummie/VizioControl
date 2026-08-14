# VizioControl 1.0.0 — Operating Guide

## Install or run

- `VizioControl Setup 1.0.0.exe` installs the app and creates Windows shortcuts.
- `VizioControl 1.0.0 Portable.exe` runs without installation.
- The builds are unsigned unless a Windows code-signing certificate is supplied. Windows SmartScreen may show **Windows protected your PC**; use **More info → Run anyway** only after checking the SHA-256 value in `SHA256SUMS.txt`.
- Start-with-Windows is enabled by default. Closing the main window sends VizioControl to the tray; the tray menu can open the app, reconnect to the TV, pause Luna navigation, or exit.

The obsolete Ollama/Qwen builds should not be installed. Current builds bundle Codex App Server `0.147.0` and do not use Ollama or an OpenAI API key.

## Pair a TV

1. Put the PC and TV on the same home network. Turn on the TV or enable its quick-start mode.
2. Open VizioControl and select **Scan**.
3. Choose your TV. If discovery cannot find it after a DHCP change, enter its current private LAN address as the manual fallback and scan again.
4. Enter the four-digit PIN displayed on the TV.

The pairing token is encrypted with Windows credential protection. The app verifies the TV’s device identity before accepting its self-signed certificate; it does not disable TLS validation globally.

## Manual control

Standby/wake, input, Home, Back, Menu, the separated rectangular D-pad, playback controls, app launch buttons, mute, and the volume slider operate directly over the home LAN. They do not require ChatGPT, internet access, or AI vision.

When the TV is on, **Standby** first verifies its Power Mode and changes Eco Mode to **Quick Start** before sending an explicit Power Off command. If Quick Start cannot be verified, VizioControl fails closed and leaves the TV on instead of risking an unreachable full shutdown. Quick Start uses more standby power than Eco Mode.

When the TV is offline, unsafe controls are disabled and **Standby** becomes **Wake**. VizioControl sends a LAN wake packet, waits for the verified SmartCast service, and re-discovers the TV if DHCP changed. Turn the TV on once and press **Refresh** after pairing so the app can remember its network adapter. A TV already stranded in Eco/full-off mode must be turned on once with its physical button; after that, VizioControl's protected Standby path keeps network wake available.

Straightforward typed requests also stay local. Examples:

- `mute`
- `volume down twice`
- `open Hulu`
- `set volume to 20`

A successful request becomes a reusable button. Saved buttons can be renamed, edited, moved, duplicated, or deleted with Undo.

## Keep the TV viewport live

Open **Settings > TV viewport** and enable **Always stream at 24 FPS**. VizioControl then keeps the visible screen preview live whether Luna is navigating or idle. This is an opt-in, local-only stream: frames remain in memory on this PC and are never sent to OpenAI, written to disk, or included in logs.

The stream is available only while the current SmartCast surface exposes a compatible Chromium screen. Some native TV menus, HDMI inputs, and protected playback surfaces may not expose capturable pixels. VizioControl never blocks capture by app name: it retries dynamically, clears only a stale frame after the observer actually reports an unavailable target, and resumes on the next valid frame. **Hide preview** pauses the continuous stream, and **Show preview** resumes it. The app publishes no more than 24 frames per second; a static TV page may naturally produce fewer frames.

Use the expand button in the upper-right corner of the viewport to open the TV display fullscreen. Press **Esc** or the collapse button to return. Frames are decoded behind the visible image and swapped only when ready, so a slow frame cannot blank the display between updates.

Hulu menus and controls can appear in the viewport, but DRM-protected program and movie pixels are intentionally withheld by Hulu's encrypted playback layer and appear black in Chromium capture. Fullscreen does not bypass that protection. VizioControl can still navigate and control playback; displaying protected video on the PC would require a separate authorized capture-device path rather than SmartCast screen inspection.

## Teach a local TV-setting macro

You can describe a supported native setting in ordinary language. The first request uses Luna only to choose from VizioControl's small, host-validated settings API. After the TV confirms the new value, VizioControl saves the result as a **Local command**. Pressing that button—or entering the same request again—replays the verified SmartCast command directly over the LAN without Luna, screenshots, or internet access.

Supported teachable settings in 1.0.0 are:

- **Screen brightness**: Vizio's Backlight control, 0–100, including relative requests such as `turn screen brightness up`.
- **Picture brightness**: Vizio's black-level Brightness control, 0–100.
- **Sleep timer**: Off, 30, 60, 90, 120, or 180 minutes, including `turn on a 60 minute sleep timer`.

Only verified setting writes can become learned macros. VizioControl intentionally does not record blind D-pad/menu sequences, content searches, playback, profile selection, app launches, text entry, purchases, or account actions as macros. Those workflows can change between screens and would be unsafe to replay without observing the TV.

## Sign in for Luna navigation

1. Open **Settings → ChatGPT navigation**.
2. Select **Sign in with ChatGPT**. VizioControl opens the system browser only for this authentication step.
3. Complete the official ChatGPT sign-in. Cached credentials are stored by the pinned Codex runtime in Windows credential storage, so normal later launches do not reopen the browser.
4. Return to VizioControl and press **Refresh** if status has not updated automatically.

AI navigation is enabled only when `model/list` confirms all of the following for the signed-in account:

- exact model `gpt-5.6-luna`;
- Max reasoning;
- image input.

VizioControl never silently substitutes another GPT model, Ollama, or an API-key session. If Luna Max is unavailable or the account usage limit is reached, manual controls continue working.

## Ask Luna to find content

Enter a content-dependent request such as `play the latest episode of The Bear` and press Enter. Each semantic request starts a fresh ephemeral Luna session. During that active run, the app shows the current TV screen, action timeline, **Stop**, and **Take over** controls.

Luna can use only VizioControl’s validated TV operations: observe the TV, read TV state, launch an allowlisted TV app, press an allowlisted TV key, enter bounded text, wait, request a choice or confirmation, and finish. It cannot see or control Windows, read files, run commands, browse the web, use general computer-use, MCP, apps, plugins, connectors, skills, permissions, or other agents.

SmartCast Home does not expose an inspectable web screen on the TV. That is expected: Luna reads the TV state, opens the requested compatible app, waits for that app's temporary screen target, and then begins visual navigation. Content requests that do not name a service use Hulu as the v1 default.

At Hulu's profile picker, VizioControl automatically uses and remembers the profile when only one existing profile is available. If several profiles exist, the app comes to the foreground and asks once; that selection becomes the preferred Hulu profile for later requests. It can be changed in **Settings → Preferred Hulu profile**.

Ordinary included content may start automatically. Purchases, rentals, subscriptions, sign-in/out, account or profile changes, and destructive actions always pause for explicit confirmation. Ambiguous search results pause for a choice instead of guessing.

Each run is capped at five minutes, 48 Luna tool steps, and 100 TV actions. **Stop** is immediate. **Take over** cancels the run and leaves manual controls ready.

## Screen privacy

- The optional 24 FPS viewport captures compatible SmartCast video frames while enabled and visible, even when Luna is idle. That continuous stream stays local and is never routed into Luna.
- Luna screenshots and accessibility/focus data are captured separately only during an active AI request.
- Luna observations stay in memory and are sent to OpenAI only for that active Luna run.
- Screenshots and accessibility data are not written to disk or application logs.
- The TV pairing token, ChatGPT credentials, screenshots, and accessibility data are never stored in saved-button files.
- Turn history persistence, App Server remote control, web tools, shell, files, plugins, skills, MCP, connectors, and Windows control are disabled for VizioControl’s isolated runtime.

Turn off **Settings > Allow AI vision** to disable visual automation entirely. **Always stream at 24 FPS** controls the local continuous stream independently; **Show the screen preview** hides and pauses that stream.

## Troubleshooting

- **The TV is offline:** press **Wake**. If it does not come online within 30 seconds, it was probably last shut down in Eco Mode. Turn it on once with the physical button and press **Refresh**. The next **Standby** command verifies/enables **Menu → System → Power Mode → Quick Start** before turning it off. Discovery rechecks Vizio Cast, Google Cast, and AirPlay announcements plus the stored device identity before using a manual address.
- **Manual controls work but Luna is signed out:** use **Settings → Sign in with ChatGPT**. Internet is required for Luna navigation only.
- **Luna access unavailable:** press **Refresh** and read the exact status. The account must expose GPT-5.6 Luna with Max reasoning and image input; the app will not fall back to another model.
- **Usage limit reached:** wait for the displayed usage window to reset. Manual control and local macros remain available.
- **A TV app cannot be observed after launch:** that app may not expose a compatible Chromium target. Use manual control; relaunching an app triggers bounded debugging-port and target rediscovery. An unobservable SmartCast Home screen by itself is normal and no longer ends a Luna run.
- **The local viewport says Waiting for screen:** open a compatible SmartCast streaming app. Home, native TV menus, and HDMI inputs cannot be captured; VizioControl reconnects automatically after an app exposes its Chromium target.
- **Hulu menus appear but the show itself is black:** Hulu's encrypted playback layer blocks Chromium screen capture. This is expected DRM behavior; manual controls and Luna navigation still work, but the protected video cannot be mirrored through the SmartCast debug page.
- **Hulu asks for a profile:** choose once in the foreground prompt. VizioControl stores that profile locally and uses it automatically on later Hulu requests.
- **Reset TV pairing:** use **Settings → Forget TV and erase the local pairing token**, then pair again.
- **Remove local data before uninstalling:** first sign out of ChatGPT and forget the TV in Settings. The installer intentionally does not erase user data automatically.
