// Copyright (c) 2023 - 2026 Skip
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import ArgumentParser
import SkipSyntax

/// Generates the browser host files used by an experimental Skip Web/Wasm build.
///
/// The generated host intentionally delegates the actual Wasm bootstrap to a JavaScript
/// module. This keeps the command independent of the Swift Wasm SDK version while providing
/// a stable mount point and a predictable project layout for web runtimes such as SkipWebWasm.
@available(macOS 13, iOS 16, tvOS 16, watchOS 8, *)
struct WebCommand: MessageCommand {
    static var configuration = CommandConfiguration(
        commandName: "web",
        abstract: "Generate an experimental browser host for a Skip Web/Wasm build",
        shouldDisplay: true)

    @OptionGroup(title: "Output Options")
    var outputOptions: OutputOptions

    @Option(name: [.long], help: ArgumentHelp("Browser host output directory", valueName: "directory"))
    var outputDirectory: String = "Web"

    @Option(name: [.long], help: ArgumentHelp("JavaScript bootstrap module to load", valueName: "path"))
    var bootstrapModule: String = "App.js"

    @Option(name: [.long], help: ArgumentHelp("Browser document title", valueName: "title"))
    var title: String = "Skip Web App"

    @Flag(help: ArgumentHelp("Replace existing generated host files"))
    var force: Bool = false

    func performCommand(with out: MessageQueue) async throws {
        let outputURL = URL(fileURLWithPath: outputDirectory, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let indexURL = outputURL.appendingPathComponent("index.html")
        let manifestURL = outputURL.appendingPathComponent("skip-web.json")
        let urls = [indexURL, manifestURL]
        if !force, let existing = urls.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            throw ValidationError("Generated web host already exists at \(existing.path); pass --force to replace it")
        }

        let index = WebHostTemplate.html(title: title, bootstrapModule: bootstrapModule)
        try index.write(to: indexURL, atomically: true, encoding: .utf8)

        let manifest = WebHostTemplate.manifest(title: title, bootstrapModule: bootstrapModule)
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        await out.yield(MessageBlock(status: .pass, "Generated experimental Skip Web host at \(outputURL.path)"))
        await out.yield(MessageBlock(status: .warn, "The host requires a Swift Wasm bootstrap module; it does not provide SwiftUI Web parity by itself"))
    }
}

enum WebHostTemplate {
    static func html(title: String, bootstrapModule: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escapeHTML(title))</title>
          <style>
            html, body, #skip-root { margin: 0; min-height: 100%; width: 100%; }
            body { min-height: 100vh; }
          </style>
        </head>
        <body>
          <main id="skip-root" aria-label="Skip Web application"></main>
          <script type="module">
            import * as app from "./\(escapeJavaScriptString(bootstrapModule))";
            if (typeof app.start === "function") {
              await app.start(document.getElementById("skip-root"));
            }
          </script>
        </body>
        </html>
        """
    }

    static func manifest(title: String, bootstrapModule: String) -> String {
        """
        {
          "version": 1,
          "title": "\(escapeJSON(title))",
          "bootstrap": "\(escapeJSON(bootstrapModule))",
          "mount": "#skip-root"
        }
        """
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func escapeJavaScriptString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private static func escapeJSON(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
