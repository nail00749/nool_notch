# Wallpaper Engine scene import

## Scope

Import local `scene.pkg`, a `project.json`, or a project directory into a separate
`.noolwe` library item. Playback uses pinned, bundled WebWallGL 3.0.0 inside a
disposable WKWebView. The existing native Metal wallpapers remain unchanged.
The importer does not download Workshop content or require Steam credentials.

Compatible scene animations, particles and GLSL effects run live. The integration
is experimental: SceneScript, executable projects, web wallpapers, audio and
system-audio/Now Playing integration are not enabled. Video speed controls apply
only to video wallpapers. Frame rate, display assignment, visibility/sleep/power
pauses and scale modes apply to imported scenes.

## Boundaries

- Validate PKGV0009 and PKGV0012–0023 indexes without extraction, then validate the actual copy
  before atomic publication. Maximum package 512 MiB; scene/manifest JSON 2 MiB.
- Reject unsafe paths, overlapping/out-of-bounds entries, nonregular sources and
  symlinks; allow only macOS's exact `/tmp` and `/var` system aliases.
- Serve only fixed local resource URLs. Nonpersistent WebKit storage, network
  rules, CSP, permission/navigation delegates and `scripts:false` constrain the
  runtime. Imported projects receive no native file or command bridge.
- Stop the renderer on errors and reveal the system wallpaper. Unchanged state
  does not continually retry a failed scene; switching wallpapers recovers.
- Pause preserves the mounted scene. Repeated unchanged settings do not send
  JavaScript or recapture snapshots. Cursor polling runs only during playback.
- Snapshot is asynchronous and cached; the first available frame triggers system
  wallpaper synchronization only when the user's existing toggle is enabled.
- Each display owns its web process surface; large scenes can multiply memory/GPU
  cost. No CPU comparison with native Plexus is implied by functional tests.

## Verification

`NOOL_WE_NATIVE=1 xcrun swift test --filter WallpaperEngineWebViewTests` exercises
the repository's original synthetic PKG through import and rendering: animated
pixels, pause before loading, stable paused pixels, resume without reloading,
blocked file/traversal/HTTPS requests and malformed package failure.

`xcrun swift test --filter 'LiveWallpaper|WallpaperEngine'` additionally covers
import limits, persistence, existing renderer behavior and failure recovery.
`node --test Tests/WallpaperEngine/host.test.cjs` covers bridge startup/cleanup.

The fixture verifies the integration, not all Workshop effects. No real user
Workshop package was available for this implementation.

Pinned source, licenses, rebuild instructions and fixture generator:
[third_party/wallpaper-engine](../../third_party/wallpaper-engine/README.md).
Wallpaper Engine's own description of packed scenes:
[Editing downloaded wallpapers](https://help.wallpaperengine.io/en/functionality/editingwallpapers.html).
