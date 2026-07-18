# 03 - Phase 1: Instance preparation (control plane)

[README](../README.md) - [Architecture](01-architecture.md) - [Phase 0](02-phase0-confirmations.md) - **Phase 1** - [Phase 2](04-phase2-watchdog.md) - [Phase 3](05-phase3-stop-sequence.md) - [Phase 4](06-phase4-safety-net.md) - [Phase 5](07-phase5-notifications.md)

Phase 1 runs from an **admin workstation** with AWS CLI v2 configured. It does
two control-plane things and one in-guest housekeeping thing: set the shutdown
behavior, create the least-privilege instance role, and make sure the box's PATH
has the tools the pipeline needs. Every script takes `INSTANCE_ID` and
`AWS_REGION` from the environment and stores no real ids or secrets.

## 1. Set the shutdown behavior to `stop`

This is the single most important control-plane setting in the whole project.

```bash
INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> \
  ./control-plane/01-set-shutdown-behavior.sh
```

[`01-set-shutdown-behavior.sh`](../control-plane/01-set-shutdown-behavior.sh)
runs `aws ec2 modify-instance-attribute --instance-initiated-shutdown-behavior
stop` and then **reads the attribute back** to confirm it took, aborting if the
value is anything other than `stop`.

Why it matters: a default EC2 instance **terminates** on a guest-initiated
shutdown. With this set to `stop`, the watchdog's `Stop-Computer -Force` stops
the box (preserving the root volume and letting you restart it) instead of
destroying it. This is what lets the primary stop path work with **no AWS API
call and no credentials on the box** (see [Architecture](01-architecture.md)).

## 2. Create the least-privilege instance role

```bash
INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> \
  ./control-plane/02-create-iam-role.sh
```

[`02-create-iam-role.sh`](../control-plane/02-create-iam-role.sh) creates the
role `topaz-render-instance-role` + instance profile
`topaz-render-instance-profile`, attaches an inline policy, and associates the
profile with the instance. It is idempotent - re-runs reuse existing entities
rather than failing.

**Normal grant (all the box needs):** `cloudwatch:PutMetricData` only, from
[`iam/cloudwatch-putmetric-policy.json`](../control-plane/iam/cloudwatch-putmetric-policy.json).
That is the single permission the metric publisher
([Phase 4](06-phase4-safety-net.md)) requires. The trust policy
([`iam/instance-role-trust-policy.json`](../control-plane/iam/instance-role-trust-policy.json))
lets `ec2.amazonaws.com` assume the role.

**Optional API-stop grant (off by default):**

```bash
INSTANCE_ID=i-XXXXXXXXXXXXXXXXX AWS_REGION=<region> INCLUDE_EC2_STOP=1 \
  ./control-plane/02-create-iam-role.sh
```

`INCLUDE_EC2_STOP=1` additionally attaches
[`iam/ec2-stop-optional-policy.json`](../control-plane/iam/ec2-stop-optional-policy.json),
an `ec2:StopInstances` grant **tag-scoped** to instances tagged
`AutoStopEligible=true`. This is belt-and-suspenders for operators who want an
API stop path; the normal guest-shutdown stop does not use it. Leave it off
unless you specifically want it.

> **The primary path deliberately does not need this permission.** Granting
> `ec2:StopInstances` is a *choice*, not a requirement. Keeping it off means the
> box literally cannot call the EC2 API to stop anything - it can only shut its
> own OS down.

## 3. AutoAdminLogon caveat (treat any stored password as a secret)

For a fully unattended run the Topaz GUI must come up in an interactive session
after a fresh boot, which typically means enabling **AutoAdminLogon** so a user
session exists for Topaz to render in.

Handle this carefully:

- **AutoAdminLogon stores a password in the registry** (`DefaultPassword` under
  `Winlogon`). Treat that value as a **secret**: it can be read by anyone who can
  read the registry or the AMI.
- **Prefer a throwaway, low-privilege local account** dedicated to running Topaz,
  not a domain account and not an account whose password is reused anywhere.
- **Keep the stored password out of the golden AMI** where you can - wire up
  AutoAdminLogon on the launched instance rather than baking it into the shared
  image (see the Sysprep note in [Phase 0](02-phase0-confirmations.md)).
- Rotate/retire the account when you are done with the box.

The watchdog and stop tasks themselves run as **SYSTEM** (see
[Phase 2](04-phase2-watchdog.md)), not as this interactive user - so the
interactive account only needs to be able to run the Topaz GUI, nothing more.

## 4. Ensure `nvidia-smi` and `aws` are on PATH

The GPU metric publisher ([`Push-GpuMetric.ps1`](../in-guest/Push-GpuMetric.ps1))
shells out to both `nvidia-smi.exe` (to read GPU utilization) and `aws.exe` (to
publish the metric). Confirm both resolve on the box:

```powershell
Get-Command nvidia-smi.exe
Get-Command aws.exe
```

[`Install.ps1`](../in-guest/Install.ps1) also checks this and **warns** (without
failing) if either is missing. If the warning appears, install / add the missing
tool before relying on the idle alarm - otherwise the box can publish no GPU
metric and the safety net has nothing to watch. (The `nvidia-smi` visibility you
confirmed in Phase 0 is the interactive-session view; make sure the executable is
resolvable on PATH for the SYSTEM task too.)

## Phase 1 exit checklist

- [ ] `InstanceInitiatedShutdownBehavior` reads back as `stop`.
- [ ] `topaz-render-instance-role` created and associated (PutMetricData only, unless you chose `INCLUDE_EC2_STOP=1`).
- [ ] Interactive Topaz account is a throwaway local account; stored logon password treated as a secret and kept out of the AMI.
- [ ] `nvidia-smi.exe` and `aws.exe` both resolvable on PATH.

Continue to [Phase 2 - the watchdog](04-phase2-watchdog.md).
