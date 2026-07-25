#!/usr/bin/env bash
# ============================================================
# 002_infrastructure - 完全卸载并重新安装 Docker 脚本
#
# 用法: chmod +x reinstall-docker.sh && ./reinstall-docker.sh
#       或执行: make reinstall-docker
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

echo -e "${RED}============================================================${NC}"
echo -e "${RED} 警告：此脚本将彻底删除 Docker 及其所有镜像、容器和数据！${NC}"
echo -e "${RED}============================================================${NC}"
echo ""

if [[ "${1:-}" != "--force" ]]; then
    read -rp "确定要继续卸载并重装 Docker 吗？(y/N): " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        echo "已取消操作。"
        exit 0
    fi
fi

echo -e "${BLUE}[1/4] 停止并清理所有容器与数据卷...${NC}"
if command -v docker &>/dev/null; then
    sudo docker stop $(sudo docker ps -aq) 2>/dev/null || true
    sudo docker system prune -a --volumes -f 2>/dev/null || true
fi

echo -e "${BLUE}[2/4] 停止 Docker 服务...${NC}"
sudo systemctl stop docker docker.socket containerd 2>/dev/null || true

echo -e "${BLUE}[3/4] 卸载 Docker 软件包并清理残留文件...${NC}"
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras 2>/dev/null || true
sudo rm -rf /var/lib/docker
sudo rm -rf /var/lib/containerd
sudo rm -rf /etc/docker
sudo rm -rf /etc/apt/keyrings/docker.gpg
sudo rm -f /etc/apt/sources.list.d/docker.list
sudo apt-get autoremove -y --purge

echo -e "${GREEN}[OK] Docker 已彻底卸载。${NC}"
echo ""
echo -e "${BLUE}[4/4] 重新执行 setup.sh 进行干净安装...${NC}"
chmod +x "$SCRIPT_DIR/setup.sh"
"$SCRIPT_DIR/setup.sh"

echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} Docker 完全重装完成！${NC}"
echo -e "${GREEN}============================================================${NC}"
