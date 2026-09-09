import SwiftUI
import AppKit

//struct to open second view
@available(macOS 13.0, *)
private struct HelpButtonMacOS13: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Need Help?") {
            openWindow(id: "help")
        }
    }
    
}

struct ContentView: View {
    @State private var sourcePath = ""
    @State private var destinationPath = ""
    @State private var dryRun = true
    @State private var copySupported = false
    @State private var purgeJSON = false
    @State private var injectJSON = false
    
    @State private var isRunning = false
    @State private var outputLog = ""
    @State private var runError = ""
    @State private var sourceStatusMessage = ""
    @State private var showDependencyAlert = false
    @State private var dependencyAlertMessage = ""
    
    @State private var allowOptions = true
    @State private var activeRunner: PythonRunner?
    
    private var canRun: Bool {
        !isRunning && !sourcePath.isEmpty && sourceStatusMessage.isEmpty
    }
    private var runButtonTitle: String { isRunning ? "Running..." : "Convert" }
    
    var body: some View {
        if #available(macOS 12.0, *) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Google Takeout Converter")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(20)
                
                pathSection
                optionsSection
                actionSection
                statusSection
                logSection
                cancelSection
            }
            .padding(18)
            .frame(minWidth: 760, minHeight: 560)
            .task {
                await checkDependenciesOnStartup()
            }
            .alert("Missing Dependency", isPresented: $showDependencyAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(dependencyAlertMessage)
            }
        } else {
            // Fallback on earlier versions
        }
    }
    
    //legacy window function
    final class PopupWindowController: NSWindowController {
        convenience init() {
            let host = NSHostingController(rootView: Inst2())
            let window = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
                styleMask: [.titled, .closable, .utilityWindow], // utility look
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.center()
            window.title = "Help"

            self.init(window: window)
            self.contentViewController = host
        }

        static var shared: PopupWindowController?

        static func presentLegacyPopup() {
            if let existing = shared, existing.window?.isVisible == true {
                existing.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            let controller = PopupWindowController()
            shared = controller
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    // Path pickers drive all script arguments. Source is required, destination is optional.
    private var pathSection: some View {
        Group {
            pathRow(label: "Source (Google Photos folder)", path: sourcePath, action: chooseSource)
            pathRow(label: "Destination (optional)", path: destinationPath, action: chooseDestination)
            if !sourceStatusMessage.isEmpty {
                if #available(macOS 12.0, *) {
                    Text(sourceStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    // Fallback on earlier versions
                }
            }
        }
    }
    
    // These switches map directly to script CLI flags.
    // options
    private var optionsSection: some View {
        Group {
            Toggle("Dry run: (shows supported files, does not run program)", isOn: $dryRun)
            Toggle("Copy supported files (when destination is set)", isOn: $copySupported)
                .disabled(!allowOptions)
            Toggle("Purge JSON sidecars", isOn: $purgeJSON)
                .disabled(!allowOptions)
            Toggle("Inject JSON metadata", isOn: $injectJSON)
                .disabled(!allowOptions)
        }
    }
    
    // Run executes Python; clear only resets on-screen output.
    private var actionSection: some View {
        HStack(spacing: 10) {
            Button(runButtonTitle) {
                Task { await runCleaner() }
            }
            .disabled(!canRun)
            
            Button("Clear Log") {
                outputLog = ""
                runError = ""
            }
            .disabled(isRunning)
            
            //help button
            if #available(macOS 13.0, *) {
                HelpButtonMacOS13()
            } else {
                Button("Need Help?") {
                    PopupWindowController.presentLegacyPopup()
                }
            }
            }
        }
    
    // Errors are shown inline so users do not need to inspect Xcode logs.
    @ViewBuilder
    private var statusSection: some View {
        if !runError.isEmpty {
            if #available(macOS 14.0, *) {
                Text(runError)
                    .foregroundStyle(.red)
            } else {
                // Fallback on earlier versions
            }
        }
    }
    
    // Stdout/stderr stream here in real time while Python runs.
    @ViewBuilder
    private var logSection: some View {
        if #available(macOS 12.0, *) {
            TextEditor(text: $outputLog)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 260)
                .border(.quaternary)
        } else {
            // Fallback on earlier versions
            // Read-only fallback for older macOS (no TextEditor):
                    ScrollView {
                        Text(outputLog.isEmpty ? " " : outputLog) // avoid zero-height
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(4)
                    }
                    .frame(minHeight: 260)
                    //.border(.quaternary)

        }
    }
    //cancel button
    private var cancelSection: some View {
        HStack {
            Button("Cancel Conversion") {
                activeRunner?.cancel()
                outputLog += "\nCancellation requested...\n"
            }
            .disabled(!isRunning)
            Spacer()
        }
    }
    
    private func pathRow(label: String, path: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.headline)
            HStack {
                if #available(macOS 12.0, *) {
                    Text(path.isEmpty ? "Not selected" : path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(path.isEmpty ? .secondary : .primary)
                } else {
                    // Fallback on earlier versions
                }
                Spacer()
                Button("Choose") {
                    action()
                }
            }
        }
    }
    
    private func chooseSource() {
        //file picker function
        guard let pickedPath = pickDirectory() else { return }
        guard validateSourceFolder(pickedPath) else {
            sourcePath = ""
            return
        }
        sourcePath = pickedPath
        sourceStatusMessage = ""
        runError = ""
    }
    
    private func chooseDestination() {
        destinationPath = pickDirectory() ?? destinationPath
    }
    
    // A valid source must include at least one media file and one JSON sidecar.
    private func validateSourceFolder(_ folderPath: String) -> Bool {
        let root = URL(fileURLWithPath: folderPath)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            sourceStatusMessage = "Cannot read the selected folder."
            return false
        }
        
        let mediaExtensions: Set<String> = [
            ".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".tif", ".tiff", ".bmp", ".webp",
            ".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm", ".3gp"
        ]
        
        var foundMedia = false
        var foundJSON = false
        
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if ext == "json" {
                foundJSON = true
            } else if mediaExtensions.contains(".\(ext)") {
                foundMedia = true
            }
            
            if foundMedia && foundJSON {
                return true
            }
        }
        
        sourceStatusMessage = "Source must contain media files and Takeout JSON metadata."
        return false
    }
    
    @MainActor //runs code on main thread
    private func runCleaner() async {
        isRunning = true
        runError = ""
        outputLog = ""
        let runner = PythonRunner()
        activeRunner = runner
        
        defer {
            isRunning = false
            activeRunner = nil
        }
        
        do {
            let scriptURL = try locateScript()
            let exitCode = try await runner.run(
                scriptURL: scriptURL,
                arguments: buildArguments()
            ) { text in
                Task { @MainActor in
                    outputLog += text
                }
            }
            
            if exitCode == 130 {
                runError = "Conversion cancelled."
            } else if exitCode != 0 {
                runError = "Cleaner exited with code \(exitCode)."
            }
        } catch {
            runError = "Failed to run cleaner: \(error.localizedDescription)"
        }
    }
    
    private func buildArguments() -> [String] {
        var args = [sourcePath]
        
        if !destinationPath.isEmpty {
            args += ["--dest", destinationPath]
        }
        if dryRun {
            args.append("--dry-run")
        }
        if copySupported {
            args.append("--copy-supported")
        }
        if purgeJSON {
            args.append("--purge-json")
        }
        if injectJSON {
            args.append("--inject-json")
        }
        
        return args
    }
    
    private func locateScript() throws -> URL {
        if let bundled = Bundle.main.url(forResource: "takeout_icloud_media_cleaner", withExtension: "py") {
            return bundled
        }
        
        let devURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("takeout_icloud_media_cleaner.py")
        
        if FileManager.default.fileExists(atPath: devURL.path) {
            return devURL
        }
        
        throw NSError(
            domain: "TakeoutConverter",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Python script not found in app bundle or source folder."]
        )
    }
    
    private func pickDirectory() -> String? {
        //file picker function universal
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    
    @MainActor // checks dependencies on startup and sends one alert if unavailable
    private func checkDependenciesOnStartup() async {
        let runner = PythonRunner()
        var count = 0

        if let missingMessage = await runner.checkPythonModule("PIL", minVersion: "8.0.0") {
            dependencyAlertMessage = missingMessage
            showDependencyAlert = true
            count+=1
            return
        }

        if let missingMessage = await runner.checkFFmpeg(minVersion: "1.0") {
            dependencyAlertMessage = missingMessage + " Install using Homebrew in Terminal: 'brew install ffmpeg'"
            showDependencyAlert = true
            count+=1
        }
        if count != 0 {
            allowOptions = false
        }
    }
    
    private final class PythonRunner {
        private let stateQueue = DispatchQueue(label: "TakeoutConverter.PythonRunner")
        private var activeProcess: Process?
        private var cancelRequested = false

        private func resolvePythonExecutable() throws -> URL {
            if let resourceRoot = Bundle.main.resourceURL {
                let bundled = resourceRoot
                    .appendingPathComponent("python-runtime")
                    .appendingPathComponent("bin/python3")
                if FileManager.default.isExecutableFile(atPath: bundled.path) {
                    return bundled
                }
            }
            
            let home = NSHomeDirectory()
            let fallbackPythonPaths = [
                "/opt/homebrew/bin/python3",
                "/usr/local/bin/python3",
                "\(home)/opt/miniconda3/bin/python3",
                "\(home)/miniconda3/bin/python3",
            ]
            
            for path in fallbackPythonPaths where FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            
            throw NSError(
                domain: "TakeoutConverter",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No usable Python interpreter was found."]
            )
        }
        
        func run(
            scriptURL: URL,
            arguments: [String],
            onOutput: @escaping @Sendable (String) -> Void
        ) async throws -> Int32 {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                
                do {
                    process.executableURL = try resolvePythonExecutable()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                process.arguments = [scriptURL.path] + arguments
                process.standardOutput = stdout
                process.standardError = stderr
                stateQueue.sync {
                    cancelRequested = false
                    activeProcess = process
                }
                
                let reader: @Sendable (FileHandle) -> Void = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                        return
                    }
                    onOutput(text)
                }
                
                stdout.fileHandleForReading.readabilityHandler = reader
                stderr.fileHandleForReading.readabilityHandler = reader
                
                process.terminationHandler = { proc in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    let wasCancelled = self.stateQueue.sync { () -> Bool in
                        let cancelled = self.cancelRequested
                        self.activeProcess = nil
                        return cancelled
                    }
                    continuation.resume(returning: wasCancelled ? 130 : proc.terminationStatus)
                }
                
                do {
                    try process.run()
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    stateQueue.sync {
                        activeProcess = nil
                    }
                    continuation.resume(throwing: error)
                }
            }
        }

        func cancel() {
            stateQueue.sync {
                cancelRequested = true
                activeProcess?.terminate()
            }
        }
        
        //fmpeg
        func checkFFmpeg(minVersion: String? = nil) async -> String? {
            await withCheckedContinuation { continuation in
                guard let ffmpegExecutable = resolveFFmpegExecutable() else {
                    continuation.resume(returning: "ffmpeg is not installed or not discoverable.")
                    return
                }
                let process = Process()
                process.executableURL = ffmpegExecutable
                process.arguments  = ["-version"]
                
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError  = pipe
                
                
                process.terminationHandler = { proc in
                    guard proc.terminationStatus == 0 else {
                        continuation.resume(returning: "ffmpeg check failed when executing \(ffmpegExecutable.path).")
                        return
                    }
                    // Read combined output
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    
                    
                    if let required = minVersion,
                       let actual = Self.parseFFmpegVersion(from: text),
                       Self.compareVersions(actual, required) < 0 {
                        continuation.resume(returning: "ffmpeg \(required)+ required; found \(actual).")
                        return
                    }
                    continuation.resume(returning: nil)
                }
                
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: "Failed to execute ffmpeg: \(error.localizedDescription)")
                }
            }
        }
        //MARK: - Helpers

        private func resolveFFmpegExecutable() -> URL? {
            let fileManager = FileManager.default
            let env = ProcessInfo.processInfo.environment

            if let override = env["TAKEOUT_FFMPEG"] {
                let expanded = NSString(string: override).expandingTildeInPath
                if fileManager.isExecutableFile(atPath: expanded) {
                    return URL(fileURLWithPath: expanded)
                }
            }

            if let pathValue = env["PATH"] {
                for dir in pathValue.split(separator: ":") {
                    let candidate = String(dir) + "/ffmpeg"
                    if fileManager.isExecutableFile(atPath: candidate) {
                        return URL(fileURLWithPath: candidate)
                    }
                }
            }

            let fallbackPaths = [
                "/opt/homebrew/bin/ffmpeg",
                "/usr/local/bin/ffmpeg",
            ]
            for path in fallbackPaths where fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            return nil
        }
        
        private static func parseFFmpegVersion(from output: String) -> String? {
            // Looks for "ffmpeg version 6.1.1" at the start of the output.
            guard let line = output.split(separator: "\n").first else { return nil }
            let tokens = line.split(separator: " ")
            if tokens.count >= 3, tokens[0] == "ffmpeg", tokens[1] == "version" {
                return String(tokens[2])
            }
            return nil
        }
        /// Simple dotted-number comparator (-1 if a<b, 0 if ==, 1 if a>b)
        private static func compareVersions(_ a: String, _ b: String) -> Int {
            func parts(_ v: String) -> [Int] {
                v.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
            }
            let pa = parts(a), pb = parts(b)
            for i in 0..<max(pa.count, pb.count) {
                let ai = i < pa.count ? pa[i] : 0
                let bi = i < pb.count ? pb[i] : 0
                if ai != bi { return ai < bi ? -1 : 1 }
            }
            return 0
        }
    
    
    
    
    //general check
    func checkPythonModule(_ module: String, minVersion: String? = nil) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            do {
                process.executableURL = try resolvePythonExecutable()
            } catch {
                continuation.resume(returning: "No usable Python interpreter was found. Rebuild/archive so the embedded runtime is included, or install a system Python.")
                return
            }
            
            let pySnippet: String
            if let min = minVersion {
                // Do a version-aware import check
                pySnippet = """
                                import importlib, sys
                                try:
                                    m = importlib.import_module(\(String(reflecting: module)))
                                except Exception as e:
                                    sys.exit(2)  # missing module
                                ver = getattr(m, "__version__", None)
                                if ver is None:
                                    sys.exit(3)  # no version attribute; treat as failure for min-version checks
                                def _parse(v):
                                    return [int(''.join(c for c in part if c.isdigit()) or '0') for part in v.split('.')[:4]]
                                if _parse(ver) < _parse(\(String(reflecting: min))):
                                    sys.exit(4)  # version too low
                                sys.exit(0)
                                """
            } else {
                // Import-only check
                pySnippet = """
                                import importlib, sys
                                try:
                                    importlib.import_module(\(String(reflecting: module)))
                                    sys.exit(0)
                                except Exception:
                                    sys.exit(2)

"""
            }
            
            process.arguments = ["-c", pySnippet]
            
            process.terminationHandler = { proc in
                switch proc.terminationStatus {
                case 0:  continuation.resume(returning: nil)
                case 2:  continuation.resume(returning: "Python module '\(module)' is not installed.")
                case 3:  continuation.resume(returning: "Python module '\(module)' has no __version__ attribute; cannot verify minimum version.")
                case 4:  continuation.resume(returning: "Python module '\(module)' does not meet the minimum version \(minVersion!).")
                default: continuation.resume(returning: "Dependency check for '\(module)' failed with exit code \(proc.terminationStatus).")
                }
            }
            
            do {
                try process.run()
            } catch {
                continuation.resume(returning: "Python dependency check failed for '\(module)': \(error.localizedDescription)")
            }
        }
    }
}
        
        
//        func pillowDependencyMessage() async -> String? {
//            await withCheckedContinuation { continuation in
//                let process = Process()
//                do {
//                    process.executableURL = try resolvePythonExecutable()
//                } catch {
//                    continuation.resume(returning: "Bundled Python runtime not found. Rebuild/archive so the Embed Python Runtime build phase can package it.")
//                    return
//                }
//                process.arguments = ["-c", "import PIL"]
//                
//                process.terminationHandler = { proc in
//                    if proc.terminationStatus == 0 {
//                        continuation.resume(returning: nil)
//                    } else {
//                        continuation.resume(returning: "Pillow is missing from the bundled Python runtime. Rebuild/archive after installing Pillow in the source Python used by the embed script.")
//                    }
//                }
//                
//                do {
//                    try process.run()
//                } catch {
//                    continuation.resume(returning: "Python dependency check failed: \(error.localizedDescription)")
//                }
//            }
//        }
}

#Preview {
    if #available(macOS 13.0, *) {
        ContentView()
    } else {
        // Fallback on earlier versions
        Text("Preview not available on this version of macOS")
            .padding()
    }
}
