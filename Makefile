# Local development and CI entry points.
#
# Windows users: dev.ps1 mirrors these targets.

SHELL := /bin/bash
.DEFAULT_GOAL := help

COMPOSE := docker compose
TENANT ?= acme
BASE ?= http://$(TENANT).localhost:8080

.PHONY: help
help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------- local stack

.PHONY: up
up: ## Build and start the whole local stack, then migrate and seed
	$(COMPOSE) up -d --build
	$(MAKE) migrate
	@echo ""
	@echo "  Ready: $(BASE)"
	@echo "  Sign in as admin@$(TENANT).test / password"
	@echo "  Other tenants: whiteknight.localhost:8080, frdm.localhost:8080"
	@echo "  Roles: owner@ / admin@ / operator@ / viewer@$(TENANT).test"

.PHONY: down
down: ## Stop the stack, keeping volumes
	$(COMPOSE) down

.PHONY: clean
clean: ## Stop the stack and delete all data
	$(COMPOSE) down -v --remove-orphans

.PHONY: migrate
migrate: ## Create, migrate and seed every tenant schema
	$(COMPOSE) run --rm migrate

.PHONY: logs
logs: ## Tail logs for the application services
	$(COMPOSE) logs -f web-api worker nginx

.PHONY: ps
ps: ## Show service status
	$(COMPOSE) ps

.PHONY: scale-workers
scale-workers: ## Scale the worker pool the way the HPA would (N=3)
	$(COMPOSE) up -d --scale worker=$${N:-3}

.PHONY: rebuild-frontend
rebuild-frontend: ## Rebuild just the SPA and restart nginx
	$(COMPOSE) run --rm frontend-build
	$(COMPOSE) restart nginx

# ---------------------------------------------------------------- verification

.PHONY: test
test: test-go test-php ## Run every test suite

.PHONY: test-go
test-go: ## Go unit tests (payroll arithmetic, envelope contract, registry)
	cd worker-go && go build ./... && go vet ./... && go test ./... -count=1

.PHONY: test-php
test-php: ## PHP feature tests (tenancy isolation, authz, idempotency, audit)
	cd web-api && vendor/bin/phpunit

.PHONY: test-frontend
test-frontend: ## Typecheck and production-build the SPA
	cd frontend && npm run build

.PHONY: lint
lint: ## Formatting and static checks
	cd worker-go && gofmt -l . && go vet ./...
	cd web-api && php -l app/Http/Kernel.php >/dev/null
	python3 scripts/validate-yaml.py

.PHONY: smoke
smoke: ## Exercise the running stack end to end
	./scripts/smoke.sh $(BASE) $(TENANT)

# ---------------------------------------------------------------- deployment

.PHONY: tf-plan
tf-plan: ## Terraform plan for an environment (ENV=dev|prod)
	cd terraform/envs/$${ENV:-dev} && terraform init -upgrade && terraform plan

.PHONY: tf-apply
tf-apply: ## Terraform apply for an environment (ENV=dev|prod)
	cd terraform/envs/$${ENV:-dev} && terraform init && terraform apply

.PHONY: bootstrap
bootstrap: ## Run the ordered cluster bootstrap (after tf-apply)
	./bootstrap/run-all.sh

.PHONY: images
images: ## Build and push both service images (TAG=<git sha>)
	./ci/build-images.sh
