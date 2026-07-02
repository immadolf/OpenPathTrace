APP := OpenPathTrace
APP_DIR := .build/$(APP).app

.PHONY: build check app run

build:
	swift build

check:
	swift run OpenPathTraceCoreChecks

app:
	swift build
	mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources"
	cp ".build/debug/$(APP)" "$(APP_DIR)/Contents/MacOS/$(APP)"
	cp "Resources/Info.plist" "$(APP_DIR)/Contents/Info.plist"
	@echo "$(APP_DIR)"

run:
	swift run OpenPathTrace
