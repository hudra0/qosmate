include $(TOPDIR)/rules.mk

PKG_NAME:=qosmate
PKG_VERSION:=0.5.31
PKG_RELEASE:=1

PKG_MAINTAINER:=Markus Hütter <mh@hudra.net>
PKG_LICENSE:=GPL-3.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/qosmate
  SECTION:=net
  CATEGORY:=Base system
  TITLE:=QoSmate - Quality of Service management tool
  DEPENDS:=+ip-full +tc-full +kmod-veth +kmod-netem +kmod-sched +kmod-sched-ctinfo +kmod-sched-cake +kmod-ifb
endef

define Package/qosmate/description
  QoSmate is a Quality of Service management tool for OpenWrt
endef

define Build/Prepare
endef

define Build/Compile
endef

define Package/qosmate/conffiles
/etc/config/qosmate
endef

define Package/qosmate/install
	$(INSTALL_DIR) $(1)/etc
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_DIR) $(1)/usr/lib/tc

	$(INSTALL_BIN) $(CURDIR)/files/qosmate.sh $(1)/etc/qosmate.sh
	$(INSTALL_CONF) $(CURDIR)/files/qosmate.conf $(1)/etc/config/qosmate
	$(INSTALL_BIN) $(CURDIR)/files/qosmate.init $(1)/etc/init.d/qosmate
	$(INSTALL_BIN) $(CURDIR)/files/qosmate.migrate $(1)/etc/uci-defaults/99_migrate_qosmate
	$(INSTALL_BIN) $(CURDIR)/files/qosmate.hotplug $(1)/etc/hotplug.d/iface/13-qosmate
	
	$(INSTALL_DATA) $(CURDIR)/files/tc-libs/experimental.dist $(1)/usr/lib/tc/experimental.dist
	$(INSTALL_DATA) $(CURDIR)/files/tc-libs/normal.dist $(1)/usr/lib/tc/normal.dist
	$(INSTALL_DATA) $(CURDIR)/files/tc-libs/normmix20-64.dist $(1)/usr/lib/tc/normmix20-64.dist
	$(INSTALL_DATA) $(CURDIR)/files/tc-libs/pareto.dist $(1)/usr/lib/tc/pareto.dist
	$(INSTALL_DATA) $(CURDIR)/files/tc-libs/paretonormal.dist $(1)/usr/lib/tc/paretonormal.dist
endef

$(eval $(call BuildPackage,qosmate))
