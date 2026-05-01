// Copyright (c) 2023 - 2026 Skip
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import SkipBuild

final class SkipBuildTests: XCTestCase {
    func testANSIColors() {
        XCTAssertEqual(0, Term.stripANSIAttributes(from: "").count)
        XCTAssertEqual(1, Term.stripANSIAttributes(from: "A").count)

        XCTAssertEqual(12, Term(colors: true).green("ABC").count)
        XCTAssertEqual(3, Term.stripANSIAttributes(from: Term(colors: true).green("ABC")).count)
    }

    func testSHA256() throws {
        do {
            let tmpFile = URL(fileURLWithPath: NSTemporaryDirectory().appending("/" + UUID().uuidString))
            try "Hello World".write(to: tmpFile, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tmpFile) }
            XCTAssertEqual("a591a6d40bf420404a011733cfb7b190d62c65bf0bcda32b57b277d9ad9f146e", try tmpFile.SHA256Hash())
        }

        do {
            let msg = "".data(using: .utf8)!
            let result = msg.SHA256Hash()
            let expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" // echo -n "" | openssl dgst -sha256
            XCTAssertEqual(result, expected, "Invalid conversion from msg to sha256")
        }

        do {
            let msg = "foobar".data(using: .utf8)!
            let result = msg.SHA256Hash()
            let expected = "c3ab8ff13720e8ad9047dd39466b3c8974e592c2fa383d4a3960714caef0c4f2" // echo -n "foobar" | openssl dgst -sha256
            XCTAssertEqual(result, expected, "Invalid conversion from msg to sha256")
        }

        do {
            let msg = "æøå".data(using: .utf8)!
            let result = msg.SHA256Hash()
            let expected = "6c228cdba89548a1af198f33819536422fb01b66e51f761cf2ec38d1fb4178a6" // echo -n "æøå" | openssl dgst -sha256
            XCTAssertEqual(result, expected, "Invalid conversion from msg to sha256")
        }

        do {
            let msg = "KfZ=Day*q4MsZ=_xRy4G_Uefk?^Ytr&2xL*RYY%VLyB_&c7R_dr&J+8A79suf=^".data(using: .utf8)!
            let result = msg.SHA256Hash()
            let expected = "b754632a872b3f5ddb0e1e24b531e35eb334ee3c2957618ac4a2ac4047ed6127" // echo -n "KfZ=Day*q4MsZ=_xRy4G_Uefk?^Ytr&2xL*RYY%VLyB_&c7R_dr&J+8A79suf=^" | openssl dgst -sha256
            XCTAssertEqual(result, expected, "Invalid conversion from msg to sha256")
        }

        do {
            let msg = "Lorem ipsum dolor sit amet, suas consequuntur mei ad, duo eu noluisse adolescens temporibus. Mutat fuisset constituam te vis. Animal meliore cu has, ius ad recusabo complectitur. Eam at persius inermis sensibus. Mea at velit nobis dolor, vitae omnium eos an, ei dolorum pertinacia nec.".data(using: .utf8)!
            let result = msg.SHA256Hash()
            let expected = "31902eb17aa07165b645553c14b985c1908c7d8f4f5178de61a3232f09940df7" // echo -n "Lorem ipsum dolor sit amet, suas consequuntur mei ad, duo eu noluisse adolescens temporibus. Mutat fuisset constituam te vis. Animal meliore cu has, ius ad recusabo complectitur. Eam at persius inermis sensibus. Mea at velit nobis dolor, vitae omnium eos an, ei dolorum pertinacia nec." | openssl dgst -sha256
            XCTAssertEqual(result, expected, "Invalid conversion from msg to sha256")
        }

        do {
            let msg = "0".data(using: .utf8)!
            let result = msg.SHA256Hash()
            let expected = "5feceb66ffc86f38d952786c6d696c79c2dbc239dd4e91b46729d73a27fb57e9" // echo -n "0" | openssl dgst -sha256
            XCTAssertEqual(result, expected, "Invalid conversion from msg to sha256")
        }
    }

    func testPadString() {
        XCTAssertEqual("a", "abc".pad(1))
        XCTAssertEqual("ab", "abc".pad(2))
        XCTAssertEqual("abc", "abc".pad(3))
        XCTAssertEqual("abc ", "abc".pad(4))
        XCTAssertEqual("abc  ", "abc".pad(5))
    }

    func testExtract() throws {
        XCTAssertEqual("c", try "abc".extract(pattern: "ab(.*)"))
        XCTAssertEqual("345", try "12345 abc".extract(pattern: "12([0-9]+)"))
    }

    func testRegex() throws {
        XCTAssertEqual(["345"], try NSRegularExpression(pattern: "12([0-9]+)").extract(from: "12345 abc"))
        XCTAssertEqual(nil, try NSRegularExpression(pattern: "([a-zA-Z]+)([0-9]+)").extract(from: ""))
        XCTAssertEqual(["A", "1"], try NSRegularExpression(pattern: "([a-zA-Z]+)([0-9]+)").extract(from: "A1"))
        XCTAssertEqual(["xA", "19"], try NSRegularExpression(pattern: "([a-zA-Z]+)\\s([0-9]+)").extract(from: "xA 19"))
    }

    func testSlide() {
        XCTAssertEqual(["A"], ["A"].slice(0))
        XCTAssertEqual([], ["A"].slice(1))
        XCTAssertEqual(["A"], ["A"].slice(0, 1))
        XCTAssertEqual(["A"], ["A"].slice(0, 9))
        XCTAssertEqual([], ["A"].slice(1, 2))
        XCTAssertEqual([], ["A"].slice(5))
        XCTAssertEqual([], ["A"].slice(8, 3))

        XCTAssertEqual([0, 1, 2, 3, 4, 5, 6, 7, 8, 9], [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].slice(0))
        XCTAssertEqual([1, 2, 3, 4, 5, 6, 7, 8, 9], [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].slice(1))
        XCTAssertEqual([0], [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].slice(0, 1))
        XCTAssertEqual([0, 1, 2, 3, 4, 5, 6, 7, 8], [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].slice(0, 9))
        XCTAssertEqual([1], [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].slice(1, 2))
        XCTAssertEqual([5, 6, 7, 8, 9], [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].slice(5))
    }

    func testCreateIcon() async throws {
        #if canImport(ImageIO)
        for size in [10, 100, 1024] {
            do { // square
                let expectedIconSize = size == 10 ? 250 : size == 100 ? 4591 : 208601 // note: implementation details may change
                let iconData = try await createAppIcon(width: size, height: size, circular: false, foreground: nil, backgroundColors: ["#4994EC"], foregroundColor: nil, iconSources: [], iconShadow: nil, iconInset: 0.02)
                XCTAssertEqual(iconData.count, expectedIconSize)
            }

            do { // circular
                let expectedIconSize = size == 10 ? 291 : size == 100 ? 5262 : 262667 // note: implementation details may change
                let iconData = try await createAppIcon(width: size, height: size, circular: true, foreground: nil, backgroundColors: ["#ABABAB"], foregroundColor: nil, iconSources: [], iconShadow: nil, iconInset: 0.02)
                XCTAssertEqual(iconData.count, expectedIconSize)
            }
        }

        setenv("CORESVG_VERBOSE", "1", 1)
        XCTAssertNil(SVG("<XXX></XXX>"), "should not have been able to create invalid SVG") // CoreSVG: Error: Reader: Error on line 0: Root XML node does not have "SVG" type

        let svg1 = try XCTUnwrap(SVG("<svg width='12' height='12'></svg>"), "could not create SVG")
        XCTAssertEqual(12.0, svg1.size.width)
        XCTAssertEqual(12.0, svg1.size.height)

        let svg2 = try XCTUnwrap(SVG(MaterialIcon.icon_chess.rawValue), "could not create SVG")
        XCTAssertEqual(40.0, svg2.size.width)
        #endif
    }

    func testParseXCConfig() {
        let keyValues = parseXCConfig(contents: """
        # Comment
        A = B

        // Comment 2
        Some Key   =   __somevalue;;;
        """)

        XCTAssertEqual(Dictionary(uniqueKeysWithValues: keyValues), [
            "A": "B",
            "Some Key": "__somevalue;;;"
        ])
    }

    func testParseModule() throws {
        let pmod = try PackageModule(parse: "Foo:skip-model/SkipModel")
        XCTAssertEqual("Foo", pmod.moduleName)
        XCTAssertEqual(1, pmod.dependencies.count)
        XCTAssertEqual("skip-model", pmod.dependencies.first?.repositoryName)
        XCTAssertEqual("SkipModel", pmod.dependencies.first?.moduleName)
    }

    // MARK: - Meta Generate Tests

    func testGitRemoteToHTTPS() {
        XCTAssertEqual("https://github.com/Org/Repo", MetaIndexCommand.gitRemoteToHTTPS("https://github.com/Org/Repo.git"))
        XCTAssertEqual("https://github.com/Org/Repo", MetaIndexCommand.gitRemoteToHTTPS("git@github.com:Org/Repo.git"))
        XCTAssertEqual("https://github.com/Org/Repo", MetaIndexCommand.gitRemoteToHTTPS("https://github.com/Org/Repo"))
        XCTAssertEqual("https://gitlab.com/Org/Repo", MetaIndexCommand.gitRemoteToHTTPS("git@gitlab.com:Org/Repo.git"))
    }

    func testParseGitOriginURL() throws {
        let cmd = MetaIndexCommand()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try """
        [core]
        \trepositoryformatversion = 0
        \tfilemode = true
        [remote "origin"]
        \turl = https://github.com/Example/MyApp.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [branch "main"]
        \tremote = origin
        """.write(to: tmpDir.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)

        let url = cmd.parseGitOriginURL(projectRoot: tmpDir)
        XCTAssertEqual(url, "https://github.com/Example/MyApp.git")
    }

    func testLocaleNormalization() {
        XCTAssertEqual("zh-CN", MetaIndexCommand.normalizeLocale("zh-Hans"))
        XCTAssertEqual("zh-TW", MetaIndexCommand.normalizeLocale("zh-Hant"))
        XCTAssertEqual("zh-TW", MetaIndexCommand.normalizeLocale("zh-Hant-TW"))
        XCTAssertEqual("zh-HK", MetaIndexCommand.normalizeLocale("zh-Hant-HK"))
        XCTAssertEqual("ar", MetaIndexCommand.normalizeLocale("ar-SA"))
        XCTAssertEqual("no-NO", MetaIndexCommand.normalizeLocale("nb-NO"))
        XCTAssertEqual("iw-IL", MetaIndexCommand.normalizeLocale("he-IL"))
        XCTAssertEqual("en-US", MetaIndexCommand.normalizeLocale("en-US"))
        XCTAssertEqual("fr-FR", MetaIndexCommand.normalizeLocale("fr-FR"))
        XCTAssertEqual("pt-BR", MetaIndexCommand.normalizeLocale("pt-BR"))
        XCTAssertEqual("pt-PT", MetaIndexCommand.normalizeLocale("pt-PT"))
        XCTAssertEqual("de-DE", MetaIndexCommand.normalizeLocale("de-DE"))
    }

    func testMetadataKeyNormalization() {
        XCTAssertEqual("description", MetaIndexCommand.normalizeMetadataKey("full_description", platform: .android))
        XCTAssertEqual("subtitle", MetaIndexCommand.normalizeMetadataKey("short_description", platform: .android))
        XCTAssertEqual("title", MetaIndexCommand.normalizeMetadataKey("title", platform: .android))
        XCTAssertEqual("releaseNotes", MetaIndexCommand.normalizeMetadataKey("release_notes", platform: .ios))
        XCTAssertEqual("privacyURL", MetaIndexCommand.normalizeMetadataKey("privacy_url", platform: .ios))
        XCTAssertEqual("supportURL", MetaIndexCommand.normalizeMetadataKey("support_url", platform: .ios))
        XCTAssertEqual("subtitle", MetaIndexCommand.normalizeMetadataKey("subtitle", platform: .ios))
    }

    func testParseSkipEnv() throws {
        let cmd = MetaIndexCommand()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let envFile = tmpDir.appendingPathComponent("Skip.env")
        try """
        PRODUCT_NAME = TestApp
        PRODUCT_BUNDLE_IDENTIFIER = com.example.test
        MARKETING_VERSION = 1.2.3
        CURRENT_PROJECT_VERSION = 42
        ANDROID_APPLICATION_ID = com.example.test.android
        APPLE_APP_STORE_ID = 123456789
        GOOGLE_PLAY_STORE_ID = com.example.test
        """.write(to: envFile, atomically: true, encoding: .utf8)

        let env = try cmd.parseSkipEnv(at: envFile)
        XCTAssertEqual(env["PRODUCT_NAME"], "TestApp")
        XCTAssertEqual(env["PRODUCT_BUNDLE_IDENTIFIER"], "com.example.test")
        XCTAssertEqual(env["MARKETING_VERSION"], "1.2.3")
        XCTAssertEqual(env["CURRENT_PROJECT_VERSION"], "42")
        XCTAssertEqual(env["ANDROID_APPLICATION_ID"], "com.example.test.android")
        XCTAssertEqual(env["APPLE_APP_STORE_ID"], "123456789")
        XCTAssertEqual(env["GOOGLE_PLAY_STORE_ID"], "com.example.test")
    }

    func testParseInfoPlist() throws {
        let cmd = MetaIndexCommand()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let plistFile = tmpDir.appendingPathComponent("Info.plist")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>ITSAppUsesNonExemptEncryption</key>
            <false/>
            <key>NSLocationWhenInUseUsageDescription</key>
            <string>We need your location for nearby search</string>
            <key>NSCameraUsageDescription</key>
            <string>We need camera access for photos</string>
        </dict>
        </plist>
        """.write(to: plistFile, atomically: true, encoding: .utf8)

        let info = try cmd.parseInfoPlist(at: plistFile)
        XCTAssertEqual(info["ITSAppUsesNonExemptEncryption"] as? Bool, false)

        // Without xcstrings: descriptions use the default locale
        let permissions = try cmd.extractIOSPermissions(at: plistFile, xcstringsURL: nil)
        XCTAssertEqual(permissions.count, 2)
        let permKeys = permissions.compactMap { $0["key"] as? String }.sorted()
        XCTAssertEqual(permKeys, ["NSCameraUsageDescription", "NSLocationWhenInUseUsageDescription"])
        let cameraDesc = permissions.first(where: { $0["key"] as? String == "NSCameraUsageDescription" })?["description"] as? [String: String]
        XCTAssertEqual(cameraDesc?["en-US"], "We need camera access for photos")

        // With xcstrings: translations are merged in
        let xcstringsFile = tmpDir.appendingPathComponent("InfoPlist.xcstrings")
        try """
        {
          "sourceLanguage" : "en",
          "strings" : {
            "NSCameraUsageDescription" : {
              "localizations" : {
                "fr" : {
                  "stringUnit" : {
                    "state" : "translated",
                    "value" : "Accès caméra pour les photos"
                  }
                },
                "zh-Hans" : {
                  "stringUnit" : {
                    "state" : "translated",
                    "value" : "需要相机权限来拍照"
                  }
                }
              }
            }
          },
          "version" : "1.0"
        }
        """.write(to: xcstringsFile, atomically: true, encoding: .utf8)

        let localizedPerms = try cmd.extractIOSPermissions(at: plistFile, xcstringsURL: xcstringsFile)
        let cameraPerm = localizedPerms.first(where: { $0["key"] as? String == "NSCameraUsageDescription" })
        let cameraDescs = cameraPerm?["description"] as? [String: String]
        XCTAssertEqual(cameraDescs?["en-US"], "We need camera access for photos")
        XCTAssertEqual(cameraDescs?["fr"], "Accès caméra pour les photos")
        XCTAssertEqual(cameraDescs?["zh-CN"], "需要相机权限来拍照")  // zh-Hans normalized to zh-CN
    }

    func testParseAndroidManifest() throws {
        let cmd = MetaIndexCommand()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manifestFile = tmpDir.appendingPathComponent("AndroidManifest.xml")
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <manifest xmlns:android="http://schemas.android.com/apk/res/android">
            <!-- <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/> -->
            <uses-permission android:name="android.permission.INTERNET" />
            <uses-permission android:name="android.permission.CAMERA" />
            <application
                android:label="${PRODUCT_NAME}"
                android:name=".AndroidAppMain">
            </application>
        </manifest>
        """.write(to: manifestFile, atomically: true, encoding: .utf8)

        let permissions = try cmd.extractAndroidPermissions(at: manifestFile)
        // Should only include non-commented permissions
        XCTAssertEqual(permissions.count, 2)
        XCTAssertEqual(permissions[0]["key"], "android.permission.INTERNET")
        XCTAssertEqual(permissions[1]["key"], "android.permission.CAMERA")

        let meta = try cmd.parseAndroidManifest(at: manifestFile)
        XCTAssertEqual(meta["label"] as? String, "${PRODUCT_NAME}")
    }

    func testParseFastlaneMetadata() throws {
        let cmd = MetaIndexCommand()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create Android-style metadata structure
        let metaDir = tmpDir.appendingPathComponent("metadata/android")
        let enDir = metaDir.appendingPathComponent("en-US")
        let frDir = metaDir.appendingPathComponent("fr-FR")
        let zhDir = metaDir.appendingPathComponent("zh-Hans")
        try FileManager.default.createDirectory(at: enDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zhDir, withIntermediateDirectories: true)

        try "My App".write(to: enDir.appendingPathComponent("title.txt"), atomically: true, encoding: .utf8)
        try "A great app".write(to: enDir.appendingPathComponent("full_description.txt"), atomically: true, encoding: .utf8)
        try "Great".write(to: enDir.appendingPathComponent("short_description.txt"), atomically: true, encoding: .utf8)

        try "Mon App".write(to: frDir.appendingPathComponent("title.txt"), atomically: true, encoding: .utf8)
        try "Une super app".write(to: frDir.appendingPathComponent("full_description.txt"), atomically: true, encoding: .utf8)

        try "My App Chinese".write(to: zhDir.appendingPathComponent("title.txt"), atomically: true, encoding: .utf8)

        let result = cmd.parseFastlaneMetadata(folder: metaDir, platform: .android)

        // Check title across locales
        XCTAssertEqual(result["title"]?["en-US"], "My App")
        XCTAssertEqual(result["title"]?["fr-FR"], "Mon App")
        // zh-Hans should be normalized to zh-CN
        XCTAssertEqual(result["title"]?["zh-CN"], "My App Chinese")

        // Check description (full_description → "description")
        XCTAssertEqual(result["description"]?["en-US"], "A great app")
        XCTAssertEqual(result["description"]?["fr-FR"], "Une super app")

        // Check short description
        XCTAssertEqual(result["subtitle"]?["en-US"], "Great")
    }

    func testParseEntitlements() throws {
        let cmd = MetaIndexCommand()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let entFile = tmpDir.appendingPathComponent("Entitlements.plist")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.developer.aps-environment</key>
            <string>production</string>
            <key>com.apple.security.app-sandbox</key>
            <true/>
        </dict>
        </plist>
        """.write(to: entFile, atomically: true, encoding: .utf8)

        let entitlements = try cmd.parseEntitlements(at: entFile)
        XCTAssertEqual(entitlements["com.apple.developer.aps-environment"] as? String, "production")
        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
    }

    func testMetaGenerateCatalogStructure() throws {
        // Test that a generated catalog from a mock project has the expected structure.
        // We can't call generateAppCatalog directly (needs parseSwiftPackage), but we
        // can test that building iOS/Android metadata dictionaries produces correct output.
        let cmd = MetaIndexCommand()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a minimal app project structure
        let fm = FileManager.default
        try fm.createDirectory(at: tmpDir.appendingPathComponent("Sources/TestApp/Skip"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmpDir.appendingPathComponent("Sources/TestApp/Resources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmpDir.appendingPathComponent("Tests/TestAppTests"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmpDir.appendingPathComponent("Darwin/Sources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmpDir.appendingPathComponent("Darwin/TestApp.xcodeproj"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmpDir.appendingPathComponent("Darwin/Assets.xcassets/AccentColor.colorset"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmpDir.appendingPathComponent("Darwin/Assets.xcassets/AppIcon.appiconset"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmpDir.appendingPathComponent("Darwin/fastlane/metadata/en-US"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmpDir.appendingPathComponent("Darwin/fastlane/metadata/fr-FR"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmpDir.appendingPathComponent("Android/app/src/main/kotlin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmpDir.appendingPathComponent("Android/fastlane/metadata/android/en-US"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmpDir.appendingPathComponent("Android/gradle/wrapper"), withIntermediateDirectories: true)

        // Required files
        try "".write(to: tmpDir.appendingPathComponent("Sources/TestApp/Skip/skip.yml"), atomically: true, encoding: .utf8)
        try "".write(to: tmpDir.appendingPathComponent("Sources/TestApp/Resources/Localizable.xcstrings"), atomically: true, encoding: .utf8)
        try "".write(to: tmpDir.appendingPathComponent("Darwin/Sources/Main.swift"), atomically: true, encoding: .utf8)
        try "".write(to: tmpDir.appendingPathComponent("Darwin/TestApp.xcconfig"), atomically: true, encoding: .utf8)
        try "".write(to: tmpDir.appendingPathComponent("Darwin/TestApp.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        try "{}".write(to: tmpDir.appendingPathComponent("Darwin/Assets.xcassets/Contents.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: tmpDir.appendingPathComponent("Darwin/Assets.xcassets/AccentColor.colorset/Contents.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: tmpDir.appendingPathComponent("Darwin/Assets.xcassets/AppIcon.appiconset/Contents.json"), atomically: true, encoding: .utf8)
        try "".write(to: tmpDir.appendingPathComponent("Android/gradle.properties"), atomically: true, encoding: .utf8)
        try "".write(to: tmpDir.appendingPathComponent("Android/settings.gradle.kts"), atomically: true, encoding: .utf8)
        try "".write(to: tmpDir.appendingPathComponent("Android/app/build.gradle.kts"), atomically: true, encoding: .utf8)
        try "".write(to: tmpDir.appendingPathComponent("Android/app/proguard-rules.pro"), atomically: true, encoding: .utf8)

        // Skip.env
        try """
        PRODUCT_NAME = TestApp
        PRODUCT_BUNDLE_IDENTIFIER = com.example.testapp
        MARKETING_VERSION = 2.0.0
        CURRENT_PROJECT_VERSION = 10
        APPLE_APP_STORE_ID = 9876543
        GOOGLE_PLAY_STORE_ID = com.example.testapp
        """.write(to: tmpDir.appendingPathComponent("Skip.env"), atomically: true, encoding: .utf8)

        // Info.plist with a permission
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>ITSAppUsesNonExemptEncryption</key>
            <false/>
            <key>NSPhotoLibraryUsageDescription</key>
            <string>Access photos for sharing</string>
        </dict>
        </plist>
        """.write(to: tmpDir.appendingPathComponent("Darwin/Info.plist"), atomically: true, encoding: .utf8)

        // Entitlements
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.developer.aps-environment</key>
            <string>development</string>
        </dict>
        </plist>
        """.write(to: tmpDir.appendingPathComponent("Darwin/Entitlements.plist"), atomically: true, encoding: .utf8)

        // AndroidManifest.xml
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <manifest xmlns:android="http://schemas.android.com/apk/res/android">
            <uses-permission android:name="android.permission.INTERNET" />
            <uses-permission android:name="android.permission.CAMERA" />
            <application android:label="${PRODUCT_NAME}" android:name=".AndroidAppMain">
            </application>
        </manifest>
        """.write(to: tmpDir.appendingPathComponent("Android/app/src/main/AndroidManifest.xml"), atomically: true, encoding: .utf8)

        // iOS fastlane metadata
        try "TestApp".write(to: tmpDir.appendingPathComponent("Darwin/fastlane/metadata/en-US/title.txt"), atomically: true, encoding: .utf8)
        try "A test app".write(to: tmpDir.appendingPathComponent("Darwin/fastlane/metadata/en-US/description.txt"), atomically: true, encoding: .utf8)
        try "TestApp FR".write(to: tmpDir.appendingPathComponent("Darwin/fastlane/metadata/fr-FR/title.txt"), atomically: true, encoding: .utf8)

        // Android fastlane metadata
        try "TestApp".write(to: tmpDir.appendingPathComponent("Android/fastlane/metadata/android/en-US/title.txt"), atomically: true, encoding: .utf8)
        try "A test app for Android".write(to: tmpDir.appendingPathComponent("Android/fastlane/metadata/android/en-US/full_description.txt"), atomically: true, encoding: .utf8)

        // Build the project layout (with no URL checks since this is a test)
        let appProject = AppProjectLayout(moduleName: "TestApp", root: tmpDir, check: AppProjectLayout.noURLChecks)
        let env = try cmd.parseSkipEnv(at: appProject.skipEnv)

        // Build iOS metadata
        let ios = try cmd.buildIOSMetadata(appProject: appProject, projectRoot: tmpDir, productName: env["PRODUCT_NAME"]!, bundleId: env["PRODUCT_BUNDLE_IDENTIFIER"]!, version: env["MARKETING_VERSION"]!, buildNumber: env["CURRENT_PROJECT_VERSION"]!, appleStoreId: env["APPLE_APP_STORE_ID"])

        XCTAssertEqual(ios["bundleIdentifier"] as? String, "com.example.testapp")
        XCTAssertEqual(ios["version"] as? String, "2.0.0")
        XCTAssertEqual(ios["appStoreId"] as? String, "9876543")
        XCTAssertEqual(ios["appStoreURL"] as? String, "https://apps.apple.com/app/id9876543")

        // Check iOS permissions
        let iosPerms = ios["permissions"] as? [[String: Any]]
        XCTAssertEqual(iosPerms?.count, 1)
        XCTAssertEqual(iosPerms?.first?["key"] as? String, "NSPhotoLibraryUsageDescription")
        let photoDesc = iosPerms?.first?["description"] as? [String: String]
        XCTAssertEqual(photoDesc?["en-US"], "Access photos for sharing")

        // Check iOS entitlements
        let entitlements = ios["entitlements"] as? [String: Any]
        XCTAssertEqual(entitlements?["com.apple.developer.aps-environment"] as? String, "development")

        // Check iOS localized metadata
        let iosTitle = ios["title"] as? [String: String]
        XCTAssertEqual(iosTitle?["en-US"], "TestApp")
        XCTAssertEqual(iosTitle?["fr-FR"], "TestApp FR")

        // Build Android metadata
        let android = try cmd.buildAndroidMetadata(appProject: appProject, projectRoot: tmpDir, productName: env["PRODUCT_NAME"]!, bundleId: env["PRODUCT_BUNDLE_IDENTIFIER"]!, androidAppId: nil, version: env["MARKETING_VERSION"]!, buildNumber: env["CURRENT_PROJECT_VERSION"]!, googlePlayStoreId: env["GOOGLE_PLAY_STORE_ID"])

        XCTAssertEqual(android["applicationId"] as? String, "com.example.testapp")
        XCTAssertEqual(android["playStoreId"] as? String, "com.example.testapp")

        // Check Android permissions
        let androidPerms = android["permissions"] as? [[String: String]]
        XCTAssertEqual(androidPerms?.count, 2)
        XCTAssertEqual(androidPerms?[0]["key"], "android.permission.INTERNET")
        XCTAssertEqual(androidPerms?[1]["key"], "android.permission.CAMERA")

        // Check Android localized metadata
        let androidTitle = android["title"] as? [String: String]
        XCTAssertEqual(androidTitle?["en-US"], "TestApp")
        let androidDesc = android["description"] as? [String: String]
        XCTAssertEqual(androidDesc?["en-US"], "A test app for Android")
    }

    func testPNGDimensionParsing() {
        // Construct a minimal valid PNG: 8-byte signature + IHDR chunk
        // IHDR: 4-byte length (13) + "IHDR" + 4-byte width + 4-byte height + 5 bytes (bit depth, color type, etc.)
        var png = Data()
        // PNG signature
        png.append(contentsOf: [137, 80, 78, 71, 13, 10, 26, 10] as [UInt8])
        // IHDR chunk length: 13 bytes
        png.append(contentsOf: [0, 0, 0, 13] as [UInt8])
        // IHDR type
        png.append(contentsOf: [73, 72, 68, 82] as [UInt8]) // "IHDR"
        // Width: 320 (0x00000140)
        png.append(contentsOf: [0, 0, 1, 64] as [UInt8])
        // Height: 480 (0x000001E0)
        png.append(contentsOf: [0, 0, 1, 224] as [UInt8])
        // bit depth, color type, compression, filter, interlace
        png.append(contentsOf: [8, 6, 0, 0, 0] as [UInt8])

        let (width, height) = ImageResourceRef.parsePNGDimensions(png)
        XCTAssertEqual(width, 320)
        XCTAssertEqual(height, 480)

        // Invalid data should return (0, 0)
        let (w2, h2) = ImageResourceRef.parsePNGDimensions(Data([0, 1, 2]))
        XCTAssertEqual(w2, 0)
        XCTAssertEqual(h2, 0)
    }

    func testImageResourceRefFromPNG() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a minimal PNG file
        var png = Data()
        png.append(contentsOf: [137, 80, 78, 71, 13, 10, 26, 10] as [UInt8])
        png.append(contentsOf: [0, 0, 0, 13] as [UInt8])
        png.append(contentsOf: [73, 72, 68, 82] as [UInt8])
        png.append(contentsOf: [0, 0, 4, 0] as [UInt8])   // 1024
        png.append(contentsOf: [0, 0, 4, 0] as [UInt8])   // 1024
        png.append(contentsOf: [8, 6, 0, 0, 0] as [UInt8])

        let iconFile = tmpDir.appendingPathComponent("icon.png")
        try png.write(to: iconFile)

        let ref = try XCTUnwrap(ImageResourceRef.from(pngURL: iconFile, relativeTo: tmpDir))
        XCTAssertEqual(ref.width, 1024)
        XCTAssertEqual(ref.height, 1024)
        XCTAssertEqual(ref.location, "icon.png")
        XCTAssertEqual(ref.mimeType, "image/png")
        XCTAssertEqual(ref.size, Int64(png.count))
        XCTAssertFalse(ref.hash.isEmpty)
    }

    func testParseSwiftToolchainAPI() async throws {
        let staticLinuxSDKs = try await SwiftSDKOpenAPI.fetchSDKs(sdkName: "static")
        let staticDownloadURL = "https://download.swift.org/swift-6.2.3-release/static-sdk/swift-6.2.3-RELEASE/swift-6.2.3-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz"
        XCTAssertTrue(staticLinuxSDKs.contains(where: { $0.downloadURL.absoluteString == staticDownloadURL }), "missing expected path in: \(staticLinuxSDKs)")

        let wasmSDKs = try await SwiftSDKOpenAPI.fetchSDKs(sdkName: "wasm")
        let wasmDownloadURL = "https://download.swift.org/swift-6.2.3-release/wasm-sdk/swift-6.2.3-RELEASE/swift-6.2.3-RELEASE_wasm.artifactbundle.tar.gz"
        XCTAssertTrue(wasmSDKs.contains(where: { $0.downloadURL.absoluteString == wasmDownloadURL }), "missing expected path in: \(wasmSDKs)")

        let wasmDevSDKs = try await SwiftSDKOpenAPI.fetchSDKs(sdkName: "wasm", forDevelVersion: "6.2")
        let wasmDevDownloadURL = "https://download.swift.org/swift-6.2-branch/wasm-sdk/swift-6.2-DEVELOPMENT-SNAPSHOT-2025-12-03-a/swift-6.2-DEVELOPMENT-SNAPSHOT-2025-12-03-a_wasm.artifactbundle.tar.gz"
        XCTAssertTrue(wasmDevSDKs.contains(where: { $0.downloadURL.absoluteString == wasmDevDownloadURL }), "missing expected path in: \(wasmDevSDKs)")

        let androidDevelopmentDownloadURL = "https://download.swift.org/development/android-sdk/swift-DEVELOPMENT-SNAPSHOT-2025-12-17-a/swift-DEVELOPMENT-SNAPSHOT-2025-12-17-a_android.artifactbundle.tar.gz"
        let androidDevSDKs = try await SwiftSDKOpenAPI.fetchSDKs(sdkName: "android", forDevelVersion: "main")
        XCTAssertTrue(androidDevSDKs.contains(where: { $0.downloadURL.absoluteString == androidDevelopmentDownloadURL }), "missing expected path in: \(androidDevSDKs)")

        let androidDev63DownloadURL = "https://download.swift.org/swift-6.3-branch/android-sdk/swift-6.3-DEVELOPMENT-SNAPSHOT-2025-12-18-a/swift-6.3-DEVELOPMENT-SNAPSHOT-2025-12-18-a_android.artifactbundle.tar.gz"
        let androidDev63SDKs = try await SwiftSDKOpenAPI.fetchSDKs(sdkName: "android", forDevelVersion: "6.3")
        XCTAssertTrue(androidDev63SDKs.contains(where: { $0.downloadURL.absoluteString == androidDev63DownloadURL }), "missing expected path in: \(androidDev63SDKs)")
    }
}

