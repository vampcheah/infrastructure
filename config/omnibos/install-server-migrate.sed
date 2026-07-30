371s/"$managed_schema"/"$had_deploy"/
390c\
if [ "$had_deploy" = 0 ]; then\
	runtime_container -e "DATABASE_URL=$DATABASE_URL" --schema-check\
fi
403a\
	runtime_container -e "DATABASE_URL=$DATABASE_URL" --schema-check
473a\
if ! owner_container --migrate ||\
	! runtime_container -e "DATABASE_URL=$DATABASE_URL" --schema-check; then\
	rollback_update\
	die "数据库迁移或低权限 schema 检查失败"\
fi
