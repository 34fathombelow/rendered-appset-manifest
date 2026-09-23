# Entry points for local use and CI. The logic lives in scripts/, where
# shellcheck can see it; each target here only calls a script.
#
#   make diff ENV=prod STAT=1    make render OUT=/tmp/r
#
# Works with the GNU make 3.81 that ships with macOS.

OUT ?= /tmp/rendered

# Only take ENV from the make command line: POSIX shells use $ENV for a startup
# file, and make would otherwise inherit it from the environment.
DIFF_ENV := $(if $(filter command line,$(origin ENV)),$(ENV))

.PHONY: help check validate lint diff render

help: ## List targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{ printf "  %-10s %s\n", $$1, $$2 }'

check: validate lint ## Everything CI runs before rendering

validate: ## Offline checks on clusters/, apps/, addons/, appsets/, argocd/
	scripts/validate.sh

lint: ## shellcheck every script
	shellcheck scripts/*.sh

diff: ## Local change vs each env's PR/branch  (ENV=prod, STAT=1 for file list)
	scripts/diff.sh $(if $(STAT),--stat) $(DIFF_ENV)

render: ## Render every AppSet into OUT (default /tmp/rendered)
	scripts/render.sh $(OUT)
