/*
===============================================================================
Stored Procedure: Load Gold Layer (Silver -> Gold)
===============================================================================
Script Purpose:
    This stored procedure performs the ETL process to populate the 'gold'
    schema tables from the 'silver' schema.

Features:
    - Level 4 Audit: Now tracks @batch_id for all table loads and DQ issues.
    - Full Load strategy for Star Schema.
    - Integration of business logic and transformations.
    - Persistent Audit Logging (audit.etl_log).
    - Data Quality Layer (audit.data_quality_issues).
===============================================================================
*/

CREATE OR ALTER PROCEDURE gold.load_gold @batch_id INT = NULL AS
BEGIN
    DECLARE @start_time DATETIME, @end_time DATETIME, @batch_start_time DATETIME, @batch_end_time DATETIME;
    DECLARE @rows_inserted INT;
    DECLARE @dq_errors INT;

    BEGIN TRY
        SET @batch_start_time = GETDATE();

        PRINT '================================================';
        PRINT 'Loading Gold Layer | Batch ID: ' + CAST(ISNULL(@batch_id, 0) AS NVARCHAR);
        PRINT '================================================';

        -- ======================================================
        -- Loading gold.dim_customers
        -- ======================================================
        SET @start_time = GETDATE();
        PRINT '------------------------------------------------';
        PRINT '>> Cleaning Table: gold.dim_customers (Preserving -1)';
        -- Change: Swapped TRUNCATE for DELETE to keep the 'Unknown' member
        DELETE FROM gold.dim_customers WHERE customer_key <> -1; 
        PRINT '>> Inserting Data Into: gold.dim_customers';

        INSERT INTO gold.dim_customers (
            customer_key,
            customer_id,
            customer_number,
            first_name,
            last_name,
            country,
            marital_status,
            gender,
            birthdate,
            create_date
        )
        SELECT
            ROW_NUMBER() OVER (ORDER BY ci.cst_id) AS customer_key, -- Surrogate key
            ci.cst_id AS customer_id,
            ci.cst_key AS customer_number,
            ci.cst_firstname AS first_name,
            ci.cst_lastname AS last_name,
            la.cntry AS country,
            ci.cst_marital_status AS marital_status,
            CASE
                WHEN ci.cst_gndr != 'n/a' THEN ci.cst_gndr -- CRM is primary source
                ELSE COALESCE(ca.gen, 'n/a') -- Fallback to ERP
            END AS gender,
            ca.bdate AS birthdate,
            ci.cst_create_date AS create_date
        FROM silver.crm_cust_info ci
        LEFT JOIN silver.erp_cust_az12 ca ON ci.cst_key = ca.cid
        LEFT JOIN silver.erp_loc_a101 la ON ci.cst_key = la.cid;

        SET @rows_inserted = @@ROWCOUNT;
        SET @end_time = GETDATE();

        -- DQ CHECK: Uniqueness of Surrogate Key
        SELECT @dq_errors = COUNT(*) FROM (SELECT customer_key FROM gold.dim_customers GROUP BY customer_key HAVING COUNT(*) > 1) t;
        IF @dq_errors > 0
            INSERT INTO audit.data_quality_issues (batch_id, table_name, check_name, expected_value, actual_value, issue_description, check_layer)
            VALUES (@batch_id, 'gold.dim_customers', 'Uniqueness Check', '0', CAST(@dq_errors AS NVARCHAR), 'Duplicate customer_key detected', 'Gold');

        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        INSERT INTO audit.etl_log (batch_id, table_name, start_time, end_time, row_count, status)
        VALUES (@batch_id, 'gold.dim_customers', @start_time, @end_time, @rows_inserted, 'Success');
        PRINT '>> -------------';

        -- ======================================================
        -- Loading gold.dim_products
        -- ======================================================
        SET @start_time = GETDATE();
        PRINT '------------------------------------------------';
        PRINT '>> Cleaning Table: gold.dim_products (Preserving -1)';
        -- Change: Swapped TRUNCATE for DELETE to keep the 'Unknown' member
        DELETE FROM gold.dim_products WHERE product_key <> -1;
        PRINT '>> Inserting Data Into: gold.dim_products';

        INSERT INTO gold.dim_products (
            product_key,
            product_id,
            product_number,
            product_name,
            category_id,
            category,
            subcategory,
            maintenance,
            cost,
            product_line,
            start_date
        )
        SELECT
            ROW_NUMBER() OVER (ORDER BY pn.prd_id) AS product_key, -- Surrogate key
            pn.prd_id,
            pn.prd_key,
            pn.prd_nm,
            pn.cat_id,
            pc.cat,
            pc.subcat,
            pc.maintenance,
            pn.prd_cost,
            pn.prd_line,
            pn.effective_date -- Updated to reflect silver column name
        FROM silver.crm_prd_info pn
        LEFT JOIN silver.erp_px_cat_g1v2 pc ON pn.cat_id = pc.id
        WHERE pn.is_current = 1; -- Filter only current version for Gold Dim

        SET @rows_inserted = @@ROWCOUNT;
        SET @end_time = GETDATE();

        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        INSERT INTO audit.etl_log (batch_id, table_name, start_time, end_time, row_count, status)
        VALUES (@batch_id, 'gold.dim_products', @start_time, @end_time, @rows_inserted, 'Success');
        PRINT '>> -------------';

        -- ======================================================
        -- Loading gold.fact_sales
        -- ======================================================
        SET @start_time = GETDATE();
        PRINT '>> Truncating Table: gold.fact_sales';
        TRUNCATE TABLE gold.fact_sales;
        PRINT '>> Inserting Data Into: gold.fact_sales';

        INSERT INTO gold.fact_sales (
            order_number,
            product_key,
            customer_key,
            order_date,
            shipping_date,
            due_date,
            sales_amount,
            quantity,
            price
        )
        SELECT
            sd.sls_ord_num AS order_number,
            ISNULL(pr.product_key, -1) AS product_key, -- Maps missing products to -1
            ISNULL(cu.customer_key, -1) AS customer_key, -- Maps missing customers to -1
            sd.sls_order_dt AS order_date,
            sd.sls_ship_dt AS shipping_date,
            sd.sls_due_dt AS due_date,
            sd.sls_sales AS sales_amount,
            sd.sls_quantity AS quantity,
            sd.sls_price AS price
        FROM silver.crm_sales_details sd
        -- Change: Added SUBSTRING to clean product key to match dim_products.product_number format
        LEFT JOIN gold.dim_products pr ON SUBSTRING(sd.sls_prd_key, 7, LEN(sd.sls_prd_key)) = pr.product_number
        -- Change: Added CAST to ensure sls_cust_id matches the INT format of dim_customers
        LEFT JOIN gold.dim_customers cu ON CAST(sd.sls_cust_id AS INT) = cu.customer_id;

        SET @rows_inserted = @@ROWCOUNT;
        SET @end_time = GETDATE();

        -- DQ CHECK: Referential Integrity (Orphans)
        SELECT @dq_errors = COUNT(*) FROM gold.fact_sales WHERE customer_key = -1 OR product_key = -1;
        IF @dq_errors > 0
            INSERT INTO audit.data_quality_issues (batch_id, table_name, check_name, expected_value, actual_value, issue_description, check_layer)
            VALUES (@batch_id, 'gold.fact_sales', 'Referential Integrity', '0', CAST(@dq_errors AS NVARCHAR), 'Missing key mappings (-1) found in fact table', 'Gold');

        PRINT '>> Load Duration: ' + CAST(DATEDIFF(SECOND, @start_time, @end_time) AS NVARCHAR) + ' seconds';
        INSERT INTO audit.etl_log (batch_id, table_name, start_time, end_time, row_count, status)
        VALUES (@batch_id, 'gold.fact_sales', @start_time, @end_time, @rows_inserted, 'Success');
        PRINT '>> -------------';

        SET @batch_end_time = GETDATE();
        PRINT '=========================================='
        PRINT 'Loading Gold Layer is Completed';
        PRINT ' - Total Load Duration: ' + CAST(DATEDIFF(SECOND, @batch_start_time, @batch_end_time) AS NVARCHAR) + ' seconds';
        PRINT '==========================================';

    END TRY
    BEGIN CATCH
        INSERT INTO audit.etl_log (batch_id, table_name, start_time, end_time, status, error_message)
        VALUES (@batch_id, 'Full Gold Batch', @batch_start_time, GETDATE(), 'Failed', ERROR_MESSAGE());

        PRINT '=========================================='
        PRINT 'ERROR OCCURED DURING LOADING GOLD LAYER'
        PRINT 'Error Message: ' + ERROR_MESSAGE();
        PRINT '=========================================='
    END CATCH
END
