# Jellyfin Desktop — video surface never paints until fullscreen toggle

Running diagnostic log. Machine: owner's Razer Blade (Windows 11).

---

## Phase 0 — Environment

### Machine / OS
| Item | Value |
|---|---|
| OS | Windows 11, build **10.0.26200.9711**, version 25H2 |
| Machine | Razer Blade, x64 |
| Panel | `BOE0747` (built-in), current mode **1920 x 1080 @ 60 Hz, 32-bit** |
| Scaling now | **125 %** (effective 120 DPI) — owner has also run 200 % |

### Graphics — this is a hybrid (Optimus) laptop
| Adapter | Driver | Attached display |
|---|---|---|
| **Intel UHD 630** | 30.0.101.1756 | **`BOE0747` built-in panel, 1920x1080 @60Hz** |
| **NVIDIA GTX 1060 Max-Q** | 32.0.15.8278 | **none** — `MonitorName` empty, `CurrentMode: Unknown` |

Source: `dxdiag /x`. **Hybrid: YES, render-offload (Optimus) with no mux.** The NVIDIA GPU has
no display outputs connected; the Intel iGPU owns the desktop, DWM composition and the physical
panel. Anything the dGPU renders must cross to the iGPU to be presented.

> `Win32_VideoController` separately reports NVIDIA at 3840x2160 — that is a stale/phantom WMI
> mode for an adapter with nothing attached. `dxdiag` is authoritative. Do not trust the WMI value.

### DPI discrepancy (feeds H2)
Panel is **1920x1080 physical** and Windows scaling is currently **125 %**.
The earlier in-app Player check reported `Screen 1920x1080 · DPR 2`, which implies the app believes
its surface is **3840x2160** — a **2x mismatch** against the real panel. Worth confirming whether
Qt is applying its own scale factor on top of (or instead of) the Windows one.

### Code under test
| Item | Value |
|---|---|
| Upstream repo | `jellyfin/jellyfin-desktop` |
| Commit | **`2cb4a4456fd29b5b62d825ef0e5df93ed6913328`** |
| Commit date | **2026-08-31T09:43:51+02:00** |
| Submodule `external/mpvqt` | `2ebbd38bf65d01be9c55d673ecd43c8bb9a6fc8e` (KDE mpvqt) |
| Working branch | `fix/video-surface-render` |
| Clone path | `C:\Users\User\Documents\Claude\jellyfin-desktop` (installed app untouched) |

**Correction to a prior assumption:** upstream `master` has had **no commits since 2026-08-31**.
The installed "2.0.0-dev Aug 31 build" and the "fresh nightly master build from Oct 17" are
therefore **the same source**. That A/B test did not compare two versions and should not be cited
as evidence that the bug survives a code change.

**`external/mpvqt` is the embedding layer** — KDE's Qt wrapper around libmpv's **render API**.
This is the prime suspect surface for H1/H2/H3.

### Toolchain present
| Tool | State |
|---|---|
| git | `C:\Program Files\Git\cmd\git.exe` |
| python | WindowsApps alias (may be a Store stub) |
| cmake | **MISSING** |
| ninja | **MISSING** |
| MSVC (`cl`) / msbuild / vswhere | **MISSING** — no Visual Studio installed |
| vcpkg | **MISSING** |

---

## Established facts carried in (owner-supplied, not re-verified)
- Standalone mpv renders the same file correctly on this machine.
- Jellyfin web client in a normal browser renders correctly.
- DOM instrumentation: every page layer over the video is transparent (rgba 0) at 1/3/6/12/25 s —
  the native video surface itself is not painting.
- No stable `playing` state: once no `playing` for 28 s; once it flapped playing/paused 8x between
  10–27 s, first `playing` ~11 s after the Play press.
- `setVideoRectangle` is **never called at play start**; it fires only at exit, as `(-1,0,0,0)`.
- Reproduces with the owner's JS/CSS injection disabled.
- Already ruled out (identical every time): `vo=gpu-next` vs default; `gpu-api=d3d11` vs `vulkan`;
  `hwdec=auto` vs `no`; HAGS on/off (rebooted); clean NVIDIA driver reinstall (DDU).

### Still to confirm
- How Jellyfin Media Player 1.12.0 fails here — **video only, UI only, or both.** Prior session saw
  the entire app window black (i.e. UI too), which would point away from an mpv-specific fault.
- Exact standalone mpv command line on a real media file (the verified-working line so far is the
  synthetic `mpv.exe "av://lavfi:testsrc2=duration=30:size=1920x1080:rate=30"`).

---

## Phase 1 — Experiments

### 1a. GPU assignment (per-app Graphics Settings)

Mechanism: `HKCU\SOFTWARE\Microsoft\DirectX\UserGpuPreferences`, value name = full exe path,
data = `GpuPreference=1;` (power saving / iGPU) or `GpuPreference=2;` (high performance / dGPU).

| Run | Setting | Result |
|---|---|---|
| 1a-i | `GpuPreference=1;` (Intel iGPU) | **App fails to launch at all.** Reverted; app launched again immediately on the default. |
| 1a-ii | `GpuPreference=2;` (NVIDIA dGPU) | Launches fine. Playback result: _pending owner test_ |
| default | (no entry) | Launches fine — the normal state. |

**1a-i is a result in its own right:** the app cannot even start when confined to the Intel iGPU.

> **Revert note.** The only key I added/removed is the `Jellyfin Desktop.exe` value under
> `UserGpuPreferences`. Pre-existing entries (games, CapCut, `jellyfin.exe` server, etc.) were
> never touched. To fully revert: delete the `...\Jellyfin Desktop.exe` value from that key.

### Driver age — previously unexamined, now the leading mechanism
| Adapter | Driver | Date | Role in this bug |
|---|---|---|---|
| **Intel UHD 630** | 30.0.101.1756 | **2022-08-01** | **Presents everything**: drives `BOE0747` panel, owns DWM composition |
| NVIDIA GTX 1060 Max-Q | 32.0.15.8278 | 2026-06-24 | Render-only, **no attached display** |

The owner's DDU clean-reinstall cleaned **NVIDIA**, which is *not* the presenting adapter.
Every previously-run mpv experiment (`vo=gpu-next`/default, `gpu-api=d3d11`/`vulkan`,
`hwdec=auto`/`no`) varied the **render** side only. The **present** side — a 4-year-old Intel
driver responsible for all composition — has never been varied or updated.

This is a concrete mechanism for **H5** and is consistent with:
- Jellyfin Media Player 1.12 also failing (different Qt, same Intel presentation path),
- standalone mpv working (simpler presentation path, no render-API interop into a Qt surface),
- the browser working (Chromium has far more mature fallback paths),
- the app refusing to launch when pinned to Intel (1a-i).

**Intel driver update:** owner authorised, but handed back to the owner to perform. This is an
OEM-customised Razer display driver (`oem80.inf`, `SUBSYS_20011A58`) on the only panel; a wrong or
generic package risks a black screen on the one display needed to recover. Owner to use Intel DSA
or Razer support. Note UHD 630 (8th/9th gen) is on Intel's **legacy** branch — expect ~31.0.101.21xx,
not a 2026-dated driver. **Not yet done; retest when it is.**

### 1e. Full mpv trace logging — BLOCKED
`msg-level=all=trace` + `log-file=` in `mpv.conf` produced nothing: no trace file, zero `[trace]`
lines in the app log. Under **libmpv the host owns logging** — Jellyfin Desktop calls
`mpv_request_log_messages()` at its own level, which caps what is forwarded, and `log-file` is a
CLI-only option. **Raising mpv verbosity requires patching the app** (Phase 4 / needs the build).

### 1h. hwdec — a previously "ruled out" result was INVALID
The app **overrides mpv properties at runtime**, after `mpv.conf` is parsed:
```
Set property: video-sync="audio" -> 1      (mpv.conf says display-resample)
Set property: hwdec="auto" -> 1            (overrides any mpv.conf hwdec)
Set property: hwdec-image-format="no" -> 1
```
**Therefore the owner's earlier `hwdec=no` test in `mpv.conf` never took effect** and must be struck
from the ruled-out list. `vo` and `gpu-api` are *not* runtime-set and are init-time-only options, so
those results stand.

The correct lever is the app's own `jellyfin-desktop.conf` → `video.hardwareDecoding`.

| Date | `hardwareDecoding` | mpv result | Picture |
|---|---|---|---|
| 2026-10-12 | `"copy"` | `d3d11va-copy` (copy-back to system RAM) | fails |
| 2026-10-20 | `"enabled"` | `nvdec` → `VO: [libmpv] 1920x1080 **cuda[nv12]**` | fails |
| 2026-10-20 | `"disabled"` | software | _pending owner test_ |

**The decode path is now properly varied and the failure is invariant across it** — direct CUDA
surface and copy-back-to-RAM both fail. What is common to *every* configuration ever tested is the
**presentation hop**: mpvqt render-API → D3D11 → DWM → **Intel** (the only adapter with a display).
That hop has never been varied, and is precisely what the minimal repro (1g) isolates.

> Config backup: `jellyfin-desktop.conf.bak-20261020` in the profile dir.
> Diagnostic block in `mpv.conf` has been **removed**; `mpv.conf` and `jellyfin-desktop.conf` are
> back to their pre-session state. App verified running normally afterwards.

### 1i. The embedding layer — THE KEY FINDING

`external/mpvqt` renders via **`MPV_RENDER_API_TYPE_OPENGL`** and contains an explicit guard:
```cpp
// src/mpvabstractitem.cpp:25
if (QQuickWindow::graphicsApi() != QSGRendererInterface::OpenGL) {
    "The graphics api must be set to opengl or mpv won't be able to render the video."
}
```
`src/main.cpp:231` sets `QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL)` **unconditionally**,
and on Windows `detectOpenGLEarly()` is an **empty no-op** with no ANGLE or software fallback
(`src/player/OpenGLDetect.cpp`). So the app hard-requires native desktop OpenGL.

**Which adapter provides that GL context on this machine:**
```
libmpv_render: GL_VENDOR  ='NVIDIA Corporation'
libmpv_render: GL_RENDERER='NVIDIA GeForce GTX 1060 with Max-Q Design/PCIe/SSE2'
libmpv_render: GL_VERSION ='4.6.0 NVIDIA 582.78'
libmpv_render: Detected desktop OpenGL 4.6
```
The GL context is **NVIDIA and healthy**. But NVIDIA **has no attached display**. So:

> **mpv renders into an OpenGL FBO on the NVIDIA GPU, and every frame must then cross to the Intel
> iGPU — the only adapter with a display — to be composited by DWM and presented.**

This is a confirmed cross-adapter OpenGL presentation path on an Optimus laptop. It is exactly the
shape of H1, and it explains why a fullscreen toggle (which forces swapchain/surface recreation)
jolts the picture into appearing.

### 1j. Software OpenGL test — INVALID (crashes)
Forcing `QT_OPENGL=software` did load Qt's bundled llvmpipe
(`GL_RENDERER='Gallium 0.4 on llvmpipe'`, `GL_VERSION='3.0 Mesa 11.2.2'`), which would have removed
the cross-adapter copy entirely. But Qt ships an **ancient Mesa (GL 3.0)**; `vo=gpu-next` needs GL
4.x, and even after dropping to `vo=gpu` **the app crashed seconds after startup**. No usable result.
Reverted.

---

## ⚠️ Correction: most of the previously "ruled out" list was never valid

With `mpvqt` using the render API, mpv's video output is **`VO: [libmpv]`** (confirmed in the log).
In that mode mpv does **not** own the output path — the host's GL context does.

| Previously "ruled out" | Actual status |
|---|---|
| `vo=gpu-next` vs default | **No-op.** The render API forces `vo=libmpv`; the `vo` setting never governs output here. |
| `gpu-api=d3d11` vs `vulkan` | **No-op.** Not consulted by the `MPV_RENDER_API_TYPE_OPENGL` path. |
| `hwdec=auto` vs `no` | **Never applied.** App re-sets `hwdec` at runtime after `mpv.conf` is read. |
| 2.0.0-dev Aug vs "Oct nightly" | **Same commit.** `master` has no commits since 2026-08-31. Not a version comparison. |
| HAGS on/off, DDU reinstall | Valid — but DDU cleaned **NVIDIA**, which is not the presenting adapter. |

**Net: almost nothing had actually been eliminated before this session.** The one genuinely
invariant factor across every configuration ever tried is the **cross-adapter GL presentation hop**,
which had never been varied.

---

## Phase 2 — Hypotheses

### H1. Hybrid-graphics adapter mismatch — **STRONGLY SUPPORTED, leading**
- **For:** GL context confirmed on NVIDIA; NVIDIA confirmed to have no display; Intel owns DWM and
  the panel. Cross-adapter copy is mandatory for every frame. Fullscreen toggle (swapchain
  recreation) is the known workaround shape for this class. Standalone mpv works (own window/
  swapchain, not Qt's GL FBO). Browser works (ANGLE→D3D11, not native GL). JMP 1.12 fails too —
  same Qt+GL+Optimus shape. App refuses to launch when confined to Intel (1a-i).
- **Against:** Pinning to NVIDIA (1a-ii) did not fix it — but that does **not** falsify H1, since
  NVIDIA still has no display and the Intel presentation hop remains either way.
- **Deciding experiment:** **1g minimal repro** (plain Win32 window + libmpv GL render API).
  Not yet built. Also: forcing Qt's GL onto Intel (NVIDIA Control Panel "OpenGL rendering GPU").

### H2. Video surface sized/positioned wrongly at play start — **OPEN, plausible secondary**
- **For:** `setVideoRectangle` never fires at play start, only `(-1,0,0,0)` at exit. Earlier Player
  check reported `Screen 1920x1080 · DPR 2` implying a 3840x2160 surface against a 1920x1080 panel.
- **Against:** A pure sizing fault would usually show a wrongly-placed or scaled picture, not a
  reliably blank one that a fullscreen toggle fixes.
- **Deciding experiment:** 1f instrumentation (needs build); 1b DPI sweep (cheap, not yet run).

### H3. Render-loop gating — **SUPPORTED, likely the proximate symptom of H1**
- **For:** `mpv_render_context_render() not being called or stuck` recurs; no stable `playing`
  state; audio proceeds normally while video never presents.
- **Against:** More likely the *observable* consequence of the presentation hop stalling than an
  independent root cause.
- **Deciding experiment:** 1f + 1g.

### H4. Transparent CEF layer over native surface under DWM — **WEAKENED**
- **Against:** DOM instrumentation shows every layer transparent (`rgba 0`) at all samples; nothing
  overlays the video. Reproduces with the owner's injection disabled.

### H5. Machine-level cause any libmpv-embedding app would hit — **SUPPORTED, overlaps H1**
- **For:** JMP 1.12 fails here too; standalone mpv and the browser both work. The common factor in
  the failing cases is Qt + native GL + cross-adapter present.
- **Still to confirm:** whether JMP 1.12 fails at **video only** or **whole UI** (prior session saw
  the entire window black, which would broaden this).

---

## Phase 3 — Gate report

### Confirmed root cause (confidence: **moderate-high**, ~75 %)
**Cross-adapter OpenGL presentation on an Optimus laptop.** `mpvqt` renders mpv's video into an
OpenGL FBO on the **NVIDIA** GPU, which has no display; the frame must then cross to the **Intel**
iGPU for DWM composition and presentation. That hop stalls, so the render context is never driven
to completion (`mpv_render_context_render() not being called or stuck`) and no picture appears until
a fullscreen toggle recreates the surface.

**Why not higher confidence:** the decisive experiment (**1g**, the minimal libmpv GL repro in a
plain window) has **not been built** — the machine has no C/C++ toolchain (no MSVC, CMake, Ninja or
vcpkg), and standing one up plus a Qt6 build of the app is a multi-GB, multi-hour task. Without 1g I
cannot fully separate "any GL-render-API embedding fails on this machine" (→ Option 3) from
"something specific in Qt/mpvqt's integration fails" (→ Option 1).

### How small would a fix be?
Three shapes, very different sizes:
1. **Workaround — force a surface/swapchain re-create after first frame** (mimic what the fullscreen
   toggle does). Small: likely tens of lines in the mpvqt item or the player window. Hacky, possibly
   flaky, but fast to try.
2. **Make Qt's GL run on the presenting adapter (Intel).** Not a code fix — config/driver level.
   Blocked: app refuses to launch when confined to Intel (1a-i), and the Intel driver is from 2022.
3. **Move off the GL render API** (e.g. to a D3D11 path, or out of the render API entirely).
   Large, and lands in `mpvqt` (a KDE dependency), not just this repo.

### Cost–benefit

| Criterion | **Option 1 — patch jellyfin-desktop** | **Option 3 — new app** |
|---|---|---|
| Time to working playback | **Days if workaround #1 works**; weeks if it needs #3 | **1–2 weeks** to first picture-on-Play milestone |
| Maintenance burden | Lower than feared — `master` has **not moved since 2026-08-31**, so rebase churn is currently low. But the real fix may belong in `mpvqt` (KDE), outside your control | You own it all; no upstream churn, but no upstream fixes either |
| Feature ceiling (LumaVision, DiscBrain, IzzyFlix) | Constrained by Qt/mpvqt's render-API abstraction; per-scene shader/tone-map control is awkward through it | **Highest** — direct libmpv control, full access to `vo=gpu-next`, custom shaders, dynamic properties |
| Risk of inheriting this bug | **High** for anything reusing the GL render API; low only if workaround #1 holds | **Very low** for the separate-window candidate — standalone mpv is *already proven working on this exact machine* |

### Option 3 architecture comparison
| Candidate | Verdict |
|---|---|
| **Separate borderless top-level mpv window + transparent web view over it** | **Recommended.** Uniquely, its video path is *already proven on this machine* (standalone mpv renders fine). Avoids the render API entirely, so it cannot inherit H1. Cost: window z-order, input routing, OSD compositing, fullscreen and multi-monitor handling are all real work. |
| **Tauri / WebView2 + libmpv** | Strong second. WebView2 is Chromium→ANGLE→D3D11 (proven working here via the browser); libmpv in its own window (proven). Small binary, good JS/CSS injection story. Same windowing caveats as above. |
| **Electron + libmpv** | Same shape as Tauri, heavier runtime, larger distribution. No advantage here. |
| **Fork jellyfin-desktop minus the video layer** | Inherits all the Qt complexity you'd be trying to escape, for little gain over a clean Tauri/WebView2 build. |

### Recommendation
**Try Option 1's cheap workaround first, with a hard timebox; fall back to Option 3 (separate mpv
window + WebView2/Tauri) if it fails.**

Reasoning: the fullscreen toggle already proves the pipeline *can* present correctly once the
surface is recreated — so a forced re-create after first frame is a genuinely plausible few-line
fix, and it is far cheaper than a rewrite. But it is a workaround over an architectural mismatch on
your specific hardware, so if it doesn't hold, do not sink weeks into Option 1: the evidence that a
separate top-level mpv window works on this machine is the single strongest datum we have, and
Option 3 built that way also *raises* your feature ceiling for LumaVision rather than constraining it.

**Caveat the decision should account for:** both the workaround and the confidence rating above rest
on H1 being correct, and H1 is not yet nailed down because 1g wasn't built. If you want the gate
decision made on solid ground rather than a 75 % call, authorise the toolchain install and I'll
build the minimal repro first — it is the single highest-value remaining experiment.

**STOPPING HERE for your decision.**

---

# ⚠️ GATE REPORT SUPERSEDED — 1g was built, and it overturns the conclusion above

## 1g. Minimal libmpv OpenGL render-API repro — **BUILT AND RUN**

Toolchain installed: MSYS2 + mingw-w64 gcc (winget; ~400 MB, not the 4 GB VS route).
libmpv dev package: `mpv-dev-x86_64-20261011-git-accb7b2821`.
Source: `C:\Users\User\Documents\Claude\mpv-repro\repro.c` (~160 lines, plain Win32 + WGL +
`MPV_RENDER_API_TYPE_OPENGL` — the same API `mpvqt` uses). Build command in the file header.

### Result: **the repro WORKS. Picture renders. Owner confirmed visually.**

```
[gl] GL_RENDERER = NVIDIA GeForce GTX 1060 with Max-Q Design/PCIe/SSE2
[gl] GL_VERSION  = 4.6.0 NVIDIA 582.78
Using hardware decoding (nvdec).
VO: [libmpv] 3840x1600 cuda[p010]
[repro] RESULT: 711 render calls, 711 frames over 30016 ms
```

The repro reproduces **every** environmental condition of the failing app — same machine, same
Optimus topology, GL context on **NVIDIA**, frames in a **CUDA** surface via **nvdec**, presented
across to **Intel** — and renders 711/711 frames at a steady rate with visible picture.

> One earlier run showed `0 renders` and was **void**: the UNC path had been mangled (`//` → `\`)
> and mpv never opened the file (`Cannot open file ... Invalid argument`). Recorded here so the
> number is not mistaken for a reproduction.

### Consequences for the hypotheses

| Hypothesis | Prior status | **Now** |
|---|---|---|
| **H1** adapter mismatch | leading, ~75 % | **KILLED.** The repro uses the identical cross-adapter path and works. |
| **H5** machine-level, any embedder | supported | **KILLED.** A libmpv GL-render-API embedder works fine on this machine. |
| **H3** render-loop gating | supported | **NOW LEADING.** The app's own log says `mpv_render_context_render() not being called or stuck` — i.e. **Qt never calls render**. The repro calls render on every update callback and works. |
| **H2** surface sized/positioned wrongly | open | **Promoted — likely the cause of H3.** `setVideoRectangle` never fires at play start. |

### Unified explanation (new leading theory)
The QQuickItem hosting the video has **no usable geometry at play start** — consistent with
`setVideoRectangle` never being called until exit. With a zero-sized / non-laid-out item, Qt's
scene graph never schedules a render pass for it, so mpv's update callbacks go nowhere and
`mpv_render_context_render()` is never driven — exactly the logged symptom. **Toggling fullscreen
forces a full relayout/resize**, the item finally gets geometry, and rendering starts. This also
explains why every mpv-side option was irrelevant: nothing downstream matters if Qt never renders.

This is a **small, localized, Qt-side bug**, not an architectural or environmental one.

---

> # ⏩ READ `HANDOFF-20261021.md` FIRST.
> **Root cause was found on 2026-10-21: QtWebEngine's `WebEngineView` compositor layer is
> opaque and covers the mpv video item, despite the page being fully CSS-transparent.**
> Proven by a `Ctrl+Shift+W` toggle of `web.visible` — hiding the web view reveals the video.
> Everything below this line predates that discovery; several conclusions in it were later
> corrected or falsified. The handoff has the current, accurate picture.

# STATUS 2026-10-20 (end of session): bug #1 fixed, bug #2 identified

There are **two independent faults**. The first is fixed and proven. The second is newly isolated.

### Bug #1 — mpvqt render pump stalls — **FIXED** (details in the next section)
One-line fix, verified in both a minimal Qt app and the full app build.

### Bug #2 — the video node is never composited — **OPEN**
With bug #1 fixed, the full app now runs a healthy render pump (1320+ renders, 1:1 with callbacks,
valid FBO 3840x2160, `VO: [libmpv] 1920x1080 cuda[nv12]`, GL on NVIDIA) — **and the picture still
does not appear.**

**Decisive test:** `MpvRenderer::render()` was made to `glClear` the FBO to **magenta** before mpv
draws. Result: **no magenta ever reached the screen.** Therefore the QQuickFramebufferObject's
scene-graph node is **not being displayed at all** — this is a compositing/occlusion problem, not an
mpv or render-pump problem.

**Leading theory:** the Jellyfin **web page content** stays opaque over the video. The
`WebEngineView` is transparent at the Qt level (`backgroundColor: #00000000`, confirmed), but the
page itself still paints the item **backdrop image** (visible in the owner's screenshot: Man of
Steel art + logo, while the timeline runs and audio plays). Jellyfin's web client toggles a
`transparentDocument` class on `<html>` for native-video playback; if that does not take effect, the
page covers the video surface completely. A fullscreen toggle forces a page relayout, the backdrop
clears, and the video becomes visible — which is exactly the reported workaround.

### ⚠️ CORRECTION (2026-10-21): the "offset video" finding was a TOOLING ARTIFACT
`tools/grab-window.ps1` and `tools/burst-capture.ps1` use **`PrintWindow`**, which returns stale
internal window content for GPU-composited (Qt RHI / OpenGL) windows. Proof: a 45 s burst taken
while the owner *did* press Play produced **pixel-identical frames** throughout.

**Therefore the earlier "video renders but is offset/cropped" conclusion (from `broken-novf.png`)
is NOT evidence and must be disregarded.** The geometry/`setVideoRectangle` theory built on it is
unproven. Use **`tools/burst-screen.ps1`** (real composited-screen capture via `CopyFromScreen`,
DPI-aware) for any future visual evidence.

### Verified real-screen evidence (2026-10-21, `logs/screen/`)
Window rect measured DPI-aware: **4096x2160** (4K projector, 200 % scaling). Earlier non-DPI-aware
tooling misreported this as 2048x1080, which also explains some confusing size numbers above.

| State | What the screen actually shows |
|---|---|
| Fullscreen / maximised, after Play | Viewfinder's `85-curtain.js` loader: **"MAN OF STEEL / STARTING THE FILM / 1 %"** with the colour-barcode bar, **frozen at 1 %**. No video. |
| After a window-state transition (→ windowed) | Curtain gone, **film plays correctly** (Legendary logo, timeline running, controls normal). |

The curtain is frozen at 1 % because it waits on the app player's `playing` signal, which is never
emitted in the initial state. This is consistent with the C++ chain traced below.

### Confirmed C++ chain for why `playing` never fires
```
mpv "core-idle" stays true
  -> PlayerComponent.cpp:543   m_playbackActive = !core-idle   (stays false)
  -> PlayerComponent.cpp:424   never reaches State::playing
  -> PlayerComponent.cpp:456   emit playing() never runs
  -> native/mpvVideoPlayer.js:546  player.playing.connect(onPlaying) never fires
  -> onPlaying() never runs, so neither of these happen:
       * dlg.style.backgroundImage = ''      (loading backdrop never hidden)
       * window.api.player.setVideoRectangle(0,0,0,0)   (line 178)
```
`setVideoRectangle` has **no C++ callers** — it is `Q_INVOKABLE`, called only from that JS handler.
So "setVideoRectangle never fires at play start" is a *symptom* of `playing` never firing, not an
independent fault.

**Still unexplained:** why mpv keeps `core-idle` true in the initial fullscreen/maximised state.
Both mpvqt fixes (re-arm + `report_swap`) are in the tested build and do **not** resolve it; a
window-state transition still does.

### Bug #2 — earlier characterisation (2026-10-20, from window captures) — SEE CORRECTION ABOVE
Window captures (`logs/broken-state.png`, `logs/broken-novf.png`, `logs/burst/`) settle what is
actually on screen, and it is **not** a compositing failure:

- **With Viewfinder OFF:** the video **does render** — a real movie frame — but it is **offset and
  cropped** (black bands top/left, picture pushed down-right, overflowing the client area).
- **With Viewfinder ON:** its `85-curtain.js` loading curtain (**"STARTING THE FILM"**) covers the
  whole window. The curtain ends on the app player's `playing` signal, and the Player check already
  showed **`playing` never fires** — so the curtain never lifts. **This is a third, separate issue,
  in Viewfinder, independent of bugs #1 and #2.**
- **Burst capture across a fullscreen toggle:** in one post-toggle frame the Jellyfin header had
  moved to the vertical middle of the screen with video only in the bottom strip — the whole content
  area displaced vertically.

**Conclusion:** bug #2 is a **video-surface geometry / coordinate-space mismatch**, not occlusion
and not a render stall. The surface is drawn as though it were full-screen-sized while the client
area is smaller, so it only looks correct when client area == screen (true fullscreen).
`setVideoRectangle` **never being called at play start** is the smoking gun — the rect is never set
to the client area.

**Ruled out as the cause of #2:** QML anchors (replacing the conflicting
`anchors.left/right`+`width`/`height` with `anchors.fill: parent` changed nothing), scene-graph
teardown (`SG INVALIDATED` never fires), window-surface recreation (1px window nudge recreated the
FBO but did not fix it), page occlusion (DOM fully transparent, verified live via DevTools).

**Where to look next:** `src/player/PlayerComponent.cpp:227 setVideoRectangle()` and its callers —
why it is never invoked at play start, and which coordinate space it would use if it were.

**Next steps for bug #2 (not done):**
1. Confirm whether `<html>` gets `transparentDocument` (and whether an opaque backdrop `<img>` or
   `background-image` remains) at play start, via the web inspector or DOM instrumentation.
2. If so, the fault is in the web-client/page layer (possibly interacting with the owner's
   JS Injector customisations), **not** in Qt/mpvqt.
3. Note bug #2 is almost certainly the fault the owner has been chasing all along; bug #1 was a
   second, genuine defect masking it.

> **Build state:** `external/mpvqt/src/mpvrenderer.cpp` currently contains the fix **plus** debug
> instrumentation (`[INSTR]` counters and the magenta `glClear`). The magenta clear and counters
> must be removed before any real use or upstream submission.

---

# ✅ BUG #1 ROOT CAUSE FOUND AND FIXED (2026-10-20)

**`MpvRenderer::render()` in `external/mpvqt` never calls `mpv_render_context_update()`.**

libmpv's render-context update callback is **edge-triggered** — it is not invoked again until the
outstanding notification is acknowledged via `mpv_render_context_update()`. mpvqt never calls it, so
the item gets exactly **one** `on_mpv_redraw`, renders one frame, and the pump stalls permanently.
Audio keeps playing; video stays black; libmpv logs `mpv_render_context_render() not being called or
stuck`. A fullscreen toggle marks the item dirty and yields one more frame — which is exactly why
that "fixed" it.

### Evidence (instrumented mpvqt, same machine)
| | `on_mpv_redraw` | `render()` | Result |
|---|---|---|---|
| Before fix | **1, then never again** | **2, then never again** | black video, audio fine |
| After fix | 420+ continuous | 420+ continuous | **plays correctly (owner confirmed)** |

FBO was valid at 2560x1440 and the item `visible: true` with real geometry throughout — so not a
sizing, visibility or framebuffer fault.

### The fix
```cpp
// src/mpvrenderer.cpp, top of MpvRenderer::render()
mpv_render_context_update(m_mpvAItem->d_ptr->m_mpv_gl);
```
Committed on branch `fix/rearm-render-update` in the `external/mpvqt` submodule (`0e20f42`).
Upstream draft (not submitted): `UPSTREAM-mpvqt-issue.md`. **The fix belongs to KDE's mpvqt, not to
jellyfin-desktop's own source.**

### Final hypothesis outcomes
| Hypothesis | Outcome |
|---|---|
| H1 adapter mismatch | **Killed** — plain Win32 repro renders 711/711 frames on the identical cross-adapter path |
| H2 geometry/sizing | **Killed** — item sized and visible, FBO valid |
| **H3 render-loop gating** | **CONFIRMED — this was it**, cause identified as the missing update-callback re-arm |
| H4 CEF overlay | **Killed** — all layers transparent; reproduces with injection disabled |
| H5 machine-level | **Killed** — reproduced in a 100-line Qt app; not environmental |

---

# REVISED GATE REPORT (superseded by the section above — retained for the record)

### Root cause (confidence: **high**, ~85 %)
Not the environment. **Jellyfin Desktop / mpvqt fails to drive the mpv render context**, almost
certainly because the video item lacks geometry/layout at play start, so Qt never schedules the
render pass. Proven by a minimal repro that works under identical hardware, driver, adapter-crossing
and decode conditions.

### Revised recommendation: **Option 1 — patch jellyfin-desktop.**
The earlier lean toward Option 3 rested on H1/H5, both of which 1g has now falsified. Specifically:
- The defect is in the **Qt integration layer**, which is in-tree (`src/`) or in the pinned
  `external/mpvqt` submodule — both patchable, and the submodule is pinned so there is no churn risk.
- Upstream `master` has **not moved since 2026-08-31**, so rebase burden is currently near zero —
  the "fast-moving 2.0-dev" concern does not apply right now.
- A rewrite (Option 3) would now be **solving a problem that does not exist**: the render API is not
  broken on this machine.
- Expected diff: **small** — geometry/visibility handling or render scheduling in the mpv item,
  plausibly tens of lines, in 1–3 files.
- Upstream acceptance: **good prospects**, since this will affect other users whose video item is
  laid out late, and the fix is principled rather than a hardware-specific hack.

Option 3 remains the fallback **only** if the Qt-side fix proves intractable; the feature-ceiling
argument for LumaVision/DiscBrain is real but does not justify a rewrite to fix this bug.

### Next step if Option 1 is chosen
1. Build jellyfin-desktop from source (needs Qt 6 — the significant remaining toolchain cost).
2. Instrument per Phase 1f: log the video item's size/visibility/DPI, every `setVideoRectangle`,
   every update-callback and `mpv_render_context_render()` call, on one clock.
3. Confirm the zero-geometry theory, fix, and regression-test across maximized/windowed/fullscreen
   at 125 % and 200 %.

---

## 2026-10-21 (later) — CONTROLLED RUN: the stated root cause is FALSIFIED

Run driven entirely via CDP (no human input, **fullscreen never touched**): app launched with
`QTWEBENGINE_REMOTE_DEBUGGING=9222`, navigated to Man of Steel's detail page, clicked Play.
Bug reproduced. Log: `Jellyfin Desktop.log` 16:18–16:20.

### Capture tooling — `burst-screen.ps1` is ALSO untrustworthy
All 37 frames of a 45 s burst were **byte-identical black**, including frames taken while the
home and detail pages were plainly rendering. Cause: it calls `GetWindowRect` (physical px,
4096x2160) and copies that region without mapping it to the desktop; at 200% scaling the request
runs off a desktop its process sees as 2048x1080, so every frame is black. **Three of four capture
tools have now produced false evidence.** Replacement: `tools/screencap2.ps1` (calls
`SetProcessDPIAware`, then `GetSystemMetrics(76..79)`; verified by capturing the real desktop).

### §2's "ROOT CAUSE" does not survive measurement
| Prediction (from §2) | Measured | Verdict |
|---|---|---|
| `core-idle` never false → `playing()` never emitted | `Entering state: playing` @15:52:37.809 and @16:19:31.947 | **FALSE** |
| JS never learns playback started | JS logs `stateChanged: 5 -> 4`, `videoPlaybackActive: true` | **FALSE** |
| Page stays opaque (backdrop painted) | `transparentDocument` on `<html>`; `.videoPlayerContainer` `background-image: none`; no `<img>` >200px; every layer at screen centre `rgba(0,0,0,0)` incl. `background-image` | **FALSE** |
| Hiding the web view reveals the video | `[INSTR] WebEngineView visible -> false` @16:20:26; screen brightness **0/765** at 16:20:28 and 16:20:30 | **FALSE** |

`onPlaying` therefore runs and clears the backdrop. The web view is not the occluder.

### What is actually true in the broken state
- mpv render pump healthy: `render() #1560`, continuous.
- `MpvVideoItem`: 2048x1080 logical, `visible: true`, FBO 4096x2160 (dpr 2) — geometry correct.
- `SG initialized` fires, `SG INVALIDATED` never does.
- State `playing`; audio plays; timeline advances.
- Screen is uniformly black (0/765) **with the web view hidden**.

**So: mpv renders 1500+ frames into a correctly-sized FBO whose content never reaches the
screen, and nothing is covering it.** This agrees with the earlier magenta-`glClear` result
("no magenta ever reached the screen") and makes that the one piece of prior evidence that
still stands. The fault is in presentation of the `QQuickFramebufferObject` node, not in
occlusion, not in the page, not in the C++/JS state chain.

### Next probe (instrumentation only, not yet run)
`glReadPixels` one centre pixel of the FBO at the end of `MpvRenderer::render()` and log RGBA.
Distinguishes: real pixels with alpha=255 (presentation/compositing fault) vs alpha=0 (the item's
texture is blended away) vs black (mpv is not drawing into this FBO at all).

### ⚠️ RETRACTION (same day): the capture-based half of the section above is VOID

`tools/screencap2.ps1` is DPI-correct and captures the desktop and the app **windowed** (verified:
`logs/winmode/` shows the full Viewfinder UI). But with the app **fullscreen** every capture is
uniformly black (`max=0`) — including the home page, which is plainly visible to the owner, and
including a `#ff0000` div injected live at `z-index:2147483647`. Windowed capture of the same
window immediately after: `mean=95.9 max=765`.

**Conclusion: in fullscreen this window presents through a path GDI `CopyFromScreen` cannot see
(independent flip / MPO). No screen-capture tool can produce evidence about the fullscreen broken
state on this machine.** That is now **four of four** capture tools giving false evidence, and it
likely poisoned earlier sessions' captures too.

Therefore these claims from the section above are **withdrawn** — the measurements were real, but
they measured the capture path, not the screen:
- "hiding the web view does not reveal the video"
- "nothing the app draws reaches the screen"
- "§2's root cause is falsified"

The owner's direct observation (Ctrl+Shift+W → moving, in-sync video) stands, and occlusion by the
web view remains the leading theory. What survives from the controlled run is only the
capture-independent evidence:

1. **NEW, and solid — the FBO contains real video.** `glReadPixels` at the end of
   `MpvRenderer::render()`, render #120 during playback:
   `centre=188,196,148,a=255  left=68,56,63,a=255  upper=52,19,13,a=255  glErr=0x0`
   (#1–#5, pre-playback: all `0,0,0,a=255`.) So mpv draws real frames at **full alpha** into a
   correctly sized 4096x2160 FBO. The video content exists; nothing downstream is reading zeros,
   and an alpha-blending explanation is ruled out.
2. The C++/JS chain is healthy (`playing` emitted, JS receives it, `onPlaying` runs).
3. The page is genuinely transparent, `background-image` included.
4. `burst-screen.ps1`'s DPI defect is real and independent of the overlay issue.

**Next probe (capture-independent):** `QQuickWindow::grabWindow()` bound to a shortcut, saving a
PNG of what *Qt itself* composites. That bypasses DWM/MPO entirely and separates "Qt composites
the web layer over the video" from "Qt composites correctly and presentation to the display is at
fault".

---

## 2026-10-21 (evening) — ROOT CAUSE CONFIRMED capture-independently

New probe: `Ctrl+Shift+G` in `src/ui/webview.qml` calls `grabToImage` on the content item, the
video item and the web view separately, saving PNGs to `logs/grabs/`. This renders through the
scene graph, so it bypasses DWM/MPO and is immune to the capture failures above.

### Results, during a confirmed-broken fullscreen playback
| Grab | mean brightness | note |
|---|---|---|
| `video` (MpvVideoItem alone) | 97 / 29.6 | **real video frames** |
| `scene` (whole content item) | 21.8 / 141.3 | |
| `web` (WebEngineView alone) | 21.8 / 141.3 | **byte-identical to `scene`** |

`scene` and `web` are byte-identical (verified by file hash) whenever the web view is visible:
compositing the web layer over the video yields exactly the web layer, so the video contributes
**nothing** to the final scene.

Control that validates the method: with the web view hidden (`Ctrl+Shift+W`), the `scene` grab
changes to mean 38.5 and matches video content — so `grabToImage` **does** include the
`QQuickFramebufferObject` item. The caveat about FBO items being excluded does not apply here.

Pixel-level confirmation: the `web` grab is `Format32bppArgb` with **alpha=255 in every sample**
(989/989), while CDP simultaneously reports `transparentDocument` on `<html>`, every layer at
screen centre `rgba(0,0,0,0)` with `background-image: none`, and no element over half the viewport
with any painted background.

> **ROOT CAUSE: QtWebEngine composites the WebEngineView as a fully opaque surface
> (alpha=255 everywhere) despite `backgroundColor: "transparent"` and a fully CSS-transparent
> page. It sits at `z:100` over `MpvVideoItem`, whose FBO contains correct video at full alpha.
> A window-state change recreates the surface with working transparency — the fullscreen-toggle
> workaround.**

This vindicates §2 and supersedes the retraction above: §2's conclusion was right, its supporting
"page is opaque / playing never fires" reasoning was wrong, and the occlusion is real.

### Candidate fixes tested
| Candidate | Prediction | Result |
|---|---|---|
| `QTWEBENGINE_CHROMIUM_FLAGS=--disable-gpu-compositing` (env only, no code change; safe because `allowBrowserZoom:true` leaves `chromiumFlags` empty so `main.cpp` does not overwrite the var) | web layer gains alpha<255, video shows | **FAILED** — alpha still 255 everywhere, `scene==web` still byte-identical |

### Next candidates (untested)
1. Re-apply `web.backgroundColor = "transparent"` **after** first page load — a known Qt
   behaviour where the base background colour only takes effect if set at the right moment.
2. `QSurfaceFormat::setAlphaBufferSize(8)` in `detectOpenGLEarly()` before
   `QtWebEngineQuick::initialize()`. Note the Windows branch of `OpenGLDetect.cpp` sets **no**
   surface format at all, unlike the macOS branch.
3. Force a surface recreation off a real signal rather than a timer — but note the hide/re-show
   reset already failed, so this is the weakest option.

---

## 2026-10-21 — CANDIDATE 1 WORKS (experiment, not yet a shippable fix)

`mainWindow.reapplyWebBackground()` forces a real property change on the web view's base
background colour (assign `#01000000`, then `transparent` — assigning the same value twice is a
no-op, so Qt never propagates it to Chromium).

| When it is re-applied | web layer alpha | `scene==web` | scene vs video mean | Video visible |
|---|---|---|---|---|
| Never (baseline) | 255 / 989 samples | identical | 21.8 vs 97 | no |
| After page load only | 255 / 989 | identical | 51.9 vs 23.2 | no |
| **After load + 4x across first 5 s of playback** | **0 / 966 samples** (rest 46–95, the OSD bar) | **differs** | **78.1 vs 78.1** | **YES** |

Scene grab now shows the film (Alien's 20th Century Fox opening) — `logs/grabs/fixed-scene.png`.

**So the surface only turns opaque once video is playing underneath it, and re-applying the base
background colour at that point restores transparency.** Re-applying while the page is still the
library UI is too early, which is why the after-load-only variant failed.

### Still to do before this is a fix
1. Find the minimal deterministic trigger. The 4x1.2 s timer is a hack; the right trigger is
   probably `PlayerComponent`'s `playing()` / `videoPlaybackActive` signal, which the logs show
   fires reliably. Needs testing — one re-apply may be enough.
2. Confirm on the real display (the grabs prove what Qt composites, not what the projector shows;
   no screen-capture tool on this machine can check that).
3. Regression: windowed / maximised / fullscreen, 125% and 200%, 10 consecutive plays mixed
   4K HDR and SDR.
