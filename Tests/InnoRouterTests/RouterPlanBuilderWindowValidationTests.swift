import Foundation
import Testing

import InnoRouterCore

/// A plan step can introduce duplicate window IDs before any validation runs.
/// The builder must answer with a typed error; a trap would turn a malformed
/// plan into a crash.
@Suite("Router plan builder window validation")
struct RouterPlanBuilderWindowValidationTests {
    private enum RouteFixture: String, Route, Codable {
        case editor
        case viewer
    }

    @Test("A plan with duplicate windows followed by an action throws instead of trapping")
    func duplicateWindowsThenActionThrows() async {
        await #expect(processExitsWith: .success) {
            let id = UUID()
            let window = RouterWindow<RouteFixture>(id: id, route: .editor)
            do {
                _ = try RouterPlan<RouteFixture> {
                    RouterPlanStep.windows([window, window])
                    RouterPlanStep.action(.dismissWindow(id))
                }
                exit(EXIT_FAILURE)
            } catch RouterMutationError.invalidTargetState(.duplicateWindow) {
                // Expected: the error 7.0 gave the actions that did not trap.
            } catch {
                exit(EXIT_FAILURE)
            }
        }
    }

    @Test("Duplicate windows are rejected at the step that introduces them")
    func duplicateWindowsStepThrows() {
        let id = UUID()
        let window = RouterWindow<RouteFixture>(id: id, route: .editor)
        #expect(throws: RouterStateValidationError.duplicateWindow) {
            _ = try RouterPlan<RouteFixture> {
                RouterPlanStep.windows([window, window])
            }
        }
    }

    @Test("An action after duplicate windows throws the error it threw in 7.0")
    func actionAfterDuplicatesKeepsItsError() {
        let window = RouterWindow<RouteFixture>(route: .editor)
        #expect(throws: RouterMutationError.invalidTargetState(.duplicateWindow)) {
            _ = try RouterPlan<RouteFixture> {
                RouterPlanStep.windows([window, window])
                RouterPlanStep.stack([.viewer])
            }
        }
    }

    @Test("A later windows step that removes the duplicate still builds")
    func laterWindowsStepReplacesDuplicate() throws {
        let window = RouterWindow<RouteFixture>(route: .editor)
        let plan = try RouterPlan<RouteFixture> {
            RouterPlanStep.windows([window, window])
            RouterPlanStep.windows([window])
        }
        #expect(plan.state.windows == [window])
    }

    @Test("A window count over the budget is reported as the budget failure")
    func overBudgetCountWinsOverDuplicate() throws {
        let window = RouterWindow<RouteFixture>(route: .editor)
        let limit = RouterResourceBudget.provisional.snapshot.maximumWindows
        let windows = Array(repeating: window, count: limit + 1)
        #expect(throws: RouterResourceLimitFailure.self) {
            _ = try RouterPlan<RouteFixture> {
                RouterPlanStep.windows(windows)
            }
        }
    }

    @Test("Distinct windows still build and later actions see them")
    func distinctWindowsBuild() throws {
        let first = RouterWindow<RouteFixture>(route: .editor)
        let second = RouterWindow<RouteFixture>(route: .viewer)
        let plan = try RouterPlan<RouteFixture> {
            RouterPlanStep.windows([first, second])
            RouterPlanStep.action(.dismissWindow(first.id))
        }
        #expect(plan.state.windows == [second])
    }
}
