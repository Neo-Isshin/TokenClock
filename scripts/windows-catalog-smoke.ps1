# Runs TokenClock's Windows-only catalog reporter against isolated, parser-shaped fixtures.
# It verifies declaration, path selection, real parser readability, and exists-but-unreadable state.
param(
    [Parameter(Mandatory = $true)]
    [string] $Exe,
    [string] $Out = (Join-Path $env:USERPROFILE 'TokenClockCatalogSmoke\catalog.json')
)

$ErrorActionPreference = 'Stop'
$outputDirectory = Split-Path $Out -Parent
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

# Keep the developer's real provider data out of this smoke test.
$isolatedUser = Join-Path $outputDirectory 'isolated-user'
$env:USERPROFILE = $isolatedUser
$env:APPDATA = Join-Path $isolatedUser 'AppData\Roaming'
$env:LOCALAPPDATA = Join-Path $isolatedUser 'AppData\Local'
$env:TC_EXPAND_SHORT = 'short-value'
$env:TC_EXPAND_LONG = 'long-value'
$env:TC_EXPAND_LONGER = 'longer-value'

$validLine = '{"timestamp":"2026-08-06T00:00:00Z","message":{"role":"assistant","usage":{"input":1,"output":1,"cacheRead":0}}}'
$env:OPENCLAW_HOME = Join-Path $outputDirectory 'openclaw-home-parent'
$env:OPENCLAW_STATE_DIR = Join-Path $outputDirectory 'openclaw-state'
$stateSessions = Join-Path $env:OPENCLAW_STATE_DIR 'agents\smoke\sessions'
New-Item -ItemType Directory -Path $stateSessions -Force | Out-Null
Set-Content -LiteralPath (Join-Path $stateSessions 'smoke.jsonl') -Value $validLine -Encoding ASCII

$env:CLAUDE_CONFIG_DIR = Join-Path $outputDirectory 'claude'
New-Item -ItemType Directory -Path (Join-Path $env:CLAUDE_CONFIG_DIR 'projects\smoke') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $env:CLAUDE_CONFIG_DIR 'projects\smoke\smoke.jsonl') -Value '{"type":"assistant","message":{"usage":{"input_tokens":1,"output_tokens":1}}}' -Encoding ASCII

$env:GEMINI_CLI_HOME = Join-Path $outputDirectory 'gemini-parent'
$geminiData = Join-Path $env:GEMINI_CLI_HOME '.gemini\tmp\smoke\chats'
New-Item -ItemType Directory -Path $geminiData -Force | Out-Null
Set-Content -LiteralPath (Join-Path $geminiData 'smoke.json') -Value '{"messages":[{"type":"gemini","tokens":{"input":1,"output":1}}]}' -Encoding ASCII

$env:CODEX_HOME = Join-Path $outputDirectory 'codex'
New-Item -ItemType Directory -Path (Join-Path $env:CODEX_HOME 'sessions\2026\08\06') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $env:CODEX_HOME 'sessions\2026\08\06\rollout-smoke.jsonl') -Value '{"payload":{"info":{"last_token_usage":{"total_tokens":2,"input_tokens":1,"output_tokens":1}}}}' -Encoding ASCII

$env:HERMES_HOME = Join-Path $outputDirectory 'hermes'
New-Item -ItemType Directory -Path $env:HERMES_HOME -Force | Out-Null
$hermesDb = Join-Path $env:HERMES_HOME 'state.db'

$env:OPENCODE_DB = Join-Path $outputDirectory 'opencode-direct\custom.db'
New-Item -ItemType Directory -Path (Split-Path $env:OPENCODE_DB -Parent) -Force | Out-Null
$openCodeDb = $env:OPENCODE_DB

$env:QWEN_RUNTIME_DIR = Join-Path $outputDirectory 'qwen'
New-Item -ItemType Directory -Path (Join-Path $env:QWEN_RUNTIME_DIR 'projects\smoke') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $env:QWEN_RUNTIME_DIR 'projects\smoke\smoke.jsonl') -Value '{"type":"gemini","tokens":{"input":1,"output":1}}' -Encoding ASCII

$env:COPILOT_OTEL_FILE_EXPORTER_PATH = Join-Path $outputDirectory 'copilot\otel-smoke.jsonl'
New-Item -ItemType Directory -Path (Split-Path $env:COPILOT_OTEL_FILE_EXPORTER_PATH -Parent) -Force | Out-Null
Set-Content -LiteralPath $env:COPILOT_OTEL_FILE_EXPORTER_PATH -Value '{"timestamp":"2026-08-06T00:00:00Z","attributes":{"gen_ai.usage.input_tokens":1,"gen_ai.usage.output_tokens":1}}' -Encoding ASCII

# An existing provider root containing only a schema-invalid record must not be parser-readable.
$env:GROK_HOME = Join-Path $outputDirectory 'grok-invalid'
New-Item -ItemType Directory -Path (Join-Path $env:GROK_HOME 'sessions\smoke') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $env:GROK_HOME 'sessions\smoke\invalid.jsonl') -Value '{}' -Encoding ASCII

$env:AIDER_ANALYTICS_LOG = Join-Path $outputDirectory 'aider\analytics.jsonl'
New-Item -ItemType Directory -Path (Split-Path $env:AIDER_ANALYTICS_LOG -Parent) -Force | Out-Null
Set-Content -LiteralPath $env:AIDER_ANALYTICS_LOG -Value '{"event":"message_send","properties":{"prompt_tokens":1,"completion_tokens":1}}' -Encoding ASCII

$env:ANTIGRAVITY_HOME = Join-Path $outputDirectory 'antigravity'
$antigravityConversations = Join-Path $env:ANTIGRAVITY_HOME 'conversations'
New-Item -ItemType Directory -Path $antigravityConversations -Force | Out-Null
$antigravityDb = Join-Path $antigravityConversations 'smoke.db'

$env:CLINE_HOME = Join-Path $outputDirectory 'cline'
$clineTask = Join-Path $env:CLINE_HOME 'tasks\smoke'
New-Item -ItemType Directory -Path $clineTask -Force | Out-Null
Set-Content -LiteralPath (Join-Path $clineTask 'api_conversation.json') -Value '[{"message":{"usage":{"input_tokens":1,"output_tokens":1}}}]' -Encoding ASCII

$env:CONTINUE_HOME = Join-Path $outputDirectory 'continue'
New-Item -ItemType Directory -Path (Join-Path $env:CONTINUE_HOME 'dev_data') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $env:CONTINUE_HOME 'dev_data\smoke.jsonl') -Value '{"prompt_tokens":1,"completion_tokens":1}' -Encoding ASCII

$env:CURSOR_AGENT_HOME = Join-Path $outputDirectory 'cursor-global-storage'
New-Item -ItemType Directory -Path $env:CURSOR_AGENT_HOME -Force | Out-Null
$cursorDb = Join-Path $env:CURSOR_AGENT_HOME 'state.vscdb'

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { throw 'Python with sqlite3 is required for the isolated SQLite catalog fixtures.' }
$pythonScript = Join-Path $outputDirectory 'create-catalog-fixtures.py'
Set-Content -LiteralPath $pythonScript -Encoding ASCII -Value @'
import os, sqlite3, sys

def create(path, schema, insert=None):
    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    try:
        db.execute(schema)
        if insert:
            db.execute(*insert)
        db.commit()
    finally:
        db.close()

create(sys.argv[1], "CREATE TABLE sessions(started_at REAL, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER, message_count INTEGER)")
create(sys.argv[2], "CREATE TABLE session(tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, time_created INTEGER)")
create(sys.argv[3], "CREATE TABLE steps(step_payload BLOB, metadata BLOB)")
create(sys.argv[4], "CREATE TABLE ItemTable(key TEXT, value TEXT)", ("INSERT INTO ItemTable(key, value) VALUES (?, ?)", ("cursorAuth/accessToken", "smoke-token")))
'@
& $python.Source $pythonScript $hermesDb $openCodeDb $antigravityDb $cursorDb
if ($LASTEXITCODE -ne 0) { throw "SQLite fixture creation failed with exit code $LASTEXITCODE." }

function Invoke-CatalogReport([string] $Path) {
    $process = Start-Process -FilePath $Exe -ArgumentList @('--catalog-report', $Path) -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Catalog reporter exited with $($process.ExitCode)." }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Catalog reporter did not create $Path" }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$report = Invoke-CatalogReport $Out
if ($report.platform -ne 'windows') { throw 'Catalog report has the wrong platform.' }
if (@($report.providers).Count -ne 14) { throw "Expected 14 providers, got $(@($report.providers).Count)." }
$ids = @($report.providers | ForEach-Object id)
if (@($ids | Sort-Object -Unique).Count -ne 14) { throw 'Provider IDs are not unique.' }
foreach ($provider in $report.providers) {
    if ([string]::IsNullOrWhiteSpace($provider.defaultPath)) { throw "$($provider.id) has no declared default path." }
    if ($null -eq $provider.pathExists) { throw "$($provider.id) omitted pathExists." }
    if ($null -eq $provider.parserReadable) { throw "$($provider.id) omitted parserReadable." }
    if ($provider.parserReadable -and -not $provider.pathExists) { throw "$($provider.id) is readable but its path does not exist." }
    foreach ($override in $provider.environmentOverrides) {
        if ($override.status -notin @('official', 'tokenClockCompatibility')) {
            throw "$($provider.id) has an unclassified environment override: $($override.name)"
        }
    }
}

$validProviderIds = @('openclaw', 'claudeCode', 'gemini', 'codex', 'hermes', 'opencode', 'qwen', 'copilot', 'aider', 'antigravity', 'cline', 'continue', 'cursorAgent')
foreach ($id in $validProviderIds) {
    $provider = $report.providers | Where-Object id -eq $id | Select-Object -First 1
    if (-not $provider.pathExists -or -not $provider.parserReadable) {
        throw "$id fixture was not recognized as parser-readable."
    }
}
$grok = $report.providers | Where-Object id -eq 'grok' | Select-Object -First 1
if ($grok.selectedPath -ne $env:GROK_HOME -or -not $grok.pathExists -or $grok.parserReadable) {
    throw 'Schema-invalid Grok fixture must report pathExists=true and parserReadable=false.'
}

$openClaw = $report.providers | Where-Object id -eq 'openclaw' | Select-Object -First 1
$openClawNames = @($openClaw.environmentOverrides | ForEach-Object name)
if ('OPENCLAW_STATE_DIR' -notin $openClawNames -or 'OPENCLAW_HOME' -notin $openClawNames) {
    throw 'OpenClaw catalog must declare both OPENCLAW_STATE_DIR and OPENCLAW_HOME.'
}
if ($openClaw.selectedPath -ne $env:OPENCLAW_STATE_DIR -or -not $openClaw.parserReadable) {
    throw 'OPENCLAW_STATE_DIR must be used as the direct, highest-priority state directory.'
}

$openCode = $report.providers | Where-Object id -eq 'opencode' | Select-Object -First 1
$expectedOpenCodeDefault = Join-Path $isolatedUser '.local\share\opencode'
if ($openCode.defaultPath -ne $expectedOpenCodeDefault) { throw 'OpenCode Windows default must match the upstream .local\share\opencode location.' }
$openCodeDbContract = $openCode.environmentOverrides | Where-Object name -eq 'OPENCODE_DB' | Select-Object -First 1
if ($openCodeDbContract.status -ne 'official' -or $openCode.selectedPath -ne $env:OPENCODE_DB) {
    throw 'OPENCODE_DB must be official and selected as a direct database path.'
}
$hermes = $report.providers | Where-Object id -eq 'hermes' | Select-Object -First 1
$expectedHermesDefault = Join-Path $env:LOCALAPPDATA 'hermes'
$hermesContract = $hermes.environmentOverrides | Where-Object name -eq 'HERMES_HOME' | Select-Object -First 1
if ($hermes.defaultPath -ne $expectedHermesDefault -or $hermesContract.status -ne 'official') {
    throw 'Hermes must use the official LocalAppData default and official HERMES_HOME override.'
}
$copilot = $report.providers | Where-Object id -eq 'copilot' | Select-Object -First 1
$copilotContract = $copilot.environmentOverrides | Where-Object name -eq 'COPILOT_OTEL_FILE_EXPORTER_PATH' | Select-Object -First 1
if ($copilotContract.status -ne 'official' -or $copilot.selectedPath -ne $env:COPILOT_OTEL_FILE_EXPORTER_PATH) {
    throw 'COPILOT_OTEL_FILE_EXPORTER_PATH must be official and selected as a direct JSONL path.'
}
$copilotHomeContract = $copilot.environmentOverrides | Where-Object name -eq 'COPILOT_HOME' | Select-Object -First 1
if ($copilotHomeContract.status -ne 'official') { throw 'COPILOT_HOME must be marked as an official override.' }

$homeState = Join-Path $env:OPENCLAW_HOME '.openclaw\agents\smoke\sessions'
New-Item -ItemType Directory -Path $homeState -Force | Out-Null
Set-Content -LiteralPath (Join-Path $homeState 'smoke.jsonl') -Value $validLine -Encoding ASCII
Remove-Item Env:OPENCLAW_STATE_DIR
$homeReportPath = Join-Path $outputDirectory 'catalog-openclaw-home.json'
$homeReport = Invoke-CatalogReport $homeReportPath
$homeOpenClaw = $homeReport.providers | Where-Object id -eq 'openclaw' | Select-Object -First 1
$expectedHomeState = Join-Path $env:OPENCLAW_HOME '.openclaw'
if ($homeOpenClaw.selectedPath -ne $expectedHomeState -or -not $homeOpenClaw.parserReadable) {
    throw 'OPENCLAW_HOME must be treated as a home parent and resolve to its .openclaw child.'
}

$compatibilityNames = @($report.providers.environmentOverrides | Where-Object status -eq 'tokenClockCompatibility' | ForEach-Object name)
foreach ($required in @('GROK_HOME', 'CLINE_HOME', 'CONTINUE_HOME', 'ANTIGRAVITY_HOME', 'OPENCODE_HOME')) {
    if ($required -notin $compatibilityNames) { throw "$required must be marked TokenClock compatibility." }
}

$expansion = $report.pathExpansion
if ($expansion.'$TC_EXPAND_SHORT\child' -ne 'short-value\child') { throw 'Short token expansion failed.' }
if ($expansion.'$TC_EXPAND_LONG\child' -ne 'long-value\child') { throw 'Long token expansion failed.' }
if ($expansion.'$TC_EXPAND_LONGER\child' -ne 'longer-value\child') { throw 'Overlapping token expansion was corrupted.' }

[ordered]@{
    passed = $true
    providerCount = @($report.providers).Count
    declared = @($report.providers | Where-Object { -not [string]::IsNullOrWhiteSpace($_.defaultPath) }).Count
    pathsExisting = @($report.providers | Where-Object pathExists).Count
    parsersReadable = @($report.providers | Where-Object parserReadable).Count
    validFixturesRecognized = $validProviderIds.Count
    invalidExistingFixtureRejected = $true
    officialOverrides = @($report.providers.environmentOverrides | Where-Object status -eq 'official').Count
    compatibilityOverrides = $compatibilityNames.Count
    openClawStateDirContract = $true
    openClawHomeParentContract = $true
    openCodeDirectDatabaseContract = $true
    copilotDirectOtelContract = $true
    report = $Out
} | ConvertTo-Json
