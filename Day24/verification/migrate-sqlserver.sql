IF OBJECT_ID(N'[__EFMigrationsHistory]') IS NULL
BEGIN
    CREATE TABLE [__EFMigrationsHistory] (
        [MigrationId] nvarchar(150) NOT NULL,
        [ProductVersion] nvarchar(32) NOT NULL,
        CONSTRAINT [PK___EFMigrationsHistory] PRIMARY KEY ([MigrationId])
    );
END;
GO

BEGIN TRANSACTION;
IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260812114103_InitialCreate'
)
BEGIN
    CREATE TABLE [Collections] (
        [Id] int NOT NULL IDENTITY,
        [Name] nvarchar(80) NOT NULL,
        [OwnerId] nvarchar(max) NOT NULL,
        CONSTRAINT [PK_Collections] PRIMARY KEY ([Id])
    );
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260812114103_InitialCreate'
)
BEGIN
    CREATE TABLE [Quotes] (
        [Id] int NOT NULL IDENTITY,
        [Author] nvarchar(max) NOT NULL,
        [Text] nvarchar(max) NOT NULL,
        [CreatedByUserId] nvarchar(max) NULL,
        CONSTRAINT [PK_Quotes] PRIMARY KEY ([Id])
    );
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260812114103_InitialCreate'
)
BEGIN
    CREATE TABLE [Users] (
        [Id] int NOT NULL IDENTITY,
        [Email] nvarchar(255) NOT NULL,
        [PasswordHash] nvarchar(max) NOT NULL,
        [CreatedAt] datetime2 NOT NULL,
        CONSTRAINT [PK_Users] PRIMARY KEY ([Id])
    );
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260812114103_InitialCreate'
)
BEGIN
    CREATE TABLE [CollectionItem] (
        [QuoteId] int NOT NULL,
        [CollectionId] int NOT NULL,
        [AddedAt] datetime2 NOT NULL,
        CONSTRAINT [PK_CollectionItem] PRIMARY KEY ([CollectionId], [QuoteId]),
        CONSTRAINT [FK_CollectionItem_Collections_CollectionId] FOREIGN KEY ([CollectionId]) REFERENCES [Collections] ([Id]) ON DELETE CASCADE
    );
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260812114103_InitialCreate'
)
BEGIN
    CREATE TABLE [RefreshTokens] (
        [Id] int NOT NULL IDENTITY,
        [UserId] int NOT NULL,
        [TokenHash] nvarchar(450) NOT NULL,
        [ExpiresAt] datetime2 NOT NULL,
        [RevokedAt] datetime2 NULL,
        [ReplacedByToken] nvarchar(max) NULL,
        [CreatedAt] datetime2 NOT NULL,
        [FamilyId] nvarchar(100) NULL,
        CONSTRAINT [PK_RefreshTokens] PRIMARY KEY ([Id]),
        CONSTRAINT [FK_RefreshTokens_Users_UserId] FOREIGN KEY ([UserId]) REFERENCES [Users] ([Id]) ON DELETE CASCADE
    );
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260812114103_InitialCreate'
)
BEGIN
    CREATE INDEX [IX_RefreshTokens_FamilyId] ON [RefreshTokens] ([FamilyId]);
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260812114103_InitialCreate'
)
BEGIN
    CREATE UNIQUE INDEX [IX_RefreshTokens_TokenHash] ON [RefreshTokens] ([TokenHash]);
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260812114103_InitialCreate'
)
BEGIN
    CREATE INDEX [IX_RefreshTokens_UserId] ON [RefreshTokens] ([UserId]);
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260812114103_InitialCreate'
)
BEGIN
    CREATE UNIQUE INDEX [IX_Users_Email] ON [Users] ([Email]);
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260812114103_InitialCreate'
)
BEGIN
    INSERT INTO [__EFMigrationsHistory] ([MigrationId], [ProductVersion])
    VALUES (N'20260812114103_InitialCreate', N'10.0.10');
END;

COMMIT;
GO

BEGIN TRANSACTION;
IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260901072938_SyncModelThroughDay19'
)
BEGIN
    DECLARE @var nvarchar(max);
    SELECT @var = QUOTENAME([d].[name])
    FROM [sys].[default_constraints] [d]
    INNER JOIN [sys].[columns] [c] ON [d].[parent_column_id] = [c].[column_id] AND [d].[parent_object_id] = [c].[object_id]
    WHERE ([d].[parent_object_id] = OBJECT_ID(N'[Quotes]') AND [c].[name] = N'Author');
    IF @var IS NOT NULL EXEC(N'ALTER TABLE [Quotes] DROP CONSTRAINT ' + @var + ';');
    ALTER TABLE [Quotes] ALTER COLUMN [Author] nvarchar(450) NOT NULL;
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260901072938_SyncModelThroughDay19'
)
BEGIN
    ALTER TABLE [Quotes] ADD [BackgroundImageUrl] nvarchar(500) NOT NULL DEFAULT N'';
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260901072938_SyncModelThroughDay19'
)
BEGIN
    CREATE TABLE [ProcessedMessages] (
        [MessageId] nvarchar(128) NOT NULL,
        [SubscriptionName] nvarchar(50) NOT NULL,
        [ProcessedAtUtc] datetime2 NOT NULL,
        [Outcome] nvarchar(50) NOT NULL,
        CONSTRAINT [PK_ProcessedMessages] PRIMARY KEY ([MessageId], [SubscriptionName])
    );
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260901072938_SyncModelThroughDay19'
)
BEGIN
    CREATE TABLE [QuoteAuditEntries] (
        [Id] int NOT NULL IDENTITY,
        [EventId] nvarchar(128) NOT NULL,
        [QuoteId] int NOT NULL,
        [EventType] nvarchar(50) NOT NULL,
        [OwnerId] nvarchar(max) NULL,
        [OccurredAt] datetimeoffset NOT NULL,
        [RecordedAtUtc] datetime2 NOT NULL,
        CONSTRAINT [PK_QuoteAuditEntries] PRIMARY KEY ([Id])
    );
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260901072938_SyncModelThroughDay19'
)
BEGIN
    CREATE TABLE [QuoteSearchProjections] (
        [QuoteId] int NOT NULL,
        [Author] nvarchar(200) NULL,
        [Text] nvarchar(1000) NULL,
        [LastUpdatedAt] datetimeoffset NOT NULL,
        CONSTRAINT [PK_QuoteSearchProjections] PRIMARY KEY ([QuoteId])
    );
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260901072938_SyncModelThroughDay19'
)
BEGIN
    CREATE INDEX [IX_Quotes_Author] ON [Quotes] ([Author]);
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260901072938_SyncModelThroughDay19'
)
BEGIN
    CREATE INDEX [IX_ProcessedMessages_ProcessedAtUtc] ON [ProcessedMessages] ([ProcessedAtUtc]);
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260901072938_SyncModelThroughDay19'
)
BEGIN
    CREATE INDEX [IX_QuoteAuditEntries_QuoteId] ON [QuoteAuditEntries] ([QuoteId]);
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260901072938_SyncModelThroughDay19'
)
BEGIN
    CREATE INDEX [IX_QuoteAuditEntries_RecordedAtUtc] ON [QuoteAuditEntries] ([RecordedAtUtc]);
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260901072938_SyncModelThroughDay19'
)
BEGIN
    INSERT INTO [__EFMigrationsHistory] ([MigrationId], [ProductVersion])
    VALUES (N'20260901072938_SyncModelThroughDay19', N'10.0.10');
END;

COMMIT;
GO

BEGIN TRANSACTION;
IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260902061851_AddOutboxMessages'
)
BEGIN
    CREATE TABLE [OutboxMessages] (
        [Id] bigint NOT NULL IDENTITY,
        [MessageId] nvarchar(128) NOT NULL,
        [EventType] nvarchar(50) NOT NULL,
        [SchemaVersion] nvarchar(16) NOT NULL,
        [Payload] nvarchar(max) NOT NULL,
        [TraceParent] nvarchar(64) NULL,
        [OccurredAtUtc] datetime2 NOT NULL,
        [Status] nvarchar(16) NOT NULL,
        [Attempts] int NOT NULL,
        [LastError] nvarchar(512) NULL,
        [LockedUntilUtc] datetime2 NULL,
        [LockOwner] nvarchar(64) NULL,
        [SentAtUtc] datetime2 NULL,
        CONSTRAINT [PK_OutboxMessages] PRIMARY KEY ([Id])
    );
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260902061851_AddOutboxMessages'
)
BEGIN
    CREATE UNIQUE INDEX [IX_OutboxMessages_MessageId] ON [OutboxMessages] ([MessageId]);
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260902061851_AddOutboxMessages'
)
BEGIN
    EXEC(N'CREATE INDEX [IX_OutboxMessages_Pending] ON [OutboxMessages] ([Status], [Id]) WHERE [Status] = ''Pending''');
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260902061851_AddOutboxMessages'
)
BEGIN
    CREATE INDEX [IX_OutboxMessages_SentAtUtc] ON [OutboxMessages] ([SentAtUtc]);
END;

IF NOT EXISTS (
    SELECT * FROM [__EFMigrationsHistory]
    WHERE [MigrationId] = N'20260902061851_AddOutboxMessages'
)
BEGIN
    INSERT INTO [__EFMigrationsHistory] ([MigrationId], [ProductVersion])
    VALUES (N'20260902061851_AddOutboxMessages', N'10.0.10');
END;

COMMIT;
GO

