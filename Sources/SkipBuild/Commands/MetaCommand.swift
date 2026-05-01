// Copyright (c) 2023 - 2026 Skip
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import ArgumentParser
import SkipSyntax
import TSCBasic

#if canImport(SkipDriveExternal)
import SkipDriveExternal
extension MetaIndexCommand : GradleHarness { }
fileprivate let metaCommandEnabled = true
#else
fileprivate let metaCommandEnabled = false
#endif

// MARK: - Container Command

@available(macOS 13, iOS 16, tvOS 16, watchOS 8, *)
struct MetaCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "meta",
        abstract: "App metadata and SBOM tools",
        discussion: """
        Commands for generating app metadata catalogs and Software Bill of Materials (SBOM).
        """,
        shouldDisplay: metaCommandEnabled,
        subcommands: [
            MetaIndexCommand.self,
            SBOMCommand.self,
        ])
}

// MARK: - Generate Subcommand

@available(macOS 13, iOS 16, tvOS 16, watchOS 8, *)
struct MetaIndexCommand: MessageCommand, ToolOptionsCommand {
    static var configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Generate a JSON metadata index for the app",
        usage: """
# generate app metadata to stdout
skip meta index

# write to a file
skip meta index -O appindex.json

# include SBOM in the output
skip meta index --sbom -O appindex.json
""",
        discussion: """
Generate a structured JSON document containing all user-facing metadata for a Skip app, \
including localized titles and descriptions from fastlane metadata, app permissions \
from Info.plist and AndroidManifest.xml, version information from Skip.env, \
and optionally a Software Bill of Materials (SBOM) for each platform.

The output uses Android/Play Store locale codes (e.g. "zh-CN" instead of Apple's "zh-Hans").
""",
        shouldDisplay: metaCommandEnabled)

    @OptionGroup(title: "Output Options")
    var outputOptions: OutputOptions

    @OptionGroup(title: "Tool Options")
    var toolOptions: ToolOptions

    @Option(name: [.customShort("O"), .customLong("catalog-output")], help: ArgumentHelp("Write catalog JSON to the given file instead of stdout", valueName: "path"))
    var catalogOutput: String?

    @Option(help: ArgumentHelp("Project folder", valueName: "dir"))
    var project: String = "."

    @Flag(help: ArgumentHelp("Include SBOM in the output"))
    var sbom: Bool = false

    func performCommand(with out: MessageQueue) async {
        await withLogStream(with: out) {
            try await runMetaGenerate(with: out)
        }
    }

    func runMetaGenerate(with out: MessageQueue) async throws {
        let projectURL = URL(fileURLWithPath: self.project).standardized
        let catalog = try await generateAppCatalog(projectURL: projectURL, includeSBOM: sbom, with: out)
        let jsonData = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

        if let outputPath = catalogOutput {
            let outputURL = URL(fileURLWithPath: outputPath)
            try jsonData.write(to: outputURL)
            await out.write(status: .pass, "Wrote app catalog to \(outputPath)")
        } else {
            // Write to stdout
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
            }
        }
    }

    // MARK: - Catalog Generation

    func generateAppCatalog(projectURL: URL, includeSBOM: Bool, with out: MessageQueue) async throws -> [String: Any] {
        let packageJSON = try await parseSwiftPackage(with: out, at: projectURL.path)
        return try await AppIndexGenerator.generateAppIndex(projectURL: projectURL, packageJSON: packageJSON, includeSBOM: includeSBOM, command: self, out: out)
    }

    // MARK: - Skip.env Parsing

    func parseSkipEnv(at url: URL) throws -> [String: String] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        var env: [String: String] = [:]
        for (key, value) in parseXCConfig(contents: contents) {
            env[key] = value
        }
        return env
    }

    // MARK: - iOS Metadata

    func buildIOSMetadata(appProject: AppProjectLayout, projectRoot: URL, productName: String, bundleId: String, version: String, buildNumber: String, appleStoreId: String?) throws -> [String: Any] {
        var ios: [String: Any] = [
            "platform": "ios",
            "bundleIdentifier": bundleId,
            "version": version,
            "buildNumber": buildNumber,
        ]

        if let appleStoreId = appleStoreId, !appleStoreId.isEmpty {
            ios["appStoreId"] = appleStoreId
            ios["appStoreURL"] = "https://apps.apple.com/app/id\(appleStoreId)"
        }

        // Parse Info.plist for permissions and metadata (optional file)
        if FileManager.default.fileExists(atPath: appProject.darwinInfoPlist.path) {
            let infoPlistData = try parseInfoPlist(at: appProject.darwinInfoPlist)
            if !infoPlistData.isEmpty {
                ios["infoPlist"] = infoPlistData
            }
            let permissions = try extractIOSPermissions(at: appProject.darwinInfoPlist)
            if !permissions.isEmpty {
                ios["permissions"] = permissions
            }
        }

        // Parse Entitlements.plist
        if FileManager.default.fileExists(atPath: appProject.darwinEntitlementsPlist.path) {
            let entitlements = try parseEntitlements(at: appProject.darwinEntitlementsPlist)
            if !entitlements.isEmpty {
                ios["entitlements"] = entitlements
            }
        }

        // Parse localized fastlane metadata
        let localizedMeta = parseFastlaneMetadata(folder: appProject.darwinFastlaneMetadataFolder, platform: .ios)
        for (key, locales) in localizedMeta {
            ios[key] = locales
        }

        // App icon: largest PNG in AppIcon.appiconset
        if let iconRef = findLargestPNG(in: appProject.darwinAppIconFolder, relativeTo: projectRoot) {
            ios["icon"] = iconRef.asDictionary
        }

        // Screenshots: Darwin/fastlane/screenshots/{locale}/*.png
        let screenshotDir = appProject.darwinFastlaneFolder.appendingPathComponent("screenshots")
        let screenshots = collectLocalizedScreenshots(folder: screenshotDir, relativeTo: projectRoot)
        if !screenshots.isEmpty {
            ios["screenshots"] = screenshots
        }

        return ios
    }

    // MARK: - Android Metadata

    func buildAndroidMetadata(appProject: AppProjectLayout, projectRoot: URL, productName: String, bundleId: String, androidAppId: String?, version: String, buildNumber: String, googlePlayStoreId: String?) throws -> [String: Any] {
        let effectiveAppId = androidAppId ?? bundleId.replacingOccurrences(of: "-", with: "_")

        var android: [String: Any] = [
            "platform": "android",
            "applicationId": effectiveAppId,
            "version": version,
            "buildNumber": buildNumber,
        ]

        if let googlePlayStoreId = googlePlayStoreId, !googlePlayStoreId.isEmpty {
            android["playStoreId"] = googlePlayStoreId
            android["playStoreURL"] = "https://play.google.com/store/apps/details?id=\(googlePlayStoreId)"
        } else {
            android["playStoreURL"] = "https://play.google.com/store/apps/details?id=\(effectiveAppId)"
        }

        // Parse AndroidManifest.xml for permissions and metadata
        if FileManager.default.fileExists(atPath: appProject.androidManifest.path) {
            let manifestPermissions = try extractAndroidPermissions(at: appProject.androidManifest)
            if !manifestPermissions.isEmpty {
                android["permissions"] = manifestPermissions
            }
            let manifestMeta = try parseAndroidManifest(at: appProject.androidManifest)
            if !manifestMeta.isEmpty {
                android["manifest"] = manifestMeta
            }
        }

        // Parse localized fastlane metadata
        let localizedMeta = parseFastlaneMetadata(folder: appProject.androidFastlaneMetadataFolder, platform: .android)
        for (key, locales) in localizedMeta {
            android[key] = locales
        }

        // App icon: Android/fastlane/metadata/android/en-US/images/icon.png
        let androidIconURL = appProject.androidFastlaneMetadataFolder.appendingPathComponent("en-US/images/icon.png")
        if let iconRef = ImageResourceRef.from(pngURL: androidIconURL, relativeTo: projectRoot) {
            android["icon"] = iconRef.asDictionary
        }

        // Feature graphic: Android/fastlane/metadata/android/{locale}/images/featureGraphic.png
        let featureGraphics = collectLocalizedImages(named: "featureGraphic.png", subpath: "images", metadataFolder: appProject.androidFastlaneMetadataFolder, relativeTo: projectRoot)
        if !featureGraphics.isEmpty {
            android["featureGraphic"] = featureGraphics
        }

        // Screenshots: Android/fastlane/metadata/android/{locale}/images/phoneScreenshots/
        let screenshots = collectAndroidScreenshots(metadataFolder: appProject.androidFastlaneMetadataFolder, relativeTo: projectRoot)
        if !screenshots.isEmpty {
            android["screenshots"] = screenshots
        }

        return android
    }

    // MARK: - Info.plist Parsing

    func parseInfoPlist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw error("Info.plist at \(url.path) is not a valid dictionary plist")
        }
        var result: [String: Any] = [:]
        let includeKeys = ["CFBundleName", "CFBundleDisplayName", "CFBundleShortVersionString", "CFBundleVersion",
                           "ITSAppUsesNonExemptEncryption", "UIRequiredDeviceCapabilities",
                           "UISupportedInterfaceOrientations", "UILaunchStoryboardName",
                           "LSApplicationQueriesSchemes", "CFBundleURLTypes"]
        for key in includeKeys {
            if let value = plist[key] {
                result[key] = value
            }
        }
        return result
    }

    func extractIOSPermissions(at url: URL) throws -> [[String: String]] {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw error("Info.plist at \(url.path) is not a valid dictionary plist")
        }
        var permissions: [[String: String]] = []
        for (key, value) in plist {
            if key.hasSuffix("UsageDescription"), let desc = value as? String {
                permissions.append(["key": key, "description": desc])
            }
        }
        return permissions.sorted { ($0["key"] ?? "") < ($1["key"] ?? "") }
    }

    // MARK: - Entitlements Parsing

    func parseEntitlements(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw error("Entitlements.plist at \(url.path) is not a valid dictionary plist")
        }
        return plist
    }

    // MARK: - AndroidManifest.xml Parsing

    func parseAndroidManifest(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let delegate = AndroidManifestParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            let parseError = parser.parserError.map { ": \($0.localizedDescription)" } ?? ""
            throw error("Failed to parse AndroidManifest.xml at \(url.path)\(parseError)")
        }
        return delegate.metadata
    }

    func extractAndroidPermissions(at url: URL) throws -> [[String: String]] {
        let data = try Data(contentsOf: url)
        let delegate = AndroidManifestParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            let parseError = parser.parserError.map { ": \($0.localizedDescription)" } ?? ""
            throw error("Failed to parse AndroidManifest.xml at \(url.path)\(parseError)")
        }
        return delegate.permissions
    }

    // MARK: - Fastlane Metadata Parsing

    enum MetadataPlatform {
        case ios
        case android
    }

    /// Metadata files we extract from fastlane directories.
    /// iOS: Darwin/fastlane/metadata/{locale}/{file}.txt
    /// Android: Android/fastlane/metadata/android/{locale}/{file}.txt
    static let iosMetadataFiles = ["title", "subtitle", "description", "keywords", "release_notes",
                                   "privacy_url", "support_url", "marketing_url"]
    static let androidMetadataFiles = ["title", "short_description", "full_description"]

    func parseFastlaneMetadata(folder: URL, platform: MetadataPlatform) -> [String: [String: String]] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return [:] }
        guard let locales = try? fm.contentsOfDirectory(atPath: folder.path) else { return [:] }

        let metadataFiles = platform == .ios ? Self.iosMetadataFiles : Self.androidMetadataFiles
        var result: [String: [String: String]] = [:]

        for locale in locales.sorted() {
            let localeDir = folder.appendingPathComponent(locale)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: localeDir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let normalizedLocale = Self.normalizeLocale(locale)

            for fileName in metadataFiles {
                let filePath = localeDir.appendingPathComponent(fileName + ".txt")
                guard fm.fileExists(atPath: filePath.path) else { continue }
                guard let content = try? String(contentsOf: filePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                      !content.isEmpty else { continue }

                let key = Self.normalizeMetadataKey(fileName, platform: platform)
                if result[key] == nil {
                    result[key] = [:]
                }
                result[key]?[normalizedLocale] = content
            }
        }

        return result
    }

    /// Normalize a metadata file name to a common key across platforms.
    static func normalizeMetadataKey(_ fileName: String, platform: MetadataPlatform) -> String {
        switch fileName {
        case "full_description": return "description"
        case "short_description": return "subtitle"
        case "release_notes", "version_whats_new": return "releaseNotes"
        case "privacy_url": return "privacyURL"
        case "support_url": return "supportURL"
        case "marketing_url": return "marketingURL"
        default: return fileName
        }
    }

    // MARK: - Locale Normalization

    /// Normalize Apple/iOS locale codes to Android/Play Store codes.
    /// Apple uses codes like "zh-Hans", "zh-Hant", "pt-BR", "ar-SA".
    /// Android uses codes like "zh-CN", "zh-TW", "pt-BR", "ar".
    /// See: https://support.google.com/googleplay/android-developer/answer/9844778
    static func normalizeLocale(_ locale: String) -> String {
        // Apple script subtag → Android region subtag mappings
        let scriptMappings: [String: String] = [
            "zh-Hans": "zh-CN",
            "zh-Hant": "zh-TW",
            "zh-Hant-TW": "zh-TW",
            "zh-Hant-HK": "zh-HK",
        ]

        if let mapped = scriptMappings[locale] {
            return mapped
        }

        // Apple sometimes uses 3-letter region subtags that Android doesn't use
        let simplifyMappings: [String: String] = [
            "ar-SA": "ar",
            "ca-ES": "ca",
            "cs-CZ": "cs",
            "da-DK": "da",
            "el-GR": "el",
            "fi-FI": "fi",
            "he-IL": "iw-IL",  // Android uses "iw" for Hebrew
            "hi-IN": "hi-IN",
            "hr-HR": "hr",
            "hu-HU": "hu",
            "id-ID": "id",
            "ja-JP": "ja-JP",
            "ko-KR": "ko-KR",
            "ms-MY": "ms-MY",
            "nb-NO": "no-NO",  // Norwegian Bokmal → "no" on Android
            "nl-NL": "nl-NL",
            "pl-PL": "pl-PL",
            "pt-PT": "pt-PT",
            "ro-RO": "ro",
            "ru-RU": "ru-RU",
            "sk-SK": "sk",
            "sv-SE": "sv-SE",
            "th-TH": "th",
            "tr-TR": "tr-TR",
            "uk-UA": "uk",
            "vi-VN": "vi",
        ]

        if let mapped = simplifyMappings[locale] {
            return mapped
        }

        return locale
    }
}

// MARK: - Image Resource Reference

public struct ImageResourceRef: Codable, Equatable, Sendable {
    public var mimeType: String?
    public var location: String
    public var size: Int64
    public var hash: String
    public var width: Int
    public var height: Int
    public var caption: String?

    /// Convert to a dictionary for JSON serialization.
    var asDictionary: [String: Any] {
        var dict: [String: Any] = [
            "location": location,
            "size": size,
            "hash": hash,
            "width": width,
            "height": height,
        ]
        if let mimeType = mimeType { dict["mimeType"] = mimeType }
        if let caption = caption { dict["caption"] = caption }
        return dict
    }

    /// Create an ImageResourceRef from a PNG file URL, relative to the project root.
    static func from(pngURL: URL, relativeTo root: URL) -> ImageResourceRef? {
        guard let data = try? Data(contentsOf: pngURL) else { return nil }
        let fileSize = Int64(data.count)
        guard fileSize > 0 else { return nil }
        let hash = data.SHA256Hash()
        let (width, height) = parsePNGDimensions(data)
        let location = relativePath(of: pngURL, to: root)
        return ImageResourceRef(mimeType: "image/png", location: location, size: fileSize, hash: hash, width: width, height: height)
    }

    /// Parse width and height from a PNG file's IHDR chunk.
    /// PNG format: 8-byte signature, then IHDR chunk with 4-byte length, 4-byte type ("IHDR"),
    /// 4-byte width (big-endian), 4-byte height (big-endian).
    static func parsePNGDimensions(_ data: Data) -> (width: Int, height: Int) {
        // PNG signature is 8 bytes, then first chunk: 4 bytes length + 4 bytes "IHDR" + 4 bytes width + 4 bytes height
        // Minimum offset for width: 16, for height: 20
        guard data.count >= 24 else { return (0, 0) }
        // Verify PNG signature
        let sig: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        for i in 0..<8 {
            if data[i] != sig[i] { return (0, 0) }
        }
        // Width at offset 16, height at offset 20 (big-endian UInt32)
        let width = Int(data[16]) << 24 | Int(data[17]) << 16 | Int(data[18]) << 8 | Int(data[19])
        let height = Int(data[20]) << 24 | Int(data[21]) << 16 | Int(data[22]) << 8 | Int(data[23])
        return (width, height)
    }

    /// Compute a relative path from a file URL to a root URL.
    static func relativePath(of fileURL: URL, to root: URL) -> String {
        let filePath = fileURL.standardized.path
        let rootPath = root.standardized.path.hasSuffix("/") ? root.standardized.path : root.standardized.path + "/"
        if filePath.hasPrefix(rootPath) {
            return String(filePath.dropFirst(rootPath.count))
        }
        return filePath
    }
}

@available(macOS 13, iOS 16, tvOS 16, watchOS 8, *)
extension MetaIndexCommand {

    // MARK: - Icon Discovery

    /// Find the largest PNG file in a directory (used for iOS AppIcon.appiconset).
    func findLargestPNG(in folder: URL, relativeTo root: URL) -> ImageResourceRef? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return nil }
        guard let files = try? fm.contentsOfDirectory(atPath: folder.path) else { return nil }

        var largest: (url: URL, size: Int64)? = nil
        for file in files where file.hasSuffix(".png") {
            let fileURL = folder.appendingPathComponent(file)
            guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                  let fileSize = attrs[.size] as? Int64 else { continue }
            if largest == nil || fileSize > largest!.size {
                largest = (fileURL, fileSize)
            }
        }

        guard let best = largest else { return nil }
        return ImageResourceRef.from(pngURL: best.url, relativeTo: root)
    }

    // MARK: - Localized Image Discovery

    /// Collect a single named image file across locale directories.
    /// Returns a locale → ImageResourceRef dictionary.
    /// Path: {metadataFolder}/{locale}/{subpath}/{fileName}
    func collectLocalizedImages(named fileName: String, subpath: String, metadataFolder: URL, relativeTo root: URL) -> [String: [String: Any]] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: metadataFolder.path) else { return [:] }
        guard let locales = try? fm.contentsOfDirectory(atPath: metadataFolder.path) else { return [:] }

        var result: [String: [String: Any]] = [:]
        for locale in locales.sorted() {
            let imageURL = metadataFolder.appendingPathComponent(locale)
                .appendingPathComponent(subpath)
                .appendingPathComponent(fileName)
            if fm.fileExists(atPath: imageURL.path),
               let ref = ImageResourceRef.from(pngURL: imageURL, relativeTo: root) {
                result[Self.normalizeLocale(locale)] = ref.asDictionary
            }
        }
        return result
    }

    // MARK: - Screenshot Discovery

    /// Collect iOS screenshots from Darwin/fastlane/screenshots/{locale}/*.png
    func collectLocalizedScreenshots(folder: URL, relativeTo root: URL) -> [String: [[String: Any]]] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return [:] }
        guard let locales = try? fm.contentsOfDirectory(atPath: folder.path) else { return [:] }

        var result: [String: [[String: Any]]] = [:]

        for locale in locales.sorted() {
            let localeDir = folder.appendingPathComponent(locale)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: localeDir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let normalizedLocale = Self.normalizeLocale(locale)
            var refs: [[String: Any]] = []

            if let files = try? fm.contentsOfDirectory(atPath: localeDir.path) {
                for file in files.sorted() where file.hasSuffix(".png") {
                    let fileURL = localeDir.appendingPathComponent(file)
                    if let ref = ImageResourceRef.from(pngURL: fileURL, relativeTo: root) {
                        refs.append(ref.asDictionary)
                    }
                }
            }

            if !refs.isEmpty {
                result[normalizedLocale] = refs
            }
        }

        return result
    }

    /// Collect Android screenshots from Android/fastlane/metadata/android/{locale}/images/phoneScreenshots/*.png
    func collectAndroidScreenshots(metadataFolder: URL, relativeTo root: URL) -> [String: [[String: Any]]] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: metadataFolder.path) else { return [:] }
        guard let locales = try? fm.contentsOfDirectory(atPath: metadataFolder.path) else { return [:] }

        var result: [String: [[String: Any]]] = [:]

        for locale in locales.sorted() {
            let screenshotDir = metadataFolder.appendingPathComponent(locale)
                .appendingPathComponent("images/phoneScreenshots")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: screenshotDir.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let normalizedLocale = Self.normalizeLocale(locale)
            var refs: [[String: Any]] = []

            if let files = try? fm.contentsOfDirectory(atPath: screenshotDir.path) {
                for file in files.sorted() where file.hasSuffix(".png") {
                    let fileURL = screenshotDir.appendingPathComponent(file)
                    if let ref = ImageResourceRef.from(pngURL: fileURL, relativeTo: root) {
                        refs.append(ref.asDictionary)
                    }
                }
            }

            if !refs.isEmpty {
                result[normalizedLocale] = refs
            }
        }

        return result
    }
}

// MARK: - Shared App Index Generator

/// Shared logic for generating an app index JSON document, used by both
/// `skip meta index` and `skip export --appindex`.
@available(macOS 13, iOS 16, tvOS 16, watchOS 8, *)
enum AppIndexGenerator {
    static let appIndexFilename = "appindex.json"

    /// Generate the app index dictionary from a project.
    static func generateAppIndex<C: StreamingCommand & OutputOptionsCommand>(projectURL: URL, packageJSON: PackageManifest, includeSBOM: Bool, command: C, out: MessageQueue) async throws -> [String: Any] {
        let moduleNames = packageJSON.targets.compactMap(\.a).filter({ $0.type == "regular" }).filter({ $0.pluginUsages != nil }).map(\.name)
        guard let appModuleName = moduleNames.first else {
            throw AppIndexError(message: "No Skip module targets found in package \(packageJSON.name)")
        }

        let appProject = AppProjectLayout(moduleName: appModuleName, root: projectURL, check: AppProjectLayout.noURLChecks)
        let cmd = MetaIndexCommand()

        let env = try cmd.parseSkipEnv(at: appProject.skipEnv)

        let bundleId = env["PRODUCT_BUNDLE_IDENTIFIER"] ?? ""
        let version = env["MARKETING_VERSION"] ?? "0.0.1"
        let buildNumber = env["CURRENT_PROJECT_VERSION"] ?? "1"
        let productName = env["PRODUCT_NAME"] ?? appModuleName
        let androidAppId = env["ANDROID_APPLICATION_ID"]
        let appleStoreId = env["APPLE_APP_STORE_ID"]
        let googlePlayStoreId = env["GOOGLE_PLAY_STORE_ID"]

        var iosDict = try cmd.buildIOSMetadata(appProject: appProject, projectRoot: projectURL, productName: productName, bundleId: bundleId, version: version, buildNumber: buildNumber, appleStoreId: appleStoreId)
        var androidDict = try cmd.buildAndroidMetadata(appProject: appProject, projectRoot: projectURL, productName: productName, bundleId: bundleId, androidAppId: androidAppId, version: version, buildNumber: buildNumber, googlePlayStoreId: googlePlayStoreId)

        if includeSBOM {
            #if canImport(SkipDriveExternal)
            let outputDir = try AbsolutePath(validating: NSTemporaryDirectory())
            let sbomFiles = try await SBOMGenerator.generateSBOMFiles(generateIOS: true, generateAndroid: true, projectPath: projectURL.path, packageName: packageJSON.name, packageJSON: packageJSON, outputDirAbsolute: outputDir, command: command, out: out)
            for file in sbomFiles {
                let data = try Data(contentsOf: file)
                let json = try JSONSerialization.jsonObject(with: data)
                if file.lastPathComponent.contains("darwin") || file.lastPathComponent.contains("ios") {
                    iosDict["sbom"] = json
                } else if file.lastPathComponent.contains("android") {
                    androidDict["sbom"] = json
                }
            }
            #endif
        }

        let appDict: [String: Any] = [
            "name": productName,
            "version": version,
            "buildNumber": buildNumber,
            "platforms": [
                "ios": iosDict,
                "android": androidDict,
            ] as [String: Any],
        ]

        return ["app": appDict]
    }

    /// Write the app index JSON to a file and optionally create a symlink in the app Resources folder.
    static func writeAppIndex(_ catalog: [String: Any], to outputURL: URL, linkResource: Bool, appModuleName: String, projectURL: URL, out: MessageQueue) async throws -> URL {
        let jsonData = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try jsonData.write(to: outputURL)

        if linkResource {
            let resourcesFolder = projectURL.appendingPathComponent("Sources/\(appModuleName)/Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: resourcesFolder, withIntermediateDirectories: true)

            let linkPath = resourcesFolder.appendingPathComponent(appIndexFilename).path
            try? FileManager.default.removeItem(atPath: linkPath)
            let relPath = relativePath(from: resourcesFolder.path, to: outputURL.path)
            try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: relPath)
            await out.write(status: .pass, "Linked \(appIndexFilename) -> \(relPath)")
        }

        return outputURL
    }

    /// Compute a relative path for symlink creation.
    private static func relativePath(from fromDir: String, to toPath: String) -> String {
        let fromComponents = URL(fileURLWithPath: fromDir).standardized.pathComponents
        let toComponents = URL(fileURLWithPath: toPath).standardized.pathComponents

        var commonLength = 0
        while commonLength < fromComponents.count && commonLength < toComponents.count
                && fromComponents[commonLength] == toComponents[commonLength] {
            commonLength += 1
        }

        let ups = fromComponents.count - commonLength
        var parts = Array(repeating: "..", count: ups)
        parts.append(contentsOf: toComponents[commonLength...])
        return parts.joined(separator: "/")
    }
}

private struct AppIndexError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Android Manifest XML Parser

/// XMLParser delegate that extracts metadata and permissions from AndroidManifest.xml.
private class AndroidManifestParserDelegate: NSObject, XMLParserDelegate {
    var metadata: [String: Any] = [:]
    var permissions: [[String: String]] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "manifest":
            if let pkg = attributeDict["package"] {
                metadata["package"] = pkg
            }
        case "application":
            if let label = attributeDict["android:label"] {
                metadata["label"] = label
            }
            if let name = attributeDict["android:name"] {
                metadata["name"] = name
            }
            if let icon = attributeDict["android:icon"] {
                metadata["icon"] = icon
            }
            if let theme = attributeDict["android:theme"] {
                metadata["theme"] = theme
            }
        case "uses-permission":
            if let name = attributeDict["android:name"] {
                permissions.append(["name": name])
            }
        case "uses-feature":
            if let name = attributeDict["android:name"] {
                var feature: [String: String] = ["name": name]
                if let required = attributeDict["android:required"] {
                    feature["required"] = required
                }
                var features = metadata["features"] as? [[String: String]] ?? []
                features.append(feature)
                metadata["features"] = features
            }
        default:
            break
        }
    }
}
