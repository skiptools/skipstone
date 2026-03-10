// Copyright (c) 2023 - 2026 Skip
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import SkipBuild
import TSCBasic
import Universal

final class SkipstoneCommandTests: XCTestCase {

    // MARK: - resolveSourceFileOutputPath Tests

    /// Kotlin files should be placed under the kotlin output folder with package-derived subdirectories.
    func testSourceFileOutputPath_KotlinFile() throws {
        let kotlinFolder = try AbsolutePath(validating: "/output/kotlin")
        let javaFolder = try AbsolutePath(validating: "/output/java")

        let result = try SkipstoneSession.resolveSourceFileOutputPath(
            for: "MyClass.kt",
            packageName: "skip.foundation",
            kotlinFolder: kotlinFolder,
            javaFolder: javaFolder,
            manifestName: "AndroidManifest.xml",
            basePath: nil)

        XCTAssertEqual(result?.pathString, "/output/kotlin/skip/foundation/MyClass.kt")
    }

    /// Java files should be placed under the java output folder with package-derived subdirectories.
    func testSourceFileOutputPath_JavaFile() throws {
        let kotlinFolder = try AbsolutePath(validating: "/output/kotlin")
        let javaFolder = try AbsolutePath(validating: "/output/java")

        let result = try SkipstoneSession.resolveSourceFileOutputPath(
            for: "Helper.java",
            packageName: "skip.model",
            kotlinFolder: kotlinFolder,
            javaFolder: javaFolder,
            manifestName: "AndroidManifest.xml",
            basePath: nil)

        XCTAssertEqual(result?.pathString, "/output/java/skip/model/Helper.java")
    }

    /// skip.yml files should be excluded from output (returns nil).
    func testSourceFileOutputPath_SkipYml() throws {
        let kotlinFolder = try AbsolutePath(validating: "/output/kotlin")
        let javaFolder = try AbsolutePath(validating: "/output/java")

        let result = try SkipstoneSession.resolveSourceFileOutputPath(
            for: "skip.yml",
            packageName: "skip.ui",
            kotlinFolder: kotlinFolder,
            javaFolder: javaFolder,
            manifestName: "AndroidManifest.xml",
            basePath: nil)

        XCTAssertNil(result)
    }

    /// AndroidManifest.xml should be placed one level up from the type-specific folder.
    func testSourceFileOutputPath_AndroidManifest() throws {
        let kotlinFolder = try AbsolutePath(validating: "/output/kotlin")
        let javaFolder = try AbsolutePath(validating: "/output/java")

        let result = try SkipstoneSession.resolveSourceFileOutputPath(
            for: "AndroidManifest.xml",
            packageName: "skip.ui",
            kotlinFolder: kotlinFolder,
            javaFolder: javaFolder,
            manifestName: "AndroidManifest.xml",
            basePath: nil)

        // AndroidManifest goes up one level from java folder (since it's not .kt)
        XCTAssertEqual(result?.pathString, "/output/AndroidManifest.xml")
    }

    /// When basePath is provided, files should be placed relative to it.
    func testSourceFileOutputPath_WithBasePath() throws {
        let kotlinFolder = try AbsolutePath(validating: "/output/kotlin")
        let javaFolder = try AbsolutePath(validating: "/output/java")
        let basePath = try AbsolutePath(validating: "/custom/path")

        let result = try SkipstoneSession.resolveSourceFileOutputPath(
            for: "Override.kt",
            packageName: "skip.ui",
            kotlinFolder: kotlinFolder,
            javaFolder: javaFolder,
            manifestName: "AndroidManifest.xml",
            basePath: basePath)

        XCTAssertEqual(result?.pathString, "/custom/path/Override.kt")
    }

    /// Deep package names should create nested subdirectories.
    func testSourceFileOutputPath_DeepPackage() throws {
        let kotlinFolder = try AbsolutePath(validating: "/output/kotlin")
        let javaFolder = try AbsolutePath(validating: "/output/java")

        let result = try SkipstoneSession.resolveSourceFileOutputPath(
            for: "File.kt",
            packageName: "com.example.deep.package",
            kotlinFolder: kotlinFolder,
            javaFolder: javaFolder,
            manifestName: "AndroidManifest.xml",
            basePath: nil)

        XCTAssertEqual(result?.pathString, "/output/kotlin/com/example/deep/package/File.kt")
    }

    // MARK: - resolveModuleMode Tests

    /// Explicit "native" mode in config should return .native.
    func testModuleMode_Native() throws {
        let config = try makeSkipConfig(mode: "native")
        let configMap: [String: SkipConfig] = ["TestModule": config]

        let result = SkipstoneSession.resolveModuleMode(
            moduleName: nil, configMap: configMap,
            baseConfig: config, hasSkipFuse: false,
            primaryModuleName: "TestModule")

        XCTAssertEqual(result, .native)
    }

    /// Explicit "transpiled" mode should return .transpiled.
    func testModuleMode_Transpiled() throws {
        let config = try makeSkipConfig(mode: "transpiled")
        let configMap: [String: SkipConfig] = ["TestModule": config]

        let result = SkipstoneSession.resolveModuleMode(
            moduleName: nil, configMap: configMap,
            baseConfig: config, hasSkipFuse: false,
            primaryModuleName: "TestModule")

        XCTAssertEqual(result, .transpiled)
    }

    /// Automatic mode with SkipFuse present should return .native for the primary module.
    func testModuleMode_AutomaticWithFuse() throws {
        let config = try makeSkipConfig(mode: nil)
        let configMap: [String: SkipConfig] = ["TestModule": config, "SkipFuse": config]

        let result = SkipstoneSession.resolveModuleMode(
            moduleName: nil, configMap: configMap,
            baseConfig: config, hasSkipFuse: true,
            primaryModuleName: "TestModule")

        XCTAssertEqual(result, .native)
    }

    /// Automatic mode without SkipFuse should return .transpiled.
    func testModuleMode_AutomaticWithoutFuse() throws {
        let config = try makeSkipConfig(mode: nil)
        let configMap: [String: SkipConfig] = ["TestModule": config]

        let result = SkipstoneSession.resolveModuleMode(
            moduleName: nil, configMap: configMap,
            baseConfig: config, hasSkipFuse: false,
            primaryModuleName: "TestModule")

        XCTAssertEqual(result, .transpiled)
    }

    /// Automatic mode with SkipFuse for a non-primary module should return .transpiled.
    func testModuleMode_AutomaticWithFuseNonPrimary() throws {
        let config = try makeSkipConfig(mode: nil)
        let configMap: [String: SkipConfig] = ["OtherModule": config, "SkipFuse": config]

        let result = SkipstoneSession.resolveModuleMode(
            moduleName: "OtherModule", configMap: configMap,
            baseConfig: config, hasSkipFuse: true,
            primaryModuleName: "TestModule")

        XCTAssertEqual(result, .transpiled)
    }

    // MARK: - isTestModule Tests

    /// The primary module itself should not be considered a test module.
    func testIsTestModule_SameModule() {
        XCTAssertFalse(SkipstoneSession.isTestModule("MyModule", primaryModuleName: "MyModule"))
    }

    /// The test peer (primary name without "Tests" suffix) should not be a test module.
    func testIsTestModule_TestPeer() {
        XCTAssertFalse(SkipstoneSession.isTestModule("MyModule", primaryModuleName: "MyModuleTests"))
    }

    /// A different module should be considered a test module.
    func testIsTestModule_DifferentModule() {
        XCTAssertTrue(SkipstoneSession.isTestModule("SkipFoundation", primaryModuleName: "MyModule"))
    }

    /// SkipUnit should be considered a test module for any primary module.
    func testIsTestModule_SkipUnit() {
        XCTAssertTrue(SkipstoneSession.isTestModule("SkipUnit", primaryModuleName: "MyModule"))
    }

    // MARK: - identifyStaleFiles Tests

    /// When all snapshot files are still in output, there should be no stale files.
    func testIdentifyStaleFiles_NoStale() {
        let snapshot = [
            URL(fileURLWithPath: "/output/File1.kt"),
            URL(fileURLWithPath: "/output/File2.kt"),
        ]
        let outputFiles = [
            try! AbsolutePath(validating: "/output/File1.kt"),
            try! AbsolutePath(validating: "/output/File2.kt"),
        ]

        let stale = SkipstoneSession.identifyStaleFiles(snapshot: snapshot, outputFiles: outputFiles)
        XCTAssertTrue(stale.isEmpty)
    }

    /// Files in snapshot but not in output should be identified as stale.
    func testIdentifyStaleFiles_WithStale() {
        let snapshot = [
            URL(fileURLWithPath: "/output/File1.kt"),
            URL(fileURLWithPath: "/output/OldFile.kt"),
            URL(fileURLWithPath: "/output/File2.kt"),
        ]
        let outputFiles = [
            try! AbsolutePath(validating: "/output/File1.kt"),
            try! AbsolutePath(validating: "/output/File2.kt"),
        ]

        let stale = SkipstoneSession.identifyStaleFiles(snapshot: snapshot, outputFiles: outputFiles)
        XCTAssertEqual(stale, Set(["/output/OldFile.kt"]))
    }

    /// An empty snapshot should produce no stale files.
    func testIdentifyStaleFiles_EmptySnapshot() {
        let stale = SkipstoneSession.identifyStaleFiles(snapshot: [], outputFiles: [])
        XCTAssertTrue(stale.isEmpty)
    }

    // MARK: - categorizeSourceFiles Tests

    /// In transpiled mode, all files should be in the transpile list.
    func testCategorizeSourceFiles_Transpiled() {
        let urls = [
            URL(fileURLWithPath: "/src/A.swift"),
            URL(fileURLWithPath: "/src/B.swift"),
        ]

        let (transpile, swift) = SkipstoneSession.categorizeSourceFiles(sourceURLs: urls, isNative: false)

        XCTAssertEqual(transpile.count, 2)
        XCTAssertTrue(swift.isEmpty)
        // Should be sorted
        XCTAssertEqual(transpile, transpile.sorted())
    }

    /// In native mode, all files should be in the swift (bridge) list.
    func testCategorizeSourceFiles_Native() {
        let urls = [
            URL(fileURLWithPath: "/src/A.swift"),
            URL(fileURLWithPath: "/src/B.swift"),
        ]

        let (transpile, swift) = SkipstoneSession.categorizeSourceFiles(sourceURLs: urls, isNative: true)

        XCTAssertTrue(transpile.isEmpty)
        XCTAssertEqual(swift.count, 2)
        XCTAssertEqual(swift, swift.sorted())
    }

    /// Empty source list should produce empty results.
    func testCategorizeSourceFiles_Empty() {
        let (transpile, swift) = SkipstoneSession.categorizeSourceFiles(sourceURLs: [], isNative: false)
        XCTAssertTrue(transpile.isEmpty)
        XCTAssertTrue(swift.isEmpty)
    }

    // MARK: - mergeGradleProperties Tests

    /// Default properties should be parsed and output sorted.
    func testMergeGradleProperties_DefaultsOnly() {
        let defaults = """
        org.gradle.jvmargs=-Xmx4g
        android.useAndroidX=true
        kotlin.code.style=official
        """

        let result = SkipstoneSession.mergeGradleProperties(defaults: defaults, custom: nil)

        XCTAssertTrue(result.contains("android.useAndroidX=true"))
        XCTAssertTrue(result.contains("kotlin.code.style=official"))
        XCTAssertTrue(result.contains("org.gradle.jvmargs=-Xmx4g"))
    }

    /// Custom properties should override defaults.
    func testMergeGradleProperties_WithOverrides() {
        let defaults = """
        org.gradle.jvmargs=-Xmx4g
        android.useAndroidX=true
        """

        let result = SkipstoneSession.mergeGradleProperties(
            defaults: defaults,
            custom: ["org.gradle.jvmargs": "-Xmx8g"])

        XCTAssertTrue(result.contains("org.gradle.jvmargs=-Xmx8g"))
        XCTAssertFalse(result.contains("org.gradle.jvmargs=-Xmx4g"))
    }

    /// Custom properties should add new entries.
    func testMergeGradleProperties_CustomAdded() {
        let defaults = """
        org.gradle.jvmargs=-Xmx4g
        """

        let result = SkipstoneSession.mergeGradleProperties(
            defaults: defaults,
            custom: ["custom.prop": "value"])

        XCTAssertTrue(result.contains("custom.prop=value"))
        XCTAssertTrue(result.contains("org.gradle.jvmargs=-Xmx4g"))
    }

    /// Comments and blank lines in defaults should be ignored.
    func testMergeGradleProperties_IgnoresComments() {
        let defaults = """
        # This is a comment
        key1=value1

        key2=value2
        """

        let result = SkipstoneSession.mergeGradleProperties(defaults: defaults, custom: nil)

        XCTAssertTrue(result.contains("key1=value1"))
        XCTAssertTrue(result.contains("key2=value2"))
        XCTAssertFalse(result.contains("#"))
    }

    /// Output should be sorted by key.
    func testMergeGradleProperties_Sorted() {
        let defaults = """
        zebra=last
        alpha=first
        middle=mid
        """

        let result = SkipstoneSession.mergeGradleProperties(defaults: defaults, custom: nil)

        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["alpha=first", "middle=mid", "zebra=last"])
    }

    // MARK: - buildResourceEntries Tests

    /// When no config resources and no resource URLs, should return empty.
    func testBuildResourceEntries_EmptyResources() throws {
        let config = try makeSkipConfig(mode: nil)
        let result = try SkipstoneSession.buildResourceEntries(
            config: config, resourceURLs: [], projectBaseURL: URL(fileURLWithPath: "/project"))

        XCTAssertTrue(result.isEmpty)
    }

    /// When resource URLs exist but no config, should fall back to default Resources/ entry.
    func testBuildResourceEntries_FallbackToResources() throws {
        let config = try makeSkipConfig(mode: nil)
        let resourceURLs = [URL(fileURLWithPath: "/project/Resources/file.txt")]

        let result = try SkipstoneSession.buildResourceEntries(
            config: config, resourceURLs: resourceURLs, projectBaseURL: URL(fileURLWithPath: "/project"))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.path, "Resources")
        XCTAssertFalse(result.first?.isCopyMode ?? true)
    }

    // MARK: - filterExportYAML Tests

    /// Blocks with export:false should be removed.
    func testFilterExportYAML_RemovesExportFalse() throws {
        let yaml: YAML = .object([
            "key1": .string("value1"),
            "export": .boolean(false),
        ])

        let result = SkipstoneSession.filterExportYAML(yaml)
        XCTAssertNil(result)
    }

    /// Blocks without export:false should be preserved.
    func testFilterExportYAML_PreservesNonExportBlocks() throws {
        let yaml: YAML = .object([
            "key1": .string("value1"),
            "key2": .string("value2"),
        ])

        let result = SkipstoneSession.filterExportYAML(yaml)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.object?["key1"]?.string, "value1")
    }

    /// Nested blocks with export:false should be removed from arrays.
    func testFilterExportYAML_FiltersNestedArrayItems() throws {
        let yaml: YAML = .array([
            .object(["key1": .string("keep")]),
            .object(["export": .boolean(false), "key2": .string("remove")]),
            .object(["key3": .string("also keep")]),
        ])

        let result = SkipstoneSession.filterExportYAML(yaml)
        XCTAssertNotNil(result)
        let array = result?.array
        XCTAssertEqual(array?.count, 2)
    }

    /// Scalar values should pass through unchanged.
    func testFilterExportYAML_ScalarPassthrough() throws {
        let yaml: YAML = .string("hello")
        let result = SkipstoneSession.filterExportYAML(yaml)
        XCTAssertEqual(result?.string, "hello")
    }

    // MARK: - Helpers

    /// Creates a minimal SkipConfig with an optional mode for testing.
    private func makeSkipConfig(mode: String?) throws -> SkipConfig {
        if let mode {
            let json: Universal.JSON = .object(["skip": .object(["mode": .string(mode)])])
            return try json.decode()
        } else {
            return try Universal.JSON.object([:]).decode()
        }
    }
}
