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
| Plugins with a source in this repo | built by `scripts/fork/install-plugins.sh`; their IDs are embedded in the app (`ForkPluginSources.txt`) and each bundle is marked (`ForkPluginBuild.txt`) | never updated, replaced, or installed from the catalog |

Upstream's `SUPublicEDKey` is still in Info.plist, but it cannot validate anything the fork
publishes. Before hosting a fork appcast, generate a fork key with Sparkle's `generate_keys`
and replace it.

## Building the main app

```bash
scripts/fork/setup-local-signing.sh   # optional fallback: local identity when no Apple Development certificate exists
scripts/fork/build-main-app.sh        # every rebuild from main
```

`build-main-app.sh` builds the checkout with the main app's isolated identity
(`com.typewhisper.mac.dev.main`, `TypeWhisper-Dev-main`), signs it with your Apple Development
certificate (falling back to the local identity), archives the previous app under `~/TypeWhisper-archives/apps/`,
and installs to `~/Applications/TypeWhsiper-main.app`. Settings are never touched.

Keychain approvals: macOS ties each Keychain item to the signer's Team ID. An Apple Development
certificate has one, so "Always Allow" holds across rebuilds. The local self-signed identity has
none, so Keychain pins every build's code hash and asks once per key after each rebuild. After
switching identities, each key asks once more; answer "Always Allow".

## Using the app on another Mac

Every Mac builds the app from this repo, so all of them run the same code and plugins.
Settings travel through the private repo `Kombuchameister/typewhisper-settings`
(cloned to `~/TypeWhisper-settings`); API keys stay in each Mac's Keychain.

Routine use:

```bash
scripts/fork/settings-sync.sh export          # on the Mac where you changed settings
scripts/fork/update-mac.sh                    # on any Mac: pull main, rebuild app and plugins, relaunch
scripts/fork/update-mac.sh --import-settings  # the same, and take the settings exported on the other Mac
```

Import overwrites the synced settings on that Mac (the replaced files are kept under
`~/Library/Application Support/TypeWhisper-Dev-main/settings-sync.replaced/`), so export on
one Mac and import on the other rather than editing settings on both in between.

What is synced: the preferences domain (except window positions, updater state, device IDs,
the ChatGPT login, and loaded models), the workflows, profiles, prompt-actions, snippets and
dictionary stores, small plugin configuration files (such as Script Runner's scripts), and the
list of installed plugins. Paths under your home folder are adjusted to the other Mac's.
Not synced: API keys and logins, history, usage statistics, audio, and models.

First setup on a new Mac:

1. Install Xcode, open it, sign in under Settings > Accounts with the same Apple ID, then
   choose Manage Certificates… > + > Apple Development. Signing in alone does not always
   create the certificate, and the build refuses to install an unsigned app (macOS cannot
   keep microphone or Device Control permissions for one).
2. Install the GitHub CLI and sign in: `brew install gh && gh auth login`.
3. Clone and build:
   ```bash
   git clone https://github.com/Kombuchameister/my-whisper-fork.git ~/TypeWhisper-fork
   cd ~/TypeWhisper-fork
   git remote add upstream https://github.com/TypeWhisper/typewhisper-mac.git
   git remote set-url --push upstream DISABLED-do-not-push-to-upstream
   scripts/fork/update-mac.sh --import-settings
   ```
4. Enter the API keys the import lists in the app's plugin settings, sign in to ChatGPT again
   if you use it, and let local engines (WhisperKit, Parakeet) download their models.
   Answer "Always Allow" to each Keychain prompt once.

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
