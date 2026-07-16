// MARK: - ChildCoordinatorCoreTests.swift
// InnoRouter Tests
// Copyright © 2025 Inno Squad. All rights reserved.

import Testing
import Foundation
@testable import InnoRouterSwiftUI

// MARK: - ChildCoordinator Tests

@Suite("ChildCoordinator Tests")
struct ChildCoordinatorTests {
    private static func builtExecutable(named name: String) -> URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildDirectory = root.appending(path: ".build")
        guard let enumerator = FileManager.default.enumerator(
            at: buildDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == name else {
                continue
            }

            guard fileURL.pathExtension.isEmpty, !fileURL.path.contains(".dSYM/") else {
                continue
            }

            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
            if values?.isRegularFile == true, values?.isExecutable == true {
                return fileURL
            }
        }

        return nil
    }

    @MainActor
    final class OnboardingChild: ChildCoordinator {
        typealias Result = String

        var onFinish: (@MainActor @Sendable (String) -> Void)?
        var onCancel: (@MainActor @Sendable () -> Void)?
    }

    @MainActor
    final class LifetimeCapture {
        weak var child: LifetimeChild?
        var finish: (@MainActor @Sendable (String) -> Void)?
    }

    @MainActor
    final class LifetimeChild: ChildCoordinator {
        typealias Result = String

        let capture: LifetimeCapture
        var onFinish: (@MainActor @Sendable (String) -> Void)? {
            didSet { capture.finish = onFinish }
        }
        var onCancel: (@MainActor @Sendable () -> Void)?

        init(capture: LifetimeCapture) {
            self.capture = capture
            capture.child = self
        }
    }

    @MainActor
    final class ImmediateFinishingChild: ChildCoordinator {
        typealias Result = String

        var onFinish: (@MainActor @Sendable (String) -> Void)? {
            didSet { onFinish?("immediate") }
        }
        var onCancel: (@MainActor @Sendable () -> Void)?
        private(set) var parentDidCancelCount = 0

        func parentDidCancel() {
            parentDidCancelCount += 1
        }
    }

    @MainActor
    private func waitForCallbacks<Child: ChildCoordinator>(
        on child: Child
    ) async -> Bool {
        for _ in 0..<1_000 {
            if child.onFinish != nil, child.onCancel != nil {
                return true
            }
            await Task.yield()
        }
        return false
    }

    @Test("waitForResult() resolves with the finish result")
    @MainActor
    func testFinishResumesTask() async {
        let child = OnboardingChild()

        let task = Task { @MainActor in
            await child.waitForResult()
        }
        #expect(await waitForCallbacks(on: child))
        child.onFinish?("welcome")

        let result = await task.value
        #expect(result == "welcome")
    }

    @Test("waitForResult() resolves with nil on cancel")
    @MainActor
    func testCancelResumesTaskWithNil() async {
        let child = OnboardingChild()

        let task = Task { @MainActor in
            await child.waitForResult()
        }
        #expect(await waitForCallbacks(on: child))
        child.onCancel?()

        let result = await task.value
        #expect(result == nil)
    }

    @Test("waitForResult() ignores cancel after finish")
    @MainActor
    func testCancelAfterFinishIsIgnored() async {
        let child = OnboardingChild()

        let task = Task { @MainActor in
            await child.waitForResult()
        }
        #expect(await waitForCallbacks(on: child))
        child.onFinish?("final")
        child.onCancel?()

        let result = await task.value
        #expect(result == "final")
    }

    @Test("waitForResult() ignores finish after cancel")
    @MainActor
    func testFinishAfterCancelIsIgnored() async {
        let child = OnboardingChild()

        let task = Task { @MainActor in
            await child.waitForResult()
        }
        #expect(await waitForCallbacks(on: child))
        child.onCancel?()
        child.onFinish?("late")

        let result = await task.value
        #expect(result == nil)
    }

    @Test("waitForResult() installs finish and cancel callbacks on the child")
    @MainActor
    func testWaitForResultInstallsCallbacks() async {
        let child = OnboardingChild()

        #expect(child.onFinish == nil)
        #expect(child.onCancel == nil)

        let task = Task { @MainActor in
            await child.waitForResult()
        }
        #expect(await waitForCallbacks(on: child))

        #expect(child.onFinish != nil)
        #expect(child.onCancel != nil)

        child.onCancel?()
        _ = await task.value
    }

    @Test("waitForResult() restores callbacks after resolving")
    @MainActor
    func testWaitForResultRestoresCallbacks() async {
        let child = OnboardingChild()

        let task = Task { @MainActor in
            await child.waitForResult()
        }
        #expect(await waitForCallbacks(on: child))

        child.onFinish?("welcome")
        #expect(await task.value == "welcome")
        #expect(child.onFinish == nil)
        #expect(child.onCancel == nil)
    }

    @Test("waitForResult() strongly retains an inline temporary until it resolves")
    @MainActor
    func testWaitForResultRetainsInlineTemporary() async {
        let capture = LifetimeCapture()

        let task = Task { @MainActor in
            await LifetimeChild(capture: capture).waitForResult()
        }

        for _ in 0..<1_000 where capture.finish == nil {
            await Task.yield()
        }
        #expect(capture.finish != nil)
        #expect(capture.child != nil)

        capture.finish?("welcome")
        #expect(await task.value == "welcome")

        await Task.yield()
        #expect(capture.finish == nil)
        #expect(capture.child == nil)
    }

    @Test("waitForResult() preserves a result fired before its continuation is installed")
    @MainActor
    func testImmediateFinishBeforeContinuationInstallation() async {
        let child = ImmediateFinishingChild()

        let result = await child.waitForResult()

        #expect(result == "immediate")
        #expect(child.parentDidCancelCount == 0)
        #expect(child.onFinish == nil)
        #expect(child.onCancel == nil)
    }

    @Test("An already-cancelled caller wins a result fired while callbacks are installed")
    @MainActor
    func testAlreadyCancelledCallerWinsImmediateFinish() async {
        let child = ImmediateFinishingChild()

        // This test owns MainActor until `task.value` is awaited, ensuring
        // cancellation is visible before waitForResult() begins installing
        // callbacks. The child's onFinish setter reports synchronously.
        let task = Task { @MainActor in
            await child.waitForResult()
        }
        task.cancel()
        task.cancel()

        #expect(await task.value == nil)
        #expect(child.parentDidCancelCount == 1)
        #expect(child.onFinish == nil)
        #expect(child.onCancel == nil)
    }

    @Test("waitForResult() fails fast when the same child is awaited concurrently")
    func testWaitForResultRejectsConcurrentReuse() throws {
        guard let executableURL = Self.builtExecutable(named: "ChildCoordinatorFailFastProbe") else {
            Issue.record("Expected ChildCoordinatorFailFastProbe executable to be built")
            return
        }

        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stderrOutput = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        #expect(process.terminationStatus != 0)
        #expect(stderrOutput.contains("Cannot wait for a ChildCoordinator result while completion callbacks are already installed."))
    }
}
