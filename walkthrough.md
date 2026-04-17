# Jenkins HA on Kubernetes — Complete Beginner's Guide

> [!IMPORTANT]
> **You already have all the code files.** They are in `/Users/harshraj/Documents/Project__CP/jenkins-ha-k8s/`. You do NOT need to write any code. This guide explains what everything does and how to run it.

---

## 🎯 What Is This Project?

**In one sentence:** You're deploying Jenkins (a CI/CD tool) on Kubernetes such that if one instance crashes, another automatically takes over — with zero data loss.

### Why does HPE care?
- Jenkins is used for building/testing/deploying code (CI/CD)
- If Jenkins goes down, no one can deploy code — that's bad for business
- This project makes Jenkins **highly available (HA)** — meaning it keeps running even when things break

### The 3 things you need to prove in your demo:
1. ✅ **Only ONE Jenkins pod is ever active** (no "split-brain" — two pods both thinking they're the leader)
2. ✅ **Failover happens within 30 seconds** (when the active one dies, the standby takes over fast)
3. ✅ **Data survives the failover** (Jenkins home directory isn't lost)

---

## 🏗️ Architecture — How It Works (Plain English)

```
                   ┌──────────────────────┐
                   │   Kubernetes Service │  ← The "front door" — only talks to active pod
                   │  (selector: active)  │
                   └──────────┬───────────┘
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
       ┌─────────────┐                ┌─────────────┐
       │  jenkins-0   │                │  jenkins-1   │
       │  (ACTIVE ✅)  │                │  (STANDBY ⏸) │
       │              │                │              │
       │ [Jenkins App]│                │ [Jenkins App]│  ← Only starts when "active"
       │ [Sidecar Bot]│◄── Lease ────► │ [Sidecar Bot]│  ← Competes for the Lease
       └──────┬───────┘                └──────┬───────┘
              │        Shared Disk (PVC)       │
              └────────── /jenkins_home ◄──────┘      ← Both pods see the same files
```

### The key concepts:

| Concept | What it is | Analogy |
|---------|-----------|---------|
| **StatefulSet** | A Kubernetes way to run 2 identical pods with stable names (`jenkins-0`, `jenkins-1`) | Like having 2 identical servers named Server-A and Server-B |
| **Lease** | A Kubernetes object that acts as a "lock" — only one pod can hold it | Like a talking stick — whoever holds it is the leader |
| **Sidecar** | A helper container inside each pod that runs the leader election logic | Like a bodyguard that checks "Am I the leader?" every few seconds |
| **Guard Script** | Wraps Jenkins startup — only lets Jenkins run if the pod is the leader | Like a bouncer — "You're not the leader? Jenkins stays off." |
| **PVC (RWX)** | A shared disk that BOTH pods can read/write to | Like a shared Google Drive folder — both can access it |
| **Service** | Routes traffic only to the pod labeled `active` | Like a reception desk — "Let me connect you to the active server" |

### What happens during failover:
1. `jenkins-0` is the **active** leader, running Jenkins
2. `jenkins-0` **crashes** (or gets deleted)
3. `jenkins-0`'s sidecar was renewing the Lease every 5 seconds. Now it stopped.
4. `jenkins-1`'s sidecar notices the Lease expired (after ~15 seconds of no renewal)
5. `jenkins-1`'s sidecar **claims the Lease** and labels itself `active`
6. The Service automatically shifts traffic to `jenkins-1`
7. `jenkins-1`'s guard script sees role=`active` and **starts Jenkins**
8. Meanwhile, Kubernetes recreates `jenkins-0`, but it comes back as **standby**
9. The marker file on the shared disk is untouched — **data survived!**

---

## 📁 Every File Explained

Your project lives at: `~/Documents/Project__CP/jenkins-ha-k8s/`

```
jenkins-ha-k8s/
├── manifests/                          ← Kubernetes YAML files (applied in order)
│   ├── 00-namespace.yaml              ← Creates the "jenkins" namespace
│   ├── 01-serviceaccount.yaml         ← Identity for the pods to talk to K8s API
│   ├── 02-role.yaml                   ← Permissions: can read/write Leases, label pods
│   ├── 03-rolebinding.yaml            ← Links the ServiceAccount to the Role
│   ├── 04-pvc.yaml                    ← 20Gi shared storage (ReadWriteMany)
│   ├── 05-lease.yaml                  ← The "lock" object for leader election
│   ├── 06-configmap-scripts.yaml      ← All 4 shell scripts packaged for K8s
│   ├── 07-statefulset.yaml            ← The heart — defines 2 Jenkins pods + sidecars
│   └── 08-services.yaml               ← Two services: main (routes to active) + headless
├── scripts/                            ← Same scripts as in ConfigMap (for reference)
│   ├── leader-elector.sh              ← Sidecar logic: compete for Lease, label pod
│   ├── jenkins-guard.sh               ← Main container: start/stop Jenkins based on role
│   ├── readiness.sh                   ← "Is this pod ready to receive traffic?"
│   └── liveness.sh                    ← "Is this pod still alive?"
├── deploy.sh                          ← One command to deploy everything
├── demo-failover.sh                   ← The demo: kills active, times failover
├── teardown.sh                        ← Removes everything
├── Makefile                           ← Shortcuts: make deploy, make status, etc.
└── README.md                          ← Project documentation
```

### What each manifest does:

| File | What It Creates | Why It Exists |
|------|----------------|--------------|
| `00-namespace.yaml` | Namespace `jenkins` | Isolates all resources in their own area |
| `01-serviceaccount.yaml` | ServiceAccount `jenkins-ha-sa` | Gives pods an identity to call K8s API |
| `02-role.yaml` | Role `jenkins-ha-role` | Grants permission to: manage Leases, label pods, create events |
| `03-rolebinding.yaml` | RoleBinding | Connects the ServiceAccount to the Role |
| `04-pvc.yaml` | PVC `jenkins-ha-home` (20Gi, RWX) | Shared disk for `/var/jenkins_home` — both pods mount this |
| `05-lease.yaml` | Lease `jenkins-leader` | The "lock" — only one pod can hold it at a time |
| `06-configmap-scripts.yaml` | ConfigMap with 4 scripts | Injects the shell scripts into containers |
| `07-statefulset.yaml` | StatefulSet `jenkins` (2 replicas) | Creates two pods, each with Jenkins container + sidecar |
| `08-services.yaml` | Service `jenkins` + `jenkins-headless` | Routes traffic to active pod only |

### What each script does:

| Script | Runs In | Purpose |
|--------|---------|---------|
| `leader-elector.sh` | Sidecar container | Infinite loop: check Lease → claim if free → renew if holder → label pod accordingly |
| `jenkins-guard.sh` | Jenkins container | Watches role file → starts Jenkins if `active`, stops it if `standby` |
| `readiness.sh` | Jenkins container (probe) | Reports "ready" only if role=`active` AND Jenkins HTTP responds |
| `liveness.sh` | Jenkins container (probe) | Always passes for standby; checks HTTP for active |

---

## 🛠️ Prerequisites — What You Need Installed

### 1. Docker Desktop
You need Docker to run containers. Download from: https://www.docker.com/products/docker-desktop/

```bash
# Verify Docker is installed and running:
docker version
```

### 2. kubectl (Kubernetes CLI)
```bash
# Install on Mac:
brew install kubectl

# Verify:
kubectl version --client
```

### 3. kind (Kubernetes IN Docker)
This creates a local Kubernetes cluster inside Docker containers.
```bash
# Install on Mac:
brew install kind

# Verify:
kind --version
```

### 4. make (should already be on your Mac)
```bash
# Verify:
make --version
```

> [!TIP]
> If `brew` is not installed, install Homebrew first:
> ```bash
> /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
> ```

---

## 🚀 Step-by-Step: Running the Demo

### Step 1: Start Docker Desktop
Open the Docker Desktop app and wait for it to say "Docker is running".

### Step 2: Create a Kubernetes cluster
```bash
kind create cluster --name jenkins-ha
```
This takes ~1 minute. You'll see:
```
Creating cluster "jenkins-ha" ...
 ✓ Ensuring node image ...
 ✓ Preparing nodes ...
 ✓ Writing configuration ...
 ✓ Starting control-plane ...
 ✓ Installing CNI ...
 ✓ Installing StorageClass ...
Set kubectl context to "kind-jenkins-ha"
```

Verify it works:
```bash
kubectl cluster-info
kubectl get nodes
```

### Step 3: Create the namespace and hostPath PV (storage workaround for kind)

Since `kind` is a single-node cluster, it doesn't have real shared storage (NFS). We fake it with a hostPath:

```bash
# Create the namespace first
kubectl create namespace jenkins

# Create a PersistentVolume that maps to a directory on the node
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

You should see:
```
namespace/jenkins created
persistentvolume/jenkins-ha-pv created
```

### Step 4: Deploy Jenkins HA

```bash
cd ~/Documents/Project__CP/jenkins-ha-k8s
make deploy
```

> [!NOTE]
> This will take **60–90 seconds** to pull Docker images and start pods.

Watch the output — it will show pods starting up and eventually say which one became active.

### Step 5: Check status

```bash
make status
```

You should see something like:
```
=== Pods ===
NAME        READY   STATUS    RESTARTS   AGE   JENKINS-ROLE
jenkins-0   2/2     Running   0          2m    active
jenkins-1   2/2     Running   0          90s   standby

=== Lease ===
    holderIdentity: jenkins-0
    renewTime: "2026-04-14T14:15:30.000000Z"

=== Service Endpoints ===
NAME      ENDPOINTS
jenkins   10.244.0.5:8080,10.244.0.5:50000

=== PVC ===
NAME              STATUS   VOLUME          CAPACITY   ACCESS MODES
jenkins-ha-home   Bound    jenkins-ha-pv   20Gi       RWX
```

### Step 6: Run the failover demo

```bash
make failover-test
```

This is the **star of the show**. It:
1. Shows current state (one active, one standby) ✅
2. Writes a marker file to shared storage ✅
3. Kills the active pod 💀
4. Times the failover (should be ≤30s) ⏱️
5. Reads the marker file from the new leader ✅
6. Prints PASS/FAIL results 📊

### Step 7: Access Jenkins UI (optional but impressive)

```bash
make port-forward
```
Then open http://localhost:8080 in your browser. You'll see the Jenkins dashboard.

Press `Ctrl+C` to stop port-forwarding.

### Step 8: Clean up (after your demo)

```bash
# Remove everything but keep the storage:
make teardown

# Or remove absolutely everything:
make teardown-all

# Delete the kind cluster when completely done:
kind delete cluster --name jenkins-ha
```

---

## 🎤 What to Say During the Demo

### Opening (30 seconds)
> "I've deployed Jenkins in a high-availability configuration on Kubernetes. The architecture uses an active-passive model with two pods — one running Jenkins, the other on standby."

### Showing the current state
> "Let me show you the current state. We have two pods — jenkins-0 is the active leader and jenkins-1 is on standby. The Kubernetes Service only routes traffic to the active pod, using a label selector. The sidecar container in each pod handles leader election using a Kubernetes Lease object."

### Before killing the pod
> "I'm writing a marker file to the shared persistent volume — this will help us prove that data survives the failover."

### Killing the active pod
> "Now I'm deleting the active pod to simulate a failure. Watch what happens..."

### During failover
> "The standby pod's sidecar detected that the lease expired — no one renewed it. It claimed the lease, relabeled itself as active, and started Jenkins. The Kubernetes Service endpoints automatically updated."

### After failover
> "The failover completed in [X] seconds — well within our 30-second target. The marker file we wrote before the failure is still there on the new leader. This proves data survived — zero data loss. Meanwhile, Kubernetes is already recreating the deleted pod as a new standby."

### Closing
> "This demonstrates continuous Jenkins availability with automatic failover, secure shared storage, and reliable CI/CD execution — all the requirements for the project."

---

## 🔧 Troubleshooting

| Problem | What to do |
|---------|-----------|
| `docker: command not found` | Install Docker Desktop and start it |
| `kind: command not found` | `brew install kind` |
| `kubectl: command not found` | `brew install kubectl` |
| Pods stuck at `ContainerCreating` | PVC not bound. Run `kubectl describe pvc -n jenkins` |
| Pods stuck at `ImagePullBackOff` | Image pull failed. Check internet connection. Run `kubectl describe pod jenkins-0 -n jenkins` |
| Both pods say `standby` | RBAC issue or Lease problem. Run `make logs` to see sidecar output |
| Failover takes > 30s | Normal on slow machines. Jenkins startup time adds delay |
| `make deploy` gives `sed` errors on Mac | The `sed -i` command differs on macOS. See the fix below |

### Mac `sed` fix
If `deploy.sh` fails with a `sed` error when passing a StorageClass, the default Mac `sed` needs `''` after `-i`. But since we're using the hostPath workaround (no StorageClass needed), this shouldn't affect you. Just run `make deploy` without a StorageClass argument.

---

## 📚 Key Kubernetes Concepts (Quick Reference)

| Term | What it means |
|------|--------------|
| **Pod** | The smallest unit in K8s — a running container (or group of containers) |
| **StatefulSet** | Like a Deployment, but gives each pod a stable name (jenkins-0, jenkins-1) |
| **Namespace** | A folder-like isolation for resources |
| **Service** | A stable network endpoint that routes to matching pods |
| **PVC** | PersistentVolumeClaim — a request for disk storage |
| **PV** | PersistentVolume — the actual storage backing a PVC |
| **RWX** | ReadWriteMany — storage mode where multiple pods can read AND write |
| **Lease** | A K8s object for distributed locking / leader election |
| **ConfigMap** | Injects config data (here: shell scripts) into pods |
| **RBAC** | Role-Based Access Control — permissions for pods to call K8s API |
| **Sidecar** | An extra container in a pod that handles supporting tasks |
| **Affinity** | Rules about where pods should be scheduled (prefer different nodes) |

---

## 🔍 Useful Commands for Debugging

```bash
# See everything in the jenkins namespace:
kubectl -n jenkins get all

# Detailed pod info (shows events, errors):
kubectl -n jenkins describe pod jenkins-0

# Sidecar logs (leader election):
kubectl -n jenkins logs jenkins-0 -c leader-elector
kubectl -n jenkins logs jenkins-1 -c leader-elector

# Jenkins app logs:
kubectl -n jenkins logs jenkins-0 -c jenkins

# PVC status:
kubectl -n jenkins describe pvc jenkins-ha-home

# Lease status:
kubectl -n jenkins get lease jenkins-leader -o yaml

# Watch pods live (updates every 2s):
make watch-pods

# Watch lease live:
make watch-lease
```

---

## ✅ Pre-Demo Checklist

- [ ] Docker Desktop is running
- [ ] `kubectl version --client` works
- [ ] `kind --version` works
- [ ] `kind create cluster --name jenkins-ha` completed successfully
- [ ] Namespace and PV created (Step 3 above)
- [ ] `make deploy` completed with one pod showing `active`
- [ ] `make status` shows one `active` and one `standby` pod
- [ ] `make port-forward` opens Jenkins UI at http://localhost:8080
- [ ] `make failover-test` runs and shows PASS for all 3 criteria

> [!CAUTION]
> **Do a dry run the night before your demo!** Run through all steps once to pull the Docker images (they're large, ~500MB). On demo day, images will already be cached and pods will start much faster.
