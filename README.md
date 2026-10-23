# Teslacam

macOS aplikace (SwiftUI, Apple Silicon) na odemčení, prohlížení, stříhání a třídění klipů z Tesla dashcamu a Sentry, včetně šifrovaných záznamů z firmwaru 2026.20+.

## Co umí

- **Odemčení** šifrovaných klipů (`TeslaCam/EncryptedClips`) přes klíče z `dashcam.tesla.com`; video se dešifruje lokálně. Paralelní zpracování, navazování, kontrola volného místa, nedopsané klipy hlásí česky. Nešifrované klipy jen zkopíruje.
- **Token** jen v paměti: vložení ze schránky, nebo přihlášení ve vestavěném okně, které token zachytí samo. Posílá se výhradně na `https://dashcam.tesla.com`.
- **Knihovna** událostí s náhledy, filtry, štítky, poznámkami a označením ponechat/smazat.
- **Přehrávač** všech 6 kamer synchronně, minutové soubory navazují jako jeden celek.
- **Telemetrie** z videa (H.264 SEI, firmware 2025.44.25+): rychlost, plyn, brzda, volant, blinkry, převodový stupeň, FSD / Autosteer / TACC, GPS. Zobrazuje se nad videem, v grafu rychlosti a na mapě trasy.
- **Úklid**: označené události do Koše (a zapamatování, aby se znovu neodemkly); smazání šifrovaných originálů ze zdroje nebo flashky jen tehdy, když je odemčené video ověřené (shoda podle klíče v hlavičce), vždy až po potvrzení se seznamem.
- **Střih a export**: označení úseku (klávesy I/O), uložení výřezu jako nové události, export všech kamer, přední kamery (bez ztráty kvality, s telemetrií) nebo mozaiky.

## Sestavení

Potřeba: macOS 14+, Xcode, ffmpeg (`brew install ffmpeg`).

```bash
./scripts/build-app.sh
```

Výsledek: `build/Tesla Preview.app`. Testy: `swift test`.

## Struktura

- `Sources/TeslaCamCore`: šifrovaný kontejner (hlavička, IV, AES-CBC, kontrola `ftyp`), klient Tesla API, skener zdroje, odemykání, manifest, MP4 parser, telemetrie, knihovna, indexace, export.
- `Sources/TeslaPreview`: UI.
- Ve složce odemčených videí vzniká `.tesla-preview/` (manifest odemčení, označení, mezipaměť náhledů a telemetrie).

## Zdroje

- Formát kontejneru a logika odemykání podle [tesla-dashcam-decrypt-go](https://github.com/crstian19/tesla-dashcam-decrypt-go) (MIT, commit `ed2b751`); testovací vzorek `real_clip.*` pochází odtud (licence v `Tests/TeslaCamCoreTests/Fixtures`).
- Telemetrie (SEI, `dashcam.proto`) podle [teslamotors/dashcam](https://github.com/teslamotors/dashcam).
