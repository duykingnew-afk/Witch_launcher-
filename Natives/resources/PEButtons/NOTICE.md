# Notices

## Code — `PEButtons.m`
MIT License. Copyright (c) 2026 PE Buttons contributors.

## Textures — `textures/**`
The button, icon and joystick textures in `textures/classic/`, `textures/new/` and
`textures/empty/` come from the **TouchController** project:

- Project: https://github.com/fifth-light/TouchController
- Files: `touchcontroller/resources/texture/control/{classic,new}/…` and `touchcontroller/resources/texture/empty/*.9.png`
- Commit: `f8128cc2b70aa98b8e2a7da422a5eeb110c6001c`
- Copyright (C) fifth_light and TouchController contributors
- License: **GNU LGPL-3.0-or-later** — full text in `LICENSE`

Changes: files were renamed and copied into this layout; the Android 9-patch marker
border of `empty/*.9.png` was removed (the stretch regions are recorded in
`textures/nine.json`). No pixel of the artwork was altered. The conversion script is
`tools/import_touchcontroller.py` in the source repository.

As a whole this package is distributed under LGPL-3.0-or-later (the MIT-licensed code
is compatible with it). You may replace any texture with your own, see README.

"Minecraft" is a trademark of Mojang Studios / Microsoft. This project is not affiliated
with or endorsed by them or by the TouchController authors.
