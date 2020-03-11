.PHONY: deps compile test typecheck cover

REBAR=./rebar3
HASH=$(shell git describe)

all: compile

deps:
	$(REBAR) get-deps

compile:
	$(REBAR) compile

clean:
	$(REBAR) clean

test: compile
	$(REBAR) as test do eunit, ct --verbose

typecheck:
	$(REBAR) dialyzer xref

ci: compile
	rm success; $(REBAR) do dialyzer,xref && $(REBAR) do eunit,ct && touch success
	if [ ! -f success ] ; \
then \
    mkdir -p artifacts; \
    tar -czf artifacts/test_log-$(HASH).tar.gz _build/test; \
fi;

release:
	$(REBAR) as prod release -n miner

cover:
	$(REBAR) cover

devrelease:
	$(REBAR) as dev release

devrel:
	$(REBAR) as dev, miner1 release -n miner1
	$(REBAR) as dev, miner2 release -n miner2
	$(REBAR) as dev, miner3 release -n miner3
	$(REBAR) as dev, miner4 release -n miner4
	$(REBAR) as dev, miner5 release -n miner5
	$(REBAR) as dev, miner6 release -n miner6
	$(REBAR) as dev, miner7 release -n miner7
	$(REBAR) as dev, miner8 release -n miner8

startdevrel:
	./_build/default/rel/miner/bin/miner ping && ./_build/default/rel/miner/bin/miner restart || ./_build/default/rel/miner/bin/miner start

stopdevrel:
	./_build/default/rel/miner/bin/miner stop
