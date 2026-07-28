.PHONY: test release check-secrets

test:
	@echo "No tests defined yet."

# Builds the macOS universal .dmg for the tag being released and uploads it to GitLab's
# generic package registry, under the same package (dtl-app) the .deb already uses.
# Only meant to run inside a GitLab CI tag pipeline: it relies on CI_COMMIT_TAG, CI_JOB_TOKEN,
# CI_API_V4_URL and CI_PROJECT_ID, which GitLab sets automatically on every job and are not
# something to configure by hand.
release:
	@if [ -z "$(CI_COMMIT_TAG)" ]; then \
		echo "release: CI_COMMIT_TAG is not set - this only runs in a GitLab tag pipeline, refusing to build a versionless artifact"; \
		exit 1; \
	fi
	$(eval VERSION := $(patsubst v%,%,$(CI_COMMIT_TAG)))
	@echo "release: building version $(VERSION) from tag $(CI_COMMIT_TAG)"
	node -e "const fs=require('fs'); const p=JSON.parse(fs.readFileSync('package.json','utf8')); p.version='$(VERSION)'; fs.writeFileSync('package.json', JSON.stringify(p, null, 2) + '\n');"
	npm ci
	rm -rf dist
	npm run dist:dmg
	@DMG_COUNT=$$(ls dist/*.dmg 2>/dev/null | wc -l | tr -d ' '); \
	if [ "$$DMG_COUNT" != "1" ]; then \
		echo "release: FAILED - expected exactly one .dmg in dist/, found $$DMG_COUNT"; \
		ls dist/*.dmg 2>/dev/null; \
		exit 1; \
	fi; \
	DMG_PATH=$$(ls dist/*.dmg); \
	echo "release: built $$DMG_PATH"; \
	$(MAKE) check-secrets DMG_PATH="$$DMG_PATH"; \
	curl --fail --silent --show-error \
		--header "JOB-TOKEN: $(CI_JOB_TOKEN)" \
		--upload-file "$$DMG_PATH" \
		"$(CI_API_V4_URL)/projects/$(CI_PROJECT_ID)/packages/generic/dtl-app/$(VERSION)/dtl-app-$(VERSION)-universal.dmg"
	@echo "release: uploaded dtl-app-$(VERSION)-universal.dmg"

# Guards against shipping lab secrets (test certificates, private keys, kill-switch signing
# material) inside the packaged .dmg. Mounts the disk image and inspects both the volume and
# the app's asar archive; fails the build if anything forbidden is found, or if the check
# itself couldn't actually run, so a leak - or a broken check - fails the pipeline instead of
# shipping silently.
check-secrets:
	@if [ -z "$(DMG_PATH)" ]; then \
		echo "check-secrets: DMG_PATH is not set"; \
		exit 1; \
	fi
	@echo "check-secrets: inspecting $(DMG_PATH)"
	@MOUNTPOINT=$$(hdiutil attach "$(DMG_PATH)" -nobrowse | grep "/Volumes" | awk -F"\t" '{print $$3}' | tail -1); \
	if [ -z "$$MOUNTPOINT" ]; then \
		echo "check-secrets: FAILED - hdiutil attach did not report a mount point"; \
		exit 1; \
	fi; \
	FOUND=$$(find "$$MOUNTPOINT" \( -path "*/lab/*" -o -name "*.key" -o -name "*.pem" -o -name "*.p12" -o -name "tokens.enc" -o -name "kill-signing*" -o -name "kill-command.json" \) 2>/dev/null); \
	if ! ASAR_LISTING=$$(npx asar list "$$MOUNTPOINT/DTL App.app/Contents/Resources/app.asar" 2>&1); then \
		echo "check-secrets: FAILED - could not read app.asar (missing app, wrong app name, or broken build)"; \
		echo "$$ASAR_LISTING"; \
		hdiutil detach "$$MOUNTPOINT" -quiet; \
		exit 1; \
	fi; \
	ASAR_HITS=$$(echo "$$ASAR_LISTING" | grep -iE "lab/|\.key$$|\.pem$$|\.p12$$|tokens\.enc|kill-signing|kill-command" || true); \
	hdiutil detach "$$MOUNTPOINT" -quiet; \
	if [ -n "$$FOUND" ] || [ -n "$$ASAR_HITS" ]; then \
		echo "check-secrets: FAILED - forbidden material found in the .dmg:"; \
		echo "$$FOUND"; \
		echo "$$ASAR_HITS"; \
		exit 1; \
	fi; \
	echo "check-secrets: clean, no lab or secret material found"
