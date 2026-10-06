import XCTest
@testable import TypeWhisper

final class AppFormatterServiceTests: XCTestCase {
    func testPremiumAccountKeychainServiceSeparatesRuntimeEnvironments() {
        XCTAssertEqual(
            AppConstants.resolvePremiumAccountKeychainService(
                isScreenshotAutomation: false,
                isRunningTests: false,
                isDevelopment: false
            ),
            "com.typewhisper.mac.premium-account"
        )
        XCTAssertEqual(
            AppConstants.resolvePremiumAccountKeychainService(
                isScreenshotAutomation: false,
                isRunningTests: false,
                isDevelopment: true
            ),
            "com.typewhisper.mac.dev.premium-account"
        )
        XCTAssertEqual(
            AppConstants.resolvePremiumAccountKeychainService(
                isScreenshotAutomation: false,
                isRunningTests: true,
                isDevelopment: true
            ),
            "com.typewhisper.mac.tests.premium-account"
        )
        XCTAssertEqual(
            AppConstants.resolvePremiumAccountKeychainService(
                isScreenshotAutomation: true,
                isRunningTests: true,
                isDevelopment: true
            ),
            "com.typewhisper.mac.screenshots.premium-account"
        )
    }

    func testBundledReleaseChannelUsesInfoDictionaryValue() {
        let channel = AppConstants.bundledReleaseChannel(
            infoDictionary: ["TypeWhisperReleaseChannel": AppConstants.ReleaseChannel.releaseCandidate.rawValue]
        )

        XCTAssertEqual(channel, .releaseCandidate)
    }

    func testBundledPreviewReleaseUsesDailyTagAndURL() throws {
        let release = try XCTUnwrap(AppConstants.bundledPreviewRelease(
            infoDictionary: [
                "TypeWhisperReleaseChannel": AppConstants.ReleaseChannel.daily.rawValue,
                "TypeWhisperReleaseTag": "v1.6.0-daily.20260716",
            ]
        ))

        XCTAssertEqual(release.tag, "v1.6.0-daily.20260716")
        XCTAssertEqual(
            release.url.absoluteString,
            "https://github.com/Kombuchameister/my-whisper-fork/releases/tag/v1.6.0-daily.20260716"
        )
    }

    func testKeychainSaveReplacesExistingValueInPlace() throws {
        let service = "tests.keychain-update-in-place.\(UUID().uuidString)"
        defer { try? KeychainService.delete(service: service) }

        try KeychainService.save(key: "first-key", service: service)
        try KeychainService.save(key: "second-key", service: service)

        XCTAssertEqual(KeychainService.load(service: service), "second-key")
    }

    func testForkDistributionEndpointsNeverPointUpstream() throws {
        let forkPages = AppConstants.ForkDistribution.pagesBaseURL.absoluteString
        let feedURL = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)
        let automaticChecks = Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool

        XCTAssertTrue(feedURL.hasPrefix(forkPages + "/"), "Sparkle feed must be served by the fork: \(feedURL)")
        XCTAssertEqual(automaticChecks, false)
        XCTAssertTrue(
            AppConstants.ForkDistribution.termPackRegistryURL.absoluteString.hasPrefix(forkPages + "/")
        )
        for endpoint in [feedURL, forkPages, AppConstants.ForkDistribution.releaseTagsURL.absoluteString] {
            XCTAssertFalse(endpoint.lowercased().contains("typewhisper/typewhisper-"), endpoint)
            XCTAssertFalse(endpoint.lowercased().contains("typewhisper.github.io"), endpoint)
        }
        // The plugin catalog is upstream's; plugin ZIPs come from upstream's or the fork's releases.
        XCTAssertTrue(PluginRegistryService.isTrustedRegistryDownloadURL(
            "https://github.com/Kombuchameister/my-whisper-fork/releases/download/plugin-x-v1.0.0/X.zip",
            source: .community
        ))
        XCTAssertTrue(PluginRegistryService.isTrustedRegistryDownloadURL(
            "https://github.com/TypeWhisper/typewhisper-mac/releases/download/plugin-groq-v1.0.25/GroqPlugin.zip",
            source: .official
        ))
        XCTAssertFalse(PluginRegistryService.isTrustedRegistryDownloadURL(
            "https://github.com/someone-else/plugins/releases/download/plugin-x-v1.0.0/X.zip",
            source: .community
        ))
        XCTAssertFalse(PluginRegistryService.isTrustedRegistryDownloadURL(
            "https://example.com/TypeWhisper/typewhisper-mac/releases/download/x/X.zip",
            source: .official
        ))
    }

    func testForkBuiltPluginBundlesAreRecognizedByTheirMarker() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("GroqPlugin.bundle")
        let resources = bundleURL.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        XCTAssertFalse(PluginRegistryService.isForkBuiltPluginBundle(at: bundleURL))
        try "plugin=GroqPlugin\n".write(
            to: bundleURL.appendingPathComponent(AppConstants.ForkDistribution.forkPluginBuildMarker),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(PluginRegistryService.isForkBuiltPluginBundle(at: bundleURL))
    }

    func testPluginsWithForkSourcesAreProtectedEvenWithoutMarker() {
        let catalogCopy = URL(fileURLWithPath: "/tmp/does-not-exist/OpenAIPlugin.bundle")
        XCTAssertTrue(PluginRegistryService.isForkPlugin(
            "com.typewhisper.openai", forkSourceIds: ["com.typewhisper.openai"], installedBundleURL: catalogCopy
        ))
        XCTAssertTrue(PluginRegistryService.isForkPlugin(
            "com.typewhisper.openai", forkSourceIds: ["com.typewhisper.openai"], installedBundleURL: nil
        ), "Not installed or not loaded must not open the catalog route either")
        XCTAssertFalse(PluginRegistryService.isForkPlugin(
            "com.example.community", forkSourceIds: ["com.typewhisper.openai"], installedBundleURL: catalogCopy
        ))
    }

    func testBundledPreviewReleaseUsesReleaseCandidateTagAndURL() throws {
        let release = try XCTUnwrap(AppConstants.bundledPreviewRelease(
            infoDictionary: [
                "TypeWhisperReleaseChannel": AppConstants.ReleaseChannel.releaseCandidate.rawValue,
                "TypeWhisperReleaseTag": "v1.6.0-rc1",
            ]
        ))

        XCTAssertEqual(release.tag, "v1.6.0-rc1")
        XCTAssertEqual(
            release.url.absoluteString,
            "https://github.com/Kombuchameister/my-whisper-fork/releases/tag/v1.6.0-rc1"
        )
    }

    func testBundledPreviewReleaseIsHiddenForStableBuild() {
        let release = AppConstants.bundledPreviewRelease(
            infoDictionary: [
                "TypeWhisperReleaseChannel": AppConstants.ReleaseChannel.stable.rawValue,
                "TypeWhisperReleaseTag": "v1.6.0",
            ]
        )

        XCTAssertNil(release)
    }

    func testBundledPreviewReleaseIgnoresMissingOrBlankTag() {
        XCTAssertNil(AppConstants.bundledPreviewRelease(
            infoDictionary: [
                "TypeWhisperReleaseChannel": AppConstants.ReleaseChannel.daily.rawValue,
            ]
        ))
        XCTAssertNil(AppConstants.bundledPreviewRelease(
            infoDictionary: [
                "TypeWhisperReleaseChannel": AppConstants.ReleaseChannel.daily.rawValue,
                "TypeWhisperReleaseTag": " \n ",
            ]
        ))
    }

    func testSelectedUpdateChannelUsesStoredOverride() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(AppConstants.ReleaseChannel.daily.rawValue, forKey: UserDefaultsKeys.updateChannel)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        let channel = AppConstants.selectedUpdateChannel(
            defaults: defaults,
            infoDictionary: ["TypeWhisperReleaseChannel": AppConstants.ReleaseChannel.stable.rawValue]
        )

        XCTAssertEqual(channel, .daily)
    }

    func testSelectedUpdateChannelIgnoresInvalidStoredOverride() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set("beta", forKey: UserDefaultsKeys.updateChannel)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        let channel = AppConstants.selectedUpdateChannel(
            defaults: defaults,
            infoDictionary: ["TypeWhisperReleaseChannel": AppConstants.ReleaseChannel.stable.rawValue]
        )

        XCTAssertEqual(channel, .stable)
    }

    @MainActor
    func testMarkdownFormattingNormalizesBullets() {
        let service = AppFormatterService()

        let output = service.format(
            text: "bullet first item\n* second item",
            bundleId: "md.obsidian",
            outputFormat: "auto"
        )

        XCTAssertEqual(output, "- first item\n- second item")
    }

    @MainActor
    func testHTMLFormattingEscapesMarkup() {
        let service = AppFormatterService()

        let output = service.format(
            text: "hello <team>\n- launch",
            bundleId: "com.apple.mail",
            outputFormat: "auto"
        )

        XCTAssertEqual(output, "<p>hello &lt;team&gt;</p>\n<ul>\n<li>launch</li>\n</ul>")
    }

    @MainActor
    func testBrowserAutoFormattingUsesURLDomainForGoogleMail() {
        let service = AppFormatterService()

        let output = service.format(
            text: "hello <team>\n- launch",
            bundleId: "com.google.Chrome",
            url: "https://mail.google.com/mail/u/0/#inbox",
            outputFormat: "auto"
        )

        XCTAssertEqual(output, "<p>hello &lt;team&gt;</p>\n<ul>\n<li>launch</li>\n</ul>")
    }

    @MainActor
    func testRTFFormattingLeavesMarkdownTextForClipboardConversion() {
        let service = AppFormatterService()

        let output = service.format(
            text: "**Launch**\n- Budget",
            bundleId: "com.apple.mail",
            outputFormat: "rtf"
        )

        XCTAssertEqual(output, "**Launch**\n- Budget")
    }

    func testAutoFormatResolverMapsRichTextAndBrowserTargets() {
        XCTAssertEqual(
            WorkflowOutputFormatResolver.resolvedFormat(
                storedFormat: "auto",
                bundleIdentifier: "com.microsoft.Word"
            ),
            "rtf"
        )
        XCTAssertEqual(
            WorkflowOutputFormatResolver.resolvedFormat(
                storedFormat: "auto",
                bundleIdentifier: "com.google.Chrome",
                url: "https://docs.google.com/document/d/abc/edit"
            ),
            "rtf"
        )
        XCTAssertEqual(
            WorkflowOutputFormatResolver.resolvedFormat(
                storedFormat: "auto",
                bundleIdentifier: "com.google.Chrome",
                url: "https://github.com/TypeWhisper/typewhisper-mac"
            ),
            "plaintext"
        )
        XCTAssertNil(
            WorkflowOutputFormatResolver.resolvedFormat(
                storedFormat: nil,
                bundleIdentifier: "com.microsoft.Word"
            )
        )
    }

    @MainActor
    func testRegisterDefaultUserDefaultsIncludesAppFormattingFlag() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        AppDelegate.registerDefaultUserDefaults(defaults)

        XCTAssertEqual(defaults.object(forKey: UserDefaultsKeys.appFormattingEnabled) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled) as? Bool, true)
        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsKeys.dictationRecoveryRetentionDays) as? Int,
            DictationRecoveryRetentionPolicy.thirtyDays.rawValue
        )
    }
}
