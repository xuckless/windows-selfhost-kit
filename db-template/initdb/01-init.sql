-- Runs ONCE, only when the database volume is created for the first time.
-- Good for extensions or roles. Put your tables in the app instead (e.g. Flyway
-- migrations in src/main/resources/db/migration), so schema changes deploy with the code.
-- To re-run this file you would have to delete the volume, which deletes ALL data.

-- Example:
-- CREATE EXTENSION IF NOT EXISTS pgcrypto;
SELECT 1;
