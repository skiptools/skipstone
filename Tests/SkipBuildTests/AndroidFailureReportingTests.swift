// Copyright (c) 2023 - 2026 Skip
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
#if canImport(SkipDriveExternal)
import SkipDriveExternal

/// Checks that a failing test in a new project is reported as a failure when run on an Android emulator.
///
/// Run by the CI emulator job with `ANDROID_SERIAL` set to the emulator; skipped otherwise.
/// The children's output is logged with a line prefix, so the `::error` workflow commands
/// that the expected failures print do not become GitHub annotations.
final class AndroidFailureReportingTests: XCTestCase {
    func testSwiftPackageFailureIsReported() async throws {
        let serial = try androidSerial()
        let dir = try tmpDir().appendingPathComponent("package-demo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await run(in: dir, "swift", "package", "init", "--name", "PackageDemo")
        try append(#"@Test func shouldFail() { #expect(1+1 == 3, "Test should fail") }"#, to: dir.appendingPathComponent("Tests/PackageDemoTests/PackageDemoTests.swift"))

        try await run(in: dir, "swift", "build", "--build-tests")
        try await run(in: dir, expectFailure: "Test should fail", "swift", "test")
        try await run(in: dir, env: ["ANDROID_SERIAL": serial], expectFailure: "Test should fail", "skip", "android", "test", "--apk", "--arch", androidArch)
    }

    func testFuseFrameworkFailureIsReported() async throws {
        let serial = try androidSerial()
        let tmp = try tmpDir()
        // Under swiftbuild a Fuse package graph links SkipLib and SkipUnit statically into more than
        // one dynamic product, which is an error; dynamic shared products keep it valid (see HostSwiftBuild)
        let env = ["SKIP_DYNAMIC_LIBRARIES": "1"]
        try await run(in: tmp, env: env, "skip", "init", "--no-build", "--native-model", "--bridged", "--module-tests", "demo-fuse-framework", "DemoFramework")
        let dir = tmp.appendingPathComponent("demo-fuse-framework", isDirectory: true)
        try append("""
        #if os(Android)
        @Test func shouldFailOnAndroid() { #expect(1+1 == 3, "Test should fail on Android") }
        #endif
        """, to: dir.appendingPathComponent("Tests/DemoFrameworkTests/DemoFrameworkTests.swift"))

        try await run(in: dir, env: env, "swift", "build", "--build-tests")
        #if !os(Linux)
        // Robolectric should still pass. Not on Linux, where skip-android-bridge's AndroidBundle
        // can't subclass swift-corelibs-foundation's Bundle
        try await run(in: dir, env: env, "swift", "test")
        #endif
        try await run(in: dir, env: env.merging(["ANDROID_SERIAL": serial]) { $1 }, expectFailure: "Test should fail on Android", "swift", "test")
    }

    private var androidArch: String {
        ProcessInfo.processInfo.environment["ANDROID_ARCH"] ?? "x86_64"
    }

    private func androidSerial() throws -> String {
        guard let serial = ProcessInfo.processInfo.environment["ANDROID_SERIAL"], !serial.isEmpty else {
            throw XCTSkip("ANDROID_SERIAL is not set; this test needs an Android emulator")
        }
        return serial
    }

    private func tmpDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("AndroidFailureReportingTests/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func append(_ code: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + code + "\n").utf8))
    }

    /// Runs the command and asserts that it succeeds or, given `expectFailure`, that it fails with output containing that message.
    /// The child does not inherit `ANDROID_SERIAL`, so `swift test` runs under Robolectric unless `env` sets it.
    private func run(in dir: URL, env: [String: String] = [:], expectFailure expectedMessage: String? = nil, _ args: String..., file: StaticString = #filePath, line: UInt = #line) async throws {
        // turn "-[AndroidFailureReportingTests testSomeTest]" into "testSomeTest"
        let testName = testRun?.test.name.split(separator: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? "TEST"
        var penv = ProcessInfo.processInfo.environment
        penv["ANDROID_SERIAL"] = nil
        penv["SKIPLOCAL"] = nil // remote dependencies cannot use local paths
        penv["TERM"] = "dumb" // no ANSI colors or progress animations
        penv.merge(env) { $1 }

        print("\(testName) running: \(env.keys.sorted().map { "\($0)=\(env[$0]!) " }.joined())\(args.joined(separator: " "))")
        var output: [String] = []
        var result: ProcessResult? = nil
        for try await outputLine in Process.streamLines(command: ["/usr/bin/env"] + args, environment: penv, workingDirectory: dir, includeStdErr: true, onExit: { result = $0 }) {
            print("\(testName) [\(outputLine.err ? "stderr" : "stdout")]> \(outputLine.line)")
            output.append(outputLine.line)
        }

        let succeeded = result?.exitStatus == .terminated(code: 0)
        let command = args.joined(separator: " ")
        if let expectedMessage {
            XCTAssertFalse(succeeded, "\(command) should have failed", file: file, line: line)
            XCTAssertTrue(output.contains { $0.contains(expectedMessage) }, "\(command) output should contain: \(expectedMessage)", file: file, line: line)
        } else if !succeeded {
            XCTFail("\(command) failed: \(String(describing: result?.exitStatus))", file: file, line: line)
            throw ProcessResult.Error.nonZeroExit(result!)
        }
    }
}
#endif
