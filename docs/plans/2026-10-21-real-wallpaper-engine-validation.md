# Real Wallpaper Engine packages: compatibility and CPU

Date: 2026-10-21. Release UUID `0A8703E7-56B2-30DF-883D-6279C9532893`.

## Sources

Public author repositories were downloaded for local testing only. Their artwork,
packages and screenshots are not included in the NooL repository or distribution.
The repositories contain MIT license files; game artwork remains attributable to
the respective creators. No Workshop downloader or Steam credentials were used.

| Project | Pinned revision | Package bytes | Container |
| --- | --- | ---: | --- |
| [CrossCode Title Screen](https://github.com/BlacRyu/Wallpaper-Engine-Crosscode-Title-Scene) | `4805eae5850e485207190b7acd8a41a07a30c9fe` | 9,206,344 | PKGV0009 |
| [Mega Man X – Endless Highway](https://github.com/BlacRyu/Wallpaper-Engine-Mega-Man-X-Highway) | `ccd9b82b89635dee5e016aa7a6fcdb3fcf171f3b` | 5,989,315 | PKGV0009 |
| [Diablo II – The Dark Wanderer](https://github.com/BlacRyu/Wallpaper-Engine-Diablo-II-Resurrected-Wanderer) | `9b9bfaf36ff0bef566b3a7eecf4e30d20ca615a1` | 17,601,259 | PKGV0012 |

SHA-256, respectively:

```
f5373f08e9e4a688891a51978724f45ee92a3b97f28ac2c2a324b6301bea2d3e
fe8baea7c7feab04bad5cadee340cdb1a15f8f5bbd11cd565d4fbf368e92f280
652098e9301781fb0a684fd1905528a078ea1cd71aa3a1c644cc3fbdb12f8bca
```

## Compatibility findings

The first CrossCode import failed because the importer only admitted v12–23.
Inspection of its 122-entry index confirmed the same layout and exact payload
bounds. Added explicit v9 support, without admitting unverified v10/v11. GIF
previews now become bounded first-frame PNGs; package/source bytes are unchanged.
Twelve importer tests passed, including malformed v9, bounds, preview size,
symlinks and first-frame conversion. Independent scoped review found no blocker
in these changes. Release build, signature verification and diff check passed.

All three real projects passed the native test with `NOOL_WE_FIXTURE` pointing to
their source directory: import into `.noolwe`, render, actual pixel changes, pause
stability, resume without remount, and blocked external/path-traversal requests.
This is not proof of complete visual compatibility:

- CrossCode: visible sky, city, water and foreground; animation runs. Its original
  scene has 23 script fields, and full scripted title/startup behavior is not supported.
- Diablo II: visible character/composition and animation; source has five particle
  objects, five effect fields and ten script fields. Exact Windows effect parity
  was not checked.
- Mega Man X: native test passes, but the captured frame shows a character against
  a largely blank background. Marked **visually incomplete**, not a successful
  compatibility result. Its 18 script fields are a possible factor, not an
  established sole cause. Excluded from the CPU comparison.

The three local imports remain available in the user's library. SceneScript and
audio remain disabled. The user's original wallpaper selection was restored.

## Whole-application CPU

User confirmed Odyssey desktop visibility. Display: 5120×1440, scale1×; configured
60 FPS (not a measurement of delivered FPS). Built-in screen and other preferences
were preserved. System-wallpaper sync was temporarily disabled, then restored.

Each pass restarted the same Release, waited20 seconds and took15 samples about
2 seconds apart, discarding the initial `top` sample. Sequence:
Plexus → CrossCode → Diablo II → Plexus. No builds or profilers ran during samples.

WebKit PIDs were taken from `launchctl print pid/<NooL PID>` service entries.
The PID set and wallpaper preferences were checked before/after every pass.
Only NooL and its own WebContent/GPU/Networking services were included; unrelated
browser processes were excluded. The GPU-service column below is **CPU used by
that process**, not hardware GPU utilization. 100% means one fully occupied core.

| Scene/pass | NooL CPU | WebKit CPU | Total mean | Total median |
| --- | ---: | ---: | ---: | ---: |
| Plexus A1 | 12.89% | 0.00% | 12.89% | 12.90% |
| CrossCode | 6.70% | 41.72% | 48.42% | 49.20% |
| Diablo II | 5.74% | 51.50% | 57.24% | 58.50% |
| Plexus A2 | 16.49% | 0.01% | 16.50% | 15.90% |
| Plexus combined | 14.69% | 0.01% | 14.69% | 14.95% |

CrossCode WebKit split: WebContent15.85%, GPU service25.87%.
Diablo split: WebContent36.73%, GPU service14.77%. Networking rounded to0%.
These short runs compare real configurations of different complexity; they do
not isolate engine overhead or prove a stable performance ratio across projects.
Real imported scenes are substantially more CPU-intensive here than native Plexus.

An initial attempt was discarded after `top` truncated an unrelated UTF-8 process
name and the collector failed decoding. Its finally block restored preferences;
the collector was fixed before the four successful passes above.

After completion, the original preferences Data matched the saved backup byte for
byte, including per-display selections and the system-wallpaper sync switch.
Raw samples: [benchmark data](../benchmarks/real-wallpaper-engine/).
