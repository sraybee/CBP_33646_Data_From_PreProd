# RCA — CBP-31078 / CBP-33646

The bug is caused by a gap between what `dsl-engine-cli` validates and what actually gets written to etcd.

## What `dsl-engine-cli` does

After transforming the workflow, `transformWorkflow()` in `transformworkflow.go` calls `validateObjectSize()` on every object it is about to create — Task, ConfigMap, Secret, PipelineRun. The limit is defined in `engine.go` as two constants: `k8sObjectSizeLimit = 1024 * 1024` (1 MB) and `limitValidationMultiplier = 0.7`. The actual check in `validateObjectSize()` rejects any object whose serialized size exceeds `0.7 × 1,048,576 = 734,003 bytes (~717 KB)`. At even 297 steps, the Task object is only ~330 KB, so `validateObjectSize()` never rejects it. All objects are created successfully from `dsl-engine-cli`'s perspective.

## What Tekton does (outside dsl-engine-cli's control)

When the Tekton TaskRun controller reconciles the submitted TaskRun, it internally constructs a run Pod by injecting per-step entrypoint overrides, step-ordering environment variables, and volume mounts for every step in the Task. This Pod spec is approximately 8–10x larger than the Task itself. At ~163–165 steps it exceeds the etcd `max-request-bytes` limit. etcd rejects the write, Tekton marks the TaskRun as `PodCreationFailed`, and that error message bubbles up as `etcdserver: request is too large`.

## Why `validateObjectSize()` cannot catch this

`dsl-engine-cli` never calls `client.Create(pod)` — the Pod is created by Tekton's controller, not by `dsl-engine-cli`. So `validateObjectSize()` is architecturally never in the call path for the object that actually fails.

## Why the feature flag makes it exploitable

The 100-step limit in `transformToTektonTask()` (in `transformjob.go`) was the implicit safety guard keeping step count — and therefore Pod size — below the etcd threshold. The feature flag bypasses this check entirely, with no replacement guard that estimates projected Pod size before submission.

## Fix direction (per the Jira description)

`validateObjectSize()` needs to be extended — or a new pre-flight check added in `transformToTektonTask()` — to estimate the projected run Pod size based on step count before the Task/TaskRun is submitted to Tekton. If the estimated Pod size would exceed the etcd limit, reject with a clear user-facing error inside meta-pipeline rather than letting Tekton fail silently with `PodCreationFailed`.

---

## Supporting Data

| Steps | ETCD Error | Run Pod Exists | Run Pod Size | Task Size | TaskRun Status |
|-------|-----------|----------------|--------------|-----------|----------------|
| 140   | No        | Yes            | 4,514,125 B (4.30 MB) | 157,929 B | Pending        |
| 152   | No        | Yes            | 5,266,824 B (5.02 MB) | 171,069 B | TaskRunTimeout |
| 160   | No        | Yes            | 5,799,839 B (5.53 MB) | 179,824 B | Pending        |
| 170   | **Yes**   | **No**         | —            | 190,779 B | **PodCreationFailed** |
| 190   | **Yes**   | **No**         | —            | 212,679 B | **PodCreationFailed** |
| 220   | **Yes**   | **No**         | —            | 245,529 B | **PodCreationFailed** |
| 242   | **Yes**   | **No**         | —            | 269,619 B | **PodCreationFailed** |
| 270   | **Yes**   | **No**         | —            | 300,279 B | **PodCreationFailed** |
| 297   | **Yes**   | **No**         | —            | 329,844 B | **PodCreationFailed** |

**Threshold: between 160 and 170 steps.** The run Pod is created by Tekton (not dsl-engine-cli) and grows ~9–10 KB per step due to Tekton's per-step injection overhead.
