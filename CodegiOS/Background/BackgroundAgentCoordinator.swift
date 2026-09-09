import BackgroundTasks
import Foundation
import Network
import UIKit
import UserNotifications

/// Owns the system-facing pieces of a user-started agent turn:
///
/// - iOS 26 continued-processing tasks, so an in-flight agent can keep receiving
///   HTTP/WebSocket traffic after the app moves to the background.
/// - Network-path recovery signals used to accelerate a silent WebSocket retry.
/// - Actionable local notifications for permission/question/plan requests.
///
/// The transport itself stays authoritative. This coordinator deliberately does
/// not turn a background-task expiration into an agent failure: iOS uses the same
/// expiration callback both when a person cancels the system Live Activity and
/// when the OS reclaims resources, and does not expose which reason occurred.
/// Server-side agent cancellation therefore remains an explicit Codeg action.
final class BackgroundAgentCoordinator: NSObject, @unchecked Sendable {
    static let shared = BackgroundAgentCoordinator()

    private struct ActiveTurn {
        var title: String
        var phase: String
        let startedAt: Date
    }

    private enum PendingRequest {
        case permission(client: CodegClient, connectionID: String, requestID: String, options: [PermissionOption], createdAt: Date)
        case question(client: CodegClient, connectionID: String, questionID: String, questions: [QuestionSpec], answers: [QuestionAnswerItem], index: Int, createdAt: Date)
        case plan(client: CodegClient, connectionID: String, approvalID: String, createdAt: Date)
    }

    private let lock = NSLock()
    private let notificationCenter = UNUserNotificationCenter.current()
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "app.codeg.background.network")

    private var activeTurns: [UUID: ActiveTurn] = [:]
    private var pendingRequests: [String: PendingRequest] = [:]
    private var notificationCategories: [String: UNNotificationCategory] = [:]
    private var networkListeners: [UUID: @Sendable () -> Void] = [:]

    private var continuedTask: BGContinuedProcessingTask?
    private var continuedTaskIdentifier: String?
    private var continuedProgressTimer: DispatchSourceTimer?
    private var backgroundedAt: Date?
    private var lastSystemTaskUpdateAt: Date?
    private var lastRenderedTitle: String?
    private var lastRenderedSubtitle: String?
    private var notificationAuthorizationRequested = false
    private var configured = false

    private static let continuedIdentifierPrefix = "app.codeg.ios.continued.agent"
    private static let retryTTL: TimeInterval = 60
    private static let backgroundQuietPeriod: TimeInterval = 60
    private static let systemUpdateDebounce: TimeInterval = 3

    private override init() {
        super.init()
    }

    // MARK: - App setup

    /// Safe to call repeatedly. Notification permission itself is requested lazily
    /// on the first user-started live turn rather than during cold launch.
    func configure() {
        lock.lock()
        let shouldConfigure = !configured
        configured = true
        lock.unlock()
        guard shouldConfigure else { return }

        notificationCenter.delegate = self
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            self?.notifyNetworkRecovered()
        }
        networkMonitor.start(queue: networkQueue)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func applicationDidEnterBackground() {
        lock.lock()
        backgroundedAt = Date()
        lock.unlock()
        // Publish one useful state when the Dynamic Island becomes relevant, then
        // leave it alone for at least a minute so iOS can collapse it naturally.
        updateSystemTaskTitle(force: true)
    }

    @objc private func applicationWillEnterForeground() {
        lock.lock()
        backgroundedAt = nil
        lock.unlock()
    }

    // MARK: - Active turn / continued processing

    @discardableResult
    func beginTurn(title: String = "Codeg", subtitle: String = "Working") -> UUID {
        configure()
        requestNotificationAuthorizationIfNeeded()

        let handle = UUID()
        let startedAt = BackgroundAgentNavigationStore.shared.singleActiveStartedAt() ?? Date()
        lock.lock()
        activeTurns[handle] = ActiveTurn(
            title: title,
            phase: Self.normalizedPhase(subtitle),
            startedAt: startedAt
        )
        let shouldSubmit = continuedTaskIdentifier == nil
        lock.unlock()

        if shouldSubmit { submitContinuedProcessingTask() }
        updateSystemTaskTitle(force: true)
        return handle
    }

    func updateTurn(_ handle: UUID, title: String? = nil, subtitle: String) {
        let nextPhase = Self.normalizedPhase(subtitle)
        var changed = false
        var attention = false
        lock.lock()
        if var turn = activeTurns[handle] {
            if let title, turn.title != title {
                turn.title = title
                changed = true
            }
            let wasAttention = Self.isAttentionPhase(turn.phase)
            if turn.phase != nextPhase {
                turn.phase = nextPhase
                changed = true
            }
            // Entering or leaving an interactive wait is important enough to
            // break the quiet window. Leaving must clear stale "Waiting for
            // confirmation" text immediately after the user responds.
            attention = wasAttention || Self.isAttentionPhase(nextPhase)
            activeTurns[handle] = turn
        }
        lock.unlock()
        guard changed else { return }
        updateSystemTaskTitle(force: attention)
    }

    /// Transport liveness is intentionally not a user-facing Live Activity update.
    /// Token streaming can call this extremely frequently; keeping it a no-op is
    /// what lets the Dynamic Island settle back to compact/minimal presentation.
    func pulseTurn(_ handle: UUID) {
        lock.lock()
        _ = activeTurns[handle]
        lock.unlock()
    }

    /// Session views call this after persisted routing metadata is created or
    /// updated. It lets a newly-created record contribute its original start time
    /// without turning metadata churn into an immediate Dynamic Island expansion.
    func navigationMetadataChanged() {
        updateSystemTaskTitle()
    }

    func endTurn(_ handle: UUID) {
        lock.lock()
        activeTurns.removeValue(forKey: handle)
        let empty = activeTurns.isEmpty
        let task = empty ? continuedTask : nil
        let identifier = empty ? continuedTaskIdentifier : nil
        if empty {
            continuedTask = nil
            continuedTaskIdentifier = nil
            continuedProgressTimer?.cancel()
            continuedProgressTimer = nil
        }
        lock.unlock()

        if let identifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        task?.setTaskCompleted(success: true)
        if !empty { updateSystemTaskTitle() }
    }

    private func submitContinuedProcessingTask() {
        guard UIApplication.shared.applicationState == .active else { return }

        let identifier = "\(Self.continuedIdentifierPrefix).\(UUID().uuidString)"
        let scheduler = BGTaskScheduler.shared
        let registered = scheduler.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            guard let self, let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: true)
                return
            }
            self.didStart(continued, identifier: identifier)
        }
        guard registered else { return }

        lock.lock()
        continuedTaskIdentifier = identifier
        let aggregate = aggregateTitleLocked(now: Date())
        lock.unlock()

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: aggregate.title,
            subtitle: aggregate.subtitle
        )
        // The user-facing work already started in the foreground. If the OS cannot
        // grant continued execution now, fail immediately instead of queueing a
        // stale Live Activity that could appear after the agent has already ended.
        request.strategy = .fail

        do {
            try scheduler.submit(request)
        } catch {
            lock.lock()
            if continuedTaskIdentifier == identifier { continuedTaskIdentifier = nil }
            lock.unlock()
        }
    }

    private func didStart(_ task: BGContinuedProcessingTask, identifier: String) {
        lock.lock()
        guard continuedTaskIdentifier == identifier, !activeTurns.isEmpty else {
            lock.unlock()
            task.setTaskCompleted(success: true)
            return
        }
        continuedTask = task
        // Agent turns have no honest completion percentage. Foundation represents
        // 0/0 as indeterminate progress; the useful user signal is elapsed time
        // plus the current phase in the title/subtitle, not a fake progress bar.
        task.progress.totalUnitCount = 0
        task.progress.completedUnitCount = 0
        lock.unlock()

        // iOS invokes this both for system resource expiration and for a person
        // cancelling the system Live Activity. Because the API does not expose the
        // reason, cancelling the remote agent here could kill a valid server-side
        // turn merely because the phone is under memory/thermal pressure. Treat it
        // as loss of local background ownership only; explicit Codeg Stop remains
        // the operation that calls acp_cancel.
        task.expirationHandler = { [weak self, weak task] in
            guard let self else { return }
            self.lock.lock()
            if self.continuedTaskIdentifier == identifier {
                self.continuedTask = nil
                self.continuedTaskIdentifier = nil
                self.continuedProgressTimer?.cancel()
                self.continuedProgressTimer = nil
            }
            self.lock.unlock()
            task?.setTaskCompleted(success: true)
        }

        startProgressHeartbeat(for: task, identifier: identifier)
        updateSystemTaskTitle()
    }

    private func startProgressHeartbeat(for task: BGContinuedProcessingTask, identifier: String) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        // Elapsed time is intentionally minute-granularity. Updating every token or
        // every second keeps the Dynamic Island visually expanded for no benefit.
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self, weak task] in
            guard let self, task != nil else { return }
            self.lock.lock()
            let valid = self.continuedTaskIdentifier == identifier && !self.activeTurns.isEmpty
            self.lock.unlock()
            guard valid else { return }
            self.updateSystemTaskTitle()
        }
        lock.lock()
        continuedProgressTimer?.cancel()
        continuedProgressTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func updateSystemTaskTitle(force: Bool = false) {
        let now = Date()
        lock.lock()
        guard let task = continuedTask else { lock.unlock(); return }
        let aggregate = aggregateTitleLocked(now: now)
        let duplicate = aggregate.title == lastRenderedTitle && aggregate.subtitle == lastRenderedSubtitle
        let inBackgroundQuietPeriod = backgroundedAt.map {
            now.timeIntervalSince($0) < Self.backgroundQuietPeriod
        } ?? false
        let tooSoon = lastSystemTaskUpdateAt.map {
            now.timeIntervalSince($0) < Self.systemUpdateDebounce
        } ?? false

        if !force && (duplicate || inBackgroundQuietPeriod || tooSoon) {
            lock.unlock()
            return
        }
        lastRenderedTitle = aggregate.title
        lastRenderedSubtitle = aggregate.subtitle
        lastSystemTaskUpdateAt = now
        lock.unlock()
        task.updateTitle(aggregate.title, subtitle: aggregate.subtitle)
    }

    private func aggregateTitleLocked(now: Date) -> (title: String, subtitle: String) {
        if activeTurns.count > 1 {
            return ("Codeg", "\(activeTurns.count) agent tasks are running")
        }
        if let only = activeTurns.values.first {
            // The navigation store is created by the session UI and can become
            // available just after the transport starts. Prefer its persisted
            // timestamp so elapsed time survives process recreation and never
            // depends on EventStream/view callback ordering.
            let startedAt = BackgroundAgentNavigationStore.shared.singleActiveStartedAt(now: now)
                ?? only.startedAt
            return (
                only.title,
                "\(only.phase) · \(Self.elapsedText(from: startedAt, now: now))"
            )
        }
        return ("Codeg", "Agent task")
    }

    private static func normalizedPhase(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "…", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()
        if lower.contains("waiting for permission")
            || lower.contains("waiting for your answer")
            || lower.contains("waiting for plan approval") {
            return "Waiting for confirmation"
        }
        if lower.contains("keeping the agent connected") || lower.contains("restoring") {
            return "Restoring connection"
        }
        if lower == "running in the background" || lower == "agent is working" {
            return "Working"
        }
        return cleaned.isEmpty ? "Working" : cleaned
    }

    private static func isAttentionPhase(_ phase: String) -> Bool {
        phase.lowercased().contains("waiting for confirmation")
    }

    private static func elapsedText(from startedAt: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(startedAt))
        guard seconds >= 60 else { return "Elapsed <1 min" }
        let minutes = max(1, Int(seconds / 60))
        return "Elapsed \(minutes) min"
    }

    // MARK: - Network path recovery

    func addNetworkRecoveryListener(_ listener: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        networkListeners[id] = listener
        lock.unlock()
        return id
    }

    func removeNetworkRecoveryListener(_ id: UUID) {
        lock.lock()
        networkListeners.removeValue(forKey: id)
        lock.unlock()
    }

    private func notifyNetworkRecovered() {
        lock.lock()
        let listeners = Array(networkListeners.values)
        lock.unlock()
        listeners.forEach { $0() }
    }

    // MARK: - Interactive notifications

    func presentPermission(
        client: CodegClient,
        connectionID: String,
        requestID: String,
        toolCall: AnyJSON,
        options: [PermissionOption]
    ) {
        guard !requestID.isEmpty else { return }
        let key = "permission:\(requestID)"
        lock.lock()
        pendingRequests[key] = .permission(
            client: client,
            connectionID: connectionID,
            requestID: requestID,
            options: options,
            createdAt: Date()
        )
        lock.unlock()

        let parsed = ParsedPermission.parse(toolCall)
        let allowOnce = options.first { $0.kind.lowercased() == "allow_once" }
            ?? options.first { !$0.isReject && $0.kind.lowercased() != "allow_always" }
        let reject = options.first { $0.isReject }
        let allowAlways = options.first { $0.kind.lowercased() == "allow_always" }

        var actions: [UNNotificationAction] = []
        if let allowOnce {
            actions.append(UNNotificationAction(
                identifier: "codeg.permission.apply|\(requestID)|\(allowOnce.optionId)",
                title: allowOnce.name.isEmpty ? "Allow Once" : allowOnce.name,
                options: []
            ))
        }
        if let reject {
            actions.append(UNNotificationAction(
                identifier: "codeg.permission.apply|\(requestID)|\(reject.optionId)",
                title: reject.name.isEmpty ? "Reject" : reject.name,
                options: [.destructive]
            ))
        }
        if let allowAlways {
            actions.append(UNNotificationAction(
                identifier: "codeg.permission.confirmAlways|\(requestID)|\(allowAlways.optionId)",
                title: allowAlways.name.isEmpty ? "Always Allow" : allowAlways.name,
                options: []
            ))
        }

        let categoryID = "CODEG_PERMISSION_\(requestID)"
        registerCategory(identifier: categoryID, actions: actions)
        let body = parsed.command ?? parsed.planMarkdown ?? parsed.prompt ?? parsed.title
        scheduleNotification(
            identifier: key,
            title: parsed.isPlan ? "Codeg plan needs approval" : "Codeg needs permission",
            body: body,
            categoryID: categoryID
        )
    }

    func resolvePermissionNotification(requestID: String) {
        resolvePending(key: "permission:\(requestID)")
    }

    func presentQuestion(
        client: CodegClient,
        connectionID: String,
        questionID: String,
        questions: [QuestionSpec]
    ) {
        guard !questionID.isEmpty, !questions.isEmpty else { return }
        let key = "question:\(questionID)"
        lock.lock()
        pendingRequests[key] = .question(
            client: client,
            connectionID: connectionID,
            questionID: questionID,
            questions: questions,
            answers: [],
            index: 0,
            createdAt: Date()
        )
        lock.unlock()
        scheduleQuestionStep(key: key)
    }

    func resolveQuestionNotification(questionID: String) {
        resolvePending(key: "question:\(questionID)")
    }

    func presentPlanApproval(
        client: CodegClient,
        connectionID: String,
        approvalID: String,
        planMarkdown: String
    ) {
        guard !approvalID.isEmpty else { return }
        let key = "plan:\(approvalID)"
        lock.lock()
        pendingRequests[key] = .plan(
            client: client,
            connectionID: connectionID,
            approvalID: approvalID,
            createdAt: Date()
        )
        lock.unlock()

        let actions: [UNNotificationAction] = [
            UNNotificationAction(identifier: "codeg.plan.approve|\(approvalID)", title: "Approve", options: []),
            UNNotificationAction(identifier: "codeg.plan.abandon|\(approvalID)", title: "Abandon", options: [.destructive]),
            UNTextInputNotificationAction(
                identifier: "codeg.plan.changes|\(approvalID)",
                title: "Request Changes",
                options: [],
                textInputButtonTitle: "Send",
                textInputPlaceholder: "What should change?"
            )
        ]
        let categoryID = "CODEG_PLAN_\(approvalID)"
        registerCategory(identifier: categoryID, actions: actions)
        scheduleNotification(
            identifier: key,
            title: "Codeg plan ready for review",
            body: planMarkdown.isEmpty ? "The agent is waiting for a plan decision." : planMarkdown,
            categoryID: categoryID
        )
    }

    func resolvePlanNotification(approvalID: String) {
        resolvePending(key: "plan:\(approvalID)")
    }

    func notifyTurnCompleted() {
        scheduleNotification(
            identifier: "turn-complete:\(UUID().uuidString)",
            title: "Codeg task completed",
            body: "The agent finished its reply.",
            categoryID: ""
        )
    }

    func notifyTurnFailed(_ message: String) {
        scheduleNotification(
            identifier: "turn-failed:\(UUID().uuidString)",
            title: "Codeg task needs attention",
            body: message,
            categoryID: ""
        )
    }

    private func scheduleQuestionStep(key: String) {
        lock.lock()
        guard case .question(_, _, let questionID, let questions, _, let index, _)? = pendingRequests[key],
              questions.indices.contains(index) else {
            lock.unlock()
            return
        }
        let question = questions[index]
        lock.unlock()

        var actions: [UNNotificationAction] = question.options.prefix(3).map { option in
            UNNotificationAction(
                identifier: "codeg.question.option|\(questionID)|\(index)|\(option.label)",
                title: option.label,
                options: []
            )
        }
        actions.append(UNTextInputNotificationAction(
            identifier: "codeg.question.text|\(questionID)|\(index)",
            title: "Other…",
            options: [],
            textInputButtonTitle: "Answer",
            textInputPlaceholder: "Type an answer"
        ))

        let categoryID = "CODEG_QUESTION_\(questionID)_\(index)"
        registerCategory(identifier: categoryID, actions: actions)
        scheduleNotification(
            identifier: key,
            title: question.header.isEmpty ? "Codeg has a question" : question.header,
            body: question.question,
            categoryID: categoryID
        )
    }

    private func resolvePending(key: String) {
        lock.lock()
        pendingRequests.removeValue(forKey: key)
        lock.unlock()
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [key])
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [key])
    }

    private func registerCategory(identifier: String, actions: [UNNotificationAction]) {
        guard !identifier.isEmpty else { return }
        let category = UNNotificationCategory(
            identifier: identifier,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        lock.lock()
        notificationCategories[identifier] = category
        let all = Set(notificationCategories.values)
        lock.unlock()
        notificationCenter.setNotificationCategories(all)
    }

    private func requestNotificationAuthorizationIfNeeded() {
        lock.lock()
        let shouldRequest = !notificationAuthorizationRequested
        notificationAuthorizationRequested = true
        lock.unlock()
        guard shouldRequest else { return }
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func scheduleNotification(identifier: String, title: String, body: String, categoryID: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(1200))
        if !categoryID.isEmpty { content.categoryIdentifier = categoryID }
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        notificationCenter.add(request) { _ in }
    }

    // MARK: - Notification action execution

    private func handleNotificationResponse(_ response: UNNotificationResponse) async {
        let id = response.actionIdentifier
        if id.hasPrefix("codeg.permission.apply|") {
            let parts = id.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return }
            await applyPermission(requestID: parts[1], optionID: parts[2])
        } else if id.hasPrefix("codeg.permission.confirmAlways|") {
            let parts = id.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return }
            presentAlwaysAllowConfirmation(requestID: parts[1], optionID: parts[2])
        } else if id.hasPrefix("codeg.permission.always|") {
            let parts = id.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return }
            await applyPermission(requestID: parts[1], optionID: parts[2])
        } else if id.hasPrefix("codeg.question.option|") {
            let parts = id.split(separator: "|", maxSplits: 3).map(String.init)
            guard parts.count == 4, let index = Int(parts[2]) else { return }
            await answerQuestionStep(questionID: parts[1], index: index, labels: [parts[3]])
        } else if id.hasPrefix("codeg.question.text|") {
            let parts = id.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3, let index = Int(parts[2]),
                  let textResponse = response as? UNTextInputNotificationResponse else { return }
            let text = textResponse.userText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            await answerQuestionStep(questionID: parts[1], index: index, labels: [text])
        } else if id.hasPrefix("codeg.plan.approve|") {
            let approvalID = String(id.dropFirst("codeg.plan.approve|".count))
            await answerPlan(approvalID: approvalID, decision: .approve, feedback: nil)
        } else if id.hasPrefix("codeg.plan.abandon|") {
            let approvalID = String(id.dropFirst("codeg.plan.abandon|".count))
            await answerPlan(approvalID: approvalID, decision: .abandon, feedback: nil)
        } else if id.hasPrefix("codeg.plan.changes|") {
            let approvalID = String(id.dropFirst("codeg.plan.changes|".count))
            guard let textResponse = response as? UNTextInputNotificationResponse else { return }
            let feedback = textResponse.userText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !feedback.isEmpty else { return }
            await answerPlan(approvalID: approvalID, decision: .requestChanges, feedback: feedback)
        }
    }

    private func presentAlwaysAllowConfirmation(requestID: String, optionID: String) {
        let action = UNNotificationAction(
            identifier: "codeg.permission.always|\(requestID)|\(optionID)",
            title: "Confirm Always Allow",
            options: []
        )
        let categoryID = "CODEG_ALWAYS_CONFIRM_\(requestID)"
        registerCategory(identifier: categoryID, actions: [action])
        scheduleNotification(
            identifier: "permission-confirm:\(requestID)",
            title: "Always allow this operation?",
            body: "This changes the agent permission policy for future matching operations.",
            categoryID: categoryID
        )
    }

    private func applyPermission(requestID: String, optionID: String) async {
        let key = "permission:\(requestID)"
        lock.lock()
        guard case .permission(let client, let connectionID, _, let options, _)? = pendingRequests[key],
              options.contains(where: { $0.optionId == optionID }) else {
            lock.unlock()
            notifyExpiredRequest()
            return
        }
        lock.unlock()

        let success = await retryTransientForOneMinute {
            try await client.respondPermission(connectionId: connectionID, requestId: requestID, optionId: optionID)
        }
        if success { resolvePending(key: key) }
        else { notifyActionNotDelivered() }
    }

    private func answerQuestionStep(questionID: String, index: Int, labels: [String]) async {
        let key = "question:\(questionID)"
        lock.lock()
        guard case .question(let client, let connectionID, _, let questions, var answers, let current, let createdAt)? = pendingRequests[key],
              current == index, questions.indices.contains(index) else {
            lock.unlock()
            notifyExpiredRequest()
            return
        }
        let question = questions[index]
        answers.append(QuestionAnswerItem(questionId: question.id, labels: labels))
        let next = index + 1
        if questions.indices.contains(next) {
            pendingRequests[key] = .question(
                client: client,
                connectionID: connectionID,
                questionID: questionID,
                questions: questions,
                answers: answers,
                index: next,
                createdAt: createdAt
            )
            lock.unlock()
            scheduleQuestionStep(key: key)
            return
        }
        lock.unlock()

        let answer = QuestionAnswer(answers: answers, declined: false)
        let success = await retryTransientForOneMinute {
            try await client.answerQuestion(connectionId: connectionID, questionId: questionID, answer: answer)
        }
        if success { resolvePending(key: key) }
        else { notifyActionNotDelivered() }
    }

    private func answerPlan(approvalID: String, decision: PlanApprovalDecision, feedback: String?) async {
        let key = "plan:\(approvalID)"
        lock.lock()
        guard case .plan(let client, let connectionID, _, _)? = pendingRequests[key] else {
            lock.unlock()
            notifyExpiredRequest()
            return
        }
        lock.unlock()

        let success = await retryTransientForOneMinute {
            try await client.answerPlanApproval(
                connectionId: connectionID,
                approvalId: approvalID,
                decision: decision,
                feedback: feedback
            )
        }
        if success { resolvePending(key: key) }
        else { notifyActionNotDelivered() }
    }

    private func retryTransientForOneMinute(_ operation: @escaping @Sendable () async throws -> Void) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.retryTTL)
        var delay: UInt64 = 500
        while true {
            do {
                try await operation()
                return true
            } catch let error as APIError where error.isTransient && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(Int(delay)))
                delay = min(delay * 2, 8_000)
            } catch {
                return false
            }
        }
    }

    private func notifyExpiredRequest() {
        scheduleNotification(
            identifier: "request-expired:\(UUID().uuidString)",
            title: "Codeg request is no longer active",
            body: "The approval may already have been handled from another client.",
            categoryID: ""
        )
    }

    private func notifyActionNotDelivered() {
        scheduleNotification(
            identifier: "action-failed:\(UUID().uuidString)",
            title: "Codeg could not send the action",
            body: "Open Codeg to review the latest agent state before trying again.",
            categoryID: ""
        )
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension BackgroundAgentCoordinator: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { [weak self] in
            await self?.handleNotificationResponse(response)
            completionHandler()
        }
    }
}
