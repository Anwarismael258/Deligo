param(
  [string]$ProjectUrl = $env:SUPABASE_URL,
  [string]$ServiceRoleKey = $env:SUPABASE_SERVICE_ROLE_KEY,
  [string]$AnonKey = $env:SUPABASE_ANON_KEY,
  [string]$AdminEmail = $env:ORDER_OPS_ADMIN_EMAIL,
  [string]$AdminPassword = $env:ORDER_OPS_ADMIN_PASSWORD,
  [string]$AdminAccessToken = $env:ADMIN_ACCESS_TOKEN,
  [int]$DispatchLimit = 25,
  [bool]$ProcessDispatches = $true
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectUrl)) {
  throw 'Defina SUPABASE_URL ou passe -ProjectUrl.'
}

if ($DispatchLimit -lt 1) {
  throw 'DispatchLimit deve ser >= 1.'
}

function Get-AdminAccessToken {
  if (-not [string]::IsNullOrWhiteSpace($AdminAccessToken)) {
    return $AdminAccessToken.Trim()
  }

  if (-not [string]::IsNullOrWhiteSpace($ServiceRoleKey)) {
    Write-Host 'A usar SUPABASE_SERVICE_ROLE_KEY como bearer para order-ops-sweep.' -ForegroundColor Yellow
    return $ServiceRoleKey.Trim()
  }

  if ([string]::IsNullOrWhiteSpace($AnonKey)) {
    throw 'Defina SUPABASE_SERVICE_ROLE_KEY, ADMIN_ACCESS_TOKEN ou SUPABASE_ANON_KEY para autenticar.'
  }

  if ([string]::IsNullOrWhiteSpace($AdminEmail)) {
    throw 'Defina ORDER_OPS_ADMIN_EMAIL ou passe -AdminEmail.'
  }

  if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
    throw 'Defina ORDER_OPS_ADMIN_PASSWORD ou passe -AdminPassword.'
  }

  $tokenUri = ($ProjectUrl.TrimEnd('/')) + '/auth/v1/token?grant_type=password'
  Write-Host "A obter token fresco para $AdminEmail" -ForegroundColor Cyan

  $session = Invoke-RestMethod `
    -Uri $tokenUri `
    -Method Post `
    -Headers @{
      apikey = $AnonKey
    } `
    -ContentType 'application/json' `
    -Body (@{
      email = $AdminEmail
      password = $AdminPassword
    } | ConvertTo-Json -Depth 4)

  $token = [string]$session.access_token
  if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'Nao foi possivel obter access_token do admin.'
  }

  return $token
}

$uri = ($ProjectUrl.TrimEnd('/')) + '/functions/v1/order-ops-sweep'
$body = @{
  process_dispatches = $ProcessDispatches
  dispatch_limit = $DispatchLimit
}
$resolvedAccessToken = Get-AdminAccessToken

Write-Host "Chamando $uri" -ForegroundColor Cyan
Write-Host "process_dispatches=$ProcessDispatches dispatch_limit=$DispatchLimit" -ForegroundColor Cyan

$response = Invoke-RestMethod `
  -Uri $uri `
  -Method Post `
  -Headers @{
    apikey = if ([string]::IsNullOrWhiteSpace($AnonKey)) { $resolvedAccessToken } else { $AnonKey }
    Authorization = "Bearer $resolvedAccessToken"
  } `
  -ContentType 'application/json' `
  -Body ($body | ConvertTo-Json -Depth 4)

$response | ConvertTo-Json -Depth 8
