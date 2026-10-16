# Changelog

## 0.1.0 (2026-10-16)

- Initial release of Backcap for iOS 6.x (`armv7`).
- Automatic background app limit: `0` (close immediately on Home button exit), `1` to `6` background apps, or `Unlimited`.
- Configurable eviction mode when the limit is exceeded: close the oldest app in the App Switcher or close the last used (previous) background app.
- Automatic removal of closed apps from the iOS 6 App Switcher bar.
- Lock screen cleanup: closes all unused background apps when locking the device, with an optional toggle to preserve the app that was on screen right before locking.
- Automatic protection for apps actively playing background audio (Pandora, Music, Spot6, Muzika, etc.), recording audio, or in an active phone call.
- Manual Protected Apps picker and one-tap "Close Background Apps Now" action in Settings -> Backcap.
- Full English and Czech (`en.lproj` and `cs.lproj`) localization.
