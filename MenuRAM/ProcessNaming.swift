import Darwin
import Foundation

enum ProcessKind: String {
    case app = "App"
    case tool = "Background"
    case system = "macOS"
}

/// Human label for a process: the app bundle it lives in, a known tool, or the script an interpreter runs.
struct ProcessLabel: Equatable {
    let name: String
    let kind: ProcessKind
    /// Short hint shown in the expanded list, e.g. `~/.refact/bin`.
    let detail: String?
}

enum ProcessNaming {
    /// Path fragments for tools whose executable name says nothing useful.
    private static let knownTools: [(fragment: String, name: String)] = [
        ("/cursor-agent/", "Cursor Agent CLI"),
        ("anysphere.cursor-agent", "Cursor Agent CLI"),
        ("/.refact/", "Refact.ai"),
        ("refact", "Refact.ai"),
        ("com.canonical.multipass", "Multipass VM"),
        ("/.lmstudio/apps/bionic/", "Bionic"),
        ("/.lmstudio/", "LM Studio"),
        ("/.ollama/", "Ollama"),
        ("com.docker", "Docker"),
        ("/.colima/", "Colima VM"),
        ("/.orbstack/", "OrbStack"),
    ]

    private static let systemNames: [String: String] = [
        "WindowServer": "WindowServer (display)",
        "kernel_task": "Kernel",
        "mds": "Spotlight",
        "mds_stores": "Spotlight",
        "mdworker": "Spotlight",
        "mdworker_shared": "Spotlight",
        "corespotlightd": "Spotlight",
        "Spotlight": "Spotlight",
        "photoanalysisd": "Photos analysis",
        "mediaanalysisd": "Photos analysis",
        "iLifeSlideshows": "Photos slideshows",
        "suggestd": "Siri Suggestions",
        "AppleSpell": "Spell checker",
        "ibtoold": "Xcode (Interface Builder)",
    ]

    private static let interpreters: Set<String> = [
        "node", "python", "python3", "Python", "ruby", "java", "bun", "deno", "perl", "php",
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var bundleNameCache: [String: String] = [:]

    static func label(pid: pid_t, rawName: String, path: String) -> ProcessLabel {
        let home = NSHomeDirectory()

        // Some processes hide their path from proc_pidpath; the short name still identifies them.
        let haystack = path.isEmpty ? rawName : path
        for tool in knownTools where haystack.contains(tool.fragment) {
            return ProcessLabel(name: tool.name, kind: .tool, detail: nil)
        }

        if let bundlePath = outermostAppBundle(in: path) {
            // Dock, Finder, Control Center, loginwindow: part of macOS, not something you'd quit.
            let isSystemUI = bundlePath.hasPrefix("/System/Library/")
            return ProcessLabel(name: bundleDisplayName(bundlePath), kind: isSystemUI ? .system : .app, detail: nil)
        }

        let executable = path.isEmpty ? rawName : (path as NSString).lastPathComponent
        if let friendly = systemNames[executable] ?? systemNames[rawName] {
            return ProcessLabel(name: friendly, kind: .system, detail: executable)
        }

        if interpreters.contains(executable) {
            let script = scriptName(pid: pid)
            let name = script.map { "\(executable) · \($0)" } ?? executable
            return ProcessLabel(name: name, kind: .tool, detail: abbreviate(directory(of: path), home: home))
        }

        let isSystem = path.isEmpty || path.hasPrefix("/System/") || path.hasPrefix("/usr/")
            || path.hasPrefix("/Library/Apple/") || path.hasPrefix("/sbin/")
        return ProcessLabel(
            name: helperStripped(rawName),
            kind: isSystem ? .system : .tool,
            detail: isSystem ? nil : abbreviate(directory(of: path), home: home)
        )
    }

    /// `/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/...` → `/Applications/Cursor.app`.
    private static func outermostAppBundle(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    private static func bundleDisplayName(_ bundlePath: String) -> String {
        lock.lock()
        if let cached = bundleNameCache[bundlePath] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let fallback = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        var name = fallback
        if let info = NSDictionary(contentsOfFile: bundlePath + "/Contents/Info.plist") {
            let display = info["CFBundleDisplayName"] as? String
            let bundleName = info["CFBundleName"] as? String
            // Some bundles (WhatsApp) prefix their name with an invisible left-to-right mark.
            let cleaned = [display, bundleName].compactMap { $0?.filter { !$0.unicodeScalars.allSatisfy { $0.properties.generalCategory == .format } } }
            if let candidate = cleaned.first(where: { !$0.isEmpty }) {
                name = candidate
            }
        }

        lock.lock()
        bundleNameCache[bundlePath] = name
        lock.unlock()
        return name
    }

    /// First argument after the interpreter that looks like a script or module, via KERN_PROCARGS2.
    private static func scriptName(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path, then the NUL padding before argv[0].
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var args: [String] = []
        while index < size, args.count < Int(argc) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            let bytes = buffer[start..<index].map { UInt8(bitPattern: $0) }
            args.append(String(decoding: bytes, as: UTF8.self))
            index += 1
        }

        var iterator = args.dropFirst().makeIterator()
        while let arg = iterator.next() {
            if arg == "-m", let module = iterator.next() { return module }
            if arg == "-e" || arg == "-c" { return "inline script" }
            if arg.hasPrefix("-") { continue }
            let last = (arg as NSString).lastPathComponent
            if ["index.js", "main.js", "cli.js", "server.js", "main.py", "__main__.py"].contains(last) {
                let parent = ((arg as NSString).deletingLastPathComponent as NSString).lastPathComponent
                return parent.isEmpty ? last : "\(parent)/\(last)"
            }
            return last
        }
        return nil
    }

    private static func helperStripped(_ rawName: String) -> String {
        for suffix in [" Helper (Renderer)", " Helper (Plugin)", " Helper (GPU)", " Helper"] where rawName.hasSuffix(suffix) {
            let base = String(rawName.dropLast(suffix.count))
            return base.isEmpty ? rawName : base
        }
        return rawName
    }

    private static func directory(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// `~/.refact/bin`, or `~/…/cursor-agent/versions` when the path is long.
    private static func abbreviate(_ path: String, home: String) -> String? {
        guard !path.isEmpty else { return nil }
        let short = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let parts = short.split(separator: "/", omittingEmptySubsequences: false)
        guard short.count > 40, parts.count > 4 else { return short }
        return "\(parts[0])/…/" + parts.suffix(3).joined(separator: "/")
    }
}