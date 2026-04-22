COMPOSE ?= docker compose

.PHONY: up down logs ps kafka-topics demo demo-canary demo-story manifest tail reason adapter-k8s-replay adapter-k8s-fixtures

up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down -v

logs:
	$(COMPOSE) logs -f redpanda console

ps:
	$(COMPOSE) ps

kafka-topics:
	$(COMPOSE) exec redpanda rpk topic list

demo:
	mix colony.demo

demo-canary:
	mix colony.demo --scenario canary_regression

manifest:
	mix colony.manifest

tail:
	mix colony.tail

reason:
	mix colony.reason

adapter-k8s-replay:
	mix colony.adapter.k8s.replay --all

adapter-k8s-fixtures:
	mix colony.adapter.k8s.replay --list

demo-story:
	@printf '%s\n' \
	"Self-healing infra runtime (Phase 1 reference scenarios):" \
	"- change_failure: deploy/schema regression with downstream breakage" \
	"- canary_regression: canary rollout degrades live behavior" \
	"1. Producers emit commands and observations from many services." \
	"2. Kafka partitions route work into swarm cells." \
	"3. A cell crashes and is restarted under supervision." \
	"4. The replacement consumer replays from Kafka and restores state." \
	"5. Side effects stay idempotent and operator history remains inspectable."
