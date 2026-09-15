SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
 
CREATE   PROCEDURE [CURATED].[USP_GET_NOTIFICATION_RECIPIENTS]
    @PipelineType      VARCHAR(50),
    @NotificationType  VARCHAR(50),
    @NotificationGroup VARCHAR(500) = 'DEFAULT'   -- semicolon-separated, e.g. 'SALES;ACCRUALS'
AS
BEGIN
    SET NOCOUNT ON;


    DECLARE @FallbackToRecipients VARCHAR(2000) = 'chrisli@amphenol-hsio.com';
    DECLARE @FallbackCcRecipients VARCHAR(2000) = 'sudarshan.g@digitusbiz.com';
    DECLARE @FallbackTeamsId      VARCHAR(200)  = '19:c6b85cc2f0b74863b3f81bcb6653a8bf@thread.v2';
 
    ;WITH RequestedGroups AS (
        SELECT DISTINCT LTRIM(RTRIM(value)) AS NOTIFICATION_GROUP
        FROM STRING_SPLIT(@NotificationGroup, ';')
        WHERE LTRIM(RTRIM(value)) <> ''
    ),
 
    -- Priority 1: rows matching a specifically requested group
    SpecificMatch AS (
        SELECT DISTINCT
            c.TO_RECIPIENTS, c.CC_RECIPIENTS, c.TEAM_GROUP_ID, 'FOUND' AS CONFIG_STATUS
        FROM CURATED.CTL_NOTIFICATION_CONFIG c
        INNER JOIN RequestedGroups g
            ON g.NOTIFICATION_GROUP = c.NOTIFICATION_GROUP
        WHERE c.PIPELINE_TYPE     = @PipelineType
          AND c.NOTIFICATION_TYPE = @NotificationType
          AND c.IS_ACTIVE         = 'Y'
    ),
 
    -- Priority 2: no specific group matched, fall back to DEFAULT rows
    DefaultMatch AS (
        SELECT DISTINCT
            c.TO_RECIPIENTS, c.CC_RECIPIENTS, c.TEAM_GROUP_ID, 'FOUND' AS CONFIG_STATUS
        FROM CURATED.CTL_NOTIFICATION_CONFIG c
        WHERE c.PIPELINE_TYPE      = @PipelineType
          AND c.NOTIFICATION_TYPE  = @NotificationType
          AND c.IS_ACTIVE          = 'Y'
          AND c.NOTIFICATION_GROUP = 'DEFAULT'
          AND NOT EXISTS (SELECT 1 FROM SpecificMatch)
    ),
 
    -- Priority 3: nothing in the table at all, generic hardcoded fallback
    FallbackMatch AS (
        SELECT
            @FallbackToRecipients AS TO_RECIPIENTS,
            @FallbackCcRecipients AS CC_RECIPIENTS,
            @FallbackTeamsId      AS TEAM_GROUP_ID,
            'NOT_FOUND'           AS CONFIG_STATUS
        WHERE NOT EXISTS (SELECT 1 FROM SpecificMatch)
          AND NOT EXISTS (SELECT 1 FROM DefaultMatch)
    ),
 

    Combined AS (
        SELECT * FROM SpecificMatch
        UNION ALL SELECT * FROM DefaultMatch
        UNION ALL SELECT * FROM FallbackMatch
    ),
 
    ToRecipientsFlat AS (
        SELECT DISTINCT LTRIM(RTRIM(t.value)) AS item
        FROM Combined c
        CROSS APPLY STRING_SPLIT(c.TO_RECIPIENTS, ';') t
        WHERE LTRIM(RTRIM(t.value)) <> ''
    ),
    CcRecipientsFlat AS (
        SELECT DISTINCT LTRIM(RTRIM(t.value)) AS item
        FROM Combined c
        CROSS APPLY STRING_SPLIT(c.CC_RECIPIENTS, ';') t
        WHERE LTRIM(RTRIM(t.value)) <> ''
    ),
    TeamGroupFlat AS (
        SELECT DISTINCT LTRIM(RTRIM(c.TEAM_GROUP_ID)) AS item
        FROM Combined c
        WHERE c.TEAM_GROUP_ID IS NOT NULL AND LTRIM(RTRIM(c.TEAM_GROUP_ID)) <> ''
    )
 
    SELECT
        (SELECT STRING_AGG(item, '; ') FROM ToRecipientsFlat) AS TO_RECIPIENTS,
        (SELECT STRING_AGG(item, '; ') FROM CcRecipientsFlat) AS CC_RECIPIENTS,
        (SELECT STRING_AGG(item, '; ') FROM TeamGroupFlat)    AS TEAM_GROUP_ID,
        (SELECT MAX(CONFIG_STATUS) FROM Combined)             AS CONFIG_STATUS;
END
GO
