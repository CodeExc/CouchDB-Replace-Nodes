#requires -Version 7.2
<#
.SYNOPSIS
Transfers all shard assignments from one CouchDB 3.5 node to another.
.DESCRIPTION
Run with PowerShell 7.2 or later (pwsh.exe), not Windows PowerShell 5.1.
Plan is read-only. Prepare adds replicas and starts synchronization.
Status displays replication activity; zero jobs alone does NOT prove success.
Finalize requires explicit confirmation that synchronization was verified.
It removes old shard assignments, but never deletes files or cluster membership.
Backups are shard metadata only, NOT a backup of database documents.
Use a current database backup. Pause database creation/deletion and resharding
for the migration. Configure the load balancer to exclude the new node while
maintenance_mode is true. Use direct node URLs, not a load balancer URL.
Re-running Prepare is supported after partial failure. No automatic rollback.
Docs: https://docs.couchdb.org/en/stable/cluster/sharding.html#moving-a-shard
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExistingUrl,
    [Parameter(Mandatory)][string]$NewUrl,
    [Parameter(Mandatory)][string]$OldNode,
    [Parameter(Mandatory)][string]$NewNode,
    [ValidateSet('Plan','Prepare','Status','Finalize')][string]$Mode = 'Plan',
    [PSCredential]$Credential,
    [string]$BackupDirectory = (Join-Path $PWD 'couchdb-migration-backups'),
    [switch]$SynchronizationVerified
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ExistingUrl = $ExistingUrl.TrimEnd('/')
$NewUrl = $NewUrl.TrimEnd('/')
foreach ($url in @($ExistingUrl, $NewUrl)) {
    $u = [uri]$url
    if (-not $u.IsAbsoluteUri -or $u.Scheme -notin @('http','https') -or $u.UserInfo) {
        throw 'Use an absolute http(s) URL without embedded credentials.'
    }
}
if ($OldNode -ceq $NewNode) { throw 'OldNode and NewNode must differ.' }
if (-not $Credential) { $Credential = Get-Credential -UserName admin -Message 'CouchDB administrator' }
$plain = $Credential.GetNetworkCredential()
$auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($plain.UserName + ':' + $plain.Password))
$headers = @{ Authorization = "Basic $auth" }
$plain = $null
function Api([string]$Base, [string]$Path, [string]$Method = 'GET', $Body = $null) {
    $argsHttp = @{ Uri = "$Base$Path"; Method = $Method; Headers = $headers; TimeoutSec = 120 }
    if ($null -ne $Body) {
        $json = ConvertTo-Json -InputObject $Body -Depth 100 -Compress
        $argsHttp.ContentType = 'application/json; charset=utf-8'
        $argsHttp.Body = [Text.Encoding]::UTF8.GetBytes($json)
    }
    $response = Invoke-WebRequest @argsHttp
    if ($response.Content) {
        $content = $response.Content
        if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
        return ConvertFrom-Json -InputObject $content -AsHashtable -Depth 100
    }
}
function Escape([string]$Value) { return [uri]::EscapeDataString($Value) }
function Check-Map($Doc) {
    foreach ($range in $Doc.by_range.Keys) {
        $nodes = @($Doc.by_range[$range])
        if (@($nodes | Sort-Object -Unique).Count -ne $nodes.Count) { throw "Duplicate nodes: $($Doc._id)/$range" }
        foreach ($node in $nodes) {
            if (-not $Doc.by_node.Contains($node) -or $range -cnotin @($Doc.by_node[$node])) {
                throw "Inconsistent shard map: $($Doc._id)/$range/$node"
            }
        }
    }
    foreach ($node in $Doc.by_node.Keys) {
        foreach ($range in @($Doc.by_node[$node])) {
            if (-not $Doc.by_range.Contains($range) -or $node -cnotin @($Doc.by_range[$range])) {
                throw "Inconsistent reverse shard map: $($Doc._id)/$range/$node"
            }
        }
    }
}
function Read-Maps {
    $rows = Api $ExistingUrl '/_node/_local/_dbs/_all_docs?include_docs=true'
    foreach ($row in $rows.rows) {
        if ($row.id.StartsWith('_design/')) { continue }
        if (-not $row.Contains('doc')) { throw "Missing metadata document: $($row.id)" }
        $doc = $row.doc
        if ($doc.Contains('_deleted') -and $doc._deleted) { continue }
        if (-not $doc.Contains('by_node') -or -not $doc.Contains('by_range')) {
            throw "Unexpected metadata: $($row.id)"
        }
        Check-Map $doc
        Write-Output -NoEnumerate $doc
    }
}
function Jobs {
    $sys = Api $NewUrl '/_node/_local/_system'
    if (-not $sys.Contains('internal_replication_jobs')) { throw 'Replication metric missing.' }
    return $sys.internal_replication_jobs
}
try {
    foreach ($base in @($ExistingUrl, $NewUrl)) {
        $info = Api $base '/'
        if ($info.version -ne '3.5.2') { Write-Warning "$base reports CouchDB $($info.version), expected 3.5.2." }
        $membership = Api $base '/_membership'
        foreach ($name in @($OldNode, $NewNode)) {
            if ($name -cnotin @($membership.all_nodes) -or $name -cnotin @($membership.cluster_nodes)) {
                throw "$name must be registered AND connected on $base."
            }
        }
    }
    $actualNew = Api $NewUrl '/_node/_local'
    if ($actualNew.name -cne $NewNode) { throw "NewUrl points to $($actualNew.name), not $NewNode." }
    if ($Mode -eq 'Status') {
        $maintenance = Api $NewUrl '/_node/_local/_config/couchdb/maintenance_mode'
        Write-Host "New node maintenance_mode: $maintenance"
        Write-Host "New node internal_replication_jobs: $(Jobs)"
        Write-Host 'Zero jobs alone is not proof of complete replication. Check logs and shard data before Finalize.'
        return
    }
    $reshard = Api $ExistingUrl '/_reshard'
    if ([int]$reshard.running -gt 0) { throw 'Resharding jobs are running. Stop them before migration.' }
    $docs = @(Read-Maps)
    $affected = @($docs | Where-Object { $_.by_node.Contains($OldNode) })
    $affected | ForEach-Object {
        [pscustomobject]@{ Database = $_._id; OldNodeShards = @($_.by_node[$OldNode]).Count }
    } | Format-Table | Out-Host
    Write-Host "Databases checked: $($docs.Count); affected: $($affected.Count)"
    if ($Mode -eq 'Plan') { Write-Host 'Read-only plan. Use -Mode Prepare to add replicas.'; return }
    if ($affected.Count -eq 0) { Write-Host 'No shard assignments on the old node. No changes made.'; return }
    if ($Mode -eq 'Finalize') {
        if (-not $SynchronizationVerified) { throw 'Finalize requires -SynchronizationVerified after you verified replication and logs.' }
        foreach ($doc in $affected) {
            foreach ($range in @($doc.by_node[$OldNode])) {
                if ($NewNode -cnotin @($doc.by_range[$range])) { throw "Target replica missing: $($doc._id)/$range" }
            }
        }
        if ([int](Jobs) -ne 0) { throw 'Replication jobs are still active on the target. Retry later.' }
    }
    # Save every metadata document before performing any mutation.
    $runDir = Join-Path $BackupDirectory ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    ConvertTo-Json -InputObject $docs -Depth 100 | Set-Content -LiteralPath (Join-Path $runDir 'shard-metadata.json') -Encoding utf8NoBOM
    @{ExistingUrl=$ExistingUrl;NewUrl=$NewUrl;OldNode=$OldNode;NewNode=$NewNode;Mode=$Mode} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runDir 'parameters.json') -Encoding utf8NoBOM
    Write-Host "Metadata backup: $runDir (not a database data backup)"
    if ($Mode -eq 'Prepare') {
        $null = Api $NewUrl '/_node/_local/_config/couchdb/maintenance_mode' 'PUT' 'true'
    } else {
        # Target can serve requests only after the operator verified its data.
        $null = Api $NewUrl '/_node/_local/_config/couchdb/maintenance_mode' 'PUT' 'false'
        $null = Api $NewUrl '/_up'
    }
    foreach ($original in $affected) {
        $path = '/_node/_local/_dbs/' + (Escape $original._id)
        $doc = Api $ExistingUrl $path
        Check-Map $doc
        if ($doc._rev -cne $original._rev) { throw "Metadata changed during migration: $($doc._id). Re-run after investigating." }
        $ranges = @($doc.by_node[$OldNode])
        $changed = $false
        foreach ($range in $ranges) {
            if ($Mode -eq 'Prepare') {
                if ($NewNode -cnotin @($doc.by_range[$range])) {
                    if (-not $doc.by_node.Contains($NewNode)) { $doc.by_node[$NewNode] = @() }
                    $doc.by_node[$NewNode] = @($doc.by_node[$NewNode]) + @($range)
                    $doc.by_range[$range] = @($doc.by_range[$range]) + @($NewNode)
                    if (-not $doc.Contains('changelog')) { $doc.changelog = @() }
                    $doc.changelog = @($doc.changelog) + ,@('add', $range, $NewNode)
                    $changed = $true
                }
            } else {
                if ($NewNode -cnotin @($doc.by_range[$range])) { throw "New replica missing: $($doc._id)/$range" }
                $doc.by_range[$range] = @($doc.by_range[$range] | Where-Object { $_ -cne $OldNode })
                if (-not $doc.Contains('changelog')) { $doc.changelog = @() }
                $doc.changelog = @($doc.changelog) + ,@('remove', $range, $OldNode)
                $changed = $true
            }
        }
        if ($Mode -eq 'Finalize') { $doc.by_node.Remove($OldNode) }
        Check-Map $doc
        if ($changed) {
            $saved = Api $ExistingUrl $path 'PUT' $doc
            if (-not $saved.ok) { throw "Metadata update failed: $($doc._id)" }
        }
        if ($Mode -eq 'Prepare') {
            $synced = Api $ExistingUrl ('/' + (Escape $doc._id) + '/_sync_shards') 'POST'
            if (-not $synced.ok) { throw "Sync request failed: $($doc._id)" }
            Write-Host "Sync started: $($doc._id)"
        } else { Write-Host "Old assignments removed: $($doc._id)" }
    }
    if ($Mode -eq 'Prepare') {
        Write-Host 'Prepare complete. Target stays in maintenance mode. Keep the old node running.'
        Write-Host 'Use Status repeatedly; inspect replication errors and target shards before Finalize.'
    } else {
        $remaining = @(Read-Maps | Where-Object { $_.by_node.Contains($OldNode) -or
            @($_.by_range.Values | ForEach-Object { $_ } | Where-Object { $_ -ceq $OldNode }).Count -gt 0 })
        if ($remaining.Count) { throw 'Old-node assignments still exist. Do not remove the old node.' }
        Write-Host 'Finalize complete. No old-node shard assignments remain.'
        Write-Host 'Old cluster membership and data files were NOT deleted. Remove membership separately after verification.'
    }
} catch {
    Write-Error "Migration stopped: $($_.Exception.Message). Already committed changes remain; inspect the backup and re-run the same phase after fixing the cause." -ErrorAction Continue
    exit 1
} finally {
    $headers.Clear()
    $auth = $null
}