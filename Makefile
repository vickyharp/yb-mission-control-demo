COMPOSE     := bash scripts/compose.sh
YSQL_HOST   ?= $(shell bash scripts/resolve-ysql-host.sh)
PY          := .venv/bin/python
ROWS        ?= 3000000
RATE        ?= 150
DB          ?= mission_control

# Use local ysqlsh if available (brew tap yugabyte/tap && brew install yugabyte-client),
# otherwise shell into the container
ifneq ($(shell command -v ysqlsh 2>/dev/null),)
YSQL_ADMIN  := ysqlsh -h $(YSQL_HOST) -p 5433 -U yugabyte
YSQL        := $(YSQL_ADMIN) -d $(DB)
YSQL_TTY    := $(YSQL)
run_sql_file = $(YSQL) -f $(1)
else
YSQL_ADMIN  := $(COMPOSE) exec -T yb-node1 /home/yugabyte/bin/ysqlsh -h yb-node1 -p 5433 -U yugabyte
YSQL        := $(YSQL_ADMIN) -d $(DB)
YSQL_TTY    := $(COMPOSE) exec yb-node1 /home/yugabyte/bin/ysqlsh -h yb-node1 -p 5433 -U yugabyte -d $(DB)
run_sql_file = cat $(1) | $(YSQL)
endif

.DEFAULT_GOAL := help
.PHONY: help up down clean restart wait diagnose show status servers connect shell sql \
        venv db setup setup-lab demo-mode lab-mode load dash refill reset walkthrough \
        kill revive repair-node logs collect-logs

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

clean: ## Stop the cluster AND delete all data volumes
	$(COMPOSE) down -v

restart: down up ## Full restart (keeps data)

wait: ## Wait for all 3 nodes (progress + timeout)
	@bash scripts/wait-for-cluster.sh

diagnose: ## Print cluster connectivity diagnostics
	@bash scripts/wait-for-cluster.sh --diagnose

show: ## Show cluster URLs and status
	@bash scripts/wait-for-cluster.sh --show

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

db: ## Create the mission_control database (settings come from sql/core/01_schema.sql)
	@$(YSQL_ADMIN) -tAc "SELECT 1 FROM pg_database WHERE datname='$(DB)'" | grep -q 1 \
	  || $(YSQL_ADMIN) -c "CREATE DATABASE $(DB)"
	@echo "database $(DB) ready"

setup: venv db ## DEMO mode: schema + ~3M rows of real satellite history + both indexes pre-built
	$(call run_sql_file,sql/core/01_schema.sql)
	$(call run_sql_file,sql/core/02_views.sql)
	YSQL_HOST=$(YSQL_HOST) $(PY) app/ingest.py --backfill --rows $(ROWS)
	$(call run_sql_file,sql/core/indexes.sql)
	$(YSQL) -c "ANALYZE telemetry;" -c "ANALYZE satellites;"
	@echo "✅ demo mode ready. make load (terminal 1) + make dash (terminal 2), then sql/demo/walkthrough.sql"

setup-lab: venv db ## LAB mode: same data, NO secondary indexes; you build them in the lab
	$(call run_sql_file,sql/core/01_schema.sql)
	$(call run_sql_file,sql/core/02_views.sql)
	YSQL_HOST=$(YSQL_HOST) $(PY) app/ingest.py --backfill --rows $(ROWS)
	$(YSQL) -c "ANALYZE telemetry;" -c "ANALYZE satellites;"
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
	YSQL_HOST=$(YSQL_HOST) $(PY) app/ingest.py --rate $(RATE)

dash: venv ## Run the Mission Control dashboard at http://localhost:8501
	YSQL_HOST=$(YSQL_HOST) .venv/bin/streamlit run app/1_Dashboard.py --server.headless true

refill: venv ## Reset telemetry to a fresh ~3M-row backfill (TRUNCATE + reload; indexes kept)
	$(YSQL) -c "TRUNCATE telemetry;"
	YSQL_HOST=$(YSQL_HOST) $(PY) app/ingest.py --backfill --rows $(ROWS)
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
