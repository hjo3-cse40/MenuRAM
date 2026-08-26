# MenuRAM — handoff for the next chat

Continue from here. Do not re-litigate MVP or Xcode setup unless something is broken.

## Repo

- GitHub: https://github.com/hjo3-cse40/MenuRAM
- Local: `/Users/samjo/GITHUB_REPO/menuram`
- Author for commits: `hjo3-cse40 <hjo3@ucsc.edu>`
- **Never** leave `Co-authored-by: Cursor` on commits. After `git commit`, check `%B`. If the trailer is there, `git commit-tree` (same tree/parent, stripped message) then `git update-ref HEAD`. Do not use `git reset --hard`. If already pushed and Sam wants GitHub fixed: `--force-with-lease`. User-wide rule: `~/.cursor/rules/no-cursor-commit-attribution.mdc`. Attribution toggle is off in Cursor Settings.

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
- Top apps: `proc_listallpids(nil,0)` returns a **PID count, not bytes**. Rank `ri_phys_footprint`. Group `Helper (Renderer|Plugin|GPU)`. Group `com.apple.WebKit*` into the responsible app (Safari/Mail/Notes) via `responsibility_get_pid_responsible_for_pid`; fallback label is still WebKit. Locked: show the app you would quit, not a WebKit row. `phys_footprint` can be ~9 GB for Safari tabs while RSS looks like ~1 GB.
- Files: `MenuRAM/App.swift`, `MemoryMonitor.swift`, `MemoryBarView.swift`, `ProcessMemory.swift`, `HoverTooltip.swift`, `Assets.xcassets`.
- Scheme: `MenuRAM`. Ad-hoc sign to run locally. DerivedData gitignored; local `.derivedData` in repo is junk.
- Launch at Login: `SMAppService.mainApp.register()` / `.unregister()` in the popover (toggle above Quit). `openSystemSettingsLoginItems()` if status is `.requiresApproval`. Shipped `7ec37dd`.
- App icon: `Assets.xcassets/AppIcon`. README title uses `docs/menuram-icon.png` at 48px (`ae94514`). Hero stays the main screenshot.

## Product decisions (locked unless user reopens)

- Stay simple. No App Store / notarization **today**.
- Skip GitHub iOS workflows. Optional later: one macOS `xcodebuild` job.
- README hero: `docs/menuram-hero.png` (black padded canvas ~850×992). Centered, width ~420 in README.
- Screenshot is **Critical / loaded 18 GB**. Caption in README covers Top Apps vs App Memory mismatch.
- No YAML/XcodeGen for now.
- Top Apps grouping is for “what would I quit,” not raw process names. WebKit → Safari (etc.) is shipped (`c1d52bd`).
- Daily use is a **Release `.app`** (`./scripts/install-local.sh`, default `~/Applications`). Do not leave Xcode Run attached for background use. Do not treat DerivedData as an install.

## Distribution (later, Sam will handle)

Locked direction: **Homebrew cask of a prebuilt `.app`**, not App Store, not a CLI that prints RAM. Terminal use is `open -a MenuRAM` / `killall MenuRAM` after the cask drops the app in `/Applications`.

- A cask still installs a real app. That is correct. Do not rewrite as a formula that compiles from source (needs Xcode on every machine).
- **Cask file lives in this repo:** `Casks/menuram.rb`. Tap with an explicit URL, e.g. `brew tap hjo3-cse40/menuram https://github.com/hjo3-cse40/MenuRAM`. A separate `homebrew-tap` repo is optional later (short `user/tap/menuram` name). Not required for v1.
- Launchpad will show the icon if the app is in `/Applications`. Ignore Launchpad. Do not hide the app to avoid it.
- Do **not** add install docs until a real GitHub Release zip URL exists. README “clone + Xcode” is still correct.
- Packaging is **not** ready yet: no Release archive, no zip, no tag. `MARKETING_VERSION` is `1.0`; use **1.0.0** on the tag/zip/cask when cutting.
- Updates do **not** auto-apply. New zip + new SHA in the cask, then `brew upgrade --cask`. Running MenuRAM does not pull git.
- Unsigned / ad-hoc: document `brew install --cask --no-quarantine`. No notarization today.
- Before first cask: Archive (Release), smoke `/Applications` copy (menu bar, Quit, login item, icon), `zip -r MenuRAM-v1.0.0.zip MenuRAM.app`, release + `shasum -a 256`, then write the cask.

## Not done / later

- Homebrew cask (see Distribution). Sam postponed.
- Notarized download / `.dmg`
- Further helper grouping (non-WebKit XPCs) if it still mislabels owners
- CI
- `@Observable` migration

## User prefs

- Simple, direct language. No em dashes in user-facing copy.
- Understand-before-changing: plan, small diffs, review checklist.
- Commit/push only when asked; GitHub must show only Sam (no Cursor co-author).
- Project rule: `.cursor/rules/menuram.mdc`.
