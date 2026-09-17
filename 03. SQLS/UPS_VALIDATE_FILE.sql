CREATE OR ALTER PROCEDURE CURATED.USP_VALIDATE_FILE (
    @FileLoadConfigId  INT,
    @FileName          VARCHAR(255),
    @FileSizeBytes     BIGINT
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ExpectedFileName VARCHAR(255), @MaxSizeBytes BIGINT, @FileType VARCHAR(10);

    SELECT
        @ExpectedFileName = SHAREPOINT_WORKING_FILE_NAME,
        @MaxSizeBytes     = MAX_FILE_SIZE_BYTES,
        @FileType         = FILE_TYPE
    FROM CURATED.CTL_FILE_LOAD_CONFIG
    WHERE FILE_LOAD_CONFIG_ID = @FileLoadConfigId;

    DECLARE @ActualExtension VARCHAR(10) =
        CASE WHEN CHARINDEX('.', REVERSE(@FileName)) > 0
             THEN RIGHT(@FileName, CHARINDEX('.', REVERSE(@FileName)) - 1)
             ELSE '' END;

    DECLARE @ExpectedExtension VARCHAR(10) =
        CASE @FileType WHEN 'EXCEL' THEN 'xlsx' WHEN 'CSV' THEN 'csv' END;

    DECLARE @ValidationStatus VARCHAR(10) = 'PASS';
    DECLARE @FailureStage VARCHAR(50) = NULL;
    DECLARE @FailureReason VARCHAR(1000) = NULL;

    IF LOWER(LTRIM(RTRIM(@FileName))) <> LOWER(LTRIM(RTRIM(@ExpectedFileName))) 
    BEGIN
        SET @ValidationStatus = 'FAIL';
        SET @FailureStage = 'FILENAME_CHECK';
        SET @FailureReason = CONCAT('Uploaded file [', @FileName, '] does not match the expected file name [', @ExpectedFileName, '] for this subject area.');
    END
    ELSE IF LOWER(@ActualExtension) <> LOWER(@ExpectedExtension)
    BEGIN
        SET @ValidationStatus = 'FAIL';
        SET @FailureStage = 'FILE_TYPE_CHECK';
        SET @FailureReason = CONCAT('Uploaded file has extension [.', @ActualExtension, '] but this subject area expects [.', @ExpectedExtension, '].');
    END
    ELSE IF @FileSizeBytes = 0
    BEGIN
        SET @ValidationStatus = 'FAIL';
        SET @FailureStage = 'FILE_SIZE_CHECK';
        SET @FailureReason = 'Uploaded file is empty (0 bytes).';
    END
    ELSE IF @FileSizeBytes > @MaxSizeBytes
    BEGIN
        SET @ValidationStatus = 'FAIL';
        SET @FailureStage = 'FILE_SIZE_CHECK';
        SET @FailureReason = CONCAT('Uploaded file size [', @FileSizeBytes, ' bytes] exceeds the maximum allowed [', @MaxSizeBytes, ' bytes] for this subject area.');
    END

    SELECT @ValidationStatus AS VALIDATION_STATUS, @FailureStage AS FAILURE_STAGE, @FailureReason AS FAILURE_REASON;
END;


----> File type and File size check

File_Type ----> 1. file_name check should be not doen be changing any case in lower caseor upper case as ....adf is case sensitive tool
                2. there are also patterned based files for example Revenue Projection Loading Sheets_051326    where Revenue Projection Loading Sheets{_mmddYY} is naming style for such the date part should be removed and matching should be done on basis on name.
                3. what if some one instead of EXCEL , put xlsx as file type.
                4. tommorow we alos need to think about file types like parquet can alos be on boarded..
                5. also ther could be issue like user cans send instead of item.csv  and file called as item.CSV...you can laos think aboyu any other edge cases 



select * from curated.ctl_file_load_config