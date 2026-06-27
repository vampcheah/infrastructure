-- ==============================================================
-- PostgreSQL 初始化脚本
-- 在此为各项目创建数据库，首次启动时自动执行
-- ==============================================================

-- 按需在此添加新项目数据库
-- CREATE DATABASE new_project;

CREATE EXTENSION IF NOT EXISTS vector;

\connect template1
CREATE EXTENSION IF NOT EXISTS vector;

\connect postgres

SELECT 'CREATE DATABASE yummybook'
WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = 'yummybook'
)\gexec

\connect yummybook
CREATE EXTENSION IF NOT EXISTS vector;

\connect postgres

SELECT 'CREATE DATABASE personal_tutor_platform'
WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = 'personal_tutor_platform'
)\gexec

\connect personal_tutor_platform
CREATE EXTENSION IF NOT EXISTS vector;

\connect postgres

SELECT 'CREATE DATABASE arena_shooter'
WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = 'arena_shooter'
)\gexec

SELECT 'CREATE DATABASE arena_shooter_test'
WHERE NOT EXISTS (
    SELECT FROM pg_database WHERE datname = 'arena_shooter_test'
)\gexec
