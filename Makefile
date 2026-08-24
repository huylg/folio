APP      = Folio
CONFIG  ?= debug
BUILDDIR = .build/$(CONFIG)
BUNDLE   = build/$(APP).app
BIN      = $(BUILDDIR)/$(APP)
ICONSET  = build/$(APP).iconset
ICNS     = build/$(APP).icns
DMG      = build/$(APP).dmg
DMGROOT  = build/dmg
.PHONY: all build app icon dmg run test dump snapshot clean

all: app

build:
	swift build -c $(CONFIG)

test:
	swift test

# The icon is drawn by a script rather than checked in as a binary, so a change to it is a
# readable diff. Regenerated whenever the generator changes.
icon: $(ICNS)

$(ICNS): Tools/MakeAppIcon.swift
	@mkdir -p build
	@rm -rf $(ICONSET)
	swift Tools/MakeAppIcon.swift $(ICONSET)
	iconutil -c icns $(ICONSET) -o $(ICNS)
	@echo "Built $(ICNS)"

app: build $(ICNS)
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Support/Info.plist $(BUNDLE)/Contents/Info.plist
	cp $(ICNS) $(BUNDLE)/Contents/Resources/$(APP).icns
	@for b in $(BUILDDIR)/*.bundle; do \
		[ -d "$$b" ] && cp -R "$$b" $(BUNDLE)/Contents/Resources/ || true; \
	done
	codesign --force --sign - $(BUNDLE)
	@echo "Built $(BUNDLE)"

# The release asset. A disk image rather than a zip so the install is the usual macOS
# drag-to-Applications: the window shows the app beside a symlink to /Applications, and
# nothing lands in Downloads half-unpacked.
dmg: app
	rm -rf $(DMGROOT) $(DMG)
	mkdir -p $(DMGROOT)
	cp -R $(BUNDLE) $(DMGROOT)/
	ln -s /Applications $(DMGROOT)/Applications
	hdiutil create -volname $(APP) -srcfolder $(DMGROOT) -ov -format UDZO $(DMG)
	@echo "Built $(DMG)"

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
