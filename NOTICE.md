# NOTICE

## This repository

`install-windows.ps1`, `README.md`, `AGENTS.md` — Apache-2.0.

## Hex

Hex is © Anomaly (Anomaly Innovations, Inc), MIT licensed:
https://github.com/anomalyco/hex

This repository does **not** redistribute Hex. The installer downloads Hex from
Anomaly's own release service (`https://anoma.ly/hex/install-windows.ps1`), which
validates the download's size and SHA-256. `install-windows.ps1` in this repository
additionally requires a valid Authenticode signature from Anomaly Innovations, Inc.

## Changes in this copy

`install-windows.ps1`, `README.md`, `AGENTS.md` and this file were modified on
2026-11-23 from commit `055aefb` of mathruffian-dot/hex-zh-hant (installer
hardening; see the script header). `transformer/*.ts` are unchanged.

## Transformer and dictionaries

`transformer/*.ts` come from:

**truelife2/opencode-hex3-transformer-s2tw** — Apache-2.0
https://github.com/truelife2/opencode-hex3-transformer-s2tw

which packages the conversion tables of:

**OpenCC** — © Carbo Kuo and contributors, Apache-2.0
https://github.com/BYVoid/OpenCC

The tables used are OpenCC's `STCharacters`, `STPhrases` (simplified → traditional)
plus `TWVariants`, `TWVariantsPhrases`, `TWPhrases` (Taiwan wording). They are
embedded in `transformer/hex-data-st.ts` and `transformer/hex-data-tw.ts`.

The full Apache-2.0 license text is in `LICENSE` and
`transformer/LICENSE-Apache-2.0.txt`; section 4 of that license applies: this
NOTICE file must accompany redistributions of the transformer files, and modified
files must be marked as changed.

## Upstream discussion this repository implements

- https://github.com/anomalyco/hex/issues/829 — "Open the voice model prompt"
  (maintainer: post-transcription conversion via `hex.config.ts` is the supported path)
- https://github.com/anomalyco/hex/issues/1835 — "Dictation: mixed Chinese/English
  with configurable Traditional Chinese output" (open, `needs-design`)
