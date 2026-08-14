---
name: VizioControl
description: A calm living-room control console that keeps manual control immediate and Luna TV navigation inspectable.
colors:
  ground: "#111311"
  surface: "#181b18"
  surface-raised: "#20231f"
  surface-pressed: "#121411"
  seam: "#343933"
  seam-strong: "#484f46"
  text: "#f3f0e8"
  muted: "#b7b9af"
  subtle: "#868c81"
  moss: "#a8c96b"
  moss-strong: "#b9dd76"
  moss-dark: "#27331d"
  danger: "#e7a39d"
  danger-surface: "#382321"
  warning: "#e3c07a"
typography:
  display:
    fontFamily: "Segoe UI Variable, Segoe UI, system-ui, sans-serif"
    fontSize: "clamp(42px, 5vw, 72px)"
    fontWeight: 700
    lineHeight: 0.98
    letterSpacing: "-0.035em"
  headline:
    fontFamily: "Segoe UI Variable, Segoe UI, system-ui, sans-serif"
    fontSize: "21px"
    fontWeight: 700
    lineHeight: 1.25
    letterSpacing: "-0.01em"
  title:
    fontFamily: "Segoe UI Variable, Segoe UI, system-ui, sans-serif"
    fontSize: "17px"
    fontWeight: 700
    lineHeight: 1.25
    letterSpacing: "-0.01em"
  body:
    fontFamily: "Segoe UI Variable, Segoe UI, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.45
    letterSpacing: "normal"
  label:
    fontFamily: "Segoe UI Variable, Segoe UI, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 650
    lineHeight: 1.3
    letterSpacing: "normal"
rounded:
  control-sm: "9px"
  control: "11px"
  field: "13px"
  panel: "16px"
  pill: "999px"
spacing:
  xs: "4px"
  sm: "8px"
  control-gap: "9px"
  md: "12px"
  panel: "14px"
  section: "18px"
  shell: "22px"
components:
  button-primary:
    backgroundColor: "{colors.moss}"
    textColor: "{colors.surface-pressed}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "0 14px"
    height: "54px"
  button-control:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.text}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    padding: "0 12px"
    height: "48px"
  dpad-key:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.text}"
    rounded: "{rounded.control-sm}"
    width: "82px"
    height: "62px"
  dpad-ok:
    backgroundColor: "{colors.moss}"
    textColor: "{colors.surface}"
    rounded: "{rounded.control-sm}"
    width: "82px"
    height: "62px"
  input-command:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.text}"
    typography: "{typography.body}"
    rounded: "{rounded.field}"
    padding: "0 17px"
    height: "54px"
  card-saved:
    backgroundColor: "{colors.surface-raised}"
    textColor: "{colors.text}"
    rounded: "12px"
    padding: "12px 34px 12px 12px"
---

# Design System: VizioControl

## Overview

**Creative North Star: "The Agent Theater"**

VizioControl is a warm graphite operating surface: the TV view and Luna's constrained TV actions lead, while chunky local controls remain immediately available. It should feel calm, trustworthy, and purpose-built for a living room—not like a novelty imitation of a handheld remote and not like a generic analytics dashboard.

The interface combines recessed observation glass with softly raised controls. A single moss signal carries connection, progress, focus, and primary-action meaning; danger and warning colors appear only when the user needs to make a consequential decision.

**Key Characteristics:**

- Inspectable 16:9 observation beside a chronological action rail.
- Large, separated rectangular controls with tactile pressed states.
- A persistent command composer and reachable saved-request shelf.
- Plain language, restrained motion, and clear manual takeover.

## Colors

The palette is warm charcoal and parchment with a deliberately scarce moss signal.

### Primary

- **Living Moss:** The main action, active state, range fill, connection signal, and focus color.
- **Bright Moss:** A higher-visibility companion reserved for focus outlines, active status text, and selected state details.
- **Moss Recess:** A dark tinted field behind active badges and status marks.

### Neutral

- **Graphite Ground:** The full-window foundation.
- **Console Surface:** The primary panel plane.
- **Raised Charcoal:** Tactile controls and cards at rest.
- **Pressed Charcoal:** Inset feedback while a control is active.
- **Warm Parchment:** Primary text.
- **Quiet Silver** and **Subtle Sage Gray:** Supporting copy, timestamps, and secondary icons.
- **Cabinet Seam** and **Strong Seam:** Structural borders and field outlines.

### Secondary

- **Soft Alarm:** Destructive or muted state text paired with its dark alarm surface.
- **Amber Pause:** Paused, uncertain, and blocked automation states.

### Named Rules

**The One Signal Rule.** Moss is the only routine accent and should remain rare enough that active state and focus are unmistakable.

**The State, Not Decoration Rule.** Alarm and amber colors communicate an actionable state; never use them as ornamental variety.

## Typography

**Display Font:** Segoe UI Variable (with Segoe UI and system sans-serif fallbacks)
**Body Font:** Segoe UI Variable (with Segoe UI and system sans-serif fallbacks)

**Character:** Native to Windows, compact, and highly legible at practical couch-to-screen distances. Weight and spacing create hierarchy without introducing a decorative display face.

### Hierarchy

- **Display:** Used only for first-run onboarding.
- **Headline:** Dialog and major surface titles.
- **Title:** Panel headings and the main app identity.
- **Body:** Explanations, state copy, and settings descriptions.
- **Label:** Controls, compact status, values, and saved-request names.

### Named Rules

**The Plain Voice Rule.** Labels name the action directly; avoid clever wording, all-caps display styling, and theatrical AI language.

## Layout

The window is a three-row shell: top status bar, scrollable operating surface, and persistent command composer. The first operating region is a two-column agent stage with a fluid 16:9 viewport and a fixed-width action rail. Manual controls and saved requests form a second two-column region below it.

At 1160px the rail and control columns tighten. At 900px the agent stage, manual deck, and saved shelf stack, and the composer becomes sticky. At 620px labels collapse only where controls retain explicit accessible names; the separated D-pad remains a three-by-three spatial grid. Use the observed 4–22px spacing rhythm and preserve generous gaps between D-pad directions to prevent misclicks.

## Elevation & Depth

Depth is structural and tactile: outer panels use seams and tonal layering, raised controls use short diffuse shadows, recessed wells use inset shadows, and dialogs receive the only large ambient shadow. The live viewport is the deepest surface, reading as black observation glass.

### Shadow Vocabulary

- **Raised Control** (`0 5px 13px rgba(0, 0, 0, .28)`): Standard remote and saved-request controls.
- **Pressed Control** (`inset 0 3px 8px rgba(0, 0, 0, .52)`): Immediate activation feedback.
- **Observation Glass** (`inset 0 2px 12px rgba(0, 0, 0, .72), 0 6px 18px rgba(0, 0, 0, .22)`): Live SmartCast preview.
- **Dialog Lift** (`0 24px 60px rgba(0, 0, 0, .58)`): Modal settings and saved-button editing only.

**The Tactile Hierarchy Rule.** Controls may rise, wells may recess, and modal work may float; ordinary panels stay on the cabinet plane.

## Shapes

Panels use gently rounded 16px corners. Fields use 11–13px corners, and individual keys use 9–11px corners. Pills are limited to compact status badges and switches. The signature D-pad is five independent rectangles with open space between them; never merge it into a ring or circular touch target.

**The Separated Target Rule.** Directional actions must have distinct silhouettes and at least the implemented 9px gap at the narrowest layout.

## Components

### Buttons

- **Shape:** Softly squared tactile controls with 9–12px corners.
- **Primary:** Moss fill with dark text; use for Run, Save, Pair, and the D-pad OK key.
- **Hover / Focus:** Lighten the resting plane on hover; show the global 3px bright-moss outline with a 3px offset on keyboard focus.
- **Active:** Move down 1px and exchange the outer shadow for an inset pressed shadow.

### D-pad

- **Structure:** Five independent 82×62px buttons in a three-by-three spatial grid, with no dead circular shell.
- **OK key:** Moss filled, larger label weight, and the same rectangular footprint as every direction.
- **Responsive behavior:** Keys can contract to 74×58px, but gaps and separate hit targets remain visible.

### Volume Slider

- **Structure:** A native horizontal range input paired with a 48px mute button and numeric output.
- **Track:** 10px recessed track with live moss fill.
- **Thumb:** Chunky 28×28px softly squared handle; it must remain visibly draggable and keyboard operable.

### Cards / Containers

- **Corner Style:** 16px for structural panels; 12px for saved-request cards.
- **Background:** Tonal graphite layering rather than gradients or imagery.
- **Shadow Strategy:** Short raised shadow only for actionable cards.
- **Border:** One-pixel seams separate cabinet regions.

### Inputs / Fields

- **Style:** Dark recessed field, strong seam, 11–13px corners, and warm high-contrast text.
- **Focus:** The same 3px bright-moss focus outline used across all interactive elements.
- **Command field:** 54px tall and visually paired with a same-height Run or Stop button.

### Saved Requests

Saved requests are compact action cards, not media tiles. Show a semantic icon, single-line label, request kind or usage metadata, and a separately reachable editor control. Keep the shelf scrollable so every saved request remains accessible.

## Do's and Don'ts

### Do:

- **Do** make the TV view, current agent action, Cancel, and Take Over easy to find during automation.
- **Do** use real semantic buttons, a native range input, visible focus, accessible names, and reduced-motion behavior.
- **Do** keep every directional control rectangular, separated, and large enough for imprecise input.
- **Do** keep runtime TV captures in the live viewport only; use CSS and inline SVG for the product chrome.

### Don't:

- **Don't** imitate a circular handheld remote or join the D-pad into a radial control.
- **Don't** turn saved requests into poster art, service-logo tiles, or a hidden fixed-size list.
- **Don't** use scenic placeholder imagery, glossy gradients, or decorative texture in the operating surface.
- **Don't** use moss, alarm, or amber without a clear interactive or status meaning.
- **Don't** hide uncertainty: preserve the latest view and hand control back instead of visually implying success.
