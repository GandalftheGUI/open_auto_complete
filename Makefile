APP_NAME      := OpenScribe
BUNDLE_ID     := com.opensource.openscribe
BUILD_DIR     := .build/release
APP_BUNDLE    := $(BUILD_DIR)/$(APP_NAME).app
PROBE_BIN     := $(BUILD_DIR)/AXProbe

.PHONY: all build bundle run probe run-probe clean

all: bundle

build:
	swift build -c release

bundle: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BUILD_DIR)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp Resources/OpenScribe-Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@codesign --force --deep --sign - --identifier $(BUNDLE_ID) "$(APP_BUNDLE)"
	@echo "✓ Built $(APP_BUNDLE)"

run: bundle
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	@echo ""
	@echo "First launch will trigger Accessibility + Input Monitoring prompts."
	@echo "Grant both in System Settings → Privacy & Security, then re-run 'make run'."
	@echo ""
	@open "$(APP_BUNDLE)"
	@echo "Log file: ~/Library/Logs/OpenScribe/openscribe.log"
	@echo "Tail it:  tail -f ~/Library/Logs/OpenScribe/openscribe.log"

probe:
	swift build -c release --product AXProbe
	@codesign --force --sign - --identifier com.opensource.axprobe $(PROBE_BIN)
	@echo "✓ Built $(PROBE_BIN)"

run-probe: probe
	@$(PROBE_BIN)

clean:
	rm -rf .build
