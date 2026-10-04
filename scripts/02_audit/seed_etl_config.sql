/*
===============================================================================
Seed Script: Populate ETL Configuration (Metadata)
===============================================================================
Script Purpose:
    Single source of truth for the metadata-driven ERP loader
    (silver.load_metadata_driven). init.load_all aborts if no active rows exist.

Prerequisite:
    Run scripts/02_audit/ddl_audit.sql first (creates audit.etl_config).
===============================================================================
*/

USE DataWarehouse;
GO

-- Clear existing config to avoid duplicates during testing
TRUNCATE TABLE audit.etl_config;

INSERT INTO audit.etl_config (source_table, target_table, load_type, is_active, priority)
VALUES 
('bronze.erp_loc_a101',    'silver.erp_loc_a101',    'FULL', 1, 10),
('bronze.erp_cust_az12',   'silver.erp_cust_az12',   'FULL', 1, 20),
('bronze.erp_px_cat_g1v2', 'silver.erp_px_cat_g1v2', 'FULL', 1, 30);

PRINT '>> ETL Configuration Seeded Successfully.';
