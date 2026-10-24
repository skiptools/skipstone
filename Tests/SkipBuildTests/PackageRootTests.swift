// Copyright (c) 2026 Skip
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
import TSCBasic
@testable import SkipBuild

final class PackageRootTests: XCTestCase {
    func testTargetPackageRoots() throws {
        let fs = InMemoryFileSystem()
        let root = try AbsolutePath(validating: "/component")
        let tests = root.appending(component: "Tests")
        try fs.createDirectory(tests, recursive: true)
        for package in [root, tests] {
            try fs.writeFileContents(package.appending(component: "Package.swift")) { $0.write("// package") }
        }

        XCTAssertEqual(root, try SkipstoneCommand.packageRoot(containing: root.appending(components: "Sources", "Component"), fs: fs))
        XCTAssertEqual(tests, try SkipstoneCommand.packageRoot(containing: tests.appending(component: "ComponentTests"), fs: fs))
        XCTAssertEqual(root, try SkipstoneCommand.packageRoot(containing: root.appending(components: "Custom", "Deep", "Target"), fs: fs))
    }

    func testSourceEnumerationFollowsTargetDirectorySymlink() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("OriginalTarget")
        let link = root.appendingPathComponent("MirroredTarget")
        try manager.createDirectory(at: target.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try "first".write(to: target.appendingPathComponent("First.swift"), atomically: true, encoding: .utf8)
        try "second".write(to: target.appendingPathComponent("Nested/Second.swift"), atomically: true, encoding: .utf8)
        try "external".write(to: root.appendingPathComponent("ExternalSource.swift"), atomically: true, encoding: .utf8)
        try manager.createSymbolicLink(at: target.appendingPathComponent("External.swift"), withDestinationURL: root.appendingPathComponent("ExternalSource.swift"))
        try manager.createSymbolicLink(at: link, withDestinationURL: target)

        let sources = try manager.enumeratedURLs(of: link)
        XCTAssertEqual(Set(sources), Set([link.appendingPathComponent("First.swift"), link.appendingPathComponent("Nested/Second.swift"), link.appendingPathComponent("External.swift")]))
        XCTAssertEqual(try String(contentsOf: link.appendingPathComponent("Nested/Second.swift"), encoding: .utf8), "second")
    }

    func testMissingManifestFails() throws {
        XCTAssertThrowsError(try SkipstoneCommand.packageRoot(containing: AbsolutePath(validating: "/missing/Target"), fs: InMemoryFileSystem()))
    }
}
