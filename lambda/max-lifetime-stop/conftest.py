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

The fix has two halves, and the second one is easy to forget:

1. Point botocore at empty config/credentials files (``os.devnull``) and pin
   static throwaway credentials via env vars, so client construction never
   touches ``~/.aws/*`` or a real credential provider (env/SSO/IMDS/etc.).
2. Remove the ambient *profile name* too. Emptying the config files is not
   enough on its own: with ``AWS_PROFILE`` still set, botocore dutifully looks
   that profile up in the now-empty config and raises
   ``botocore.exceptions.ProfileNotFound`` during client construction --
   trading one failure mode for another, and failing 21 of the suite's tests
   before a single assertion runs. Half a fix here looks exactly like no fix:
   green on CI (GitHub runners have no ``AWS_PROFILE``) and broken only on the
   laptop of whoever actually works on this code.

AWS_DEFAULT_REGION / AWS_REGION are deliberately not cleared here. The handler
test suite clears both ambient values before each test, then explicitly sets
AWS_DEFAULT_REGION in its fallback-region test. That keeps default-region
behavior hermetic without masking the fallback path.
"""

import os

import pytest

# Env vars that select a *profile*. Both must be unset, not overridden: any
# name we could set would also have to exist in the (deliberately empty)
# config file. See point 2 in the module docstring.
PROFILE_ENV_VARS = ("AWS_PROFILE", "AWS_DEFAULT_PROFILE")


def scrub_ambient_aws_env(monkeypatch):
    """Neutralize the ambient AWS configuration for one test.

    Factored out of the fixture below so the suite can exercise it directly
    (test_hermetic_env_survives_an_ambient_aws_profile) rather than only ever
    getting it applied invisibly by autouse -- a regression here is otherwise
    invisible on any machine that happens to have no AWS config, which is
    every CI runner.
    """
    for name in PROFILE_ENV_VARS:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("AWS_CONFIG_FILE", os.devnull)
    monkeypatch.setenv("AWS_SHARED_CREDENTIALS_FILE", os.devnull)
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")


@pytest.fixture(autouse=True)
def hermetic_aws_env(monkeypatch):
    """Prevent boto3/botocore from reading the developer's real ~/.aws
    config, resolving real credentials, or resolving an ambient named
    profile, for every test in this suite."""
    scrub_ambient_aws_env(monkeypatch)
