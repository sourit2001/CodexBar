# CodexQuotaBar

macOS menu bar and Touch Bar app for Codex rate limits.

It starts the bundled Codex executable from the current ChatGPT app, with the legacy standalone Codex app as a fallback:

```sh
/Applications/ChatGPT.app/Contents/Resources/codex app-server --listen stdio://
# or: /Applications/Codex.app/Contents/Resources/codex app-server --listen stdio://
```

Then it sends newline-delimited JSON-RPC `account/rateLimits/read` over stdio and displays:

- all available rate-limit windows (`primary` and, when present, `secondary`)
- a label derived from `windowDurationMins` (for example, 5 hours or weekly)
- remaining percent: `100 - usedPercent`
- reset time: `resetsAt`

Codex currently returns the weekly quota as `primary` and may omit `secondary`. The app derives each label from the window duration and hides missing windows, while remaining compatible with older responses that contain both 5-hour and weekly quotas.

The UI keeps the previous snapshot while refreshes are in flight, so failed or slow refreshes do not blank the menu bar or Touch Bar.

## Claude Code quota

The menu also shows Claude Code's 5 hour and weekly remaining quota (the same
numbers as `/usage`). The menu bar title reads `Codex% · C Claude%`.

It reads the OAuth token the Claude Code CLI stores in the macOS Keychain
(`Claude Code-credentials`, falling back to `~/.claude/.credentials.json`) and
calls `GET https://api.anthropic.com/api/oauth/usage` every 5 minutes. The
Claude desktop app keeps its own encrypted login, so if you only use Claude
Code inside the desktop app, log in once with the `claude` CLI (subscription
login, not an API key). On first launch macOS asks to allow Keychain access:
choose "Always Allow". When the access token is about to expire (or the API
returns 401), the app refreshes it with the stored refresh token and writes the
new tokens back to the same Keychain item (or file) in Claude Code's own format,
so the CLI keeps working. If refreshing fails, running `claude` once fixes it.

## Build

```sh
swift build -c release
```

## Build `.app`

```sh
chmod +x Scripts/build-app.sh
Scripts/build-app.sh
open dist/CodexQuotaBar.app
```

The app is an `LSUIElement` menu bar app. It uses the private Touch Bar selector `presentSystemModalTouchBar:systemTrayItemIdentifier:` with a fallback to `presentSystemModalFunctionBar:systemTrayItemIdentifier:`.
