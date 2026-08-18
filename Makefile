.PHONY: help deps run run-cloud analyze test test-update-goldens check \
        backend-env backend-up backend-down backend-down-v backend-run \
        backend-health clean

APP_PORT ?= 18386
API_BASE_URL ?= http://localhost:$(APP_PORT)

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── App (local only, no backend) ────────────────────────────────────────────

deps: ## Fetch Flutter dependencies
	flutter pub get

run: deps ## Run the app locally, no backend/account
	flutter run

# ── App + backend ────────────────────────────────────────────────────────────

run-cloud: deps ## Run the app pointed at the local backend (APP_PORT=18386)
	flutter run --dart-define=VEEA_API_BASE_URL=$(API_BASE_URL)

backend-env: ## Create cloud/.env from the example, first time only
	test -f cloud/.env || cp cloud/.env.example cloud/.env

backend-up: backend-env ## Start postgres, redis and nats for the backend
	cd cloud && docker compose up -d postgres redis nats

backend-run: ## Run the backend server (migrations run automatically)
	cd cloud && APP_PORT=$(APP_PORT) cargo run

backend-health: ## Check the backend is up
	curl localhost:$(APP_PORT)/health/ready

backend-down: ## Stop backend infrastructure, keep the data
	cd cloud && docker compose down

backend-down-v: ## Stop backend infrastructure and wipe the database
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
