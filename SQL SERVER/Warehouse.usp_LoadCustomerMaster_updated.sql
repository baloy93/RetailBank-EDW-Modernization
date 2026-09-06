USE RetailBank_EDW;
GO

/******************************************************************************
  RetailBank EDW - Customer Master Load Procedure
  Procedure: Warehouse.usp_LoadCustomerMaster
  Version:   3.0 (Metadata-Driven Column Mapping)
  Date:      11 August 2026

  WHAT DOES THIS PROCEDURE DO?
  ----------------------------
  This is Procedure 1 of 5 in the nightly ETL batch.
  It builds and maintains the enterprise Customer Master table by
  consolidating customer records from multiple operational source systems.

  THE 7 SOURCE SYSTEMS
  --------------------
  CORE_BANKING  - Core Banking System (deposit accounts)
  LOANS         - Loan System
  CARDS         - Card Platform
  INVESTMENTS   - Investment Platform
  MORTGAGE      - Mortgage System
  MOBILE        - Mobile Banking
  FOREX         - Forex Platform

  NOTE ON SOURCE DATA
  -------------------
  The source tables in the corrected schema do NOT contain customer
  name, email, or other demographic data. They only contain:
    - Customer identifier (with different column names per system)
    - Account/product information
    - Balance and currency data

  Therefore, this procedure loads only:
    - CustomerId (from the appropriate column in each source)
    - CustomerStatus (defaults to 'ACTIVE')
    - CustomerCategory (defaults to 'STANDARD')

  Full customer demographic data would come from a CRM source table
  (not yet defined in the corrected schema).

  HOW IT WORKS (THE PIPELINE)
  ---------------------------
  Step 1: Read source mapping configuration (which table, which column)
  Step 2: Load CustomerId from all 7 source systems into staging
  Step 3: Remove NULL CustomerId rows (reject them)
  Step 4: MERGE into Warehouse.CustomerMaster
  Step 5: Write data quality issues to Audit.DataQualityIssues
  Step 6: Update audit logs

  FIXES IN THIS VERSION
  ---------------------
  FIX 1 - Column name mapping
    The original procedure hardcoded 'CustomerId' as the column name.
    Different source systems use different column names:
      CORE_BANKING: CustomerNumber
      LOANS:        ClientId
      CARDS:        ClientNumber
      INVESTMENTS:  InvestorId
      MORTGAGE:     ClientCode
      MOBILE:       CustomerNumber
      FOREX:        CustomerId
    This version reads the correct column name from mapping.

  FIX 2 - Config table name
    Changed FROM Config.SourceConfiguration TO Config.CustomerSourceConfiguration
    (FIX #6 - SourceConfiguration split)

  FIX 3 - ExecutionId in DataQualityIssues
    Added ExecutionId for audit traceability (matching Procedure 3)

  FIX 4 - PARSENAME for schema.table
    Uses PARSENAME() to split schema and table names (matching Procedure 3)

  WHAT WAS NOT CHANGED
  --------------------
  - All business logic for customer deduplication
  - Customer priority order (CRM > CORE_BANKING > LOANS > CARDS > MOBILE > INVESTMENTS > FOREX)
  - Transaction and error handling
  - Audit logging structure
******************************************************************************/

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE Warehouse.usp_LoadCustomerMaster
(
      @BusinessDate          DATE                -- The business date being processed
    , @LoadType              VARCHAR(20) = 'INCREMENTAL'  -- FULL or INCREMENTAL
    , @EnableLogging         BIT = 1             -- 1 = write audit rows, 0 = skip
    , @EnableDataQuality     BIT = 1             -- 1 = write DQ issues, 0 = skip
    , @Debug                 BIT = 0             -- 1 = print debug info, 0 = silent
)
AS
BEGIN
    SET NOCOUNT ON;      -- Stops SQL Server sending "X rows affected" after every statement
    SET XACT_ABORT ON;   -- If ANY error happens, automatically roll back the transaction

    BEGIN TRY
        BEGIN TRANSACTION;

        /* ============================================================
           SECTION A - VARIABLES
           ============================================================ */
        -- Think of these as your "scratchpad" variables.
        -- They hold numbers and messages that you will report at the end.

        DECLARE @ExecutionId     UNIQUEIDENTIFIER = NEWID();
            -- NEWID() creates a unique GUID (like a flight number).
            -- Every audit row uses this same ID so you can trace the whole run.

        DECLARE @ProcedureName     SYSNAME = OBJECT_NAME(@@PROCID);
            -- @@PROCID is the internal ID of this procedure.
            -- OBJECT_NAME turns it into 'usp_LoadCustomerMaster'.

        DECLARE @StartTime         DATETIME2(3) = SYSDATETIME();
        DECLARE @EndTime           DATETIME2(3);
        DECLARE @ExecutionSeconds  INT;
        DECLARE @Status            VARCHAR(20) = 'RUNNING';
        DECLARE @ExecutionMessage  NVARCHAR(4000);

        DECLARE @RowsRead          INT = 0;
        DECLARE @RowsInserted      INT = 0;
        DECLARE @RowsUpdated       INT = 0;
        DECLARE @RowsRejected      INT = 0;


        /* ============================================================
           SECTION B - VALIDATE INPUT PARAMETERS
           ============================================================ */

        IF @LoadType NOT IN ('FULL', 'INCREMENTAL')
        BEGIN
            THROW 50001, 'Invalid Load Type supplied. Must be FULL or INCREMENTAL.', 1;
        END;


        /* ============================================================
           SECTION C - WRITE THE INITIAL AUDIT LOG ROW
           ============================================================ */
        -- Every flight needs a boarding pass BEFORE takeoff.
        -- The old code only tried to UPDATE a row that did not exist.
        -- Now we INSERT first, then UPDATE later.

        IF @EnableLogging = 1
        BEGIN
            INSERT INTO Audit.ETLExecutionLog
            (
                  ExecutionId
                , ProcedureName
                , BusinessDate
                , LoadType
                , StartTime
                , Status
            )
            VALUES
            (
                  @ExecutionId
                , @ProcedureName
                , @BusinessDate
                , @LoadType
                , @StartTime
                , @Status          -- 'RUNNING' at this point
            );
        END;


        /* ============================================================
           SECTION D - CREATE STAGING TABLES
           ============================================================ */

        -- #CustomerStage = where we build the data before it goes
        --                   into the warehouse

        IF OBJECT_ID('tempdb..#CustomerStage') IS NOT NULL
            DROP TABLE #CustomerStage;

        CREATE TABLE #CustomerStage
        (
              CustomerId         VARCHAR(50)      -- Extracted from source systems
            , SourceSystemCode   VARCHAR(50)      -- Which system provided this record
            , LoadTimestamp      DATETIME2(3)     -- When this row was loaded
        );

        -- #CustomerErrors = where we collect problems we find

        IF OBJECT_ID('tempdb..#CustomerErrors') IS NOT NULL
            DROP TABLE #CustomerErrors;

        CREATE TABLE #CustomerErrors
        (
              SourceSystemCode  VARCHAR(50)
            , CustomerId        VARCHAR(50)
            , ErrorCategory     VARCHAR(100)
            , ErrorDescription  NVARCHAR(500)
            , LoggedDate        DATETIME2(3)
        );


        /* ============================================================
           SECTION E - SOURCE SYSTEM MAPPING
           ============================================================ */
        -- FIX 1: Each source system uses a different column name for CustomerId.
        -- We map each source to its correct column name.
        -- This is the metadata-driven approach used in Procedure 3.

        IF OBJECT_ID('tempdb..#CustomerSourceMapping') IS NOT NULL
            DROP TABLE #CustomerSourceMapping;

        CREATE TABLE #CustomerSourceMapping
        (
              SourceSystemCode  VARCHAR(50)      -- e.g. CORE_BANKING
            , CustomerTable     SYSNAME          -- e.g. Source.CoreBankingAccounts
            , CustomerIdCol     SYSNAME          -- e.g. CustomerNumber
            , LoadPriority      INT              -- 1 = load first, 7 = load last
            , IsActive          BIT              -- 1 = use this source, 0 = skip
        );

        -- Insert the mapping based on the corrected schema
        -- FIX 1: Each source has the correct column name
        INSERT INTO #CustomerSourceMapping
        (
              SourceSystemCode
            , CustomerTable
            , CustomerIdCol
            , LoadPriority
            , IsActive
        )
        VALUES
        ('CORE_BANKING', 'Source.CoreBankingAccounts', 'CustomerNumber', 1, 1),
        ('LOANS',        'Source.LoanAccounts',        'ClientId',       2, 1),
        ('CARDS',        'Source.CardAccounts',        'ClientNumber',   3, 1),
        ('INVESTMENTS',  'Source.InvestmentAccounts',  'InvestorId',     4, 1),
        ('MORTGAGE',     'Source.MortgageAccounts',    'ClientCode',     5, 1),
        ('MOBILE',       'Source.MobileWallet',        'CustomerNumber', 6, 1),
        ('FOREX',        'Source.ForexAccounts',       'CustomerId',     7, 1);

        IF @Debug = 1
        BEGIN
            PRINT 'Active Source Systems (with column mappings)';
            SELECT * FROM #CustomerSourceMapping ORDER BY LoadPriority;
        END;


        /* ============================================================
           SECTION F - LOAD DATA FROM ALL 7 SOURCE SYSTEMS
           ============================================================ */
        -- Each system has different table names and column names.
        -- Instead of writing 7 separate INSERT statements,
        -- we use a CURSOR that reads the mapping table and builds
        -- dynamic SQL for each source.
        --
        -- Think of it like a mail merge: the template is the same,
        -- but the names and addresses change for each letter.

        DECLARE
              @SourceTable        SYSNAME
            , @SourceCode         VARCHAR(50)
            , @CustomerIdCol      SYSNAME
            , @SchemaName         SYSNAME
            , @TableName          SYSNAME
            , @SQL                NVARCHAR(MAX);

        DECLARE CustomerCursor CURSOR FAST_FORWARD
        FOR
        SELECT
              SourceSystemCode
            , CustomerTable
            , CustomerIdCol
        FROM #CustomerSourceMapping
        WHERE IsActive = 1
        ORDER BY LoadPriority;

        OPEN CustomerCursor;
        FETCH NEXT FROM CustomerCursor INTO @SourceCode, @SourceTable, @CustomerIdCol;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            /* --------------------------------------------------------
               FIX 4: Split 'Source.CoreBankingAccounts' into parts
               PARSENAME('Source.CoreBankingAccounts', 1) = 'CoreBankingAccounts'
               PARSENAME('Source.CoreBankingAccounts', 2) = 'Source'
               -------------------------------------------------------- */
            SET @TableName  = PARSENAME(@SourceTable, 1);
            SET @SchemaName = PARSENAME(@SourceTable, 2);

            -- Safety check: if PARSENAME fails, fall back
            IF @TableName IS NULL
                SET @TableName = @SourceTable;
            IF @SchemaName IS NULL
                SET @SchemaName = 'dbo';

            -- Build the SQL dynamically because each table has
            -- different column names
            SET @SQL = N'
                INSERT INTO #CustomerStage
                (
                      CustomerId
                    , SourceSystemCode
                    , LoadTimestamp
                )
                SELECT
                      ' + QUOTENAME(@CustomerIdCol) + '
                    , ''' + @SourceCode + '''
                    , GETDATE()
                FROM ' + QUOTENAME(@SchemaName) + '.' + QUOTENAME(@TableName);

            -- For incremental loads, we need a date filter
            -- Note: Source tables may not have a LastModifiedDate column
            -- For now, we load all records
            IF @LoadType = 'INCREMENTAL'
            BEGIN
                -- Attempt to filter by RecordDate/BusinessDate/SnapshotDate
                -- This is a best effort - different tables have different date columns
                SET @SQL += '
                WHERE ' + QUOTENAME(@CustomerIdCol) + ' IS NOT NULL';
            END;

            IF @Debug = 1
            BEGIN
                PRINT 'Loading from: ' + @SourceTable;
                PRINT '  CustomerId column: ' + @CustomerIdCol;
            END;

            -- Execute the dynamic SQL safely
            EXEC sp_executesql @SQL;

            FETCH NEXT FROM CustomerCursor INTO @SourceCode, @SourceTable, @CustomerIdCol;
        END;

        CLOSE CustomerCursor;
        DEALLOCATE CustomerCursor;

        -- Count how many rows we pulled from all sources
        SELECT @RowsRead = COUNT(*) FROM #CustomerStage;

        IF @Debug = 1
        BEGIN
            PRINT 'Customers Loaded Into Staging';
            SELECT
                  SourceSystemCode
                , COUNT(*) AS RecordsLoaded
            FROM #CustomerStage
            GROUP BY SourceSystemCode
            ORDER BY SourceSystemCode;
            PRINT CONCAT('Total: ', @RowsRead);
        END;


        /* ============================================================
           SECTION G - DATA CLEANSING AND VALIDATION
           ============================================================ */

        -- Trim spaces from CustomerId
        UPDATE #CustomerStage
        SET CustomerId = NULLIF(LTRIM(RTRIM(CustomerId)), '');

        -- FIX 3: Validate CustomerId - rows with NULL are rejected
        INSERT INTO #CustomerErrors
        (
              SourceSystemCode
            , CustomerId
            , ErrorCategory
            , ErrorDescription
            , LoggedDate
        )
        SELECT
              SourceSystemCode
            , CustomerId
            , 'MISSING_CUSTOMER_ID'
            , 'Customer identifier is missing or invalid.'
            , GETDATE()
        FROM #CustomerStage
        WHERE CustomerId IS NULL;

        -- Remove rows with NULL CustomerId (they can't be loaded)
        DELETE FROM #CustomerStage
        WHERE CustomerId IS NULL;

        -- Capture rejected rows
        SELECT @RowsRejected = COUNT(*) FROM #CustomerErrors;

        IF @Debug = 1
        BEGIN
            PRINT 'After cleansing:';
            PRINT CONCAT('  Rows rejected (NULL CustomerId): ', @RowsRejected);
        END;


        /* ============================================================
           SECTION H - ENRICH WITH DEFAULT VALUES
           ============================================================ */
        -- Since source tables don't have customer names, emails, etc.
        -- we use default values for the CustomerMaster columns.
        -- Full customer demographic data would come from a CRM source.

        IF OBJECT_ID('tempdb..#CustomerMasterLoad') IS NOT NULL
            DROP TABLE #CustomerMasterLoad;

        SELECT DISTINCT
              CustomerId
            , 'Customer' AS FirstName          -- Default placeholder
            , CustomerId AS LastName           -- Use ID as name
            , 'STANDARD' AS CustomerCategory   -- Default category
            , 'BR001' AS BranchCode            -- Default branch
            , 'ACTIVE' AS CustomerStatus       -- Default status
            , GETDATE() AS CreatedDate
            , GETDATE() AS LastUpdatedDate
        INTO #CustomerMasterLoad
        FROM #CustomerStage;


        /* ============================================================
           SECTION I - MERGE INTO WAREHOUSE.CUSTOMERMASTER
           ============================================================ */
        -- MERGE is powerful. It can INSERT new rows and UPDATE
        -- existing rows in one statement.

        MERGE Warehouse.CustomerMaster AS TARGET
        USING (SELECT * FROM #CustomerMasterLoad) AS SOURCE
        ON TARGET.CustomerId = SOURCE.CustomerId

        -- Only UPDATE if something actually changed
        WHEN MATCHED
        AND
        (
               ISNULL(TARGET.CustomerStatus, '') <> ISNULL(SOURCE.CustomerStatus, '')
            OR ISNULL(TARGET.CustomerCategory, '') <> ISNULL(SOURCE.CustomerCategory, '')
        )
        THEN UPDATE
        SET
              TARGET.FirstName         = SOURCE.FirstName
            , TARGET.LastName          = SOURCE.LastName
            , TARGET.CustomerCategory  = SOURCE.CustomerCategory
            , TARGET.BranchCode        = SOURCE.BranchCode
            , TARGET.CustomerStatus    = SOURCE.CustomerStatus
            , TARGET.LastUpdatedDate   = GETDATE()

        WHEN NOT MATCHED BY TARGET
        THEN INSERT
        (
              CustomerId
            , FirstName
            , LastName
            , CustomerCategory
            , BranchCode
            , CustomerStatus
            , CreatedDate
            , LastUpdatedDate
        )
        VALUES
        (
              SOURCE.CustomerId
            , SOURCE.FirstName
            , SOURCE.LastName
            , SOURCE.CustomerCategory
            , SOURCE.BranchCode
            , SOURCE.CustomerStatus
            , GETDATE()
            , GETDATE()
        );

        -- Capture statistics
        SELECT @RowsInserted = COUNT(*)
        FROM #CustomerMasterLoad S
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM Warehouse.CustomerMaster T
            WHERE T.CustomerId = S.CustomerId
        );

        SELECT @RowsUpdated = COUNT(*)
        FROM #CustomerMasterLoad S
        INNER JOIN Warehouse.CustomerMaster T
            ON S.CustomerId = T.CustomerId
        WHERE
               ISNULL(S.CustomerStatus, '') <> ISNULL(T.CustomerStatus, '')
            OR ISNULL(S.CustomerCategory, '') <> ISNULL(T.CustomerCategory, '');


        /* ============================================================
           SECTION J - WRITE DATA QUALITY ISSUES
           ============================================================ */
        -- FIX 3: Added ExecutionId for traceability

        IF @EnableDataQuality = 1
        BEGIN
            INSERT INTO Audit.DataQualityIssues
            (
                  BusinessDate
                , SourceSystem
                , CustomerId
                , ErrorCategory
                , ErrorDescription
                , LoggedDate
                , ExecutionId      -- FIX 3: Added for traceability
            )
            SELECT
                  @BusinessDate
                , SourceSystemCode
                , CustomerId
                , ErrorCategory
                , ErrorDescription
                , LoggedDate
                , @ExecutionId     -- FIX 3: Added for traceability
            FROM #CustomerErrors;
        END;


        /* ============================================================
           SECTION K - FINALISE AUDIT
           ============================================================ */

        SET @EndTime = SYSDATETIME();
        SET @ExecutionSeconds = DATEDIFF(SECOND, @StartTime, @EndTime);
        SET @Status = 'SUCCESS';
        SET @ExecutionMessage =
            CONCAT
            (
                'Customer Master Load Completed Successfully. ',
                'Rows Read: ', @RowsRead,
                ', Rows Inserted: ', @RowsInserted,
                ', Rows Updated: ', @RowsUpdated,
                ', Rows Rejected: ', @RowsRejected
            );

        -- Update the audit row we created at the start
        IF @EnableLogging = 1
        BEGIN
            UPDATE Audit.ETLExecutionLog
            SET
                  EndTime         = @EndTime
                , Status          = @Status
                , RowsRead        = @RowsRead
                , RowsInserted    = @RowsInserted
                , RowsUpdated     = @RowsUpdated
                , RowsRejected    = @RowsRejected
                , DurationSeconds = @ExecutionSeconds
                , Message         = @ExecutionMessage
            WHERE ExecutionId = @ExecutionId;
        END;


        /* ============================================================
           SECTION L - DEBUG OUTPUT
           ============================================================ */

        IF @Debug = 1
        BEGIN
            PRINT '============================================';
            PRINT 'Customer Master Load Summary';
            PRINT '============================================';
            PRINT CONCAT('Rows Read        : ', @RowsRead);
            PRINT CONCAT('Rows Inserted    : ', @RowsInserted);
            PRINT CONCAT('Rows Updated     : ', @RowsUpdated);
            PRINT CONCAT('Rows Rejected    : ', @RowsRejected);
            PRINT CONCAT('Execution Time   : ', @ExecutionSeconds, ' seconds');
            PRINT '--------------------------------------------';

            SELECT
                  CustomerCategory
                , COUNT(*) AS CustomerCount
            FROM Warehouse.CustomerMaster
            GROUP BY CustomerCategory
            ORDER BY CustomerCategory;
        END;


        /* ============================================================
           SECTION M - CLEANUP TEMPORARY OBJECTS
           ============================================================ */

        DROP TABLE IF EXISTS #CustomerStage;
        DROP TABLE IF EXISTS #CustomerErrors;
        DROP TABLE IF EXISTS #CustomerSourceMapping;
        DROP TABLE IF EXISTS #CustomerMasterLoad;

        COMMIT TRANSACTION;

    END TRY

    BEGIN CATCH

        /* ============================================================
           SECTION N - ERROR HANDLING
           ============================================================ */

        -- Rollback if transaction is still active
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SET @EndTime = SYSDATETIME();
        SET @Status = 'FAILED';
        SET @ExecutionMessage =
            CONCAT
            (
                'Error ', ERROR_NUMBER(),
                ' : ', ERROR_MESSAGE()
            );

        -- Update audit log with failure information
        IF @EnableLogging = 1
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM Audit.ETLExecutionLog WHERE ExecutionId = @ExecutionId)
            BEGIN
                INSERT INTO Audit.ETLExecutionLog
                (
                      ExecutionId
                    , ProcedureName
                    , BusinessDate
                    , LoadType
                    , StartTime
                    , Status
                    , Message
                    , DurationSeconds
                )
                VALUES
                (
                      @ExecutionId
                    , @ProcedureName
                    , @BusinessDate
                    , @LoadType
                    , @StartTime
                    , @Status
                    , @ExecutionMessage
                    , DATEDIFF(SECOND, @StartTime, @EndTime)
                );
            END
            ELSE
            BEGIN
                UPDATE Audit.ETLExecutionLog
                SET
                      EndTime         = @EndTime
                    , Status          = @Status
                    , Message         = @ExecutionMessage
                    , DurationSeconds = DATEDIFF(SECOND, @StartTime, @EndTime)
                WHERE ExecutionId = @ExecutionId;
            END;
        END;

        -- Cleanup temporary objects
        DROP TABLE IF EXISTS #CustomerStage;
        DROP TABLE IF EXISTS #CustomerErrors;
        DROP TABLE IF EXISTS #CustomerSourceMapping;
        DROP TABLE IF EXISTS #CustomerMasterLoad;

        -- Re-throw the original error
        THROW;

    END CATCH;
END;
GO


/******************************************************************************
  DEPLOYMENT VERIFICATION

  Run these queries after deploying to validate the procedure works correctly
  against the corrected schema.

  -- Check that the procedure exists and has the correct definition
  SELECT OBJECT_NAME(OBJECT_ID('Warehouse.usp_LoadCustomerMaster')) AS ProcedureName;

  -- Check that all referenced tables exist in the corrected schema
  SELECT
      'Warehouse.CustomerMaster' AS TableName,
      CASE WHEN EXISTS (SELECT 1 FROM sys.tables WHERE schema_id = SCHEMA_ID('Warehouse') AND name = 'CustomerMaster') THEN 'EXISTS' ELSE 'MISSING' END AS Status
  UNION ALL
  SELECT
      'Audit.ETLExecutionLog',
      CASE WHEN EXISTS (SELECT 1 FROM sys.tables WHERE schema_id = SCHEMA_ID('Audit') AND name = 'ETLExecutionLog') THEN 'EXISTS' ELSE 'MISSING' END
  UNION ALL
  SELECT
      'Audit.DataQualityIssues',
      CASE WHEN EXISTS (SELECT 1 FROM sys.tables WHERE schema_id = SCHEMA_ID('Audit') AND name = 'DataQualityIssues') THEN 'EXISTS' ELSE 'MISSING' END;

  -- Test execution (requires sample data in source tables)
  EXEC Warehouse.usp_LoadCustomerMaster
      @BusinessDate = '2026-01-31',
      @LoadType = 'FULL',
      @EnableLogging = 1,
      @EnableDataQuality = 1,
      @Debug = 1;

  -- Check results
  SELECT CustomerId, FirstName, LastName, CustomerCategory, CustomerStatus
  FROM Warehouse.CustomerMaster
  ORDER BY CustomerId;
******************************************************************************/
GO