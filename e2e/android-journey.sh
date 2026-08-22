#!/usr/bin/env bash
# Parcours de bout en bout sur l'émulateur Android.
#
# Pendant exact de ios/EcoBuilding/UITests/JourneyTests.swift : mêmes étapes,
# même ordre, mêmes attentes — pour que les deux écrans se comparent l'un à
# côté de l'autre.
#
#   ./e2e/android-journey.sh [dossier-de-captures]
#
# N'écrit rien d'autre que ses captures, et ne touche à aucun serveur.
set -euo pipefail

ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"
PKG=io.confinia.ecobuilding
SHOTS="${1:-/tmp/eco-journey}"
# Un pavillon de plain-pied sans DPE publié : le cas ordinaire, et justement
# celui qui faisait tomber l'application.
QUERY="16 impasse jean jaures saint vallier"
# L'assertion porte sur la COMMUNE : « 16 impasse jean jaures » seul ramène
# d'abord Chevilly-Larue, et le parcours validait un tout autre bâtiment.
MATCH="Saint-Vallier"
LON=4.335445
LAT=46.643645

mkdir -p "$SHOTS"

say()  { printf '\033[36m· %s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*"; exit 1; }

dump() {
  "$ADB" shell uiautomator dump /sdcard/e2e.xml >/dev/null 2>&1 || true
  "$ADB" shell cat /sdcard/e2e.xml 2>/dev/null
}

# Attend qu'un texte apparaisse et renvoie le centre de son cadre.
# On attend le RÉSEAU (adresses, neuf sources ouvertes), pas une animation :
# les délais sont donc généreux et l'attente est active.
await() {
  local needle="$1" limit="${2:-30}" i=0
  while [ "$i" -lt "$limit" ]; do
    local found
    found=$(locate "$needle")
    [ -n "$found" ] && { echo "$found"; return 0; }
    sleep 2; i=$((i + 1))
  done
  return 1
}

# Cherche un libellé et renvoie le centre de son cadre.
#
# On regarde `text` ET `content-desc` : une croix de fermeture n'a pas de texte,
# seulement une description d'accessibilité — et le parcours cherchait en vain
# un bouton pourtant bien présent à l'écran.
locate() {
  dump | python3 -c "
import sys, re
s = sys.stdin.read()
needle = sys.argv[1].lower()
for m in re.finditer(r'<node[^>]*>', s):
    node = m.group(0)
    labels = re.findall(r'(?:text|content-desc)=\"([^\"]*)\"', node)
    if not any(needle in l.lower() for l in labels if l):
        continue
    b = re.search(r'bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', node)
    if b:
        print((int(b.group(1)) + int(b.group(3))) // 2,
              (int(b.group(2)) + int(b.group(4))) // 2)
        break
" "$1"
}

# Appuie sur un texte, PUIS vérifie qu'un second texte est apparu — et
# recommence si besoin.
#
# Un appui isolé ne prouve rien : l'appui envoyé juste après un relevé de
# coordonnées tombait dans le vide quand la liste des suggestions se
# reconstruisait entre les deux, et le parcours continuait comme si de rien
# n'était. La confirmation doit être propre à l'écran ATTENDU : « Saint-Vallier »
# figure aussi dans les suggestions, « ÉNERGIE » non.
tap_until() {
  local target="$1" confirm="$2" limit="${3:-4}" i=0
  while [ "$i" -lt "$limit" ]; do
    local at
    at=$(locate "$target")
    if [ -n "$at" ]; then
      # shellcheck disable=SC2086
      "$ADB" shell input tap $at
    fi
    if await "$confirm" 8 >/dev/null; then return 0; fi
    i=$((i + 1))
  done
  return 1
}

# Saisit l'adresse LETTRE PAR LETTRE, puis vérifie ce qui est réellement entré.
#
# `adb shell input text` injecte les caractères plus vite que le champ Compose
# ne les enregistre : « jean jaures » arrivait en « je jau », et le parcours
# cherchait une adresse qui n'existe pas. Envoyer la chaîne entière en un seul
# appel ne change rien — c'est la cadence qui est en cause, pas le découpage.
type_query() {
  local attempt=0
  while [ "$attempt" -lt 3 ]; do
    local i=0 char
    while [ "$i" -lt "${#QUERY}" ]; do
      char="${QUERY:$i:1}"
      if [ "$char" = " " ]; then
        "$ADB" shell input keyevent 62 >/dev/null
      else
        "$ADB" shell input text "$char" >/dev/null
      fi
      i=$((i + 1))
    done
    sleep 2
    # Le champ doit contenir la fin de la requête : c'est elle qui distingue
    # Saint-Vallier des innombrables « impasse Jean Jaurès » de France.
    if dump | grep -q "vallier"; then return 0; fi
    say "saisie incomplète, on efface et on recommence"
    local clear
    clear=$(locate "Effacer")
    # shellcheck disable=SC2086
    [ -n "$clear" ] && "$ADB" shell input tap $clear
    sleep 1
    attempt=$((attempt + 1))
  done
  fail "impossible de saisir l'adresse"
}

shot() { "$ADB" exec-out screencap -p > "$SHOTS/$1.png"; }

say "démarrage à froid"
"$ADB" shell am force-stop "$PKG"
"$ADB" logcat -c
"$ADB" shell am start -n "$PKG/.MainActivity" >/dev/null
FIELD=$(await "Adresse en France" 20) || fail "champ de recherche absent"
# Le point GPS de l'émulateur est ponctuel : rejoué une fois l'app à l'écoute.
"$ADB" emu geo fix "$LON" "$LAT" >/dev/null 2>&1 || true

say "recherche d'adresse"
# shellcheck disable=SC2086
"$ADB" shell input tap $FIELD
sleep 2
type_query

await "$MATCH" 25 >/dev/null || fail "aucune suggestion"
shot 1-suggestions

say "fiche du bâtiment"
# « ÉNERGIE » n'existe que dans la fiche : c'est la preuve qu'elle est ouverte.
tap_until "$MATCH" "ÉNERGIE" || fail "la fiche ne s'est pas ouverte"
# Le bouton PDF doit être là SANS faire défiler : c'est l'objet vendu.
await "Obtenir la fiche PDF" 25 >/dev/null || fail "bouton PDF hors d'atteinte"
shot 2-fiche

say "génération de la fiche PDF (10 à 45 s)"
tap_until "Obtenir la fiche PDF" "Fermer la fiche" 12 \
  || fail "la fiche PDF ne s'est pas ouverte"
shot 3-pdf

say "retour à la carte"
tap_until "Fermer la fiche" "Adresse en France" || fail "impossible de revenir à la carte"
shot 4-carte

if "$ADB" logcat -d | grep -qE "FATAL EXCEPTION"; then
  fail "plantage relevé dans le journal"
fi

printf '\033[32m✓ parcours complet — captures dans %s\033[0m\n' "$SHOTS"
