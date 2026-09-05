# Development and verification

## Toolchain

- Xcode 26.6 (build 17F113)
- Swift 6 language mode
- iOS 26.0 deployment target
- iOS 26.5 simulator runtime
- Swift Testing
- no third-party packages

## Xcode workflow

Open `KidMoney.xcodeproj`, select the `KidMoney` scheme, and choose an iPhone simulator. A physical-device run additionally requires selecting an Apple development team and replacing the placeholder `com.example.KidMoney` bundle identifier with a unique identifier.

Build and test from the command line:

```zsh
xcodebuild -project KidMoney.xcodeproj -scheme KidMoney \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

xcodebuild -project KidMoney.xcodeproj -scheme KidMoney \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

For sandboxed automation, add a writable derived-data path such as `-derivedDataPath /private/tmp/kidmoney-derived`.

## Simulator and test-runner notes

A newly installed runtime can take several minutes to migrate system data on its first boot. Let one invocation finish. Concurrent test runs can leave temporary incomplete `.xcresult` bundles.

Xcode 26.6's MCP `RunAllTests` action has occasionally attempted to read its result bundle before the write completed. `GetTestList` followed by `RunSomeTests` has produced reliable structured results. Treat an incomplete bundle as runner state, not a pass or failure; retry and require explicit counts.

## Xcode tools for agents

1. Open the project in Xcode.
2. Enable **Xcode → Settings → Intelligence → Model Context Protocol → Allow external agents to use Xcode tools**.
3. Run `codex mcp add xcode -- xcrun mcpbridge`.
4. Start a new Codex session so its tool catalog includes Xcode.

The bridge provides native builds, tests, Issue Navigator diagnostics, previews, file operations, and Apple documentation search.

## Physical iPhone preparation

1. Connect and trust the iPhone.
2. Add an Apple ID under Xcode Settings → Accounts.
3. Select the KidMoney target and choose a development team under Signing & Capabilities.
4. Set a unique bundle identifier.
5. Select the iPhone as the destination and run once.

Do not commit a personal development-team identifier unless the owner explicitly wants it shared.

## Logs

Phase 2 should use `Logger`/OSLog around intent invocation, entity lookup, amount conversion, transaction persistence, and returned results. Keep logs useful without recording more family data than necessary.

