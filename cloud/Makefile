.PHONY: help dev build test clippy fmt check migrate docker-up docker-down \
        docker-build docker-logs clean

# Default target
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Development ────────────────────────────────────────────────────────────

dev: ## Run the application in development mode
	cargo run

build: ## Build release binary
	cargo build --release

test: ## Run all tests
	cargo test --all-features

clippy: ## Run clippy lints
	cargo clippy --all-targets --all-features -- -D warnings

fmt: ## Format code
	cargo fmt

fmt-check: ## Check formatting without modifying files
	cargo fmt -- --check

check: fmt-check clippy test ## Run all checks (format, lint, test)

# ── Database ───────────────────────────────────────────────────────────────

migrate: ## Run database migrations
	cargo sqlx migrate run --source migrations

migrate-add: ## Create a new migration (usage: make migrate-add name=create_foo)
	cargo sqlx migrate add -r $(name) --source migrations

# ── Docker ─────────────────────────────────────────────────────────────────

docker-up: ## Start all services with docker compose
	docker compose up -d

docker-down: ## Stop all services
	docker compose down

docker-build: ## Build the application docker image
	docker compose build app

docker-logs: ## Tail logs for all services
	docker compose logs -f

docker-clean: ## Stop and remove all containers/volumes
	docker compose down -v --remove-orphans

# ── Misc ───────────────────────────────────────────────────────────────────

clean: ## Clean build artifacts
	cargo clean
