# MenuRAM

Native macOS menu bar app. Shows live RAM use.

## MVP

**Menu bar**

- Shows `Used / Total GB` (example: `12.4 / 32 GB`)
- No Dock icon (`LSUIElement`)

**Dropdown**

- Available (free + reclaimable)
- App Memory
- Wired Memory
- Compressed
- Quit

## Tech

- SwiftUI `MenuBarExtra`
- `ObservableObject` `MemoryMonitor`
- Darwin: `host_statistics64` / `HOST_VM_INFO64`
- Refresh every 2 seconds
- Used ≈ App + Wired + Compressed
- App = internal pages (not internal − compressed)
- Available = free + speculative + inactive + purgeable

## Files

- `MenuRAM/App.swift` — menu bar UI
- `MenuRAM/MemoryMonitor.swift` — RAM stats
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
5. Check the menu bar for `Used / Total GB`
6. Use Quit in the dropdown to stop

## Later (not MVP)

- Color breakdown bar
- Available / free headroom
- Top apps list

## Status

MVP builds. Ready to run from Xcode.
