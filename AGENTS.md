# AGENTS.md

Instructions for an AI agent that lands in this repository. Read this file before
running anything. Everything here is idempotent: running it twice is safe.

## Goal

Hex is a local dictation app (Anomaly, MIT). It ships a Traditional Chinese
*interface*, but its **transcripts are whatever script the speech model picks** —
in practice Simplified. There is no built-in simplified-to-traditional step
(upstream: anomalyco/hex#1835, open, `needs-design`). The supported workaround
(upstream maintainer, anomalyco/hex#829) is a **personal transformation** in
`~/.config/hex/hex.config.ts`.

This repository installs Hex and that transformation, then wires the step into
"Every dictation".

## Requirements

- Windows 10/11, x64 or ARM64
- PowerShell 5.1+ (`powershell.exe` is fine; `pwsh` also works)
- Network access to `anoma.ly` (Hex install + model) and `raw.githubusercontent.com`
- Hex's OS-level prerequisites: microphone permission for the app; no admin rights
  (per-user install into `%APPDATA%\hex`)

## Run

Run it from a reviewed local clone. Do not pipe the script from the `main` branch:
that content can change after it was reviewed.

```powershell
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```

Useful switches: `-SkipHotkey`, `-ConfigureOnly`, `-Hotkey caps-lock`,
`-AllowUnreviewedInstaller` (only after reading the changed vendor installer).

With no path to `install-windows.ps1` (offline agent), do the four "Manual steps"
in `README.md` instead.

## What the script mutates

| Path | Change |
|---|---|
| `%APPDATA%\hex\` | Hex install (official installer, pinned by SHA-256, stable channel; it verifies size + SHA-256, and this script then requires a valid Authenticode signature from Anomaly Innovations, Inc) |
| `%USERPROFILE%\.config\hex\` | `hex.config.ts` + 3 transformer `.ts` files, `hex.d.ts`, `tsconfig.json` (via `hex commands init`) |
| Hex settings, via `hex settings apply` | `dictation_processing.default_mode.transformations` gains `s2twp`; `ui_language = zh-Hant`; `dictation_hotkey` (unless `-SkipHotkey`). Values already in place are not written again |
| `%APPDATA%\hex\settings.json.bak-<timestamp>` | Backup written before a change, when settings.json exists |
| `%USERPROFILE%\.config\hex\hex.config.ts.bak-<timestamp>` | A pre-existing `hex.config.ts` that differed |
| HKCU user `PATH` | Hex's own installer appends `%APPDATA%\hex\bin` |

It does **not** touch other apps' config, the registry beyond Hex's own keys, or
any network service besides the two hosts above.

## Success criteria — check, do not assume

```powershell
hex commands check                            # must contain: 3 transformations
hex settings get ui_language                  # must be: zh-Hant
hex settings get dictation_processing.default_mode   # must contain: s2twp
hex settings get dictation_hotkey             # e.g. control+option+space
```

Then verify the pipeline end to end: have the user dictate one Chinese sentence,
and compare

```powershell
hex history --raw --limit 1
```

`raw_text` stays Simplified (model output); `final_text` must be Traditional
(e.g. 軟體 / 記憶體 / 硬碟 / 網路 / 資料庫). Different scripts in the two fields
is the proof the transformation ran.

## Guardrails

- **Do not edit `settings.json` by hand.** Hex rewrites it on exit and the edit is
  lost. Use `hex settings set` / `hex settings apply <file>`; `apply` takes nested
  JSON values such as `dictation_processing.default_mode`.
- **Do not use the Output pane's "Try" field to verify.** Its preview only applies
  *built-in* steps (`lowercase`, …); script transformations run only on a real
  dictation.
- **The script exits non-zero when one of the checks above fails.** The dictation
  test below is still needed: only a real dictation proves the step runs.
- **Per-mode steps are independent.** If the user creates an app-specific mode, it
  needs `s2twp` added separately.
- **Live text previews stay Simplified.** The step is post-processing; only the
  pasted result is Traditional.
- Do not add `fetch`/`child_process` to `hex.config.ts`. That would make Hex show a
  trust prompt and, until allowed, paste text unchanged.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `hex commands check` prints "no hex.config.ts or hex.config.js" | workspace missing / wrong dir | `hex commands init`, then re-copy the 4 `.ts` files |
| `unknown setting` from `hex settings set` | `set` takes whole keys from `hex settings list` | put the JSON value in a file and use `hex settings apply <file>` |
| Pane shows "還沒有步驟" after install | Hex cached settings before the edit | `hex restart` |
| Output still Simplified | step missing, or a different app mode is active | check `dictation_processing.default_mode` / the mode's own `transformations` |
| Hotkey does nothing | `Ctrl+Space` grabbed by the Chinese IME | `hex settings set dictation_hotkey control+option+space` |
| Hex reports version/binary mismatch on install | a running Hex held the old binary | quit Hex, re-run the installer |
| "vendor installer changed since it was reviewed" | Anomaly updated `install-windows.ps1` | read the new script, then re-run with `-AllowUnreviewedInstaller` |
| "does not match its pinned SHA-256" | a transformer file was edited, or checked out with CRLF | restore the file from git (`.gitattributes` keeps LF) |

## Attribution

The transformer and dictionaries are OpenCC (Apache-2.0) data packaged by
`truelife2/opencode-hex3-transformer-s2tw`. Keep `NOTICE.md` and the Apache-2.0
license text when redistributing.
