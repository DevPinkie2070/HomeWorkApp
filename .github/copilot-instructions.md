# Copilot instructions for HomeWorkApp

## Project overview

HomeWorkApp is a macOS menu-bar SwiftUI application for entering homework and creating a task in ClickUp. The Xcode project is `HomeWorkApp.xcodeproj`; its shared scheme is `MyApp`, while the built product and target are named `HomeWorkApp`.

The app starts in `HomeWorkApp/HomeWorkApp.swift` with a `MenuBarExtra` and a Settings scene. `HomeworkStore` is the `@MainActor` observable state coordinator: views bind to its published form and status properties, and the store coordinates lesson lookup and ClickUp submission. Keep UI state and orchestration in the store rather than putting network or process work in views.

The integration flow is:

- `HomeworkComposerView` collects subject, homework, and either a manually selected due date or the next matching lesson.
- `SchoolManagerCalendarService` checks the opt-in setting and credentials, then invokes `Support/schulmanager_schedule.py` through `Process`. The bridge receives one JSON request on stdin and emits one JSON response on stdout.
- The Python bridge imports the external `Vendor/Schulmanager-API` checkout, uses Selenium with Chrome/Chromium, and only reads the timetable. Its credentials must never be logged or persisted by the bridge.
- `ClickUpService` validates the Keychain token and `UserDefaults` list ID, then POSTs a task to ClickUp. ClickUp due dates are sent as Unix epoch milliseconds; manually selected dates include a time, while next-lesson dates do not.
- `KeychainStore` stores ClickUp and Schulmanager credentials in the macOS Keychain. `SchoolSettings` stores the non-secret opt-in flag and ClickUp list ID in `UserDefaults`.

The project uses the Xcode filesystem-synchronized root group, so Swift files placed under `HomeWorkApp/` are picked up by the target without manually editing source-file entries in `project.pbxproj`. The target is macOS-only, unsandboxed so it can access the local Python/Selenium installation, and has the network-client entitlement.

## Build and run

Build and launch the Debug app with the repository script:

```bash
./script/build_and_run.sh
```

The script uses `xcodebuild` with scheme `MyApp`, destination `platform=macOS`, and derived data under `.build/DerivedData`. Useful modes are:

```bash
./script/build_and_run.sh --verify      # Build, launch, and check the process
./script/build_and_run.sh --logs        # Build, launch, and stream process logs
./script/build_and_run.sh --telemetry   # Build, launch, and stream logs for the app subsystem
./script/build_and_run.sh --debug      # Build, then launch the binary under LLDB
```

For a build without launching the app:

```bash
xcodebuild -project HomeWorkApp.xcodeproj \
  -scheme MyApp \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_USER_SCRIPT_SANDBOXING=NO \
  build
```

There is currently no test target, test source, Swift Package manifest, SwiftLint configuration, or SwiftFormat configuration. Consequently there is no repository-supported full-suite or single-test command yet. If XCTest targets are added, use the shared `MyApp` scheme and Xcode's `-only-testing:<test-target>/<TestClass>/<testMethod>` selector for an individual test.

## Schulmanager setup

The optional timetable integration requires Python 3 and Google Chrome or Chromium. Prepare its ignored local dependencies with:

```bash
./script/setup_schulmanager_api.sh
```

This clones `Schulmanager-API` into ignored `Vendor/Schulmanager-API/`, creates `.venv/`, and installs Selenium. The Swift bridge expects `.venv/bin/python` and `Vendor/Schulmanager-API/main/schedules.py`, unless `SCHULMANAGER_API_PATH` points to a valid API checkout.

The app's settings must enable Schulmanager access and save credentials before lesson lookup can work. ClickUp requires both a personal API token and a list ID. Do not add either kind of credential to source files, logs, test fixtures, or repository configuration.

## Repository-specific conventions

- Keep user-facing strings and `LocalizedError.errorDescription` messages in German, matching the existing UI.
- Preserve Swift concurrency assumptions: the store is `@MainActor`, async service calls should remain non-blocking, and the Python process is already moved to a background queue.
- Inject `URLSession` into `ClickUpService` when testing or extending HTTP behavior rather than hard-coding a session in the service.
- Translate integration failures into the existing `HomeworkServiceError` cases so the store can surface `localizedDescription` consistently. Avoid swallowing errors except for intentionally optional response fields such as the ClickUp task URL.
- Normalize user-entered subjects, homework, and list IDs with trimming before validation or submission. Subject matching in the Python bridge is whitespace/HTML normalized and case-insensitive, with partial matching in either direction.
- Keep secrets in `KeychainStore` under the existing accounts (`clickUpToken`, `schoolManagerUsername`, and `schoolManagerPassword`). Keep non-secret preferences in `SchoolSettings` rather than introducing a second persistence mechanism.
- When changing the Python bridge protocol, update both `SchoolManagerCalendarService`'s Codable request/response types and `Support/schulmanager_schedule.py`; stdout is a machine-readable protocol, so diagnostic output must not be written there.
- Preserve the local-only nature of the Schulmanager adapter: it is opt-in, read-only, and must close its Selenium driver in a `finally` block.
- The app is a menu-bar utility (`LSUIElement`); changes to the app lifecycle or scenes should preserve the `MenuBarExtra` plus Settings scene structure.
