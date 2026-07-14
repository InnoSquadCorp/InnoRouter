import InnoRouterCore

@MainActor
final class ModalMiddlewareRegistry<M: Route> {
    struct InterceptionOutcome {
        let command: ModalCommand<M>
        let interception: ModalInterception<M>
        /// Snapshot of the middlewares that ran `willExecute` for this
        /// command, in the same order they ran. The follow-up
        /// `didExecute` call iterates this exact list so a middleware
        /// mutated into or out of the live `entries` array between
        /// intercept and finalisation cannot receive a one-sided
        /// callback.
        let participants: [AnyModalMiddleware<M>]
    }

    private struct Entry {
        let handle: ModalMiddlewareHandle
        let debugName: String?
        let middleware: AnyModalMiddleware<M>

        init(registration: ModalMiddlewareRegistration<M>) {
            self.handle = ModalMiddlewareHandle()
            self.debugName = registration.debugName
            self.middleware = registration.middleware
        }

        init(middleware: AnyModalMiddleware<M>, debugName: String?) {
            self.handle = ModalMiddlewareHandle()
            self.debugName = debugName
            self.middleware = middleware
        }

        var metadata: ModalMiddlewareMetadata {
            ModalMiddlewareMetadata(handle: handle, debugName: debugName)
        }

        func replacing(with middleware: AnyModalMiddleware<M>, debugName: String?) -> Self {
            Self(handle: handle, debugName: debugName, middleware: middleware)
        }

        private init(
            handle: ModalMiddlewareHandle,
            debugName: String?,
            middleware: AnyModalMiddleware<M>
        ) {
            self.handle = handle
            self.debugName = debugName
            self.middleware = middleware
        }
    }

    private var entries: [Entry]
    private let telemetrySink: ModalStoreTelemetrySink<M>

    init(
        registrations: [ModalMiddlewareRegistration<M>],
        telemetrySink: ModalStoreTelemetrySink<M>
    ) {
        self.entries = registrations.map(Entry.init)
        self.telemetrySink = telemetrySink
    }

    var metadata: [ModalMiddlewareMetadata] {
        entries.map(\.metadata)
    }

    @discardableResult
    func add(
        _ middleware: AnyModalMiddleware<M>,
        debugName: String? = nil
    ) -> ModalMiddlewareHandle {
        let entry = Entry(middleware: middleware, debugName: debugName)
        entries.append(entry)
        telemetrySink.recordMiddlewareMutation(.added, metadata: entry.metadata, index: entries.count - 1)
        return entry.handle
    }

    @discardableResult
    func insert(
        _ middleware: AnyModalMiddleware<M>,
        at index: Int,
        debugName: String? = nil
    ) -> ModalMiddlewareHandle {
        let entry = Entry(middleware: middleware, debugName: debugName)
        let insertionIndex = min(max(index, 0), entries.count)
        entries.insert(entry, at: insertionIndex)
        telemetrySink.recordMiddlewareMutation(.inserted, metadata: entry.metadata, index: insertionIndex)
        return entry.handle
    }

    @discardableResult
    func remove(_ handle: ModalMiddlewareHandle) -> AnyModalMiddleware<M>? {
        guard let index = entries.firstIndex(where: { $0.handle == handle }) else {
            return nil
        }
        let removed = entries.remove(at: index)
        telemetrySink.recordMiddlewareMutation(.removed, metadata: removed.metadata, index: index)
        return removed.middleware
    }

    @discardableResult
    func replace(
        _ handle: ModalMiddlewareHandle,
        with middleware: AnyModalMiddleware<M>,
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
    func move(_ handle: ModalMiddlewareHandle, to index: Int) -> Bool {
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
        _ command: ModalCommand<M>,
        currentPresentation: ModalPresentation<M>?,
        queuedPresentations: [ModalPresentation<M>]
    ) -> InterceptionOutcome {
        var currentCommand = command
        var participants: [AnyModalMiddleware<M>] = []
        participants.reserveCapacity(entries.count)

        for entry in entries {
            let interception = entry.middleware.willExecute(
                currentCommand,
                currentPresentation: currentPresentation,
                queuedPresentations: queuedPresentations
            )
            // Append before branching so a cancelling middleware is
            // still recorded as a participant for its didExecute pair.
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
        _ command: ModalCommand<M>,
        currentPresentation: ModalPresentation<M>?,
        queuedPresentations: [ModalPresentation<M>],
        participants: [AnyModalMiddleware<M>]
    ) {
        for middleware in participants {
            middleware.didExecute(
                command,
                currentPresentation: currentPresentation,
                queuedPresentations: queuedPresentations
            )
        }
    }

    private func resolveCancellationReason(
        _ reason: ModalCancellationReason<M>,
        entry: Entry
    ) -> ModalCancellationReason<M> {
        switch reason {
        case .middleware(let debugName, let originalCommand):
            let resolvedName = debugName ?? entry.debugName
            return .middleware(debugName: resolvedName, command: originalCommand)
        case .conditionFailed:
            return .conditionFailed
        case .custom(let message):
            return .custom(message)
        }
    }
}
