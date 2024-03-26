PACKAGE_NAME = image-builder

.PHONY: help
help:
	@echo "make [TARGETS...]"
	@echo
	@echo "This is the maintenance makefile of image-builder. The following"
	@echo "targets are available:"
	@echo
	@echo "    help:               Print this usage information."
	@echo "    build:              Build the project from source code"
	@echo "    run:                Run the project on localhost"
	@echo "    unit-tests:         Run unit tests (calls dev-prerequisites)"
	@echo "    dev-prerequisites:  Install necessary development prerequisites on your system"
	@echo "    push-check:         Replicates the github workflow checks as close as possible"
	@echo "                        (do this before pushing!)"

.PHONY: build
build:
	go build -o image-builder ./cmd/image-builder/
	go build -o gen-oscap ./cmd/oscap
	go build -o image-builder-migrate-db-tern ./cmd/image-builder-migrate-db-tern/
	go test -c -tags=integration -o image-builder-db-test ./cmd/image-builder-db-test/

.PHONY: run
run:
	go run ./cmd/image-builder/

# pip3 install openapi-spec-validator
.PHONY: check-api-spec
check-api-spec:
	 openapi-spec-validator internal/v1/api.yaml

.PHONY: ubi-container
ubi-container:
	podman build -t osbuild/image-builder -f distribution/Dockerfile-ubi .

.PHONY: generate-openscap-blueprints
generate-openscap-blueprints:
	go run ./cmd/oscap/ ./distributions

.PHONY: dev-prerequisites
dev-prerequisites:
	go install github.com/jackc/tern@latest

.PHONY: unit-tests
# re-implementing .github/workflows/tests.yml as close as possible
unit-tests: dev-prerequisites
	go test -v -race -covermode=atomic -coverprofile=coverage.txt -coverpkg=./... ./...

.PHONY: generate
generate:
	go generate ./...

.PHONY: push-check
push-check: generate build unit-tests
	./tools/prepare-source.sh
	@if [ 0 -ne $$(git status --porcelain --untracked-files|wc -l) ]; then \
	    echo "There should be no changed or untracked files"; \
	    git status --porcelain --untracked-files; \
	    exit 1; \
	fi
	@echo "All looks good - congratulations"

CONTAINER_EXECUTABLE ?= podman
DOCKER_IMAGE := image-builder_devel
DOCKERFILE := distribution/Dockerfile-ubi_srcinstall

SRC_DEPS_NAMES := community-gateway osbuild-composer
SRC_DEPS_ORIGIN := $(addprefix ../,$(SRC_DEPS_NAMES))

$(SRC_DEPS_ORIGIN):
	@for DIR in $@; do if ! [ -d $$DIR ]; then echo "Please checkout $$DIR so it is available at $$(pwd)/$$DIR"; exit 1; fi; done
	touch $@

#SRC_DEPS_LOCAL_DIR := vendor/github.com/osbuild
#SRC_DEPS_OUTSIDE := $(addprefix $(SRC_DEPS_LOCAL_DIR)/,$(SRC_DEPS_NAMES))

#$(SRC_DEPS_OUTSIDE): $(SRC_DEPS_ORIGIN) $(shell find $(SRC_DEPS_ORIGIN) -name *.go)
#	mkdir -p $(SRC_DEPS_LOCAL_DIR)
#	cp -r $(SRC_DEPS_ORIGIN) $(SRC_DEPS_LOCAL_DIR)/
#	touch $@


GOPROXY ?= https://proxy.golang.org,direct

go.mod_changed.info: go.mod $(SRC_DEPS_ORIGIN)
	go mod edit -replace github.com/osbuild/osbuild-composer=../osbuild-composer
	go mod edit -replace github.com/osbuild/community-gateway=../community-gateway
	env GOPROXY=$(GOPROXY) go mod tidy
	env GOPROXY=$(GOPROXY) go mod vendor

	# workaround when golang version of ubi9 is still 1.20 (and not 1.21 or above)
	# "tidy" from a newer version on the host would lead to
	# "unknown directive: toolchain"
	# so we just remove the keyword for now
	gawk -i inplace '!/toolchain.*/' go.mod

	touch $@

container_built.info: go.mod_changed.info $(shell find $(SRC_DEPS_ORIGIN) -name *.go) $(DOCKERFILE)
	$(CONTAINER_EXECUTABLE) build -t $(DOCKER_IMAGE) -f $(DOCKERFILE) .
	echo "Container last built on" > $@
	date >> $@

.PHONY: container
container: container_built.info

.PHONY: clean
clean:
	rm -f container_built.info
	rm -f go.mod_changed.info
