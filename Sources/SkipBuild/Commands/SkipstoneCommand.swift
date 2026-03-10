// Copyright (c) 2023 - 2026 Skip
// Licensed under the GNU Affero General Public License v3.0
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import ArgumentParser
import Universal
import SkipSyntax
import TSCBasic

/// The file extension for the metadata about skipcode
let skipcodeExtension = ".skipcode.json"

/// The command executed by the Skip plugin that will perform all the actions to transform a SwiftPM module into a Gradle project, including transpiling source code, building native bridges, and processing resources.
struct SkipstoneCommand: BuildPluginOptionsCommand, StreamingCommand {
    static var configuration = CommandConfiguration(commandName: "skipstone", abstract: "Convert Swift project to Gradle", shouldDisplay: false, aliases: ["transpile"])

    /// The `ENABLE_PREVIEW` parameter specifies whether we are building for previews
    static let enablePreviews = ProcessInfo.processInfo.environment["ENABLE_PREVIEWS"] == "YES"

    @OptionGroup(title: "Check Options")
    var inputOptions: SkipstoneInputOptions

    @OptionGroup(title: "Skipstone Options")
    var skipstoneOptions: SkipstoneCommandOptions

    @OptionGroup(title: "Output Options")
    var outputOptions: OutputOptions

    struct Output : MessageEncodable {
        let transpilation: Transpilation

        func message(term: Term) -> String? {
            // successful run outputs no message so as to not clutter xcode logs
            return nil
        }
    }

    var moduleNamePaths: [(module: String, path: String)] {
        skipstoneOptions.moduleNames.map({
            let parts = $0.split(separator: ":")
            return (module: parts.first?.description ?? "", path: parts.last?.description ?? "")
        })
    }

    var linkNamePaths: [(module: String, link: String)] {
        skipstoneOptions.linkPaths.map({
            let parts = $0.split(separator: ":")
            return (module: parts.first?.description ?? "", link: parts.last?.description ?? "")
        })
    }

    var dependencyIdPaths: [(targetName: String, packageID: String, packagePath: String)] {
        skipstoneOptions.dependencies.compactMap({
            let parts = $0.split(separator: ":").map(\.description)
            if parts.count != 3 { return nil }
            return (targetName: parts[0], packageID: parts[1], packagePath: parts[2])
        })
    }

    func performCommand(with out: MessageQueue) async throws {
        #if DEBUG
        let v = skipVersion + "*" // * indicates debug version
        #else
        let v = skipVersion
        #endif

        if Self.enablePreviews == true {
            info("Skip \(v): skipstone plugin not running for ENABLE_PREVIEWS=YES")
            return
        }

        if SkippyCommand.skippyOnly == true {
            info("Skip \(v): skipstone plugin not running for CONFIGURATION=Skippy")
            return
        }

        // show the local time in the plugin output; this helps identify from the Xcode Navigator when an old log file is being replayed for a plugin re-execution
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"

        guard let moduleRoot = skipstoneOptions.moduleRoot else {
            throw error("Must specify --module-root")
        }
        let moduleRootPath = try AbsolutePath(validating: moduleRoot)

        guard let skipFolder = skipstoneOptions.skipFolder else {
            throw error("Must specify --skip-folder")
        }

        let fs = localFileSystem
        let baseOutputPath = try fs.currentWorkingDirectory ?? fs.tempDirectory

        // the --skip-folder flag
        let skipFolderPath = try AbsolutePath(validating: skipFolder, relativeTo: baseOutputPath)

        // the --project flag
        let projectFolderPath = try AbsolutePath(validating: skipstoneOptions.projectFolder, relativeTo: baseOutputPath)

        guard let outputFolder = skipstoneOptions.outputFolder else {
            throw error("Must specify --output-folder")
        }
        let outputFolderPath = try AbsolutePath(validating: outputFolder, relativeTo: baseOutputPath)


        info("Skip \(v): skipstone plugin to: \(skipstoneOptions.outputFolder ?? "nowhere") at \(dateFormatter.string(from: .now))")

        // Delegates to a `SkipstoneSession` which encapsulates all the mutable state and operational logic
        let session = SkipstoneSession(
            command: self,
            rootPath: baseOutputPath,
            projectFolderPath: projectFolderPath,
            moduleRootPath: moduleRootPath,
            skipFolderPath: skipFolderPath,
            outputFolderPath: outputFolderPath,
            fs: fs)
        do {
            try await session.run(with: out)
        } catch {
            // ensure that the error is logged in some way before failing
            self.error("Skip \(skipVersion) error: \(error.localizedDescription)")
            throw error
        }
    }

    /// Generate transpiler transformers from the given skip config
    func createTransformers(for config: SkipConfig, with moduleMap: [String: SkipConfig]) throws -> [KotlinTransformer] {
        var transformers: [KotlinTransformer] = builtinKotlinTransformers()

        let configOptions = config.skip?.bridgingOptions() ?? []
        let transformerOptions = KotlinBridgeOptions.parse(configOptions)
        transformers.append(KotlinBridgeTransformer(options: transformerOptions))

        if let root = config.skip?.dynamicroot {
            transformers.append(KotlinDynamicObjectTransformer(root: root))
        }

        return transformers
    }

    func loadSourceHashes(from allSourceURLs: [URL]) async throws -> [URL: String] {
        // take a snapshot of all the source hashes for each of the URLs so we know when anything has changes
        // TODO: this doesn't need to be a full SHA256 hash, it can be something faster (or maybe even just a snapshot of the file's size and last modified date…)
        let sourcehashes = try await withThrowingTaskGroup(of: (URL, String).self) { group in
            for url in allSourceURLs {
                group.addTask {
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    return (url, data.SHA256Hash())
                }
            }

            var results = [URL: String]()
            results.reserveCapacity(allSourceURLs.count)

            for try await (url, sha256) in group {
                results[url] = sha256
            }

            return results
        }

        return sourcehashes
    }
}

struct SkipstoneCommandOptions: ParsableArguments {
    @Option(name: [.customLong("project"), .long], help: ArgumentHelp("The project folder to transpile", valueName: "folder"))
    var projectFolder: String // --project

    @Option(name: [.long], help: ArgumentHelp("The path to the source hash file to output", valueName: "path"))
    var sourcehash: String // --sourcehash

    @Option(name: [.customLong("module")], help: ArgumentHelp("ModuleName:SourcePath", valueName: "module"))
    var moduleNames: [String] = [] // --module name:path

    @Option(name: [.customLong("link")], help: ArgumentHelp("ModuleName:LinkPath", valueName: "module"))
    var linkPaths: [String] = [] // --link name:path

    @Option(help: ArgumentHelp("Path to the folder that contains skip.yml and overrides", valueName: "path"))
    var skipFolder: String? = nil // --skip-folder

    @Option(help: ArgumentHelp("Path to the output module root folder", valueName: "path"))
    var moduleRoot: String? = nil // --module-root

    @Option(name: [.customShort("D", allowingJoined: true)], help: ArgumentHelp("Set preprocessor variable for transpilation", valueName: "value"))
    var preprocessorVariables: [String] = []

    @Option(name: [.long], help: ArgumentHelp("Output directory", valueName: "dir"))
    var outputFolder: String? = nil

    @Option(name: [.customLong("dependency")], help: ArgumentHelp("id:path", valueName: "dependency"))
    var dependencies: [String] = [] // --dependency id:path

    @Option(name: [.long], help: ArgumentHelp("Folder for SkipBridge generated Swift files", valueName: "suffix"))
    var skipBridgeOutput: String? = nil
}


/// A collected resource entry with its file URLs and processing mode.
///
/// Resource entries are built from `skip.yml` configuration and track whether resources
/// should be processed (flattened with localization conversion) or copied (preserving
/// the source directory hierarchy, matching Darwin's `.copy()` behavior).
struct ResourceEntry {
    /// The relative path to the resource directory from the project folder.
    let path: String
    /// The file URLs contained within the resource directory.
    let urls: [URL]
    /// Whether this entry uses copy mode (preserving hierarchy) vs process mode (flattening).
    let isCopyMode: Bool
}

/// Manages the mutable state and execution phases of a single skipstone transpilation invocation.
///
/// `SkipstoneSession` encapsulates all the mutable state and operational logic that was previously
/// contained within `skipstoneThrows` as nested closures. By organizing this logic into a class
/// with distinct methods, each phase of the skipstone pipeline becomes independently understandable
/// and testable.
///
/// ## Execution Phases
///
/// The session executes via ``run(with:)`` in sequential phases:
///
/// 1. **Validation & Setup** — Validates paths, enumerates source/resource files, snapshots
///    existing output files for stale detection, loads and merges `skip.yml` configs.
///
/// 2. **Transpilation** — Loads dependent module codebase info, creates the transpiler with
///    appropriate transformers, runs transpilation, and writes Kotlin output files.
///
/// 3. **Output & Linking** — Saves codebase info for downstream modules, generates bridge code,
///    links dependent module sources, links resources (process or copy mode), and generates
///    Gradle build files.
///
/// 4. **Cleanup** — Removes stale output files from previous runs and writes the sourcehash
///    marker file to signal completion to the build plugin host.
class SkipstoneSession {

    // MARK: - Command & Environment

    /// The command that created this session, used for logging and accessing parsed options.
    private let command: SkipstoneCommand

    /// The filesystem abstraction for all file operations.
    let fs: FileSystem

    // MARK: - Immutable Paths

    /// The working directory root path.
    let rootPath: AbsolutePath

    /// Path to the Swift source project folder (e.g., Sources/ModuleName).
    let projectFolderPath: AbsolutePath

    /// Path to the Gradle module root output directory.
    let moduleRootPath: AbsolutePath

    /// Path to the Skip/ configuration folder containing skip.yml and overrides.
    let skipFolderPath: AbsolutePath

    /// Path to the Kotlin/Java output folder (e.g., src/main/kotlin or src/test/kotlin).
    let outputFolderPath: AbsolutePath

    // MARK: - Constants

    /// The filename for the Android manifest, which requires special output path handling.
    let androidManifestName = "AndroidManifest.xml"

    /// The folder name for Gradle build scripts and plugins.
    let buildSrcFolderName = "buildSrc"

    // MARK: - Accumulated Output State

    /// All output files written during this session. Used for stale file detection:
    /// any file in the output folder not in this list after the session is considered stale.
    var outputFiles: [AbsolutePath] = []

    /// All input files read during this session, tracked for modification timestamps.
    var inputFiles: [AbsolutePath] = []

    /// Bridge transpilation outputs accumulated during the transpilation phase,
    /// consumed later when saving bridge code.
    var skipBridgeTranspilations: [Transpilation] = []

    // MARK: - Phase-Derived State (set during run)

    /// Snapshot of output file URLs taken at session start, for stale file comparison.
    private var outputFilesSnapshot: [URL] = []

    /// Source .swift file URLs enumerated from the project folder.
    private var sourceURLs: [URL] = []

    /// Resource file URLs from the default Resources/ folder.
    private var resourceURLs: [URL] = []

    /// The base (unmerged) skip.yml config for this module.
    private var baseSkipConfig: SkipConfig!

    /// The merged skip.yml config combining all dependent module configs.
    private var mergedSkipConfig: SkipConfig!

    /// Map of module name to its parsed skip.yml config.
    private var configMap: [String: SkipConfig]!

    /// Whether SkipFuse is present in the dependency graph.
    private var hasSkipFuse: Bool = false

    /// Whether this module operates in native (non-transpiled) mode.
    private var isNativeModule: Bool = false

    /// The Kotlin package name for this module (e.g., "skip.foundation").
    private var packageName: String!

    /// Structured resource entries built from skip.yml configuration.
    private var resourceEntries: [ResourceEntry] = []

    /// SHA256 hashes of all source files, used for change detection.
    private var sourcehashes: [URL: String] = [:]

    /// Codebase info loaded from dependent modules, populated during transpilation.
    private var codebaseInfo: CodebaseInfo!

    /// Kotlin filenames that have manual overrides from the Skip/ folder.
    private var overriddenKotlinFiles: [String] = []

    // MARK: - Computed Properties

    /// The parent directory of moduleRootPath, used as the base for relative output paths.
    var moduleBasePath: AbsolutePath { moduleRootPath.parentDirectory }

    /// Module name/path pairs from --module arguments, forwarded from the command.
    var moduleNamePaths: [(module: String, path: String)] { command.moduleNamePaths }

    /// Module name/link pairs from --link arguments, forwarded from the command.
    var linkNamePaths: [(module: String, link: String)] { command.linkNamePaths }

    /// Dependency id/path triples from --dependency arguments, forwarded from the command.
    var dependencyIdPaths: [(targetName: String, packageID: String, packagePath: String)] { command.dependencyIdPaths }

    /// The skipstone-specific command options.
    var skipstoneOptions: SkipstoneCommandOptions { command.skipstoneOptions }

    // MARK: - JSON Encoder

    /// Shared JSON encoder configured for deterministic output, used for
    /// serializing `.skipcode.json` codebase and `.sourcehash` marker contents.
    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [
            .sortedKeys, // needed for deterministic output
            .withoutEscapingSlashes,
        ]
        return e
    }()

    // MARK: - Initialization

    /// Creates a new session with the given command and pre-validated paths.
    ///
    /// The initializer stores references but performs no I/O. All work is deferred
    /// to ``run(with:)`` and its phase methods.
    ///
    /// - Parameters:
    ///   - command: The parsed skipstone command, providing options and logging.
    ///   - rootPath: The filesystem root / working directory.
    ///   - projectFolderPath: Path to the Swift project source folder.
    ///   - moduleRootPath: Path to the Gradle module root output.
    ///   - skipFolderPath: Path to the Skip/ configuration folder.
    ///   - outputFolderPath: Path to the Kotlin/Java output folder.
    ///   - fs: The filesystem abstraction for file operations.
    init(command: SkipstoneCommand, rootPath: AbsolutePath, projectFolderPath: AbsolutePath, moduleRootPath: AbsolutePath, skipFolderPath: AbsolutePath, outputFolderPath: AbsolutePath, fs: FileSystem) {
        self.command = command
        self.rootPath = rootPath
        self.projectFolderPath = projectFolderPath
        self.moduleRootPath = moduleRootPath
        self.skipFolderPath = skipFolderPath
        self.outputFolderPath = outputFolderPath
        self.fs = fs
    }

    // MARK: - Logging (forwarded to command)

    func trace(_ message: @autoclosure () -> String) {
        command.trace(message())
    }

    func info(_ message: @autoclosure () -> String, sourceFile: Source.FilePath? = nil) {
        command.info(message(), sourceFile: sourceFile)
    }

    func warn(_ message: @autoclosure () -> String, sourceFile: Source.FilePath? = nil) {
        command.warn(message(), sourceFile: sourceFile)
    }

    @discardableResult func error(_ message: @autoclosure () -> String, sourceFile: Source.FilePath? = nil) -> ValidationError {
        command.error(message(), sourceFile: sourceFile)
    }

    func msg(_ kind: Message.Kind, _ message: @autoclosure () -> String, sourceFile: Source.FilePath? = nil) {
        command.msg(kind, message(), sourceFile: sourceFile)
    }

    // MARK: - Main Execution

    /// Executes all phases of the skipstone pipeline.
    ///
    /// This method orchestrates the full skipstone invocation by calling phase methods
    /// in sequence. A `defer` block ensures that stale file cleanup and the sourcehash
    /// marker are always written, even if an error occurs.
    ///
    /// - Parameter out: The message queue for yielding transpilation results to the build plugin host.
    func run(with out: MessageQueue) async throws {
        let primaryModuleName = try requirePrimaryModule().module

        trace("skipstoneThrows: rootPath=\(rootPath), projectFolderPath=\(projectFolderPath), moduleRootPath=\(moduleRootPath), skipFolderPath=\(skipFolderPath), outputFolderPath=\(outputFolderPath)")

        try validateSkipFolder()
        try snapshotExistingOutputFiles()
        try ensureModuleRootExists()

        let (sources, resources) = try buildSourceList()
        self.sourceURLs = sources
        self.resourceURLs = resources

        try loadAndMergeConfiguration()
        try await computeSourceHashes()

        defer { finalizeSession() }

        self.codebaseInfo = try await loadCodebaseInfo()

        let autoBridge: AutoBridge = primaryModuleName == "SkipSwiftUI" ? .none : baseSkipConfig.skip?.isAutoBridgingEnabled() == true ? .public : .default
        let dynamicRoot = baseSkipConfig.skip?.dynamicroot

        if isCMakeProject {
            try linkCMakeProject()
        }

        let kotlinOutputFolder = try setupOutputFolders()
        try setupTransformersAndOverrides(kotlinOutputFolder: kotlinOutputFolder)

        try await runTranspiler(autoBridge: autoBridge, dynamicRoot: dynamicRoot, kotlinOutputFolder: kotlinOutputFolder, with: out)

        try saveCodebaseInfo()
        try saveSkipBridgeCode()

        let sourceModules = try linkDependentModuleSources()
        try linkResources()

        try generateGradle(for: sourceModules, with: mergedSkipConfig, isApp: isAppModule)
    }

    // MARK: - Phase 1: Validation & Setup

    /// Returns the primary module name and path from the command's --module arguments.
    ///
    /// - Throws: `ValidationError` if no --module argument was provided.
    /// - Returns: The first module name/path tuple.
    func requirePrimaryModule() throws -> (module: String, path: String) {
        guard let primary = moduleNamePaths.first else {
            throw error("Must specify at least one --module")
        }
        return primary
    }

    /// The primary module name, extracted from the first --module argument.
    var primaryModuleName: String {
        moduleNamePaths.first?.module ?? ""
    }

    /// Whether this module is an app (vs a library), determined by the presence of an `.xcconfig` file.
    var isAppModule: Bool {
        let configModuleName = primaryModuleName.hasSuffix("Tests") ? String(primaryModuleName.dropLast("Tests".count)) : primaryModuleName
        let moduleXCConfig = rootPath.appending(component: configModuleName + ".xcconfig")
        return fs.isFile(moduleXCConfig)
    }

    /// The path to the module's xcconfig file (used for app module manifest configuration).
    var moduleXCConfig: AbsolutePath {
        let configModuleName = primaryModuleName.hasSuffix("Tests") ? String(primaryModuleName.dropLast("Tests".count)) : primaryModuleName
        return rootPath.appending(component: configModuleName + ".xcconfig")
    }

    /// Whether the project uses CMake (has a CMakeLists.txt in the project folder).
    var isCMakeProject: Bool {
        let cmakeLists = projectFolderPath.appending(component: "CMakeLists.txt")
        return fs.exists(cmakeLists)
    }

    /// Validates that the Skip/ folder exists (unless this is a CMake project).
    ///
    /// - Throws: `ValidationError` if the Skip/ folder is missing and this isn't a CMake project.
    func validateSkipFolder() throws {
        if !isCMakeProject && !fs.isDirectory(skipFolderPath) {
            throw error("In order for Skip to process the module, a Skip/ folder must exist and contain a skip.yml file at: \(skipFolderPath)")
        }
    }

    /// Takes a snapshot of all files currently in the output folder.
    ///
    /// This snapshot is compared against ``outputFiles`` at session end to identify
    /// stale files from previous runs that should be cleaned up.
    func snapshotExistingOutputFiles() throws {
        self.outputFilesSnapshot = try FileManager.default.enumeratedURLs(of: outputFolderPath.asURL)
    }

    /// Ensures the module root directory exists, creating it if needed.
    ///
    /// - Throws: `ValidationError` if the directory cannot be created.
    func ensureModuleRootExists() throws {
        if !fs.isDirectory(moduleRootPath) {
            try fs.createDirectory(moduleRootPath, recursive: true)
        }
        if !fs.isDirectory(moduleRootPath) {
            throw error("Module root path did not exist at: \(moduleRootPath.pathString)")
        }
    }

    /// Enumerates the project folder to find Swift source files and resource files.
    ///
    /// Source files are any `.swift` files in the project folder. Resource files
    /// are files under the `Resources/` subdirectory.
    ///
    /// - Returns: A tuple of (sourceURLs, resourceURLs).
    func buildSourceList() throws -> (sources: [URL], resources: [URL]) {
        let projectBaseURL = projectFolderPath.asURL
        let allProjectFiles: [URL] = try FileManager.default.enumeratedURLs(of: projectBaseURL)

        let swiftPathExtensions: Set<String> = ["swift"]
        let sourceURLs: [URL] = allProjectFiles.filter({ swiftPathExtensions.contains($0.pathExtension) })

        let projectResourcesURL = projectBaseURL.appendingPathComponent("Resources", isDirectory: true)
        let resourceURLs: [URL] = try FileManager.default.enumeratedURLs(of: projectResourcesURL)

        return (sources: sourceURLs, resources: resourceURLs)
    }

    // MARK: - Phase 2: Configuration Loading

    /// Loads and merges skip.yml configs from this module and all its dependencies.
    ///
    /// After this method completes, ``baseSkipConfig``, ``mergedSkipConfig``,
    /// ``configMap``, ``hasSkipFuse``, ``isNativeModule``, ``packageName``,
    /// and ``resourceEntries`` are all populated.
    func loadAndMergeConfiguration() throws {
        let (base, merged, map) = try loadSkipConfig(merge: true)
        self.baseSkipConfig = base
        self.mergedSkipConfig = merged
        self.configMap = map
        self.hasSkipFuse = map.keys.contains("SkipFuse")

        self.resourceEntries = try Self.buildResourceEntries(
            config: base, resourceURLs: resourceURLs, projectBaseURL: projectFolderPath.asURL)

        self.isNativeModule = Self.resolveModuleMode(
            moduleName: nil, configMap: map, baseConfig: base,
            hasSkipFuse: hasSkipFuse, primaryModuleName: primaryModuleName) == .native

        self.packageName = base.skip?.package ?? KotlinTranslator.packageName(forModule: primaryModuleName)
    }

    /// Loads a single skip.yml file, optionally filtering `export: false` blocks.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the skip.yml file.
    ///   - forExport: When true, blocks marked `export: false` are stripped.
    /// - Returns: The parsed `SkipConfig`.
    func loadSkipYAML(path: AbsolutePath, forExport: Bool) throws -> SkipConfig {
        do {
            var yaml = try inputSource(path).withData(YAML.parse(_:))
            if yaml.object == nil {
                yaml = .object([:])
            }

            if forExport {
                yaml = Self.filterExportYAML(yaml) ?? yaml
            }
            return try yaml.json().decode()
        } catch let e {
            throw error("The skip.yml file at \(path) could not be loaded: \(e)", sourceFile: path.sourceFile)
        }
    }

    /// Loads the skip.yml config, optionally merged with dependent module configs.
    ///
    /// When `merge` is true, iterates through all --module dependencies, loads each
    /// module's skip.yml, and produces an aggregate config. The aggregate includes
    /// auto-generated Gradle dependency blocks and, for app modules, manifest
    /// placeholder configuration from the .xcconfig file.
    ///
    /// - Parameters:
    ///   - merge: Whether to merge with dependent module configs. Defaults to true.
    ///   - configFileName: The config filename. Defaults to "skip.yml".
    /// - Returns: A tuple of (base config, merged config, per-module config map).
    func loadSkipConfig(merge: Bool = true, configFileName: String = "skip.yml") throws -> (base: SkipConfig, merged: SkipConfig, configMap: [String: SkipConfig]) {
        let configStart = Date().timeIntervalSinceReferenceDate
        let skipConfigPath = skipFolderPath.appending(component: configFileName)
        let currentModuleConfig = try loadSkipYAML(path: skipConfigPath, forExport: false)

        var configMap: [String: SkipConfig] = [:]
        configMap[primaryModuleName] = currentModuleConfig

        let currentModuleJSON = try currentModuleConfig.json()
        info("loading skip.yml from \(skipConfigPath)", sourceFile: skipConfigPath.sourceFile)

        if !merge {
            return (currentModuleConfig, currentModuleConfig, configMap)
        }

        var aggregateJSON: Universal.JSON = [:]

        for (moduleName, modulePath) in moduleNamePaths {
            trace("moduleName: \(moduleName) modulePath: \(modulePath) primaryModuleName: \(primaryModuleName)")
            if moduleName == primaryModuleName {
                continue
            }

            let moduleSkipBasePath = try AbsolutePath(validating: modulePath, relativeTo: moduleRootPath.parentDirectory)
                .appending(components: ["Skip"])

            let moduleSkipConfigPath = moduleSkipBasePath.appending(component: configFileName)

            if fs.isFile(moduleSkipConfigPath) {
                let skipConfigLoadStart = Date().timeIntervalSinceReferenceDate
                let isTestPeer = primaryModuleName == moduleName + "Tests"
                trace("primaryModuleName: \(primaryModuleName) moduleName: \(moduleName) isTestPeer=\(isTestPeer)")
                let isForExport = !isTestPeer
                let moduleConfig = try loadSkipYAML(path: moduleSkipConfigPath, forExport: isForExport)
                configMap[moduleName] = moduleConfig
                let skipConfigLoadEnd = Date().timeIntervalSinceReferenceDate
                info("\(moduleName) skip.yml config loaded (\(Int64((skipConfigLoadEnd - skipConfigLoadStart) * 1000)) ms)", sourceFile: moduleSkipConfigPath.sourceFile)
                aggregateJSON = try aggregateJSON.merged(with: moduleConfig.json())
            }
        }

        aggregateJSON = try aggregateJSON.merged(with: currentModuleJSON)

        // Merge auto-generated module dependency and app config blocks
        do {
            var moduleDependencyBlocks: [GradleBlock.BlockOrCommand] = []

            for (moduleName, _) in moduleNamePaths {
                if Self.isTestModule(moduleName, primaryModuleName: primaryModuleName) {
                    if moduleName == "SkipUnit" {
                        moduleDependencyBlocks += [
                            .init("testImplementation(project(\":\(moduleName)\"))"),
                            .init("androidTestImplementation(project(\":\(moduleName)\"))")
                        ]
                    } else {
                        moduleDependencyBlocks += [
                            .init("api(project(\":\(moduleName)\"))"),
                        ]
                    }
                }
            }

            var localConfig = GradleBlock(contents: [.init(GradleBlock(block: "dependencies", contents: moduleDependencyBlocks))])

            if isAppModule {
                var manifestConfigLines: [String] = []

                let moduleXCConfigContents = try String(contentsOf: moduleXCConfig.asURL, encoding: .utf8)
                for (key, value) in parseXCConfig(contents: moduleXCConfigContents) {
                    manifestConfigLines += ["""
                    manifestPlaceholders["\(key)"] = System.getenv("\(key)") ?: "\(value)"
                    """]
                }

                manifestConfigLines += ["""
                applicationId = manifestPlaceholders["PRODUCT_BUNDLE_IDENTIFIER"]?.toString().replace("-", "_")
                """]

                manifestConfigLines += ["""
                versionCode = (manifestPlaceholders["CURRENT_PROJECT_VERSION"]?.toString())?.toInt()
                """]

                manifestConfigLines += ["""
                versionName = manifestPlaceholders["MARKETING_VERSION"]?.toString()
                """]

                localConfig.contents?.append(.init(GradleBlock(block: "android", contents: [
                    .init(GradleBlock(block: "defaultConfig", contents: manifestConfigLines.map({ .a($0) })))
                ])))
            }

            aggregateJSON = try aggregateJSON.merged(with: JSON.object(["build": localConfig.json()]))
        }

        var aggregateSkipConfig: SkipConfig = try aggregateJSON.decode()
        aggregateSkipConfig.build?.removeContent(withExports: true)
        aggregateSkipConfig.settings?.removeContent(withExports: true)

        let configEnd = Date().timeIntervalSinceReferenceDate
        info("skip.yml aggregate created (\(Int64((configEnd - configStart) * 1000)) ms) for modules: \(moduleNamePaths.map(\.module))")
        return (currentModuleConfig, aggregateSkipConfig, configMap)
    }

    // MARK: - Phase 3: Source Hash Computation

    /// Computes SHA256 hashes for all source files and Skip/ folder contents.
    ///
    /// These hashes are written to the sourcehash marker file to enable the build
    /// plugin to detect when source content has changed.
    func computeSourceHashes() async throws {
        let skipFolderPathContents = try FileManager.default.enumeratedURLs(of: skipFolderPath.asURL)
            .filter({ (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true })

        let sourceHashStart = Date().timeIntervalSinceReferenceDate
        self.sourcehashes = try await command.loadSourceHashes(from: sourceURLs + skipFolderPathContents)
        let sourceHashEnd = Date().timeIntervalSinceReferenceDate
        info("source hashes calculated \(self.sourcehashes) files for modules: \(moduleNamePaths.map(\.module)) (\(Int64((sourceHashEnd - sourceHashStart) * 1000)) ms)")
    }

    // MARK: - Phase 4: Transpilation

    /// Loads codebase info from previously transpiled dependent modules.
    ///
    /// Iterates through --link arguments to find `ModuleName.skipcode.json` files
    /// from prior transpilation runs. These provide type and function information
    /// that the transpiler needs for cross-module references.
    ///
    /// - Returns: A populated `CodebaseInfo` with dependent module exports.
    func loadCodebaseInfo() async throws -> CodebaseInfo {
        let decoder = JSONDecoder()
        var dependentModuleExports: [CodebaseInfo.ModuleExport] = []

        for (linkModuleName, relativeLinkPath) in linkNamePaths {
            let linkModuleRoot = moduleRootPath
                .parentDirectory
                .appending(try RelativePath(validating: relativeLinkPath))

            let dependencyModuleExport = linkModuleRoot
                .parentDirectory
                .appending(try moduleExportPath(forModule: linkModuleName))

            do {
                let exportLoadStart = Date().timeIntervalSinceReferenceDate
                trace("dependencyModuleExport \(dependencyModuleExport): exists \(fs.exists(dependencyModuleExport))")
                let exportData = try inputSource(dependencyModuleExport).withData { Data($0) }
                let export = try decoder.decode(CodebaseInfo.ModuleExport.self, from: exportData)
                dependentModuleExports.append(export)
                let exportLoadEnd = Date().timeIntervalSinceReferenceDate
                info("\(dependencyModuleExport.basename) codebase (\(exportData.count.byteCount)) loaded (\(Int64((exportLoadEnd - exportLoadStart) * 1000)) ms) for \(linkModuleName)", sourceFile: dependencyModuleExport.sourceFile)
            } catch let e {
                throw error("Skip: error loading codebase for \(linkModuleName): \(e.localizedDescription)", sourceFile: dependencyModuleExport.sourceFile)
            }
        }

        let codebaseInfo = CodebaseInfo(moduleName: primaryModuleName)
        codebaseInfo.dependentModules = dependentModuleExports
        return codebaseInfo
    }

    /// Links the CMake project's ext/ directory to the project folder.
    func linkCMakeProject() throws {
        let extLink = moduleRootPath.appending(component: "ext")
        try addLink(extLink, pointingAt: projectFolderPath, relative: false)
    }

    /// Creates output folders and sets up the androidTest symlink for test modules.
    ///
    /// - Returns: The path to the Kotlin output folder.
    func setupOutputFolders() throws -> AbsolutePath {
        let kotlinOutputFolder = try AbsolutePath(outputFolderPath, validating: "kotlin")

        if !fs.isDirectory(kotlinOutputFolder) {
            try fs.createDirectory(kotlinOutputFolder, recursive: true)
        }

        // Link src/androidTest/kotlin → src/test/kotlin for test modules
        if primaryModuleName.hasSuffix("Tests") {
            let androidTestOutputFolder = try AbsolutePath(outputFolderPath, validating: "../androidTest")
            removePath(androidTestOutputFolder)
            try fs.createSymbolicLink(addOutputFile(androidTestOutputFolder), pointingAt: outputFolderPath, relative: true)
        }

        return kotlinOutputFolder
    }

    /// Creates transpiler transformers and links override files from the Skip/ folder.
    ///
    /// Override `.kt` files in the Skip/ folder take precedence over transpiled output.
    /// The `buildSrc` folder, if present, is also linked for Gradle build scripts.
    ///
    /// - Parameter kotlinOutputFolder: The Kotlin output folder to link overrides into.
    func setupTransformersAndOverrides(kotlinOutputFolder: AbsolutePath) throws {
        let transformers = try command.createTransformers(for: baseSkipConfig, with: configMap)
        let overridden = try linkSkipFolder(skipFolderPath, to: kotlinOutputFolder, topLevel: true)
        self.overriddenKotlinFiles = overridden.map({ $0.basename })

        let buildSrcFolder = skipFolderPath.appending(component: buildSrcFolderName)
        if fs.isDirectory(buildSrcFolder) {
            try addLink(moduleBasePath.appending(component: buildSrcFolderName), pointingAt: buildSrcFolder, relative: false)
        }

        // Store transformers for use by the transpiler
        self._transformers = transformers
    }

    /// Stored transformers, set by ``setupTransformersAndOverrides(kotlinOutputFolder:)``.
    private var _transformers: [KotlinTransformer] = []

    /// Creates and runs the transpiler, handling each transpilation result.
    ///
    /// Source files are categorized into transpilation targets (transpiled mode) or
    /// native bridge files (native mode). The transpiler processes all files and
    /// calls ``handleTranspilation(transpilation:kotlinOutputFolder:with:)`` for each result.
    ///
    /// - Parameters:
    ///   - autoBridge: The auto-bridge mode for the transpiler.
    ///   - dynamicRoot: The dynamic root class name, if any.
    ///   - kotlinOutputFolder: The Kotlin output folder path.
    ///   - out: The message queue for yielding results.
    func runTranspiler(autoBridge: AutoBridge, dynamicRoot: String?, kotlinOutputFolder: AbsolutePath, with out: MessageQueue) async throws {
        let (transpileFiles, swiftFiles) = Self.categorizeSourceFiles(sourceURLs: sourceURLs, isNative: isNativeModule)

        let transpiler = Transpiler(
            packageName: packageName,
            transpileFiles: transpileFiles.map(Source.FilePath.init(path:)),
            bridgeFiles: swiftFiles.map(Source.FilePath.init(path:)),
            autoBridge: autoBridge,
            isBridgeGatherEnabled: dynamicRoot != nil,
            codebaseInfo: codebaseInfo,
            preprocessorSymbols: Set(command.inputOptions.symbols),
            transformers: _transformers)

        try await transpiler.transpile(handler: { transpilation in
            try await self.handleTranspilation(transpilation: transpilation, kotlinOutputFolder: kotlinOutputFolder, with: out)
        })
    }

    /// Handles a single transpilation result by writing output files and forwarding messages.
    ///
    /// Bridge transpilations are accumulated for later processing. Regular transpilations
    /// are written to the Kotlin output folder with source mapping files.
    ///
    /// - Parameters:
    ///   - transpilation: The transpilation result to process.
    ///   - kotlinOutputFolder: The Kotlin output folder path.
    ///   - out: The message queue for yielding results.
    func handleTranspilation(transpilation: Transpilation, kotlinOutputFolder: AbsolutePath, with out: MessageQueue) async throws {
        for message in transpilation.messages {
            await out.yield(message)
        }

        switch transpilation.outputType {
        case .bridgeToSwift, .bridgeFromSwift:
            skipBridgeTranspilations.append(transpilation)
            return
        case .default:
            break
        }

        if skipstoneOptions.skipBridgeOutput != nil {
            return
        }

        let sourcePath = try AbsolutePath(validating: transpilation.input.file.path)

        let (outputFile, changed, overridden) = try saveTranspilation(transpilation: transpilation, kotlinOutputFolder: kotlinOutputFolder)

        info("\(outputFile.relative(to: moduleBasePath).pathString) (\(transpilation.output.content.lengthOfBytes(using: .utf8).byteCount)) transpilation \(overridden ? "overridden" : !changed ? "unchanged" : "saved") from \(sourcePath.basename) (\(transpilation.input.content.lengthOfBytes(using: .utf8).byteCount)) in \(Int64(transpilation.duration * 1000)) ms", sourceFile: overridden ? transpilation.input.file : outputFile.sourceFile)

        for message in transpilation.messages {
            if message.kind == .error {
                await out.finish(throwing: message)
                return
            }
        }

        let output = SkipstoneCommand.Output(transpilation: transpilation)
        await out.yield(output)
    }

    /// Writes a single transpilation's Kotlin output and source map to disk.
    ///
    /// If the output filename has been overridden by a file in the Skip/ folder,
    /// the transpiled output is skipped.
    ///
    /// - Parameters:
    ///   - transpilation: The transpilation result to save.
    ///   - kotlinOutputFolder: The Kotlin output folder path.
    /// - Returns: A tuple of (output path, whether the file changed, whether it was overridden).
    func saveTranspilation(transpilation: Transpilation, kotlinOutputFolder: AbsolutePath) throws -> (output: AbsolutePath, changed: Bool, overridden: Bool) {
        trace("path: \(kotlinOutputFolder)")

        let kotlinName = transpilation.kotlinFileName
        guard let outputFilePath = try Self.resolveSourceFileOutputPath(
            for: kotlinName, packageName: packageName,
            kotlinFolder: kotlinOutputFolder,
            javaFolder: try AbsolutePath(outputFolderPath, validating: "java"),
            manifestName: androidManifestName, basePath: nil) else {
            throw error("No output path for \(kotlinName)")
        }

        if overriddenKotlinFiles.contains(kotlinName) {
            return (output: outputFilePath, changed: false, overridden: true)
        }

        let kotlinBytes = ByteString(encodingAsUTF8: transpilation.output.content)
        let fileWritten = try fs.writeChanges(path: addOutputFile(outputFilePath), checkSize: true, makeReadOnly: true, bytes: kotlinBytes)

        trace("wrote to: \(outputFilePath)\(!fileWritten ? " (unchanged)" : "")")

        // Save the source map file
        let sourceMappingPath = outputFilePath.parentDirectory.appending(component: "." + outputFilePath.basenameWithoutExt + ".sourcemap")
        let sourceMapData = try self.encoder.encode(transpilation.outputMap)
        try fs.writeChanges(path: addOutputFile(sourceMappingPath), makeReadOnly: true, bytes: ByteString(sourceMapData))

        return (output: outputFilePath, changed: fileWritten, overridden: false)
    }

    // MARK: - Phase 5: Output Saving & Linking

    /// Saves the codebase info JSON for consumption by downstream module transpilations.
    func saveCodebaseInfo() throws {
        let outputFilePath = try moduleBasePath.appending(moduleExportPath(forModule: primaryModuleName))
        let moduleExport = CodebaseInfo.ModuleExport(of: codebaseInfo)
        try writeChanges(tag: "codebase", to: outputFilePath, contents: encoder.encode(moduleExport), readOnly: true)
    }

    /// Saves bridge code files or sets up the native Swift link tree.
    ///
    /// When `--skip-bridge-output` is set, writes generated bridge Swift files
    /// for each source file. Otherwise, if the module is native or has bridge
    /// transpilations, creates a mirrored link tree for native Swift compilation
    /// on Android.
    func saveSkipBridgeCode() throws {
        if let skipBridgeOutput = skipstoneOptions.skipBridgeOutput {
            let skipBridgeOutputFolder = try AbsolutePath(validating: skipBridgeOutput)

            let swiftBridgeFileNameTranspilationMap = skipBridgeTranspilations.reduce(into: Dictionary<String, Transpilation>()) { result, transpilation in
                result[transpilation.output.file.name] = transpilation
            }

            for swiftSourceFile in sourceURLs.filter({ $0.pathExtension == "swift"}) {
                let swiftFileBase = swiftSourceFile.deletingPathExtension().lastPathComponent
                let swiftBridgeFileName = swiftFileBase.appending(Source.FilePath.bridgeFileSuffix)
                let swiftBridgeOutputPath = skipBridgeOutputFolder.appending(components: [swiftBridgeFileName])

                let bridgeContents: String
                if let bridgeTranspilation = swiftBridgeFileNameTranspilationMap[swiftBridgeFileName] {
                    bridgeContents = bridgeTranspilation.output.content
                } else {
                    bridgeContents = ""
                }
                try writeChanges(tag: "skipbridge", to: swiftBridgeOutputPath, contents: bridgeContents.utf8Data, readOnly: true)
            }

            for supportFileName in [KotlinDynamicObjectTransformer.supportFileName, KotlinBundleTransformer.supportFileName, KotlinFoundationBridgeTransformer.supportFileName] {
                let supportContents: String
                if let supportTranspilation = swiftBridgeFileNameTranspilationMap[supportFileName] {
                    supportContents = supportTranspilation.output.content
                } else {
                    supportContents = ""
                }
                let supportOutputPath = skipBridgeOutputFolder.appending(components: [supportFileName])
                try writeChanges(tag: "skipbridge", to: supportOutputPath, contents: supportContents.utf8Data, readOnly: true)
            }

            return
        }

        guard isNativeModule || !skipBridgeTranspilations.isEmpty else {
            return
        }

        // Link src/main/swift/ to the Swift project folder for native compilation
        let swiftLinkFolder = try AbsolutePath(outputFolderPath, validating: "swift")
        try fs.createDirectory(swiftLinkFolder, recursive: true)

        let packagesLinkFolder = try AbsolutePath(swiftLinkFolder, validating: "Packages")
        try fs.createDirectory(packagesLinkFolder, recursive: true)

        var packageAddendum = """
        
        /// Convert remote dependencies into their locally-cached versions.
        /// This allows us to re-use dependencies from the parent
        /// Xcode/SwiftPM process without redundently cloning them.
        func useLocalPackage(named packageName: String, id packageID: String, dependencies: inout [Package.Dependency]) {
            func localDependency(name: String?, location: String) -> Package.Dependency? {
                if name == packageID || location.hasSuffix("/" + packageID) || location.hasSuffix("/" + packageID + ".git") {
                    return Package.Dependency.package(path: "Packages/" + packageID)
                } else {
                    return nil
                }
            }
            dependencies = dependencies.map { dep in
                switch dep.kind {
                case let .sourceControl(name: name, location: location, requirement: _):
                    return localDependency(name: name, location: location) ?? dep
                case let .fileSystem(name: name, path: location):
                    return localDependency(name: name, location: location) ?? dep
                default:
                    return dep
                }
            }
        }
        
        """

        var createdIds: Set<String> = []
        let moduleLinkPaths = Dictionary(self.linkNamePaths, uniquingKeysWith: { $1 })

        for (targetName, packageName, var packagePath) in self.dependencyIdPaths {
            let packageID = packagePath.split(separator: "/").last?.description ?? packagePath

            if !createdIds.insert(packageID).inserted {
                continue
            }

            if let relativeLinkPath = moduleLinkPaths[targetName] {
                let linkModuleRoot = moduleRootPath
                    .parentDirectory
                    .appending(try RelativePath(validating: relativeLinkPath))
                let linkModuleSrcMainSwift = linkModuleRoot.appending(components: "src", "main", "swift")
                if fs.exists(linkModuleSrcMainSwift) {
                    info("override link path for \(targetName) from \(packagePath) to \(linkModuleSrcMainSwift.pathString)")
                    packagePath = linkModuleSrcMainSwift.pathString
                }
            }

            let dependencyPackageLink = try AbsolutePath(packagesLinkFolder, validating: packageID)
            let destinationPath = try AbsolutePath(validating: packagePath)
            try addLink(dependencyPackageLink, pointingAt: destinationPath, relative: false)

            packageAddendum += """
            useLocalPackage(named: "\(packageName)", id: "\(packageID)", dependencies: &package.dependencies)
            
            """
        }

        let mirrorSource = projectFolderPath.appending(components: "..", "..")

        try createMirroredLinkTree(swiftLinkFolder, pointingAt: mirrorSource, shallow: true, excluding: ["Packages", "Package.resolved", ".build", ".swiftpm", "skip-export", "build"]) { destPath, path in
            self.trace("createMirroredLinkTree for \(path.pathString)->\(destPath)")

            if path.basename == "Package.swift" && !self.dependencyIdPaths.isEmpty {
                let packageContents = try self.fs.readFileContents(path).withData { $0 + packageAddendum.utf8Data }
                try self.writeChanges(tag: "skippackage", to: destPath, contents: packageContents, readOnly: true)
                return false
            } else {
                return true
            }
        }
    }

    /// Links dependent module output directories into the current module's output tree.
    ///
    /// Creates symbolic links from the dependent module build outputs to the current
    /// module, allowing Gradle to see all modules in a unified project structure.
    ///
    /// - Returns: The list of dependent module names that were linked.
    func linkDependentModuleSources() throws -> [String] {
        var dependentModules: [String] = []
        let moduleBasePath = moduleRootPath.parentDirectory

        for (linkModuleName, relativeLinkPath) in linkNamePaths {
            let linkModulePath = try moduleBasePath.appending(RelativePath(validating: linkModuleName))
            trace("relativeLinkPath: \(relativeLinkPath) moduleBasePath: \(moduleBasePath) linkModuleName: \(linkModuleName) -> linkModulePath: \(linkModulePath)")
            try createMergedRelativeLinkTree(from: linkModulePath, to: relativeLinkPath, shallow: false)
            dependentModules.append(linkModuleName)
        }

        return dependentModules
    }
}

extension SkipstoneSession {
    /// Links resource files from the project to the output assets folder.
    ///
    /// Iterates through ``resourceEntries`` and dispatches each entry to either
    /// ``linkCopyResources(entry:resourcesBasePath:)`` or
    /// ``linkProcessResources(entry:resourcesBasePath:)`` based on its mode.
    func linkResources() throws {
        let resourcesOutputFolder = try AbsolutePath(outputFolderPath, validating: "assets")
        let resourcesBasePath = resourcesOutputFolder
            .appending(components: packageName.split(separator: ".").map(\.description))
            .appending(component: "Resources")

        for entry in resourceEntries {
            if entry.isCopyMode {
                try linkCopyResources(entry: entry, resourcesBasePath: resourcesBasePath)
            } else {
                try linkProcessResources(entry: entry, resourcesBasePath: resourcesBasePath)
            }
        }
    }

    /// Links resources in "copy" mode, preserving the full directory hierarchy.
    ///
    /// In copy mode, the resource folder name is preserved as a subdirectory prefix,
    /// matching Darwin's `.copy()` behavior. For example, a file at
    /// `ResourcesCopy/subdir/file.txt` is linked to `Resources/ResourcesCopy/subdir/file.txt`.
    ///
    /// - Parameters:
    ///   - entry: The resource entry to link.
    ///   - resourcesBasePath: The base output path for resources.
    private func linkCopyResources(entry: ResourceEntry, resourcesBasePath: AbsolutePath) throws {
        for resourceFile in entry.urls.map(\.path).sorted() {
            let resourceFileCanonical = (resourceFile as NSString).standardizingPath
            guard let resourceSourceURL = moduleNamePaths.compactMap({ (_, folder) -> URL? in
                let folderCanonical = (folder as NSString).standardizingPath
                guard resourceFileCanonical.hasPrefix(folderCanonical) else { return nil }
                let relativePath = String(resourceFileCanonical.dropFirst(folderCanonical.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return URL(fileURLWithPath: relativePath, relativeTo: URL(fileURLWithPath: folderCanonical, isDirectory: true))
            }).first else {
                msg(.trace, "no module root parent for \(resourceFile)")
                continue
            }

            let sourcePath = try AbsolutePath(validating: resourceSourceURL.path)
            let resourceComponents = try RelativePath(validating: resourceSourceURL.relativePath).components

            let resourceSourcePath = try RelativePath(validating: resourceComponents.joined(separator: "/"))
            let destinationPath = resourcesBasePath.appending(resourceSourcePath)

            if sourcePath.parentDirectory.basename == buildSrcFolderName {
                trace("skipping resource linking for buildSrc/")
            } else if isCMakeProject {
                trace("skipping resource linking for CMake project")
            } else if fs.isFile(sourcePath) {
                info("\(destinationPath.relative(to: moduleBasePath).pathString) copying to \(sourcePath.pathString)", sourceFile: sourcePath.sourceFile)
                try fs.createDirectory(destinationPath.parentDirectory, recursive: true)
                try addLink(destinationPath, pointingAt: sourcePath, relative: false)
            }
        }
    }

    /// Links resources in "process" mode, flattening the hierarchy.
    ///
    /// In process mode, the resource directory prefix is stripped and files are placed
    /// directly in the Resources/ output folder. Special handling is applied for:
    /// - `.xcstrings` files, which are converted to `.strings` and `.stringsdict` localizations
    /// - `res/` prefixed resources, which are placed in the Android res/ folder
    ///
    /// - Parameters:
    ///   - entry: The resource entry to link.
    ///   - resourcesBasePath: The base output path for resources.
    private func linkProcessResources(entry: ResourceEntry, resourcesBasePath: AbsolutePath) throws {
        let resOutputFolder = try AbsolutePath(outputFolderPath, validating: "res")

        for resourceFile in entry.urls.map(\.path).sorted() {
            let resourceFileCanonical = (resourceFile as NSString).standardizingPath
            guard let resourceSourceURL = moduleNamePaths.compactMap({ (_, folder) -> URL? in
                let folderCanonical = (folder as NSString).standardizingPath
                guard resourceFileCanonical.hasPrefix(folderCanonical) else { return nil }
                let relativePath = String(resourceFileCanonical.dropFirst(folderCanonical.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return URL(fileURLWithPath: relativePath, relativeTo: URL(fileURLWithPath: folderCanonical, isDirectory: true))
            }).first else {
                msg(.trace, "no module root parent for \(resourceFile)")
                continue
            }

            let sourcePath = try AbsolutePath(validating: resourceSourceURL.path)

            let resourceComponents = try RelativePath(validating: resourceSourceURL.relativePath).components
            let components = resourceComponents.dropFirst(1)
            let resourceSourcePath = try RelativePath(validating: components.joined(separator: "/"))

            if sourcePath.parentDirectory.basename == buildSrcFolderName {
                trace("skipping resource linking for buildSrc/")
            } else if isCMakeProject {
                trace("skipping resource linking for CMake project")
            } else if sourcePath.extension == "xcstrings" {
                try convertStrings(resourceSourceURL: resourceSourceURL, sourcePath: sourcePath, resourcesBasePath: resourcesBasePath)
            } else {
                let isAndroidRes = resourceComponents.first == "res"
                let destinationPath = (isAndroidRes ? resOutputFolder : resourcesBasePath).appending(resourceSourcePath)

                if fs.isFile(sourcePath) {
                    info("\(destinationPath.relative(to: moduleBasePath).pathString) linking to \(sourcePath.pathString)", sourceFile: sourcePath.sourceFile)
                    try fs.createDirectory(destinationPath.parentDirectory, recursive: true)
                    try addLink(destinationPath, pointingAt: sourcePath, relative: false)
                }
            }
        }
    }

    /// Converts `.xcstrings` files to `.strings` and `.stringsdict` localization files.
    ///
    /// Parses the Xcode string catalog JSON and generates per-locale `.strings` files
    /// (for simple translations) and `.stringsdict` plist files (for plural rules),
    /// mirroring the conversion Xcode performs for iOS builds.
    ///
    /// - Parameters:
    ///   - resourceSourceURL: The URL of the `.xcstrings` file.
    ///   - sourcePath: The absolute path to the `.xcstrings` file.
    ///   - resourcesBasePath: The base output path for localization folders.
    private func convertStrings(resourceSourceURL: URL, sourcePath: AbsolutePath, resourcesBasePath: AbsolutePath) throws {
        let xcstrings = try JSONDecoder().decode(LocalizableStringsDictionary.self, from: Data(contentsOf: resourceSourceURL))
        let defaultLanguage = xcstrings.sourceLanguage
        let locales = Set(xcstrings.strings.values.compactMap(\.localizations?.keys).joined())
        for localeId in locales {
            let lprojFolder = resourcesBasePath.appending(component: localeId + ".lproj")
            let locBase = sourcePath.basenameWithoutExt

            var locdict: [String: String] = [:]
            var plurals: [String: [String : LocalizableStringsDictionary.StringUnit]] = [:]

            for (key, value) in xcstrings.strings {
                guard let localized = value.localizations?[localeId] else {
                    continue
                }
                if let value = localized.stringUnit?.value {
                    locdict[key] = value
                }
                if let pluralDict = localized.variations?.plural {
                    plurals[key] = pluralDict.mapValues(\.stringUnit)
                }
            }

            if !locdict.isEmpty {
                func escape(_ string: String) throws -> String? {
                    let writingOptions: JSONSerialization.WritingOptions
                    if #available(iOS 13.0, macOS 15.0, *) {
                        writingOptions = [
                            .sortedKeys, // needed for deterministic output
                            .withoutEscapingSlashes,
                        ]
                    } else {
                        writingOptions = [
                            .sortedKeys,
                        ]
                    }

                    return try String(data: JSONSerialization.data(withJSONObject: string, options: writingOptions), encoding: .utf8)
                }

                var stringsContent = ""
                for (key, value) in locdict.sorted(by: { $0.key < $1.key }) {
                    if let keyString = try escape(key), let valueString = try escape(value) {
                        stringsContent += keyString + " = " + valueString + ";\n"
                    }
                }
                try fs.createDirectory(lprojFolder, recursive: true)
                if localeId == defaultLanguage {
                    try addLink(resourcesBasePath.appending(component: "base.lproj"), pointingAt: lprojFolder, relative: true)
                }

                let localizableStrings = try RelativePath(validating: locBase + ".strings")
                let localizableStringsPath = lprojFolder.appending(localizableStrings)
                info("create \(localizableStrings.pathString) from \(sourcePath.pathString)", sourceFile: localizableStringsPath.sourceFile)
                try writeChanges(tag: localizableStrings.pathString, to: localizableStringsPath, contents: stringsContent.utf8Data, readOnly: false)
            }

            if !plurals.isEmpty {
                let localizableStringsDict = try RelativePath(validating: locBase + ".stringsdict")

                var pluralDictNodes: [Universal.XMLNode] = []
                for (key, value) in plurals.sorted(by: { $0.key < $1.key }) {
                    pluralDictNodes.append(Universal.XMLNode(elementName: "key", children: [.content(key)]))

                    var pluralsDict = Universal.XMLNode(elementName: "dict")
                    pluralsDict.addPlist(key: "NSStringLocalizedFormatKey", stringValue: "%#@value@")

                    pluralsDict.append(Universal.XMLNode(elementName: "key", children: [.content("value")]))
                    var pluralsSubDict = Universal.XMLNode(elementName: "dict")

                    pluralsSubDict.addPlist(key: "NSStringFormatSpecTypeKey", stringValue: "NSStringPluralRuleType")
                    pluralsSubDict.addPlist(key: "NSStringFormatValueTypeKey", stringValue: "lld")

                    for (pluralType, stringUnit) in value.sorted(by: { $0.key < $1.key }) {
                        if let stringUnitValue = stringUnit.value {
                            pluralsSubDict.addPlist(key: pluralType, stringValue: stringUnitValue)
                        }
                    }
                    pluralsDict.append(pluralsSubDict)
                    pluralDictNodes.append(pluralsDict)
                }

                let pluralDict = Universal.XMLNode(elementName: "dict", children: pluralDictNodes.map({ .element($0) }))

                let stringsDictPlist = Universal.XMLNode(elementName: "plist", attributes: ["version": "1.0"], children: [.element(pluralDict)])
                let stringsDictDocument = Universal.XMLNode(elementName: "", children: [.element(stringsDictPlist)])

                let localizableStringsDictPath = lprojFolder.appending(localizableStringsDict)
                info("create \(localizableStringsDict.pathString) from \(sourcePath.pathString)", sourceFile: localizableStringsDictPath.sourceFile)
                try writeChanges(tag: localizableStringsDict.pathString, to: localizableStringsDictPath, contents: stringsDictDocument.xmlString().utf8Data, readOnly: false)
            }
        }
    }
}

extension SkipstoneSession {
    // MARK: - Phase 6: Gradle Generation

    /// Generates all Gradle build files for the module.
    ///
    /// Creates the per-module `build.gradle.kts`, the project `settings.gradle.kts`,
    /// `gradle.properties`, `proguard-rules.pro`, and the Gradle wrapper properties.
    ///
    /// - Parameters:
    ///   - sourceModules: The dependent source module names to include in settings.
    ///   - skipConfig: The merged skip.yml configuration.
    ///   - isApp: Whether this is an app module (affects Gradle plugin selection).
    func generateGradle(for sourceModules: [String], with skipConfig: SkipConfig, isApp: Bool) throws {
        let buildGradle = moduleRootPath.appending(component: "build.gradle.kts")
        try generateGradleWrapperProperties()
        try generateProguardFile(packageName)
        try generatePerModuleGradle(config: skipConfig, buildGradle: buildGradle)
        try generateGradleProperties(config: skipConfig)
        try generateSettingsGradle(sourceModules: sourceModules, config: skipConfig)
    }

    /// Generates the per-module `build.gradle.kts` file from the merged config.
    ///
    /// - Parameters:
    ///   - config: The merged skip.yml configuration.
    ///   - buildGradle: The output path for build.gradle.kts.
    private func generatePerModuleGradle(config: SkipConfig, buildGradle: AbsolutePath) throws {
        let buildContents = (config.build ?? .init()).generate(context: .init(dsl: .kotlin))

        trace("created gradle: \(buildContents.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).joined(separator: "; "))")

        let contents = """
        // build.gradle.kts generated by Skip for \(primaryModuleName)
        
        """ + buildContents

        try writeChanges(tag: "gradle project", to: buildGradle, contents: contents.utf8Data, readOnly: true)
    }

    /// Generates the project `settings.gradle.kts` with module includes.
    ///
    /// Includes the primary module and all dependent source modules. For native
    /// (bridged) modules, adds them to the `bridgeModules` Gradle extra property.
    ///
    /// - Parameters:
    ///   - sourceModules: The dependent source module names.
    ///   - config: The merged skip.yml configuration.
    private func generateSettingsGradle(sourceModules: [String], config: SkipConfig) throws {
        let settingsPath = moduleRootPath.parentDirectory.appending(component: "settings.gradle.kts")
        var settingsContents = (config.settings ?? .init()).generate(context: .init(dsl: .kotlin))

        settingsContents += """
        
        rootProject.name = "\(packageName ?? "")"
        
        """

        var bridgedModules: [String] = []

        func addIncludeModule(_ moduleName: String) {
            settingsContents += """
            include(":\(moduleName)")
            project(":\(moduleName)").projectDir = file("\(moduleName)")
            
            """

            if Self.resolveModuleMode(moduleName: moduleName, configMap: configMap, baseConfig: baseSkipConfig, hasSkipFuse: hasSkipFuse, primaryModuleName: primaryModuleName) == .native {
                bridgedModules.append(moduleName)
            }
        }

        if !sourceModules.contains(primaryModuleName) && !primaryModuleName.hasSuffix("Tests") {
            addIncludeModule(primaryModuleName)
        }

        for sourceModule in sourceModules {
            addIncludeModule(sourceModule)
        }

        if !bridgedModules.isEmpty {
            settingsContents += """
            
            gradle.extra["bridgeModules"] = listOf("\(bridgedModules.joined(separator: "\", \""))")
            
            """
        }

        try writeChanges(tag: "gradle settings", to: settingsPath, contents: settingsContents.utf8Data, readOnly: true)
    }

    /// Generates the `proguard-rules.pro` file for release build optimization.
    ///
    /// - Parameter packageName: The Kotlin package name for keep rules.
    private func generateProguardFile(_ packageName: String) throws {
        try writeChanges(tag: "proguard", to: moduleRootPath.appending(component: "proguard-rules.pro"), contents: FrameworkProjectLayout.defaultProguardContents(packageName).utf8Data, readOnly: true)
    }

    /// Generates the `gradle-wrapper.properties` file specifying the Gradle distribution version.
    private func generateGradleWrapperProperties() throws {
        let gradleWrapperFolder = moduleRootPath.parentDirectory.appending(components: "gradle", "wrapper")
        try fs.createDirectory(gradleWrapperFolder, recursive: true)
        let gradleWrapperPath = gradleWrapperFolder.appending(component: "gradle-wrapper.properties")
        let gradeWrapperContents = FrameworkProjectLayout.defaultGradleWrapperProperties()
        try writeChanges(tag: "gradle wrapper", to: gradleWrapperPath, contents: gradeWrapperContents.utf8Data, readOnly: true)
    }

    /// Generates the `gradle.properties` file, merging defaults with custom properties from skip.yml.
    ///
    /// - Parameter config: The merged skip.yml configuration containing optional custom properties.
    private func generateGradleProperties(config: SkipConfig) throws {
        let gradlePropertiesPath = moduleRootPath.parentDirectory.appending(component: "gradle.properties")
        let contents = Self.mergeGradleProperties(
            defaults: FrameworkProjectLayout.defaultGradleProperties(),
            custom: config.gradleProperties)
        try writeChanges(tag: "gradle config", to: gradlePropertiesPath, contents: contents.utf8Data, readOnly: true)
    }
}

extension SkipstoneSession {
    // MARK: - Phase 7: Cleanup

    /// Removes stale output files and writes the sourcehash completion marker.
    ///
    /// Called in a `defer` block to ensure cleanup happens even on error.
    func finalizeSession() {
        cleanupStaleOutputFiles()
        do {
            try saveSourcehashFile()
        } catch {
            warn("could not create build completion marker: \(error)")
        }
    }

    /// Removes output files from previous runs that are no longer being produced.
    ///
    /// Compares the ``outputFilesSnapshot`` taken at session start against the
    /// ``outputFiles`` accumulated during this run. Files present in the snapshot
    /// but not in the current outputs are considered stale and removed.
    /// `Package.resolved` is excluded since it's managed by the native build system.
    func cleanupStaleOutputFiles() {
        let staleFiles = Self.identifyStaleFiles(snapshot: outputFilesSnapshot, outputFiles: outputFiles)
        for staleFile in staleFiles.sorted() {
            let staleFileURL = URL(fileURLWithPath: staleFile, isDirectory: false)
            if staleFileURL.lastPathComponent == "Package.resolved" {
                continue
            }
            msg(.warning, "removing stale output file: \(staleFileURL.lastPathComponent)", sourceFile: try? staleFileURL.absolutePath.sourceFile)

            do {
                try FileManager.default.trash(fileURL: staleFileURL, trash: false)
            } catch {
                msg(.warning, "error removing stale output file: \(staleFileURL.lastPathComponent): \(error)")
            }
        }
    }

    /// Writes the sourcehash marker file with current source file hashes.
    ///
    /// The marker file signals to the build plugin host that the transpilation
    /// is complete and records the source hashes for future change detection.
    func saveSourcehashFile() throws {
        if !fs.isDirectory(moduleBasePath) {
            try fs.createDirectory(moduleBasePath, recursive: true)
        }

        struct SourcehashContents : Encodable {
            let skipstone: String = skipVersion
            let sourcehashes: [String: String]
        }

        let sourcePathHashes: [(String, String)] = sourcehashes.compactMap { url, sourcehash in
            let absolutePath = url.path
            if !absolutePath.hasPrefix(projectFolderPath.pathString) {
                return .none
            }

            let relativePath = absolutePath.dropFirst(projectFolderPath.pathString.count).trimmingPrefix(while: { $0 == "/" })
            return (relativePath.description, sourcehash)
        }

        let sourcehashOutputPath = try AbsolutePath(validating: skipstoneOptions.sourcehash)
        let sourcehash = SourcehashContents(sourcehashes: Dictionary(sourcePathHashes, uniquingKeysWith: { $1 }))
        try writeChanges(tag: "sourcehash", to: sourcehashOutputPath, contents: try encoder.encode(sourcehash), readOnly: false)
    }
}

extension SkipstoneSession {
    // MARK: - File Operation Helpers

    /// Registers a path as an output file to prevent stale file cleanup.
    ///
    /// Every file written or linked during the session must be registered via this method
    /// so it is not removed during ``cleanupStaleOutputFiles()``.
    ///
    /// - Parameter path: The output file path to register.
    /// - Returns: The same path, for convenient chaining.
    @discardableResult func addOutputFile(_ path: AbsolutePath) -> AbsolutePath {
        outputFiles.append(path)
        return path
    }

    /// Registers a path as an input file for modification time tracking.
    ///
    /// - Parameter path: The input file path to register.
    /// - Returns: The same path, for convenient chaining.
    @discardableResult func addInputFile(_ path: AbsolutePath) -> AbsolutePath {
        inputFiles.append(path)
        return path
    }

    /// Reads a source file's contents and registers it as an input file.
    ///
    /// - Parameter path: The file to read.
    /// - Returns: The file contents as a `ByteString`.
    func inputSource(_ path: AbsolutePath) throws -> ByteString {
        try fs.readFileContents(addInputFile(path))
    }

    /// Writes content to an output file if it has changed, tracking the file as output.
    ///
    /// - Parameters:
    ///   - tag: A descriptive tag for logging (e.g., "gradle project", "codebase").
    ///   - outputFilePath: The destination file path.
    ///   - contents: The content to write.
    ///   - readOnly: Whether to make the file read-only after writing.
    func writeChanges(tag: String, to outputFilePath: AbsolutePath, contents: any DataProtocol, readOnly: Bool) throws {
        let changed = try fs.writeChanges(path: addOutputFile(outputFilePath), makeReadOnly: readOnly, bytes: ByteString(contents))
        info("\(outputFilePath.relative(to: moduleBasePath).pathString) (\(contents.count.byteCount)) \(tag) \(!changed ? "unchanged" : "written")", sourceFile: outputFilePath.sourceFile)
    }

    /// Creates a symbolic link (or copy for read-only files) from source to destination.
    ///
    /// For read-only files, a copy is made instead of a symlink to avoid Gradle write
    /// permission failures on subsequent builds. The output link's modification time
    /// is set to match the destination for accurate change detection.
    ///
    /// - Parameters:
    ///   - linkSource: The path where the link/copy will be created.
    ///   - destPath: The target path the link points to.
    ///   - relative: Whether to create a relative (vs absolute) symlink.
    ///   - replace: Whether to replace existing symlinks. Defaults to true.
    ///   - copyReadOnlyFiles: Whether to copy instead of link read-only files. Defaults to true.
    func addLink(_ linkSource: AbsolutePath, pointingAt destPath: AbsolutePath, relative: Bool, replace: Bool = true, copyReadOnlyFiles: Bool = true) throws {
        msg(.trace, "linking: \(linkSource) to: \(destPath)")

        if replace && fs.isSymlink(destPath) {
            removePath(destPath)
        }

        if let existingSymlinkDestination = try? FileManager.default.destinationOfSymbolicLink(atPath: linkSource.pathString) {
            if existingSymlinkDestination == destPath.pathString {
                msg(.trace, "retaining existing link from \(destPath.pathString) to \(existingSymlinkDestination)")
                addOutputFile(linkSource)
                return
            }
        }

        let destInfo = try fs.getFileInfo(destPath)
        let modTime = destInfo.modTime
        let perms = destInfo.posixPermissions

        let writablePermissions = perms | 0o200

        let shouldCopy = copyReadOnlyFiles && !fs.isDirectory(linkSource) && (perms != writablePermissions)

        removePath(linkSource)
        if shouldCopy {
            msg(.trace, "copying \(destPath) to \(linkSource)")
            try fs.copy(from: destPath, to: addOutputFile(linkSource))
            try FileManager.default.setAttributes([.posixPermissions: writablePermissions], ofItemAtPath: linkSource.pathString)
        } else {
            msg(.trace, "linking \(destPath) to \(linkSource)")
            try fs.createSymbolicLink(addOutputFile(linkSource), pointingAt: destPath, relative: relative)
        }

        try (linkSource.asURL as NSURL).setResourceValue(modTime, forKey: .contentModificationDateKey)
    }

    /// Removes a file or directory, tolerating non-existent paths.
    ///
    /// - Parameter path: The path to remove.
    /// - Returns: true if the path existed and was removed, false otherwise.
    @discardableResult
    func removePath(_ path: AbsolutePath) -> Bool {
        do {
            if !fs.exists(path, followSymlink: false) {
                return false
            }
            try fs.removeFileTree(path)
            return true
        } catch {
            warn("unable to remove entry \(path): \(error)", sourceFile: path.sourceFile)
            return false
        }
    }

    // MARK: - Link Tree Operations

    /// Resolves the output path for a source file, accounting for file type and package structure.
    ///
    /// This is a convenience instance method that delegates to the static version
    /// using the session's configured paths.
    ///
    /// - Parameters:
    ///   - baseSourceFileName: The source file's base name (e.g., "MyClass.kt").
    ///   - basePath: Optional override base path.
    /// - Returns: The resolved output path, or nil if the file should be skipped.
    func sourceFileOutputPath(for baseSourceFileName: String, in basePath: AbsolutePath? = nil) throws -> AbsolutePath? {
        try Self.resolveSourceFileOutputPath(
            for: baseSourceFileName,
            packageName: packageName,
            kotlinFolder: try AbsolutePath(outputFolderPath, validating: "kotlin"),
            javaFolder: try AbsolutePath(outputFolderPath, validating: "java"),
            manifestName: androidManifestName,
            basePath: basePath)
    }

    /// Copies override .kt files from the Skip/ folder into the output, and links subdirectories.
    ///
    /// Any Kotlin file in the Skip/ folder takes precedence over the transpiled version.
    /// Subdirectories are recursively linked to support custom Android resources and manifests.
    ///
    /// - Parameters:
    ///   - path: The Skip/ folder path to scan.
    ///   - outputFilePath: The destination output folder.
    ///   - topLevel: Whether this is the top-level Skip/ folder (affects path resolution).
    /// - Returns: The set of output file paths that were overridden.
    func linkSkipFolder(_ path: AbsolutePath, to outputFilePath: AbsolutePath, topLevel: Bool) throws -> Set<AbsolutePath> {
        if skipstoneOptions.skipBridgeOutput != nil {
            return []
        }

        var copiedFiles: Set<AbsolutePath> = []
        for fileName in try fs.getDirectoryContents(path) {
            if fileName.hasPrefix(".") {
                continue
            }

            if path.basename == buildSrcFolderName || fileName == buildSrcFolderName {
                continue
            }

            let sourcePath = try AbsolutePath(path, validating: fileName)
            let outputPath = try AbsolutePath(outputFilePath, validating: fileName)

            if fs.isDirectory(sourcePath) {
                let subPaths = try linkSkipFolder(sourcePath, to: outputPath, topLevel: false)
                copiedFiles.formUnion(subPaths)
            } else {
                if let outputFilePath = try sourceFileOutputPath(for: sourcePath.basename, in: topLevel ? nil : outputFilePath) {
                    copiedFiles.insert(outputFilePath)
                    try fs.createDirectory(outputFilePath.parentDirectory, recursive: true)
                    try addLink(outputFilePath, pointingAt: sourcePath, relative: false)
                    info("\(outputFilePath.relative(to: moduleBasePath).pathString) override linked from project source \(sourcePath.pathString)", sourceFile: sourcePath.sourceFile)
                }
            }
        }
        return copiedFiles
    }

    /// Creates merged relative symbolic links from one module's output to another.
    ///
    /// If the destination is a directory and the source already exists as a directory,
    /// recursively creates links for each child. Otherwise, creates a single relative link.
    ///
    /// - Parameters:
    ///   - fromPath: The path to create the link at.
    ///   - relative: The relative path to the link target.
    ///   - shallow: Whether to create shallow (non-recursive) links.
    func createMergedRelativeLinkTree(from fromPath: AbsolutePath, to relative: String, shallow: Bool) throws {
        let destPath = try AbsolutePath(validating: relative, relativeTo: fromPath.parentDirectory)
        if !fs.isDirectory(destPath) {
            if !fs.exists(destPath) {
                warn("Expected destination path did not exist: \(destPath)")
            }
            return
        }
        trace("creating merged link tree from: \(fromPath) to: \(relative)")
        if fs.isSymlink(fromPath) {
            removePath(fromPath)
        }

        if !shallow && fs.isDirectory(fromPath) {
            for fsEntry in try fs.getDirectoryContents(destPath) {
                let fromSubPath = fromPath.appending(try RelativePath(validating: fsEntry))
                try createMergedRelativeLinkTree(from: fromSubPath, to: "../" + relative + "/" + fsEntry, shallow: shallow)
            }
        } else {
            try addLink(fromPath, pointingAt: destPath, relative: true)
        }
    }

    /// Creates a mirror of a directory structure using symbolic links.
    ///
    /// Recursively traverses the source directory and creates corresponding links
    /// in the destination. A content handler can intercept individual files to
    /// provide custom handling (e.g., modifying Package.swift).
    ///
    /// - Parameters:
    ///   - destPath: The destination path to create the mirror at.
    ///   - fromPath: The source path to mirror.
    ///   - shallow: Whether to create shallow links (link children, don't recurse).
    ///   - excludePaths: Set of filenames to exclude from the mirror.
    ///   - contentHandler: Optional handler called for each file. Return false to skip linking.
    func createMirroredLinkTree(_ destPath: AbsolutePath, pointingAt fromPath: AbsolutePath, shallow: Bool, excluding excludePaths: Set<String> = [], contentHandler: ((_ destPath: AbsolutePath, _ fromPath: AbsolutePath) throws -> Bool)? = nil) throws {
        trace("creating absolute merged link tree from: \(fromPath) to: \(destPath)")
        if fs.isDirectory(fromPath) {
            try fs.createDirectory(destPath, recursive: true)
            for fsEntry in try fs.getDirectoryContents(fromPath) {
                if fsEntry.hasPrefix(".") || excludePaths.contains(fsEntry) {
                    continue
                }
                let rel = try RelativePath(validating: fsEntry)
                let childDestPath = destPath.appending(rel)
                let childFromPath = fromPath.appending(rel)
                if shallow {
                    if try contentHandler?(childDestPath, childFromPath) != false {
                        try addLink(childDestPath, pointingAt: childFromPath, relative: false)
                    }
                } else {
                    try createMirroredLinkTree(childDestPath, pointingAt: childFromPath, shallow: shallow, contentHandler: contentHandler)
                }
            }
        } else if fs.isFile(fromPath) {
            if try contentHandler?(destPath, fromPath) != false {
                try addLink(destPath, pointingAt: fromPath, relative: false)
            } else {
                warn("unknown file type encountered when creating links: \(fromPath)")
            }
        }
    }

    // MARK: - Utility Helpers

    /// Returns the relative path for a module's codebase info JSON file.
    ///
    /// - Parameter moduleName: The module name.
    /// - Returns: The relative path like "ModuleName.skipcode.json".
    func moduleExportPath(forModule moduleName: String) throws -> RelativePath {
        try RelativePath(validating: moduleName + skipcodeExtension)
    }

    // MARK: - Static Pure Functions (Testable)

    /// Determines the output path for a source file based on its type and the package structure.
    ///
    /// - Kotlin (`.kt`) files are placed under `kotlinFolder/package/path/File.kt`
    /// - Java (`.java`) files are placed under `javaFolder/package/path/File.java`
    /// - `AndroidManifest.xml` is placed one level up from the type-specific folder
    /// - `skip.yml` files return nil (excluded from output)
    ///
    /// - Parameters:
    ///   - fileName: The source file's base name.
    ///   - packageName: The Kotlin package name (e.g., "skip.foundation").
    ///   - kotlinFolder: The base Kotlin output folder.
    ///   - javaFolder: The base Java output folder.
    ///   - manifestName: The Android manifest filename.
    ///   - basePath: Optional override base path; when set, the file is placed relative to it.
    /// - Returns: The resolved output path, or nil if the file should be skipped.
    static func resolveSourceFileOutputPath(
        for fileName: String,
        packageName: String,
        kotlinFolder: AbsolutePath,
        javaFolder: AbsolutePath,
        manifestName: String,
        basePath: AbsolutePath?
    ) throws -> AbsolutePath? {
        if fileName == "skip.yml" {
            return nil
        }

        let rawSourceDestination = fileName.hasSuffix(".kt") ? kotlinFolder : javaFolder

        let isManifest = fileName == manifestName
        return try (basePath ?? rawSourceDestination
            .appending(components: isManifest ? [".."] : packageName.split(separator: ".").map(\.description)))
            .appending(RelativePath(validating: fileName))
    }

    /// Determines the module mode for a given module based on skip.yml configuration.
    ///
    /// The mode controls how the module is processed:
    /// - `.native` — Swift is compiled natively on Android via the Swift toolchain.
    /// - `.transpiled` — Swift is transpiled to Kotlin.
    ///
    /// When the mode is `"automatic"` (the default), the presence of SkipFuse in the
    /// dependency graph causes the primary module to use native mode.
    ///
    /// - Parameters:
    ///   - moduleName: The module to check, or nil for the primary module.
    ///   - configMap: Map of module names to their skip.yml configs.
    ///   - baseConfig: The base skip.yml config for the current module.
    ///   - hasSkipFuse: Whether SkipFuse is in the dependency graph.
    ///   - primaryModuleName: The primary module name being processed.
    /// - Returns: The resolved module mode.
    static func resolveModuleMode(
        moduleName: String?,
        configMap: [String: SkipConfig],
        baseConfig: SkipConfig,
        hasSkipFuse: Bool,
        primaryModuleName: String
    ) -> ModuleMode {
        let moduleMode: String?

        if let moduleName {
            moduleMode = configMap[moduleName]?.skip?.mode
        } else {
            moduleMode = baseConfig.skip?.mode
        }

        switch moduleMode {
        case "native": return .native
        case "transpiled": return .transpiled
        case "automatic", .none: return hasSkipFuse && (moduleName == primaryModuleName || moduleName == nil) ? .native : .transpiled
        default:
            return .transpiled
        }
    }

    /// Determines whether a module is a test dependency (not the primary or its test peer).
    ///
    /// A module is NOT a test module if:
    /// - It equals the primary module name, OR
    /// - It equals the primary module name with "Tests" stripped (the test peer relationship)
    ///
    /// This is used to determine Gradle dependency types: test modules get
    /// `testImplementation` while non-test modules get `api`.
    ///
    /// - Parameters:
    ///   - moduleName: The module name to check.
    ///   - primaryModuleName: The primary module name.
    /// - Returns: true if the module is a test dependency.
    static func isTestModule(_ moduleName: String, primaryModuleName: String) -> Bool {
        primaryModuleName != moduleName && primaryModuleName != moduleName + "Tests"
    }

    /// Identifies output files from a previous run that are no longer being produced.
    ///
    /// Takes the set difference between the snapshot file paths and the current output
    /// file paths. `Package.resolved` exclusion is handled by the caller.
    ///
    /// - Parameters:
    ///   - snapshot: URLs of files that existed before the current run.
    ///   - outputFiles: Paths of files produced during the current run.
    /// - Returns: Set of stale file path strings that should be cleaned up.
    static func identifyStaleFiles(snapshot: [URL], outputFiles: [AbsolutePath]) -> Set<String> {
        Set(snapshot.map(\.path))
            .subtracting(outputFiles.map(\.pathString))
    }

    /// Partitions source file URLs into transpilation targets and native bridge files.
    ///
    /// In native mode, all files become bridge files (compiled natively on Android).
    /// In transpiled mode, all files become transpilation targets.
    ///
    /// - Parameters:
    ///   - sourceURLs: The source file URLs to categorize.
    ///   - isNative: Whether the module uses native mode.
    /// - Returns: Tuple of (transpileFiles, swiftFiles) as sorted path strings.
    static func categorizeSourceFiles(sourceURLs: [URL], isNative: Bool) -> (transpile: [String], swift: [String]) {
        var transpileFiles: [String] = []
        var swiftFiles: [String] = []
        for sourceFile in sourceURLs.map(\.path).sorted() {
            if isNative {
                swiftFiles.append(sourceFile)
            } else {
                transpileFiles.append(sourceFile)
            }
        }
        return (transpile: transpileFiles, swift: swiftFiles)
    }

    /// Merges default Gradle properties with custom overrides from skip.yml.
    ///
    /// Parses the default properties string into key-value pairs, overlays custom
    /// properties, and produces a sorted output string. Comments and blank lines
    /// from the defaults are discarded.
    ///
    /// - Parameters:
    ///   - defaults: The default Gradle properties as a multi-line string.
    ///   - custom: Optional custom properties that override or extend defaults.
    /// - Returns: The merged properties as a newline-terminated string.
    static func mergeGradleProperties(defaults: String, custom: [String: String]?) -> String {
        var properties: [String: String] = [:]

        for line in defaults.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                properties[key] = value
            }
        }

        if let custom {
            for (key, value) in custom {
                properties[key] = value
            }
        }

        var result = ""
        for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
            result += "\(key)=\(value)\n"
        }
        result += "\n"
        return result
    }

    /// Builds structured resource entries from skip.yml configuration.
    ///
    /// If the skip.yml declares resource paths with modes, each path is enumerated
    /// and paired with its declared mode. Otherwise, falls back to the default
    /// `Resources/` folder contents with process mode.
    ///
    /// - Parameters:
    ///   - config: The base skip.yml config.
    ///   - resourceURLs: Default resource URLs from the Resources/ folder.
    ///   - projectBaseURL: The project folder URL for resolving relative resource paths.
    /// - Returns: Array of resource entries with their files and processing modes.
    static func buildResourceEntries(config: SkipConfig, resourceURLs: [URL], projectBaseURL: URL) throws -> [ResourceEntry] {
        if let resourceConfigs = config.skip?.resources {
            return try resourceConfigs.map { resourceConfig in
                let resourceDirURL = projectBaseURL.appendingPathComponent(resourceConfig.path, isDirectory: true)
                let urls: [URL] = try FileManager.default.enumeratedURLs(of: resourceDirURL)
                return ResourceEntry(path: resourceConfig.path, urls: urls, isCopyMode: resourceConfig.isCopyMode)
            }
        } else if !resourceURLs.isEmpty {
            return [ResourceEntry(path: "Resources", urls: resourceURLs, isCopyMode: false)]
        } else {
            return []
        }
    }

    /// Filters YAML content by removing blocks marked with `export: false`.
    ///
    /// When a module's skip.yml is loaded for use by a dependent module, blocks
    /// explicitly marked as non-exported are stripped. This allows modules to have
    /// configuration that only applies locally.
    ///
    /// - Parameter yaml: The YAML content to filter.
    /// - Returns: The filtered YAML, or nil if the entire block should be removed.
    static func filterExportYAML(_ yaml: YAML) -> YAML? {
        guard var obj = yaml.object else {
            if let array = yaml.array {
                return .array(array.compactMap(filterExportYAML(_:)))
            } else {
                return yaml
            }
        }
        for (key, value) in obj {
            if key == "export" {
                if value.boolean == false {
                    return nil
                }
            } else {
                obj[key] = filterExportYAML(value)
            }
        }
        return .object(obj)
    }
}

extension Universal.XMLNode {
    mutating func addPlist(key: String, stringValue: String) {
        append(Universal.XMLNode(elementName: "key", children: [.content(key)]))
        append(Universal.XMLNode(elementName: "string", children: [.content(stringValue)]))
    }
}

extension URL {
    /// The path from this URL, validatating that it is an absolute path
    var absolutePath: AbsolutePath {
        get throws {
            try AbsolutePath(validating: path)
        }
    }
}

extension FileManager {
    /// Remove the given file URL, attempting to trash it when on macOS, otherwise just deleting it
    public func trash(fileURL: URL, trash: Bool) throws {
        if trash {
            #if os(macOS)
            do {
                // make sure it is writeable, since trashItem will fail if it is not
                try? localFileSystem.chmod(.userWritable, path: fileURL.absolutePath)

                // trash it on macOS so the user can recover it from the trash
                try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)

                return
            } catch {
                // tolerate failures and fall back to removing the item
            }
            #endif
        }

        // trash not supported or requested
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Returns the deep contents of a given directory URL.
    public func enumeratedURLs(of folderURL: URL) throws -> [URL] {
        var childFileURLs: [URL] = []

        if let fileURLs = self.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let fileURL as URL in fileURLs {
                let attrs = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if attrs.isRegularFile == true || attrs.isSymbolicLink == true {
                    childFileURLs.append(fileURL)
                }
            }
        }

        return childFileURLs
    }
}

/// Parse the simple .xcconfig file format
func parseXCConfig(contents: String) -> [(key: String, value: String)] {
    var keyValues: [(key: String, value: String)] = []
    let lines = contents.components(separatedBy: .newlines)
    for line in lines {
        if line.hasPrefix("#") || line.hasPrefix("//") || line.isEmpty {
            continue
        }

        let components = line.split(separator: "=", maxSplits: 2)
        // note that we do not currently handle conditional lines like "PRODUCT_BUNDLE_IDENTIFIER[config=Debug][sdk=iphoneos*] = myorg.app.App-Name"
        if components.count == 2 {
            let key = components[0].trimmingCharacters(in: .whitespaces)
            let value = components[1].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !value.isEmpty {
                keyValues.append((key, value))
            }
        }
    }
    return keyValues
}


/// The contents of a `Localizable.xcstrings` file, which is used for maually generating `Localizable.strings` files.
struct LocalizableStringsDictionary : Decodable {
    let version: String
    let sourceLanguage: String
    let strings: [String: StringsEntry]

    struct StringsEntry : Decodable {
        let extractionState: String? // e.g., "stale"
        let comment: String?
        let localizations: [String: TranslationSet]?
    }

    struct TranslationSet : Decodable {
        let stringUnit: StringUnit?

        /** e.g.:
         ```
         "variations" : {
           "plural" : {
             "one" : {
               "stringUnit" : {
                 "state" : "translated",
                 "value" : "%lld Goose"
               }
             },
             "other" : {
               "stringUnit" : {
                 "state" : "translated",
                 "value" : "%lld Geese"
               }
             }
           }
         }
         ```
         */
        let variations: Variations?

        struct Variations: Decodable {
            let plural: [String: VariationStringUnit]?

            struct VariationStringUnit : Decodable {
                let stringUnit: StringUnit
            }
        }
    }

    struct StringUnit: Decodable {
        let state: String? // e.g., "translated"
        let value: String?
    }
}
