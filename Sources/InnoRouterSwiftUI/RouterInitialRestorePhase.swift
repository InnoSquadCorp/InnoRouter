/// The one-shot restore policy for the complete lifetime of a driver.
///
/// Display status and owner bookkeeping cannot represent this state: saves
/// overwrite `status`, while a deliberate stop and a natural last-owner
/// detach have opposite retry policies. Keeping those meanings in one phase
/// prevents a later detach from turning an explicitly stopped restore back
/// into a first activation.
enum RouterInitialRestorePhase {
    case notStarted, inProgress, completed, explicitlyStopped
}
