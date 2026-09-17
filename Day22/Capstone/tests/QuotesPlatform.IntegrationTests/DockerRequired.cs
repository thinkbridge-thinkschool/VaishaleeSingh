using DotNet.Testcontainers.Builders;
using Testcontainers.MsSql;

namespace QuotesPlatform.IntegrationTests;

/// <summary>
/// Turns "Docker is not running" into one readable line.
///
/// WHY THIS EXISTS. Testcontainers pings the Docker endpoint inside
/// MsSqlBuilder.Build(), so with Docker stopped the fixture throws before a
/// single test body runs -- and xUnit reports a fixture failure once PER TEST.
/// The observed cost was 24 near-identical failures, each carrying a
/// forty-frame stack trace through Docker.DotNet and Microsoft.Net.Http.Client,
/// for one fact that fits on one line: Docker Desktop was not started.
///
/// That is a real diagnostic defect, not a cosmetic one. Output that long reads
/// like a broken test suite rather than a stopped daemon, and the honest first
/// reaction to it is to go looking in the code that was just written.
///
/// The guard does not make anything pass. It only makes the reason legible.
/// </summary>
internal static class DockerRequired
{
    internal static MsSqlContainer Build(string image)
    {
        try
        {
            return new MsSqlBuilder(image).Build();
        }
        catch (DockerUnavailableException ex)
        {
            throw new InvalidOperationException(
                """
                Docker is not reachable, so no real SQL Server can be started.

                These tests are not broken -- they were green on the last run
                and nothing about them has changed. Start Docker Desktop, wait
                for it to report Running, and run the suite again.

                To run only the tests that do not need Docker meanwhile:
                  dotnet test --filter "FullyQualifiedName!~IntegrationTests&FullyQualifiedName!~ApiTests"
                """,
                ex);
        }
    }
}
