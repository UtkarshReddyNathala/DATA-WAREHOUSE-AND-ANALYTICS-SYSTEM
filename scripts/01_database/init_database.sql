/*
=============================================================
Create Database and Schemas (Corrected)
=============================================================
Script Purpose:
This script creates the 'DataWarehouse' database and initializes 
all five required schemas to support the Audit and Master Pipeline framework.

WARNING:
Running this script will drop the entire 'DataWarehouse' database if it exists.
Proceed with caution.
*/

USE master;
GO

-- Drop and recreate the 'DataWarehouse' database
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'DataWarehouse')
BEGIN
    ALTER DATABASE DataWarehouse SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE DataWarehouse;
END;
GO

-- Create the 'DataWarehouse' database
CREATE DATABASE DataWarehouse;
GO

USE DataWarehouse;
GO

-- =============================================================
-- Create Schemas
-- =============================================================

-- Layer Schemas (Data Storage)
CREATE SCHEMA bronze;
GO

CREATE SCHEMA silver;
GO

CREATE SCHEMA gold;
GO

-- Management Schemas (Framework & Logging)
CREATE SCHEMA audit; -- Sole owner of this schema; ddl_audit.sql only creates the tables
GO

CREATE SCHEMA init;  -- NEW: Required for the Master Load Procedure
GO

PRINT '------------------------------------------------';
PRINT 'Database and All Schemas (5) Created Successfully';
PRINT '------------------------------------------------';
