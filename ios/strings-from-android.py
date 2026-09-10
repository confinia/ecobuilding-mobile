#!/usr/bin/env python3
"""Engendre les tables iOS `fr.lproj` / `en.lproj` depuis les ressources Android.

Les chaînes se DÉCIDENT une fois, dans `android/app/src/main/res/values*/strings.xml`
(voir Strings.swift). Ce script les recopie vers `ios/EcoBuilding/Resources/<lang>.lproj/
Localizable.strings`, avec les seules différences de format :

    %1$s   -> %@        %1$d   -> %lld       (un seul argument : forme courte)
    %2$s   -> %2$@      %2$d   -> %2$lld     (plusieurs arguments : positionnels)
    \\'    -> '         \\"    -> \\"        &amp; &lt; &gt; -> & < >

`app_name` reste côté Android (l'iOS le tient d'Info.plist). Lancer depuis `mobile/` :

    python3 ios/strings-from-android.py
"""
import html
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TABLES = {"fr": "values", "en": "values-en"}
SKIP = {"app_name"}


def android_strings(path: pathlib.Path) -> dict[str, str]:
    out = {}
    for m in re.finditer(r'<string name="([^"]+)">(.*?)</string>', path.read_text(), re.S):
        key, raw = m.group(1), m.group(2)
        if key in SKIP:
            continue
        out[key] = html.unescape(raw).replace("\\'", "'").replace('\\"', '"')
    return out


def to_ios(text: str) -> str:
    positional = len(re.findall(r"%\d+\$", text)) > 1
    def sub(m):
        idx, kind = m.group(1), m.group(2)
        ios = {"s": "@", "d": "lld"}[kind]
        return f"%{idx}${ios}" if positional else f"%{ios}"
    text = re.sub(r"%(\d+)\$([sd])", sub, text)
    return text.replace('"', '\\"')


def main() -> int:
    for lang, folder in TABLES.items():
        src = ROOT / "android/app/src/main/res" / folder / "strings.xml"
        dst = ROOT / "ios/EcoBuilding/Resources" / f"{lang}.lproj" / "Localizable.strings"
        lines = [f"/* EcoBuilding — {lang}. Mêmes clés que res/{folder}/strings.xml",
                 "   côté Android : une seule décision de vocabulaire pour les deux apps.",
                 "   ENGENDRÉ par ios/strings-from-android.py : ne pas éditer à la main. */"]
        strings = android_strings(src)
        for key in sorted(strings):
            lines.append(f'"{key}" = "{to_ios(strings[key])}";')
        dst.write_text("\n".join(lines) + "\n")
        print(f"{dst.relative_to(ROOT)}: {len(strings)} chaînes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
