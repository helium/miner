.PHONY: deps compile test typecheck cover

REBAR=./rebar3
VAL_VERSION=$(shell git describe --abbrev=0 | sed -e 's,validator,,')
ifeq ($(BUILDKITE), true)
  # get branch name and replace any forward slashes it may contain
  CIBRANCH=$(subst /,-,$(BUILDKITE_BRANCH))
else
  CIBRANCH=$(shell git rev-parse --abbrev-ref HEAD | sed 's/\//-/')
endif

IMAGE_ARCH ?= amd64

ifeq ($(IMAGE_ARCH), amd64)
  RUST_TARGET=x86_64
else
  RUST_TARGET=aarch64
endif

GRPC_SERVICES_DIR=src/grpc/autogen

all: compile

deps:
	$(REBAR) get-deps

compile:
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
	git clone --quiet --depth 1 https://github.com/helium/gateway-rs ./external/gateway-rs 2>/dev/null || true
	cd ./external/gateway-rs && cargo build --release --target $(RUST_TARGET)-unknown-linux-musl && cd ../../
	mv ./external/gateway-rs/target/$(RUST_TARGET)-unknown-linux-musl/release/helium_gateway ./priv/gateway_rs/

clean_external_svcs:
	@echo "removing external dependency project files"
	rm -rf ./external/gateway-rs 2>/dev/null || true
