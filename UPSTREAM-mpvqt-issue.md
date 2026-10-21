# DRAFT — upstream report for KDE mpvqt (NOT SUBMITTED)

Target: https://invent.kde.org/libraries/mpvqt
Affects downstream: jellyfin/jellyfin-desktop (vendors mpvqt as `external/mpvqt`)

---

## Title
`MpvRenderer::render()` never calls `mpv_render_context_update()`, so the render pump stalls after the first frame

## Summary
`MpvRenderer` never calls `mpv_render_context_update()`. libmpv's render-context update
callback is **edge-triggered**: it is not invoked again until the outstanding notification is
acknowledged by calling `mpv_render_context_update()`.

As a result the item receives exactly **one** `on_mpv_redraw`, renders a single frame, and the
render pump then stalls permanently. Audio continues normally while the video surface stays black,
and libmpv logs:

```
vo/libmpv: mpv_render_context_render() not being called or stuck.
```

Any *unrelated* repaint that marks the item dirty (a resize, or a fullscreen toggle) produces one
more frame. That is why "toggle fullscreen and it starts working" is such a common workaround
report — it is not a GPU or driver issue, it is the pump being restarted by an incidental relayout.

## Environment
- Windows 11 26200 (25H2)
- Qt 6, QtQuick scene graph on the **OpenGL** RHI backend (confirmed via `QSG_INFO=1`:
  `Creating QRhi with backend OpenGL`)
- GL context: `NVIDIA GeForce GTX 1060 with Max-Q Design`, `OpenGL 4.6.0 NVIDIA 582.78`
- libmpv `mpv-dev-x86_64-20261011-git-accb7b2821`
- mpvqt `2ebbd38bf65d01be9c55d673ecd43c8bb9a6fc8e`

Note: this is a hybrid-graphics (Optimus) laptop, but **that is not the cause** — see "What was
ruled out" below.

## Reproduction
A minimal Qt Quick app with nothing but a `MpvAbstractItem` subclass filling the window, plus an
animating `Rectangle` as a control to show the scene graph is otherwise healthy.

Instrumenting `mpvrenderer.cpp` with counters in `on_mpv_redraw` and `render()`:

**Before the fix**
```
[INSTR] on_mpv_redraw #1 (mpv wants a frame)
[INSTR] render() #1  fbo=0x... handle=1 size=2560x1440 valid=1
[INSTR] render() #2  fbo=0x... handle=1 size=2560x1440 valid=1
   ... nothing further, permanently. Video black, audio plays, control Rectangle keeps animating.
```

**After the fix** (single call added at the top of `render()`)
```
[INSTR] on_mpv_redraw #420 (mpv wants a frame)
[INSTR] render() #420  fbo=0x... handle=1 size=2560x1440 valid=1
   ... continuous 1:1 callback/render pairs. Video plays correctly.
```

The FBO was valid and correctly sized the whole time, and the item was `visible: true` with non-zero
geometry — so this is not a sizing, visibility or framebuffer problem.

## Proposed fix
```diff
 void MpvRenderer::render()
 {
+    // Consume the pending render update and re-arm mpv's update callback.
+    // The callback is edge-triggered; without this libmpv never notifies again
+    // and the render pump stalls after the first frame.
+    mpv_render_context_update(m_mpvAItem->d_ptr->m_mpv_gl);
+
     QOpenGLFramebufferObject *fbo = framebufferObject();
```

Optionally the return value can be checked for `MPV_RENDER_UPDATE_FRAME` to skip redundant work,
but the acknowledgement itself is the required part.

## What was ruled out (so reviewers don't re-tread it)
- **GPU / driver / mpv itself**: a ~160-line plain Win32 + WGL app using
  `MPV_RENDER_API_TYPE_OPENGL` directly renders **711/711 frames correctly** on the same machine,
  same GL context (NVIDIA), same `nvdec`/`cuda[p010]` decode path. That app calls
  `mpv_render_context_update()` each cycle — which is exactly what differs.
- **Hybrid-graphics / cross-adapter presentation**: identical adapter topology in the working
  plain-Win32 case.
- **Qt RHI backend mismatch**: scene graph confirmed on OpenGL, not D3D11.
- **Item geometry / visibility**: item is sized and `visible: true`; FBO valid at 2560x1440.
- **hwdec / vo / gpu-api**: all irrelevant — nothing downstream matters when render is never driven.
- **GPU driver age**: reproduced before and after an Intel display-driver update.

## Impact
Any mpvqt consumer on a build where the scene graph does not happen to repaint the item for other
reasons will see black video with working audio. Downstream, this is the long-standing
jellyfin-desktop "video only appears after toggling fullscreen" bug.
