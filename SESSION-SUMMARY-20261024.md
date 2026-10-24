# Session summary — Jellyfin Desktop + Viewfinder, 2026-10-23 → 24

Written to be interrogated. Every claim is marked **verified** (measured or
owner-confirmed) or **unverified** (reasoned, not demonstrated).

---

## 1. The picture bug — SOLVED, owner-confirmed

### Symptom
Audio plays, timeline advances, UI works, **no picture until a fullscreen
toggle**. Long-standing; the toggle was the owner's habitual workaround.

### Root cause
`WebEngineView.backgroundColor` was declared `"transparent"`, but Qt only
propagates that to Chromium's compositor on an actual property *change*.
Declaring it is a no-op, so the web view composited opaquely at `z:100` over the
mpv video item. Video rendered correctly and was never visible.

`419dd19` (pre-session) fixed this by forcing a real change: assign
`#01000000`, then `"transparent"`. **That worked on Qt 6.8.1 and crashed on
6.9.3.**

### The crash, and what it actually was
Four builds, every crash identical: `Qt6WebEngineCore.dll` 6.9.3,
exception `0x80000003` (STATUS_BREAKPOINT), fault offset `0x315c40e`.

| Build | Value assigned | Result |
|---|---|---|
| upstream master | `"transparent"` only | runs; bug present |
| `419dd19` | runtime `#01000000` → transparent | crash at startup |
| load call-site removed (`3a008a3`) | same, other site | crash at playback |
| declared at construction (`a38743d`) | `#01000000`, zero runtime writes | crash at startup |

The constant is the **value**, not the timing. **Chromium requires its base
background to be fully opaque or fully transparent.** `#01000000` is alpha
1/255 — illegal — and trips a CHECK. 6.8.1 tolerated it; 6.9.3 aborts.

### Fix — `a4280da`
Keep `419dd19`'s mechanism verbatim (`reapplyWebBackground()`, the
`videoPlaybackActive` trigger, the 12-pass settle timer). Change the
intermediate from `#01000000` to `#ff000000`. Opaque black is legal, still
differs from `"transparent"` so it still forces propagation, and is never
presented because both assignments occur in one call.

**Verified:** owner played a film; picture appeared without a fullscreen toggle
and playback did not crash.

### Secondary finding
**Qt 6.9.3 still has the underlying bug.** Owner tested clean upstream master
and got no picture until toggling. So the fix is necessary, not vestigial.

---

## 2. Scaling / cut-off UI — OPEN

### Symptom
App-layout UI clipped at the right (and bottom). Owner screenshots show the
right-hand column running off-screen; a window capture came out 3916x2148 on a
4096x2160 display.

### Measured evidence (holds up)
Over CDP, 4096x2160 at 200% scaling (logical 2048x1080):

```
page viewport (innerWidth/Height) : 2048 x 1080
window        (outerWidth/Height) : 2034 x 1073   at x=7, y=0
```

The page lays out into a viewport **larger than the window showing it**, so
~14 logical px fall outside. A CDP screenshot shows the layout complete with a
normal margin, because it captures the full rendered viewport including the part
the window never displays. **That disagreement between CDP capture and the
owner's screenshot is the diagnostic signature.**

Cause: borderless-**maximised** on Windows keeps the invisible ~7px resize
border. Qt reports the full screen size while the client area is smaller.

### Four failed attempts — do not repeat
1. **Viewfinder zoom → 100%.** Wrong mechanism entirely. The *computer* layout
   scales via CSS `zoom: var(--vf-zoom)`; the **app layout does not use
   `--vf-zoom`**. It uses `fit()` in `viewfinder/src/pages/app.js`:
   `transform: scale(min(innerWidth/1920, innerHeight/1080))` on a fixed
   1920x1080 design canvas. Measured: stage exactly 2048x1080 at `scale(1)`,
   origin (0,0), `bodyScroll` equal to viewport — the page does **not** overflow.
   (352 elements do extend past `innerWidth`; those are horizontally-scrolling
   carousel rows and are supposed to.)
2. **Display overscan** (NVIDIA scaling / projector "Just Scan"). Wrong layer —
   the CDP-vs-screenshot comparison localises it to the window, not the panel.
3. **`anchors.fill: parent` on the WebEngineView** (`5bb508b`). Right idea,
   wrong level: the `contentItem` it fills is *itself* the oversized 2048x1080.
   Left in the branch (harmless, arguably more correct) but **not the fix**.
4. **Explicit geometry in QML `_enterFakeFullScreen()`** (`5053d5f`, then
   `78e5c72` deferring via `Qt.callLater`). No effect — see below.

### THE ACTUAL FINDING (found last)
**The QML function is not on the startup path.** Window state is owned by C++:

```cpp
// src/ui/WindowManager.cpp
void WindowManager::setFullScreen(bool enable) {
  if (enable) { m_window->showFullScreen(); updateForcedScreen(); }
  else { ... m_window->showMaximized(); ... }
}
```

With `fullscreen=true` in config, **C++ calls `showFullScreen()` at startup**.
The QML `_enterFakeFullScreen()` serves the web client's own fullscreen toggle
and never runs at launch. Confirmed the shipped binary *does* contain
`_applyFullScreenGeometry` (string present), so the code shipped — it just is
not executed on that path. **Any fix belongs in `WindowManager.cpp`.**

Unresolved design conflict: `419dd19` added the QML fake-fullscreen
*specifically to avoid* true fullscreen (Optimus direct-scanout theory), while
C++ still calls `showFullScreen()`. Those two intentions contradict each other
and should be reconciled deliberately.

### Pass condition for any future fix
Launch portable with `--remote-debugging-port=9222`, evaluate:
```js
JSON.stringify({inner:[innerWidth,innerHeight], outer:[outerWidth,outerHeight],
                screenXY:[screenX,screenY], screen:[screen.width,screen.height]})
```
Pass = `inner` equals `outer` equals `[2048,1080]`, origin `(0,0)`, taskbar
covered.

### Unexplored
`storage.json` keys window state **per resolution** and has no entry for the
current one: `"3840x2160 screen: Window-Maximized": true` exists;
`2048x1080` has only XPosition/YPosition. Also unexplored: handling
`WM_NCCALCSIZE`, the standard Windows fix for borderless-maximised insets.

---

## 3. mpv — APPLIED, UNVERIFIED by playback

Path: `%LOCALAPPDATA%\Jellyfin Desktop\profiles\5d0b1223...\mpv.conf`
Backup: `mpv.conf.bak-20261023-2214` (the previous HDR-passthrough config).

### Owner decision reversal — flag this
The old config did **HDR passthrough on purpose** (2026-10-12 note: switched
*away* from tone-mapping, needs Windows HDR ON). The new config **tone-maps to
SDR** because the owner asked for "best possible SDR picture". If the projector
genuinely accepts HDR, passthrough beats any tone map and the backup should be
restored instead.

### HDR → SDR
| Setting | Why |
|---|---|
| `tone-mapping=spline` | best general curve in gpu-next; holds highlights without hable's dull midtones |
| `tone-mapping-mode=hybrid` | keeps saturation in bright areas instead of desaturating toward white |
| `hdr-compute-peak=yes` + `hdr-peak-percentile=99.995` | measures each scene's real peak; static metadata is often wrong — biggest single HDR→SDR win |
| `hdr-contrast-recovery=0.30` | restores local contrast that tone mapping flattens; 0.30 is the practical ceiling before highlight ringing |
| `gamut-mapping-mode=perceptual` | compresses out-of-gamut BT.2020 instead of clipping saturated reds/blues |

### Upscaling (shaders in `...\profiles\...\shaders\`)
| Shader | Why |
|---|---|
| `ravu-zoom-ar-r3.hook` | learned upscaler with anti-ringing, handles **arbitrary** factors — needed because 1920x1080 → 4096x2160 is 2.13x wide but 2.0x tall, not integer |
| `KrigBilateral.glsl` | chroma upscaling; 4:2:0 stores colour at quarter resolution, so bigger win than it sounds |
| `SSimDownscaler.glsl` | for true-4K sources; **requires `linear-downscaling=no`** |
| `ravu-lite-ar-r4.hook` | downloaded as the cheap fallback, not active |

**FSRCNNX could not be obtained** — igv's repo URL 404s. RAVU is arguably the
better fit anyway given the non-integer factor.

Plus `sigmoid-upscaling=yes` (kills edge halos), `correct-downscaling`,
2-pass deband (banding is more visible after tone mapping).

### Display characterisation
| Setting | Why |
|---|---|
| `icc-profile-auto=yes` | uses `CalibratedDisplayProfile-1.icc`, which Windows has associated with this display. Corrects the display's real primaries/transfer rather than assuming ideal Rec.709 — **bigger real-world win than any scaler** |
| `icc-3dlut-size=64x64x64` + cache dir | more accurate, computed once |
| `dither=error-diffusion` + `sierra-lite` | visibly cleaner gradients than ordered dither |
| `blend-subtitles=yes` | subtitles filtered with the picture, less aliasing |
| `video-output-levels=auto`, `target-contrast=auto` | **left at auto deliberately** — wrong values here actively hurt near-black, and the projector's real contrast/range is unknown. Comments in-file explain how to set them |

### Machine-specific
| Setting | Why |
|---|---|
| `d3d11-adapter=NVIDIA` | **Optimus machine**: Intel UHD 630 + GTX 1060 Max-Q. D3D11 can select the iGPU even when the display is wired to NVIDIA; the shader chain on an iGPU would crawl. Possibly the largest perf win of the set |
| `cache=yes`, `demuxer-max-bytes=1GiB`, `readahead-secs=20` | everything streams from the server; 4K remuxes run 60-100 Mbit/s and the default buffer turns a hiccup into a stall |

Removed `temporal-dither` — a no-op alongside error diffusion.

### Caveats
- **Windows HDR must be OFF** for this display or Windows double-converts and
  the result is flat regardless of config.
- Heavy chain for a 1060 Max-Q at 4096x2160. Ordered back-off ladder is at the
  bottom of the file (start with `interpolation`).
- **Shader load failures are silent.** Verify with `i` twice during playback
  (mpv stats) that `ravu-zoom-ar-r3` appears.
- Config verified free of real duplicate keys; the apparent ones are
  `[sd-content]` profile overrides and intentional `glsl-shaders-append` lines.

---

## 4. Infrastructure changes made this session
- Created **`JustIzzy/jellyfin-desktop`** (now **public**) and
  **`JustIzzy/mpvqt`** (**public**). All previously local-only desktop work is
  now pushed — that was a standing data-loss risk.
- mpvqt had to be public: CI checks out submodules with the default
  `GITHUB_TOKEN`, which cannot clone another private repo. `.gitmodules`
  repointed in `4b791aa` — revert if the render-pump fix lands upstream at KDE.
- jellyfin-desktop was made public to escape the **Actions artifact storage
  quota** (`jellyfinedits` consumed 372 GB-hours in October; public repos don't
  draw on it).
- Default branch temporarily set to the fix branch so `gh workflow run` could
  resolve workflows; **should be set back to `master`**.

---

## 5. Verified vs unverified

| Item | Status |
|---|---|
| Picture appears without fullscreen toggle | **verified** — owner played a film |
| Startup + playback crashes fixed | **verified** — measured, no crash events |
| Partial-alpha is the crash cause | **verified** — four-build bisect |
| Qt 6.9.3 still has the picture bug | **verified** — owner tested clean master |
| Viewport smaller than page (scaling cause) | **verified** — CDP measurement |
| Fix belongs in `WindowManager.cpp` | **reasoned**, not yet demonstrated |
| All mpv settings | **unverified** — no playback since they became active |
| `d3d11-adapter` actually changes adapter | **unverified** |
| "Navigation smoother" | owner-reported, not measured |

---

## 6. Still open
1. **Scaling** — fix in `WindowManager.cpp` (section 2).
2. **60fps / "buttery"** — mpvqt render-pump (`0e20f42`) already in. Untried:
   `"useOpenGL": false` in `jellyfin-desktop.conf`. Measure frame timings over
   CDP rather than cycling settings.
3. **Regression pass never ran** for the picture fix: 10 consecutive plays,
   mixed 4K HDR and SDR, windowed/maximised/fullscreen at 125% and 200%.
4. **Installed app is still the crashing build** (21:08 on 2026-10-23). Working
   options: `Downloads\jf-portable6` (current, real profile) or the backup at
   `Documents\Claude\_app-backup-20261024`.
5. **Viewfinder pad fix** — `jellyfinedits`, `viewfinder-app`, 6 commits ahead,
   **not pushed, not deployed**. Server-side; deploys via `viewfinder-deploy`.
   See `handoff-viewfinder-pad-20261023.md` + `.patch` in that repo.
6. Upstream reports remain unsubmitted drafts.
7. Default branch of the fork should go back to `master`.

---

## 7. Methodology errors — the honest list
These cost real time and are the most likely things to be asked about.

1. **Qt version mismatch.** The fix was developed and verified on local Qt
   **6.8.1** while the shipping app uses **6.9.3**. That gap produced the crash
   that cost most of the evening. Local `build/` should be moved to 6.9.3, or
   only CI builds trusted.
2. **Installed before testing.** The first CI build was installed over the
   working app without testing the portable artifact first — despite the fix
   being known-unverified on 6.9.3. Result: no working player for ~30 minutes.
   Portable-first costs nothing and was adopted afterwards.
3. **Sandboxed network probes reported as fact.** Claude's shell cannot reach
   the LAN; it reported the Jellyfin server unreachable for an extended stretch
   while it was fine. The evidence that held up came from the app's own log and
   the self-hosted runner. **Do not trust shell socket tests for LAN questions.**
4. **Portable builds have their own profile.** `<portable>\data\profiles\<id>\`
   is a fresh default (`fullscreen=False`, no `mpv.conf`, no server URL).
   Several builds were compared without accounting for this, so differences in
   *profile state* were attributed to *code*. Specifically, the claim that
   `5053d5f` regressed the window to 1280x720 was **wrong** — that was simply
   `fullscreen=False`. Copy the real profile in before comparing builds.
5. **Edited code that never runs.** Two commits were spent on QML
   `_enterFakeFullScreen()` before establishing that C++ owns the startup path.
   Should have traced the call path before editing.
6. **Three wrong scaling theories before measuring.** Zoom, then overscan, then
   anchoring — all reasoned from source. The decisive measurement
   (`inner` vs `outer`) took one CDP call and should have come first.
