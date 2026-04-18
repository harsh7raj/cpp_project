# Makefile — Jenkins HA on Kubernetes
# Helm is the canonical install path. All targets either delegate to Helm
# or read state directly from the cluster.
#
# Usage:
#   make install                    # Deploy (default StorageClass)
#   make install SC=nfs-client      # Deploy with a specific StorageClass
#   make install IPS_REGISTRY=registry.hpe.example.com \
#                IPS_USER=ciuser IPS_PASS=xxxx     # ...and a private registry
#   make upgrade                    # Re-render and apply chart/values changes
#   make uninstall                  # Remove the Helm release (PVC + Lease kept)
#   make teardown-all               # Full wipe — PVC, Lease, namespace
#   make template                   # Render chart to stdout (debug)
#   make lint                       # Lint the chart
#   make status                     # Show current state
#   make failover-test              # Run the failover demo (criteria 1-3)
#   make upgrade-test               # Run the Helm upgrade demo (criterion 4)
#   make ui-demo                    # Guided browser demo (run in 2nd terminal)
#   make ui-port-forward            # Auto-reconnecting port-forward for browser
#   make logs / logs-jenkins        # Tail sidecar / Jenkins logs
#   make port-forward               # Open Jenkins UI on localhost:8080

NS       := jenkins
SC       ?=
RELEASE  := jenkins-ha
CHART    := helm/jenkins-ha

.PHONY: install upgrade uninstall teardown-all template lint \
        status failover-test upgrade-test ui-demo ui-port-forward \
        logs logs-jenkins port-forward \
        watch-pods watch-lease

# ── Helm args (shared by install/upgrade/template) ────────────────────────────
# Pass SC=<class> to pin storageClassName, or leave empty for cluster default.
# Use IPS_* vars to enable private-registry image pulls.
IPS_REGISTRY ?=
IPS_USER     ?=
IPS_PASS     ?=
IPS_EMAIL    ?=
IPS_EXISTING ?=

HELM_ARGS  = --namespace $(NS) --create-namespace
ifneq ($(strip $(SC)),)
HELM_ARGS += --set persistence.storageClassName=$(SC)
endif
ifneq ($(strip $(IPS_EXISTING)),)
HELM_ARGS += --set imagePullSecret.enabled=true --set imagePullSecret.existingSecret=$(IPS_EXISTING)
else ifneq ($(strip $(IPS_REGISTRY)),)
HELM_ARGS += --set imagePullSecret.enabled=true \
             --set imagePullSecret.registry=$(IPS_REGISTRY) \
             --set imagePullSecret.username=$(IPS_USER) \
             --set imagePullSecret.password=$(IPS_PASS)
ifneq ($(strip $(IPS_EMAIL)),)
HELM_ARGS += --set imagePullSecret.email=$(IPS_EMAIL)
endif
endif

# ── Install / upgrade / uninstall ─────────────────────────────────────────────
install:
	helm upgrade --install $(RELEASE) $(CHART) $(HELM_ARGS)

upgrade: install

uninstall:
	helm uninstall $(RELEASE) --namespace $(NS) || true
	@echo ""
	@echo "Note: PVC ('jenkins-ha-home') and Lease ('jenkins-leader') are retained"
	@echo "      via helm.sh/resource-policy: keep, so Jenkins data survives."
	@echo "      Run 'make teardown-all' for a full wipe (PVC + namespace)."

teardown-all:
	helm uninstall $(RELEASE) --namespace $(NS) || true
	kubectl -n $(NS) delete pvc jenkins-ha-home --ignore-not-found=true
	kubectl -n $(NS) delete lease jenkins-leader --ignore-not-found=true
	kubectl delete namespace $(NS) --ignore-not-found=true
	@echo ""
	@echo "✓ Full teardown complete."

template:
	helm template $(RELEASE) $(CHART) $(HELM_ARGS)

lint:
	helm lint $(CHART)

# ── Status ────────────────────────────────────────────────────────────────────
status:
	@echo "=== Pods ==="
	@kubectl -n $(NS) get pods -l app=jenkins -L jenkins-role -o wide 2>/dev/null || echo "No pods found"
	@echo ""
	@echo "=== Lease ==="
	@kubectl -n $(NS) get lease jenkins-leader -o yaml 2>/dev/null | grep -E 'holderIdentity|renewTime' || echo "No lease found"
	@echo ""
	@echo "=== Service Endpoints ==="
	@kubectl -n $(NS) get endpoints jenkins 2>/dev/null || echo "No endpoints found"
	@echo ""
	@echo "=== PVC ==="
	@kubectl -n $(NS) get pvc 2>/dev/null || echo "No PVC found"

# ── Failover Demo ─────────────────────────────────────────────────────────────
failover-test:
	@chmod +x demo-failover.sh
	@./demo-failover.sh

# ── Helm Upgrade Demo (4th success criterion) ─────────────────────────────────
upgrade-test:
	@chmod +x helm-upgrade-demo.sh
	@./helm-upgrade-demo.sh

# ── UI / Browser Demo ─────────────────────────────────────────────────────────
# Endpoint-gated port-forward — only opens the tunnel when the Service has
# a Ready active endpoint. During failover (no active pod exists) we leave
# localhost:8080 with no listener, so the browser gets a clean
# ERR_CONNECTION_REFUSED instead of stale cached content. Once the new
# leader's jenkins container is Ready, the tunnel opens and the browser
# immediately works on refresh — one clean down→up visual transition.
ui-port-forward:
	@echo "Endpoint-gated port-forward → http://localhost:8080"
	@echo "(Press Ctrl+C to stop — stays DOWN until a Ready active pod exists)"
	@echo ""
	@while true; do \
	  ACTIVE=""; READY=""; \
	  while [ "$$READY" != "true" ]; do \
	    ACTIVE=$$(kubectl -n $(NS) get pod -l app=jenkins,jenkins-role=active \
	      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	    if [ -n "$$ACTIVE" ]; then \
	      READY=$$(kubectl -n $(NS) get pod "$$ACTIVE" \
	        -o jsonpath='{.status.containerStatuses[?(@.name=="jenkins")].ready}' 2>/dev/null); \
	    else \
	      READY=""; \
	    fi; \
	    if [ "$$READY" != "true" ]; then \
	      printf "\r  ⏳ Waiting for Ready active pod (active=%-12s ready=%-5s)  " "$${ACTIVE:-<none>}" "$${READY:-<no>}"; \
	      sleep 1; \
	    fi; \
	  done; \
	  echo ""; \
	  echo "  ✓ Leader Ready ($$ACTIVE) — opening tunnel on :8080"; \
	  kubectl -n $(NS) port-forward pod/$$ACTIVE 8080:8080 2>/dev/null || true; \
	  echo ""; \
	  echo "  ⚠ Tunnel to $$ACTIVE dropped — UI is now DOWN until new leader is Ready"; \
	  sleep 1; \
	done

ui-demo:
	@chmod +x ui-demo.sh
	@./ui-demo.sh

# ── Logs ──────────────────────────────────────────────────────────────────────
logs:
	@echo "=== jenkins-0 sidecar ==="
	@kubectl -n $(NS) logs jenkins-0 -c leader-elector --tail=20 2>/dev/null || echo "(not running)"
	@echo ""
	@echo "=== jenkins-1 sidecar ==="
	@kubectl -n $(NS) logs jenkins-1 -c leader-elector --tail=20 2>/dev/null || echo "(not running)"

logs-jenkins:
	@ACTIVE=$$(kubectl -n $(NS) get pod -l app=jenkins,jenkins-role=active -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -n "$$ACTIVE" ]; then \
		echo "=== Jenkins logs on $$ACTIVE ==="; \
		kubectl -n $(NS) logs "$$ACTIVE" -c jenkins --tail=50; \
	else \
		echo "No active pod found"; \
	fi

# ── Watch ─────────────────────────────────────────────────────────────────────
watch-pods:
	watch -n2 'kubectl -n $(NS) get pods -l app=jenkins -L jenkins-role -o wide'

watch-lease:
	watch -n2 'kubectl -n $(NS) get lease jenkins-leader -o jsonpath="Holder: {.spec.holderIdentity}  Renew: {.spec.renewTime}" && echo'

# ── Access ────────────────────────────────────────────────────────────────────
port-forward:
	@echo "Opening Jenkins on http://localhost:8080 ..."
	@echo "(Press Ctrl+C to stop)"
	kubectl -n $(NS) port-forward svc/jenkins 8080:8080
