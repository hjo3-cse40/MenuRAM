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
    @Published private(set) var availableBytes: UInt64 = 0

    private var timer: Timer?

    var menuBarTitle: String {
        "\(formatGB(usedBytes)) / \(formatGB(totalBytes)) GB"
    }

    var availableText: String { "Available: \(formatGB(availableBytes)) GB" }
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
        // Use stride (not size). Wrong count can return incomplete/wrong fields.
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return }

        let pageSize = UInt64(vm_kernel_page_size)

        // On current macOS, internal pages are anonymous/app-resident and are
        // already separate from compressor pages. Do not subtract compressed.
        let app = UInt64(stats.internal_page_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize

        // Headroom: free pages + pages macOS can usually reclaim for apps.
        let available = (
            UInt64(stats.free_count)
                + UInt64(stats.speculative_count)
                + UInt64(stats.inactive_count)
                + UInt64(stats.purgeable_count)
        ) * pageSize

        appBytes = app
        wiredBytes = wired
        compressedBytes = compressed
        availableBytes = available
        usedBytes = app + wired + compressed
        totalBytes = ProcessInfo.processInfo.physicalMemory
    }

    private func formatGB(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        return String(format: "%.1f", gb)
    }
}
