# MyWizard development

## Keep the in-app English help current

The user requires accessible English help and updates with every new development.

- For every user-visible feature, behavior change, removed option, shortcut, permission or workflow change, update `App/Help/guide.json` in the same change. Correct existing topics rather than appending contradictory release notes. For internal-only changes, review the affected help and leave it unchanged only if it remains accurate.
- Keep the guide concise, task-oriented, in English, and consistent with actual controls. Document limitations that affect use, especially live system speech versus export-only microphone speech, source-language export, audio cleanup, and permissions.
- Before releasing a new version, review the full guide and set `reviewedVersion` to `CFBundleShortVersionString` in `App/Info.plist`. Packaging must fail when these differ. This version check is a reminder to review content, not proof that it is accurate.
- Keep Help → MyWizard Help and its ⇧⌘H shortcut available. The guide must work offline, support search and selectable text, and retain native accessibility labels/headings.
- Validate help loading/search after changing the guide or its window. Rebuild and verify the signed `.build/MyWizard.app` before delivery; do not stop an active recording to refresh the UI.

## GitHub source management

- The private source repository is `https://github.com/yvancognasse/MyWizard`. This Mac folder remains the working checkout for native development and local tests.
- Use the `main` branch and `origin` remote. Preserve unrelated user changes. Commit and push authorized completed code changes after the required documentation updates and checks; report any blocked push explicitly.
- Exclude generated builds, compiled applications, caches, logs, credentials, tokens, local configuration and signing material. Never change the repository visibility or access without explicit instruction.
