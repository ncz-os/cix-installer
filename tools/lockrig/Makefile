# tools/lockrig/Makefile — CI/operator entry points for the multi-host test rig.
#
# Everything is offline-safe except the `run*` targets, which touch real hosts
# and therefore take a lease per host. `make selftest` needs nothing but bash.

LOCKRIG := ./lockrig
OUT     ?= $(CURDIR)/../../build/lockrig-out
HOSTS   ?=
ALLOW_ATTENDED ?=
OWNER   ?= make-$(shell hostname -s)-$$

.PHONY: help selftest status reap dry-run run run-all clean matrix
help:
	@sed -n '1,8p' Makefile

# Offline: syntax + lease semantics + report consolidation (no hosts touched).
selftest:
	LOCKRIG_OWNER=$(OWNER) ./test-lockrig.sh

status:
	./lease.sh status

reap:
	./lease.sh reap

# Headless dry-run on a build host from the inventory (validates the rig + the
# lock suite). DRY_HOST names it (default: build-amd64 from hosts.example.tsv).
DRY_HOST ?= build-amd64
dry-run:
	LOCKRIG_OWNER=$(OWNER) $(LOCKRIG) run --hosts $(DRY_HOST) --skip-install --out $(OUT)

# Live run over the requested hosts, e.g. HOSTS=prime-laptop,sky1-board
run:
	@[ -n "$(HOSTS)" ] || { echo "set HOSTS=host,host"; exit 2; }
	LOCKRIG_OWNER=$(OWNER) $(LOCKRIG) run --hosts $(HOSTS) \
	  $(if $(ALLOW_ATTENDED),--allow-attended,) $(if $(FROM_APT),--from-apt,) \
	  $(if $(CANDIDATE_DIR),--candidate-dir $(CANDIDATE_DIR),) --out $(OUT)

# The full verification sweep over every inventory host (attended hosts last,
# one at a time).
run-all:
	LOCKRIG_OWNER=$(OWNER) $(LOCKRIG) run --hosts all \
	  --allow-attended --out $(OUT)

matrix:
	./report.sh --out $(OUT) --hosts "$(HOSTS)"

clean:
	rm -rf $(OUT)
