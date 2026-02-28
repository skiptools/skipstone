// Copyright (c) 2023 - 2026 Skip
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import SkipBuild
import TSCBasic
import ArgumentParser

// MARK: - Test Message Command

/// A test command that conforms to MessageCommand for use in validators
///
/// Note: To create an instance, use `try TestMessageCommand.parse([])` in your test.
@available(macOS 13, iOS 16, tvOS 16, watchOS 8, *)
struct TestMessageCommand: MessageCommand {
    static var configuration = CommandConfiguration(
        commandName: "test-message-command",
        abstract: "Test command for validators",
        shouldDisplay: false
    )

    @OptionGroup(title: "Output Options")
    var outputOptions: OutputOptions

    func performCommand(with out: MessageQueue) async throws {
        // Test command doesn't do anything by default
        // It's used as a vehicle to access the run() method for executing sub-commands
    }
}

// MARK: - Mock Environment Helpers

/// Helper to create temporary directories with mock scripts for testing
@available(macOS 13, iOS 16, tvOS 16, watchOS 8, *)
struct MockEnvironment {
    let tempDir: String
    let homeDir: String
    let homebrewPrefix: String
    let androidHome: String

    /// Path to the Homebrew OpenJDK installation (used by validateJava)
    var javaHome: String {
        "\(homebrewPrefix)/opt/openjdk/libexec/openjdk.jdk/Contents/Home"
    }

    /// Path to the emulator binary (ANDROID_HOME/emulator/emulator)
    var emulatorPath: String {
        "\(androidHome)/emulator/emulator"
    }

    init() throws {
        let baseTemp = "\(FileManager.default.temporaryDirectory.path)/skip-tests-\(UUID().uuidString)"

        self.tempDir = baseTemp
        self.homeDir = "\(baseTemp)/home"
        self.homebrewPrefix = "\(baseTemp)/opt/homebrew"
        self.androidHome = "\(homeDir)/Library/Android/sdk"

        // Create directories
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: homeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: homebrewPrefix, withIntermediateDirectories: true)
    }
    
    /// Creates a mock executable script at the given path
    func createMockScript(at path: String, content: String) throws {
        let parentDir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        
        let scriptContent = "#!/bin/bash\n" + content
        try scriptContent.write(toFile: path, atomically: true, encoding: .utf8)
        
        if FileManager.default.fileExists(atPath: path) {
            _ = chmod(path, 0o755)
        }
    }
    
    /// Creates a mock executable script that echoes the given string and exits 0
    func createMockScript(at path: String, echoing: String) throws {
        try createMockScript(at: path, content: """
            echo "\(echoing)"
            exit 0
            """)
    }
    
    /// Creates a mock java script that outputs the given version to stderr
    func createMockJava(version: String) throws {
        try createMockScript(at: "\(javaHome)/bin/java", content: """
            echo 'openjdk version "\(version)" 2024-01-01' >&2
            exit 0
            """)
    }
    
    /// Creates a mock bootstrap sdkmanager at homebrew prefix that installs cmdline-tools to androidHome
    /// when invoked as: sdkmanager --sdk_root=<androidHome> "cmdline-tools;latest"
    /// Also creates bootstrap avdmanager and emulator, then copies them to their installed locations
    func createMockBootstrapSdkmanager() throws {
        // Create bootstrap avdmanager and emulator that will be copied during installation
        let bootstrapAvdmanager = "\(homebrewPrefix)/bin/avdmanager"
        try createMockScript(at: bootstrapAvdmanager, echoing: "Android Virtual Device created successfully")

        let bootstrapEmulator = "\(homebrewPrefix)/share/android-commandlinetools/emulator/emulator"
        try createMockScript(at: bootstrapEmulator, echoing: "")

        let sdkmanagerPath = "\(homebrewPrefix)/bin/sdkmanager"
        let cmdlineToolsPath = "\(androidHome)/cmdline-tools/latest/bin"
        let installedSdkmanager = "\(cmdlineToolsPath)/sdkmanager"
        let installedAvdmanager = "\(cmdlineToolsPath)/avdmanager"
        let emulatorPath = "\(androidHome)/emulator/emulator"

        try createMockScript(at: sdkmanagerPath, content: """
            if [ "$1" = "--version" ]; then
                echo "20.0"
            elif [[ "$1" == --sdk_root=* ]] && [ "$2" = "cmdline-tools;latest" ]; then
                mkdir -p \(cmdlineToolsPath)

                # Create installed sdkmanager that just echoes version
                echo '#!/bin/bash' > \(installedSdkmanager)
                echo 'echo "20.0"' >> \(installedSdkmanager)
                chmod +x \(installedSdkmanager)

                # Copy bootstrap avdmanager to installed location
                cp \(bootstrapAvdmanager) \(installedAvdmanager)

                # Copy bootstrap emulator to installed location
                mkdir -p \(androidHome)/emulator
                cp \(bootstrapEmulator) \(emulatorPath)
            fi
            exit 0
            """)
    }
    
    /// Returns environment variables configured for testing with mock scripts
    func environment(additional: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = homeDir
        env["HOMEBREW_PREFIX"] = homebrewPrefix
        env["ANDROID_HOME"] = androidHome
        env["PATH"] = "\(homebrewPrefix)/bin:/usr/bin:/bin"

        for (key, value) in additional {
            env[key] = value
        }

        return env
    }
    
    /// Cleans up the temporary directory
    func cleanup() {
        try? FileManager.default.removeItem(atPath: tempDir)
    }
}

// MARK: - XCTest Helpers

extension XCTestCase {
    /// Asserts that an async expression throws an error
    func XCTAssertThrowsErrorAsync<T>(
        _ expression: @escaping () async throws -> T,
        file: StaticString = #file,
        line: UInt = #line,
        _ errorHandler: @escaping (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected error but none was thrown", file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }
}

// MARK: - Test Message Queue Helper

/// Helper to run a validator with a collecting queue, returning both the result and the messages
@available(macOS 13, iOS 16, tvOS 16, watchOS 8, *)
func runValidator<T>(
    _ operation: (MessageQueue) async throws -> T
) async throws -> (result: T, messages: [MessageBlock]) {
    let (_, continuation) = MessageStream.makeStream()
    let queue = MessageQueue(retain: true, continuation: continuation)

    let result = try await operation(queue)

    // Extract message blocks from the queue's elements
    let elements = await queue.elements
    let messages: [MessageBlock] = elements.compactMap {
        switch $0 {
        case .success(let element as MessageBlock): return element
        default: return nil
        }
    }

    return (result, messages)
}

// MARK: - AndroidEmulatorSetupTests

@available(macOS 13, iOS 16, tvOS 16, watchOS 8, *)
final class AndroidEmulatorSetupTests: XCTestCase {
    
    var mockEnv: MockEnvironment!
    
    override func setUp() async throws {
        try await super.setUp()
        mockEnv = try MockEnvironment()
    }
    
    override func tearDown() async throws {
        mockEnv?.cleanup()
        mockEnv = nil
        try await super.tearDown()
    }
    
    // MARK: - Java Validation Tests

    /// Homebrew openjdk - expect version extracted and javaHome returned
    func testJavaValidationSucceedsWithHomebrewOpenjdk() async throws {
        // Create mock java at homebrew location
        try mockEnv.createMockJava(version: "25.0.2")

        let env = mockEnv.environment()
        let command = try TestMessageCommand.parse([])

        let (result, messages) = try await runValidator { queue in
            try await validateJava(command: command, environment: env, out: queue)
        }

        // validateJava should return the JAVA_HOME path
        XCTAssertEqual(result, mockEnv.javaHome)
        // StreamingCommand.run() generates a message block with timing info,
        // and validateJava adds another message with the version details
        XCTAssertEqual(messages.count, 2)
        // First message is from StreamingCommand.run() with timing
        XCTAssertEqual(messages[0].status, MessageBlock.Status.pass)
        // Second message is the version message from validateJava
        XCTAssertEqual(messages[1].status, MessageBlock.Status.pass)
        XCTAssertTrue(messages[1].message(term: .plain)?.contains("25.0.2") == true)
    }

    /// No Java available - expect JavaNotFoundError
    /// This test does not create a mock Java, so the validator will fail to find it
    func testJavaValidationFailsWhenNoJavaAvailable() async throws {
        let command = try TestMessageCommand.parse([])
        let env = mockEnv.environment()

        await XCTAssertThrowsErrorAsync(
            { _ = try await runValidator { queue in
                try await validateJava(command: command, environment: env, out: queue)
            }}
        ) { error in
            XCTAssertTrue(error is JavaNotFoundError)
        }
    }
    
    // MARK: - ANDROID_HOME Validation Tests

    /// Missing ANDROID_HOME and no default - expect AndroidHomeNotFoundError
    func testAndroidHomeValidationFailsWhenNotSetAndNoDefault() async {
        // Create a completely isolated environment with no Android SDK
        let env: [String: String] = [
            "HOME": mockEnv.homeDir
        ]

        await XCTAssertThrowsErrorAsync(
            { _ = try await runValidator { queue in
                try await validateAndroidHome(environment: env, out: queue)
            }}
        ) { error in
            XCTAssertTrue(error is AndroidHomeNotFoundError, "Expected AndroidHomeNotFoundError but got \(type(of: error))")
        }
    }

    /// Environment variable set - expect path
    func testAndroidHomeValidationSucceedsWithEnvVariable() async throws {
        let tempDir = mockEnv.tempDir

        let env: [String: String] = [
            "ANDROID_HOME": mockEnv.tempDir
        ]

        let (result, messages) = try await runValidator { queue in
            try await validateAndroidHome(environment: env, out: queue)
        }

        XCTAssertEqual(result, tempDir)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.status, MessageBlock.Status.pass)
    }

    /// Default macOS path using HOME mock
    #if os(macOS)
    func testAndroidHomeFallsBackToDefaultMacOSPath() async throws {
        try FileManager.default.createDirectory(atPath: mockEnv.androidHome, withIntermediateDirectories: true)

        let env: [String: String] = [
            "HOME": mockEnv.homeDir
        ]

        let (result, messages) = try await runValidator { queue in
            try await validateAndroidHome(environment: env, out: queue)
        }

        XCTAssertEqual(result, mockEnv.androidHome)
        XCTAssertEqual(messages.count, 1)
    }
    #endif

    /// ANDROID_HOME set but points to non-existent directory
    func testAndroidHomeValidationFailsWhenSetToNonExistentDirectory() async {
        let env: [String: String] = [
            "ANDROID_HOME": "/nonexistent/android/sdk",
            "HOME": mockEnv.tempDir
        ]

        await XCTAssertThrowsErrorAsync(
            { _ = try await runValidator { queue in
                try await validateAndroidHome(environment: env, out: queue)
            }}
        ) { error in
            XCTAssertTrue(error is AndroidHomeNotFoundError)
            XCTAssertTrue(error.localizedDescription.contains("/nonexistent/android/sdk"))
        }
    }
    
    // MARK: - cmdline-tools Validation Tests

    /// Missing cmdline-tools with bootstrap available
    /// The bootstrap sdkmanager script creates the cmdline-tools when executed
    func testCmdlineToolsBootstrap() async throws {
        // Create Android SDK without cmdline-tools
        let androidHome = mockEnv.androidHome

        // Create bootstrap sdkmanager at homebrew location that installs cmdline-tools when run
        try mockEnv.createMockBootstrapSdkmanager()

        let env = mockEnv.environment()

        let command = try TestMessageCommand.parse([])

        let (result, messages) = try await runValidator { queue in
            try await validateCmdlineTools(
                command: command,
                androidHome: androidHome,
                javaHome: mockEnv.javaHome,
                environment: env,
                out: queue
            )
        }

        XCTAssertTrue(result.wasBootstrapped)
        XCTAssertEqual(result.sdkmanagerPath, "\(androidHome)/cmdline-tools/latest/bin/sdkmanager")
        // StreamingCommand.run() generates message blocks with timing info for each command run,
        // plus validateCmdlineTools writes its own messages
        // Should have more messages now due to StreamingCommand.run() timing messages
        XCTAssertGreaterThanOrEqual(messages.count, 2)
    }

    /// Bootstrap installation fails - cmdline-tools still not present after installation
    /// The bootstrap script runs but doesn't create cmdline-tools (simulating a failed install)
    func testCmdlineToolsBootstrapFails() async throws {
        // Create Android SDK without cmdline-tools
        let androidHome = mockEnv.androidHome

        // Create bootstrap sdkmanager at homebrew location that does NOT create cmdline-tools
        // The bootstrap is invoked as: sdkmanager --sdk_root=<androidHome> "cmdline-tools;latest"
        // (simulating a failed bootstrap installation that doesn't create the files)
        let bootstrapSdkmanager = "\(mockEnv.homebrewPrefix)/bin/sdkmanager"
        try? mockEnv.createMockScript(at: bootstrapSdkmanager, echoing: "20.0")

        let env = mockEnv.environment()

        let command = try TestMessageCommand.parse([])

        await XCTAssertThrowsErrorAsync(
            { _ = try await runValidator { queue in
                try await validateCmdlineTools(
                    command: command,
                    androidHome: androidHome,
                    javaHome: self.mockEnv.javaHome,
                    environment: env,
                    out: queue
                )
            }}
        ) { error in
            XCTAssertTrue(error is CmdlineToolsBootstrapFailedError)
        }
    }

    /// Existing cmdline-tools validated successfully
    func testCmdlineToolsValidationSucceedsWhenPresent() async throws {
        // Create Android SDK with cmdline-tools
        let androidHome = mockEnv.androidHome
        let sdkmanagerPath = "\(androidHome)/cmdline-tools/latest/bin/sdkmanager"
        try mockEnv.createMockScript(at: sdkmanagerPath, echoing: "20.0")

        let env = mockEnv.environment()

        let command = try TestMessageCommand.parse([])

        let (result, messages) = try await runValidator { queue in
            try await validateCmdlineTools(
                command: command,
                androidHome: androidHome,
                javaHome: mockEnv.javaHome,
                environment: env,
                out: queue
            )
        }

        XCTAssertFalse(result.wasBootstrapped)
        XCTAssertEqual(result.version, "20.0")
        XCTAssertEqual(result.sdkmanagerPath, sdkmanagerPath)
        // StreamingCommand.run() generates a message block with timing info,
        // and validateCmdlineTools adds its own message
        XCTAssertGreaterThanOrEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.status, MessageBlock.Status.pass)
    }

    /// No sdkmanager found anywhere
    func testCmdlineToolsNotFoundAnywhereFails() async throws {
        let androidHome = mockEnv.androidHome

        let env = mockEnv.environment()

        let command = try TestMessageCommand.parse([])

        await XCTAssertThrowsErrorAsync(
            { _ = try await runValidator { queue in
                try await validateCmdlineTools(
                    command: command,
                    androidHome: androidHome,
                    javaHome: self.mockEnv.javaHome,
                    environment: env,
                    out: queue
                )
            }}
        ) { error in
            XCTAssertTrue(error is CmdlineToolsNotFoundError)
        }
    }

    // MARK: - AVD Existence Check Tests

    /// AVD doesn't exist - should allow creation
    func testCheckAVDExistsReturnsFalseWhenNoAVD() async throws {
        let androidHome = mockEnv.androidHome

        // Create mock emulator script that returns empty AVD list
        try mockEnv.createMockScript(at: mockEnv.emulatorPath, echoing: "")

        let env = mockEnv.environment()

        let command = try TestMessageCommand.parse([])

        let (result, messages) = try await runValidator { queue in
            try await checkAVDExists(
                command: command,
                androidHome: androidHome,
                environment: env,
                avdName: "TestAVD",
                out: queue
            )
        }

        XCTAssertFalse(result)
        // StreamingCommand.run() generates a message block with timing info
        XCTAssertEqual(messages.count, 1)
    }

    /// AVD exists - should skip creation
    func testCheckAVDExistsReturnsTrueWhenPresent() async throws {
        let androidHome = mockEnv.androidHome

        // Create mock emulator script that returns list including TestAVD
        try mockEnv.createMockScript(at: mockEnv.emulatorPath, echoing: """
            OtherAVD
            TestAVD
            AnotherAVD
            """)

        let env = mockEnv.environment()

        let command = try TestMessageCommand.parse([])

        let (result, _) = try await runValidator { queue in
            try await checkAVDExists(
                command: command,
                androidHome: androidHome,
                environment: env,
                avdName: "TestAVD",
                out: queue
            )
        }

        XCTAssertTrue(result)
    }

    /// AVD with similar name exists - should not match partial names
    func testCheckAVDExistsReturnsFalseForDifferentName() async throws {
        let androidHome = mockEnv.androidHome

        // Create mock emulator script that returns other AVDs but not TestAVD
        try mockEnv.createMockScript(at: mockEnv.emulatorPath, echoing: """
            OtherAVD
            AnotherAVD
            """)

        let env = mockEnv.environment()

        let command = try TestMessageCommand.parse([])

        let (result, _) = try await runValidator { queue in
            try await checkAVDExists(
                command: command,
                androidHome: androidHome,
                environment: env,
                avdName: "TestAVD",
                out: queue
            )
        }

        XCTAssertFalse(result)
    }

    /// emulator command fails - should throw error, not assume no AVDs
    func testCheckAVDExistsThrowsWhenCommandFails() async throws {
        let androidHome = mockEnv.androidHome

        // Create mock emulator script that fails with an error
        try mockEnv.createMockScript(at: mockEnv.emulatorPath, content: "exit 1")

        let env = mockEnv.environment()

        let command = try TestMessageCommand.parse([])

        await XCTAssertThrowsErrorAsync(
            { _ = try await runValidator { queue in
                try await checkAVDExists(
                    command: command,
                    androidHome: androidHome,
                    environment: env,
                    avdName: "TestAVD",
                    out: queue
                )
            }}
        ) { error in
            XCTAssertTrue(error is EmulatorListAVDsError, "Expected EmulatorListAVDsError but got \(type(of: error))")
            XCTAssertTrue(error.localizedDescription.contains("emulator -list-avds"))
        }
    }

    // MARK: - Emulator Path Validation Tests

    func testFindEmulatorPathSucceedsWhenPresent() async throws {
        let androidHome = mockEnv.androidHome

        try mockEnv.createMockScript(at: mockEnv.emulatorPath, echoing: "Android emulator version 34.2.0.0")

        let (result, messages) = try await runValidator { queue in
            try await findEmulatorPath(androidHome: androidHome, out: queue)
        }

        XCTAssertEqual(result, mockEnv.emulatorPath)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.status, MessageBlock.Status.pass)
    }

    /// Emulator binary not found - should fail with clear error
    func testFindEmulatorPathFailsWhenMissing() async {
        let androidHome = mockEnv.androidHome
        try? FileManager.default.createDirectory(atPath: androidHome, withIntermediateDirectories: true)

        await XCTAssertThrowsErrorAsync(
            { _ = try await runValidator { queue in
                try await findEmulatorPath(androidHome: androidHome, out: queue)
            }}
        ) { error in
            XCTAssertTrue(error is EmulatorNotFoundError)
        }
    }
    
    // MARK: - Integration Test
    
    /// Test AndroidEmulatorCreateCommand.performCommand validates environment
    /// Uses a bootstrap SDK manager that generates sdkmanager, avdmanager, and emulator
    func testAndroidEmulatorCreateCommandPerformCommand() async throws {
        let androidHome = mockEnv.androidHome

        // Create the ANDROID_HOME directory (required for validation)
        try FileManager.default.createDirectory(atPath: androidHome, withIntermediateDirectories: true)

        // Create bootstrap sdkmanager (also creates avdmanager and emulator as bootstrap scripts)
        try mockEnv.createMockBootstrapSdkmanager()

        try mockEnv.createMockJava(version: "17.0.8")

        let env = mockEnv.environment()

        var command = try AndroidEmulatorCreateCommand.parse([])
        command.env = env

        let stream = MessageStream { continuation in
            Task {
                let messageQueue = MessageQueue(retain: true, continuation: continuation)
                do {
                    try await command.performCommand(with: messageQueue)
                    await messageQueue.finish()
                } catch {
                    await messageQueue.finish(throwing: error)
                }
            }
        }

        var messages: [String] = []
        for try await message in stream {
            if let msg = message.message(term: .plain) {
                messages.append(msg)
            }
        }

        XCTAssertGreaterThan(messages.count, 0, "performCommand should generate messages")
        let javaMessages = messages.filter { $0.contains("Java") || $0.contains("java") }
        XCTAssertGreaterThan(javaMessages.count, 0, "Java validation should run")
        let androidHomeMessages = messages.filter { $0.contains("ANDROID_HOME") }
        XCTAssertGreaterThan(androidHomeMessages.count, 0, "ANDROID_HOME validation should run")
    }
}
