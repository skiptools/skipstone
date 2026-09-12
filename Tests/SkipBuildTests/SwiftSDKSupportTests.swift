// Copyright (c) 2023 - 2026 Skip
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import SkipBuild

final class SwiftSDKSupportTests: XCTestCase {
    func testWebAssemblySDKIdentifiers() {
        let inventory = SwiftSDKInventory(output: "swift-6.3-RELEASE-wasm32-unknown-wasip1\nswift-6.2-RELEASE-android-0.1")

        XCTAssertTrue(inventory.supports(.webAssembly))
        XCTAssertEqual(SwiftSDKKind(identifier: "swift-6.3-RELEASE-wasm32-unknown-wasip1"), .webAssembly)
        XCTAssertEqual(SwiftSDKKind(identifier: "swift-6.2-RELEASE-android-0.1"), .android)
    }

    func testNonWebAssemblySDKIdentifiers() {
        let inventory = SwiftSDKInventory(output: "swift-6.2-RELEASE-android-0.1\nswift-6.3-RELEASE-linux")

        XCTAssertFalse(inventory.supports(.webAssembly))
        XCTAssertEqual(SwiftSDKKind(identifier: "swift-6.3-RELEASE-linux"), .other)
    }
}
