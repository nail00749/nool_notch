# Wallpaper texture quality: whole-app CPU comparison

Measured 2026-10-21 after the user accepted the improved background and confirmed
the Odyssey desktop was visible. This measures the whole NooL process, not just
the renderer. CPU percentages use `top` convention: 100% is one fully occupied core.

## Method

- B: improved textures, Release UUID `C8F52493-3812-3487-A65E-8E22DC689C32`.
- A: saved previous Release UUID `8380ACAF-1A4B-311D-81A6-15BC4486262D`.
- Order B1 → A1 → A2 → B2. The first pass used the already-running app;
  subsequent passes restarted the same bundle with the selected binary and stable signing.
- Each pass: 20 seconds settling, then 15 CPU samples approximately 2 seconds apart;
  discarded the first `top` sample. No builds or profilers ran during measurement.
- Wallpaper preferences hash was identical before/after all four passes:
  `035c89ad4a3e6731898c6f77a985a9d4c0e40f7f12a4368b1036e9334c6e2c67`.
- User kept the Odyssey desktop visible and NooL panels closed. No settings changed.

## Results

| Pass | Mean CPU | Median CPU |
| --- | ---: | ---: |
| B1, improved | 16.24% | 14.50% |
| A1, previous | 14.86% | 14.50% |
| A2, previous | 14.78% | 13.70% |
| B2, improved | 13.06% | 13.00% |
| A combined | 14.82% | 14.15% |
| B combined | 14.65% | 13.35% |

Observed mean difference: −0.17 percentage points. These short passes show no
clear CPU increase from higher texture quality; they do not establish a CPU
improvement. Background work and newly randomized scenes after restart remain
sources of variation. GPU utilization and power consumption were not measured.

The improved Release was restored, its UUID checked, and signature verified by
the switching helper. No source implementation changed for this comparison.

Raw measurements: [JSON and top output](../benchmarks/wallpaper-quality/).
