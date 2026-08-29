## Pull Requests

When a pull request fixes or implements a GitHub issue, always:
- include the issue context in the PR body
- include an auto-close reference such as `Closes #123`
- include a short test plan with the exact verification command(s)

## Developer Feature Apps

A feature-app build is not complete when the app is merely built and installed. For every newly installed TypeWhisper developer feature app:

- keep `/Applications/TypeWhisper.app` untouched as the production fallback
- use a stable, feature-specific bundle ID, Application Support directory, preferences domain, Keychain service prefix, and designated signing requirement
- initialize the new app from the most recently tested and configured developer app, never from production: clone its Application Support data and complete preferences domain into the new isolated namespaces
- clone its provider/token Keychain items into the new bundle-ID-prefixed services and authorize only the new feature app under its stable designated requirement; never grant broad Keychain access to `/usr/bin/security`
- treat a request to build or install a developer feature app as authorization to perform this initialization without asking the user to repeat the convention
- launch once to verify the copied workflows and configured providers are available without Keychain prompts, then close the app to avoid hotkey conflicts
- on routine rebuilds of the same feature app, preserve its existing isolated state and credentials; do not reclone or overwrite them
