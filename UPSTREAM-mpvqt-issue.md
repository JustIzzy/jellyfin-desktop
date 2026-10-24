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

---
---

# SECOND ISSUE (added 2026-10-24) — higher impact than the one above

## Title
`MpvController::init()` never enables mpv config loading, so no consumer's `mpv.conf` is ever read — and the `mpvqt.conf` include is set too late to work

## Summary
`MpvController::init()` (`src/mpvcontroller.cpp`) calls `mpv_initialize()` without ever
setting `config=yes`. **libmpv defaults to `config=no`**, so mpv reads no configuration
file at all. Every option a host application ships in its config directory stays at
mpv's built-in default, silently.

The `mpvqt.conf` include is affected by a second, related bug. `config`, `config-dir` and
`include` are only honoured during mpv's option **pre-parse**, inside `mpv_initialize()`.
`init()` assigns `include` **after** `mpv_initialize()` has already returned:

```cpp
mpv_initialize(d_ptr->m_mpv);                      // pre-parse happens here
...
setProperty(QStringLiteral("include"), configPath); // too late - accepted, no effect
```

So mpvqt's own config file mechanism does not work either. On a default install the path
does not exist, which also means telling mpv to include it would emit a startup error.

## Evidence (measured)
Replicating this exact init sequence against a host's 10 KB `mpv.conf` and reading the
properties back:

| option | as mpvqt initialises | with `config=yes` + `config-dir` |
|---|---|---|
| `config` | **no** | yes |
| `glsl-shaders` | **(empty)** | the configured shaders |
| `tone-mapping` | auto | spline |
| `hdr-compute-peak` | auto | yes |
| `deband` | **no** | yes |
| `dither` | **fruit** | error-diffusion |
| `scale` | **lanczos** | ewa_lanczossharp |
| `icc-profile-auto` | **no** | yes |
| `blend-subtitles` | no | yes |

Every value differs. Confirmed live afterwards: with the fix applied, mpv immediately
began reporting on an option it had never seen before
(`Interpolation now requires enabling display-sync mode` — emitted only because
`interpolation=yes` was finally being read).

## Impact
Every mpvqt consumer silently loses its entire mpv configuration. Downstream in
jellyfin-desktop this meant user-authored shader chains, tone mapping, debanding,
dithering and ICC settings had never taken effect — tuning sessions were comparing
mpv defaults against mpv defaults.

## Suggested fix
Set `config=yes` and move the `include` before `mpv_initialize()`, guarding the include
on the file existing:

```cpp
d_ptr->m_mpv = mpv_create();
mpv_set_option_string(d_ptr->m_mpv, "config", "yes");
if (QFileInfo::exists(configPath))
    mpv_set_option_string(d_ptr->m_mpv, "include", configPath.toUtf8().constData());
if (mpv_initialize(d_ptr->m_mpv) < 0) { /* ... */ }
setProperty("vo", "libmpv");   // must stay after, must win over any vo= in config
```

Hosts then point `MPV_HOME` (or `config-dir`) at their own profile directory.

Implemented downstream as `JustIzzy/mpvqt` commit `1dd0a97` on branch
`fix/rearm-render-update`, with the host-side half in `JustIzzy/jellyfin-desktop`
commit `4e4f64e`.

## Note on scope
`vo=libmpv` is correctly set after `mpv_initialize()` and must stay there, so a config
file cannot select a different VO. That is intended, but worth documenting: it means
`vo=gpu-next` is unreachable through mpvqt, and gpu-next-only options are rejected at
runtime with `Tone mapping curve unsupported by vo_gpu, falling back`.
