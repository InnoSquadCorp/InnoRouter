public enum NavigationCommand<R: Route>: Sendable, Equatable {
    case push(R)
    case pushAll([R])
    case pop
    case popCount(Int)
    case popToRoot
    case popTo(R)
    case replace([R])
    indirect case sequence([NavigationCommand<R>])
    /// Attempts `primary` inside an internal savepoint. If it reports
    /// anything other than success, discards that leg and attempts
    /// `fallback` from the same starting state. Only a successful leg
    /// commits. If the fallback also fails, its partial changes are
    /// discarded and the returned result is the fallback failure.
    ///
    /// `NavigationStore` additionally routes `.whenCancelled`
    /// through the middleware layer recursively, so a middleware
    /// cancellation on `primary` triggers `fallback` with middleware
    /// still applied to the fallback command. Direct
    /// ``NavigationEngine`` users see engine-level failures only.
    ///
    /// **Broadcaster contract.** `NavigationStore` emits at most one
    /// `.changed` event for the *net* transition produced by a
    /// `.whenCancelled` execution:
    ///
    /// - Primary success: one event for `oldState → primaryFinalState`
    ///   (suppressed entirely if the final state equals `oldState`).
    /// - Primary failure (engine or middleware), fallback success:
    ///   partial primary mutations are discarded before the fallback
    ///   runs, and one event reports `oldState → fallbackFinalState`.
    /// - Both legs fail: both sets of partial mutations are discarded
    ///   and no `.changed` event is emitted.
    ///
    /// In particular, when `primary` is itself a `.sequence`, the
    /// per-step intermediate states reached by either sequence do not
    /// leak as separate `.changed` events. The store evaluates each leg
    /// against a shadow state and only emits the final committed
    /// transition.
    indirect case whenCancelled(
        NavigationCommand<R>,
        fallback: NavigationCommand<R>
    )

    public static func == (lhs: NavigationCommand<R>, rhs: NavigationCommand<R>) -> Bool {
        switch (lhs, rhs) {
        case (.push(let l), .push(let r)): l == r
        case (.pushAll(let l), .pushAll(let r)): l == r
        case (.pop, .pop): true
        case (.popCount(let l), .popCount(let r)): l == r
        case (.popToRoot, .popToRoot): true
        case (.popTo(let l), .popTo(let r)): l == r
        case (.replace(let l), .replace(let r)): l == r
        case (.sequence(let l), .sequence(let r)): l == r
        case (.whenCancelled(let lp, let lf), .whenCancelled(let rp, let rf)):
            lp == rp && lf == rf
        default: false
        }
    }
}

public extension NavigationCommand {
    /// Returns the result this command would produce on the provided stack.
    ///
    /// This makes command legality explicit without mutating router state or
    /// introducing a generic state-machine layer above navigation.
    ///
    /// - Parameters:
    ///   - state: The current `RouteStack` to validate against.
    ///   - engine: The navigation engine to use. Defaults to a freshly
    ///     constructed `NavigationEngine`. The engine is a stateless `struct`
    ///     so the default initialiser is cheap, but if you call `validate`
    ///     in a hot loop (e.g. property-based tests, plan synthesis,
    ///     middleware that pre-flights every step) prefer passing a single
    ///     reused engine to keep the call site allocation-free.
    func validate(on state: RouteStack<R>, using engine: NavigationEngine<R> = .init()) -> NavigationResult<R> {
        var preview = state
        return engine.apply(self, to: &preview)
    }

    /// Returns `true` when the command can succeed on the provided stack.
    ///
    /// The same `engine` reuse advice from ``validate(on:using:)`` applies.
    func canExecute(on state: RouteStack<R>, using engine: NavigationEngine<R> = .init()) -> Bool {
        validate(on: state, using: engine).isSuccess
    }
}
