import InnoRouterCore

@MainActor
final class NavigationMiddlewareRegistry<R: Route> {
    struct InterceptionOutcome {
        let command: NavigationCommand<R>
        let interception: NavigationInterception<R>
        /// Snapshot of the middlewares that ran `willExecute` for this
        /// command, in the same order they ran. The follow-up
        /// `didExecute` / `discardExecution` calls iterate this exact
        /// list so a middleware mutated into or out of the live
        /// `entries` array between intercept and finalisation cannot
        /// receive a one-sided callback.
        let participants: [AnyNavigationMiddleware<R>]
    }

    private struct Entry {
        let handle: NavigationMiddlewareHandle
        let debugName: String?
        let middleware: AnyNavigationMiddleware<R>

        init(registration: NavigationMiddlewareRegistration<R>) {
            self.handle = NavigationMiddlewareHandle()
            self.debugName = registration.debugName
            self.middleware = registration.middleware
        }

        init(middleware: AnyNavigationMiddleware<R>, debugName: String?) {
            self.handle = NavigationMiddlewareHandle()
            self.debugName = debugName
            self.middleware = middleware
        }

        var metadata: NavigationMiddlewareMetadata {
            NavigationMiddlewareMetadata(handle: handle, debugName: debugName)
        }

        func replacing(with middleware: AnyNavigationMiddleware<R>, debugName: String?) -> Self {
            Self(handle: handle, debugName: debugName, middleware: middleware)
        }

        private init(
            handle: NavigationMiddlewareHandle,
            debugName: String?,
            middleware: AnyNavigationMiddleware<R>
        ) {
            self.handle = handle
            self.debugName = debugName
            self.middleware = middleware
        }
    }

    private var entries: [Entry]
    private let telemetrySink: NavigationStoreTelemetrySink<R>
    private var callbackDepth = 0
    private var callbackState: RouteStack<R>?

    init(
        registrations: [NavigationMiddlewareRegistration<R>],
        telemetrySink: NavigationStoreTelemetrySink<R>
    ) {
        self.entries = registrations.map(Entry.init)
        self.telemetrySink = telemetrySink
    }

    var metadata: [NavigationMiddlewareMetadata] {
        entries.map(\.metadata)
    }

    var isInvokingCallback: Bool {
        callbackDepth > 0
    }

    var activeCallbackState: RouteStack<R>? {
        callbackState
    }

    @discardableResult
    func add(
        _ middleware: AnyNavigationMiddleware<R>,
        debugName: String? = nil
    ) -> NavigationMiddlewareHandle {
        let entry = Entry(middleware: middleware, debugName: debugName)
        entries.append(entry)
        telemetrySink.recordMiddlewareMutation(.added, metadata: entry.metadata, index: entries.count - 1)
        return entry.handle
    }

    @discardableResult
    func insert(
        _ middleware: AnyNavigationMiddleware<R>,
        at index: Int,
        debugName: String? = nil
    ) -> NavigationMiddlewareHandle {
        let entry = Entry(middleware: middleware, debugName: debugName)
        let insertionIndex = min(max(index, 0), entries.count)
        entries.insert(entry, at: insertionIndex)
        telemetrySink.recordMiddlewareMutation(.inserted, metadata: entry.metadata, index: insertionIndex)
        return entry.handle
    }

    @discardableResult
    func remove(_ handle: NavigationMiddlewareHandle) -> AnyNavigationMiddleware<R>? {
        guard let index = entries.firstIndex(where: { $0.handle == handle }) else {
            return nil
        }
        let removed = entries.remove(at: index)
        telemetrySink.recordMiddlewareMutation(.removed, metadata: removed.metadata, index: index)
        return removed.middleware
    }

    @discardableResult
    func replace(
        _ handle: NavigationMiddlewareHandle,
        with middleware: AnyNavigationMiddleware<R>,
        debugName: String? = nil
    ) -> Bool {
        guard let index = entries.firstIndex(where: { $0.handle == handle }) else {
            return false
        }
        entries[index] = entries[index].replacing(with: middleware, debugName: debugName)
        telemetrySink.recordMiddlewareMutation(.replaced, metadata: entries[index].metadata, index: index)
        return true
    }

    @discardableResult
    func move(_ handle: NavigationMiddlewareHandle, to index: Int) -> Bool {
        guard let currentIndex = entries.firstIndex(where: { $0.handle == handle }) else {
            return false
        }
        let targetIndex = min(max(index, 0), entries.count - 1)
        let entry = entries.remove(at: currentIndex)
        entries.insert(entry, at: targetIndex)
        telemetrySink.recordMiddlewareMutation(.moved, metadata: entry.metadata, index: targetIndex)
        return true
    }

    func intercept(
        _ command: NavigationCommand<R>,
        state: RouteStack<R>
    ) -> InterceptionOutcome {
        var currentCommand = command
        var participants: [AnyNavigationMiddleware<R>] = []
        participants.reserveCapacity(entries.count)

        for entry in entries {
            let interception = withCallbackBoundary(state: state) {
                entry.middleware.willExecute(currentCommand, state: state)
            }
            // Append before branching on the interception so a
            // middleware that cancels here is still recorded as a
            // participant and receives its didExecute/discard
            // callback for the same command.
            participants.append(entry.middleware)

            switch interception {
            case .proceed(let updatedCommand):
                currentCommand = updatedCommand
            case .cancel(let reason):
                let resolvedReason = resolveCancellationReason(reason, entry: entry)
                return InterceptionOutcome(
                    command: currentCommand,
                    interception: .cancel(resolvedReason),
                    participants: participants
                )
            }
        }

        return InterceptionOutcome(
            command: currentCommand,
            interception: .proceed(currentCommand),
            participants: participants
        )
    }

    func didExecute(
        _ command: NavigationCommand<R>,
        result: NavigationResult<R>,
        state: RouteStack<R>,
        participants: [AnyNavigationMiddleware<R>]
    ) -> NavigationResult<R> {
        var currentResult = result
        for middleware in participants {
            currentResult = withCallbackBoundary(state: state) {
                middleware.didExecute(command, result: currentResult, state: state)
            }
        }
        return currentResult
    }

    func discardExecution(
        _ command: NavigationCommand<R>,
        result: NavigationResult<R>,
        state: RouteStack<R>,
        participants: [AnyNavigationMiddleware<R>]
    ) {
        for middleware in participants {
            withCallbackBoundary(state: state) {
                middleware.discardExecution(command, result: result, state: state)
            }
        }
    }

    private func withCallbackBoundary<T>(
        state: RouteStack<R>,
        _ operation: () -> T
    ) -> T {
        let previousState = callbackState
        callbackDepth += 1
        callbackState = state
        defer {
            callbackState = previousState
            callbackDepth -= 1
            precondition(callbackDepth >= 0, "Navigation middleware callback depth underflowed.")
        }
        return operation()
    }

    private func resolveCancellationReason(
        _ reason: NavigationCancellationReason<R>,
        entry: Entry
    ) -> NavigationCancellationReason<R> {
        switch reason {
        case .middleware(let debugName, let originalCommand):
            let resolvedName = debugName ?? entry.debugName
            return .middleware(debugName: resolvedName, command: originalCommand)
        case .conditionFailed:
            return .conditionFailed
        case .custom(let message):
            return .custom(message)
        case .staleAfterPrepare(let command):
            return .staleAfterPrepare(command: command)
        }
    }
}
