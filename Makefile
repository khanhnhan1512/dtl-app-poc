.PHONY: release check-secrets

# Builds the macOS universal .dmg for the tag being released and uploads it to GitLab's
# generic package registry
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
	DMG_LINK_NAME="dtl-app-$(VERSION)-universal.dmg"; \
	DMG_LINK_URL="$(CI_API_V4_URL)/projects/$(CI_PROJECT_ID)/packages/generic/dtl-app/$(VERSION)/$$DMG_LINK_NAME"; \
	$(MAKE) check-secrets DMG_PATH="$$DMG_PATH" && \
	curl --fail --silent --show-error \
		--header "JOB-TOKEN: $(CI_JOB_TOKEN)" \
		--upload-file "$$DMG_PATH" \
		"$$DMG_LINK_URL" && \
	echo "release: uploaded $$DMG_LINK_NAME to the package registry" && \
	RELEASE_TAG="$(CI_COMMIT_TAG)" RELEASE_VERSION="$(VERSION)" RELEASE_LINK_NAME="$$DMG_LINK_NAME" RELEASE_LINK_URL="$$DMG_LINK_URL" \
		node -e "const fs=require('fs'); const e=process.env; const payload={tag_name:e.RELEASE_TAG,name:'DTL App '+e.RELEASE_VERSION,assets:{links:[{name:e.RELEASE_LINK_NAME,url:e.RELEASE_LINK_URL,link_type:'package'}]}}; fs.writeFileSync('/tmp/dtl-release-payload.json', JSON.stringify(payload));" && \
	RELEASE_STATUS=$$(curl --silent --show-error -o /tmp/dtl-release-response.json -w '%{http_code}' \
		--header "JOB-TOKEN: $(CI_JOB_TOKEN)" \
		--header "Content-Type: application/json" \
		--data @/tmp/dtl-release-payload.json \
		"$(CI_API_V4_URL)/projects/$(CI_PROJECT_ID)/releases"); \
	if [ "$$RELEASE_STATUS" = "201" ]; then \
		echo "release: created the GitLab release for $(CI_COMMIT_TAG), with $$DMG_LINK_NAME attached"; \
	elif [ "$$RELEASE_STATUS" = "409" ]; then \
		echo "release: a GitLab release for $(CI_COMMIT_TAG) already exists (rerun of this tag) - checking whether $$DMG_LINK_NAME is already attached"; \
		LINKS_STATUS=$$(curl --silent --show-error -o /tmp/dtl-release-links.json -w '%{http_code}' \
			--header "JOB-TOKEN: $(CI_JOB_TOKEN)" \
			"$(CI_API_V4_URL)/projects/$(CI_PROJECT_ID)/releases/$(CI_COMMIT_TAG)/assets/links"); \
		if [ "$$LINKS_STATUS" != "200" ]; then \
			echo "release: FAILED - could not list existing assets for the release $(CI_COMMIT_TAG) (HTTP $$LINKS_STATUS)"; \
			cat /tmp/dtl-release-links.json; \
			exit 1; \
		fi; \
		if RELEASE_LINK_URL="$$DMG_LINK_URL" node -e "const fs=require('fs'); const links=JSON.parse(fs.readFileSync('/tmp/dtl-release-links.json','utf8')); process.exit(links.some(l => l.url === process.env.RELEASE_LINK_URL) ? 0 : 1);"; then \
			echo "release: $$DMG_LINK_NAME is already attached to the release for $(CI_COMMIT_TAG), nothing to do"; \
		else \
			RELEASE_LINK_NAME="$$DMG_LINK_NAME" RELEASE_LINK_URL="$$DMG_LINK_URL" \
				node -e "const fs=require('fs'); const e=process.env; fs.writeFileSync('/tmp/dtl-release-link-payload.json', JSON.stringify({name:e.RELEASE_LINK_NAME,url:e.RELEASE_LINK_URL,link_type:'package'}));" && \
			LINK_STATUS=$$(curl --silent --show-error -o /tmp/dtl-release-link-response.json -w '%{http_code}' \
				--header "JOB-TOKEN: $(CI_JOB_TOKEN)" \
				--header "Content-Type: application/json" \
				--data @/tmp/dtl-release-link-payload.json \
				"$(CI_API_V4_URL)/projects/$(CI_PROJECT_ID)/releases/$(CI_COMMIT_TAG)/assets/links"); \
			if [ "$$LINK_STATUS" != "201" ]; then \
				echo "release: FAILED - the release for $(CI_COMMIT_TAG) already existed, and attaching $$DMG_LINK_NAME to it also failed (HTTP $$LINK_STATUS)"; \
				cat /tmp/dtl-release-link-response.json; \
				exit 1; \
			fi; \
			echo "release: attached $$DMG_LINK_NAME to the existing release"; \
		fi; \
	else \
		echo "release: FAILED - creating the GitLab release for $(CI_COMMIT_TAG) returned HTTP $$RELEASE_STATUS"; \
		cat /tmp/dtl-release-response.json; \
		exit 1; \
	fi

# Guards against shipping lab secrets (test certificates, private keys, kill-switch signing
# material) inside the packaged .dmg.
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
