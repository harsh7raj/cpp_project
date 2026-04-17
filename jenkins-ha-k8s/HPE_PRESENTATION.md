# Jenkins High Availability on Kubernetes — HPE Presentation Guide

> This document is written for someone presenting this project to HPE engineers.
> It covers the full architecture, every file and how they connect, the exact
> commands to run, the chain of thought behind every design decision, and the
> hardest questions engineers are likely to ask — with full answers rooted in
> the actual code.

---

## Table of Contents

1. [The One-Sentence Pitch](#1-the-one-sentence-pitch)
2. [Why This Problem Is Hard](#2-why-this-problem-is-hard)
3. [Architecture — The Big Picture](#3-architecture--the-big-picture)
4. [Every File, What It Does, and How They Connect](#4-every-file-what-it-does-and-how-they-connect)
5. [The Failover Sequence — Step by Step with Chain of Thought](#5-the-failover-sequence--step-by-step-with-chain-of-thought)
6. [How to Start the Demo (Step by Step)](#6-how-to-start-the-demo-step-by-step)
6a. [How to Run the Helm Upgrade Demo (Criterion 4)](#6a-how-to-run-the-helm-upgrade-demo-criterion-4)
6b. [How to Run the Browser UI Demo](#6b-how-to-run-the-browser-ui-demo)
7. [How to Stop / Clean Up After the Demo](#7-how-to-stop--clean-up-after-the-demo)
8. [What the Demo Output Means](#8-what-the-demo-output-means)
8a. [Helm Packaging and Private Registry](#8a-helm-packaging-and-private-registry)
9. [Hard Questions Engineers Will Ask — With Full Answers](#9-hard-questions-engineers-will-ask--with-full-answers)

---

## 1. The One-Sentence Pitch

> **Two Jenkins pods run simultaneously — one active, one hot standby — and if the active one dies, the standby automatically takes over within 30 seconds, with zero data loss, using only native Kubernetes primitives.**

No external databases. No third-party HA controllers. No proprietary lock managers. Everything is built from Kubernetes Lease objects, pod labels, a shell sidecar, and a shared PersistentVolume.

---

## 2. Why This Problem Is Hard

Before explaining what was built, it helps to understand what makes Jenkins HA hard in the first place.

Jenkins is a **stateful, single-master application**. It was not designed to run in a cluster. Its home directory (`/var/jenkins_home`) contains jobs, configurations, credentials, plugin state, and build history. You cannot just run two copies and load-balance between them — they would write conflicting state to disk and corrupt each other. This is called **split-brain**: two nodes both believing they are the leader.

The challenge is therefore threefold:

**1. Mutual exclusion** — at any moment, exactly one Jenkins instance must be running. Not zero (that is downtime), not two (that is corruption).

**2. Fast detection** — when the active instance dies, the system must detect this automatically, without a human operator, within a reasonable window.

**3. Data continuity** — all the job history, configs, and artifacts must be accessible to whichever pod takes over. The new leader must pick up exactly where the old one left off.

This project solves all three using a Kubernetes-native design.

---

## 3. Architecture — The Big Picture

```
                      ┌──────────────────────────────────┐
                      │     Kubernetes Service "jenkins"  │
                      │   selector: jenkins-role=active   │
                      │   (only routes to the leader)     │
                      └──────────────┬───────────────────┘
                                     │
               ┌─────────────────────┴──────────────────────┐
               ▼                                            ▼
     ┌─────────────────────┐                    ┌─────────────────────┐
     │      jenkins-0      │                    │      jenkins-1      │
     │   (ACTIVE ✅)        │                    │   (STANDBY ⏸)       │
     │                     │                    │                     │
     │  ┌───────────────┐  │                    │  ┌───────────────┐  │
     │  │   Jenkins     │  │                    │  │   Jenkins     │  │
     │  │   (running)   │  │                    │  │  (NOT running)│  │
     │  └───────────────┘  │                    │  └───────────────┘  │
     │  ┌───────────────┐  │◄── Lease object ──►│  ┌───────────────┐  │
     │  │ leader-elector│  │   (the lock)       │  │ leader-elector│  │
     │  │   sidecar     │  │                    │  │   sidecar     │  │
     │  └───────────────┘  │                    │  └───────────────┘  │
     └──────────┬──────────┘                    └──────────┬──────────┘
                │                                          │
                └──────────────┬───────────────────────────┘
                               │
                   ┌───────────▼───────────┐
                   │  PersistentVolumeClaim │
                   │   "jenkins-ha-home"   │
                   │   ReadWriteMany (RWX) │
                   │  /var/jenkins_home    │
                   └───────────────────────┘
```

**Chain of thought behind this design:**

> The fundamental question is: how do you let two pods share one role, where only one can be "the boss" at any time? The answer in distributed systems is a **lock**. Kubernetes provides a native lock object called a `Lease`. It has a holder field, a timestamp showing when it was last renewed, and a duration after which it is considered expired. This is exactly a distributed mutex — a concept from operating systems, applied at the infrastructure level. The sidecar in each pod is essentially a lock manager loop: "Do I hold the lock? Renew it. Does someone else hold a valid lock? Wait. Is the lock expired? Race to grab it."

---

## 4. Every File, What It Does, and How They Connect

### Directory Map

The deployment is packaged as a single Helm chart. The chart is the only source
of truth for every Kubernetes object the system needs.

```
jenkins-ha-k8s/
├── helm/jenkins-ha/                       ← The chart
│   ├── Chart.yaml                         ← Chart metadata + version
│   ├── values.yaml                        ← Every tunable (images, lease, storage, registry)
│   ├── files/scripts/                     ← Shell scripts (bundled into the ConfigMap)
│   │   ├── leader-elector.sh              ← Core lock manager (runs in sidecar)
│   │   ├── jenkins-guard.sh               ← Jenkins lifecycle manager
│   │   ├── readiness.sh                   ← "Is this pod ready for traffic?"
│   │   └── liveness.sh                    ← "Is this pod still alive?"
│   └── templates/
│       ├── _helpers.tpl                   ← Label / pull-secret helpers
│       ├── NOTES.txt                      ← Post-install help text
│       ├── serviceaccount.yaml            ← Pod identity for API calls
│       ├── role.yaml                      ← Exact permissions granted
│       ├── rolebinding.yaml               ← Links identity to permissions
│       ├── pvc.yaml                       ← Shared RWX disk declaration
│       ├── lease.yaml                     ← The lock object
│       ├── configmap-scripts.yaml         ← Pulls files/scripts/*.sh via .Files.Glob
│       ├── services.yaml                  ← ClusterIP (active-only) + headless
│       ├── statefulset.yaml               ← The two pods, fully defined
│       └── registry-secret.yaml           ← dockerconfigjson, gated by imagePullSecret.enabled
├── demo-failover.sh                       ← The live demo script
├── Makefile                               ← install / upgrade / uninstall / status / failover-test
├── README.md                              ← Quick start
└── HPE_PRESENTATION.md                    ← This file
```

The namespace itself is created by `helm install --create-namespace` (the
`Makefile` does this for you). Everything else lives inside `templates/`.

---

### Namespace — Isolation

The chart deploys into the `jenkins` namespace, which `helm install --create-namespace`
creates on the first install. All resources in this project live here. Scoping
to a namespace is standard Kubernetes hygiene: it prevents name collisions with
other workloads on the same cluster and allows RBAC (permissions) to be scoped
tightly to just this namespace.

---

### `templates/serviceaccount.yaml` + `templates/role.yaml` + `templates/rolebinding.yaml` — Permission Chain

This is a three-part chain. The pods need to call the Kubernetes API server at runtime (to read and write the Lease, and to label themselves). By default, pods have no API permissions. These three files grant them exactly the permissions they need — nothing more.

**`templates/role.yaml`:**
```yaml
rules:
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "create", "update", "patch", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "patch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
```

Breaking this down:
- `leases` — the sidecar must be able to read, create, and update the Lease object. Without this, leader election is impossible.
- `pods/patch` — the sidecar must be able to label its own pod (`jenkins-role=active` or `jenkins-role=standby`). This label is what the Service uses to route traffic. Without this, the Service would never shift traffic to the new leader.
- `events` — optional but good practice for observability; allows logging election events into Kubernetes.

**Chain of thought:** The principle here is **least privilege**. The sidecar is only granted exactly what it needs. It cannot read secrets, cannot delete pods, cannot touch other namespaces. If the sidecar were ever compromised, the blast radius is minimal.

**How they link:** `templates/rolebinding.yaml` binds the Role to the ServiceAccount. `templates/statefulset.yaml` specifies `serviceAccountName: jenkins-ha-sa`, which causes Kubernetes to mount the ServiceAccount token inside the pods automatically. `kubectl` inside the sidecar uses this mounted token transparently when it calls the API.

---

### `templates/pvc.yaml` — The Shared Disk

```yaml
spec:
  accessModes:
    - ReadWriteMany   # ← Both pods can read AND write simultaneously
  resources:
    requests:
      storage: 20Gi
```

`ReadWriteMany` (RWX) is the critical access mode here. Standard Kubernetes storage (`ReadWriteOnce`) only allows one pod to mount the volume at a time. RWX allows both `jenkins-0` and `jenkins-1` to have the same `/var/jenkins_home` mounted simultaneously.

**Chain of thought:** You might ask: "If both pods can write to the same disk at the same time, won't they corrupt each other?" The answer is: yes, they would — if both were running Jenkins simultaneously. That is exactly why only one pod ever runs Jenkins at a time (enforced by the guard script). The active pod writes; the standby pod has the volume mounted but Jenkins is not running inside it, so it is not writing anything. The shared disk is the mechanism that makes data survive failover — the new leader inherits all the data from the old leader's last write.

In this demo setup on `kind` (a single-node local Kubernetes cluster), the RWX storage is backed by a `hostPath` PersistentVolume pointing to `/tmp/jenkins-ha-home` on the node. In a real production HPE environment, this would be backed by NFS, CephFS, or a cloud provider's file storage (AWS EFS, Azure Files, etc.).

---

### `templates/lease.yaml` — The Lock

The Lease object is a first-class Kubernetes resource under the `coordination.k8s.io` API group. It has three key fields:

```yaml
spec:
  holderIdentity: "jenkins-0/<pod-uid>"   # Who holds the lock right now
  leaseDurationSeconds: 15                 # How long until it expires if not renewed
  renewTime: "2026-04-15T10:00:00Z"        # Last time the holder renewed it
```

**Chain of thought:** This is essentially a dead-man's switch. The holder must "check in" every 5 seconds by updating `renewTime`. If it stops checking in (because the pod died), the lease goes stale after 15 seconds. Any other pod watching the lease can then declare the holder dead and take over. The 15-second duration is a deliberate trade-off: shorter means faster failover but more risk of false positives (brief network hiccup triggers unnecessary failover); longer means more stability but slower recovery. 15 seconds with a 5-second renewal interval gives a 3x safety margin.

---

### `templates/configmap-scripts.yaml` — Scripts Packaged for Kubernetes

Kubernetes cannot run scripts from your laptop. Scripts must be injected into
pods. This template builds a ConfigMap whose `data` keys are populated dynamically
from every file in `helm/jenkins-ha/files/scripts/`:

```yaml
data:
{{- range $path, $_ := .Files.Glob "files/scripts/*.sh" }}
  {{ base $path }}: |
{{ $.Files.Get $path | indent 4 }}
{{- end }}
```

In `templates/statefulset.yaml`, this ConfigMap is mounted as a volume at
`/scripts` inside every container:

```yaml
volumes:
  - name: scripts
    configMap:
      name: jenkins-ha-scripts
      defaultMode: 0755   # ← Makes them executable
```

**The link:** When `helm install` (or `helm upgrade`) renders this template, the
scripts are stored in etcd as ConfigMap data. When pods start, Kubernetes
mounts the ConfigMap as files at `/scripts/`. So `/scripts/leader-elector.sh`
inside the container is exactly the content of the file in
`helm/jenkins-ha/files/scripts/leader-elector.sh` — no file copying, no
Dockerfiles, no image builds.

**Single source of truth:** Because the ConfigMap is generated from
`files/scripts/`, there is no longer a "keep these in sync" hazard. Editing a
script and running `make upgrade` is enough — the StatefulSet template carries a
SHA256 checksum of the rendered ConfigMap, so Helm sees the change and triggers
a rolling restart automatically.

---

### `templates/statefulset.yaml` — The Heart of the System

This is the most important file. It defines what the two pods look like and how they behave.

**Why a StatefulSet and not a Deployment?**

`StatefulSet` gives each pod a **stable, predictable name**: `jenkins-0` and `jenkins-1`. They always get these exact names, even after restart. `Deployment` pods get random suffixes (`jenkins-7d4f9b-xkzpq`). For leader election using pod names as identities, stable names are required.

However — and this is critical — the *name* being stable does not mean the *instance* is stable. When `jenkins-0` is killed and recreated by the StatefulSet controller, it gets the same name but a **brand new pod UID**. This distinction is the key to making honest failover work.

**The two containers inside each pod:**

**Container 1: `jenkins`**
- Runs `/scripts/jenkins-guard.sh` as its entrypoint (not Jenkins directly)
- The guard script decides whether to start Jenkins or not
- Has environment variable `ROLE_FILE=/var/run/jenkins-ha/role` which it reads every 2 seconds
- Mounts the shared PVC at `/var/jenkins_home` — this is where Jenkins stores all its data
- Has both a liveness probe (`liveness.sh`) and readiness probe (`readiness.sh`)

**Container 2: `leader-elector`**
- Runs `/scripts/leader-elector.sh`
- Has environment variables injected via the Kubernetes Downward API:
  - `POD_NAME` — the pod's name (`jenkins-0` or `jenkins-1`) from `metadata.name`
  - `POD_UID` — the pod's unique instance ID from `metadata.uid` ← **this is the key to honest failover**
  - `POD_NAMESPACE` — `jenkins`
- Mounts the `ha-signal` emptyDir volume at `/var/run/jenkins-ha` — this is the shared signal channel between the two containers

**The inter-container communication channel:**
```yaml
volumes:
  - name: ha-signal
    emptyDir: {}
```

An `emptyDir` is a temporary directory that exists only as long as the pod lives. Both containers in the same pod mount it. The sidecar writes `active` or `standby` to `/var/run/jenkins-ha/role`. The guard script reads that file. This is how the sidecar tells Jenkins whether to run.

**Chain of thought:** Two containers in the same pod share the same network namespace and can share volumes. The `emptyDir` acts like a Unix pipe but via the filesystem. The sidecar is the writer; the guard is the reader. They never talk to each other directly — they communicate through a single file. This is intentionally simple: a file either says `active` or `standby`. No complex IPC, no sockets, no race conditions on the signal itself.

**The UID-based identity (Downward API in the sidecar `env:`):**
```yaml
- name: POD_UID
  valueFrom:
    fieldRef:
      fieldPath: metadata.uid
```

This is the architectural fix that makes natural failover work. The sidecar script constructs its identity as `IDENTITY="${POD_NAME}/${POD_UID}"`. When the lease says `holderIdentity: jenkins-0/abc-123` and the newly recreated pod's sidecar has `IDENTITY=jenkins-0/def-456`, they do not match — so the new pod does not renew, does not claim leadership, and waits for the lease to expire. This solved the "same name, different instance" problem that caused the original race condition.

---

### `templates/services.yaml` — Traffic Routing

Two services are defined in this template:

**Service `jenkins` (the active-only Service):**
```yaml
selector:
  app: jenkins
  jenkins-role: active   # ← The magic selector
```

This service only routes traffic to pods that have **both** the `app=jenkins` label and the `jenkins-role=active` label. The `active` label is dynamically applied by the sidecar. When the sidecar labels itself `active`, the Service's endpoint list automatically updates — no human intervention, no rolling restart. The Kubernetes endpoint controller watches pod labels continuously and updates the endpoint list within 1–2 seconds of a label change.

**Service `jenkins-headless`:**
This service has `clusterIP: None`. It is required by the StatefulSet for stable DNS names. It gives each pod a DNS record: `jenkins-0.jenkins-headless.jenkins.svc.cluster.local`. This allows the pods to refer to each other by name if needed (not used in this implementation, but required by Kubernetes StatefulSet contract).

---

### `helm/jenkins-ha/files/scripts/leader-elector.sh` — The Core Algorithm

This is the brains of the system. It runs in an infinite loop inside the sidecar container. Here is the full logic annotated:

```
startup:
  - Write "standby" to role file  (conservative default)
  - Label self as standby
  - Ensure the Lease object exists in Kubernetes

loop every 2 seconds:
  - Read the Lease from Kubernetes API

  IF holder == my IDENTITY (pod-name/uid):
    → Renew the lease (update renewTime)
    → If I was standby, become active (write to role file, re-label pod)
    → Sleep 5 seconds (renewal interval)

  ELSE IF lease is vacant OR lease is older than 15 seconds:
    → Try to acquire: patch the Lease with my identity
    → Sleep 0.5 seconds
    → Verify I actually won (re-read the lease)
    → If I won: become active
    → If I lost: become standby (another pod won the race)

  ELSE:
    → Someone else holds a valid lease
    → If I was active, become standby (demote myself)
    → Sleep 2 seconds (retry interval)
```

**The race condition handling (the `try_acquire` + `verify_holder` block):**

The 0.5-second sleep after `try_acquire` followed by `verify_holder` is critical. Two pods can simultaneously decide the lease is expired and both attempt to patch it. Kubernetes applies patches serially — one will win, one will see the other's identity when it re-reads. The loser gracefully becomes standby. This is optimistic concurrency: try, then check if you actually won.

**The self-fencing mechanism (`self_fence`):**

```bash
self_fence() {
  log "FENCING: cannot reach API ($consecutive_failures failures). Assuming lost leadership."
  become_standby
}
```

If the pod loses connectivity to the Kubernetes API server 3 times in a row, it demotes itself to standby — even if it currently holds the lease. This is the safe choice: it is better to have zero active leaders temporarily than to have two active leaders permanently. This is the "fail-safe" design principle.

**The graceful shutdown (`cleanup` + `trap`):**

```bash
cleanup() {
  if [ "$current_role" = "active" ]; then
    clear_lease    # Set holderIdentity to null
  fi
  become_standby
  exit 0
}
trap cleanup SIGTERM SIGINT EXIT
```

When a pod is gracefully terminated (SIGTERM), the sidecar clears the lease before dying. This tells the other pod immediately that leadership is available, instead of waiting for the 15-second expiry. This makes planned maintenance (rolling updates, manual restarts) much faster than crash scenarios.

---

### `helm/jenkins-ha/files/scripts/jenkins-guard.sh` — The Split-Brain Preventer

The guard script runs as the main process of the Jenkins container. It wraps Jenkins startup entirely:

```bash
loop every 2 seconds:
  Read /var/run/jenkins-ha/role

  IF role == "active" AND Jenkins not running:
    → Start Jenkins in background
    → Record Jenkins PID

  IF role == "active" AND Jenkins running:
    → Check if Jenkins process is still alive
    → If dead: restart it

  IF role == "standby" AND Jenkins running:
    → Send SIGTERM to Jenkins
    → Wait up to 30 seconds for graceful shutdown
    → If still running: SIGKILL
```

**Why this is critical for correctness:** The guard is the physical enforcement of the mutual exclusion guarantee. Even if somehow two pods both had `jenkins-role=active` (which the Lease prevents, but as a defense-in-depth), the guard would start Jenkins on both. But because only one pod can hold the Lease (which is enforced by Kubernetes etcd's atomic patch semantics), and the guard reads its decision from the role file which the sidecar writes based on the Lease, the invariant holds.

The guard also handles the case where Jenkins crashes for an unrelated reason (out of memory, plugin bug): it detects the dead PID and restarts Jenkins automatically without involving the leader election at all.

---

### `helm/jenkins-ha/files/scripts/readiness.sh` and `liveness.sh` — Probe Logic

These are queried by Kubernetes periodically. The intervals are configured in
`values.yaml` under `jenkins.readinessProbe` and `jenkins.livenessProbe`
(defaults: readiness every 5s, liveness every 10s).

**`readiness.sh`** — controls Service endpoint membership:
- If role ≠ `active`: exit 1 (not ready) → Pod stays out of the Service endpoints
- If role = `active`: check `http://localhost:8080/login` → exit 0 only if Jenkins responds

This is what keeps the standby pod out of the Service's endpoint list. Even though the standby pod exists and is "running," it is never considered ready, so the Service never sends it traffic.

**`liveness.sh`** — controls container restart:
- If role ≠ `active`: exit 0 (alive) → Kubernetes does not restart the standby
- If role = `active`: check `http://localhost:8080/login`

**Chain of thought:** The distinction between liveness and readiness matters. Liveness failing causes Kubernetes to *kill and restart* the container. Readiness failing simply removes it from *traffic routing*. A standby pod must always pass liveness (it's doing its job — just not serving traffic). A standby pod must always fail readiness (it should never receive traffic). Getting these wrong would cause Kubernetes to constantly restart standby pods, which would disrupt leader election.

---

### `demo-failover.sh` — The Live Demo Script

This script orchestrates the demonstration in 6 steps:

1. **Pre-flight** — confirms the StatefulSet exists
2. **Show current state** — displays pods, Lease, and Service endpoints
3. **Write marker file** — writes a unique file to the shared PVC
4. **Crash the active pod** — `kubectl delete pod <active> --force --grace-period=0`
5. **Watch failover** — polls every 2 seconds, detects when the Lease holder changes
6. **Verify persistence** — reads the marker file from the new leader

**The failover detection logic:**

```bash
if [ -n "$HOLDER" ] && [ "$HOLDER" != "$ORIGINAL_HOLDER" ] && [ -n "$NEW_ACTIVE" ]; then
    FAILOVER_DETECTED=true
```

It captures `ORIGINAL_HOLDER` (the full `pod-name/uid` identity) before the kill, then waits until `HOLDER` is different AND some pod has the `active` label. This correctly distinguishes between the old pod and a new pod that happens to have the same name but a different UID.

---

## 5. The Failover Sequence — Step by Step with Chain of Thought

This section traces what happens at every layer of the system when the active pod dies. This is the most important thing to be able to explain verbally.

### T = 0s — Pod dies

```bash
kubectl delete pod jenkins-0 --force --grace-period=0
```

`--force --grace-period=0` means Kubernetes immediately removes the pod from its internal state without waiting for a graceful shutdown. The processes inside the pod are killed with SIGKILL (no SIGTERM, no cleanup time). The sidecar's `trap cleanup` does NOT fire.

> **Chain of thought:** This simulates the worst possible failure — a kernel panic, power loss, or OOM kill. The pod vanishes without any opportunity to clear the lease or notify the other pod. This is the hardest case. Any HA system that only handles graceful shutdowns is not truly HA.

### T = 0s to 15s — The Lease sits stale

The Lease still has `holderIdentity: jenkins-0/<old-uid>` and the `renewTime` from the last renewal (which happened up to 5 seconds before death). `jenkins-1`'s sidecar is polling every 2 seconds. On every poll, it reads the Lease, calculates `age = now - renewTime`, and checks `age > 15`. Until 15 seconds have passed since the last renewal, the lease is considered valid and `jenkins-1` waits.

Meanwhile, the StatefulSet controller notices `jenkins-0` is missing and recreates it. The new `jenkins-0` starts, its sidecar runs. The sidecar reads the Lease: `holderIdentity = jenkins-0/<old-uid>`. Its own identity is `jenkins-0/<new-uid>`. They do not match → the new pod does NOT renew the lease → the lease continues going stale.

> **Chain of thought:** Without the UID in the identity, the new pod would see its own name in the lease and renew it — effectively "stealing" leadership without having been elected. The standby would never get to take over. The UID makes each pod instance unique even if names repeat. This is the same principle as using UUIDs instead of names in distributed systems — identity must be globally unique, not just locally unique.

### T ≈ 15-17s — Lease expires, election begins

`jenkins-1`'s sidecar calculates `age > 15`. It logs: `Lease expired. Attempting acquisition...` and calls `try_acquire()`:

```bash
kubectl patch lease jenkins-leader --type=merge \
  -p '{"spec":{"holderIdentity":"jenkins-1/<uid>","renewTime":"<now>","acquireTime":"<now>"}}'
```

The new `jenkins-0` may simultaneously attempt the same patch. Kubernetes applies these patches to etcd serially using its internal serialization. One patch lands first. The other pod then does `verify_holder` (re-reads the lease) and sees a different identity won — it backs off to standby.

### T ≈ 15-17s — Role file written, pod labeled

The winner of the election calls `become_active()`:

```bash
write_role() {
  echo "active" > /var/run/jenkins-ha/role
}
label_pod() {
  kubectl label pod jenkins-1 -n jenkins jenkins-role=active --overwrite
}
```

### T ≈ 15-17s — Service endpoints update

The Kubernetes endpoint controller is watching pod labels continuously. Within 1-2 seconds of the `jenkins-role=active` label being applied to `jenkins-1`, it adds `jenkins-1`'s IP to the `jenkins` Service's endpoint list and removes any old entries. Traffic now routes to `jenkins-1`.

### T ≈ 17-19s — Jenkins starts on the new leader

`jenkins-1`'s guard script polls the role file every 2 seconds. It sees `role=active`. It calls `start_jenkins()`, which runs `/usr/local/bin/jenkins.sh` in the background. Jenkins reads `/var/jenkins_home` from the shared PVC — the same data the old leader was using — and starts up.

### T ≈ 25-35s — Old pod rejoins as standby

The recreated `jenkins-0` starts, its sidecar runs. It reads the Lease: `holderIdentity = jenkins-1/<uid>`. Age is small (just acquired). The lease is valid. `jenkins-0` calls `become_standby()`, labels itself `standby`, and begins polling every 2 seconds. The cluster is fully healthy again.

**Total failover time from pod death to new leader serving traffic: approximately 17–20 seconds.**

---

## 6. How to Start the Demo (Step by Step)

### Prerequisites (one-time install, skip if already done)

```bash
# Docker Desktop must be running first
docker version

# Install kubectl and kind if not present
brew install kubectl kind

# Verify
kubectl version --client
kind --version
```

### Every-time startup sequence

```bash
# Step 1: Create the local Kubernetes cluster (skip if already exists)
kind get clusters                       # if "jenkins-ha" appears, skip the next line
kind create cluster --name jenkins-ha

# Step 2: Create the shared storage PV (single-node hostPath workaround for kind).
#         In a real cluster, an NFS / EFS / Filestore CSI driver provides RWX,
#         and you would skip this step entirely.
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: jenkins-ha-pv
spec:
  capacity:
    storage: 20Gi
  accessModes:
    - ReadWriteMany
  hostPath:
    path: /tmp/jenkins-ha-home
    type: DirectoryOrCreate
  claimRef:
    namespace: jenkins
    name: jenkins-ha-home
EOF

# Step 3: Install the Helm chart. The 'jenkins' namespace is created on demand.
cd ~/Documents/Project__CP/jenkins-ha-k8s
make install

# Step 4: Wait for pods to stabilize (about 60-90 seconds on first run)
make status
# You want to see: one pod 2/2 active, one pod 1/2 standby

# Step 5: Run the failover demo
make failover-test
```

### What "ready to demo" looks like

```
NAME        READY   STATUS    JENKINS-ROLE
jenkins-0   2/2     Running   active
jenkins-1   1/2     Running   standby
```

- `2/2` on the active pod means both Jenkins and the sidecar are running
- `1/2` on the standby pod is correct — only the sidecar is running, Jenkins intentionally is not

### Optional: Access Jenkins UI during the demo

```bash
make port-forward
# Open http://localhost:8080 in browser
# Press Ctrl+C when done
```

Note: `make port-forward` tunnels to a specific pod chosen at startup — if
that pod dies during a failover, the tunnel dies too. For live browser
demos, use `make ui-port-forward` instead (Section 6b) — it loops and
auto-reconnects to the current leader.

---

## 6a. How to Run the Helm Upgrade Demo (Criterion 4)

`make failover-test` proves criteria 1–3 (single active, ≤30s failover,
stable storage). The 4th criterion — **successful Helm upgrades** — has
its own dedicated demo: `make upgrade-test`.

### Prerequisites

Same as Section 6. You need a running cluster with both pods healthy
(`one active, one standby`). If you just finished `make failover-test`,
give the cluster ~30 seconds to stabilize before running this.

### Startup sequence

```bash
cd ~/Documents/Project__CP/jenkins-ha-k8s

# Step 1: Confirm the cluster is healthy and both pods are ready
make status
# Look for: one pod 2/2 active, one pod 1/2 standby

# Step 2: Run the Helm upgrade demo
make upgrade-test
```

### What the script does (6 steps, ~2–3 minutes)

1. **Pre-upgrade state capture** — records the current Helm revision, the
   current `jenkins.resources.limits.memory` on both pods (default `1Gi`),
   and identifies the active pod.
2. **Writes a marker file** to `/var/jenkins_home/HA_UPGRADE_MARKER.txt`
   on the active pod. This is the persistence probe — we will read it
   back after the rolling restart to prove the PVC survived.
3. **Runs `helm upgrade`** with `--reuse-values --set jenkins.resources.limits.memory=1536Mi`.
   Helm diffs the rendered manifests, patches the StatefulSet spec, and
   creates a new release revision.
4. **Watches the rolling update.** Because `updateStrategy: RollingUpdate`
   is default on StatefulSets, pods restart in reverse ordinal order:
   `jenkins-1` first, then `jenkins-0`. Helm's `--wait` flag blocks until
   both pods are Ready. One pod is always up, so the Lease holder keeps
   serving traffic across the entire upgrade.
5. **Verifies the new value applied** on both `jenkins-0` and `jenkins-1`
   by reading the pod spec's container resources.
6. **Verifies the marker file survived** on the current leader. Then runs
   `helm rollback` to restore the previous revision, reverses the rolling
   restart, and confirms the memory limit is back at `1Gi` and the marker
   is still intact (two rollouts, data still there).

### What "ready to demo" looks like

Immediately before running it, `helm history` should show a clean release:

```bash
helm history jenkins-ha -n jenkins
# REVISION  STATUS      CHART              DESCRIPTION
# 1         deployed    jenkins-ha-1.0.0   Install complete
```

### What the audience will see

```
STEP 3 of 6 — 📦 Running helm upgrade
Release "jenkins-ha" has been upgraded. Happy Helming!
  ✓ helm upgrade completed in 45s
  ✓ Helm revision: 1 → 2

STEP 4 of 6 — 🔍 Verify New Value Applied
  jenkins-0:  1Gi  →  1536Mi      ✓
  jenkins-1:  1Gi  →  1536Mi      ✓

STEP 5 of 6 — 💾 Marker File Survived?
  ✅ MARKER FILE SURVIVED THE UPGRADE!

STEP 6 of 6 — ⏪ helm rollback
  ✓ helm rollback completed in 40s
  jenkins-0:  1536Mi  →  1Gi      ✓
  jenkins-1:  1536Mi  →  1Gi      ✓
  ✓ Marker file STILL present after rollback
```

### What to say during the demo

> "We just changed a value in the Helm chart — bumping the Jenkins
> container memory limit from 1 GiB to 1.5 GiB. Watch `helm upgrade`
> diff the chart against the last release and patch only what changed.
>
> The StatefulSet controller takes it from there — rolling pods in
> reverse ordinal order. Notice jenkins-1 restarts first, waits until
> Ready, then jenkins-0. At every moment one pod is up, so the Lease
> holder keeps serving traffic.
>
> After both pods have rolled through, the new memory limit is in
> effect on both. And the marker file we wrote before the upgrade is
> still there — because the PVC is decoupled from pod lifecycle.
>
> Then `helm rollback` — one command, same rolling mechanism in reverse.
> This is how you ship to production and sleep at night."

---

## 6b. How to Run the Browser UI Demo

`make failover-test` is fully automated in the terminal. For a live
presentation, seeing the Jenkins UI go dark and come back up on a new
pod is more visceral. That's what `make ui-demo` is for — it's an
interactive guide that pauses at each step so you can narrate.

### Prerequisites

Same as Section 6, plus two terminals open side-by-side (one for the
port-forward, one for the guided script).

### Startup sequence (3 terminals recommended)

```bash
cd ~/Documents/Project__CP/jenkins-ha-k8s

# ── TERMINAL 1 ───────────────────────────────────────────────────────
# Auto-reconnecting port-forward. Unlike `make port-forward`, this one
# survives pod restarts — when the pod serving the UI dies, the inner
# kubectl command exits, the outer while-loop retries, and it picks up
# the new leader once the Service endpoint updates.
make ui-port-forward
# Leave this running for the entire demo.

# ── BROWSER ──────────────────────────────────────────────────────────
# Open http://localhost:8080
# Sign in with your admin account. The Jenkins dashboard should load.

# ── TERMINAL 2 ───────────────────────────────────────────────────────
# The guided demo. It pauses at each step with browser instructions.
make ui-demo
```

### What the script does (5 steps, fully interactive)

1. **Show the healthy cluster** — prints the current pod state, active
   leader, hot standby. You point at the browser: "Jenkins is running."
2. **Create a job in the browser** — the script tells you exactly what
   to click. A freestyle job `ha-demo-job` with a 20-second shell step
   (10 × `sleep 2`) so the Console Output has live output you can watch.
3. **Crash the active pod** — press Enter, the script force-deletes the
   current leader with `--grace-period=0 --force`. You switch to the
   browser and point out the page going dark / showing connection refused.
4. **Wait for the new leader** — the script polls the Lease every 2s.
   Audience watches the Lease holder change from `jenkins-0/<old-uid>`
   to `jenkins-1/<new-uid>` in real time, then waits for the new pod's
   readiness probe to go green. Total downtime: ~20–25s.
5. **Refresh the browser** — the script tells you when. The UI comes
   back, the `ha-demo-job` is still there, the previous build history
   is intact. Click Build Now again to prove the new leader accepts work.

### What "ready to demo" looks like

Terminal 1 shows:

```
Forwarding from 127.0.0.1:8080 -> 8080
Forwarding from [::1]:8080 -> 8080
```

Browser shows the Jenkins dashboard, signed in.

Terminal 2 shows the first step's pod state + the banner:
```
→ Press ENTER when you're ready to continue...
```

### What the audience will see at the critical moment

When you press Enter at step 3, Terminal 2 shows:

```
>>> CRASHING jenkins-0 NOW <<<
  ✓ Pod deleted. Lease renewals have stopped.

  [+2s]  Lease: jenkins-0   ⏳ Old holder still listed — waiting for lease expiry
  [+4s]  Lease: jenkins-0   ⏳ Old holder still listed — waiting for lease expiry
  [+8s]  Lease: jenkins-0   ⏳ Old holder still listed — waiting for lease expiry
  [+14s] Lease: jenkins-0   ⏳ Old holder still listed — waiting for lease expiry
  [+16s] Lease: jenkins-1   🏆 NEW holder: jenkins-1

  🎉 New leader elected in 16s: jenkins-1
```

Meanwhile in the browser (on that same timeline):
- +0s: page stops responding, Console Output freezes mid-build
- +16s: Lease flips (script says "refresh now")
- ~+22s: Jenkins readiness probe passes, port-forward reconnects
- Hit refresh → dashboard loads, job is still there, history intact

### What to say during the demo

> "I'm about to force-delete the pod serving this page. No graceful
> shutdown, no SIGTERM handler doing a clean release — this is the
> pod crashing. Watch the browser.
>
> [crash]
>
> Connection refused. The pod that was rendering this page is gone.
> In the terminal you can see the Lease object still names the dead
> pod as holder — its replacement has started but can't reclaim the
> Lease because the UID is different.
>
> [wait ~15s]
>
> There — the Lease just expired. jenkins-1 noticed, patched its
> identity in, labeled itself active. The Service selector shifted.
> Now jenkins-1's guard script sees role=active and starts Jenkins.
>
> [~10s more]
>
> Refresh the browser. Same URL, same session — but a different pod.
> Our job is still there. Its config, its build history, its console
> output — all on the shared PVC, completely unaffected by the pod
> crash. This is HA with zero data loss."

### Cleanup note

When the demo ends, you can either:
- Leave `make ui-port-forward` running — it stays connected for Q&A and
  will auto-reconnect if anything else changes.
- Press Ctrl+C in Terminal 1 to stop it. The cluster continues running;
  only the local tunnel is closed.

---

## 7. How to Stop / Clean Up After the Demo

```bash
cd ~/Documents/Project__CP/jenkins-ha-k8s

# Option A: Remove the Helm release but keep PVC + Lease.
#          (Fastest to restart — just run `make install` again. Jenkins data survives.)
make uninstall

# Option B: Full wipe — release, PVC, Lease, namespace.
make teardown-all

# Option C: Delete the entire Kubernetes cluster (clean slate).
kind delete cluster --name jenkins-ha
```

**Recommendation for a presentation:** Use Option C after the demo. It completely frees all resources and leaves Docker clean. Before the next presentation, run the full startup sequence again.

**Do a full dry run the night before.** The first run pulls Docker images (~500MB for Jenkins). Subsequent runs use the cached images and pods start in about 30 seconds instead of 90.

---

## 8. What the Demo Output Means

### The Lease line
```
Holder: jenkins-0   Renew: 2026-04-15T10:00:05.000000Z
```
This is the raw Lease object. The holder field names the current leader's pod identity. The renew time updates every 5 seconds while the leader is alive. If the renew time stops updating, the lease will expire in 15 seconds.

### The pod table
```
NAME        READY   STATUS    RESTARTS   AGE   JENKINS-ROLE
jenkins-0   2/2     Running   0          5m    active
jenkins-1   1/2     Running   0          4m    standby
```
- `2/2` = both containers healthy (Jenkins + sidecar)
- `1/2` = only sidecar healthy (Jenkins not running — correct for standby)
- `JENKINS-ROLE` = the dynamic label the sidecar writes

### The service endpoints
```
NAME      ENDPOINTS
jenkins   10.244.0.5:8080,10.244.0.5:50000
```
One IP address means one pod is receiving traffic. During failover, this line briefly shows no endpoints, then updates to the new pod's IP.

### The failover timing
The timer starts at pod deletion and ends when a new pod has the `active` label. Expected range: **15–20 seconds**. This is honest: 15 seconds for the lease to expire plus 2 seconds for detection plus 1–2 seconds for labeling and endpoint update.

---

## 8a. Helm Packaging and Private Registry

The chart at `helm/jenkins-ha/` is the single source of truth for every Kubernetes
object the system deploys. There is no separate set of "raw" manifests — `helm template`
is what produces the YAML that `kubectl` applies.

### Why Helm matters here
The prospectus lists Helm both as a required technology and as a success
criterion ("Successful Helm upgrades"). The chart turns the deployment into a
versioned, repeatable artefact: one command installs, one command upgrades, one
command rolls back.

```bash
make install                       # first-time install
make install SC=nfs-client         # pin RWX StorageClass
make upgrade                       # apply any values change
make uninstall                     # remove release (PVC + Lease retained)
make template                      # render to stdout (debug)
make lint                          # lint the chart
```

`upgrade --install` is idempotent, so `make install` is safe to re-run.

### What is parameterised in `values.yaml`
- `replicaCount`, image repo/tag/pullPolicy for jenkins / sidecar / init
- `persistence.size`, `accessModes`, `storageClassName`, `keepOnUninstall`
- `leaderElection.leaseDurationSeconds`, `renewIntervalSeconds`, `retryIntervalSeconds`
- Resource requests/limits for both containers, probe timings
- Pod anti-affinity weight and topology key
- `imagePullSecret` (see below)

A SHA256 of the rendered ConfigMap is annotated on the pod template, so
`make upgrade` after a script edit triggers a rolling restart automatically.

### Private registry — two modes
The chart supports both the "let Helm create the Secret" and the "reference an
existing Secret" workflows. The `imagePullSecrets:` block on the StatefulSet is
only emitted when `imagePullSecret.enabled=true`.

**Mode A — chart generates the Secret:**
```bash
make install \
  IPS_REGISTRY=registry.hpe.example.com \
  IPS_USER=ciuser \
  IPS_PASS="$REGISTRY_TOKEN" \
  IPS_EMAIL=ci@hpe.example.com
```
This renders a `kubernetes.io/dockerconfigjson` Secret named `jenkins-registry-creds`. Missing creds fail the chart at render time with a clear error — no half-broken deploys.

**Mode B — reference an existing Secret managed elsewhere (e.g. ExternalSecrets, sealed-secrets):**
```bash
kubectl -n jenkins create secret docker-registry my-creds \
  --docker-server=registry.hpe.example.com \
  --docker-username=ciuser --docker-password="$TOKEN"
make install IPS_EXISTING=my-creds
```

This satisfies three prospectus items in one shot: the **Private Registry** technology, the **Secure image access** business requirement, and the **Private registry authentication** technical constraint.

### What `make uninstall` does NOT delete
The PVC and the Lease both carry `helm.sh/resource-policy: keep`, so Jenkins data survives a release deletion. Use `make teardown-all` if you want a true wipe.

---

## 9. Hard Questions Engineers Will Ask — With Full Answers

---

### Q1: What prevents two pods from both thinking they are the leader simultaneously?

**The answer has multiple layers:**

**Layer 1 — The Lease (distributed lock):** Kubernetes etcd uses a compare-and-swap operation for patches. When two pods race to acquire the lease, only one patch can land first. The second pod's patch is applied after the first, overwriting it — but then the first pod's `verify_holder` check catches this and demotes it. There is a brief window where two pods may have written to the lease, but only one will emerge as the holder after verification.

**Layer 2 — The role file:** Even if the Lease somehow had a race, each pod's guard script reads its own local role file. Each pod's sidecar writes independently to its own role file. The role file is per-pod (in an `emptyDir` volume), not shared.

**Layer 3 — The Service selector:** Traffic only flows to pods labeled `jenkins-role=active`. If somehow two pods were both labeled active (which requires two separate label patches to succeed), traffic would split — but Jenkins data would not corrupt because both would be reading/writing the shared PVC. In practice, the Lease prevents this from happening.

**Layer 4 — Readiness probe:** The standby pod always fails its readiness probe (it reads the role file and returns non-ready if not active). Kubernetes never routes traffic to a pod that fails readiness, regardless of labels.

The combination of these four layers provides defense in depth against split-brain.

---

### Q2: What happens if the sidecar crashes but Jenkins is still running?

The guard script checks Jenkins' PID every 2 seconds. If the sidecar crashes:
- It does not renew the Lease
- After 15 seconds, the Lease expires
- The other pod claims leadership
- The other pod starts Jenkins
- The guard on the original pod eventually sees its role file says `standby` (either the sidecar left it that way via the SIGTERM trap, or the role file retains its last value)
- If Jenkins is still running on the original pod, the guard will send it SIGTERM when the role file changes to `standby`

This means a sidecar crash is handled the same way as a pod crash — the other side takes over via lease expiry. The role file acting as the communication channel between the sidecar and the guard provides a degree of independence between the two components.

---

### Q3: What is the actual RTO (Recovery Time Objective)?

Approximately **15–20 seconds** in a crash scenario. Broken down:

| Phase | Duration |
|-------|----------|
| Lease last renewed before crash | 0–5s ago |
| Lease expiry detection | Up to 15s |
| Acquisition + verification | ~1s |
| Label update + Service endpoint propagation | ~2s |
| Jenkins startup (already running on standby? No — guard starts it) | ~2s to signal, then Jenkins itself takes ~30–60s to be fully operational |

**Important distinction:** Traffic routing to the new pod changes in 15–20 seconds. Jenkins being fully warmed up and serving requests takes another 30–60 seconds (JVM startup, plugin loading). If this is a concern, a pre-warming approach (keeping the standby Jenkins process warm) would reduce RTTR (Recovery Time To Ready) — but this implementation chooses not to do that to prevent any risk of dual writes.

---

### Q4: In a real multi-node cluster, is this approach safe across node failures?

Yes, and this is where the UID-based identity becomes even more important. In a multi-node cluster:

- `jenkins-0` runs on Node A
- Node A experiences a hardware failure
- Kubernetes marks `jenkins-0` as `Unknown`
- The StatefulSet controller waits for the node eviction timeout (default 5 minutes) before rescheduling `jenkins-0` on a different node
- Meanwhile, the Lease expires after 15 seconds
- `jenkins-1` takes over naturally

The long node eviction timeout is intentional — Kubernetes does not want to reschedule pods if the node might come back. For HA use cases, this timeout can be reduced with `--pod-eviction-timeout` on the controller-manager. The Lease-based approach is independent of this: regardless of when the pod gets rescheduled, the Lease expires on its own clock and the standby takes over.

Without the UID in the identity: if the node came back and `jenkins-0` restarted, it would see its own name in the Lease and renew — causing split-brain with `jenkins-1` which had already taken over. With the UID: the revived pod has a new UID, sees a foreign identity in the Lease, and becomes standby. No split-brain.

---

### Q5: What if the Kubernetes API server is unreachable? Can this cause split-brain?

This is the most dangerous failure scenario and it is handled explicitly.

**Scenario A — Active pod loses API access:**
- Active pod cannot renew the Lease → after `MAX_API_FAILURES` (3) consecutive failures, it calls `self_fence()` → demotes itself to standby
- Jenkins is stopped (guard sees role=standby)
- Lease expires on the Kubernetes side (since no renewals came in)
- Standby pod takes over when it can reach the API

**Scenario B — Network partition (active pod can reach app clients but not API server):**
- Active pod: loses API, self-fences, stops Jenkins
- This causes brief downtime but prevents split-brain
- When the partition heals, the former active pod rejoins as standby

**Scenario C — Standby pod loses API access:**
- It cannot detect the Lease expiry
- It cannot acquire the Lease even if the active fails
- The system has reduced redundancy but no split-brain risk

The design choice here is **consistency over availability** in the face of API server failure. This is the correct choice for Jenkins because split-brain (two instances writing to the same config simultaneously) causes data corruption that is much worse than brief downtime.

---

### Q6: Why use pod labels for Service routing instead of directly patching the Service?

Patching the Service's selector or endpoint list directly would also work, but pod labeling is architecturally cleaner:

1. **Single source of truth** — the label on the pod is the ground truth of its role. The Service, monitoring tools, `kubectl get pods`, and the guard script all read from this single source.

2. **Kubernetes reconciliation** — if anything patches the Service incorrectly (a bug, a misconfiguration), Kubernetes will reconcile it back. If the label is wrong, the Service routing is wrong — a clear, auditable error.

3. **RBAC minimality** — the sidecar needs `pods/patch` permission (which it needs anyway) but does not need `services/patch` permission. Fewer permissions = smaller attack surface.

4. **Observability** — `kubectl get pods -L jenkins-role` immediately shows the HA state of the cluster. You do not need to inspect Service selectors or endpoints separately.

---

### Q7: Why not use Kubernetes' built-in leader election library instead of a shell script?

The `client-go` leader election library (used in most Kubernetes controllers) implements the same Lease-based algorithm. Using it would produce identical behavior. The shell script approach was chosen here for three reasons:

1. **Transparency** — every line of the election logic is readable without knowing Go. HPE engineers can audit it without compiling anything.

2. **No custom Docker images** — the sidecar uses `bitnami/kubectl:latest` which is a standard, maintained image. A Go-based elector would require building and maintaining a custom container image.

3. **Portability** — the script runs in any container that has `bash`, `kubectl`, and `date`. It is not tied to any specific programming language ecosystem.

The trade-off is that the shell script is more verbose and has less built-in error handling than a library. For a production system at scale, migrating to a compiled controller would be appropriate.

---

### Q8: What happens to ongoing Jenkins builds when failover occurs?

In this implementation: **running builds are lost.** When the active pod is killed with `--force --grace-period=0`, Jenkins is killed mid-execution. Any builds in progress are terminated.

This is an accepted limitation of the active-passive model. Mitigations in production:

1. **Graceful shutdown** — when possible (planned maintenance), use a graceful restart instead of force-kill. The SIGTERM trap in the sidecar clears the Lease, which triggers failover immediately on `jenkins-1`. `jenkins-0` gets its full `terminationGracePeriodSeconds` (60 seconds in `07-statefulset.yaml` line 11) to finish running builds before dying.

2. **Build re-queuing** — Jenkins has a built-in "retry failed builds" option and can be configured to re-queue builds that were aborted due to a controller restart.

3. **Distributed builds** — for critical pipelines, running builds on Jenkins agents (not the controller) means the build process itself survives. The Jenkins controller is only the coordinator; the actual build work runs on agent pods that are independent of the controller's lifecycle.

---

### Q9: How does the RWX PVC prevent data corruption if both pods have it mounted?

The PVC is mounted on both pods at all times. The operating system's filesystem (in this case, the hostPath or NFS backing store) allows both pods to read and write simultaneously. However, Jenkins maintains file locks on its own critical files (e.g., `$JENKINS_HOME/.jenkins.lock`). If a second Jenkins instance were started with the same home directory, it would either fail to start (lock conflict) or start in an inconsistent state.

The guard script prevents this from happening at the application level: Jenkins only starts if the role file says `active`, and only one pod can have role `active` at a time (enforced by the Lease). So while the filesystem allows concurrent access, the application-level guard ensures only one Jenkins process is ever writing.

For production, using an NFS server with advisory locking (NFSv4) or a distributed filesystem with strong consistency guarantees (CephFS) would add an additional layer of protection at the storage level.

---

### Q10: Why is the lease duration 15 seconds? What happens if you change it?

The 15-second duration is a deliberate trade-off point on the **stability vs. recovery speed** curve:

| Parameter | Value | Reasoning |
|-----------|-------|-----------|
| `LEASE_DURATION` | 15s | Max time before standby detects failure |
| `RENEW_INTERVAL` | 5s | How often the active pod renews |
| `RETRY_INTERVAL` | 2s | How often the standby polls |
| Safety margin | 3x | Duration / Renew = 15 / 5 = 3 renewals before expiry |

**If you set LEASE_DURATION too low (e.g., 5s):**
- A brief network hiccup causing one missed renewal could trigger a false failover
- Two pods might both try to claim leadership during transient conditions
- In a heavily loaded cluster where API calls take longer than expected, the renew might not complete in time

**If you set LEASE_DURATION too high (e.g., 60s):**
- A real failure takes up to 60 seconds to detect
- This may violate SLAs requiring faster recovery
- The system appears "stuck" for a long time when the active pod dies

15 seconds with a 5-second renewal gives a 3x safety margin — consistent with what the Kubernetes core controllers use for their own leader election (10-15 seconds is the standard range).

---

### Q11: The demo says failover completes in 15-20 seconds. How can you be more precise?

The exact time depends on where in the 5-second renewal cycle the pod dies:

- **Best case:** Pod dies immediately after a renewal. Lease has just been refreshed. Must wait the full 15 seconds. Total ≈ 15s + 2s detection + 1s acquire = 18s.
- **Worst case:** Pod dies 4.9 seconds after a renewal. Lease expires in 10.1 seconds. Total ≈ 10s + 2s + 1s = 13s.
- **Average case:** 15s / 2 = 7.5s remaining + 3s overhead = ~17-18s.

So the realistic range is **13–20 seconds**, with an average of approximately **17 seconds**. This is comfortably under the 30-second target.

---

### Q12: How would this design change for a production HPE environment vs. this local kind cluster?

| Aspect | Demo (kind) | Production (HPE) |
|--------|------------|-----------------|
| Storage | hostPath on single node | NFS / CephFS / HPE Primera |
| Cluster nodes | 1 | 3+ (separate nodes for each Jenkins pod) |
| Pod scheduling | No affinity (single node) | Hard anti-affinity (pods on different nodes) |
| Node failure handling | StatefulSet recreates immediately | Node eviction timeout (configurable) |
| Monitoring | `make logs` | Prometheus + Grafana, Lease age alerts |
| Image registry | Docker Hub | HPE internal registry |
| RBAC | Namespace-scoped Role | Review for production hardening |
| TLS / Ingress | None (port-forward) | Ingress controller with TLS termination |
| Jenkins agents | None | Kubernetes plugin for dynamic agents |

The core architecture — Lease-based election, sidecar + guard pattern, RWX storage — is production-ready as-is. The differences are mostly infrastructure concerns that depend on HPE's specific environment.

---

*End of HPE Presentation Guide.*
