"""
Pytest suite for lambda/max-lifetime-stop/handler.py.

No network calls and no real AWS credentials are needed:

  * We build a *real* boto3 EC2 client (so botocore's request/response
    validation still applies) but wrap it in ``botocore.stub.Stubber`` and
    give it throwaway static credentials, so nothing ever hits the network
    or a credential provider chain.
  * ``handler._ec2_client`` (the handler's own client factory) is
    monkeypatched per-test to return that stubbed client.
  * The exact max-lifetime boundary uses the handler's small ``_utc_now``
    seam so it is deterministic rather than relying on wall-clock scheduling.
"""

from __future__ import annotations

import os
from datetime import UTC, datetime, timedelta

import boto3
import pytest
from botocore.exceptions import ClientError
from botocore.stub import Stubber

# Imported as a module (rather than `from conftest import ...`) to make it
# obvious at the call site that the helper under test is the suite's own
# hermeticity scrubbing, not a handler concern.
import conftest
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


def _describe_response(
    instance_id,
    state,
    launch_time=None,
    include_launch_time=True,
    include_state=True,
):
    """Build a DescribeInstances response.

    ``include_state=False`` omits the State member entirely. That is not a
    shape EC2 realistically returns, but State is not a required member of the
    Instance shape (so Stubber accepts it), and it is the only way to reach the
    handler's ``state = ... "unknown"`` default and the ``not-running`` reason
    that hangs off it.
    """
    instance = {
        "InstanceId": instance_id,
    }
    if include_state:
        instance["State"] = {"Code": 0, "Name": state}
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
    for key in (
        "TARGET_INSTANCE_ID",
        "INSTANCE_ID",
        "MAX_LIFETIME_HOURS",
        "AWS_TARGET_REGION",
        "AWS_DEFAULT_REGION",
        "AWS_REGION",
    ):
        monkeypatch.delenv(key, raising=False)


# ---------------------------------------------------------------------------
# running + age vs. ceiling
# ---------------------------------------------------------------------------


def test_running_well_over_ceiling_stops_instance(monkeypatch):
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)
    monkeypatch.setenv("MAX_LIFETIME_HOURS", "12")
    launch_time = datetime.now(UTC) - timedelta(hours=20)

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
    launch_time = datetime.now(UTC) - timedelta(hours=12) + timedelta(minutes=1)

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
    """age_hours >= max_hours (not strictly >) must still stop."""
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)
    monkeypatch.setenv("MAX_LIFETIME_HOURS", "1")
    now = datetime(2026, 8, 2, tzinfo=UTC)
    monkeypatch.setattr(handler_module, "_utc_now", lambda: now)
    launch_time = now - timedelta(hours=1)

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
    launch_time = datetime.now(UTC) - timedelta(hours=100)

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
    launch_time = datetime.now(UTC) - timedelta(hours=100)

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
    launch_time = datetime.now(UTC) - timedelta(hours=100)

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


def test_state_terminated_is_noop(monkeypatch):
    """'terminated' is in _NON_RUNNING_STATES but was never exercised, so a
    refactor could drop it from the set and still ship green -- and stopping a
    terminated instance is the one call guaranteed to fail."""
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)
    monkeypatch.setenv("MAX_LIFETIME_HOURS", "1")
    launch_time = datetime.now(UTC) - timedelta(hours=100)

    client, stubber = _make_client()
    stubber.add_response(
        "describe_instances",
        _describe_response(INSTANCE_ID, "terminated", launch_time),
        {"InstanceIds": [INSTANCE_ID]},
    )
    stubber.activate()
    _patch_client(monkeypatch, client)

    result = lambda_handler({}, None)

    stubber.assert_no_pending_responses()
    assert result["action"] == "noop"
    assert result["reason"] == "already-not-running"
    assert result["state"] == "terminated"


def test_unrecognized_state_is_noop_with_the_not_running_reason(monkeypatch):
    """The `not-running` reason -- the else side of the reason ternary, and a
    documented return value in the README -- is only reachable for a state
    outside _NON_RUNNING_STATES and not 'running': the 'unknown' default when
    the response carries no State, or a state EC2 adds in future. It was
    produced by no test, and statement coverage hid that because the ternary
    is one line, so either side of it could be inverted and still ship green.
    The important assertion is the last one: an unrecognized state must never
    be read as licence to stop."""
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)
    monkeypatch.setenv("MAX_LIFETIME_HOURS", "1")
    launch_time = datetime.now(UTC) - timedelta(hours=100)

    client, stubber = _make_client()
    stubber.add_response(
        "describe_instances",
        _describe_response(INSTANCE_ID, None, launch_time, include_state=False),
        {"InstanceIds": [INSTANCE_ID]},
    )
    # No stop_instances response is queued: Stubber raises if one is called.
    stubber.activate()
    _patch_client(monkeypatch, client)

    result = lambda_handler({}, None)

    stubber.assert_no_pending_responses()  # proves stop_instances was NOT called
    assert result["state"] == "unknown"
    assert result["action"] == "noop"
    assert result["reason"] == "not-running"


# ---------------------------------------------------------------------------
# instance lookup edge cases
# ---------------------------------------------------------------------------


def test_instance_not_found_client_error_is_noop(monkeypatch):
    """NotFound is a legitimate runtime condition (the guarded instance was
    terminated or replaced), so it degrades to a noop rather than failing the
    invocation -- unlike Malformed, below."""
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


def test_malformed_instance_id_client_error_propagates(monkeypatch):
    """A structurally invalid instance id can only be a configuration error --
    a typo'd TARGET_INSTANCE_ID edited into the Lambda console. It used to
    share the NotFound branch and degrade to a *successful* noop, which meant
    every scheduled tick reported success, the function's Errors metric stayed
    flat, and the cap was permanently and invisibly dead. It must fail the
    invocation instead: no future invocation would ever do better."""
    monkeypatch.setenv("TARGET_INSTANCE_ID", "i-not-a-real-id")

    client, stubber = _make_client()
    stubber.add_client_error(
        "describe_instances",
        service_error_code="InvalidInstanceID.Malformed",
        service_message="Invalid id: 'i-not-a-real-id'",
        http_status_code=400,
    )
    stubber.activate()
    _patch_client(monkeypatch, client)

    with pytest.raises(ClientError):
        lambda_handler({}, None)

    stubber.assert_no_pending_responses()


def test_describe_instances_other_client_error_propagates(monkeypatch):
    """Only InvalidInstanceID.NotFound is treated as "not found -> noop" by
    _describe_instance. Any other describe_instances failure (e.g. a
    permissions problem) must propagate out of handler() so the invocation is
    recorded as failed, not silently swallowed as a noop."""
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


def test_describe_returns_reservation_with_no_instances_is_noop(monkeypatch):
    """The second, distinct empty-response branch: a reservation came back but
    it contains no instances. The test above only covers the *no reservations*
    branch, so this one was uncovered -- and the two are adjacent enough that a
    refactor of _describe_instance could drop it without any test noticing."""
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)

    client, stubber = _make_client()
    stubber.add_response(
        "describe_instances",
        {"Reservations": [{"ReservationId": "r-0123456789abcdef0", "Instances": []}]},
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


@pytest.mark.parametrize("raw_value", ["abc", "nan", "inf", "-inf", "0", "-5"])
def test_bad_max_lifetime_hours_falls_back_to_default(monkeypatch, raw_value):
    """Covers all three fallback branches, one value class each:

      * "abc" -- the non-numeric-string branch (float() raises).
      * "nan"/"inf"/"-inf" -- the non-finite branch. All three parse without
        raising but must never reach the ceiling comparison: `age_hours < nan`
        is always False (the handler would fall through to stop_instances on
        *every* invocation, regardless of age) and `age_hours < inf` is always
        True (the cap silently disabled forever). Note "-inf" is caught here,
        by the math.isfinite check, NOT by the non-positive check below it --
        isfinite runs first, so -inf returns before `hours <= 0` is ever
        evaluated. (An earlier version of this docstring claimed otherwise,
        which left the branch below with zero coverage while reading as though
        it were covered.)
      * "0"/"-5" -- the non-positive branch, which is the only thing that
        actually exercises `hours <= 0`. It matters most of the three:
        MAX_LIFETIME_HOURS=0 makes `age_hours >= 0` true on every invocation,
        i.e. stop the box minutes after boot, on every schedule tick, forever.

    Each value is checked on both sides of the default 12h ceiling so a
    leak in *either* direction is caught: an un-rejected "nan" would
    wrongly stop in the under-ceiling phase, and an un-rejected "inf"
    would wrongly no-op in the over-ceiling phase.
    """
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)
    monkeypatch.setenv("MAX_LIFETIME_HOURS", raw_value)

    # 13h old: past the default 12h ceiling -> stops.
    client, stubber = _make_client()
    launch_time_over = datetime.now(UTC) - timedelta(hours=13)
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
    launch_time_under = datetime.now(UTC) - timedelta(hours=11)
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
    launch_time = datetime.now(UTC) - timedelta(hours=13)

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
def test_no_usable_instance_id_env_raises_value_error(
    monkeypatch, target_value, legacy_value
):
    # clean_env autouse fixture already guarantees both vars start unset.
    if target_value is not None:
        monkeypatch.setenv("TARGET_INSTANCE_ID", target_value)
    if legacy_value is not None:
        monkeypatch.setenv("INSTANCE_ID", legacy_value)

    with pytest.raises(ValueError):
        lambda_handler({}, None)


def test_legacy_instance_id_env_used_when_target_absent(monkeypatch):
    monkeypatch.setenv("INSTANCE_ID", INSTANCE_ID)
    launch_time = datetime.now(UTC) - timedelta(hours=1)

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
    launch_time = datetime.now(UTC) - timedelta(hours=1)

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
    launch_time = datetime.now(UTC) - timedelta(hours=1)

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


def test_padded_aws_target_region_is_stripped(monkeypatch):
    """A stray space around the region -- trivially introduced by a console
    edit or a shell variable -- is truthy, so without stripping it goes
    straight to boto3, which raises InvalidRegionError on *every* invocation
    before describe_instances ever runs. The cap would then never fire at
    all, visible only on the function's Errors metric."""
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)
    monkeypatch.setenv("AWS_TARGET_REGION", "  us-west-2 ")

    client = handler_module._ec2_client()

    assert client.meta.region_name == "us-west-2"


def test_whitespace_only_aws_target_region_falls_back_to_default_region(monkeypatch):
    """Empty-after-stripping means "the operator set nothing", so the client
    must fall through to boto3's standard resolution rather than raising."""
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)
    monkeypatch.setenv("AWS_TARGET_REGION", "   ")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-2")

    client = handler_module._ec2_client()

    assert client.meta.region_name == "us-east-2"


def test_default_region_used_when_target_region_is_unset(monkeypatch):
    """Without an explicit target region, defer to boto3's standard region
    configuration. Lambda provides AWS_DEFAULT_REGION and AWS_REGION."""
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-2")

    client = handler_module._ec2_client()

    assert client.meta.region_name == "us-east-2"


# ---------------------------------------------------------------------------
# suite hermeticity (see conftest.py)
# ---------------------------------------------------------------------------


def test_hermetic_env_survives_an_ambient_aws_profile(monkeypatch):
    """conftest's scrubbing must neutralize an ambient AWS_PROFILE, not just
    the config files it would have been read from.

    This calls the scrubber directly, *after* deliberately re-introducing a
    bogus profile, because the autouse fixture alone proves nothing on a
    machine that has no AWS_PROFILE to begin with -- which is every CI runner,
    and is exactly why the gap survived: with the profile name left set and
    the config file pointed at os.devnull, botocore raises ProfileNotFound
    during client construction and 21 of these tests fail before their first
    assertion, on a developer laptop only.
    """
    # clean_env clears the ambient region vars, and a region-less client
    # raises NoRegionError for reasons that have nothing to do with profiles.
    monkeypatch.setenv("AWS_TARGET_REGION", "us-east-1")
    for name in conftest.PROFILE_ENV_VARS:
        monkeypatch.setenv(name, "bogus-sso-profile-that-does-not-exist")

    conftest.scrub_ambient_aws_env(monkeypatch)

    for name in conftest.PROFILE_ENV_VARS:
        assert name not in os.environ
    # Client construction is where ProfileNotFound would have been raised.
    assert handler_module._ec2_client().meta.region_name == "us-east-1"


# ---------------------------------------------------------------------------
# stop_instances failure propagation
# ---------------------------------------------------------------------------


def test_stop_instances_failure_is_raised_not_swallowed(monkeypatch):
    monkeypatch.setenv("TARGET_INSTANCE_ID", INSTANCE_ID)
    monkeypatch.setenv("MAX_LIFETIME_HOURS", "1")
    launch_time = datetime.now(UTC) - timedelta(hours=5)

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
