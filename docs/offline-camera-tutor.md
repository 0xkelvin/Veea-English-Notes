# Camera tutor — isolated development branch

Branch: `feat/offline-camera-tutor-20261128`, based on main `39a4f66` after PR #53.
This is an iPhone preview. Keep it separate from the release branch until physical
phone acceptance. No merge, App Store submission or phone deployment is implied.

## User flow

1. Notebook → camera icon → **Camera tutor**. **Scan text** still opens the existing OCR experience.
2. One-time model setup: **Download AI model · 2.6 GB** on Wi-Fi, with progress,
   verification and cancellation. Keep the page open; allow about 6 GB free during
   installation. Advanced users can import a compatible `.litertlm` file from Files.
   Leaving the app cancels the download; the next attempt starts from zero.
3. Aim the live back camera and take a photo, or choose one from Photos. The camera
   stops while studying the frozen scene. **New photo** returns to live preview;
   another explicit capture chooses the next scene.
4. Ask in English/Vietnamese by typing, or use on-device dictation when installed
   and available. Final speech submits the question. Follow-up questions retain
   the scene and completed conversation context. The lesson has bounded length.
5. Read the Vietnamese explanation and English answer. Optional read-aloud uses
   installed Apple voices; English-only playback can still work without a Vietnamese voice.
6. **Review & save word** opens Veea's existing editable word form and duplicate
   handling. Only the chosen word/meaning/examples are saved in the local notebook.
   Saved words are available in Listen, Review and the existing unlock-word picker;
   they never silently enlarge a saved app-unlock selection.

This learning mode has no account/Pro check. The existing one-app/one-word Free
and multiple-app/multiple-word Pro limits from #53 are unchanged.

## Review of the open-source implementation

Reference: [Google AI Edge Gallery](https://github.com/google-ai-edge/gallery),
commit `e4624ebf590d9b20da531f4f60b0a03f03609321` (Apache 2.0).
Its public tutor source is Android code under
`Android/src/app/src/main/java/com/google/ai/edge/gallery/customtasks/xrlanguageteacher/`.
Claude CLI and Codex reviewed the scene/session controller, frame preparation,
structured vocabulary extraction, retained context and speech coordination.

The reference sends a prepared frame on the first turn, reuses conversation
context for follow-ups, and extracts vocabulary through a second schema-guided
pass. Veea adapts those patterns with its own Flutter UI and one concise structured
reply containing both the explanation and cards. No Android source is copied.

The iPhone runtime is the official [LiteRT-LM Swift SDK](https://github.com/google-ai-edge/LiteRT-LM/tree/v0.18.1),
pinned to **0.18.1** through Swift Package Manager, including the real binary SDK.
There is no stubbed runtime or cloud inference fallback. Source models, wrapper
APIs and actual linker/build output were checked. The SDK is loaded lazily when
needed. Installed model data is separate from the app download.

On iPhone, image encoding uses CPU and language generation prefers GPU (with a
CPU fallback). Physical testing found that SDK 0.18.1's Metal vision delegate
cannot prepare Gemma 4's composite image operations. Its language model loads,
but creating the image conversation fails. The CPU image executor resolves this;
its cache has a separate `cpu-vision-v1` directory so old Metal vision caches are
not reused. The Mac keeps its working GPU image path.

The iPhone implementation uses Apple's installed on-device Speech recognition
and speech synthesis instead of Android-only ML Kit services. Recognition always
sets `requiresOnDeviceRecognition = true`; an unavailable language offers typed
input. Camera/microphone/audio are stopped on exit/background; completed idle
lessons can resume. Partial answers and late results cannot become saved cards.

## Model provenance and installation

Recommended model: `litert-community/gemma-4-E2B-it-litert-lm`.
The public model repository is not gated and declares Apache 2.0 at review time.
Download only starts through the user's setup action. The pinned artifact is:

- Revision: `6e5c4f1e395deb959c494953478fa5cec4b8008f`
- File: `gemma-4-E2B-it.litertlm`
- Bytes: `2,588,147,712`
- SHA-256: `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c`

[Model repository](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm)
· [Pinned source](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/tree/6e5c4f1e395deb959c494953478fa5cec4b8008f)

A staged install checks size, header and SDK metadata before atomic replacement;
cancellation/failure keeps the old model. Automatic download also checks the
pinned digest. Model storage is private Application Support and excluded from
backup; compiled caches are in Caches. Removing it never deletes vocabulary.
The model and generated test media stay out of Git. Apache license text and
source credits are available under Tutor settings → Open-source licenses.

## Supported hardware and build

Current preview: a real iPhone with an advertised 8 GB of RAM or more
(the native threshold accounts for iOS reporting less than the marketing size).
The runtime requires iOS 16+. The app's install requirement follows its existing
Xcode deployment-target setting (`RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET`), which
resolved to iOS 17 on the verification machine; no deployment target was changed.
The runtime also checks available process memory before load. Smaller devices
show an explanation, not simulated answers. This is not yet an Android or desktop
UI implementation, and a simulator cannot prove camera/speech/memory behavior.
No increased-memory-limit entitlement was added. Signed-device testing decides
whether the chosen model is reliable on each supported phone.

Build machines need Xcode, Flutter/CocoaPods and **git-lfs** for the official Swift
package checkout. For a local unsigned check, install git-lfs if missing, then:

```sh
GIT_LFS_SKIP_SMUDGE=1 flutter build ios --debug --no-codesign
```

The release payment build script, backend/account configuration, SKU and Screen
Time entitlements remain unchanged. Use the existing paid team for any signed
candidate. Do not treat an unsigned build as phone acceptance.

For a local camera-only build, use a separate bundle ID and notebook; do not
replace the user's TestFlight app or register its `veea` URL scheme. Back up any
test data before device file operations. **Never use `devicectl device copy to
--remove-existing-content` against an app container:** the empty-directory
cleanup attempted during this preview cleared the whole test container despite
a nested destination. Its model and five starter words were subsequently
restored. Leave imported-model source files in place or remove them individually
through Files instead; never apply this cleanup flag to the production app.

## Privacy and offline boundary

Tutor inference never uses the account API, online dictionary APIs or a hosted
AI. Images/audio/questions are not uploaded. Only the explicit model download
contacts Hugging Face/CDN; opening the model website is an external browser action.
Saved words remain in the existing device notebook with sync disabled. The normal
word editor's optional online dictionary lookup still requires its separate,
explicit user consent. Scene photos and conversation are ephemeral, not notebook
attachments. Model output is validated text, never commands, HTML or app settings.

The privacy manifest declares the disk-space check used to admit an installation.
It is now included in Runner's resources; the pre-existing file was not in that
build phase and used incorrect API category names, both fixed here.

**Before App Store submission:** audit the LiteRT-LM binary's file-timestamp and
system-boot-time API usage and provide applicable required-reason declarations
(or an updated SDK). The upstream SDK currently supplies no privacy manifest.
Do not invent declarations for the SDK's internal uses. This is not a completed
App Store privacy/release review; inspect the final archive and operator policy
before shipping this preview publicly.

## Verification and remaining device acceptance

Automated tests use synthetic fixtures and no deployed services. Real inference
was additionally run on the Mac with the pinned Gemma model, using the production
runtime/prompt/parser and a generated coffee-cup image. The runtime uses the Mac
memory probe on that host; iOS uses its per-process available-memory probe.
With all network access denied to the executable, it recognized the cup and
answered a contextual follow-up, including Vietnamese translations for coffee,
cup, order and please. The final check also cancelled actual generation, reset
the scene and completed another real image question (about 11 seconds for the
whole check on the test Mac). Claude independently tested a taxi scene and the
live engine lifecycle. This proves local execution, not physical iPhone behavior.

Verification on 28 November 2026:

- Flutter analyzer: no issues.
- Tutor model/controller/channel/UI/editor checks: **44 passed**.
- Native policy/download/cancellation/runtime checks: **257 passed**, also checked
  under ThreadSanitizer by Claude.
- Actual official SDK linked in unsigned iPhone Debug and Release builds; arm64
  Simulator also compiled. These are build checks, not signed-device acceptance.
- Existing native Screen Time regression suite passed.
- Full Flutter run: **878 passed, 8 skipped**, two pre-existing Home golden image
  failures and one unrelated cartridge-screen timing failure. All five tests in
  that cartridge file passed on an isolated rerun. Goldens were not regenerated.
- Compact light/dark and 200% text layouts were rendered and inspected.
- Signed local test on iPhone 17 Pro, iOS 27.2.1: app/model installation and camera
  capture succeeded. The user confirmed a Vietnamese/English explanation and
  vocabulary cards after the CPU-vision fix. The same GPU-language/CPU-vision
  configuration also passed real Mac inference, follow-up, cancellation and
  scene reset with networking denied. Phone voice, follow-up, save, interruption
  and memory-pressure acceptance remain pending.

Claude CLI independently reviewed and implemented the native integration, and
reviewed the Flutter flow. No deployed service, customer data or account/payment
configuration was used for these checks. Model weights and generated media are
not committed.

Before release, use a signed phone to test model setup/cancel/low storage,
Airplane Mode, camera rotation
and denied permissions, installed/offline English and Vietnamese dictation/voices,
several follow-ups, editor save/duplicates, retake, rapid cancel/reopen, background
and memory pressure. Confirm the notebook, Listen and native app locks still work.
