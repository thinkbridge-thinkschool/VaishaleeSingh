using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace QuotesPlatform.Modules.Curation.Infrastructure.Migrations
{
    /// <inheritdoc />
    public partial class AddProcessedMessages : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "ProcessedMessages",
                schema: "curation",
                columns: table => new
                {
                    MessageId = table.Column<string>(type: "nvarchar(64)", maxLength: 64, nullable: false),
                    SubscriptionName = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: false),
                    ProcessedAtUtc = table.Column<DateTime>(type: "datetime2", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_ProcessedMessages", x => new { x.MessageId, x.SubscriptionName });
                });

            migrationBuilder.CreateIndex(
                name: "IX_ProcessedMessages_ProcessedAtUtc",
                schema: "curation",
                table: "ProcessedMessages",
                column: "ProcessedAtUtc");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "ProcessedMessages",
                schema: "curation");
        }
    }
}
