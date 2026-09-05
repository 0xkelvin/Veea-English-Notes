# Veea Product Backlog

## Home Screen & Lock Screen Widgets

### 1. Pronounce on Widget Tap (Audio Playback from Widget)
- **Status**: Backlog / Deferred
- **Feature Request**: When the user taps the home screen or lock screen widget, pronounce/speak the current English vocabulary word aloud using Text-To-Speech (TTS) audio.
- **Current OS Architecture Constraints**:
  - Native iOS WidgetKit (and Android AppWidget) runtime environments do not support direct ambient audio playback without an active audio session or without bringing the host app into the foreground.
  - Interactive widgets on iOS 17+ and Android 12+ enforce strict boundaries on execution time and prevent background extensions from acquiring audio output focus directly.
- **Interim Implementation**:
  - Tapping the widget advances/rotates to the next vocabulary word (configured via **"ROTATE ON WIDGET TAP"** in Settings).
- **Future Implementation Roadmap**:
  - Investigate iOS App Intents with background audio playback capabilities or pre-rendered audio asset playback via WidgetKit interactive buttons.
  - Explore Android `PendingIntent` integration with an audio foreground playback service.
  - Pre-render TTS audio clips into the shared App Group / shared container for instantaneous offline widget playback once OS audio support matures.
