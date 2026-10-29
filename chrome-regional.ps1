<#
.SYNOPSIS
    Abre Chrome com proxy residencial de uma cidade brasileira.

.PARAMETER Cidade
    Nome da cidade (ex: "Sao Paulo", "Rio de Janeiro").

.PARAMETER CEP
    CEP de 8 dígitos (pega cidade automaticamente).

.PARAMETER Porta
    Porta do proxy (default: 10000). Cada porta = 1 IP sticky.

.PARAMETER Regiao
    UF/região se a cidade existir em mais de um estado.

.EXAMPLE
    .\chrome-regional.ps1 -Cidade "Sao Paulo"

.EXAMPLE
    .\chrome-regional.ps1 -CEP "01310100"
#>

param(
    [string]$Cidade = "",
    [string]$CEP = "",
    [int]$Porta = 10000,
    [string]$Regiao = ""
)

$ErrorActionPreference = "Stop"

# API Key do proxy-seller
$API_KEY = "qMRJxRPq5HuN"
$BASE_URL = "https://proxy-seller.com/personal/api/v1/$API_KEY"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Level) {
        "INFO"  { "Cyan" }
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "White" }
    }
    Write-Host "[$timestamp][$Level] $Message" -ForegroundColor $color
}

function Get-CidadeFromCEP {
    param([string]$cep)
    $cep = $cep -replace '\D', ''
    if ($cep.Length -ne 8) {
        Write-Log "CEP invalido: $cep (deve ter 8 digitos)" "ERROR"
        return $null
    }
    try {
        $response = Invoke-RestMethod -Uri "https://viacep.com.br/ws/$cep/json/" -TimeoutSec 10
        if ($response.erro) {
            Write-Log "CEP nao encontrado: $cep" "ERROR"
            return $null
        }
        return @{
            Cidade = $response.localidade
            UF = $response.uf
        }
    } catch {
        Write-Log "Erro ao consultar CEP: $_" "ERROR"
        return $null
    }
}

function Get-ProxyList {
    param([string]$cidade, [string]$regiao)

    Write-Log "Buscando lista de proxy para '$cidade'..."

    # Verifica se já existe uma lista ativa
    try {
        $lists = Invoke-RestMethod -Uri "$BASE_URL/resident/list" -TimeoutSec 30
        $cidadeNorm = $cidade.ToLower() -replace '[^a-z0-9]', ''

        foreach ($list in $lists.data) {
            if ($list.status -eq "active") {
                $titleNorm = $list.title.ToLower() -replace '[^a-z0-9]', ''
                if ($titleNorm -like "*$cidadeNorm*") {
                    Write-Log "Reusando lista existente: $($list.title)" "OK"
                    return @{
                        Login = $list.login
                        Password = $list.password
                    }
                }
            }
        }
    } catch {
        Write-Log "Erro ao buscar listas: $_" "WARN"
    }

    # Cria nova lista
    Write-Log "Criando nova lista para '$cidade'..."

    $body = @{
        title = "$cidade-$(Get-Date -Format 'yyyyMMdd')"
        country = "BR"
        city = $cidade
        rotation = -1  # Sticky
        protocol = "http"
    }
    if ($regiao) { $body.region = $regiao }

    try {
        $createResponse = Invoke-RestMethod -Uri "$BASE_URL/resident/list" -Method Post -Body ($body | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 30

        if (-not $createResponse.data.id) {
            Write-Log "Erro ao criar lista: $($createResponse | ConvertTo-Json)" "ERROR"
            return $null
        }

        $listId = $createResponse.data.id
        Write-Log "Lista criada (id: $listId), aguardando ativacao..."

        # Aguarda lista ficar ativa
        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Seconds 3
            $checkResponse = Invoke-RestMethod -Uri "$BASE_URL/resident/list/$listId" -TimeoutSec 15
            if ($checkResponse.data.status -eq "active") {
                Write-Log "Lista ativa!" "OK"
                return @{
                    Login = $checkResponse.data.login
                    Password = $checkResponse.data.password
                }
            }
            Write-Host "." -NoNewline
        }

        Write-Log "Lista nao ativou em tempo" "ERROR"
        return $null

    } catch {
        Write-Log "Erro ao criar lista: $_" "ERROR"
        return $null
    }
}

function Start-ChromeWithProxy {
    param(
        [string]$proxyHost,
        [int]$proxyPort,
        [string]$proxyUser,
        [string]$proxyPass,
        [string]$cidade
    )

    # Encontra o Chrome
    $chromePaths = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )

    $chromePath = $chromePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $chromePath) {
        Write-Log "Chrome nao encontrado!" "ERROR"
        Write-Host "Instale o Google Chrome em: https://www.google.com/chrome/"
        return
    }

    # Cria perfil temporario
    $profileDir = "$env:TEMP\chrome-regional-$cidade-$(Get-Date -Format 'HHmmss')"

    # Monta URL do proxy com autenticacao
    $proxyUrl = "http://${proxyUser}:${proxyPass}@${proxyHost}:${proxyPort}"

    Write-Log "Abrindo Chrome..."
    Write-Log "  Proxy: ${proxyHost}:${proxyPort}" "INFO"
    Write-Log "  Cidade: $cidade" "INFO"
    Write-Log "  Perfil: $profileDir" "INFO"

    # Inicia o Chrome
    $chromeArgs = @(
        "--proxy-server=http://${proxyHost}:${proxyPort}",
        "--user-data-dir=$profileDir",
        "--no-first-run",
        "--disable-blink-features=AutomationControlled",
        "https://whatismyipaddress.com"
    )

    Write-Host ""
    Write-Host "=== CHROME ABERTO ===" -ForegroundColor Green
    Write-Host "Cidade: $cidade"
    Write-Host "Proxy: ${proxyHost}:${proxyPort}"
    Write-Host ""
    Write-Host "IMPORTANTE: O Chrome vai pedir usuario/senha do proxy:" -ForegroundColor Yellow
    Write-Host "  Usuario: $proxyUser"
    Write-Host "  Senha: $proxyPass"
    Write-Host ""

    Start-Process -FilePath $chromePath -ArgumentList $chromeArgs
}

# === MAIN ===

Write-Host ""
Write-Host "=== Chrome Regional ===" -ForegroundColor Cyan
Write-Host ""

# Determina cidade
if ($CEP) {
    $cepInfo = Get-CidadeFromCEP -cep $CEP
    if (-not $cepInfo) { exit 1 }
    $Cidade = $cepInfo.Cidade
    $Regiao = $cepInfo.UF
    Write-Log "CEP $CEP = $Cidade/$Regiao" "OK"
}

if (-not $Cidade) {
    $Cidade = "Caxias do Sul"
    $Regiao = "RS"
    Write-Log "Usando cidade default: $Cidade/$Regiao" "INFO"
}

# Busca/cria lista de proxy
$proxy = Get-ProxyList -cidade $Cidade -regiao $Regiao
if (-not $proxy) {
    Write-Log "Nao consegui obter proxy para '$Cidade'" "ERROR"
    exit 1
}

# Abre Chrome
Start-ChromeWithProxy -proxyHost "res.proxy-seller.com" -proxyPort $Porta -proxyUser $proxy.Login -proxyPass $proxy.Password -cidade $Cidade
