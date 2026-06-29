CC = clang
CFLAGS = -Wall -Wextra -fPIC -mmacosx-version-min=11.0 -arch x86_64 -arch arm64
LDFLAGS = -dynamiclib -framework CoreFoundation -framework CoreMediaIO -framework CoreMedia -framework CoreVideo -framework AVFoundation
TARGET = VirtualCamPlugin
PLUGIN_DIR = VirtualCam.plugin/Contents/MacOS
INSTALL_DIR = /Library/CoreMediaIO/Plug-Ins/DAL

all: $(PLUGIN_DIR)/$(TARGET)

$(PLUGIN_DIR):
	mkdir -p $(PLUGIN_DIR)
	cp Info.plist VirtualCam.plugin/Contents/

$(PLUGIN_DIR)/$(TARGET): VirtualCamPlugin.c | $(PLUGIN_DIR)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

install: all
	sudo cp -R VirtualCam.plugin $(INSTALL_DIR)/
	sudo killall -9 AppleCameraAssistant 2>/dev/null || true
	sudo killall -9 VDCAssistant 2>/dev/null || true
	@echo "[VirtualCam] Installed. Restart any camera apps."

uninstall:
	sudo rm -rf $(INSTALL_DIR)/VirtualCam.plugin
	sudo killall -9 AppleCameraAssistant 2>/dev/null || true
	sudo killall -9 VDCAssistant 2>/dev/null || true
	@echo "[VirtualCam] Uninstalled."

clean:
	rm -rf VirtualCam.plugin

.PHONY: all install uninstall clean
