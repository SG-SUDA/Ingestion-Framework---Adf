SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE    PROCEDURE [CURATED].[USP_GET_FILE_LOAD_CONFIG] ( @SiteUrl    VARCHAR(500), @FolderPath VARCHAR(1000), @FileName   VARCHAR(255) )
AS
BEGIN
    SET NOCOUNT ON;

--1. Normalizing all the inputs -- trim '/' first, then whitespace, then '/' again
--   in case a slash was hiding a trailing space underneath it

    DECLARE @NormSite   VARCHAR(500)  = LOWER(LTRIM(RTRIM(TRIM('/' FROM LTRIM(RTRIM(@SiteUrl))))));
    DECLARE @NormFolder VARCHAR(1000) = LOWER(LTRIM(RTRIM(TRIM('/' FROM LTRIM(RTRIM(@FolderPath))))));
    DECLARE @NormFile   VARCHAR(255)  = LOWER(LTRIM(RTRIM(@FileName)));

-- 2. Normalizing the config paths the same way, so both sides compare on equal footing

    SELECT C.FILE_LOAD_CONFIG_ID, C.SUBJECT_AREA, C.NOTIFICATION_GROUP, C.SHAREPOINT_SITE_URL, C.SHAREPOINT_WORKING_FOLDER_PATH, C.SHAREPOINT_WORKING_FILE_NAME, C.SHAREPOINT_ARCHIVE_FOLDER_PATH, C.SHAREPOINT_QUARANTINE_FOLDER_PATH, C.ADLS_WORK_FILE_NAME, C.ADLS_WORK_FOLDER_PATH, C.ADLS_ARCHIVE_FOLDER_PATH, C.FILE_TYPE, C.FILE_DELIMITER, C.MAX_FILE_SIZE_BYTES, C.LOAD_STRATEGY, C.TARGET_SCHEMA_NAME, C.TARGET_TABLE_NAME, C.ADF_PIPELINE_NAME, C.DUPLICATE_CHECK_WINDOW_IN_DAYS, C.APPROVAL_TIMEOUT_HOURS, C.IS_WORKSHEET_VALIDATION_REQUIRED, C.IS_SCHEMA_VALIDATION_REQUIRED,
        LOWER(LTRIM(RTRIM(TRIM('/' FROM LTRIM(RTRIM(C.SHAREPOINT_SITE_URL)))))) AS NORM_SITE,
        LOWER(LTRIM(RTRIM(TRIM('/' FROM LTRIM(RTRIM(C.SHAREPOINT_WORKING_FOLDER_PATH)))))) AS NORM_FOLDER,
        LOWER(LTRIM(RTRIM(C.SHAREPOINT_WORKING_FILE_NAME))) AS NORM_FILE
    INTO #Normalized
    FROM CURATED.CTL_FILE_LOAD_CONFIG C
    WHERE C.IS_ACTIVE = 'Y';

---> 3. MATCH COUNTS -> STATUS

    DECLARE @ExactCount INT, @FolderCount INT;

    SELECT @ExactCount = COUNT(*)
    FROM #Normalized
    WHERE NORM_SITE = @NormSite AND NORM_FOLDER = @NormFolder AND NORM_FILE = @NormFile;

    SELECT @FolderCount = COUNT(*)
    FROM #Normalized
    WHERE NORM_SITE = @NormSite AND NORM_FOLDER = @NormFolder;

    DECLARE @Status VARCHAR(25) = CASE WHEN @ExactCount = 1 THEN 'FOUND'
                                       WHEN @ExactCount > 1 THEN 'MULTIPLE_FOUND'
                                       WHEN @FolderCount > 0 THEN 'FILE_NOT_RECOGNIZED'
                                       ELSE 'NOT_FOUND' END;

    DECLARE @ConfigId INT = NULL;
    IF @Status = 'FOUND'
        SELECT @ConfigId = FILE_LOAD_CONFIG_ID
        FROM #Normalized
        WHERE NORM_SITE = @NormSite AND NORM_FOLDER = @NormFolder AND NORM_FILE = @NormFile;


---4. Defining the Notification_group based on the status

    DECLARE @NotificationGroup VARCHAR(100) =
        CASE
            WHEN @Status = 'FOUND' THEN
                (SELECT NOTIFICATION_GROUP FROM #Normalized WHERE FILE_LOAD_CONFIG_ID = @ConfigId)
            WHEN @Status = 'MULTIPLE_FOUND' THEN
                (SELECT TOP 1 NOTIFICATION_GROUP FROM #Normalized
                 WHERE NORM_SITE = @NormSite AND NORM_FOLDER = @NormFolder AND NORM_FILE = @NormFile
                 ORDER BY FILE_LOAD_CONFIG_ID)
            WHEN @Status = 'FILE_NOT_RECOGNIZED' THEN
                (SELECT TOP 1 NOTIFICATION_GROUP FROM #Normalized
                 WHERE NORM_SITE = @NormSite AND NORM_FOLDER = @NormFolder
                 ORDER BY FILE_LOAD_CONFIG_ID)
            WHEN @Status = 'NOT_FOUND' THEN 'SUPPORT_TEAM'
        END;


--5. Defining error message per staus

    DECLARE @ErrorMessage VARCHAR(1000) =
        CASE
            WHEN @Status = 'MULTIPLE_FOUND' THEN
                CONCAT('Multiple metadata entries found for site [', @SiteUrl, '], folder [', @FolderPath, '] and file [', @FileName, '].')
            WHEN @Status = 'FILE_NOT_RECOGNIZED' THEN
                CONCAT('File [', @FileName, '] is not recognized in folder [', @FolderPath, '].')
            WHEN @Status = 'NOT_FOUND' THEN
                CONCAT('No file load configuration found for site [', @SiteUrl, '] and folder [', @FolderPath, ']. File [', @FileName, '] cannot be processed. Please contact the support team.')
        END;


-- 6. RETURN EXACTLY ONE ROW -- only one branch ever executes

    IF @Status = 'FOUND'
    BEGIN
        SELECT
            @Status AS CONFIG_STATUS, FILE_LOAD_CONFIG_ID, SUBJECT_AREA, 
            @NotificationGroup AS NOTIFICATION_GROUP, SHAREPOINT_ARCHIVE_FOLDER_PATH, SHAREPOINT_QUARANTINE_FOLDER_PATH, ADLS_WORK_FILE_NAME, ADLS_WORK_FOLDER_PATH, ADLS_ARCHIVE_FOLDER_PATH, 
            FILE_TYPE, FILE_DELIMITER, MAX_FILE_SIZE_BYTES, LOAD_STRATEGY, TARGET_SCHEMA_NAME, TARGET_TABLE_NAME, ADF_PIPELINE_NAME, DUPLICATE_CHECK_WINDOW_IN_DAYS, APPROVAL_TIMEOUT_HOURS, IS_WORKSHEET_VALIDATION_REQUIRED, IS_SCHEMA_VALIDATION_REQUIRED, 
        NULL AS ERROR_MESSAGE
        FROM #Normalized
        WHERE FILE_LOAD_CONFIG_ID = @ConfigId;
    END
    ELSE
    BEGIN
        SELECT
		    @Status AS CONFIG_STATUS, NULL  AS FILE_LOAD_CONFIG_ID, NULL  AS SUBJECT_AREA, 
		    @NotificationGroup  AS NOTIFICATION_GROUP, 
		    NULL AS SHAREPOINT_ARCHIVE_FOLDER_PATH, NULL AS SHAREPOINT_QUARANTINE_FOLDER_PATH, NULL AS ADLS_WORK_FILE_NAME, NULL AS ADLS_WORK_FOLDER_PATH, NULL AS ADLS_ARCHIVE_FOLDER_PATH,
            NULL AS FILE_TYPE, NULL AS FILE_DELIMITER, NULL AS MAX_FILE_SIZE_BYTES, NULL AS LOAD_STRATEGY, NULL AS TARGET_SCHEMA_NAME, NULL AS TARGET_TABLE_NAME, NULL AS ADF_PIPELINE_NAME, NULL AS DUPLICATE_CHECK_WINDOW_IN_DAYS, 
            NULL AS APPROVAL_TIMEOUT_HOURS, NULL AS IS_WORKSHEET_VALIDATION_REQUIRED, NULL AS IS_SCHEMA_VALIDATION_REQUIRED,
        @ErrorMessage   AS ERROR_MESSAGE;
    END
END;
GO