# Vane auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil)

> Upstream-App (kein Teil dieses Ordners): `https://github.com/ItzCrazyKns/Vane`
> (AI-powered answering engine im Stil von Perplexica, Fork-basiert)
> Dieses Repo enthält **nur den Proxmox-Installer**: Install-Script + systemd-Units.
> Die App läuft nativ (Node 20/Next.js + SearxNG via pip/gunicorn, ohne Docker).
> Vollständig lokal: SearxNG-Suche + Web UI laufen im LXC; das LLM ist frei wählbar
> (Cloud-Keys im Setup-Screen eintragen oder eigener lokaler OpenAI-kompatibler Server).

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VaneAI-Proxmox/main/install/vane.sh)"
```

Anpassungen per Umgebungsvariable oder Flag (ID immer **nächste freie**, außer gesetzt):

```bash
CT_ID=150 CORES=2 RAM=2048 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VaneAI-Proxmox/main/install/vane.sh)"
bash vane.sh --ctid 150 --cores 2 --memory 2048 --disk 8 --bridge vmbr0 --storage local-lvm
bash vane.sh --debug     # = bash -x, komplette Fehlermeldungskette + Log unter /tmp/vane-install-*.log
```

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `vane` |
| Zweck | Privacy-fokussierte AI-Antwortmaschine: Web/Diskussions/Academic-Suche mit Quellenangaben, Widgets, Bild-/Video-Suche, File-Upload |
| Tech-Stack | Node 20 + Next.js (`npm ci && npm run build && npm run start`, bind `0.0.0.0:3000`) + SearxNG (pip + gunicorn, nur `127.0.0.1:8080`) |
| GitHub-Repo (Upstream) | `https://github.com/ItzCrazyKns/Vane` |
| Web UI | `http://<LXC-IP>:3000` |
| Standard-Ressourcen | 2 vCPU / 2048 MB RAM / 1024 MB Swap / 12 GB Disk (node_modules ~2 GB + Build-Cache; ältere 8-GB-CTs ggf. per `pct resize <ID> +4G` erweitern) |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |
| LXC-Features | **unprivilegiert** (`--unprivileged 1`), `nesting=1`, `onboot: 1` |

Das Skript (`set -euo pipefail`, idempotent, `trap ERR` mit Befehl+Zeile+Exit-Code):
1. prüft Host/Tools, nimmt die nächste freie CT-ID, erkennt RootFS-Storage
   (bevorzugt `local-lvm`), lädt das neueste `debian-12-standard`-Template falls nötig,
2. erstellt den LXC `vane` (`onboot: 1`, unprivilegiert),
3. installiert im Container: Node 20 (NodeSource), SearxNG (venv + gunicorn,
   `/etc/searxng/settings.yml` mit **JSON-Format + Wolfram Alpha**, Secret nur beim
   ersten Lauf generiert),    klont/pullt Vane nach `/opt/vane`, `npm ci && npm run build`,
   schreibt `vane.service` + `searxng.service`, `systemctl enable --now` beide,
   wobei **SearXNG bereits direkt nach seiner Installation startet und per HTTP
   verifiziert wird** — unabhängig davon, ob der (lange) Vane-Build danach
   beim ersten Versuch hakt,
4. verifiziert `systemctl is-active vane searxng` + HTTP auf `localhost:3000`
   und `localhost:8080` und gibt die finale URL + Container-IP aus.

Nach dem ersten Öffnen von `http://<LXC-IP>:3000`: Im Setup-Screen
- LLM-Provider + API-Key eintragen (OpenAI, Claude, Gemini, Groq …), und
- als SearxNG-URL `http://127.0.0.1:8080` setzen (läuft im selben Container).

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    SearxNG läuft (systemctl is-active searxng = active).
[OK]    Vane-Service läuft (systemctl is-active vane = active).
[OK]    SearxNG antwortet (HTTP 200 auf localhost:8080/).
[OK]    Web UI antwortet (HTTP 200 auf localhost:3000/).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : Vane – privacy-fokussierte AI-Antwortmaschine
  Container    : CT 100 (Hostname: vane, unprivilegiert, onboot=1)
  Ressourcen   : 2 vCPU / 2048 MB RAM / 8 GB Disk
  Web UI       : http://192.168.1.100:3000
  ...
  Log          : /tmp/vane-install-2026-....log
══════════════════════════════════════════════════════════
```

## Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 60
pct exec $CT -- systemctl is-active vane searxng
curl -fs http://<LXC-IP>:3000 >/dev/null && echo WEB_UI_OK
```

Beide Units haben `Restart=always` + `After=network-online.target`, der CT hat
`onboot: 1` – nach einem Node-/Host-Reboot kommt alles selbstständig hoch.

## Update / Deinstall

```bash
bash vane.sh --ctid 100              # Update: idempotent (git pull + npm ci + rebuild + restart)
pct stop 100 && pct destroy 100     # Deinstall
```

## Debugging

- Jeder Fehler gibt Befehl + Zeile + Exit-Code aus, Voll-Log unter `/tmp/vane-install-*.log`.
- `bash vane.sh --debug` für `bash -x`-Trace.
- Im Container: `systemctl status vane searxng --no-pager`,
  `journalctl -u vane -n 100`, `journalctl -u searxng -n 100`.
- Ollama/lokaler LLM-Server statt Cloud: URL im Setup-Screen eintragen
  (siehe Vane-README-Abschnitt „Local OpenAI-API-Compliant Servers“).

## Dateien

- `install/vane.sh` – Proxmox-Einzeiler (Host, root).
- `systemd/vane.service` – Next.js-Unit (bind `0.0.0.0:3000`, `After=network-online.target searxng.service`, `Restart=always`).
- `systemd/searxng.service` – SearxNG-Unit (nur `127.0.0.1:8080`, `Restart=always`).
