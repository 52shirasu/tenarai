import Foundation
import Core
import LearningCore

/// Owns the single store. Disk work runs on the actor, never in the key event handler.
private actor LearningWorker {
    private var storage: LearningStore?
    private var expiryTask: Task<Void, Never>?
    func store() throws -> LearningStore {
        if let storage { return storage }
        let created = try LearningStore(directory: AppGroup.applicationSupportDirectoryURL()
            .appendingPathComponent("context-learning", isDirectory: true), discardPending: true)
        storage = created
        return created
    }

    func observe(_ text: String, origin: LearningStore.Origin, selectedLatin: Bool = false, app: String? = nil) async throws -> [LocalTendency] {
        let store = try store()
        let bounded = String(text.prefix(32768))
        if origin == .typed, !selectedLatin, Config.Learning().value != .nothing {
            PersonalModelTraining.record(bounded, app: app)
        }
        let observations: [LearningStore.Observation] = selectedLatin
            ? [.init(key: "selectedLatin:\(bounded.lowercased())", kind: .spelling, value: bounded)]
            : LocalExtractor.extract(bounded, origin: origin, app: app)
        try await store.learnTransient(bounded, origin: origin, observations: observations)
        return await store.tendencies()
    }

    private func scheduleExpiry(_ store: LearningStore) async {
        expiryTask?.cancel()
        guard let jobs = try? await store.pending(),
              let date = jobs.map(\.expiresAt).min() else { return }
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow))) }
            catch { return }
            try? await store.purgeExpired()
            await self?.scheduleExpiry(store)
        }
    }

    func handle(_ command: LocalLearningCommand, app: String? = nil) async throws -> [LocalTendency] {
        let store = try store()
        switch command {
        case .list: try await store.purgeExpired()
        case .edit(let key, let value): try await store.edit(key: key, value: value)
        case .delete(let key): try await store.delete(key: key)
        case .deleteAll: try await store.deleteAll()
        case .observe(let text, let origin): return try await observe(text, origin: origin, app: app)
        }
        await scheduleExpiry(store)
        return await store.tendencies()
    }
}

@MainActor
final class LocalLearningService {
    private let worker = LearningWorker()
    private(set) var tendencies: [LocalTendency] = []
    private var generation = UUID()
    private var editing = false
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var maintenance: Task<Void, Never>?
    private(set) var failed = false

    init() {
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                guard let worker = self?.worker else { return }
                let epoch = self?.generation
                do {
                    let values = try await worker.handle(.list)
                    if self?.generation == epoch, self?.editing == false { self?.tendencies = values }
                } catch { self?.failed = true }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func observe(_ text: String, origin: LearningStore.Origin, selectedLatin: Bool = false, app: String? = nil) {
        if selectedLatin && Config.Learning().value != .inputAndOutput { return }
        if Config.LearningExcludedApps().excludes(app) { return }
        guard !editing, !text.isEmpty, tasks.count < 16 else { return }
        let id = UUID(), epoch = generation
        tasks[id] = Task(priority: .utility) { [weak self, worker] in
            defer { self?.tasks.removeValue(forKey: id) }
            guard !Task.isCancelled else { return }
            do {
                let result = try await worker.observe(text, origin: origin, selectedLatin: selectedLatin, app: app)
                guard !Task.isCancelled, self?.generation == epoch else { return }
                self?.tendencies = result
            } catch { self?.failed = true }
        }
    }

    func handle(_ command: LocalLearningCommand, app: String? = nil) async throws -> [LocalTendency] {
        guard !editing else { throw CocoaError(.userCancelled) }
        defer { editing = false }
        switch command {
        case .observe(let text, let origin):
            observe(text, origin: origin, app: app)
            return tendencies
        case .list: break
        default:
            editing = true
            generation = UUID()
            let running = Array(tasks.values)
            running.forEach { $0.cancel() }
            // Drain work before deleting so a pre-delete job cannot enqueue after deletion.
            for task in running { await task.value }
        }
        let values = try await worker.handle(command)
        tendencies = values
        return values
    }
}
