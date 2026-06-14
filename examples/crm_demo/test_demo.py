#!/usr/bin/env python3
"""Unit tests for the demo orchestrator (mirrors consent.zig logic)."""

import sys
from pathlib import Path

# Make the demo importable
sys.path.insert(0, str(Path(__file__).resolve().parent))
from demo import (
    classify,
    risk_for_change,
    ChangeSpec,
    RiskSignals,
    ConsentTier,
    run_consent_flow,
    init_db,
    seed_tenant,
    propose_followup_tightening,
)


def test_classify_minor():
    r = RiskSignals(0.0, 0.0, 0.0)
    assert classify(r) == ConsentTier.MINOR, f"expected minor, got {classify(r)}"


def test_classify_standard():
    r = RiskSignals(0.3, 0.3, 0.3)  # combined = 0.3 → standard
    assert classify(r) == ConsentTier.STANDARD


def test_classify_major():
    r = RiskSignals(0.6, 0.6, 0.3)
    assert classify(r) == ConsentTier.MAJOR


def test_classify_critical():
    r = RiskSignals(1.0, 0.6, 0.9)
    assert classify(r) == ConsentTier.CRITICAL


def test_risk_l1_is_zero():
    c = ChangeSpec(
        l5_module="", files_added=[], files_modified=[],
        lines_changed=0, affected_features=[], affected_users=0, reversible=True,
    )
    r = risk_for_change(c)
    assert r.severity == 0.0
    assert r.reversibility == 0.0
    assert classify(r) == ConsentTier.MINOR


def test_risk_l3_is_standard():
    c = ChangeSpec(
        l5_module="", files_added=["new_method.zig"], files_modified=[],
        lines_changed=20, affected_features=["x"], affected_users=10, reversible=True,
    )
    r = risk_for_change(c)
    # severity 0.3, blast 0.6 (10 users), reversibility 0.0
    # combined = 0.3 → standard
    assert classify(r) == ConsentTier.STANDARD


def test_risk_l5_irreversible_global_is_critical():
    c = ChangeSpec(
        l5_module="core.zig", files_added=[], files_modified=["a.zig", "b.zig", "c.zig"],
        lines_changed=300, affected_features=["all"], affected_users=5000, reversible=False,
    )
    r = risk_for_change(c)
    assert classify(r) == ConsentTier.CRITICAL


def test_consent_flow_creates_log():
    import tempfile
    import json
    with tempfile.TemporaryDirectory() as tmp:
        db = Path(tmp) / "test.sqlite"
        conn = init_db(db)
        tenant = seed_tenant(conn, "test", "saas_mid_market")

        product = {
            "consent_defaults": {
                "minor_tier_timeout_hours": 24,
                "standard_tier_timeout_hours": 72,
                "major_tier_timeout_hours": 168,
                "critical_tier_requires_double_approval": True,
            }
        }
        proposal = propose_followup_tightening(tenant)
        result = run_consent_flow(conn, product, proposal)

        cur = conn.execute("SELECT COUNT(*) FROM consent_log")
        n = cur.fetchone()[0]
        assert n == 1, f"expected 1 consent log entry, got {n}"
        assert result["tier"] in ("minor", "standard", "major", "critical")


def test_consent_flow_includes_rationale():
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        db = Path(tmp) / "test.sqlite"
        conn = init_db(db)
        tenant = seed_tenant(conn, "test", "saas_mid_market")
        product = {
            "consent_defaults": {
                "minor_tier_timeout_hours": 24,
                "standard_tier_timeout_hours": 72,
                "major_tier_timeout_hours": 168,
                "critical_tier_requires_double_approval": True,
            }
        }
        proposal = propose_followup_tightening(tenant)
        result = run_consent_flow(conn, product, proposal)
        assert "rationale" not in result  # rationale is in the log row, not the result
        cur = conn.execute("SELECT rationale FROM consent_log LIMIT 1")
        rationale = cur.fetchone()[0]
        assert "5-day follow-up" in rationale or "win rate" in rationale


if __name__ == "__main__":
    tests = [
        test_classify_minor,
        test_classify_standard,
        test_classify_major,
        test_classify_critical,
        test_risk_l1_is_zero,
        test_risk_l3_is_standard,
        test_risk_l5_irreversible_global_is_critical,
        test_consent_flow_creates_log,
        test_consent_flow_includes_rationale,
    ]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"  ✓ {t.__name__}")
        except AssertionError as e:
            print(f"  ✗ {t.__name__}: {e}")
            failed += 1
        except Exception as e:
            print(f"  ✗ {t.__name__}: {type(e).__name__}: {e}")
            failed += 1
    print()
    if failed == 0:
        print(f"All {len(tests)} tests passed.")
        sys.exit(0)
    else:
        print(f"{failed} of {len(tests)} tests failed.")
        sys.exit(1)
