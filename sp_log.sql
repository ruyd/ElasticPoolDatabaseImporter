SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author: Ruy
-- Create Date: 11/30/2018
-- Description: Custom Azure Stats Collection for Queries 
-- =============================================
-- DROP TABLE ImportLogs 

ALTER PROCEDURE [dbo].[sp_log]
(
    @tableName VARCHAR(150), @sourceName VARCHAR(150), @DatabaseKey VARCHAR(50), 
	@loopId DECIMAL(18,2), @t1 DATETIME, @g1 DATETIME, @affected INT = 0, @message VARCHAR(1000) = NULL, @BatchID VARCHAR(50) = NULL  
)
AS
BEGIN

	IF OBJECT_ID('ImportLogs') IS NULL 
	BEGIN 
	 
	CREATE TABLE [dbo].[ImportLogs](
	[ID] [int] IDENTITY(1,1) NOT NULL,
	[TableName] [varchar](150) NULL,	
	[SourceName] [varchar](50) NULL,
	[DatabaseKey] [varchar](50) NULL,	
	[Message] [varchar](1000) NULL,
	[LoopID] [decimal](18, 2) NULL,
	[LoopInSeconds] [int] NULL,
	[LoopInMinutes] [int] NULL,
	[RunMinutes] [int] NULL,
	[AvgCPU] [decimal](18, 1) NULL,
	[MaxCPU] [decimal](18, 1) NULL,
	[AvgIO] [decimal](18, 1) NULL,
	[MaxIO] [decimal](18, 1) NULL,
	[AvgLog] [decimal](18, 1) NULL,
	[MaxLog] [decimal](18, 1) NULL,
	[AvgMem] [decimal](18, 1) NULL,
	[MaxMem] [decimal](18, 1) NULL,
	[AvgDTU] [decimal](18, 1) NULL,
	[MaxDTU] [decimal](18, 1) NULL,
	[DateTimeCreated] [datetime] NULL,
	[DateTimeStart] [datetime] NULL,
	[PartScheme] [int] NULL,
	[CompressScheme] [varchar](150) NULL,
	[AfterCount] [int] NULL,
	[AffectedCount] [int] NULL,
	[BatchID] [varchar](50) NULL,
	CONSTRAINT [PK_ImportLogs] PRIMARY KEY CLUSTERED ([ID] ASC)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF) ON [PRIMARY]) ON [PRIMARY]

	ALTER TABLE [dbo].[ImportLogs] ADD  CONSTRAINT [DF_Logs_DateTimeCreated]  DEFAULT (getdate()) FOR [DateTimeCreated]

	END



    -- SET NOCOUNT ON added to prevent extra result sets from
    -- interfering with SELECT statements.
    SET NOCOUNT ON

		DECLARE @AvgCPU	decimal(18, 1);
		DECLARE @MaxCPU	decimal(18, 1);
		DECLARE @AvgIO	decimal(18, 1);
		DECLARE @MaxIO	decimal(18, 1);
		DECLARE @AvgLog	decimal(18, 1);
		DECLARE @MaxLog	decimal(18, 1);
		DECLARE @AvgMem	decimal(18, 1);
		DECLARE @MaxMem	decimal(18, 1);
		DECLARE @AvgDTU	decimal(18, 1);
		DECLARE @MaxDTU	decimal(18, 1);

		DECLARE @Compression VARCHAR(100); 
		DECLARE @AfterCount INT; 
		DECLARE @Partitions INT; 
		DECLARE @IsAzure BIT = IIF(SERVERPROPERTY('EngineEdition') = 5, 1, 0);

		 
		SELECT @Partitions = COUNT(a.partition_number), @AfterCount = SUM(a.rows), @Compression = MIN(a.data_compression_desc) FROM sys.partitions a WITH (NOLOCK) 
		INNER JOIN sys.tables b ON a.object_id = b.object_id 
		WHERE b.name = @tableName AND a.index_id = 1 

		IF @IsAzure = 1 
		BEGIN 

			SELECT @AvgCPU = AVG(avg_cpu_percent), @MaxCPU = MAX(avg_cpu_percent), @AvgIO = AVG(avg_data_io_percent), @MaxIO = MAX(avg_data_io_percent), 
				@AvgLog = AVG(avg_log_write_percent), @MaxLog = MAX(avg_log_write_percent), @AvgMem = AVG(avg_memory_usage_percent), @MaxMem = MAX(avg_memory_usage_percent) 
			FROM sys.dm_db_resource_stats WHERE end_time >= @g1;

 
			SELECT 
				@AvgDTU = AVG(t.[avg_DTU_percent]), 
				@MaxDTU = MAX(t.[max_DTU_percent]) 
				FROM 		
					(SELECT end_time, 
							(SELECT Avg(v) FROM (VALUES (avg_cpu_percent), (avg_data_io_percent), (avg_log_write_percent)) AS value(v)) AS [avg_DTU_percent], 
							(SELECT Max(v) FROM (VALUES (avg_cpu_percent), (avg_data_io_percent), (avg_log_write_percent)) AS value(v)) AS [max_DTU_percent] 
					FROM sys.dm_db_resource_stats WHERE end_time >= @g1) as t 

		END 
	
		PRINT CONCAT('Loop: ', @loopId, ' Size: ', ' Time: ', DATEDIFF(second, @t1, GETDATE()), 's or ', DATEDIFF(minute, @t1, GETDATE()), 'mins | Run: ', DATEDIFF(minute, @g1, GETDATE()), 'mins @ DTU: ', @MaxDTU, ' | Rows: ', @AfterCount, ' Affected: ', @affected, GETDATE());
	
		-- Insert statements for procedure here
		INSERT INTO ImportLogs(TableName, SourceName, DatabaseKey, [Message], LoopID, LoopInSeconds, LoopInMinutes, RunMinutes, AvgCPU,
		MaxCPU,
		AvgIO,
		MaxIO,
		AvgLog,
		MaxLog,
		AvgMem,
		MaxMem,
		AvgDTU,
		MaxDTU,
		DateTimeStart, 
		PartScheme, 
		CompressScheme, 
		AfterCount, 
		AffectedCount,
		BatchID)
	VALUES(@tableName, @sourceName, @DatabaseKey, @message, @loopId, DATEDIFF(second, @t1, GETDATE()), DATEDIFF(MINUTE, @t1, GETDATE()), DATEDIFF(MINUTE, @g1, GETDATE()), 
		@AvgCPU,
		@MaxCPU,
		@AvgIO,
		@MaxIO,
		@AvgLog,
		@MaxLog,
		@AvgMem,
		@MaxMem,
		@AvgDTU,
		@MaxDTU,
		@t1, 
		@Partitions, 
		@Compression, 
		@AfterCount,
		@affected, 
		@BatchID);

END