# TRD 10 — Server-Delivered Cartridges (first Premium feature)

**Status:** v0.1 proposal. Nothing is approved or implemented. Recorded at Nin's request (TRD 09 E2, 2026-11-15) as the proposed first Premium capability.
**Date:** 2026-11-15
**Depends on:** [TRD 09](09-free-premium-entitlements.md) plan management (implemented).

## 1. Why cartridges

Cartridges (vocabulary packs) are the one Premium candidate that already has a product surface. The app shows a priced cartridge library (`lib/screens/cartridge_library_screen.dart`) and installs packs with `CartridgeProvider.installCartridge`. But the content is bundled in the public app and installed with no check (`docs/product/product-discovery.md` §2.13, `MONETIZATION_SEQUENCE.md` Phase 0). A plan check is only enforceable if the server delivers the content, so this TRD proposes moving cartridge content behind the Go API.

## 2. Proposed scope **[Proposed]**

1. **Catalog.** `GET /v1/cartridges`: id, title, version, word count and plan (`free` or `premium`). It is readable by any signed-in account and carries no content.
2. **Content.** `GET /v1/cartridges/{id}/content`. It checks the caller's TRD 09 effective plan at database time, refuses a Premium cartridge on Free with a new `403 plan_required`, and serves versioned content otherwise.
3. **Installed words become the user's own words.**
   - Installing adds words to the account's vocabulary through the TRD 05 import or push path, inside the existing quota.
   - After a downgrade, installed words stay: TRD 09 E1 preserves data. Only new Premium installs or updates are refused.
4. **Storage.**
   - Cartridge content is shared catalog data, not user-owned. Per TRD 04 §2 it is never deleted by a purge.
   - The user's installed copies are vocabulary and follow TRD 05 export and purge.
5. **Removal from the public repository.** Premium content leaves the MIT-licensed app bundle. A free starter pack may stay bundled.

## 3. Decisions needed before a design is finalized

| ID | Question |
|---|---|
| C1 | Which cartridges are Free and which are Premium, and is a free starter pack kept bundled? |
| C2 | Does installing copy words into the account's vocabulary (counted in quota, kept after downgrade), or reference shared content (not counted, hidden after downgrade)? The TRD 09 E1 "preserve data" rule favors copying. |
| C3 | Is offline use of already-installed Premium cartridges kept after expiry? Recommended: yes, as owned words. |
| C4 | How is content versioned and updated, and are updates Premium? |
| C5 | Where is content stored and authored: PostgreSQL, object storage, or a private repository? Who may publish? |
| C6 | Client rollout: the rebuilt Flutter client must handle `plan_required` and the catalog before any content leaves the bundle. |

Payments stay out of scope until a payments TRD adds `source = 'store'` grants to TRD 09.
