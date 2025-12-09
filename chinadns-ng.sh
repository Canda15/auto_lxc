#!/bin/bash

# 设置颜色变量
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

WORK_DIR="/opt/chinadns-ng"

echo -e "${GREEN}>>> 开始安装 ChinaDNS-NG for Debian 13 (x86-64v3)...${NC}"

# 1. 检查并安装必要依赖
echo -e "${YELLOW}>>> 安装必要依赖 (curl, wget, jq)...${NC}"
apt-get update
apt-get install -y curl wget jq

# 2. 创建安装目录
if [ ! -d "$WORK_DIR" ]; then
    mkdir -p "$WORK_DIR"
    echo -e "${GREEN}>>> 创建目录: $WORK_DIR${NC}"
fi

# 3. 获取最新版本下载地址 (x86-64v3)
echo -e "${YELLOW}>>> 获取 GitHub 最新版本信息...${NC}"
LATEST_RELEASE_URL=$(curl -s "https://api.github.com/repos/zfl9/chinadns-ng/releases/latest" | jq -r '.assets[] | select(.name | contains("linux-musl@x86_64_v3") and (contains("wolfssl")|not)) | .browser_download_url')

if [ -z "$LATEST_RELEASE_URL" ]; then
    echo -e "${RED}>>> 错误: 未找到 x86-64v3 版本的下载链接。${NC}"
    exit 1
fi

# 4. 下载主程序 (直接是二进制文件，无需解压)
cd "$WORK_DIR"
echo -e "${YELLOW}>>> 下载主程序...${NC}"

# 删除旧文件（如果存在）
rm -f chinadns-ng

wget -qO chinadns-ng "$LATEST_RELEASE_URL"

if [ ! -s "chinadns-ng" ]; then
    echo -e "${RED}>>> 错误: 文件下载失败或为空。${NC}"
    exit 1
fi

chmod +x chinadns-ng

# 5. 下载辅助脚本
echo -e "${YELLOW}>>> 下载依赖更新脚本...${NC}"
SCRIPT_BASE_URL="https://raw.githubusercontent.com/zfl9/chinadns-ng/master"
SCRIPTS=("update-chnlist.sh" "update-gfwlist.sh" "update-chnroute6-nft.sh" "update-chnroute-nft.sh")

for script in "${SCRIPTS[@]}"; do
    wget -qO "$script" "$SCRIPT_BASE_URL/$script"
    chmod +x "$script"
    echo "已下载: $script"
done

# 6. 生成一键更新脚本 (update-all.sh)
echo -e "${YELLOW}>>> 生成一键更新脚本 update-all.sh...${NC}"
cat > "$WORK_DIR/update-all.sh" <<EOF
#!/bin/bash
cd $WORK_DIR
echo "Updating chnlist..."
./update-chnlist.sh
echo "Updating gfwlist..."
./update-gfwlist.sh
echo "Updating chnroute-nft..."
./update-chnroute-nft.sh
echo "Updating chnroute6-nft..."
./update-chnroute6-nft.sh
echo "所有列表更新完成。"
EOF

chmod +x "$WORK_DIR/update-all.sh"

# 7. 立即运行一次更新
echo -e "${YELLOW}>>> 正在运行首次更新 (拉取依赖)...${NC}"
bash "$WORK_DIR/update-all.sh"

# 8. 下载并配置运行参数
echo -e "${YELLOW}>>> 下载并配置运行参数...${NC}"
# 使用 Raw 链接下载
CONFIG_URL="https://raw.githubusercontent.com/ddd-zero/smartdns_install/main/%E5%85%B6%E4%BB%96/cnng"
CONFIG_FILE="$WORK_DIR/config"

RAW_ARGS=$(curl -s "$CONFIG_URL")

if [ -z "$RAW_ARGS" ]; then
    echo -e "${RED}>>> 警告: 配置文件下载失败，使用默认空配置。${NC}"
    echo 'CHINADNS_ARGS=""' > "$CONFIG_FILE"
else
    # 清理换行符并将内容赋值给 CHINADNS_ARGS 变量，以便 Systemd 读取
    CLEAN_ARGS=$(echo "$RAW_ARGS" | tr -d '\n' | tr -d '\r')
    echo "CHINADNS_ARGS=\"$CLEAN_ARGS\"" > "$CONFIG_FILE"
    echo -e "${GREEN}>>> 配置文件已保存至: $CONFIG_FILE${NC}"
fi

# 9. 配置 Systemd 服务
echo -e "${YELLOW}>>> 配置 Systemd 服务...${NC}"
SERVICE_FILE="/etc/systemd/system/chinadns-ng.service"

# 根据要求：
# 1. EnvironmentFile 改为 /opt/chinadns-ng/config
# 2. ExecStartPre/ExecStart 等路径全部指向 /opt/chinadns-ng
# 3. 假设生成的规则文件后缀为 .nftset (根据你的要求)

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ChinaDNS-NG Service
Documentation=https://github.com/zfl9/chinadns-ng
After=network.target nftables.service
Wants=network.target

[Service]
Type=simple
User=root


# --- 核心逻辑开始 ---

# 1. 启动前加载 NFTables 集合
# 注意：这里假设 update-chnroute*-nft.sh 生成的文件名确认为 .nftset
ExecStartPre=nft -f /opt/chinadns-ng/chnroute.nftset
ExecStartPre=nft -f /opt/chinadns-ng/chnroute6.nftset

# 2. 启动主程序
ExecStart=/opt/chinadns-ng/chinadns-ng -C /opt/chinadns-ng/config

# 3. 停止后清理
# 方式 B：清洗集合
ExecStopPost=-nft flush set inet global chnroute
ExecStopPost=-nft flush set inet global chnroute6

# --- 核心逻辑结束 ---

Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# 10. 启动服务
echo -e "${YELLOW}>>> 启动服务...${NC}"
systemctl daemon-reload
systemctl enable chinadns-ng
systemctl start chinadns-ng

# 11. 检查状态
echo -e "${GREEN}>>> 安装完成！服务状态如下：${NC}"
systemctl status chinadns-ng --no-pager

echo -e "${GREEN}>>>${NC}"
echo -e "配置文件路径: ${YELLOW}$CONFIG_FILE${NC}"
echo -e "一键更新脚本: ${YELLOW}$WORK_DIR/update-all.sh${NC}"
