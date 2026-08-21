APP      = Folio
CONFIG  ?= debug
BUILDDIR = .build/$(CONFIG)
BUNDLE   = build/$(APP).app
BIN      = $(BUILDDIR)/$(APP)
.PHONY: all build app run test dump snapshot clean

all: app

build:
	swift build -c $(CONFIG)

test:
	swift test

app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Support/Info.plist $(BUNDLE)/Contents/Info.plist
	@for b in $(BUILDDIR)/*.bundle; do \
		[ -d "$$b" ] && cp -R "$$b" $(BUNDLE)/Contents/Resources/ || true; \
	done
	codesign --force --sign - $(BUNDLE)
	@echo "Built $(BUNDLE)"

run: app
	open $(BUNDLE)

# Deterministic structural dump of every sample document — the primary regression check.
# Cheaper than pixel diffing and free of pixel noise. `find -print0` because sample filenames
# contain spaces, which plain word-splitting mangles.
dump: build
	@mkdir -p build/dumps
	@find sample-vault -name '*.md' -print0 | while IFS= read -r -d '' f; do \
		out="build/dumps/$$(basename "$$f" .md).txt"; \
		$(BIN) --render-txt "$$f" > "$$out" && echo "  $$out"; \
	done

# PNG snapshots of the reading pane, for eyeballing.
snapshot: build
	@mkdir -p build/snapshots
	@find sample-vault -name '*.md' -print0 | while IFS= read -r -d '' f; do \
		base="build/snapshots/$$(basename "$$f" .md)"; \
		$(BIN) --render-png "$$f" "$$base.png" --width 900 && echo "  $$base.png"; \
	done

clean:
	rm -rf .build build
