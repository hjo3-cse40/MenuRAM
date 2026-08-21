import Combine
import Darwin
import Foundation

/// Reads macOS VM stats via Darwin host APIs and publishes them for the menu bar UI.
@MainActor
final class MemoryMonitor: ObservableObject {
    @Published private(set) var usedBytes: UInt64 = 0
    @Published private(set) var totalBytes: UInt64 = 0
    @Published private(set) var appBytes: UInt64 = 0
    @Published private(set) var wiredBytes: UInt64 = 0
    @Published private(set) var compressedBytes: UInt64 = 0

    private var timer: Timer?

    var menuBarTitle: String {
        "\(formatGB(usedBytes)) / \(formatGB(totalBytes)) GB"
    }

    var appText: String { "App Memory: \(formatGB(appBytes)) GB" }
    var wiredText: String { "Wired Memory: \(formatGB(wiredBytes)) GB" }
    var compressedText: String { "Compressed: \(formatGB(compressedBytes)) GB" }

    init() {
        totalBytes = ProcessInfo.processInfo.physicalMemory
        refresh()
        start()
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return }

        let pageSize = UInt64(vm_kernel_page_size)
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let internalPages = UInt64(stats.internal_page_count) * pageSize
        // Activity Monitor–style App Memory ≈ internal pages minus compressed pages.
        let app = internalPages > compressed ? internalPages - compressed : 0

        appBytes = app
        wiredBytes = wired
        compressedBytes = compressed
        usedBytes = app + wired + compressed
        totalBytes = ProcessInfo.processInfo.physicalMemory
    }

    private func formatGB(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        return String(format: "%.1f", gb)
    }
}
