# Fase 3 — Controlador de dominio con Windows Server 2025

Windows Server 2025 desplegado como VM 101 (`DC01`) en la LAN. Es el controlador de dominio de la pyme y da los servicios de **Active Directory**, **DNS** y **DHCP**. La estructura de AD y las políticas de grupo se crean con dos scripts de PowerShell del repositorio. Un cliente Windows 11 (`PC01`, VM 102) se une al dominio para comprobar que todo funciona de verdad: DHCP, DNS dinámico, inicio de sesión y aplicación de las GPOs.

| Elemento | Valor |
|---|---|
| Dominio (FQDN) / NetBIOS | `pyme.internal` / `PYME` |
| Nivel funcional | Windows2025Domain / Windows2025Forest |
| DC | VM 101 `DC01`, Windows Server 2025 Standard Evaluation (Desktop Experience) |
| IP de DC01 | 10.10.10.10/24, gateway 10.10.10.1 (FortiGate, port2) |
| DNS de DC01 | 10.10.10.10, 127.0.0.1. Reenviadores 8.8.8.8 y 9.9.9.9 |
| DHCP | Ámbito `LAN-PYME` 10.10.10.100–200, concesión de 8 días |
| Cliente | VM 102 `PC01`, Windows 11 Pro |

### 1. Subir las ISOs

La ISO de Windows Server 2025 (en inglés, `WS2025_en-us.iso`) se sube desde el PC con *local (pve) → Imágenes ISO → Cargar*.

![Subida de la ISO de Windows Server](img/03-iso-cargar.png)

La ISO de los drivers VirtIO se descarga directamente en el nodo, desde *pve → Consola*:

```bash
cd /var/lib/vz/template/iso
wget -O virtio-win.iso https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
```

![Descarga de virtio-win.iso](img/03-iso-virtio-wget.png)
![ISOs disponibles en local](img/03-isos.png)

### 2. Crear la VM DC01

Asistente *Crear VM* con la casilla **Avanzado** marcada:

| Pestaña | Campo | Valor |
|---|---|---|
| General | VM ID / Nombre | `101` / `DC01` |
| | Iniciar al arranque / Orden | ✅ / `2` |
| SO | Imagen ISO | `WS2025_en-us.iso` |
| | Tipo / Versión | Microsoft Windows / 11/2022/2025 |
| | Disco adicional para drivers VirtIO | ✅ `virtio-win.iso` |
| Sistema | Máquina / BIOS | q35 / OVMF (UEFI) |
| | Disco EFI | local-lvm, con llaves preinscritas |
| | Controlador SCSI / Qemu Agent | VirtIO SCSI single / ✅ |
| | TPM | v2.0 en local-lvm |
| Discos | Bus / Tamaño | SCSI 0, local-lvm, 60 GiB |
| | Descartar / IO thread | ✅ / ✅ |
| CPU | Zócalos / Núcleos / Tipo | 1 / 2 / x86-64-v2-AES (por defecto) |
| Memoria | Memoria / Mínimo | 4096 MiB / 4096 MiB |
| Red | Puente / Modelo / Cortafuego | `vmbr1` (LAN) / VirtIO / desactivado |

![General](img/03-vm-general.png)
![SO](img/03-vm-so.png)
![Sistema](img/03-vm-sistema.png)
![Discos](img/03-vm-discos.png)
![CPU](img/03-vm-cpu.png)
![Memoria](img/03-vm-memoria.png)
![Red](img/03-vm-red.png)
![Confirmar](img/03-vm-confirmar.png)

### 3. Instalar Windows Server

- **Idioma:** instalación en inglés, con formato de hora y moneda y teclado en español.
- **Clave de producto:** *I don't have a product key*.
- **Edición:** Windows Server 2025 Standard Evaluation (Desktop Experience).

![Idioma y formato regional](img/03-win-idioma.png)
![Edición Standard Evaluation (Desktop Experience)](img/03-win-edicion.png)

El instalador no ve el disco porque el controlador VirtIO SCSI no viene en Windows. Hay que pulsar **Load driver → Browse** y elegir `D:\vioscsi\2k25\amd64` (*Red Hat VirtIO SCSI pass-through controller*). Después ya aparece el disco de 60 GB.

![Driver vioscsi](img/03-win-driver-vioscsi.png)
![Disco visible tras cargar el driver](img/03-win-disco.png)

Al terminar, se instala `virtio-win-guest-tools.exe` desde la unidad del CD de VirtIO. Instala el resto de drivers (red VirtIO, balloon, etc.) y el **QEMU Guest Agent**.

![virtio-win-guest-tools](img/03-guest-tools.png)

Con el agente funcionando, Proxmox muestra la IP de la VM en *101 → Resumen*. De momento es una 169.254.x.x, porque todavía no hay IP configurada.

![IP visible gracias al Guest Agent](img/03-guest-agent.png)

### 4. IP fija, zona horaria y nombre

PowerShell como administrador:

```powershell
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 10.10.10.10 -PrefixLength 24 -DefaultGateway 10.10.10.1
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 8.8.8.8
Set-TimeZone -Id "Romance Standard Time"
Rename-Computer -NewName "DC01" -Restart
```

El DNS público es temporal. En cuanto DC01 sea servidor DNS, apuntará a sí mismo (paso 8). Se usa 8.8.8.8 porque 1.1.1.1 está bloqueado en la red de casa (ver [Incidencias](#incidencias-y-diagnóstico)).

Comprobación tras el reinicio:

```powershell
hostname
ipconfig /all
Get-Date
```

![Nombre, IP y hora correctos](img/03-hostname-ipconfig.png)

### 5. Snapshot antes de promocionar

*101 → Snapshots → Tomar una snapshot*: nombre `pre-dc`, con RAM, descripción *Windows instalado, IP fija, antes de AD DS*. Si la promoción falla, se puede volver aquí sin reinstalar Windows.

![Snapshot pre-dc](img/03-snapshot-pre-dc.png)

### 6. Promoción a controlador de dominio

```powershell
Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools
Install-ADDSForest -DomainName "pyme.internal" -DomainNetbiosName "PYME" -InstallDns
```

Pide la contraseña de **DSRM** (modo de restauración de servicios de directorio), que debe ser distinta de la de Administrator. Los avisos amarillos sobre la delegación DNS son normales: `pyme.internal` no tiene zona padre en ningún servidor DNS. El servidor se reinicia solo y, a partir de ahí, se entra como `PYME\Administrator`.

![Install-ADDSForest completado](img/03-addsforest.png)

### 7. Verificar el dominio

```powershell
Get-ADDomain | Select-Object Name, DNSRoot, NetBIOSName, DomainMode
Get-Service adws, kdc, netlogon, dns | Select-Object Name, Status
dcdiag /q
Get-SmbShare SYSVOL, NETLOGON
```

![Dominio creado y servicios en marcha](img/03-dominio.png)

El dominio está creado, los servicios están en *Running* y SYSVOL y NETLOGON están compartidos. `dcdiag /q` solo marca **DFSREvent**, que es un aviso transitorio del primer arranque (ver [Incidencias](#incidencias-y-diagnóstico)).

### 8. DNS

```powershell
Set-DnsServerForwarder -IPAddress 8.8.8.8, 9.9.9.9
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 10.10.10.10, 127.0.0.1
Add-DnsServerPrimaryZone -NetworkId "10.10.10.0/24" -ReplicationScope Domain
ipconfig /registerdns
```

- **Reenviadores:** el DC resuelve los nombres de Internet a través de Google y Quad9.
- **DNS del propio DC:** su IP primero y el loopback después.
- **Zona inversa** `10.10.10.in-addr.arpa`, integrada en AD.

Pruebas:

```powershell
Get-DnsServerForwarder
Resolve-DnsName dc01.pyme.internal
Resolve-DnsName _ldap._tcp.dc._msdcs.pyme.internal -Type SRV
Resolve-DnsName www.microsoft.com
Resolve-DnsName 10.10.10.10
```

![Reenviadores, registro A y SRV del DC](img/03-dns.png)
![Resolución inversa (PTR)](img/03-dns-ptr.png)

El registro SRV `_ldap._tcp.dc._msdcs` es el que usan los clientes para encontrar el controlador de dominio. Si no resuelve, ningún equipo podrá unirse al dominio.

### 9. DHCP

```powershell
Install-WindowsFeature DHCP -IncludeManagementTools
netsh dhcp add securitygroups
Restart-Service dhcpserver
Add-DhcpServerInDC -DnsName dc01.pyme.internal -IPAddress 10.10.10.10
Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12 -Name ConfigurationState -Value 2

Add-DhcpServerv4Scope -Name "LAN-PYME" -StartRange 10.10.10.100 -EndRange 10.10.10.200 -SubnetMask 255.255.255.0 -LeaseDuration 8.00:00:00 -State Active
Set-DhcpServerv4OptionValue -ScopeId 10.10.10.0 -Router 10.10.10.1 -DnsServer 10.10.10.10 -DnsDomain pyme.internal
Set-DhcpServerv4DnsSetting -DynamicUpdates Always -DeleteDnsRROnLeaseExpiry $true
```

- `netsh dhcp add securitygroups` crea los grupos locales *DHCP Administrators* y *DHCP Users*.
- `Add-DhcpServerInDC` **autoriza** el servidor en AD. Un DHCP de Windows no autorizado no reparte direcciones dentro de un dominio.
- La clave `ConfigurationState = 2` marca como hecha la configuración posterior a la instalación y quita el aviso amarillo del Server Manager.
- DNS dinámico *Always*: el DHCP registra en DNS los nombres de los clientes y los borra cuando caduca la concesión.

| Opción | Valor |
|---|---|
| 3 Router | 10.10.10.1 |
| 6 DNS Servers | 10.10.10.10 |
| 15 DNS Domain Name | pyme.internal |
| 51 Lease | 691200 s (8 días) |

```powershell
Get-DhcpServerInDC
Get-DhcpServerv4Scope
Get-DhcpServerv4OptionValue -ScopeId 10.10.10.0
```

![Servidor autorizado, ámbito y opciones](img/03-dhcp-verificacion.png)

### 10. Estructura de AD con `03-ad-estructura.ps1`

Escribir en la consola noVNC es poco fiable (ver [Incidencias](#incidencias-y-diagnóstico)), así que el script se descarga desde GitHub directamente en el DC:

```powershell
mkdir C:\Scripts
cd C:\Scripts
iwr https://raw.githubusercontent.com/baRdeNNy/homelab-pyme/main/scripts/03-ad-estructura.ps1 -OutFile 03-ad-estructura.ps1
.\03-ad-estructura.ps1
```

[`scripts/03-ad-estructura.ps1`](../scripts/03-ad-estructura.ps1) hace lo siguiente:

1. Activa la **Papelera de reciclaje de AD**.
2. Crea las OUs bajo `OU=PYME`, protegidas contra el borrado accidental.
3. Crea un grupo global de seguridad por departamento (`GG_<depto>`).
4. Crea los usuarios en la OU de su departamento y los mete en su grupo. Pide la contraseña inicial al ejecutarse (no hay ninguna contraseña en el script) y obliga a cambiarla en el primer inicio de sesión.
5. Crea la cuenta de administración separada `adm.fbertomeu`, en *Domain Admins*.

```
OU=PYME,DC=pyme,DC=internal
├── Usuarios
│   ├── Direccion        mpuig (Gerente)
│   ├── Administracion   jferre, lsanz
│   ├── Comercial        proca, avidal
│   └── Produccion       mgil, nfont
├── Equipos              PC01
├── Servidores
├── Grupos               GG_Direccion, GG_Administracion, GG_Comercial, GG_Produccion
└── Admins               adm.fbertomeu (Domain Admins)
```

![Script de AD: papelera, OUs y grupos](img/03-script-ad.png)
![Script de AD: usuarios y resumen](img/03-script-ad-resumen.png)

El script es **idempotente**: si se vuelve a ejecutar, detecta lo que ya existe y no lo duplica ni da error.

![Segunda ejecución: todo "ya existe"](img/03-script-idempotente.png)

Por último, se redirige el contenedor por defecto de los equipos nuevos a la OU `Equipos`:

```powershell
redircmp "OU=Equipos,OU=PYME,DC=pyme,DC=internal"
```

![redircmp](img/03-redircmp.png)

### 11. Cliente PC01

VM 102 creada con el mismo asistente que DC01, con estas diferencias:

| Campo | Valor en PC01 |
|---|---|
| VM ID / Nombre | `102` / `PC01` |
| Iniciar al arranque | No (se enciende solo para las pruebas) |
| ISO | Windows 11 en español (`Windows11_Client_x64_es-es_…iso`), subida igual que la del servidor |
| Disco | IDE 0, local-lvm, 64 GiB |
| Red | `vmbr1`, Intel E1000 |
| Sistema, CPU y memoria | Igual que DC01: q35, OVMF + TPM 2.0, 2 núcleos, 4096 MiB |

![Disco IDE de 64 GiB](img/03-pc01-discos.png)
![Red E1000 en vmbr1](img/03-pc01-red.png)

Con disco IDE y tarjeta E1000, Windows 11 tiene los drivers de serie: no hace falta cargar ningún driver durante la instalación. Edición **Windows 11 Pro** (*No tengo clave de producto*), con una cuenta local (`user`) creada en la configuración inicial.

![Edición Windows 11 Pro](img/03-pc01-edicion.png)

Después se monta `virtio-win.iso` en la unidad de CD de la VM (*102 → Hardware → Unidad CD/DVD → Editar*) y se instala `virtio-win-guest-tools.exe` para tener el QEMU Guest Agent. Se cambia el nombre del equipo a `PC01` y se reinicia.

PC01 recibe la configuración del DHCP del DC:

```
ipconfig /all
```

![PC01 con IP 10.10.10.100 por DHCP](img/03-pc01-dhcp.png)

En DC01:

```powershell
Get-DhcpServerv4Lease -ScopeId 10.10.10.0
```

![Concesión de PC01 en el DHCP](img/03-dhcp-lease.png)

### 12. Unir PC01 al dominio

*Configuración → Sistema → Información → Dominio o grupo de trabajo → Cambiar…* → **Dominio**: `pyme.internal` → credenciales de `Administrator` del dominio → reiniciar.

![Información del sistema](img/03-pc01-info.png)
![Miembro del dominio pyme.internal](img/03-pc01-join.png)

Lo mismo en PowerShell (como administrador):

```powershell
Add-Computer -DomainName pyme.internal -Credential PYME\Administrator -Restart
```

Primer inicio de sesión con `mpuig` (*Otro usuario*): el dominio obliga a cambiar la contraseña inicial.

![Cambio de contraseña obligatorio](img/03-cambio-password.png)

Comprobación en PC01:

```powershell
whoami
$env:LOGONSERVER
nltest /dsgetdc:pyme.internal
```

![Sesión de dominio validada por DC01](img/03-pc01-usuario.png)

Y en DC01: el equipo ha caído en `OU=Equipos` gracias a `redircmp`, y su registro DNS se ha creado solo.

```powershell
Get-ADComputer PC01 | Select-Object Name, DistinguishedName
Resolve-DnsName pc01.pyme.internal
```

![PC01 en OU=Equipos y con registro DNS](img/03-pc01-ad.png)

### 13. Políticas de grupo y carpeta compartida con `03-gpo.ps1`

```powershell
cd C:\Scripts
iwr https://raw.githubusercontent.com/baRdeNNy/homelab-pyme/main/scripts/03-gpo.ps1 -OutFile 03-gpo.ps1
.\03-gpo.ps1
```

[`scripts/03-gpo.ps1`](../scripts/03-gpo.ps1), también idempotente, hace lo siguiente:

| # | Qué | Detalle |
|---|---|---|
| 1 | Política de contraseñas del dominio | 12 caracteres, complejidad, historial de 10, caducidad de 180 días, mínimo 1 día. Bloqueo tras 5 intentos durante 15 min |
| 2 | Carpeta `\\DC01\Datos` (`C:\Shares\Datos`) | `Comun` (todos modifican) y una carpeta por departamento (solo su `GG_*` modifica). **Access-Based Enumeration** activada |
| 3 | Fondo corporativo | Generado con `System.Drawing` y guardado en `\\pyme.internal\NETLOGON\fondo-pyme.jpg` |
| 4 | GPO `PYME-Equipos-Seguridad` → OU Equipos | Bloqueo de pantalla a los 900 s de inactividad y aviso legal al iniciar sesión |
| 5 | GPO `PYME-Usuarios-Escritorio` → OU Usuarios | Fondo de escritorio (estilo: rellenar) |

![Script de GPOs: contraseñas, carpeta, fondo y GPO de equipos](img/03-script-gpo.png)
![Script de GPOs: GPO de usuarios y resumen](img/03-script-gpo-resumen.png)

### 14. Unidad P: con Preferencias de GPO

En *Server Manager → Tools → Group Policy Management*: *Forest → Domains → pyme.internal → PYME → Usuarios →* `PYME-Usuarios-Escritorio` → **Edit**.

![GPMC: editar PYME-Usuarios-Escritorio](img/03-gpmc.png)

*User Configuration → Preferences → Windows Settings → Drive Maps → New → Mapped Drive*:

| Campo | Valor |
|---|---|
| Action | Update |
| Location | `\\DC01.pyme.internal\Datos` |
| Reconnect | ✅ |
| Label as | `Datos PYME` |
| Drive Letter | Use: `P` |

![Unidad P: \\DC01.pyme.internal\Datos](img/03-gpp-unidad.png)

### 15. Prueba en el cliente

Antes de iniciar sesión en PC01 aparece el aviso legal de la GPO de equipos:

![Aviso legal](img/03-aviso-legal.png)

Al entrar con `mpuig` se aplican el fondo corporativo y la unidad P:.

![Fondo corporativo](img/03-escritorio-fondo.png)

```
gpresult /r
```

![gpresult: PYME-Usuarios-Escritorio aplicada y grupo GG_Direccion](img/03-gpresult.png)

Gracias a la enumeración basada en acceso, cada usuario solo ve en P: las carpetas a las que tiene permiso:

| Usuario | Departamento | Ve en P: |
|---|---|---|
| mpuig | Dirección | Comun, Direccion |
| lsanz | Administración | Comun, Administracion |

![P: con mpuig](img/03-escritorio-p-mpuig.png)
![P: con lsanz](img/03-escritorio-p-lsanz.png)

### 16. Snapshot final

Snapshot `fase3-ok`, con RAM, de la VM 101 (*DC con AD DS, DNS, DHCP, OUs, usuarios y GPOs*) y de la VM 102 (*Cliente unido al dominio*).

![Snapshot fase3-ok](img/03-snapshots.png)

### Incidencias y diagnóstico

**Reloj de Proxmox desfasado.** La hora del nodo iba atrasada (más de 12 horas) y el servicio NTP no estaba sincronizado. En un dominio la hora es crítica: Kerberos rechaza los tickets si la diferencia supera los 5 minutos, y las VMs heredan la hora del host al arrancar. Arreglo desde *pve → Consola*:

```bash
timedatectl set-timezone Europe/Madrid
systemctl restart chrony
chronyc makestep
timedatectl
```

![Corrección de la hora en Proxmox](img/03-pve-hora.png)

**1.1.1.1 bloqueado en la red de casa.** Con 1.1.1.1 como DNS inicial de DC01, no había ni ping ni resolución, aunque el gateway 10.10.10.1 sí respondía.

![IP fija con DNS 1.1.1.1](img/03-ip-fija.png)
![10.10.10.1 responde, 1.1.1.1 no](img/03-conectividad-fallo.png)

Diagnóstico en el FortiGate (*CLI Console*), lanzando un ping desde DC01 mientras se captura:

```
diagnose debug reset
diagnose debug flow filter clear
diagnose debug flow filter addr 1.1.1.1
diagnose debug flow show function-name enable
diagnose debug flow trace start 20
diagnose debug enable
diagnose debug disable
```

![debug flow hacia 1.1.1.1](img/03-debug-flow.png)

El FortiGate hace bien su parte: encuentra la ruta por port1 hacia 192.168.1.1, el tráfico entra en la *Policy-1* (LAN-a-Internet) y se aplica SNAT a 192.168.1.201. Pero no vuelve ninguna respuesta. En cambio, 8.8.8.8 responde y resuelve sin problema:

![8.8.8.8 responde y resuelve](img/03-conectividad-8888.png)

Conclusión: el router o el operador de casa bloquea 1.1.1.1, no es un problema del lab. Se usa 8.8.8.8 como DNS temporal, y 8.8.8.8 y 9.9.9.9 como reenviadores.

**`dcdiag` falla en DFSREvent tras la promoción.** En el primer arranque, el servicio DFSR se inicia antes de que AD esté del todo levantado y registra el evento **6016** (error 1355, *dominio no contactable*). Poco después aparecen el **4602** (SYSVOL inicializado, miembro primario) y el **6018** (configuración actualizada correctamente). Es transitorio: el test deja de fallar cuando el error sale de la ventana de 24 horas que revisa `dcdiag`.

```powershell
Get-WinEvent -LogName "DFS Replication" -MaxEvents 10 | Format-List Id, Message
```

![Evento 6016 en el primer arranque](img/03-dfsr-6016.png)
![SYSVOL y NETLOGON compartidos, eventos 4602 y 6018](img/03-sysvol-eventos.png)

**Portapapeles de la consola noVNC.** Al pegar texto en la consola de Proxmox se duplicaban caracteres y varias líneas acababan juntas en una sola. Solución: los comandos cortos se escriben a mano, una línea cada vez, y los largos van en scripts que se descargan desde GitHub con `iwr`.

**GPMC no mostraba las GPOs.** La consola estaba abierta antes de ejecutar `03-gpo.ps1`. Se arregla refrescando con **F5**.

### Decisiones de diseño

- **`.internal` en vez de `.local`:** `.internal` es el TLD que ICANN reservó en 2024 para redes privadas. `.local` choca con mDNS/Bonjour.
- **Standard en vez de Datacenter:** los roles AD DS, DNS, DHCP y las GPOs son idénticos. Datacenter solo aporta VMs Windows ilimitadas en un host Hyper-V, S2D, SDN y Shielded VMs. Una pyme típica compra Standard (2 instancias virtuales), y aquí el hipervisor es Proxmox.
- **ISO en inglés con formato y teclado españoles:** los menús y los mensajes coinciden con la documentación oficial y con los resultados de búsqueda cuando hay errores.
- **VirtIO (SCSI single + IO thread, red VirtIO) y Guest Agent en el DC:** dispositivos paravirtualizados con el mejor rendimiento. El agente permite ver las IPs y hacer apagados limpios desde Proxmox, y lo necesitarán las copias de seguridad de la Fase 6.
- **Drivers nativos en PC01 (IDE + E1000):** el cliente solo sirve para validar el dominio, así que se priorizó instalarlo rápido sin cargar drivers. En un puesto real se usaría VirtIO igual que en el servidor. El cortafuegos de la NIC en Proxmox está marcado, pero no filtra nada porque el firewall de Proxmox no está activado a nivel de centro de datos.
- **UEFI + TPM 2.0 + Secure Boot:** requisito de Windows 11 y buena práctica en Server 2025.
- **RAM fija de 4 GB:** en un DC con Windows, el ballooning no aporta nada y puede dar problemas.
- **Direccionamiento de la LAN:** .1 el FortiGate, .2–.99 para servidores e IPs fijas (DC01 en .10) y .100–.200 para DHCP.
- **DNS del DC (su IP + 127.0.0.1) y reenviadores públicos:** los clientes solo preguntan al DC, que resuelve el dominio y reenvía lo de fuera.
- **Snapshot antes de promocionar:** permite volver atrás sin reinstalar Windows. Con un único DC, revertir no es un problema. Con varios DCs, revertir un snapshot provoca *USN rollback*, así que en producción el respaldo de un DC se hace con backups que respeten AD, no con snapshots.
- **Cuenta de administración separada (`adm.fbertomeu`):** la cuenta diaria no se usa para administrar (tiering básico), y ninguna cuenta de usuario es administradora.
- **Permisos por grupos globales de departamento**, nunca a usuarios sueltos: un alta o un cambio de puesto se resuelve cambiando la pertenencia a grupos.
- **`redircmp`:** los equipos nuevos van a `OU=Equipos`, donde se pueden vincular GPOs. Al contenedor `Computers` por defecto no se pueden vincular.
- **Papelera de reciclaje de AD:** permite recuperar objetos borrados sin hacer una restauración autoritativa.
- **Scripts idempotentes, sin contraseñas y descargados desde GitHub:** se pueden repetir sin romper nada, evitan teclear en noVNC y dejan la configuración documentada en el repositorio.
- **Carpeta compartida en el DC:** solo por los recursos limitados del lab. En producción iría en un servidor de ficheros aparte.
- **Access-Based Enumeration:** cada usuario ve solo las carpetas a las que tiene acceso.
- **Unidad P: con Preferencias de GPO** en vez de un script de inicio de sesión: se gestiona desde GPMC, sin código, y se puede filtrar por grupo si hace falta.
- **Cliente PC01:** sin un cliente, el DHCP y las GPOs solo se podrían enseñar configurados, no funcionando. Se apaga cuando no se usa para ahorrar RAM.

### Verificación

- `Get-ADDomain`: `pyme.internal`, NetBIOS `PYME`, `Windows2025Domain`. Los servicios adws, dns, kdc y Netlogon están en *Running*.
- SYSVOL y NETLOGON compartidos. `dcdiag /q` solo con el aviso transitorio de DFSREvent.
- DNS: resuelven el registro A de dc01, el SRV `_ldap._tcp.dc._msdcs`, los nombres de Internet a través de los reenviadores y el PTR de 10.10.10.10.
- DHCP autorizado en AD, ámbito `LAN-PYME` activo y PC01 con 10.10.10.100.
- PC01 unido al dominio, en `OU=Equipos`, con registro DNS dinámico, y `nltest` localiza DC01.
- Al iniciar sesión en PC01 se ven el aviso legal, el fondo corporativo y la unidad P:. `mpuig` ve *Comun + Direccion* y `lsanz` ve *Comun + Administracion*.
- Snapshots `pre-dc` (VM 101) y `fase3-ok` (VMs 101 y 102) creados.
