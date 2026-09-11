#if INNOROUTER_AVAILABILITY_NEGATIVE
import InnoRouterMacroFirstExternalConsumer

public func unguardedFuturePresentationFactory() {
    _ = ExternalRoute.Presentation.futureConfirmation
    _ = ExternalRoute.Presentation.conditionalFutureConfirmation
}
#endif
