// Copyright (c) 2023 - 2026 Skip
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import SkipBuild

final class WebCommandTests: XCTestCase {
    func testHTMLTemplateProvidesResponsiveMountAndBootstrap() {
        let html = WebHostTemplate.html(title: "My <Skip> App", bootstrapModule: "bootstrap/index.js")

        XCTAssertTrue(html.contains("<main id=\"skip-root\""))
        XCTAssertTrue(html.contains("<title>My &lt;Skip&gt; App</title>"))
        XCTAssertTrue(html.contains("await import(\"./bootstrap/index.js\")"))
        XCTAssertTrue(html.contains("await bootstrap.init()"))
        XCTAssertTrue(html.contains("min-height: 100dvh"))
        XCTAssertTrue(html.contains("@media (min-width: 600px)"))
        XCTAssertTrue(html.contains("@media (min-width: 840px)"))
        XCTAssertTrue(html.contains("safe-area-inset-bottom"))
    }

    func testManifestContainsMountAndBreakpoints() {
        let manifest = WebHostTemplate.manifest(title: "A \"web\" app", bootstrapModule: "main\\app.js")

        XCTAssertTrue(manifest.contains("\"title\": \"A \\\"web\\\" app\""))
        XCTAssertTrue(manifest.contains("\"bootstrap\": \"main\\\\app.js\""))
        XCTAssertTrue(manifest.contains("\"mount\": \"#skip-root\""))
        XCTAssertTrue(manifest.contains("\"compact\": 600"))
        XCTAssertTrue(manifest.contains("\"medium\": 840"))
    }
}
