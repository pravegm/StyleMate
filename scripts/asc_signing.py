"""App Store signing assets for one TestFlight run, made through the App Store Connect API.

Xcode's automatic signing can't be used from CI for StyleMate: it lists the team's iCloud containers,
and Apple answers that request from an API key with 401 NOT_AUTHORIZED (an app without iCloud, like
the Duo games, never asks). So .github/workflows/testflight.yml signs manually instead:

  create   makes a private key and an Apple Distribution certificate, imports both into a
           temporary keychain, and creates an App Store profile for com.stylemates.StyleMate
           (its iCloud container comes from the App ID on the portal). Writes CERT_ID,
           PROFILE_ID and PROFILE_NAME to $GITHUB_ENV.
  cleanup  deletes that profile and revokes that certificate, so certificates never pile up
           (Apple allows only a few). Builds already uploaded are not affected.
"""

import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com"
BUNDLE = "com.stylemates.StyleMate"
TMP = os.environ.get("RUNNER_TEMP", "/tmp")
RUN = os.environ.get("GITHUB_RUN_NUMBER", "local")


def token():
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        os.environ["ASC_PRIVATE_KEY"], algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {path} -> HTTP {e.code}: {e.read().decode()[:600]}")


def sh(*args):
    subprocess.run(args, check=True)


def env_out(**values):
    with open(os.environ["GITHUB_ENV"], "a") as f:
        for k, v in values.items():
            f.write(f"{k}={v}\n")


def create():
    key, csr = f"{TMP}/dist.key", f"{TMP}/dist.csr"
    sh("openssl", "genrsa", "-out", key, "2048")
    sh("openssl", "req", "-new", "-key", key, "-out", csr, "-subj", f"/CN=StyleMate CI {RUN}/")
    cert = call("POST", "/v1/certificates", {"data": {"type": "certificates", "attributes": {
        "certificateType": "DISTRIBUTION", "csrContent": open(csr).read()}}})["data"]
    cert_id = cert["id"]
    env_out(CERT_ID=cert_id)
    print(f"Certificate {cert_id} ({cert['attributes'].get('name')}), expires {cert['attributes'].get('expirationDate')}")

    der, pem, p12 = f"{TMP}/dist.cer", f"{TMP}/dist.pem", f"{TMP}/dist.p12"
    open(der, "wb").write(base64.b64decode(cert["attributes"]["certificateContent"]))
    sh("openssl", "x509", "-inform", "DER", "-in", der, "-out", pem)
    pw = base64.b16encode(os.urandom(12)).decode()
    sh("openssl", "pkcs12", "-export", "-legacy", "-inkey", key, "-in", pem, "-out", p12, "-passout", "pass:" + pw)
    kc = f"{TMP}/signing.keychain-db"
    sh("security", "create-keychain", "-p", pw, kc)
    sh("security", "set-keychain-settings", "-lut", "21600", kc)
    sh("security", "unlock-keychain", "-p", pw, kc)
    sh("security", "import", p12, "-k", kc, "-P", pw, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
    sh("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", pw, kc)
    existing = subprocess.run(["security", "list-keychains", "-d", "user"], capture_output=True, text=True).stdout
    sh("security", "list-keychains", "-d", "user", "-s", kc, *[k.strip().strip('"') for k in existing.split()])
    for f in (key, p12):
        os.remove(f)

    bundles = call("GET", f"/v1/bundleIds?filter[identifier]={BUNDLE}&limit=20")["data"]
    bundle = next(b for b in bundles if b["attributes"]["identifier"] == BUNDLE)
    name = f"StyleMate CI {RUN}"
    profile = call("POST", "/v1/profiles", {"data": {
        "type": "profiles", "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                          "certificates": {"data": [{"type": "certificates", "id": cert_id}]}}}})["data"]
    env_out(PROFILE_ID=profile["id"], PROFILE_NAME=name)
    content = base64.b64decode(profile["attributes"]["profileContent"])
    uuid = profile["attributes"]["uuid"]
    for d in ("Library/MobileDevice/Provisioning Profiles", "Library/Developer/Xcode/UserData/Provisioning Profiles"):
        path = os.path.join(os.path.expanduser("~"), d)
        os.makedirs(path, exist_ok=True)
        open(os.path.join(path, uuid + ".mobileprovision"), "wb").write(content)
    print(f"Profile '{name}' ({uuid})")
    plist = subprocess.run(["security", "cms", "-D", "-i", os.path.join(path, uuid + ".mobileprovision")],
                           capture_output=True, text=True).stdout
    ents = plist[plist.find("<key>Entitlements</key>"):]
    ents = ents[:ents.find("</dict>") + 7]
    print(ents)
    if "iCloud.com.stylemates.StyleMate" not in ents:
        raise SystemExit("::error::The profile has no iCloud container: tick iCloud.com.stylemates.StyleMate "
                         "on the App ID (docs/TESTFLIGHT.md step 1)")


def cleanup():
    if os.environ.get("PROFILE_ID"):
        call("DELETE", f"/v1/profiles/{os.environ['PROFILE_ID']}")
        print("Deleted the run's profile")
    if os.environ.get("CERT_ID"):
        call("DELETE", f"/v1/certificates/{os.environ['CERT_ID']}")
        print("Revoked the run's certificate")


{"create": create, "cleanup": cleanup}[sys.argv[1]]()
