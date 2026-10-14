# kiri

kiri is a macOS menu-bar app that keeps your screenshots on a floating shelf, so you can collect many captures, add notes to them, and hand them all to an agent at once.

- Press **⌃⇧4** to capture. Drag a region, or click a highlighted button or panel to capture just that element. The selector stays open so you can keep capturing; **Esc** ends it.
- Each capture lands on a **shelf** along the top of the screen. **Click a capture** to copy it.
- Press **⌃⇧5** to see all captures full-screen. Add a typed or dictated **note** to any capture, then **Copy All**, **Copy for Agent** or **Save…** them.
- While kiri runs, the shelf is mirrored to your Mac's temporary folder, so an agent (such as Claude Code with the `/kiri` skill) can read the current captures and notes directly.

## Requirements

- **macOS 14 (Sonoma) or later.**
- **A Mac with Apple silicon** (M1 or newer). This build doesn't run on Intel Macs.
  To check: Apple menu  → **About This Mac** → look for "Chip: Apple M…".

## Install and first launch

kiri isn't signed by Apple yet, so macOS asks you to confirm before it opens the first time. This walks you through that once, then through the permissions kiri needs. It takes about two minutes.

### 1. Move kiri to Applications

1. Download `kiri-<version>.zip` from the [latest release](https://github.com/assassinave/kiri/releases/latest) and double-click it to unzip it.
2. Drag **kiri** into your **Applications** folder.

Open it from Applications, not from Downloads. Some features (Relaunch and Launch at login) may not work from the Downloads folder.

### 2. Open kiri the first time

Double-click **kiri** in Applications. macOS stops it and shows a warning. That's expected for apps that aren't signed by Apple. What you do next depends on your macOS version (Apple menu  → **About This Mac**).

**macOS 15 (Sequoia) or later**

1. On the warning, click **Done**. Don't click Move to Trash.
2. Open **System Settings → Privacy & Security**.
3. Scroll down to **Security**. You'll see a line saying kiri was blocked. Click **Open Anyway**.
4. Enter your Mac password if asked.
5. Open kiri again and click **Open Anyway** (or **Open**) on the confirmation.

The **Open Anyway** button shows up only after you've tried to open kiri, and only for a while afterwards. If you don't see it, double-click kiri again, then go back to Privacy & Security.

**macOS 14 (Sonoma)**

1. In Applications, **Control-click** (or right-click) **kiri** and choose **Open**.
2. Click **Open** on the warning.

If that doesn't offer an Open button, use the System Settings steps for macOS 15 above.

You only need to do this once. After that, kiri opens normally.

**If you're comfortable with Terminal**, this removes the "downloaded from the internet" mark, so macOS stops asking:

```sh
xattr -dr com.apple.quarantine /Applications/kiri.app
```

### 3. Find kiri

kiri lives in the **menu bar** at the top of the screen, as a small **K** icon. It has no Dock icon and no main window. Click the K for the menu.

### 4. Allow permissions

The first time kiri opens, a **Permissions** window lists four permissions with a status for each. Click **Allow…** next to each one:

| Permission | What kiri uses it for | Do you need it? |
|---|---|---|
| **Screen Recording** | Taking screenshots | **Yes**, kiri can't capture without it |
| **Accessibility** | Clicking a button or panel to capture just that element; scrolling the page under the selector | Optional. Without it, you drag to select |
| **Microphone** | Dictating notes about a capture | Optional. You can type notes instead |
| **Speech Recognition** | Turning dictation into text, on your Mac | Optional, same as Microphone |

- For **Screen Recording** and **Accessibility**, kiri opens System Settings. Turn on the switch next to **kiri** and enter your password if asked.
- For **Microphone** and **Speech Recognition**, macOS asks in a pop-up. Click **Allow**.
- Each status turns into a green check when it's allowed.

**After allowing Screen Recording, click Relaunch kiri** at the bottom of the window. macOS often applies it only after the app restarts. If macOS offers **Quit & Reopen**, that does the same.

You can open this window again any time from the K menu: **Permissions…**

### 5. Take your first capture

1. Press **⌃⇧4** (Control-Shift-4). The screen dims.
2. Drag a rectangle around what you want. If you allowed Accessibility, you can also just click a highlighted element.
3. The capture appears on a shelf along the top of the screen. Keep capturing; the selector stays open.
4. Press **Esc** (or right-click, or double-click) when you're done.

**Click a capture** on the shelf to copy it. Press **⌃⇧5** (or click the count at the end of the shelf) to see all captures, add notes, and copy or save them all.

Both shortcuts can be changed in **Settings…** in the K menu.

## Troubleshooting

**kiri doesn't open, and there's no Open Anyway button.**
Double-click kiri in Applications once more, then check **System Settings → Privacy & Security** again right away.

**Screen Recording is on in System Settings, but kiri still asks for it.**
Click **Relaunch kiri** in the Permissions window. If that doesn't help, select kiri in the Screen Recording list, remove it with the **–** button, then click **Allow…** in kiri again.

**macOS asks again later whether kiri can keep recording your screen.**
Newer macOS versions do this from time to time for screen-capture apps. Click **Allow** to keep using kiri.

**The screen is dimmed and I can't get out.**
Press **Esc**, right-click, or double-click.

**I don't see the K in the menu bar.**
On a crowded menu bar, icons can be hidden behind the notch. Quit some menu bar apps or hold ⌘ and drag icons to make room.

## Updating

Quit kiri from the K menu (**Quit kiri**), then replace the old copy in Applications with the new one. You may need to do step 2 again for a new download, and macOS may ask for some permissions again.

## Privacy

- Captures and notes stay on your Mac. kiri keeps them in memory and writes copies to your Mac's temporary folder, which macOS clears on its own. They aren't restored after you quit and reopen kiri; use **Save…** in the all-captures view to keep them.
- Dictation is processed **on your Mac**. kiri doesn't send audio to Apple's servers.

## Using kiri with Claude Code

`skills/kiri` is a Claude Code skill (`/kiri`) that reads the captures and notes on kiri's shelf and makes the changes the notes ask for in the current project. Install it by linking the folder into your skills directory:

```sh
ln -s "$(pwd)/skills/kiri" ~/.claude/skills/kiri
```

## Building from source

kiri is a Swift Package (no Xcode project). It needs a Swift 6 toolchain and macOS 14 or later.

```sh
swift build
swift test                 # layout tests (KiriCore)
./scripts/build_app.sh     # → build/kiri.app
open build/kiri.app        # it's a bundle; don't run the binary directly
```

`build_app.sh` signs with `$KIRI_SIGN_IDENTITY` if set, otherwise with a keychain code-signing identity named "kiri", otherwise ad-hoc. On an ad-hoc build it also resets kiri's privacy permissions (`KIRI_KEEP_TCC=1` skips that), because macOS doesn't carry permission grants over to a new ad-hoc build.
