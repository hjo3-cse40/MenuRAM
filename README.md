# MenuRAM

Native macOS menu bar app. Shows live RAM use.

## Features

**Menu bar**

- Colored pressure dot + `Used / Total GB`
- No Dock icon (`LSUIElement`)

**Popover (click the menu bar item)**

- Available (free + reclaimable)
- Pressure: Normal / Warning / Critical
- Color breakdown bar (App / Wired / Compressed / Other)
- Top 5 apps by RAM
- Quit

## Tech

- SwiftUI `MenuBarExtra` (`.window` style)
- `ObservableObject` `MemoryMonitor`
- Darwin: `host_statistics64` / `HOST_VM_INFO64`
- Memory pressure via sysctl + `DispatchSource`
- Top processes via `libproc`
- Host stats every 2 seconds; top apps about every 4 seconds

## Files

- `MenuRAM/App.swift` — menu bar + popover UI
- `MenuRAM/MemoryMonitor.swift` — RAM + pressure
- `MenuRAM/MemoryBarView.swift` — color bar
- `MenuRAM/ProcessMemory.swift` — top processes
- `MenuRAM.xcodeproj` — Xcode project

## Requirements

- macOS 14+
- Xcode 16.4+

## Build and run

**In Xcode**

1. Open Existing Project
2. Pick `MenuRAM.xcodeproj`
3. Destination: My Mac
4. Press Run (▶)
5. Click the menu bar item to open the popover
6. Use Quit to stop

## Status

Popover overview with pressure, color bar, and top 5 apps.
