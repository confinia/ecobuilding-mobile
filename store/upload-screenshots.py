import hashlib, json, pathlib, subprocess, sys, urllib.request

SP = pathlib.Path("/private/tmp/claude-501/-Users-clement-igonet-project-ecobuilding/21660515-c1ca-47a4-8656-e76808345fc1/scratchpad")
SET = (SP / "store/setid.txt").read_text().strip()
DOSSIER = sys.argv[1] if len(sys.argv) > 1 else "captures"
BASE = "https://api.appstoreconnect.apple.com/v1"

def token():
    return subprocess.run([str(SP / "asc.sh")], capture_output=True, text=True).stdout.strip()

def call(method, url, body=None, headers=None, raw=None):
    h = {"Authorization": f"Bearer {token()}"}
    if headers:
        h.update(headers)
    data = raw if raw is not None else (json.dumps(body).encode() if body else None)
    if body is not None and raw is None:
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    with urllib.request.urlopen(req) as r:
        payload = r.read()
        return json.loads(payload) if payload and r.headers.get("content-type", "").startswith("application/json") else {}

for order, name in enumerate(["1-fiche", "2-carte-3d", "3-satellite-cadastre"]):
    path = SP / DOSSIER / f"{name}.png"
    blob = path.read_bytes()
    created = call("POST", f"{BASE}/appScreenshots", {
        "data": {"type": "appScreenshots",
                 "attributes": {"fileSize": len(blob), "fileName": f"{name}.png"},
                 "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": SET}}}}})
    sid = created["data"]["id"]
    for op in created["data"]["attributes"]["uploadOperations"]:
        chunk = blob[op["offset"]:op["offset"] + op["length"]]
        headers = {h["name"]: h["value"] for h in op["requestHeaders"]}
        req = urllib.request.Request(op["url"], data=chunk, headers=headers, method=op["method"])
        urllib.request.urlopen(req).read()
    done = call("PATCH", f"{BASE}/appScreenshots/{sid}", {
        "data": {"type": "appScreenshots", "id": sid,
                 "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(blob).hexdigest()}}})
    state = done["data"]["attributes"]["assetDeliveryState"]["state"]
    print(f"  {name:22s} {len(blob):>9} octets  ->  {state}")
