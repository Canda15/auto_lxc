#!/bin/bash

# =================================================================
# 颜色定义
# =================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'

# =================================================================
# 全局变量
# =================================================================
APT_UPDATED="false" # 用于标记是否执行过 apt update

# =================================================================
# 基础检查
# =================================================================
if [ "$(id -u)" != "0" ]; then
   echo -e "${RED}错误：此脚本必须以 root 权限运行！${PLAIN}" 1>&2
   exit 1
fi

# =================================================================
# 获取系统信息
# =================================================================
if [ -f /etc/os-release ]; then
    . /etc/os-release
fi

# =================================================================
# 通用辅助函数
# =================================================================

# 智能更新源：只在第一次调用时执行 apt update
function check_apt_update() {
    if [ "$APT_UPDATED" = "false" ]; then
        echo -e "${SKYBLUE}-> 正在更新软件源列表 (apt-get update)...${PLAIN}"
        apt-get update
        APT_UPDATED="true"
    else
        echo -e "${SKYBLUE}-> 软件源已更新，跳过重复执行。${PLAIN}"
    fi
}

# =================================================================
# 功能函数定义
# =================================================================

# 1. 限制 Systemd 日志大小
function limit_journald() {
    echo -e "${YELLOW}正在执行：限制 systemd 日志大小为 64M...${PLAIN}"
    if grep -q "^#\?SystemMaxUse=" /etc/systemd/journald.conf; then
        sed -i -E 's/^#?SystemMaxUse=.*/SystemMaxUse=64M/' /etc/systemd/journald.conf
    else
        echo "SystemMaxUse=64M" >> /etc/systemd/journald.conf
    fi
    systemctl restart systemd-journald
    echo -e "${GREEN}✔ systemd 日志大小限制完成。${PLAIN}"
}

# 2. 配置 dpkg 排除文件
function configure_dpkg_exclude() {
    echo -e "${YELLOW}正在执行：配置 dpkg 以排除文档和非必要文件...${PLAIN}"
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
    echo -e "${GREEN}✔ dpkg 配置完成。${PLAIN}"
}

# 3. 精简 Locale 语言包
function strip_locales() {
    echo -e "${YELLOW}正在执行：精简已安装的基础系统的 locale 文件 (保留 en_US 和 zh_CN)...${PLAIN}"
    find /usr/share/locale -mindepth 1 -maxdepth 1 ! \( -name '*en_US*' -o -name '*zh_CN*' -o -name 'locale.alias' \) -exec rm -rf {} +
    echo -e "${GREEN}✔ 语言环境文件精简完成。${PLAIN}"
}

# 4. 设置时区并配置 NTP 时间同步 (新增 systemd-timesyncd)
function set_time_and_ntp() {
    echo -e "${YELLOW}正在执行：设置时区并配置 NTP 时间同步...${PLAIN}"
    
    # 1. 设置时区
    echo -e "${SKYBLUE}-> 设置时区为 Asia/Shanghai...${PLAIN}"
    timedatectl set-timezone Asia/Shanghai
    
    # 2. 安装 timesyncd
    check_apt_update # 智能检查更新
    echo -e "${SKYBLUE}-> 安装 systemd-timesyncd...${PLAIN}"
    apt-get install systemd-timesyncd -y
    
    # 3. 启动服务
    systemctl enable --now systemd-timesyncd
    
    # 4. 检查状态
    echo -e "${SKYBLUE}-> 检查 NTP 服务状态...${PLAIN}"
    if systemctl is-active --quiet systemd-timesyncd; then
        echo -e "${GREEN}✔ systemd-timesyncd 正在运行 (Active)。${PLAIN}"
        # 显示详细的时间状态
        echo -e "${SKYBLUE}--- 时间同步状态 (timedatectl) ---${PLAIN}"
        timedatectl status | grep -E "System clock synchronized|NTP service" | sed 's/^[ \t]*//'
    else
        echo -e "${RED}✘ systemd-timesyncd 启动失败，请检查系统日志。${PLAIN}"
    fi
    
    echo -e "${GREEN}✔ 时区与时间同步配置完成 ($(date))。${PLAIN}"
}

# 5. 安装 Cron 并配置日志自动清理
function log_cleaner() {
    echo -e "${YELLOW}正在执行：安装 cron 服务并配置日志定时清理...${PLAIN}"
    
    # --- 第一步：安装 cron ---
    check_apt_update # 智能检查更新
    echo -e "${SKYBLUE}-> 正在安装 cron...${PLAIN}"
    apt-get install --no-install-recommends -y cron
    
    # --- 第二步：配置清理脚本 ---
    echo -e "${SKYBLUE}-> 正在创建清理脚本...${PLAIN}"
    cat > /usr/local/bin/clear_logs.sh <<'EOF'
#!/bin/bash
# 删除 /var/log/ 下的所有文件和目录
find /var/log/ -type f -delete
find /var/log/ -type d -empty -delete
EOF
    chmod +x /usr/local/bin/clear_logs.sh

    # --- 第三步：添加定时任务 ---
    local job="0 3 */14 * * /usr/local/bin/clear_logs.sh"
    
    if crontab -l 2>/dev/null | grep -Fq "$job"; then
        echo -e "${SKYBLUE}提示：日志清理任务已存在，跳过添加。${PLAIN}"
    else
        (crontab -l 2>/dev/null; echo "$job") | crontab -
        echo -e "${GREEN}✔ 已添加定时任务：每14天自动清理日志。${PLAIN}"
    fi

    echo -e "${GREEN}✔ Cron 安装及配置全部完成。${PLAIN}"
}

# 6. 安装 SmartDNS
function install_smartdns() {
    local run_mode=$1 # 接收参数：auto 表示一键执行中调用
    
    echo -e "${YELLOW}正在执行：安装 SmartDNS...${PLAIN}"
    
    # 检查 SmartDNS 是否已安装
    if dpkg -l | grep -q smartdns; then
        if [ "$run_mode" == "auto" ]; then
            echo -e "${SKYBLUE}检测到 SmartDNS 已安装，跳过安装。${PLAIN}"
            return
        else
            echo -e "${SKYBLUE}检测到 SmartDNS 已安装，但当前为手动选择模式，将继续执行安装脚本。${PLAIN}"
        fi
    fi
    
    # 检查 curl
    if ! command -v curl &> /dev/null; then
        echo -e "${SKYBLUE}-> 检测到系统未安装 curl，正在安装...${PLAIN}"
        check_apt_update
        apt-get install -y curl
    fi

    echo -e "${SKYBLUE}-> 开始下载并运行 SmartDNS 安装脚本...${PLAIN}"
    bash <(curl -sL https://raw.githubusercontent.com/ddd-zero/smartdns_install/main/install.sh)
    
    echo -e "${GREEN}✔ SmartDNS 安装脚本执行完毕。${PLAIN}"
}



# 8. VPS 安全加固 (SSH端口 + NFTables)
function setup_vps_security() {
    echo -e "${YELLOW}正在执行：VPS 安全防护配置 (SSH端口改30122 + nftables防爆破)...${PLAIN}"

    # --- 1. 检查 nftables 是否存在 ---
    if ! command -v nft &> /dev/null; then
        echo -e "${RED}错误：未检测到 nftables，无法配置防火墙。请先安装 nftables (apt install nftables)。本步骤终止。${PLAIN}"
        return
    fi
	
    # --- 1.5 检查是否已执行过安全加固 (新增功能) ---
    # 逻辑：检查配置文件中是否存在自定义的 blocklist 集合
    if [ -f /etc/nftables.conf ] && grep -q "ssh_blocklist" /etc/nftables.conf; then
        echo -e "${GREEN}✔ 检测到 /etc/nftables.conf 中已存在安全规则(ssh_blocklist)，说明已加固过。${PLAIN}"
        echo -e "${YELLOW}跳过本次安全配置，以免覆盖。${PLAIN}"
        return
    fi

    # --- 2. 修改 SSH 端口 ---
    echo -e "${SKYBLUE}-> 正在检查 SSH 监听端口...${PLAIN}"
    # 使用 ss 命令检查是否有程序监听 30122 端口
    if ss -tlnp | grep -q ":30122 "; then
        echo -e "${GREEN}SSH 端口已是 30122，无需修改。${PLAIN}"
    else
        echo -e "${SKYBLUE}当前端口非 30122，正在修改配置...${PLAIN}"
        # 创建配置片段 (Debian/Ubuntu 标准做法)
        mkdir -p /etc/ssh/sshd_config.d
        echo "Port 30122" > /etc/ssh/sshd_config.d/01-change-ssh-port.conf
        
        echo -e "${SKYBLUE}重启 SSH 服务以应用更改...${PLAIN}"
        systemctl restart sshd
        echo -e "${GREEN}SSH 服务已重启，新端口：30122。${PLAIN}"
    fi

    # --- 3. 配置 nftables ---
    echo -e "${SKYBLUE}-> 正在配置 nftables 防火墙...${PLAIN}"
    
    # 备份原有配置
    if [ -f /etc/nftables.conf ]; then
        cp /etc/nftables.conf /etc/nftables.conf.bak.$(date +%F_%H%M%S)
        echo -e "${SKYBLUE}已备份原配置文件为 /etc/nftables.conf.bak...${PLAIN}"
    fi

    # 写入新配置
    # 注意：这里将原规则的 dport 22 改为了 dport 30122，以配合上面修改的端口
    cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    # 创建一个动态集合，用于存放被封禁的IPv4和IPv6地址
    # 被封禁的地址会在1小时后自动移除
    set ssh_blocklist {
        type ipv4_addr;
        flags dynamic, timeout;
        timeout 1h;
    }

    set ssh_blocklist_v6 {
        type ipv6_addr;
        flags dynamic, timeout;
        timeout 1h;
    }

    chain input {
        type filter hook input priority 0;

        # 允许已建立和相关的连接
        ct state established,related accept

        # 丢弃无效的数据包
        ct state invalid drop

        # ---- SSH 防护规则 (端口 30122) 开始 ----

        # 针对IPv4的SSH防护
        tcp dport 30122 ct state new ip saddr @ssh_blocklist drop
        tcp dport 30122 ct state new limit rate over 5/minute add @ssh_blocklist { ip saddr } drop

        # 针对IPv6的SSH防护
        tcp dport 30122 ct state new ip6 saddr @ssh_blocklist_v6 drop
        tcp dport 30122 ct state new limit rate over 5/minute add @ssh_blocklist_v6 { ip6 saddr } drop
    }
}
EOF

    echo -e "${SKYBLUE}应用 nftables 规则...${PLAIN}"
    systemctl enable nftables
    systemctl restart nftables
    
    if systemctl is-active --quiet nftables; then
        echo -e "${GREEN}✔ nftables 启动成功并正在运行。${PLAIN}"
        # 简单展示一下当前的规则数，确认写入成功
        echo -e "${SKYBLUE}当前规则集概览：${PLAIN}"
        nft list ruleset | grep -E "table|chain|dport" | head -n 5
    else
        echo -e "${RED}✘ nftables 启动失败，请检查配置文件 /etc/nftables.conf${PLAIN}"
    fi

    echo -e "${GREEN}✔ VPS 安全防护配置完成。请务必使用新端口 30122 连接 SSH！${PLAIN}"
}



# END. 执行 APT 清理
function apt_cleanup() {
    echo -e "${YELLOW}正在执行：apt 清理 (clean & autoremove)...${PLAIN}"
    apt-get clean
    apt-get autoremove -y
    echo -e "${GREEN}✔ apt 清理完成。${PLAIN}"
}

# =================================================================
# 任务调度核心
# =================================================================

# 执行单个任务的函数（根据ID）
function execute_task() {
    local task_id=$1
	local mode=$2
    case "$task_id" in
        1) limit_journald ;;
        2) configure_dpkg_exclude ;;
        3) strip_locales ;;
        4) set_time_and_ntp ;;
        5) log_cleaner ;;
        6) install_smartdns "$mode" ;;
        7) setup_vps_security ;;
        8) apt_cleanup ;;
        *) echo -e "${RED}忽略未知任务 ID: $task_id ${PLAIN}" ;;
    esac
}

# 一键执行所有
function run_all() {
    echo -e "${SKYBLUE}>>> 开始执行所有优化步骤 (1-8)...${PLAIN}"
    for i in {1..8}; do
        execute_task "$i" "auto" # 【修复】传入 auto 参数，跳过已安装的 smartdns
    done
    echo -e "${GREEN}>>> 所有操作已成功完成！${PLAIN}"
}

# =================================================================
# 菜单界面
# =================================================================
while true; do
    clear
    echo -e "${SKYBLUE}=============================================${PLAIN}"
    echo -e "${SKYBLUE}       Linux 系统精简与优化脚本       ${PLAIN}"
    echo -e "${SKYBLUE}=============================================${PLAIN}"
    echo -e "${YELLOW} 系统全称 : ${SKYBLUE}${PRETTY_NAME:-未检测到}${PLAIN}"
    echo -e "${YELLOW} 发行版本 : ${SKYBLUE}${NAME:-未检测到}${PLAIN}"
    echo -e "${YELLOW} 系统版本 : ${SKYBLUE}${VERSION:-未检测到}${PLAIN}"
    echo -e "${SKYBLUE}---------------------------------------------${PLAIN}"
    
    echo -e "${GREEN} 0. 一键执行所有优化 (1-8)${PLAIN}"
    echo -e "---------------------------------------------"
    echo -e "${GREEN} 1.${PLAIN} 限制 journald 日志大小为 64M"
    echo -e "${GREEN} 2.${PLAIN} 配置 dpkg 排除文档/Man/Info文件"
    echo -e "${GREEN} 3.${PLAIN} 精简 Locale (仅保留中英)"
    echo -e "${GREEN} 4.${PLAIN} 设置时区 + 配置 NTP 时间同步"
    echo -e "${GREEN} 5.${PLAIN} 安装 Cron + 配置每14天自动清理日志"
    echo -e "${GREEN} 6.${PLAIN} 安装 SmartDNS"
    echo -e "${GREEN} 7.${PLAIN} 执行 VPS 安全加固 (改端口+防爆破)"
    echo -e "${GREEN} 8.${PLAIN} 执行 apt clean & autoremove"
    echo -e "---------------------------------------------"
    echo -e "${GREEN} q.${PLAIN} 退出脚本"
    echo -e "${SKYBLUE}=============================================${PLAIN}"
    echo -e "${YELLOW}提示: 支持多选 (如 \"1 3\") 或 排除 (如 \"-1\" 表示除了1以外全做，\"-1 2\" 表示排除1和2)${PLAIN}"
    echo

    read -p "请输入选项: " -a choices # 读取为数组
    echo

    # 1. 处理退出
    if [[ "${choices[0]}" =~ ^[qQ]$ ]]; then
        echo "已退出。"
        exit 0
    fi

    # 2. 处理 "0" (Run All)
    if [[ "${choices[0]}" == "0" ]]; then
        run_all
        break
    fi

    # 3. 解析输入模式 (普通多选 OR 排除模式)
    # 只要输入中包含任何带 "-" 的数字，就视为排除模式 (Run All minus x)
    exclude_mode=false
    for choice in "${choices[@]}"; do
        if [[ "$choice" == -* ]]; then
            exclude_mode=true
            break
        fi
    done

    # 4. 构建任务队列
    tasks_to_run=()
    if [ "$exclude_mode" = true ]; then
        echo -e "${SKYBLUE}>>> 识别为[排除模式]，将执行除指定项外的所有任务...${PLAIN}"
        # 遍历 1 到 8
        for i in {1..8}; do
            skip=false
            for choice in "${choices[@]}"; do
                # 去掉负号取绝对值 (如 -1 变为 1, 2 变为 2)
                # 这样输入 "-1 2" 或 "-1 -2" 都能正确排除 1 和 2
                abs_choice=${choice#-} 
                if [[ "$i" == "$abs_choice" ]]; then
                    skip=true
                    break
                fi
            done
            
            if [ "$skip" = false ]; then
                tasks_to_run+=("$i")
            fi
        done
    else
        # 普通多选模式，按 1-8 的顺序检查用户是否输入了该数字
        # 这样做的好处是执行顺序固定为 1->8，避免依赖关系出错
        echo -e "${SKYBLUE}>>> 识别为[多选模式]...${PLAIN}"
        for i in {1..8}; do
            for choice in "${choices[@]}"; do
                if [[ "$i" == "$choice" ]]; then
                    tasks_to_run+=("$i")
                    break
                fi
            done
        done
    fi

    # 5. 执行队列中的任务
    if [ ${#tasks_to_run[@]} -eq 0 ]; then
        echo -e "${RED}未选择任何有效任务，请重新输入。${PLAIN}"
        sleep 1
    else
        echo -e "${SKYBLUE}即将执行的任务 ID: ${tasks_to_run[*]}${PLAIN}"
        echo
        for task_id in "${tasks_to_run[@]}"; do
            execute_task "$task_id" "" 
        done
        echo -e "${GREEN}>>> 指定任务已全部完成！${PLAIN}"
        break 
    fi
done
