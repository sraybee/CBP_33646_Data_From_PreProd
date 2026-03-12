# RCA — CBP-31078 / CBP-33646

The bug is caused by a gap between what `dsl-engine-cli` validates and what actually gets written to etcd.

## What `dsl-engine-cli` does

After transforming the workflow, `transformWorkflow()` in `transformworkflow.go` calls `validateObjectSize()` on every object it is about to create — Task, ConfigMap, Secret, PipelineRun. The limit is defined in `engine.go` as two constants: `k8sObjectSizeLimit = 1024 * 1024` (1 MB) and `limitValidationMultiplier = 0.7`. The actual check in `validateObjectSize()` rejects any object whose serialized size exceeds `0.7 × 1,048,576 = 734,003 bytes (~717 KB)`. At even 297 steps, the Task object is only ~330 KB, so `validateObjectSize()` never rejects it. All objects are created successfully from `dsl-engine-cli`'s perspective.

## What Tekton does (outside dsl-engine-cli's control)

When the Tekton TaskRun controller reconciles the submitted TaskRun, it internally constructs a run Pod by injecting per-step entrypoint overrides and — critically — **a `/tekton/run/{N}` volumeMount for every step into every container**. This is how Tekton implements step sequencing: each step's entrypoint binary waits on `/tekton/run/{prev}/out` and signals `/tekton/run/{self}/out`. Because every container gets mounts for all N steps, total pod spec size grows **O(N²)** in step count. At ~163–165 steps the pod spec alone approaches the etcd `max-request-bytes` limit of 3,145,728 bytes (3 MB). etcd rejects the write, Tekton marks the TaskRun as `PodCreationFailed`, and that error bubbles up as `etcdserver: request is too large`.

## Why `validateObjectSize()` cannot catch this

`dsl-engine-cli` never calls `client.Create(pod)` — the Pod is created by Tekton's controller, not by `dsl-engine-cli`. So `validateObjectSize()` is architecturally never in the call path for the object that actually fails.

## Why the feature flag makes it exploitable

The 100-step limit in `transformToTektonTask()` (in `transformjob.go`) was the implicit safety guard keeping step count — and therefore Pod size — below the etcd threshold. The feature flag bypasses this check entirely, with no replacement guard that estimates projected Pod size before submission.

## Why pod spec growth is O(N²) — confirmed from captured pod YAMLs

Actual pod YAMLs were captured from preprod at 105 steps (passed) and 160 steps (failed). Parsed results:

| | 105 steps | 160 steps |
|---|---|---|
| **Pod spec size** (written to etcd at creation) | **1,178,082 bytes** | **2,583,119 bytes** |
| `prepare-workspace` volumeMounts | 123 | 178 |
| `step-s001` volumeMounts | 118 | 173 |

The volumeMount difference is exactly 55 = (160 − 105). Each added step adds one `/tekton/run/{N}` mount to **every container**. For a pod with N steps and ~N containers, that is N² total mount entries in the spec. The spec size ratio (2.19×) for a step ratio of 1.52× confirms super-linear growth — close to the O(N²) prediction of 2.32×.

The size measurements above are from `kubectl get pod -o yaml | wc -c` (API server JSON/YAML representation). The true etcd Protobuf size is typically smaller, but the relative growth pattern is the same and the etcd error confirms the limit is being hit in practice.

Pod YAMLs for inspection: [105 steps](https://github.com/sraybee/CBP_33646_Data_From_PreProd/blob/main/pod_yaml_105_steps.yaml) | [160 steps](https://github.com/sraybee/CBP_33646_Data_From_PreProd/blob/main/pod_yaml_160_steps.yaml)

## Fix direction (per the Jira description)

`validateObjectSize()` needs to be extended — or a new pre-flight check added in `transformToTektonTask()` — to estimate the projected run Pod size based on step count before the Task/TaskRun is submitted to Tekton. If the estimated Pod size would exceed the etcd limit, reject with a clear user-facing error inside meta-pipeline rather than letting Tekton fail silently with `PodCreationFailed`.

Given the O(N²) growth, the safe step limit is approximately **~115–120 steps** before the pod spec + runtime status combined risk exceeding 3 MB.

---

## Supporting Data

| Steps | ETCD Error | Run Pod Exists | Run Pod JSON Size | Pod Spec Size | Task Size | TaskRun Status |
|-------|-----------|----------------|-------------------|--------------|-----------|----------------|
| 105   | No        | Yes            | 2,704,674 B (2.58 MB) | **1,178,082 B** | — | Succeeded |
| 140   | No        | Yes            | 4,514,125 B (4.30 MB) | — | 157,929 B | Pending |
| 152   | No        | Yes            | 5,266,824 B (5.02 MB) | — | 171,069 B | TaskRunTimeout |
| 160   | No        | Yes            | 5,799,839 B (5.53 MB) | **2,583,119 B** | 179,824 B | Pending |
| 170   | **Yes**   | **No**         | —                 | —            | 190,779 B | **PodCreationFailed** |
| 190   | **Yes**   | **No**         | —                 | —            | 212,679 B | **PodCreationFailed** |
| 220   | **Yes**   | **No**         | —                 | —            | 245,529 B | **PodCreationFailed** |
| 242   | **Yes**   | **No**         | —                 | —            | 269,619 B | **PodCreationFailed** |
| 270   | **Yes**   | **No**         | —                 | —            | 300,279 B | **PodCreationFailed** |
| 297   | **Yes**   | **No**         | —                 | —            | 329,844 B | **PodCreationFailed** |

**Threshold: between 160 and 170 steps.** The pod spec at creation is what hits the 3 MB etcd limit — the Tekton-injected `/tekton/run/{N}` volumeMounts are the primary driver, growing O(N²) with step count. This is entirely Tekton-internal and cannot be reduced from our side.
