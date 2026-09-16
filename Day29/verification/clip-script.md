# Recording the happy path — shot list

Roughly two minutes. The point is not to show that a script prints
"VERIFIED"; it is to show that the things it crosses are real and that the
result survives the script that produced it.

## Before recording (not filmed)

```powershell
Get-Process dotnet -ErrorAction SilentlyContinue | Stop-Process -Force
cd C:\thinkschool
$env:CAPSTONE_SQL_PASSWORD = '<local sa password>'
./Day29/scripts/run-host.ps1
```

Wait for `Now listening on: http://localhost:5080` and the three
`... processor started` lines. Second window: `cd C:\thinkschool`, `cls`.
For both panes in one frame, split with `Alt`+`Shift`+`D` — Game Bar
records a single window.

Start recording only when the Host is idle. A build is not evidence.

## Filmed

### 1. The infrastructure is real (~15s)

```powershell
docker ps --filter name=capstone-sql --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
az servicebus topic subscription list --resource-group thinkschool-dev-rg `
  --namespace-name sb-quotes-7mo4cimyk4vnk --topic-name capstone.collection-events `
  --query "[].name" -o tsv
```

Answers "is any of this in-memory?" before it is asked.

### 2. The API is up (~5s)

```powershell
Invoke-RestMethod http://localhost:5080/health
```

### 3. The run (~40s)

```powershell
./Day29/verification/happy-path.ps1 -BaseUrl http://localhost:5080 -TimeoutSeconds 60
```

Do not touch anything while it runs. The two waits are the subject, not
dead air: each is a message crossing Service Bus, and with the Host pane in
frame the relay and consumer lines land inside them.

### 4. The result outlives the script (~20s)

```powershell
Invoke-RestMethod http://localhost:5080/api/editions/day-29-happy-path-<id> |
  ConvertTo-Json -Depth 4
```

Different module, different endpoint, same edition — so the proof is not
the script asserting on its own echo.

### 5. Again, on fresh ids (~15s, optional)

```powershell
./Day29/verification/happy-path.ps1 -BaseUrl http://localhost:5080 -TimeoutSeconds 60
```

Answers "did it only work once?" for the cost of forty seconds.

## Avoid

- `docker run` or `dotnet ef database update` on camera: slow, and not the
  thing being demonstrated.
- Typing during the async waits. A still terminal reads as the system
  working; a scrolling one reads as noise.

## If it fails on camera

Keep the take. A failed hop with the Host log beside it is more useful to a
reviewer than a clean re-run, because it shows where the seam is. Four of
this day's nine defects were found exactly this way.
