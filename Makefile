# Defaults to a user-local install so `make install` never needs sudo: /usr/local/bin is
# root-owned on a default macOS setup. Override with `make install PREFIX=/usr/local` if you
# want it system-wide.
PREFIX ?= $(HOME)/.local
# SwiftPM names the product after the target ("Spacelight"), but the installed command is
# lowercase, so these are deliberately two different names rather than one variable.
BUILT_BINARY := Spacelight
BINARY := spacelight
BUILD_DIR := .build/release

.PHONY: build test install uninstall clean run-agent

build:
	swift build -c release

test:
	swift test

install: build
	@mkdir -p $(PREFIX)/bin
	install -m 755 $(BUILD_DIR)/$(BUILT_BINARY) $(PREFIX)/bin/$(BINARY)
	codesign -s - -f $(PREFIX)/bin/$(BINARY)
	@echo "Installed to $(PREFIX)/bin/$(BINARY)"
	@echo "Bind it in ~/.aerospace.toml, e.g.:"
	@echo "  alt-space = 'exec-and-forget $(PREFIX)/bin/$(BINARY)'"

uninstall:
	$(PREFIX)/bin/$(BINARY) quit || true
	rm -f $(PREFIX)/bin/$(BINARY)

clean:
	swift package clean
	rm -rf .build

run-agent: build
	$(BUILD_DIR)/$(BUILT_BINARY) --agent
