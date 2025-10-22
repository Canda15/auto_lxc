#!/bin/bash

# 确保以 root 权限运行
if [ "$(id -u)" != "0" ]; then
   echo "此脚本必须以 root 权限运行" 1>&2
   exit 1
fi

# --- 1. 更改 journald.conf 中 SystemMaxUse 的选项为 64M ---
echo "正在限制 systemd 日志大小为 64M..."
# 使用 sed 命令查找并替换 SystemMaxUse 的值，如果不存在则添加
if grep -q "^#\?SystemMaxUse=" /etc/systemd/journald.conf; then
    sed -i -E 's/^#?SystemMaxUse=.*/SystemMaxUse=64M/' /etc/systemd/journald.conf
else
    echo "SystemMaxUse=64M" >> /etc/systemd/journald.conf
fi
# 重启 systemd-journald 服务以应用更改
systemctl restart systemd-journald
echo "systemd 日志大小限制完成。"
echo

# --- 2. 创建 dpkg 配置文件以排除不必要的文件 ---
echo "正在配置 dpkg 以排除文档和非必要文件..."
cat > /etc/dpkg/dpkg.cfg.d/del <<'EOF'
# 排除文档
path-exclude=/usr/share/doc/*
# 保留版权文件以符合法律要求
path-include=/usr/share/doc/*/copyright
# 排除 man 手册页
path-exclude=/usr/share/man/*
# 排除 info 文件
path-exclude=/usr/share/info/*
# 排除 lintian
path-exclude=/usr/share/lintian/*
path-exclude=/usr/share/linda/*
EOF
echo "dpkg 配置完成。"
echo

# --- 3. 精简已安装的基础系统的 locale 文件 ---
echo "正在精简现有的语言环境文件..."
find /usr/share/locale -mindepth 1 -maxdepth 1 ! \( -name '*en_US*' -o -name '*zh_CN*' -o -name 'locale.alias' \) -exec rm -rf {} +
echo "语言环境文件精简完成。"
echo

# --- 4. 设置时区 ---
echo "正在设置时区为 Asia/Shanghai..."
timedatectl set-timezone Asia/Shanghai
echo "时区设置完成。"
echo

# --- 5. 最小化安装 cron ---
echo "正在以最小化模式安装 cron..."
apt-get update
apt-get install --no-install-recommends -y cron
echo "cron 安装完成。"
echo

# --- 6. 自动执行 apt 清理 ---
echo "正在执行 apt 清理..."
apt-get clean
apt-get autoremove -y
echo "apt 清理完成。"
echo

# --- 7. 写入 cron 任务，每14天自动删除日志 ---
echo "正在创建定时任务以定期清理日志..."
# 创建一个脚本文件用于删除日志
cat > /usr/local/bin/clear_logs.sh <<'EOF'
#!/bin/bash
# 删除 /var/log/ 下的所有文件和目录
find /var/log/ -type f -delete
find /var/log/ -type d -empty -delete
EOF

# 赋予脚本执行权限
chmod +x /usr/local/bin/clear_logs.sh

# 将 cron 任务添加到 crontab 中
# 0 3 */14 * * 表示每14天的凌晨3点执行
(crontab -l 2>/dev/null; echo "0 3 */14 * * /usr/local/bin/clear_logs.sh") | crontab -
echo "定时任务创建完成。"
echo

echo "所有操作已成功完成！"
