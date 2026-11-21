#!/usr/bin/env pwsh
<#
Open ■
┬────┴  Sync-OpenKnxForks
■ KNX   2026 OpenKNX - Erkan Çolak

.SYNOPSIS
    Keeps the forks of all public OpenKNX repositories in the target organization up to date.

.DESCRIPTION
    For every public, non-empty repository of the source organization:
    - forks it into the target organization if the fork is missing;
    - switches Actions off in every fork where they are on;
    - creates branches and tags that exist upstream but not in the fork;
    - moves a fork branch to the upstream commit when that is a fast-forward; when upstream was rewritten
      (branch) or moved (tag), the old fork commit is kept as upstream-rewritten/<name>/<date>-<sha>
      before the ref is moved;
    - copies releases (name, text, assets) whose tag has no release in the fork yet, and assets that are
      missing in an existing fork release.
    Refs that exist only in the fork are never changed; upstream refs named local/*, wiki-mirror or
    upstream-rewritten/* are skipped. Nothing is deleted. Release texts and assets that change upstream after
    the copy are not updated. At most MaxWrites changes are made per run (GitHub allows about 500
    content-creating requests per hour); the rest follows in the next run.
    Needs the GitHub CLI (gh) logged in or GH_TOKEN set. All changes go through the API, nothing is cloned.

.PARAMETER Source
    Organization to fork from (default OpenKNX).

.PARAMETER Target
    Organization that holds the forks (default openknx-ec).

.PARAMETER Only
    Process only the repository with this name.

.PARAMETER SkipReleases
    Do not copy releases.

.PARAMETER MaxWrites
    Maximum number of changes per run (default 400).

.PARAMETER DryRun
    Report what would change, change nothing.

.PARAMETER Help
    Show usage information and exit.

.EXAMPLE
    ./Sync-OpenKnxForks.ps1 -DryRun
    ./Sync-OpenKnxForks.ps1 -Only OFM-Network -SkipReleases

.LINK
    https://cli.github.com/manual/gh_api
#>
param(
    [string]$Source = 'OpenKNX',
    [string]$Target = 'openknx-ec',
    [string]$Only = '',
    [switch]$SkipReleases,
    [int]$MaxWrites = 400,
    [switch]$DryRun,
    [Alias('h')][switch]$Help
)

if ($Help) { Get-Help $PSCommandPath -Detailed; exit 0 }
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { Write-Warning "console encoding not set: $($_.Exception.Message)" }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$script:Report = New-Object System.Collections.Generic.List[string]
$script:Errors = 0
$script:Writes = 0
$script:Capped = $false
$Today = (Get-Date).ToUniversalTime().ToString('yyyyMMdd')
$Reserved = '^(local/|upstream-rewritten/|wiki-mirror$)'

function Write-Note([string]$Text) {
    Write-Host $Text
    $script:Report.Add($Text)
}

function New-Map {
    <# @brief Returns an empty case-sensitive hashtable (git ref and asset names are case-sensitive). #>
    return ,(New-Object System.Collections.Hashtable ([StringComparer]::Ordinal))
}

function Invoke-Gh {
    <# @brief Runs gh with the given arguments; returns @{ Ok; Out } with stdout and stderr joined as text. #>
    param([string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $out = (& gh @Arguments 2>&1 | ForEach-Object { "$_" }) -join "`n"
    return @{ Ok = ($LASTEXITCODE -eq 0); Out = $out.Trim() }
}

function ConvertTo-RefPath([string]$Ref) {
    <# @brief URL-encodes every segment of a ref name for use in an API path. #>
    return (($Ref -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
}

function Get-GhList {
    <# @brief Returns all items of a paginated list endpoint as objects. #>
    param([string]$Path)
    $r = Invoke-Gh @('api', '--paginate', $Path, '--jq', '.[] | @json')
    if (-not $r.Ok) { throw "gh api $Path failed: $($r.Out)" }
    $items = @()
    foreach ($line in ($r.Out -split "`n")) {
        if ($line.Trim()) { $items += ($line | ConvertFrom-Json) }
    }
    return ,$items
}

function Get-RefMap {
    <# @brief Returns name -> object sha for refs/heads or refs/tags of a repository (empty map when none). #>
    param([string]$Repo, [string]$Kind)
    $map = New-Map
    $r = Invoke-Gh @('api', '--paginate', "repos/$Repo/git/matching-refs/$Kind/", '--jq', '.[] | [.ref, .object.sha] | @tsv')
    if (-not $r.Ok) { throw "refs of $Repo failed: $($r.Out)" }
    foreach ($line in ($r.Out -split "`n")) {
        $p = $line.Trim() -split "`t"
        if ($p.Count -eq 2) { $map[$p[0].Substring("refs/$Kind/".Length)] = $p[1] }
    }
    return ,$map
}

function Test-WriteBudget {
    <# @brief Returns $false once MaxWrites changes were made in this run; notes that once. #>
    if ($DryRun -or (-not $script:Capped -and $script:Writes -lt $MaxWrites)) { return $true }
    if (-not $script:Capped) { Write-Note "  write limit of $MaxWrites reached, the rest follows in the next run" }
    $script:Capped = $true
    return $false
}

function Invoke-Write {
    <# @brief Runs a changing gh call; waits and retries on a GitHub rate limit; returns @{ Ok; Out }. #>
    param([string[]]$Arguments)
    for ($try = 1; ; $try++) {
        $script:Writes++
        $r = Invoke-Gh $Arguments
        Start-Sleep -Milliseconds 1000
        $limited = $r.Out -match 'rate limit|HTTP 429|abuse'
        if ($r.Ok -or -not $limited) { return $r }
        if ($try -ge 10) {
            Write-Note "  still rate limited after $try tries, no further changes in this run"
            $script:Capped = $true
            return $r
        }
        Write-Host "  rate limit, waiting 300 s ($try)"
        Start-Sleep -Seconds 300
    }
}

function Invoke-Change {
    <#
    @brief Runs a changing gh call unless -DryRun or the write limit is reached; logs and counts a failure.
    #>
    param([string]$What, [string[]]$Arguments)
    if ($DryRun) { Write-Note "  would $What"; return $true }
    if (-not (Test-WriteBudget)) { return $false }
    $r = Invoke-Write $Arguments
    if ($r.Ok) { Write-Note "  $What"; return $true }
    Write-Note "  FAILED $What : $($r.Out -replace "`r?`n", ' ')"
    $script:Errors++
    return $false
}

function Sync-Refs {
    <# @brief Creates missing branches/tags, fast-forwards branches; keeps the old commit of a rewritten ref. #>
    param([string]$SrcRepo, [string]$DstRepo)
    foreach ($kind in @('heads', 'tags')) {
        $up = Get-RefMap $SrcRepo $kind
        $mine = Get-RefMap $DstRepo $kind
        foreach ($ref in ($up.Keys | Sort-Object)) {
            $sha = $up[$ref]
            if ($ref -cmatch $Reserved) { Write-Note "  skipped upstream $kind/$ref (name reserved for the fork)"; continue }
            if (-not $mine.ContainsKey($ref)) {
                [void](Invoke-Change "create $kind/$ref" @('api', '-X', 'POST', "repos/$DstRepo/git/refs", '-f', "ref=refs/$kind/$ref", '-f', "sha=$sha"))
                continue
            }
            if ($mine[$ref] -ceq $sha) { continue }
            $path = "repos/$DstRepo/git/refs/$kind/$(ConvertTo-RefPath $ref)"
            if ($kind -eq 'heads') {
                if ($DryRun) { Write-Note "  would update heads/$ref (fast-forward, or keep old and move)"; continue }
                if (-not (Test-WriteBudget)) { continue }
                $r = Invoke-Write @('api', '-X', 'PATCH', $path, '-f', "sha=$sha", '-F', 'force=false')
                if ($r.Ok) { Write-Note "  update heads/$ref"; continue }
                if ($r.Out -notmatch 'not a fast forward') {
                    Write-Note "  FAILED update heads/$ref : $($r.Out -replace "`r?`n", ' ')"; $script:Errors++; continue
                }
            }
            $old = $mine[$ref]
            $old12 = $old.Substring(0, 12)
            $kept = $mine.Keys | Where-Object { $_ -cmatch ('^upstream-rewritten/' + [regex]::Escape($ref) + '/\d{8}-' + $old12 + '$') -and $mine[$_] -ceq $old }
            if ($kept) {
                Write-Note "  old $kind/$ref already kept as $kind/$(@($kept)[0])"
                $ok = $true
            } else {
                $keep = "upstream-rewritten/$ref/$Today-$old12"
                $ok = Invoke-Change "keep old $kind/$ref as $kind/$keep" @('api', '-X', 'POST', "repos/$DstRepo/git/refs", '-f', "ref=refs/$kind/$keep", '-f', "sha=$old")
            }
            if ($ok) {
                [void](Invoke-Change "move rewritten $kind/$ref" @('api', '-X', 'PATCH', $path, '-f', "sha=$sha", '-F', 'force=true'))
            }
        }
    }
}

function Sync-Releases {
    <# @brief Copies releases whose tag has no release in the fork yet, and assets missing in a fork release. #>
    param([string]$SrcRepo, [string]$DstRepo)
    $up = Get-GhList "repos/$SrcRepo/releases?per_page=100"
    if ($up.Count -eq 0) { return }
    $mine = New-Map
    foreach ($r in (Get-GhList "repos/$DstRepo/releases?per_page=100")) { $mine[$r.tag_name] = $r }
    $tags = Get-RefMap $DstRepo 'tags'
    $latest = Invoke-Gh @('api', "repos/$SrcRepo/releases/latest", '--jq', '.tag_name')
    if ($latest.Ok) { $latestTag = $latest.Out }
    elseif ($latest.Out -match 'HTTP 404') { $latestTag = '' }
    else { throw "latest release of $SrcRepo failed: $($latest.Out)" }
    [array]::Reverse($up)
    foreach ($rel in $up) {
        $tag = $rel.tag_name
        $have = New-Map
        if ($mine.ContainsKey($tag)) {
            foreach ($a in $mine[$tag].assets) {
                $have[$a.name] = $true
                if ($a.state -ne 'uploaded') { Write-Note "  FAILED asset $tag/$($a.name) : incomplete in the fork (state $($a.state)), delete it there"; $script:Errors++ }
            }
        } else {
            if (-not $DryRun -and -not $tags.ContainsKey($tag)) {
                Write-Note "  FAILED release $tag : tag missing in the fork"; $script:Errors++; continue
            }
            if ($DryRun) { Write-Note "  would release $tag ($(@($rel.assets).Count) assets)"; continue }
            $json = Join-Path ([System.IO.Path]::GetTempPath()) "release-$([guid]::NewGuid()).json"
            $title = if ($rel.name) { $rel.name } else { $tag }
            $body = if ($rel.body) { $rel.body } else { '' }
            $data = [ordered]@{
                tag_name = $tag; name = $title; body = $body; prerelease = [bool]$rel.prerelease; draft = $false
                make_latest = $(if ($tag -ceq $latestTag) { 'true' } else { 'false' })
            }
            [System.IO.File]::WriteAllText($json, ($data | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
            try {
                $ok = Invoke-Change "release $tag" @('api', '-X', 'POST', "repos/$DstRepo/releases", '--input', $json)
            } finally {
                Remove-Item -LiteralPath $json -Force -ErrorAction SilentlyContinue
            }
            if (-not $ok) { continue }
        }
        foreach ($a in $rel.assets) {
            if ($have.ContainsKey($a.name)) { continue }
            if ($DryRun) { Write-Note "  would copy asset $tag/$($a.name)"; continue }
            if (-not (Test-WriteBudget)) { return }
            if ($a.name.Contains('#')) { Write-Note "  FAILED asset $tag/$($a.name) : '#' in the name"; $script:Errors++; continue }
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tmp | Out-Null
            try {
                $file = Join-Path $tmp $a.name
                try {
                    Invoke-WebRequest -Uri $a.browser_download_url -OutFile $file -UseBasicParsing
                } catch {
                    Write-Note "  FAILED download $tag/$($a.name) : $($_.Exception.Message)"; $script:Errors++; continue
                }
                if ((Get-Item -LiteralPath $file).Length -ne $a.size) {
                    Write-Note "  FAILED download $tag/$($a.name) : size differs"; $script:Errors++; continue
                }
                $arg = if ($a.label) { "$file#$($a.label)" } else { $file }
                [void](Invoke-Change "asset $tag/$($a.name)" @('release', 'upload', $tag, $arg, '-R', $DstRepo))
            } finally {
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Disable-ForkActions {
    <# @brief Switches Actions off in a fork when they are on. #>
    param([string]$DstRepo)
    $s = Invoke-Gh @('api', "repos/$DstRepo/actions/permissions", '--jq', '.enabled')
    if (-not $s.Ok) { Write-Note "  FAILED actions state : $($s.Out -replace "`r?`n", ' ')"; $script:Errors++; return }
    if ($s.Out -eq 'false') { return }
    [void](Invoke-Change "actions off" @('api', '-X', 'PUT', "repos/$DstRepo/actions/permissions", '-F', 'enabled=false'))
}

# ---- main -------------------------------------------------------------------------------------------
$who = Invoke-Gh @('api', "orgs/$Target", '--jq', '.login')
if (-not $who.Ok) { Write-Error "No access to organization $Target : $($who.Out)"; exit 1 }

$repos = Get-GhList "orgs/$Source/repos?type=public&per_page=100"
$forks = @{}
foreach ($r in (Get-GhList "orgs/$Target/repos?per_page=100")) { $forks[$r.name] = $r }
Write-Note "$($repos.Count) public repositories in $Source, $($forks.Count) repositories in $Target"

foreach ($repo in ($repos | Sort-Object name)) {
    $name = $repo.name
    $dstName = $name
    if ($Only -and $name -ne $Only) { continue }
    if ($repo.size -eq 0 -and -not $forks.ContainsKey($name)) {
        $probe = Invoke-Gh @('api', "repos/$Source/$name/commits?per_page=1")
        if (-not $probe.Ok) {
            if ($probe.Out -match 'is empty') { Write-Note "$name : empty, skipped" }
            else { Write-Note "$name : FAILED probe : $($probe.Out -replace "`r?`n", ' ')"; $script:Errors++ }
            continue
        }
    }
    if (-not $forks.ContainsKey($name)) {
        Write-Note "$name : new"
        if ($DryRun) { Write-Note "  would fork $name"; continue }
        if (-not (Test-WriteBudget)) { continue }
        $f = Invoke-Write @('api', '-X', 'POST', "repos/$Source/$name/forks", '-f', "organization=$Target", '-F', 'default_branch_only=false', '--jq', '.name')
        if (-not $f.Ok -or -not $f.Out) { Write-Note "  FAILED fork $name : $($f.Out -replace "`r?`n", ' ')"; $script:Errors++; continue }
        $dstName = $f.Out
        if ($forks.ContainsKey($dstName)) {
            Write-Note "  already forked as $dstName (renamed upstream)"
        } else {
            Write-Note "  fork $name"
            for ($i = 0; $i -lt 60; $i++) {
                $h = Invoke-Gh @('api', "repos/$Target/$dstName/git/matching-refs/heads/", '--jq', 'length')
                if ($h.Ok -and $h.Out -match '^\d+$' -and [int]$h.Out -gt 0) { break }
                Start-Sleep -Seconds 5
            }
        }
    } elseif (-not $forks[$name].fork) {
        Write-Note "$name : exists in $Target but is not a fork, skipped"; continue
    }
    try {
        $before = $script:Report.Count
        Write-Host "== $name"
        $script:Report.Add("$name :")
        Disable-ForkActions "$Target/$dstName"
        Sync-Refs "$Source/$name" "$Target/$dstName"
        if (-not $SkipReleases) { Sync-Releases "$Source/$name" "$Target/$dstName" }
        if ($script:Report.Count -eq $before + 1) { $script:Report.RemoveAt($before) }
    } catch {
        Write-Note "  FAILED $name : $($_.Exception.Message)"
        $script:Errors++
    }
}

Write-Note "done, write calls: $($script:Writes), errors: $($script:Errors)"
if ($env:GITHUB_STEP_SUMMARY) {
    $lines = @('```') + $script:Report + @('```')
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($lines -join "`n")
}
if ($script:Errors) { exit 1 }
exit 0
