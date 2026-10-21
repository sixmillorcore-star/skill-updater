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
| Locale support | 7,317 assertions | All 20 language packs and 92 keys per pack, placeholders, culture/RTL metadata, explicit English fallback, preferences, and installed font selection. |

The 48 PowerShell fixture cases mock external update commands. They do not install, remove, or update the reader's actual skills or plugins. Discovery tests create and inspect their own temporary fixture trees. Locale tests do not open application windows.

## Recorded desktop UI validation

The following local desktop checks were completed while developing this version. Their full native rendering harnesses are not included in the initial repository test runner; the table records the tested scope rather than claiming that the included test runner repeats them.

| Local check | Result and scope |
| --- | --- |
| Minimum window | 256 cases passed at 640 × 460: 20 languages × five font sizes, representative text fonts, normal/empty/error/warning/missing-provider reports, and busy-close states. |
| Detail layout | 200 integrated checks passed across 20 languages × five sizes at the top and end of content. The detail pane admits four whole native text lines, preserves the full text, and keeps the final line fully visible after scrolling. |
| Integral text control | 600 cases and 6,600 assertions passed: 20 languages × five sizes × six fractional control heights, including native line pitch, top/middle/end scrolling, and native rendered text checks. |
| Live interaction | 10 checks passed for language/font switching, raw row identity and provider preservation, localized searching, global update eligibility, busy-close behavior, and appearance Apply/Cancel. |

Actual display DPI for these desktop checks was 96. Native rendering at 120/144 DPI was not exercised by the full minimum-window matrix. Character coverage also depends on the fonts and Windows language support installed on the machine. Long skill names can shorten in table cells; selecting a row exposes the full name, path, and detail in the scrollable pane.

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
