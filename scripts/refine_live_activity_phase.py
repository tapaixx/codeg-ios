from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected 1 match, found {count}")
    p.write_text(text.replace(old, new, 1))

replace_once(
    "CodegiOS/Networking/EventStream.swift",
    '''        case .contentDelta, .thinking:\n            // Token/thinking deltas are intentionally silent at the system UI\n            // layer. Updating the Live Activity for every streamed frame keeps the\n            // Dynamic Island expanded and communicates no meaningful new state.\n            break\n''',
    '''        case .contentDelta, .thinking:\n            // This is a phase signal, not a per-token system update. The\n            // coordinator de-duplicates an unchanged "Generating reply" phase, so\n            // only the first delta after another phase (for example a tool or\n            // approval) can rewrite the Live Activity.\n            if let backgroundHandle {\n                coordinator.updateTurn(backgroundHandle, subtitle: "Generating reply…")\n            }\n'''
)

for label, call in [
    (
        '''        case .permissionResolved(let requestID):\n            coordinator.resolvePermissionNotification(requestID: requestID)\n''',
        '''        case .permissionResolved(let requestID):\n            coordinator.resolvePermissionNotification(requestID: requestID)\n            if let backgroundHandle { coordinator.updateTurn(backgroundHandle, subtitle: "Working") }\n'''
    ),
    (
        '''        case .questionResolved(let questionID):\n            coordinator.resolveQuestionNotification(questionID: questionID)\n''',
        '''        case .questionResolved(let questionID):\n            coordinator.resolveQuestionNotification(questionID: questionID)\n            if let backgroundHandle { coordinator.updateTurn(backgroundHandle, subtitle: "Working") }\n'''
    ),
    (
        '''        case .planApprovalResolved(let approvalID):\n            coordinator.resolvePlanNotification(approvalID: approvalID)\n''',
        '''        case .planApprovalResolved(let approvalID):\n            coordinator.resolvePlanNotification(approvalID: approvalID)\n            if let backgroundHandle { coordinator.updateTurn(backgroundHandle, subtitle: "Working") }\n'''
    )
]:
    replace_once("CodegiOS/Networking/EventStream.swift", label, call)

replace_once(
    "CodegiOS/Background/BackgroundAgentCoordinator.swift",
    '''        if var turn = activeTurns[handle] {\n            if let title, turn.title != title {\n                turn.title = title\n                changed = true\n            }\n            if turn.phase != nextPhase {\n                turn.phase = nextPhase\n                changed = true\n            }\n            attention = Self.isAttentionPhase(nextPhase)\n            activeTurns[handle] = turn\n        }\n        lock.unlock()\n        guard changed else { return }\n        // Permission/question/plan waits are the only phase transitions allowed\n        // to break the post-background quiet window; they need the user's action.\n        updateSystemTaskTitle(force: attention)\n''',
    '''        if var turn = activeTurns[handle] {\n            if let title, turn.title != title {\n                turn.title = title\n                changed = true\n            }\n            let wasAttention = Self.isAttentionPhase(turn.phase)\n            if turn.phase != nextPhase {\n                turn.phase = nextPhase\n                changed = true\n            }\n            // Entering or leaving an interactive wait is important enough to\n            // break the quiet window. Leaving must clear stale "Waiting for\n            // confirmation" text immediately after the user responds.\n            attention = wasAttention || Self.isAttentionPhase(nextPhase)\n            activeTurns[handle] = turn\n        }\n        lock.unlock()\n        guard changed else { return }\n        updateSystemTaskTitle(force: attention)\n'''
)

print("phase refinement applied")
