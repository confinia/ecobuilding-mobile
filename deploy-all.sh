#!/usr/bin/env bash
# Installe la version courante sur TOUS les appareils joignables.
#
#   ./deploy-all.sh
#
# Cibles, chacune facultative : émulateur Android, téléphone Android branché,
# simulateur iPhone démarré, iPhone physique (câble ou Wi-Fi). Un appareil
# absent est signalé, jamais bloquant — on ne rate pas un déploiement sur trois
# appareils parce que le quatrième dort.
#
# Android part en debug (installable sans signature de distribution), iOS en
# RELEASE pour l'appareil : la configuration Debug embarque des bibliothèques
# de débogage qui empêchent l'app de démarrer seule depuis l'écran d'accueil.
set -uo pipefail
cd "$(dirname "$0")"

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ADB="$ANDROID_HOME/platform-tools/adb"
PKG=io.confinia.ecobuilding
BUILD_DIR="${BUILD_DIR:-$PWD/.build}"
SIM_NAME="${SIM_NAME:-iPhone 17}"

ok()   { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
skip() { printf '\033[33m  – %s\033[0m\n' "$*"; }
ko()   { printf '\033[31m  ✗ %s\033[0m\n' "$*"; }
step() { printf '\033[36m%s\033[0m\n' "$*"; }

# --- Android ---------------------------------------------------------------
step "Android — compilation"
if (cd android && ./gradlew -q :app:assembleDebug >/dev/null 2>&1); then
  APK=android/app/build/outputs/apk/debug/app-debug.apk
  ok "APK $(du -h "$APK" | cut -f1)"
  step "Android — installation"
  DEVICES=$("$ADB" devices | awk '/\tdevice$/ {print $1}')
  if [ -z "$DEVICES" ]; then
    skip "aucun appareil Android joignable"
  else
    for d in $DEVICES; do
      if "$ADB" -s "$d" install -r "$APK" >/dev/null 2>&1; then
        "$ADB" -s "$d" shell am force-stop "$PKG" >/dev/null 2>&1
        "$ADB" -s "$d" shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1
        ok "$d"
      else
        ko "$d — installation refusée"
      fi
    done
  fi
else
  ko "compilation Android"
fi

# --- iPhone ----------------------------------------------------------------
build_ios() {   # $1 = destination, $2 = dossier de sortie
  (cd ios && xcodebuild -project EcoBuilding.xcodeproj -scheme EcoBuilding \
     -configuration "$3" -destination "$1" -derivedDataPath "$2" build) >/dev/null 2>&1
}

step "iPhone simulé — compilation"
BOOTED=$(xcrun simctl list devices booted 2>/dev/null | grep -oE "\(([0-9A-F-]{36})\)" | tr -d "()")
if [ -z "$BOOTED" ]; then
  skip "aucun simulateur démarré (xcrun simctl boot \"$SIM_NAME\")"
elif build_ios "platform=iOS Simulator,name=$SIM_NAME" "$BUILD_DIR/sim" Debug; then
  APP="$BUILD_DIR/sim/Build/Products/Debug-iphonesimulator/EcoBuilding.app"
  ok "compilé"
  step "iPhone simulé — installation"
  for u in $BOOTED; do
    if xcrun simctl install "$u" "$APP" >/dev/null 2>&1; then
      xcrun simctl terminate "$u" "$PKG" >/dev/null 2>&1
      xcrun simctl launch "$u" "$PKG" >/dev/null 2>&1
      ok "$u"
    else
      ko "$u"
    fi
  done
else
  ko "compilation simulateur"
fi

step "iPhone physique — compilation Release"
if ! command -v ios-deploy >/dev/null 2>&1; then
  skip "ios-deploy absent (brew install ios-deploy)"
elif ! ios-deploy -c -t 2 2>/dev/null | grep -q "Found"; then
  skip "aucun iPhone joignable"
elif build_ios "generic/platform=iOS" "$BUILD_DIR/dev" Release; then
  ok "compilé"
  step "iPhone physique — installation"
  ios-deploy --bundle "$BUILD_DIR/dev/Build/Products/Release-iphoneos/EcoBuilding.app" \
    >/dev/null 2>&1 && ok "installé" || ko "installation refusée"
else
  ko "compilation appareil"
fi
