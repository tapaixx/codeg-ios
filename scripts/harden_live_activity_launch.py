from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}")
    p.write_text(text.replace(old, new, 1))

replace_once(
    "CodegiOS/App/RootView.swift",
    '''        .onContinueUserActivity(NSUserActivityTypeLiveActivity) { _ in\n            model.handleLiveActivityLaunch()\n        }\n''',
    '''        .onContinueUserActivity(NSUserActivityTypeLiveActivity) { _ in\n            // A cold Live Activity launch can arrive before the initial\n            // horizontal-size onChange callback. Resolve the shell width here so\n            // an iPhone tap can never be routed through the iPad selection path.\n            model.isCompact = horizontalSizeClass == .compact\n            model.handleLiveActivityLaunch()\n        }\n'''
)

replace_once(
    "CodegiOS/App/AppModel.swift",
    '''            guard let client = serverStore.client(for: server) else {\n                openLiveActivityRoute(.conversation(conversationID), serverID: serverID)\n                return\n            }\n\n            // Validate when possible. A definite 404/not-found invalidates the\n            // stale hint; transient network/auth failures still open the recorded\n            // conversation because the local hint may be perfectly valid offline.\n            Task { [weak self] in\n                guard let self else { return }\n                do {\n                    _ = try await client.conversationDetail(id: conversationID)\n                } catch {\n                    let description = String(describing: error).lowercased()\n                    if description.contains("404") || description.contains("not found") {\n                        store.invalidate(recordID)\n                        self.openActivityRoot()\n                        return\n                    }\n                }\n                self.openLiveActivityRoute(.conversation(conversationID), serverID: serverID)\n            }\n''',
    '''            // The persisted record is deliberately a navigation hint. Honor\n            // the user's tap immediately instead of blocking navigation on a\n            // network round-trip; validate in the background and only unwind a\n            // destination when the server definitively says it no longer exists.\n            openLiveActivityRoute(.conversation(conversationID), serverID: serverID)\n            guard let client = serverStore.client(for: server) else { return }\n\n            Task { [weak self] in\n                guard let self else { return }\n                do {\n                    _ = try await client.conversationDetail(id: conversationID)\n                } catch {\n                    let description = String(describing: error).lowercased()\n                    if description.contains("404") || description.contains("not found") {\n                        store.invalidate(recordID)\n                        self.openActivityRoot()\n                    }\n                }\n            }\n'''
)

replace_once(
    "CodegiOS/Background/BackgroundAgentCoordinator.swift",
    '''        if let only = activeTurns.values.first {\n            return (\n                only.title,\n                "\\(only.phase) · \\(Self.elapsedText(from: only.startedAt, now: now))"\n            )\n        }\n''',
    '''        if let only = activeTurns.values.first {\n            // The navigation store is created by the session UI and can become\n            // available just after the transport starts. Prefer its persisted\n            // timestamp so elapsed time survives process recreation and never\n            // depends on EventStream/view callback ordering.\n            let startedAt = BackgroundAgentNavigationStore.shared.singleActiveStartedAt(now: now)\n                ?? only.startedAt\n            return (\n                only.title,\n                "\\(only.phase) · \\(Self.elapsedText(from: startedAt, now: now))"\n            )\n        }\n'''
)

print("Live Activity launch hardening applied")
