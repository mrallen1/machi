#  -------------------------------------------------------------------
#
#  Copyright (c) 2014 Basho Technologies, Inc.
#
#  This file is provided to you under the Apache License,
#  Version 2.0 (the "License"); you may not use this file
#  except in compliance with the License.  You may obtain
#  a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing,
#  software distributed under the License is distributed on an
#  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
#  KIND, either express or implied.  See the License for the
#  specific language governing permissions and limitations
#  under the License.
#
#  -------------------------------------------------------------------

#  -------------------------------------------------------------------
#  NOTE: This file is is from https://github.com/basho/tools.mk.
#  It should not be edited in a project. It should simply be updated
#  wholesale when a new version of tools.mk is released.
#  -------------------------------------------------------------------

REBAR ?= ./rebar
REVISION ?= $(shell git rev-parse --short HEAD)
PROJECT ?= $(shell basename `find src -name "*.app.src"` .app.src)

.PHONY: compile-no-deps test docs xref dialyzer-run dialyzer-quick dialyzer \
		cleanplt upload-docs

compile-no-deps:
	${REBAR} compile skip_deps=true

test: compile
	${REBAR} eunit skip_deps=true

upload-docs: docs
	@if [ -z "${BUCKET}" -o -z "${PROJECT}" -o -z "${REVISION}" ]; then \
		echo "Set BUCKET, PROJECT, and REVISION env vars to upload docs"; \
	        exit 1; fi
	@cd doc; s3cmd put -P * "s3://${BUCKET}/${PROJECT}/${REVISION}/" > /dev/null
	@echo "Docs built at: http://${BUCKET}.s3-website-us-east-1.amazonaws.com/${PROJECT}/${REVISION}"

docs:
	${REBAR} doc skip_deps=true

xref: compile
	${REBAR} xref skip_deps=true

PLT ?= $(HOME)/.combo_dialyzer_plt
LOCAL_PLT = .local_dialyzer_plt
DIALYZER_FLAGS ?= -Wunmatched_returns
NATIVE_EBIN ?= ./.ebin.native
DIALYZER_BIN ?= dialyzer
# Always include -pa arg in DIALYZER_CMD for speed
DIALYZER_CMD ?= $(DIALYZER_BIN) -pa $(NATIVE_EBIN)
DIALYZER_VERSION = $(shell $(DIALYZER_BIN) --version | sed 's/.* //')
ERL_LIB_DIR = $(shell erl -eval '{io:format("~s\n", [code:lib_dir()]), erlang:halt(0)}.' | tail -1)

native-ebin:
	mkdir -p $(NATIVE_EBIN)
	rm -f $(NATIVE_EBIN)/*.erl $(NATIVE_EBIN)/*.hrl $(NATIVE_EBIN)/*.beam
	cp $(ERL_LIB_DIR)/stdlib-*/src/{lists,dict,digraph,digraph_utils,ets,gb_sets,gb_trees,ordsets,sets,sofs}.erl $(NATIVE_EBIN)
	cp $(ERL_LIB_DIR)/compiler-*/src/{cerl,cerl_trees,core_parse}.?rl  $(NATIVE_EBIN)
	cp $(ERL_LIB_DIR)/dialyzer-*/src/{dialyzer_analysis_callgraph,dialyzer,dialyzer_behaviours,dialyzer_codeserver,dialyzer_contracts,dialyzer_coordinator,dialyzer_dataflow,dialyzer_dep,dialyzer_plt,dialyzer_succ_typings,dialyzer_typesig,dialyzer_worker}.?rl  $(NATIVE_EBIN)
	cp $(ERL_LIB_DIR)/hipe-*/*/{erl_types,erl_bif_types}.?rl  $(NATIVE_EBIN)
	erlc -o $(NATIVE_EBIN) -smp +native -DVSN='"$(DIALYZER_VERSION)"' $(NATIVE_EBIN)/*erl

${PLT}: compile
	@mkdir -p $(NATIVE_EBIN)
	@if [ -f $(PLT) ]; then \
		$(DIALYZER_CMD) --check_plt --plt $(PLT) --apps $(DIALYZER_APPS) && \
		$(DIALYZER_CMD) --add_to_plt --plt $(PLT) --output_plt $(PLT) --apps $(DIALYZER_APPS) ; test $$? -ne 1; \
	else \
		$(DIALYZER_CMD) --build_plt --output_plt $(PLT) --apps $(DIALYZER_APPS); test $$? -ne 1; \
	fi

${LOCAL_PLT}: compile
	@mkdir -p $(NATIVE_EBIN)
	@if [ -d deps ]; then \
		if [ -f $(LOCAL_PLT) ]; then \
			$(DIALYZER_CMD) --check_plt --plt $(LOCAL_PLT) deps/*/ebin  && \
			$(DIALYZER_CMD) --add_to_plt --plt $(LOCAL_PLT) --output_plt $(LOCAL_PLT) deps/*/ebin ; test $$? -ne 1; \
		else \
			$(DIALYZER_CMD) --build_plt --output_plt $(LOCAL_PLT) deps/*/ebin ; test $$? -ne 1; \
		fi \
	fi

dialyzer-run:
	@mkdir -p $(NATIVE_EBIN)
	@echo "==> $(shell basename $(shell pwd)) (dialyzer)"
# The bulk of the code below deals with the dialyzer.ignore-warnings file
# which contains strings to ignore if output by dialyzer.
# Typically the strings include line numbers. Using them exactly is hard
# to maintain as the code changes. This approach instead ignores the line
# numbers, but takes into account the number of times a string is listed
# for a given file. So if one string is listed once, for example, and it
# appears twice in the warnings, the user is alerted. It is possible but
# unlikely that this approach could mask a warning if one ignored warning
# is removed and two warnings of the same kind appear in the file, for
# example. But it is a trade-off that seems worth it.
# Details of the cryptic commands:
#   - Remove line numbers from dialyzer.ignore-warnings
#   - Pre-pend duplicate count to each warning with sort | uniq -c
#   - Remove annoying white space around duplicate count
#   - Save in dialyer.ignore-warnings.tmp
#   - Do the same to dialyzer_warnings
#   - Remove matches from dialyzer.ignore-warnings.tmp from output
#   - Remove duplicate count
#   - Escape regex special chars to use lines as regex patterns
#   - Add pattern to match any line number (file.erl:\d+:)
#   - Anchor to match the entire line (^entire line$)
#   - Save in dialyzer_unhandled_warnings
#   - Output matches for those patterns found in the original warnings
	@if [ -f $(LOCAL_PLT) ]; then \
		PLTS="$(PLT) $(LOCAL_PLT)"; \
	else \
		PLTS=$(PLT); \
	fi; \
	if [ -f dialyzer.ignore-warnings ]; then \
		if [ $$(grep -cvE '[^[:space:]]' dialyzer.ignore-warnings) -ne 0 ]; then \
			echo "ERROR: dialyzer.ignore-warnings contains a blank/empty line, this will match all messages!"; \
			exit 1; \
		fi; \
		$(DIALYZER_CMD) $(DIALYZER_FLAGS) --plts $${PLTS} -c ebin > dialyzer_warnings ; \
		cat dialyzer.ignore-warnings \
		| sed -E 's/^([^:]+:)[^:]+:/\1/' \
		| sort \
		| uniq -c \
		| sed -E '/.*\.erl: /!s/^[[:space:]]*[0-9]+[[:space:]]*//' \
		> dialyzer.ignore-warnings.tmp ; \
		egrep -v "^[[:space:]]*(done|Checking|Proceeding|Compiling)" dialyzer_warnings \
		| sed -E 's/^([^:]+:)[^:]+:/\1/' \
		| sort \
		| uniq -c \
		| sed -E '/.*\.erl: /!s/^[[:space:]]*[0-9]+[[:space:]]*//' \
		| grep -F -f dialyzer.ignore-warnings.tmp -v \
		| sed -E 's/^[[:space:]]*[0-9]+[[:space:]]*//' \
		| sed -E 's/([]\^:+?|()*.$${}\[])/\\\1/g' \
		| sed -E 's/(\\\.erl\\\:)/\1[[:digit:]]+:/g' \
		| sed -E 's/^(.*)$$/^[[:space:]]*\1$$/g' \
		> dialyzer_unhandled_warnings ; \
		rm dialyzer.ignore-warnings.tmp; \
		if [ $$(cat dialyzer_unhandled_warnings | egrep -v 'Unknown functions\\:' | wc -l) -gt 0 ]; then \
		    egrep -f dialyzer_unhandled_warnings dialyzer_warnings ; \
			found_warnings=1; \
	    fi; \
		[ "$$found_warnings" != 1 ] ; \
	else \
		$(DIALYZER_CMD) $(DIALYZER_FLAGS) --plts $${PLTS} -c ebin; \
	fi

dialyzer-quick: compile-no-deps dialyzer-run

dialyzer: ${PLT} ${LOCAL_PLT} dialyzer-run

cleanplt:
	@echo
	@echo "Are you sure?  It takes several minutes to re-build."
	@echo Deleting $(PLT) and $(LOCAL_PLT) in 5 seconds.
	@echo
	sleep 5
	rm $(PLT)
	rm $(LOCAL_PLT)