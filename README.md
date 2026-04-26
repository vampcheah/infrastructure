# infrastructure

本地开发基础设施，基于 Docker Compose，按需启动各类数据库和监控服务。

## 服务一览

| 类别     | 服务                     | 默认端口 |
| -------- | ------------------------ | -------- |
| 数据库   | PostgreSQL (TimescaleDB) | 5432     |
| 数据库   | Redis                    | 6379     |
| 数据库   | MongoDB                  | 27017    |
| 数据库   | MySQL                    | 3306     |
| 对象存储 | RustFS                   | 9000     |
| 管理界面 | pgAdmin                  | 5050     |
| 管理界面 | phpMyAdmin               | 5051     |
| 管理界面 | Mongo Express            | 5052     |
| 管理界面 | Redis Commander          | 5053     |
| 容器管理 | Portainer                | 9443     |

## 首次安装

> 支持 Ubuntu 22.04 / 24.04，需以普通用户（非 root）运行。

```bash
make install
```

脚本会自动完成：

- 安装 Docker CE 和 Docker Compose 插件
- 将当前用户加入 `docker` 用户组
- 从 `.env.example` 生成 `.env` 配置文件，并为各服务自动生成随机密码

安装完成后，若提示需要重新登录，执行：

```bash
newgrp docker
```

## 配置

编辑 `.env` 文件修改端口、密码等默认值（首次安装已自动生成）：

```bash
vi .env
```

## 启动服务

每个服务独立启动，按需使用：

```bash
# 数据库
make up-postgres
make up-redis
make up-mongodb
make up-mysql

# 管理界面（会同时启动对应数据库）
make up-pgadmin          # PostgreSQL 管理界面 → http://localhost:5050
make up-phpmyadmin       # MySQL 管理界面     → http://localhost:5051
make up-mongo-express    # MongoDB 管理界面   → http://localhost:5052
make up-redis-commander  # Redis 管理界面     → http://localhost:5053

# 容器管理
make up-portainer        # Portainer          → http://localhost:9000


```

## 停止服务

```bash
# 停止单个服务
make down-postgres
make down-redis
make down-mongodb
make down-mysql
# ... 其他服务同理

# 停止所有服务（保留数据）
make down

# 停止所有服务并删除数据（危险！）
make down-all
```

## 数据库 Shell

```bash
make pg-shell      # 进入 PostgreSQL 命令行
make redis-cli     # 进入 Redis 命令行
make mongo-shell   # 进入 MongoDB 命令行
make mysql-shell   # 进入 MySQL 命令行
```

## 查看状态和日志

```bash
make status   # 查看所有容器状态
make logs     # 实时查看所有日志
```

## 账号与密码

首次安装时密码由 `setup.sh` 自动随机生成，查看各服务密码：

```bash
cat .env
```

| 服务       | 用户名            | 密码对应的 .env 变量  |
| ---------- | ----------------- | --------------------- |
| PostgreSQL | postgres          | `POSTGRES_PASSWORD`   |
| Redis      | (无)              | `REDIS_PASSWORD`      |
| MongoDB    | admin             | `MONGO_PASSWORD`      |
| MySQL      | root              | `MYSQL_ROOT_PASSWORD` |
| pgAdmin    | admin@infra.local | `PGADMIN_PASSWORD`    |


## 自动化远程部署 (Ansible)

本项目支持通过 Ansible 一键将整个基础设施部署到远程 Linux 服务器。该方式内置了**安全最佳实践**，会专门创建一个隔离的 `infra` 账户用于运行所有容器。

### 部署步骤：

1. **准备环境**：
   在你的**本地控制机**（比如你的笔记本）上安装 Ansible：
   ```bash
   # Ubuntu/Debian
   sudo apt update && sudo apt install ansible rsync -y
   # macOS
   brew install ansible
   ```

2. **配置服务器信息**：
   编辑 `ansible/inventory/hosts.ini`，填入目标服务器的 IP、用户和 SSH 密钥。
   ```ini
   [infrastructure]
   prod_server ansible_host=YOUR_SERVER_IP ansible_user=root ansible_ssh_private_key_file=~/.ssh/id_rsa
   ```

3. **执行部署**：
   进入 `ansible/` 目录：
   ```bash
   cd ansible/
   
   # 步骤一：初始化服务器（安装 Docker、创建隔离的 infra 用户）
   ansible-playbook playbooks/setup_server.yml
   
   # 步骤二：同步代码并启动基础架构
   ansible-playbook playbooks/deploy_infra.yml
   ```
   *注意：如果目标服务器是首次部署，脚本会自动帮你生成所有数据库的随机强密码，保存在远端的 `.env` 中。*

想了解更详细的原理和说明，请查看 [ansible/README.md](./ansible/README.md)。
