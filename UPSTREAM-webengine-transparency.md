# DRAFT — not submitted

## WebEngineView composites an opaque surface over sibling video, despite `backgroundColor: "transparent"`

**Status:** draft for the owner's review. Decide whether this is filed against Qt
(QTBUG) as a WebEngine bug, or against Jellyfin Desktop as a workaround PR, or both.

### Environment
- Windows 11 Home 26200, hybrid Intel + NVIDIA, 200% display scaling, 4096x2160 output
- Qt 6.8.1 msvc2022_64, QtWebEngine, Qt Quick with `QQuickFramebufferObject` video item (mpvqt/libmpv render API)
- Jellyfin Desktop 2.0.0-dev; reproduces with an unmodified upstream build and the stock web client

### Symptom
A `WebEngineView` declared `backgroundColor: "transparent"`, at `z: 100` over a
`QQuickFramebufferObject` video item, composites **fully opaque** once video playback
starts underneath it. Audio plays and the timeline advances, but no picture is visible.
Toggling fullscreen makes the picture appear — the long-standing user workaround.

### Evidence (all capture-independent)
Measured with `QQuickItem::grabToImage()` on the content item, the video item and the
web view separately, which renders through the scene graph and so is immune to the
desktop-capture failures below.

| | baseline (broken) | after re-applying `backgroundColor` |
|---|---|---|
| web view grab alpha | 255 in 989/989 samples | 0 in 966/989 (rest 46–95, the OSD bar) |
| `scene` vs `web` grab | byte-identical | differ |
| scene mean vs video mean | 21.8 vs 97 | 78.1 vs 78.1 |

Byte-identical `scene` and `web` grabs mean compositing the web layer over the video
yields exactly the web layer: the video contributes nothing.

Simultaneously, the page itself is genuinely transparent — via DevTools:
`transparentDocument` on `<html>`, every layer at screen centre `rgba(0, 0, 0, 0)` with
`background-image: none`, and no element over half the viewport painting a background.

The video content is also known good: `glReadPixels` on the FBO at the end of
`MpvRenderer::render()` returns real frames at full alpha
(`centre=188,196,148,a=255`, `glErr=0`) in a correctly sized 4096x2160 FBO.

### Cause and workaround
Assigning `backgroundColor` a value equal to its current value is a no-op, so Qt never
propagates it to Chromium. Forcing a genuine property change restores transparency:

```qml
function reapplyWebBackground() {
    web.backgroundColor = "#01000000"
    web.backgroundColor = "transparent"
}
```

Timing matters: the surface only turns opaque **once video is playing underneath it**.
Re-applying after page load alone does not help (verified). It must be re-applied from
playback start, and repeated briefly, because the web client then navigates to its OSD
view and that new view arrives with a fresh opaque surface a second or two later.

### What was ruled out (each measured, not assumed)
`layer.enabled` on the view; hide/re-show surface reset; 1px resize; minimize/restore;
`QTWEBENGINE_CHROMIUM_FLAGS=--disable-gpu-compositing`; page/DOM occlusion; the
C++→JS playback-state chain (`core-idle` does go false, `playing()` is emitted, the web
client receives it and clears its backdrop); mpv itself; GPU/driver.

### Note for anyone reproducing this on Windows
No desktop screen-capture tool can see this window in fullscreen — it presents through
independent flip / MPO, so GDI `CopyFromScreen` returns pure black even for content that
is plainly visible. Four separate capture tools produced false evidence during this
investigation. Use `grabToImage` instead.

---

## UPDATE 2026-10-24 — Qt 6.9.3 coverage, and a trap in the workaround

### The bug is still present in Qt 6.9.3
Originally investigated on Qt 6.8.1. Re-confirmed on **Qt 6.9.3**: a clean upstream build
still shows no picture until fullscreen is toggled. The report stands for 6.9.3.

### The workaround has a hard constraint that is worth stating in the report
The fix is to force a real property change, since assigning `backgroundColor` its current
value is a no-op and never reaches Chromium's compositor. **The intermediate colour must
be fully opaque or fully transparent.**

The original workaround used `#01000000` (alpha 1/255). On Qt 6.8.1 that is tolerated. On
**Qt 6.9.3 it trips a CHECK inside `Qt6WebEngineCore` and kills the process** with
exception `0x80000003` (STATUS_BREAKPOINT), fault offset `0x315c40e`.

Established by a four-build bisect, every crash identical:

| Build | Value assigned | Result |
|---|---|---|
| upstream master | `"transparent"` only | runs; bug present |
| workaround v1 | runtime `#01000000` → transparent | crash at startup |
| workaround v2 (one call site removed) | same value, other site | crash at playback |
| workaround v3 (declared at construction) | `#01000000`, zero runtime writes | crash at startup |

The constant is the **value**, not the timing: Chromium requires its base background to be
fully opaque or fully transparent, and alpha 1/255 is neither.

Working form — opaque black is legal, still differs from `"transparent"` so propagation is
still forced, and is never seen because both assignments happen in one call:

```qml
function reapplyWebBackground() {
  web.backgroundColor = "#ff000000"
  web.backgroundColor = "transparent"
}
```

This matters for the report: anyone reproducing the bug and reaching for the obvious
"nearly transparent" intermediate value will crash on 6.9.3 and may wrongly conclude the
workaround itself is unsafe.

### Suggested framing
Two separate asks for Qt:
1. `WebEngineView.backgroundColor` declared `"transparent"` should reach Chromium's base
   background without requiring a property *change* (the actual bug).
2. Assigning a partially transparent `backgroundColor` should be rejected or clamped at
   the Qt layer, not allowed through to a CHECK failure that terminates the process.
