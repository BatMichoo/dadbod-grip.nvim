-- Run once by the SQL Server image on first start (see compose.yaml). The seed
-- has no USE of its own, so switch to the database MSSQL_DB created first.
USE grip_test;
GO
:r /seed/seed_mssql.sql
GO
