include $(TOPDIR)/rules.mk

PKG_NAME:=on-wireguard

include $(INCLUDE_DIR)/opennet.mk

define Package/on-wireguard
  SECTION:=opennet
  CATEGORY:=Opennet
  URL:=https://www.opennet-initiative.de/
  MAINTAINER:=Opennet Initiative <admin@opennet-initiative.de>
  TITLE:=VPN extensions with wireguard
  DEPENDS:=+wireguard-tools +luci-proto-wireguard
endef

define Package/on-wireguard/description
	VPN extensions with wireguard
endef

# dummy fuer den openwrt-Buildprozess
define Package/on-wireguard/compile
endef

define Package/on-wireguard/install
	# dieses Template wird via patches/makefile_include_opennet_packages.patch definiert
	$(call Package/opennet/install/template,$(1),$(PKG_NAME))
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
