# Local release helpers for continuo-core-finance-demo.
#
# Prereqs (see README): Continuo running on a local cluster, and
#   kubectl -n continuo port-forward svc/ui 8090:8090
# so continuo's public API is reachable at $(CONTINUO_URL), plus an operator's
# bearer token in the CONTINUO_TOKEN environment variable (continuo's
# deploy/AUTH.md, "Bearer tokens", shows how to get one from Dex).
#
# Usage:
#   make release SERVICE=continuo-core    TAG=v1    # build + load + POST to local Continuo
#   make release SERVICE=continuo-finance TAG=v1
#   make release SERVICE=continuo-core    TAG=v2 LOADER=k3s   # if your cluster is k3s, not kind

CONTINUO_URL    ?= http://localhost:8090
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

# build + load the image, then POST a release to the local continuo.
# RELEASE_ID is unique per invocation so re-releases don't collide.
release: build load
	@test -n "$$CONTINUO_TOKEN" || { echo "set CONTINUO_TOKEN to an operator's bearer token (see README)"; exit 1; }
	CONTINUO_URL=$(CONTINUO_URL) \
	RELEASE_ID=rel-$(SERVICE)-$(TAG)-$$(date +%s) \
	SERVICE=$(SERVICE) IMAGE_TAG=$(TAG) \
	REPO=$(REPO) COMMIT_SHA=$$(git rev-parse HEAD) \
	  bash scripts/release.sh
