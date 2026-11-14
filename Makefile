# ============================================================================
# PUBLISHER MAKEFILE
# ============================================================================
# This Makefile provides automation for the release registry publisher.
# Run 'make help' to see all available commands.
# ============================================================================

# Default target - show help when running 'make' without arguments
.DEFAULT_GOAL := help

# ============================================================================
# TESTING & QUALITY ASSURANCE
# ============================================================================

## Run tests
#
# Runs focused regression tests for publisher scripts.
.PHONY: test
test: test-homebrew test-rpm
	bash scripts/publish_downloads_test.sh

## Run RPM regression in Linux (Docker on macOS)
.PHONY: test-rpm
test-rpm:
ifeq ($(shell uname -s),Darwin)
	docker build --platform linux/amd64 -f scripts/test-rpm.Dockerfile -t publisher-rpm-test .
	docker run --rm --platform linux/amd64 -v "$(CURDIR):/publisher:ro" -w /publisher publisher-rpm-test bash scripts/publish_rpm_reuse_test.sh
else
	bash scripts/publish_rpm_reuse_test.sh
endif

## Validate rendered Homebrew templates (requires Homebrew)
.PHONY: test-homebrew
test-homebrew:
	brew ruby scripts/homebrew_template_test.rb

## Format code and organize files
#
# Automatically formats all files in the project:
# - dprint fmt: Formats files (JSON, YAML, Markdown, etc.) using dprint
#
# Run this before committing to ensure consistent code style.
.PHONY: format
format:
	dprint fmt

# ============================================================================
# HELP & DOCUMENTATION
# ============================================================================

## Show this help message with all available commands
#
# Displays a formatted list of all available make targets with descriptions.
# Commands are organized by topic for easy navigation.
.PHONY: help
help:
	@echo "=============================================="
	@echo "PUBLISHER DEVELOPMENT COMMANDS"
	@echo "=============================================="
	@echo ""
	@awk 'BEGIN { desc = ""; target = "" } \
	/^## / { desc = substr($$0, 4) } \
	/^\.PHONY: / && desc != "" { \
		target = $$2; \
		printf "\033[36m%-20s\033[0m %s\n", target, desc; \
		desc = ""; target = "" \
	}' $(MAKEFILE_LIST)
	@echo ""
	@echo "Use 'make <command>' to run any command above."
	@echo "For detailed information, see comments in the Makefile."
	@echo ""
