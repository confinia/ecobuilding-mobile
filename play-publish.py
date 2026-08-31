#!/usr/bin/env python3
"""Publish an Android App Bundle to a Play track, without the console.

Every release step Google exposes to machines is here: upload the bundle,
attach it to a track, write the release notes, commit. What stays manual is
what Google keeps manual — creating the app record, the data-safety form, the
content rating, and the individual tester e-mails (the API only accepts Google
Groups for those).

Credentials: a service-account key at ~/.config/playconsole/service-account.json,
whose e-mail must be invited under Play Console > Users and permissions.
The key is never committed: this repository is public.

    python3 mobile/play-publish.py --track internal
    python3 mobile/play-publish.py --track alpha --notes "..." --rollout
"""
import argparse
import json
import os
import pathlib
import sys

from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload

PACKAGE = "io.confinia.ecobuilding"
CLE = pathlib.Path(os.path.expanduser("~/.config/playconsole/service-account.json"))
AAB = (pathlib.Path(__file__).parent
       / "android/app/build/outputs/bundle/release/app-release.aab")
# Play names its tracks: "internal", "alpha" (= closed testing), "beta"
# (= open testing), "production".
NOTES = ("Première version. Carte 3D des bâtiments de France, fiche PDF par "
         "bâtiment et par logement diagnostiqué.")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--track", default="internal",
                   choices=["internal", "alpha", "beta", "production"])
    p.add_argument("--notes", default=NOTES)
    p.add_argument("--aab", default=str(AAB))
    p.add_argument("--rollout", action="store_true",
                   help="set the release live; otherwise it is left as a draft")
    a = p.parse_args()

    if not CLE.exists():
        print(f"missing service-account key: {CLE}", file=sys.stderr)
        return 2
    aab = pathlib.Path(a.aab)
    if not aab.exists():
        print(f"missing bundle: {aab}\nbuild it with: "
              f"cd mobile/android && ./gradlew bundleRelease", file=sys.stderr)
        return 2

    creds = service_account.Credentials.from_service_account_file(
        str(CLE), scopes=["https://www.googleapis.com/auth/androidpublisher"])
    api = build("androidpublisher", "v3", credentials=creds, cache_discovery=False)
    edits = api.edits()

    edit = edits.insert(body={}, packageName=PACKAGE).execute()["id"]
    print(f"edit {edit} opened")

    bundle = edits.bundles().upload(
        packageName=PACKAGE, editId=edit,
        media_body=MediaFileUpload(str(aab), mimetype="application/octet-stream",
                                   resumable=True)).execute()
    code = bundle["versionCode"]
    print(f"bundle uploaded: versionCode {code} ({aab.stat().st_size // 1024 // 1024} MB)")

    edits.tracks().update(
        packageName=PACKAGE, editId=edit, track=a.track,
        body={"releases": [{
            "versionCodes": [str(code)],
            "status": "completed" if a.rollout else "draft",
            "releaseNotes": [{"language": "fr-FR", "text": a.notes}],
        }]}).execute()
    print(f"attached to track '{a.track}' as "
          f"{'a live release' if a.rollout else 'a draft'}")

    edits.commit(packageName=PACKAGE, editId=edit).execute()
    print("edit committed — visible in Play Console")
    return 0


if __name__ == "__main__":
    sys.exit(main())
