# Non-Nix build/install (the Nix flake is the primary path). `make` bakes the
# current commit into the binary so the in-app update check works off-NixOS too;
# without a baked rev the check stays disabled.
PREFIX ?= $(HOME)/.local
REV := $(shell git rev-parse HEAD 2>/dev/null)

build:
	go build -ldflags "-s -w -X main.gitRev=$(REV)" -o slqs .

install: build
	install -Dm755 slqs $(PREFIX)/bin/slqs
	mkdir -p $(PREFIX)/share/slqs
	cp -r ui $(PREFIX)/share/slqs/ui
	install -Dm755 media-viewer.sh $(PREFIX)/share/slqs/media-viewer.sh
	@echo "installed → $(PREFIX). run the daemon: slqs   ·   open the UI: qs -p $(PREFIX)/share/slqs/ui"
	@echo "set SLK_UPDATE_CMD to your apply step for the in-app 'U' keybind."

.PHONY: build install
