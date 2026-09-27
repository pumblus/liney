# Liney

A light journal for words and photos on iPhone and iPad. Everything stays on your device: no account, no network, no analytics.

- Write entries with text, checklists, and photo groups
- Search and browse a timeline by day
- Import from Day One (JSON export with media)
- Export a portable Markdown ZIP
- Optional App Lock with Face ID, Touch ID, or passcode
- English and Simplified Chinese

## Build

Requires Xcode 26 or later; runs on iOS/iPadOS 17 and later. Open `Liney.xcodeproj`, select the `Liney` scheme, and run. The only dependency, [ZIPFoundation](https://github.com/weichsel/ZIPFoundation), is resolved by Swift Package Manager.

To run the tests:

```sh
xcodebuild test -project Liney.xcodeproj -scheme Liney -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Privacy

See the [privacy policy](https://pumblus.github.io/liney/privacy.html). Support: [pumblus.github.io/liney](https://pumblus.github.io/liney/).

## License

[MIT](LICENSE)
