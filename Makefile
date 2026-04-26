.PHONY: help install \
        up-postgres up-redis up-mongodb up-mysql up-rustfs \
        up-pgadmin up-phpmyadmin up-mongo-express up-redis-commander \
        up-portainer up-caddy caddy-trust caddy-reload \
        up-backup backup-build backup-run backup-logs down-backup \
        down-postgres down-redis down-mongodb down-mysql down-rustfs \
        down-pgadmin down-phpmyadmin down-mongo-express down-redis-commander \
        down-portainer down-caddy \
        down down-all status logs \
        pg-shell redis-cli mongo-shell mysql-shell

COMPOSE := docker compose

help:
	@echo ""
	@echo "002_infrastructure - 中央基础设施"
	@echo ""
	@echo "单个服务启动 (up-<服务>):"
	@echo "  make up-postgres          启动 PostgreSQL          :5432"
	@echo "  make up-redis             启动 Redis               :6379"
	@echo "  make up-mongodb           启动 MongoDB             :27017"
	@echo "  make up-mysql             启动 MySQL               :3306"
	@echo "  make up-pgadmin           启动 pgAdmin             :5050"
	@echo "  make up-phpmyadmin        启动 phpMyAdmin          :5051"
	@echo "  make up-mongo-express     启动 Mongo Express       :5052"
	@echo "  make up-redis-commander   启动 Redis Commander     :5053"
	@echo "  make up-rustfs            启动 RustFS              :9000 (API) :9001 (Console)"
	@echo "  make up-portainer         启动 Portainer           :9443"
	@echo "  make up-caddy             启动 Caddy (HTTPS localhost)"
	@echo "  make caddy-trust          安装本地 CA 到系统信任库（首次使用）"
	@echo "  make caddy-reload         热重载 Caddy 配置（无需重启）"
	@echo ""
	@echo "数据库备份 (ofelia + smart-backup-db):"
	@echo "  make up-backup            启动 ofelia + 注册备份容器"
	@echo "  make backup-build         重建备份镜像"
	@echo "  make backup-run           手动触发一次备份"
	@echo "  make backup-logs          查看最近一次备份日志"
	@echo "  make down-backup          停止 ofelia + 备份容器"
	@echo ""
	@echo "单个服务停止 (down-<服务>):"
	@echo "  make down-postgres / down-redis / down-mongodb / down-mysql"
	@echo "  make down-pgadmin / down-phpmyadmin / down-mongo-express / down-redis-commander"
	@echo "  make down-portainer / down-caddy"
	@echo ""
	@echo "环境安装:"
	@echo "  make install          一键安装 Docker 及所有依赖"
	@echo ""
	@echo "管理命令:"
	@echo "  make down             停止并移除所有容器 (保留数据)"
	@echo "  make down-all         停止并移除所有容器和数据 (危险!)"
	@echo "  make status           查看容器状态"
	@echo "  make logs             查看所有日志"
	@echo ""
	@echo "数据库 Shell:"
	@echo "  make pg-shell         进入 PostgreSQL 命令行"
	@echo "  make redis-cli        进入 Redis 命令行"
	@echo "  make mongo-shell      进入 MongoDB 命令行"
	@echo "  make mysql-shell      进入 MySQL 命令行"
	@echo ""

install:
	@chmod +x setup.sh
	@./setup.sh

# ==============================================================
# 单个服务启动 / 停止
# ==============================================================

up-postgres:
	$(COMPOSE) --profile postgres up -d postgres

up-redis:
	$(COMPOSE) --profile redis up -d redis

up-mongodb:
	$(COMPOSE) --profile mongodb up -d mongodb

up-mysql:
	$(COMPOSE) --profile mysql up -d mysql

up-rustfs:
	$(COMPOSE) --profile rustfs up -d rustfs

down-rustfs:
	docker stop infra-rustfs && docker rm infra-rustfs

up-pgadmin:
	$(COMPOSE) --profile postgres --profile admin up -d pgadmin

up-phpmyadmin:
	$(COMPOSE) --profile mysql --profile admin up -d phpmyadmin

up-mongo-express:
	$(COMPOSE) --profile mongodb --profile admin up -d mongo-express

up-redis-commander:
	$(COMPOSE) --profile redis --profile admin up -d redis-commander

up-portainer:
	$(COMPOSE) --profile portainer up -d portainer

up-caddy:
	$(COMPOSE) --profile caddy up -d caddy

down-caddy:
	docker stop infra-caddy && docker rm infra-caddy

caddy-trust:
	docker exec infra-caddy caddy trust

caddy-reload:
	docker exec infra-caddy caddy reload --config /etc/caddy/Caddyfile

# --- Backup stack ---

up-backup:
	$(COMPOSE) --profile backup up -d

backup-build:
	$(COMPOSE) --profile backup build smart-backup-db

backup-run:
	docker exec infra-smart-backup /opt/smart-backup-db/backup.sh

backup-logs:
	docker exec infra-smart-backup tail -n 200 /var/log/smart-backup-db/log.txt

down-backup:
	$(COMPOSE) --profile backup down

down-postgres:
	docker stop infra-postgres && docker rm infra-postgres

down-redis:
	docker stop infra-redis && docker rm infra-redis

down-mongodb:
	docker stop infra-mongodb && docker rm infra-mongodb

down-mysql:
	docker stop infra-mysql && docker rm infra-mysql

down-pgadmin:
	docker stop infra-pgadmin && docker rm infra-pgadmin

down-phpmyadmin:
	docker stop infra-phpmyadmin && docker rm infra-phpmyadmin

down-mongo-express:
	docker stop infra-mongo-express && docker rm infra-mongo-express

down-redis-commander:
	docker stop infra-redis-commander && docker rm infra-redis-commander

down-portainer:
	docker stop infra-portainer && docker rm infra-portainer

down:
	$(COMPOSE) --profile postgres --profile redis --profile mongodb --profile mysql --profile rustfs --profile admin --profile portainer --profile backup --profile caddy down

down-all:
	@echo "警告: 这将删除所有数据! 按 Ctrl+C 取消，或等待 5 秒继续..."
	@sleep 5
	$(COMPOSE) --profile postgres --profile redis --profile mongodb --profile mysql --profile rustfs --profile admin --profile portainer --profile backup --profile caddy down -v

status:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f

# --- Database Shells ---

pg-shell:
	docker exec -it infra-postgres psql -U $${POSTGRES_USER:-postgres}

redis-cli:
	docker exec -it infra-redis redis-cli

mongo-shell:
	docker exec -it infra-mongodb mongosh -u $${MONGO_USER:-admin} -p $${MONGO_PASSWORD:-admin}

mysql-shell:
	docker exec -it infra-mysql mysql -u root -p$${MYSQL_ROOT_PASSWORD:-root}
