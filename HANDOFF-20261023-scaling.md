# Handoff — Jellyfin Desktop, 2026-10-23 → 24

Session covered the desktop app (Qt 6.9.3) and, earlier, a Viewfinder pad fix.
**The open item is the app-layout window scaling.** Everything else is resolved
or verified.

---

## 0. Read this first

- The app you care about is **`JustIzzy/jellyfin-desktop`, branch
  `fix/webengine-transparent-surface`** — pushed, public, builds in CI.
- CI builds with **Qt 6.9.3**; the local `build/` tree uses **Qt 6.8.1**. That
  mismatch caused a crash that cost most of an evening. **Test CI builds, not
  local ones**, or install Qt 6.9.3 locally.
- Always test the **portable** artifact first. Do not install over
  `C:\Users\User\AppData\Local\Programs\Jellyfin Desktop` until a film has
  played on the portable build.

## 1. THE OPEN PROBLEM — app-layout window scaling

### Symptom
In the app layout the UI is cut off at the right (and bottom). Owner's
screenshots show the right-hand column running off the edge; a window capture
came out 3916x2148 rather than the display's 4096x2160.

### Root cause (measured, holds up)
Borderless-**maximised** on Windows keeps the invisible ~7px resize border.
Qt reports the full screen size while the real client area is smaller, so the
page lays out wider than the area actually displayed and the edges clip.

Measured over CDP on the 4096x2160 display at 200% scaling (logical 2048x1080):

```
page viewport (innerWidth/Height) : 2048 x 1080
window        (outerWidth/Height) : 2034 x 1073   at x=7, y=0
```

The page itself is fine — a CDP screenshot shows the full layout with a normal
margin, because it captures the whole rendered viewport including the part the
window never shows. **That disagreement between the CDP capture and the owner's
screenshot is the diagnostic signature.**

### Three failed attempts (do not repeat)
1. **Viewfinder zoom to 100%** (`M` → ZOOM (THIS APP)). Wrong mechanism. The
   computer layout scales via CSS `zoom: var(--vf-zoom)`; the **app layout does
   not use `--vf-zoom` at all** — it uses its own `fit()` in
   `viewfinder/src/pages/app.js`: `transform: scale(min(innerWidth/1920,
   innerHeight/1080))` against a fixed 1920x1080 design canvas. Measured that
   stage as exactly 2048x1080 at `scale(1)`, origin 0,0, `bodyScroll` equal to
   the viewport — i.e. the page does not overflow. (352 elements do extend past
   `innerWidth`, but those are horizontally-scrolling carousel rows and are
   meant to.)
2. **Display overscan** (NVIDIA / projector "Just Scan"). Plausible, wrong —
   the CDP vs screenshot comparison localises it to the window, not the panel.
3. **`anchors.fill: parent` on the WebEngineView** (commit `5bb508b`). Right
   idea, wrong level: the `contentItem` it fills is *itself* the oversized
   2048x1080. Kept in the branch anyway — harmless and arguably more correct —
   but it is **not** the fix.

### Current attempt — UNVERIFIED
`5053d5f` then `78e5c72` in `src/ui/webview.qml`, `_enterFakeFullScreen()`:
replace `visibility = Window.Maximized` with explicit geometry from
`mainWindow.screen` (x/y/width/height), keeping `Qt.FramelessWindowHint`.

- `5053d5f` **regressed it**: applied geometry immediately after changing
  visibility, and Qt's asynchronous windowed-restore landed afterwards and
  overwrote it. Result: a 1280x720 window at (384,151) — the stored windowed
  geometry — despite `fullscreen=true`.
- `78e5c72` defers the geometry via `Qt.callLater(_applyFullScreenGeometry)`.
  **Built but never tested.** This is where to pick up.

### How to verify (do this before believing any fix)
Launch the portable build with `--remote-debugging-port=9222`, then evaluate in
the page:
```js
JSON.stringify({inner:[innerWidth,innerHeight], outer:[outerWidth,outerHeight],
                screenXY:[screenX,screenY], screen:[screen.width,screen.height]})
```
Pass condition: `inner` equals `outer` equals `[2048,1080]`, origin `(0,0)`,
and the taskbar is covered. Helper scripts are in the scratchpad (see §6).

### If `78e5c72` also fails
Fall back to `visibility = Window.Maximized` (clips 14px but works), and
investigate handling `WM_NCCALCSIZE`, which is the standard Windows fix for
borderless-maximised client-area insets. Also unexplored: `storage.json` has
per-resolution window state with **no entry for the current resolution** —
`"3840x2160 screen: Window-Maximized": true` exists, `2048x1080` has only
XPosition/YPosition. Adding a maximized key for `2048x1080` may matter.

---

## 2. SOLVED — picture never appears until a fullscreen toggle

Owner confirmed playback works on the build containing `a4280da`.

**The real bug**, after a four-build bisect (all crashes shared fault offset
`0x315c40e` in `Qt6WebEngineCore.dll` 6.9.3):

| Build | backgroundColor used | Result |
|---|---|---|
| upstream master | `"transparent"` only | works, but bug present |
| `419dd19` original | runtime `#01000000` → transparent | crash at startup |
| load call site removed | same, other site | crash at playback |
| declared at construction | `#01000000`, no runtime writes | crash at startup |

**Chromium requires its base background to be fully opaque or fully
transparent.** `#01000000` is alpha 1/255 — illegal — and trips a CHECK that
aborts the process (`0x80000003`, STATUS_BREAKPOINT). Qt 6.8.1 tolerated it;
6.9.3 does not. It was never a timing problem.

Fix (`a4280da`): keep `419dd19`'s mechanism exactly — `reapplyWebBackground()`,
the `videoPlaybackActive` trigger, the 12-pass settle timer — but use
`#ff000000` (opaque black) as the intermediate. Legal, still differs from
`"transparent"`, still forces propagation, never visible since both assignments
happen in one call.

Also confirmed: **Qt 6.9.3 still has the underlying bug** — owner tested clean
master and got no picture until a fullscreen toggle. The fix is needed.

## 3. SOLVED — crash on startup / on playback
Same root cause as §2. See `3a008a3` (removed the vestigial load-triggered
re-apply, which `419dd19`'s own commit message records as ineffective anyway)
and `a4280da`.

## 4. mpv configuration — applied, untested by owner
`...\profiles\5d0b1223c3f2422b8e33f407461c6c22\mpv.conf`, rewritten for **best
SDR picture, upscaling pushed hard**. Backup: `mpv.conf.bak-20261023-2214`.

- **Reversal to flag:** the old config did HDR *passthrough* on purpose
  (2026-10-12 note). The new one tone-maps to SDR because the owner asked for
  it. If the projector does accept real HDR, passthrough beats any tone map.
- **Windows HDR must be OFF** for the display or Windows double-converts.
- HDR→SDR: `tone-mapping=spline`, `hdr-compute-peak=yes` +
  `hdr-peak-percentile=99.995`, `hdr-contrast-recovery=0.30`,
  `gamut-mapping-mode=perceptual`.
- Upscaling shaders in `...\profiles\...\shaders\`: `ravu-zoom-ar-r3.hook`
  (handles the non-integer 2.13x/2.0x factor), `KrigBilateral.glsl` (chroma),
  `SSimDownscaler.glsl` (requires `linear-downscaling=no`).
  `ravu-lite-ar-r4.hook` also downloaded as the cheap fallback.
  FSRCNNX was **not** obtainable — igv's URL 404s.
- Heavy for a GTX 1060 Max-Q at 4096x2160. Ordered back-off ladder is at the
  bottom of the file, starting with `interpolation`.

## 5. Also open
- **"Navigation smooth but not buttery."** The mpvqt render-pump commit
  (`0e20f42`, "2 renders → 1300+") is already in. Untried: `"useOpenGL": false`
  in `jellyfin-desktop.conf` — one line, reversible, the obvious next lever.
  Measure frame timings over CDP rather than cycling settings.
- **Regression pass for the picture fix never ran**: 10 consecutive plays,
  mixed 4K HDR and SDR, across window states at 125%/200%.
- **Viewfinder pad fix is committed and undeployed** — `jellyfinedits`,
  `viewfinder-app`, 6 commits ahead of origin, **not pushed**. That work is
  server-side (deploys via the `viewfinder-deploy` workflow). See
  `handoff-viewfinder-pad-20261023.md` and `.patch` in that repo.
- Upstream reports in this repo are still unsubmitted drafts.

## 6. Environment notes / traps
- **CI is the only Qt 6.9.3 build path.** `gh workflow run build-windows.yml
  --repo JustIzzy/jellyfin-desktop --ref fix/webengine-transparent-surface`,
  ~8-14 min, then download the `windows-x64-portable` artifact.
- `JustIzzy/mpvqt` is **public** (CI cannot clone a private submodule with the
  default GITHUB_TOKEN). `.gitmodules` points at it — commit `4b791aa`. Revert
  if the render-pump fix ever lands upstream at KDE.
- `JustIzzy/jellyfin-desktop` was made **public** to escape the Actions
  artifact storage quota (`jellyfinedits` had consumed 372 GB-hours in
  October). Private repos hit that quota; public ones do not.
- **Claude's shell network probes are sandboxed and cannot see the LAN.** They
  reported the Jellyfin server unreachable for an hour while it was fine.
  Trust the app's own log and the self-hosted runner instead.
- Desktop screen capture cannot see this window in fullscreen (independent
  flip / MPO). **CDP `Page.captureScreenshot` works** and was the key tool —
  but note it captures the full rendered viewport, including parts the window
  does not display. That is a feature for this bug, not a flaw.
- Dev-build log: `%LOCALAPPDATA%\Jellyfin Desktop\profiles\<id>\logs\`, NOT the
  installed app's `JellyfinMediaPlayer` path.
- Backups: old installed app at
  `C:\Users\User\Documents\Claude\_app-backup-20261024` (Programs + profile);
  git bundles of all three repos at
  `C:\Users\User\Documents\Claude\_branch-backups`.
- Scratchpad helpers (CDP eval / screenshot / recorder) are in
  `C:\Users\User\AppData\Local\Temp\claude\C--Users-User\51b90df8-aeb3-458e-8709-4f1160c8d95b\scratchpad`
  — session-scoped, copy them out if still needed.

## 7. Build artifacts on disk
| Path | What it is |
|---|---|
| `Downloads\jf-master-portable` | clean upstream master — works, no picture fix |
| `Downloads\jf-portable4` | `a4280da` — **playback confirmed working**, clips 14px |
| `Downloads\jf-portable5` | `5053d5f` — geometry regressed to 1280x720, do not use |
| (pending) | `78e5c72` — deferred geometry, **untested** |
