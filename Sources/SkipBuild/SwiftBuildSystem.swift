// Copyright (c) 2023 - 2026 Skip
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import ArgumentParser

/// The SwiftPM build engine used for an underlying `swift build` invocation.
///
/// SwiftPM ships two build engines side by side: the original `native` engine and
/// the Swift Build (`swiftbuild`) engine. Swift 6.3 defaults to `native`; Swift 6.4
/// flips the default to `swiftbuild` and deprecates `native`. The engines lay their
/// build products out differently, so Skip pins the choice explicitly rather than
/// inheriting whatever default the current toolchain happens to have:
///
///     native:     <scratch>/<target-triple>/<configuration>
///     swiftbuild: <scratch>/out/Products/<Configuration>[-<platform>]
///
/// Note that the `swiftbuild` product directory carries no architecture component,
/// so cross-compiling several Android ABIs through a single scratch directory would
/// have them overwrite one another. `AndroidCommand` gives each architecture its own
/// scratch directory when this engine is in use.
enum SwiftBuildSystem: String, CaseIterable, ExpressibleByArgument {
    /// Let Skip choose: `native` while the toolchain still offers it, otherwise `swiftbuild`.
    case auto
    /// The original SwiftPM build engine (deprecated as of Swift 6.4).
    case native
    /// The Swift Build engine (the default as of Swift 6.4).
    case swiftbuild

    /// The value to pass to `swift build --build-system`, or `nil` for `auto`.
    var argumentValue: String? {
        self == .auto ? nil : rawValue
    }

    /// The environment variable that forces the build engine for nested Skip invocations.
    ///
    /// The Android Swift build for an app runs as a `skip android build` child process launched by
    /// the generated gradle project, and that generated command pins its own `--build-system` value
    /// (gradle files generated before this option existed pin `native`). A pinned value is
    /// indistinguishable from a typed flag by the time the child command parses it, so an outer
    /// command such as `skip checkup --build-system swiftbuild` cannot express its choice as an
    /// argument. Setting this variable overrides the engine for every nested build, whatever the
    /// generated gradle happens to pin.
    static let environmentKey = "SKIP_BUILD_SYSTEM"

    /// The build engine forced by `SKIP_BUILD_SYSTEM`, or `auto` when it is unset or unrecognized.
    static func fromEnvironment() -> SwiftBuildSystem {
        guard let value = ProcessInfo.processInfo.environment[environmentKey] else { return .auto }
        return SwiftBuildSystem(rawValue: value.lowercased()) ?? .auto
    }

    /// Resolve `auto` against the capabilities of the given `swift` executable.
    ///
    /// `native` is preferred while it remains available. The `swiftbuild` engine
    /// normalizes the Android target triple (`aarch64-unknown-linux-android28` becomes
    /// `aarch64-unknown-linux28.0.0-android`), for which the currently released Swift
    /// Android SDKs carry no modules, and it promotes SwiftPM's "static product linked
    /// by two dynamic products" warning into a hard error. Once a toolchain stops
    /// offering `native`, `swiftbuild` is used instead.
    func resolved(swift swiftCommand: String) async -> SwiftBuildSystem {
        await resolved(swiftCommand: [swiftCommand])
    }

    /// Resolve `auto` for a multi-part swift command such as `["xcrun", "swift"]`.
    func resolved(swiftCommand: [String]) async -> SwiftBuildSystem {
        guard self == .auto else { return self }
        return await SwiftBuildSystemProbe.shared.supportsNative(swiftCommand: swiftCommand) ? .native : .swiftbuild
    }
}

extension SwiftBuildSystem {
    /// The `--build-system` arguments for a build that targets the host/Darwin, or `[]` when the
    /// toolchain offers no choice.
    ///
    /// These deliberately ignore `SKIP_BUILD_SYSTEM`, which selects the engine for Android
    /// cross-compilation. A Skip Fuse package graph embeds shared library products such as
    /// SkipLib and SkipFoundation into several dynamic products at once, which the `swiftbuild`
    /// engine rejects outright ("is linked as a static library by … This will result in
    /// duplication of library code") whereas `native` only warned. Until every framework package
    /// ships the SKIP_DYNAMIC_LIBRARIES support that makes those products dynamic, Apple-platform
    /// builds must stay on `native`; without this pin they silently switch engines — and start
    /// failing — the moment the toolchain default changes under them, as it does in Swift 6.4.
    static func hostBuildArguments(swiftCommand: [String] = ["swift"]) async -> [String] {
        guard let value = await SwiftBuildSystem.auto.resolved(swiftCommand: swiftCommand).argumentValue else {
            return []
        }
        return ["--build-system", value]
    }
}

/// Caches, per `swift` executable, whether `swift build --build-system native` is still accepted.
actor SwiftBuildSystemProbe {
    static let shared = SwiftBuildSystemProbe()

    private var cache: [String: Bool] = [:]

    func supportsNative(swiftCommand: [String]) async -> Bool {
        let key = swiftCommand.joined(separator: " ")
        if let cached = cache[key] { return cached }
        let supported = Self.probeNativeSupport(swiftCommand: swiftCommand)
        cache[key] = supported
        return supported
    }

    /// Ask `swift build --help` whether `native` is still listed as a `--build-system` value.
    /// If the help text cannot be read, assume `native` is available, which matches the
    /// behavior of every toolchain Skip supports today.
    private static func probeNativeSupport(swiftCommand: [String]) -> Bool {
        guard let launchPath = swiftCommand.first else { return true }
        let prefix = Array(swiftCommand.dropFirst())
        guard let help = runCapturingOutput(launchPath, prefix + ["build", "--help"]) else { return true }
        guard let optionRange = help.range(of: "--build-system") else { return true }
        // the enumerated values follow the option, before the next option's description
        let valueList = help[optionRange.upperBound...].prefix(600)
        return valueList.contains("native")
    }

    private static func runCapturingOutput(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        if launchPath.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: launchPath)
        } else {
            // resolve bare tool names (e.g. "xcrun") through the environment
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [launchPath]
        }
        process.arguments = (process.arguments ?? []) + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
