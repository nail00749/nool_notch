# Display refresh-rate mode selection

## Incident and evidence

Odyssey G95SC, direct HDMI, 5120×1440: the user reported whole-screen colored
noise after NooL switched 120→240 Hz. The 15-second trial reverted to 120 Hz,
but HDMI reconnection was required to recover. System Settings, Crisp and
BetterDisplay were reported to switch successfully.

The incident WindowServer log recorded NooL applying mode 434 at 14:29:03
and mode 436 at 14:29:20 on 2026-10-21 (Moscow time).
Read-only enumeration after the successful system switch showed:

| Mode ID | Logical / pixel size | Hz | I/O flags |
| --- | --- | --- | --- |
| 434 | 5120×1440 / 5120×1440 | 240 | 0x02000003 |
| 435 (current) | 5120×1440 / 5120×1440 | 240 | 0x02000007 |
| 436 | 5120×1440 / 5120×1440 | 120 | 0x02000003 |
| 437 | 5120×1440 / 5120×1440 | 60 | 0x02000003 |

The differing bit is `kDisplayModeDefaultFlag` (0x4), as defined by the
installed IOKit SDK. Mode IDs are connection-local evidence, not constants
to hardcode. Both duplicate-enumeration settings returned these candidates.

## Defect and fix

NooL discarded I/O flags and collapsed equivalent labels by first occurrence.
From 120 Hz this chose 434, whereas the working system selection was 435.
The fixed policy retains the current driver mode for an unchanged choice,
otherwise prefers the driver-default duplicate, with deterministic ordering.
Deduplication and refresh-rate choices retain exact pixel dimensions.
Preset resolution uses the same policy. Optional flags preserve decoding of
older mode descriptions. No HDR writes or confirmation timeout changes were added.

## Validation

- Regression tests cover the captured Odyssey catalog in both enumeration
  orders, preserving a current alternative, and rejecting pixel-size changes.
- A standalone native probe compiled the production DisplayModels.swift and
  used the same CGConfigureDisplayWithDisplayMode / forSession transaction as
  the service. It switched 435→436→435 at 14:55, receiving success for both
  commits. Ten reads over 20 seconds retained active mode 435 at 240 Hz.
- This probe did not run NooL's surrounding brightness/HDR observers or its
  confirmation panel. The user confirmed that the image remained normal
  after this transition. The installed Release UI path remains a separate
  check; a successful CG return alone is not proof of a correct physical image.
- The invalid 434 path was not deliberately reproduced again. The selection
  mismatch is established; internal monitor/link failure is not diagnosed.
