# Go backend (TRD 01). Run from backend/, or use `make -C backend <target>`.
# The repo-root Makefile's backend-* targets belong to the Rust service in cloud/.

# Pinned so every machine generates byte-identical code. Needs a C compiler (cgo) and,
# on first use, network access to fetch the module.
SQLC := go run github.com/sqlc-dev/sqlc/cmd/sqlc@v1.31.1
SQLC_OUT := internal/platform/db/sqlc

.PHONY: help build fmt vet test test-db-up test-db-down test-integration check sqlc sqlc-verify

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

build: ## Build the api and migrate binaries into bin/
	go build -o bin/api ./cmd/api
	go build -o bin/migrate ./cmd/migrate

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

test-integration: ## Integration tests; needs `make test-db-up` first
	VEEA_TEST_DATABASE_URL="$$(scripts/test-postgres.sh url)" go test -tags=integration -count=1 ./test/integration/...

sqlc: ## Regenerate internal/platform/db/sqlc from migrations/ and internal/platform/db/queries/
	$(SQLC) generate

sqlc-verify: ## Validate queries, regenerate, and fail if the checked-in output changes
	$(SQLC) compile
	@scripts/sqlc-verify.sh "$(SQLC)" $(SQLC_OUT)

check: fmt vet test ## Everything that needs no database or network
