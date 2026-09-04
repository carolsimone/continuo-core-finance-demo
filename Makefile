# Local release helpers for continuo-core-finance-demo.
#
# Prereqs (see README): Continuo running on a local cluster, and
#   kubectl -n continuo port-forward svc/release-controller 8088:8088
# so the controller is reachable at $(RELEASE_API_URL).
#
# Usage:
#   make release SERVICE=continuo-core    TAG=v1    # build + load + POST to local Continuo
#   make release SERVICE=continuo-finance TAG=v1
#   make release SERVICE=continuo-core    TAG=v2 LOADER=k3s   # if your cluster is k3s, not kind

RELEASE_API_URL ?= http://localhost:8088
REPO            ?= carolsimone/continuo-core-finance-demo
CLUSTER         ?= continuo        # kind cluster name (used when LOADER=kind)
LOADER          ?= kind            # kind | k3s
TAG             ?= v1

.PHONY: build load release
build:
	@test -n "$(SERVICE)" || { echo "set SERVICE=continuo-core|continuo-finance"; exit 1; }
	docker build -t $(SERVICE):$(TAG) services/$(SERVICE)

load:
	@test -n "$(SERVICE)" || { echo "set SERVICE=continuo-core|continuo-finance"; exit 1; }
ifeq ($(LOADER),k3s)
	docker save $(SERVICE):$(TAG) | sudo k3s ctr images import -
else
	kind load docker-image $(SERVICE):$(TAG) --name $(CLUSTER)
endif

# build + load the image, then POST a release to the local release-controller.
# RELEASE_ID is unique per invocation so re-releases don't collide.
release: build load
	RELEASE_API_URL=$(RELEASE_API_URL) \
	RELEASE_ID=rel-$(SERVICE)-$(TAG)-$$(date +%s) \
	SERVICE=$(SERVICE) IMAGE_TAG=$(TAG) \
	REPO=$(REPO) COMMIT_SHA=$$(git rev-parse HEAD) \
	  bash scripts/release.sh
