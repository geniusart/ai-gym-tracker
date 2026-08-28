"""Unit tests for the analytics math helpers."""

from datetime import datetime, timedelta, timezone

import pytest

from app.routes._analytics_helpers import (
    as_number,
    best_set_of,
    epley_1rm,
    is_number,
    parse_iso,
    relative_delta_pct,
    split_window,
    split_window_avg,
    to_utc,
    utc_isoformat,
    week_start,
    window_is_covered,
    workout_metrics,
)


# MARK: - epley_1rm

def test_epley_1rm_canonical_values():
    # Canonical literature values for sanity
    assert epley_1rm(100, 1) == pytest.approx(103.33, abs=0.05)
    assert epley_1rm(100, 5) == pytest.approx(116.67, abs=0.05)
    assert epley_1rm(100, 10) == pytest.approx(133.33, abs=0.05)


def test_epley_1rm_smooths_across_rep_ranges():
    """High-rep light set should compute a similar 1RM to low-rep heavy set."""
    a = epley_1rm(60, 15)   # 60 * (1 + 15/30) = 90
    b = epley_1rm(80, 6)    # 80 * (1 + 6/30) = 96
    # Both are in the 90-100 ballpark; analytics line stays smooth.
    assert 80 < a < 100
    assert 90 < b < 100


# MARK: - best_set_of

def test_best_set_of_returns_heaviest():
    sets = [
        {"weight_kg": 60, "reps": 12},
        {"weight_kg": 80, "reps": 6},
        {"weight_kg": 70, "reps": 10},
    ]
    best = best_set_of(sets)
    assert best["weight_kg"] == 80


def test_best_set_of_breaks_weight_ties_by_reps():
    sets = [
        {"weight_kg": 80, "reps": 6},
        {"weight_kg": 80, "reps": 8},  # higher reps at same weight wins
    ]
    assert best_set_of(sets)["reps"] == 8


def test_best_set_of_empty_returns_none():
    assert best_set_of([]) is None


# MARK: - workout_metrics

def test_workout_metrics_filters_invalid_sets():
    sets = [
        {"weight_kg": 60, "reps": 10},   # valid
        {"weight_kg": None, "reps": 10},  # filtered
        {"weight_kg": 70, "reps": 0},     # filtered (reps must be > 0)
        {"weight_kg": -5, "reps": 5},     # filtered (weight must be >= 0)
    ]
    m = workout_metrics(sets)
    assert m["working_sets"] == 1
    assert m["volume"] == 600
    assert m["best_set"]["weight_kg"] == 60


def test_workout_metrics_handles_empty():
    m = workout_metrics([])
    assert m == {
        "volume": 0.0, "est_1rm": None, "best_set": None, "working_sets": 0,
    }


def test_workout_metrics_volume_and_est_1rm():
    sets = [
        {"weight_kg": 100, "reps": 12},
        {"weight_kg": 100, "reps": 10},
        {"weight_kg": 100, "reps": 8},
    ]
    m = workout_metrics(sets)
    assert m["volume"] == 100 * 12 + 100 * 10 + 100 * 8
    # Highest est_1rm comes from the highest-rep set at this weight
    assert m["est_1rm"] == pytest.approx(100 * (1 + 12 / 30))


# MARK: - relative_delta_pct

def test_relative_delta_pct_positive():
    assert relative_delta_pct(110, 100) == 10.0


def test_relative_delta_pct_negative():
    assert relative_delta_pct(80, 100) == -20.0


def test_relative_delta_pct_no_change():
    assert relative_delta_pct(100, 100) == 0.0


def test_relative_delta_pct_none_prior():
    assert relative_delta_pct(100, None) is None


def test_relative_delta_pct_zero_prior_is_none():
    """Avoid division by zero AND avoid misleading 'inf%' display."""
    assert relative_delta_pct(100, 0) is None


def test_relative_delta_pct_rounded_to_2_decimals():
    assert relative_delta_pct(123.456, 100) == 23.46


# MARK: - split_window

def test_split_window_basic():
    now = datetime(2026, 4, 30, tzinfo=timezone.utc)
    points = [
        # Recent window (last 30d): days 5 ago
        {"date": (now - timedelta(days=5)).isoformat(), "value": 100},
        # Recent: 25 ago
        {"date": (now - timedelta(days=25)).isoformat(), "value": 50},
        # Prior window (30-60d ago): 45 ago
        {"date": (now - timedelta(days=45)).isoformat(), "value": 80},
        # Outside window: 90 ago
        {"date": (now - timedelta(days=90)).isoformat(), "value": 999},
    ]
    recent, prior = split_window(points, days=30, now=now)
    assert recent == 150
    assert prior == 80


def test_split_window_no_prior_returns_none():
    """If no points fall in the prior window, return None (not 0) so the
    delta can be rendered as 'no comparison' instead of 'inf%'."""
    now = datetime(2026, 4, 30, tzinfo=timezone.utc)
    points = [
        {"date": (now - timedelta(days=5)).isoformat(), "value": 100},
    ]
    recent, prior = split_window(points, days=30, now=now)
    assert recent == 100
    assert prior is None


def test_split_window_handles_naive_datetime_in_input():
    """Logs may have naive ISO strings; the helper must coerce to UTC."""
    now = datetime(2026, 4, 30, tzinfo=timezone.utc)
    points = [
        {"date": "2026-04-25T12:00:00", "value": 100},  # 5 days ago, naive
    ]
    recent, prior = split_window(points, days=30, now=now)
    assert recent == 100


# MARK: - week_start

def test_week_start_returns_monday():
    # 2026-04-30 is a Thursday
    monday = week_start(datetime(2026, 4, 30, tzinfo=timezone.utc))
    assert monday.weekday() == 0
    assert monday.isoformat() == "2026-04-27"


def test_week_start_idempotent_on_monday():
    monday_input = datetime(2026, 4, 27, tzinfo=timezone.utc)
    assert week_start(monday_input).isoformat() == "2026-04-27"


# MARK: - parse_iso

def test_parse_iso_accepts_z_suffix():
    d = parse_iso("2026-04-30T12:00:00Z")
    assert d.tzinfo is not None
    assert d.year == 2026


def test_parse_iso_accepts_offset_suffix():
    d = parse_iso("2026-04-30T12:00:00+02:00")
    assert d.tzinfo is not None


# MARK: - to_utc / utc_isoformat

def test_to_utc_treats_naive_input_as_utc():
    """Logs are raw client JSON; a naive `started_at` must not crash the
    comparison against an aware `now`."""
    d = to_utc("2026-08-01T10:00:00")
    assert d == datetime(2026, 8, 1, 10, 0, tzinfo=timezone.utc)


def test_to_utc_converts_offset_to_utc():
    assert to_utc("2026-08-01T13:00:00+03:00") == datetime(
        2026, 8, 1, 10, 0, tzinfo=timezone.utc
    )


@pytest.mark.parametrize("value", [None, "", "None", "not-a-date", 42, {}])
def test_to_utc_returns_none_for_unusable_values(value):
    assert to_utc(value) is None


def test_utc_isoformat_normalizes_offset_for_string_range_filters():
    """`started_at` is stored as a string, so the Mongo bound is compared
    lexicographically and has to be in UTC."""
    assert utc_isoformat("2026-06-15T12:00:00+03:00") == "2026-06-15T09:00:00+00:00"


def test_utc_isoformat_bound_does_not_exclude_same_instant_z_value():
    stored = "2026-06-15T09:00:00Z"
    bound = utc_isoformat("2026-06-15T12:00:00+03:00")
    assert stored >= bound  # the comparison Mongo actually performs


# MARK: - numeric coercion

def test_workout_metrics_accepts_float_reps():
    """BSON stores a client-written `10.0` as a double; dropping those made
    /exercise-progress and /body-parts disagree on the same set."""
    m = workout_metrics([{"weight_kg": 100, "reps": 10.0}])
    assert m["working_sets"] == 1
    assert m["volume"] == 1000


def test_workout_metrics_rejects_bool_reps():
    """`isinstance(True, int)` is True, so a bool would count as 1 rep."""
    m = workout_metrics([{"weight_kg": 100, "reps": True}])
    assert m["working_sets"] == 0


def test_workout_metrics_counts_bodyweight_sets():
    m = workout_metrics([{"weight_kg": 0, "reps": 12}])
    assert m["working_sets"] == 1
    assert m["volume"] == 0


def test_is_number_and_as_number():
    assert is_number(1) and is_number(1.5)
    assert not is_number(True) and not is_number("1") and not is_number(None)
    assert as_number("100") is None
    assert as_number(100) == 100.0


# MARK: - split_window_avg / window_is_covered

def test_split_window_avg_compares_means_not_sums():
    """More sessions in a window must not read as 'stronger'."""
    now = datetime(2026, 4, 30, tzinfo=timezone.utc)
    points = [
        {"date": now - timedelta(days=5), "value": 100},
        {"date": now - timedelta(days=10), "value": 100},
        {"date": now - timedelta(days=45), "value": 100},
    ]
    recent, prior = split_window_avg(points, days=30, now=now)
    assert recent == 100
    assert prior == 100


def test_split_window_avg_empty_windows_are_none():
    now = datetime(2026, 4, 30, tzinfo=timezone.utc)
    assert split_window_avg([], days=30, now=now) == (None, None)


def test_split_window_skips_non_numeric_values():
    now = datetime(2026, 4, 30, tzinfo=timezone.utc)
    points = [
        {"date": now - timedelta(days=5), "value": "100"},
        {"date": now - timedelta(days=5), "value": 50},
    ]
    recent, _ = split_window(points, days=30, now=now)
    assert recent == 50


def test_window_is_covered_requires_two_full_windows():
    """A 120-day fetch cannot back a 90-day comparison: the prior half would
    hold 30 days of data and report +200% on a flat load."""
    now = datetime(2026, 4, 30, tzinfo=timezone.utc)
    assert not window_is_covered(now - timedelta(days=120), now, 90)
    assert window_is_covered(now - timedelta(days=180), now, 90)
    assert window_is_covered(now - timedelta(days=120), now, 30)
