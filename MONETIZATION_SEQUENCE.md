# Veea English Notes — Monetization Sequence

**Status:** proposal, for review
**Author:** drafted with Claude Code from a read of the repo at `3df0efd` (2026-08-29)

---

## Thesis

**Veea has a demand problem, not a supply problem.**

The engineering is well ahead of the commercial work. Nothing has ever been sold to
anyone, and the one asset that is priced in the UI is 10% written. Every phase below
is ordered to buy information about whether anyone will pay, in increasing order of
cost — cheapest question first.

---

## Assets (verified in-tree)

| Asset | State |
| --- | --- |
| Flutter app | 78 Dart files, ~22,000 LOC, 195 tests across 26 files |
| Rust backend (`cloud/`) | 148 files, ~7,800 LOC — identity commands, outbox/inbox, idempotency records, refresh-token rotation into the platform keychain |
| Offline pronunciation dictionary | 126,052 entries, gzipped IPA, bundled |
| Arcade SDK | Real extension point (`ArcadeRegistry`, `ArcadeCrtScreen`, starter template); 9 games ship against it |
| Design identity | Handjet pixel font w/ full Vietnamese diacritics, 6 retro themes, CRT treatment |

This is production-grade infrastructure most solo projects never reach.

## Liabilities (verified in-tree)

| Item | Evidence |
| --- | --- |
| README claims "300+ technical terms" | `grep -c "CartridgeWord(" lib/data/cartridges_data.dart` → **30** |
| README claims "Smart OCR Scanner" | No camera / ML Kit / image dependency in `pubspec.yaml`; `lib/screens/pixel_lens_screen.dart:33` loads canned `OcrService.sampleScans` |
| README claims "Retro AI Context Wizard" | `lib/services/context_wizard_service.dart` is a hardcoded corpus plus string templates — no model, no API |
| Cartridge shows `$2.99 / FREE TRIAL` | Display label only (`cartridge_library_screen.dart:252`). `CartridgeProvider.installCartridge` has no entitlement check |
| No monetization code | No IAP, no RevenueCat, no billing anywhere in `lib/` |
| No analytics or crash reporting | None. All post-launch decisions are currently unmeasurable |
| Android cannot ship | `android/app/build.gradle.kts:37` — release builds sign with **debug keys** |
| Bundle ID mismatch | App is `com.nintran.veeaEnglishApp`; tests are `com.veea.veeaEnglishApp` |
| Sellable content is public and MIT | Cartridge content sits in-tree in a public MIT repo |

---

## Phase 0 — Stop the bleeding

**Timebox:** this week (hours, not days)

1. **Move cartridge content out of the public MIT repo.** Most irreversible item on the
   list, so it goes first. Every entry written into a public MIT repo is one given away.
   Keep the app and Arcade SDK MIT — that is the marketing. Content goes private and is
   delivered from the existing Rust service behind an entitlement check.
2. **Correct the three false README claims** (300+ terms, OCR scanner, AI wizard). Either
   build them or rename them honestly. The repo is public; anyone who verifies and finds
   a 10x overstatement is gone for good.
3. **Fix release signing config and the bundle ID mismatch.** Pure blocker, roughly an hour.

**Gate:** none. This is remedial work that precedes everything.

---

## Phase 1 — Ship it free

**Timebox:** weeks 1–3

4. Add analytics and crash reporting. Without them every decision downstream is blind.
5. Ship to Play Store, **free, no paywall**. Android leads market share in Vietnam and
   review is faster and cheaper. App Store follows.
6. Reach 200–500 installs through channels where Vietnamese developers actually are:
   Vietnamese dev Facebook groups, Viblo, r/VietNam, short-form video of the arcade games.

**Gate — D7 retention.**
Above ~20%: proceed. Below ~10%: nothing downstream matters — not cartridges, not B2B,
and not hardware. Fix retention or stop.

---

## Phase 2 — Charge before building

**Timebox:** weeks 3–6

This is the step most builders skip, and it is the one that saves ~60 hours of content
writing done on spec.

7. Put the cartridge in the app at $2.99 **with the 30 entries that already exist**,
   honestly labeled "Vol. 1 — 30 terms", or as a discounted pre-order for the full 300.
8. Measure paywall tap-through and conversion. Fifty people tapping *buy* is worth more
   information than 270 more entries written before anyone has been asked for money.
9. In parallel, at zero engineering cost: contact 10 Vietnamese dev shops — FPT, KMS,
   NashTech, Axon, and smaller 50–200 person outsourcing firms. Not a pitch, a question:
   *do your engineers struggle running English standups with client teams?*

**Gate — which channel pulled?** This is the branch point for everything after.

---

## Phase 3 — Build what the data chose

**Timebox:** months 2–4

- **B2C converted** → finish the 300 entries; add 2–3 further cartridges (IELTS-for-devs,
  Japanese-market IT English, Business English). Prefer lifetime pricing over subscription;
  it converts better in this market.
- **B2B bit** → seat licensing and an admin view on the Rust backend. Users and
  `change_user_role.rs` already exist, so this is closer than a polished consumer funnel.
  Ten companies × 100 seats × $4/seat/month ≈ $4k MRR, with materially lower churn than
  consumer.
- **Neither converted** → the content is not the product. Stop and rethink before
  spending more.

**Gate — revenue exists, from somewhere.** Do not proceed to Phase 4 without it.

---

## Phase 4 — Hardware

**Timebox:** month 4+, gated on an audience

The proposed device: a keychain e-ink display that syncs vocabulary from the phone over
BLE, cycling words offline for weeks on a charge.

### Why it is a strong product idea

- **The aesthetic is already 1-bit.** Most e-ink products fight the panel; this design was
  built for those constraints before the panel existed. A 200×200 monochrome e-paper panel
  renders the existing design natively rather than as a degraded port.
- **Hardware is the moat the MIT license is not.** Anyone can fork the repo. Nobody forks
  a physical object.
- **ARPU moves from ~$3 to ~$69.** One device sale is worth roughly 23 cartridge sales.
- **It addresses the actual failure mode:** the phone is where the distraction lives. A
  single-purpose object that shows one word and cannot notify you is a behavior product.

### Key architectural call

**Render the bitmap on the phone, not the device.** Rasterize each word to a 200×200 1-bit
image (5,000 bytes) in Flutter and ship it over BLE.

- Vietnamese diacritics stop being a problem — no subset font on flash, no glyph fallback.
- The existing pixel widgets are reused verbatim; the device screen *is* the app's design
  system, pixel-identical.
- The device becomes language-agnostic by construction, so the same hardware serves
  Japanese, Korean and Spanish learners while content stays per-market.
- 4MB SPI flash (~$0.30) holds ~800 pre-rendered screens. Sync once, then fully offline.

`WidgetService.rotateToNextWord()` (`lib/services/widget_service.dart:35`) already
implements this exact data path — select a word set, serialize, push to an external
surface, manage a rotation index. The device is that pattern with `flutter_blue_plus`
in place of `home_widget`.

### Component reality

There is no commodity 1.4" panel. **1.54" / 200×200 is the standard part**; 1.02" (128×80)
is too cramped for word + IPA + gloss.

| Part | Cost @ 1k units |
| --- | --- |
| 1.54" e-paper panel + FPC connector | $5–8 |
| nRF52832 pre-certified BLE module | $2–3 |
| 150mAh LiPo + charging IC | $2 |
| 4MB SPI flash, button, passives, PCB | $2–3 |
| Injection-molded enclosure | $2–5 |
| **BOM** | **$13–20** |
| Landed (assembly, test, packaging, freight) | **$25–35** |
| **Retail at 2.5–3×** | **$59–89** |

Use a **pre-certified BLE module** to inherit its modular FCC/CE grant — that removes
roughly $10–15k of intentional-radiator testing, leaving ~$1–3k of Part 15B work. Avoid
CR2032: e-ink refresh peak current sags coin cells. Small LiPo plus USB-C. E-ink holds its
image at zero power, so 150mAh with BLE deep sleep and a few refreshes daily gives roughly
4–8 weeks per charge — that is the spec that sells the product.

### Risks

- **Hardware kills software companies.** Inventory, defects, returns, customs, support.
- **Cash before revenue:** panel MOQs run 500–1,000 units, so $6–10k is committed before a
  single sale. Injection tooling adds $3–8k, and the first revision is always wrong.
- **The hardware buyer and the content buyer may be different people.** $69 is steep for
  the Vietnamese consumer market; the natural audience is the global developer-gadget and
  language-learning crowd. Phone-side rendering is what resolves this — the device is a
  neutral vessel sold worldwide while the Vietnamese content sells into Vietnam. Decide
  this deliberately, not after the tooling is paid for.

### De-risking, running in parallel from week one

1. Build one with off-the-shelf parts — Waveshare 1.54" e-Paper + Seeed Xiao nRF52840 +
   LiPo, about $40, no PCB design.
2. Carry it on your keys for three weeks. Do you actually glance at it? That is the entire
   product thesis and only the builder can answer it.
3. Post the prototype video around month 2. It is the best top-of-funnel available and
   costs one weekend, not one production run.
4. Pre-sell. ~300 pre-orders at $69 ≈ $20k, which funds the run. Never build on spec.
5. Consider a kit first — 3D-printed case, pre-flashed dev board, $89, sold in dozens.
   Validates the object without the mold, the MOQ, or the cash risk.

**Commit tooling money only once Phase 3 produces revenue and the waitlist reaches 300–500.**

---

## Why hardware is Phase 4 and not Phase 1

The bottleneck is not a missing device. Release builds still sign with debug keys, so the
Android app has never shipped; there is no analytics, no payment code, and no entitlement
check; and the priced cartridge is 30 words of a promised 300.

Building hardware now stacks a capital-intensive second business on top of an unvalidated
first one, and the hard parts of hardware are entirely unrelated to the hard part that has
not been done yet.

There is also a sequencing trap worth naming: writing 270 vocabulary entries and asking
Vietnamese engineers for money is tedious and exposing. Designing a BLE e-ink keychain is
fascinating. The fascinating one will always feel more productive.

Hence the parallel lane — the prototype is cheap, it is genuinely the best marketing asset
available, and one enjoyable thread is what keeps the tedious one moving.

---

## Open questions for the reviewer

1. **Is D7 > 20% the right gate**, or is a vocabulary journal inherently low-frequency
   enough that D30 is the honest metric?
2. **Is the license split actually enforceable in practice?** A determined user can
   extract cartridge content from a decompiled APK regardless. Is the private-repo split
   worth the friction, or is convenience-plus-goodwill the real business model?
3. **B2C or B2B first?** Phase 2 runs both cheaply, but if only one can be resourced,
   B2B has better unit economics and worse founder-market fit for a solo engineer.
4. **Does the Vietnamese-gloss content survive contact with a global hardware audience,**
   or does the keychain quietly force a pivot to an English-only product?
5. **Is $2.99 anchoring the product too low?** A "tech interview English" package at
   $29–49 targets the IELTS-prep wallet (3–10M VND) rather than the app-store-impulse
   wallet, and 200 buyers/year at $39 outperforms several thousand cartridge sales.
