USE RetailBank_EDW;
GO

-- Drop the old version if it exists (to avoid conflicts)
IF OBJECT_ID('Warehouse.usp_LoadCustomerMasterExceptions', 'P') IS NOT NULL
    DROP PROCEDURE Warehouse.usp_LoadCustomerMasterExceptions;
GO

/******************************************************************************
  RetailBank EDW - Customer Master Exceptions Load Procedure
  Procedure: Warehouse.usp_LoadCustomerMasterExceptions
  Version:   2.0 (Corrected Schema Compatibility Release)
  Date:      10 August 2026

  WHAT DOES THIS PROCEDURE DO?
  ----------------------------
  This is Procedure 2 of 5 in the nightly ETL batch.
  It identifies invalid customer records, classifies data quality issues,
  assigns severity levels, assigns business owners, and records exceptions.

  HOW IT WORKS (THE PIPELINE)
  ---------------------------
  Step 1: Read data quality issues from Audit.DataQualityIssues
  Step 2: Remove duplicate exceptions (keep latest by LoggedDate)
  Step 3: Read exception configuration (ExceptionCategory, Severity, BusinessOwner)
  Step 4: Classify exceptions and assign severity, business area, owner
  Step 5: Handle unclassified exceptions (MEDIUM severity, Data Governance)
  Step 6: Set exception status and calculate resolution due date
  Step 7: MERGE into Warehouse.CustomerMasterExceptions
  Step 8: Write execution summary to Audit.ExceptionExecutionSummary
  Step 9: Update audit logs

  FIXES IN THIS VERSION
  ---------------------
  FIX 1 - Column name mismatch
    Changed ExecutionTimeSeconds to ExecutionSeconds
    (Matches corrected schema Audit.ExceptionExecutionSummary)

  FIX 2 - ExecutionId in DataQualityIssues read
    Added ExecutionId for audit traceability

  WHAT WAS NOT CHANGED
  --------------------
  - All business logic for exception classification
  - Severity mapping (CRITICAL/HIGH/MEDIUM/LOW)
  - SLA calculation (2/8/24/72 hours)
  - Escalation logic
  - Transaction and error handling
  - Audit logging structure
******************************************************************************/

CREATE OR ALTER PROCEDURE Warehouse.usp_LoadCustomerMasterExceptions
(
      @BusinessDate     DATE
    , @EnableLogging    BIT = 1
    , @Debug            BIT = 0
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* ============================================================
           SECTION A - VARIABLES
           ============================================================ */

        DECLARE @ExecutionId UNIQUEIDENTIFIER = NEWID();
        DECLARE @ProcedureName SYSNAME = OBJECT_NAME(@@PROCID);
        DECLARE @StartTime DATETIME2(3) = SYSDATETIME();
        DECLARE @RowsRead INT = 0;
        DECLARE @RowsInserted INT = 0;
        DECLARE @RowsIgnored INT = 0;
        DECLARE @DuplicateExceptionsRemoved INT = 0;
        DECLARE @Status VARCHAR(20) = 'RUNNING';
        DECLARE @Message NVARCHAR(4000);
        DECLARE @EndTime DATETIME2(3);
        DECLARE @DurationSeconds INT;

        /* ============================================================
           SECTION B - WRITE THE INITIAL AUDIT LOG ROW
           ============================================================ */

        IF @EnableLogging = 1
        BEGIN
            INSERT INTO Audit.ETLExecutionLog
            (
                  ExecutionId
                , ProcedureName
                , BusinessDate
                , StartTime
                , Status
            )
            VALUES
            (
                  @ExecutionId
                , @ProcedureName
                , @BusinessDate
                , @StartTime
                , @Status
            );
        END;

        /* ============================================================
           SECTION C - READ DATA QUALITY EXCEPTIONS
           ============================================================ */

        IF OBJECT_ID('tempdb..#DataQualityIssues') IS NOT NULL
            DROP TABLE #DataQualityIssues;

        CREATE TABLE #DataQualityIssues
        (
              BusinessDate    DATE
            , SourceSystem    VARCHAR(50)
            , CustomerId      VARCHAR(50)
            , ErrorCategory   VARCHAR(100)
            , ErrorDescription NVARCHAR(500)
            , LoggedDate      DATETIME2(3)
            , ExecutionId     UNIQUEIDENTIFIER
        );

        INSERT INTO #DataQualityIssues
        (
              BusinessDate
            , SourceSystem
            , CustomerId
            , ErrorCategory
            , ErrorDescription
            , LoggedDate
            , ExecutionId
        )
        SELECT
              BusinessDate
            , SourceSystem
            , CustomerId
            , ErrorCategory
            , ErrorDescription
            , LoggedDate
            , ExecutionId
        FROM Audit.DataQualityIssues
        WHERE BusinessDate = @BusinessDate;

        SELECT @RowsRead = COUNT(*) FROM #DataQualityIssues;

        IF @Debug = 1
        BEGIN
            PRINT 'Data Quality Records Loaded';
            SELECT COUNT(*) AS TotalIssues FROM #DataQualityIssues;
        END;

        /* ============================================================
           SECTION D - REMOVE DUPLICATE EXCEPTIONS
           ============================================================ */

        ;WITH RankedExceptions AS
        (
            SELECT
                  *
                , ROW_NUMBER()
                  OVER
                  (
                      PARTITION BY CustomerId, ErrorCategory, ErrorDescription
                      ORDER BY LoggedDate DESC
                  ) AS ExceptionRank
            FROM #DataQualityIssues
        )
        SELECT *
        INTO #ExceptionStage
        FROM RankedExceptions
        WHERE ExceptionRank = 1;

        SELECT @DuplicateExceptionsRemoved = @RowsRead - COUNT(*) FROM #ExceptionStage;

        IF @Debug = 1
        BEGIN
            PRINT CONCAT('Duplicate Exceptions Removed : ', @DuplicateExceptionsRemoved);
        END;

        /* ============================================================
           SECTION E - READ EXCEPTION CONFIGURATION
           ============================================================ */

        IF OBJECT_ID('tempdb..#ExceptionCategory') IS NOT NULL
            DROP TABLE #ExceptionCategory;

        SELECT
              ExceptionCategory
            , Description
            , DefaultSeverity
            , BusinessArea
        INTO #ExceptionCategory
        FROM Config.ExceptionCategory;

        IF OBJECT_ID('tempdb..#ExceptionSeverity') IS NOT NULL
            DROP TABLE #ExceptionSeverity;

        SELECT
              SeverityCode
            , PriorityLevel
            , SLAHours
            , EscalationRequired
        INTO #ExceptionSeverity
        FROM Config.ExceptionSeverity;

        IF OBJECT_ID('tempdb..#BusinessOwner') IS NOT NULL
            DROP TABLE #BusinessOwner;

        SELECT
              BusinessArea
            , BusinessOwner
            , SupportTeam
        INTO #BusinessOwner
        FROM Config.BusinessOwner;

        /* ============================================================
           SECTION F - CLASSIFY CUSTOMER EXCEPTIONS
           ============================================================ */

        IF OBJECT_ID('tempdb..#CustomerExceptions') IS NOT NULL
            DROP TABLE #CustomerExceptions;

        CREATE TABLE #CustomerExceptions
        (
              CustomerId           VARCHAR(50)
            , SourceSystemCode     VARCHAR(50)
            , ExceptionCategory    VARCHAR(100)
            , ExceptionDescription NVARCHAR(500)
            , SeverityCode         VARCHAR(20)
            , SeverityDescription  VARCHAR(100)
            , EscalationRequired   BIT
            , ResolutionTargetHours INT
            , BusinessArea         VARCHAR(100)
            , BusinessOwner        VARCHAR(100)
            , SupportTeam          VARCHAR(100)
            , LoggedDate           DATETIME2(3)
            , BusinessDate         DATE
            , ExceptionStatus      VARCHAR(30)
            , AssignedDate         DATETIME2(3)
            , ResolutionStatus     VARCHAR(30)
            , EscalationLevel      INT
            , ResolutionDueDate    DATETIME2(3)
        );

        -- Classified exceptions (found in configuration)
        INSERT INTO #CustomerExceptions
        (
              CustomerId
            , SourceSystemCode
            , ExceptionCategory
            , ExceptionDescription
            , SeverityCode
            , SeverityDescription
            , EscalationRequired
            , ResolutionTargetHours
            , BusinessArea
            , BusinessOwner
            , SupportTeam
            , LoggedDate
            , BusinessDate
            , ExceptionStatus
            , AssignedDate
            , ResolutionStatus
            , EscalationLevel
            , ResolutionDueDate
        )
        SELECT
              D.CustomerId
            , D.SourceSystem
            , D.ErrorCategory
            , D.ErrorDescription
            , S.SeverityCode
            , 'Severity: ' + S.SeverityCode
            , S.EscalationRequired
            , S.SLAHours
            , C.BusinessArea
            , B.BusinessOwner
            , B.SupportTeam
            , D.LoggedDate
            , @BusinessDate
            , 'OPEN'
            , GETDATE()
            , 'PENDING'
            , CASE
                  WHEN S.SeverityCode = 'CRITICAL' THEN 1
                  WHEN S.SeverityCode = 'HIGH'      THEN 2
                  WHEN S.SeverityCode = 'MEDIUM'    THEN 3
                  ELSE 4
              END
            , DATEADD(HOUR, S.SLAHours, D.LoggedDate)
        FROM #ExceptionStage D
        INNER JOIN #ExceptionCategory C
            ON D.ErrorCategory = C.ExceptionCategory
        INNER JOIN #ExceptionSeverity S
            ON C.DefaultSeverity = S.SeverityCode
        LEFT JOIN #BusinessOwner B
            ON C.BusinessArea = B.BusinessArea;

        -- Unclassified exceptions (not found in configuration)
        INSERT INTO #CustomerExceptions
        (
              CustomerId
            , SourceSystemCode
            , ExceptionCategory
            , ExceptionDescription
            , SeverityCode
            , SeverityDescription
            , EscalationRequired
            , ResolutionTargetHours
            , BusinessArea
            , BusinessOwner
            , SupportTeam
            , LoggedDate
            , BusinessDate
            , ExceptionStatus
            , AssignedDate
            , ResolutionStatus
            , EscalationLevel
            , ResolutionDueDate
        )
        SELECT
              D.CustomerId
            , D.SourceSystem
            , D.ErrorCategory
            , D.ErrorDescription
            , 'MEDIUM'
            , 'Medium Priority'
            , 0
            , 48
            , 'Data Governance'
            , 'Data Steward'
            , 'Data Quality Team'
            , D.LoggedDate
            , @BusinessDate
            , 'OPEN'
            , GETDATE()
            , 'PENDING'
            , 3
            , DATEADD(HOUR, 48, D.LoggedDate)
        FROM #ExceptionStage D
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM #ExceptionCategory C
            WHERE C.ExceptionCategory = D.ErrorCategory
        );

        -- Prefix [CRITICAL] to description for critical exceptions
        UPDATE #CustomerExceptions
        SET ExceptionDescription = CONCAT('[CRITICAL] ', ExceptionDescription)
        WHERE SeverityCode = 'CRITICAL';

        IF @Debug = 1
        BEGIN
            PRINT 'Exception Classification Summary';
            SELECT
                  SeverityCode
                , COUNT(*) AS TotalExceptions
            FROM #CustomerExceptions
            GROUP BY SeverityCode
            ORDER BY
                CASE SeverityCode
                    WHEN 'CRITICAL' THEN 1
                    WHEN 'HIGH'     THEN 2
                    WHEN 'MEDIUM'   THEN 3
                    ELSE 4
                END;
        END;

        /* ============================================================
           SECTION G - MERGE INTO WAREHOUSE.CUSTOMERMASTEREXCEPTIONS
           ============================================================ */

        MERGE Warehouse.CustomerMasterExceptions AS TARGET
        USING (SELECT * FROM #CustomerExceptions) AS SOURCE
        ON
            TARGET.BusinessDate = SOURCE.BusinessDate
            AND TARGET.CustomerId = SOURCE.CustomerId
            AND TARGET.ExceptionCategory = SOURCE.ExceptionCategory

        WHEN MATCHED
        AND
        (
               ISNULL(TARGET.ExceptionDescription, '') <> ISNULL(SOURCE.ExceptionDescription, '')
            OR ISNULL(TARGET.SeverityCode, '')         <> ISNULL(SOURCE.SeverityCode, '')
            OR ISNULL(TARGET.BusinessOwner, '')        <> ISNULL(SOURCE.BusinessOwner, '')
            OR ISNULL(TARGET.SupportTeam, '')          <> ISNULL(SOURCE.SupportTeam, '')
            OR ISNULL(TARGET.ResolutionDueDate, '1900-01-01') <> ISNULL(SOURCE.ResolutionDueDate, '1900-01-01')
        )
        THEN UPDATE
        SET
              TARGET.ExceptionDescription = SOURCE.ExceptionDescription
            , TARGET.SeverityCode         = SOURCE.SeverityCode
            , TARGET.SeverityDescription  = SOURCE.SeverityDescription
            , TARGET.BusinessArea         = SOURCE.BusinessArea
            , TARGET.BusinessOwner        = SOURCE.BusinessOwner
            , TARGET.SupportTeam          = SOURCE.SupportTeam
            , TARGET.EscalationRequired   = SOURCE.EscalationRequired
            , TARGET.EscalationLevel      = SOURCE.EscalationLevel
            , TARGET.ResolutionDueDate    = SOURCE.ResolutionDueDate
            , TARGET.LastUpdatedDate      = GETDATE()

        WHEN NOT MATCHED BY TARGET
        THEN INSERT
        (
              BusinessDate
            , CustomerId
            , SourceSystemCode
            , ExceptionCategory
            , ExceptionDescription
            , SeverityCode
            , SeverityDescription
            , EscalationRequired
            , ResolutionTargetHours
            , EscalationLevel
            , BusinessArea
            , BusinessOwner
            , SupportTeam
            , ExceptionStatus
            , ResolutionStatus
            , LoggedDate
            , AssignedDate
            , ResolutionDueDate
            , CreatedDate
            , LastUpdatedDate
        )
        VALUES
        (
              SOURCE.BusinessDate
            , SOURCE.CustomerId
            , SOURCE.SourceSystemCode
            , SOURCE.ExceptionCategory
            , SOURCE.ExceptionDescription
            , SOURCE.SeverityCode
            , SOURCE.SeverityDescription
            , SOURCE.EscalationRequired
            , SOURCE.ResolutionTargetHours
            , SOURCE.EscalationLevel
            , SOURCE.BusinessArea
            , SOURCE.BusinessOwner
            , SOURCE.SupportTeam
            , SOURCE.ExceptionStatus
            , SOURCE.ResolutionStatus
            , SOURCE.LoggedDate
            , SOURCE.AssignedDate
            , SOURCE.ResolutionDueDate
            , GETDATE()
            , GETDATE()
        );

        SELECT @RowsInserted = COUNT(*) FROM #CustomerExceptions;

        /* ============================================================
           SECTION H - BUILD SUMMARY TABLES
           ============================================================ */

        IF OBJECT_ID('tempdb..#DailyExceptionSummary') IS NOT NULL
            DROP TABLE #DailyExceptionSummary;

        SELECT
              BusinessDate
            , SeverityCode
            , COUNT(*) AS ExceptionCount
        INTO #DailyExceptionSummary
        FROM #CustomerExceptions
        GROUP BY BusinessDate, SeverityCode;

        IF OBJECT_ID('tempdb..#BusinessAreaSummary') IS NOT NULL
            DROP TABLE #BusinessAreaSummary;

        SELECT
              BusinessArea
            , COUNT(*) AS ExceptionCount
            , SUM(CASE WHEN EscalationRequired = 1 THEN 1 ELSE 0 END) AS EscalatedExceptions
        INTO #BusinessAreaSummary
        FROM #CustomerExceptions
        GROUP BY BusinessArea;

        /* ============================================================
           SECTION I - FINALISE AUDIT
           ============================================================ */

        SET @EndTime = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @StartTime, @EndTime);

        SET @Status = 'SUCCESS';
        SET @Message =
            CONCAT
            (
                'Customer Exception Load Completed Successfully. ',
                'Exceptions Read: ', @RowsRead,
                ', Exceptions Loaded: ', @RowsInserted,
                ', Duplicate Exceptions Removed: ', @DuplicateExceptionsRemoved
            );

        IF @EnableLogging = 1
        BEGIN
            UPDATE Audit.ETLExecutionLog
            SET
                  EndTime         = @EndTime
                , Status          = @Status
                , RowsRead        = @RowsRead
                , RowsInserted    = @RowsInserted
                , RowsUpdated     = 0
                , RowsRejected    = 0
                , DurationSeconds = @DurationSeconds
                , Message         = @Message
            WHERE ExecutionId = @ExecutionId;
        END;

        INSERT INTO Audit.ExceptionExecutionSummary
        (
              BusinessDate
            , ProcedureName
            , ExecutionId
            , TotalExceptions
            , CriticalExceptions
            , HighExceptions
            , MediumExceptions
            , LowExceptions
            , EscalatedExceptions
            , ExecutionSeconds
            , CreatedDate
        )
        SELECT
              @BusinessDate
            , @ProcedureName
            , @ExecutionId
            , COUNT(*)
            , SUM(CASE WHEN SeverityCode = 'CRITICAL' THEN 1 ELSE 0 END)
            , SUM(CASE WHEN SeverityCode = 'HIGH'      THEN 1 ELSE 0 END)
            , SUM(CASE WHEN SeverityCode = 'MEDIUM'    THEN 1 ELSE 0 END)
            , SUM(CASE WHEN SeverityCode = 'LOW'       THEN 1 ELSE 0 END)
            , SUM(CASE WHEN EscalationRequired = 1     THEN 1 ELSE 0 END)
            , @DurationSeconds
            , GETDATE()
        FROM #CustomerExceptions;

        IF @Debug = 1
        BEGIN
            PRINT '========================================';
            PRINT 'Customer Exception Load Summary';
            PRINT '========================================';
            PRINT CONCAT('Rows Read             : ', @RowsRead);
            PRINT CONCAT('Rows Loaded           : ', @RowsInserted);
            PRINT CONCAT('Duplicates Removed    : ', @DuplicateExceptionsRemoved);
            PRINT CONCAT('Execution Time        : ', @DurationSeconds);
            PRINT '----------------------------------------';
            SELECT
                  SeverityCode
                , COUNT(*) AS ExceptionCount
            FROM #CustomerExceptions
            GROUP BY SeverityCode
            ORDER BY SeverityCode;
        END;

        /* ============================================================
           SECTION J - CLEANUP TEMPORARY OBJECTS
           ============================================================ */

        DROP TABLE IF EXISTS #DataQualityIssues;
        DROP TABLE IF EXISTS #ExceptionStage;
        DROP TABLE IF EXISTS #ExceptionCategory;
        DROP TABLE IF EXISTS #ExceptionSeverity;
        DROP TABLE IF EXISTS #BusinessOwner;
        DROP TABLE IF EXISTS #CustomerExceptions;
        DROP TABLE IF EXISTS #DailyExceptionSummary;
        DROP TABLE IF EXISTS #BusinessAreaSummary;

        COMMIT TRANSACTION;

    END TRY

    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SET @EndTime = SYSDATETIME();
        SET @Status = 'FAILED';
        SET @Message = CONCAT('Error ', ERROR_NUMBER(), ' - ', ERROR_MESSAGE());

        IF @EnableLogging = 1
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM Audit.ETLExecutionLog WHERE ExecutionId = @ExecutionId)
            BEGIN
                INSERT INTO Audit.ETLExecutionLog
                (
                      ExecutionId
                    , ProcedureName
                    , BusinessDate
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
                    , @StartTime
                    , @Status
                    , @Message
                    , DATEDIFF(SECOND, @StartTime, @EndTime)
                );
            END
            ELSE
            BEGIN
                UPDATE Audit.ETLExecutionLog
                SET
                      EndTime         = @EndTime
                    , Status          = @Status
                    , Message         = @Message
                    , DurationSeconds = DATEDIFF(SECOND, @StartTime, @EndTime)
                WHERE ExecutionId = @ExecutionId;
            END;
        END;

        DROP TABLE IF EXISTS #DataQualityIssues;
        DROP TABLE IF EXISTS #ExceptionStage;
        DROP TABLE IF EXISTS #ExceptionCategory;
        DROP TABLE IF EXISTS #ExceptionSeverity;
        DROP TABLE IF EXISTS #BusinessOwner;
        DROP TABLE IF EXISTS #CustomerExceptions;
        DROP TABLE IF EXISTS #DailyExceptionSummary;
        DROP TABLE IF EXISTS #BusinessAreaSummary;

        THROW;
    END CATCH;
END;
GO

PRINT 'Procedure Warehouse.usp_LoadCustomerMasterExceptions created successfully.';
GO





