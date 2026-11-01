#!/bin/sh
# QoSmate & LuCI-App-QoSmate Installer (Optimized fork by w0l4i)
# Supports OpenWrt 23.05, 24.10, and 25.12+ (opkg and apk)
set -e

BRANCH="main"
REPO_BACKEND="w0l4i/qosmate"
REPO_FRONTEND="w0l4i/luci-app-qosmate"
RAW_BACKEND="https://raw.githubusercontent.com/${REPO_BACKEND}/${BRANCH}"
RAW_FRONTEND="https://raw.githubusercontent.com/${REPO_FRONTEND}/${BRANCH}"

echo "=================================================="
echo "  Installing QoSmate (w0l4i optimized fork)       "
echo "  Passwall 2 Coexistence & CAKE Diffserv8 Edition "
echo "=================================================="

# 1. Install prerequisites
echo "[1/5] Checking and installing prerequisites..."
REQUIRED_PKGS="kmod-sched ip-full kmod-veth tc-full kmod-netem kmod-sched-ctinfo kmod-ifb kmod-sched-cake kmod-sched-red luci-lib-jsonc lua jq coreutils-sleep"

if command -v apk >/dev/null 2>&1; then
    apk update || true
    for pkg in $REQUIRED_PKGS; do
        apk add "$pkg" || true
    done
elif command -v opkg >/dev/null 2>&1; then
    opkg update || true
    for pkg in $REQUIRED_PKGS; do
        opkg install "$pkg" || true
    done
fi

# 2. Download Backend
echo "[2/5] Downloading QoSmate backend..."
mkdir -p /etc/init.d /etc/hotplug.d/iface /etc/qosmate.d /etc/config
uclient-fetch -qO /etc/init.d/qosmate "${RAW_BACKEND}/etc/init.d/qosmate"
chmod +x /etc/init.d/qosmate

uclient-fetch -qO /etc/qosmate.sh "${RAW_BACKEND}/etc/qosmate.sh"
chmod +x /etc/qosmate.sh

if [ ! -f /etc/hotplug.d/iface/13-qosmateHotplug ]; then
    uclient-fetch -qO /etc/hotplug.d/iface/13-qosmateHotplug "${RAW_BACKEND}/etc/hotplug.d/iface/13-qosmateHotplug" || touch /etc/hotplug.d/iface/13-qosmateHotplug
fi

if [ ! -f /etc/config/qosmate ]; then
    uclient-fetch -qO /etc/config/qosmate "${RAW_BACKEND}/etc/config/qosmate"
fi

# 3. Download Frontend
echo "[3/5] Downloading LuCI web interface..."
mkdir -p /www/luci-static/resources/view/qosmate /usr/share/luci/menu.d /usr/share/rpcd/acl.d /usr/libexec/rpcd

VIEWS="settings hfsc cake advanced rules connections custom_rules ipsets statistics"
for view in $VIEWS; do
    uclient-fetch -qO "/www/luci-static/resources/view/qosmate/${view}.js" "${RAW_FRONTEND}/htdocs/luci-static/resources/view/${view}.js"
done

uclient-fetch -qO /usr/share/luci/menu.d/luci-app-qosmate.json "${RAW_FRONTEND}/root/usr/share/luci/menu.d/luci-app-qosmate.json"
uclient-fetch -qO /usr/share/rpcd/acl.d/luci-app-qosmate.json "${RAW_FRONTEND}/root/usr/share/rpcd/acl.d/luci-app-qosmate.json"
uclient-fetch -qO /usr/libexec/rpcd/luci.qosmate "${RAW_FRONTEND}/root/usr/libexec/rpcd/luci.qosmate"
uclient-fetch -qO /usr/libexec/rpcd/luci.qosmate_stats "${RAW_FRONTEND}/root/usr/libexec/rpcd/luci.qosmate_stats"
chmod +x /usr/libexec/rpcd/luci.qosmate /usr/libexec/rpcd/luci.qosmate_stats

# 4. Generate integrity registry checksums
echo "[4/5] Generating file integrity registry..."
md5sum /etc/init.d/qosmate /etc/qosmate.sh /etc/hotplug.d/iface/13-qosmateHotplug /etc/config/qosmate > /etc/qosmate.d/backend_reg.md5 2>/dev/null || true
md5sum /www/luci-static/resources/view/qosmate/*.js /usr/share/luci/menu.d/luci-app-qosmate.json /usr/share/rpcd/acl.d/luci-app-qosmate.json /usr/libexec/rpcd/luci.qosmate* > /etc/qosmate.d/frontend_reg.md5 2>/dev/null || true

# 5. Enable and restart services
echo "[5/5] Restarting LuCI and enabling QoSmate..."
/etc/init.d/rpcd restart 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || true
/etc/init.d/qosmate enable 2>/dev/null || true

echo ""
echo "=================================================="
echo "  Installation Successful!                        "
echo "  Access LuCI: Network -> QoSmate                 "
echo "  To start: /etc/init.d/qosmate start             "
echo "  To check: /etc/init.d/qosmate health_check      "
echo "=================================================="
