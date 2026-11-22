<#
.SYNOPSIS
    Políticas de grupo y recurso compartido de la pyme simulada (homelab-pyme, Fase 3).

.DESCRIPTION
    1. Política de contraseñas y bloqueo de cuentas del dominio.
    2. Carpeta compartida \\DC01\Datos con una carpeta por departamento (permisos NTFS
       por grupo GG_*) y enumeración basada en acceso: cada usuario solo ve lo suyo.
    3. Fondo de escritorio corporativo generado en NETLOGON.
    4. GPO PYME-Equipos-Seguridad   (OU=Equipos):  bloqueo por inactividad y aviso legal.
    5. GPO PYME-Usuarios-Escritorio (OU=Usuarios): fondo de escritorio.
       La unidad de red P: se añade a mano en esta GPO (Preferencias), ver la guía.

    Es idempotente: se puede ejecutar varias veces.

.EXAMPLE
    .\03-gpo.ps1
#>

#Requires -Modules ActiveDirectory, GroupPolicy
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory, GroupPolicy

$domain    = Get-ADDomain
$domainDN  = $domain.DistinguishedName
$netbios   = $domain.NetBIOSName
$rootOU    = "OU=PYME,$domainDN"
$departamentos = 'Direccion', 'Administracion', 'Comercial', 'Produccion'

function Write-Step($text) { Write-Host "`n$text" -ForegroundColor Cyan }
function Write-Ok($text)   { Write-Host "  + $text" -ForegroundColor Green }
function Write-Skip($text) { Write-Host "  = $text" -ForegroundColor DarkGray }

function Get-OrCreateGPO {
    param([string]$Name, [string]$Comment, [string]$LinkTarget)
    $gpo = Get-GPO -Name $Name -ErrorAction SilentlyContinue
    if ($gpo) { Write-Skip "GPO $Name ya existe" }
    else {
        $gpo = New-GPO -Name $Name -Comment $Comment
        Write-Ok "GPO $Name creada"
    }
    $linked = (Get-GPInheritance -Target $LinkTarget).GpoLinks | Where-Object DisplayName -eq $Name
    if ($linked) { Write-Skip "Ya vinculada a $LinkTarget" }
    else {
        New-GPLink -Name $Name -Target $LinkTarget -LinkEnabled Yes | Out-Null
        Write-Ok "Vinculada a $LinkTarget"
    }
    return $gpo
}

# --- 1. Política de contraseñas y bloqueo -----------------------------------------

Write-Step '[1/5] Politica de contrasenas y bloqueo de cuentas (dominio)'
Set-ADDefaultDomainPasswordPolicy -Identity $domain.DNSRoot `
    -MinPasswordLength 12 -ComplexityEnabled $true -PasswordHistoryCount 10 `
    -MaxPasswordAge 180.00:00:00 -MinPasswordAge 1.00:00:00 `
    -LockoutThreshold 5 -LockoutDuration 00:15:00 -LockoutObservationWindow 00:15:00
Get-ADDefaultDomainPasswordPolicy |
    Format-List MinPasswordLength, ComplexityEnabled, PasswordHistoryCount, MaxPasswordAge,
                LockoutThreshold, LockoutDuration

# --- 2. Carpeta compartida Datos ---------------------------------------------------

Write-Step '[2/5] Carpeta compartida \\DC01\Datos'
$dataPath = 'C:\Shares\Datos'
foreach ($folder in @('Comun') + $departamentos) {
    $p = Join-Path $dataPath $folder
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null; Write-Ok "Carpeta $p" }
    else { Write-Skip "Carpeta $p ya existe" }
}

# Raíz: sin herencia. Admins y SYSTEM control total; Domain Users solo puede listar la raíz.
icacls $dataPath /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" "$netbios\Domain Users:RX" | Out-Null
# Comun: todos los usuarios modifican.
icacls (Join-Path $dataPath 'Comun') /grant:r "$netbios\Domain Users:(OI)(CI)M" | Out-Null
# Departamentos: solo su grupo modifica.
foreach ($d in $departamentos) {
    icacls (Join-Path $dataPath $d) /grant:r "$netbios\GG_${d}:(OI)(CI)M" | Out-Null
}
Write-Ok 'Permisos NTFS aplicados'

if (Get-SmbShare -Name 'Datos' -ErrorAction SilentlyContinue) { Write-Skip 'Recurso Datos ya existe' }
else {
    New-SmbShare -Name 'Datos' -Path $dataPath -FolderEnumerationMode AccessBased `
                 -FullAccess "$netbios\Domain Admins" -ChangeAccess "$netbios\Domain Users" `
                 -Description 'Datos de la empresa' | Out-Null
    Write-Ok 'Recurso \\DC01\Datos creado (Access-Based Enumeration activada)'
}

# --- 3. Fondo de escritorio corporativo ------------------------------------------------

Write-Step '[3/5] Fondo de escritorio corporativo'
$netlogon  = "C:\Windows\SYSVOL\sysvol\$($domain.DNSRoot)\scripts"
$wallLocal = Join-Path $netlogon 'fondo-pyme.jpg'
$wallUNC   = "\\$($domain.DNSRoot)\NETLOGON\fondo-pyme.jpg"

Add-Type -AssemblyName System.Drawing
$bmp  = New-Object System.Drawing.Bitmap 1920, 1080
$g    = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode     = 'AntiAlias'
$g.TextRenderingHint = 'AntiAliasGridFit'
$rect  = New-Object System.Drawing.Rectangle 0, 0, 1920, 1080
$c1    = [System.Drawing.Color]::FromArgb(12, 28, 56)
$c2    = [System.Drawing.Color]::FromArgb(28, 96, 150)
$brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush -ArgumentList $rect, $c1, $c2, 35.0
$g.FillRectangle($brush, $rect)
$fTitle = New-Object System.Drawing.Font 'Segoe UI', 88, ([System.Drawing.FontStyle]::Bold)
$fSub   = New-Object System.Drawing.Font 'Segoe UI', 28
$g.DrawString('PYME', $fTitle, [System.Drawing.Brushes]::White, 110, 740)
$g.DrawString("$($domain.DNSRoot)   |   Soporte IT: ext. 100", $fSub, [System.Drawing.Brushes]::Gainsboro, 122, 900)
$bmp.Save($wallLocal, [System.Drawing.Imaging.ImageFormat]::Jpeg)
$g.Dispose(); $bmp.Dispose()
Write-Ok "Fondo guardado en $wallUNC"

# --- 4. GPO de equipos ----------------------------------------------------------------

Write-Step '[4/5] GPO PYME-Equipos-Seguridad'
$gpoEq = Get-OrCreateGPO -Name 'PYME-Equipos-Seguridad' -LinkTarget "OU=Equipos,$rootOU" `
                         -Comment 'Bloqueo por inactividad (15 min) y aviso legal al iniciar sesion'
$sysKey = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System'
Set-GPRegistryValue -Name $gpoEq.DisplayName -Key $sysKey -ValueName 'InactivityTimeoutSecs' -Type DWord  -Value 900 | Out-Null
Set-GPRegistryValue -Name $gpoEq.DisplayName -Key $sysKey -ValueName 'LegalNoticeCaption'    -Type String -Value 'PYME - Uso autorizado' | Out-Null
Set-GPRegistryValue -Name $gpoEq.DisplayName -Key $sysKey -ValueName 'LegalNoticeText'       -Type String `
    -Value 'Este equipo es propiedad de PYME. Su uso esta limitado a personal autorizado y puede ser monitorizado.' | Out-Null
Write-Ok 'Bloqueo a los 900 s y aviso legal configurados'

# --- 5. GPO de usuarios ---------------------------------------------------------------

Write-Step '[5/5] GPO PYME-Usuarios-Escritorio'
$gpoUs = Get-OrCreateGPO -Name 'PYME-Usuarios-Escritorio' -LinkTarget "OU=Usuarios,$rootOU" `
                         -Comment 'Fondo corporativo y unidad P: (Datos)'
$userKey = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System'
Set-GPRegistryValue -Name $gpoUs.DisplayName -Key $userKey -ValueName 'Wallpaper'      -Type String -Value $wallUNC | Out-Null
Set-GPRegistryValue -Name $gpoUs.DisplayName -Key $userKey -ValueName 'WallpaperStyle' -Type String -Value '4' | Out-Null
Write-Ok 'Fondo de escritorio configurado (estilo: rellenar)'

# --- Resumen ----------------------------------------------------------------------------

Write-Step 'Resumen de GPOs vinculadas'
foreach ($ou in "OU=Equipos,$rootOU", "OU=Usuarios,$rootOU") {
    $links = (Get-GPInheritance -Target $ou).GpoLinks.DisplayName -join ', '
    Write-Host ("  {0,-45} -> {1}" -f $ou, $links)
}
Write-Host "`nSiguiente paso: anadir la unidad P: (\\DC01\Datos) en PYME-Usuarios-Escritorio > Preferencias > Asignaciones de unidades." -ForegroundColor Yellow
