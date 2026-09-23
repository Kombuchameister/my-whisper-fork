import Foundation
import XCTest
@testable import WebLinkPlugin
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting

final class WebLinkObsidianNoteTests: XCTestCase {
    func testNoteFileNameKeepsTitleReadableButSafeForObsidianLinks() {
        XCTAssertEqual(
            WebLinkObsidianNoteWriter.noteFileName(for: "Rust in 100 Seconds: Why #1? | Fireship [4K]"),
            "Rust in 100 Seconds - Why 1 - Fireship 4K"
        )
        XCTAssertEqual(WebLinkObsidianNoteWriter.noteFileName(for: "../../etc/passwd"), "-..-etc-passwd")
        XCTAssertEqual(WebLinkObsidianNoteWriter.noteFileName(for: "Über  Größe\nzweite Zeile"), "Über Größe zweite Zeile")
        XCTAssertEqual(WebLinkObsidianNoteWriter.noteFileName(for: " ... "), "Web Link")
        XCTAssertLessThanOrEqual(
            WebLinkObsidianNoteWriter.noteFileName(for: String(repeating: "ä", count: 300)).utf8.count,
            200
        )
    }

    func testSubfolderCannotLeaveTheVault() {
        XCTAssertEqual(
            WebLinkObsidianNoteWriter.sanitizedSubfolderComponents("../Inbox/./ YouTube /../"),
            ["Inbox", "YouTube"]
        )
        XCTAssertEqual(WebLinkObsidianNoteWriter.sanitizedSubfolderComponents(""), [])
    }

    func testCreateNoteWritesLinkAndPlaceholderWithoutOverwritingExistingNotes() throws {
        let vault = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vault) }
        let writer = WebLinkObsidianNoteWriter(vaultPath: vault.path, subfolder: "Inbox/YouTube")
        let source = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=T15BuMPZW4Q"))

        let first = try writer.createNote(title: "Talk: Part 1", sourceURL: source)
        let second = try writer.createNote(title: "Talk: Part 1", sourceURL: source)

        XCTAssertEqual(first.path, vault.appendingPathComponent("Inbox/YouTube/Talk - Part 1.md").path)
        XCTAssertEqual(second.lastPathComponent, "Talk - Part 1 2.md")
        XCTAssertEqual(
            try String(contentsOf: first, encoding: .utf8),
            "https://www.youtube.com/watch?v=T15BuMPZW4Q\n\n*Transcribing…*\n"
        )
    }

    func testCreateNoteRequiresAnExistingVault() throws {
        let source = try XCTUnwrap(URL(string: "https://example.com/video"))
        XCTAssertThrowsError(
            try WebLinkObsidianNoteWriter(vaultPath: "", subfolder: "").createNote(title: "A", sourceURL: source)
        )
        XCTAssertThrowsError(
            try WebLinkObsidianNoteWriter(vaultPath: "/nonexistent-vault-\(UUID())", subfolder: "")
                .createNote(title: "A", sourceURL: source)
        )
    }

    func testCompletingNoteReplacesPlaceholderAndKeepsUserEdits() throws {
        let vault = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vault) }
        let writer = WebLinkObsidianNoteWriter(vaultPath: vault.path, subfolder: "")
        let note = try writer.createNote(title: "Video", sourceURL: try XCTUnwrap(URL(string: "https://example.com/v")))
        try Data("#tag\nhttps://example.com/v\n\n*Transcribing…*\n\nMy notes\n".utf8).write(to: note)

        try WebLinkObsidianNoteWriter.completeNote(at: note, transcript: "  Hello world.\n")

        XCTAssertEqual(
            try String(contentsOf: note, encoding: .utf8),
            "#tag\nhttps://example.com/v\n\nHello world.\n\nMy notes\n"
        )
    }

    func testTranscriptIsAppendedWhenPlaceholderWasRemoved() throws {
        let vault = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vault) }
        let note = vault.appendingPathComponent("Video.md")
        try Data("https://example.com/v".utf8).write(to: note)

        try WebLinkObsidianNoteWriter.completeNote(at: note, transcript: "Hello")

        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "https://example.com/v\n\nHello\n")
    }

    func testFailedTranscriptionLeavesWarningCallout() throws {
        let vault = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: vault) }
        let writer = WebLinkObsidianNoteWriter(vaultPath: vault.path, subfolder: "")
        let note = try writer.createNote(title: "Video", sourceURL: try XCTUnwrap(URL(string: "https://example.com/v")))

        try WebLinkObsidianNoteWriter.failNote(at: note, message: "Engine missing\nsecond line")

        XCTAssertEqual(
            try String(contentsOf: note, encoding: .utf8),
            "https://example.com/v\n\n> [!warning] Transcription failed\n> Engine missing\n> second line\n"
        )
    }

    func testVaultDetectionReadsObsidianConfigMostRecentFirst() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let configDirectory = home.appendingPathComponent("Library/Application Support/obsidian", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let config = #"{"vaults":{"a":{"path":"/Vaults/Old","ts":1},"b":{"path":"/Vaults/New","ts":5}}}"#
        try Data(config.utf8).write(to: configDirectory.appendingPathComponent("obsidian.json"))

        let vaults = WebLinkObsidianVaultLocator.detectVaults(homeDirectory: home)

        XCTAssertEqual(vaults.map(\.path), ["/Vaults/New", "/Vaults/Old"])
        XCTAssertEqual(vaults.first?.name, "New")
    }

    @MainActor
    func testAddToObsidianDownloadsUsingVideoTitleAndFillsInTranscript() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let bin = try makeFakeToolchain(in: root)

        let runner = ObsidianTestProcessRunner { request in
            let titleIndex = try XCTUnwrap(request.arguments.firstIndex(of: "--print-to-file"))
            XCTAssertEqual(request.arguments[titleIndex + 1], "after_move:%(title)s")
            try Data("Größe: A Talk | Channel\n".utf8)
                .write(to: URL(fileURLWithPath: request.arguments[titleIndex + 2]))
            try Data([0, 1]).write(to: request.workingDirectory.appendingPathComponent("Gre_A_Talk-id.m4a"))
            return WebLinkProcessResult(exitCode: 0, diagnosticOutput: "")
        }
        let plugin = WebLinkPlugin(runner: runner, environment: ["PATH": bin.path], homeDirectory: root)
        let host = try PluginTestHostServices(
            defaults: [
                WebLinkPlugin.obsidianVaultPathKey: vault.path,
                WebLinkPlugin.obsidianSubfolderKey: "YouTube",
            ],
            pluginDataDirectory: root.appendingPathComponent("plugin-data")
        )
        host.setMediaTranscriptionHandler { media in
            XCTAssertEqual(media.displayName, "Größe: A Talk | Channel")
            return "The transcript.\n"
        }
        plugin.activate(host: host)

        let viewModel = WebLinkTranscriptionSidebarViewModel(plugin: plugin)
        viewModel.link = "https://www.youtube.com/watch?v=T15BuMPZW4Q"
        XCTAssertTrue(viewModel.canSubmitToObsidian)
        viewModel.importLinkToObsidian()

        let completed = await waitUntil {
            plugin.obsidianJobs.jobs.first?.state == .done
        }
        XCTAssertTrue(completed, "\(String(describing: viewModel.errorMessage))")
        XCTAssertEqual(host.transcribedImportedMedia.count, 1)
        XCTAssertTrue(host.enqueuedImportedMedia.isEmpty)
        XCTAssertEqual(viewModel.link, "")

        let note = vault.appendingPathComponent("YouTube/Größe - A Talk - Channel.md")
        XCTAssertEqual(
            try String(contentsOf: note, encoding: .utf8),
            "https://www.youtube.com/watch?v=T15BuMPZW4Q\n\nThe transcript.\n"
        )
    }

    @MainActor
    func testAddToObsidianWritesErrorIntoNoteWhenTranscriptionFails() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let bin = try makeFakeToolchain(in: root)

        let runner = ObsidianTestProcessRunner { request in
            try Data([0, 1]).write(to: request.workingDirectory.appendingPathComponent("Fallback_title-id.m4a"))
            return WebLinkProcessResult(exitCode: 0, diagnosticOutput: "")
        }
        let plugin = WebLinkPlugin(runner: runner, environment: ["PATH": bin.path], homeDirectory: root)
        let host = try PluginTestHostServices(
            defaults: [WebLinkPlugin.obsidianVaultPathKey: vault.path, WebLinkPlugin.obsidianSubfolderKey: ""],
            pluginDataDirectory: root.appendingPathComponent("plugin-data")
        )
        host.setMediaTranscriptionHandler { _ in
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "No engine"])
        }
        plugin.activate(host: host)

        let viewModel = WebLinkTranscriptionSidebarViewModel(plugin: plugin)
        viewModel.link = "https://example.com/video"
        viewModel.importLinkToObsidian()

        let failed = await waitUntil {
            plugin.obsidianJobs.jobs.first?.state == .failed("No engine")
        }
        XCTAssertTrue(failed)
        let note = vault.appendingPathComponent("Fallback title-id.md")
        XCTAssertEqual(
            try String(contentsOf: note, encoding: .utf8),
            "https://example.com/video\n\n> [!warning] Transcription failed\n> No engine\n"
        )
    }

    @MainActor
    func testAddToObsidianUsesChosenEngineAndDropsModelOfAnotherEngine() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = root.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let bin = try makeFakeToolchain(in: root)
        let runner = ObsidianTestProcessRunner { request in
            try Data([0, 1]).write(to: request.workingDirectory.appendingPathComponent("Video-id.m4a"))
            return WebLinkProcessResult(exitCode: 0, diagnosticOutput: "")
        }
        let plugin = WebLinkPlugin(runner: runner, environment: ["PATH": bin.path], homeDirectory: root)
        let host = try PluginTestHostServices(
            defaults: [
                WebLinkPlugin.obsidianVaultPathKey: vault.path,
                WebLinkPlugin.obsidianEngineIdKey: "groq",
                WebLinkPlugin.obsidianModelIdKey: "whisper-large-v3",
            ],
            pluginDataDirectory: root.appendingPathComponent("plugin-data")
        )
        host.mediaTranscriptionEngines = [
            PluginTranscriptionEngineOption(
                id: "groq",
                displayName: "Groq",
                isReady: true,
                models: [
                    .init(id: "whisper-large-v3", displayName: "Whisper Large v3"),
                    .init(id: "whisper-large-v3-turbo", displayName: "Whisper Large v3 Turbo"),
                ],
                defaultModelId: "whisper-large-v3-turbo"
            ),
            PluginTranscriptionEngineOption(
                id: "parakeet", displayName: "Parakeet", isReady: true, models: [], defaultModelId: nil
            ),
        ]
        host.defaultMediaTranscriptionEngineId = "parakeet"
        plugin.activate(host: host)

        let viewModel = WebLinkTranscriptionSidebarViewModel(plugin: plugin)
        viewModel.link = "https://example.com/one"
        viewModel.importLinkToObsidian()
        let firstDone = await waitUntil { plugin.obsidianJobs.jobs.first?.state == .done }
        XCTAssertTrue(firstDone)

        // Back to the default engine: the Groq model no longer applies.
        plugin.obsidianEngineId = nil
        viewModel.link = "https://example.com/two"
        viewModel.importLinkToObsidian()
        let secondDone = await waitUntil {
            plugin.obsidianJobs.jobs.count == 2 && plugin.obsidianJobs.jobs.first?.state == .done
        }
        XCTAssertTrue(secondDone)

        XCTAssertEqual(host.mediaTranscriptionSelections, [
            PluginTestMediaTranscriptionSelection(engineId: "groq", modelId: "whisper-large-v3"),
            PluginTestMediaTranscriptionSelection(engineId: nil, modelId: nil),
        ])
    }

    private func makeFakeToolchain(in root: URL) throws -> URL {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["yt-dlp", "ffmpeg"] {
            let executable = bin.appendingPathComponent(name)
            try Data().write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        return bin
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebLinkObsidianNoteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private struct ObsidianTestProcessRunner: WebLinkProcessRunning {
    let handler: @Sendable (WebLinkProcessRequest) throws -> WebLinkProcessResult

    init(handler: @escaping @Sendable (WebLinkProcessRequest) throws -> WebLinkProcessResult) {
        self.handler = handler
    }

    func run(_ request: WebLinkProcessRequest) async throws -> WebLinkProcessResult {
        try handler(request)
    }
}
