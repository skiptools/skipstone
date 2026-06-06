// Copyright (c) 2023 - 2026 Skip
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
@testable import SkipSyntax
import XCTest

/// Tests for `@_exported import` umbrella re-export support.
///
/// When a Swift module marks an import as `@_exported`, types from the imported module are
/// visible to code that imports the umbrella module without naming the underlying one. The
/// transpiler needs to emit the matching Kotlin imports so that the same is true for the
/// transpiled output.
final class ExportedImportTests: XCTestCase {
    /// `CodebaseInfo` records the names of modules re-exported via `@_exported import` so that
    /// dependent modules can pick them up at translation time.
    func testCodebaseInfoRecordsExportedModuleNames() throws {
        let info = try codebaseInfo(moduleName: "Umbrella", swift: """
        @_exported import Inner
        import Other

        public class Wrapped {}
        """)

        XCTAssertEqual(["Inner"], info.exportedModuleNames)
    }

    /// Multiple `@_exported import` declarations stack up, while plain imports do not.
    func testCodebaseInfoRecordsMultipleExportedModuleNames() throws {
        let info = try codebaseInfo(moduleName: "Umbrella", swift: """
        @_exported import InnerA
        @_exported import InnerB
        import Other

        public class Wrapped {}
        """)

        XCTAssertEqual(["InnerA", "InnerB"], info.exportedModuleNames)
    }

    /// A duplicated `@_exported import` of the same module is only recorded once.
    func testCodebaseInfoDeduplicatesExportedModuleNames() throws {
        let info = CodebaseInfo(moduleName: "Umbrella")
        info.gather(from: try syntaxTree(forSwift: """
        @_exported import Inner

        public class FirstFile {}
        """, named: "First"))
        info.gather(from: try syntaxTree(forSwift: """
        @_exported import Inner

        public class SecondFile {}
        """, named: "Second"))
        info.prepareForUse()

        XCTAssertEqual(["Inner"], info.exportedModuleNames)
    }

    /// A `ModuleExport` round-trip through JSON preserves `exportedModuleNames`.
    func testModuleExportRoundTrip() throws {
        let info = try codebaseInfo(moduleName: "Umbrella", swift: """
        @_exported import Inner
        """)
        let original = CodebaseInfo.ModuleExport(of: info)
        XCTAssertEqual(["Inner"], original.exportedModuleNames)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CodebaseInfo.ModuleExport.self, from: data)
        XCTAssertEqual(["Inner"], decoded.exportedModuleNames)
    }

    /// A `ModuleExport` without `exportedModuleNames` (older skipcode.json) decodes with an empty list,
    /// preserving backwards compatibility.
    func testModuleExportBackwardsCompatibleDecoding() throws {
        let legacyJSON = #"{"m":"Legacy","p":"legacy"}"#
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(CodebaseInfo.ModuleExport.self, from: data)
        XCTAssertEqual("Legacy", decoded.moduleName)
        XCTAssertEqual("legacy", decoded.packageName)
        XCTAssertEqual([], decoded.exportedModuleNames)
    }

    /// A `ModuleExport` with no `@_exported import`s should omit the `x` key entirely,
    /// matching skipcode.json files produced by older skipstone versions.
    func testModuleExportEncodingOmitsEmptyExportedModuleNames() throws {
        let info = try codebaseInfo(moduleName: "Plain", swift: """
        public class A {}
        """)
        let export = CodebaseInfo.ModuleExport(of: info)
        XCTAssertEqual([], export.exportedModuleNames)

        let data = try JSONEncoder().encode(export)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("\"x\""), "Expected the 'x' (exportedModuleNames) key to be omitted when empty; got: \(json)")
    }

    /// Importing an umbrella module that re-exports another module in Swift should produce
    /// Kotlin imports for both the umbrella package and the re-exported package.
    func testTranspiledImportPullsInExportedModule() async throws {
        let inner = try CodebaseInfo.ModuleExport(of: codebaseInfo(moduleName: "Inner", swift: """
        public class InnerType {
            public init() {}
            public func value() -> Int { return 0 }
        }
        """))
        let umbrella = try CodebaseInfo.ModuleExport(of: codebaseInfo(moduleName: "Umbrella", swift: """
        @_exported import Inner

        public class UmbrellaType {
            public init() {}
        }
        """))

        try await check(dependentModules: [inner, umbrella], swift: """
        import Umbrella

        func f() -> Int {
            return InnerType().value()
        }
        """, kotlin: """
        import umbrella.module.*
        import inner.module.*

        internal fun f(): Int = InnerType().value()
        """)
    }

    /// `@_exported` propagation walks through chains: if A re-exports B and B re-exports C,
    /// then `import A` should pull in B and C.
    func testTranspiledImportPullsInTransitivelyExportedModules() async throws {
        let inner = try CodebaseInfo.ModuleExport(of: codebaseInfo(moduleName: "Inner", swift: """
        public class InnerType {
            public init() {}
            public func value() -> Int { return 0 }
        }
        """))
        let middle = try CodebaseInfo.ModuleExport(of: codebaseInfo(moduleName: "Middle", swift: """
        @_exported import Inner

        public class MiddleType { public init() {} }
        """))
        let umbrella = try CodebaseInfo.ModuleExport(of: codebaseInfo(moduleName: "Umbrella", swift: """
        @_exported import Middle

        public class UmbrellaType { public init() {} }
        """))

        try await check(dependentModules: [inner, middle, umbrella], swift: """
        import Umbrella

        func f() -> Int {
            return InnerType().value()
        }
        """, kotlin: """
        import umbrella.module.*
        import middle.module.*
        import inner.module.*

        internal fun f(): Int = InnerType().value()
        """)
    }

    /// A plain (non-`@_exported`) `import` should not be propagated when the importer is used elsewhere.
    func testPlainImportIsNotPropagated() async throws {
        let inner = try CodebaseInfo.ModuleExport(of: codebaseInfo(moduleName: "Inner", swift: """
        public class InnerType { public init() {} }
        """))
        let umbrella = try CodebaseInfo.ModuleExport(of: codebaseInfo(moduleName: "Umbrella", swift: """
        import Inner

        public class UmbrellaType { public init() {} }
        """))

        try await check(dependentModules: [inner, umbrella], swift: """
        import Umbrella

        func f() -> UmbrellaType {
            return UmbrellaType()
        }
        """, kotlin: """
        import umbrella.module.*

        internal fun f(): UmbrellaType = UmbrellaType()
        """)
    }

    // MARK: - Helpers

    private func codebaseInfo(moduleName: String, swift: String) throws -> CodebaseInfo {
        let codebaseInfo = CodebaseInfo(moduleName: moduleName)
        codebaseInfo.gather(from: try syntaxTree(forSwift: swift, named: moduleName))
        codebaseInfo.prepareForUse()
        return codebaseInfo
    }

    private func syntaxTree(forSwift swift: String, named name: String) throws -> SyntaxTree {
        let srcFile = try tmpFile(named: "Source_\(name).swift", contents: swift)
        let source = Source(file: Source.FilePath(path: srcFile.path), content: swift)
        return SyntaxTree(source: source)
    }
}
