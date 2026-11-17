# Fork wetpas/plezy

Persönlicher Fork von [edde746/plezy](https://github.com/edde746/plezy). Diese Datei gibt es nur auf dem
Branch `wetpas`, nicht in Branches, die als PR ans Original gehen.

## Branches

| Branch | Zweck |
|---|---|
| `main` | 1:1-Spiegel von `upstream/main`. Nie darauf committen. Aktualisieren mit `git sync`. |
| `fix/…`, `perf/…`, `feat/…` | Ein Thema pro Branch, ab `upstream/main` (`git neu feat/thema`). Kann als PR ans Original gehen. |
| `wetpas` | Sammel-Branch für die eigene App: `main` + alle eigenen Themen-Branches + Fork-Build. |

Upstream übernehmen: `git sync`, dann `git switch wetpas && git merge main`.

## Eigene App bauen

`.github/workflows/fork-android.yml` baut bei jedem Push auf `wetpas` die APKs („Plezy Fork“, App-ID
`com.edde746.plezy.fork`). Sie lassen sich neben der offiziellen Plezy installieren. Download unter
*Actions → Fork – Android-Build → Lauf → Artifacts*: jede APK einzeln als `.apk`, direkt aufs Handy (14 Tage verfügbar,
GitHub-Login nötig).

- `arm64-v8a`: aktuelle Handys und die meisten neueren TV-Geräte
- `armeabi-v7a`: ältere bzw. 32-Bit-TV-Boxen (z. B. viele Google-TV-Sticks)
- `x86_64`: Emulator

Signatur: Secrets `FORK_ANDROID_KEYSTORE_B64` und `FORK_ANDROID_KEYSTORE_PASSWORD`. Ohne sie wird mit einem
wechselnden Debug-Schlüssel signiert und jedes Update braucht eine Neuinstallation.

## Rücksicht aufs Original

- Keine Releases unter dem Namen „Plezy“, keine Plezy-Dienste (`bugs.plezy.app`, `ice.plezy.app`) bei Weitergabe,
  siehe [TRADEMARKS.md](TRADEMARKS.md). Sentry und Update-Prüfung bleiben im Fork-Build aus.
- PRs ans Original: klein und gezielt, vorher offene Issues/PRs prüfen, Checks aus [CONTRIBUTING.md](CONTRIBUTING.md)
  laufen lassen, eingesetztes KI-Modell in der PR-Beschreibung nennen.
