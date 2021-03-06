SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Ruy Delgado
-- Create Date: 11/30/2018
-- Description: Report Counts and Totals 
-- sp_report
-- =============================================
ALTER PROCEDURE [dbo].[sp_report] 
(
 @option VARCHAR(2) = NULL
)
AS
BEGIN

    SET NOCOUNT ON	 

	DECLARE @query NVARCHAR(MAX); 

	SET @query = '
		IF OBJECT_ID(''ImportCounts'') IS NULL 
		BEGIN 		 
			CREATE TABLE ImportCounts (TableName VARCHAR(100), RecordCount INT, SizeMB DECIMAL(18, 2), NoteStore BIT)
		END 
		TRUNCATE TABLE ImportCounts; 
		INSERT INTO ImportCounts 	
		SELECT t.name, SUM(s.row_count), SUM(reserved_page_count * 8.0 / 1024), @isNote FROM sys.tables t join sys.dm_db_partition_stats s 
		ON t.object_id = s.object_id AND t.type_desc = ''USER_TABLE'' AND t.name not like ''%dss%'' AND s.index_id = 1 
		GROUP BY t.name 
		ORDER BY t.name 
	'; 

	EXEC sp_execute_remote [RepoDS], @query, N'@isNote BIT = 0'; 

	EXEC sp_execute_remote [RepoNotesDS], @query, N'@isNote BIT = 1'; 

	IF OBJECT_ID('repo_counts') IS NULL 
	BEGIN 
		CREATE EXTERNAL TABLE repo_counts (TableName VARCHAR(100), RecordCount INT, SizeMB DECIMAL(18, 2), NoteStore BIT)
		WITH (DATA_SOURCE = [RepoDS], SCHEMA_NAME = 'dbo', OBJECT_NAME = 'ImportCounts') 
	END 
	
	IF OBJECT_ID('note_counts') IS NULL 
	BEGIN 
		CREATE EXTERNAL TABLE note_counts (TableName VARCHAR(100), RecordCount INT, SizeMB DECIMAL(18, 2), NoteStore BIT)
		WITH (DATA_SOURCE = [RepoNotesDS], SCHEMA_NAME = 'dbo', OBJECT_NAME = 'ImportCounts') 
	END 

	IF OBJECT_ID('ImportCounts') IS NULL 
	BEGIN 		 	 
		CREATE TABLE ImportCounts (TableName VARCHAR(100), RecordCount INT, SizeMB DECIMAL(18, 2), NoteStore BIT)
	END 
	TRUNCATE TABLE ImportCounts; 
	INSERT INTO ImportCounts (TableName, RecordCount, SizeMB, NoteStore) 
	SELECT * FROM repo_counts 
	UNION 
	SELECT * FROM note_counts 
	
	SELECT * FROM ImportCounts 
       
END
