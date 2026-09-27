-- Local stand-in for the shared Cloud SQL for MySQL instance.
--
-- One instance, one application user, one schema per tenant. That is exactly the
-- "Shared Application - Multi-Database" model in the architecture: tenants are
-- isolated at the schema boundary, not by separate instances.

CREATE DATABASE IF NOT EXISTS tenant_acme        CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS tenant_whiteknight CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS tenant_frdm        CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- The application user gets DML plus the DDL it needs for migrations, scoped to
-- the tenant_% pattern. It deliberately has no rights outside that prefix.
CREATE USER IF NOT EXISTS 'app'@'%' IDENTIFIED BY 'secret';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, REFERENCES
    ON `tenant\_%`.* TO 'app'@'%';

-- tenants:migrate connects to information_schema to issue CREATE DATABASE for a
-- schema that does not exist yet, so it needs the global create privilege too.
GRANT CREATE ON *.* TO 'app'@'%';

FLUSH PRIVILEGES;
