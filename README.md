# MenuRAM

Native macOS menu bar app for live RAM, pressure, and swap.

<p align="center">
  <img src="docs/menuram-hero.png" alt="MenuRAM in the menu bar with a popover showing available memory, pressure, swap, a color breakdown, and top apps" width="420">
</p>

<p align="center">
  <em>Always-on used / total in the menu bar. Click for the rest. No Dock icon.</em>
</p>

<p align="center">
  <img src="docs/menuram-menubar.png" alt="MenuRAM extra in the macOS menu bar showing used and total RAM next to battery, Wi-Fi, and Control Center" width="420">
</p>

<p align="center">
  <em>Lives in the menu bar.</em>
</p>

## Features

- **Menu bar:** pressure color + `Used / Total GB`
- **Available:** free + reclaimable memory
- **Pressure:** Normal / Warning / Critical (same family of signal as Activity Monitor)
- **Swap:** pages on disk (thrash signal)
- **Breakdown:** App, Wired, Compressed, Other
- **Top 5 apps:** ranked by footprint; helpers grouped (Cursor Helper → Cursor, WebKit → Safari/Mail/etc.)
- Hover Available, Pressure, Swap, or the bar for a short explanation

Built with SwiftUI `MenuBarExtra` and Darwin `host_statistics64`.

## Requirements

- macOS 14 or later
- Xcode 16.4 or later

## Run

```bash
git clone https://github.com/hjo3-cse40/MenuRAM.git
cd MenuRAM
open MenuRAM.xcodeproj
```

In Xcode: destination **My Mac** → Run. Click the menu bar item. Quit from the popover.

There is no App Store build yet. This is source + Xcode.

## How numbers work

| Field | Meaning |
|--------|---------|
| Used | App + Wired + Compressed |
| Total | Physical RAM |
| App | Internal / anonymous pages |
| Available | Free + speculative + inactive + purgeable |
| Top Apps | Per-process `phys_footprint`, helpers folded into the parent name (including WebKit into Safari) |

Top Apps will not sum to App Memory. Different accounting (grouped processes vs VM buckets). That is expected.

Stats refresh about every 2 seconds. Top apps refresh about every 4 seconds.

## License

MIT. See `LICENSE`.

There is no packaged download or notarized app yet. This is source + Xcode.
