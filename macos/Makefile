CC = clang
CFLAGS = -Wall -fobjc-arc -mmacosx-version-min=11.0 -arch x86_64 -arch arm64
LDFLAGS = -dynamiclib -framework Foundation -framework AVFoundation -framework CoreMedia -framework CoreMediaIO -framework CoreVideo
TARGET = VirtualCamPlugin
PLUGIN_DIR = VirtualCam.plugin/Contents/MacOS
INSTALL_DIR = /Library/CoreMediaIO/Plug-Ins/DAL
VIDEO_DIR = $(HOME)/Library/Application Support/VirtualCam

all: $(PLUGIN_DIR)/$(TARGET)

$(PLUGIN_DIR):
	mkdir -p $(PLUGIN_DIR)
	cp Info.plist VirtualCam.plugin/Contents/

$(PLUGIN_DIR)/$(TARGET): VirtualCamPlugin.m | $(PLUGIN_DIR)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)
	@echo "[VirtualCam] Build complete"

install: all
	mkdir -p $(VIDEO_DIR)
	sudo cp -R VirtualCam.plugin $(INSTALL_DIR)/
	sudo killall -9 AppleCameraAssistant 2>/dev/null || true
	sudo killall -9 VDCAssistant 2>/dev/null || true
	@echo "[VirtualCam] Installed to $(INSTALL_DIR)"
	@echo "[VirtualCam] Drop video.mp4 in $(VIDEO_DIR)/"
	@echo "[VirtualCam] Restart any camera apps to see 'Integrated Camera'"

uninstall:
	sudo rm -rf $(INSTALL_DIR)/VirtualCam.plugin
	sudo killall -9 AppleCameraAssistant 2>/dev/null || true
	sudo killall -9 VDCAssistant 2>/dev/null || true
	@echo "[VirtualCam] Uninstalled"

clean:
	rm -rf VirtualCam.plugin

.PHONY: all install uninstall clean
