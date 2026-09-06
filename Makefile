.PHONY: all build clean distclean flash upgrade help

all: build

help:
	@echo "OpenWrt Headless NAS Build System"
	@echo ""
	@echo "Usage:"
	@echo "  make build       Build the ready-to-flash OpenWrt image using Docker"
	@echo "  make clean       Remove temporary overlays and output images"
	@echo "  make distclean   Remove all build artifacts and download caches"
	@echo "  make flash       Interactively flash the factory image to microSD card"
	@echo "  make upgrade     Remotely upgrade running Pi over LAN or Tailscale"
	@echo ""

build:
	./build.sh

clean:
	rm -rf build/overlay output/ tests/tmp tests/test-usb.img

distclean: clean
	rm -rf build/

flash:
	./scripts/flash_sd.sh

upgrade:
	@test -n "$(TARGET)" || { echo "Usage: make upgrade TARGET=<ip-or-hostname>"; exit 1; }
	./scripts/remote_upgrade.sh "$(TARGET)"