APP_NAME      := OpenAutoComplete
BUNDLE_ID     := com.opensource.openautocomplete
BUILD_DIR     := .build/release
APP_BUNDLE    := $(BUILD_DIR)/$(APP_NAME).app
PROBE_BIN     := $(BUILD_DIR)/AXProbe

# xcodebuild (rather than `swift build`) because SPM on the command line can't
# compile Metal shader sources, which mlx-swift needs at runtime. xcodebuild uses
# Xcode's build system, which does compile .metal → .metallib properly.
XCODE_DERIVED := .build-xcode
XCODE_PRODUCT := $(XCODE_DERIVED)/Build/Products/Release/$(APP_NAME)

.PHONY: all build bundle run probe run-probe clean

all: bundle

build:
	xcodebuild -scheme $(APP_NAME) -configuration Release \
		-derivedDataPath $(XCODE_DERIVED) \
		-destination 'platform=macOS' \
		-skipMacroValidation \
		build 2>&1 | grep -E "error:|warning:|ld:|\*\*" | head -40 || true

bundle: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(XCODE_PRODUCT)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@# Copy every resource bundle Xcode produced next to the binary — MLX's
	@# metallib lives inside mlx-swift_Cmlx.bundle, and MLXLLM/MLXLMCommon each
	@# bring their own tokenizer/chat-template bundles.
	@cp -R "$(XCODE_DERIVED)/Build/Products/Release/"*.bundle "$(APP_BUNDLE)/Contents/Resources/" 2>/dev/null || true
	@cp Resources/OpenAutoComplete-Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@codesign --force --deep --sign - --identifier $(BUNDLE_ID) "$(APP_BUNDLE)"
	@echo "✓ Built $(APP_BUNDLE)"

run: bundle
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	@echo ""
	@echo "First launch will trigger Accessibility + Input Monitoring prompts."
	@echo "Grant both in System Settings → Privacy & Security, then re-run 'make run'."
	@echo ""
	@open "$(APP_BUNDLE)"
	@echo "Log file: ~/Library/Logs/OpenAutoComplete/openautocomplete.log"
	@echo "Tail it:  tail -f ~/Library/Logs/OpenAutoComplete/openautocomplete.log"

# Foreground run: useful for seeing any crash output / stderr that the bundle swallows.
run-fg: bundle
	@pkill -x "$(APP_NAME)" 2>/dev/null || true
	"$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"

probe:
	swift build -c release --product AXProbe
	@codesign --force --sign - --identifier com.opensource.axprobe $(PROBE_BIN)
	@echo "✓ Built $(PROBE_BIN)"

run-probe: probe
	@$(PROBE_BIN)

clean:
	rm -rf .build
