APP_NAME    = Heed
BUILD_DIR   = build
APP_BUNDLE  = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS    = $(APP_BUNDLE)/Contents

.PHONY: build clean install test

build:
	swift build -c release
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp .build/release/$(APP_NAME) $(CONTENTS)/MacOS/
	cp Resources/Info.plist $(CONTENTS)/
	codesign --force --sign - --entitlements Resources/Heed.entitlements $(APP_BUNDLE)

clean:
	swift package clean
	rm -rf $(BUILD_DIR)

test:
	swift run HeedTests

install: build
	rsync -a --delete $(APP_BUNDLE) /Applications/
