"""Creates StyleMate Premium in App Store Connect, or finishes it if a part already exists.

Run by .github/workflows/asc-subscriptions.yml with the TestFlight API key. Safe to re-run: every
step looks first and only creates what is missing. Sets up (docs/TESTFLIGHT.md section 6b):
  - subscription group "StyleMate Premium" with its en-GB display name
  - Premium Annual  com.stylemates.StyleMate.premium.annual   1 year   GBP 24.99  level 1  1-week free trial
  - Premium Monthly com.stylemates.StyleMate.premium.monthly  1 month  GBP 3.99   level 2
  - en-GB names and descriptions, availability in every territory, and the UK price with Apple's
    equalised price in every other territory
The review screenshot is left to the founder (App Store Connect asks for it only at submission).
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
BUNDLE = "com.stylemates.StyleMate"
GROUP = "StyleMate Premium"
LOCALE = "en-GB"
REVIEW_NOTE = (
    "StyleMate is free for the first 50 wardrobe items; StyleMate Premium (auto-renewable, monthly or "
    "yearly) removes the limit. Every other feature is free. Sign in with your own Apple ID. To reach the "
    "paywall quickly: on the welcome screen tap \"Try with sample photos\", sign in, then open Profile > "
    "StyleMate Premium > \"See Premium plans\"."
)
PLANS = [
    {"productId": BUNDLE + ".premium.annual", "name": "Premium Annual", "period": "ONE_YEAR",
     "level": 1, "gbp": "24.99", "description": "Unlimited wardrobe, billed yearly", "trial": True},
    {"productId": BUNDLE + ".premium.monthly", "name": "Premium Monthly", "period": "ONE_MONTH",
     "level": 2, "gbp": "3.99", "description": "Unlimited wardrobe, billed monthly", "trial": False},
]

_token = {"value": None, "at": 0}


def token():
    now = int(time.time())
    if not _token["value"] or now - _token["at"] > 900:
        _token["value"] = jwt.encode(
            {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
            os.environ["ASC_PRIVATE_KEY"], algorithm="ES256",
            headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})
        _token["at"] = now
    return _token["value"]


def call(method, path, body=None, ok_conflict=False, ok_missing=False):
    url = path if path.startswith("http") else API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            text = e.read().decode()
            if e.code == 429 or e.code >= 500:
                time.sleep(5 * (attempt + 1))
                continue
            if ok_conflict and e.code == 409:
                print(f"    (skipped: {text[:200]})")
                return {"conflict": text}
            if ok_missing and e.code == 404:
                return {}
            raise SystemExit(f"{method} {path} -> HTTP {e.code}: {text[:800]}")
    raise SystemExit(f"{method} {path} kept failing")


def get_all(path, **params):
    url = API + path + ("?" + urllib.parse.urlencode(params) if params else "")
    data, included = [], []
    while url:
        body = call("GET", url)
        page = body.get("data", [])
        data.extend(page if isinstance(page, list) else [page])
        included.extend(body.get("included", []))
        url = body.get("links", {}).get("next")
    return data, included


def rel(kind, ident):
    return {"data": {"type": kind, "id": ident}}


def post(kind, attributes, relationships, ok_conflict=False):
    body = {"data": {"type": kind, "attributes": attributes, "relationships": relationships}}
    return call("POST", "/v1/" + kind, body, ok_conflict).get("data", {})


apps, _ = get_all("/v1/apps", **{"filter[bundleId]": BUNDLE})
if not apps:
    raise SystemExit(f"No app record for {BUNDLE}")
app_id = apps[0]["id"]
print(f"App {apps[0]['attributes']['name']} ({app_id})")

territories = [t["id"] for t in get_all("/v1/territories", limit=200)[0]]
print(f"{len(territories)} territories")

# Group and its display name.
groups, _ = get_all(f"/v1/apps/{app_id}/subscriptionGroups", limit=50)
group = next((g for g in groups if g["attributes"]["referenceName"] == GROUP), None)
if group:
    print(f"Group '{GROUP}' exists")
else:
    group = post("subscriptionGroups", {"referenceName": GROUP}, {"app": rel("apps", app_id)})
    print(f"Created group '{GROUP}'")
glocs, _ = get_all(f"/v1/subscriptionGroups/{group['id']}/subscriptionGroupLocalizations", limit=50)
if not any(l["attributes"]["locale"] == LOCALE for l in glocs):
    post("subscriptionGroupLocalizations", {"name": GROUP, "locale": LOCALE},
         {"subscriptionGroup": rel("subscriptionGroups", group["id"])})
    print("  added group display name")

existing, _ = get_all(f"/v1/subscriptionGroups/{group['id']}/subscriptions", limit=50)
by_product = {s["attributes"]["productId"]: s for s in existing}

for plan in PLANS:
    sub = by_product.get(plan["productId"])
    if sub:
        print(f"{plan['name']} exists ({sub['attributes'].get('state')})")
    else:
        sub = post("subscriptions", {
            "name": plan["name"], "productId": plan["productId"], "subscriptionPeriod": plan["period"],
            "groupLevel": plan["level"], "familySharable": False, "reviewNote": REVIEW_NOTE,
        }, {"group": rel("subscriptionGroups", group["id"])})
        print(f"Created {plan['name']}")
    sid = sub["id"]

    locs, _ = get_all(f"/v1/subscriptions/{sid}/subscriptionLocalizations", limit=50)
    if not any(l["attributes"]["locale"] == LOCALE for l in locs):
        post("subscriptionLocalizations", {"name": plan["name"], "locale": LOCALE,
                                           "description": plan["description"]},
             {"subscription": rel("subscriptions", sid)})
        print("  added name and description")

    if not call("GET", f"/v1/subscriptions/{sid}/subscriptionAvailability", ok_missing=True).get("data"):
        post("subscriptionAvailabilities", {"availableInNewTerritories": True}, {
            "subscription": rel("subscriptions", sid),
            "availableTerritories": {"data": [{"type": "territories", "id": t} for t in territories]},
        })
        print(f"  available in {len(territories)} territories")

    prices, _ = get_all(f"/v1/subscriptions/{sid}/prices", limit=200, include="territory")
    priced = {p["relationships"]["territory"]["data"]["id"] for p in prices
              if p.get("relationships", {}).get("territory", {}).get("data")}
    if len(priced) < len(territories):
        points, _ = get_all(f"/v1/subscriptions/{sid}/pricePoints", **{"filter[territory]": "GBR", "limit": 200})
        uk = next((p for p in points if p["attributes"]["customerPrice"] == plan["gbp"]), None)
        if not uk:
            raise SystemExit(f"No GBP {plan['gbp']} price point for {plan['name']}")
        eq, _ = get_all(f"/v1/subscriptionPricePoints/{uk['id']}/equalizations", limit=200, include="territory")
        targets = [("GBR", uk["id"])] + [
            (p["relationships"]["territory"]["data"]["id"], p["id"]) for p in eq
            if p.get("relationships", {}).get("territory", {}).get("data")]
        added = 0
        for terr, point in targets:
            if terr in priced:
                continue
            post("subscriptionPrices", {"preserveCurrentPrice": False}, {
                "subscription": rel("subscriptions", sid),
                "subscriptionPricePoint": rel("subscriptionPricePoints", point),
                "territory": rel("territories", terr),
            }, ok_conflict=True)
            added += 1
        print(f"  prices: GBP {plan['gbp']} in the UK, equalised in {added} territories")
    else:
        print("  prices already set")

    if plan["trial"]:
        offers, _ = get_all(f"/v1/subscriptions/{sid}/introductoryOffers", limit=200, include="territory")
        offered = {o["relationships"]["territory"]["data"]["id"] for o in offers
                   if o.get("relationships", {}).get("territory", {}).get("data")}
        added = 0
        for terr in territories:
            if terr in offered:
                continue
            post("subscriptionIntroductoryOffers", {
                "duration": "ONE_WEEK", "offerMode": "FREE_TRIAL", "numberOfPeriods": 1,
            }, {"subscription": rel("subscriptions", sid), "territory": rel("territories", terr)},
                ok_conflict=True)
            added += 1
        print(f"  1-week free trial: added in {added} territories ({len(offered)} already had it)")

# Review screenshot (Apple shows "Missing Metadata" until each plan has one): the paywall from
# the latest green CI run, passed in as REVIEW_SCREENSHOT.
shot = os.environ.get("REVIEW_SCREENSHOT")
if shot and os.path.exists(shot):
    import hashlib
    data = open(shot, "rb").read()
    subs_now, _ = get_all(f"/v1/subscriptionGroups/{group['id']}/subscriptions", limit=50)
    for s in subs_now:
        sid = s["id"]
        if call("GET", f"/v1/subscriptions/{sid}/appStoreReviewScreenshot", ok_missing=True).get("data"):
            print(f"{s['attributes']['name']}: review screenshot already there")
            continue
        res = post("subscriptionAppStoreReviewScreenshots",
                   {"fileName": "paywall.png", "fileSize": len(data)},
                   {"subscription": rel("subscriptions", sid)})
        for op in res["attributes"]["uploadOperations"]:
            chunk = data[op["offset"]:op["offset"] + op["length"]]
            req = urllib.request.Request(op["url"], data=chunk, method=op["method"],
                                         headers={h["name"]: h["value"] for h in op.get("requestHeaders", [])})
            with urllib.request.urlopen(req):
                pass
        call("PATCH", f"/v1/subscriptionAppStoreReviewScreenshots/{res['id']}", {"data": {
            "type": "subscriptionAppStoreReviewScreenshots", "id": res["id"],
            "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
        print(f"{s['attributes']['name']}: review screenshot uploaded")
elif shot:
    print(f"No review screenshot at {shot}")

# Final state.
subs, _ = get_all(f"/v1/subscriptionGroups/{group['id']}/subscriptions", limit=50)
lines = ["## StyleMate Premium in App Store Connect", ""]
for s in subs:
    a = s["attributes"]
    lines.append(f"- `{a['productId']}` ({a['name']}): {a['subscriptionPeriod']}, level {a.get('groupLevel')}, {a.get('state')}")
print("\n".join(lines))
if os.environ.get("GITHUB_STEP_SUMMARY"):
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
        f.write("\n".join(lines) + "\n")
sys.exit(0)
