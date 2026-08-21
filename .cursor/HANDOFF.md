# MenuRAM — handoff for the next chat

Continue from here. Do not re-litigate MVP or Xcode setup unless something is broken.

## Repo

- GitHub: https://github.com/hjo3-cse40/MenuRAM
- Local: `/Users/samjo/GITHUB_REPO/menuram`
- Author for commits: `hjo3-cse40 <hjo3@ucsc.edu>`
- **Never** leave `Co-authored-by: Cursor` on commits. Cursor injects it on `git commit`; use `git commit-tree` + `git reset --hard` then `git push` (see last commits).

## Environment (done)

- Mac, Apple Silicon, macOS 15.7.4 Sequoia
- Xcode **16.4** (not App Store Xcode 26; that needs macOS 26.2)
- `xcode-select` → `/Applications/Xcode.app/Contents/Developer`
- Swift 6.1.2
- Homebrew present; no XcodeGen (not needed)

## What the app is

Native **menu-bar-only** SwiftUI app (`LSUIElement`). Popover via `MenuBarExtra` + `.menuBarExtraStyle(.window)`. No Dock icon.

**Menu bar:** colored pressure dot (bitmap, `isTemplate = false`; SF Symbols stay monochrome) + `Used / Total GB`.

**Popover:** Available, Pressure, Swap, color bar (App/Wired/Compressed/Other), Top 5 apps, Quit. Hover cards on Available / Pressure / Swap / bar — **not** on Top Apps (user removed those). Tooltips are an overlay card, not `.help()` (broken in menu extra) and not inline text (caused popover jitter).

## Key implementation facts

- `ObservableObject` not `@Observable` (macro plugin failed in CLI sandbox; keep ObservableObject unless rebuilding in Xcode proves `@Observable` works).
- Host stats: `host_statistics64` / `HOST_VM_INFO64`. Count uses **stride**, not size.
- **App Memory = `internal_page_count` only.** Do not subtract compressed (that made App 0.0).
- Used = App + Wired + Compressed. Total = `physicalMemory`.
- Available = free + speculative + inactive + purgeable.
- Pressure: `kern.memorystatus_vm_pressure_level` + `DispatchSourceMemoryPressure`. Critical on this 18 GB machine under Cursor/browsers is **often real**, not a bug. User accepted that. Pair with Swap.
- Swap: `vm.swapusage` / `xsu_used`.
- Top apps: `proc_listallpids(nil,0)` returns a **PID count, not bytes**. Rank `ri_phys_footprint`. Group `Helper (Renderer|Plugin|GPU)` and `com.apple.WebKit*` → WebKit.
- Files: `MenuRAM/App.swift`, `MemoryMonitor.swift`, `MemoryBarView.swift`, `ProcessMemory.swift`, `HoverTooltip.swift`.
- Scheme: `MenuRAM`. Ad-hoc sign to run locally. DerivedData gitignored; local `.derivedData` in repo is junk.

## Product decisions (locked unless user reopens)

- Stay simple. No App Store / notarization **today**.
- Skip GitHub iOS workflows. Optional later: one macOS `xcodebuild` job.
- README hero: `docs/menuram-hero.png` (black padded canvas ~850×992). Centered, width ~420 in README.
- Screenshot is **Critical / loaded 18 GB**. Caption in README covers Top Apps vs App Memory mismatch.
- No YAML/XcodeGen for now.

## Not done / later

- Notarized download / `.dmg`
- Launch at login
- Helper grouping polish
- CI
- `@Observable` migration

## User prefs

- Simple, direct language. No em dashes in user-facing copy.
- Understand-before-changing: plan, small diffs, review checklist.
- Commit/push only when asked; no Cursor co-author trailer.
