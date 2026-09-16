# RunStuff design system

The visual references are `ui-examples/runstuff-popover.png` and `ui-examples/runstuff-detail.png`.
`RunStuff/DesignSystem.swift` owns the shared SwiftUI tokens and components.

## Visual direction

Use dark, opaque surfaces rather than translucent material inside the panel. Separate related controls into outlined cards.
Keep activity visible without making the interface look busy. Use colour for meaning, not for random job identities.
The reference images are enlarged compositions; the app uses compact macOS sizes and scrolls detail content between a fixed header and footer.

## Colours

| Token | Approximate hex | Use |
| --- | --- | --- |
| `canvas` | `#15171B` | Panel background |
| `surface` | `#1F2228` | Cards, headers and footers |
| `raised` | `#252930` | Hovered cards and header gradient |
| `border` | `#33373F` | One-point card outlines |
| `text` | `#F0F2F7` | Primary text |
| `secondary` | `#A2ABBA` | Labels and secondary actions |
| `mint` | `#28CE9D` | Running state, primary actions and enabled switches |
| `coral` | `#FF6D72` | Stop and delete actions |
| `blue` | `#5DA5FF` | Memory measurements |

Warnings retain the system orange. Errors retain a distinct error indicator and explanatory text.
Never communicate state through colour alone. Disabled controls use reduced opacity and retain their explanatory help text.
The app chrome is dark in both system appearances. Terminal windows retain the user's terminal theme preference.

## Typography and spacing

Use the system sans serif for navigation and labels, and the system monospace for commands, paths and measurements.

| Token | Size and weight | Use |
| --- | --- | --- |
| `title` | 22 pt semibold | Running count and editor title |
| `heading` | 15 pt semibold | Stuff names |
| `body` | 13 pt regular | Controls and detail labels |
| `caption` | 11 pt medium | Section labels and action tiles |
| `code` | 12 pt monospace | Technical values |

Use 16 pt panel insets, 12 pt card padding, and 8–12 pt gaps. Cards have a 14 pt radius; buttons use 10 pt.
The panel is 420 × 620 pt. Lists and detail content scroll; navigation and lifecycle actions stay visible.
Truncate commands in list rows, but allow selection and wrapping in details. Do not shrink technical text to fit.

## Components

- `StuffCard`: an outlined surface for related rows, charts or controls. Use dividers within a card rather than more nested cards.
- `StuffButtonStyle`: neutral, mint or coral action treatment. Keep destructive actions separate from navigation targets.
- `StuffActionLabelStyle`: an icon above a short label for equal-width action tiles.
- `RunningCountLabelStyle`: a small mint indicator beside the running count.
- `stuffTheme()`: shared typography, foreground, tint, canvas and dark appearance for SwiftUI window roots.
- Native text fields, pickers, disclosure groups and switches retain macOS keyboard and accessibility behaviour.

Show actual metric history, including sampling gaps. Do not fabricate chart activity when a job has no measurements.
Raw terminal bytes continue through SwiftTerm; the redesign does not replace terminal output with styled plain text.

## Motion

Motion acknowledges an action or explains a change in location. It must not compete with process output.

| Token | Timing | Use |
| --- | --- | --- |
| `feedback` | 120 ms ease-out | Button press and card hover |
| `transition` | 200 ms ease-in-out | Navigation intent, running header and PATH disclosure |

Buttons darken and scale to 97% while pressed. Cards change surface on hover without moving.
Navigation uses SwiftUI's native transition; the timing token supplies the transaction, not a custom sliding implementation.
PATH expansion uses the transition token. Do not animate every metric sample, elapsed-time tick or output update.
Hide the running header when no Stuff is running. Slide and fade it in from the top when the first job starts, and out when the last stops.

Read `accessibilityReduceMotion` at the interaction site. When enabled, omit explicit animation and press scaling; keep immediate colour feedback.
Avoid perpetual pulses, bounce, staggered list entrances and layout movement on hover.

## Check a visual change

Build and run the app, then inspect the empty list, running and stopped rows, long commands, expanded PATH and scrolled detail controls.
Check the editor and settings separately. Verify that start/stop controls do not also navigate, and that Back and keyboard shortcuts still work.
Check Reduced Motion before adding a new animated interaction. Launch must still show only the menu bar item; closing other windows must not quit RunStuff.
