# Go backend (TRD 01). Run from backend/, or use `make -C backend <target>`.
# The root backend-* targets delegate here. Test services remain separate from Compose.
.DEFAULT_GOAL := help

# Explicit paths make root/backend invocations select the same project and env file.
# Relative COMPOSE_ENV_FILE paths are always relative to backend/, never the invoking cwd.
BACKEND_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
COMPOSE_PROJECT_NAME ?= veea-go
COMPOSE_ENV_FILE ?= .env
BACKEND_ENV_FILE = $(if $(filter /%,$(COMPOSE_ENV_FILE)),$(COMPOSE_ENV_FILE),$(BACKEND_DIR)/$(COMPOSE_ENV_FILE))
COMPOSE = docker compose --project-directory "$(BACKEND_DIR)" --env-file "$(BACKEND_ENV_FILE)" -p "$(COMPOSE_PROJECT_NAME)" -f "$(BACKEND_DIR)/compose.yaml"
BACKEND_LOG_ARGS ?= --follow --tail=100

# Preserve an explicitly supplied legacy APP_PORT as an alias for the Go host port.
ifneq ($(origin APP_PORT),undefined)
ifeq ($(origin VEEA_GO_HTTP_PORT),undefined)
export VEEA_GO_HTTP_PORT := $(APP_PORT)
endif
endif

# Pinned so every machine generates byte-identical code. Needs a C compiler (cgo) and,
# on first use, network access to fetch the module.
SQLC := go run github.com/sqlc-dev/sqlc/cmd/sqlc@v1.31.1
SQLC_OUT := internal/platform/db/sqlc

.PHONY: help build fmt vet test test-db-up test-db-down test-integration check sqlc sqlc-verify \
        mailpit-up mailpit-down test-flutter-go test-flutter-admin test-alerts \
        backend-env backend-config backend-up backend-run backend-down backend-down-v \
        backend-logs backend-ps backend-health backend-url backend-migrate-status

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

backend-env: ## Generate private local Compose keys once; preserve an existing env file
	@"$(BACKEND_DIR)/scripts/compose-env.sh" "$(BACKEND_ENV_FILE)"

backend-config: backend-env ## Validate the selected Go Compose config without printing secrets
	$(COMPOSE) config --quiet

backend-up: backend-env ## Build and start Go API, migration, PostgreSQL and Mailpit; wait for health
	$(COMPOSE) up -d --build --wait --wait-timeout 120

backend-run: backend-up ## Compatibility alias for backend-up (detached Go stack)

backend-down: ## Stop the selected Go Compose project; preserve its PostgreSQL volume
	$(COMPOSE) down

backend-down-v: ## Stop the selected Go project and DELETE its local database volume
	$(COMPOSE) down --volumes

backend-logs: ## Follow Go stack logs (override BACKEND_LOG_ARGS for a finite snapshot)
	$(COMPOSE) logs $(BACKEND_LOG_ARGS)

backend-ps: ## Show Go stack status, including the completed migrator
	$(COMPOSE) ps --all

backend-migrate-status: ## Show current Go schema version and pending migration count
	$(COMPOSE) run --rm --no-deps migrate status

backend-url: ## Print the running Go API loopback URL (including a configured custom port)
	@binding="$$( $(COMPOSE) port mailpit 18386 )"; \
	 test -n "$$binding" || { echo "Start the Go stack with make backend-up first." >&2; exit 1; }; \
	 printf 'http://%s\n' "$$binding"

backend-health: ## Check the running Go API's /healthz and /readyz using its published port
	@binding="$$( $(COMPOSE) port mailpit 18386 )"; \
	 test -n "$$binding" || { echo "Start the Go stack with make backend-up first." >&2; exit 1; }; \
	 curl --fail --silent --show-error "http://$$binding/healthz" && \
	 curl --fail --silent --show-error "http://$$binding/readyz"

build: ## Build the api, migrate and admin binaries into bin/
	go build -o bin/api ./cmd/api
	go build -o bin/migrate ./cmd/migrate
	go build -o bin/admin ./cmd/admin

fmt: ## Fail if any file needs gofmt
	@test -z "$$(gofmt -l .)" || (gofmt -l .; echo "gofmt needed"; exit 1)

vet: ## go vet, with and without the integration tag
	go vet ./...
	go vet -tags=integration ./...

test: ## Unit tests (no database needed)
	go test ./...

test-db-up: ## Start the disposable local PostgreSQL (Docker) and print its URL
	scripts/test-postgres.sh start

test-db-down: ## Stop and discard the disposable PostgreSQL
	scripts/test-postgres.sh stop

test-integration: ## Integration tests; needs `make test-db-up` first. The Mailpit test runs only with VEEA_TEST_SMTP_ADDR and VEEA_TEST_MAILPIT_API set
	VEEA_TEST_DATABASE_URL="$$(scripts/test-postgres.sh url)" go test -tags=integration -count=1 ./test/integration/...

test-flutter-go: ## Flutter -> real Go router + disposable PostgreSQL + Mailpit; keeps rollout sync closed
	scripts/test-flutter-go.sh

test-flutter-admin: ## TRD 07 admin console -> real Go router + OpenAPI checker + disposable PostgreSQL
	scripts/test-flutter-admin.sh

test-alerts: ## TRD 08 Prometheus rules: promtool check + unit tests (local promtool or pinned image)
	scripts/test-alert-rules.sh

mailpit-up: ## Start local Mailpit (SMTP 127.0.0.1:1025, UI http://127.0.0.1:8025)
	scripts/test-mailpit.sh start

mailpit-down: ## Stop Mailpit and discard captured mail
	scripts/test-mailpit.sh stop

sqlc: ## Regenerate internal/platform/db/sqlc from migrations/ and internal/platform/db/queries/
	$(SQLC) generate

sqlc-verify: ## Validate queries, regenerate, and fail if the checked-in output changes
	$(SQLC) compile
	@scripts/sqlc-verify.sh "$(SQLC)" $(SQLC_OUT)

check: fmt vet test ## Everything that needs no database or network
