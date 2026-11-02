# Bundled Wallpaper Engine scene player

NooL bundles **WebWallGL 3.0.0**, upstream revision
`197abe54266c31d346cebc314e49a26b70c960cc`:
https://github.com/oneincase/webwallgl/tree/197abe54266c31d346cebc314e49a26b70c960cc

`Sources/NotchApp/Resources/WallpaperEngine/webwallgl.global.min.js` is a
self-contained UMD browser bundle (1,106,821 bytes), not a CDN loader.
SHA-256: `a999f8dc251c3adc4c9c646c65c51a71d63dcc854cde40323849bd289c844863`.

## Licenses and corresponding source

- WebWallGL: MIT (`WebWallGL-LICENSE`).
- Bundled `renderer/vendor/we-scene`: MIT, aurora-wallpaper contributors
  (`we-scene-LICENSE`).
- Mediabunny **1.56.0**: MPL-2.0 (`mediabunny-LICENSE`, `BUNDLE-NOTICES.txt`).
  No local source modifications. Corresponding source as distributed by npm
  is included in `mediabunny-1.56.0-source.tar.gz` (src/, LICENSE, package.json).
  SHA-256: `fe3388cbb5ddecc10bd6d5c345a3dbc2b8bce6091353996a3ca0310ba9342c1a`.
  Upstream source: https://github.com/Vanilagy/mediabunny/tree/v1.56.0/src

The application's resources include the license texts and source-location
notice. Preserve these notices when redistributing the player bundle.

## Rebuild

Use an isolated temporary directory. Copy `package.json`, `build-package-lock.json`
(renamed `package-lock.json`), and `build-engine.mjs` there. Run
`npm ci --ignore-scripts --no-audit --no-fund`. Clone the pinned WebWallGL revision,
then link its `node_modules` to this isolated installation. Run:

```sh
node build-engine.mjs /absolute/path/to/webwallgl /absolute/path/to/output
```

This uses the same Vite GLSL/raw-text plugins and UMD/minification options as
upstream's build-lib/assemble-lib scripts. Electron and its build hooks are not
installed. The pinned lockfile includes build-only tooling; only Mediabunny is
incorporated as a third-party runtime dependency.

## Runtime and compatibility

Only the host's fixed local scheme serves assets. No network/CDN is necessary.
The host passes `scripts: false`, `audio: null`, `volume: 0`, `bake: false`,
`debugHooks: false`; imported SceneScript is disabled and CSP excludes eval,
workers, frames, and external connections. Blob/data images and blob media are
needed by built-in texture decoding. Inline style is allowed for engine canvas
layout, not inline scripts. Native pointer input uses `pushPointer(u, v)` with
normalized coordinates and a top-left origin.

Supported animation includes the engine's particle simulation, keyframes and
GLSL effects. Compatibility with every Workshop package is not guaranteed;
SceneScript-dependent interaction, Windows executable plugins and web wallpaper
projects are outside this import path. Playback-rate control is not exposed by
the player API. Real system audio and Now Playing are not connected.

## Synthetic fixture

`fixture/scene.pkg` is generated, original test content: a checker/gradient
texture, animated wave GLSL effect and snow particles. It is 18,383 bytes and
uses PKGV0012 with a TEX image container. It was produced through upstream's
image/effect/particle editor helpers and `buildScenePkg`, then parsed back with
`parsePkg/getEntry`. This proves a test pipeline, not real Workshop compatibility.
SHA-256: `b834d95eb4183bff60c3faaffa83c559fa4882d2ab04e03c77175712cfea4123`.
`generate-fixture.mjs` records the fixture generation logic.
