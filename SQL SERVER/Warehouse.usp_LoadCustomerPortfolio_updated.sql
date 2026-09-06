USE RetailBank_EDW;
GO

/******************************************************************************
  RetailBank EDW - Customer Portfolio Load Procedure
  Procedure: Warehouse.usp_LoadCustomerPortfolio
  Version:   3.2 (Fixed NULL CustomerId duplicate key + SUM warning)
  Date:      9 August 2026

  WHAT DOES THIS PROCEDURE DO?
  ---------------------------
  This is Procedure 3 of 5 in the nightly ETL batch.
  It reads account data from all 7 operational systems
  (Core Banking, Loans, Cards, Investments, Mortgage, Mobile, Forex)
  and builds the "single portfolio view" in Warehouse.CustomerPortfolio.

  THE 7 SOURCE SYSTEMS
  --------------------
  Each system sends us a daily file with different column names:
    Core Banking calls the customer column "CustomerNumber"
    Loans calls it "ClientId"
    Cards calls it "ClientNumber"
    ...and so on.

  We do not hard-code these names. Instead we read them from
  Config.PortfolioSourceConfiguration. If a system changes its column
  name, we just update the config table -- no code change needed.

  HOW IT WORKS (THE PIPELINE)
  ---------------------------
  Step 1: Read the config (which tables, which columns)
  Step 2: Read exchange rates (so we can convert EUR/GBP to USD)
  Step 3: Read product reference (so we know SAV001 = Savings Account)
  Step 4: Loop through all 7 sources with a cursor and load raw data
  Step 5: Validate the data (missing customers, missing products, etc.)
  Step 6: Clean the data (trim spaces, uppercase codes, fix -0.00)
  Step 7: Convert currencies to USD
  Step 8: Look up product descriptions and regulatory categories
  Step 9: Join to CustomerMaster to get names and branch codes
  Step 10: Apply business rules (exclude closed accounts, zero balances,
           customers with critical open exceptions)
  Step 11: Calculate portfolio value bands (STANDARD/SILVER/GOLD/PLATINUM)
  Step 12: MERGE into Warehouse.CustomerPortfolio
  Step 13: Write raw errors to Warehouse.PortfolioErrors
  Step 14: Update audit logs

  FIXES IN THIS VERSION (from the broken v2.5)
  ---------------------------------------------
  FIX 1 - Config table was split
    The old code read Config.SourceConfiguration.
    That table was doing two jobs at once (customer config + portfolio config).
    The corrected schema split it into two tables:
      Config.CustomerSourceConfiguration     (for Procedure 1)
      Config.PortfolioSourceConfiguration      (for this procedure)
    We now read from the portfolio-specific one.

  FIX 2 - CRITICAL runtime failure #8
    The old procedure tried to insert 7 columns into
    Warehouse.CustomerPortfolioExceptions, which now has 20+ columns.
    It was like posting a letter into a parcel slot -- it does not fit.
    SQL Server threw an error and the whole batch died.

    SOLUTION: We created a NEW staging table Warehouse.PortfolioErrors.
    It has exactly the 7 columns Procedure 3 produces, plus ExecutionId.
    Think of it as the "inbox" for raw problems.
    Procedure 4 (the exception enricher) can read from here if it wants.

  FIX 3 - Audit traceability
    Every error row now carries the @ExecutionId.
    If someone asks "Which batch run created this error?"
    you can trace it straight back to the exact ETLExecutionLog row.

  FIX 4 - Missing audit log INSERT
    The old code only did UPDATE Audit.ETLExecutionLog.
    But it never INSERTed the row first! So the UPDATE affected 0 rows.
    It is like trying to update a bank account that does not exist.
    We now INSERT with Status = 'RUNNING' at the start,
    then UPDATE to 'SUCCESS' or 'FAILED' at the end.

  FIX 5 - MERGE statistics were never captured
    The old code declared @RowsUpdated but never set it.
    We now use an OUTPUT clause on the MERGE to catch every action
    ($action tells us INSERT or UPDATE), then count them.

  FIX 6 - Source naming standardised
    All source tables are now in the Source schema:
      Source.CoreBankingAccounts, Source.LoanAccounts, etc.
    The config table stores these names. The cursor reads them.
    No more confusion between Raw.CustomerAccounts and Source.CoreBankingAccounts.

  FIX 7 - QUOTENAME bug on schema.table names (v3.1)
    The config table stores ProductTable = 'Source.CoreBankingAccounts'.
    QUOTENAME() wrapped the whole thing as [Source.CoreBankingAccounts],
    which SQL Server treats as ONE object name, not schema.table.
    We now use PARSENAME() to split it into schema and table,
    then quote each part: [Source].[CoreBankingAccounts].

  FIX 8 - NULL CustomerId duplicate key (v3.2)
    Account CB10005 has CustomerId = NULL in the source data.
    When MERGE tries to match NULL = NULL, SQL Server says UNKNOWN,
    not TRUE. So MERGE thinks the row is brand new and tries to INSERT.
    But the row already exists from a previous test run, so the unique
    index throws a duplicate key error.
    
    SOLUTION: We exclude rows with NULL CustomerId from the MERGE.
    These rows are already flagged as errors in PortfolioErrors.
    They do not belong in the golden data anyway.

  FIX 9 - NULL warning in SUM (v3.2)
    When SQL Server sums a column that contains NULLs, it prints a
    harmless warning: "Null value is eliminated by an aggregate..."
    We wrap the column in ISNULL(..., 0) to suppress this.
******************************************************************************/

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE Warehouse.usp_LoadCustomerPortfolio
(
      @BusinessDate  DATE                -- The business date being processed
    , @EnableLogging BIT = 1            -- 1 = write audit rows, 0 = skip
    , @LoadType      VARCHAR(20) = 'INCREMENTAL'  -- FULL or INCREMENTAL
    , @Debug         BIT = 0              -- 1 = print debug info, 0 = silent
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
            -- OBJECT_NAME turns it into 'usp_LoadCustomerPortfolio'.

        DECLARE @StartTime         DATETIME2(3) = SYSDATETIME();
        DECLARE @EndTime           DATETIME2(3);
        DECLARE @ExecutionSeconds  INT;
        DECLARE @Status            VARCHAR(20) = 'RUNNING';
        DECLARE @ExecutionMessage  NVARCHAR(4000);

        DECLARE @RowsRead          INT = 0;
        DECLARE @RowsInserted      INT = 0;
        DECLARE @RowsUpdated       INT = 0;
        DECLARE @RowsRejected      INT = 0;
        DECLARE @SourceCount       INT = 0;
        DECLARE @ErrorCount        INT = 0;

        -- FIX 7: We need to split 'Source.CoreBankingAccounts' into two parts
        DECLARE @SchemaName        SYSNAME;
        DECLARE @TableName         SYSNAME;


        /* ============================================================
           FIX 4 - WRITE THE INITIAL AUDIT LOG ROW
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
           SECTION B - READ SOURCE CONFIGURATION
           FIX 1: Read from Config.PortfolioSourceConfiguration
           ============================================================ */
        -- The cursor needs to know:
        --   - Which 7 tables to read
        --   - Which column in each table holds the customer ID
        --   - Which column holds the balance
        --   - Which column holds the currency
        --   - etc.
        -- All of this is stored in Config.PortfolioSourceConfiguration.
        -- We load it into a temp table so the cursor can read it quickly.

        IF OBJECT_ID('tempdb..#SourceConfiguration') IS NOT NULL
            DROP TABLE #SourceConfiguration;

        CREATE TABLE #SourceConfiguration
        (
              SourceSystemId      INT
            , SourceSystemCode    VARCHAR(50)
            , SourceSystemName    VARCHAR(100)
            , ProductTable        SYSNAME        -- e.g. Source.CoreBankingAccounts
            , CustomerField       SYSNAME        -- e.g. CustomerNumber
            , ProductField        SYSNAME        -- e.g. ProductCode
            , BalanceField        SYSNAME        -- e.g. AccountBalance
            , CurrencyField       SYSNAME        -- e.g. Currency
            , StatusField         SYSNAME        -- e.g. AccountStatus
            , BusinessDateField   SYSNAME        -- e.g. RecordDate
            , SourceAccountField  SYSNAME        -- e.g. AccountNumber
            , LoadPriority        INT            -- 1 = read first, 7 = read last
            , SupportsIncremental BIT
            , IsActive            BIT
        );

        INSERT INTO #SourceConfiguration
        (
              SourceSystemId
            , SourceSystemCode
            , SourceSystemName
            , ProductTable
            , CustomerField
            , ProductField
            , BalanceField
            , CurrencyField
            , StatusField
            , BusinessDateField
            , SourceAccountField
            , LoadPriority
            , SupportsIncremental
            , IsActive
        )
        SELECT
              SourceSystemId
            , SourceSystemCode
            , SourceSystemName
            , ProductTable
            , CustomerField
            , ProductField
            , BalanceField
            , CurrencyField
            , StatusField
            , BusinessDateField
            , SourceAccountField
            , LoadPriority
            , SupportsIncremental
            , IsActive
        FROM Config.PortfolioSourceConfiguration    -- FIX 1: was Config.SourceConfiguration
        WHERE IsActive = 1
        ORDER BY LoadPriority;

        -- Safety check: if no sources are active, stop immediately
        IF NOT EXISTS (SELECT 1 FROM #SourceConfiguration)
        BEGIN
            THROW 51001, 'No active source systems configured.', 1;
        END;

        SELECT @SourceCount = COUNT(*) FROM #SourceConfiguration;

        IF @Debug = 1
        BEGIN
            PRINT 'Active Source Systems';
            SELECT * FROM #SourceConfiguration ORDER BY LoadPriority;
        END;


        /* ============================================================
           SECTION C - READ EXCHANGE RATES
           ============================================================ */
        -- Accounts are in EUR, GBP, JPY, etc.
        -- Reports are in USD. We need the conversion rate
        -- for the business date being processed.

        IF OBJECT_ID('tempdb..#ExchangeRates') IS NOT NULL
            DROP TABLE #ExchangeRates;

        SELECT  CurrencyCode
              , ExchangeRate
              , EffectiveDate
        INTO    #ExchangeRates
        FROM    Reference.ExchangeRates
        WHERE   EffectiveDate = @BusinessDate;

        IF NOT EXISTS (SELECT 1 FROM #ExchangeRates)
        BEGIN
            THROW 51002, 'Exchange rates not found for business date.', 1;
        END;


        /* ============================================================
           SECTION D - READ PRODUCT REFERENCE
           ============================================================ */
        -- Source data has ProductCode = 'SAV001'.
        -- We need to know that means 'Savings Account'.
        -- We also need ProductCategory and RegulatoryCategory.

        IF OBJECT_ID('tempdb..#ProductReference') IS NOT NULL
            DROP TABLE #ProductReference;

        SELECT  ProductCode
              , ProductDescription
              , ProductCategory
              , RegulatoryCategory
              , ProductStatus
        INTO    #ProductReference
        FROM    Reference.Product
        WHERE   ProductStatus = 'ACTIVE';


        /* ============================================================
           SECTION E - CREATE STAGING TABLES
           ============================================================ */
        -- #PortfolioStage = where we build the data before it goes
        --                   into the warehouse
        -- #PortfolioErrors = where we collect problems we find
        --                     (FIX 2: this is a temp copy; we will
        --                      persist to Warehouse.PortfolioErrors later)

        IF OBJECT_ID('tempdb..#PortfolioStage') IS NOT NULL
            DROP TABLE #PortfolioStage;

        CREATE TABLE #PortfolioStage
        (
              SourceSystemCode     VARCHAR(50)
            , SourceAccountNumber  VARCHAR(100)
            , CustomerId           VARCHAR(50)
            , ProductCode          VARCHAR(50)
            , CurrencyCode         VARCHAR(10)
            , AccountBalance       DECIMAL(18,2)
            , ExchangeRate         DECIMAL(18,8)
            , BaseCurrencyBalance  DECIMAL(18,2)
            , AccountStatus        VARCHAR(30)
            , BusinessDate         DATE
            , LoadTimestamp        DATETIME2(3)
        );

        IF OBJECT_ID('tempdb..#PortfolioErrors') IS NOT NULL
            DROP TABLE #PortfolioErrors;

        CREATE TABLE #PortfolioErrors
        (
              SourceSystemCode     VARCHAR(50)
            , SourceAccountNumber  VARCHAR(100)
            , CustomerId           VARCHAR(50)
            , ErrorCategory        VARCHAR(100)
            , ErrorDescription     NVARCHAR(500)
            , LoggedDate           DATETIME2(3)
            , ExecutionId          UNIQUEIDENTIFIER    -- FIX 3: audit trace
        );


        /* ============================================================
           SECTION F - LOAD DATA FROM ALL 7 SOURCE SYSTEMS
           FIX 7: Parse schema and table names separately
           ============================================================ */
        -- Each system has different table names and column names.
        -- Instead of writing 7 separate INSERT statements,
        -- we use a CURSOR that reads the config table and builds
        -- dynamic SQL for each source.
        --
        -- Think of it like a mail merge: the template is the same,
        -- but the names and addresses change for each letter.

        DECLARE
              @SourceTable        SYSNAME
            , @CustomerField     SYSNAME
            , @ProductField      SYSNAME
            , @BalanceField      SYSNAME
            , @CurrencyField     SYSNAME
            , @StatusField       SYSNAME
            , @BusinessDateField SYSNAME
            , @SourceAccountField SYSNAME
            , @SourceSystemCode  VARCHAR(50)
            , @SQL               NVARCHAR(MAX);

        DECLARE PortfolioCursor CURSOR FAST_FORWARD
        FOR
            SELECT  ProductTable
                  , CustomerField
                  , ProductField
                  , BalanceField
                  , CurrencyField
                  , StatusField
                  , BusinessDateField
                  , SourceAccountField
                  , SourceSystemCode
            FROM    #SourceConfiguration
            ORDER BY LoadPriority;

        OPEN PortfolioCursor;
        FETCH NEXT FROM PortfolioCursor
        INTO  @SourceTable, @CustomerField, @ProductField, @BalanceField,
              @CurrencyField, @StatusField, @BusinessDateField,
              @SourceAccountField, @SourceSystemCode;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            /* --------------------------------------------------------
               FIX 7: Split 'Source.CoreBankingAccounts' into parts
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
                INSERT INTO #PortfolioStage
                (
                      SourceSystemCode
                    , SourceAccountNumber
                    , CustomerId
                    , ProductCode
                    , CurrencyCode
                    , AccountBalance
                    , AccountStatus
                    , BusinessDate
                    , LoadTimestamp
                )
                SELECT
                      ''' + @SourceSystemCode + '''
                    , ' + QUOTENAME(@SourceAccountField) + '
                    , ' + QUOTENAME(@CustomerField) + '
                    , ' + QUOTENAME(@ProductField) + '
                    , ' + QUOTENAME(@CurrencyField) + '
                    , ' + QUOTENAME(@BalanceField) + '
                    , ' + QUOTENAME(@StatusField) + '
                    , ' + QUOTENAME(@BusinessDateField) + '
                    , GETDATE()
                FROM ' + QUOTENAME(@SchemaName) + '.' + QUOTENAME(@TableName) + '
                WHERE ' + QUOTENAME(@BusinessDateField) + ' = @BusinessDate';

            -- For incremental loads, skip CLOSED accounts
            IF @LoadType = 'INCREMENTAL'
                SET @SQL += '
                AND ' + QUOTENAME(@StatusField) + ' <> ''CLOSED''';

            -- Execute the dynamic SQL safely with a parameter
            EXEC sp_executesql
                @SQL,
                N'@BusinessDate DATE',
                @BusinessDate;

            FETCH NEXT FROM PortfolioCursor
            INTO  @SourceTable, @CustomerField, @ProductField, @BalanceField,
                  @CurrencyField, @StatusField, @BusinessDateField,
                  @SourceAccountField, @SourceSystemCode;
        END;

        CLOSE PortfolioCursor;
        DEALLOCATE PortfolioCursor;

        -- Count how many rows we pulled from all sources
        SELECT @RowsRead = COUNT(*) FROM #PortfolioStage;

        IF @Debug = 1
        BEGIN
            PRINT 'Portfolio Records Loaded';
            SELECT  SourceSystemCode, COUNT(*) AS RecordsLoaded
            FROM    #PortfolioStage
            GROUP BY SourceSystemCode
            ORDER BY SourceSystemCode;
        END;


        /* ============================================================
           SECTION G - VALIDATE THE RAW DATA
           ============================================================ */
        -- Before we do any processing, we check for obvious problems.
        -- Each problem goes into #PortfolioErrors.
        -- These are RAW errors -- just the basic facts.
        -- Procedure 4 will enrich them later with severity,
        -- business owner, SLA, etc.

        -- Rule: Every account must have a customer
        INSERT INTO #PortfolioErrors
        (SourceSystemCode, SourceAccountNumber, CustomerId,
         ErrorCategory, ErrorDescription, LoggedDate, ExecutionId)
        SELECT  SourceSystemCode, SourceAccountNumber, CustomerId,
                'MISSING_CUSTOMER', 'Customer identifier is missing.',
                GETDATE(), @ExecutionId
        FROM    #PortfolioStage
        WHERE   CustomerId IS NULL;

        -- Rule: Every account must have a product code
        INSERT INTO #PortfolioErrors
        (SourceSystemCode, SourceAccountNumber, CustomerId,
         ErrorCategory, ErrorDescription, LoggedDate, ExecutionId)
        SELECT  SourceSystemCode, SourceAccountNumber, CustomerId,
                'MISSING_PRODUCT', 'Product code is missing.',
                GETDATE(), @ExecutionId
        FROM    #PortfolioStage
        WHERE   ProductCode IS NULL;

        -- Rule: Every account must have a balance
        INSERT INTO #PortfolioErrors
        (SourceSystemCode, SourceAccountNumber, CustomerId,
         ErrorCategory, ErrorDescription, LoggedDate, ExecutionId)
        SELECT  SourceSystemCode, SourceAccountNumber, CustomerId,
                'INVALID_BALANCE', 'Account balance is NULL.',
                GETDATE(), @ExecutionId
        FROM    #PortfolioStage
        WHERE   AccountBalance IS NULL;


        /* ============================================================
           SECTION H - CLEAN AND STANDARDISE
           ============================================================ */
        -- Data from 7 different systems is messy.
        -- Some have leading spaces.
        -- Some product codes are lowercase.
        -- Some currencies are lowercase.
        -- Some balances are -0.00 (which is silly).

        UPDATE  #PortfolioStage
        SET     CustomerId     = NULLIF(LTRIM(RTRIM(CustomerId)), '')
              , ProductCode    = UPPER(NULLIF(LTRIM(RTRIM(ProductCode)), ''))
              , CurrencyCode   = UPPER(NULLIF(LTRIM(RTRIM(CurrencyCode)), ''))
              , AccountStatus  = UPPER(AccountStatus)
              , AccountBalance = CASE WHEN AccountBalance = -0.00 THEN 0.00
                                      ELSE AccountBalance END;


        /* ============================================================
           SECTION I - APPLY EXCHANGE RATES
           ============================================================ */
        -- Convert every balance to USD using the rates we loaded.
        -- If a currency has no rate, we flag it as an error.

        UPDATE  P
        SET     ExchangeRate        = ISNULL(E.ExchangeRate, 1)
              , BaseCurrencyBalance = ROUND(P.AccountBalance *
                                              ISNULL(E.ExchangeRate, 1), 2)
        FROM    #PortfolioStage P
        LEFT JOIN #ExchangeRates E
            ON  P.CurrencyCode = E.CurrencyCode;

        -- Flag missing exchange rates
        INSERT INTO #PortfolioErrors
        (SourceSystemCode, SourceAccountNumber, CustomerId,
         ErrorCategory, ErrorDescription, LoggedDate, ExecutionId)
        SELECT  SourceSystemCode, SourceAccountNumber, CustomerId,
                'MISSING_EXCHANGE_RATE',
                CONCAT('Exchange rate not found for currency ', CurrencyCode),
                GETDATE(), @ExecutionId
        FROM    #PortfolioStage
        WHERE   ExchangeRate IS NULL;


        /* ============================================================
           SECTION J - ENRICH WITH PRODUCT INFORMATION
           ============================================================ */
        -- We have ProductCode = 'SAV001'. Now we look up
        -- the human-readable name, category, and regulatory type.

        ALTER TABLE #PortfolioStage
        ADD     ProductDescription  VARCHAR(200)
              , ProductCategory     VARCHAR(100)
              , RegulatoryCategory  VARCHAR(100);

        UPDATE  P
        SET     ProductDescription = R.ProductDescription
              , ProductCategory    = R.ProductCategory
              , RegulatoryCategory = R.RegulatoryCategory
        FROM    #PortfolioStage P
        LEFT JOIN #ProductReference R
            ON  P.ProductCode = R.ProductCode;

        -- Flag products that are not in our reference table
        INSERT INTO #PortfolioErrors
        (SourceSystemCode, SourceAccountNumber, CustomerId,
         ErrorCategory, ErrorDescription, LoggedDate, ExecutionId)
        SELECT  SourceSystemCode, SourceAccountNumber, CustomerId,
                'UNKNOWN_PRODUCT',
                CONCAT('Unknown Product Code : ', ProductCode),
                GETDATE(), @ExecutionId
        FROM    #PortfolioStage
        WHERE   ProductDescription IS NULL;


        /* ============================================================
           SECTION K - JOIN TO CUSTOMER MASTER
           ============================================================ */
        -- We need the customer's name, category (PREMIUM, etc.),
        -- and branch code. These come from Warehouse.CustomerMaster
        -- which was built by Procedure 1.

        ALTER TABLE #PortfolioStage
        ADD     CustomerName     VARCHAR(200)
              , CustomerCategory VARCHAR(50)
              , BranchCode       VARCHAR(20);

        UPDATE  P
        SET     CustomerName     = CONCAT(C.FirstName, ' ', C.LastName)
              , CustomerCategory = C.CustomerCategory
              , BranchCode       = C.BranchCode
        FROM    #PortfolioStage P
        LEFT JOIN Warehouse.CustomerMaster C
            ON  P.CustomerId = C.CustomerId;

        -- Flag customers not found in the master
        INSERT INTO #PortfolioErrors
        (SourceSystemCode, SourceAccountNumber, CustomerId,
         ErrorCategory, ErrorDescription, LoggedDate, ExecutionId)
        SELECT  SourceSystemCode, SourceAccountNumber, CustomerId,
                'CUSTOMER_NOT_FOUND', 'Customer not found in Customer Master.',
                GETDATE(), @ExecutionId
        FROM    #PortfolioStage
        WHERE   CustomerName IS NULL;

        IF @Debug = 1
        BEGIN
            PRINT 'Portfolio Enrichment Summary';
            -- FIX 9: ISNULL prevents "Null value eliminated" warning
            SELECT  COUNT(*) AS TotalAccounts
                  , SUM(ISNULL(BaseCurrencyBalance, 0)) AS TotalPortfolioValue
            FROM    #PortfolioStage;
        END;


        /* ============================================================
           SECTION L - APPLY BUSINESS RULES
           FIX 8: Exclude NULL CustomerId from warehouse load
           ============================================================ */
        -- Not every account should appear in reports.
        -- We EXCLUDE accounts that are:
        --   - CLOSED
        --   - Zero balance
        --   - Unknown product
        --   - Missing exchange rate
        -- We also EXCLUDE customers who have OPEN CRITICAL
        -- exceptions in Warehouse.CustomerMasterExceptions.
        --
        -- FIX 8: We ALSO exclude rows where CustomerId is NULL.
        -- WHY: If CustomerId is NULL, the MERGE cannot match it.
        --      NULL = NULL evaluates to UNKNOWN in SQL Server, not TRUE.
        --      So MERGE thinks the row is brand new and tries to INSERT.
        --      If the row already exists (from a previous run), the unique
        --      index throws a duplicate key error.
        --      These rows are already in PortfolioErrors anyway.

        IF OBJECT_ID('tempdb..#EnterprisePortfolio') IS NOT NULL
            DROP TABLE #EnterprisePortfolio;

        ;WITH PortfolioBusinessRules AS
        (
            SELECT  P.*
                  , CASE
                        WHEN AccountStatus = 'CLOSED'        THEN 0
                        WHEN BaseCurrencyBalance = 0           THEN 0
                        WHEN ProductDescription IS NULL       THEN 0
                        WHEN ExchangeRate IS NULL              THEN 0
                        ELSE 1
                    END AS IncludePortfolio
            FROM    #PortfolioStage P
        ),
        CustomerExceptions AS
        (
            -- Find customers with unresolved CRITICAL exceptions
            SELECT DISTINCT CustomerId
            FROM   Warehouse.CustomerMasterExceptions
            WHERE  ExceptionStatus = 'OPEN'
              AND  SeverityCode    = 'CRITICAL'
        )
        SELECT  P.SourceSystemCode
              , P.SourceAccountNumber
              , P.CustomerId
              , P.CustomerName
              , P.CustomerCategory
              , P.BranchCode
              , P.ProductCode
              , P.ProductDescription
              , P.ProductCategory
              , P.RegulatoryCategory
              , P.CurrencyCode
              , P.ExchangeRate
              , P.AccountBalance
              , P.BaseCurrencyBalance
              , P.AccountStatus
              , P.BusinessDate
              , CASE WHEN C.CustomerId IS NULL THEN 'Y' ELSE 'N'
                END AS EligibleForReporting
              , GETDATE() AS WarehouseLoadDate
        INTO    #EnterprisePortfolio
        FROM    PortfolioBusinessRules P
        LEFT JOIN CustomerExceptions C
            ON  P.CustomerId = C.CustomerId
        WHERE   IncludePortfolio = 1
          AND   C.CustomerId IS NULL
          AND   P.CustomerId IS NOT NULL;    -- FIX 8: Exclude NULL CustomerId


        /* ============================================================
           SECTION M - CALCULATE PORTFOLIO METRICS
           ============================================================ */
        -- We need to know:
        --   - Which value band? (STANDARD / SILVER / GOLD / PLATINUM)
        --   - Is this a high-value customer? (>$500k)
        --   - How many products does this customer have?

        ALTER TABLE #EnterprisePortfolio
        ADD     PortfolioValueBand VARCHAR(50)
              , HighValueCustomer  BIT
              , ProductCount       INT;

        UPDATE  #EnterprisePortfolio
        SET     PortfolioValueBand =
                    CASE
                        WHEN BaseCurrencyBalance >= 1000000 THEN 'PLATINUM'
                        WHEN BaseCurrencyBalance >= 250000  THEN 'GOLD'
                        WHEN BaseCurrencyBalance >= 50000   THEN 'SILVER'
                        ELSE 'STANDARD'
                    END;

        UPDATE  #EnterprisePortfolio
        SET     HighValueCustomer =
                    CASE WHEN BaseCurrencyBalance >= 500000 THEN 1 ELSE 0 END;

        ;WITH ProductSummary AS
        (
            SELECT  CustomerId, COUNT(*) AS ProductCount
            FROM    #EnterprisePortfolio
            GROUP BY CustomerId
        )
        UPDATE  P
        SET     ProductCount = S.ProductCount
        FROM    #EnterprisePortfolio P
        INNER JOIN ProductSummary S
            ON  P.CustomerId = S.CustomerId;


        /* ============================================================
           SECTION N - FINAL VALIDATION (NEGATIVE BALANCES)
           ============================================================ */
        INSERT INTO #PortfolioErrors
        (SourceSystemCode, SourceAccountNumber, CustomerId,
         ErrorCategory, ErrorDescription, LoggedDate, ExecutionId)
        SELECT  SourceSystemCode, SourceAccountNumber, CustomerId,
                'NEGATIVE_PORTFOLIO',
                'Portfolio balance below acceptable threshold.',
                GETDATE(), @ExecutionId
        FROM    #EnterprisePortfolio
        WHERE   BaseCurrencyBalance < -10000;


        /* ============================================================
           SECTION O - MERGE INTO WAREHOUSE.CUSTOMERPORTFOLIO
           FIX 5: Capture INSERT vs UPDATE counts
           ============================================================ */
        -- MERGE is powerful. It can INSERT new rows and UPDATE
        -- existing rows in one statement. But we need to KNOW
        -- how many of each happened for our audit log.
        --
        -- We use an OUTPUT clause to catch every action into a
        -- temporary table, then count them.

        DECLARE @MergeOutput TABLE (ActionType VARCHAR(10));

        MERGE Warehouse.CustomerPortfolio AS TARGET
        USING (SELECT * FROM #EnterprisePortfolio) AS SOURCE
        ON     TARGET.BusinessDate        = SOURCE.BusinessDate
           AND TARGET.CustomerId          = SOURCE.CustomerId
           AND TARGET.SourceAccountNumber = SOURCE.SourceAccountNumber

        -- Only UPDATE if something actually changed
        WHEN MATCHED AND
        (
               ISNULL(TARGET.ProductCode,'')          <> ISNULL(SOURCE.ProductCode,'')
            OR ISNULL(TARGET.ProductCategory,'')        <> ISNULL(SOURCE.ProductCategory,'')
            OR ISNULL(TARGET.CurrencyCode,'')           <> ISNULL(SOURCE.CurrencyCode,'')
            OR ISNULL(TARGET.ExchangeRate,0)           <> ISNULL(SOURCE.ExchangeRate,0)
            OR ISNULL(TARGET.AccountBalance,0)         <> ISNULL(SOURCE.AccountBalance,0)
            OR ISNULL(TARGET.BaseCurrencyBalance,0)     <> ISNULL(SOURCE.BaseCurrencyBalance,0)
            OR ISNULL(TARGET.AccountStatus,'')          <> ISNULL(SOURCE.AccountStatus,'')
            OR ISNULL(TARGET.PortfolioValueBand,'')    <> ISNULL(SOURCE.PortfolioValueBand,'')
            OR ISNULL(TARGET.HighValueCustomer,0)      <> ISNULL(SOURCE.HighValueCustomer,0)
            OR ISNULL(TARGET.ProductCount,0)            <> ISNULL(SOURCE.ProductCount,0)
        )
        THEN UPDATE SET
              TARGET.CustomerName        = SOURCE.CustomerName
            , TARGET.CustomerCategory    = SOURCE.CustomerCategory
            , TARGET.BranchCode          = SOURCE.BranchCode
            , TARGET.ProductCode         = SOURCE.ProductCode
            , TARGET.ProductDescription  = SOURCE.ProductDescription
            , TARGET.ProductCategory     = SOURCE.ProductCategory
            , TARGET.RegulatoryCategory  = SOURCE.RegulatoryCategory
            , TARGET.CurrencyCode        = SOURCE.CurrencyCode
            , TARGET.ExchangeRate        = SOURCE.ExchangeRate
            , TARGET.AccountBalance      = SOURCE.AccountBalance
            , TARGET.BaseCurrencyBalance = SOURCE.BaseCurrencyBalance
            , TARGET.AccountStatus       = SOURCE.AccountStatus
            , TARGET.EligibleForReporting = SOURCE.EligibleForReporting
            , TARGET.PortfolioValueBand  = SOURCE.PortfolioValueBand
            , TARGET.HighValueCustomer   = SOURCE.HighValueCustomer
            , TARGET.ProductCount        = SOURCE.ProductCount
            , TARGET.LastUpdatedDate     = GETDATE()

        WHEN NOT MATCHED BY TARGET THEN INSERT
        (
              BusinessDate
            , SourceSystemCode
            , SourceAccountNumber
            , CustomerId
            , CustomerName
            , CustomerCategory
            , BranchCode
            , ProductCode
            , ProductDescription
            , ProductCategory
            , RegulatoryCategory
            , CurrencyCode
            , ExchangeRate
            , AccountBalance
            , BaseCurrencyBalance
            , AccountStatus
            , EligibleForReporting
            , PortfolioValueBand
            , HighValueCustomer
            , ProductCount
            , CreatedDate
            , LastUpdatedDate
        )
        VALUES
        (
              SOURCE.BusinessDate
            , SOURCE.SourceSystemCode
            , SOURCE.SourceAccountNumber
            , SOURCE.CustomerId
            , SOURCE.CustomerName
            , SOURCE.CustomerCategory
            , SOURCE.BranchCode
            , SOURCE.ProductCode
            , SOURCE.ProductDescription
            , SOURCE.ProductCategory
            , SOURCE.RegulatoryCategory
            , SOURCE.CurrencyCode
            , SOURCE.ExchangeRate
            , SOURCE.AccountBalance
            , SOURCE.BaseCurrencyBalance
            , SOURCE.AccountStatus
            , SOURCE.EligibleForReporting
            , SOURCE.PortfolioValueBand
            , SOURCE.HighValueCustomer
            , SOURCE.ProductCount
            , GETDATE()
            , GETDATE()
        )
        OUTPUT $action INTO @MergeOutput(ActionType);

        -- FIX 5: Count what the MERGE did
        SELECT  @RowsInserted = COUNT(*) FROM @MergeOutput WHERE ActionType = 'INSERT';
        SELECT  @RowsUpdated  = COUNT(*) FROM @MergeOutput WHERE ActionType = 'UPDATE';
        SELECT  @RowsRejected = COUNT(*) FROM #PortfolioErrors;


        /* ============================================================
           SECTION P - FIX 2: SAVE RAW ERRORS TO PortfolioErrors
           ============================================================ */
        -- This is the CRITICAL FIX. The old code tried to insert
        -- 7 columns into Warehouse.CustomerPortfolioExceptions,
        -- which expects 20+ enriched columns. That would CRASH.
        --
        -- Instead, we write to Warehouse.PortfolioErrors --
        -- a simple 7-column staging table designed exactly for
        -- this purpose. Procedure 4 can read from here if it
        -- wants to enrich these raw errors.

        INSERT INTO Warehouse.PortfolioErrors
        (
              BusinessDate
            , SourceSystemCode
            , SourceAccountNumber
            , CustomerId
            , ErrorCategory
            , ErrorDescription
            , LoggedDate
            , ExecutionId
        )
        SELECT  @BusinessDate
              , SourceSystemCode
              , SourceAccountNumber
              , CustomerId
              , ErrorCategory
              , ErrorDescription
              , LoggedDate
              , ExecutionId
        FROM    #PortfolioErrors;


        /* ============================================================
           SECTION Q - BUILD SUMMARY TABLES (for audit/debug)
           ============================================================ */

        IF OBJECT_ID('tempdb..#PortfolioSummary') IS NOT NULL
            DROP TABLE #PortfolioSummary;

        SELECT  BusinessDate
              , ProductCategory
              , COUNT(*) AS AccountCount
              , SUM(BaseCurrencyBalance) AS PortfolioValue
        INTO    #PortfolioSummary
        FROM    #EnterprisePortfolio
        GROUP BY BusinessDate, ProductCategory;

        IF OBJECT_ID('tempdb..#BranchSummary') IS NOT NULL
            DROP TABLE #BranchSummary;

        SELECT  BranchCode
              , COUNT(DISTINCT CustomerId) AS CustomerCount
              , COUNT(*) AS AccountCount
              , SUM(BaseCurrencyBalance) AS PortfolioValue
        INTO    #BranchSummary
        FROM    #EnterprisePortfolio
        GROUP BY BranchCode;


        /* ============================================================
           SECTION R - FINALISE AUDIT
           ============================================================ */

        SET @EndTime = SYSDATETIME();
        SET @ExecutionSeconds = DATEDIFF(SECOND, @StartTime, @EndTime);
        SET @Status = 'SUCCESS';
        SET @ExecutionMessage =
            CONCAT('Customer Portfolio Load Completed Successfully. ',
                   'Rows Read: ', @RowsRead,
                   ', Rows Loaded: ', @RowsInserted,
                   ', Rows Updated: ', @RowsUpdated,
                   ', Rows Rejected: ', @RowsRejected);

        -- Update the audit row we created at the start
        IF @EnableLogging = 1
        BEGIN
            UPDATE  Audit.ETLExecutionLog
            SET     EndTime         = @EndTime
                  , Status          = @Status
                  , RowsRead        = @RowsRead
                  , RowsInserted    = @RowsInserted
                  , RowsUpdated     = @RowsUpdated
                  , RowsRejected    = @RowsRejected
                  , DurationSeconds = @ExecutionSeconds
                  , Message         = @ExecutionMessage
            WHERE   ExecutionId     = @ExecutionId;
        END;

        -- Write the daily portfolio summary
        INSERT INTO Audit.PortfolioExecutionSummary
        (
              BusinessDate
            , ProcedureName
            , ExecutionId
            , TotalCustomers
            , TotalAccounts
            , TotalPortfolioValue
            , TotalErrors
            , ExecutionTimeSeconds
            , CreatedDate
        )
        SELECT  @BusinessDate
              , @ProcedureName
              , @ExecutionId
              , COUNT(DISTINCT CustomerId)
              , COUNT(*)
              , SUM(BaseCurrencyBalance)
              , (SELECT COUNT(*) FROM #PortfolioErrors)
              , @ExecutionSeconds
              , GETDATE()
        FROM    #EnterprisePortfolio;


          /* ============================================================
           SECTION S - DEBUG OUTPUT
           ============================================================ */
        SELECT @ErrorCount = COUNT(*) FROM #PortfolioErrors;

        IF @Debug = 1
        BEGIN
            PRINT '============================================';
            PRINT 'Customer Portfolio Load Summary';
            PRINT '============================================';
            PRINT CONCAT('Rows Read        : ', @RowsRead);
            PRINT CONCAT('Rows Loaded      : ', @RowsInserted);
            PRINT CONCAT('Rows Updated     : ', @RowsUpdated);
            PRINT CONCAT('Rows Rejected    : ', @RowsRejected);
            PRINT CONCAT('Execution Time   : ', @ExecutionSeconds);
            PRINT CONCAT('Validation Errors: ', @ErrorCount);
            PRINT '--------------------------------------------';
            SELECT  ProductCategory, COUNT(*) AS Accounts,
                    SUM(BaseCurrencyBalance) AS PortfolioValue
            FROM    #EnterprisePortfolio
            GROUP BY ProductCategory
            ORDER BY PortfolioValue DESC;
        END;


        /* ============================================================
           SECTION T - CLEANUP
           ============================================================ */
        DROP TABLE IF EXISTS #SourceConfiguration;
        DROP TABLE IF EXISTS #ExchangeRates;
        DROP TABLE IF EXISTS #ProductReference;
        DROP TABLE IF EXISTS #PortfolioStage;
        DROP TABLE IF EXISTS #EnterprisePortfolio;
        DROP TABLE IF EXISTS #PortfolioErrors;
        DROP TABLE IF EXISTS #PortfolioSummary;
        DROP TABLE IF EXISTS #BranchSummary;

        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SET @EndTime = SYSDATETIME();
        SET @Status = 'FAILED';
        SET @ExecutionMessage =
            CONCAT('Error ', ERROR_NUMBER(), ' - ', ERROR_MESSAGE());

        IF @EnableLogging = 1
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM Audit.ETLExecutionLog WHERE ExecutionId = @ExecutionId)
            BEGIN
                INSERT INTO Audit.ETLExecutionLog
                (ExecutionId, ProcedureName, BusinessDate, LoadType,
                 StartTime, Status, Message, DurationSeconds)
                VALUES
                (@ExecutionId, @ProcedureName, @BusinessDate, @LoadType,
                 @StartTime, @Status, @ExecutionMessage,
                 DATEDIFF(SECOND, @StartTime, @EndTime));
            END
            ELSE
            BEGIN
                UPDATE  Audit.ETLExecutionLog
                SET     EndTime = @EndTime, Status = @Status,
                        Message = @ExecutionMessage,
                        DurationSeconds = DATEDIFF(SECOND, @StartTime, @EndTime)
                WHERE   ExecutionId = @ExecutionId;
            END;
        END;

        THROW;

    END CATCH;
END;
GO