SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:      Ruy Delgado
-- Create Date: 11/29/2018
-- Description: After Elastic Pool Mount, 
-- before importing, optimizations to source db
-- =============================================
--CREATE 
--OR 
ALTER 
PROCEDURE [dbo].[sp_prep]
(
   @dsName NVARCHAR(500), 
   @objs s_objs READONLY, 
   @cols s_cols READONLY,    
   @indexes s_indexes READONLY, 
   @keys s_keys READONLY, 
   @fkeys s_fkeys READONLY, 
   @tables s_tables READONLY 
)
AS
BEGIN

	DECLARE @oid INT, @parentName NVARCHAR(500), @tableName NVARCHAR(500), @query NVARCHAR(MAX), @ix NVARCHAR(500), @dbName VARCHAR(500), @ispk BIT;

	SELECT @dbName = database_name FROM sys.external_data_sources WHERE name = @dsName;

	--MOST CURRENT COMPATIBILITY LEVEL  				
	SET @query = N'ALTER DATABASE ' + @dbName + ' SET COMPATIBILITY_LEVEL = 140 ';
	
	EXEC sp_execute_remote @dsName, @query;

	--CHECK TABLES WITH 2+ VARCHAR/BINARY(MAX) FIELDS AND CHANGE TO COLUMNSTORE
	
	DECLARE maxcur CURSOR FOR  	
	SELECT o.object_id, o.name FROM @cols c INNER JOIN @objs o ON o.object_id = c.object_id 
		WHERE c.max_length = -1 AND o.type = 'U' GROUP BY o.object_id, o.name HAVING COUNT(1) > 1; 

	OPEN maxcur 
	FETCH NEXT FROM maxcur INTO @oid, @tableName  
	WHILE @@FETCH_STATUS = 0 
	BEGIN
	 
		--DEPENDANT FOREIGN KEYS 
		PRINT 'CHECKING FOREIGN KEYS...'
		DECLARE fkcur CURSOR FOR 
		SELECT f.name, t.name FROM @fkeys f INNER JOIN @tables t ON f.parent_object_id = t.object_id WHERE referenced_object_id = @oid; 
 
		OPEN fkcur 
		FETCH NEXT FROM fkcur INTO @ix, @parentName 
		WHILE @@FETCH_STATUS = 0 
		BEGIN 			
			PRINT 'DROPPING FK PKS ' + @ix;
			SET @query = 'ALTER TABLE ' + @parentName + ' DROP CONSTRAINT ' + @ix;			
			PRINT @query;
			EXEC sp_execute_remote @dsName, @query;
			FETCH NEXT FROM fkcur INTO @ix, @parentName 
		END 		
		CLOSE fkcur 
		DEALLOCATE fkcur 

		SET @ix = NULL; 
		
		PRINT 'CHECKING INDEXES...'
		--1.1 REMOVE PREVIOUS IXES 
		DECLARE ixcur CURSOR FOR 
		SELECT name, is_primary_key FROM @indexes WHERE object_id = @oid AND [type] <> 5; 

		OPEN ixcur 
		FETCH NEXT FROM ixcur INTO @ix, @ispk 
		WHILE @@FETCH_STATUS = 0 
		BEGIN 			
			PRINT 'DROPPING INDEX ' + @ix;
			
			IF @ispk = 1 
				SET @query = 'ALTER TABLE ' + @tableName + ' DROP CONSTRAINT ' + @ix;
			ELSE 
				SET @query = 'DROP INDEX IF EXISTS ' + @ix + ' ON ' + @tableName + '';

			PRINT @query;

			EXEC sp_execute_remote @dsName, @query;

			FETCH NEXT FROM ixcur INTO @ix, @ispk 
		END 		
		CLOSE ixcur 
		DEALLOCATE ixcur 

		--1.2 NEW
		SET @query = CONCAT('IF NOT EXISTS(SELECT NAME FROM sys.indexes WHERE name = ''IX_CS_', @tableName,''') CREATE CLUSTERED COLUMNSTORE INDEX [IX_CS_', @tableName, '] ON ', 
									@tableName, ' WITH (DATA_COMPRESSION = COLUMNSTORE_ARCHIVE) '); 		
		PRINT 'CREATING COLUMNSTORE...';
		PRINT @query; 			
		EXEC sp_execute_remote @dsName, @query;

		FETCH NEXT FROM maxcur INTO @oid, @tableName 
	END

	CLOSE maxcur 
	DEALLOCATE maxcur 

	--*******EXPAND PROCESSING HERE ************** 





	

END
