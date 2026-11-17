.PHONY: help deps run run-cloud analyze test test-update-goldens check \
        backend-env backend-up backend-down backend-down-v backend-run \
        backend-health backend-config backend-logs backend-ps backend-migrate-status backend-url \
        clean

.DEFAULT_GOAL := help

API_BASE_URL ?=

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── App (local only, no backend) ────────────────────────────────────────────

deps: ## Fetch Flutter dependencies
	flutter pub get

run: deps ## Run the app locally, no backend/account
	flutter run

# ── App + backend ────────────────────────────────────────────────────────────

run-cloud: deps ## Run Flutter against the running Go stack (or explicit API_BASE_URL)
	@api_url="$(API_BASE_URL)"; \
	 if [ -z "$$api_url" ]; then \
	   api_url="$$( $(MAKE) --no-print-directory -s -C backend backend-url )" || exit 1; \
	 fi; \
	 flutter run --dart-define=VEEA_API_BASE_URL="$$api_url"

backend-env: ## Generate backend/.env local keys once (Go)
	+$(MAKE) -C backend $@

backend-up: ## Build and start the Go Compose stack, including migrations
	+$(MAKE) -C backend $@

backend-run: ## Alias for backend-up (Go stack, detached)
	+$(MAKE) -C backend $@

backend-health: ## Check Go /healthz and /readyz
	+$(MAKE) -C backend $@

backend-down: ## Stop Go Compose, keeping database data
	+$(MAKE) -C backend $@

backend-down-v: ## Stop Go Compose and DELETE its local database volume
	+$(MAKE) -C backend $@

backend-config: ## Validate the Go Compose configuration without printing secrets
	+$(MAKE) -C backend $@

backend-logs: ## Follow Go Compose logs
	+$(MAKE) -C backend $@

backend-ps: ## Show Go Compose status and migrator completion
	+$(MAKE) -C backend $@

backend-migrate-status: ## Show the Go migration version and pending count
	+$(MAKE) -C backend $@

backend-url: ## Print the running Go API URL
	+$(MAKE) --no-print-directory -s -C backend $@

# ── Checks ───────────────────────────────────────────────────────────────────

analyze: ## Run flutter analyze
	flutter analyze

test: ## Run unit, widget and golden tests
	flutter test

test-update-goldens: ## Regenerate golden files after an intentional visual change
	flutter test --update-goldens

check: analyze test ## Run analyze and test together

# ── Misc ─────────────────────────────────────────────────────────────────────

clean: ## Clean Flutter build artifacts
	flutter clean

.PHONY: backend-prod-config backend-prod-build backend-prod-up backend-prod-down backend-prod-logs backend-prod-ps backend-prod-migrate-status backend-prod-health
backend-prod-config: ## Validate production configuration
	+$(MAKE) -C backend $@

backend-prod-build: ## Build the production release image
	+$(MAKE) -C backend $@

backend-prod-up: ## Start production Docker stack without Mailpit
	+$(MAKE) -C backend $@

backend-prod-down: ## Stop production and keep database data
	+$(MAKE) -C backend $@

backend-prod-logs: ## Follow production logs
	+$(MAKE) -C backend $@

backend-prod-ps: ## Show production service status
	+$(MAKE) -C backend $@

backend-prod-migrate-status: ## Show production migration status
	+$(MAKE) -C backend $@

backend-prod-health: ## Check production health/readiness
	+$(MAKE) -C backend $@
