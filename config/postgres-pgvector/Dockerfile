ARG TIMESCALEDB_IMAGE=timescale/timescaledb:latest-pg16
FROM ${TIMESCALEDB_IMAGE}

RUN apk add --no-cache postgresql-pgvector

# PostGIS: 默认仓库针对 pg17 编译，此镜像为 pg16（/usr/local），故从 alpine 3.20 仓库
# 安装针对 postgresql16 编译的 postgis，再复制扩展文件到 /usr/local 的 PG 目录
RUN apk add --no-cache 'postgis<3.5' \
      --repository=https://dl-cdn.alpinelinux.org/alpine/v3.20/community \
      --repository=https://dl-cdn.alpinelinux.org/alpine/v3.20/main \
 && cp -r /usr/share/postgresql16/extension/. /usr/local/share/postgresql/extension/ \
 && cp -r /usr/lib/postgresql16/. /usr/local/lib/postgresql/
