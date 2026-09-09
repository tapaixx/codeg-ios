# Background Agent UX and Recovery Design

Status: accepted design for the tapaixx fork

Target: iOS 26+

## Goals

The primary product goal is not to make reconnect UI faster. It is to make ordinary transport recovery invisible to the user.

A user switching from Codeg to another app and back should normally see the latest agent state directly. A WebSocket reconnect is an implementation detail, not a chat state.

## Two independent state machines

Agent/turn state and network transport state are separate concepts.

Agent state:

- idle
- running
- waiting for permission
- waiting for question
- waiting for plan approval
- completed
- failed
- cancelled

Transport state:

- healthy
- suspect
- recovering
- offline

A running agent whose WebSocket is recovering remains a running agent. The UI must not replace the agent state with a blocking "reconnecting" state.

## Foreground/background behavior

### Active turn

When an event stream for a user-started turn is active, Codeg requests an iOS 26 `BGContinuedProcessingTask` so the process can continue receiving HTTP and WebSocket traffic after the app moves to the background.

The system continued-processing task is best effort, not a guarantee. Resource pressure can still terminate background execution.

### Idle app

When no agent turn is active, the app does not try to keep a permanent background WebSocket alive. Opening the app performs a normal foreground refresh. A future APNs integration is the preferred solution for true server-initiated, cross-device background notifications.

### Returning to foreground

Becoming active is not, by itself, a reason to reconnect. A healthy existing socket is retained. Recovery happens only after an actual receive/ping/socket failure.

## Transparent WebSocket recovery

`EventStream` owns short transport recovery so callers continue to observe one logical stream.

On a socket-level failure after attach:

1. Keep the logical event stream alive.
2. Reopen `/ws/events` with exponential backoff.
3. Reuse the same subscription id and ACP connection id.
4. Re-attach with the latest observed `seq` as `since_seq`.
5. Consume snapshot/replay and resume normal events.
6. Do not emit `.closed` during these short recovery attempts.
7. After the transparent retry budget is exhausted, emit `.closed` so the existing SessionDetail reconciliation/fallback logic can take over.

Network path changes are hints only. Wi-Fi/5G/VPN changes do not proactively tear down a healthy socket. When the network changes from unavailable to available while a retry is already pending, Codeg skips the remaining backoff and retries immediately.

### Native WebSocket authentication and CDN compatibility

The native iOS client authenticates the `/ws/events` HTTP Upgrade with the same bearer token as normal Codeg API requests:

- `Authorization: Bearer <token>` carries authentication through the CDN/WAF and into Codeg.
- `Sec-WebSocket-Protocol: codeg-events` advertises only the application protocol.
- The token is trimmed for surrounding whitespace/newlines before the handshake.

The web/browser client may need to encode a token into a secondary WebSocket subprotocol because browser JavaScript cannot freely add an `Authorization` header to `new WebSocket(...)`. Native iOS does not have that limitation and must not rely on the browser-specific `codeg-token.*` subprotocol. This keeps CDN authentication behavior consistent between ordinary API calls and the WebSocket upgrade and avoids intermediaries rejecting token-bearing custom subprotocol values.

## Reconnect UX

Desired UI policy if transport state is surfaced later:

- 0-5 seconds: completely silent.
- 5-15 seconds: optional non-blocking "Restoring connection…" banner.
- Over 15 seconds: persistent non-blocking banner with Retry.
- Never show an automatic modal solely because a socket is reconnecting.

The transcript remains readable, scrollable and copyable during recovery. Draft editing also remains available. Network-dependent actions may be disabled while truly offline.

Offline sends are not queued for later automatic execution. The draft is preserved and the user explicitly sends after connectivity returns.

## Continued-processing Live Activity

The iOS 26 continued-processing task automatically provides system Live Activity presentation.

Content should be low sensitivity by default:

- Codeg / agent identity
- session or task summary when safe
- current phase such as "Generating reply", "Running a tool", or "Waiting for permission"

Do not intentionally surface full prompts, source code, shell arguments or tool output in the compact lock-screen presentation.

For multiple simultaneous local streams, show aggregate task wording rather than treating each WebSocket reconnect as a new activity.

### Dynamic Island update and navigation policy

The system continued-processing Live Activity is intentionally low-frequency. Agent work has no honest completion percentage, so its `Progress` is indeterminate and the user-facing subtitle carries phase plus wall-clock elapsed time (for example, `Running a tool · Elapsed 4 min`). The first minute is shown as `<1 min`; multiple simultaneous tasks show only an aggregate task count.

Token/thinking deltas and repeated tool updates never rewrite the system title. Entering the background publishes one state, followed by at least a 60-second quiet window; normal elapsed-time refreshes are minute-granularity. Permission/question/plan waits may break the quiet window because they require user action. Task completion ends the continued-processing task immediately. iOS ultimately controls Dynamic Island compact/minimal/expanded presentation, so Codeg reduces update pressure rather than pretending it can force a collapse.

Because the system-owned continued-processing Live Activity does not expose a custom per-task `widgetURL`, a tap launches Codeg using `NSUserActivityTypeLiveActivity`. Codeg persists only non-sensitive navigation/timing hints (`serverID`, conversation or new-session identity, and `startedAt`). A single active task opens its owning server/session, multiple tasks open Activity, and a just-finished task remains routable for approximately two minutes to cover tap/completion races. App-icon launches and ordinary App Switcher foregrounding do not auto-navigate.

### Important cancellation limitation

`BGContinuedProcessingTask.expirationHandler` is used when the system reclaims resources and also when continued processing is cancelled. The API does not provide a reason enum that lets Codeg reliably distinguish those cases.

Therefore the expiration handler must **not** call server-side `acp_cancel`; doing so could kill a perfectly valid remote agent merely because iOS reclaimed local resources.

Explicit Codeg Stop actions remain authoritative for cancelling an agent and must call the backend `acp_cancel` endpoint.

## Background approval notifications

When the app is backgrounded and the live stream receives an interactive request, Codeg can issue an actionable local notification.

### Permission requests

Primary actions:

- Allow Once
- Reject

Expanded action:

- Always Allow

Always Allow requires a second confirmation notification. Per accepted product policy, these actions do not add the `authenticationRequired` option.

Each action is bound to the concrete request id and connection. Resolution events remove stale notifications.

### Questions

Question sets are handled as a notification wizard. One question is presented at a time. Standard options become notification actions and an `UNTextInputNotificationAction` provides free-text input. Answers are accumulated and submitted only when the final step is complete.

### Plan approval

Supported notification actions:

- Approve
- Abandon
- Request Changes (text input)

### Stale requests and retry TTL

An interactive notification is tied to its request identifier. If another client resolves the request, the live resolution event removes the local notification.

A user action that fails because of a transient network error retries for up to approximately 60 seconds with bounded exponential backoff. It must not execute unexpectedly much later after connectivity returns.

## Completion and failure notifications

When a turn completes or errors while Codeg is backgrounded, the app can deliver a local completion/attention notification. Foreground completion continues to use the normal in-app experience.

A future settings surface should expose completion/failure/approval notification preferences; the intended default is enabled for meaningful state changes, not for streaming token updates.

## System resource termination

Losing local background execution is not equivalent to agent failure. The server-side ACP connection may continue running.

On the next available execution opportunity or foreground launch, Codeg should reconcile the authoritative conversation/snapshot. If the agent has already completed, the final transcript should be shown immediately; restoring an obsolete WebSocket first is not a user-visible prerequisite.

## Force quit

A user force-quitting Codeg is treated as an instruction for this client to stop trying to maintain local background activity. The remote server may still have an active agent. A later manual app launch discovers and reattaches/reconciles that state.

## Future APNs phase

The first implementation only protects turns that the iPhone itself is already observing.

To support tasks started on Codeg Web, Mac, or another device while the iPhone is idle, the correct architecture is server-driven APNs. That future phase can deliver:

- remote task started/running notifications
- permission/question/plan approval notifications
- task completion notifications

without attempting to keep an idle iOS WebSocket permanently alive.

## Release/build policy for this fork

The tapaixx fork publishes an unsigned IPA for external signing workflows. CI builds the device app with code signing disabled, verifies that `_CodeSignature` is absent, packages the `.app` as `Payload/Codeg.app`, and publishes the IPA plus SHA-256 digest.
