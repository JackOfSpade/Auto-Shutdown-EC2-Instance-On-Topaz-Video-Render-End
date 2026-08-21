#!/usr/bin/env bash
# Minimal fake AWS CLI for test_create_iam_role.sh. Records every invocation in
# FAKE_AWS_TRACE (one flattened line per call) and emulates only the responses
# 02-create-iam-role.sh reads back. Every failure mode it can simulate is
# driven by an env knob, so a test can exercise one reconciliation branch at a
# time.
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_AWS_TRACE:?FAKE_AWS_TRACE must be set}"

if [[ "$1" == "iam" && "$2" == "create-role" && "${FAKE_ROLE_EXISTS:-0}" == "1" ]]; then
  echo "An error occurred (EntityAlreadyExists) when calling the CreateRole operation: Role with name topaz-render-instance-role already exists." >&2
  exit 254
fi

if [[ "$1" == "iam" && "$2" == "get-role" ]]; then
  # Only the role-already-exists branch reads this, and only for the trust
  # document. Default: a trust policy that still allows ec2.amazonaws.com.
  default_trust='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  printf '%s\n' "${FAKE_ROLE_TRUST:-$default_trust}"
  exit 0
fi

if [[ "$1" == "iam" && "$2" == "create-instance-profile" && "${FAKE_PROFILE_EXISTS:-0}" == "1" ]]; then
  echo "An error occurred (EntityAlreadyExists) when calling the CreateInstanceProfile operation: Instance Profile topaz-render-instance-profile already exists." >&2
  exit 254
fi

if [[ "$1" == "iam" && "$2" == "add-role-to-instance-profile" && "${FAKE_PROFILE_HAS_ROLE:-0}" == "1" ]]; then
  echo "An error occurred (LimitExceeded) when calling the AddRoleToInstanceProfile operation: Cannot exceed quota for InstanceSessionsPerInstanceProfile: 1" >&2
  exit 254
fi

if [[ "$1" == "iam" && "$2" == "get-instance-profile" ]]; then
  # Which role is ACTUALLY attached to the instance profile.
  printf '%s\n' "${FAKE_ATTACHED_ROLE:-topaz-render-instance-role}"
  exit 0
fi

if [[ "$1" == "iam" && "$2" == "get-role-policy" ]]; then
  # Used only by the INCLUDE_EC2_STOP!=1 "is a previous grant still live?"
  # probe, which discards output and checks the exit status.
  exit "${FAKE_EC2_STOP_POLICY_PRESENT:-1}"
fi

if [[ "$1" == "ec2" && "$2" == "associate-iam-instance-profile" ]]; then
  case "${FAKE_ASSOCIATE_RESULT:-ok}" in
    ok) exit 0 ;;
    already)
      echo "An error occurred (IncorrectState) when calling the AssociateIamInstanceProfile operation: There is an existing association for instance i-0123456789abcdef0" >&2
      exit 254
      ;;
    propagation)
      # The failure a too-short IAM propagation wait produces. It reads like a
      # typo in the profile name, which is exactly why 02 hints at it.
      echo "An error occurred (InvalidParameterValue) when calling the AssociateIamInstanceProfile operation: Invalid IAM Instance Profile name" >&2
      exit 254
      ;;
    denied)
      echo "An error occurred (UnauthorizedOperation) when calling the AssociateIamInstanceProfile operation: You are not authorized" >&2
      exit 254
      ;;
  esac
fi

if [[ "$1" == "ec2" && "$2" == "describe-iam-instance-profile-associations" ]]; then
  # 02 reads this twice on the mismatch path: once for the profile ARN, once
  # for the AssociationId it prints in the remediation command.
  if [[ " ${*} " == *"AssociationId"* ]]; then
    printf '%s\n' "${FAKE_ASSOCIATION_ID:-iip-assoc-0abcdef1234567890}"
  else
    printf '%s\n' "arn:aws:iam::123456789012:instance-profile/${FAKE_ASSOCIATED_PROFILE:-topaz-render-instance-profile}"
  fi
  exit 0
fi
