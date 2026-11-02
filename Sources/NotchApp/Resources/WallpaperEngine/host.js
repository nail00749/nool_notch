/* NooL's local scene bridge. Imported SceneScript and network access stay disabled. */
(() => {
  'use strict';
  window.NooLUniformCache?.install();
  let scene = null;
  let destroyed = false;
  let heartbeat = 0;
  let applied = null;
  let state = { playing: false, framesPerSecond: 60, volume: 0, scaleMode: 'fill', cursor: null };
  const send = (value) => window.webkit?.messageHandlers?.noolWallpaper?.postMessage(value);
  const fail = (error) => {
    // A rejected mount attaches its otherwise inaccessible instance to the error.
    try { error?.instance?.destroy({ releasePkgCache: true }); } catch { /* Still release the host-owned instance below. */ }
    if (destroyed) return;
    try {
      send({ status: 'failure', message: String(error?.message || error).slice(0, 400) });
    } finally {
      destroy();
    }
  };
  const fit = (mode) => mode === 'fit' || mode === 'contain' ? 'contain' : mode === 'stretch' ? 'stretch' : 'cover';
  const apply = (patch) => {
    if (destroyed || !patch || typeof patch !== 'object') return;
    state = { ...state, ...patch };
    if (!scene) return;
    const requestedFps = Number(state.framesPerSecond);
    const fps = Number.isFinite(requestedFps) ? Math.max(1, Math.min(120, requestedFps)) : 60;
    const scale = fit(state.scaleMode);
    const playing = !!state.playing;
    const cursor = state.cursor && Number.isFinite(state.cursor.x) && Number.isFinite(state.cursor.y)
      ? { x: Math.max(0, Math.min(1, state.cursor.x)), y: Math.max(0, Math.min(1, state.cursor.y)) } : null;
    if (!applied || applied.fps !== fps) scene.setFps(fps);
    // Audio remains off until a future explicit audio permission/control feature.
    if (!applied) scene.setVolume(0);
    if (!applied || applied.scale !== scale) scene.setFit(scale);
    if (!applied || applied.cursor?.x !== cursor?.x || applied.cursor?.y !== cursor?.y) {
      if (cursor) scene.pushPointer(cursor.x, cursor.y, 0);
      else scene.pointerLeave();
    }
    // resume() resets the engine's frame clock/meter. Cursor updates must not call it.
    if (!applied || applied.playing !== playing) {
      if (playing) scene.resume(); else scene.pause();
    }
    applied = { fps, scale, playing, cursor };
  };
  const timer = setInterval(() => {
    if (!scene || destroyed) return;
    const stats = scene.stats;
    if (stats.running && stats.fps > 0) send({ status: 'frame', frame: ++heartbeat, fps: stats.fps });
  }, 1000);
  const destroy = () => {
    if (destroyed) return;
    destroyed = true;
    clearInterval(timer);
    window.removeEventListener('error', onWindowError);
    window.removeEventListener('unhandledrejection', onUnhandledRejection);
    const owned = scene;
    scene = null;
    owned?.destroy({ releasePkgCache: true });
  };
  // Do not preventDefault: the original browser error remains visible to diagnostics.
  const onWindowError = (event) => fail(event.error || new Error(event.message || 'Wallpaper script failed'));
  const onUnhandledRejection = (event) => fail(event.reason || new Error('Wallpaper promise failed'));
  window.noolWallpaper = {
    apply, destroy, stop: destroy,
    getState: () => ({ playing: state.playing && !destroyed, cursor: state.cursor, stats: scene?.stats ?? null,
      uniformCache: window.NooLUniformCache?.stats() ?? null, destroyed })
  };
  window.addEventListener('pagehide', destroy, { once: true });
  window.addEventListener('error', onWindowError);
  window.addEventListener('unhandledrejection', onUnhandledRejection);
  (async () => {
    const [pkgResponse, projectResponse] = await Promise.all([
      fetch('noolwe://runtime/project/scene.pkg'), fetch('noolwe://runtime/project/project.json')
    ]);
    if (!pkgResponse.ok || (!projectResponse.ok && projectResponse.status !== 404)) throw new Error('Unable to load local wallpaper files');
    const [pkg, project] = await Promise.all([
      pkgResponse.arrayBuffer(), projectResponse.ok ? projectResponse.json() : Promise.resolve({ type: 'scene', file: 'scene.json' })
    ]);
    if (destroyed) return;
    const mounted = await WebWallGL.mount(document.getElementById('wallpaper'), {
      source: WebWallGL.bytesSource(pkg, project),
      scripts: false, autoplay: false, fps: 60, volume: 0,
      audio: null, media: null, bake: false, debugHooks: false,
      renderDpr: window.devicePixelRatio || 1,
      fit: fit(state.scaleMode), mountTimeoutMs: 45000,
      onError: fail,
    });
    if (destroyed) { mounted.destroy({ releasePkgCache: true }); return; }
    scene = mounted;
    apply(state);
    send({ status: 'ready' });
  })().catch(fail);
})();
