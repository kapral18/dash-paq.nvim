STYLUA ?= stylua

UNIT_SPECS := $(sort $(wildcard tests/unit/*_spec.lua))
INTEGRATION_SPECS := $(sort $(wildcard tests/integration/*_spec.lua))

.PHONY: test test-unit test-integration fmt lint

test: test-unit test-integration

test-unit:
	@tests/run_specs.sh $(UNIT_SPECS)

test-integration:
	@tests/run_specs.sh $(INTEGRATION_SPECS)

fmt:
	$(STYLUA) --config-path stylua.toml lua tests

lint:
	$(STYLUA) --config-path stylua.toml --check lua tests
