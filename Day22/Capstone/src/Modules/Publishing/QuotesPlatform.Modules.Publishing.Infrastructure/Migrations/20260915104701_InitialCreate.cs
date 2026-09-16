using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace QuotesPlatform.Modules.Publishing.Infrastructure.Migrations
{
    /// <inheritdoc />
    public partial class InitialCreate : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.EnsureSchema(
                name: "publishing");

            migrationBuilder.CreateTable(
                name: "Editions",
                schema: "publishing",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "uniqueidentifier", nullable: false),
                    CollectionId = table.Column<Guid>(type: "uniqueidentifier", nullable: false),
                    EditionNumber = table.Column<int>(type: "int", nullable: false),
                    Name = table.Column<string>(type: "nvarchar(80)", maxLength: 80, nullable: false),
                    Slug = table.Column<string>(type: "nvarchar(120)", maxLength: 120, nullable: false),
                    OwnerId = table.Column<string>(type: "nvarchar(max)", nullable: false),
                    PublishedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_Editions", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "EditionItems",
                schema: "publishing",
                columns: table => new
                {
                    Position = table.Column<int>(type: "int", nullable: false),
                    EditionId = table.Column<Guid>(type: "uniqueidentifier", nullable: false),
                    QuoteId = table.Column<Guid>(type: "uniqueidentifier", nullable: false),
                    Author = table.Column<string>(type: "nvarchar(200)", maxLength: 200, nullable: false),
                    Text = table.Column<string>(type: "nvarchar(1000)", maxLength: 1000, nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_EditionItems", x => new { x.EditionId, x.Position });
                    table.ForeignKey(
                        name: "FK_EditionItems_Editions_EditionId",
                        column: x => x.EditionId,
                        principalSchema: "publishing",
                        principalTable: "Editions",
                        principalColumn: "Id",
                        onDelete: ReferentialAction.Cascade);
                });

            migrationBuilder.CreateIndex(
                name: "IX_Editions_CollectionId_EditionNumber",
                schema: "publishing",
                table: "Editions",
                columns: new[] { "CollectionId", "EditionNumber" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_Editions_Slug",
                schema: "publishing",
                table: "Editions",
                column: "Slug");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "EditionItems",
                schema: "publishing");

            migrationBuilder.DropTable(
                name: "Editions",
                schema: "publishing");
        }
    }
}
