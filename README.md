# Screen Recorder

A native macOS app for recording your screen, webcam and microphone, then turning the result into a polished video without a subscription.

## Features

**Recording**
- Record a whole display, a single window, or a dragged-out area, with live previews of the screen and camera before you start.
- Webcam, microphone and screen (app/system) audio, each saved as its own track, with live mic level meters.
- Pause and resume to record several takes into one project, or import existing videos.

**Editing**
- Camera layouts: four corners (landscape, portrait or square, small or large), large and centred, or hidden. Change them anywhere on the timeline with smooth transitions.
- Zooms with an adjustable focal point, smooth easing and light motion blur. Auto-zoom suggests zooms from your clicks.
- Split, trim and delete sections of a take, with undo/redo.
- Styled frame: gradient or image backgrounds (kept in a reusable library), padding, rounded corners, shadow, or full screen.
- Webcam background blur (on-device person segmentation) and rounded, mirrored camera.
- Separate volume and mute for the mic and screen audio.

**Transcript and subtitles** (macOS 26 or later)
- On-device transcription with word timings.
- Edit the video by deleting words or sentences from the transcript.
- Burned-in subtitles with the spoken word highlighted, editable without cutting the video, plus `.srt` export.

**Export**
- 16:9, 9:16 and 1:1 from one edit (portrait and square follow the cursor), at 1080p, 1440p or 4K, 30 or 60 fps, HEVC or H.264.

## Requirements

- macOS 15 or later (transcription needs macOS 26)
- Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Building

```sh
xcodegen generate
open ScreenRecorder.xcodeproj
```

Or from the command line:

```sh
xcodegen generate
xcodebuild -project ScreenRecorder.xcodeproj -scheme ScreenRecorder -configuration Release -derivedDataPath build
open "build/Build/Products/Release/Screen Recorder.app"
```

The app is signed ad-hoc by default, which is fine for running on your own Mac. On first use macOS asks for Screen Recording, Camera and Microphone permission.

### Signing with your own Developer ID

Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and fill in your team and bundle ID prefix. That file is ignored by git.

To build a notarized DMG, also copy `scripts/release.local.env.example` to `scripts/release.local.env`, store your notary credentials once with `xcrun notarytool store-credentials`, then run:

```sh
scripts/release.sh
```

## Project layout

- `Sources/RecorderCore` – the engine: project model, timeline and layout maths, Core Image renderer, AVFoundation composition and export, transcription and subtitles. Built as a Swift package so it can be tested on its own.
- `App/Sources` – the SwiftUI app: capture (ScreenCaptureKit, AVFoundation), editor, timeline and inspector.
- `Tests/RecorderCoreTests` – unit and rendering tests: `swift test`.

Projects are saved as `.screenrec` folders in `~/Movies/Screen Recorder`, with each take's screen, camera and audio kept as separate files.

## License

Public domain ([Unlicense](LICENSE)): use it however you like.
