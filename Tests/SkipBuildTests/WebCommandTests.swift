// Copyright (c) 2023 - 2026 Skip
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import SkipBuild

final class WebCommandTests: XCTestCase {
    func testHTMLTemplateProvidesMountPointAndBootstrap() {
        let html = WebHostTemplate.html(title: "My <Skip> App", bootstrapModule: "bootstrap/app.js")

        XCTAssertTrue(html.contains("<main id=\"skip-root\""))
        XCTAssertTrue(html.contains("<title>My &lt;Skip&gt; App</title>"))
        XCTAssertTrue(html.contains("import * as app from \"./bootstrap/app.js\""))
        XCTAssertTrue(html.contains("app.start(document.getElementById(\"skip-root\"))"))

        let escapedModule = WebHostTemplate.html(title: "App", bootstrapModule: "bootstrap/\"app.js")
        XCTAssertTrue(escapedModule.contains("import * as app from \"./bootstrap/\\\"app.js\""))
    }

    func testManifestEscapesJSONValues() {
        let manifest = WebHostTemplate.manifest(title: "A \"web\" app", bootstrapModule: "main\\app.js")

        XCTAssertTrue(manifest.contains("\"title\": \"A \\\"web\\\" app\""))
        XCTAssertTrue(manifest.contains("\"bootstrap\": \"main\\\\app.js\""))
        XCTAssertTrue(manifest.contains("\"mount\": \"#skip-root\""))
    }
}
