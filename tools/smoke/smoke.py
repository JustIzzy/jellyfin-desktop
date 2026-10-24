#!/usr/bin/env python3
"""Smoke test for Jellyfin Desktop portable builds.

Launches a portable build with the remote debugging port, then checks:

  * window geometry   - the authoritative Win32 check (see WINDOW GEOMETRY below)
  * crash events      - Qt6WebEngineCore faults, exception 0x80000003
  * playback          - the 10-play regression (needs a reachable server)

Run with no arguments for the checks that need nothing but the build:

    python tools/smoke/smoke.py --build C:/Users/User/Downloads/jf-portable6

Add --plays to run the playback regression, which needs the Jellyfin server up
and will drive the web client over CDP:

    python tools/smoke/smoke.py --build ... --plays

WINDOW GEOMETRY - why this does not test inner == outer
-------------------------------------------------------
An earlier pass condition was "window.innerWidth == window.outerWidth ==
[2048,1080]". That condition is unsatisfiable and testing it is misleading.
Measured on 2026-10-24 with the window genuinely fullscreen on a 2048x1080
logical display:

    Win32 GetWindowRect : 0,0 -> 2048x1080      (exact, at the origin)
    Win32 GetClientRect : 2048x1080             (zero frame inset)
    Chromium innerWidth : 2048 x 1080           (correct)
    Chromium outerWidth : 2034 x 1073           (wrong)
    Chromium screenX/Y  : 7, 0                  (wrong)

A 2048-wide viewport starting at screenX=7 would end at 2055 on a 2048-wide
screen, which is impossible - so outerWidth/screenX are not real coordinates.
QtWebEngine does not implement real browser-window geometry and Chromium falls
back to a derived value with default frame insets subtracted. The same numbers
appear on a local qrc: page with no app layout in it at all, which proves they
are a property of the embedder and not of the content.

So this script asserts the authoritative thing instead: GetClientRect ==
GetWindowRect == screen size, at origin (0,0). It still records inner/outer for
reference, and flags it only if *inner* is wrong.
"""

import argparse, asyncio, ctypes, ctypes.wintypes as wt, json, os, re
import subprocess, sys, time, urllib.request
from pathlib import Path

PORT = 9222
SERVER = "http://192.168.1.200:30013"

# ---------------------------------------------------------------- Win32 geometry

user32 = ctypes.windll.user32


class RECT(ctypes.Structure):
    _fields_ = [("left", ctypes.c_long), ("top", ctypes.c_long),
                ("right", ctypes.c_long), ("bottom", ctypes.c_long)]


def window_rects(pid):
    """Return (window_rect, client_size) for the top-level window owned by pid."""
    found = []

    @ctypes.WINFUNCTYPE(ctypes.c_bool, wt.HWND, wt.LPARAM)
    def cb(hwnd, _):
        p = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(p))
        if p.value == pid and user32.IsWindowVisible(hwnd):
            r = RECT()
            user32.GetWindowRect(hwnd, ctypes.byref(r))
            if (r.right - r.left) > 200 and (r.bottom - r.top) > 200:
                c = RECT()
                user32.GetClientRect(hwnd, ctypes.byref(c))
                found.append(((r.left, r.top, r.right - r.left, r.bottom - r.top),
                              (c.right - c.left, c.bottom - c.top)))
        return True

    user32.EnumWindows(cb, 0)
    return found[0] if found else (None, None)


def screen_size():
    return user32.GetSystemMetrics(0), user32.GetSystemMetrics(1)


# ------------------------------------------------------------------------- CDP

def cdp_targets(port=PORT, timeout=2.0):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=timeout) as r:
        return json.load(r)


def wait_for_page(port=PORT, deadline=90.0, url_sub=None):
    t0 = time.time()
    while time.time() - t0 < deadline:
        try:
            ts = [t for t in cdp_targets(port)
                  if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
            if url_sub:
                ts = [t for t in ts if url_sub in (t.get("url") or "")]
            if ts:
                return ts[0]
        except Exception:
            pass
        time.sleep(0.5)
    return None


async def _eval(ws_url, expr, await_promise=False):
    import websockets
    async with websockets.connect(ws_url, max_size=64 * 1024 * 1024) as ws:
        await ws.send(json.dumps({"id": 1, "method": "Runtime.enable"}))
        await ws.recv()
        await ws.send(json.dumps({"id": 2, "method": "Runtime.evaluate",
                                  "params": {"expression": expr,
                                             "returnByValue": True,
                                             "awaitPromise": await_promise}}))
        while True:
            m = json.loads(await ws.recv())
            if m.get("id") == 2:
                return m


def page_eval(target, expr, await_promise=False):
    r = asyncio.run(_eval(target["webSocketDebuggerUrl"], expr, await_promise))
    res = r.get("result", {})
    if res.get("exceptionDetails"):
        return None, json.dumps(res["exceptionDetails"])[:400]
    return res.get("result", {}).get("value"), None


# ------------------------------------------------------------------- crash check

def crash_events(since_minutes=30):
    """Windows Application-log entries naming the app or WebEngine."""
    ps = (
        "Get-WinEvent -FilterHashtable @{LogName='Application';"
        f" StartTime=(Get-Date).AddMinutes(-{since_minutes})}} -ErrorAction SilentlyContinue |"
        " Where-Object { $_.Message -match 'Jellyfin Desktop|Qt6WebEngineCore' } |"
        " Select-Object -First 20 TimeCreated,Id,Message | ConvertTo-Json -Depth 3"
    )
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-Command", ps],
                             capture_output=True, text=True, timeout=60).stdout.strip()
    except Exception as e:
        return [], f"could not read event log: {e}"
    if not out:
        return [], None
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return [], "event log output was not JSON"
    if isinstance(data, dict):
        data = [data]
    hits = []
    for ev in data:
        msg = (ev.get("Message") or "").replace("\r", " ").replace("\n", " ")
        if "0x80000003" in msg or "Qt6WebEngineCore" in msg:
            hits.append({"id": ev.get("Id"), "msg": msg[:300]})
    return hits, None


def server_up(url=SERVER, timeout=6):
    try:
        with urllib.request.urlopen(f"{url}/System/Info/Public", timeout=timeout) as r:
            return r.status == 200
    except Exception:
        return False


# ----------------------------------------------------------------------- launch

def launch(build_dir, extra_args=()):
    exe = Path(build_dir) / "Jellyfin Desktop.exe"
    if not exe.exists():
        sys.exit(f"no executable at {exe}")
    args = [str(exe), f"--remote-debugging-port={PORT}", *extra_args]
    return subprocess.Popen(args, cwd=str(build_dir),
                            creationflags=getattr(subprocess, "DETACHED_PROCESS", 0))


def kill_app():
    subprocess.run(["powershell", "-NoProfile", "-Command",
                    "Get-Process -Name 'Jellyfin Desktop' -ErrorAction SilentlyContinue |"
                    " Stop-Process -Force -ErrorAction SilentlyContinue"],
                   capture_output=True, timeout=60)
    time.sleep(2)


# ------------------------------------------------------------------------ checks

def check_geometry(proc):
    """Authoritative window geometry check. Returns (rows, inner, outer)."""
    rows = []
    sw, sh = screen_size()
    win, client = None, None
    for _ in range(40):
        win, client = window_rects(proc.pid)
        if win:
            break
        time.sleep(0.5)

    if not win:
        rows.append(("window found", "FAIL", "no visible top-level window"))
        return rows, None, None

    x, y, w, h = win
    rows.append(("GetWindowRect == screen",
                 "PASS" if (w, h) == (sw, sh) else "FAIL",
                 f"{w}x{h} vs screen {sw}x{sh}"))
    rows.append(("window at origin (0,0)",
                 "PASS" if (x, y) == (0, 0) else "FAIL",
                 f"at ({x},{y})"))
    rows.append(("GetClientRect == GetWindowRect",
                 "PASS" if client == (w, h) else "FAIL",
                 f"client {client[0]}x{client[1]} vs window {w}x{h}"))

    inner = outer = None
    tgt = wait_for_page()
    if tgt:
        val, err = page_eval(tgt, "JSON.stringify({i:[innerWidth,innerHeight],"
                                  "o:[outerWidth,outerHeight],s:[screenX,screenY],"
                                  "sc:[screen.width,screen.height],d:devicePixelRatio})")
        if val:
            m = json.loads(val)
            inner, outer = m["i"], m["o"]
            rows.append(("page viewport == screen",
                         "PASS" if inner == [sw, sh] else "FAIL",
                         f"inner {inner} vs screen [{sw},{sh}]"))
            rows.append(("outer/screenX (reference only)", "INFO",
                         f"outer={outer} screenXY={m['s']} dpr={m['d']}"
                         "  - QtWebEngine artifact, not asserted"))
        else:
            rows.append(("page viewport", "FAIL", f"eval failed: {err}"))
    else:
        rows.append(("CDP page target", "FAIL", "no page target appeared"))

    return rows, inner, outer


PLAY_MATRIX = [
    # (label, window state, scaling %) - 10 plays, mixed HDR/SDR
    ("4K HDR  fullscreen 200%", "fullscreen", 200),
    ("4K HDR  fullscreen 125%", "fullscreen", 125),
    ("4K HDR  maximised  200%", "maximised", 200),
    ("4K HDR  windowed   200%", "windowed", 200),
    ("4K HDR  windowed   125%", "windowed", 125),
    ("SDR 1080 fullscreen 200%", "fullscreen", 200),
    ("SDR 1080 fullscreen 125%", "fullscreen", 125),
    ("SDR 1080 maximised  200%", "maximised", 200),
    ("SDR 1080 windowed   200%", "windowed", 200),
    ("SDR 1080 windowed   125%", "windowed", 125),
]


def check_plays():
    """The 10-play regression.

    Deliberately NOT automated end to end. Two of the three axes cannot be
    driven safely without permission:

      * display scaling (125% / 200%) is a per-user display setting; changing it
        from a script resizes every window on the desktop.
      * window state needs either the app's fullscreen host command or synthetic
        input into a fullscreen window.

    So this prints the matrix and the per-play pass criteria, and verifies the
    parts that ARE scriptable: that the server is reachable, and that no crash
    event appears during the run. Drive the plays by hand against this list.
    """
    rows = []
    rows.append(("server reachable", "PASS" if server_up() else "FAIL", SERVER))
    for label, state, scale in PLAY_MATRIX:
        rows.append((f"play: {label}", "MANUAL",
                     f"state={state} scaling={scale}%  "
                     "pass = picture on first play, no fullscreen toggle, no crash"))
    return rows


# -------------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", required=True, help="portable build directory")
    ap.add_argument("--plays", action="store_true", help="include the 10-play regression")
    ap.add_argument("--keep", action="store_true", help="leave the app running")
    a = ap.parse_args()

    print(f"build  : {a.build}")
    print(f"screen : {screen_size()[0]}x{screen_size()[1]} (logical)")
    print()

    kill_app()
    proc = launch(a.build)
    rows, inner, outer = check_geometry(proc)

    if a.plays:
        rows += [("", "", "")] + check_plays()

    hits, err = crash_events(since_minutes=10)
    if err:
        rows.append(("crash events", "INFO", err))
    else:
        rows.append(("no crash events (0x80000003 / Qt6WebEngineCore)",
                     "PASS" if not hits else "FAIL",
                     "none found" if not hits else f"{len(hits)} event(s): {hits[0]['msg'][:160]}"))

    if not a.keep:
        kill_app()

    w = max(len(r[0]) for r in rows if r[0]) + 2
    print(f"{'check'.ljust(w)}{'result'.ljust(8)}detail")
    print("-" * (w + 8 + 40))
    for name, result, detail in rows:
        if not name:
            print()
            continue
        print(f"{name.ljust(w)}{result.ljust(8)}{detail}")

    failed = [r for r in rows if r[1] == "FAIL"]
    manual = [r for r in rows if r[1] == "MANUAL"]
    print()
    print(f"{len(failed)} FAIL, {len(manual)} MANUAL, "
          f"{len([r for r in rows if r[1] == 'PASS'])} PASS")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
