#!/bin/bash

# 设置颜色变量
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}>>> 开始安装 ChinaDNS-NG for Debian 13 (x86-64v3)...${NC}"

# 1. 检查并安装必要依赖
echo -e "${YELLOW}>>> 安装必要依赖 (curl, wget, jq, nftables)...${NC}"
apt-get update
apt-get install -y curl wget jq tar

# 2. 创建安装目录
WORK_DIR="/opt/chinadns-ng"
if [ ! -d "$WORK_DIR" ]; then
    mkdir -p "$WORK_DIR"
    echo -e "${GREEN}>>> 创建目录: $WORK_DIR${NC}"
fi

# 3. 获取最新版本下载地址 (x86-64v3)
echo -e "${YELLOW}>>> 获取 GitHub 最新版本信息...${NC}"
LATEST_RELEASE_URL=$(curl -s "https://api.github.com/repos/zfl9/chinadns-ng/releases/latest" | jq -r '.assets[] | select(.name | contains("linux-x86_64v3")) | .browser_download_url')

if [ -z "$LATEST_RELEASE_URL" ]; then
    echo -e "${RED}>>> 错误: 未找到 x86-64v3 版本的下载链接，请检查网络或架构支持。${NC}"
    exit 1
fi

echo -e "${GREEN}>>> 下载地址: $LATEST_RELEASE_URL${NC}"

# 4. 下载并解压
cd "$WORK_DIR"
echo -e "${YELLOW}>>> 下载并解压主程序...${NC}"
wget -qO chinadns-ng.tar.gz "$LATEST_RELEASE_URL"
# 解压并提取 chinadns-ng 二进制文件，忽略其他文件
tar -zxvf chinadns-ng.tar.gz chinadns-ng
rm chinadns-ng.tar.gz

# 设置权限
chmod +x chinadns-ng
if [ -f "$WORK_DIR/chinadns-ng" ]; then
    echo -e "${GREEN}>>> 主程序安装成功。${NC}"
else
    echo -e "${RED}>>> 错误: 主程序解压失败。${NC}"
    exit 1
fi

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
echo "正在更新 chnlist..."
./update-chnlist.sh
echo "正在更新 gfwlist..."
./update-gfwlist.sh
echo "正在更新 chnroute-nft..."
./update-chnroute-nft.sh
echo "正在更新 chnroute6-nft..."
./update-chnroute6-nft.sh

# 重命名以匹配 Systemd 服务文件中的定义 (.nft -> .nftset)
if [ -f chnroute.nft ]; then mv chnroute.nft chnroute.nftset; fi
if [ -f chnroute6.nft ]; then mv chnroute6.nft chnroute6.nftset; fi

echo "所有列表更新完成，且已重命名为 .nftset 格式。"
# 可选：更新后重载 nftables 或重启服务 (取决于你的需求，这里仅打印提示)
echo "请记得重载 nftables 规则或重启 chinadns-ng 服务以生效。"
EOF

chmod +x "$WORK_DIR/update-all.sh"

# 7. 立即运行一次更新
echo -e "${YELLOW}>>> 正在运行首次更新 (这可能需要几秒钟)...${NC}"
bash "$WORK_DIR/update-all.sh"

# 8. 下载并配置运行参数
echo -e "${YELLOW}>>> 下载并配置运行参数...${NC}"
# 注意：GitHub URL 包含中文，使用 URL 编码后的 Raw 链接
CONFIG_URL="https://raw.githubusercontent.com/ddd-zero/smartdns_install/main/%E5%85%B6%E4%BB%96/cnng"
CONFIG_FILE="/etc/default/chinadns-ng"

# 下载原始配置内容
RAW_ARGS=$(curl -s "$CONFIG_URL")

# 检查是否下载成功
if [ -z "$RAW_ARGS" ]; then
    echo -e "${RED}>>> 警告: 配置文件下载失败，将使用默认空配置。${NC}"
    echo 'CHINADNS_ARGS=""' > "$CONFIG_FILE"
else
    # 将下载的内容封装进 CHINADNS_ARGS 变量中
    # 去除可能存在的换行符，确保是单行
    CLEAN_ARGS=$(echo "$RAW_ARGS" | tr -d '\n' | tr -d '\r')
    echo "CHINADNS_ARGS=\"$CLEAN_ARGS\"" > "$CONFIG_FILE"
    echo -e "${GREEN}>>> 配置文件已写入: $CONFIG_FILE${NC}"
fi

# 9. 配置 Systemd 服务
echo -e "${YELLOW}>>> 配置 Systemd 服务...${NC}"
SERVICE_FILE="/etc/systemd/system/chinadns-ng.service"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ChinaDNS-NG Service
Documentation=https://github.com/zfl9/chinadns-ng
After=network.target nftables.service
Wants=network.target

[Service]
Type=simple
User=root
# 加载环境变量
EnvironmentFile=-/etc/default/chinadns-ng

# --- 核心逻辑开始 ---

# 1. 启动前加载 NFTables 集合
ExecStartPre=/usr/sbin/nft -f /opt/chinadns-ng/chnroute.nftset
ExecStartPre=/usr/sbin/nft -f /opt/chinadns-ng/chnroute6.nftset

# 2. 启动主程序
ExecStart=/opt/chinadns-ng/chinadns-ng \$CHINADNS_ARGS

# 3. 停止后清理
# 方式 B：如果 .nftset 只是向现有的 table 添加 set (最通用的情况)
ExecStopPost=-/usr/sbin/nft flush set inet filter chnroute
ExecStopPost=-/usr/sbin/nft flush set inet filter chnroute6

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
echo -e "以后更新列表，请运行: ${YELLOW}/opt/chinadns-ng/update-all.sh${NC}"
echo -e "记得在 update-all.sh 运行后重启服务: ${YELLOW}systemctl restart chinadns-ng${NC}"
