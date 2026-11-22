#!/usr/bin/env python3
"""
homelab-pyme · Fase 5 — Automatización con las APIs de FortiGate y Proxmox VE.

  1. Backup cifrado de la configuración del FortiGate (API REST de FortiOS).
  2. Informe de estado del nodo Proxmox y de sus VMs (API de Proxmox VE).

Solo usa la librería estándar de Python (no hace falta pip install).
Los tokens y la clave de cifrado se leen de un archivo .env que NO se sube al repo.

Uso:
    python scripts/05-automatizacion.py              # backup + informe
    python scripts/05-automatizacion.py --backup     # solo backup del FortiGate
    python scripts/05-automatizacion.py --informe    # solo informe de Proxmox
    python scripts/05-automatizacion.py --env C:\\ruta\\.env

Códigos de salida: 0 = todo correcto, 1 = alguna tarea ha fallado, 2 = error de configuración.
"""

import argparse
import datetime as dt
import json
import logging
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ENV_POR_DEFECTO = REPO / ".env"

log = logging.getLogger("homelab")


# --------------------------------------------------------------------------- #
#  Configuración
# --------------------------------------------------------------------------- #
def cargar_env(ruta: Path) -> dict:
    """Lee un .env sencillo (CLAVE=valor). Ignora líneas vacías y comentarios."""
    if not ruta.is_file():
        raise FileNotFoundError(f"No existe {ruta}. Copia .env.example a .env y rellénalo.")
    cfg = {}
    for linea in ruta.read_text(encoding="utf-8").splitlines():
        linea = linea.strip()
        if not linea or linea.startswith("#") or "=" not in linea:
            continue
        clave, valor = linea.split("=", 1)
        cfg[clave.strip()] = valor.strip().strip('"').strip("'")
    return cfg


def requerir(cfg: dict, *claves: str) -> None:
    faltan = [c for c in claves if not cfg.get(c)]
    if faltan:
        raise ValueError(f"Faltan en el .env: {', '.join(faltan)}")


def contexto_tls(verificar: str, ca: str) -> ssl.SSLContext:
    """
    Por defecto verifica el certificado. En el lab, FortiGate y Proxmox usan
    certificados autofirmados: se puede indicar su CA (FGT_CA / PVE_CA) o
    desactivar la verificación (FGT_VERIFY_TLS=false), solo en un entorno de pruebas.
    """
    if verificar.lower() in ("false", "0", "no"):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    return ssl.create_default_context(cafile=ca or None)


def peticion(url, cabeceras, ctx, metodo="GET", cuerpo=None, timeout=30):
    datos = json.dumps(cuerpo).encode() if cuerpo is not None else None
    req = urllib.request.Request(url, data=datos, method=metodo, headers=cabeceras)
    if datos is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, context=ctx, timeout=timeout) as r:
        return r.status, r.read()


# --------------------------------------------------------------------------- #
#  1. Backup del FortiGate
# --------------------------------------------------------------------------- #
def backup_fortigate(cfg: dict, salida: Path) -> bool:
    requerir(cfg, "FGT_HOST", "FGT_TOKEN", "FGT_BACKUP_PASSWORD")
    host = cfg["FGT_HOST"]
    ctx = contexto_tls(cfg.get("FGT_VERIFY_TLS", "true"), cfg.get("FGT_CA", ""))
    cabeceras = {"Authorization": f"Bearer {cfg['FGT_TOKEN']}", "Accept": "*/*"}

    # Hostname para nombrar el archivo
    try:
        _, cuerpo = peticion(f"https://{host}/api/v2/monitor/system/status", cabeceras, ctx)
        estado = json.loads(cuerpo)
        nombre = estado.get("results", {}).get("hostname", "fortigate")
        version = f"{estado.get('version', '?')} build {estado.get('build', '?')}"
    except (urllib.error.URLError, ValueError) as e:
        log.error("FortiGate: no responde la API (%s)", e)
        return False

    # FortiOS 8: el backup se pide por POST y exige clave de cifrado
    cuerpo_backup = {
        "destination": "file",
        "scope": "global",
        "password": cfg["FGT_BACKUP_PASSWORD"],
    }
    try:
        codigo, datos = peticion(
            f"https://{host}/api/v2/monitor/system/config/backup",
            cabeceras, ctx, metodo="POST", cuerpo=cuerpo_backup, timeout=120,
        )
    except urllib.error.HTTPError as e:
        log.error("FortiGate: backup rechazado, HTTP %s (¿permisos del perfil?)", e.code)
        return False
    except urllib.error.URLError as e:
        log.error("FortiGate: error de conexión (%s)", e)
        return False

    # Un backup válido empieza por #FGBK (cifrado) o #config-version (texto).
    # Si llega un JSON, es un error aunque el HTTP sea 200.
    if not (datos.startswith(b"#FGBK") or datos.startswith(b"#config-version")):
        try:
            detalle = json.loads(datos).get("results", {}).get("error", datos[:200])
        except ValueError:
            detalle = datos[:200]
        log.error("FortiGate: la respuesta no es un backup (%s)", detalle)
        return False

    carpeta = salida / "backups" / "fortigate"
    carpeta.mkdir(parents=True, exist_ok=True)
    marca = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    archivo = carpeta / f"{nombre}_{marca}.conf"
    archivo.write_bytes(datos)
    log.info("FortiGate %s (FortiOS %s): backup guardado en %s (%d bytes)",
             nombre, version, archivo, len(datos))

    rotar(carpeta, f"{nombre}_*.conf", int(cfg.get("FGT_RETENCION", "14")))
    return True


def rotar(carpeta: Path, patron: str, conservar: int) -> None:
    """Mantiene solo los N backups más recientes."""
    archivos = sorted(carpeta.glob(patron), key=lambda p: p.stat().st_mtime, reverse=True)
    for viejo in archivos[conservar:]:
        viejo.unlink()
        log.info("FortiGate: eliminado backup antiguo %s", viejo.name)


# --------------------------------------------------------------------------- #
#  2. Informe de Proxmox
# --------------------------------------------------------------------------- #
def gib(b) -> str:
    return f"{(b or 0) / 1024**3:.1f} GiB"


def duracion(seg) -> str:
    seg = int(seg or 0)
    if seg == 0:
        return "—"
    d, resto = divmod(seg, 86400)
    h, resto = divmod(resto, 3600)
    m = resto // 60
    return f"{d}d {h}h {m}m" if d else f"{h}h {m}m"


def pct(usado, total) -> str:
    if not total:
        return "—"
    return f"{min(100.0, 100 * (usado or 0) / total):.0f} %"


def informe_proxmox(cfg: dict, salida: Path) -> bool:
    requerir(cfg, "PVE_HOST", "PVE_NODE", "PVE_TOKEN_ID", "PVE_TOKEN_SECRET")
    base = f"https://{cfg['PVE_HOST']}:{cfg.get('PVE_PORT', '8006')}/api2/json"
    nodo = cfg["PVE_NODE"]
    ctx = contexto_tls(cfg.get("PVE_VERIFY_TLS", "true"), cfg.get("PVE_CA", ""))
    cabeceras = {"Authorization": f"PVEAPIToken={cfg['PVE_TOKEN_ID']}={cfg['PVE_TOKEN_SECRET']}"}

    def api(ruta):
        _, cuerpo = peticion(base + ruta, cabeceras, ctx)
        return json.loads(cuerpo)["data"]

    try:
        estado_nodo = api(f"/nodes/{nodo}/status")
        version = api("/version")
        vms = sorted(api(f"/nodes/{nodo}/qemu"), key=lambda v: int(v["vmid"]))
        almacenes = api(f"/nodes/{nodo}/storage")
    except urllib.error.HTTPError as e:
        log.error("Proxmox: HTTP %s en la API (¿token o permisos?)", e.code)
        return False
    except urllib.error.URLError as e:
        log.error("Proxmox: error de conexión (%s)", e)
        return False

    filas = []
    for vm in vms:
        vmid = vm["vmid"]
        try:
            snaps = [s for s in api(f"/nodes/{nodo}/qemu/{vmid}/snapshot") if s.get("name") != "current"]
        except urllib.error.HTTPError:
            snaps = []
        ultimo = max(snaps, key=lambda s: s.get("snaptime", 0), default=None)
        ultimo_txt = "—"
        if ultimo:
            fecha = dt.datetime.fromtimestamp(ultimo.get("snaptime", 0)).strftime("%Y-%m-%d %H:%M")
            ultimo_txt = f"{ultimo['name']} ({fecha})"
        en_marcha = vm.get("status") == "running"
        filas.append({
            "vmid": vmid,
            "nombre": vm.get("name", ""),
            "estado": "🟢 running" if en_marcha else "🔴 " + vm.get("status", "?"),
            "cpu": f"{vm.get('cpu', 0) * 100:.1f} % de {vm.get('cpus', '?')} vCPU" if en_marcha else f"{vm.get('cpus', '?')} vCPU",
            "ram": f"{gib(vm.get('mem'))} / {gib(vm.get('maxmem'))} ({pct(vm.get('mem'), vm.get('maxmem'))})" if en_marcha else gib(vm.get("maxmem")),
            "disco": gib(vm.get("maxdisk")),
            "uptime": duracion(vm.get("uptime")),
            "snapshots": f"{len(snaps)} · último: {ultimo_txt}" if snaps else "0",
        })

    ahora = dt.datetime.now()
    mem = estado_nodo.get("memory", {})
    raiz = estado_nodo.get("rootfs", {})
    en_marcha = sum(1 for v in vms if v.get("status") == "running")

    md = [
        f"# Informe de estado — Proxmox `{nodo}`",
        "",
        f"Generado: {ahora:%Y-%m-%d %H:%M} · Proxmox VE {version.get('version', '?')}",
        "",
        "## Nodo",
        "",
        "| Métrica | Valor |",
        "|---|---|",
        f"| Uptime | {duracion(estado_nodo.get('uptime'))} |",
        f"| CPU | {estado_nodo.get('cpu', 0) * 100:.1f} % de {estado_nodo.get('cpuinfo', {}).get('cpus', '?')} núcleos |",
        f"| RAM | {gib(mem.get('used'))} / {gib(mem.get('total'))} ({pct(mem.get('used'), mem.get('total'))}) |",
        f"| Disco raíz | {gib(raiz.get('used'))} / {gib(raiz.get('total'))} ({pct(raiz.get('used'), raiz.get('total'))}) |",
        f"| VMs | {en_marcha} en marcha de {len(vms)} |",
        "",
        "## Máquinas virtuales",
        "",
        "| VMID | Nombre | Estado | CPU | RAM | Disco | Uptime | Snapshots |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for f in filas:
        md.append(f"| {f['vmid']} | {f['nombre']} | {f['estado']} | {f['cpu']} | {f['ram']} | "
                  f"{f['disco']} | {f['uptime']} | {f['snapshots']} |")

    md += ["", "## Almacenamiento", "", "| Almacén | Tipo | Usado | Total | Uso |", "|---|---|---|---|---|"]
    for a in sorted(almacenes, key=lambda x: x.get("storage", "")):
        if not a.get("active"):
            continue
        md.append(f"| {a['storage']} | {a.get('type', '')} | {gib(a.get('used'))} | "
                  f"{gib(a.get('total'))} | {pct(a.get('used'), a.get('total'))} |")

    carpeta = salida / "informes"
    carpeta.mkdir(parents=True, exist_ok=True)
    archivo = carpeta / f"informe-proxmox_{ahora:%Y%m%d-%H%M%S}.md"
    archivo.write_text("\n".join(md) + "\n", encoding="utf-8")

    # Resumen por consola
    log.info("Proxmox %s: %d/%d VMs en marcha", nodo, en_marcha, len(vms))
    for f in filas:
        log.info("  %-4s %-10s %-12s %s", f["vmid"], f["nombre"], f["estado"].split(" ", 1)[1], f["ram"])
    log.info("Proxmox: informe guardado en %s", archivo)
    return True


# --------------------------------------------------------------------------- #
def main() -> int:
    p = argparse.ArgumentParser(description="Backup del FortiGate e informe de Proxmox (homelab-pyme)")
    p.add_argument("--backup", action="store_true", help="solo backup del FortiGate")
    p.add_argument("--informe", action="store_true", help="solo informe de Proxmox")
    p.add_argument("--env", type=Path, default=ENV_POR_DEFECTO, help="ruta del archivo .env")
    args = p.parse_args()
    hacer_todo = not (args.backup or args.informe)

    try:
        cfg = cargar_env(args.env)
    except FileNotFoundError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    salida = Path(cfg.get("SALIDA", REPO / "salida"))
    salida.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        handlers=[logging.StreamHandler(sys.stdout),
                  logging.FileHandler(salida / "automatizacion.log", encoding="utf-8")],
    )
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    ok = True
    try:
        if hacer_todo or args.backup:
            ok &= backup_fortigate(cfg, salida)
        if hacer_todo or args.informe:
            ok &= informe_proxmox(cfg, salida)
    except ValueError as e:
        log.error("%s", e)
        return 2

    log.info("Resultado: %s", "OK" if ok else "CON ERRORES")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
