OFFSET      ?= $(offset)
COMPOSE     := bash scripts/compose.sh
YSQL_HOST   ?= $(shell bash scripts/resolve-ysql-host.sh)
YB_YSQL_PORT ?= $(shell bash -c 'source scripts/load-ports.sh 2>/dev/null && echo $${YB_YSQL_PORT:-5433}')
PY          := .venv/bin/python
ROWS        ?= 1000000
RATE        ?= 150
DB          ?= mission_control

# Use local ysqlsh if available (brew tap yugabyte/tap && brew install yugabyte-client),
# otherwise shell into the container
ifneq ($(shell command -v ysqlsh 2>/dev/null),)
YSQL_ADMIN  := ysqlsh -h $(YSQL_HOST) -p $(YB_YSQL_PORT) -U yugabyte
YSQL        := $(YSQL_ADMIN) -d $(DB)
YSQL_TTY    := $(YSQL)
run_sql_file = $(YSQL) -f $(1)
# Same as run_sql_file but builds indexes offline. Only safe with no writers.
run_sql_file_nc = $(YSQL) -v nc=NONCONCURRENTLY -f $(1)
else
YSQL_ADMIN  := $(COMPOSE) exec -T yb-node1 /home/yugabyte/bin/ysqlsh -h yb-node1 -p 5433 -U yugabyte
YSQL        := $(YSQL_ADMIN) -d $(DB)
YSQL_TTY    := $(COMPOSE) exec yb-node1 /home/yugabyte/bin/ysqlsh -h yb-node1 -p 5433 -U yugabyte -d $(DB)
run_sql_file = cat $(1) | $(YSQL)
run_sql_file_nc = cat $(1) | $(YSQL) -v nc=NONCONCURRENTLY
endif

.DEFAULT_GOAL := help
.PHONY: help up down clean restart wait diagnose show welcome bootstrap status servers connect shell sql \
        venv db setup setup-lab setup-lab-schema setup-lab-views setup-lab-backfill setup-lab-analyze \
        demo-mode lab-mode load stop-load dash refill reset walkthrough verify-setup \
        kill revive repair-node logs collect-logs port-offset reset-ports

help: ## Show available commands
	@printf "\n\033[1m🛰️  Mission Control: YugabyteDB bucket index demo\033[0m\n\n"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@printf "\n\033[90mDemo quick start: make up → make setup → make load → make dash\033[0m\n\n"

# ── Cluster lifecycle ──────────────────────────────────────────────────────────

up: ## Start the 3-node cluster (detached)
	$(COMPOSE) up -d
	@bash scripts/wait-for-cluster.sh

down: ## Stop the cluster (data volumes kept)
	$(COMPOSE) down

clean: ## Stop the cluster AND delete all data volumes (also resets port offset)
	$(COMPOSE) down -v
	@rm -rf .yb-data
	@rm -f .env

port-offset: ## Shift host ports by OFFSET (e.g. make port-offset OFFSET=10): make down first
	@test -n "$(OFFSET)" || (printf "Usage: make port-offset OFFSET=<number>\n  Example: make port-offset OFFSET=10\n"; exit 1)
	@bash scripts/write-ports-env.sh "$(OFFSET)"
	@printf "\033[32mPort offset set to +$(OFFSET). Run: make up\033[0m\n"

reset-ports: ## Reset port offset to defaults (0): make down first
	@rm -f .env
	@printf "\033[32mPort offset cleared — defaults restored. Run: make up\033[0m\n"

restart: down up ## Full restart (keeps data)

wait: ## Wait for all 3 nodes (progress + timeout)
	@bash scripts/wait-for-cluster.sh

diagnose: ## Print cluster connectivity diagnostics
	@bash scripts/wait-for-cluster.sh --diagnose

show: ## Show cluster URLs and status
	@bash scripts/wait-for-cluster.sh --show

welcome: ## Print setup status and next steps (Codespaces attach banner)
	@bash scripts/welcome.sh

bootstrap: ## Load demo data if empty (devcontainer auto-runs; local: make bootstrap)
	@MISSION_CONTROL_AUTO_BOOTSTRAP=1 bash scripts/bootstrap-data.sh

verify-setup: ## Sanity check: ~1M rows and both secondary indexes (post-prebuild)
	@bash scripts/verify-setup.sh

status: ## Show yugabyted status for all nodes
	@for n in 1 2 3; do \
	  printf "\033[1m── node$$n ──\033[0m\n"; \
	  $(COMPOSE) exec yb-node$$n /home/yugabyte/bin/yugabyted status 2>/dev/null || true; \
	  echo; \
	done

servers: ## List YB servers visible to YSQL
	$(YSQL) -c "SELECT host, port, cloud, region, zone, node_type FROM yb_servers() ORDER BY host;"

logs: ## Tail live logs from all three nodes (Ctrl+C to exit)
	$(COMPOSE) logs -f yb-node1 yb-node2 yb-node3

collect-logs: ## Snapshot logs from all nodes: make collect-logs [NOTE="reason"]
	@bash scripts/collect-logs.sh "$(NOTE)"

# ── The demo ───────────────────────────────────────────────────────────────────

venv: ## Create the Python venv and install app dependencies
	@test -d .venv || python3 -m venv .venv
	@.venv/bin/pip install -q -r app/requirements.txt
	@echo "venv ready"

db: ## Create the mission_control database (settings come from sql/core/schema.sql)
	@$(YSQL_ADMIN) -tAc "SELECT 1 FROM pg_database WHERE datname='$(DB)'" | grep -q 1 \
	  || $(YSQL_ADMIN) -c "CREATE DATABASE $(DB)"
	@echo "database $(DB) ready"

setup-lab-schema: wait db ## (internal) lab setup step: schema
	@bash scripts/stop-load.sh
	$(call run_sql_file,sql/core/schema.sql)

setup-lab-views: ## (internal) lab setup step: views
	$(call run_sql_file,sql/core/views.sql)

setup-lab-backfill: venv ## (internal) lab setup step: historical telemetry
	YSQL_HOST=$(YSQL_HOST) YSQL_PORT=$(YB_YSQL_PORT) $(PY) app/ingest.py --backfill --rows $(ROWS)

setup-lab-analyze: ## (internal) lab setup step: ANALYZE
	$(YSQL) -c "ANALYZE telemetry;" -c "ANALYZE satellites;"

setup: venv wait db ## DEMO mode: schema + ~1M rows of real satellite history + both indexes pre-built
	@bash scripts/stop-load.sh
	$(call run_sql_file,sql/core/schema.sql)
	$(call run_sql_file,sql/core/views.sql)
	YSQL_HOST=$(YSQL_HOST) YSQL_PORT=$(YB_YSQL_PORT) $(PY) app/ingest.py --backfill --rows $(ROWS)
	$(call run_sql_file_nc,sql/core/indexes.sql)
	$(YSQL) -c "ANALYZE telemetry;" -c "ANALYZE satellites;"
	@echo "✅ demo mode ready. make load (terminal 1) + make dash (terminal 2), then sql/demo/walkthrough.sql"

setup-lab: venv setup-lab-schema setup-lab-views setup-lab-backfill setup-lab-analyze ## LAB mode: same data, NO secondary indexes; you build them in the lab
	@echo "✅ lab mode ready. Open sql/lab/walkthrough.sql and build the indexes yourself"

demo-mode: ## Switch to demo mode: (re)build both indexes (~2 min; not mid-presentation)
	$(call run_sql_file,sql/core/drop_indexes.sql)
	$(call run_sql_file,sql/core/indexes.sql)
	$(YSQL) -c "ANALYZE telemetry;"

lab-mode: ## Switch to lab mode: drop both secondary indexes (instant)
	$(call run_sql_file,sql/core/drop_indexes.sql)
	@echo "✅ lab mode: no secondary indexes. sql/lab/walkthrough.sql awaits"

reset: demo-mode ## Alias for demo-mode (rebuild both indexes fresh)

load: venv ## Live telemetry ingest (Ctrl-C to stop): make load [RATE=150]
	YSQL_HOST=$(YSQL_HOST) YSQL_PORT=$(YB_YSQL_PORT) $(PY) app/ingest.py --rate $(RATE)

stop-load: ## Stop background load generator (Controls page / prior make load)
	@bash scripts/stop-load.sh

dash: venv ## Run the Mission Control dashboard at http://localhost:8501
	YSQL_HOST=$(YSQL_HOST) YSQL_PORT=$(YB_YSQL_PORT) .venv/bin/streamlit run app/1_Dashboard.py --server.headless true --server.port 8501

refill: venv stop-load ## Reset telemetry to a fresh ~1M-row backfill (DELETE + reload; indexes kept)
	$(YSQL) -c "DELETE FROM telemetry;"
	YSQL_HOST=$(YSQL_HOST) YSQL_PORT=$(YB_YSQL_PORT) $(PY) app/ingest.py --backfill --rows $(ROWS)
	$(YSQL) -c "ANALYZE telemetry;"
	@echo "✅ telemetry refilled. If the indexes are weeks old, also run: make demo-mode"

walkthrough: ## Where the actual demos live
	@echo "Demo (presenter, ~3 min):  sql/demo/walkthrough.sql   (after make setup)"
	@echo "Lab (hands-on, ~30 min):   sql/lab/walkthrough.sql    (after make setup-lab)"

sql: ## Run an inline SQL statement: make sql Q="SELECT version();"
	@test -n "$(Q)" || (printf "Usage: make sql Q=\"<statement>\"\n"; exit 1)
	$(YSQL) -c "$(Q)"

connect: ## Open an interactive YSQL shell (Ctrl-D to exit)
	$(YSQL_TTY)

shell: ## Open a shell on node 1 (access yugabyted, yb-admin, etc.)
	$(COMPOSE) exec yb-node1 bash

# ── Fault-injection (kept from yb-3node-demo; not part of the demo script) ────

kill: ## Pause a node to simulate failure: make kill N=2
	@test -n "$(N)" || (printf "Usage: make kill N=<1|2|3>\n"; exit 1)
	@bash scripts/kill-node.sh $(N)

revive: ## Restart a paused node: make revive N=2
	@test -n "$(N)" || (printf "Usage: make revive N=<1|2|3>\n"; exit 1)
	@bash scripts/revive-node.sh $(N)

repair-node: ## Wipe and recreate a node (fixes exit 137): make repair-node N=3
	@test -n "$(N)" || (printf "Usage: make repair-node N=<1|2|3>\n"; exit 1)
	@bash scripts/repair-node.sh $(N)
