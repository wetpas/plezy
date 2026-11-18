#!/usr/bin/env bash
# Fork-Branding für wetpas/plezy – läuft NUR im CI-Build, nie auf einem Branch fürs Original.
#
#   bash scripts/fork/branding.sh <android|linux|windows>
#
# Setzt den sichtbaren App-Namen „Plezy Fork“ und eine eigene App-ID, damit die Fork-App
# neben der offiziellen Plezy installiert werden kann und eigene Daten hat. Die Dateien des
# Originals bleiben im Repo unverändert (keine Merge-Konflikte mit upstream). Erwartet ein
# bereits ausgeführtes `flutter pub get`. Bricht ab, wenn upstream eine der Stellen geändert hat.
set -euo pipefail

PLATFORM="${1:?Plattform fehlt: android|linux|windows}"
FORK_APP_ID="${FORK_APP_ID:-com.edde746.plezy.fork}"
FORK_APP_LABEL="${FORK_APP_LABEL:-Plezy Fork}"
cd "$(dirname "$0")/../.."

swap() { # Datei, alt, neu
  grep -qF -- "$2" "$1" || { echo "::error file=$1::'$2' nicht gefunden – upstream hat sich geändert"; exit 1; }
  sed -i "s|$2|$3|g" "$1"
}

# --- App-Name in der App (Anmeldung, Über, Log-Kopf, Fenstertitel aus Flutter) ---------
python3 -I - "$FORK_APP_LABEL" lib/i18n/*.i18n.json <<'PY'
import json, sys
label, files = sys.argv[1], sys.argv[2:]
changed = done = 0
for path in files:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    app = data.get("app")
    if not isinstance(app, dict):
        continue
    if app.get("title") == label:
        done += 1  # schon gesetzt (zweiter Aufruf im selben Checkout)
    elif app.get("title") == "Plezy":
        app["title"] = label
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        changed += 1
if changed + done == 0:
    sys.exit("::error::app.title 'Plezy' in keiner Sprachdatei gefunden – upstream hat sich geändert")
print(f"app.title -> {label} in {changed} Sprachdateien ({done} schon gesetzt)")
PY
dart run slang >/dev/null

# --- Plattform ------------------------------------------------------------------------
case "$PLATFORM" in
  android)
    swap android/app/build.gradle.kts 'applicationId = "com.edde746.plezy"' "applicationId = \"$FORK_APP_ID\""
    swap android/app/src/main/AndroidManifest.xml 'android:label="Plezy"' "android:label=\"$FORK_APP_LABEL\""
    # Feste Content-Provider-Namen: zwei Apps mit gleichem Namen lassen sich nicht nebeneinander installieren.
    swap android/app/src/main/AndroidManifest.xml '"com.edde746.plezy.fileprovider"' "\"$FORK_APP_ID.fileprovider\""
    swap android/app/src/main/AndroidManifest.xml '"com.edde746.plezy.systemshelf.artwork"' "\"$FORK_APP_ID.systemshelf.artwork\""
    swap android/app/src/main/kotlin/com/edde746/plezy/ExternalPlayerChannel.kt '"com.edde746.plezy.fileprovider"' "\"$FORK_APP_ID.fileprovider\""
    swap android/app/src/main/kotlin/com/edde746/plezy/watchnext/SystemShelfArtworkProvider.kt '"com.edde746.plezy.systemshelf.artwork"' "\"$FORK_APP_ID.systemshelf.artwork\""
    if grep -rnE '"com\.edde746\.plezy\.(fileprovider|systemshelf\.artwork)"' android/app/src/main; then
      echo "::error::Original-Provider-Name noch vorhanden – App würde mit der offiziellen Plezy kollidieren"
      exit 1
    fi
    ;;
  linux)
    swap linux/CMakeLists.txt 'set(APPLICATION_ID "com.edde746.plezy")' "set(APPLICATION_ID \"$FORK_APP_ID\")"
    swap linux/runner/my_application.cc '"Plezy"' "\"$FORK_APP_LABEL\""
    swap linux/packaging/com.edde746.plezy.desktop 'Name=Plezy' "Name=$FORK_APP_LABEL"
    ;;
  windows)
    # Fenstertitel; FindWindow sucht eine laufende Instanz über denselben Titel. Eigener
    # Einzelinstanz-Mutex, sonst beendet sich der Fork, solange die offizielle Plezy läuft.
    swap windows/runner/main.cpp 'L"Plezy"' "L\"$FORK_APP_LABEL\""
    swap windows/runner/main.cpp 'L"com.edde746.Plezy.SingleInstance"' 'L"com.edde746.Plezy.Fork.SingleInstance"'
    ;;
  *)
    echo "Unbekannte Plattform: $PLATFORM" >&2
    exit 1
    ;;
esac
echo "Fork-Branding ($PLATFORM) gesetzt: $FORK_APP_LABEL / $FORK_APP_ID"
