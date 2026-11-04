# Icon sources

- `icon-1024.png` is the master app icon. It was generated with GPT image generation from the design council's brief: a white pointer with a cyan contrail on a twilight-indigo squircle. The 64–1024 px sizes in `Contrail/Assets.xcassets/AppIcon.appiconset` are scaled from it.
- The 16 and 32 px sizes are drawn separately with simpler, bolder shapes so they stay legible:

  ```sh
  swift design/small-icon.swift 16 Contrail/Assets.xcassets/AppIcon.appiconset/icon_16.png
  swift design/small-icon.swift 32 Contrail/Assets.xcassets/AppIcon.appiconset/icon_32.png
  ```

- The menu-bar glyph is drawn in code: `Contrail/UI/MenuBarIcon.swift`.

The Contrail name and icon aren't covered by the GPL. See the main README.
