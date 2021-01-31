SHELL = /bin/bash

MAKEFLAGS += --no-print-directory

# Project
NAME := dnsbench
VERSION ?= $(shell cat VERSION)
COMMIT := $(shell test -d .git && git rev-parse --short HEAD)
BUILD_INFO := $(COMMIT)-$(shell date -u +"%Y%m%d-%H%M%SZ")
HASCMD := $(shell test -d cmd && echo "true")
GOOS ?= $(shell uname | tr '[:upper:]' '[:lower:]')
GOARCH ?= $(shell uname -m | sed 's/x86_64/amd64/; s/i386/386/')
ARCH = $(shell uname -m)
CONTAINER?=docker

ISRELEASED := $(shell git show-ref v$(cat VERSION) 2>&1 > /dev/null && echo "true")

# Utilities
# Default environment variables.
# Any variables already set will override the values in this file(s).
DOTENV := godotenv -f $(HOME)/.env,.env

# Variables
ROOT = $(shell pwd)

# Go
GOMODOPTS = GO111MODULE=on
GOGETOPTS = GO111MODULE=off
GOPATH = $(shell go env GOPATH)
GOFILES := $(shell find cmd pkg internal src -name '*.go' 2> /dev/null)
GODIRS = $(shell find . -maxdepth 1 -mindepth 1 -type d | egrep 'cmd|internal|pkg|api')

.PHONY: _build browsereports cattest clean _deps depsdev _go.mod _go.mod_err help \
        _isreleased lint _package _release _release_gitlab test _test _test_setup _test_setup_dirs \
        _test_setup_gitserver _unit _cc _cx _install tag \
        _dockerbuild _dockerbuild_nscd _dockerbuild_dnsmasq _dockerstart

#
# End user targets
#
help: ## Print Help
	@echo "Usage: make <target>"
	@perl -n -e 'if(/^_?[A-Za-z_]+:.*?##\s*/) { s/^_//; s/:.*?##\s*/ - /; print "  "; print }' Makefile

_build: go.mod ## Build binary docker images
	@test -d .cache || go fmt ./...
ifeq ($(XCOMPILE),true)
	GOOS=linux GOARCH=amd64 $(MAKE) dist/$(NAME)_linux_amd64/$(NAME)
	GOOS=darwin GOARCH=amd64 $(MAKE) dist/$(NAME)_darwin_amd64/$(NAME)
	GOOS=windows GOARCH=amd64 $(MAKE) dist/$(NAME)_windows_amd64/$(NAME).exe
endif
ifeq ($(HASCMD),true)
	@$(MAKE) $(NAME)
endif

_dockerbuild: ## Build container images
	@$(MAKE) _dockerbuild_nscd
	@$(MAKE) _dockerbuild_dnsmasq

_dockerbuild_nscd: dist/$(NAME)_linux_amd64/$(NAME)
	$(CONTAINER) build . -f Dockerfile.nscd -t bench_nscd:$(VERSION)

_dockerbuild_dnsmasq: dist/$(NAME)_linux_amd64/$(NAME)
	$(CONTAINER) build . -f Dockerfile.dnsmasq -t bench_dnsmasq:$(VERSION)

_dockerrun: ## Start containers
	-$(CONTAINER) rm -f bench_nscd
	$(CONTAINER) run --name=bench_nscd --restart=always -d bench_nscd:$(VERSION)
	-$(CONTAINER) rm -f bench_dnsmasq
	$(CONTAINER) run --name=bench_dnsmasq --restart=always -d bench_dnsmasq:$(VERSION)
	@# Workaround override dns
	$(CONTAINER) exec bench_dnsmasq bash -c 'echo "nameserver 127.0.0.1" > /etc/resolv.conf'

_benchdocker: ## Benchmark DNS on docker
	@mkdir -p tmp/bench
	@$(MAKE) dockerbuild 2>&1 > /dev/null
	@$(MAKE) dockerrun 2>&1 > /dev/null
	@cp /dev/null tmp/bench/dnsbench.csv
	$(CONTAINER) exec -it bench_nscd dnsbench -t 1 -i 10 600 -m "$(CONTAINER): software=nscd threads=1" | tee -a tmp/bench/dnsbench-container.csv
	$(CONTAINER) exec -it bench_dnsmasq dnsbench -t 1 -i 10 600 -m "$(CONTAINER): software=dnsmasq threads=1" | tail +2 | tee -a tmp/bench/dnsbench-container.csv
	cp tmp/bench/dnsbench-container.csv tmp/bench/dnsbench-container-$$(date +%Y-%m-%d-%H:%M:%S).csv

_benchlocal: _build ## Benchmark locally
	./dnsbench -t 1 -i 10 600 -m "local: threads=1" | tee tmp/bench/dnsbench-local.csv
	cp tmp/bench/dnsbench-local.csv tmp/bench/dnsbench-local-$$(date +%Y-%m-%d-%H:%M:%S).csv

_install: $(GOPATH)/bin/$(NAME) ## Install to $(GOPATH)/bin

clean: ## Reset project to original state
	rm -rf .cache $(NAME) dist reports tmp vendor

test: ## Test
	$(MAKE) lint
	$(MAKE) unit
	@exit $(cat reports/exitcode.txt)

_unit: test_setup ## Unit testing
	### Unit Tests
	$(GOPATH)/bin/gotestsum --junitfile reports/junit.xml -- -timeout 5s -covermode atomic -coverprofile=./reports/coverage.out -v ./...; echo $? > reports/exitcode.txt

_cc: _unit ## Code coverage
	### Code Coverage
	@go tool cover -func=./reports/coverage.out | tee ./reports/coverage.txt
	@go tool cover -html=reports/coverage.out -o reports/html/coverage.html

_cx: test_setup ## Code complexity test
	### Cyclomatix Complexity Report
	@$(GOPATH)/bin/gocyclo -avg $(GODIRS) | grep -v _test.go | tee reports/cyclocomplexity.txt

_package: ## Create an RPM & DEB
	@XCOMPILE=true make build
	@VERSION=$(VERSION) envsubst < nfpm.yaml.in > nfpm.yaml
	$(MAKE) dist/$(NAME).rb
	$(MAKE) dist/$(NAME)-$(VERSION).$(ARCH).rpm
	$(MAKE) dist/$(NAME)_$(VERSION)_$(GOARCH).deb

_test_setup: ## Setup test directories
	@mkdir -p tmp
	@mkdir -p reports/html
	@sync

_test_setup_dirs:
	@find test/fixtures -maxdepth 1 -type d -exec cp -r {} tmp/ \; 

_release: ## Trigger a release
	@echo "### Releasing v$(VERSION)"
	@$(MAKE) _isreleased 2> /dev/null
	git tag v$(VERSION)
	git push --tags

_release_github: _package ## To be run inside a github workflow
	github-release release \
	  --user dexterp \
	  --repo dnsbench \
	  --tag v$(VERSION)

	github-release upload \
	  --name dnsbench-$(VERSION).tar.gz \
	  --user dexterp \
	  --repo {PROJECT_NAME} \
	  --tag v$(VERSION) \
	  --file dist/dnsbench-$(VERSION).tar.gz

	github-release upload \
	  --name dnsbench.rb \
	  --user dexterp \
	  --repo dnsbench \
	  --tag v$(VERSION) \
	  --file dist/dnsbench.rb

	github-release upload \
	  --name dnsbench-$(VERSION).x86_64.rpm \
	  --user dexterp \
	  --repo dnsbench \
	  --tag v$(VERSION) \
	  --file dist/dnsbench-$(VERSION).x86_64.rpm

	github-release upload \
	  --name dnsbench_$(VERSION)_amd64.deb \
	  --user dexterp \
	  --repo dnsbench \
	  --tag v$(VERSION) \
	  --file dist/dnsbench_$(VERSION)_amd64.deb

lint: internal/version.go ## Lint tests
	golangci-lint run --enable=gocyclo
	golint -set_exit_status ./...

tag:
	git fetch --tags
	git tag v$(VERSION)
	git push --tags

deps: go.mod ## Install build dependencies
	$(GOMODOPTS) go mod tidy
	$(GOMODOPTS) go mod download

depsdev: ## Install development dependencies
ifeq ($(USEGITLAB),true)
	@mkdir -p $(ROOT)/.cache/{go,gomod}
endif
	@GO111MODULE=on $(MAKE) $(GOGETS)

bumpmajor: ## Version - major bump
	git fetch --tags
	versionbump --checktags major VERSION

bumpminor: ## Version - minor bump
	git fetch --tags
	versionbump --checktags minor VERSION

bumppatch: ## Version - patch bump
	git fetch --tags
	versionbump --checktags patch VERSION

browsereports: _cc ## Open reports in a browser
	@$(MAKE) $(REPORTS)

cattest: ## Print the output of the last set of tests
	### Unit Tests
	@cat reports/test.txt
	### Code Coverage
	@cat reports/coverage.txt
	### Cyclomatix Complexity Report
	@cat reports/cyclocomplexity.txt

.PHONY: getversion
getversion:
	VERSION=$(VERSION) bash -c 'echo $VERSION'

#
# Helper targets
#
$(GOPATH)/bin/$(NAME): $(NAME)
	install -m 755 $(NAME) $(GOPATH)/bin/$(NAME)

GOGETS := github.com/crosseyed/versionbump/cmd/versionbump \
		  github.com/github-release/github-release \
		  github.com/golangci/golangci-lint/cmd/golangci-lint \
		  github.com/goreleaser/nfpm/cmd/nfpm \
		  github.com/joho/godotenv/cmd/godotenv github.com/sosedoff/gitkit \
		  golang.org/x/lint/golint github.com/fzipp/gocyclo gotest.tools/gotestsum

.PHONY: $(GOGETS)
$(GOGETS):
	cd /tmp; go get $@

REPORTS = reports/html/coverage.html
.PHONY: $(REPORTS)
$(REPORTS):
ifeq ($(GOOS),darwin)
	@test -f $@ && open $@
else ifeq ($(GOOS),linux)
	@test -f $@ && xdg-open $@
endif

# Check versionbump
_isreleased:
ifeq ($(ISRELEASED),true)
	@echo "Version $(VERSION) has been released."
	@echo "Please bump with 'make bump(minor|patch|major)' depending on breaking changes."
	@exit 1
endif

#
# File targets
#
$(NAME): dist/$(NAME)_$(GOOS)_$(GOARCH)/$(NAME)
	install -m 755 $< $@

dist/$(NAME)_linux_amd64/$(NAME): $(GOFILES)
	@mkdir -p $$(dirname $@)
	GOOS=linux GOARCH=amd64 go build -o $@ ./cmd/dnsbench

dist/$(NAME)_darwin_amd64/$(NAME): $(GOFILES)
	@mkdir -p $$(dirname $@)
	GOOS=darwin GOARCH=amd64 go build -o $@ ./cmd/dnsbench

dist/$(NAME)_windows_amd64/$(NAME).exe: $(GOFILES)
	@mkdir -p $$(dirname $@)
	GOOS=windows GOARCH=amd64 go build -o $@ ./cmd/dnsbench

dist/$(NAME)-$(VERSION).$(ARCH).rpm: dist/$(NAME)_linux_amd64/$(NAME)
	@mkdir -p $$(dirname $@)
	@$(MAKE) nfpm.yaml
	nfpm pkg --packager rpm --target dist/

dist/$(NAME)_$(VERSION)_$(GOARCH).deb: dist/$(NAME)_linux_amd64/$(NAME)
	@mkdir -p $$(dirname $@)
	@$(MAKE) nfpm.yaml
	nfpm pkg --packager deb --target dist/

internal/version.go: internal/version.go.in VERSION
	@VERSION=$(VERSION) $(DOTENV) envsubst < $< > $@

dist/dnsbench.rb: dnsbench.rb.in dist/dnsbench-$(VERSION).tar.gz
	@VERSION=$(VERSION) SHA256=$$(sha256sum dist/dnsbench-$(VERSION).tar.gz | awk '{print $$1}') $(DOTENV) envsubst < $< > $@

nfpm.yaml: nfpm.yaml.in VERSION
	@VERSION=$(VERSION) $(DOTENV) envsubst < $< > $@

dist/dnsbench-$(VERSION).tar.gz: $(GOFILES)
	@mkdir -p dist
	@tar -zcf dist/dnsbench-$(VERSION).tar.gz $$(find . \( -path ./test -prune -o -path ./tmp \) -prune -false -o \( -name go.mod -o -name go.sum -o -name \*.go \))

go.mod:
	@$(DOTENV) $(MAKE) _go.mod

_go.mod:
ifndef GOSERVER
	@$(MAKE) _go.mod_err
else ifndef GOGROUP
	@$(MAKE) _go.mod_err
endif
	go mod init $(GOSERVER)/$(GOGROUP)/$(NAME)
	@$(MAKE) deps

_go.mod_err:
	@echo 'Please run "go mod init server.com/group/project"'
	@echo 'Alternatively set "GOSERVER=$YOURSERVER" and "GOGROUP=$YOURGROUP" in ~/.env or $(ROOT)/.env file'
	@exit 1

#
# make wrapper - Execute any target target prefixed with a underscore.
# EG 'make vmcreate' will result in the execution of 'make _vmcreate' 
#
%:
	@egrep -q '^_$@:' Makefile && $(DOTENV) $(MAKE) _$@
