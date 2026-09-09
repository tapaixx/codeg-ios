from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count} for:\n{old[:160]}")
    p.write_text(text.replace(old, new, 1))


# BackgroundAgentCoordinator: elapsed-time semantics, low-frequency updates,
# indeterminate progress, and a quiet window after entering the background.
path = "CodegiOS/Background/BackgroundAgentCoordinator.swift"
replace_once(path,
'''    private struct ActiveTurn {
        var title: String
        var subtitle: String
    }
''',
'''    private struct ActiveTurn {
        var title: String
        var phase: String
        let startedAt: Date
    }
''')

replace_once(path,
'''    private var continuedTask: BGContinuedProcessingTask?
    private var continuedTaskIdentifier: String?
    private var continuedProgressTimer: DispatchSourceTimer?
    private var notificationAuthorizationRequested = false
    private var configured = false

    private static let continuedIdentifierPrefix = "app.codeg.ios.continued.agent"
    private static let retryTTL: TimeInterval = 60
''',
'''    private var continuedTask: BGContinuedProcessingTask?
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
''')

replace_once(path,
'''        networkMonitor.start(queue: networkQueue)
    }

    // MARK: - Active turn / continued processing
''',
'''        networkMonitor.start(queue: networkQueue)

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
''')

replace_once(path,
'''    @discardableResult
    func beginTurn(title: String = "Codeg agent is working", subtitle: String = "Running in the background") -> UUID {
        configure()
        requestNotificationAuthorizationIfNeeded()

        let handle = UUID()
        lock.lock()
        activeTurns[handle] = ActiveTurn(title: title, subtitle: subtitle)
        let shouldSubmit = continuedTaskIdentifier == nil
        lock.unlock()

        if shouldSubmit { submitContinuedProcessingTask() }
        updateSystemTaskTitle()
        return handle
    }

    func updateTurn(_ handle: UUID, title: String? = nil, subtitle: String) {
        lock.lock()
        if var turn = activeTurns[handle] {
            if let title { turn.title = title }
            turn.subtitle = subtitle
            activeTurns[handle] = turn
        }
        lock.unlock()
        updateSystemTaskTitle()
        pulseProgress()
    }

    func pulseTurn(_ handle: UUID) {
        lock.lock()
        let exists = activeTurns[handle] != nil
        lock.unlock()
        if exists { pulseProgress() }
    }
''',
'''    @discardableResult
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
            if turn.phase != nextPhase {
                turn.phase = nextPhase
                changed = true
            }
            attention = Self.isAttentionPhase(nextPhase)
            activeTurns[handle] = turn
        }
        lock.unlock()
        guard changed else { return }
        // Permission/question/plan waits are the only phase transitions allowed
        // to break the post-background quiet window; they need the user's action.
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
''')

replace_once(path,
'''        lock.lock()
        continuedTaskIdentifier = identifier
        let aggregate = aggregateTitleLocked()
        lock.unlock()
''',
'''        lock.lock()
        continuedTaskIdentifier = identifier
        let aggregate = aggregateTitleLocked(now: Date())
        lock.unlock()
''')

replace_once(path,
'''        continuedTask = task
        task.progress.totalUnitCount = 1_000_000
        task.progress.completedUnitCount = 1
        lock.unlock()
''',
'''        continuedTask = task
        // Agent turns have no honest completion percentage. Foundation represents
        // 0/0 as indeterminate progress; the useful user signal is elapsed time
        // plus the current phase in the title/subtitle, not a fake progress bar.
        task.progress.totalUnitCount = 0
        task.progress.completedUnitCount = 0
        lock.unlock()
''')

old_block = '''    private func startProgressHeartbeat(for task: BGContinuedProcessingTask, identifier: String) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self, weak task] in
            guard let self, let task else { return }
            self.lock.lock()
            let valid = self.continuedTaskIdentifier == identifier && !self.activeTurns.isEmpty
            self.lock.unlock()
            guard valid else { return }
            // Agent turns do not have a meaningful percent complete. Advancing a
            // very large progress range represents liveness without pretending the
            // UI knows how much work remains, and prevents a healthy quiet tool run
            // from looking stalled to the scheduler.
            let next = min(task.progress.completedUnitCount + 1, task.progress.totalUnitCount - 1)
            task.progress.completedUnitCount = next
        }
        lock.lock()
        continuedProgressTimer?.cancel()
        continuedProgressTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func pulseProgress() {
        lock.lock()
        let task = continuedTask
        lock.unlock()
        guard let task else { return }
        task.progress.completedUnitCount = min(task.progress.completedUnitCount + 1, task.progress.totalUnitCount - 1)
    }

    private func updateSystemTaskTitle() {
        lock.lock()
        let task = continuedTask
        let aggregate = aggregateTitleLocked()
        lock.unlock()
        task?.updateTitle(aggregate.title, subtitle: aggregate.subtitle)
    }

    private func aggregateTitleLocked() -> (title: String, subtitle: String) {
        if activeTurns.count > 1 {
            return ("Codeg", "\\(activeTurns.count) agent tasks are running")
        }
        if let only = activeTurns.values.first {
            return (only.title, only.subtitle)
        }
        return ("Codeg", "Agent task")
    }
'''
new_block = '''    private func startProgressHeartbeat(for task: BGContinuedProcessingTask, identifier: String) {
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
            return ("Codeg", "\\(activeTurns.count) agent tasks are running")
        }
        if let only = activeTurns.values.first {
            return (
                only.title,
                "\\(only.phase) · \\(Self.elapsedText(from: only.startedAt, now: now))"
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
        return "Elapsed \\(minutes) min"
    }
'''
replace_once(path, old_block, new_block)

# EventStream: transport health and token deltas must not repeatedly rewrite the
# system Live Activity. Keep only meaningful phase changes.
path = "CodegiOS/Networking/EventStream.swift"
replace_once(path,
'''        if let handle {
            BackgroundAgentCoordinator.shared.updateTurn(handle, subtitle: "Agent is working")
            BackgroundAgentCoordinator.shared.pulseTurn(handle)
        }
''',
'''        if let handle {
            BackgroundAgentCoordinator.shared.pulseTurn(handle)
        }
''')

replace_once(path,
'''        case .contentDelta, .thinking:
            if let backgroundHandle {
                coordinator.updateTurn(backgroundHandle, subtitle: "Generating reply…")
            }
''',
'''        case .contentDelta, .thinking:
            // Token/thinking deltas are intentionally silent at the system UI
            // layer. Updating the Live Activity for every streamed frame keeps the
            // Dynamic Island expanded and communicates no meaningful new state.
            break
''')

replace_once(path,
'''        case .toolCallUpdate(_, let title, _, _, _, _, _, _):
            if let backgroundHandle, let title, !title.isEmpty {
                coordinator.updateTurn(backgroundHandle, subtitle: "Running \\(title)…")
            }
''',
'''        case .toolCallUpdate:
            // Tool updates are often high frequency. The initial toolCall event is
            // enough to publish the phase; completion naturally moves on when the
            // next meaningful event arrives.
            break
''')

# SessionDetailView: bind visible session identity to the persisted navigation
# store independently from transport internals.
path = "CodegiOS/Features/SessionDetail/SessionDetailView.swift"
replace_once(path,
'''    @State private var showDeleteConfirm = false
''',
'''    @State private var showDeleteConfirm = false
    @State private var backgroundNavigationHandle: UUID?
''')

replace_once(path,
'''        .task { await model.load() }
        .onDisappear { model.teardown() }
''',
'''        .task { await model.load() }
        .onChange(of: model.isInFlight, initial: true) { _, inFlight in
            syncBackgroundNavigation(inFlight: inFlight)
        }
        .onChange(of: model.conversationID) { _, _ in
            updateBackgroundNavigation()
        }
        .onDisappear { model.teardown() }
''')

replace_once(path,
'''    private var content: some View {
''',
'''    private func syncBackgroundNavigation(inFlight: Bool) {
        let store = BackgroundAgentNavigationStore.shared
        if inFlight {
            if let handle = backgroundNavigationHandle {
                store.updateTask(handle, conversationID: model.conversationID, newSession: model.newRequest)
            } else {
                backgroundNavigationHandle = store.beginTask(
                    serverID: server.id,
                    conversationID: model.conversationID,
                    newSession: model.newRequest
                )
            }
            BackgroundAgentCoordinator.shared.navigationMetadataChanged()
        } else if let handle = backgroundNavigationHandle {
            store.finishTask(handle)
            backgroundNavigationHandle = nil
            BackgroundAgentCoordinator.shared.navigationMetadataChanged()
        }
    }

    private func updateBackgroundNavigation() {
        guard let handle = backgroundNavigationHandle else { return }
        BackgroundAgentNavigationStore.shared.updateTask(
            handle,
            conversationID: model.conversationID,
            newSession: model.newRequest
        )
        BackgroundAgentCoordinator.shared.navigationMetadataChanged()
    }

    private var content: some View {
''')

# AppModel: resolve a launch from the system Live Activity into the owning server
# and conversation/new-session route. Multi-task taps go to Activity.
path = "CodegiOS/App/AppModel.swift"
insert_anchor = '''    // MARK: - Routing

    /// Open a destination from any entry point. Compact pushes onto the current
'''
insert = '''    // MARK: - Routing

    /// The system-owned continued-processing Live Activity has no custom URL, so
    /// iOS launches Codeg with NSUserActivityTypeLiveActivity. Resolve the task
    /// from our lightweight persisted routing hints instead of hijacking normal
    /// app-icon/App-Switcher foregrounding.
    func handleLiveActivityLaunch() {
        let store = BackgroundAgentNavigationStore.shared
        guard let destination = store.launchDestination() else { return }

        switch destination {
        case .activity:
            openActivityRoot()

        case .newSession(let recordID, let serverID, let request):
            guard serverStore.servers.contains(where: { $0.id == serverID }) else {
                store.invalidate(recordID)
                openActivityRoot()
                return
            }
            openLiveActivityRoute(.newSession(request), serverID: serverID)

        case .conversation(let recordID, let serverID, let conversationID):
            guard let server = serverStore.servers.first(where: { $0.id == serverID }) else {
                store.invalidate(recordID)
                openActivityRoot()
                return
            }
            guard let client = serverStore.client(for: server) else {
                openLiveActivityRoute(.conversation(conversationID), serverID: serverID)
                return
            }

            // Validate when possible. A definite 404/not-found invalidates the
            // stale hint; transient network/auth failures still open the recorded
            // conversation because the local hint may be perfectly valid offline.
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await client.conversationDetail(id: conversationID)
                } catch {
                    let description = String(describing: error).lowercased()
                    if description.contains("404") || description.contains("not found") {
                        store.invalidate(recordID)
                        self.openActivityRoot()
                        return
                    }
                }
                self.openLiveActivityRoute(.conversation(conversationID), serverID: serverID)
            }
        }
    }

    private func openLiveActivityRoute(_ route: Route, serverID: ServerProfile.ID) {
        if selectedServerID != serverID { selectedServerID = serverID }
        if isCompact {
            selectedTab = .chats
            paths[.chats] = [route]
        } else {
            sidebarSection = .chats
            contentPath = []
            open(route)
        }
    }

    private func openActivityRoot() {
        if isCompact {
            selectedTab = .activity
            paths[.activity] = []
        } else {
            sidebarSection = .activity
            contentPath = []
        }
    }

    /// Open a destination from any entry point. Compact pushes onto the current
'''
replace_once(path, insert_anchor, insert)

# RootView: handle only explicit taps on a no-URL system Live Activity.
path = "CodegiOS/App/RootView.swift"
replace_once(path, 'import SwiftUI\n', 'import SwiftUI\nimport WidgetKit\n')
replace_once(path,
'''        .onOpenURL { model.handle(url: $0) }
''',
'''        .onOpenURL { model.handle(url: $0) }
        .onContinueUserActivity(NSUserActivityTypeLiveActivity) { _ in
            model.handleLiveActivityLaunch()
        }
''')

# Version / release tag.
path = "project.yml"
replace_once(path, '        CURRENT_PROJECT_VERSION: "5"\n', '        CURRENT_PROJECT_VERSION: "6"\n')

path = ".github/workflows/unsigned-ipa.yml"
replace_once(path, '          TAG: v1.0.1-tapaixx.3\n', '          TAG: v1.0.1-tapaixx.4\n')
replace_once(path,
'''          ## Codeg iOS ${VERSION} (${BUILD}) — tapaixx WebSocket bearer-auth hotfix
''',
'''          ## Codeg iOS ${VERSION} (${BUILD}) — tapaixx Live Activity UX update
''')
# Remove shell-command-substitution-prone backticks from release-note bullets if
# they are present in this fork's heredoc.
p = Path(path)
text = p.read_text()
text = text.replace('`Authorization: Bearer <token>`', 'Authorization: Bearer <token>')
text = text.replace('`codeg-events`', 'codeg-events')
old_notes = '''          - Trims surrounding whitespace/newlines from the WebSocket token before authentication.
          - Keeps transparent post-attach reconnect, event replay, continued processing, and actionable background notifications.
          - Preserves HTTP status diagnostics for failed WebSocket handshakes.
'''
new_notes = '''          - Trims surrounding whitespace/newlines from the WebSocket token before authentication.
          - Shows elapsed task time and meaningful phases instead of pretending an agent has a known completion percentage.
          - Throttles system Live Activity updates so the Dynamic Island can collapse naturally after backgrounding.
          - Tapping the system Live Activity routes to the active conversation/new task; multi-task taps open Activity.
          - Persists only non-sensitive routing/timing hints for launch restoration.
          - Keeps transparent post-attach reconnect, event replay, continued processing, and actionable background notifications.
'''
if old_notes not in text:
    raise SystemExit(f"{path}: release-note anchor not found")
p.write_text(text.replace(old_notes, new_notes, 1))

# Changelog.
path = "CHANGELOG.md"
p = Path(path)
text = p.read_text()
anchor = '''- iOS background coordination now starts only after the WebSocket server has
  completed the initial upgrade and the client begins its attach handshake.
'''
addition = anchor + '''- Continued-processing Live Activity updates are now state-based and minute-
  granularity, showing elapsed time instead of continuously advancing a fake
  completion percentage.
- Tapping the system Live Activity now restores the owning server/session using
  lightweight persisted routing hints; ordinary app foregrounding remains unchanged.
'''
if anchor not in text:
    raise SystemExit(f"{path}: changelog anchor not found")
p.write_text(text.replace(anchor, addition, 1))

# Accepted design doc.
path = "docs/background-agent-ux.md"
p = Path(path)
text = p.read_text()
anchor = '''For multiple simultaneous local streams, show aggregate task wording rather than treating each WebSocket reconnect as a new activity.
'''
addition = anchor + '''
### Dynamic Island update and navigation policy

The system continued-processing Live Activity is intentionally low-frequency. Agent work has no honest completion percentage, so its `Progress` is indeterminate and the user-facing subtitle carries phase plus wall-clock elapsed time (for example, `Running a tool · Elapsed 4 min`). The first minute is shown as `<1 min`; multiple simultaneous tasks show only an aggregate task count.

Token/thinking deltas and repeated tool updates never rewrite the system title. Entering the background publishes one state, followed by at least a 60-second quiet window; normal elapsed-time refreshes are minute-granularity. Permission/question/plan waits may break the quiet window because they require user action. Task completion ends the continued-processing task immediately. iOS ultimately controls Dynamic Island compact/minimal/expanded presentation, so Codeg reduces update pressure rather than pretending it can force a collapse.

Because the system-owned continued-processing Live Activity does not expose a custom per-task `widgetURL`, a tap launches Codeg using `NSUserActivityTypeLiveActivity`. Codeg persists only non-sensitive navigation/timing hints (`serverID`, conversation or new-session identity, and `startedAt`). A single active task opens its owning server/session, multiple tasks open Activity, and a just-finished task remains routable for approximately two minutes to cover tap/completion races. App-icon launches and ordinary App Switcher foregrounding do not auto-navigate.
'''
if anchor not in text:
    raise SystemExit(f"{path}: design-doc anchor not found")
p.write_text(text.replace(anchor, addition, 1))

print("Live Activity UX patch applied successfully")
