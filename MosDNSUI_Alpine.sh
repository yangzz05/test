#!/bin/sh

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
log_green() { echo -e "${C_GREEN}$1${C_NC}"; }
print_line() { echo -e "${C_BLUE}============================================================${C_NC}"; }

# --- 全局变量 ---
FLASK_APP_NAME="mosdns_monitor_panel"
PROJECT_DIR="/opt/$FLASK_APP_NAME"
BACKUP_DIR="$PROJECT_DIR/backups"
FLASK_PORT=5001
MOSDNS_ADMIN_URL="http://127.0.0.1:9099"
WEB_USER="nobody"
INIT_SERVICE_FILE="/etc/init.d/$FLASK_APP_NAME"

# --- 外部下载地址 ---
APP_PY_URL="https://raw.githubusercontent.com/Jimmyzxk/MosDNSUI/main/app.py"
INDEX_HTML_URL="https://raw.githubusercontent.com/Jimmyzxk/MosDNSUI/main/index.html"
APP_PY_PATH="$PROJECT_DIR/app.py"
INDEX_HTML_PATH="$PROJECT_DIR/templates/index.html"

# --- [重构] 辅助命令执行函数 ---
run_command() {
    local message="$1"
    shift # 移除消息参数，剩下的是要执行的命令
    
    # 打印任务描述，使用 printf 控制格式，-55s 表示左对齐，宽度为55
    printf "    %-55s" "$message"

    # 在子shell中执行命令，并将输出重定向到/dev/null
    ($@ >/dev/null 2>&1) &
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
    if rc-service $FLASK_APP_NAME status >/dev/null 2>&1; then
        run_command "停止服务" rc-service $FLASK_APP_NAME stop
        run_command "禁用服务" rc-update del $FLASK_APP_NAME default
    fi
    if [ -f "$INIT_SERVICE_FILE" ]; then
        run_command "移除服务文件" rm -f "$INIT_SERVICE_FILE"
    fi
    if [ -d "$PROJECT_DIR" ]; then
        run_command "移除项目目录 $PROJECT_DIR" rm -rf "$PROJECT_DIR"
    fi
    log_success "卸载/清理操作完成！"
}

# --- 部署函数 ---
deploy_monitor() {
    print_line
    echo -e "${C_BLUE}  🚀  开始部署 MosDNS 监控面板 v7.3-alpine  🚀${C_NC}"
    print_line
    
    log_step 1 5 "环境检测与依赖安装"
    run_command "测试 MosDNS 接口..." curl --output /dev/null --silent --head --fail "$MOSDNS_ADMIN_URL/metrics" || { log_error "无法访问 MosDNS 接口。"; return 1; }
    
    # Alpine 使用 nobody 用户，无需创建
    log_info "使用系统 '$WEB_USER' 用户运行服务"

    run_command "更新 apk 缓存..." apk update
    run_command "安装系统依赖..." apk add python3 py3-pip py3-flask py3-requests curl wget || return 1
    
    log_step 2 5 "创建项目目录结构"
    run_command "创建主目录及子目录..." mkdir -p "$PROJECT_DIR/templates" "$PROJECT_DIR/static" "$BACKUP_DIR" || return 1
    
    log_step 3 5 "下载核心应用文件"
    run_command "下载 app.py..." wget -qO "$APP_PY_PATH" "$APP_PY_URL" || { log_error "下载 app.py 失败！"; return 1; }
    run_command "下载 index.html..." wget -qO "$INDEX_HTML_PATH" "$INDEX_HTML_URL" || { log_error "下载 index.html 失败！"; return 1; }
    run_command "设置文件权限..." chown -R "$WEB_USER:$WEB_USER" "$PROJECT_DIR" || return 1

    log_step 4 5 "创建并配置 OpenRC 服务"
    local python_path; python_path=$(which python3)
    cat <<EOF > "$INIT_SERVICE_FILE"
#!/sbin/openrc-run

name="$FLASK_APP_NAME"
description="MosDNS Monitoring Panel Flask App"

supervisor=supervise-daemon
command="$python_path"
command_args="$PROJECT_DIR/app.py"
command_user="$WEB_USER"
command_background=true
pidfile="/run/$FLASK_APP_NAME.pid"
directory="$PROJECT_DIR"

env="FLASK_PORT=$FLASK_PORT"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --owner $command_user:$command_user --mode 0755 \$(dirname $pidfile)
}
EOF
    run_command "创建 OpenRC 服务文件..." chmod +x "$INIT_SERVICE_FILE" || return 1

    log_step 5 5 "启动服务并设置开机自启"
    run_command "启用服务..." rc-update add "$FLASK_APP_NAME" default || return 1
    run_command "启动服务..." rc-service "$FLASK_APP_NAME" start || {
        log_error "服务启动失败！"
        log_warn "请运行 'rc-service $FLASK_APP_NAME status' 查看详细信息。"
        return 1
    }
    
    local ip_addr; ip_addr=$(hostname -i | awk '{print $1}')
    [ -z "$ip_addr" ] && ip_addr=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n 1)
    print_line
    log_success "部署完成！您的监控面板已准备就绪"
    echo -e "${C_CYAN}
    ┌──────────────────────────────────────────────────┐
    │                                                  │
    │   请在浏览器中访问以下地址:                        │
    │   ${C_BOLD}http://${ip_addr}:${FLASK_PORT}${C_NC}                     │
    │                                                  │
    └──────────────────────────────────────────────────┘
    ${C_NC}"
    return 0
}

# --- 更新函数 ---
update_app() {
    print_line; echo -e "${C_BLUE}  🔄  开始一键更新流程  🔄${C_NC}"; print_line
    if [ ! -d "$PROJECT_DIR" ]; then log_error "项目目录不存在，请先部署。"; return 1; fi

    local timestamp; timestamp=$(date +"%Y%m%d-%H%M%S")
    local current_backup_dir="$BACKUP_DIR/$timestamp"
    
    run_command "创建备份目录..." mkdir -p "$current_backup_dir/templates" || return 1
    run_command "备份 app.py..." cp "$APP_PY_PATH" "$current_backup_dir/app.py" || return 1
    run_command "备份 index.html..." cp "$INDEX_HTML_PATH" "$current_backup_dir/templates/index.html" || return 1

    log_info "正在从 GitHub 下载最新版本..."
    run_command "下载新版 app.py..." wget -qO "$APP_PY_PATH" "$APP_PY_URL" || { log_error "下载 app.py 失败！"; return 1; }
    run_command "下载新版 index.html..." wget -qO "$INDEX_HTML_PATH" "$INDEX_HTML_URL" || { log_error "下载 index.html 失败！"; return 1; }
    
    run_command "重设文件权限..." chown -R "$WEB_USER:$WEB_USER" "$PROJECT_DIR"
    
    run_command "重启服务以应用更新..." rc-service "$FLASK_APP_NAME" restart
    
    log_success "更新成功！请刷新浏览器页面查看新版本。"
}

# --- 恢复函数 ---
revert_app() {
    print_line; echo -e "${C_BLUE}  ⏪  开始版本恢复流程  ⏪${C_NC}"; print_line
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR")" ]; then
        log_warn "没有找到任何备份。无法执行恢复操作。"
        return 0
    fi

    log_info "发现以下备份版本（按时间倒序）："
    local backups; backups=$(ls -1r "$BACKUP_DIR")
    local i=1
    for backup in $backups; do
        echo -e "    ${C_YELLOW}$i)${C_NC} ${C_CYAN}$backup${C_NC}"
        i=$((i+1))
    done

    local selection
    read -rp "请输入您要恢复的备份版本编号 (1-$(echo "$backups" | wc -l)): " selection

    if ! [ "$selection" -eq "$selection" ] 2>/dev/null || [ "$selection" -lt 1 ] || [ "$selection" -gt $(echo "$backups" | wc -l) ]; then
        log_error "无效的编号。操作已取消。"
        return 1
    fi

    local selected_backup; selected_backup=$(echo "$backups" | sed -n "${selection}p")
    local selected_backup_dir="$BACKUP_DIR/$selected_backup"
    log_info "您选择了恢复版本: $selected_backup"
    read -rp "确定要用此版本覆盖当前文件吗？(y/N): " CONFIRM

    if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
        run_command "从 $selected_backup_dir 恢复文件..." \
            cp "$selected_backup_dir/app.py" "$APP_PY_PATH" && \
            cp "$selected_backup_dir/templates/index.html" "$INDEX_HTML_PATH"
        run_command "重设文件权限..." chown -R "$WEB_USER:$WEB_USER" "$PROJECT_DIR"
        run_command "重启服务以应用恢复..." rc-service "$FLASK_APP_NAME" restart
        log_success "恢复成功！请刷新浏览器页面。"
    else
        log_info "恢复操作已取消。"
    fi
}

# --- 诊断函数 ---
diagnose_and_fix() {
    print_line; echo -e "${C_BLUE}  🩺  开始一键诊断流程  🩺${C_NC}"; print_line
    
    log_info "检查 MosDNS 服务..."
    if curl --output /dev/null --silent --head --fail "$MOSDNS_ADMIN_URL/metrics"; then
        log_green "✅ MosDNS 服务正常。"
    else
        log_warn "❌ MosDNS 服务无法访问。请手动检查。"
    fi

    log_info "检查监控面板服务..."
    if rc-service "$FLASK_APP_NAME" status >/dev/null 2>&1; then
        log_green "✅ 监控面板服务 ($FLASK_APP_NAME) 正在运行。"
    else
        log_warn "❌ 监控面板服务未运行。尝试重启..."
        run_command "重启监控服务..." rc-service "$FLASK_APP_NAME" restart || log_error "重启失败，请查看日志"
    fi
}

# --- 主程序逻辑 ---
main() {
    clear
    print_line
    echo -e "${C_PURPLE}  __  __  ____  ____    _   _ ____  _   _ ___  _   _${C_NC}"
    echo -e "${C_PURPLE} |  \\/  |/ ___|/ ___|  | \\ | |  _ \\| \\ | |_ _|| \\ | |${C_NC}"
    echo -e "${C_PURPLE} | |\\/| | |  _| |      |  \\| | | | |  \\| || | |  \\| |${C_NC}"
    echo -e "${C_PURPLE} | |  | | |_| | |___   | |\\  | |_| | |\\  || | | |\\  |${C_NC}"
    echo -e "${C_PURPLE} |_|  |_|\\____|\\____|  |_| \\_|____/|_| \\_|___||_| \\_|${C_NC}"
    echo -e "${C_BLUE}        独立监控面板 - Alpine 管理脚本 v7.3-alpine${C_NC}"
    print_line
    echo ""

    if [ "$(id -u)" -ne 0 ]; then
       log_error "此脚本必须以 root 用户运行。请使用 'sudo sh $0'"
       exit 1
    fi

    echo -e "${C_BOLD}请选择您要执行的操作:${C_NC}"
    echo -e "    ${C_YELLOW}1)${C_NC} ${C_CYAN}部署 / 重装监控面板${C_NC}"
    echo -e "    ${C_YELLOW}2)${C_NC} ${C_CYAN}一键更新 (从 GitHub)${C_NC}"
    echo -e "    ${C_YELLOW}3)${C_NC} ${C_CYAN}一键恢复 (从本地备份)${C_NC}"
    echo -e "    ${C_YELLOW}4)${C_NC} ${C_CYAN}一键诊断${C_NC}"
    echo -e "    ${C_YELLOW}5)${C_NC} ${C_RED}卸载监控面板${C_NC}"
    echo -e "    ${C_YELLOW}6)${C_NC} ${C_CYAN}退出脚本${C_NC}"
    echo ""
    
    local choice
    read -rp "请输入选项编号 [1-6]: " choice

    case $choice in
        1)
            read -rp "这将覆盖现有部署。确定吗？ (y/N): " CONFIRM
            if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                uninstall_monitor
                deploy_monitor
            else
                log_info "部署已取消。"
            fi
            ;;
        2)
            read -rp "这将备份当前版本并从GitHub下载最新版。确定吗？ (y/N): " CONFIRM
            if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                update_app
            else
                log_info "更新已取消。"
            fi
            ;;
        3)
            revert_app
            ;;
        4)
            diagnose_and_fix
            ;;
        5)
            read -rp "警告：这将删除所有相关文件、服务和备份！确定吗？(y/N): " CONFIRM
            if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                uninstall_monitor
            else
                log_info "卸载已取消。"
            fi
            ;;
        6)
            log_info "脚本已退出。"
            exit 0
            ;;
        *) 
            log_error "无效的选项。"
            ;;
    esac
    
    echo ""
    print_line
    echo -e "${C_BLUE}    -- 操作完成 --${C_NC}"
    print_line
}

# --- 脚本入口 ---
main "$@"
