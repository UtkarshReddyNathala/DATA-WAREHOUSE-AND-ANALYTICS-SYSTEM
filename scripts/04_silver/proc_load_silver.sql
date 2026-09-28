/*
===============================================================================
Stored Procedure: Load Silver Layer (Bronze -> Silver)
===============================================================================
Script Purpose:
    This stored procedure performs the ETL process to load data from the 
    'bronze' schema into the 'silver' schema as part of the transformation layer.

Features:
    - Hash-based change detection using HASHBYTES.
    - Watermark (CDC) framework for incremental and delta loading.
    - Hybrid loading strategy:
        • Incremental (SCD Type 1) for Customers
        • SCD Type 2 for Products
        • Delta Load for Sales
    - Metadata-driven dynamic loading for ERP tables.
    - Individual table-level transaction handling.
    - Persistent audit logging using audit.etl_log.
    - Data quality validation using audit.data_quality_issues.
===============================================================================
*/

CREATE OR ALTER PROCEDURE silver.load_silver @batch_id INT = NULL AS
BEGIN
    DECLARE @start_time DATETIME, @end_time DATETIME, @batch_start_time DATETIME, @batch_end_time DATETIME; 
    DECLARE @rows_inserted INT;       -- Capture row counts for audit table
    DECLARE @last_watermark DATETIME; -- Variable for CDC tracking

    -- Variables for DQ Checks
    DECLARE @brz_cnt INT, @slv_cnt INT;
    DECLARE @brz_sales_sum MONEY, @slv_sales_sum MONEY;

    BEGIN TRY
        SET @batch_start_time = GETDATE();
        -- Global Transaction removed to allow per-table commits

        PRINT '================================================';
        PRINT 'Loading Silver Layer | Batch ID: ' + CAST(ISNULL(@batch_id, 0) AS NVARCHAR);
        PRINT '================================================';

        PRINT '------------------------------------------------';
        PRINT 'Loading CRM Tables (Hardcoded Logic with Watermarks)';
        PRINT '------------------------------------------------';

        -- ======================================================
        -- Loading silver.crm_cust_info (INCREMENTAL - SCD TYPE 1 with Watermark & Hashing)
        -- ======================================================
        SET @start_time = GETDATE();
        
        -- Get Last Run Date from Watermark table
        SELECT @last_watermark = ISNULL(last_load_date, '1900-01-01') 
        FROM audit.watermark_thresholds 
        WHERE table_name = 'silver.crm_cust_info';

        PRINT '>> Starting Incremental Merge: silver.crm_cust_info (Watermark: ' + CAST(ISNULL(@last_watermark, '1900-01-01') AS NVARCHAR) + ')';
        
        BEGIN TRANSACTION;
            MERGE silver.crm_cust_info AS target
            USING (
                SELECT
                    *,
                    -- Level 7: Generate Hash for Change Detection
                    HASHBYTES('SHA2_256', 
                        CONCAT(
                            ISNULL(CAST(cst_key AS NVARCHAR), ''), '|',
                            ISNULL(cst_firstname, ''), '|',
                            ISNULL(cst_lastname, ''), '|',
                            ISNULL(cst_marital_status, ''), '|',
                            ISNULL(cst_gndr, '')
                        )
                    ) AS source_hash
                FROM (
                    SELECT
                        cst_id,
                        cst_key,
                        TRIM(cst_firstname) AS cst_firstname,
                        TRIM(cst_lastname) AS cst_lastname,
                        CASE 
                            WHEN UPPER(TRIM(cst_marital_status)) = 'S' THEN 'Single'
                            WHEN UPPER(TRIM(cst_marital_status)) = 'M' THEN 'Married'
                            ELSE 'n/a'
                        END AS cst_marital_status,
                        CASE 
                            WHEN UPPER(TRIM(cst_gndr)) = 'F' THEN 'Female'
                            WHEN UPPER(TRIM(cst_gndr)) = 'M' THEN 'Male'
                            ELSE 'n/a'
                        END AS cst_gndr,
                        cst_create_date
                    FROM (
                        SELECT
                            *,
                            ROW_NUMBER() OVER (PARTITION BY cst_id ORDER BY cst_create_date DESC) AS flag_last
                        FROM bronze.crm_cust_info
                        WHERE cst_id IS NOT NULL 
                          AND cst_create_date > @last_watermark -- Delta Filter
                    ) t
                    WHERE flag_last = 1
                ) sub
            ) AS source
            ON (target.cst_id = source.cst_id)
            -- Level 7: Compare hash instead of individual columns
            WHEN MATCHED AND target.dwh_hash_full <> source.source_hash THEN
                UPDATE SET 
                    target.cst_key = source.cst_key,
                    target.cst_firstname = source.cst_firstname,
                    target.cst_lastname = source.cst_lastname,
                    target.cst_marital_status = source.cst_marital_status,
                    target.cst_gndr = source.cst_gndr,
                    target.dwh_hash_full = source.source_hash,
                    target.dwh_create_date = GETDATE()
            WHEN NOT MATCHED THEN
                INSERT (cst_id, cst_key, cst_firstname, cst_lastname, cst_marital_status, cst_gndr, cst_create_date, dwh_hash_full)
                VALUES (source.cst_id, source.cst_key, source.cst_firstname, source.cst_lastname, source.cst_marital_status, source.cst_gndr, source.cst_create_date, source.source_hash);

            SET @rows_inserted = @@ROWCOUNT; 

            -- Update Watermark after success
            -- REFINEMENT: Added DATEADD(day, -1, ...) to create a safety buffer for late-arriving records
            IF @rows_inserted > 0
                UPDATE audit.watermark_thresholds
                SET last_load_date = (SELECT DATEADD(day, -1, MAX(cst_create_date)) FROM bronze.crm_cust_info WHERE cst_create_date > @last_watermark)
                WHERE table_name = 'silver.crm_cust_info';
        COMMIT TRANSACTION;

        SET @end_time = GETDATE();

        -- DQ CHECK: Row Count
        SELECT @brz_cnt = COUNT(DISTINCT cst_id) FROM bronze.crm_cust_info WHERE cst_id IS NOT NULL;
        SELECT @slv_cnt = COUNT(*) FROM silver.crm_cust_info;
        IF @brz_cnt <> @slv_cnt
            INSERT INTO audit.data_quality_issues (batch_id, table_name, check_name, expected_value, actual_value, issue_description, check_layer)
            VALUES (@batch_id, 'silver.crm_cust_info', 'Row Count', @brz_cnt, @slv_cnt, 'Customer record mismatch', 'Silver');

        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        
        INSERT INTO audit.etl_log (batch_id, table_name, start_time, end_time, row_count, status)
        VALUES (@batch_id, 'silver.crm_cust_info', @start_time, @end_time, @rows_inserted, 'Success');
        PRINT '>> -------------';

        -- ======================================================
        -- Loading silver.crm_prd_info (SCD TYPE 2 with Hashing)
        -- ======================================================
        SET @start_time = GETDATE();
        PRINT '>> Starting SCD Type 2 Process: silver.crm_prd_info';

        BEGIN TRANSACTION;
            -- Step 1: Expire existing records using Hash Comparison
            UPDATE target
            SET target.expiry_date = GETDATE(),
                target.is_current = 0
            FROM silver.crm_prd_info target
            JOIN (
                SELECT 
                    prd_id,
                    HASHBYTES('SHA2_256', 
                        CONCAT(
                            ISNULL(prd_nm, ''), '|', 
                            ISNULL(CAST(prd_cost AS NVARCHAR), '0'), '|', 
                            ISNULL(TRIM(prd_line), '')
                        )
                    ) AS source_hash
                FROM bronze.crm_prd_info
            ) source ON target.prd_id = source.prd_id
            WHERE target.is_current = 1
              AND target.dwh_hash_full <> source.source_hash; -- Level 7 Hash Check

            -- Step 2: Insert New versions
            -- FIX: Added check to ensures only records not currently active are inserted
            INSERT INTO silver.crm_prd_info (
                prd_id, cat_id, prd_key, prd_nm, prd_cost, prd_line, effective_date, is_current, dwh_hash_full
            )
            SELECT
                prd_id,
                REPLACE(SUBSTRING(prd_key, 1, 5), '-', '_') AS cat_id,
                SUBSTRING(prd_key, 7, LEN(prd_key)) AS prd_key,
                prd_nm,
                ISNULL(prd_cost, 0) AS prd_cost,
                CASE 
                    WHEN UPPER(TRIM(prd_line)) = 'M' THEN 'Mountain'
                    WHEN UPPER(TRIM(prd_line)) = 'R' THEN 'Road'
                    WHEN UPPER(TRIM(prd_line)) = 'S' THEN 'Other Sales'
                    WHEN UPPER(TRIM(prd_line)) = 'T' THEN 'Touring'
                    ELSE 'n/a'
                END AS prd_line,
                GETDATE() AS effective_date,
                1 AS is_current,
                HASHBYTES('SHA2_256', 
                    CONCAT(
                        ISNULL(prd_nm, ''), '|', 
                        ISNULL(CAST(prd_cost AS NVARCHAR), '0'), '|', 
                        ISNULL(TRIM(prd_line), '')
                    )
                ) AS dwh_hash_full
            FROM bronze.crm_prd_info s
            WHERE NOT EXISTS (
                SELECT 1 FROM silver.crm_prd_info t 
                WHERE t.prd_id = s.prd_id AND t.is_current = 1
            );

            SET @rows_inserted = @@ROWCOUNT; 
        COMMIT TRANSACTION;

        SET @end_time = GETDATE();

        -- DQ CHECK: Duplicate Product Key Detection
        SELECT @slv_cnt = COUNT(prd_key) FROM silver.crm_prd_info WHERE is_current = 1;
        SELECT @brz_cnt = COUNT(DISTINCT prd_key) FROM bronze.crm_prd_info;
        IF @slv_cnt <> @brz_cnt
            INSERT INTO audit.data_quality_issues (batch_id, table_name, check_name, expected_value, actual_value, issue_description, check_layer)
            VALUES (@batch_id, 'silver.crm_prd_info', 'Duplicate Check', @brz_cnt, @slv_cnt, 'Duplicate active product keys detected', 'Silver');

        INSERT INTO audit.etl_log (batch_id, table_name, start_time, end_time, row_count, status)
        VALUES (@batch_id, 'silver.crm_prd_info', @start_time, @end_time, @rows_inserted, 'Success');
        PRINT '>> -------------';

        -- ======================================================
        -- Loading silver.crm_sales_details (DELTA LOAD with Watermark)
        -- ======================================================
        SET @start_time = GETDATE();
        
        -- Get Watermark
        SELECT @last_watermark = ISNULL(last_load_date, '1900-01-01') 
        FROM audit.watermark_thresholds 
        WHERE table_name = 'silver.crm_sales_details';

        PRINT '>> Starting Delta Load: silver.crm_sales_details (Watermark: ' + CAST(ISNULL(@last_watermark, '1900-01-01') AS NVARCHAR) + ')';
        
        BEGIN TRANSACTION;
            INSERT INTO silver.crm_sales_details (
                sls_ord_num, sls_prd_key, sls_cust_id, sls_order_dt, sls_ship_dt, sls_due_dt, sls_sales, sls_quantity, sls_price
            )
            SELECT 
                sls_ord_num, sls_prd_key, sls_cust_id,
                CASE WHEN sls_order_dt = 0 OR LEN(sls_order_dt) != 8 THEN NULL ELSE CAST(CAST(sls_order_dt AS VARCHAR) AS DATE) END,
                CASE WHEN sls_ship_dt = 0 OR LEN(sls_ship_dt) != 8 THEN NULL ELSE CAST(CAST(sls_ship_dt AS VARCHAR) AS DATE) END,
                CASE WHEN sls_due_dt = 0 OR LEN(sls_due_dt) != 8 THEN NULL ELSE CAST(CAST(sls_due_dt AS VARCHAR) AS DATE) END,
                -- FIX: Explicit CAST to MONEY for consistency
                CASE WHEN sls_sales IS NULL OR sls_sales <= 0 OR sls_sales != sls_quantity * ABS(sls_price) THEN CAST(sls_quantity * ABS(sls_price) AS MONEY) ELSE CAST(sls_sales AS MONEY) END,
                sls_quantity,
                CASE WHEN sls_price IS NULL OR sls_price <= 0 THEN CAST(sls_sales / NULLIF(sls_quantity, 0) AS MONEY) ELSE CAST(sls_price AS MONEY) END
            FROM bronze.crm_sales_details
            WHERE sls_order_dt > CAST(CONVERT(VARCHAR, @last_watermark, 112) AS INT); 

            SET @rows_inserted = @@ROWCOUNT; 

            -- Update Watermark
            -- REFINEMENT: Safety buffer maintained
            IF @rows_inserted > 0
                UPDATE audit.watermark_thresholds
                SET last_load_date = (SELECT DATEADD(day, -1, CAST(CAST(MAX(sls_order_dt) AS VARCHAR) AS DATETIME)) FROM bronze.crm_sales_details WHERE sls_order_dt > CAST(CONVERT(VARCHAR, @last_watermark, 112) AS INT))
                WHERE table_name = 'silver.crm_sales_details';
        COMMIT TRANSACTION;

        SET @end_time = GETDATE();

        -- DQ CHECK: Sales Total Reconciliation
        -- FIX: CAST to MONEY to ensure sum comparison doesn't fail due to precision
        SELECT @brz_sales_sum = SUM(CAST(CASE WHEN sls_sales IS NULL OR sls_sales <= 0 THEN sls_quantity * ABS(sls_price) ELSE sls_sales END AS MONEY)) 
        FROM bronze.crm_sales_details 
        WHERE sls_order_dt > CAST(CONVERT(VARCHAR, @last_watermark, 112) AS INT);
        
        SELECT @slv_sales_sum = SUM(sls_sales) 
        FROM silver.crm_sales_details 
        WHERE sls_order_dt > @last_watermark;
        
        IF ISNULL(@brz_sales_sum, 0) <> ISNULL(@slv_sales_sum, 0)
            INSERT INTO audit.data_quality_issues (batch_id, table_name, check_name, expected_value, actual_value, issue_description, check_layer)
            VALUES (@batch_id, 'silver.crm_sales_details', 'Revenue Check', @brz_sales_sum, @slv_sales_sum, 'Sales amount mismatch during delta load', 'Silver');
        
        INSERT INTO audit.etl_log (batch_id, table_name, start_time, end_time, row_count, status)
        VALUES (@batch_id, 'silver.crm_sales_details', @start_time, @end_time, @rows_inserted, 'Success');
        PRINT '>> -------------';

        -- ======================================================
        -- Columnstore Optimization (Maintenance)
        -- ======================================================
        PRINT '>> Optimizing Columnstore Index for Performance...';

        ALTER INDEX CCI_crm_sales_details ON silver.crm_sales_details 
        REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);

        PRINT '>> Columnstore Optimized.';
        PRINT '>> -------------';

        -- ======================================================
        -- LOADING ERP TABLES VIA METADATA ENGINE (DYNAMIC LOAD)
        -- ======================================================
        PRINT '------------------------------------------------';
        PRINT 'Loading ERP Tables (Metadata-Driven Engine)';
        PRINT '------------------------------------------------';
        
        BEGIN TRANSACTION;
            EXEC silver.load_metadata_driven @batch_id = @batch_id;
        COMMIT TRANSACTION;

        -- ======================================================

        SET @batch_end_time = GETDATE();
        PRINT '=========================================='
        PRINT 'Loading Silver Layer is Completed';
        PRINT '   - Total Load Duration: ' + CAST(DATEDIFF(SECOND, @batch_start_time, @batch_end_time) AS NVARCHAR) + ' seconds';
        PRINT '==========================================';
        
    END TRY
    BEGIN CATCH
        -- Check for open transactions in case of error
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        -- Log Failure to Audit
        INSERT INTO audit.etl_log (batch_id, table_name, start_time, end_time, status, error_message)
        VALUES (@batch_id, 'Full Silver Batch', @batch_start_time, GETDATE(), 'Failed', ERROR_MESSAGE());

        PRINT '=========================================='
        PRINT 'ERROR OCCURRED DURING LOADING SILVER LAYER'
        PRINT 'Error Message: ' + ERROR_MESSAGE();
        PRINT '=========================================='
    END CATCH
END
GO
