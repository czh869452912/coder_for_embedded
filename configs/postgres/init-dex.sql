-- 自动创建 Dex OIDC 服务所需的数据库
-- 此脚本在 postgres 容器首次初始化时执行（数据卷为空时）
-- 若数据库已存在则跳过，不会重复执行
SELECT 'CREATE DATABASE dex OWNER coder'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'dex')\gexec
