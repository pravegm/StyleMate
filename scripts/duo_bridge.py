#!/usr/bin/env python3
"""Host side of StyleMate's iPhone Duo screenshot run (.github/workflows/duo.yml).

StyleMateUITests/DuoScreensTests navigates the app on the Duo simulator while the phone is closed (cover display,
where XCUITest taps are reliable) and calls this server at each screen. It owns the hinge and the screenshots:

  GET /shoot?name=<n>   phone closed on entry. Captures <n>-cover.png (cover display), opens to FLAT_ANGLE (180)
                        and captures <n>-flat.png (inner), folds to HALF_ANGLE (110) and captures <n>-half.png
                        (inner, half-open), closes to 0 and answers "ok". Each shot keeps both raw panels in raw/
                        and picks the lit one (a panel that is off captures black).
  GET /pose?name=<n>&to=cover|flat|half|closed
                        the same sequence one step at a time, so the test can check the inner display between
                        shots: moves the hinge (0 / FLAT_ANGLE / HALF_ANGLE / 0), captures <n>-<to>.png (not for
                        closed) and answers "ok fold=x,y,w,h window=WxH posture=p", the app's own latest DuoLayout
                        reading (DEBUG Documents/duo-log.txt; "fold=none" without one). The phone stays there.
  GET /hinge?angle=<a>  moves the hinge there (used to start closed).
  GET /ping

Hinge driver: the `hinge` CLI (github.com/artemnovichkov/hinge, `brew install artemnovichkov/tap/hinge`), which runs
a helper inside the simulator posting Device Hub's hinge HID event. Lessons kept from the sister Duo rigs (Squish
docs/DUO-CI.md, Glint ci/duo.sh): every call has a timeout, sets are retried, ~2.5 s settle after a move before a
shot, a slow sweep (not a jump) so the app sees a continuous fold, and NEVER `simctl io ... screenConfig` (it
crash-loops SpringBoard on the Duo). Display names differ between sources (LCD / LCD-1, primary / primary-1, 1 / 3):
probed once.

Env: UDID (required), OUT (duo-screens), PORT (8765), FLAT_ANGLE (180), HALF_ANGLE (110), SETTLE (2.5),
     SECS_PER_30 (1.5, sweep speed), BUNDLE (com.stylemates.StyleMate). Writes OUT/logs/bridge.txt,
     OUT/logs/posture.txt and OUT/MANIFEST.txt.
"""
import http.server
import os
import re
import struct
import subprocess
import sys
import threading
import time
import urllib.parse

UDID = os.environ["UDID"]
OUT = os.path.abspath(os.environ.get("OUT", "duo-screens"))
PORT = int(os.environ.get("PORT", "8765"))
FLAT = int(os.environ.get("FLAT_ANGLE", "180"))
HALF = int(os.environ.get("HALF_ANGLE", "110"))
SETTLE = float(os.environ.get("SETTLE", "2.5"))
SECS_PER_30 = float(os.environ.get("SECS_PER_30", "1.5"))
BUNDLE = os.environ.get("BUNDLE", "com.stylemates.StyleMate")

os.makedirs(os.path.join(OUT, "logs"), exist_ok=True)
os.makedirs(os.path.join(OUT, "raw"), exist_ok=True)
LOG = open(os.path.join(OUT, "logs", "bridge.txt"), "a", buffering=1)
POSTURE = open(os.path.join(OUT, "logs", "posture.txt"), "a", buffering=1)
MANIFEST = open(os.path.join(OUT, "MANIFEST.txt"), "a", buffering=1)
LOCK = threading.Lock()
STATE = {"angle": None, "inner": None, "cover": None, "failures": 0}

# Expected capture sizes (px): inner book 2853x2007, inner seated (portrait) 2007x2853, cover 1398x2034.
SIZES = {"inner": {(2853, 2007): "book", (2007, 2853): "seated"}, "cover": {(1398, 2034): "portrait", (2034, 1398): "landscape"}}


def log(*parts):
    line = time.strftime("%H:%M:%S ") + " ".join(str(p) for p in parts)
    print(line, flush=True)
    LOG.write(line + "\n")


def run(cmd, timeout):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "timeout after %ss" % timeout
    except FileNotFoundError as e:
        return 127, str(e)


# ---- hinge ----------------------------------------------------------------------------------------------

def hinge_set(angle):
    for attempt in range(3):
        rc, out = run(["hinge", "-d", UDID, "-t", "3", str(angle)], 25)
        if rc == 0:
            return True
        log("WARN hinge set %s attempt %d: rc=%d %s" % (angle, attempt + 1, rc, out[-300:]))
        time.sleep(1.5)
    STATE["failures"] += 1
    return False


def move(target):
    """A slow sweep from the current angle (so onHingeChange sees a continuous fold), a confirmed set, a settle."""
    current = STATE["angle"]
    if current is not None and current != target:
        secs = max(0.6, abs(target - current) / 30.0 * SECS_PER_30)
        rc, out = run(["hinge", "-d", UDID, "sweep", str(current), str(target), "%.2f" % secs], int(secs) + 20)
        if rc != 0:
            log("WARN sweep %s->%s rc=%d %s" % (current, target, rc, out[-300:]))
    ok = hinge_set(target)
    STATE["angle"] = target
    time.sleep(SETTLE)
    if current is not None and (current < 150 <= target or target == 0):
        time.sleep(SETTLE)  # display switches (cover <-> inner) take 1-2.5 s more
    log("hinge %s -> %s %s" % (current, target, "ok" if ok else "NOT CONFIRMED"))
    return ok


# ---- displays and screenshots -----------------------------------------------------------------------------

def screenshot(display, path):
    rc, out = run(["xcrun", "simctl", "io", UDID, "screenshot", "--display=%s" % display, path], 40)
    if rc != 0:
        log("screenshot %s failed rc=%d %s" % (display, rc, out[-200:]))
    return rc == 0 and os.path.exists(path)


def probe_displays():
    rc, out = run(["xcrun", "simctl", "io", UDID, "enumerate"], 30)
    log("simctl io enumerate rc=%d\n%s" % (rc, out[:3000]))
    probe = os.path.join(OUT, "raw", "_probe.png")
    for c in ["LCD-1", "primary-1", "3", "internal"]:
        if screenshot(c, probe):
            STATE["inner"] = c
            break
    for c in ["LCD", "primary", "1", "external"]:
        if c != STATE["inner"] and screenshot(c, probe):
            STATE["cover"] = c
            break
    if os.path.exists(probe):
        os.remove(probe)
    log("displays: inner=%s cover=%s" % (STATE["inner"], STATE["cover"]))


def png_size(path):
    try:
        with open(path, "rb") as f:
            head = f.read(24)
        return struct.unpack(">II", head[16:24])
    except Exception:
        return (0, 0)


def brightness(path):
    """Mean brightness 0-255 (sips scales to a 16x16 BMP); -1 on error."""
    bmp = path + ".bmp"
    rc, _ = run(["sips", "-z", "16", "16", "-s", "format", "bmp", path, "--out", bmp], 20)
    if rc != 0 or not os.path.exists(bmp):
        return -1
    try:
        b = open(bmp, "rb").read()
        off = struct.unpack_from("<I", b, 10)[0]
        w, h = struct.unpack_from("<ii", b, 18)
        step = struct.unpack_from("<H", b, 28)[0] // 8
        row = (w * step + 3) & ~3
        tot = n = 0
        for y in range(abs(h)):
            for x in range(w):
                p = off + y * row + x * step
                tot += b[p] + b[p + 1] + b[p + 2]
                n += 3
        return int(tot / max(n, 1))
    except Exception:
        return -1
    finally:
        os.remove(bmp)


def shot(name, expect):
    """Capture both panels into raw/, copy the lit one (or the expected one) to <name>.png."""
    lit = {}
    for panel in ("inner", "cover"):
        display = STATE[panel]
        if not display:
            continue
        path = os.path.join(OUT, "raw", "%s-%s.png" % (name, panel))
        if screenshot(display, path):
            lit[panel] = (brightness(path), path)
    if not lit:
        log("WARN %s: no capture" % name)
        STATE["failures"] += 1
        return
    ib = lit.get("inner", (-1, None))[0]
    cb = lit.get("cover", (-1, None))[0]
    if ib > 6 and cb <= 6:
        pick = "inner"
    elif cb > 6 and ib <= 6:
        pick = "cover"
    else:
        pick = expect if expect in lit else next(iter(lit))
    src = lit[pick][1]
    dst = os.path.join(OUT, name + ".png")
    with open(src, "rb") as s, open(dst, "wb") as d:
        d.write(s.read())
    w, h = png_size(dst)
    shape = SIZES.get(pick, {}).get((w, h), "UNEXPECTED")
    note = "" if pick == expect else "  NOTE expected %s" % expect
    if ib <= 6 and cb <= 6:
        note += "  WARN both panels dark"
        STATE["failures"] += 1
    log("captured %s (inner=%d cover=%d -> %s %dx%d %s)%s" % (name, ib, cb, pick, w, h, shape, note))
    MANIFEST.write("%s.png  display=%s  %dx%d  %s  hinge=%s%s\n" % (name, pick, w, h, shape, STATE["angle"], note))
    rc, out = run(["hinge", "-d", UDID, "posture"], 20)
    POSTURE.write("== %s (hinge %s)\n%s\n" % (name, STATE["angle"], out[:1500]))


def shoot_sequence(name):
    if STATE["angle"] != 0:
        move(0)
    shot(name + "-cover", "cover")
    move(FLAT)
    shot(name + "-flat", "inner")
    move(HALF)
    shot(name + "-half", "inner")
    move(0)  # back on the cover for the test's next taps


# /pose steps: hinge angle and the panel to capture (None: no shot).
POSES = {"cover": (0, "cover"), "flat": (FLAT, "inner"), "half": (HALF, "inner"), "closed": (0, None)}

# DuoLayout's DEBUG line: "posture=flat hinge=fullyOpen angle=180 crease=456,0 40x669 active=0 window=951x669 wide=1"
LAYOUT_LINE = re.compile(r"posture=(\w+) .*?crease=(none|(-?\d+),(-?\d+) (\d+)x(\d+)) active=\d window=(\d+)x(\d+)")


def app_layout():
    """The app's latest DuoLayout reading from its Documents/duo-log.txt, as "fold=x,y,w,h window=WxH posture=p"."""
    rc, out = run(["xcrun", "simctl", "get_app_container", UDID, BUNDLE, "data"], 30)
    path = os.path.join(out.splitlines()[-1].strip() if rc == 0 and out else "", "Documents", "duo-log.txt")
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError as e:
        log("WARN no app duo log (%s)" % e)
        return "fold=none window=0x0 posture=unknown"
    for line in reversed(lines):
        m = LAYOUT_LINE.search(line)
        if m:
            fold = "none" if m.group(2) == "none" else "%s,%s,%s,%s" % m.group(3, 4, 5, 6)
            return "fold=%s window=%sx%s posture=%s" % (fold, m.group(7), m.group(8), m.group(1))
    return "fold=none window=0x0 posture=unknown"


def pose(name, to):
    angle, expect = POSES[to]
    if STATE["angle"] != angle:
        move(angle)
    if expect:
        shot("%s-%s" % (name, to), expect)
    reading = app_layout()
    log("pose %s %s: app %s" % (name, to, reading))
    return reading


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        LOG.write("http " + (fmt % args) + "\n")

    def reply(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        q = dict(urllib.parse.parse_qsl(url.query))
        with LOCK:
            try:
                if url.path == "/ping":
                    return self.reply(200, "ok")
                if url.path == "/hinge":
                    ok = move(int(float(q.get("angle", "180"))))
                    return self.reply(200 if ok else 500, "ok" if ok else "hinge not confirmed")
                if url.path == "/shoot":
                    name = "".join(ch for ch in q.get("name", "shot") if ch.isalnum() or ch in "-_.")
                    before = STATE["failures"]
                    log("=== shoot %s" % name)
                    shoot_sequence(name)
                    bad = STATE["failures"] - before
                    return self.reply(200, "ok" if bad == 0 else "ok with %d warning(s)" % bad)
                if url.path == "/pose":
                    name = "".join(ch for ch in q.get("name", "shot") if ch.isalnum() or ch in "-_.")
                    to = q.get("to", "")
                    if to not in POSES:
                        return self.reply(400, "to must be one of %s" % ", ".join(POSES))
                    before = STATE["failures"]
                    if to == "cover":
                        log("=== shoot %s" % name)
                    reading = pose(name, to)
                    bad = STATE["failures"] - before
                    return self.reply(200, ("ok " if bad == 0 else "ok with %d warning(s) " % bad) + reading)
                return self.reply(404, "unknown")
            except Exception as e:  # keep serving; the test reports the failure
                log("ERROR %s: %r" % (self.path, e))
                return self.reply(500, repr(e))


def main():
    probe_displays()
    server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    log("bridge listening on 127.0.0.1:%d (udid %s)" % (PORT, UDID))
    try:
        server.serve_forever()
    finally:
        log("bridge stopped, %d failure(s)" % STATE["failures"])


if __name__ == "__main__":
    sys.exit(main())
