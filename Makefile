#
# Copyright (C) 2026
#
# This is free software, licensed under the MIT License.
#
# Build via the OpenWrt buildroot:
#   cp -r luci-app-workbuddy package/
#   make package/luci-app-workbuddy/compile V=s
#
# Or drop it into a feeds directory so it is picked up automatically.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-workbuddy
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=ZeroWrt user

LUCI_TITLE:=LuCI support for the WorkBuddy relay
LUCI_DEPENDS:=+ucode +ucode-mod-uloop +ucode-mod-socket +curl
LUCI_PKGARCH:=all
LUCI_DESCRIPTION:=Runs a small OpenAI-compatible relay on the router that \
	shares the free WorkBuddy models with every device on the LAN. \
	Includes a web login flow to obtain and refresh the access token.

include $(TOPDIR)/feeds/luci/luci.mk

# Call BuildPackage - the standard LuCI application entry point.
# Both opkg (24.10 and older) and apk (25.12 and newer) output formats are
# produced by the build system itself, so no extra handling is needed here.

# The ucode relay must stay executable after installation.
define Package/luci-app-workbuddy/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	chmod 755 /usr/bin/workbuddy-server 2>/dev/null
	chmod 755 /usr/bin/workbuddy-ctl 2>/dev/null
	/etc/init.d/workbuddy enable 2>/dev/null
}
exit 0
endef

# Stop the relay and drop its runtime state on removal.
define Package/luci-app-workbuddy/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/workbuddy stop 2>/dev/null
	/etc/init.d/workbuddy disable 2>/dev/null
	rm -f /var/run/workbuddy-login.state /tmp/workbuddy-req.json 2>/dev/null
}
exit 0
endef

# Keep the user's token when the package is upgraded. uci files under
# /etc/config are already preserved by the package manager, so only the
# explicit housekeeping is needed here.
define Package/luci-app-workbuddy/conffiles
/etc/config/workbuddy
endef

$(eval $(call BuildPackage,luci-app-workbuddy))
