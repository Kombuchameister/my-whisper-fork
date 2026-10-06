# my-whisper-fork

Personal fork of [TypeWhisper/typewhisper-mac](https://github.com/TypeWhisper/typewhisper-mac).
The app never updates itself from upstream. The plugin catalog is upstream's, so every upstream
plugin can be installed, but plugins built from this fork are never updated or replaced from it.

## Remotes and branches

- `origin` = `Kombuchameister/my-whisper-fork`. All pushes and pull requests go here.
- `upstream` = `TypeWhisper/typewhisper-mac`. Fetch only; its push URL is disabled locally.
- `main` is the version I run. Builds are made from `main`.
- New work happens on `feature/<name>` branches and is merged into `main`.

### Pulling upstream changes (only when I choose to)

```bash
git fetch upstream
git switch -c sync/upstream-$(date +%Y%m%d) main
git merge upstream/main          # resolve conflicts, keeping fork behaviour
# run the tests, then merge the sync branch into main
```

After every upstream merge, check that no upstream endpoints came back:

```bash
git grep -nE 'typewhisper\.github\.io|TypeWhisper/typewhisper-mac/releases' -- TypeWhisper ':!*.md' ':!TypeWhisper/App/AppConstants.swift' ':!TypeWhisper/Services/ScreenshotFixtureSeeder.swift'
```

(The plugin catalog's upstream URLs live only in `AppConstants.ForkDistribution`.)

`AppFormatterServiceTests.testForkDistributionEndpointsNeverPointUpstream` fails if they do.

## Where the app downloads from

Everything is defined in `AppConstants.ForkDistribution` (`TypeWhisper/App/AppConstants.swift`),
plus Sparkle's `SUFeedURL` in `TypeWhisper/Resources/Info.plist`.

| What | Source | Current state |
| --- | --- | --- |
| App updates (Sparkle) | `kombuchameister.github.io/my-whisper-fork/appcast.xml` | not published; automatic checks off |
| Plugin catalog (Integrations → Discover) | upstream's `typewhisper.github.io/typewhisper-mac/plugins-community-v1.json` | all upstream plugins listed and installable |
| Term packs | `kombuchameister.github.io/my-whisper-fork/termpacks.json` | published by the fork's term-pack workflow |
| Plugin downloads (official and community) | `github.com/TypeWhisper/typewhisper-mac/releases/download/…` or `github.com/Kombuchameister/my-whisper-fork/releases/download/…` | anything else is ignored |
| Fork-built plugins | built by `scripts/fork/install-plugins.sh`, marked with `Contents/Resources/ForkPluginBuild.txt` | never offered upstream updates, never replaced from the catalog |

Upstream's `SUPublicEDKey` is still in Info.plist, but it cannot validate anything the fork
publishes. Before hosting a fork appcast, generate a fork key with Sparkle's `generate_keys`
and replace it.

## Building the main app

```bash
scripts/fork/setup-local-signing.sh   # once: creates a local code-signing identity (asks for your password)
scripts/fork/build-main-app.sh        # every rebuild from main
```

`build-main-app.sh` builds the checkout with the main app's isolated identity
(`com.typewhisper.mac.dev.main`, `TypeWhisper-Dev-main`), signs it with the local identity so
Keychain approvals survive rebuilds, archives the previous app under `~/TypeWhisper-archives/apps/`,
and installs to `~/Applications/TypeWhsiper-main.app`. Settings are never touched.

## Plugins

All first-party plugin sources are in `TypeWhisperPluginSDK/Plugins/<Name>Plugin/`.
Installed plugins are compiled bundles in
`~/Library/Application Support/<app-support-dir>/Plugins/`, outside this repo.
Build them from this checkout rather than downloading them:

```bash
scripts/fork/install-plugins.sh --app-support TypeWhisper-Dev-main            # rebuild every installed plugin
scripts/fork/install-plugins.sh --app-support TypeWhisper-Dev-main --add GroqPlugin
```

The script moves replaced bundles to `Plugins.replaced/<timestamp>/` and writes
`fork-plugins.lock` (plugin, version, source commit). Each bundle it installs is marked as
fork-built, so the app keeps it even when upstream's catalog has a newer version. A first-party
plugin installed from the catalog is replaced by a fork build the next time this script runs
(it rebuilds every installed plugin that has a source in this checkout). It never touches the production app:
`/Applications/TypeWhisper.app` stays the unmodified upstream build as a fallback.

## State outside this repo

Per app: a preferences domain, SwiftData stores (workflows, profiles, prompts, snippets,
dictionary), installed plugin bundles, plugin model data, and Keychain API keys.
`scripts/fork/snapshot-app-state.sh` versions the configuration of every local app in a
separate local-only git repository (`~/TypeWhisper-state`). It stores Keychain service
names only, never secrets, and skips history, usage statistics, audio, and models.

```bash
scripts/fork/snapshot-app-state.sh --message "before trying X"
```

## GitHub Actions in the fork

Upstream's release and registry workflows are disabled in the fork's Actions settings
(not in the workflow files, so upstream merges stay conflict-free): Build and Release,
Build and Release Plugin, Update Plugin Download Counts, Redeploy Website on Release Edit,
PR Guard, Community Plugin Registry, Fetch Notarization Log, CodeQL, Mac App Store Upload.

Enabled: Build DMG (build and tests on push), Update Term Packs (publishes `termpacks.json`
to the fork's Pages), Feature App (isolated developer app artifacts).
If an upstream merge adds a new workflow, check it and disable it with
`gh workflow disable "<name>" -R Kombuchameister/my-whisper-fork` if it is upstream-only.
