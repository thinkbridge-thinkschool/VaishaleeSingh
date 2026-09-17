using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace QuotesPlatform.Modules.Publishing.Infrastructure.Migrations
{
    /// <inheritdoc />
    public partial class IndexEditionsBySlugAndNumber : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_Editions_Slug",
                schema: "publishing",
                table: "Editions");

            migrationBuilder.CreateIndex(
                name: "IX_Editions_Slug_EditionNumber",
                schema: "publishing",
                table: "Editions",
                columns: new[] { "Slug", "EditionNumber" },
                descending: new[] { false, true });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_Editions_Slug_EditionNumber",
                schema: "publishing",
                table: "Editions");

            migrationBuilder.CreateIndex(
                name: "IX_Editions_Slug",
                schema: "publishing",
                table: "Editions",
                column: "Slug");
        }
    }
}
