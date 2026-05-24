param(
    [string]$BASE = "http://localhost:3000",
    [int]   $JobWaitSec = 20
)
$pass = 0; $fail = 0; $warn = 0
function Write-Result {
    param($label, $status, $detail = "")
    $color = switch ($status) {
        "PASS" { "Green" }
        "FAIL" { "Red" }
        "WARN" { "Yellow" }
        default { "White" }
    }
    if ($detail) { Write-Host "[$status] $label -- $detail" -ForegroundColor $color }
    else         { Write-Host "[$status] $label" -ForegroundColor $color }
    if ($status -eq "PASS") { $script:pass++ }
    elseif ($status -eq "FAIL") { $script:fail++ }
    else { $script:warn++ }
}
function Invoke-Api {
    param($method, $path, $body = $null)
    try {
        $headers = @{ "Content-Type" = "application/json"; "X-API-Key" = $env:TESTDASHBOARD_API_KEY }
        if ($body) { $r = Invoke-WebRequest -Uri "$BASE$path" -Method $method -Body $body -Headers $headers -UseBasicParsing -ErrorAction Stop }
        else       { $r = Invoke-WebRequest -Uri "$BASE$path" -Method $method -Headers $headers -UseBasicParsing -ErrorAction Stop }
        $json = $null; try { $json = $r.Content | ConvertFrom-Json } catch {}
        return @{ ok = $true; status = $r.StatusCode; json = $json; content = $r.Content }
    } catch {
        $code = 0; try { $code = $_.Exception.Response.StatusCode.value__ } catch {}
        return @{ ok = $false; status = $code; json = $null; error = $_.ToString() }
    }
}
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " OccupancyCounter Smoke Test" -ForegroundColor Cyan
Write-Host " Target: $BASE" -ForegroundColor Cyan
Write-Host "============================================"
Write-Host ""
# --- Prereq: Server Health ---
Write-Host "--- [Prereq] Server Health ---"
$r = Invoke-Api GET "/healthz"
if ($r.ok -and $r.json -and $r.json.ok) {
    Write-Result "TC-INF-04 healthz" "PASS" "ts=$($r.json.ts)"
} else {
    Write-Result "TC-INF-04 healthz" "FAIL" "Server not running"
    Write-Host "Aborting." -ForegroundColor Red; exit 1
}
# --- W1: Headcount ---
Write-Host ""; Write-Host "--- [W1] Headcount ---"
$r = Invoke-Api DELETE "/api/state"
if ($r.ok) { Write-Result "TC-W1-04 state reset" "PASS" } else { Write-Result "TC-W1-04 state reset" "FAIL" $r.error }
$devices = @(
    [pscustomobject]@{ id="AA:11:11:11:11:11"; hc=8; conf="confirmed"; room="large"  }
    [pscustomobject]@{ id="3F:A8:91:0C:7B:E2"; hc=5; conf="confirmed"; room="medium" }
    [pscustomobject]@{ id="CC:33:33:33:33:33"; hc=2; conf="confirmed"; room="small"  }
    [pscustomobject]@{ id="DD:44:44:44:44:44"; hc=1; conf="tentative"; room="booth"  }
)
foreach ($d in $devices) {
    $body = '{"device_id":"' + $d.id + '","headcount":' + $d.hc + ',"confidence":"' + $d.conf + '"}'
    $r = Invoke-Api POST "/ingest/headcount" $body
    if ($r.ok -and $r.json -and $r.json.ok -and $r.json.room -eq $d.room) {
        Write-Result "TC-W1-01 headcount/$($d.room)" "PASS" "headcount=$($r.json.headcount)"
    } else {
        Write-Result "TC-W1-01 headcount/$($d.room)" "FAIL" "HTTP $($r.status)"
    }
}
$r = Invoke-Api POST "/ingest/headcount" '{"device_id":"ZZ:ZZ:ZZ:ZZ:ZZ:ZZ","headcount":3}'
if ($r.json -and $r.json.ok -eq $false) { Write-Result "TC-W1-02 unknown device" "PASS" }
else { Write-Result "TC-W1-02 unknown device" "FAIL" }
$r = Invoke-Api POST "/ingest/headcount" '{"device_id":"AA:11:11:11:11:11"}'
if ($r.status -eq 400) { Write-Result "TC-W1-03 validation 400" "PASS" }
else { Write-Result "TC-W1-03 validation 400" "FAIL" "HTTP $($r.status)" }
$r = Invoke-Api GET "/api/state"
if ($r.ok -and $r.json -and $r.json.rooms) {
    $large = $r.json.rooms | Where-Object { $_.id -eq "large" } | Select-Object -First 1
    if ($large -and $large.headcount -eq 8) { Write-Result "TC-W1 state verify" "PASS" "large.headcount=8" }
    else { Write-Result "TC-W1 state verify" "FAIL" "headcount=$($large.headcount)" }
} else { Write-Result "TC-W1 api/state" "FAIL" $r.error }
# --- W2: Recording Upload ---
Write-Host ""; Write-Host "--- [W2] Recording Upload ---"
$tmpAudio = [System.IO.Path]::Combine($env:TEMP, "smoke-test.wav")
# Generate a minimal valid WAV file: 16kHz, mono, 16-bit PCM, 2 seconds of silence
$sampleRate = 16000; $channels = 1; $bitsPerSample = 16
$numSamples = $sampleRate * 2  # 2 seconds
$dataSize = $numSamples * $channels * ($bitsPerSample / 8)
$fileSize = 36 + $dataSize
$wavHeader = [byte[]]@(
    0x52,0x49,0x46,0x46,  # "RIFF"
    [byte]($fileSize -band 0xFF), [byte](($fileSize -shr 8) -band 0xFF), [byte](($fileSize -shr 16) -band 0xFF), [byte](($fileSize -shr 24) -band 0xFF),
    0x57,0x41,0x56,0x45,  # "WAVE"
    0x66,0x6D,0x74,0x20,  # "fmt "
    0x10,0x00,0x00,0x00,  # chunk size = 16
    0x01,0x00,            # PCM format
    [byte]$channels, 0x00,
    [byte]($sampleRate -band 0xFF), [byte](($sampleRate -shr 8) -band 0xFF), 0x00, 0x00,
    [byte](($sampleRate * $channels * $bitsPerSample/8) -band 0xFF), [byte]((($sampleRate * $channels * $bitsPerSample/8) -shr 8) -band 0xFF), 0x00, 0x00,
    [byte]($channels * $bitsPerSample/8), 0x00,
    [byte]$bitsPerSample, 0x00,
    0x64,0x61,0x74,0x61,  # "data"
    [byte]($dataSize -band 0xFF), [byte](($dataSize -shr 8) -band 0xFF), [byte](($dataSize -shr 16) -band 0xFF), [byte](($dataSize -shr 24) -band 0xFF)
)
$pcmData = [byte[]]::new($dataSize)  # silence
$wavBytes = $wavHeader + $pcmData
[System.IO.File]::WriteAllBytes($tmpAudio, $wavBytes)
$stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$jobId   = "smoke-$stamp"
$startAt = (Get-Date).AddMinutes(-30).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
$endAt   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
$metaObj = [PSCustomObject]@{ job_id=$jobId; device_id="3F:A8:91:0C:7B:E2"; room_id="medium"; title="Smoke Test MTG"; started_at=$startAt; ended_at=$endAt; language="ja-JP" }
$metaJson = $metaObj | ConvertTo-Json -Compress
$metaFile = [System.IO.Path]::Combine($env:TEMP, "smoke-meta.json")
[System.IO.File]::WriteAllText($metaFile, $metaJson, (New-Object System.Text.UTF8Encoding $false))
$curlOut = & curl.exe -s -X POST "$BASE/ingest/recording" -H "X-API-Key: $env:TESTDASHBOARD_API_KEY" -F "meta=<$metaFile" -F "audio=@${tmpAudio};type=audio/wav" 2>&1
$uploadOk = $false
try {
    $parsed = $curlOut | ConvertFrom-Json
    if ($parsed.ok -eq $true -and $parsed.job_id) {
        Write-Result "TC-W2-01 recording upload" "PASS" "job_id=$($parsed.job_id)"
        $jobId = $parsed.job_id; $uploadOk = $true
    } else { Write-Result "TC-W2-01 recording upload" "FAIL" $curlOut }
} catch { Write-Result "TC-W2-01 recording upload" "FAIL" $curlOut }
if ($uploadOk) {
    Write-Host "  Waiting for job (up to ${JobWaitSec}s)..." -ForegroundColor DarkCyan
    $completed = $false
    for ($i = 0; $i -lt $JobWaitSec; $i++) {
        Start-Sleep 1
        $r = Invoke-Api GET "/api/jobs/$jobId"
        if ($r.ok -and $r.json -and $r.json.status -in @("completed","failed")) { $completed = $true; break }
    }
    if ($completed) {
        $r = Invoke-Api GET "/api/jobs/$jobId"
        $j = $r.json
        if ($j.status -eq "completed") { Write-Result "TC-W2-02 job completed" "PASS" "speakers=$($j.transcript.speakerCount)" }
        else { Write-Result "TC-W2-02 job completed" "FAIL" "status=$($j.status) err=$($j.error)" }
    } else { Write-Result "TC-W2-02 job completed" "WARN" "Timeout after ${JobWaitSec}s" }
    $tf = Get-ChildItem "C:\PRJ2\dev2\TestDashboard\storage\transcripts" -Filter "*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($tf) { Write-Result "TC-W2-03 transcript saved" "PASS" $tf.Name }
    else { Write-Result "TC-W2-03 transcript saved" "FAIL" "No files" }
} else {
    Write-Result "TC-W2-02 job completed" "WARN" "Skipped"
    Write-Result "TC-W2-03 transcript saved" "WARN" "Skipped"
}
$r = Invoke-Api GET "/api/jobs"
if ($r.ok -and $r.json) { Write-Result "TC-W2-04 api/jobs list" "PASS" "count=$($r.json.count)" }
else { Write-Result "TC-W2-04 api/jobs list" "FAIL" $r.error }
# --- W3: Minutes ---
Write-Host ""; Write-Host "--- [W3] Minutes ---"
$r = Invoke-Api GET "/api/jobs/$jobId"
if ($r.json -and $r.json.minutes) {
    Write-Result "TC-W3-01 minutes object" "PASS"
    $mdR = Invoke-Api GET "/api/minutes/$jobId/markdown"
    if ($mdR.ok -and $mdR.content.Length -gt 50) { Write-Result "TC-W3-03 markdown endpoint" "PASS" "chars=$($mdR.content.Length)" }
    else { Write-Result "TC-W3-03 markdown endpoint" "FAIL" "HTTP $($mdR.status)" }
    $docxPath = [System.IO.Path]::Combine($env:TEMP, "smoke-minutes.docx")
    try {
        Invoke-WebRequest -Uri "$BASE/api/minutes/$jobId/download" -Headers @{"X-API-Key"=$env:TESTDASHBOARD_API_KEY} -OutFile $docxPath -UseBasicParsing -ErrorAction Stop
        $sz = (Get-Item $docxPath).Length
        if ($sz -gt 1000) { Write-Result "TC-W3-02 docx download" "PASS" "size=${sz}B" }
        else { Write-Result "TC-W3-02 docx download" "FAIL" "size=$sz too small" }
    } catch { Write-Result "TC-W3-02 docx download" "FAIL" "$_" }
    $df = Get-ChildItem "C:\PRJ2\dev2\TestDashboard\storage\minutes" -Filter "*.docx" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($df) { Write-Result "TC-W3-01 docx file exists" "PASS" $df.Name }
    else { Write-Result "TC-W3-01 docx file exists" "WARN" "No docx in storage/minutes" }
} else { Write-Result "TC-W3-01 minutes" "WARN" "Not ready" }
# --- P4: Queue Consumer ---
Write-Host ""; Write-Host "--- [P4] Queue Consumer ---"
$r = Invoke-Api GET "/api/jobs"
if ($r.ok -and $r.json) { Write-Result "TC-P4 api/jobs endpoint" "PASS" "count=$($r.json.count)" }
else { Write-Result "TC-P4 api/jobs endpoint" "FAIL" $r.error }
Set-Location "C:\PRJ2\dev2\TestDashboard"
$nodeCheck = node -e "try{require('./services/graph');process.exit(0);}catch(e){process.exit(1);}" 2>&1
if ($LASTEXITCODE -eq 0) { Write-Result "TC-P4-01 graph module loads" "PASS" }
else { Write-Result "TC-P4-01 graph module loads" "FAIL" "$nodeCheck" }
$mockCheck = node -e "const qc=require('./services/queue-consumer');process.exit(qc.isMock()?0:1);" 2>&1
if ($LASTEXITCODE -eq 0) { Write-Result "TC-P4-03 queue mock mode" "PASS" "Mock=true" }
else { Write-Result "TC-P4-03 queue mock mode" "WARN" "Mock=false (queue polling active)" }
# --- Security ---
Write-Host ""; Write-Host "--- [Security] ---"
Set-Location "C:\PRJ2\dev2\TestDashboard"
$envInGit = & git ls-files .env 2>&1
if (-not $envInGit -or $envInGit -eq "") { Write-Result "TC-SEC-01 .env not in git" "PASS" }
else { Write-Result "TC-SEC-01 .env not in git" "FAIL" ".env is tracked" }
$auditOut = & npm audit --audit-level=high 2>&1 | Select-String -Pattern "found \d+ vulnerabilit" | Select-Object -Last 1
if ("$auditOut" -match "found 0 vulnerabilit") { Write-Result "TC-SEC-04 npm audit" "PASS" }
elseif ($auditOut) { Write-Result "TC-SEC-04 npm audit" "WARN" "$auditOut" }
else { Write-Result "TC-SEC-04 npm audit" "WARN" "Could not parse" }
# --- Infra ---
Write-Host ""; Write-Host "--- [Infra] ---"
if (Test-Path "C:\PRJ2\dev2\scripts\rotate-azurite-log.ps1") { Write-Result "TC-INF-01 rotate script exists" "PASS" }
else { Write-Result "TC-INF-01 rotate script exists" "FAIL" }
# --- Summary ---
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Test Results" -ForegroundColor Cyan
Write-Host "============================================"
Write-Host "  PASS: $pass" -ForegroundColor Green
Write-Host "  WARN: $warn" -ForegroundColor Yellow
$failColor = "Green"; if ($fail -gt 0) { $failColor = "Red" }
Write-Host "  FAIL: $fail" -ForegroundColor $failColor
Write-Host ""
if ($fail -eq 0) { Write-Host "All tests passed!" -ForegroundColor Green }
else { Write-Host "$fail test(s) failed." -ForegroundColor Red }
Write-Host ""