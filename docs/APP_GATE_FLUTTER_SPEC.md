# Veea English — App Gate ("Word Toll") Flutter Implementation Spec

Pass this file to your AI agent (or open it inside the `0xkelvin/Veea-English-Notes` Flutter repository) to implement the **App Gate** feature end-to-end.

---

## 1. Feature Summary & Design Rules

**Concept:** Before the user can open selected distracting apps (e.g., Instagram, X, TikTok, YouTube), Veea intercepts the launch and requires the user to type **1 English word** from their own saved notebook.

**Visual Rules (Strictly Enforced):**
- Follow Veea's existing theme palettes (`Paper Light`, `Night Dark`, `GameBoy Matrix Green`, `Cyberpunk Neon`, `OLED True Black`).
- `2px` hard borders, square corners (`BorderRadius.zero`), pixel typeface (`Handjet`), **zero animations**.

---

## 2. Guardrails & Word Selection Logic (Smart Review Queue)

### 2.1 Activation Guardrail
- Require at least **3 non-deleted words** in the local SQLite database before the user can enable App Gate in Settings.
- **Optional toggle:** *"Require 1 new word captured today before unlocking"* (`require_daily_capture`). If enabled and today's captured word count is `0`, redirect the user to the Add Word editor first.

### 2.2 Word Selection Priority (1 Word per Gate)
Query a single word from SQLite in this priority order:
1. **Previously Failed Gate Words:** `last_gate_failed = 1` (missed 2+ times on a previous gate).
2. **Recent Captures (Last 3 Days):** Words created within the last 72 hours (`created_at >= now - 3 days`) with `srs_stage < 3`.
3. **Spaced Repetition Due:** Words with `next_review_at <= now`, ordered by `srs_stage ASC, next_review_at ASC`.
4. **Fallback:** Least-recently reviewed active word (`ORDER BY COALESCE(last_reviewed_at, created_at) ASC LIMIT 1`).

---

## 3. Challenge State Machine & Retry Flow

Given a selected `Word` entry (`word`, `ipa`, `meaning`, `partOfSpeech`, `exampleSentence`, `source`, `day`):

### Stage 0 — Initial Prompt (Attempt 1)
- **Header bar:** `VEEA GATE` | `LOCKED · <TARGET_APP_NAME>`
- **Clues shown:**
  - Captured date + source + part of speech tag (e.g., `adj`).
  - User's native-language `meaning` in large pixel type.
  - If `exampleSentence` exists, render it with case-insensitive occurrences of `word` replaced by underscores (`___________`).
  - **Letter mask:** Show first letter, last letter, and total length: e.g., `p _ _ _ _ _ _ _ _ _ y` (`11 letters`).
- **Action:** User types the word into the text field and taps `Unlock`.
- **If match (case-insensitive, trimmed):**
  - Play offline TTS pronunciation of `word`.
  - Update SQLite: `srs_stage = srs_stage + 1`, `last_gate_failed = 0`, advance `next_review_at`.
  - Grant unlock pass for `pass_duration_minutes` (default `15` min) and dismiss gate / return to gated app.

### Stage 1 — First Wrong Attempt (`attempts == 1`)
- Clear text input.
- Auto-play offline TTS pronunciation of `word` + show `"Hear it"` button.
- Reveal `ipa` (e.g., `/prɪˈlɪməˌnɛri/`).
- Reveal the **2nd letter** in the mask (`p r _ _ _ _ _ _ _ _ y`).
- **If solved on Attempt 2:**
  - Keep `srs_stage` unchanged (`last_gate_failed = 0`), grant unlock pass.

### Stage 2 — Second+ Wrong Attempt ("Teach & Retype", `attempts >= 2`)
- Auto-play offline TTS pronunciation.
- Show the **full word** (`preliminary`) in a bordered box with label: `Attempt 2 failed · Memorise & type`.
- **Crucial rule:** As soon as `onChanged` fires with `text.isNotEmpty` (the user's first keystroke), **hide the full word** so they must finish typing it from short-term memory. Provide a `"peek again"` button that clears the input and re-shows the word if they blank again.
- **If solved after Stage 2:**
  - Reset `srs_stage = 0`, set `last_gate_failed = 1`, schedule `next_review_at` for later the same day, and grant the unlock pass.

---

## 4. SQLite Schema Migration

Add the following migration to Veea's local SQLite setup:

```sql
-- 1. Extend existing words table with SRS / Gate tracking columns
ALTER TABLE words ADD COLUMN srs_stage INTEGER NOT NULL DEFAULT 0;
ALTER TABLE words ADD COLUMN next_review_at INTEGER;
ALTER TABLE words ADD COLUMN last_reviewed_at INTEGER;
ALTER TABLE words ADD COLUMN last_gate_failed INTEGER NOT NULL DEFAULT 0;

-- 2. App Gate settings singleton row
CREATE TABLE IF NOT EXISTS gate_config (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  enabled INTEGER NOT NULL DEFAULT 0,
  pass_duration_minutes INTEGER NOT NULL DEFAULT 15, -- 5, 15, 30, or 0 (every open)
  require_daily_capture INTEGER NOT NULL DEFAULT 0,
  gated_apps_json TEXT NOT NULL DEFAULT '[]'
);

INSERT OR IGNORE INTO gate_config (id, enabled, pass_duration_minutes, require_daily_capture, gated_apps_json)
VALUES (1, 0, 15, 0, '[]');

-- 3. Gate completion history
CREATE TABLE IF NOT EXISTS gate_logs (
  id TEXT PRIMARY KEY,
  word_id TEXT NOT NULL,
  target_app TEXT NOT NULL,
  attempts INTEGER NOT NULL,
  passed_at INTEGER NOT NULL
);
```

---

## 5. Flutter ↔ Native Platform Channel Contract

Use a single `MethodChannel('app.veea.english/app_gate')`:

| Method | Direction | Arguments | Description |
| :--- | :--- | :--- | :--- |
| `requestPermissions` | Dart → Native | `{}` | Requests `AuthorizationCenter.shared.requestAuthorization` on iOS or `PACKAGE_USAGE_STATS` / Accessibility + `SYSTEM_ALERT_WINDOW` on Android. |
| `pickAppsToGate` | Dart → Native | `{}` | Opens `FamilyActivityPicker` on iOS or installed-apps checklist on Android; returns selected app tokens/package names. |
| `setGateEnabled` | Dart → Native | `{ enabled: bool, passMinutes: int }` | Enables/disables active shields or foreground service. |
| `grantPass` | Dart → Native | `{ targetApp: String, durationMinutes: int }` | Lifts the shield/overlay for `targetApp` for `durationMinutes` and schedules automatic re-lock. |
| `onGateTriggered` | Native → Dart | `{ targetApp: String }` | Navigates Flutter immediately to `AppGateScreen(targetApp: targetApp)`. |

---

## 6. Native OS Implementation Details

### 6.1 iOS (`FamilyControls`, `ManagedSettings`, `DeviceActivity`)
1. **Entitlements:** Enable `com.apple.developer.family-controls` in `Runner.entitlements`, plus `ShieldConfigurationExtension`, `ShieldActionExtension`, and `DeviceActivityMonitorExtension` targets sharing an App Group (`group.app.veea.english`).
2. **Shield UI (`ShieldConfigurationDataSource`):** Style the system shield in Veea's monochrome colours with primary button `"Spell 1 word in Veea"`.
3. **Shield Action (`ShieldActionDelegate`):** When tapped, write the pending `targetApp` token to shared `UserDefaults(suiteName: "group.app.veea.english")` and trigger a local notification / URL scheme (`veea://gate`) that opens `AppGateScreen`.
4. **Pass Window (`DeviceActivityCenter`):** When `grantPass` is called from Flutter after the user types the word, remove the application token from `ManagedSettingsStore.shield.applications` and start a `DeviceActivitySchedule` for `durationMinutes`. In `DeviceActivityMonitor.intervalDidEnd`, re-apply the application token to `ManagedSettingsStore.shield.applications`.

### 6.2 Android (`AccessibilityService` / `UsageStatsManager` + Overlay)
1. **Detection:** Create `VeeaGateAccessibilityService` listening to `AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED`. Check if `event.packageName` is in `gated_apps_json` and whether `unlocked_until[packageName] > System.currentTimeMillis()`.
2. **Interception:** If locked, launch `MainActivity` (or a dedicated `GateActivity` with `launchMode="singleInstance"`) with intent extra `gate_target_package`, routing Flutter directly to `AppGateScreen`.
3. **Pass Window:** When `grantPass` is called from Flutter, record `unlocked_until[packageName] = now + durationMinutes * 60_000` in SharedPreferences and finish/minimize the gate activity so the user returns directly to the unlocked target app.
