# Backcap

A Cydia Substrate tweak for jailbroken iOS 6 that automatically limits open background applications and closes unused background applications when locking the device — saving battery and preventing wear on the physical Home button.

## Features

- **Background App Cap (`0–6` or `Unlimited`)**:
  - `0 (Close Immediately on Home)`: closes an application as soon as you press the Home button to leave it.
  - `1–6`: keeps at most `1–6` background applications open and automatically closes excess apps when you open another application.
  - Choose whether to close the **Oldest App in Switcher** (default) or the **Last Used (Previous) App** when the limit is exceeded.
- **Clean App Switcher Bar**: removes closed applications from the iOS 6 multitasking bar so stale icons do not pile up.
- **Lock Screen Cleanup**: automatically closes all unused background applications when you lock / turn off the screen, with an optional toggle to keep the currently open foreground app.
- **Smart Media & Call Protection**: applications actively playing background audio (Pandora, Music, Spot6, Muzika, etc.), recording audio, or in an active phone/VoIP call are kept running automatically.
- **Protected Apps List**: pick any user or system apps in **Settings -> Backcap -> Protected Apps** to never close them automatically.
- **One-Tap Cleanup**: includes a **Close Background Apps Now** button right in Settings.
- **Bilingual**: full English and Czech (`en.lproj` and `cs.lproj`) localization.

## Installing

1. Add `http://repo.samcejko.eu/` to Cydia and install **Backcap**, or install the `.deb` from Releases with `dpkg -i` and respring (`killall SpringBoard`).
2. Configure your preferred limit and options in **Settings -> Backcap** (changes apply immediately without respringing).

## How it works

- `src/BCSpringBoard.m` observes `SBApplicationActivationStateDidChange`, `SBAwayControllerFrontLockedNotification`, and `SBAwayControllerRelockedNotification`, hooks `-[SBApplication setNowPlayingWithAudio:]` to track background audio sessions, and closes excess apps using the exact iOS 6 `SBAppSwitcherController` + `SBWorkspaceEventQueue` (`BKSTerminateApplicationForReasonAndReportWithDescription`) sequence.
- `src/BCPreferences.m` localizes the PreferenceLoader specifiers inside `com.apple.Preferences` and provides the `BCProtectedAppsController` app picker and instant cleanup action.

## Building

CI builds the package with Theos (armv7, deployment target iOS 6.0): see `.github/workflows/build.yml`.
