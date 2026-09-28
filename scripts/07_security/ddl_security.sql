/* ============================================================
   Gold Layer Security Configuration
   - RBAC
   - Row Level Security
   - Data Masking
   - Sensitivity Classification
   - Audit Specification
   ============================================================ */

---------------------------------------------------------------
-- Create Security Schema
---------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'Security')
    EXEC ('CREATE SCHEMA Security');
GO


---------------------------------------------------------------
-- Create Application Roles
---------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'gold_analyst')
    CREATE ROLE gold_analyst;

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'gold_manager')
    CREATE ROLE gold_manager;
GO


---------------------------------------------------------------
-- User Country Mapping (Used for RLS)
---------------------------------------------------------------
IF OBJECT_ID('Security.UserCountryMapping', 'U') IS NOT NULL
    DROP TABLE Security.UserCountryMapping;
GO

CREATE TABLE Security.UserCountryMapping
(
    UserName SYSNAME NOT NULL,
    Country  NVARCHAR(50) NOT NULL,
    CONSTRAINT PK_UserCountryMapping 
        PRIMARY KEY (UserName, Country)
);
GO

CREATE INDEX IX_UserCountryMapping_UserName
ON Security.UserCountryMapping(UserName);
GO


---------------------------------------------------------------
-- Sample Access Mapping (Demo Users)
---------------------------------------------------------------
INSERT INTO Security.UserCountryMapping (UserName, Country)
VALUES 
('IndiaUser', 'India'),
('USUser', 'United States'),
('GlobalManager', 'India'),
('GlobalManager', 'United States');
GO


---------------------------------------------------------------
-- Row Level Security Function
---------------------------------------------------------------
IF OBJECT_ID('Security.fn_FilterFactSalesByCountry', 'IF') IS NOT NULL
    DROP FUNCTION Security.fn_FilterFactSalesByCountry;
GO

CREATE FUNCTION Security.fn_FilterFactSalesByCountry (@customer_key INT)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
(
    SELECT 1 AS access_granted
    FROM gold.dim_customers dc
    INNER JOIN Security.UserCountryMapping ucm
        ON dc.country = ucm.Country
    WHERE dc.customer_key = @customer_key
      AND ucm.UserName = USER_NAME()
);
GO


---------------------------------------------------------------
-- Apply Security Policy to Fact Table
---------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.security_policies 
           WHERE name = 'FactSalesCountryPolicy')
    DROP SECURITY POLICY Security.FactSalesCountryPolicy;
GO

CREATE SECURITY POLICY Security.FactSalesCountryPolicy
ADD FILTER PREDICATE 
    Security.fn_FilterFactSalesByCountry(customer_key)
ON gold.fact_sales
WITH (STATE = ON);
GO


---------------------------------------------------------------
-- Dynamic Data Masking
---------------------------------------------------------------
BEGIN TRY
    ALTER TABLE gold.fact_sales
    ALTER COLUMN sales_amount 
    ADD MASKED WITH (FUNCTION = 'default()');
END TRY
BEGIN CATCH
    -- Ignore if already masked
END CATCH;
GO


---------------------------------------------------------------
-- Sensitivity Classification
---------------------------------------------------------------
ADD SENSITIVITY CLASSIFICATION 
TO gold.dim_customers.first_name
WITH (LABEL = 'Confidential', INFORMATION_TYPE = 'Personal Data');

ADD SENSITIVITY CLASSIFICATION 
TO gold.dim_customers.last_name
WITH (LABEL = 'Confidential', INFORMATION_TYPE = 'Personal Data');

ADD SENSITIVITY CLASSIFICATION 
TO gold.dim_customers.birthdate
WITH (LABEL = 'Sensitive', INFORMATION_TYPE = 'Personal Data');
GO


---------------------------------------------------------------
-- Create Demo Users (Database-Level Only)
---------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'IndiaUser')
    CREATE USER IndiaUser WITHOUT LOGIN;

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'USUser')
    CREATE USER USUser WITHOUT LOGIN;

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'GlobalManager')
    CREATE USER GlobalManager WITHOUT LOGIN;
GO


---------------------------------------------------------------
-- Grant Schema-Level Permissions
---------------------------------------------------------------
GRANT SELECT ON SCHEMA::gold TO gold_analyst;

GRANT SELECT ON SCHEMA::gold TO gold_manager;
GRANT UNMASK TO gold_manager;
GO


---------------------------------------------------------------
-- Assign Users to Roles
---------------------------------------------------------------
ALTER ROLE gold_analyst ADD MEMBER IndiaUser;
ALTER ROLE gold_analyst ADD MEMBER USUser;

ALTER ROLE gold_manager ADD MEMBER GlobalManager;
GO


---------------------------------------------------------------
-- Audit Specification (Tracks SELECT on Gold Schema)
---------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 
    FROM sys.database_audit_specifications 
    WHERE name = 'GoldAuditSpec'
)
BEGIN
    CREATE DATABASE AUDIT SPECIFICATION GoldAuditSpec
    FOR SERVER AUDIT Audit_GoldLayer
    ADD (SELECT ON SCHEMA::gold BY PUBLIC)
    WITH (STATE = ON);
END
GO


PRINT 'Gold layer security configuration completed.';
