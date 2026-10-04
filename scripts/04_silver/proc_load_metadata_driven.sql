/*
===============================================================================
Stored Procedure: Load Silver Layer (Metadata-Driven Full Load)
===============================================================================
Purpose:
    Dynamically loads data from Source tables to Silver tables
    based on configuration stored in audit.etl_config.
===============================================================================
*/

CREATE OR ALTER PROCEDURE silver.load_metadata_driven 
    @batch_id INT = NULL 
AS
BEGIN
    -- Variable declarations
    DECLARE @src NVARCHAR(255),        -- Source table name
            @tgt NVARCHAR(255),        -- Target table name
            @sql NVARCHAR(MAX);        -- Dynamic SQL statement

    DECLARE @start_time DATETIME;      -- Load start time
    DECLARE @rows_affected BIGINT;     -- Stores inserted row count

    ---------------------------------------------------------------------------
    -- Cursor to loop through active FULL load tables from metadata config
    ---------------------------------------------------------------------------
    DECLARE table_cursor CURSOR FOR 
    SELECT source_table, target_table 
    FROM audit.etl_config 
    WHERE is_active = 1 
      AND load_type = 'FULL'
    ORDER BY priority;

    OPEN table_cursor;
    FETCH NEXT FROM table_cursor INTO @src, @tgt;

    ---------------------------------------------------------------------------
    -- Loop through each configured table
    ---------------------------------------------------------------------------
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @start_time = GETDATE();   -- Capture load start time
        PRINT '>> Dynamic Framework Loading: ' + @tgt;
        
        BEGIN TRY
            DECLARE @column_list NVARCHAR(MAX);

            -------------------------------------------------------------------
            -- Get matching column names between Source and Target tables
            -- This avoids inserting audit or extra columns accidentally
            -------------------------------------------------------------------
            SELECT @column_list = STRING_AGG(QUOTENAME(s.name), ', ') 
            FROM sys.columns s
            JOIN sys.columns t 
                ON s.name = t.name
            WHERE s.object_id = OBJECT_ID(@src)
              AND t.object_id = OBJECT_ID(@tgt);

            -- Stop execution if no matching columns are found
            IF @column_list IS NULL
                THROW 50000, 
                'No matching columns found between Source and Target.', 1;

            -------------------------------------------------------------------
            -- Build Dynamic SQL:
            -- 1. Start Transaction
            -- 2. Truncate Target Table
            -- 3. Insert Matching Columns from Source
            -- 4. Capture Row Count
            -- 5. Commit Transaction
            -------------------------------------------------------------------
            SET @sql = 
                'BEGIN TRANSACTION; ' +
                'TRUNCATE TABLE ' + @tgt + '; ' +
                'INSERT INTO ' + @tgt + ' (' + @column_list + ') ' +
                'SELECT ' + @column_list + ' FROM ' + @src + '; ' +
                'SELECT @rows = @@ROWCOUNT; ' +
                'COMMIT;';

            -------------------------------------------------------------------
            -- Execute Dynamic SQL and capture affected row count
            -------------------------------------------------------------------
            EXEC sp_executesql 
                @sql, 
                N'@rows BIGINT OUTPUT', 
                @rows = @rows_affected OUTPUT;

            -------------------------------------------------------------------
            -- Log successful execution into audit table
            -------------------------------------------------------------------
            INSERT INTO audit.etl_log 
                (batch_id, table_name, start_time, end_time, row_count, status)
            VALUES 
                (@batch_id, @tgt, @start_time, GETDATE(), 
                 @rows_affected, 'Success');
            
        END TRY
        BEGIN CATCH
            -------------------------------------------------------------------
            -- Rollback transaction if error occurs
            -------------------------------------------------------------------
            IF @@TRANCOUNT > 0 
                ROLLBACK TRANSACTION;

            -------------------------------------------------------------------
            -- Log failure details into audit table
            -------------------------------------------------------------------
            INSERT INTO audit.etl_log 
                (batch_id, table_name, start_time, end_time, status, error_message)
            VALUES 
                (@batch_id, @tgt, @start_time, GETDATE(), 
                 'Failed', ERROR_MESSAGE());
            
            PRINT '!! ERROR loading ' + @tgt + ': ' + ERROR_MESSAGE();
        END CATCH

        -- Move to next table in cursor
        FETCH NEXT FROM table_cursor INTO @src, @tgt;
    END

    ---------------------------------------------------------------------------
    -- Close and release cursor resources
    ---------------------------------------------------------------------------
    CLOSE table_cursor;
    DEALLOCATE table_cursor;
END;
GO
