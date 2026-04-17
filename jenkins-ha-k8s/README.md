# Jenkins HA on Kubernetes — Demo-Ready Deployment

Active-passive Jenkins deployment on Kubernetes with automated failover using Lease-based leader election.

## What this proves

| # | Success Criterion | How it's verified |
|---|---|---|
| 1 | **Only one active Jenkins instance** | The Service selector `jenkins-role=active` ensures traffic only reaches the leader. The sidecar enforces single-holder via a Kubernetes Lease. |
| 2 | **Failover within 30 seconds** | `make failover-test` (which runs `demo-failover.sh`) kills the active pod and times how long until the standby takes over. |
| 3 | **Stable storage** | A marker file written on the active pod is read back from the new leader after failover, proving the RWX PVC survived. |

## Architecture (one-minute version)

```
              ┌────────────────────────┐
              │   Service (ClusterIP)  │
              │ selector: role=active  │
              └───────────┬────────────┘
                          │
          ┌───────────────┴───────────────┐
          ▼                               ▼
   ┌─────────────┐                ┌─────────────┐
   │  jenkins-0  │                │  jenkins-1  │
   │  (active)   │                │  (standby)  │
   │             │                │             │
   │ [jenkins]   │                │ [jenkins]   │  ← guard blocks start
   │ [sidecar]   │◄── Lease ────►│ [sidecar]   │
   └──────┬──────┘                └──────┬──────┘
          │        Shared RWX PVC        │
          └──────────► /jenkins_home ◄───┘
```

- **StatefulSet** with 2 replicas provides stable pod identities.
- **Sidecar container** runs a leader-election loop against a Kubernetes Lease.
- **Guard script** wraps the Jenkins entrypoint — only starts Jenkins when the pod is the leader.
- **Label-based routing** — the Service selects `jenkins-role=active`, so traffic automatically follows the leader.
- **Self-fencing** — if a pod loses API connectivity, it assumes it lost leadership and shuts Jenkins down.

---

## Prerequisites

1. **Kubernetes cluster** (≥ 1.27) — kind, minikube, EKS, GKE, AKS, or bare-metal all work.
2. **kubectl** configured against the cluster.
3. **A ReadWriteMany (RWX) StorageClass** — required so both pods can mount the same PVC.

### RWX StorageClass options by environment

| Environment | StorageClass | Setup |
|---|---|---|
| **AWS EKS** | `efs-sc` | Install the EFS CSI driver + create an EFS filesystem |
| **GKE** | `standard-rwx` | Enable Filestore CSI driver |
| **Azure AKS** | `azurefile` | Built-in |
| **Bare metal / on-prem** | `nfs-client` | Deploy an NFS server + NFS subdir provisioner |
| **kind (local dev)** | See below | NFS provisioner in-cluster |
| **minikube** | See below | NFS provisioner or hostPath hack |

### Local dev: kind + NFS provisioner (quickstart)

```bash
# 1. Create a kind cluster (if not already)
kind create cluster --name jenkins-ha

# 2. Install the NFS subdir external provisioner (uses a simple in-cluster NFS)
#    Option A: Use the nfs-subdir-external-provisioner Helm chart
helm repo add nfs-subdir https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm install nfs-provisioner nfs-subdir/nfs-subdir-external-provisioner \
  --set nfs.server=<YOUR_NFS_SERVER_IP> \
  --set nfs.path=/exported/path \
  --set storageClass.name=nfs-client \
  --set storageClass.reclaimPolicy=Retain

#    Option B: For a truly local setup, use a hostPath-based workaround
#    (see the "Local Dev Without NFS" section below)
```

### Local dev without NFS (hostPath workaround for demos)

If you don't have NFS available, you can patch the PVC to use a hostPath PV. This only works on single-node clusters (kind, minikube, Docker Desktop):

```bash
# Create a PV that maps to a hostPath (single-node only!)
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
```

Then run `make install` — the chart's PVC will bind to this PV.

---

## Quick start

The deployment is packaged as a Helm chart (`helm/jenkins-ha/`). The Makefile
wraps the common Helm invocations.

```bash
# Install the chart into namespace `jenkins` (created on the fly)
make install

# Pin an RWX StorageClass at install time
make install SC=nfs-client

# Pull images from a private registry
make install \
  IPS_REGISTRY=registry.hpe.example.com \
  IPS_USER=ciuser \
  IPS_PASS="$REGISTRY_TOKEN"

# Roll out any subsequent values change
make upgrade

# Remove the release (PVC + Lease retained via helm.sh/resource-policy: keep)
make uninstall

# Full wipe (PVC + Lease + namespace)
make teardown-all
```

Other useful Helm commands:

```bash
make template          # Render chart to stdout (debug)
make lint              # Lint the chart
```

Once installed, check status and open the UI:

```bash
make status
make port-forward      # browse http://localhost:8080
```

## Running the demos

There are three demos, each mapping to prospectus success criteria:

```bash
# Criteria 1–3: single active, failover ≤30s, stable storage
make failover-test

# Criterion 4: successful Helm upgrades (+ rollback)
make upgrade-test

# Browser-based guided walkthrough (runs Steps 1–5 interactively,
# you crash the pod and watch the UI come back on the new leader)
make ui-demo           # run in terminal 2
make ui-port-forward   # run in terminal 1 (auto-reconnects on pod restart)
```

### `make failover-test`

Fully automated terminal demo. The script:
1. Shows the current state (one active, one standby)
2. Writes a marker file to the shared storage
3. Force-deletes the active pod (`--grace-period=0 --force`)
4. Watches the Lease expire naturally (~15s), then the standby acquire it
5. Verifies the new leader reads the marker file (storage survived)
6. Prints a pass/fail scorecard (target: ≤30s total)

### `make upgrade-test`

Runs `helm upgrade` with a changed `jenkins.resources.limits.memory`
value, watches the StatefulSet roll both pods, verifies the new limit
on each pod, confirms the marker file survived, then runs `helm rollback`
to restore the previous revision.

### `make ui-demo` + `make ui-port-forward`

For live presentations. Open http://localhost:8080 in a browser while
`ui-port-forward` runs (it auto-reconnects when the pod backing the
Service endpoint changes). The `ui-demo` script pauses at each step
with narration prompts so you can show the job dashboard going dark
after the crash and reappearing on the new leader.

### What to say during the demo

> "Here we see two Jenkins pods — jenkins-0 is active and serving traffic, jenkins-1 is on standby. The Service only routes to the active pod. Let me kill the active one..."
>
> "Watch the standby pod — its sidecar detects the lease has expired and claims leadership. It relabels itself as active, and the Service endpoints update automatically."
>
> "The marker file we wrote before the failure is still there on the new leader — the shared persistent volume survived the failover. Zero data loss."

---

## Useful commands

```bash
make status            # Pod states, lease, endpoints, PVC
make logs              # Sidecar logs (both pods)
make logs-jenkins      # Jenkins application logs (active pod)
make watch-pods        # Live pod status (refreshes every 2s)
make watch-lease       # Live lease state
make port-forward      # Access Jenkins UI on localhost:8080 (single shot)
make ui-port-forward   # Same, but auto-reconnects on pod restart (for demos)
make uninstall         # Remove the Helm release (keep PVC + Lease)
make teardown-all      # Full wipe — release, PVC, Lease, namespace
```

## File structure

```
jenkins-ha-k8s/
├── helm/jenkins-ha/               # Helm chart — single source of truth
│   ├── Chart.yaml
│   ├── values.yaml                # All tunables (images, storage, lease, registry)
│   ├── .helmignore
│   ├── files/scripts/             # Shell scripts bundled into the chart
│   │   ├── leader-elector.sh      # Lease-based leader election loop
│   │   ├── jenkins-guard.sh       # Wraps Jenkins entrypoint; respects role file
│   │   ├── readiness.sh           # "active + Jenkins responding" → ready
│   │   └── liveness.sh            # "active + Jenkins responding" → alive
│   └── templates/
│       ├── _helpers.tpl           # Label / name / pull-secret helpers
│       ├── NOTES.txt              # Post-install help text
│       ├── serviceaccount.yaml
│       ├── role.yaml
│       ├── rolebinding.yaml
│       ├── pvc.yaml               # RWX PVC (helm.sh/resource-policy: keep)
│       ├── lease.yaml             # Bootstrap Lease (helm.sh/resource-policy: keep)
│       ├── configmap-scripts.yaml # Built from files/scripts/*.sh via .Files.Glob
│       ├── services.yaml          # ClusterIP + headless
│       ├── statefulset.yaml       # 2-replica StatefulSet (Jenkins + sidecar)
│       └── registry-secret.yaml   # dockerconfigjson, gated by imagePullSecret.enabled
├── demo-failover.sh               # Failover demo — criteria 1–3 (automated)
├── helm-upgrade-demo.sh           # Helm upgrade + rollback demo — criterion 4
├── ui-demo.sh                     # Guided browser walkthrough (interactive)
├── Makefile                       # install / upgrade / uninstall / status / *-test
├── README.md                      # This file
└── HPE_PRESENTATION.md            # Detailed architecture write-up
```

The chart's `files/scripts/` directory is the single source of truth for the shell
scripts. The ConfigMap template reads them with `.Files.Glob`, so editing a
script and running `make upgrade` triggers a rolling restart automatically (a
SHA256 of the rendered ConfigMap is annotated on the pod template).

## How it works (detailed)

### Leader election flow

1. Both sidecar containers run `leader-elector.sh` in an infinite loop.
2. Each iteration reads the Kubernetes Lease `jenkins-leader`.
3. If the lease is unheld or expired (no renewal within 15s), the sidecar attempts to claim it.
4. After claiming, it re-reads the lease to verify it won (closes the race window).
5. The winner writes `"active"` to a shared file and labels its pod `jenkins-role=active`.
6. The loser stays as `"standby"`.
7. The winner renews the lease every 5 seconds.

### Guard script

- Wraps the Jenkins entrypoint.
- Polls the role file every 2 seconds.
- Only starts Jenkins when role = `active`.
- If role flips to `standby`, SIGTERMs Jenkins immediately (prevents split-brain writes to `$JENKINS_HOME`).

### Self-fencing

If the sidecar cannot reach the Kubernetes API for 3 consecutive attempts, it assumes it's partitioned and steps down. This prevents a scenario where both pods think they're the leader because neither can see the lease.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Both pods `standby` | Lease has no holder or RBAC broken | `kubectl -n jenkins get lease jenkins-leader -o yaml`; check sidecar logs |
| Pod stuck `ContainerCreating` | PVC not bound | Check StorageClass supports RWX; `kubectl describe pvc` |
| Jenkins takes >30s to respond after failover | Normal — Jenkins startup time | Reduce plugin count or increase resources |
| `ImagePullBackOff` | Image not accessible | Check network; for private registries, create an imagePullSecret |

---

*Built for the HPE CPP Project — Jenkins HA on Kubernetes.*
