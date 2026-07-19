"""
Pytest suite for lambda/max-lifetime-stop/handler.py.

No network calls and no real AWS credentials are needed:

  * We build a *real* boto3 EC2 client (so botocore's request/response
    validation still applies) but wrap it in ``botocore.stub.Stubber`` and
    give it throwaway static credentials, so nothing ever hits the network
    or a credential provider chain.
  * ``handler._ec2_client`` (the handler's own client factory) is
    monkeypatched per-test to return that stubbed client.
  * Ages are derived from the *real* wall clock
    (``datetime.now(timezone.utc)``) by constructing ``LaunchTime`` values
    relative to "now" at test-setup time, exactly as suggested in the task:
    this avoids patching ``datetime`` entirely, since the handler always
    reads a later "now" than the one used to build the fixture, which is
    all that's needed to land reliably on either side of the ceiling.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import boto3
import pytest
from botocore.exceptions import ClientError
from botocore.stub import Stubber

import handler as handler_module
from handler import handler as lambda_handler

INSTANCE_ID = "i-0123456789abcdef0"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_client(region="us-east-1"):
    """A real boto3 EC2 client wrapped in a Stubber, with dummy static
    credentials so client construction never touches the real credential
    chain (env/shared-config/IMDS)."""
    client = boto3.client(
        "ec2",
        region_name=region,
        aws_access_key_id="testing",
        aws_secret_access_key="testing",
    )
    return client, Stubber(client)


def _describe_response(instance_id, state, launch_time=None, include_launch_time=True):
    instance = {
        "InstanceId": instance_id,
        "State": {"Code": 0, "Name": state},
    }
    if include_launch_time:
        instance["LaunchTime"] = launch_time
    return {
        "Reservations": [
            {
                "ReservationId": "r-0123456789abcdef0",
                "Instances": [instance],
            }
        ]
    }


def _stop_response(instance_id):
    return {
        "StoppingInstances": [
            {
                "InstanceId": instance_id,
                "CurrentState": {"Code": 64, "Name": "stopping"},
                "PreviousState": {"Code": 16, "Name": "running"},
            }
        ]
    }


def _patch_client(monkeypatch, client):
    """Make handler._ec2_client() return our stubbed client instead of
    building a real one."""
    monkeypatch.setattr(handler_module, "_ec2_client", lambda: client)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def clean_env(monkeypatch):
    """Start every test from a blank slate for the env vars the handler
    reads, regardless of whatever is ambient in the host environment."""
    for key in ("TARGET_INSTANCE_ID", "INSTANCE_ID", "MAX_LIFETIME_HOURS", "AWS_TARGET_REGION"):
        monkeypatch.delenv(key, raising=False)


# ---------------------------------------------------------------------------
# running + age vs. ceiling
# ---------------------------------------------------------------------------


def test_running_well_over_ceiling_stops_instance(monkeypatch):
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)
    monkeypatch.setenv("MAX_LIFETIME_HOURS", "12")
    launch_time = datetime.now(timezone.utc) - timedelta(hours=20)

    client, stubber = _make_client()
    stubber.add_response(
        "describe_instances",
        _describe_response(INSTANCE_ID, "running", launch_time),
        {"InstanceIds": [INSTANCE_ID]},
    )
    stubber.add_response(
        "stop_instances",
        _stop_response(INSTANCE_ID),
        {"InstanceIds": [INSTANCE_ID]},
    )
    stubber.activate()
    _patch_client(monkeypatch, client)

    result = lambda_handler({}, None)

    stubber.assert_no_pending_responses()  # proves stop_instances WAS called
    assert result["action"] == "stopped"
    assert result["reason"] == "over-ceiling"
    assert result["instance_id"] == INSTANCE_ID
    assert result["stopping"] == {INSTANCE_ID: "stopping"}


def test_running_just_under_ceiling_is_noop(monkeypatch):
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)
    monkeypatch.setenv("MAX_LIFETIME_HOURS", "12")
    # A comfortable minute shy of the 12h ceiling.
    launch_time = datetime.now(timezone.utc) - timedelta(hours=12) + timedelta(minutes=1)

    client, stubber = _make_client()
    stubber.add_response(
        "describe_instances",
        _describe_response(INSTANCE_ID, "running", launch_time),
        {"InstanceIds": [INSTANCE_ID]},
    )
    # Deliberately no stop_instances response queued: if the handler called
    # it, Stubber would raise UnStubbedResponseError and fail this test.
    stubber.activate()
    _patch_client(monkeypatch, client)

    result = lambda_handler({}, None)

    stubber.assert_no_pending_responses()  # proves stop_instances was NOT called
    assert result["action"] == "noop"
    assert result["reason"] == "under-ceiling"


def test_running_age_at_boundary_stops_instance(monkeypatch):
    """age_hours >= max_hours (not strictly >) must still stop. LaunchTime is
    built exactly max_hours before test-setup "now"; by the time handler.py
    reads its own (necessarily later) now(), the computed age has ticked
    past the ceiling by a hair -- enough to exercise the `<` vs `>=` branch
    without patching time."""
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)
    monkeypatch.setenv("MAX_LIFETIME_HOURS", "1")
    launch_time = datetime.now(timezone.utc) - timedelta(hours=1)

    client, stubber = _make_client()
    stubber.add_response(
        "describe_instances",
        _describe_response(INSTANCE_ID, "running", launch_time),
        {"InstanceIds": [INSTANCE_ID]},
    )
    stubber.add_response(
        "stop_instances",
        _stop_response(INSTANCE_ID),
        {"InstanceIds": [INSTANCE_ID]},
    )
    stubber.activate()
    _patch_client(monkeypatch, client)

    result = lambda_handler({}, None)

    stubber.assert_no_pending_responses()
    assert result["action"] == "stopped"
    assert result["age_hours"] >= 1.0


# ---------------------------------------------------------------------------
# non-running states -> always noop, never call stop_instances
# ---------------------------------------------------------------------------


def test_state_stopped_is_noop(monkeypatch):
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)
    monkeypatch.setenv("MAX_LIFETIME_HOURS", "1")
    # Age is deliberately way over ceiling to prove the *state* check, not
    # the age check, is what short-circuits to noop.
    launch_time = datetime.now(timezone.utc) - timedelta(hours=100)

    client, stubber = _make_client()
    stubber.add_response(
        "describe_instances",
        _describe_response(INSTANCE_ID, "stopped", launch_time),
        {"InstanceIds": [INSTANCE_ID]},
    )
    stubber.activate()
    _patch_client(monkeypatch, client)

    result = lambda_handler({}, None)

    stubber.assert_no_pending_responses()
    assert result["action"] == "noop"
    assert result["reason"] == "already-not-running"
    assert result["state"] == "stopped"


def test_state_stopping_is_noop(monkeypatch):
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)
    monkeypatch.setenv("MAX_LIFETIME_HOURS", "1")
    launch_time = datetime.now(timezone.utc) - timedelta(hours=100)

    client, stubber = _make_client()
    stubber.add_response(
        "describe_instances",
        _describe_response(INSTANCE_ID, "stopping", launch_time),
        {"InstanceIds": [INSTANCE_ID]},
    )
    stubber.activate()
    _patch_client(monkeypatch, client)

    result = lambda_handler({}, None)

    stubber.assert_no_pending_responses()
    assert result["action"] == "noop"
    assert result["reason"] == "already-not-running"
    assert result["state"] == "stopping"


def test_state_pending_is_noop(monkeypatch):
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)
    monkeypatch.setenv("MAX_LIFETIME_HOURS", "1")
    launch_time = datetime.now(timezone.utc) - timedelta(hours=100)

    client, stubber = _make_client()
    stubber.add_response(
        "describe_instances",
        _describe_response(INSTANCE_ID, "pending", launch_time),
        {"InstanceIds": [INSTANCE_ID]},
    )
    stubber.activate()
    _patch_client(monkeypatch, client)

    result = lambda_handler({}, None)

    stubber.assert_no_pending_responses()
    assert result["action"] == "noop"
    assert result["reason"] == "already-not-running"
    assert result["state"] == "pending"


# ---------------------------------------------------------------------------
# instance lookup edge cases
# ---------------------------------------------------------------------------


def test_instance_not_found_client_error_is_noop(monkeypatch):
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)

    client, stubber = _make_client()
    stubber.add_client_error(
        "describe_instances",
        service_error_code="InvalidInstanceID.NotFound",
        service_message=f"The instance ID '{INSTANCE_ID}' does not exist",
        http_status_code=400,
    )
    stubber.activate()
    _patch_client(monkeypatch, client)

    result = lambda_handler({}, None)

    stubber.assert_no_pending_responses()
    assert result["action"] == "noop"
    assert result["reason"] == "instance-not-found"


def test_describe_instances_other_client_error_propagates(monkeypatch):
    """Only InvalidInstanceID.NotFound/.Malformed are treated as "not found
    -> noop" by _describe_instance. Any other describe_instances failure
    (e.g. a permissions problem) must propagate out of handler() so the
    invocation is recorded as failed, not silently swallowed as a noop."""
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)

    client, stubber = _make_client()
    stubber.add_client_error(
        "describe_instances",
        service_error_code="UnauthorizedOperation",
        service_message="You are not authorized to perform this operation.",
        http_status_code=403,
    )
    stubber.activate()
    _patch_client(monkeypatch, client)

    with pytest.raises(ClientError):
        lambda_handler({}, None)

    stubber.assert_no_pending_responses()


def test_describe_returns_empty_reservations_is_noop(monkeypatch):
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)

    client, stubber = _make_client()
    stubber.add_response(
        "describe_instances",
        {"Reservations": []},
        {"InstanceIds": [INSTANCE_ID]},
    )
    stubber.activate()
    _patch_client(monkeypatch, client)

    result = lambda_handler({}, None)

    stubber.assert_no_pending_responses()
    assert result["action"] == "noop"
    assert result["reason"] == "instance-not-found"


def test_missing_launch_time_is_noop(monkeypatch):
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)

    client, stubber = _make_client()
    response = _describe_response(INSTANCE_ID, "running", include_launch_time=False)
    stubber.add_response("describe_instances", response, {"InstanceIds": [INSTANCE_ID]})
    stubber.activate()
    _patch_client(monkeypatch, client)

    result = lambda_handler({}, None)

    stubber.assert_no_pending_responses()
    assert result["action"] == "noop"
    assert result["reason"] == "no-launch-time"
    assert result["state"] == "running"


# ---------------------------------------------------------------------------
# MAX_LIFETIME_HOURS parsing / fallback
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("raw_value", ["abc", "nan", "inf", "-inf"])
def test_bad_max_lifetime_hours_falls_back_to_default(monkeypatch, raw_value):
    """Covers both the non-numeric-string branch ("abc") and the
    finite-but-unusable-float branch (nan/inf/-inf) of the fallback:
    float("nan")/float("inf") both parse without raising, but must never
    reach the ceiling comparison -- `age_hours < nan` is always False (the
    handler would fall through to stop_instances on *every* invocation,
    regardless of age) and `age_hours < inf` is always True (the cap would
    be silently disabled forever). "-inf" is included for
    completeness/regression coverage even though it is already caught by
    the pre-existing "not positive" fallback.

    Each value is checked on both sides of the default 12h ceiling so a
    leak in *either* direction is caught: an un-rejected "nan" would
    wrongly stop in the under-ceiling phase, and an un-rejected "inf"
    would wrongly no-op in the over-ceiling phase.
    """
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)
    monkeypatch.setenv("MAX_LIFETIME_HOURS", raw_value)

    # 13h old: past the default 12h ceiling -> stops.
    client, stubber = _make_client()
    launch_time_over = datetime.now(timezone.utc) - timedelta(hours=13)
    stubber.add_response(
        "describe_instances",
        _describe_response(INSTANCE_ID, "running", launch_time_over),
        {"InstanceIds": [INSTANCE_ID]},
    )
    stubber.add_response(
        "stop_instances", _stop_response(INSTANCE_ID), {"InstanceIds": [INSTANCE_ID]}
    )
    stubber.activate()
    _patch_client(monkeypatch, client)

    result_over = lambda_handler({}, None)

    stubber.assert_no_pending_responses()
    stubber.deactivate()
    assert result_over["action"] == "stopped"
    assert result_over["max_lifetime_hours"] == 12.0

    # 11h old: under the default 12h ceiling -> noop.
    client2, stubber2 = _make_client()
    launch_time_under = datetime.now(timezone.utc) - timedelta(hours=11)
    stubber2.add_response(
        "describe_instances",
        _describe_response(INSTANCE_ID, "running", launch_time_under),
        {"InstanceIds": [INSTANCE_ID]},
    )
    stubber2.activate()
    _patch_client(monkeypatch, client2)

    result_under = lambda_handler({}, None)

    stubber2.assert_no_pending_responses()
    assert result_under["action"] == "noop"
    assert result_under["reason"] == "under-ceiling"
    assert result_under["max_lifetime_hours"] == 12.0


def test_empty_max_lifetime_hours_falls_back_to_default(monkeypatch):
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)
    monkeypatch.setenv("MAX_LIFETIME_HOURS", "")
    launch_time = datetime.now(timezone.utc) - timedelta(hours=13)

    client, stubber = _make_client()
    stubber.add_response(
        "describe_instances",
        _describe_response(INSTANCE_ID, "running", launch_time),
        {"InstanceIds": [INSTANCE_ID]},
    )
    stubber.add_response(
        "stop_instances", _stop_response(INSTANCE_ID), {"InstanceIds": [INSTANCE_ID]}
    )
    stubber.activate()
    _patch_client(monkeypatch, client)

    result = lambda_handler({}, None)

    stubber.assert_no_pending_responses()
    assert result["action"] == "stopped"
    assert result["max_lifetime_hours"] == 12.0


# ---------------------------------------------------------------------------
# instance id resolution (TARGET_INSTANCE_ID / legacy INSTANCE_ID)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "target_value,legacy_value",
    [
        (None, None),
        ("   ", None),
        (None, "   "),
        ("   ", "   "),
    ],
    ids=[
        "both-unset",
        "target-whitespace-only",
        "legacy-whitespace-only",
        "both-whitespace-only",
    ],
)
def test_no_usable_instance_id_env_raises_value_error(monkeypatch, target_value, legacy_value):
    # clean_env autouse fixture already guarantees both vars start unset.
    if target_value is not None:
        monkeypatch.setenv("TARGET_INSTANCE_ID", target_value)
    if legacy_value is not None:
        monkeypatch.setenv("INSTANCE_ID", legacy_value)

    with pytest.raises(ValueError):
        lambda_handler({}, None)


def test_legacy_instance_id_env_used_when_target_absent(monkeypatch):
    monkeypatch.setenv("INSTANCE_ID", INSTANCE_ID)
    launch_time = datetime.now(timezone.utc) - timedelta(hours=1)

    client, stubber = _make_client()
    stubber.add_response(
        "describe_instances",
        _describe_response(INSTANCE_ID, "running", launch_time),
        {"InstanceIds": [INSTANCE_ID]},
    )
    stubber.activate()
    _patch_client(monkeypatch, client)

    result = lambda_handler({}, None)

    stubber.assert_no_pending_responses()
    assert result["instance_id"] == INSTANCE_ID
    assert result["action"] == "noop"
    assert result["reason"] == "under-ceiling"


def test_whitespace_only_target_instance_id_falls_back_to_legacy(monkeypatch):
    """A whitespace-only TARGET_INSTANCE_ID is truthy before stripping, so
    without stripping each candidate before the `or` fallback, this would
    wrongly win over a valid legacy INSTANCE_ID and then strip down to ''
    -- silently disabling the guard. The Stubber's expected_params pin the
    describe_instances call to the legacy id, so this fails loudly if the
    empty-after-strip target leaks through instead."""
    monkeypatch.setenv("TARGET_INSTANCE_ID", "   ")
    monkeypatch.setenv("INSTANCE_ID", INSTANCE_ID)
    launch_time = datetime.now(timezone.utc) - timedelta(hours=1)

    client, stubber = _make_client()
    stubber.add_response(
        "describe_instances",
        _describe_response(INSTANCE_ID, "running", launch_time),
        {"InstanceIds": [INSTANCE_ID]},
    )
    stubber.activate()
    _patch_client(monkeypatch, client)

    result = lambda_handler({}, None)

    stubber.assert_no_pending_responses()
    assert result["instance_id"] == INSTANCE_ID
    assert result["action"] == "noop"
    assert result["reason"] == "under-ceiling"


def test_target_instance_id_preferred_over_legacy(monkeypatch):
    legacy_id = "i-legacy000000000"
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)
    monkeypatch.setenv("INSTANCE_ID", legacy_id)
    launch_time = datetime.now(timezone.utc) - timedelta(hours=1)

    client, stubber = _make_client()
    stubber.add_response(
        "describe_instances",
        _describe_response(INSTANCE_ID, "running", launch_time),
        {"InstanceIds": [INSTANCE_ID]},
    )
    stubber.activate()
    _patch_client(monkeypatch, client)

    result = lambda_handler({}, None)

    stubber.assert_no_pending_responses()
    assert result["instance_id"] == INSTANCE_ID


# ---------------------------------------------------------------------------
# region handling
# ---------------------------------------------------------------------------


def test_aws_target_region_honored_by_client_factory(monkeypatch):
    """Exercise the real (unpatched) _ec2_client() to confirm it builds the
    client for AWS_TARGET_REGION. Client construction alone never touches
    the network/credential chain, so this needs no stubbing."""
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)
    monkeypatch.setenv("AWS_TARGET_REGION", "us-west-2")

    client = handler_module._ec2_client()

    assert client.meta.region_name == "us-west-2"


# ---------------------------------------------------------------------------
# stop_instances failure propagation
# ---------------------------------------------------------------------------


def test_stop_instances_failure_is_raised_not_swallowed(monkeypatch):
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)
    monkeypatch.setenv("MAX_LIFETIME_HOURS", "1")
    launch_time = datetime.now(timezone.utc) - timedelta(hours=5)

    client, stubber = _make_client()
    stubber.add_response(
        "describe_instances",
        _describe_response(INSTANCE_ID, "running", launch_time),
        {"InstanceIds": [INSTANCE_ID]},
    )
    stubber.add_client_error(
        "stop_instances",
        service_error_code="UnauthorizedOperation",
        service_message="You are not authorized to perform this operation.",
        http_status_code=403,
    )
    stubber.activate()
    _patch_client(monkeypatch, client)

    with pytest.raises(ClientError):
        lambda_handler({}, None)

    stubber.assert_no_pending_responses()
