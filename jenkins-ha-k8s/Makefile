# Makefile — Jenkins HA on Kubernetes
# Usage:
#   make deploy                     # Deploy with default StorageClass
#   make deploy SC=nfs-client       # Deploy with a specific StorageClass
#   make status                     # Show current state
#   make failover-test              # Run the failover demo
#   make logs                       # Tail sidecar logs
#   make port-forward               # Open Jenkins UI on localhost:8080
#   make teardown                   # Remove everything (keep PVC)
#   make teardown-all               # Remove everything including PVC

NS       := jenkins
SC       ?=

.PHONY: deploy status failover-test logs port-forward teardown teardown-all \
        watch-pods watch-lease

# ── Deploy ────────────────────────────────────────────────────────────────────
deploy:
	@chmod +x deploy.sh demo-failover.sh teardown.sh
	@if [ -n "$(SC)" ]; then \
		./deploy.sh "$(SC)"; \
	else \
		./deploy.sh; \
	fi

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

# ── Teardown ──────────────────────────────────────────────────────────────────
teardown:
	@chmod +x teardown.sh
	@./teardown.sh

teardown-all:
	@chmod +x teardown.sh
	@./teardown.sh --delete-pvc
