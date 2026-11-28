#!/usr/bin/env python3
"""Generates veea-alerts.test.yml (TRD 08 §6) from the scenarios below.

Expected annotations are read from veea-alerts.yml, so a test can never drift from the rule
text. Run from backend/: python3 monitoring/prometheus/gen_tests.py, then
scripts/test-alert-rules.sh. The generated file is committed; this script only removes the
repetition of writing every expected alert by hand.
"""
import os

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
RULES = yaml.safe_load(open(os.path.join(HERE, "veea-alerts.yml")))
ALERTS = {r["alert"]: r for g in RULES["groups"] for r in g["rules"]}
J = 'job="veea-api"'
I1, I2 = 'instance="api-1:9090"', 'instance="api-2:9090"'


def s(metric, labels, values):
    return {"series": f"{metric}{{{labels}}}", "values": values}


def healthy(inst=I1, n=70, sent="0+1x70"):
    """One API instance with healthy values: a Super Admin, nothing pending, email flowing."""
    L = f"{J},{inst}"
    return [
        s("up", L, f"1x{n}"),
        s("admin_active_super_admins", L, f"1x{n}"),
        s("admin_super_admin_bootstrapped", L, f"1x{n}"),
        s("account_deletion_oldest_pending_seconds", L, f"0x{n}"),
        s("email_outbox_pending", L, f"0x{n}"),
    ] + email(inst, sent=sent, n=n)


def email(inst=I1, sent="0x70", permanent="0x70", ambiguous="0x70", retryable="0x70", n=70):
    """email_send_total as cmd/api creates it: every result series exists from startup."""
    L = f'{J},{inst},template="login_code"'
    return [
        s("email_send_total", f'{L},result="sent"', sent),
        s("email_send_total", f'{L},result="permanent"', permanent),
        s("email_send_total", f'{L},result="ambiguous"', ambiguous),
        s("email_send_total", f'{L},result="retryable"', retryable),
    ]


def replace(series, metric, values, inst=I1):
    out = [x for x in series if not (x["series"].startswith(metric + "{") and inst in x["series"])]
    if values is not None:
        out.append(s(metric, f"{J},{inst}", values))
    return out


def firing(alert, **labels):
    lbl = {"severity": ALERTS[alert]["labels"]["severity"], **labels}
    return {"exp_labels": lbl, "exp_annotations": ALERTS[alert]["annotations"]}


def check(at, alert, *expected):
    return {"eval_time": at, "alertname": alert, "exp_alerts": list(expected)}


def none_at(at, alerts):
    return [check(at, a) for a in alerts]


def test(name, series, checks):
    return {"name": name, "interval": "1m", "input_series": series, "alert_rule_test": checks}


ALL = list(ALERTS)
job = {"job": "veea-api"}
inst1 = {"job": "veea-api", "instance": "api-1:9090"}

tests = [
    test("healthy zeros fire nothing (traffic)", healthy(), none_at("59m", ALL)),
    test("healthy zeros fire nothing (no traffic at all)", healthy(sent="0x70"), none_at("59m", ALL)),
    # --- scrape -----------------------------------------------------------------------------
    test(
        "scrape failure fires after 5m and recovers; value rules stay silent while blind",
        [s("up", f"{J},{I1}", "1x10 0x20 1x20"),
         s("admin_super_admin_bootstrapped", f"{J},{I1}", "1x10 _x20 1x20"),
         s("admin_active_super_admins", f"{J},{I1}", "1x10 _x20 1x20")],
        [check("13m", "VeeaApiScrapeFailing"),
         check("17m", "VeeaApiScrapeFailing", firing("VeeaApiScrapeFailing", **inst1)),
         check("25m", "VeeaNoActiveSuperAdmin"),
         check("25m", "VeeaApiMonitoringSeriesMissing"),
         check("35m", "VeeaApiScrapeFailing")],
    ),
    test(
        "no target at all is absent, not failing",
        [s("email_outbox_pending", f'job="other",{I1}', "0x30")],
        [check("8m", "VeeaApiScrapeTargetAbsent"),
         check("12m", "VeeaApiScrapeTargetAbsent", firing("VeeaApiScrapeTargetAbsent", **job)),
         check("12m", "VeeaApiScrapeFailing")],
    ),
    test(
        "scraped but gauges missing is reported, never read as a healthy zero",
        [s("up", f"{J},{I1}", "1x30"), s("admin_active_super_admins", f"{J},{I1}", "0x30")],
        [check("15m", "VeeaApiMonitoringSeriesMissing", firing("VeeaApiMonitoringSeriesMissing", **inst1)),
         check("15m", "VeeaNoActiveSuperAdmin")],
    ),
    test(
        "a -1 read failure is reported and judged by no value rule",
        replace(healthy(), "email_outbox_pending", "-1x70"),
        [check("15m", "VeeaApiMonitoringReadFailed", firing("VeeaApiMonitoringReadFailed", **inst1)),
         check("40m", "VeeaEmailOutboxStalled"),
         check("40m", "VeeaEmailOutboxBacklogGrowing")],
    ),
    # --- Super Admin ------------------------------------------------------------------------
    test(
        "fresh deployment before bootstrap: zero Super Admins is expected",
        replace(replace(healthy(), "admin_super_admin_bootstrapped", "0x70"), "admin_active_super_admins", "0x70"),
        none_at("60m", ["VeeaNoActiveSuperAdmin", "VeeaApiMonitoringReadFailed", "VeeaApiMonitoringSeriesMissing"]),
    ),
    test(
        "after bootstrap, losing the last active Super Admin fires after 5m and recovers",
        replace(replace(healthy(), "admin_super_admin_bootstrapped", "0x5 1x64"),
                "admin_active_super_admins", "0x5 1x20 0x14 1x28"),
        [check("4m", "VeeaNoActiveSuperAdmin"),  # before bootstrap
         check("29m", "VeeaNoActiveSuperAdmin"),  # pending (zero since 27m)
         check("33m", "VeeaNoActiveSuperAdmin", firing("VeeaNoActiveSuperAdmin", **job)),
         check("45m", "VeeaNoActiveSuperAdmin")],
    ),
    test(
        "two instances: one read failure neither fires nor hides the other instance's value",
        replace(healthy(), "admin_active_super_admins", "-1x70")
        + replace(healthy(inst=I2), "email_send_total", None, inst=I2),
        [check("20m", "VeeaNoActiveSuperAdmin"),
         check("20m", "VeeaApiMonitoringReadFailed", firing("VeeaApiMonitoringReadFailed", **inst1))],
    ),
    test(
        "an unreadable bootstrap marker cannot raise the Super Admin alert",
        replace(replace(healthy(), "admin_super_admin_bootstrapped", "-1x70"), "admin_active_super_admins", "0x70"),
        [check("20m", "VeeaNoActiveSuperAdmin"),
         check("20m", "VeeaApiMonitoringReadFailed", firing("VeeaApiMonitoringReadFailed", **inst1))],
    ),
    # --- account purge ----------------------------------------------------------------------
    test(
        "purge slow after 2h (15m), overdue after 24h (5m), recovers when the purge completes",
        replace(healthy(), "account_deletion_oldest_pending_seconds", "86000+60x19 0x50"),
        [check("10m", "VeeaAccountPurgeOverdue"),  # over 86400 since 7m: pending
         check("13m", "VeeaAccountPurgeOverdue", firing("VeeaAccountPurgeOverdue", **job)),
         check("13m", "VeeaAccountPurgeSlow"),  # true since 0m, needs 15m
         check("16m", "VeeaAccountPurgeSlow", firing("VeeaAccountPurgeSlow", **job)),
         check("25m", "VeeaAccountPurgeOverdue"),
         check("25m", "VeeaAccountPurgeSlow")],
    ),
    test(
        "purge under 2h is quiet",
        replace(healthy(), "account_deletion_oldest_pending_seconds", "0+60x69"),
        none_at("69m", ["VeeaAccountPurgeSlow", "VeeaAccountPurgeOverdue"]),
    ),
    # --- email delivery ---------------------------------------------------------------------
    test(
        "high traffic: 33% failures fire the ratio rule after 10m and recover",
        replace(healthy(), "email_send_total", None)
        + email(sent="0+10x100", permanent="0+5x30 150x70", n=100),
        [check("8m", "VeeaEmailDeliveryFailureRatioHigh"),
         check("15m", "VeeaEmailDeliveryFailureRatioHigh", firing("VeeaEmailDeliveryFailureRatioHigh", **job)),
         check("15m", "VeeaEmailDeliveryFailingLowVolume"),  # sends succeed
         check("70m", "VeeaEmailDeliveryFailureRatioHigh")],
    ),
    test(
        "low traffic: one failure in an hour is not an outage",
        replace(healthy(sent="0x70"), "email_send_total", None) + email(permanent="0x10 1x60"),
        none_at("60m", ["VeeaEmailDeliveryFailureRatioHigh", "VeeaEmailDeliveryFailingLowVolume"]),
    ),
    test(
        "low traffic: three failures and no success in an hour fire; a success recovers",
        replace(healthy(sent="0x70"), "email_send_total", None)
        + email(sent="0x50 1x20", permanent="0x10 1x10 2x10 3x40"),
        [check("29m", "VeeaEmailDeliveryFailingLowVolume"),
         check("40m", "VeeaEmailDeliveryFailingLowVolume", firing("VeeaEmailDeliveryFailingLowVolume", **job)),
         check("40m", "VeeaEmailDeliveryFailureRatioHigh"),  # under 20 calls
         check("55m", "VeeaEmailDeliveryFailingLowVolume")],
    ),
    test(
        "low traffic outage is still caught if the sent series were missing",
        replace(healthy(), "email_send_total", None)
        + [s("email_send_total", f'{J},{I1},template="login_code",result="ambiguous"', "0x10 1x10 2x10 3x40")],
        [check("40m", "VeeaEmailDeliveryFailingLowVolume", firing("VeeaEmailDeliveryFailingLowVolume", **job))],
    ),
    # --- Apple purchase verification -------------------------------------------------------
    test(
        "Apple upstream and invalid-proof spikes warn, then recover",
        healthy() + [
            s("apple_purchase_verification_total", f'{J},{I1},operation="reconcile",result="upstream_failed"', "0+1x10 10x60"),
            s("apple_purchase_verification_total", f'{J},{I1},operation="claim",result="invalid_proof"', "0+2x10 20x60"),
        ],
        [check("4m", "VeeaApplePurchaseVerificationUpstreamFailing"),
         check("12m", "VeeaApplePurchaseVerificationUpstreamFailing", firing("VeeaApplePurchaseVerificationUpstreamFailing", **job)),
         check("12m", "VeeaApplePurchaseInvalidProofSpike", firing("VeeaApplePurchaseInvalidProofSpike", **job)),
         check("30m", "VeeaApplePurchaseVerificationUpstreamFailing"),
         check("30m", "VeeaApplePurchaseInvalidProofSpike")],
    ),
    test(
        "auth failures, rate limits, cooldowns, cancellations and isolated upstream errors stay quiet",
        healthy() + [
            s("apple_purchase_verification_total", f'{J},{I1},operation="claim",result="{result}"', "0+5x70")
            for result in ["authentication_failed", "rate_limited", "disabled", "reconcile_backoff", "request_canceled"]
        ] + [s("apple_purchase_verification_total", f'{J},{I1},operation="claim",result="upstream_failed"', "0x10 1x60")],
        none_at("20m", ["VeeaApplePurchaseVerificationUpstreamFailing", "VeeaApplePurchaseInvalidProofSpike"]),
    ),
    # --- outbox -----------------------------------------------------------------------------
    test(
        "backlog of 20+ that keeps growing warns after 15m; a plateau clears it",
        replace(healthy(sent="0+5x90", n=90), "email_outbox_pending", "0+2x29 60x60"),
        [check("20m", "VeeaEmailOutboxBacklogGrowing"),  # >= 20 since 10m: pending
         check("26m", "VeeaEmailOutboxBacklogGrowing", firing("VeeaEmailOutboxBacklogGrowing", **job)),
         check("26m", "VeeaEmailOutboxStalled"),  # the worker is sending
         check("60m", "VeeaEmailOutboxBacklogGrowing")],
    ),
    test(
        "low traffic: one message stuck with no provider call fires Stalled",
        replace(healthy(sent="0x70"), "email_outbox_pending", "0x10 1x60"),
        [check("25m", "VeeaEmailOutboxStalled"),  # pending since 11m: min_over_time not > 0 until 31m
         check("42m", "VeeaEmailOutboxStalled", firing("VeeaEmailOutboxStalled", **job)),
         check("42m", "VeeaEmailOutboxBacklogGrowing")],
    ),
    test(
        "low traffic: a message retried every 4 minutes is not stalled",
        replace(healthy(sent="0x70", n=70), "email_send_total", None)
        + email(retryable="0x10 1x4 2x4 3x4 4x4 5x4 6x4 7x4 8x4 9x4 10x4 11x10")
        + [s("email_outbox_pending", f"{J},{I1}", "0x10 1x60")],
        [check("50m", "VeeaEmailOutboxStalled")],
    ),
    test(
        "stalled is still caught if email_send_total were missing",
        replace(replace(healthy(), "email_send_total", None), "email_outbox_pending", "1x70"),
        [check("35m", "VeeaEmailOutboxStalled", firing("VeeaEmailOutboxStalled", **job))],
    ),
]

doc = {"rule_files": ["veea-alerts.yml"], "evaluation_interval": "1m", "tests": tests}
header = "# Generated by gen_tests.py (TRD 08 §6). Edit the scenarios there, not here.\n"
with open(os.path.join(HERE, "veea-alerts.test.yml"), "w") as f:
    f.write(header)
    yaml.safe_dump(doc, f, sort_keys=False, width=120)
