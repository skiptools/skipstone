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
    var bootstrapModule: String = "index.js"

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
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <meta name="theme-color" content="#ffffff">
          <title>\(escapeHTML(title))</title>
          <style>
            :root { color-scheme: light dark; }
            *, *::before, *::after { box-sizing: border-box; }
            html, body, #skip-root { margin: 0; min-height: 100%; width: 100%; }
            body {
              min-height: 100vh;
              min-height: 100dvh;
              overflow-x: hidden;
              padding: env(safe-area-inset-top) env(safe-area-inset-right)
                       env(safe-area-inset-bottom) env(safe-area-inset-left);
              background: Canvas;
              color: CanvasText;
              font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            }
            #skip-root { min-height: calc(100dvh - env(safe-area-inset-top) - env(safe-area-inset-bottom)); }
            @media (min-width: 600px) {
              #skip-root { padding-inline: clamp(16px, 4vw, 48px); }
            }
            @media (min-width: 840px) {
              #skip-root { margin-inline: auto; max-width: 1280px; padding-inline: clamp(24px, 5vw, 80px); }
            }
            @media (prefers-reduced-motion: reduce) {
              *, *::before, *::after { scroll-behavior: auto !important; animation-duration: 0.01ms !important; }
            }
          </style>
        </head>
        <body>
          <main id="skip-root" aria-label="Skip Web application"></main>
          <script type="module">
            const bootstrap = await import("./\(escapeJavaScriptString(bootstrapModule))");
            if (typeof bootstrap.init === "function") {
              await bootstrap.init();
            } else if (typeof bootstrap.start === "function") {
              await bootstrap.start(document.getElementById("skip-root"));
            } else {
              throw new Error("Skip Web bootstrap must export init() or start()");
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
          "mount": "#skip-root",
          "breakpoints": { "compact": 600, "medium": 840 }
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
