#!/bin/sh

# MosDNS 独立监控面板 - 一键部署、更新、恢复脚本 (Alpine Linux版本)
# 作者：ChatGPT & JimmyDADA & Phil Horse
# 版本：7.3 (Alpine兼容版)
# 特点：
# - [Alpine] 专为Alpine Linux设计，使用apk包管理器
# - [UI/UX] 重构日志输出和命令执行函数，彻底解决终端乱码问题，输出更专业。
# - 保持了所有核心功能：自动部署、更新、恢复、诊断。

# --- 定义颜色和样式 ---
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_RED='\033[0;31m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_PURPLE='\033[0;35m'
C_BOLD='\033[1m'
C_NC='\033[0m' # No Color

# --- 辅助日志函数 ---
log_info() { echo -e "${C_GREEN}✔  [信息]${C_NC} $1"; }
log_warn() { echo -e "${C_YELLOW}⚠  [警告]${C_NC} $1"; }
log_error() { echo -e "${C_RED}✖  [错误]${C_NC} $1"; }
log_step() { echo -e "\n${C_PURPLE}🚀 [步骤 ${1}/${2}]${C_NC} ${C_BOLD}$3${C_NC}"; }
log_success() { echo -e "\n${C_GREEN}🎉🎉🎉 $1 🎉🎉🎉${C_NC}"; }
print_line() { echo -e "${C_BLUE}============================================================${C_NC}"; }

# --- 全局变量 ---
FLASK_APP_NAME="mosdnsui"
PROJECT_DIR="/opt/$FLASK_APP_NAME"
BACKUP_DIR="$PROJECT_DIR/backups"
FLASK_PORT=5001
MOSDNS_ADMIN_URL="http://127.0.0.1:9099"
WEB_USER="nobody" # Alpine使用nobody用户而不是www-data
SYSTEMD_SERVICE_FILE="/etc/init.d/$FLASK_APP_NAME" # Alpine使用OpenRC而不是systemd

# --- 外部下载地址 ---
APP_PY_URL="https://raw.githubusercontent.com/yangzz05/test/refs/heads/main/app.py"
INDEX_HTML_URL="https://raw.githubusercontent.com/yangzz05/test/refs/heads/main/index.html"
APP_PY_PATH="$PROJECT_DIR/app.py"
INDEX_HTML_PATH="$PROJECT_DIR/templates/index.html"
log_file="/var/log/$FLASK_APP_NAME.log"
error_file="/var/log/$FLASK_APP_NAME.err"
# Create log directory if it doesn't exist
mkdir -p "$(dirname "$log_file")"
mkdir -p "$(dirname "$error_file")"

# --- [重构] 辅助命令执行函数 ---
run_command() {
    local message="$1"
    shift # 移除消息参数，剩下的是要执行的命令
    
    # 打印任务描述，使用 printf 控制格式，-55s 表示左对齐，宽度为55
    printf "    %-55s" "$message"

    # 在子shell中执行命令，并将输出重定向到/dev/null
    # shellcheck disable=SC2068
    ($@ &>/dev/null) &
    local pid=$!
    
    # 加载动画
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) % ${#spin} ))
        printf "${C_CYAN}%s${C_NC}" "${spin:$i:1}"
        sleep 0.1
        printf "\b"
    done
    wait $pid
    local ret=$?

    # 打印最终状态
    if [ $ret -eq 0 ]; then
        echo -e "[ ${C_GREEN}成功${C_NC} ]"
        return 0
    else
        echo -e "[ ${C_RED}失败${C_NC} ]"
        # 失败时不需要打印命令，因为主调函数会处理
        return 1
    fi
}

# --- 卸载函数 ---
uninstall_monitor() {
    log_warn "正在执行卸载/清理操作..."
    if [ -f "$SYSTEMD_SERVICE_FILE" ] && /etc/init.d/$FLASK_APP_NAME status >/dev/null 2>&1; then
        run_command "停止服务" /etc/init.d/$FLASK_APP_NAME stop
        run_command "移除服务启动项" rc-update del $FLASK_APP_NAME default
    fi
    if [ -f "$SYSTEMD_SERVICE_FILE" ]; then
        run_command "移除服务文件" rm -f "$SYSTEMD_SERVICE_FILE"
    fi
    if [ -d "$PROJECT_DIR" ]; then
        run_command "移除项目目录 $PROJECT_DIR" rm -rf "$PROJECT_DIR"
    fi
    log_success "卸载/清理操作完成！"
}

# --- 部署函数 ---
deploy_monitor() {
    print_line
    echo -e "${C_BLUE}  🚀  开始部署 MosDNS 监控面板 v7.3 (Alpine版)  🚀${C_NC}"
    print_line
    
    log_step 1 5 "环境检测与依赖安装"
    run_command "测试 MosDNS 接口..." curl --output /dev/null --silent --head --fail "$MOSDNS_ADMIN_URL/metrics" || { log_error "无法访问 MosDNS 接口。"; return 1; }
    
    # Alpine不需要创建www-data用户，使用已有的nobody用户

    run_command "更新 apk 缓存..." apk update
    run_command "安装系统依赖..." apk add python3 py3-pip py3-flask py3-requests curl wget openrc || return 1
    
    log_step 2 5 "创建项目目录结构"
    run_command "创建主目录及子目录..." mkdir -p "$PROJECT_DIR/templates" "$PROJECT_DIR/static" "$BACKUP_DIR" || return 1
    
    log_step 3 5 "下载核心应用文件"
    run_command "下载 app.py..." wget -qO "$APP_PY_PATH" "$APP_PY_URL" || { log_error "下载 app.py 失败！"; return 1; }
    run_command "下载 index.html..." wget -qO "$INDEX_HTML_PATH" "$INDEX_HTML_URL" || { log_error "下载 index.html 失败！"; return 1; }
    run_command "设置文件权限..." chown -R "$WEB_USER:$WEB_USER" "$PROJECT_DIR" || return 1

    log_step 4 5 "创建并配置 OpenRC 服务"
    local python_path; python_path=$(which python3)
    cat <<EOF > "$SYSTEMD_SERVICE_FILE"
#!/sbin/openrc-run

description="MosDNS Monitoring Panel Flask App"
command="$python_path"
command_args="$PROJECT_DIR/app.py"
directory="$PROJECT_DIR"
command_user="$WEB_USER"
command_background=true
pidfile="/run/$FLASK_APP_NAME.pid"
output_log="/var/log/$FLASK_APP_NAME.log"
error_log="/var/log/$FLASK_APP_NAME.err"
export FLASK_PORT="$FLASK_PORT"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -f -o $command_user -m 0644 "$output_log" "$error_log"
}
EOF
    run_command "创建 OpenRC 服务文件..." chmod +x "$SYSTEMD_SERVICE_FILE" || return 1

    log_step 5 5 "启动服务并设置开机自启"
    run_command "添加到默认运行级别..." rc-update add $FLASK_APP_NAME default || return 1
    run_command "启动服务..." /etc/init.d/$FLASK_APP_NAME start || {
        log_error "服务启动失败！"
        log_warn "请查看 /var/log/$FLASK_APP_NAME.err 获取详细日志。"
        return 1
    }
    
    local ip_addr; ip_addr=$(hostname -I | awk '{print $1}')
    print_line
    log_success "部署完成！您的监控面板已准备就绪"
    echo -e "\n${C_CYAN}访问信息:${C_NC}"
    echo -e "  ${C_BOLD}本地访问:${C_NC} http://localhost:$FLASK_PORT"
    echo -e "  ${C_BOLD}局域网访问:${C_NC} http://$ip_addr:$FLASK_PORT"
    echo -e "\n${C_YELLOW}提示:${C_NC} 如果无法访问，请检查防火墙是否允许 $FLASK_PORT 端口访问。"
    return 0
}

# --- 更新函数 ---
update_monitor() {
    print_line
    echo -e "${C_BLUE}  🔄  开始更新 MosDNS 监控面板  🔄${C_NC}"
    print_line
    
    log_step 1 3 "备份当前文件"
    local timestamp; timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_dir="$BACKUP_DIR/$timestamp"
    run_command "创建备份目录..." mkdir -p "$backup_dir/templates" || return 1
    
    if [ -f "$APP_PY_PATH" ]; then
        run_command "备份 app.py..." cp "$APP_PY_PATH" "$backup_dir/" || return 1
    fi
    
    if [ -f "$INDEX_HTML_PATH" ]; then
        run_command "备份 index.html..." cp "$INDEX_HTML_PATH" "$backup_dir/templates/" || return 1
    fi
    
    log_step 2 3 "下载最新文件"
    run_command "下载 app.py..." wget -qO "$APP_PY_PATH" "$APP_PY_URL" || {
        log_error "下载 app.py 失败！正在恢复备份..."
        cp "$backup_dir/app.py" "$APP_PY_PATH" 2>/dev/null
        return 1
    }
    
    run_command "下载 index.html..." wget -qO "$INDEX_HTML_PATH" "$INDEX_HTML_URL" || {
        log_error "下载 index.html 失败！正在恢复备份..."
        cp "$backup_dir/templates/index.html" "$INDEX_HTML_PATH" 2>/dev/null
        return 1
    }
    
    run_command "设置文件权限..." chown -R "$WEB_USER:$WEB_USER" "$PROJECT_DIR" || return 1
    
    log_step 3 3 "重启服务"
    run_command "重启服务..." /etc/init.d/$FLASK_APP_NAME restart || {
        log_error "服务重启失败！请检查日志。"
        return 1
    }
    
    log_success "更新完成！监控面板已更新到最新版本"
    return 0
}

# --- 诊断函数 ---
diagnose_monitor() {
    print_line
    echo -e "${C_BLUE}  🔍  开始诊断 MosDNS 监控面板  🔍${C_NC}"
    print_line
    
    echo -e "\n${C_CYAN}[1/5] 检查系统环境:${C_NC}"
    echo -e "  操作系统: $(cat /etc/os-release | grep PRETTY_NAME | cut -d '"' -f 2)"
    echo -e "  Python版本: $(python3 --version 2>/dev/null || echo '未安装')"
    echo -e "  pip版本: $(pip3 --version 2>/dev/null || echo '未安装')"
    echo -e "  Flask版本: $(pip3 freeze 2>/dev/null | grep Flask || echo '未安装')"
    echo -e "  Requests版本: $(pip3 freeze 2>/dev/null | grep requests || echo '未安装')"
    
    echo -e "\n${C_CYAN}[2/5] 检查项目文件:${C_NC}"
    if [ -d "$PROJECT_DIR" ]; then
        echo -e "  项目目录: ${C_GREEN}存在${C_NC} ($PROJECT_DIR)"
        if [ -f "$APP_PY_PATH" ]; then
            echo -e "  app.py: ${C_GREEN}存在${C_NC}"
        else
            echo -e "  app.py: ${C_RED}不存在${C_NC}"
        fi
        
        if [ -f "$INDEX_HTML_PATH" ]; then
            echo -e "  index.html: ${C_GREEN}存在${C_NC}"
        else
            echo -e "  index.html: ${C_RED}不存在${C_NC}"
        fi
    else
        echo -e "  项目目录: ${C_RED}不存在${C_NC} (应为 $PROJECT_DIR)"
    fi
    
    echo -e "\n${C_CYAN}[3/5] 检查服务状态:${C_NC}"
    if [ -f "$SYSTEMD_SERVICE_FILE" ]; then
        echo -e "  服务文件: ${C_GREEN}存在${C_NC}"
        local service_status; service_status=$(/etc/init.d/$FLASK_APP_NAME status 2>&1)
        echo -e "  服务状态: $service_status"
    else
        echo -e "  服务文件: ${C_RED}不存在${C_NC} (应为 $SYSTEMD_SERVICE_FILE)"
    fi
    
    echo -e "\n${C_CYAN}[4/5] 检查网络连接:${C_NC}"
    if curl --output /dev/null --silent --head --fail "$MOSDNS_ADMIN_URL/metrics"; then
        echo -e "  MosDNS metrics接口: ${C_GREEN}可访问${C_NC}"
    else
        echo -e "  MosDNS metrics接口: ${C_RED}不可访问${C_NC} (URL: $MOSDNS_ADMIN_URL/metrics)"
    fi
    
    if curl --output /dev/null --silent --head --fail "http://localhost:$FLASK_PORT"; then
        echo -e "  监控面板: ${C_GREEN}可访问${C_NC} (http://localhost:$FLASK_PORT)"
    else
        echo -e "  监控面板: ${C_RED}不可访问${C_NC} (http://localhost:$FLASK_PORT)"
    fi
    
    echo -e "\n${C_CYAN}[5/5] 检查日志:${C_NC}"
    if [ -f "/var/log/$FLASK_APP_NAME.err" ]; then
        echo -e "  错误日志 (最后10行):\n"
        tail -n 10 "/var/log/$FLASK_APP_NAME.err" | sed 's/^/    /'
    else
        echo -e "  错误日志: ${C_RED}不存在${C_NC}"
    fi
    
    print_line
    echo -e "${C_BLUE}  诊断完成  ${C_NC}"
    print_line
}

# --- 主菜单函数 ---
show_menu() {
    clear
    print_line
    echo -e "${C_BLUE}  🔍  MosDNS 监控面板管理工具 (Alpine版) v7.3  🔍${C_NC}"
    print_line
    echo -e "  ${C_BOLD}1.${C_NC} 部署监控面板"
    echo -e "  ${C_BOLD}2.${C_NC} 更新监控面板"
    echo -e "  ${C_BOLD}3.${C_NC} 卸载监控面板"
    echo -e "  ${C_BOLD}4.${C_NC} 诊断监控面板"
    echo -e "  ${C_BOLD}0.${C_NC} 退出"
    print_line
    echo -n "  请输入选项 [0-4]: "
    read -r choice
    
    case $choice in
        1) deploy_monitor ;;
        2) update_monitor ;;
        3) uninstall_monitor ;;
        4) diagnose_monitor ;;
        0) exit 0 ;;
        *) log_error "无效选项，请重新选择" ; sleep 2 ; show_menu ;;
    esac
    
    echo -e "\n按 Enter 键返回主菜单..."
    read -r
    show_menu
}

# --- 脚本入口 ---
if [ "$(id -u)" -ne 0 ]; then
    log_error "此脚本需要 root 权限运行。请使用 sudo 或以 root 身份运行。"
    exit 1
 fi

# 显示主菜单
show_menu
