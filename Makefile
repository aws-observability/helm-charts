ALL_SRC := $(shell find . -name '*.go' -type f | sort)
TOOLS_BIN_DIR := $(abspath ./build/tools)
GOIMPORTS_OPT?= -w

GOCMD=go
HELM=helm
GOIMPORTS = $(TOOLS_BIN_DIR)/goimports
LINTER = $(TOOLS_BIN_DIR)/golangci-lint

.PHONY: all deps tidy helm-lint check_secrets fmt lint install-goimports install-golangci-lint

all: deps tidy check_secrets fmt lint helm-lint

install-goimports:
	GOBIN=$(TOOLS_BIN_DIR) go install golang.org/x/tools/cmd/goimports@latest

install-golangci-lint:
	#Install from source for golangci-lint is not recommended based on https://golangci-lint.run/usage/install/#install-from-source so using binary
	curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(TOOLS_BIN_DIR) v1.64.2

deps:
	$(GOCMD) mod download
	$(GOCMD) mod verify

tidy:
	$(GOCMD) mod tidy

check_secrets:
	if grep --exclude-dir=build --exclude-dir=vendor -E "(A3T[A-Z0-9]|AKIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA|ASIA)[A-Z0-9]{16}|(\"')?( AWS|aws|Aws)?_?(SECRET|secret|Secret)?_?(ACCESS|access|Access)?_?(KEY|key|Key)(\"')?\\s*(:|=>|=)\\s*(\"')?[A-Za-z0-9/\\+=]{40}(\"')?" -Rn .; then echo "check_secrets failed"; exit 1; fi;

fmt: install-goimports
	go fmt ./...
	@echo $(ALL_SRC) | xargs -n 10 $(GOIMPORTS) $(GOIMPORTS_OPT)

lint: install-golangci-lint
	${LINTER} run ./...

helm-lint:
	${HELM} lint ./charts/amazon-cloudwatch-observability --set region=test-region --set clusterName=test-cluster
