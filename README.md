# Jax Riffle

Swipe your dock left and right to reveal more pages of apps, just like inside a folder.

- Rootless (Dopamine), iOS 15.0–16.x, iPhone
- 2–6 dock pages, each holding up to 4 apps
- Every page places its apps exactly where the normal dock does, including a page with only 1, 2 or 3 apps
- In jiggle mode, once the last page is full, a new empty page appears so you can drop an app onto it (swipe to it, or hold the dragged app near the dock's edge to flip pages, like folders)
- Page dots under the dock
- Puts your extra dock apps back after an unjailbroken reboot (see below)
- Plays fair with Safe Mode: every hook goes through Substrate (ElleKit) and nothing catches exceptions, so a crash drops SpringBoard into Safe Mode as usual

## Build

**On GitHub (no Mac needed):** every push to `main` builds the .deb on a GitHub-hosted Mac (`.github/workflows/build.yml`). Open the **Actions** tab, pick the latest **Build** run, and download **Jax-Riffle-deb** under Artifacts. The run fails if the arm64e slice isn't the iOS 14+ kind that SpringBoard on iPhone XS and newer needs.

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
| Dock Pages (2–6) | 3 | after respring |
| Show Page Dots | On | live |
| Always Show Empty Pages | Off | live |
| Flip Pages While Dragging | On | live |
| Restore Dock After Rejailbreak | On | live |

At the bottom of the page: **Copy Diagnostics** (puts a report about how the dock was laid out on the clipboard, to paste to the developer) and **Respring**.

## How it works

1. SpringBoard's own dock layout (`SBIconLocationDock`) and dock capacity are raised to 4 slots per page, so SpringBoard itself stores, saves and handles drag and drop for the extra apps, as one long row of slots. The dock's app list is found through the root folder's `dock`, and its stored capacity is raised too.
2. Positions aren't guessed. At the dock's normal size, SpringBoard's own dock layout method (`-[SBDockIconListView originForIconAtCoordinate:numberOfIcons:]` on iOS 16) is asked where it puts each app when the dock holds 4, 3, 2 and 1 apps, and every page puts its apps on exactly those spots. If that can't be measured on some iOS version, the apps are spaced evenly across the dock background instead.
3. Slots are read from coordinates without relying on their field order (iOS 16 swapped the row and column fields).
4. The dock's icon list is moved into a paging scroll view, one page wide and clipped to the rounded dock background. Drops on any page land on the spot under your finger.
5. Safety net: if SpringBoard ever places a dock app without asking the tweak, the app is moved back to its page spot after the layout pass.
6. SpringBoard's drop handler reports where a dragged app is, to flip pages at the edges.

## Good to know

- **Pages fill in order.** The dock is one list, so an app always joins the end of the filled pages, and removing an app from an earlier page pulls the next app forward (the way apps flow on Home Screen pages). Dragging one of a full page's own apps onto the empty page leaves it at the end of that page.
- **Reboots:** Dopamine boots without tweaks after a restart, and SpringBoard then moves every dock app past the 4th out of the dock. With *Restore Dock After Rejailbreak* on, the tweak keeps a copy of your dock in `/var/mobile/Library/Preferences/com.alienjax.riffle.dock-backup.plist` and puts those apps back the next time it loads.
- **Lowering the page count or uninstalling:** first drag apps off the pages that will go away; SpringBoard moves anything that no longer fits out of the dock.
- Right-to-left languages: pages work, but a part-filled last page lines up from the start instead of being centred.
- Other tweaks that change the dock layout (Atria, Boxy and similar) may conflict.
- iPad isn't supported.

## Troubleshooting

- **Something looks wrong:** Settings → Jax Riffle → **Copy Diagnostics**, then paste the report to the developer. It lists the iOS version, which SpringBoard methods exist, what was measured, the frames used and where the apps ended up. It contains no personal data. (The same report is at `/var/mobile/Library/Preferences/com.alienjax.riffle.diagnostics.txt`.)
- **Dock unusable:** Settings → Jax Riffle → turn off **Enabled** → **Respring**, or uninstall the package. Safe Mode works as usual.
- The tweak also logs to the system log with the prefix `[JaxRiffle]` (Console.app on a Mac with the phone connected, or `oslog` on the phone).
