# Jax Riffle

Swipe your dock left and right to reveal more pages of apps, just like inside a folder.

- Rootless (Dopamine), iOS 15.0–16.x, iPhone
- Pages appear as you need them (up to 10), each holding up to 4 apps
- Apps line up with the Home Screen's columns, like the stock dock; pages after the first fill from the left
- Pressing the Home button takes the dock back to its first page (optional)
- In jiggle mode, once the last page is full, a new empty page appears so you can drop an app onto it (swipe to it, or hold the dragged app near the dock's edge to flip pages, like folders)
- Page dots under the dock
- Puts your extra dock apps back after an unjailbroken reboot (see below)
- Plays fair with Safe Mode: every hook goes through Substrate (ElleKit) and nothing catches exceptions, so a crash drops SpringBoard into Safe Mode as usual
- Can't freeze your phone: if SpringBoard ever gets stuck, Jax Riffle switches itself off within seconds, records where SpringBoard was stuck, and stays off until you turn it back on (see *Freeze protection*)

## Build

**On GitHub (no Mac needed):** every push to `main` builds the .deb on a GitHub-hosted Mac (`.github/workflows/build.yml`). It also attaches the .deb to a draft release for the version in `control` (drafts are only visible to you; publish it when you're happy with it), or you can download **Jax-Riffle-deb** from the run on the **Actions** tab. The run fails if the arm64e slice isn't the iOS 14+ kind that SpringBoard on iPhone XS and newer needs.

**On a Mac:** needs Theos with the iPhoneOS 16.5 SDK in `$THEOS/sdks` and Xcode (Xcode is what produces the arm64e slice).

```sh
make package FINALPACKAGE=1
```

The package lands in `packages/`. To build and install over SSH in one go:

```sh
export THEOS_DEVICE_IP=<iphone-ip>
make do FINALPACKAGE=1
```

## Settings

The settings live in the Settings app with your other tweaks (PreferenceLoader): **Settings → Jax Riffle**.

| Setting | Default | Applies |
|---|---|---|
| Enabled | On | after respring |
| Show Page Dots | On | live |
| Flip Pages While Dragging | On | live |
| Home Button Returns to Page 1 | On | live |
| Restore Dock | On | live |

At the bottom of the page: **Copy Diagnostics** (puts a report about how the dock was laid out on the clipboard, to paste to the developer) and **Respring**. If Jax Riffle has switched itself off, a **Switched Off** notice with a **Turn Back On** button appears at the top.

## How it works

1. SpringBoard's own dock layout (`SBIconLocationDock`) and dock capacity are raised to 4 slots per page, so SpringBoard itself stores, saves and handles drag and drop for the extra apps, as one long row of slots. The dock's app list is found through the root folder's `dock`, and its stored capacity is raised too.
2. Positions aren't guessed. The Home Screen's columns are read from where its app icons actually are (widgets ignored; any page with an app in every column will do), or else from SpringBoard's grid on a row without widgets (`-[SBIconListView centerForIconCoordinate:metrics:]`), or else from the grid's insets and spacing. A full dock page puts its apps exactly under those columns, like the stock dock. When the whole dock has fewer than 4 apps they're centred, as in the stock dock; later pages fill from the left, like Home Screen pages. Each page is the part of the dock background that's on screen. If the Home Screen can't be read, SpringBoard's own dock positions are used, and failing that the apps are spaced evenly.
3. Slots are read from coordinates without relying on their field order (iOS 16 swapped the row and column fields).
4. The dock's icon list is moved into a paging scroll view, one page wide and clipped to the rounded dock background. Drops on any page land on the spot under your finger.
5. Safety net: if SpringBoard ever places a dock app without asking the tweak, the app is moved back to its page spot after the layout pass.
6. SpringBoard's drop handler reports where a dragged app is, to flip pages at the edges.

## Freeze protection

0.3.0 could get SpringBoard stuck laying out the dock forever, which froze the phone until the system's watchdog restarted it after 3 minutes (with Dopamine, a "userspace panic" that turns tweak injection off). Since 0.3.1:

- Nothing in the tweak asks for a new layout from inside a layout pass (that is what starts a layout loop); when one is needed it is asked for on a later run loop turn. The page dots never reorder the dock's subviews.
- If the dock or its apps are laid out hundreds of times in one second anyway, or SpringBoard keeps moving the apps back out of the pages, the tweak switches itself off on the spot: every hook stands aside and the dock is handed back to SpringBoard.
- A watchdog thread checks every second that SpringBoard's main thread is still making progress. If it has been stuck for 10 seconds (20 while SpringBoard is still starting up), the tweak switches itself off and records where the main thread was stuck. If it is still stuck at 30 seconds (40 at startup), it restarts SpringBoard, so the phone is never frozen for the 3 minutes it takes the system to step in.
- After switching itself off, it stays off on later launches (a record in `/var/mobile/Library/Preferences/com.alienjax.riffle.safety.plist`), so a problem can't repeat on every respring. Settings → Jax Riffle shows why, and **Turn Back On** clears it. Installing a newer version also starts fresh.
- The diagnostics report starts with the reason and, after a freeze, where SpringBoard's main thread was stuck. The tweak is built with its function names kept so those addresses can be read.

## Good to know

- **Pages fill in order.** The dock is one list, so an app always joins the end of the filled pages, and removing an app from an earlier page pulls the next app forward (the way apps flow on Home Screen pages). Dragging one of a full page's own apps onto the empty page leaves it at the end of that page.
- **Reboots:** Dopamine boots without tweaks after a restart, and SpringBoard then moves every dock app past the 4th out of the dock. With *Restore Dock* on, the tweak keeps a copy of your dock in `/var/mobile/Library/Preferences/com.alienjax.riffle.dock-backup.plist` and puts those apps back the next time it loads.
- **Uninstalling:** first drag the extra apps out of the dock; SpringBoard moves anything past the 4th out of it.
- Right-to-left languages: pages work, but a part-filled last page lines up from the start instead of being centred.
- Other tweaks that change the dock layout (Atria, Boxy and similar) may conflict.
- iPad isn't supported.

## Troubleshooting

- **Something looks wrong:** Settings → Jax Riffle → **Copy Diagnostics**, then paste the report to the developer. It lists the iOS version, which SpringBoard methods exist, what was measured, the frames used and where the apps ended up. It contains no personal data. (The same report is at `/var/mobile/Library/Preferences/com.alienjax.riffle.diagnostics.txt`.)
- **Dock unusable:** Settings → Jax Riffle → turn off **Enabled** → **Respring**, or uninstall the package. Safe Mode works as usual.
- **"Switched Off" in Settings:** the tweak noticed a problem and turned itself off (see *Freeze protection*). Tap **Copy Diagnostics** and send the report, then **Turn Back On** if you want to try again.
- **Dopamine showed a userspace panic** ("no successful checkins from SpringBoard"): that was the 0.3.0 freeze. Install 0.3.1 or newer (or uninstall Jax Riffle) before turning tweak injection back on in the Dopamine app.
- The tweak also logs to the system log with the prefix `[JaxRiffle]` (Console.app on a Mac with the phone connected, or `oslog` on the phone).
