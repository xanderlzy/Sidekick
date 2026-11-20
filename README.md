# Sidekick

A small menu bar app with handy Mac tools you can turn on one at a time. Everything runs on your Mac: no accounts, and nothing you say leaves it.

**Requirements:** Apple Silicon Mac, macOS 26 or later.

## Install

1. Download `Sidekick-x.y.z.zip` from the [latest release](https://github.com/xanderlzy/sidekick/releases/latest) and unzip it.
2. Drag **Sidekick** into your **Applications** folder.
3. Open it. Sidekick isn't notarized by Apple, so macOS blocks it the first time:
   open **System Settings › Privacy & Security**, scroll down, and click **Open Anyway** next to the Sidekick message.
   (Or in Terminal: `xattr -dr com.apple.quarantine /Applications/Sidekick.app`.)
4. Follow the short setup. Sidekick updates itself after that.

## Tools

- **Dictation**: hold Fn and speak, let go to insert clean text wherever you're typing. Runs on-device.

Coming from Parrot? Turn on Dictation and your history comes with you.

## Development

```sh
brew install xcodegen
scripts/make-cert.sh                      # one-time: stable local signing identity
xcodegen && open Sidekick.xcodeproj
scripts/test.sh                           # unit + integration tests
scripts/release.sh 0.1.0 "What changed"   # build, sign, publish, update the feed
```
