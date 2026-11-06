"""Read-only look at what App Store Connect already holds for StyleMate.

Run by .github/workflows/asc-check.yml with the same API key the TestFlight upload uses. It only
sends GET requests, and it prints only records whose name or identifier mentions "style" (the repo is
public, so its Actions logs are too).
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com"
EXPECTED_BUNDLE = "com.stylemates.StyleMate"
EXPECTED_PRODUCTS = {
    "com.stylemates.StyleMate.premium.annual",
    "com.stylemates.StyleMate.premium.monthly",
}


def token():
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        os.environ["ASC_PRIVATE_KEY"],
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


TOKEN = token()


def get(path, **params):
    """GET every page of a list endpoint; returns (data, included)."""
    url = API + path + ("?" + urllib.parse.urlencode(params) if params else "")
    data, included = [], []
    while url:
        req = urllib.request.Request(url, headers={"Authorization": "Bearer " + TOKEN})
        try:
            with urllib.request.urlopen(req) as r:
                body = json.load(r)
        except urllib.error.HTTPError as e:
            print(f"  ! {path}: HTTP {e.code} {e.read().decode()[:300]}")
            return [], []
        page = body.get("data", [])
        data.extend(page if isinstance(page, list) else [page])
        included.extend(body.get("included", []))
        url = body.get("links", {}).get("next")
    return data, included


def mentions_style(*values):
    return any("style" in (v or "").lower() for v in values)


out = []


def say(line=""):
    print(line)
    out.append(line)


say("## App Store Connect: what already exists for StyleMate")
say()

# App IDs (Certificates, Identifiers & Profiles) and their capabilities.
bundles, caps = get("/v1/bundleIds", limit=200, include="bundleIdCapabilities")
caps_by_id = {c["id"]: c for c in caps if c["type"] == "bundleIdCapabilities"}
say("### App IDs")
found_expected_bundle = False
for b in bundles:
    a = b["attributes"]
    if not mentions_style(a.get("identifier"), a.get("name")):
        continue
    found_expected_bundle |= a.get("identifier") == EXPECTED_BUNDLE
    rel = b.get("relationships", {}).get("bundleIdCapabilities", {}).get("data", [])
    names = sorted(caps_by_id[r["id"]]["attributes"].get("capabilityType", "?") for r in rel if r["id"] in caps_by_id)
    say(f"- `{a.get('identifier')}` ({a.get('name')}, {a.get('platform')}, team prefix {a.get('seedId')})")
    say(f"  - capabilities: {', '.join(names) or 'none'}")
if not found_expected_bundle:
    say(f"- (no App ID `{EXPECTED_BUNDLE}` yet)")
say()

# App records.
apps, _ = get("/v1/apps", limit=200)
mine = [x for x in apps if mentions_style(x["attributes"].get("name"), x["attributes"].get("bundleId"))]
say("### App records")
if not mine:
    say("- (no app record mentions StyleMate)")
for app in mine:
    a = app["attributes"]
    say(f"- **{a.get('name')}**: bundle `{a.get('bundleId')}`, SKU `{a.get('sku')}`, "
        f"language {a.get('primaryLocale')}, Apple ID {app['id']}")

    versions, _ = get(f"/v1/apps/{app['id']}/appStoreVersions", limit=10)
    for v in versions:
        va = v["attributes"]
        say(f"  - version {va.get('versionString')} ({va.get('platform')}): {va.get('appStoreState')}")

    builds, _ = get("/v1/builds", **{"filter[app]": app["id"], "limit": 10, "sort": "-uploadedDate"})
    if builds:
        top = max(int(b["attributes"].get("version") or 0) for b in builds if (b["attributes"].get("version") or "0").isdigit())
        say(f"  - builds: {len(builds)} recent, highest build number {top}")
        for b in builds[:3]:
            ba = b["attributes"]
            say(f"    - build {ba.get('version')}: {ba.get('processingState')}, uploaded {ba.get('uploadedDate')}, expired {ba.get('expired')}")
    else:
        say("  - builds: none")

    groups, _ = get(f"/v1/apps/{app['id']}/betaGroups", limit=50)
    for g in groups:
        ga = g["attributes"]
        say(f"  - TestFlight group: {ga.get('name')} ({'internal' if ga.get('isInternalGroup') else 'external'})")

    subgroups, subs = get(f"/v1/apps/{app['id']}/subscriptionGroups", limit=50, include="subscriptions")
    subs_by_id = {s["id"]: s for s in subs if s["type"] == "subscriptions"}
    seen = set()
    for g in subgroups:
        say(f"  - subscription group: {g['attributes'].get('referenceName')}")
        for r in g.get("relationships", {}).get("subscriptions", {}).get("data", []):
            s = subs_by_id.get(r["id"])
            if not s:
                continue
            sa = s["attributes"]
            seen.add(sa.get("productId"))
            say(f"    - `{sa.get('productId')}` ({sa.get('name')}): {sa.get('subscriptionPeriod')}, "
                f"level {sa.get('groupLevel')}, {sa.get('state')}")
    if not subgroups:
        say("  - subscription groups: none")

    iaps, _ = get(f"/v1/apps/{app['id']}/inAppPurchasesV2", limit=50)
    for p in iaps:
        pa = p["attributes"]
        say(f"  - in-app purchase `{pa.get('productId')}` ({pa.get('name')}, {pa.get('inAppPurchaseType')}): {pa.get('state')}")

    missing = sorted(EXPECTED_PRODUCTS - seen)
    if missing:
        say(f"  - products the app expects but ASC lacks: {', '.join(missing)}")
say()

summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    with open(summary, "a") as f:
        f.write("\n".join(out) + "\n")
sys.exit(0)
