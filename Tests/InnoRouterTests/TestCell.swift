import Synchronization

/// A `Sendable` mutable cell for a value a test changes after it has handed a
/// `@Sendable` closure a reference to it.
///
/// A captured local `var` is copied into the closure, so mutating it later is
/// both a compiler warning and, depending on the capture, not observed by the
/// closure. Routing the value through one lock makes the test say what it
/// means: the closure reads the current value on every call.
final class TestCell<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) { storage = Mutex(value) }

    var value: Value {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
