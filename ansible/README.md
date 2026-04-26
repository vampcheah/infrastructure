# Ansible 自动化部署

基于当前的底层架构构建，你可以通过这个 `ansible/` 目录将你的整个 Docker 基础设施**一键部署**到任何一台全新的 Linux (Ubuntu) 服务器上。

## 1. 准备工作

在你的**本地机器**（比如你的个人电脑或主控机，不是要部署的那台目标服务器）上安装 Ansible：

```bash
# Ubuntu / Debian
sudo apt update && sudo apt install ansible rsync -y

# macOS (Homebrew)
brew install ansible
```

## 2. 配置目标机器

打开 `ansible/inventory/hosts.ini` 文件，填入你的目标服务器信息。例如：

```ini
[infrastructure]
prod_server ansible_host=123.45.67.89 ansible_user=root ansible_ssh_private_key_file=~/.ssh/id_rsa
```

*提示：确保你的本地机器可以通过 SSH 密钥免密登录到这台目标机器。*

## 3. 执行部署

进入到 `ansible` 目录下执行。

### 第一步：初始化服务器并创建隔离用户 (仅首次需要)
安装系统依赖、配置 GPG 密钥、安装 Docker 和 Compose 插件。
更重要的是，它会在目标服务器上创建一个专用的受限用户（默认名为 `infra`），专门用于运行你的基础设施，从而与 `root` 权限实现安全隔离。
```bash
ansible-playbook playbooks/setup_server.yml
```

### 第二步：同步代码并启动服务 (代码更新时可重复执行)
将本地除了 `.git` 和数据目录之外的代码增量同步到目标机器的 `/opt/002_infrastructure` 目录。
在这个过程中，Ansible 会自动切换到上面创建的 `infra` 用户身份执行。
如果远端没有 `.env`，它会自动从 `.env.example` 复制并为各大数据库生成**随机且安全**的强密码。
最后以 `infra` 用户身份自动执行 `make up-portainer` 和 `make caddy-trust`。
```bash
ansible-playbook playbooks/deploy_infra.yml
```

## 4. 远端验证

部署完成后，你就可以通过目标服务器的 IP 或绑定的域名访问了。
如果你只使用 IP，可以通过 `https://<服务器IP>:9990` （或者如果你配了 hosts，也可以使用 `portainer.localhost` 等）访问 Portainer 界面。
密码等敏感信息已自动写入目标服务器的 `/opt/002_infrastructure/.env` 文件中。
