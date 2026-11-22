<#
.SYNOPSIS
    Crea la estructura de Active Directory de la pyme simulada (homelab-pyme, Fase 3).

.DESCRIPTION
    - Activa la Papelera de reciclaje de AD.
    - Crea las OUs bajo OU=PYME (usuarios por departamento, equipos, servidores, grupos, admins).
    - Crea un grupo global de seguridad por departamento.
    - Crea usuarios de ejemplo y los mete en su grupo.
    - Crea una cuenta de administración separada (tiering básico) en Domain Admins.

    Es idempotente: si un objeto ya existe, lo salta.
    No contiene contraseñas: pide la contraseña inicial al ejecutarlo y obliga
    a cambiarla en el primer inicio de sesión.

.EXAMPLE
    .\03-ad-estructura.ps1
#>

#Requires -Modules ActiveDirectory
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

$domain     = Get-ADDomain
$domainDN   = $domain.DistinguishedName      # DC=pyme,DC=internal
$upnSuffix  = $domain.DNSRoot                # pyme.internal
$rootOU     = "OU=PYME,$domainDN"

# --- Datos ------------------------------------------------------------------

$departamentos = 'Direccion', 'Administracion', 'Comercial', 'Produccion'

$usuarios = @(
    @{ Nombre='Marta'; Apellido='Puig';  Sam='mpuig';  Depto='Direccion';      Cargo='Gerente' }
    @{ Nombre='Jordi'; Apellido='Ferre'; Sam='jferre'; Depto='Administracion'; Cargo='Responsable de administracion' }
    @{ Nombre='Laura'; Apellido='Sanz';  Sam='lsanz';  Depto='Administracion'; Cargo='Contable' }
    @{ Nombre='Pau';   Apellido='Roca';  Sam='proca';  Depto='Comercial';      Cargo='Comercial' }
    @{ Nombre='Anna';  Apellido='Vidal'; Sam='avidal'; Depto='Comercial';      Cargo='Comercial' }
    @{ Nombre='Marc';  Apellido='Gil';   Sam='mgil';   Depto='Produccion';     Cargo='Jefe de taller' }
    @{ Nombre='Nuria'; Apellido='Font';  Sam='nfont';  Depto='Produccion';     Cargo='Operaria' }
)

$adminIT = @{ Nombre='Ferran'; Apellido='Bertomeu (admin)'; Sam='adm.fbertomeu'; Cargo='Tecnico de sistemas' }

# --- Funciones auxiliares -----------------------------------------------------

function New-OUIfMissing {
    param([string]$Name, [string]$Path)
    $dn = "OU=$Name,$Path"
    if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue) {
        Write-Host "  = OU $dn ya existe" -ForegroundColor DarkGray
    } else {
        New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $true
        Write-Host "  + OU $dn" -ForegroundColor Green
    }
}

function New-GroupIfMissing {
    param([string]$Name, [string]$Path, [string]$Description)
    if (Get-ADGroup -Filter "SamAccountName -eq '$Name'" -ErrorAction SilentlyContinue) {
        Write-Host "  = Grupo $Name ya existe" -ForegroundColor DarkGray
    } else {
        New-ADGroup -Name $Name -SamAccountName $Name -GroupScope Global -GroupCategory Security `
                    -Path $Path -Description $Description
        Write-Host "  + Grupo $Name" -ForegroundColor Green
    }
}

function New-UserIfMissing {
    param([hashtable]$U, [string]$Path, [securestring]$Password, [string]$Department)
    if (Get-ADUser -Filter "SamAccountName -eq '$($U.Sam)'" -ErrorAction SilentlyContinue) {
        Write-Host "  = Usuario $($U.Sam) ya existe" -ForegroundColor DarkGray
        return
    }
    $display = "$($U.Nombre) $($U.Apellido)"
    New-ADUser -Name $display -DisplayName $display `
               -GivenName $U.Nombre -Surname $U.Apellido `
               -SamAccountName $U.Sam -UserPrincipalName "$($U.Sam)@$upnSuffix" `
               -Title $U.Cargo -Department $Department -Company 'PYME' `
               -Path $Path -AccountPassword $Password `
               -ChangePasswordAtLogon $true -Enabled $true
    Write-Host "  + Usuario $($U.Sam)" -ForegroundColor Green
}

# --- 1. Papelera de reciclaje de AD ---------------------------------------------

Write-Host "`n[1/5] Papelera de reciclaje de AD" -ForegroundColor Cyan
$recycle = Get-ADOptionalFeature -Filter "Name -eq 'Recycle Bin Feature'"
if ($recycle.EnabledScopes.Count -gt 0) {
    Write-Host "  = Ya estaba activada" -ForegroundColor DarkGray
} else {
    Enable-ADOptionalFeature 'Recycle Bin Feature' -Scope ForestOrConfigurationSet `
                             -Target $domain.Forest -Confirm:$false
    Write-Host "  + Activada" -ForegroundColor Green
}

# --- 2. OUs ---------------------------------------------------------------------

Write-Host "`n[2/5] Unidades organizativas" -ForegroundColor Cyan
New-OUIfMissing -Name 'PYME' -Path $domainDN
foreach ($ou in 'Usuarios', 'Equipos', 'Servidores', 'Grupos', 'Admins') {
    New-OUIfMissing -Name $ou -Path $rootOU
}
foreach ($d in $departamentos) {
    New-OUIfMissing -Name $d -Path "OU=Usuarios,$rootOU"
}

# --- 3. Grupos --------------------------------------------------------------------

Write-Host "`n[3/5] Grupos de seguridad" -ForegroundColor Cyan
foreach ($d in $departamentos) {
    New-GroupIfMissing -Name "GG_$d" -Path "OU=Grupos,$rootOU" -Description "Usuarios del departamento de $d"
}

# --- 4. Usuarios --------------------------------------------------------------------

Write-Host "`n[4/5] Usuarios" -ForegroundColor Cyan
$initialPwd = Read-Host -AsSecureString 'Contrasena inicial para los usuarios (se pedira cambiarla al iniciar sesion)'

foreach ($u in $usuarios) {
    New-UserIfMissing -U $u -Path "OU=$($u.Depto),OU=Usuarios,$rootOU" -Password $initialPwd -Department $u.Depto
    Add-ADGroupMember -Identity "GG_$($u.Depto)" -Members $u.Sam
}

# --- 5. Cuenta de administracion separada ------------------------------------------------

Write-Host "`n[5/5] Cuenta de administracion de IT" -ForegroundColor Cyan
New-UserIfMissing -U $adminIT -Path "OU=Admins,$rootOU" -Password $initialPwd -Department 'IT'
Add-ADGroupMember -Identity 'Domain Admins' -Members $adminIT.Sam

# --- Resumen -------------------------------------------------------------------------------

Write-Host "`nResumen" -ForegroundColor Cyan
Get-ADUser -Filter * -SearchBase $rootOU -Properties Department, Title |
    Sort-Object Department, SamAccountName |
    Format-Table SamAccountName, Name, Department, Title -AutoSize

foreach ($d in $departamentos) {
    $miembros = (Get-ADGroupMember "GG_$d" | Select-Object -ExpandProperty SamAccountName) -join ', '
    Write-Host ("GG_{0,-15} -> {1}" -f $d, $miembros)
}
