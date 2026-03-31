COMPOSE ?= docker compose

.PHONY: up down logs ps kafka-topics demo-story

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
	mix run -e "ColonyDemo.run()"

demo-story:
	@printf '%s\n' \
	"Demo narrative:" \
	"1. Producers emit commands and observations from many services." \
	"2. Kafka partitions route work into swarm cells." \
	"3. A cell crashes and is restarted under supervision." \
	"4. The replacement consumer replays from Kafka and restores state." \
	"5. Side effects stay idempotent and operator history remains inspectable."
