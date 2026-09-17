---> Notification_config:


select * from curated.CTL_NOTIFICATION_CONFIG;




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
        SHAREPOINT_WORKING_FILE_NAME       VARCHAR(100)     NOT NULL,
        SHAREPOINT_SITE_URL                VARCHAR(500)     NOT NULL,
        SHAREPOINT_WORKING_FOLDER_PATH     VARCHAR(1000)    NOT NULL,
        SHAREPOINT_ARCHIVE_FOLDER_PATH     VARCHAR(1000)    NOT NULL,
        SHAREPOINT_QUARANTINE_FOLDER_PATH  VARCHAR(1000)    NOT NULL,
 
        -- ADLS
        ADLS_WORK_FILE_NAME                VARCHAR(255)     NOT NULL,
        ADLS_WORK_FOLDER_PATH              VARCHAR(1000)    NOT NULL,
        ADLS_ARCHIVE_FOLDER_PATH           VARCHAR(1000)    NOT NULL,
        ARCHIVE_FILE_NAME_PATTERN          VARCHAR(255)     NOT NULL,
 
        -- File shape
        FILE_TYPE                          VARCHAR(10)      NOT NULL,
        FILE_DELIMITER                     CHAR(1)          NULL,      -- assumes single-char delimiter; widen if that changes
        FILE_NAME_PATTERN                  VARCHAR(255)     NULL,
        EXPECTED_WORKSHEET_NAME            VARCHAR(255)     NULL,
        WORKSHEET_REFERENCE_TYPE           VARCHAR(10)      NULL,
        MAX_FILE_SIZE_BYTES                BIGINT           NOT NULL,
 
        -- Load behaviour
        LOAD_STRATEGY                      VARCHAR(20)      ,
        TARGET_SCHEMA_NAME                 VARCHAR(128)     NOT NULL,
        TARGET_TABLE_NAME                  VARCHAR(128)     NOT NULL,
        SNAPSHOT_DATE_COLUMN_NAME          VARCHAR(128)     NULL,
        LOCK_RESOURCE_NAME                 VARCHAR(500)     NULL,      -- see A4: unused in v1
        IS_WORKSHEET_VALIDATION_REQUIRED   VARCHAR(1)       DEFAULT('N'),
        IS_SCHEMA_VALIDATION_REQUIRED      VARCHAR(1)       DEFAULT('N'), 
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
            FILE_TYPE not in  ('EXCEL','xlsx')
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
        ON CURATED.CTL_FILE_LOAD_CONFIG (SHAREPOINT_WORKING_FOLDER_PATH,SHAREPOINT_WORKING_FILE_NAME)
        -- WHERE IS_ACTIVE = 'Y';
END
GO
 ---select * from CURATED.CTL_FILE_LOAD_CONFIG





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

-- 1. Rename and finally populate this column — it's load-bearing now, not just a label
EXEC sp_rename 'CURATED.AUD_FILE_PROCESSING.SP_SITE_NAME', 'SP_SITE_URL', 'COLUMN';
-- backfill any existing NULLs before tightening this, then:
ALTER TABLE CURATED.AUD_FILE_PROCESSING ALTER COLUMN SP_SITE_URL VARCHAR(500) NOT NULL;

-- 2. Replace the folder-only uniqueness with the real compound key
DROP INDEX IF EXISTS UX_CFLC_ACTIVE_WORKING_PATH ON CURATED.CTL_FILE_LOAD_CONFIG;

CREATE UNIQUE INDEX UX_CFLC_ACTIVE_SITE_FOLDER_FILE
    ON CURATED.CTL_FILE_LOAD_CONFIG (SHAREPOINT_SITE_URL, SHAREPOINT_WORKING_FOLDER_PATH, SHAREPOINT_WORKING_FILE_NAME)
    WHERE IS_ACTIVE = 'Y';

select * from  CURATED.CTL_FILE_LOAD_CONFIG 

ALTER TABLE CURATED.CTL_FILE_LOAD_CONFIG DROP CONSTRAINT CK_CFLC_DUP_WINDOW;
EXEC sp_rename 'CURATED.CTL_FILE_LOAD_CONFIG.DUPLICATE_CHECK_WINDOW', 'DUPLICATE_CHECK_WINDOW_IN_DAYS', 'COLUMN';
ALTER TABLE CURATED.CTL_FILE_LOAD_CONFIG ALTER COLUMN DUPLICATE_CHECK_WINDOW_IN_DAYS INT NOT NULL;
ALTER TABLE CURATED.CTL_FILE_LOAD_CONFIG
    ADD CONSTRAINT CK_CFLC_DUP_WINDOW_POSITIVE CHECK (DUPLICATE_CHECK_WINDOW_IN_DAYS > 0);




/*
========================================================================================================================================================================
-- New queries
========================================================================================================================================================================
*/


select * from CURATED.CTL_NOTIFICATION_CONFIG


-- INSERT INTO CURATED.CTL_FILE_LOAD_CONFIG (
--     SUBJECT_AREA,
--     NOTIFICATION_GROUP,
--     SHAREPOINT_WORKING_FILE_NAME,
--     SHAREPOINT_SITE_URL,
--     SHAREPOINT_WORKING_FOLDER_PATH,
--     SHAREPOINT_ARCHIVE_FOLDER_PATH,
--     SHAREPOINT_QUARANTINE_FOLDER_PATH,
--     ADLS_WORK_FILE_NAME,
--     ADLS_WORK_FOLDER_PATH,
--     ADLS_ARCHIVE_FOLDER_PATH,
--     ARCHIVE_FILE_NAME_PATTERN,
--     FILE_TYPE,
--     FILE_DELIMITER,
--     FILE_NAME_PATTERN,
--     EXPECTED_WORKSHEET_NAME,
--     WORKSHEET_REFERENCE_TYPE,
--     MAX_FILE_SIZE_BYTES,
--     LOAD_STRATEGY,
--     TARGET_SCHEMA_NAME,
--     TARGET_TABLE_NAME,
--     SNAPSHOT_DATE_COLUMN_NAME,
--     LOCK_RESOURCE_NAME,
--     IS_WORKSHEET_VALIDATION_REQUIRED,
--     IS_SCHEMA_VALIDATION_REQUIRED,
--     ADF_PIPELINE_NAME,
--     DUPLICATE_CHECK_WINDOW,
--     APPROVAL_TIMEOUT_HOURS,
--     IS_ACTIVE
-- )
-- VALUES (
--     'ACCRUALS',                                                                              -- confirmed
--     'MARKETING_TEAM',                                                                        -- confirmed
--     'revenue_accrual.xlsx',                                                                  -- confirmed
--     'https://amphenolhsio.sharepoint.com/sites/PowerBI-DataAnalyticsVisualizationproject',    -- confirmed, from trigger
--     '/Shared Documents/Power BI - Phase 2/file_landing_area/accruals',                        -- PLACEHOLDER, verify exact folder
--     '/Shared Documents/Power BI - Phase 2/file_landing_area/accruals/archive',                -- PLACEHOLDER, verify
--     '/Shared Documents/Power BI - Phase 2/file_landing_area/accruals/quarantine',             -- PLACEHOLDER, verify
--     'revenue_accrual.xlsx',                                                                  -- confirmed, same name in ADLS
--     'raw/financial_adjustment',                                                               -- PLACEHOLDER, confirm real path
--     'raw/financial_adjustment/archive',                                                       -- PLACEHOLDER, confirm real path
--     'revenue_accrual_{yyyyMMdd}.xlsx',                                                        -- pattern, confirm suffix format wanted
--     'EXCEL',
--     NULL,
--     NULL,
--     NULL,
--     NULL,
--     10485760,                                                                                 -- 10 MB, PLACEHOLDER, confirm real limit
--     'APPEND',                                                                                 -- PLACEHOLDER, confirm real load strategy
--     'CURATED',
--     'FACT_ACCRUALS',                                                                          -- PLACEHOLDER, confirm real target table
--     NULL,
--     NULL,
--     'N',
--     'N',
--     'PL_Worker_Accruals',                                                                     -- PLACEHOLDER, confirm real ADF pipeline name
--     'DAY',
--     24,
--     'Y'
-- ); 




select * from curated.CTL_FILE_LOAD_CONFIG




/*
1. Orchestator piplene ----> Scheduler ---> master ----> 
2. Parent ----> 
            |
            |---> DIM
                    |---> SALES
                    |       |--> dim_cust
                            |---> dims_ship_to
                            |---> dim_product
                    |--->FINACE
                    |
                    |---> manufacturing
            |
            |---> Fact
                    |----> sales
                    |
                    |-----> Finace
                    |
                    |-----> Manufacture
3. child/ worker



1. MARKETING TEAM SITE:  |
2. FINANACE TEAM SITE :  |-----> common logic apps ----> single shared logic app can be changed 
3. MAN                   |

sharepoint site:
        ----> documnet library
                |--> sub folders
                        |
                        |----> files 

senior developer: ----> 
1. Nmaing convention ----> done 
2. connections string  -----> sqlserevr , azure blob storage , -------> sharepoint need to bre created at single time  and reused through out 
3. reusablity -----> single 
4. exception handdling 
5. consideration of all edge cases validation 
6. mainainable and scalabel solution 


authentication--=--> who you are : 
                    ---> username 
                    ---> password 



autthorization : -----> what acces you have:
                ----> read access
                --> write acces
                ----> grant delete access
identiy in azure : 

*/


SELECT * FROM CURATED.CTL_NOTIFICATION_CONFIG;
SELECT * FROM CURATED.CTL_FILE_LOAD_CONFIG;
-- update CURATED.CTL_FILE_LOAD_CONFIG
-- set ADF_PIPELINE_NAME = 'PL_FACT_BILL_ACCRUALS_ADJ'
-- WHERE FILE_LOAD_CONFIG_ID = 1

-- delete from  CURATED.CTL_FILE_LOAD_CONFIG
-- where FILE_LOAD_CONFIG_ID  = 5


-- delete from CURATED.AUD_FILE_PROCESSING;

UPDATE CURATED.AUD_FILE_PROCESSING
SET 


ALTER TABLE CURATED.AUD_FILE_PROCESSING ALTER COLUMN FILE_LOAD_CONFIG_ID INT NULL;


/*

{
  "SiteUrl": "https://amphenolhsio.sharepoint.com/sites/PowerBI-DataAnalyticsVisualizationproject",
  "Path": "Shared Documents/Power BI - Phase 2/file_landing_area/accruals/",
  "FullPath": "Shared Documents/Power BI - Phase 2/file_landing_area/accruals/revenue_accrual.xlsx",
  "FilenameWithExtension": "revenue_accrual.xlsx",
  "DriveId": "b!dJ_s5ULXoESob7mG476duQIhLqpAsPtFmi1zGxqXZl2U9TlEYg7tTZIfjkbN6QwT",
  "DriveItemId": "012ABDJDFLH6B32QKSHJF2HCH3CRHI6EDU",
  "Identifier": "Shared%2bDocuments%252fPower%2bBI%2b-%2bPhase%2b2%252ffile_landing_area%252faccruals%252frevenue_accrual.xlsx",
  "AuthorDisplayName": "Sudarshan Girme (Vendor)",
  "EditorDisplayName": "Sudarshan Girme (Vendor)",
  "Created": "2026-09-14 17:57:11",
  "Modified": "2026-09-14 17:57:11"
}


share point 

            |
            |----> Site
                        |
                        |---> Drive
                                    |
                                    |---> ITEM


_____________________________________________________________________________________________________________________________________________________

{
  "SiteUrl": "https://amphenolhsio.sharepoint.com/sites/PowerBI-DataAnalyticsVisualizationproject",
  "Path": "Shared Documents/Power BI - Phase 2/file_landing_area/accruals/",
  "FullPath": "Shared Documents/Power BI - Phase 2/file_landing_area/accruals/accruals_lumpsum_adj.xlsx",
  "FilenameWithExtension": "accruals_lumpsum_adj.xlsx",
  "DriveId": "b!dJ_s5ULXoESob7mG476duQIhLqpAsPtFmi1zGxqXZl2U9TlEYg7tTZIfjkbN6QwT",
  "DriveItemId": "012ABDJDBWJ7WXJKP6K5HLHSF75AFDR4N5",
  "Identifier": "Shared%2bDocuments%252fPower%2bBI%2b-%2bPhase%2b2%252ffile_landing_area%252faccruals%252faccruals_lumpsum_adj.xlsx",
  "AuthorDisplayName": "Sudarshan Girme (Vendor)",
  "EditorDisplayName": "Sudarshan Girme (Vendor)",
  "Created": "2026-09-14 09:11:10",
  "Modified": "2026-09-14 09:11:10"
}



_____________________________________________________________________________________________________________________________________________________


I undesrtand your query, but I have few scenarios that need tro be handled:
1. First thing fallback is must and import for me which you have comsiderd
2. Few scenarios i have;
    a. SP_ORIGINAL_FILE_NAME,	SP_ORIGINAL_FILE_PATH,	SP_SITE_NAME_address ---> thses  3 things i have rn.
    b. in one sub folder (Mapping_tables) ----> user can drop 3 files in my case 
                                                                                1. Mapp_bill_to_rename.xlsx
                                                                                2. mapp_end_cust_to_re_oem
                                                                                3. mapp_country_revise
    
    So scenarios are :
    1. user can drop multiple files in sub folders ----> but for each file ther should be one record in metedata table . f no record for such file is ther ...then highlit it 
    2. if user drop file in marketing notification group folder ,& if that file is wrong file EG; in mapping_tables , if he drop test.csv ------> then marketing tema, should aldso be informed along with support team
    3. the site address alos need to be valiadted , because we dont know there could be scenario where same subfolder could be in 2 diffrent sites.
    4. if file droped in random folder which is not ther in config table ...just inform the support team as no fil eowner is ther for them 


*/

;

select * from curated.DISTRIBUTED


INSERT INTO CURATED.CTL_FILE_LOAD_CONFIG
(

    SUBJECT_AREA,
    NOTIFICATION_GROUP,
    SHAREPOINT_WORKING_FILE_NAME,
    SHAREPOINT_SITE_URL,
    SHAREPOINT_WORKING_FOLDER_PATH,
    SHAREPOINT_ARCHIVE_FOLDER_PATH,
    SHAREPOINT_QUARANTINE_FOLDER_PATH,
    ADLS_WORK_FILE_NAME,
    ADLS_WORK_FOLDER_PATH,
    ADLS_ARCHIVE_FOLDER_PATH,
    ARCHIVE_FILE_NAME_PATTERN,
    FILE_TYPE,
    FILE_DELIMITER,
    FILE_NAME_PATTERN,
    EXPECTED_WORKSHEET_NAME,
    WORKSHEET_REFERENCE_TYPE,
    MAX_FILE_SIZE_BYTES,
    LOAD_STRATEGY,
    TARGET_SCHEMA_NAME,
    TARGET_TABLE_NAME,
    SNAPSHOT_DATE_COLUMN_NAME,
    LOCK_RESOURCE_NAME,
    IS_WORKSHEET_VALIDATION_REQUIRED,
    IS_SCHEMA_VALIDATION_REQUIRED,
    ADF_PIPELINE_NAME,
    DUPLICATE_CHECK_WINDOW,
    APPROVAL_TIMEOUT_HOURS,
    IS_ACTIVE,
    INS_DATE,
    UPD_DATE
)
VALUES
(

    'ACCRUALS',
    'MARKETING_TEAM',
    'accruals_lumpsum_adj.xlsx',
    'https://amphenolhsio.sharepoint.com/sites/PowerBI-DataAnalyticsVisualizationproject/',
    '/Shared Documents/Power BI - Phase 2/file_landing_area/accruals/',
    '/Shared Documents/Power BI - Phase 2/file_landing_area/accruals/archive',
    '/Shared Documents/Power BI - Phase 2/file_landing_area/accruals/quarantine',
    'revenue_accrual.xlsx',
    'raw/financial_adjustment',
    'raw/financial_adjustment/archive',
    'accruals_lumpsum_adj_{yyyyMMdd}.xlsx',
    'EXCEL',
    NULL,
    NULL,
    NULL,
    NULL,
    10485760,
    'APPEND',
    'CURATED',
    'FACT_ACCRUALS',
    NULL,
    NULL,
    'N',
    'N',
    'PL_Worker_Accruals',
    'DAY',
    24,
    'Y',
    '2026-09-11 10:19:51.057',
    NULL
);


-- ALTER table CURATED.CTL_FILE_LOAD_CONFIG
-- DROP CONSTRAINT UQ_CFLC_SUBJECT_AREA




UPDATE CURATED.AUD_FILE_PROCESSING
SET FILE_LOAD_CONFIG_ID = ''
WHERE CORRELATION_ID = 


{
  "Table1": [
    {
      "TO_RECIPIENTS": "chrisli@amphenol-hsio.com",
      "CC_RECIPIENTS": "sudarshan.g@digitusbiz.com",
      "TEAM_GROUP_ID": "19:c6b85cc2f0b74863b3f81bcb6653a8bf@thread.v2",
      "CONFIG_STATUS": "FOUND"
    }


-- {
--   "Table1": [
--     {
--       "CONFIG_STATUS": "NOT_FOUND",
--       "FILE_LOAD_CONFIG_ID": null,
--       "SUBJECT_AREA": null,
--       "NOTIFICATION_GROUP": "SUPPORT_TEAM",
--       "SHAREPOINT_ARCHIVE_FOLDER_PATH": null,
--       "SHAREPOINT_QUARANTINE_FOLDER_PATH": null,
--       "ADLS_WORK_FILE_NAME": null,
--       "ADLS_WORK_FOLDER_PATH": null,
--       "ADLS_ARCHIVE_FOLDER_PATH": null,
--       "ARCHIVE_FILE_NAME_PATTERN": null,
--       "FILE_TYPE": null,
--       "FILE_DELIMITER": null,
--       "MAX_FILE_SIZE_BYTES": null,
--       "LOAD_STRATEGY": null,
--       "TARGET_SCHEMA_NAME": null,
--       "TARGET_TABLE_NAME": null,
--       "ADF_PIPELINE_NAME": null,
--       "DUPLICATE_CHECK_WINDOW": null,
--       "APPROVAL_TIMEOUT_HOURS": null,
--       "IS_WORKSHEET_VALIDATION_REQUIRED": null,
--       "IS_SCHEMA_VALIDATION_REQUIRED": null,
--       "ERROR_MESSAGE": "No file load configuration found for site [https://amphenolhsio.sharepoint.com/sites/PowerBI-DataAnalyticsVisualizationproject] and folder [Shared Documents/Power BI - Phase 2/file_landing_area/accruals/]. File [accruals_lumpsum_adj.xlsx] cannot be processed. Please contact the support team."
--     }
--   ]
-- }


SELECT
    name,
    definition
FROM sys.check_constraints
WHERE name = 'CK_AFP_APPROVAL_STATUS';