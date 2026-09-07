import Foundation
import UIKit

// MARK: - WebSocket attach-protocol messages

/// Client→server attach-protocol message (Rust `ClientMsg`, tagged `action`).
/// Encode-only; snake_case wire keys are spelled explicitly (request encoder
/// does not convert keys).
enum WSClientMessage: Encodable, Sendable {
    case attach(subscriptionId: String, connectionId: String, sinceSeq: UInt64?)
    case detach(subscriptionId: String)
    case ping

    private enum CodingKeys: String, CodingKey {
        case action
        case subscriptionId = "subscription_id"
        case connectionId = "connection_id"
        case sinceSeq = "since_seq"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .attach(let sub, let conn, let since):
            try c.encode("attach", forKey: .action)
            try c.encode(sub, forKey: .subscriptionId)
            try c.encode(conn, forKey: .connectionId)
            try c.encodeIfPresent(since, forKey: .sinceSeq)
        case .detach(let sub):
            try c.encode("detach", forKey: .action)
            try c.encode(sub, forKey: .subscriptionId)
        case .ping:
            try c.encode("ping", forKey: .action)
        }
    }
}

/// Server→client attach-protocol message (Rust `ServerMsg`, tagged `type`).
/// Decoded with the shared `.convertFromSnakeCase` decoder, so keys are
/// camelCase here.
enum WSServerMessage: Decodable, Sendable {
    case snapshot(LiveSessionSnapshot)
    case replay([EventEnvelope])
    case event(EventEnvelope)
    case detached(reason: String)
    case pong
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type, snapshot, events, envelope, reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "snapshot":
            self = .snapshot(try c.decode(LiveSessionSnapshot.self, forKey: .snapshot))
        case "replay":
            self = .replay(try c.decodeIfPresent([EventEnvelope].self, forKey: .events) ?? [])
        case "event":
            self = .event(try c.decode(EventEnvelope.self, forKey: .envelope))
        case "detached":
            self = .detached(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case "pong":
            self = .pong
        default:
            self = .unknown
        }
    }
}

// MARK: - EventStream

/// A live WebSocket connection to `/ws/events`.
///
/// The public contract remains `start → ready → attach → frames → close`, but a
/// socket-level drop after a successful attach is now recovered *inside* this
/// transport. The caller therefore keeps one logical stream across Wi-Fi/5G/VPN
/// transitions and ordinary iOS background suspension instead of turning each
/// transport blip into visible chat state.
///
/// Recovery reuses the same subscription + server-side ACP connection and sends
/// `since_seq` so missed events are replayed. Only after several consecutive
/// reconnect failures does the stream finally emit `.closed`, allowing the
/// existing SessionDetail fallback to reconcile against the server.
final class EventStream: @unchecked Sendable {
    enum Frame: Sendable {
        case ready
        case snapshot(LiveSessionSnapshot)
        case replay([EventEnvelope])
        case event(EventEnvelope)
        case detached(reason: String)
        case pong
        case closed(reason: String?)
    }

    let frames: AsyncStream<Frame>
    private let continuation: AsyncStream<Frame>.Continuation
    private let baseURL: URL
    private let url: URL
    private let token: String
    private let session: URLSession
    private let lock = NSLock()

    private var task: URLSessionWebSocketTask?
    private var isClosed = false
    private var socketGeneration = 0

    /// Logical attach identity. These survive replacement of the physical socket.
    private var attachedSubscriptionID: String?
    private var attachedConnectionID: String?
    private var lastSeq: UInt64?

    /// Internal, invisible socket recovery. A healthy frame resets the budget.
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private static let maxTransparentReconnects = 6

    private var networkListenerID: UUID?
    private var backgroundTurnHandle: UUID?

    /// Dedicated session for the long-lived event socket. `URLSession.shared`'s
    /// default 60s inactivity timeout is inappropriate for agent streams because a
    /// tool or approval may legitimately stay quiet for minutes.
    static let streamSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 604_800
        cfg.timeoutIntervalForResource = 604_800
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    private static let pingInterval: TimeInterval = 20

    init(baseURL: URL, token: String, session: URLSession = EventStream.streamSession) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.url = EventStream.websocketURL(from: baseURL)
        var captured: AsyncStream<Frame>.Continuation!
        self.frames = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        self.continuation = captured
    }

    func start() {
        BackgroundAgentCoordinator.shared.configure()

        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        if backgroundTurnHandle == nil {
            backgroundTurnHandle = BackgroundAgentCoordinator.shared.beginTurn()
        }
        lock.unlock()

        let listenerID = BackgroundAgentCoordinator.shared.addNetworkRecoveryListener { [weak self] in
            self?.networkBecameAvailable()
        }
        lock.lock()
        networkListenerID = listenerID
        lock.unlock()

        openSocket()
    }

    func attach(subscriptionId: String, connectionId: String, sinceSeq: UInt64? = nil) {
        lock.lock()
        attachedSubscriptionID = subscriptionId
        attachedConnectionID = connectionId
        let resumeSeq = sinceSeq ?? lastSeq
        lock.unlock()
        send(.attach(subscriptionId: subscriptionId, connectionId: connectionId, sinceSeq: resumeSeq))
    }

    func detach(subscriptionId: String) {
        send(.detach(subscriptionId: subscriptionId))
    }

    func ping() { send(.ping) }

    func close() {
        let t: URLSessionWebSocketTask?
        let listenerID: UUID?
        let backgroundHandle: UUID?
        lock.lock()
        let alreadyClosed = isClosed
        isClosed = true
        socketGeneration &+= 1
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        t = task
        task = nil
        listenerID = networkListenerID
        networkListenerID = nil
        backgroundHandle = backgroundTurnHandle
        backgroundTurnHandle = nil
        lock.unlock()
        guard !alreadyClosed else { return }

        if let listenerID {
            BackgroundAgentCoordinator.shared.removeNetworkRecoveryListener(listenerID)
        }
        if let backgroundHandle {
            BackgroundAgentCoordinator.shared.endTurn(backgroundHandle)
        }
        t?.cancel(with: .goingAway, reason: nil)
        continuation.finish()
    }

    // MARK: - Socket lifecycle

    private func openSocket() {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        socketGeneration &+= 1
        let generation = socketGeneration
        let protocols = ["codeg-events", "codeg-token.\(EventStream.base64URLNoPad(token))"]
        let newTask = session.webSocketTask(with: url, protocols: protocols)
        task = newTask
        lock.unlock()

        newTask.resume()
        receiveLoop(generation: generation)
        scheduleNextPing(generation: generation)
    }

    private func send(_ message: WSClientMessage) {
        guard let data = try? CodegJSON.encoder.encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        lock.lock(); let t = task; lock.unlock()
        t?.send(.string(text)) { _ in }
    }

    private func receiveLoop(generation: Int) {
        lock.lock()
        let t = generation == socketGeneration ? task : nil
        lock.unlock()
        t?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.socketFailed(reason: error.localizedDescription, generation: generation)
            case .success(let message):
                guard self.isCurrent(generation) else { return }
                self.handle(message)
                if self.isCurrent(generation) { self.receiveLoop(generation: generation) }
            }
        }
    }

    private func socketFailed(reason: String?, generation: Int) {
        lock.lock()
        guard generation == socketGeneration, !isClosed else { lock.unlock(); return }
        let canRecover = attachedSubscriptionID != nil && attachedConnectionID != nil
        lock.unlock()

        if canRecover {
            scheduleTransparentReconnect(reason: reason)
        } else {
            finishTerminal(reason: reason)
        }
    }

    private func scheduleTransparentReconnect(reason: String?) {
        let delay: TimeInterval
        let work: DispatchWorkItem

        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        reconnectWorkItem?.cancel()
        reconnectAttempt += 1
        guard reconnectAttempt <= Self.maxTransparentReconnects else {
            lock.unlock()
            finishTerminal(reason: reason)
            return
        }

        let shift = min(reconnectAttempt - 1, 4)
        delay = min(8, 0.5 * pow(2, Double(shift)))
        socketGeneration &+= 1 // invalidate callbacks from the failed socket
        task?.cancel(with: .goingAway, reason: nil)
        task = nil

        work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = !self.isClosed && self.reconnectWorkItem?.isCancelled == false
            self.reconnectWorkItem = nil
            self.lock.unlock()
            if valid { self.openSocket() }
        }
        reconnectWorkItem = work
        let handle = backgroundTurnHandle
        lock.unlock()

        if let handle {
            BackgroundAgentCoordinator.shared.updateTurn(handle, subtitle: "Keeping the agent connected…")
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Network path recovery is a *hint*, not a reason to tear down a live socket.
    /// It only short-circuits a reconnect delay that was already scheduled after a
    /// real socket failure.
    private func networkBecameAvailable() {
        lock.lock()
        guard !isClosed, let work = reconnectWorkItem else { lock.unlock(); return }
        work.cancel()
        reconnectWorkItem = nil
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.openSocket() }
    }

    private func markHealthy() {
        lock.lock()
        reconnectAttempt = 0
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        let handle = backgroundTurnHandle
        lock.unlock()
        if let handle {
            BackgroundAgentCoordinator.shared.updateTurn(handle, subtitle: "Agent is working")
            BackgroundAgentCoordinator.shared.pulseTurn(handle)
        }
    }

    private func finishTerminal(reason: String?) {
        let listenerID: UUID?
        let backgroundHandle: UUID?
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        socketGeneration &+= 1
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        listenerID = networkListenerID
        networkListenerID = nil
        backgroundHandle = backgroundTurnHandle
        backgroundTurnHandle = nil
        lock.unlock()

        if let listenerID {
            BackgroundAgentCoordinator.shared.removeNetworkRecoveryListener(listenerID)
        }
        if let backgroundHandle {
            BackgroundAgentCoordinator.shared.endTurn(backgroundHandle)
        }
        continuation.yield(.closed(reason: reason))
        continuation.finish()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !isClosed && generation == socketGeneration
    }

    // MARK: - Keepalive

    private func scheduleNextPing(generation: Int) {
        guard isCurrent(generation) else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.pingInterval) { [weak self] in
            self?.sendKeepalivePing(generation: generation)
        }
    }

    private func sendKeepalivePing(generation: Int) {
        lock.lock()
        let t = (!isClosed && generation == socketGeneration) ? task : nil
        lock.unlock()
        guard let t else { return }
        t.sendPing { [weak self] error in
            guard let self else { return }
            if let error {
                self.socketFailed(reason: error.localizedDescription, generation: generation)
            } else if self.isCurrent(generation) {
                self.markHealthy()
                self.scheduleNextPing(generation: generation)
            }
        }
    }

    // MARK: - Frame decoding / side effects

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: return
        }
        decode(data)
    }

    private func decode(_ data: Data) {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let channel = obj["channel"] as? String {
                if channel == "__ready__" {
                    markHealthy()
                    continuation.yield(.ready)
                }
                return
            }
            guard obj["type"] is String else { return }
        }
        guard let message = try? CodegJSON.decoder.decode(WSServerMessage.self, from: data) else { return }

        markHealthy()
        switch message {
        case .snapshot(let snapshot):
            if let seq = snapshot.eventSeq { remember(seq: seq) }
            syncPendingNotifications(from: snapshot)
            continuation.yield(.snapshot(snapshot))

        case .replay(let events):
            remember(events: events)
            events.forEach { observe(event: $0.event) }
            continuation.yield(.replay(events))

        case .event(let envelope):
            remember(seq: envelope.seq)
            observe(event: envelope.event)
            continuation.yield(.event(envelope))

        case .detached(let reason):
            continuation.yield(.detached(reason: reason))

        case .pong:
            continuation.yield(.pong)

        case .unknown:
            break
        }
    }

    private func remember(events: [EventEnvelope]) {
        if let seq = events.map(\.seq).max() { remember(seq: seq) }
    }

    private func remember(seq: UInt64) {
        lock.lock()
        if seq > (lastSeq ?? 0) { lastSeq = seq }
        lock.unlock()
    }

    private func observe(event: AcpEvent) {
        lock.lock()
        let connectionID = attachedConnectionID
        let backgroundHandle = backgroundTurnHandle
        lock.unlock()
        guard let connectionID else { return }

        let coordinator = BackgroundAgentCoordinator.shared
        let client = CodegClient(baseURL: baseURL, token: token)
        let appIsBackgrounded = UIApplication.shared.applicationState != .active

        switch event {
        case .contentDelta, .thinking:
            if let backgroundHandle {
                coordinator.updateTurn(backgroundHandle, subtitle: "Generating reply…")
            }

        case .toolCall(_, let title, _, _, _, _, _, _):
            if let backgroundHandle {
                coordinator.updateTurn(
                    backgroundHandle,
                    subtitle: title.isEmpty ? "Running a tool…" : "Running \(title)…"
                )
            }

        case .toolCallUpdate(_, let title, _, _, _, _, _, _):
            if let backgroundHandle, let title, !title.isEmpty {
                coordinator.updateTurn(backgroundHandle, subtitle: "Running \(title)…")
            }

        case .permissionRequest(let requestID, let toolCall, let options):
            if let backgroundHandle { coordinator.updateTurn(backgroundHandle, subtitle: "Waiting for permission") }
            if appIsBackgrounded {
                coordinator.presentPermission(
                    client: client,
                    connectionID: connectionID,
                    requestID: requestID,
                    toolCall: toolCall,
                    options: options
                )
            }

        case .permissionResolved(let requestID):
            coordinator.resolvePermissionNotification(requestID: requestID)

        case .questionRequest(let questionID, let questions):
            if let backgroundHandle { coordinator.updateTurn(backgroundHandle, subtitle: "Waiting for your answer") }
            if appIsBackgrounded {
                coordinator.presentQuestion(
                    client: client,
                    connectionID: connectionID,
                    questionID: questionID,
                    questions: questions
                )
            }

        case .questionResolved(let questionID):
            coordinator.resolveQuestionNotification(questionID: questionID)

        case .planApprovalRequest(let approvalID, _, let planMarkdown):
            if let backgroundHandle { coordinator.updateTurn(backgroundHandle, subtitle: "Waiting for plan approval") }
            if appIsBackgrounded {
                coordinator.presentPlanApproval(
                    client: client,
                    connectionID: connectionID,
                    approvalID: approvalID,
                    planMarkdown: planMarkdown
                )
            }

        case .planApprovalResolved(let approvalID):
            coordinator.resolvePlanNotification(approvalID: approvalID)

        case .turnComplete:
            if appIsBackgrounded { coordinator.notifyTurnCompleted() }

        case .error(let message, _):
            if appIsBackgrounded { coordinator.notifyTurnFailed(message) }

        default:
            break
        }
    }

    /// A reattach snapshot is authoritative pending state. If transport recovery
    /// happened while the approval event was in flight, recreate the background
    /// notification from the snapshot; otherwise remove stale delivered actions.
    private func syncPendingNotifications(from snapshot: LiveSessionSnapshot) {
        lock.lock()
        let connectionID = attachedConnectionID
        lock.unlock()
        guard UIApplication.shared.applicationState != .active,
              let connectionID else { return }

        let coordinator = BackgroundAgentCoordinator.shared
        let client = CodegClient(baseURL: baseURL, token: token)
        if let p = snapshot.pendingPermission {
            coordinator.presentPermission(
                client: client,
                connectionID: connectionID,
                requestID: p.requestId,
                toolCall: p.toolCall,
                options: p.options
            )
        }
        if let q = snapshot.pendingQuestion {
            coordinator.presentQuestion(
                client: client,
                connectionID: connectionID,
                questionID: q.questionId,
                questions: q.questions
            )
        }
        if let p = snapshot.pendingPlanApproval {
            coordinator.presentPlanApproval(
                client: client,
                connectionID: connectionID,
                approvalID: p.approvalId,
                planMarkdown: p.planMarkdown
            )
        }
    }

    // MARK: - Helpers

    static func base64URLNoPad(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func websocketURL(from baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = (baseURL.scheme == "https") ? "wss" : "ws"
        components?.path = "/ws/events"
        components?.query = nil
        return components?.url ?? baseURL
    }
}
