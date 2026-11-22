# homelab-pyme

Laboratorio que simula la infraestructura de una pyme: firewall perimetral con **FortiGate**, virtualización con **Proxmox VE**, controlador de dominio Windows Server, servidor Linux en DMZ y copias de seguridad con **Acronis Cyber Protect**. Todo se documenta paso a paso, con capturas y las decisiones de diseño.

## Arquitectura

```
                    Internet
                       │
           Router de casa 192.168.1.1
                       │
   vmbr0 (WAN) ── 192.168.1.0/24 ── Proxmox VE (192.168.1.200)
                       │
                 port1 192.168.1.201
               ┌───────────────────┐
               │   FortiGate-VM    │
               │   FortiOS 8.0.2   │
               └───────────────────┘
          port2 10.10.10.1    port3 10.10.20.1
                │                    │
   vmbr1 (LAN) 10.10.10.0/24   vmbr2 (DMZ) 10.10.20.0/24
                │                    │
   Windows Server 2025         Ubuntu 26.04 + Docker
   (AD, DNS, DHCP)             (proxy Nginx, web, Uptime Kuma)
                               VIP 192.168.1.210 → 10.10.20.10
```

| Red | Bridge | Subred | Uso |
|---|---|---|---|
| WAN | vmbr0 | 192.168.1.0/24 | Red de casa: hace de "Internet" del lab y de red de gestión |
| LAN | vmbr1 | 10.10.10.0/24 | Puestos y servidores internos (controlador de dominio) |
| DMZ | vmbr2 | 10.10.20.0/24 | Servicios publicados, aislados de la LAN y de la red de casa |

## Fases

| # | Fase | Estado | Guía |
|---|---|---|---|
| 1 | Hipervisor Proxmox VE y redes virtuales | ✅ | [docs/01-proxmox.md](docs/01-proxmox.md) |
| 2 | Firewall perimetral FortiGate-VM | ✅ | [docs/02-fortigate.md](docs/02-fortigate.md) |
| 3 | Controlador de dominio Windows Server 2025 | ✅ | [docs/03-controlador-dominio.md](docs/03-controlador-dominio.md) |
| 4 | Servidor Ubuntu 26.04 con Docker en la DMZ | ✅ | [docs/04-dmz-docker.md](docs/04-dmz-docker.md) |
| 5 | Automatización con las APIs de FortiGate y Proxmox | ⏳ | — |
| 6 | Backup y restauración con Acronis Cyber Protect | ⏳ | — |

## Hardware

- **Host:** Windows 11, Ryzen 7 7700, 32 GB RAM, HDD 4 TB, red por cable 2.5GbE.
- **Proxmox:** VM con virtualización anidada (8 vCPU, 20 GB RAM, 300 GB).

## Estructura del repositorio

```
homelab-pyme/
├── README.md        ← este archivo
├── docs/            ← una guía por fase
│   └── img/         ← capturas (NN-descripcion.png, NN = número de fase)
├── diagrams/        ← diagramas de red
├── scripts/         ← automatizaciones (Python / PowerShell / Bash)
└── configs/         ← configuraciones exportadas, sin contraseñas
```

## Autor

Ferran Bertomeu — Administrador de sistemas.
