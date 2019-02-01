SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Ruy Delgado
-- Create Date: 11/29/2018
-- Description: Generates Create Table Statement 
-- =============================================
-- BASED ON hansmichiels.com CLONE TABLE SCRIPT

CREATE 
--OR ALTER 
PROCEDURE sp_get_create
(   
    @createText VARCHAR(300),  
    @tableName VARCHAR(100), 
	@pkColumn VARCHAR(100), 
	@dateColumn VARCHAR(100), 
	@oid INT, 
	@tables s_tables READONLY, 
	@schemas s_schemas READONLY, 
	@cols s_cols READONLY, 
	@types s_types READONLY, 
	@cmps s_cmps READONLY, 
	@query_out NVARCHAR(MAX) OUTPUT 
)
AS
BEGIN
    -- SET NOCOUNT ON added to prevent extra result sets from
    -- interfering with SELECT statements.
    SET NOCOUNT ON;
	DECLARE @CrLf NVARCHAR(2) = CHAR(13) + CHAR(10);
	DECLARE @Indent NVARCHAR(2) = SPACE(2);	
	-- For 'min' script use this (in case sql is near 4000 characters):
	-- , @CrLf  = ' '
	-- , @Indent = ''	 
  
    SET @query_out = '';

	SELECT @query_out = ISNULL(@query_out, '') + CASE col_sequence WHEN 1 THEN       
	@CrLf + @createText + ' ' + @tableName + @CrLf + @Indent + '( ' ELSE @CrLf + @Indent + ', ' END
	    + [definition]
	FROM (SELECT ROW_NUMBER() OVER (PARTITION BY tb.object_id ORDER BY tb.object_id, col.column_id) AS col_sequence
		, QUOTENAME(col.name) + ' ' + COALESCE('AS ' + cmp.definition + CASE ISNULL(cmp.is_persisted, 0) WHEN 1 THEN ' PERSISTED ' ELSE '' END,
        CASE WHEN col.system_type_id != col.user_type_id THEN QUOTENAME(usr_tp.schema_name) + '.' + QUOTENAME(usr_tp.name)
			ELSE QUOTENAME(sys_tp.name) +
                CASE
                  WHEN sys_tp.name IN ('char', 'varchar', 'binary', 'varbinary') THEN '(' + CONVERT(VARCHAR, CASE col.max_length WHEN -1 THEN 'max' ELSE CAST(col.max_length AS varchar(10)) END) + ')'
                  WHEN sys_tp.name IN ('nchar', 'nvarchar') THEN '(' + CONVERT(VARCHAR, CASE col.max_length WHEN -1 THEN 'max' ELSE CAST(col.max_length/2 AS varchar(10)) END) + ')'
                  WHEN sys_tp.name IN ('decimal', 'numeric') THEN '(' + CAST(col.precision AS VARCHAR) + ',' + CAST(col.scale AS VARCHAR) +  ')'
                  WHEN sys_tp.name IN ('datetime2') THEN '(' + CAST(col.scale AS VARCHAR) +  ')'
                  ELSE ''
                END          
            END
            )       
			+ CASE WHEN col.is_nullable = 0 AND (col.name = @pkColumn OR col.name = @dateColumn) THEN ' NOT' ELSE '' END + ' NULL' AS [definition]
			FROM @tables tb 
			JOIN @schemas sch ON sch.schema_id = tb.schema_id
			JOIN @cols col ON col.object_id = tb.object_id
			JOIN @types sys_tp ON col.system_type_id = sys_tp.system_type_id AND col.system_type_id = sys_tp.user_type_id 
			LEFT JOIN
            (SELECT tp.*, sch.name AS [schema_name] 
				FROM @types tp JOIN @schemas sch ON tp.schema_id = sch.schema_id) usr_tp 
				ON col.system_type_id = usr_tp.system_type_id
			AND col.user_type_id = usr_tp.user_type_id 
			LEFT JOIN @cmps cmp ON cmp.object_id = tb.object_id AND cmp.column_id = col.column_id 
			WHERE tb.object_id = @oid AND col.is_computed=0) subqry;

	--SELECT @query_out;     
END
GO
