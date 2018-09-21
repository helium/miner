.PHONY: compile test typecheck cover

REBAR=./rebar3

compile:
	$(REBAR) compile

clean:
	$(REBAR) clean

test: compile
	$(REBAR) as test do eunit, ct --verbose

typecheck:
	$(REBAR) dialyzer, xref

release:
	$(REBAR) as prod release -n miner

cover:
	$(REBAR) cover

devrelease:
	$(REBAR) as dev release -n miner-dev

devrel:
	$(REBAR) as dev release -n miner-dev1
	$(REBAR) as dev release -n miner-dev2
	$(REBAR) as dev release -n miner-dev3
	$(REBAR) as dev release -n miner-dev4
	$(REBAR) as dev release -n miner-dev5
	$(REBAR) as dev release -n miner-dev6
	$(REBAR) as dev release -n miner-dev7
	$(REBAR) as dev release -n miner-dev8

startdevrel:
	./_build/default/rel/miner-dev/bin/miner-dev ping && ./_build/default/rel/miner-dev/bin/miner-dev restart || ./_build/default/rel/miner-dev/bin/miner-dev start

stopdevrel:
	./_build/default/rel/miner-dev/bin/miner-dev stop
