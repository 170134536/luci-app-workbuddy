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
#
# Layout follows luci.mk's install rules:
#   root/*  -> /          (etc, usr)
#   htdocs/* -> /www      (LuCI static assets)

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-workbuddy
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=ZeroWrt user

LUCI_TITLE:=LuCI support for the WorkBuddy relay
LUCI_DEPENDS:=+ucode +ucode-mod-uloop +ucode-mod-socket +curl +luci-base
LUCI_PKGARCH:=all
LUCI_DESCRIPTION:=Runs a small OpenAI-compatible relay on the router that \
	shares the free WorkBuddy models with every device on the LAN. \
	Includes a web login flow to obtain and refresh the access token.

include $(TOPDIR)/feeds/luci/luci.mk

# NOTE: luci.mk ends with its own $(eval $(call BuildPackage,...)) for every
# entry in LUCI_BUILD_PACKAGES, which already contains this package. Calling
# BuildPackage again here would define the package twice and break the build,
# so it is deliberately omitted.

# Keep the interpreters executable and enable the service.
#
# luci.mk supplies a default postinst that clears the LuCI index and module
# caches and reloads rpcd; defining this one replaces it (luci.mk guards its
# default with ifndef), so the cache clearing is repeated here — without it the
# menu entry stays invisible until the cache is cleared by hand.
define Package/luci-app-workbuddy/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	chmod 755 /usr/bin/workbuddy-server 2>/dev/null
	chmod 755 /usr/bin/workbuddy-ctl 2>/dev/null
	/etc/init.d/workbuddy enable 2>/dev/null
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
}
exit 0
endef

# Stop the relay and drop its runtime state on removal. luci.mk defines no
# default prerm, so this one simply supplements it.
#
# /etc/config/workbuddy is intentionally left in place so reinstalling keeps
# the token.
define Package/luci-app-workbuddy/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/workbuddy stop 2>/dev/null
	/etc/init.d/workbuddy disable 2>/dev/null
	rm -f /var/run/workbuddy-login.state /tmp/workbuddy-req.json 2>/dev/null
}
exit 0
endef

define Package/luci-app-workbuddy/conffiles
/etc/config/workbuddy
endef
