# Current Operator version
VERSION ?= $(shell cat VERSION)

# Default bundle image tag
BUNDLE_IMG ?= quay.io/clastix/capsule:$(VERSION)-bundle
# Options for 'bundle-build'
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# Image URL to use all building/pushing image targets
IMG ?= quay.io/clastix/capsule:$(VERSION)
# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:trivialVersions=true,preserveUnknownFields=false"

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Get information about git current status
GIT_HEAD_COMMIT ?= $$(git rev-parse --short HEAD)
GIT_TAG_COMMIT  ?= $$(git rev-parse --short $(VERSION))
GIT_MODIFIED_1  ?= $$(git diff $(GIT_HEAD_COMMIT) $(GIT_TAG_COMMIT) --quiet && echo "" || echo ".dev")
GIT_MODIFIED_2  ?= $$(git diff --quiet && echo "" || echo ".dirty")
GIT_MODIFIED    ?= $$(echo "$(GIT_MODIFIED_1)$(GIT_MODIFIED_2)")
GIT_REPO        ?= $$(git config --get remote.origin.url)
BUILD_DATE      ?= $$(date '+%Y-%m-%dT%H:%M:%S')

all: manager

# Run tests
test: generate fmt vet manifests
	go test ./... -coverprofile cover.out

# Build manager binary
manager: generate fmt vet
	go build -o bin/manager main.go

# Run against the configured Kubernetes cluster in ~/.kube/config
run: generate fmt vet manifests
	go run ./main.go

# Install CRDs into a cluster
install: manifests kustomize
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

# Uninstall CRDs from a cluster
uninstall: manifests kustomize
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
deploy: manifests kustomize
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

# Remove controller in the configured Kubernetes cluster in ~/.kube/config
remove: manifests kustomize
	$(KUSTOMIZE) build config/default | kubectl delete -f -
	kubectl delete clusterroles.rbac.authorization.k8s.io capsule-namespace-deleter capsule-namespace-provisioner --ignore-not-found
	kubectl delete clusterrolebindings.rbac.authorization.k8s.io capsule-namespace-provisioner --ignore-not-found

# Generate manifests e.g. CRD, RBAC etc.
manifests: controller-gen
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases

# Run go fmt against code
fmt:
	go fmt ./...

# Run go vet against code
vet:
	go vet ./...

# Generate code
generate: controller-gen
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

# Build the docker image
docker-build: test
	docker build . -t ${IMG} --build-arg GIT_HEAD_COMMIT=$(GIT_HEAD_COMMIT) \
 							 --build-arg GIT_TAG_COMMIT=$(GIT_TAG_COMMIT) \
 							 --build-arg GIT_MODIFIED=$(GIT_MODIFIED) \
 							 --build-arg GIT_REPO=$(GIT_REPO) \
 							 --build-arg GIT_LAST_TAG=$(VERSION) \
 							 --build-arg BUILD_DATE=$(BUILD_DATE)

# Push the docker image
docker-push:
	docker push ${IMG}

# find or download controller-gen
# download controller-gen if necessary
controller-gen:
ifeq (, $(shell which controller-gen))
	@{ \
	set -e ;\
	CONTROLLER_GEN_TMP_DIR=$$(mktemp -d) ;\
	cd $$CONTROLLER_GEN_TMP_DIR ;\
	go mod init tmp ;\
	go get sigs.k8s.io/controller-tools/cmd/controller-gen@v0.3.0 ;\
	rm -rf $$CONTROLLER_GEN_TMP_DIR ;\
	}
CONTROLLER_GEN=$(GOBIN)/controller-gen
else
CONTROLLER_GEN=$(shell which controller-gen)
endif

kustomize:
ifeq (, $(shell which kustomize))
	@{ \
	set -e ;\
	KUSTOMIZE_GEN_TMP_DIR=$$(mktemp -d) ;\
	cd $$KUSTOMIZE_GEN_TMP_DIR ;\
	go mod init tmp ;\
	go get sigs.k8s.io/kustomize/kustomize/v3@v3.5.4 ;\
	rm -rf $$KUSTOMIZE_GEN_TMP_DIR ;\
	}
KUSTOMIZE=$(GOBIN)/kustomize
else
KUSTOMIZE=$(shell which kustomize)
endif

# Generate bundle manifests and metadata, then validate generated files.
bundle: manifests
	operator-sdk generate kustomize manifests -q
	kustomize build config/manifests | operator-sdk generate bundle -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	operator-sdk bundle validate ./bundle

# Build the bundle image.
bundle-build:
	docker build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

# Sorting imports
.PHONY: goimports
goimports:
	goimports -w -l -local "github.com/clastix/capsule" .

# Linting code as PR is expecting
.PHONY: golint
golint:
	golangci-lint run -c .golangci.yml

# Running e2e tests in a KinD instance
.PHONY: e2e
e2e/%:
	kind create cluster --name capsule --image=kindest/node:$*
	make docker-build
	kind load docker-image --nodes capsule-control-plane --name capsule $(IMG)
	helm upgrade \
		--debug \
		--install \
		--namespace capsule-system \
		--create-namespace capsule \
		--set 'manager.image.pullPolicy=Never' \
		--set 'manager.resources=null'\
		--set "manager.image.tag=$(VERSION)" \
		--set 'manager.livenessProbe.failureThreshold=10' \
		--set 'manager.readinessProbe.failureThreshold=10' \
		./charts/capsule
	ginkgo -v -tags e2e ./e2e
	kind delete cluster --name capsule

# Stratio CICD flow
change-version:
	@echo $(VERSION) > VERSION