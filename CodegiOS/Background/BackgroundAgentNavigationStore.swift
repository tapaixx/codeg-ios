import Foundation

/// Lightweight, non-sensitive routing metadata for tasks represented by the
/// system continued-processing Live Activity. The store deliberately persists
/// only navigation identity and timing — never prompts, source code, tool input,
/// tool output, or other transcript content.
final class BackgroundAgentNavigationStore: @unchecked Sendable {
    static let shared = BackgroundAgentNavigationStore()

    struct Record: Codable, Identifiable, Equatable, Sendable {
        let id: UUID
        let serverID: UUID
        var conversationID: Int?
        var newSessionID: UUID?
        var preselectedFolderID: Int?
        let startedAt: Date
        var finishedAt: Date?
        var updatedAt: Date

        var isActive: Bool { finishedAt == nil }
    }

    enum LaunchDestination {
        case conversation(recordID: UUID, serverID: UUID, conversationID: Int)
        case newSession(recordID: UUID, serverID: UUID, request: NewSessionRequest)
        case activity
    }

    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private let key = "codeg.backgroundAgentNavigation.records.v1"

    /// A stale active marker should never live forever if the process died before
    /// it observed the remote terminal event. This is only a navigation hint, not
    /// authoritative task state.
    private static let activeTTL: TimeInterval = 24 * 60 * 60
    /// Keep a completed task briefly so a tap racing the task's completion still
    /// opens the conversation the user intended to inspect.
    private static let recentFinishedTTL: TimeInterval = 2 * 60

    private var records: [Record]

    private init() {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Record].self, from: data) {
            records = decoded
        } else {
            records = []
        }
        pruneAndPersist(now: Date())
    }

    @discardableResult
    func beginTask(serverID: UUID, conversationID: Int?, newSession: NewSessionRequest?) -> UUID {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: now)

        if let index = records.firstIndex(where: { record in
            guard record.isActive, record.serverID == serverID else { return false }
            if let conversationID { return record.conversationID == conversationID }
            if let newSession { return record.newSessionID == newSession.id }
            return false
        }) {
            records[index].conversationID = conversationID ?? records[index].conversationID
            records[index].newSessionID = newSession?.id ?? records[index].newSessionID
            records[index].preselectedFolderID = newSession?.preselectedFolderID ?? records[index].preselectedFolderID
            records[index].updatedAt = now
            persistLocked()
            return records[index].id
        }

        let record = Record(
            id: UUID(),
            serverID: serverID,
            conversationID: conversationID,
            newSessionID: newSession?.id,
            preselectedFolderID: newSession?.preselectedFolderID,
            startedAt: now,
            finishedAt: nil,
            updatedAt: now
        )
        records.append(record)
        persistLocked()
        return record.id
    }

    func updateTask(_ id: UUID, conversationID: Int?, newSession: NewSessionRequest?) {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if let conversationID {
            records[index].conversationID = conversationID
            // Once a server conversation exists it becomes the stable route.
            records[index].newSessionID = nil
            records[index].preselectedFolderID = nil
        } else if let newSession {
            records[index].newSessionID = newSession.id
            records[index].preselectedFolderID = newSession.preselectedFolderID
        }
        records[index].updatedAt = now
        persistLocked()
    }

    func finishTask(_ id: UUID) {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].finishedAt = records[index].finishedAt ?? now
        records[index].updatedAt = now
        pruneLocked(now: now)
        persistLocked()
    }

    func invalidate(_ id: UUID) {
        lock.lock()
        records.removeAll { $0.id == id }
        persistLocked()
        lock.unlock()
    }

    func launchDestination(now: Date = Date()) -> LaunchDestination? {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: now)
        persistLocked()

        let active = records
            .filter(\.isActive)
            .sorted { $0.startedAt < $1.startedAt }
        if active.count > 1 { return .activity }
        if let only = active.first { return destination(for: only) }

        let recent = records
            .filter { record in
                guard let finishedAt = record.finishedAt else { return false }
                return now.timeIntervalSince(finishedAt) <= Self.recentFinishedTTL
            }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
        return recent.first.flatMap(destination(for:))
    }

    func singleActiveStartedAt(now: Date = Date()) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: now)
        let active = records.filter(\.isActive)
        return active.count == 1 ? active[0].startedAt : nil
    }

    func activeCount(now: Date = Date()) -> Int {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: now)
        return records.filter(\.isActive).count
    }

    private func destination(for record: Record) -> LaunchDestination? {
        if let conversationID = record.conversationID {
            return .conversation(recordID: record.id, serverID: record.serverID, conversationID: conversationID)
        }
        if let newSessionID = record.newSessionID {
            return .newSession(
                recordID: record.id,
                serverID: record.serverID,
                request: NewSessionRequest(id: newSessionID, preselectedFolderID: record.preselectedFolderID)
            )
        }
        return nil
    }

    private func pruneAndPersist(now: Date) {
        lock.lock()
        pruneLocked(now: now)
        persistLocked()
        lock.unlock()
    }

    private func pruneLocked(now: Date) {
        records.removeAll { record in
            if let finishedAt = record.finishedAt {
                return now.timeIntervalSince(finishedAt) > Self.recentFinishedTTL
            }
            return now.timeIntervalSince(record.updatedAt) > Self.activeTTL
        }
    }

    private func persistLocked() {
        if records.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: key)
        }
    }
}
