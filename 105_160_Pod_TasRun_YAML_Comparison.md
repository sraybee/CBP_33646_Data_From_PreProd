# Pod & TaskRun YAML Comparison — CBP-33646

Data collected from PreProd (tekton-preprod clusters) by running `pod_log_collector.sh` against real bypass-limit workflows.

---

## Files

| File | Steps | Cluster | Date Collected |
|------|-------|---------|----------------|
| `pod_yaml_105_steps.yaml` | 105 | tekton-preprod-us-east-1-gree | 2026-03-13 |
| `taskrun_yaml_105_steps.yaml` | 105 | tekton-preprod-us-east-1-gree | 2026-03-13 |
| `pod_yaml_160_steps.yaml` | 160 | tekton-preprod-us-west-2-blue | 2026-03-13 |
| `taskrun_yaml_160_steps.yaml` | 160 | tekton-preprod-us-west-2-blue | 2026-03-13 |

---

## Size Comparison

| Metric | 105 steps | 160 steps |
|--------|-----------|-----------|
| Pod YAML size | 2,654,531 bytes (2.53 MB) | 2,583,341 bytes (2.46 MB) |
| TaskRun YAML size | 84,941 bytes (83 KB) | 103,482 bytes (101 KB) |

> Note: Pod YAML size is the kubectl YAML representation, not the etcd Protobuf size.
> The etcd hard limit is 3,145,728 bytes (3 MB). Protobuf is more compact than YAML,
> but the pod spec still breaches it at ~160 steps as confirmed by the actual etcd error.

---

## Tekton-Injected Volumes (Root Cause)

Tekton injects two emptyDir volumes per step into every pod:
- `tekton-internal-run-{N}` — step sequencing semaphore
- `tekton-creds-init-home-{N}` — credential init home

| Metric | 105 steps | 160 steps |
|--------|-----------|-----------|
| Unique `tekton-internal-run-*` volume entries | 210 (= 2 × 105) | 320 (= 2 × 160) |
| Volume range | `tekton-internal-run-0` → `tekton-internal-run-104` | `tekton-internal-run-0` → `tekton-internal-run-159` |

Every container in the pod gets ALL N run volumes mounted. Adding one step adds one volumeMount to every container.

---

## TaskRun Status Comparison

### 105 steps — Succeeded ✓

```
status: True (Succeeded)
lastTransitionTime: "2026-03-13T08:12:27Z"
```

Pod completed normally. All 105 steps ran to completion.

### 160 steps — Stuck / Infinite Pending ✗

```
status: Unknown
reason: Pending
message: Pending
lastTransitionTime: "2026-03-13T07:59:54Z"
podName: run-dispa33c935510a3d0d0a58f96172489ebe20d4cc9760cc2b1fec98-pod
```

Pod phase: `Pending`, `PodScheduled: True` — pod was created and scheduled to a node but **all 160 containers never started**. The TaskRun is stuck indefinitely with no error message surfaced to the user.

---

## Two Distinct Failure Modes (Both from Bypassing the 100-Step Limit)

| Mode | When | Symptom | Captured In |
|------|------|---------|-------------|
| **etcd write failure** | Pod spec too large (~3 MB) to write to etcd | `etcdserver: request is too large` — pod never created, TaskRun stuck Pending with no pod | March 12 east cluster run |
| **Infinite pending pod** | Pod created but too heavy (160 containers + 320 volumes) to initialize | Pod stuck `Pending` forever, TaskRun never progresses, no user-visible error | `taskrun_yaml_160_steps.yaml` (this file) |

Both failure modes are silent to the end user — the run just appears to hang.
This is exactly the risk described in the DSL warning:
> `Risk: Pod termination message overflow may cause infinite running TaskRuns. Manual cleanup may be required.`

---

## What is NOT in the Task Spec (Tekton Injects These Into the Pod)

None of the following exist in the `dsl-engine-cli` codebase — all are injected by Tekton's controller:

1. **`spec.volumes`** — `tekton-internal-run-{N}` and `tekton-creds-init-home-{N}` emptyDir per step
2. **`spec.containers[*].volumeMounts`** — ALL N run volumes mounted into every container
3. **`spec.containers[*].args`** — `-wait_file /tekton/run/{N-1}/out -post_file /tekton/run/{N}/out` wrapping every step command

Reference: https://github.com/tektoncd/pipeline/blob/becdc2ac0cb5f328589e4d4923e79c81f0518f46/cmd/entrypoint/README.md#L19

---

## Why validateObjectSize() in dsl-engine-cli Doesn't Catch This

`dsl-engine-cli` never creates the Pod. It creates the Task and TaskRun, which are handed to Tekton's controller. The controller then builds and writes the Pod to etcd. `validateObjectSize()` only runs on the Task object (~330 KB at 160 steps — well under 3 MB), so the size explosion in the Pod is invisible to our validation.
