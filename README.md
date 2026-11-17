# SlideOver

iPad-style Slide Over for any Mac app window. Put a window into a narrow panel at the edge of the screen, slide it in and out with a gesture or a shortcut, and keep it floating over whatever you're working in.

Free and open source. If you find it useful, you can [buy me a coffee](https://buymeacoffee.com/deco10) ☕

## Features

- Any app window can go into Slide Over, on the right or the left side
- Slides in when you push the pointer against the screen edge, and out the same way
- Several windows at once: swipe between them, or open an overview of all of them
- Stays on top while you work in the app behind it
- Follows you to whichever desktop you're on
- Remembers each window's size and height
- Editable keyboard shortcuts, launch at login
- Quitting puts every window back where it was

## Install

Requires macOS 14 or newer.

1. Download `SlideOver.dmg` from the [latest release](../../releases/latest).
2. Open it and drag SlideOver into Applications.
3. Open SlideOver. macOS warns that it can't verify the app, because the app isn't notarized by Apple. Click **Done**.
4. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to SlideOver.
5. The setup window opens. Allow the two permissions below, then click **Relaunch SlideOver**.

SlideOver lives in the menu bar; it has no Dock icon.

### Permissions

- **Accessibility (required):** to move and resize other apps' windows and to react to shortcuts and trackpad gestures.
- **Screen Recording (recommended):** only for window previews (the floating copy, smooth sliding, the overview cards). Nothing is saved or sent anywhere.

## Use

| Default shortcut | Action |
|---|---|
| 🌐 ⌥ → / 🌐 ⌥ ← | Put the front window into Slide Over, right or left |
| ⌃⌥A | Put the front window into Slide Over on the current side |
| 🌐 $ or ⌃⌥S | Show or hide Slide Over |
| Hold ⌃⌥ + swipe left / right | Next or previous Slide Over window |
| Hold ⌃⌥ + swipe up, or ⌃⌥W | Show all Slide Over windows |
| ⌃⌥N / ⌃⌥P | Next / previous window (keep holding to see the switcher) |
| ⌃⌥D | Take the current window out of Slide Over |

You can also push the pointer against the screen edge to show or hide it, click the small tab at the edge, or click the bar above the window. In the overview, swipe a card up to take that window out of Slide Over.

Change the shortcuts under **Keyboard Shortcuts…** in the menu bar menu. (🌐 $ is the $ key next to Return on a Swiss keyboard.)

## Known limitations

- Following you across desktops sets the app to "All Desktops" by clicking through its Dock menu. This currently only works with macOS set to English or German.
- Apps that also have a normal window outside Slide Over can't be fully hidden, so a strip of the stashed window can show while you swipe between desktops.
- Some apps have a minimum width larger than the Slide Over panel.
- SlideOver relies on macOS behaviour that Apple doesn't officially support, so a macOS update can break parts of it.

## Build from source

```bash
git clone <this repository>
cd SlideOver
./build.sh --run
```

Needs Xcode (the adaptive app icon needs Xcode 26 or newer; older versions fall back to a plain icon). `./share.sh` builds a DMG; `./release.sh` builds a signed and notarized DMG if you have an Apple Developer ID.

## License

Copyright © 2026 deco10

SlideOver is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License, version 3, as published by the Free Software Foundation.
It comes without any warranty. See [LICENSE](LICENSE) for the full text.
