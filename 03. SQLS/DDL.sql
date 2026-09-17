

CREATE TABLE CURATED.AUD_FILE_PROCESSING (
        AUDIT_ID                     BIGINT           IDENTITY(1,1) NOT NULL,
        CORRELATION_ID                UNIQUEIDENTIFIER NOT NULL,
        FILE_LOAD_CONFIG_ID          INT              NOT NULL,
 
        SP_ORIGINAL_FILE_NAME             VARCHAR(500)   NOT NULL,
  SP_ORIGINAL_FILE_PATH   VARCHAR(500)  ,
  SP_SITE_NAME      VARCHAR(500)   ,
 
        CREATED_BY                       VARCHAR(255) NULL,
        CREATED_TIMESTAMP                 DATETIME2(3) NULL,
        MODIFIED_BY                        VARCHAR(255) NULL,
        MODIFIED_TIMESTAMP                  DATETIME2(3) NULL,       -- see A9: DDD 5.8 spells this MODIFED_TIMESTAMP
 
        SHAREPOINT_SITE_ID                   VARCHAR(255) NULL,
        SHAREPOINT_DRIVE_ID                   VARCHAR(255) NULL,
        SHAREPOINT_ITEM_ID                     VARCHAR(255) NULL,
 
        ADLS_FILE_PATH                          VARCHAR(1000) NULL,
        PIPELINE_RUN_ID                          VARCHAR(50)   NULL, -- string, not GUID type: avoids type friction from the Logic Apps SQL connector
 
        PROCESSING_STATUS                         VARCHAR(20) NOT NULL,
        FAILURE_STAGE                              VARCHAR(50) NULL, -- free-text by design, see A5
        FAILURE_REASON                              VARCHAR(1000) NULL,
 
        APPROVAL_STATUS                              VARCHAR(20) NULL,
        APPROVED_BY                                   VARCHAR(255) NULL,
        APPROVAL_TIMESTAMP                             DATETIME2(3) NULL,
 
        RETRY_COUNT                                     INT NOT NULL CONSTRAINT DF_AFP_RETRY_COUNT DEFAULT (0),
 
        PROCESSING_START_TIME                            DATETIME2(3) NULL,
        PROCESSING_END_TIME                                DATETIME2(3) NULL,

        SP_QUARANTINE_FILE_NAME                                VARCHAR(500) NULL,
        SP_QUARANTINE_FILE_FOLDER                                VARCHAR(500) NULL,  
        SP_QUARANTINE_TIMESTAMP                                 DATETIME2(3) NULL,
        ARCHIVE_FILE_NAME                                     VARCHAR(500) NULL,
        ARCHIVE_TIMESTAMP                                      DATETIME2(3) NULL,

        FILE_SIZE_BYTES                 BIGINT        NULL,
        FILE_CHECKSUM                    VARCHAR(100) NULL,          -- quickXorHash, base64-encoded

        INS_DATE                                                DATETIME2(3) NOT NULL CONSTRAINT DF_AFP_INS_DATE DEFAULT (SYSUTCDATETIME()),
        UPD_DATE                                                 DATETIME2(3) NULL,
 
        CONSTRAINT PK_AUD_FILE_PROCESSING PRIMARY KEY CLUSTERED (AUDIT_ID),
        CONSTRAINT UQ_AFP_CORRELATION_ID UNIQUE (CORRELATION_ID),
        CONSTRAINT FK_AFP_FILE_LOAD_CONFIG FOREIGN KEY (FILE_LOAD_CONFIG_ID)
            REFERENCES CURATED.CTL_FILE_LOAD_CONFIG (FILE_LOAD_CONFIG_ID),
 
        CONSTRAINT CK_AFP_PROCESSING_STATUS CHECK (PROCESSING_STATUS IN
            ('DETECTED','IN_PROGRESS','TRIGGERED','COMPLETED','FAILED','REJECTED')),  -- see A7
        CONSTRAINT CK_AFP_APPROVAL_STATUS CHECK (APPROVAL_STATUS IS NULL OR APPROVAL_STATUS IN
            ('PENDING','APPROVED','REJECTED','TIMED_OUT')),
        CONSTRAINT CK_AFP_RETRY_COUNT_NONNEG CHECK (RETRY_COUNT >= 0)
    );
END
GO
 
-- Supports 5.2 step 6 (Concurrency gate) and the stuck-run monitor: both scan
-- for rows in a given status for a given subject area.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_AFP_CONFIG_STATUS' AND object_id = OBJECT_ID('CURATED.AUD_FILE_PROCESSING'))
BEGIN
    CREATE INDEX IX_AFP_CONFIG_STATUS
        ON CURATED.AUD_FILE_PROCESSING (FILE_LOAD_CONFIG_ID, PROCESSING_STATUS)
        INCLUDE (PROCESSING_START_TIME, CORRELATION_ID);
END
GO
 
-- Supports 5.5 checksum duplicate check: match against Completed files for the same subject area
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_AFP_CONFIG_CHECKSUM' AND object_id = OBJECT_ID('CURATED.AUD_FILE_PROCESSING'))
BEGIN
    CREATE INDEX IX_AFP_CONFIG_CHECKSUM
        ON CURATED.AUD_FILE_PROCESSING (FILE_LOAD_CONFIG_ID, FILE_CHECKSUM, PROCESSING_STATUS)
        INCLUDE (CORRELATION_ID, INS_DATE);
END
GO
 
 
-- ============================================================================
-- Auto-maintain UPD_DATE on every UPDATE, so no flow action has to remember
-- to set it by hand -- AUD_FILE_PROCESSING alone gets touched at half a
-- dozen different points in the flow's lifecycle.
-- ============================================================================
IF OBJECT_ID('CURATED.TRG_CFLC_SET_UPD_DATE', 'TR') IS NULL
EXEC('
    CREATE TRIGGER CURATED.TRG_CFLC_SET_UPD_DATE ON CURATED.CTL_FILE_LOAD_CONFIG
    AFTER UPDATE AS
    BEGIN
        SET NOCOUNT ON;
        UPDATE C SET UPD_DATE = SYSUTCDATETIME()
        FROM CURATED.CTL_FILE_LOAD_CONFIG C
        INNER JOIN inserted I ON I.FILE_LOAD_CONFIG_ID = C.FILE_LOAD_CONFIG_ID;
    END
');
GO
 
IF OBJECT_ID('CURATED.TRG_CFLCC_SET_UPD_DATE', 'TR') IS NULL
EXEC('
    CREATE TRIGGER CURATED.TRG_CFLCC_SET_UPD_DATE ON CURATED.CTL_FILE_LOAD_CONFIG_COLUMN
    AFTER UPDATE AS
    BEGIN
        SET NOCOUNT ON;
        UPDATE C SET UPD_DATE = SYSUTCDATETIME()
        FROM CURATED.CTL_FILE_LOAD_CONFIG_COLUMN C
        INNER JOIN inserted I ON I.FILE_LOAD_CONFIG_COLUMN_ID = C.FILE_LOAD_CONFIG_COLUMN_ID;
    END
');
GO
 
IF OBJECT_ID('CURATED.TRG_AFP_SET_UPD_DATE', 'TR') IS NULL
EXEC('
    CREATE TRIGGER CURATED.TRG_AFP_SET_UPD_DATE ON CURATED.AUD_FILE_PROCESSING
    AFTER UPDATE AS
    BEGIN
        SET NOCOUNT ON;
        UPDATE A SET UPD_DATE = SYSUTCDATETIME()
        FROM CURATED.AUD_FILE_PROCESSING A
        INNER JOIN inserted I ON I.AUDIT_ID = A.AUDIT_ID;
    END
');
GO
 


-- ============================================================================
-- 1. CTL_FILE_LOAD_CONFIG   (DDD Section 5.8)
-- One row per subject area. Drives every decision in the validation flow.
-- ============================================================================
IF OBJECT_ID('CURATED.CTL_FILE_LOAD_CONFIG', 'U') IS NULL
BEGIN
    CREATE TABLE CURATED.CTL_FILE_LOAD_CONFIG (
        FILE_LOAD_CONFIG_ID                INT              IDENTITY(1,1) NOT NULL,
        SUBJECT_AREA                       VARCHAR(100)     NOT NULL,
        NOTIFICATION_GROUP                 VARCHAR(100)     NOT NULL,
 
        -- SharePoint
        SHAREPOINT_SITE_URL                VARCHAR(500)     NOT NULL,
        SHAREPOINT_WORKING_FOLDER_PATH     VARCHAR(1000)    NOT NULL,
        SHAREPOINT_ARCHIVE_FOLDER_PATH     VARCHAR(1000)    NOT NULL,
        SHAREPOINT_QUARANTINE_FOLDER_PATH  VARCHAR(1000)    NOT NULL,
 
        -- ADLS
        ADLS_WORK_FOLDER_PATH              VARCHAR(1000)    NOT NULL,
        ADLS_ARCHIVE_FOLDER_PATH           VARCHAR(1000)    NOT NULL,
        WORK_FILE_NAME                     VARCHAR(255)     NOT NULL,
        ARCHIVE_FILE_NAME_PATTERN          VARCHAR(255)     NOT NULL,
 
        -- File shape
        FILE_TYPE                          VARCHAR(10)      NOT NULL,
        FILE_DELIMITER                     CHAR(1)          NULL,      -- assumes single-char delimiter; widen if that changes
        FILE_NAME_PATTERN                  VARCHAR(255)     NULL,
        EXPECTED_WORKSHEET_NAME            VARCHAR(255)     NULL,
        WORKSHEET_REFERENCE_TYPE           VARCHAR(10)      NULL,
        MAX_FILE_SIZE_BYTES                BIGINT           NOT NULL,
 
        -- Load behaviour
        LOAD_STRATEGY                      VARCHAR(20)      NOT NULL,
        TARGET_SCHEMA_NAME                 VARCHAR(128)     NOT NULL,
        TARGET_TABLE_NAME                  VARCHAR(128)     NOT NULL,
        SNAPSHOT_DATE_COLUMN_NAME          VARCHAR(128)     NULL,
        LOCK_RESOURCE_NAME                 VARCHAR(500)     NULL,      -- see A4: unused in v1
 
        -- Pipeline & duplicate handling
        ADF_PIPELINE_NAME                  VARCHAR(255)     NOT NULL,
        DUPLICATE_CHECK_WINDOW             VARCHAR(10)      NOT NULL,
        APPROVAL_TIMEOUT_HOURS             INT              NOT NULL,
 
        IS_ACTIVE                          CHAR(1)          NOT NULL CONSTRAINT DF_CFLC_IS_ACTIVE DEFAULT ('Y'),
        INS_DATE                           DATETIME2(3)     NOT NULL CONSTRAINT DF_CFLC_INS_DATE DEFAULT (SYSUTCDATETIME()),
        UPD_DATE                           DATETIME2(3)     NULL,
 
        -- Not in the DDD -- see Decision A10. Per-subject-area switches so
        -- worksheet and schema validation can be turned off while a subject
        -- area is still being onboarded, without that blocking the file from
        -- flowing through. Appended at the bottom, deliberately, rather than
        -- alongside EXPECTED_WORKSHEET_NAME / the schema columns above, so
        -- this stays a clean additive change on top of everything else.
        IS_WORKSHEET_VALIDATION_REQUIRED   CHAR(1)          NOT NULL CONSTRAINT DF_CFLC_IS_WS_VALIDATION_REQD DEFAULT ('Y'),
        IS_SCHEMA_VALIDATION_REQUIRED      CHAR(1)          NOT NULL CONSTRAINT DF_CFLC_IS_SCHEMA_VALIDATION_REQD DEFAULT ('Y'),
 
        CONSTRAINT PK_CTL_FILE_LOAD_CONFIG PRIMARY KEY CLUSTERED (FILE_LOAD_CONFIG_ID),
        CONSTRAINT UQ_CFLC_SUBJECT_AREA UNIQUE (SUBJECT_AREA),
 
        CONSTRAINT CK_CFLC_FILE_TYPE            CHECK (FILE_TYPE IN ('EXCEL','CSV')),
        CONSTRAINT CK_CFLC_LOAD_STRATEGY        CHECK (LOAD_STRATEGY IN ('UPSERT','APPEND','SNAPSHOT','TRUNCATE_LOAD')),
        CONSTRAINT CK_CFLC_WORKSHEET_REF_TYPE   CHECK (WORKSHEET_REFERENCE_TYPE IN ('NAME','INDEX') OR WORKSHEET_REFERENCE_TYPE IS NULL),
        CONSTRAINT CK_CFLC_DUP_WINDOW           CHECK (DUPLICATE_CHECK_WINDOW IN ('DAY','MONTH')),
        CONSTRAINT CK_CFLC_IS_ACTIVE            CHECK (IS_ACTIVE IN ('Y','N')),
        CONSTRAINT CK_CFLC_MAX_SIZE_POSITIVE    CHECK (MAX_FILE_SIZE_BYTES > 0),
        CONSTRAINT CK_CFLC_APPROVAL_TIMEOUT_POS CHECK (APPROVAL_TIMEOUT_HOURS > 0),
        CONSTRAINT CK_CFLC_IS_WS_VALIDATION_REQD    CHECK (IS_WORKSHEET_VALIDATION_REQUIRED IN ('Y','N')),
        CONSTRAINT CK_CFLC_IS_SCHEMA_VALIDATION_REQD CHECK (IS_SCHEMA_VALIDATION_REQUIRED IN ('Y','N')),
 
        -- Conditional requirements -- enforce the "only when" rules from 5.2/5.8 at the DB layer
        CONSTRAINT CK_CFLC_CSV_HAS_DELIMITER    CHECK (FILE_TYPE <> 'CSV'   OR FILE_DELIMITER IS NOT NULL),
        -- Worksheet name/reference type are only mandatory for Excel subject
        -- areas that actually have worksheet validation switched on -- see A10.
        CONSTRAINT CK_CFLC_EXCEL_HAS_WORKSHEET  CHECK (
            FILE_TYPE <> 'EXCEL'
            OR IS_WORKSHEET_VALIDATION_REQUIRED = 'N'
            OR (EXPECTED_WORKSHEET_NAME IS NOT NULL AND WORKSHEET_REFERENCE_TYPE IS NOT NULL)
        ),
        CONSTRAINT CK_CFLC_SNAPSHOT_HAS_DATECOL CHECK (LOAD_STRATEGY <> 'SNAPSHOT' OR SNAPSHOT_DATE_COLUMN_NAME IS NOT NULL)
    );
END
GO
 
-- Structurally prevents the "more than one active config matches this path"
-- fault condition described in DDD 5.2 step 4 (Config table lookup). See A8.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_CFLC_ACTIVE_WORKING_PATH' AND object_id = OBJECT_ID('CURATED.CTL_FILE_LOAD_CONFIG'))
BEGIN
    CREATE UNIQUE INDEX UX_CFLC_ACTIVE_WORKING_PATH
        ON CURATED.CTL_FILE_LOAD_CONFIG (SHAREPOINT_WORKING_FOLDER_PATH)
        WHERE IS_ACTIVE = 'Y';
END
GO
 

SELECT ORDER_DATE, * FROM [CURATED].[FACT_BILL]
where ORDER_DATE='01-09-2026'
AND F_ADJUST='F'




alter table curated.AUD_FILE_PROCESSING
alter column ins_date DATETIME2(3) null


drop index curated.AUD_FILE_PROCESSING.IX_AFP_CONFIG_CHECKSUM


IF OBJECT_ID('CURATED.TRG_AFP_SET_INS_DATE', 'TR') IS NULL
EXEC('
    drop  TRIGGER CURATED.TRG_AFP_SET_INS_DATE
    ON CURATED.AUD_FILE_PROCESSING
    AFTER INSERT
    AS
    BEGIN
        SET NOCOUNT ON;

        UPDATE A
        SET INS_DATE = SYSUTCDATETIME()
        FROM CURATED.AUD_FILE_PROCESSING A
        INNER JOIN inserted I
            ON I.AUDIT_ID = A.AUDIT_ID;
    END
');
GO


IF OBJECT_ID('CURATED.TRG_CFLC_SET_INS_DATE', 'TR') IS NULL
EXEC('
    drop  TRIGGER CURATED.TRG_CFLC_SET_INS_DATE
    ON CURATED.CTL_FILE_LOAD_CONFIG
    AFTER INSERT
    AS
    BEGIN
        SET NOCOUNT ON;

        UPDATE C
        SET INS_DATE = SYSUTCDATETIME()
        FROM CURATED.CTL_FILE_LOAD_CONFIG C
        INNER JOIN inserted I
            ON I.FILE_LOAD_CONFIG_ID = C.FILE_LOAD_CONFIG_ID;
    END
');
GO







select * from curated.fact_bill
wherE 1=1
and (ORDER_NUMBER LIKE 'E1000762%' AND INV_LINE = 2)
and (ORDER_NUMBER LIKE 'E1000869%' AND INV_LINE = 2)

 
E1000869	2	029-BR725	E	25HS009556_1
E1000869	2	029-BR725	E	25HS009556_1
 
 