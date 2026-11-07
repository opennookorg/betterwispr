SHELL := /bin/bash -o pipefail

APP_NAME     = BetterWispr
DERIVED_DIR  = .build
APP_DEBUG    = $(DERIVED_DIR)/debug/$(APP_NAME).app
APP_RELEASE  = $(DERIVED_DIR)/release/$(APP_NAME).app
VERSION     := $(shell tr -d '[:space:]' < VERSION)
DMG_NAME     = $(APP_NAME)-$(VERSION).dmg
DMG_DIR      = release
MODEL       ?= parakeet-v3
CLI          = $(DERIVED_DIR)/debug/BetterWisprCLI
NO_NET       = sandbox-exec -p '(version 1) (allow default) (deny network*)'
SAMPLES      = $(DERIVED_DIR)/samples

.PHONY: build release run dev clean lint test offline-test dmg version setup-notary ship help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

dev: test run ## Local testing: build, run all checks, then launch the debug app

setup-notary: ## Save BetterWispr notarization credentials in Keychain (once)
	@bash scripts/release.sh --setup-notary

ship: ## Build, sign, notarize and staple separate Apple Silicon and Intel DMGs
	@bash scripts/release.sh

build: ## Debug app bundle
	@echo "==> Building $(APP_NAME) (Debug)..."
	@./scripts/build-app.sh debug | tail -1

release: ## Release app bundle for this Mac
	@echo "==> Building $(APP_NAME) (Release)..."
	@./scripts/build-app.sh release | tail -1

run: build ## Build and launch (debug)
	@echo "==> Launching $(APP_NAME)..."
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 1
	@open -n "$(abspath $(APP_DEBUG))"

test: ## Unit tests, evaluator and release script checks
	@python3 scripts/localization.py check
	@python3 Tests/localization_tools_check.py
	@swift build 2>&1 | tail -1
	@swift test 2>&1 | tail -1
	@python3 Tests/evaluate_check.py
	@python3 Tests/release_check.py

lint: ## Check for compiler warnings
	@echo "==> Checking for warnings..."
	@swift build 2>&1 | grep -E "warning:|error:" || echo "No warnings."

offline-test: ## Download MODEL, then transcribe speech and silence with networking denied
	@swift build --product BetterWisprCLI 2>&1 | tail -1
	@$(CLI) --download-model $(MODEL)
	@mkdir -p $(SAMPLES)
	@test -f $(SAMPLES)/jfk.wav || curl -fsSL https://raw.githubusercontent.com/ggml-org/whisper.cpp/master/samples/jfk.wav -o $(SAMPLES)/jfk.wav
	@python3 -c 'import wave; w=wave.open("$(SAMPLES)/silence.wav","wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(bytes(64000)); w.close()'
	@echo "==> Speech ($(MODEL), offline)"
	@$(NO_NET) $(CLI) --transcribe-file $(SAMPLES)/jfk.wav --model $(MODEL) --language en
	@echo "==> Silence ($(MODEL), offline)"
	@$(NO_NET) $(CLI) --transcribe-file $(SAMPLES)/silence.wav --model $(MODEL) --language en

dmg: release ## Create unsigned DMG for local testing
	@bash scripts/create-dmg.sh "$(APP_RELEASE)" "$(DMG_DIR)/$(DMG_NAME)"

clean: ## Remove build artifacts
	@echo "==> Cleaning..."
	@swift package clean
	@rm -rf $(APP_DEBUG) $(APP_RELEASE) $(SAMPLES) $(DMG_DIR)
	@echo "==> Clean."

version: ## Print current version
	@echo "$(VERSION)"
