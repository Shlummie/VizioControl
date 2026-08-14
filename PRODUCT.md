# Product

<!-- impeccable:product-schema 1 -->

## Platform

Windows desktop

## Stack

Electron + React + TypeScript, selected by the user for a Windows 10 x64 desktop application that can later share its responsive interface and controller service with a phone client.

## Users

The primary user controls a compatible Vizio SmartCast television from a Windows PC on the same local network. They want a fast replacement for the official remote and an optional natural-language path for finding and playing content.

## Product Purpose

VizioControl provides immediate local TV controls and turns successful typed requests into reusable controller buttons. It also uses a visually guided agent to navigate Hulu and other compatible SmartCast apps while preserving a direct manual takeover path.

Success means the user can install a Windows EXE, pair with a supported TV, control it without cloud latency, run bounded visual automation through GPT-5.6 Luna Max with ChatGPT authentication, and reliably replay proven requests from saved buttons.

## Positioning

The product joins a tactile local remote, a direct in-memory view of the active SmartCast interface, and semantic buttons that re-run changing requests such as “play the latest episode.” The official remote does not provide that combined workflow.

## Operating Context

- The TV and Windows PC are on the same home LAN.
- The PC app normally starts minimized in the Windows tray.
- Manual controls must remain available without loading or depending on a model.
- Luna TV navigation is visible, cancellable, bounded, and hands control back when uncertain.
- Hulu uses one preferred profile remembered locally.

## Capabilities and Constraints

- Vizio SmartCast discovery, pairing, protected Quick Start standby/wake, volume, mute, input, navigation, text entry, application launching, and state queries. Power-off fails closed if network-wakeable standby cannot be verified.
- Deterministic local macros, host-verified teach-once setting macros, and content-dependent semantic saved buttons. A learned settings button replays over the LAN without Luna.
- Visual automation for SmartCast applications that expose a compatible Chromium debugging target; HDMI inputs and opaque native applications remain manual-only.
- An optional local viewport streams a compatible SmartCast Chromium screen at up to 24 FPS even when Luna is idle. Decoded frames swap atomically to avoid blank flashes, and the display can expand fullscreen. Those continuous frames stay in memory on the PC and are never forwarded to OpenAI, logged, or saved.
- SmartCast Chromium capture can show Hulu menus and controls, but DRM-protected playback pixels are withheld by the encrypted video layer and remain black; fullscreen does not bypass that boundary.
- Luna screen observations are requested separately only during an active AI run, kept in memory, sent to OpenAI through the bundled Codex App Server, and never logged or saved.
- GPT-5.6 Luna runs with Max reasoning in a fresh ephemeral session and can invoke only host-validated TV tools; shell, files, web, browser, Windows control, MCP, plugins, connectors, skills, and other agents are unavailable.
- Purchases, rentals, subscriptions, authentication changes, profile/account changes, and destructive actions require explicit confirmation.
- One run is limited to five minutes or 100 TV actions and always exposes Cancel and Take Over.
- Phone access, LAN serving, remote access, cloud sync, automatic updating, and multi-user support are deferred.

## Brand Commitments

- Product name: VizioControl.
- Voice: direct, calm, plain-language, and never theatrical about routine control.
- The visual direction uses warm charcoal surfaces, softly raised tactile controls, restrained green status color, and a premium physical-remote character.

## Evidence on Hand

- Read-only live checks on a supported Vizio TV confirmed the SmartCast HTTPS control endpoint, application state, a compatible Chromium debugging target, screen capture, and an accessibility/focus tree.
- Device identifiers, LAN details, pairing tokens, account data, and machine-specific captures are deliberately excluded from the public source tree and application logs.
- There are no approved marketing claims, customer metrics, third-party artwork, or code-signing certificate; future work must not invent them.

## Product Principles

1. Manual control is instant, local, and independent of AI availability.
2. The agent shows its work and yields safely instead of guessing.
3. A successful request becomes easier the next time through a reusable button.
4. TV pairing credentials stay encrypted on the PC; the continuous viewport stays local, and Luna observations leave the PC only during an explicitly active Luna request.
5. The desktop foundation should preserve a clean path to an authenticated phone client later.

## Accessibility & Inclusion

The interface must support complete keyboard navigation, visible focus, high-contrast states, semantic control labels, reduced motion, and common Windows display scaling.
