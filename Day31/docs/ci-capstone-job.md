# CI change for Day 31 — apply by hand

`.github/workflows/ci.yml` is protected against remote writes, so this one is a
copy-paste rather than a committed edit from the assistant.

## What to replace

In the **`capstone`** job, replace everything from the comment beginning
`# ArchitectureTests read the .csproj files` down to the end of the
`Upload test results` step with the block below. Nothing above `- name: Test`
changes; `Checkout`, `Setup .NET`, `Restore` and `Build` stay exactly as they are.

## Why it changes

**The gate did not exist for the capstone.** The coverage threshold lives only
in the `test` job, which targets `Day5/piece2`. So the newest code in the
repository — three days old, four modules, the whole capstone — had the weakest
check on it in the whole workflow. "Green CI gate" for Day 31 means closing that.

**The merged-report upload is deliberately not reused.** The `test` job's
`Upload merged coverage report` step is currently failing with a 403 from an
intermediary on `FinalizeArtifact`. Copying its shape would copy its problem, so
the capstone threshold is computed and printed in-job and does not depend on
artifact storage working at all.

**Two of the four test projects now need Docker.** `IntegrationTests` and
`ApiTests` both start a real SQL Server via Testcontainers. `ubuntu-latest`
ships with Docker so no `services:` block is needed, but this is the first thing
in this workflow to depend on that, and the first image pull costs a minute or
two. If the job starts failing on container startup, that is where to look.

## The threshold number

`THRESHOLD = 55.0` is a placeholder and **must be set from the first green run**,
not left as written. Read the percentage the step prints, then set the threshold
a few points below it — low enough not to fail on rounding, high enough to catch
a real regression. A threshold picked before the measurement is a number that
tests nothing.

## The block

```yaml
      # FOUR LAYERS RUN HERE, AND TWO OF THEM NEED DOCKER.
      #
      # ArchitectureTests read the .csproj files, so a boundary violation fails
      # the build the day the reference is added rather than the day somebody
      # writes code that uses it. CompositionTests build the container the Host
      # builds and construct every hosted service in it. Neither needs
      # infrastructure.
      #
      # IntegrationTests and ApiTests do: both start a real SQL Server 2022 via
      # Testcontainers. GitHub's ubuntu-latest runners ship with Docker, so this
      # works without a services: block -- but it is the first thing in this
      # workflow to depend on that, and the first image pull costs a minute or
      # two. If this job starts failing on container startup, that is where to
      # look, not at the tests.
      #
      # Service Bus is NOT reachable from CI and nothing here needs it: the API
      # tests strip the module hosted services out of the test host, and the
      # integration tests drive handlers directly. The broker is covered by
      # happy-path.ps1 against the live namespace, which is a human-run step by
      # design.
      - name: Test
        run: >
          dotnet test Day22/Capstone/QuotesPlatform.slnx
          --no-build
          --configuration Release
          --logger trx
          --collect:"XPlat Code Coverage"

      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: capstone-test-results
          path: '**/TestResults/*.trx'
          if-no-files-found: ignore

      # THE GATE. Until today this job built and tested and asserted nothing
      # about how much of the capstone those tests actually touch -- the
      # coverage threshold existed only for Day5/piece2, so the newest code in
      # the repository had the weakest check on it.
      #
      # Deliberately NOT reusing the other job's upload-artifact step for the
      # merged report: that step is currently failing with a 403 from an
      # intermediary on FinalizeArtifact, and copying its shape would copy its
      # problem. The summary below is computed and printed in-job, so the gate
      # does not depend on artifact storage working at all.
      - name: Enforce capstone coverage threshold
        if: always()
        shell: python {0}
        run: |
          import glob, sys, xml.etree.ElementTree as ET

          # Chosen from the measured number rather than picked from the air:
          # set this to a few points BELOW whatever the first green run reports,
          # so it catches a real regression without failing on rounding.
          THRESHOLD = 55.0

          reports = glob.glob('**/TestResults/**/coverage.cobertura.xml', recursive=True)
          if not reports:
              print('::error::No coverage report was produced. The gate cannot pass by finding nothing.')
              sys.exit(1)

          covered = total = 0
          for report in reports:
              root = ET.parse(report).getroot()
              for cls in root.iter('class'):
                  for line in cls.iter('line'):
                      total += 1
                      if int(line.get('hits', '0')) > 0:
                          covered += 1

          if total == 0:
              print('::error::Coverage reports contained no lines. Treating as a failure, not a pass.')
              sys.exit(1)

          percent = 100.0 * covered / total
          print(f'Capstone line coverage: {percent:.2f}% ({covered}/{total}) across {len(reports)} report(s)')

          with open('capstone-coverage.md', 'w') as summary:
              summary.write(f'## Capstone coverage\n\n**{percent:.2f}%** ({covered}/{total} lines)\n')

          if percent < THRESHOLD:
              print(f'::error::Coverage {percent:.2f}% is below the required {THRESHOLD}% threshold.')
              sys.exit(1)

      - name: Post capstone coverage summary
        if: always()
        run: cat capstone-coverage.md >> "$GITHUB_STEP_SUMMARY" || true
```
