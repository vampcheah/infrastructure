#!/usr/bin/env bash
# ============================================================
# 002_infrastructure - Ubuntu 环境安装脚本
#
# 用法: chmod +x setup.sh && ./setup.sh
#       或: make install
#
# 支持: Ubuntu 22.04 / 24.04
# 功能: 安装 Docker CE、Docker Compose v2，配置用户权限，
#       初始化项目 .env 文件
# 说明: 脚本可安全重复执行 (幂等)，不要以 root 身份运行
# ============================================================

set -euo pipefail

# --- 常量 ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_MIN_VERSION="24.0"
COMPOSE_MIN_VERSION="2.20"

# 颜色 (非终端时禁用)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

# --- 工具函数 ---

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}   $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

trap 'log_error "脚本在第 ${LINENO} 行失败: ${BASH_COMMAND}"' ERR

command_exists() { command -v "$1" &>/dev/null; }

# 版本比较: version_gte 当前版本 最低版本
version_gte() {
    local current="$1" min="$2"
    [[ "$(printf '%s\n' "$min" "$current" | sort -V | head -n1)" == "$min" ]]
}

check_root() {
    if [[ "${EUID}" -eq 0 ]]; then
        log_error "请不要以 root 身份运行此脚本，脚本内部会在需要时使用 sudo"
        exit 1
    fi
}

check_ubuntu() {
    if [[ ! -f /etc/os-release ]]; then
        log_warn "无法检测操作系统版本"
        return
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        log_warn "当前系统为 ${ID:-unknown}，此脚本针对 Ubuntu 设计，可能不完全兼容"
    elif [[ "${VERSION_ID:-}" != "22.04" && "${VERSION_ID:-}" != "24.04" ]]; then
        log_warn "当前 Ubuntu 版本为 ${VERSION_ID}，推荐 22.04 或 24.04"
    else
        log_success "检测到 Ubuntu ${VERSION_ID}"
    fi
}

# --- 步骤函数 ---

install_prerequisites() {
    log_info "检查系统基础工具..."

    local packages=(
        curl wget git make gnupg lsb-release
        ca-certificates apt-transport-https
        software-properties-common jq
    )
    local missing=()

    for pkg in "${packages[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_success "系统基础工具已就绪"
        return
    fi

    log_info "安装缺失的包: ${missing[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y -qq "${missing[@]}"
    log_success "系统基础工具安装完成"
}

install_docker() {
    log_info "检查 Docker..."

    if command_exists docker; then
        local current_version
        current_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0.0")"
        if version_gte "$current_version" "$DOCKER_MIN_VERSION"; then
            log_success "Docker 已安装 (v${current_version})"
            return
        fi
        log_warn "Docker 版本过低 (v${current_version})，将升级..."
    fi

    log_info "安装 Docker CE..."

    # 移除旧版本
    sudo apt-get remove -y docker docker-engine docker.io containerd runc &>/dev/null || true

    # 添加 Docker 官方 GPG key
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # 添加 apt 源
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # 安装
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    log_success "Docker CE 安装完成"
}

install_docker_compose() {
    log_info "检查 Docker Compose..."

    if docker compose version &>/dev/null; then
        local compose_version
        compose_version="$(docker compose version --short 2>/dev/null || echo "0.0")"
        if version_gte "$compose_version" "$COMPOSE_MIN_VERSION"; then
            log_success "Docker Compose 已安装 (v${compose_version})"
            return
        fi
        log_warn "Docker Compose 版本过低 (v${compose_version})，将升级..."
    fi

    log_info "安装 Docker Compose 插件..."
    sudo apt-get install -y -qq docker-compose-plugin
    log_success "Docker Compose 插件安装完成"
}

configure_docker() {
    log_info "配置 Docker..."

    # 添加用户到 docker 组
    if groups "$USER" | grep -q '\bdocker\b'; then
        log_success "用户 $USER 已在 docker 组中"
    else
        sudo usermod -aG docker "$USER"
        log_success "已将用户 $USER 添加到 docker 组"
        NEED_RELOGIN=true
    fi

    # 开机自启
    if systemctl is-enabled docker &>/dev/null; then
        log_success "Docker 已设置为开机自启"
    else
        sudo systemctl enable docker containerd
        log_success "已启用 Docker 开机自启"
    fi

    # 启动服务
    if systemctl is-active docker &>/dev/null; then
        log_success "Docker 服务正在运行"
    else
        sudo systemctl start docker
        log_success "已启动 Docker 服务"
    fi
}

gen_password() {
    # 生成 24 位随机十六进制密码，无管道避免 pipefail 下的 SIGPIPE 问题
    openssl rand -hex 12
}

setup_project() {
    log_info "初始化项目配置..."

    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        log_success ".env 文件已存在，跳过"
    elif [[ -f "$SCRIPT_DIR/.env.example" ]]; then
        cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
        log_info "正在为各服务生成随机密码..."

        local pw_postgres pw_redis pw_mongo pw_mysql pw_pgadmin
        pw_postgres="$(gen_password)"
        pw_redis="$(gen_password)"
        pw_mongo="$(gen_password)"
        pw_mysql="$(gen_password)"
        pw_pgadmin="$(gen_password)"


        # 替换 .env 中的默认密码
        sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${pw_postgres}|" "$SCRIPT_DIR/.env"
        sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=${pw_redis}|"          "$SCRIPT_DIR/.env"
        sed -i "s|^MONGO_PASSWORD=.*|MONGO_PASSWORD=${pw_mongo}|"          "$SCRIPT_DIR/.env"
        sed -i "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=${pw_mysql}|" "$SCRIPT_DIR/.env"
        sed -i "s|^PGADMIN_PASSWORD=.*|PGADMIN_PASSWORD=${pw_pgadmin}|"    "$SCRIPT_DIR/.env"


        log_success "已从 .env.example 生成 .env 文件（含随机密码）"
    else
        log_warn "未找到 .env.example，请手动创建 .env 文件"
    fi

    # 验证关键文件
    local files=("docker-compose.yml" "Makefile")
    local dirs=("config" "init")

    for f in "${files[@]}"; do
        [[ -f "$SCRIPT_DIR/$f" ]] || log_warn "缺少文件: $f"
    done
    for d in "${dirs[@]}"; do
        [[ -d "$SCRIPT_DIR/$d" ]] || log_warn "缺少目录: $d"
    done
}

verify_installation() {
    echo ""
    echo "============================================================"
    echo " 安装验证"
    echo "============================================================"

    local docker_ver compose_ver docker_status group_status env_status

    docker_ver="$(docker --version 2>/dev/null || echo '未安装')"
    compose_ver="$(docker compose version 2>/dev/null || echo '未安装')"
    docker_status="$(systemctl is-active docker 2>/dev/null || echo '未运行')"

    if groups "$USER" 2>/dev/null | grep -q '\bdocker\b'; then
        group_status="是"
    else
        group_status="否 (需重新登录)"
    fi

    [[ -f "$SCRIPT_DIR/.env" ]] && env_status="已生成" || env_status="缺失"

    printf "  %-20s %s\n" "Docker:" "$docker_ver"
    printf "  %-20s %s\n" "Compose:" "$compose_ver"
    printf "  %-20s %s\n" "Docker 服务:" "$docker_status"
    printf "  %-20s %s\n" "用户在 docker 组:" "$group_status"
    printf "  %-20s %s\n" ".env 文件:" "$env_status"

    echo "============================================================"

    if [[ "${NEED_RELOGIN:-false}" == "true" ]]; then
        echo ""
        log_warn "============================================"
        log_warn " 请注销并重新登录，或执行: newgrp docker"
        log_warn " 以使 docker 用户组权限生效"
        log_warn "============================================"
    fi

    echo ""
    log_info "下一步:"
    echo "  1. ${NEED_RELOGIN:+newgrp docker        # 使 docker 组权限生效}"
    echo "  ${NEED_RELOGIN:+2. }cd $SCRIPT_DIR"
    echo "  ${NEED_RELOGIN:+3. }make help            # 查看可用命令"
    echo "  ${NEED_RELOGIN:+4. }make up-postgres     # 启动 PostgreSQL"
    echo ""
}

# --- 主函数 ---

main() {
    echo ""
    log_info "开始 002_infrastructure 环境配置..."
    echo ""

    NEED_RELOGIN=false

    check_root
    check_ubuntu

    install_prerequisites
    install_docker
    install_docker_compose
    configure_docker
    setup_project
    verify_installation

    log_success "环境配置完成!"
    echo ""
}

main "$@"
