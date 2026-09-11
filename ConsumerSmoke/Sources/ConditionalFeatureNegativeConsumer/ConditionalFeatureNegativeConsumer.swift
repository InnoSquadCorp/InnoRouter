#if INNOROUTER_CONDITIONAL_FEATURE_NEGATIVE
import SwiftUI
import InnoRouter

@Router
public enum ConditionalFeatureChildRoute {
    case home

    public var destination: some View { EmptyView() }
}

@Router
public enum ConditionalFeatureParentRoute {
#if os(macOS)
    @FeatureRoute
    case child(ConditionalFeatureChildRoute)
#endif

    public var destination: some View { EmptyView() }
}
#endif
