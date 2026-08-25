# Ivy macOS UI specification

This file is the canonical visual specification for Ivy note panels. It adapts the approved web card system to native macOS windows without copying the web card's fixed dimensions.

## Product surface

- A note is a quiet paper surface. Content dominates; controls recede until needed.
- A note uses a standard AppKit titled, resizable, full-size-content panel. The title and traffic-light controls are visually hidden, but AppKit and WindowServer retain complete ownership of frame hit testing, resize cursors, live resize, background movement, and focus transitions. The panel preserves its frame. Default size: `280 × 220pt`; minimum size: `220 × 160pt`. The web card's fixed `232 × 232px` size does not apply.
- Notes have no separate title, label row, or visible date. The first text line remains the summary in menus; timestamps never appear on the note surface.
- No border, outline, focus ring, or window shadow. Corner radius: `10pt`; the pastel/white surface and its rounded silhouette alone define the card edge.
- `LeafiyFloatingPanel` must use `hasShadow: false`, including after the resizable style is applied. Do not draw a SwiftUI shadow.
- The editor wrapper uses `14pt` horizontally, `52pt` at the top, and `18pt` at the bottom. TextEditor contributes a native `10pt` text inset, placing the visible text edges on the top controls' `24pt` center axis. The expanded top safe area keeps text, selections, and the insertion point clear of both controls; there is no reserved bottom-control zone.

## New-note placement

- A new note starts at the active screen's top-right, inside the screen's visible frame, with `72pt` clearance from the top and right edges. This is the canonical “about three fingers” desktop margin.
- Existing visible pinned notes on that screen reserve their frames. New notes take the first open `280 × 220pt` slot, scanning right-to-left with `16pt` gaps, then wrapping to the next row from top to bottom.
- Placement never moves an existing note. Hidden, closed, unpinned, or off-screen notes do not reserve a slot.
- The initial frame is persisted immediately. Later moves and live resizes continue to overwrite it through the existing device-local frame contract.

## Typography

| Role | macOS value | Color |
|---|---:|---|
| Primary/editor text | `14pt`, `20pt` line rhythm, regular | `#29252B` |
| Strong/control text | `16pt`, `22pt` line rhythm, semibold when needed | `#171419` |
| Compact labels/tooltips | `11pt`, `16pt` line rhythm | semantic secondary |

Text remains dark on every pastel. Accent colors are for icons, links, selected states, and color controls—not body copy.

## Note palette

The storage/API raw values are stable protocol identifiers. Visual names and colors are product tokens; the `gray` identifier is retained for compatibility but renders as Peach.

| Product token | Storage key | Surface | Accent |
|---|---|---|---|
| White | `white` | `#FFFFFF` | `#7B747E` |
| Sakura pink | `pink` | `#FFE5F9` | `#E85AAE` |
| Peach | `gray` | `#FFE8E4` | `#DE7A6C` |
| Cream apricot | `yellow` | `#FFEEDC` | `#C88A3E` |
| Mint | `green` | `#E5F7EF` | `#4B9C78` |
| Misty blue | `blue` | `#E7EEFF` | `#5C7BD9` |
| Lavender | `purple` | `#EEE7FF` | `#8065D6` |

This mapping is shared by note backgrounds, palette swatches, and selected/accent states.

- White is the default for every new installation and for any invalid stored color value.
- “Default Note Color” lives in the General settings pane and changes subsequent new notes only; it does not recolor existing notes.

## Controls and drag regions

- No footer and no timestamp.
- There is no standalone palette button and no bottom control row.
- The focused note shows one `ellipsis` action button at the top-left and one pin/unpin button at the top-right. Each has a `28 × 28pt` hit target, sits `10pt` from its card edges, and fades over `140ms`. An unfocused note shows no controls; an open action popover keeps its anchor visible until dismissal.
- The ellipsis opens one compact operation popover. It contains the seven color swatches, Close, and Delete. Delete is destructive and remains confirmation-gated. These card operations are no longer duplicated in a custom right-click menu; the editor keeps its native text-editing context menu.
- When the note is pinned, the operation popover also shows a `10–100%` opacity slider with a live percentage. It uses a `5pt` adaptive track and a high-contrast `14pt` white thumb, without tick marks. Opacity applies to the card surface only, not its text or controls; an unpinned note always renders at `100%`. The per-note pinned opacity is device-local, persists without marking content dirty, and is excluded from sync.
- Operation-popover labels use semantic foreground colors so Close remains legible in light and dark appearances; Delete alone uses the destructive red treatment.
- The whitespace between the editor and the card edge on all four sides is a native AppKit window-drag region. The editor, ellipsis button, operation popover, and pin button never initiate window movement.
- Hovering draggable whitespace keeps the normal arrow cursor. A click without movement also keeps the arrow. Only after pointer movement crosses a `3pt` drag threshold does the cursor switch to `closedHand`; it returns immediately on mouse-up.
- All visible controls are real SwiftUI controls with tooltips and accessibility labels.

## Window behavior

- Unpinned notes use normal window ordering and are brought forward/key when created, reopened, or shown through “Show All Notes.”
- Pinned notes use floating ordering.
- Closing hides without deleting. Deleting always requires confirmation.
- Position, size, pinned opacity, closed state, and global-collapse state persist locally. Color and pin state persist in the note database and sync across devices.
