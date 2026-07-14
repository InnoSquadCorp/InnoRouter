public enum RouteStackValidationError<R: Route>: Error, Equatable, Sendable {
    case emptyStackNotAllowed
    case duplicateRoute(R)
    case missingRequiredRoot(expected: R)
    case invalidRoot(expected: R, actual: R)
}

/// A one-shot path validation policy consumed by
/// ``RouteStack/init(validating:using:)``.
///
/// A validator runs **once at construction** and is then discarded —
/// it does not travel with the stack, and subsequent mutations
/// (pushes, pops, replaces applied by `NavigationEngine`) are not
/// re-validated against it. Use it to reject malformed initial or
/// restored paths (for example a persisted stack decoded from disk).
/// For invariants that must hold across mutations, use a
/// `NavigationMiddleware` that intercepts violating commands instead.
public struct RouteStackValidator<R: Route>: Sendable {
    private let validateClosure: @Sendable ([R]) throws -> Void

    public init(_ validate: @escaping @Sendable ([R]) throws -> Void) {
        self.validateClosure = validate
    }

    public func validate(_ path: [R]) throws {
        try validateClosure(path)
    }

    public static var permissive: Self {
        Self { _ in }
    }

    public static var nonEmpty: Self {
        Self { path in
            guard !path.isEmpty else {
                throw RouteStackValidationError<R>.emptyStackNotAllowed
            }
        }
    }

    public static var uniqueRoutes: Self {
        Self { path in
            var seen = Set<R>()

            for route in path {
                guard seen.insert(route).inserted else {
                    throw RouteStackValidationError<R>.duplicateRoute(route)
                }
            }
        }
    }

    public static func rooted(at route: R) -> Self {
        Self { path in
            guard let first = path.first else {
                throw RouteStackValidationError<R>.missingRequiredRoot(expected: route)
            }
            guard first == route else {
                throw RouteStackValidationError<R>.invalidRoot(expected: route, actual: first)
            }
        }
    }

    public func combined(with other: Self) -> Self {
        Self { path in
            try self.validate(path)
            try other.validate(path)
        }
    }
}
