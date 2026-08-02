"""
Pytest conftest for lambda/max-lifetime-stop.

Makes the suite hermetic against the developer's ambient AWS config.

test_handler.py builds *real* boto3 EC2 clients (wrapped in
botocore.stub.Stubber) rather than mocking boto3 outright, specifically so
botocore's own request/response validation still runs. But "real client"
means construction still walks botocore's normal config-resolution chain,
which reads ``~/.aws/config`` / ``~/.aws/credentials`` from disk regardless
of the throwaway static credentials individual tests pass in. On a machine
where the default (or ambient ``AWS_PROFILE``) profile is something like a
'login_session' SSO profile, that resolution can require the optional
``botocore[crt]`` extra and raise before a test's own assertions ever run --
e.g. test_aws_target_region_honored_by_client_factory, which calls the real
(unpatched) ``handler_module._ec2_client()`` and so gets no Stubber/explicit
credentials to shield it.

The fix: point botocore at empty config/credentials files (``os.devnull``) and
pin static throwaway credentials via env vars, so client construction never
touches ``~/.aws/*`` or a real credential provider (env/SSO/IMDS/etc.) on
any machine, hermetic-CI or a developer laptop alike.

AWS_DEFAULT_REGION / AWS_REGION are deliberately not set here. The handler
test suite clears both ambient values before each test, then explicitly sets
AWS_DEFAULT_REGION in its fallback-region test. That keeps default-region
behavior hermetic without masking the fallback path.
"""

import os

import pytest


@pytest.fixture(autouse=True)
def hermetic_aws_env(monkeypatch):
    """Prevent boto3/botocore from reading the developer's real ~/.aws
    config or resolving real credentials, for every test in this suite."""
    monkeypatch.setenv("AWS_CONFIG_FILE", os.devnull)
    monkeypatch.setenv("AWS_SHARED_CREDENTIALS_FILE", os.devnull)
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")
