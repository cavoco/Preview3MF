# Preview3MF

A macOS Quick Look extension for **.3mf files** (3D Manufacturing Format). Press Space on any `.3mf` file in Finder to see a 3D preview of the model — no slicer needed.

## Features

- **Quick Look integration** — press Space in Finder to preview `.3mf` files
- **3D rendering** with SceneKit — proper lighting, shading, and materials
- **Auto-rotating model** — spins around the vertical axis so you can see all sides
- **Interactive controls** — orbit and zoom with your mouse/trackpad in the preview
- **Multi-object support** — handles files with multiple mesh objects (Bambu Studio, PrusaSlicer, etc.)
- **Drag-and-drop** — drop `.3mf` files into the host app for inline preview

## Installation

1. Download the latest release (or build from source)
2. Move `Preview3MF.app` to `/Applications`
3. Launch it once — this registers the Quick Look extension
4. Go to **System Settings → Privacy & Security → Extensions → Quick Look** and make sure **PreviewExtension** is enabled
5. That's it — press Space on any `.3mf` file in Finder

> **Tip:** If Quick Look doesn't pick it up immediately, run `qlmanage -r` in Terminal to reset the Quick Look cache.

## Building from Source

Requires Xcode 15+ and macOS 13+.

```bash
git clone https://github.com/cavoco/Preview3MF.git
cd Preview3MF
xcodebuild -scheme Preview3MF -configuration Release build
```

Or open `Preview3MF.xcodeproj` in Xcode and hit Cmd+R.

## How It Works

`.3mf` files are ZIP archives containing XML model data. The extension:

1. Extracts all `.model` files from the archive (using [ZIPFoundation](https://github.com/weichsel/ZIPFoundation))
2. Parses `<vertex>` and `<triangle>` elements from the XML
3. Builds SceneKit geometry with per-face normals for flat shading
4. Renders with a 3-point lighting setup and auto-framed camera

## Project Structure

```
├── Preview3MF/              # Host app (SwiftUI)
│   ├── Preview3MFApp.swift
│   └── ContentView.swift    # Drag-and-drop preview UI
├── PreviewExtension/        # Quick Look extension
│   ├── PreviewViewController.swift
│   └── Info.plist           # UTI + QL config
└── Shared/                  # Used by both targets
    ├── ThreeMFParser.swift  # ZIP extraction + XML parsing
    └── SceneBuilder.swift   # Mesh → SCNScene with lighting
```

## License

MIT

