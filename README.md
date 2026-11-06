# CouchDB Replace Nodes

PowerShell-Skript zum Ersetzen eines CouchDB-Cluster-Nodes über alle betroffenen Datenbanken. Zielversion: **CouchDB 3.5.2**.

Der neue Node übernimmt zusätzliche Replikate aller Shards des alten Nodes. Nach überprüfter Synchronisierung werden die alten Zuordnungen separat entfernt. Systemdatenbanken werden ebenfalls berücksichtigt.

## Voraussetzungen

- **Windows PowerShell 5.1** (`powershell.exe`) für `Replace-CouchDbNode-PS51.ps1`, oder **PowerShell 7.2+** (`pwsh.exe`) für `Replace-CouchDbNode.ps1`.
- Administrator-Zugang auf beiden HTTP-Endpunkten mit denselben Zugangsdaten.
- Neuer Node ist bereits dem Cluster beigetreten. Alter und neuer Node müssen auf beiden Endpunkten in `all_nodes` und `cluster_nodes` stehen.
- Direkte Node-Adressen verwenden, keine Loadbalancer-Adresse.
- Aktuelles Datenbackup und genügend Platz für die zusätzlichen Replikate.
- Während der gesamten Migration keine Datenbanken anlegen/löschen und keine Resharding-Jobs starten. Bereits laufende Jobs vorher beenden oder stoppen.
- Der Loadbalancer muss den neuen Node während des Wartungsmodus ausschließen. Ein korrekt eingerichteter Healthcheck auf `/_up` erkennt den Wartungsmodus als HTTP 404.

Für Windows PowerShell 5.1 ist keine zusätzliche Installation nötig. Optional PowerShell 7 installieren:

```powershell
winget install --id Microsoft.PowerShell --source winget
```

Die zum gewählten Skript passende PowerShell öffnen. Bei administrativ vorgegebener Execution Policy gelten die Vorgaben der eigenen Umgebung. Für eine heruntergeladene und geprüfte Datei kann gegebenenfalls `Unblock-File .\Replace-CouchDbNode-PS51.ps1` (beziehungsweise der PS7-Dateiname) erforderlich sein.

## Schnellstart

Repository herunterladen oder klonen und in den Ordner wechseln:

```powershell
git clone https://github.com/CodeExc/CouchDB-Replace-Nodes.git
Set-Location CouchDB-Replace-Nodes
```

Skript passend zur PowerShell-Version auswählen:

| PowerShell | Skript |
|---|---|
| Windows PowerShell 5.1, einschließlich 5.1.26100 | `Replace-CouchDbNode-PS51.ps1` |
| PowerShell 7.2 oder neuer | `Replace-CouchDbNode.ps1` |

Für Windows PowerShell 5.1:

```powershell
$ScriptPath = '.\Replace-CouchDbNode-PS51.ps1'
```

Für PowerShell 7 alternativ:

```powershell
$ScriptPath = '.\Replace-CouchDbNode.ps1'
```

Die Parameter und Modi sind in beiden Varianten identisch. Die 5.1-Version benötigt keine zusätzlichen Module; sie wandelt JSON-Objekte rekursiv in Dictionaries um, verwendet `-UseBasicParsing` und schreibt Sicherungen über .NET als UTF-8 ohne BOM. TLS 1.2 wird zusätzlich aktiviert, ohne die Zertifikatsprüfung abzuschalten.

Parameter einmal setzen. Node-Namen exakt aus `GET /_membership` übernehmen:

```powershell
$p = @{
    ExistingUrl = 'http://couchdb1.example.internal:5984'
    NewUrl      = 'http://couchdb4.example.internal:5984'
    OldNode     = 'couchdb@couchdb3.example.internal'
    NewNode     = 'couchdb@couchdb4.example.internal'
}
```

`ExistingUrl` darf auf einen erreichbaren bestehenden Node zeigen; dieser muss nicht der zu ersetzende Node sein. `NewUrl` muss direkt auf `NewNode` zeigen.

Zugangsdaten werden bei jedem Aufruf abgefragt. Optional einmal für die Sitzung erfassen:

```powershell
$p.Credential = Get-Credential -UserName admin
```

Passwörter werden nicht in die Metadaten-Sicherung geschrieben. HTTP überträgt Basic-Authentifizierung unverschlüsselt; HTTPS oder einen entsprechend geschützten Transport verwenden.

### 1. Vorschau

```powershell
& $ScriptPath @p -Mode Plan
```

Prüft Cluster-Mitgliedschaft, Zielidentität und Shard-Map. Listet betroffene Datenbanken mit der Anzahl der Shards auf. **Ändert nichts.** Ohne `-Mode` wird ebenfalls `Plan` verwendet.

### 2. Zusätzliche Replikate anlegen

```powershell
& $ScriptPath @p -Mode Prepare
```

Das Skript:

1. Sichert alle gelesenen Shard-Metadaten.
2. Setzt den neuen Node in `maintenance_mode = "true"`.
3. Ergänzt den neuen Node in `by_node`, `by_range` und `changelog`.
4. Startet je betroffener Datenbank `POST /{db}/_sync_shards`.

Die Dateien werden durch interne Replikation übertragen. Manuelles Kopieren ist nicht erforderlich. Der alte Node bleibt vollständig zugeordnet und muss weiterlaufen. Der neue Node bleibt nach diesem Schritt im Wartungsmodus.

`Prepare` kann nach einem Fehler erneut ausgeführt werden. Bereits vorhandene Zuordnungen werden nicht doppelt angelegt; Synchronisierungen werden erneut angestoßen. Nach `Finalize` nicht erneut `Prepare` verwenden.

### 3. Synchronisierung überprüfen

```powershell
& $ScriptPath @p -Mode Status
```

Zeigt den Wartungsmodus und `internal_replication_jobs` des neuen Nodes. Wiederholt beobachten und die CouchDB-Logs auf Replikations-, Netzwerk- und Speicherfehler prüfen.

**Ein Wert von 0 allein beweist keine erfolgreiche Synchronisierung.** Der Zähler zeigt Aktivität, keinen Fortschritt pro Shard und keine Fehlerhistorie. Vor dem nächsten Schritt muss der Betreiber die Vollständigkeit und Aktualität der Zielreplikate prüfen, beispielsweise anhand der tatsächlichen Shards auf dem Ziel und einer Datenprüfung in einem kontrollierten Wartungsfenster. Die Shard-Map zeigt nur die Zuordnung, nicht den Replikationsfortschritt. Eine allgemeine erfolgreiche Cluster-Abfrage beweist ebenfalls nicht, dass der neue Node selbst alle Daten hat.

Das Skript automatisiert diese inhaltliche Prüfung nicht und beendet den Wartungsmodus nicht automatisch nach einer Wartezeit.

### 4. Alte Shard-Zuordnungen entfernen

**Nur nach erfolgreich geprüfter Synchronisierung:**

```powershell
& $ScriptPath @p -Mode Finalize -SynchronizationVerified
```

Das Skript prüft, ob alle betroffenen Zielzuordnungen vorhanden sind und der neue Node aktuell keine internen Replikationsjobs meldet. Danach beendet es den Wartungsmodus, prüft `/_up`, entfernt die Zuordnungen des alten Nodes und kontrolliert abschließend die Shard-Map.

`-SynchronizationVerified` ist die ausdrückliche Bestätigung deiner Datenprüfung, kein automatischer Nachweis durch das Skript.

### 5. Alten Node aus dem Cluster entfernen

Das Skript löscht **keine Cluster-Mitgliedschaft und keine Datenbankdateien**.

Erst wenn `Finalize` erfolgreich abgeschlossen ist und die neuen Replikate geprüft sind:

1. Alten Node aus dem Loadbalancer nehmen.
2. Sicherstellen, dass keine Shard-Map mehr auf den alten Node verweist.
3. An einem verbleibenden Node `GET /_node/_local/_nodes/{alter-node-name}` aufrufen.
4. Das Mitgliedschaftsdokument mit seiner aktuellen `_rev` über `DELETE /_node/_local/_nodes/{alter-node-name}?rev={revision}` entfernen.
5. Mitgliedschaft auf den verbleibenden Nodes prüfen und den alten Dienst abschalten.

Daten des alten Nodes zunächst als Rückfallmöglichkeit behalten. Den neuen Node wieder in den Loadbalancer aufnehmen, falls er manuell ausgeschlossen wurde.

## Parameter

| Parameter | Bedeutung |
|---|---|
| `ExistingUrl` | HTTP(S)-Adresse eines bestehenden Cluster-Nodes, mit Port |
| `NewUrl` | Direkte HTTP(S)-Adresse des neuen Nodes, mit Port |
| `OldNode` | Exakter Erlang-Name des zu ersetzenden Nodes |
| `NewNode` | Exakter Erlang-Name des neuen Nodes |
| `Mode` | `Plan` (Standard), `Prepare`, `Status` oder `Finalize` |
| `Credential` | Optionale `PSCredential`; sonst interaktive Abfrage |
| `BackupDirectory` | Ziel für Metadaten-Sicherungen; Standard: `./couchdb-migration-backups` |
| `SynchronizationVerified` | Für `Finalize` erforderliche Bestätigung der Synchronisierungsprüfung |

## Sicherungen und Fehlerbehandlung

Vor jeder schreibenden Phase entsteht ein eigener Unterordner mit `shard-metadata.json` und `parameters.json`. Dies ist **nur eine Sicherung der Zuordnungen**, kein Backup der Dokumente, Attachments oder Indexdateien.

Bei HTTP-Fehlern, widersprüchlichen Zuordnungen oder geänderten Metadatenrevisionen bricht das Skript ab. Bereits gespeicherte Änderungen bleiben bestehen; es gibt keinen automatischen Rollback und keine atomare Transaktion über mehrere Datenbanken. Fehlerursache prüfen und dieselbe Phase erneut ausführen. Währenddessen alten Node und Sicherungen behalten.

Alte Metadaten-Sicherungen nicht blind zurückschreiben: Revisionen, zwischenzeitliche Änderungen und bereits erfolgte Migrationen müssen berücksichtigt werden.

## Validierung und Grenzen

Syntax und Ablauf wurden mit PowerShell 7.4.6 gegen einen simulierten HTTP-Endpunkt geprüft: Vorschau, Prepare, wiederholtes Prepare ohne Duplikate, Status, Finalize und wiederholtes Finalize; einschließlich Systemdatenbanken und kodierter Datenbanknamen.

Die 5.1-Variante wurde ebenfalls auf Syntax und gegen denselben simulierten HTTP-Endpunkt geprüft, einschließlich verschachtelter Arrays und wiederholter Ausführung. Diese Prüfungen liefen unter PowerShell 7.4.6 mit der 5.1-kompatiblen Implementierung. **Ein direkter Lauf unter Windows PowerShell 5.1 wurde hier noch nicht ausgeführt.**

**Noch kein Integrationstest gegen einen echten CouchDB-3.5.2-Cluster.** Vor produktiver Nutzung in einer passenden Testumgebung erproben.

Das Skript ist für den geplanten Austausch eines noch erreichbaren Nodes gedacht. Es fügt den neuen Node nicht selbst zum Cluster hinzu und ist kein automatisches Disaster-Recovery-Werkzeug.

## Dokumentation

- [CouchDB: Moving a shard](https://docs.couchdb.org/en/stable/cluster/sharding.html#moving-a-shard)
- [CouchDB: Node Management](https://docs.couchdb.org/en/stable/cluster/nodes.html)
