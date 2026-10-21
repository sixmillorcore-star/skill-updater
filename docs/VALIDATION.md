# Validation

The initial version was built and tested on Windows with Windows PowerShell 5.1 and the .NET Framework C# compiler. Tests described below distinguish isolated fixtures, local desktop measurements, and provider checks. The source does not need an API key for these tests.

## Run the included tests

From the repository root, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

The runner starts each suite in its own Windows PowerShell 5.1 process so that mocked functions and temporary environment changes cannot carry into another suite. Generated fixtures, logs, and compiled test executables stay under `tests/.artifacts/`, which should not be committed.

| Included suite | Checks | Scope |
| --- | ---: | --- |
| Backend | 11 cases | Version ordering, backups, isolated replacement, changed files, removed plugins, and verification after mocked updates. |
| Discovery | 13 cases | User/system/project skill discovery, disabled entries, installed plugin versions, shared paths, junction deduplication, and environment precedence. |
| Claude support | 16 cases | Local registry/scopes, marketplace metadata, disabled settings, backup/update plans, and mocked CLI outcomes. |
| Backend integration | 8 cases | Provider combination, partial results, absent CLI paths, and mocked post-update rescanning. |
| Locale support | 8,581 assertions | All 20 language packs and 108 keys per pack, placeholders, culture/RTL metadata, explicit English fallback, preferences, and installed font selection. |
| App update engine | 67 assertions | Stable versions, downgrade rejection, official release URLs, SHA-256 checks, complete manifests, corrupt downloads, unsafe ZIP entries, Windows ZIP separators, and failed-stage cleanup. |
| App update installer | 54 assertions | Isolated replacement and backup, settings/data preservation, failed-write rollback, locked files, and parent-process handoff. |
| App update UI | 4,306 assertions | Offscreen geometry across 20 languages and five font sizes, action states, update-close guards, and main-window version button at 640 × 460. |

The 48 skill-backend PowerShell fixture cases mock external update commands. They do not install, remove, or update the reader's actual skills or plugins. Discovery and self-update tests create their own temporary fixture trees. Locale and app-update UI tests do not display application windows. App-update engine tests use local release metadata and archives rather than publishing test releases.

## Recorded desktop UI validation (v1.0.0)

The following local desktop checks were completed for the original interface. Their full native rendering harnesses are not included in the repository test runner; the table records the tested scope rather than claiming that the included test runner repeats them. Version 1.1.0 adds the offscreen app-update UI checks listed above and keeps the main layout rows unchanged.

| Local check | Result and scope |
| --- | --- |
| Minimum window | 256 cases passed at 640 × 460: 20 languages × five font sizes, representative text fonts, normal/empty/error/warning/missing-provider reports, and busy-close states. |
| Detail layout | 200 integrated checks passed across 20 languages × five sizes at the top and end of content. The detail pane admits four whole native text lines, preserves the full text, and keeps the final line fully visible after scrolling. |
| Integral text control | 600 cases and 6,600 assertions passed: 20 languages × five sizes × six fractional control heights, including native line pitch, top/middle/end scrolling, and native rendered text checks. |
| Live interaction | 10 checks passed for language/font switching, raw row identity and provider preservation, localized searching, global update eligibility, busy-close behavior, and appearance Apply/Cancel. |

Actual display DPI for these desktop checks was 96. Native rendering at 120/144 DPI was not exercised by the full minimum-window matrix. Character coverage also depends on the fonts and Windows language support installed on the machine. Long skill names can shorten in table cells; selecting a row exposes the full name, path, and detail in the scrollable pane.

## App release update validation (v1.1.0)

After publication, an isolated client with its test-only installed version set to 1.0.0 detected the real public v1.1.0 release, downloaded its Windows ZIP over HTTPS, and verified GitHub's SHA-256 digest plus the complete manifest and all 34 package files. The production client at version 1.1.0 correctly reported no newer version.

The C# installer launch and PowerShell helper were also exercised together in a temporary path containing spaces and Thai characters. The test parent exited naturally after the ready handshake; 33 runtime files matched the release hashes, the old executable was retained in the backup, and personal settings, interface preferences, and installation state were preserved. GUI restart was disabled in that isolated test copy. The installed local app was then upgraded using the same helper, with configuration hashes and both scheduled tasks checked against their previous values. No Computer Use was used for the v1.1.0 checks.

## Provider coverage

Codex discovery and a read-only version check were exercised against a local installation. Claude Code was not installed on that validation machine: Claude registry, file, and CLI behavior was tested with fixtures, not with a live Claude update. Marketplace/catalog freshness and the CLI available on another machine can affect what versions can be verified.

The program only enables an update when a supported source provides a verifiable newer version. Local skills without a configured source remain manual. A passing fixture does not establish that every plugin marketplace or future CLI version is supported.

## Responsiveness measurements

An isolated native UI benchmark used a 100-row fixture at 640 × 460 and the median of three rounds. Baseline and optimized runs were executed sequentially after other UI stress tests finished.

| Operation | Baseline | Optimized |
| --- | ---: | ---: |
| Column fitting | 2.34 ms | 0.019 ms |
| Resize | 26.08 ms | 16.60 ms |
| Search change | 28.07 ms | 6.35 ms |
| Language change | 151.00 ms | 39.46 ms |

These are local observations, not a guarantee for every machine or workload. The UI-only idle sample was 2.5 seconds and excluded the production refresh timer and backend checks. Initial working set was about 49 MiB; this does not establish a RAM reduction. After warmup, 80 repeated switches among the tested locales kept font-cache counts and GDI object counts stable.
