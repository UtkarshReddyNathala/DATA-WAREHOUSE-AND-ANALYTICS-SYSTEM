gold ddl
/*
===============================================================================
DDL Script: Create Gold Tables with Partitioning
===============================================================================
Script Purpose:
    This script creates the physical tables for the Gold layer in the 
    data warehouse. The Gold layer represents the final dimension and 
    fact tables arranged in a Star Schema.

    Each table is designed to store clean, enriched, and business-ready 
    datasets processed from the Silver layer.

Usage:
    - These tables are populated via the 'gold.load_gold' stored procedure.
    - These tables should be queried directly for analytics and reporting.
===============================================================================
*/

-- =============================================================================
-- Create Dimension Table: gold.dim_customers
-- =============================================================================
IF OBJECT_ID('gold.dim_customers', 'U') IS NOT NULL
    DROP TABLE gold.dim_customers;
GO

CREATE TABLE gold.dim_customers (
    customer_key      INT NOT NULL PRIMARY KEY, -- Surrogate PK
    customer_id       INT,                       -- Primary Key from CRM System
    customer_number   NVARCHAR(50),             -- Business Key
    first_name        NVARCHAR(50),
    last_name         NVARCHAR(50),
    country           NVARCHAR(50),
    marital_status    NVARCHAR(50),
    gender            NVARCHAR(50),
    birthdate         DATE,
    create_date       DATETIME
);
GO

-- Seed the "Unknown" member
INSERT INTO gold.dim_customers (customer_key, customer_id, customer_number, first_name)
VALUES (-1, -1, 'n/a', 'Unknown');
GO


-- =============================================================================
-- Create Dimension Table: gold.dim_products
-- =============================================================================
IF OBJECT_ID('gold.dim_products', 'U') IS NOT NULL
    DROP TABLE gold.dim_products;
GO

CREATE TABLE gold.dim_products (
    product_key       INT NOT NULL PRIMARY KEY, -- Surrogate PK
    product_id        INT,                       -- Primary Key from CRM System
    product_number    NVARCHAR(50),             -- Business Key
    product_name      NVARCHAR(255),
    category_id       NVARCHAR(50),
    category          NVARCHAR(50),
    subcategory       NVARCHAR(50),
    maintenance       NVARCHAR(50),
    cost              MONEY,
    product_line      NVARCHAR(50),
    start_date        DATETIME
);
GO

-- Seed the "Unknown" member
INSERT INTO gold.dim_products (product_key, product_id, product_number, product_name)
VALUES (-1, -1, 'n/a', 'Unknown');
GO


-- =============================================================================
-- Partition Function: Partition gold.fact_sales by Year (order_date)
-- =============================================================================
IF EXISTS (SELECT * FROM sys.partition_functions WHERE name = 'pf_fact_sales_orderdate')
    DROP PARTITION FUNCTION pf_fact_sales_orderdate;
GO

CREATE PARTITION FUNCTION pf_fact_sales_orderdate (DATE)
AS RANGE LEFT FOR VALUES
(
    '2023-12-31',
    '2024-12-31',
    '2025-12-31',
    '2026-12-31'
);
GO


-- =============================================================================
-- Partition Scheme: Map partitions to PRIMARY filegroup
-- =============================================================================
IF EXISTS (SELECT * FROM sys.partition_schemes WHERE name = 'ps_fact_sales_orderdate')
    DROP PARTITION SCHEME ps_fact_sales_orderdate;
GO

CREATE PARTITION SCHEME ps_fact_sales_orderdate
AS PARTITION pf_fact_sales_orderdate
ALL TO ([PRIMARY]);
GO


-- =============================================================================
-- Create Fact Table: gold.fact_sales (Partitioned)
-- =============================================================================
IF OBJECT_ID('gold.fact_sales', 'U') IS NOT NULL
    DROP TABLE gold.fact_sales;
GO

CREATE TABLE gold.fact_sales (
    order_number      NVARCHAR(50) NOT NULL,   -- Source System PK
    product_key       INT NOT NULL,            -- FK to dim_products
    customer_key      INT NOT NULL,            -- FK to dim_customers
    order_date        DATE NOT NULL,
    shipping_date     DATE,
    due_date          DATE,
    sales_amount      MONEY,
    quantity          INT,
    price             MONEY,
    CONSTRAINT PK_fact_sales PRIMARY KEY CLUSTERED (order_date, order_number)
        ON ps_fact_sales_orderdate(order_date),
    CONSTRAINT FK_fact_product FOREIGN KEY (product_key)
        REFERENCES gold.dim_products(product_key),
    CONSTRAINT FK_fact_customer FOREIGN KEY (customer_key)
        REFERENCES gold.dim_customers(customer_key)
) ON ps_fact_sales_orderdate(order_date);
GO


-- =============================================================================
-- Create Indexes on Foreign Keys
-- =============================================================================
CREATE INDEX IDX_fact_product ON gold.fact_sales(product_key)
    ON ps_fact_sales_orderdate(order_date);

CREATE INDEX IDX_fact_customer ON gold.fact_sales(customer_key)
    ON ps_fact_sales_orderdate(order_date);
GO


PRINT '------------------------------------------------';
PRINT 'Gold Layer Tables Created Successfully with FKs, Indexes, and Partitioning';
PRINT '------------------------------------------------';


