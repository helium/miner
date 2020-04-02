.PHONY: deps compile test typecheck cover

REBAR=./rebar3

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
	$(REBAR) do dialyzer,xref && $(REBAR) do eunit,ct

release:
	$(REBAR) as prod release -n miner

cover:
	$(REBAR) cover

aws:
	$(REBAR) as aws release

seed:
	$(REBAR) as seed release

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

startdevrel:
	./_build/default/rel/miner/bin/miner ping && ./_build/default/rel/miner/bin/miner restart || ./_build/default/rel/miner/bin/miner start

stopdevrel:
	./_build/default/rel/miner/bin/miner stop
