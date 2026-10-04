/*
===============================================================================
DDL Script: Create Silver Tables
===============================================================================
Script Purpose:
    This script creates tables in the 'silver' schema as part of the 
    data warehouse transformation layer.

    Features:
        - Primary Keys and NOT NULL constraints for data integrity.
        - Non-Clustered Indexes to improve query performance.
        - dwh_hash_full column to store binary hashes for change detection.
        - Clustered Columnstore Index on sales table for analytical performance.
===============================================================================
*/

-- 1. silver.crm_cust_info
IF OBJECT_ID('silver.crm_cust_info', 'U') IS NOT NULL
    DROP TABLE silver.crm_cust_info;
GO

CREATE TABLE silver.crm_cust_info (
    cst_id              INT NOT NULL,           
    cst_key             NVARCHAR(50) NOT NULL,  
    cst_firstname       NVARCHAR(50),
    cst_lastname        NVARCHAR(50),
    cst_marital_status  NVARCHAR(50),
    cst_gndr            NVARCHAR(50),
    cst_create_date     DATE,
    dwh_hash_full       VARBINARY(32),          -- Fingerprint for change detection
    dwh_create_date     DATETIME2 DEFAULT GETDATE(),
    CONSTRAINT PK_silver_crm_cust_info PRIMARY KEY (cst_id)
);
GO

CREATE NONCLUSTERED INDEX ix_silver_crm_cust_info_cst_key 
    ON silver.crm_cust_info (cst_key);
GO

-- 2. silver.crm_prd_info (Upgraded for SCD Type 2)
IF OBJECT_ID('silver.crm_prd_info', 'U') IS NOT NULL
    DROP TABLE silver.crm_prd_info;
GO

CREATE TABLE silver.crm_prd_info (
    prd_id          INT NOT NULL,              
    cat_id          NVARCHAR(50),
    prd_key         NVARCHAR(50) NOT NULL,     
    prd_nm          NVARCHAR(255),
    prd_cost        INT,
    prd_line        NVARCHAR(50),
    effective_date  DATETIME DEFAULT GETDATE(), 
    expiry_date     DATETIME NULL,              
    is_current      BIT DEFAULT 1,              
    dwh_hash_full   VARBINARY(32),              -- Fingerprint for change detection
    dwh_create_date DATETIME2 DEFAULT GETDATE()
);
GO

CREATE NONCLUSTERED INDEX ix_silver_crm_prd_info_prd_key 
    ON silver.crm_prd_info (prd_key);
GO

-- 3. silver.crm_sales_details
IF OBJECT_ID('silver.crm_sales_details', 'U') IS NOT NULL
    DROP TABLE silver.crm_sales_details;
GO

CREATE TABLE silver.crm_sales_details (
    sls_ord_num     NVARCHAR(50) NOT NULL,     
    sls_prd_key     NVARCHAR(50) NOT NULL,     
    sls_cust_id     INT NOT NULL,              
    sls_order_dt    DATE,
    sls_ship_dt     DATE,
    sls_due_dt      DATE,
    sls_sales       MONEY, -- CHANGED: Matches Bronze MONEY for decimal precision
    sls_quantity    INT,
    sls_price       MONEY, -- CHANGED: Matches Bronze MONEY for decimal precision
    dwh_create_date DATETIME2 DEFAULT GETDATE()
);
GO

-- NEW: Clustered Columnstore Index for Level 6 Performance Optimization
CREATE CLUSTERED COLUMNSTORE INDEX CCI_crm_sales_details 
    ON silver.crm_sales_details;
GO

CREATE NONCLUSTERED INDEX ix_silver_crm_sales_details_sls_prd_key 
    ON silver.crm_sales_details (sls_prd_key);
GO

CREATE NONCLUSTERED INDEX ix_silver_crm_sales_details_sls_cust_id 
    ON silver.crm_sales_details (sls_cust_id);
GO

-- 4. silver.erp_loc_a101
IF OBJECT_ID('silver.erp_loc_a101', 'U') IS NOT NULL
    DROP TABLE silver.erp_loc_a101;
GO

CREATE TABLE silver.erp_loc_a101 (
    cid             NVARCHAR(50) NOT NULL,     
    cntry           NVARCHAR(50),
    dwh_hash_full   VARBINARY(32),             -- Fingerprint for change detection
    dwh_create_date DATETIME2 DEFAULT GETDATE(),
    CONSTRAINT PK_silver_erp_loc_a101 PRIMARY KEY (cid)
);
GO

CREATE NONCLUSTERED INDEX ix_silver_erp_loc_a101_cid 
    ON silver.erp_loc_a101 (cid);
GO

-- 5. silver.erp_cust_az12
IF OBJECT_ID('silver.erp_cust_az12', 'U') IS NOT NULL
    DROP TABLE silver.erp_cust_az12;
GO

CREATE TABLE silver.erp_cust_az12 (
    cid             NVARCHAR(50) NOT NULL,     
    bdate           DATE,
    gen             NVARCHAR(50),
    dwh_hash_full   VARBINARY(32),             -- Fingerprint for change detection
    dwh_create_date DATETIME2 DEFAULT GETDATE(),
    CONSTRAINT PK_silver_erp_cust_az12 PRIMARY KEY (cid)
);
GO

CREATE NONCLUSTERED INDEX ix_silver_erp_cust_az12_cid 
    ON silver.erp_cust_az12 (cid);
GO

-- 6. silver.erp_px_cat_g1v2
IF OBJECT_ID('silver.erp_px_cat_g1v2', 'U') IS NOT NULL
    DROP TABLE silver.erp_px_cat_g1v2;
GO

CREATE TABLE silver.erp_px_cat_g1v2 (
    id              NVARCHAR(50) NOT NULL,     
    cat             NVARCHAR(50),
    subcat          NVARCHAR(50),
    maintenance     NVARCHAR(50),
    dwh_hash_full   VARBINARY(32),             -- Fingerprint for change detection
    dwh_create_date DATETIME2 DEFAULT GETDATE(),
    CONSTRAINT PK_silver_erp_px_cat_g1v2 PRIMARY KEY (id)
);
GO
