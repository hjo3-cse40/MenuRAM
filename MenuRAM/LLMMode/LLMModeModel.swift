import AppKit
import Combine
import Foundation

/// Where LLM Mode is currently on screen. Polling runs only while at least one is active.
enum LLMModeSurface: Hashable {
    case popover
    case panel
    case menuBar
}

/// Bytes for each slice of the unified memory bar, left to right.
struct UnifiedBarSegments: Equatable {
    var systemWired: UInt64 = 0
    var loadedModels: UInt64 = 0
    var plannedWeights: UInt64 = 0
    var plannedKV: UInt64 = 0
    var freezable: UInt64 = 0
    var otherApps: UInt64 = 0
    var total: UInt64 = 0
    var gpuCeiling: UInt64 = 0
    var hasLoadedModel = false
}

@MainActor
final class LLMModeModel: ObservableObject {
    @Published private(set) var snapshot = LLMMemorySnapshot()
    @Published private(set) var runner = RunnerStatus()
    @Published private(set) var catalog: [CatalogModel] = CatalogModel.presets
    @Published private(set) var profile: KVProfile?
    @Published private(set) var profileContextLimit: Int?
    @Published private(set) var plan: ContextPlan?
    @Published private(set) var segments = UnifiedBarSegments()

    @Published var selectedModelID: String {
        didSet {
            UserDefaults.standard.set(selectedModelID, forKey: Keys.model)
            profile = nil
            profileModelID = nil
            recomputePlan()
            Task { await loadProfile() }
        }
    }
    @Published var context: Int {
        didSet {
            UserDefaults.standard.set(context, forKey: Keys.context)
            recomputePlan()
        }
    }
    @Published var quant: KVQuant {
        didSet {
            UserDefaults.standard.set(quant.rawValue, forKey: Keys.quant)
            recomputePlan()
        }
    }
    @Published var showsMenuBarStatus: Bool {
        didSet {
            UserDefaults.standard.set(showsMenuBarStatus, forKey: Keys.menuBar)
            setSurface(.menuBar, active: showsMenuBarStatus)
        }
    }

    let freezer = ProcessFreezer()

    private let telemetry = LLMTelemetryReader()
    private let detector = LLMRunnerDetector()
    private var surfaces: Set<LLMModeSurface> = []
    private var timer: Timer?
    private var tick = 0
    private var isRefreshing = false
    private var lastCatalogRefresh: Date?
    private var profileModelID: String?

    /// Compressed renderer heaps usually shrink 2x or better; frozen pages are not freed, only made cheap to compress.
    static let freezeReclaimFraction = 0.5

    private enum Keys {
        static let model = "LLMMode.selectedModel"
        static let context = "LLMMode.context"
        static let quant = "LLMMode.quant"
        static let menuBar = "LLMMode.menuBarStatus"
    }

    init() {
        let defaults = UserDefaults.standard
        selectedModelID = defaults.string(forKey: Keys.model) ?? CatalogModel.presets[0].id
        let savedContext = defaults.integer(forKey: Keys.context)
        context = savedContext > 0 ? savedContext : 16_384
        quant = defaults.string(forKey: Keys.quant).flatMap(KVQuant.init(rawValue:)) ?? .fp16
        showsMenuBarStatus = defaults.bool(forKey: Keys.menuBar)
        if showsMenuBarStatus {
            setSurface(.menuBar, active: true)
        }
        Task { await loadProfile() }
    }

    var selectedModel: CatalogModel? {
        catalog.first { $0.id == selectedModelID }
    }

    /// The loaded copy of the selected model, if the runner already holds it.
    var selectedLoadedModel: LoadedModel? {
        guard let model = selectedModel else { return nil }
        return runner.loaded.first { loaded in
            if let key = loaded.modelKey { return model.name == key || model.aliases.contains(key) }
            return loaded.runner == model.runner && loaded.name == model.name
        }
    }

    var launchCommand: String {
        guard let model = selectedModel else { return "" }
        if case .gguf(let url) = model.source, model.runner == .llamaServer {
            return LaunchCommand.llamaServer(path: url.path, context: context, quant: quant)
        }
        return LaunchCommand.text(for: model, context: context, quant: quant)
    }

    /// Compact suffix for the menu bar label, or nil when nothing worth showing.
    var menuBarSuffix: String? {
        guard showsMenuBarStatus else { return nil }
        if snapshot.swapActivity == .thrashing { return "⚠︎ swap" }
        guard !runner.loaded.isEmpty else { return nil }
        let headroom = snapshot.gpuCeilingBytes > snapshot.wiredBytes ? snapshot.gpuCeilingBytes - snapshot.wiredBytes : 0
        return "LLM \(MemoryFormat.gb(headroom))G"
    }

    // MARK: - Lifecycle

    func setSurface(_ surface: LLMModeSurface, active: Bool) {
        let wasFast = isFast
        if active {
            surfaces.insert(surface)
        } else {
            surfaces.remove(surface)
        }
        if surfaces.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil || wasFast != isFast {
            startTimer()
            refresh()
        }
    }

    private var isFast: Bool { surfaces.contains(.popover) || surfaces.contains(.panel) }

    private func startTimer() {
        timer?.invalidate()
        let interval: TimeInterval = isFast ? 1.0 : 5.0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        if let snapshot = telemetry.read() {
            self.snapshot = snapshot
        }
        tick += 1
        // Process scan and localhost calls are heavier; run them every other fast tick.
        guard !isRefreshing, !isFast || tick % 2 == 1 else {
            recomputePlan()
            return
        }
        isRefreshing = true
        let detector = detector
        let needsCatalog = isFast && (lastCatalogRefresh.map { Date().timeIntervalSince($0) > 30 } ?? true)
        Task {
            let samples = await Task.detached(priority: .utility) { ProcessMemoryProvider.samples() }.value
            let status = await detector.status(samples: samples)
            let catalog = needsCatalog ? await detector.catalog() : nil
            self.runner = status
            self.freezer.update(samples: samples, excludingPids: status.runnerPids)
            if let catalog {
                self.lastCatalogRefresh = Date()
                self.applyCatalog(catalog)
            }
            self.isRefreshing = false
            self.recomputePlan()
        }
    }

    private func applyCatalog(_ discovered: [CatalogModel]) {
        let merged = discovered + CatalogModel.presets
        guard merged != catalog else { return }
        catalog = merged
        if selectedModel == nil, let first = merged.first {
            selectedModelID = first.id
        } else if profileModelID != selectedModelID {
            Task { await loadProfile() }
        }
    }

    private func loadProfile() async {
        guard let model = selectedModel else { return }
        let (profile, limit) = await detector.profile(for: model)
        guard model.id == selectedModelID else { return }
        profileModelID = model.id
        self.profile = profile
        profileContextLimit = limit ?? model.maxContext
        recomputePlan()
    }

    // MARK: - Planning

    var freezeReclaimBytes: UInt64 {
        let unfrozen = freezer.groups.filter { !$0.isFrozen }.reduce(0) { $0 + $1.rendererBytes }
        return UInt64(Double(unfrozen) * Self.freezeReclaimFraction)
    }

    private func recomputePlan() {
        guard let model = selectedModel, let profile else {
            plan = nil
            return
        }
        // Re-planning a model that is already loaded: its current memory comes back.
        let held = selectedLoadedModel?.residentBytes ?? 0
        let wiredHeld = min(held, snapshot.wiredBytes)
        let metalHeadroom = snapshot.gpuCeilingBytes + wiredHeld > snapshot.wiredBytes
            ? snapshot.gpuCeilingBytes + wiredHeld - snapshot.wiredBytes
            : 0
        let budget = MemoryBudget(
            metalHeadroomBytes: metalHeadroom,
            ramHeadroomBytes: snapshot.availableBytes + held,
            freezeReclaimBytes: freezeReclaimBytes
        )
        let plan = ContextPlanner.plan(
            weightsBytes: model.weightsBytes,
            profile: profile,
            context: context,
            quant: quant,
            budget: budget,
            maxModelContext: profileContextLimit
        )
        if plan != self.plan {
            self.plan = plan
        }
        updateSegments(plan: plan, heldBySelected: held)
    }

    private func updateSegments(plan: ContextPlan, heldBySelected: UInt64) {
        var bar = UnifiedBarSegments()
        bar.total = snapshot.totalBytes
        bar.gpuCeiling = snapshot.gpuCeilingBytes
        bar.hasLoadedModel = !runner.loaded.isEmpty

        let loadedTotal = runner.loaded.reduce(0) { $0 + $1.residentBytes }
        let otherLoaded = loadedTotal > heldBySelected ? loadedTotal - heldBySelected : 0
        let modelWired = min(loadedTotal, snapshot.wiredBytes)
        bar.systemWired = snapshot.wiredBytes - modelWired
        bar.loadedModels = otherLoaded
        bar.plannedWeights = plan.weightsBytes + plan.overheadBytes
        bar.plannedKV = plan.kvBytes
        bar.freezable = freezer.groups.reduce(0) { $0 + $1.rendererBytes }

        let accounted = bar.systemWired + loadedTotal + bar.freezable
        bar.otherApps = snapshot.usedBytes > accounted ? snapshot.usedBytes - accounted : 0
        if bar != segments {
            segments = bar
        }
    }
}
