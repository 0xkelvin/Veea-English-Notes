.PHONY: help deps run run-cloud analyze test test-update-goldens check \
        backend-env backend-up backend-down backend-down-v backend-run \
        backend-health backend-config backend-logs backend-ps backend-migrate-status backend-url \
        rust-backend-env rust-backend-up rust-backend-down rust-backend-down-v \
        rust-backend-run rust-backend-health clean

.DEFAULT_GOAL := help

APP_PORT ?= 18386
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

# ── Legacy Rust maintenance (explicit opt-in; cloud CI/deployment unchanged) ──

rust-backend-env: ## Create legacy cloud/.env from its example, first time only
	test -f cloud/.env || cp cloud/.env.example cloud/.env

rust-backend-up: rust-backend-env ## Start legacy Rust PostgreSQL, Redis and NATS
	cd cloud && docker compose up -d postgres redis nats

rust-backend-run: ## Run the legacy Rust server with cargo (automatic Rust migrations)
	cd cloud && APP_PORT=$(APP_PORT) cargo run

rust-backend-health: ## Check legacy Rust readiness
	curl localhost:$(APP_PORT)/health/ready

rust-backend-down: ## Stop legacy Rust infrastructure, keeping its data
	cd cloud && docker compose down

rust-backend-down-v: ## Stop legacy Rust infrastructure and DELETE its local volumes
	cd cloud && docker compose down -v

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
