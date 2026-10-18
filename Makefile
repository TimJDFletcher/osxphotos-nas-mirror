.PHONY: help test lint install check

LABEL := io.github.timjdfletcher.osxphotos-nas-mirror
TEMPLATE := launchd/$(LABEL).plist.template
AGENTS_DIR := $(HOME)/Library/LaunchAgents

# FILL: print the template with @REPO@ and @HOME@ filled in. The paths go in
# through the environment, not the command line, and each is escaped twice:
# for XML (& < >), then for sed's replacement (\ & and the | delimiter).
export MIRROR_REPO := $(CURDIR)
export MIRROR_HOME := $(HOME)
FILL = esc() { printf '%s' "$$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/[\\&|]/\\&/g'; }; \
	sed -e "s|@REPO@|$$(esc "$$MIRROR_REPO")|g" -e "s|@HOME@|$$(esc "$$MIRROR_HOME")|g" $(TEMPLATE)

help: ## List targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/'

test: lint ## shellcheck, plutil and jq, then the fixture tests for osxphotos-nas-mirror.sh, the preflight checks and make install
	tests/mirror-run.sh
	tests/preflight-checks.sh
	tests/install.sh

lint: ## shellcheck the scripts, plutil the launchd agent (a filled-in copy of the template), jq the example dashboard
	shellcheck -x osxphotos-nas-mirror.sh tests/*.sh preflight-checks/*.sh
	jq -e -f tests/grafana-dashboard.jq examples/grafana-dashboard.json > /dev/null
	@tmp=$$(mktemp) && \
	$(FILL) > "$$tmp" && \
	plutil -lint "$$tmp"; rc=$$?; rm -f "$$tmp"; exit $$rc

install: ## Fill in the launchd agent template and copy it to ~/Library/LaunchAgents
	mkdir -p "$(AGENTS_DIR)"
	$(FILL) > "$(AGENTS_DIR)/$(LABEL).plist"
	@echo "Installed $(AGENTS_DIR)/$(LABEL).plist. To start it:"
	@echo "  launchctl load \"$(AGENTS_DIR)/$(LABEL).plist\""

check: test ## Same as test
