.PHONY: help test lint app package install check

LABEL := io.github.timjdfletcher.osxphotos-nas-mirror
TEMPLATE := launchd/$(LABEL).plist.template
AGENTS_DIR := $(HOME)/Library/LaunchAgents
APP := build/osxphotos-nas-mirror.app

# FILL: print the template with @HOME@ filled in. The path goes in through the
# environment, not the command line, and is escaped twice: for XML (& < >),
# then for sed's replacement (\ & and the | delimiter).
export MIRROR_HOME := $(HOME)
FILL = esc() { printf '%s' "$$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/[\\&|]/\\&/g'; }; \
	sed -e "s|@HOME@|$$(esc "$$MIRROR_HOME")|g" $(TEMPLATE)

help: ## List targets
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/'

test: lint ## shellcheck, plutil and jq, then the fixture tests for osxphotos-nas-mirror.sh, the preflight checks and make install
	tests/mirror-run.sh
	tests/preflight-checks.sh
	tests/install.sh

lint: ## shellcheck the scripts, plutil the launchd agent (a filled-in copy of the template), jq the example dashboard
	shellcheck -x osxphotos-nas-mirror.sh launchd/build-app.sh tests/*.sh preflight-checks/*.sh
	tests/grafana-dashboard.sh
	@tmp=$$(mktemp) && \
	$(FILL) > "$$tmp" && \
	plutil -lint "$$tmp"; rc=$$?; rm -f "$$tmp"; exit $$rc

app: ## Build the self-contained app in build/ (needs uv and SIGN_IDENTITY's key)
	launchd/build-app.sh "$(APP)"

package: app ## Zip the app for release
	ditto -c -k --keepParent "$(APP)" build/osxphotos-nas-mirror.zip

install: ## Copy APP (default the one make app built) to ~/Applications and install the launchd agent
	test -d "$(APP)" || { echo "No $(APP). Run make app, or set APP." >&2; exit 1; }
	mkdir -p "$(AGENTS_DIR)" "$(HOME)/Applications"
	rm -rf "$(HOME)/Applications/osxphotos-nas-mirror.app"
	ditto "$(APP)" "$(HOME)/Applications/osxphotos-nas-mirror.app"
	$(FILL) > "$(AGENTS_DIR)/$(LABEL).plist"
	@echo "Installed $(AGENTS_DIR)/$(LABEL).plist. To start it:"
	@echo "  launchctl load \"$(AGENTS_DIR)/$(LABEL).plist\""

check: test ## Same as test
