#!/bin/bash

# 遇到错误立即退出
set -e

# 定义路径
INSTALL_DIR="/opt/realm"
CONFIG_FILE="${INSTALL_DIR}/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"

# 颜色输出
info() { echo -e "\033[32m[INFO] $1\033[0m"; }
err() { echo -e "\033[31m[ERROR] $1\033[0m"; exit 1; }

# 1. 权限与环境检测
info "正在检查系统环境..."

# 检查 Root
if [[ $EUID -ne 0 ]]; then
    err "请使用 root 用户运行此脚本。"
fi

# 检查架构 (AMD64/x86_64)
ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" ]]; then
    err "架构检测不通过: 当前为 $ARCH，本脚本仅支持 x86_64 (AMD64)。"
fi

# 检查系统 (Debian)
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "debian" && "$ID_LIKE" != *"debian"* ]]; then
        err "系统检测不通过: 检测到 $ID，本脚本仅支持 Debian。"
    fi
else
    err "无法检测操作系统，请确保是在标准 Linux 环境下运行。"
fi

info "环境检测通过 (Debian/x86_64)。"

# 2. 安装依赖
info "安装必要依赖 (wget, curl, tar)..."
apt-get update -qq >/dev/null
apt-get install -y -qq wget curl tar >/dev/null

# 3. 下载并安装 Realm
info "获取 Realm 最新版本..."
# 获取最新版本号
LATEST_VER=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

if [[ -z "$LATEST_VER" ]]; then
    err "无法获取版本信息，请检查网络连接。"
fi

DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/${LATEST_VER}/realm-x86_64-unknown-linux-gnu.tar.gz"

info "正在下载版本: ${LATEST_VER} ..."
mkdir -p "$INSTALL_DIR"
wget -qO /tmp/realm.tar.gz "$DOWNLOAD_URL"

info "正在解压安装到 $INSTALL_DIR ..."
tar -xvf /tmp/realm.tar.gz -C "$INSTALL_DIR" >/dev/null
chmod +x "$INSTALL_DIR/realm"
rm -f /tmp/realm.tar.gz

# 4. 初始化配置文件 (仅当不存在时创建)
if [ ! -f "$CONFIG_FILE" ]; then
    info "生成默认配置文件: $CONFIG_FILE"
    cat > "$CONFIG_FILE" <<EOF
[network]
no_tcp = false
use_udp = true

# 默认空配置，请在下方添加 [[endpoints]]
# [[endpoints]]
# listen = "0.0.0.0:8080"
# remote = "1.1.1.1:443"
EOF
else
    info "配置文件已存在，跳过覆盖。"
fi

# 5. 配置 Systemd 守护进程
info "配置 Systemd 服务..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Realm Network Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/realm -c $CONFIG_FILE
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# 6. 启动服务
info "重新加载服务并启动..."
systemctl daemon-reload
systemctl enable realm >/dev/null 2>&1
systemctl restart realm

# 验证状态
if systemctl is-active --quiet realm; then
    info "安装成功！Realm 正在运行。"
    echo "------------------------------------------------"
    echo "主程序位置: $INSTALL_DIR/realm"
    echo "配置文件:   $CONFIG_FILE"
    echo "------------------------------------------------"
    echo "修改配置后请执行: systemctl restart realm"
else
    err "安装完成但服务启动失败，请检查: systemctl status realm"
fi
