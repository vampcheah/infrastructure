# smart-backup-db

用 Bash 实现的轻量数据库自动备份工具。支持 MySQL 与 PostgreSQL，可选目标为本地磁盘或 S3，大库自动分割。

在本仓库中以 **常驻容器 + ofelia `job-exec` 调度** 方式运行（由 `002_infrastructure/docker-compose.yml` 的 `backup` profile 编排）：备份容器以 `sleep infinity` 常驻，ofelia 到点通过 `docker exec` 触发 `backup.sh`。原主机 cron + `install.sh` 的方式仍保留，仅作归档参考，不再推荐。

## 功能

- MySQL + PostgreSQL，任意多个实例
- 指定备份哪些库，或用 `all` 自动发现
- 流式 `dump | gzip | split`，大库不落中间文件
- 目标：本地目录 或 S3
- 保留策略：自动清理本地与 S3 上超过 N 天的备份
- 所有成功/失败都写入 `log.txt`，带时间戳
- cron 定时调度
- 配套 `restore.sh`：支持本地/S3，并对生产库误覆盖设有保护

## 依赖

**Docker 模式（推荐）**：镜像内已打包 `bash` / coreutils / `mysql-client` / `postgresql-client` / `awscli`，主机只需有 Docker，无需额外安装。

**主机 cron 模式（附录，归档）**：

```bash
sudo apt install -y mysql-client postgresql-client awscli
```

## 部署（Docker + ofelia，推荐）

所有操作均在 `002_infrastructure/` 目录下执行。

### 1. 准备配置

编辑 `config/smart-backup-db/config.sh`（见下方"配置项"）。`TARGETS` 中 host 用 `infra_shared` 网络上的容器名，如 `infra-mysql`、`infra-postgres`。

### 2. 准备凭证（gitignored，chmod 600）

从模板复制并填入真实密码：

```bash
cd config/smart-backup-db/credentials
cp my.cnf.example my.cnf
cp pgpass.example pgpass
chmod 600 my.cnf pgpass
# 然后编辑两个文件，替换 CHANGE_ME 为真实密码
```

> ⚠️ 这两个文件必须在 `make up-backup` **之前**存在。否则 Docker bind-mount 会把不存在的源路径自动创建为目录，导致容器启动后无法读取凭据。

### 3. 设置 `.env`

```
TZ=Asia/Kuala_Lumpur
BACKUP_CRON_SCHEDULE=0 0 3 * * *    # ofelia 6 段 cron: 秒 分 时 日 月 周
```

### 4. 启动

```bash
make backup-build     # 首次 / 代码改动后
make up-backup        # 起 ofelia + 常驻备份容器，并注册调度
```

### 5. 手动触发 / 查看

```bash
make backup-run       # docker exec 立刻跑一次（挂着看输出）
make backup-logs      # tail log.txt 最近 200 行
docker logs -f infra-ofelia   # 看 ofelia 是否到点触发
```

### 6. 上线前检查清单

按顺序执行，确认每一步都 OK 再离开：

```bash
# 1. 确认依赖 DB 已启动并可连通
make up-mysql up-postgres          # 按实际所需
docker ps | grep -E 'infra-(mysql|postgres)'

# 2. 凭证文件存在且权限 600
ls -l config/smart-backup-db/credentials/my.cnf config/smart-backup-db/credentials/pgpass

# 3. 构建镜像 + 启动备份栈
make backup-build
make up-backup
docker ps | grep -E 'infra-(ofelia|smart-backup)'   # 两个都应 Up

# 4. 手动跑一次，确认产出与日志
make backup-run
ls data/smart-backup-db/backups/                    # 应见时间戳目录
find data/smart-backup-db/backups/ -name '*.part-*' # 应见分片文件
make backup-logs                                    # 末尾应为 status=OK

# 5. 确认 ofelia 已注册 job（无解析错误）
docker logs infra-ofelia 2>&1 | grep -i 'smart-backup-db'

# 6.（可选）把 BACKUP_CRON_SCHEDULE 临时改为 "*/30 * * * * *"
#    观察 30 秒内 ofelia 是否真的触发执行，验证后改回 "0 0 3 * * *"
#    改完需重启 ofelia 让标签生效: make down-backup && make up-backup
```

### 7. 恢复

```bash
docker compose run --rm --no-deps smart-backup-db \
  /opt/smart-backup-db/restore.sh \
    --source local \
    --path /var/backups/db/20260412_030000 \
    --db main-mysql__app \
    --target-db app_restored
```

---

## 配置项

编辑 `config/smart-backup-db/config.sh`：

| 变量 | 说明 |
|---|---|
| `DESTINATION` | `local` 或 `s3` |
| `OUTPUT_DIR` | 本地备份目录（S3 模式下也作为临时暂存） |
| `S3_BUCKET` | 仅 `DESTINATION=s3` 使用，如 `s3://my-bucket/db-backups` |
| `RETENTION_DAYS` | 默认保留天数（未指定 per-db 的库使用此值），默认 7 |
| `SPLIT_SIZE` | 分割阈值，如 `1G`、`500M` |
| `LOG_FILE` | 日志路径 |
| `TARGETS` | 备份目标列表（见下） |

`TARGETS` 每行格式：

```
type|name|host|port|user|databases
```

示例：

```bash
TARGETS=(
  "mysql|main-mysql|infra-mysql|3306|root|app:30,analytics:7"
  "postgres|main-pg|infra-postgres|5432|postgres|all"
)
```

数据库名后加 `:N` 可覆盖保留天数（如 `app:30` 保留 30 天）；未写 `:N` 的以及 `all` 自动发现的库，均使用 `RETENTION_DAYS`。清理按文件名前缀 `${name}__${db}` 分组进行，互不影响。

- `databases`：逗号分隔的库名，或 `all` 自动发现（系统库自动排除）

### S3 目标（可选）

设置 `DESTINATION=s3` + `S3_BUCKET`，并在 `docker-compose.yml` 中取消注释 `~/.aws:/root/.aws:ro` volume，或通过 `.env` 注入 `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`。IAM 需要：`s3:PutObject` `s3:GetObject` `s3:DeleteObject` `s3:ListBucket`。

---

## 附录：主机 cron 方式（不再推荐，仅归档）

### 1. 运行 `install.sh`

```bash
sudo /opt/smart-backup-db/install.sh
```

它会检查依赖、创建日志目录、写入 crontab（每天 03:00 运行）。验证：

```bash
crontab -l
```

## 手动运行

```bash
/opt/smart-backup-db/backup.sh
```

输出文件：

- MySQL：`${OUTPUT_DIR}/<时间戳>/<name>__<db>.sql.gz.part-000`（必要时有 part-001、002...）
- PostgreSQL：`${OUTPUT_DIR}/<时间戳>/<name>__<db>.dump.part-000`

若 `DESTINATION=s3`，上传后本地副本会被删除。

## 查看日志

所有运行记录在 `LOG_FILE`（默认 `/var/log/smart-backup-db/log.txt`）：

```bash
tail -f /var/log/smart-backup-db/log.txt
```

每次运行以 `=== run start ===` 开始、`=== run end ===` 结束。
- `[OK]` —— 成功
- `[ERROR]` —— 失败
- `[INFO]` / `[WARN]` —— 过程信息

## 恢复备份

恢复前先手动创建空的目标库：

```sql
-- MySQL
CREATE DATABASE app_restored;
```

```bash
# PostgreSQL
createdb app_restored
```

### 从本地恢复

```bash
./restore.sh \
  --source local \
  --path /var/backups/db/20260412_030000 \
  --db main-mysql__app \
  --target-db app_restored
```

### 从 S3 恢复

```bash
./restore.sh \
  --source s3 \
  --path s3://my-bucket/db-backups/20260412_030000 \
  --db main-pg__app \
  --target-db app_restored
```

### 参数

| 参数 | 说明 |
|---|---|
| `--source` | `local` 或 `s3` |
| `--path` | 时间戳目录（本地路径或 S3 URI） |
| `--db` | 备份文件前缀，格式为 `<name>__<db>` |
| `--target-db` | 恢复到的目标库（必须**预先创建**且**与 `config.sh` 中的生产库名不同**） |
| `--type` | `mysql` 或 `postgres`，可省略（按扩展名自动识别） |
| `--host` | 默认 `127.0.0.1` |
| `--port` | 默认 3306 / 5432 |
| `--user` | 默认 `root` / `postgres` |
| `--force` | 允许 `--target-db` 与生产库名相同（慎用） |

### 安全机制

默认情况下，`restore.sh` **拒绝**把数据恢复到任何在 `config.sh` 的 `TARGETS` 里列出的生产库名，防止误覆盖。确认要覆盖时再加 `--force`。

## 文件结构

```
smart-backup-db/
├── backup.sh         主入口（cron 调用）
├── restore.sh        恢复脚本
├── config.sh         配置
├── install.sh        依赖检查 + crontab 安装
├── lib/
│   ├── mysql.sh      mysqldump + 库枚举
│   ├── postgres.sh   pg_dump + 库枚举
│   ├── upload.sh     S3 上传/列表/删除
│   ├── retention.sh  本地 + S3 清理
│   └── log.sh        日志函数
└── README.md
```

## 故障排查

| 症状 | 原因 / 解法 |
|---|---|
| `mysqldump: Got error: Access denied` | 检查 `~/.my.cnf`（权限 600，账号/密码正确） |
| `pg_dump: password authentication failed` | 检查 `~/.pgpass`（权限 600，`host` 字段匹配） |
| `aws: command not found` | 装 awscli，或把 `DESTINATION` 改回 `local` |
| cron 不跑 | 看 `/var/log/smart-backup-db/cron.txt`；`crontab -l` 确认条目在 |
| `mysqldump: Unknown table 'column_statistics'` | 客户端版本高于服务端。在 `lib/mysql.sh` 的 `mysqldump` 行加入 `--column-statistics=0` |
| 分片恢复失败 | 必须 `cat part-*` 按顺序拼接后再 gunzip/pg_restore —— `restore.sh` 会自动处理。如手动恢复，务必用 `sort` 确保顺序 |

## 卸载

```bash
crontab -l | grep -v /opt/smart-backup-db/backup.sh | crontab -
sudo rm -rf /opt/smart-backup-db /var/log/smart-backup-db /var/backups/db
```
