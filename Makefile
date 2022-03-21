.PHONY: deps compile test typecheck cover

REBAR=./rebar3
VAL_VERSION=$(shell git describe --abbrev=0 | sed -e 's,validator,,')
ifeq ($(BUILDKITE), true)
  # get branch name and replace any forward slashes it may contain
  CIBRANCH=$(subst /,-,$(BUILDKITE_BRANCH))
else
  CIBRANCH=$(shell git rev-parse --abbrev-ref HEAD | sed 's/\//-/')
endif

GRPC_SERVICES_DIR=src/grpc/autogen

GATEWAY_RS_VSN ?= "v1.0.0-alpha.23"
SEMTECH_UDP_VSN ?= "v0.9.2"

all: compile

deps:
	$(REBAR) get-deps

compile:
	$(REBAR) get-deps
	REBAR_CONFIG="config/grpc_client_gen_local.config" $(REBAR) grpc gen
	REBAR_CONFIG="config/grpc_client_gen.config" $(REBAR) grpc gen
	$(MAKE) external_svcs
	$(REBAR) compile

clean:
	$(MAKE) clean_external_svcs
	$(MAKE) clean_grpc
	$(REBAR) clean

test: compile
	$(REBAR) as test do eunit, ct --verbose

typecheck:
	$(REBAR) dialyzer xref

ci: compile
	$(REBAR) do dialyzer,xref && ($(REBAR) do eunit,ct || (mkdir -p artifacts; tar --exclude='./_build/test/lib' --exclude='./_build/test/plugins' -czf artifacts/$(CIBRANCH).tar.gz _build/test; false))

release:
	$(REBAR) as prod release -n miner

validator:
	$(REBAR) as validator release -n miner -v $(VAL_VERSION)

cover:
	$(REBAR) cover

aws:
	$(REBAR) as aws release

seed:
	$(REBAR) as seed release

docker:
	$(REBAR) as docker release

devrel:
	$(REBAR) as testdev, miner1 release -n miner1
	$(REBAR) as testdev, miner2 release -n miner2
	$(REBAR) as testdev, miner3 release -n miner3
	$(REBAR) as testdev, miner4 release -n miner4
	$(REBAR) as testdev, miner5 release -n miner5
	$(REBAR) as testdev, miner6 release -n miner6
	$(REBAR) as testdev, miner7 release -n miner7
	$(REBAR) as testdev, miner8 release -n miner8

devrelease:
	$(REBAR) as dev release

grpc:
	@echo "generating miner grpc services"
	$(REBAR) get-deps
	REBAR_CONFIG="config/grpc_client_gen_local.config" $(REBAR) grpc gen
	REBAR_CONFIG="config/grpc_client_gen.config" $(REBAR) grpc gen

$(GRPC_SERVICE_DIR):
	@echo "miner grpc service directory $(directory) does not exist"
	$(REBAR) get-deps
	$(MAKE) grpc

clean_grpc:
	@echo "cleaning miner grpc services"
	rm -rf $(GRPC_SERVICES_DIR)

external_svcs:
	@echo "cloning external dependency projects"
	@echo "--- gateway-rs ---"
	$(call clone_project,gateway-rs,$(GATEWAY_RS_VSN))
	@(cd ./external/gateway-rs && cargo build --release)
	$(call install_rust_bin,gateway-rs,helium_gateway,gateway_rs)
	@cp ./external/gateway-rs/config/default.toml ./priv/gateway_rs/default.toml

	@echo "--- semtech-udp ---"
	$(call clone_project,semtech-udp,$(SEMTECH_UDP_VSN))
	@(cd ./external/semtech-udp && cargo build --release --features client\,server --example gwmp-mux)
	$(call install_rust_bin,semtech-udp,examples/gwmp-mux,semtech_udp)

clean_external_svcs:
	@echo "removing external dependency project files"
	$(call remove,./external/gateway-rs)
	$(call remove,./priv/gateway_rs/helium_gateway)
	$(call remove,./priv/gateway_rs/default.toml)
	$(call remove,./external/semtech-udp)
	$(call remove,./priv/semtech_udp/gwmp-mux)

define clone_project
	@git clone --quiet --depth 1 --branch $(2) https://github.com/helium/$(1) ./external/$(1) 2>/dev/null || true
endef

define install_rust_bin
	@mkdir -p ./priv/$(3)
	@mv ./external/$(1)/target/release/$(2) ./priv/$(3)/ 2>/dev/null || true
endef

define remove
	@rm -rf $(1) 2>/dev/null || true
endef
