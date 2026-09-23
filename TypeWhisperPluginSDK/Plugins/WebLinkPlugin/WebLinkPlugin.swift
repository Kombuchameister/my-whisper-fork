import Foundation
import os
import SwiftUI
import TypeWhisperPluginSDK

enum WebLinkTool: String, CaseIterable, Sendable {
    case ytDLP = "yt-dlp"
    case ffmpeg

    var formula: String { rawValue }
}

struct WebLinkToolchain: Sendable, Equatable {
    let ytDLPURL: URL?
    let ffmpegURL: URL?
    let homebrewURL: URL?

    var missingTools: [WebLinkTool] {
        var result: [WebLinkTool] = []
        if ytDLPURL == nil { result.append(.ytDLP) }
        if ffmpegURL == nil { result.append(.ffmpeg) }
        return result
    }

    var isReady: Bool { missingTools.isEmpty }
}

struct WebLinkToolLocator: Sendable {
    let environment: [String: String]
    let homeDirectory: URL

    func resolveToolchain() -> WebLinkToolchain {
        WebLinkToolchain(
            ytDLPURL: locate(WebLinkTool.ytDLP.rawValue),
            ffmpegURL: locate(WebLinkTool.ffmpeg.rawValue),
            homebrewURL: locate("brew")
        )
    }

    func locate(_ executableName: String) -> URL? {
        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent(executableName)
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            return candidate.resolvingSymlinksInPath()
        }
        return nil
    }

    private var searchDirectories: [URL] {
        var paths = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        paths.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/local/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
        ])

        var seen = Set<String>()
        return paths.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

enum WebLinkURLValidator {
    static func validatedURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 8_192,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        return components.url
    }
}

enum WebLinkDownloadRequest {
    /// yt-dlp writes the media's original title here; the downloaded file name
    /// is restricted to ASCII and cannot serve as a display title.
    static let titleFileName = "title.txt"

    static func make(
        ytDLPURL: URL,
        ffmpegURL: URL,
        sourceURL: URL,
        outputDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> WebLinkProcessRequest {
        WebLinkProcessRequest(
            executableURL: ytDLPURL,
            arguments: [
                "--no-config",
                "--no-playlist",
                "--restrict-filenames",
                "--extract-audio",
                "--audio-format", "m4a",
                "--audio-quality", "0",
                "--ffmpeg-location", ffmpegURL.deletingLastPathComponent().path,
                "--paths", outputDirectory.path,
                "--output", "%(title).180B-%(id)s.%(ext)s",
                "--print-to-file", "after_move:%(title)s",
                outputDirectory.appendingPathComponent(titleFileName).path,
                "--", sourceURL.absoluteString,
            ],
            environment: environment,
            workingDirectory: outputDirectory
        )
    }
}

struct WebLinkToolInstaller: Sendable {
    let runner: any WebLinkProcessRunning

    func install(
        missingTools: [WebLinkTool],
        homebrewURL: URL,
        workingDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        guard !missingTools.isEmpty else { return }
        let request = WebLinkProcessRequest(
            executableURL: homebrewURL,
            arguments: ["install"] + missingTools.map(\.formula),
            environment: environment,
            workingDirectory: workingDirectory
        )
        let result = try await runner.run(request)
        guard result.exitCode == 0 else {
            throw WebLinkPluginError.toolInstallationFailed(result.diagnosticOutput)
        }
    }
}

enum WebLinkPluginError: LocalizedError {
    case invalidURL
    case notActive
    case missingTools([WebLinkTool])
    case homebrewUnavailable
    case toolInstallationFailed(String)
    case downloadFailed(String)
    case noSupportedMedia
    case transcriptionQueueRejected
    case automaticTranscriptionUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            webLinkLocalized("The link must be a valid HTTP or HTTPS URL.")
        case .notActive:
            webLinkLocalized("The Web Link add-on is not active.")
        case .missingTools(let tools):
            String(
                format: webLinkLocalized("Missing helper tools: %@. Open the add-on settings to install them."),
                tools.map(\.rawValue).joined(separator: ", ")
            )
        case .homebrewUnavailable:
            webLinkLocalized("Homebrew was not found. Install the helper tools manually or install Homebrew first.")
        case .toolInstallationFailed(let diagnostic):
            diagnostic.isEmpty
                ? webLinkLocalized("Homebrew could not install the helper tools.")
                : diagnostic
        case .downloadFailed(let diagnostic):
            diagnostic.isEmpty
                ? webLinkLocalized("The media download failed.")
                : diagnostic
        case .noSupportedMedia:
            webLinkLocalized("The download did not produce a supported audio or video file.")
        case .transcriptionQueueRejected:
            webLinkLocalized("TypeWhisper could not add the downloaded media to the transcription queue.")
        case .automaticTranscriptionUnavailable:
            webLinkLocalized("This version of TypeWhisper cannot start transcriptions for add-ons.")
        }
    }
}

@objc(WebLinkPlugin)
final class WebLinkPlugin: NSObject,
    MediaImportPlugin,
    PluginUserInterfaceProviding,
    PluginSettingsWindowLayoutProviding,
    @unchecked Sendable
{
    static let pluginId = "com.typewhisper.web-link"
    static let pluginName = "Web Link Transcription"

    private struct State {
        var host: (any HostServices)?
    }

    private static let supportedExtensions = Set([
        "wav", "mp3", "m4a", "aac", "flac", "aiff", "aif", "mp4", "mov", "mkv", "webm"
    ])

    static let obsidianVaultPathKey = "obsidianVaultPath"
    static let obsidianSubfolderKey = "obsidianSubfolder"
    static let defaultObsidianSubfolder = "Web Links"
    static let obsidianEngineIdKey = "obsidianEngineId"
    static let obsidianModelIdKey = "obsidianModelId"

    private let state = OSAllocatedUnfairLock(initialState: State())
    @MainActor let obsidianJobs = WebLinkObsidianJobList()
    private let runner: any WebLinkProcessRunning
    private let environment: [String: String]
    private let homeDirectory: URL

    required override convenience init() {
        self.init(
            runner: WebLinkProcessRunner(),
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    init(
        runner: any WebLinkProcessRunning,
        environment: [String: String],
        homeDirectory: URL
    ) {
        self.runner = runner
        self.environment = environment
        self.homeDirectory = homeDirectory
        super.init()
    }

    func activate(host: HostServices) {
        state.withLock { $0.host = host }
        let importsDirectory = host.pluginDataDirectory.appendingPathComponent("Imports", isDirectory: true)
        Task.detached(priority: .utility) {
            Self.removeStaleImports(in: importsDirectory)
        }
    }

    func deactivate() {
        state.withLock { $0.host = nil }
    }

    @MainActor var mediaImportId: String { "web-link" }
    @MainActor var mediaImportDisplayName: String { webLinkLocalized("Web Link") }

    @MainActor var appMenuCommands: [PluginCommandDescriptor] {
        [transcribeWebLinkCommand, openSettingsCommand]
    }

    @MainActor var primaryMenuBarCommands: [PluginCommandDescriptor] {
        [transcribeWebLinkCommand, openSettingsCommand]
    }

    @MainActor var settingsSidebarItems: [PluginSettingsSidebarItemDescriptor] {
        [
            PluginSettingsSidebarItemDescriptor(
                id: "web-link-transcription",
                title: webLinkLocalized("Web Link Transcription"),
                systemImageName: "link"
            )
        ]
    }

    @MainActor
    func settingsSidebarView(for itemId: String) -> AnyView? {
        guard itemId == "web-link-transcription" else { return nil }
        return AnyView(WebLinkTranscriptionSidebarView(plugin: self))
    }

    @MainActor
    func performPluginCommand(_ commandId: String) {
        switch commandId {
        case "transcribe-web-link":
            state.withLock { $0.host }?.openSettingsSidebarItem("web-link-transcription")
        case "open-settings":
            state.withLock { $0.host }?.openPluginSettings()
        default:
            break
        }
    }

    @MainActor private var transcribeWebLinkCommand: PluginCommandDescriptor {
        PluginCommandDescriptor(
            id: "transcribe-web-link",
            title: webLinkLocalized("Transcribe Web Link…"),
            systemImageName: "link.badge.plus"
        )
    }

    @MainActor private var openSettingsCommand: PluginCommandDescriptor {
        PluginCommandDescriptor(
            id: "open-settings",
            title: webLinkLocalized("Web Link Transcription Settings…"),
            systemImageName: "link"
        )
    }

    @MainActor var mediaImportAvailability: PluginMediaImportAvailability {
        let missing = toolchain().missingTools
        guard missing.isEmpty else {
            return PluginMediaImportAvailability(
                isAvailable: false,
                unavailableReason: WebLinkPluginError.missingTools(missing).localizedDescription
            )
        }
        return .available
    }

    @MainActor
    func canImportMedia(from url: URL) -> Bool {
        WebLinkURLValidator.validatedURL(from: url.absoluteString) != nil
    }

    @MainActor
    func importMedia(
        from url: URL,
        onProgress: @Sendable @escaping (PluginMediaImportProgress) -> Bool
    ) async throws -> PluginImportedMedia {
        guard let validatedURL = WebLinkURLValidator.validatedURL(from: url.absoluteString) else {
            throw WebLinkPluginError.invalidURL
        }
        guard let host = state.withLock({ $0.host }) else {
            throw WebLinkPluginError.notActive
        }

        let tools = toolchain()
        guard let ytDLPURL = tools.ytDLPURL,
              let ffmpegURL = tools.ffmpegURL else {
            throw WebLinkPluginError.missingTools(tools.missingTools)
        }

        let token = UUID().uuidString
        let importsDirectory = host.pluginDataDirectory.appendingPathComponent("Imports", isDirectory: true)
        let jobDirectory = importsDirectory.appendingPathComponent(token, isDirectory: true)
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)

        do {
            guard onProgress(PluginMediaImportProgress(status: webLinkLocalized("Downloading media…"))) else {
                throw CancellationError()
            }
            let request = WebLinkDownloadRequest.make(
                ytDLPURL: ytDLPURL,
                ffmpegURL: ffmpegURL,
                sourceURL: validatedURL,
                outputDirectory: jobDirectory,
                environment: environment
            )
            let downloadingProgress = PluginMediaImportProgress(
                status: webLinkLocalized("Downloading media…")
            )
            let result = try await withThrowingTaskGroup(of: WebLinkProcessResult.self) { group in
                group.addTask { [runner] in
                    try await runner.run(request)
                }
                group.addTask {
                    while true {
                        try await Task.sleep(for: .milliseconds(100))
                        guard onProgress(downloadingProgress) else {
                            throw CancellationError()
                        }
                    }
                }

                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return result
            }
            try Task.checkCancellation()
            guard result.exitCode == 0 else {
                throw WebLinkPluginError.downloadFailed(Self.userFacingDiagnostic(result.diagnosticOutput))
            }

            let mediaURL = try Self.findImportedMedia(in: jobDirectory)
            let displayName = Self.downloadedTitle(in: jobDirectory)
                ?? mediaURL.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_", with: " ")
            _ = onProgress(PluginMediaImportProgress(fractionCompleted: 1, status: webLinkLocalized("Download complete")))
            return PluginImportedMedia(
                localFileURL: mediaURL,
                displayName: displayName,
                cleanupToken: token
            )
        } catch {
            try? FileManager.default.removeItem(at: jobDirectory)
            throw error
        }
    }

    @MainActor
    func removeImportedMedia(_ media: PluginImportedMedia) async {
        guard let host = state.withLock({ $0.host }),
              let token = media.cleanupToken,
              UUID(uuidString: token) != nil else { return }
        let importsDirectory = host.pluginDataDirectory
            .appendingPathComponent("Imports", isDirectory: true)
            .standardizedFileURL
        let jobDirectory = importsDirectory
            .appendingPathComponent(token, isDirectory: true)
            .standardizedFileURL
        guard jobDirectory.deletingLastPathComponent() == importsDirectory else { return }
        try? FileManager.default.removeItem(at: jobDirectory)
    }

    @MainActor
    var settingsView: AnyView? {
        AnyView(WebLinkSettingsView(plugin: self))
    }

    var preferredSettingsWindowSize: CGSize? { CGSize(width: 620, height: 460) }
    var minimumSettingsWindowSize: CGSize? { CGSize(width: 520, height: 400) }

    func toolchain() -> WebLinkToolchain {
        WebLinkToolLocator(environment: environment, homeDirectory: homeDirectory).resolveToolchain()
    }

    func installMissingToolsWithHomebrew() async throws {
        guard let host = state.withLock({ $0.host }) else {
            throw WebLinkPluginError.notActive
        }
        let tools = toolchain()
        guard let homebrewURL = tools.homebrewURL else {
            throw WebLinkPluginError.homebrewUnavailable
        }
        try await WebLinkToolInstaller(runner: runner).install(
            missingTools: tools.missingTools,
            homebrewURL: homebrewURL,
            workingDirectory: host.pluginDataDirectory,
            environment: environment
        )
        host.notifyCapabilitiesChanged()
    }

    @MainActor
    func enqueueImportedMediaForTranscription(_ media: PluginImportedMedia) async -> Bool {
        guard let host = state.withLock({ $0.host }) else { return false }
        return await host.enqueueImportedMediaForTranscription(
            media,
            fromMediaImporterId: mediaImportId
        )
    }

    func openSettingsWindow() {
        state.withLock { $0.host }?.openPluginSettings()
    }

    // MARK: - Obsidian notes

    func detectedObsidianVaults() -> [WebLinkObsidianVault] {
        WebLinkObsidianVaultLocator.detectVaults(homeDirectory: homeDirectory)
    }

    /// The chosen vault, or the most recently opened one Obsidian knows about.
    var obsidianVaultPath: String {
        get {
            if let stored = state.withLock({ $0.host })?.userDefault(forKey: Self.obsidianVaultPathKey) as? String,
               !stored.isEmpty {
                return stored
            }
            return detectedObsidianVaults().first?.path ?? ""
        }
        set {
            state.withLock { $0.host }?.setUserDefault(newValue, forKey: Self.obsidianVaultPathKey)
        }
    }

    var obsidianSubfolder: String {
        get {
            state.withLock { $0.host }?.userDefault(forKey: Self.obsidianSubfolderKey) as? String
                ?? Self.defaultObsidianSubfolder
        }
        set {
            state.withLock { $0.host }?.setUserDefault(newValue, forKey: Self.obsidianSubfolderKey)
        }
    }

    /// Engine for "Add to Obsidian"; nil follows the app's default engine.
    var obsidianEngineId: String? {
        get { nonEmptyDefault(forKey: Self.obsidianEngineIdKey) }
        set { state.withLock { $0.host }?.setUserDefault(newValue ?? "", forKey: Self.obsidianEngineIdKey) }
    }

    /// Model for "Add to Obsidian"; nil uses the engine's selected model.
    var obsidianModelId: String? {
        get { nonEmptyDefault(forKey: Self.obsidianModelIdKey) }
        set { state.withLock { $0.host }?.setUserDefault(newValue ?? "", forKey: Self.obsidianModelIdKey) }
    }

    var transcriptionEngines: [PluginTranscriptionEngineOption] {
        (state.withLock { $0.host } as? any HostMediaTranscriptionProviding)?.mediaTranscriptionEngines ?? []
    }

    var defaultTranscriptionEngineId: String? {
        (state.withLock { $0.host } as? any HostMediaTranscriptionProviding)?.defaultMediaTranscriptionEngineId
    }

    /// The chosen model, if it still belongs to the engine that will run;
    /// the default engine may have changed since the model was picked.
    private func validObsidianModelId(
        engineId: String?,
        transcriber: any HostMediaTranscriptionProviding
    ) -> String? {
        guard let modelId = obsidianModelId else { return nil }
        let resolvedEngineId = engineId ?? transcriber.defaultMediaTranscriptionEngineId
        let engine = transcriber.mediaTranscriptionEngines.first { $0.id == resolvedEngineId }
        return engine?.models.contains { $0.id == modelId } == true ? modelId : nil
    }

    private func nonEmptyDefault(forKey key: String) -> String? {
        guard let value = state.withLock({ $0.host })?.userDefault(forKey: key) as? String,
              !value.isEmpty else { return nil }
        return value
    }

    var canTranscribeAutomatically: Bool {
        state.withLock { $0.host } is any HostMediaTranscriptionProviding
    }

    /// Creates the note right away, then transcribes the media in the
    /// background and writes the transcript (or the error) into the note.
    @MainActor
    func createObsidianNote(for media: PluginImportedMedia, sourceURL: URL) throws -> URL {
        guard let transcriber = state.withLock({ $0.host }) as? any HostMediaTranscriptionProviding else {
            throw WebLinkPluginError.automaticTranscriptionUnavailable
        }
        let title = media.displayName ?? sourceURL.absoluteString
        let noteURL = try WebLinkObsidianNoteWriter(
            vaultPath: obsidianVaultPath,
            subfolder: obsidianSubfolder
        ).createNote(title: title, sourceURL: sourceURL)

        let jobID = obsidianJobs.add(noteURL: noteURL)
        let importerId = mediaImportId
        let engineId = obsidianEngineId
        let modelId = validObsidianModelId(engineId: engineId, transcriber: transcriber)
        Task { [obsidianJobs] in
            do {
                let transcript = try await transcriber.transcribeImportedMedia(
                    media,
                    fromMediaImporterId: importerId,
                    engineId: engineId,
                    modelId: modelId
                )
                try WebLinkObsidianNoteWriter.completeNote(at: noteURL, transcript: transcript)
                obsidianJobs.update(jobID, state: .done)
            } catch {
                try? WebLinkObsidianNoteWriter.failNote(at: noteURL, message: error.localizedDescription)
                obsidianJobs.update(jobID, state: .failed(error.localizedDescription))
            }
        }
        return noteURL
    }

    private static func findImportedMedia(in directory: URL) throws -> URL {
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard supportedExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { return false }
            return true
        }

        guard let mediaURL = candidates.max(by: { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let right = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return left < right
        }) else {
            throw WebLinkPluginError.noSupportedMedia
        }
        return mediaURL
    }

    private static func downloadedTitle(in directory: URL) -> String? {
        let titleURL = directory.appendingPathComponent(WebLinkDownloadRequest.titleFileName)
        guard let content = try? String(contentsOf: titleURL, encoding: .utf8) else { return nil }
        let title = content
            .split(whereSeparator: \.isNewline)
            .first?
            .trimmingCharacters(in: .whitespaces)
        guard let title, !title.isEmpty, title != "NA" else { return nil }
        return title
    }

    private static func userFacingDiagnostic(_ output: String) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .suffix(12)
            .joined(separator: "\n")
        return String(lines.prefix(4_000))
    }

    private static func removeStaleImports(in directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for entry in entries {
            guard UUID(uuidString: entry.lastPathComponent) != nil,
                  let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}

@MainActor
final class WebLinkObsidianJobList: ObservableObject {
    nonisolated init() {}

    enum State: Equatable {
        case transcribing
        case done
        case failed(String)
    }

    struct Job: Identifiable, Equatable {
        let id: UUID
        let noteURL: URL
        var state: State

        var title: String { noteURL.deletingPathExtension().lastPathComponent }
    }

    private static let maximumJobs = 10

    @Published private(set) var jobs: [Job] = []

    func add(noteURL: URL) -> UUID {
        let job = Job(id: UUID(), noteURL: noteURL, state: .transcribing)
        jobs.insert(job, at: 0)
        if jobs.count > Self.maximumJobs {
            jobs.removeLast(jobs.count - Self.maximumJobs)
        }
        return job.id
    }

    func update(_ id: UUID, state: State) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
    }
}

private final class WebLinkImportActivity: @unchecked Sendable {
    private let isActive = OSAllocatedUnfairLock(initialState: true)

    var shouldContinue: Bool {
        isActive.withLock { $0 }
    }

    func cancel() {
        isActive.withLock { $0 = false }
    }
}

@MainActor
final class WebLinkTranscriptionSidebarViewModel: ObservableObject {
    @Published var link = ""
    @Published var progress: PluginMediaImportProgress?
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published private(set) var isImporting = false

    let plugin: WebLinkPlugin
    private var importTask: Task<Void, Never>?
    private var activeImportID: UUID?
    private var importActivity: WebLinkImportActivity?

    init(plugin: WebLinkPlugin) {
        self.plugin = plugin
    }

    var canSubmit: Bool {
        !isImporting
            && WebLinkURLValidator.validatedURL(from: link) != nil
            && plugin.mediaImportAvailability.isAvailable
    }

    var canSubmitToObsidian: Bool {
        canSubmit && !plugin.obsidianVaultPath.isEmpty && plugin.canTranscribeAutomatically
    }

    func importLinkToObsidian() {
        importLink(toObsidian: true)
    }

    func importLink(toObsidian: Bool = false) {
        guard !isImporting else { return }
        guard let sourceURL = WebLinkURLValidator.validatedURL(from: link) else {
            errorMessage = webLinkLocalized("The link must be a valid HTTP or HTTPS URL.")
            return
        }
        guard plugin.mediaImportAvailability.isAvailable else {
            errorMessage = plugin.mediaImportAvailability.unavailableReason
                ?? webLinkLocalized("The Web Link add-on is not ready.")
            return
        }

        isImporting = true
        errorMessage = nil
        successMessage = nil
        progress = PluginMediaImportProgress(status: webLinkLocalized("Preparing web link download"))
        let importID = UUID()
        let activity = WebLinkImportActivity()
        activeImportID = importID
        importActivity = activity

        importTask = Task { [weak self] in
            guard let self else { return }
            do {
                let importedMedia = try await plugin.importMedia(
                    from: sourceURL,
                    onProgress: { [weak self] progress in
                        guard activity.shouldContinue else { return false }
                        Task { @MainActor [weak self] in
                            guard self?.activeImportID == importID else { return }
                            self?.progress = progress
                        }
                        return activity.shouldContinue
                    }
                )
                guard !Task.isCancelled, activeImportID == importID else {
                    await plugin.removeImportedMedia(importedMedia)
                    return
                }
                if toObsidian {
                    let noteURL: URL
                    do {
                        noteURL = try plugin.createObsidianNote(for: importedMedia, sourceURL: sourceURL)
                    } catch {
                        await plugin.removeImportedMedia(importedMedia)
                        throw error
                    }
                    link = ""
                    successMessage = String(
                        format: webLinkLocalized("Created the note “%@”. The transcript is added when transcription finishes."),
                        noteURL.deletingPathExtension().lastPathComponent
                    )
                } else {
                    guard await plugin.enqueueImportedMediaForTranscription(importedMedia) else {
                        await plugin.removeImportedMedia(importedMedia)
                        throw WebLinkPluginError.transcriptionQueueRejected
                    }

                    guard activeImportID == importID else { return }
                    link = ""
                    successMessage = webLinkLocalized("The downloaded media was added to the transcription queue.")
                }
            } catch is CancellationError {
                // Cancellation is an explicit user action and needs no error banner.
            } catch {
                guard activeImportID == importID else { return }
                errorMessage = error.localizedDescription
            }

            guard activeImportID == importID else { return }
            activity.cancel()
            progress = nil
            isImporting = false
            importTask = nil
            activeImportID = nil
            importActivity = nil
        }
    }

    func cancelImport() {
        importActivity?.cancel()
        importActivity = nil
        activeImportID = nil
        importTask?.cancel()
        importTask = nil
        progress = nil
        isImporting = false
    }
}

@MainActor
private struct WebLinkTranscriptionSidebarView: View {
    @StateObject private var viewModel: WebLinkTranscriptionSidebarViewModel
    @FocusState private var isLinkFieldFocused: Bool

    init(plugin: WebLinkPlugin) {
        _viewModel = StateObject(
            wrappedValue: WebLinkTranscriptionSidebarViewModel(plugin: plugin)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(webLinkLocalized("Web Link Transcription"))
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(webLinkLocalized("Transcribe audio from a web link"))
                            .font(.headline)

                        Text(webLinkLocalized("Paste a supported video or audio link. The add-on downloads its audio and adds it to TypeWhisper's transcription queue."))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            TextField(
                                webLinkLocalized("Paste a video or audio link"),
                                text: $viewModel.link
                            )
                            .textFieldStyle(.roundedBorder)
                            .focused($isLinkFieldFocused)
                            .onSubmit {
                                if viewModel.canSubmit {
                                    viewModel.importLink()
                                }
                            }
                            .disabled(viewModel.isImporting)
                            .accessibilityIdentifier("webLinkTranscription.link")

                            if viewModel.isImporting {
                                Button(webLinkLocalized("Cancel"), role: .cancel) {
                                    viewModel.cancelImport()
                                }
                            } else {
                                Button(webLinkLocalized("Add Link")) {
                                    viewModel.importLink()
                                }
                                .disabled(!viewModel.canSubmit)
                                .accessibilityIdentifier("webLinkTranscription.addLink")

                                Button {
                                    viewModel.importLinkToObsidian()
                                } label: {
                                    Label(webLinkLocalized("Add to Obsidian"), systemImage: "doc.badge.plus")
                                }
                                .disabled(!viewModel.canSubmitToObsidian)
                                .help(webLinkLocalized("Create an Obsidian note named after the video and fill in the transcript automatically."))
                                .accessibilityIdentifier("webLinkTranscription.addToObsidian")
                            }
                        }

                        if let progress = viewModel.progress {
                            HStack(spacing: 10) {
                                ProgressView(value: progress.fractionCompleted)
                                    .frame(maxWidth: 180)
                                if let status = progress.status {
                                    Text(status)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if let errorMessage = viewModel.errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }

                        if let successMessage = viewModel.successMessage {
                            Label(successMessage, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )

                    WebLinkObsidianSection(plugin: viewModel.plugin, jobs: viewModel.plugin.obsidianJobs)

                    if !viewModel.plugin.mediaImportAvailability.isAvailable {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(
                                viewModel.plugin.mediaImportAvailability.unavailableReason
                                    ?? webLinkLocalized("The Web Link add-on is not ready.")
                            )
                            .foregroundStyle(.secondary)

                            Button(webLinkLocalized("Open add-on settings…")) {
                                viewModel.plugin.openSettingsWindow()
                            }
                        }
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                    }
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                isLinkFieldFocused = true
            }
        }
    }
}

@MainActor
private struct WebLinkObsidianSection: View {
    let plugin: WebLinkPlugin
    @ObservedObject var jobs: WebLinkObsidianJobList

    @State private var vaultPath = ""
    @State private var subfolder = ""
    @State private var detectedVaults: [WebLinkObsidianVault] = []
    @State private var engineId: String?
    @State private var modelId: String?
    @State private var engines: [PluginTranscriptionEngineOption] = []
    @State private var defaultEngineId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(webLinkLocalized("Obsidian notes"))
                .font(.headline)

            Text(webLinkLocalized("“Add to Obsidian” creates a note named after the video in this folder, with the link as its first line, and adds the transcript when transcription finishes. It uses the engine selected under File Transcription."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(webLinkLocalized("Vault"))
                    HStack(spacing: 8) {
                        Picker(webLinkLocalized("Vault"), selection: $vaultPath) {
                            if vaultPath.isEmpty {
                                Text(webLinkLocalized("None")).tag("")
                            }
                            ForEach(vaultChoices) { vault in
                                Text(vault.name)
                                    .help(vault.path)
                                    .tag(vault.path)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
                        .onChange(of: vaultPath) { _, newValue in
                            plugin.obsidianVaultPath = newValue
                        }
                        .accessibilityIdentifier("webLinkTranscription.obsidianVault")

                        Button(webLinkLocalized("Choose…")) {
                            chooseVaultFolder()
                        }
                    }
                }
                GridRow {
                    Text(webLinkLocalized("Subfolder"))
                    TextField(webLinkLocalized("Vault root"), text: $subfolder)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                        .onChange(of: subfolder) { _, newValue in
                            plugin.obsidianSubfolder = newValue
                        }
                        .accessibilityIdentifier("webLinkTranscription.obsidianSubfolder")
                }
                GridRow {
                    Text(webLinkLocalized("Engine"))
                    Picker(webLinkLocalized("Engine"), selection: $engineId) {
                        Text(defaultEngineLabel).tag(nil as String?)
                        Divider()
                        ForEach(engines) { engine in
                            Text(engine.isReady
                                 ? engine.displayName
                                 : "\(engine.displayName) (\(webLinkLocalized("not ready")))")
                                .tag(engine.id as String?)
                                .disabled(!engine.isReady)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                    .onChange(of: engineId) { _, newValue in
                        plugin.obsidianEngineId = newValue
                        if let modelId, chosenEngine?.models.contains(where: { $0.id == modelId }) != true {
                            self.modelId = nil
                        }
                    }
                    .accessibilityIdentifier("webLinkTranscription.obsidianEngine")
                }
                if let engine = chosenEngine, engine.models.count > 1 {
                    GridRow {
                        Text(webLinkLocalized("Model"))
                        Picker(webLinkLocalized("Model"), selection: $modelId) {
                            Text(defaultModelLabel(for: engine)).tag(nil as String?)
                            Divider()
                            ForEach(engine.models) { model in
                                Text(model.displayName).tag(model.id as String?)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
                        .onChange(of: modelId) { _, newValue in
                            plugin.obsidianModelId = newValue
                        }
                        .accessibilityIdentifier("webLinkTranscription.obsidianModel")
                    }
                }
            }

            if !jobs.jobs.isEmpty {
                Divider()
                ForEach(jobs.jobs) { job in
                    jobRow(job)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .onAppear {
            detectedVaults = plugin.detectedObsidianVaults()
            vaultPath = plugin.obsidianVaultPath
            subfolder = plugin.obsidianSubfolder
            engines = plugin.transcriptionEngines
            defaultEngineId = plugin.defaultTranscriptionEngineId
            engineId = plugin.obsidianEngineId
            modelId = plugin.obsidianModelId
        }
    }

    /// The engine a transcription uses: the chosen one, or the app default.
    private var chosenEngine: PluginTranscriptionEngineOption? {
        let id = engineId ?? defaultEngineId
        return engines.first { $0.id == id }
    }

    /// "Default Engine (Groq)": names the engine the default resolves to.
    private var defaultEngineLabel: String {
        let label = webLinkLocalized("Default Engine")
        guard let name = engines.first(where: { $0.id == defaultEngineId })?.displayName else { return label }
        return "\(label) (\(name))"
    }

    private func defaultModelLabel(for engine: PluginTranscriptionEngineOption) -> String {
        let label = webLinkLocalized("Default model")
        guard let modelId = engine.defaultModelId else { return label }
        let name = engine.models.first { $0.id == modelId }?.displayName ?? modelId
        return "\(label) (\(name))"
    }

    private var vaultChoices: [WebLinkObsidianVault] {
        guard !vaultPath.isEmpty, !detectedVaults.contains(where: { $0.path == vaultPath }) else {
            return detectedVaults
        }
        return [WebLinkObsidianVault(path: vaultPath)] + detectedVaults
    }

    @ViewBuilder
    private func jobRow(_ job: WebLinkObsidianJobList.Job) -> some View {
        HStack(spacing: 8) {
            switch job.state {
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch job.state {
                case .transcribing:
                    Text(webLinkLocalized("Transcribing…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .done:
                    Text(webLinkLocalized("Transcript added"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Spacer()

            Button(webLinkLocalized("Open")) {
                openInObsidian(job.noteURL)
            }
            .controlSize(.small)
        }
    }

    private func openInObsidian(_ noteURL: URL) {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: noteURL.path)]
        if let url = components.url, NSWorkspace.shared.open(url) {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([noteURL])
    }

    private func chooseVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = webLinkLocalized("Choose Vault")
        if !vaultPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: vaultPath, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vaultPath = url.path
    }
}

@MainActor
private struct WebLinkSettingsView: View {
    let plugin: WebLinkPlugin

    @State private var toolchain = WebLinkToolchain(ytDLPURL: nil, ffmpegURL: nil, homebrewURL: nil)
    @State private var isInstalling = false
    @State private var installError: String?
    @State private var showInstallConfirmation = false

    var body: some View {
        Form {
            Section(webLinkLocalized("Web Link Transcription")) {
                Text(webLinkLocalized("Download audio from a supported web link and pass it to TypeWhisper's regular file-transcription queue."))
                    .foregroundStyle(.secondary)
            }

            Section(webLinkLocalized("Helper tools")) {
                toolRow(name: "yt-dlp", url: toolchain.ytDLPURL)
                toolRow(name: "ffmpeg", url: toolchain.ffmpegURL)

                if toolchain.missingTools.isEmpty {
                    Label(webLinkLocalized("Ready"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if let homebrewURL = toolchain.homebrewURL {
                    Button {
                        showInstallConfirmation = true
                    } label: {
                        if isInstalling {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(webLinkLocalized("Install missing tools with Homebrew"), systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(isInstalling)

                    Text(String(format: webLinkLocalized("Homebrew found at %@."), homebrewURL.path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(webLinkLocalized("Homebrew was not found. Install yt-dlp and ffmpeg manually, then check again."))
                        .foregroundStyle(.secondary)
                    Link(webLinkLocalized("Open Homebrew setup"), destination: URL(string: "https://brew.sh/")!)
                }

                if let installError {
                    Text(installError)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                Button(webLinkLocalized("Check again")) {
                    refresh()
                }
                .disabled(isInstalling)
            }

            Section {
                Text(webLinkLocalized("No helper tool is downloaded without confirmation. Homebrew verifies and manages the installed packages."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { refresh() }
        .confirmationDialog(
            webLinkLocalized("Install helper tools?"),
            isPresented: $showInstallConfirmation
        ) {
            Button(webLinkLocalized("Install with Homebrew")) {
                install()
            }
            Button(webLinkLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(
                String(
                    format: webLinkLocalized("Homebrew will download and install: %@"),
                    toolchain.missingTools.map(\.rawValue).joined(separator: ", ")
                )
            )
        }
    }

    @ViewBuilder
    private func toolRow(name: String, url: URL?) -> some View {
        HStack {
            Text(name)
            Spacer()
            if let url {
                Text(url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text(webLinkLocalized("Not installed"))
                    .foregroundStyle(.secondary)
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func refresh() {
        toolchain = plugin.toolchain()
        installError = nil
    }

    private func install() {
        isInstalling = true
        installError = nil
        Task {
            do {
                try await plugin.installMissingToolsWithHomebrew()
                refresh()
            } catch {
                installError = error.localizedDescription
            }
            isInstalling = false
        }
    }
}

func webLinkLocalized(_ key: String.LocalizationValue) -> String {
    #if SWIFT_PACKAGE
    String(localized: key, bundle: .module)
    #else
    String(localized: key, bundle: Bundle(for: WebLinkPlugin.self))
    #endif
}
