# Why 160-Step Runs Get Stuck Forever (Infinite Pending)

## Run Details
- **Cluster**: tekton-preprod-us-west-2-gree
- **Namespace**: event-myworkflow160yaml-dfef7f59dd2c1ae5778ebd32155aec424e2d6f4
- **Steps**: 160
- **Pod**: run-disp80bda4b92a4c5a2e3294634b8a4fcf2fde0f1778ec2fc2a7167-pod
- **Triggered**: 2026-03-16 20:48:24 UTC
- **Data collected**: 2026-03-17

## Files In This Folder

| File | Description |
|------|-------------|
| `pod_yaml_160_steps.yaml` | Full pod spec as it exists in Kubernetes (5,799,886 bytes JSON / ~2.5 MB on disk as YAML) |
| `taskrun_yaml_160_steps.yaml` | Tekton TaskRun — shows `Succeeded: Unknown`, `reason: Pending`, never completes |
| `describe_pod_160_steps.txt` | `kubectl describe pod` output — includes Events section showing exactly what happened |
| `explanation.md` | This file |

---

## Observed Behavior

```
NAME                                                              READY   STATUS   RESTARTS   AGE
run-disp80bda4b92a4c5a2e3294634b8a4fcf2fde0f1778ec2fc2a7167-pod  0/160   Pending  0          22m+
```

- Pod is scheduled (`PodScheduled: True`) — node assigned: `ip-10-228-47-137.us-west-2.compute.internal`
- Pod stays `0/160 Pending` forever — no containers ever reach Running or Completed
- TaskRun stays `Unknown / Pending` — no completion, no timeout unless manually deleted
- `containerStatuses` is **completely absent** from the pod status (only `conditions`, `phase`, `qosClass` present)

---

## What the Events Show (from describe_pod_160_steps.txt)

The kubelet Events show the following sequence:

```
Normal   Scheduled          → Pod assigned to node
Normal   Created/Started    → prepare (init container) ✅
Normal   Created/Started    → step-prepare-workspace ✅
Normal   Created/Started    → step-s001-0 ✅
Normal   Created/Started    → step-s002-1 ✅
Normal   Created/Started    → step-s003-2 ✅
Normal   Created/Started    → step-s004-3 ✅
Warning  FailedToRetrieveImagePullSecret  (x19 over 22 minutes) ← repeating
```

The kubelet created and started only **6 containers out of 160**, then stopped entirely.

---

## Root Cause

### Why does it stop after 6 containers?

Tekton injects **2 emptyDir volumes per step** for its internal sequencing mechanism:
- `tekton-creds-init-home-N` (Memory-backed)
- `tekton-internal-run-N` (used to signal step completion to next step)

For 160 steps, each container mounts **ALL** `tekton-internal-run-N` volumes (its own writable + all others read-only) so it can watch for completion signals. This means:

- **Volumes defined on the pod**: 160 × 2 = **320 tekton emptyDir volumes** + shared volumes
- **Volume mounts per container**: 10 shared + 1 own `tekton-creds-init-home-N` + 160 `tekton-internal-run-N` = **~172 mounts per container**
- **Total bind mounts** the kubelet must set up across all 160 containers: ~**27,692 bind mounts**

### Why is `containerStatuses` completely absent?

The pod JSON size is **5,799,886 bytes** (~5.8 MB). etcd has a hard limit of **3,145,728 bytes (3 MiB)** per object. Kubernetes stores objects in etcd as protobuf (more compact than JSON), so the pod spec itself fits inside etcd (it was written — the pod exists). However, when the kubelet tries to **update `containerStatuses`** back into the pod object (a PATCH to the API server), that update would push the pod object's protobuf size over the 3 MB limit.

**Evidence**: `containerStatuses` is completely missing from the live pod status after 22+ minutes of the kubelet trying. The kubelet can fire **Events** (lightweight, separate ~1 KB objects) but cannot update the pod status itself.

### Why does `FailedToRetrieveImagePullSecret` appear?

This is a side-effect, not the root cause. The kubelet fires this warning as it attempts to pull images for step-s005 and beyond. The image pull itself would probably succeed, but the kubelet cannot write the container status updates back. The ECR secret is fine — the same secret works at 105 steps.

---

## Why Reducing Steps Fixes It

| Steps | Pod JSON size | Pod status update to etcd | Result |
|-------|--------------|--------------------------|--------|
| 105   | ~2.6 MB      | ✅ Fits — kubelet updates status normally | Completes |
| 160   | **5.8 MB**   | ❌ **Too large — kubelet cannot write containerStatuses back** | Infinite Pending |
| 170   | Would be ~6+ MB | ❌ **Pod spec itself rejected by etcd at write time** | PodCreationFailed |

At 160 steps the pod spec was just small enough (in protobuf encoding) to be written to etcd as a new object. But updating it with containerStatuses is a PATCH — the combined object size exceeds the 3 MB limit. So the pod is stuck in a permanently half-initialized state.

---

## Key Proof Points

1. **`containerStatuses` is absent** from live pod JSON after 22+ minutes — the kubelet is not updating pod status
2. **Only 6 EventS were recorded** for container creation (prepare + step-s001 through step-s004) — kubelet stopped logging further container Events
3. **`FailedToRetrieveImagePullSecret` repeats x19** — same ECR secret works fine at 105 steps, so the secret is not expired; the kubelet is just stuck trying to process the next batch
4. **Pod JSON = 5,799,886 bytes** — nearly 2× the etcd 3 MB hard limit
5. **Both `us-west-2-gree` and `us-east-1-blue`** reproduce identically — this is not cluster or node specific

---

## Summary

The 160-step pod gets stuck forever because:

> Tekton creates 2 emptyDir volumes per step (320 volumes for 160 steps), and each container mounts all of them (~172 mounts per container = ~27,692 total bind mounts). The resulting pod object is 5.8 MB in JSON. The pod spec itself fits in etcd (written successfully), but the kubelet cannot update `containerStatuses` back to the API server because that PATCH would push the pod object over etcd's 3 MB hard limit. The pod is permanently stuck — scheduled, on a node, but with no container statuses and no way for Tekton to know what happened. It sits Pending until manually deleted or the job timeout fires.

This is the same underlying cause as the 170-step `etcdserver: request is too large` error — just hitting the 3 MB ceiling at a different stage (status update vs initial write).
