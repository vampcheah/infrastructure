# Credentials

从模板复制并填入真实密码，两份文件都 `chmod 600`（已 gitignore）：

```bash
cp my.cnf.example my.cnf
cp pgpass.example pgpass
chmod 600 my.cnf pgpass
# 然后编辑填入真实密码
```

模板见 `my.cnf.example` / `pgpass.example`。

## Why

The containerized `backup.sh` reads these via volume mounts:

- `./credentials/my.cnf` → `/root/.my.cnf`
- `./credentials/pgpass` → `/root/.pgpass`

Never commit real credentials. If you rotate a password, just rewrite the file on the host — no image rebuild needed.
