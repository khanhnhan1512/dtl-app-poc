.PHONY: prepare release-macos release-linux publish check-secrets-macos check-secrets-linux

VERSION := $(patsubst v%,%,$(CI_COMMIT_TAG))

# Shared setup for both platforms: guard on tag pipeline, set the version, install dependencies.
prepare:
	@if [ -z "$(CI_COMMIT_TAG)" ]; then \
		echo "prepare: CI_COMMIT_TAG is not set - this only runs in a GitLab tag pipeline, refusing to build a versionless artifact"; \
		exit 1; \
	fi
	@echo "prepare: building version $(VERSION) from tag $(CI_COMMIT_TAG)"
	node -e "const fs=require('fs'); const p=JSON.parse(fs.readFileSync('package.json','utf8')); p.version='$(VERSION)'; fs.writeFileSync('package.json', JSON.stringify(p, null, 2) + '\n');"
	npm ci

# Builds the macOS universal .dmg for the tag being released and publishes it.
release-macos: prepare
	rm -rf dist
	npm run dist:dmg
	@DMG_COUNT=$$(ls dist/*.dmg 2>/dev/null | wc -l | tr -d ' '); \
	if [ "$$DMG_COUNT" != "1" ]; then \
		echo "release-macos: FAILED - expected exactly one .dmg in dist/, found $$DMG_COUNT"; \
		ls dist/*.dmg 2>/dev/null; \
		exit 1; \
	fi; \
	ARTIFACT_PATH=$$(ls dist/*.dmg); \
	LINK_NAME="dtl-app-$(VERSION)-universal.dmg"; \
	echo "release-macos: built $$ARTIFACT_PATH, publishing as $$LINK_NAME"; \
	$(MAKE) check-secrets-macos ARTIFACT_PATH="$$ARTIFACT_PATH" && \
	$(MAKE) publish ARTIFACT_PATH="$$ARTIFACT_PATH" LINK_NAME="$$LINK_NAME"

# Builds the Linux .deb for the tag being released and publishes it.
release-linux: prepare
	npm run dist:deb
	@DEB_COUNT=$$(ls dist/*.deb 2>/dev/null | wc -l | tr -d ' '); \
	if [ "$$DEB_COUNT" != "1" ]; then \
		echo "release-linux: FAILED - expected exactly one .deb in dist/, found $$DEB_COUNT"; \
		ls dist/*.deb 2>/dev/null; \
		exit 1; \
	fi; \
	ARTIFACT_PATH=$$(ls dist/*.deb); \
	LINK_NAME="dtl-app_$(VERSION)_amd64.deb"; \
	echo "release-linux: built $$ARTIFACT_PATH, publishing as $$LINK_NAME"; \
	$(MAKE) check-secrets-linux ARTIFACT_PATH="$$ARTIFACT_PATH" && \
	$(MAKE) publish ARTIFACT_PATH="$$ARTIFACT_PATH" LINK_NAME="$$LINK_NAME"

# Uploads the artifact and creates the GitLab release for the tag
publish:
	@if [ -z "$(ARTIFACT_PATH)" ] || [ -z "$(LINK_NAME)" ]; then \
		echo "publish: ARTIFACT_PATH and LINK_NAME must both be set"; \
		exit 1; \
	fi
	@LINK_URL="$(CI_API_V4_URL)/projects/$(CI_PROJECT_ID)/packages/generic/dtl-app/$(VERSION)/$(LINK_NAME)"; \
	curl --fail --silent --show-error \
		--header "JOB-TOKEN: $(CI_JOB_TOKEN)" \
		--upload-file "$(ARTIFACT_PATH)" \
		"$$LINK_URL" && \
	echo "publish: uploaded $(LINK_NAME) to the package registry" && \
	RELEASE_TAG="$(CI_COMMIT_TAG)" RELEASE_VERSION="$(VERSION)" \
		RELEASE_LINK_NAME="$(LINK_NAME)" RELEASE_LINK_URL="$$LINK_URL" \
		node -e "const fs=require('fs'); const e=process.env; const payload={tag_name:e.RELEASE_TAG,name:'DTL App '+e.RELEASE_VERSION,assets:{links:[{name:e.RELEASE_LINK_NAME,url:e.RELEASE_LINK_URL,link_type:'package'}]}}; fs.writeFileSync('/tmp/dtl-release-payload.json', JSON.stringify(payload));" && \
	RELEASE_STATUS=$$(curl --silent --show-error -o /tmp/dtl-release-response.json -w '%{http_code}' \
		--header "JOB-TOKEN: $(CI_JOB_TOKEN)" \
		--header "Content-Type: application/json" \
		--data @/tmp/dtl-release-payload.json \
		"$(CI_API_V4_URL)/projects/$(CI_PROJECT_ID)/releases"); \
	if [ "$$RELEASE_STATUS" = "201" ]; then \
		echo "publish: created the GitLab release for $(CI_COMMIT_TAG), with $(LINK_NAME) attached"; \
	elif [ "$$RELEASE_STATUS" = "409" ]; then \
		echo "publish: a GitLab release for $(CI_COMMIT_TAG) already exists - checking whether $(LINK_NAME) is already attached"; \
		LINKS_STATUS=$$(curl --silent --show-error -o /tmp/dtl-release-links.json -w '%{http_code}' \
			--header "JOB-TOKEN: $(CI_JOB_TOKEN)" \
			"$(CI_API_V4_URL)/projects/$(CI_PROJECT_ID)/releases/$(CI_COMMIT_TAG)/assets/links"); \
		if [ "$$LINKS_STATUS" != "200" ]; then \
			echo "publish: FAILED - could not list existing assets for the release $(CI_COMMIT_TAG) (HTTP $$LINKS_STATUS)"; \
			cat /tmp/dtl-release-links.json; \
			exit 1; \
		fi; \
		if RELEASE_LINK_URL="$$LINK_URL" node -e "const fs=require('fs'); const links=JSON.parse(fs.readFileSync('/tmp/dtl-release-links.json','utf8')); process.exit(links.some(l => l.url === process.env.RELEASE_LINK_URL) ? 0 : 1);"; then \
			echo "publish: $(LINK_NAME) is already attached to the release for $(CI_COMMIT_TAG), nothing to do"; \
		else \
			RELEASE_LINK_NAME="$(LINK_NAME)" RELEASE_LINK_URL="$$LINK_URL" \
				node -e "const fs=require('fs'); const e=process.env; fs.writeFileSync('/tmp/dtl-release-link-payload.json', JSON.stringify({name:e.RELEASE_LINK_NAME,url:e.RELEASE_LINK_URL,link_type:'package'}));" && \
			LINK_STATUS=$$(curl --silent --show-error -o /tmp/dtl-release-link-response.json -w '%{http_code}' \
				--header "JOB-TOKEN: $(CI_JOB_TOKEN)" \
				--header "Content-Type: application/json" \
				--data @/tmp/dtl-release-link-payload.json \
				"$(CI_API_V4_URL)/projects/$(CI_PROJECT_ID)/releases/$(CI_COMMIT_TAG)/assets/links"); \
			if [ "$$LINK_STATUS" != "201" ]; then \
				echo "publish: FAILED - the release for $(CI_COMMIT_TAG) already existed, and attaching $(LINK_NAME) to it also failed (HTTP $$LINK_STATUS)"; \
				cat /tmp/dtl-release-link-response.json; \
				exit 1; \
			fi; \
			echo "publish: attached $(LINK_NAME) to the existing release"; \
		fi; \
	else \
		echo "publish: FAILED - creating the GitLab release for $(CI_COMMIT_TAG) returned HTTP $$RELEASE_STATUS"; \
		cat /tmp/dtl-release-response.json; \
		exit 1; \
	fi

# Guards against shipping lab secrets inside the packaged .dmg.
check-secrets-macos:
	@if [ -z "$(ARTIFACT_PATH)" ]; then \
		echo "check-secrets-macos: ARTIFACT_PATH is not set"; \
		exit 1; \
	fi
	@echo "check-secrets-macos: inspecting $(ARTIFACT_PATH)"
	@MOUNTPOINT=$$(hdiutil attach "$(ARTIFACT_PATH)" -nobrowse | grep "/Volumes" | awk -F"\t" '{print $$3}' | tail -1); \
	if [ -z "$$MOUNTPOINT" ]; then \
		echo "check-secrets-macos: FAILED - hdiutil attach did not report a mount point"; \
		exit 1; \
	fi; \
	FOUND=$$(find "$$MOUNTPOINT" \( -path "*/lab/*" -o -name "*.key" -o -name "*.pem" -o -name "*.p12" -o -name "tokens.enc" -o -name "kill-signing*" -o -name "kill-command.json" \) 2>/dev/null); \
	if ! ASAR_LISTING=$$(npx asar list "$$MOUNTPOINT/DTL App.app/Contents/Resources/app.asar" 2>&1); then \
		echo "check-secrets-macos: FAILED - could not read app.asar (missing app, wrong app name, or broken build)"; \
		echo "$$ASAR_LISTING"; \
		hdiutil detach "$$MOUNTPOINT" -quiet; \
		exit 1; \
	fi; \
	ASAR_HITS=$$(echo "$$ASAR_LISTING" | grep -iE "lab/|\.key$$|\.pem$$|\.p12$$|tokens\.enc|kill-signing|kill-command" || true); \
	hdiutil detach "$$MOUNTPOINT" -quiet; \
	if [ -n "$$FOUND" ] || [ -n "$$ASAR_HITS" ]; then \
		echo "check-secrets-macos: FAILED - forbidden material found in the .dmg:"; \
		echo "$$FOUND"; \
		echo "$$ASAR_HITS"; \
		exit 1; \
	fi; \
	echo "check-secrets-macos: clean, no lab or secret material found"

# The .deb equivalent of check-secrets-macos.
check-secrets-linux:
	@if [ -z "$(ARTIFACT_PATH)" ]; then \
		echo "check-secrets-linux: ARTIFACT_PATH is not set"; \
		exit 1; \
	fi
	@echo "check-secrets-linux: inspecting $(ARTIFACT_PATH)"
	@FOUND=$$(dpkg-deb -c "$(ARTIFACT_PATH)" | grep -iE "lab/|\.key$$|\.pem$$|\.p12$$|tokens\.enc|kill-signing|kill-command\.json" || true); \
	dpkg-deb --fsys-tarfile "$(ARTIFACT_PATH)" > /tmp/dtl-check-secrets-linux-fsys.tar; \
	if ! tar -xOf /tmp/dtl-check-secrets-linux-fsys.tar "./opt/DTL App/resources/app.asar" \
			> /tmp/dtl-check-secrets-linux-app.asar 2>/tmp/dtl-check-secrets-linux-tar.err; then \
		echo "check-secrets-linux: FAILED - could not extract app.asar (missing member, wrong app name, or broken build)"; \
		cat /tmp/dtl-check-secrets-linux-tar.err; \
		rm -f /tmp/dtl-check-secrets-linux-fsys.tar /tmp/dtl-check-secrets-linux-app.asar; \
		exit 1; \
	fi; \
	rm -f /tmp/dtl-check-secrets-linux-fsys.tar; \
	if ! ASAR_LISTING=$$(npx asar list /tmp/dtl-check-secrets-linux-app.asar 2>&1); then \
		echo "check-secrets-linux: FAILED - could not read app.asar (broken build)"; \
		echo "$$ASAR_LISTING"; \
		rm -f /tmp/dtl-check-secrets-linux-app.asar; \
		exit 1; \
	fi; \
	rm -f /tmp/dtl-check-secrets-linux-app.asar; \
	ASAR_HITS=$$(echo "$$ASAR_LISTING" | grep -iE "lab/|\.key$$|\.pem$$|\.p12$$|tokens\.enc|kill-signing|kill-command" || true); \
	if [ -n "$$FOUND" ] || [ -n "$$ASAR_HITS" ]; then \
		echo "check-secrets-linux: FAILED - forbidden material found in the .deb:"; \
		echo "$$FOUND"; \
		echo "$$ASAR_HITS"; \
		exit 1; \
	fi; \
	echo "check-secrets-linux: clean, no lab or secret material found"
