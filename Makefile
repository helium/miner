.PHONY: compile test typecheck

REBAR=./rebar3

compile:
	$(REBAR) compile

clean:
	$(REBAR) clean

test: compile
	$(REBAR) as test do eunit, ct, xref, dialyzer

typecheck:
	$(REBAR) dialyzer
