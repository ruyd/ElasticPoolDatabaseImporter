SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Ruy Delgado
-- Create Date: 11/15/2018
-- Description: Rollback / Remove Data by Key
-- =============================================
CREATE OR ALTER PROCEDURE [dbo].[sp_remove] 
(
	@key VARCHAR(50) 
)
AS
BEGIN
  
	PRINT 'REMOVING/DATA ROLLBACK FOR DatabaseKey' + @key;
			
	IF OBJECT_ID('repo_tables') IS NULL 
		BEGIN 
			CREATE EXTERNAL TABLE repo_tables (name SYSNAME, is_external BIT, object_id INT) WITH (DATA_SOURCE = [RepoDS], SCHEMA_NAME = 'sys', OBJECT_NAME = 'tables')				
		END 

	IF OBJECT_ID('note_tables') IS NULL 
		BEGIN 
			CREATE EXTERNAL TABLE note_tables (name SYSNAME, is_external BIT, object_id INT) WITH (DATA_SOURCE = [RepoNotesDS], SCHEMA_NAME = 'sys', OBJECT_NAME = 'tables')
		END 			

	DECLARE @name VARCHAR(500);
	DECLARE @query NVARCHAR(2000)
	DECLARE repocur CURSOR FOR 
	SELECT name FROM repo_tables WHERE is_external = 0  

	OPEN repocur 
	FETCH NEXT FROM repocur INTO @name 

	WHILE @@FETCH_STATUS = 0 
	BEGIN 
			
		SET @query = N'DELETE FROM ' + @name + ' WHERE DatabaseKey = ''' + @key + ''' ';
		PRINT @query;
		EXEC sp_execute_remote N'RepoDS', @query; 
		PRINT '- DONE';

		FETCH NEXT FROM repocur INTO @name 
	END 

	CLOSE repocur 
	DEALLOCATE repocur 

		
	DECLARE repocur CURSOR FOR 
	SELECT name FROM note_tables WHERE is_external = 0  

	OPEN repocur 
	FETCH NEXT FROM repocur INTO @name 

	WHILE @@FETCH_STATUS = 0 
	BEGIN 
			
		SET @query = N'DELETE FROM ' + @name + ' WHERE DatabaseKey = ''' + @key + ''' ';
		PRINT @query;
		EXEC sp_execute_remote N'RepoNotesDS', @query; 
		PRINT '- DONE';

		FETCH NEXT FROM repocur INTO @name 
	END 

	CLOSE repocur 
	DEALLOCATE repocur 
	     
	PRINT CONCAT('END OF SCRIPT // ', GETDATE());

END
