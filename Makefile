.PHONY: help verify check ci lint test build

help: ## Show targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN { FS = ":.*## " } { printf "  %-8s %s\n", $$1, $$2 }'

verify: lint test ## Credential-free, non-mutating gate

check: verify ## Developer gate (nothing to format)

ci: verify ## CI gate

lint: ## shellcheck and actionlint
	shellcheck build.sh download/*.sh lib/*.sh tests/*.sh
	actionlint

test: ## The 2 checks with their tests, and the baseline with its negative tests
	bash download/test-check-checksums.sh
	bash download/check-checksums.sh
	bash tests/check-depends-test.sh
	tests/check-baseline.sh
	tests/check-baseline-test.sh

# Not part of the gate: it builds the packages and takes several minutes.
# CODENAME=trixie (the default) or CODENAME=forky picks the Debian release.
CODENAME ?= trixie

build: ## Build the packages locally in debian:trixie or debian:forky, into dist/
	docker run --rm -v "$(CURDIR)":/src -w /src debian:$(CODENAME) bash build.sh
