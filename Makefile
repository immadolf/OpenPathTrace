APP := OpenPathTrace
APP_DIR := .build/$(APP).app
INSTALL_PATH := /Applications/$(APP).app
SIGN_IDENTITY ?=

.PHONY: build release check app signed-app install create-signing-identity verify-installed run

build:
	swift build

release:
	swift build -c release

check:
	swift run OpenPathTraceCoreChecks

app:
	swift build
	./scripts/build-app.sh debug "$(APP_DIR)"
	@echo "$(APP_DIR)"

signed-app:
	swift build -c release
	./scripts/build-app.sh release "$(APP_DIR)"
	./scripts/sign-app.sh "$(APP_DIR)" "$(SIGN_IDENTITY)"
	@echo "$(APP_DIR)"

install:
	./scripts/install.sh "$(SIGN_IDENTITY)"

create-signing-identity:
	./scripts/create-signing-identity.sh

verify-installed:
	./scripts/verify-installed.sh "$(INSTALL_PATH)"

run:
	swift run OpenPathTrace
