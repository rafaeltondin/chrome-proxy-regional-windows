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

# Mapa UF -> nome de região EXATO do dataset do proxy-seller (geo.json).
# A API exige o nome por extenso com acento (DF é excecao: "Federal District" em ingles).
$UF_TO_REGION = @{
    "AC"="Acre"; "AL"="Alagoas"; "AP"="Amapá"; "AM"="Amazonas"; "BA"="Bahia"; "CE"="Ceará"
    "DF"="Federal District"; "ES"="Espírito Santo"; "GO"="Goiás"; "MA"="Maranhão"; "MT"="Mato Grosso"
    "MS"="Mato Grosso do Sul"; "MG"="Minas Gerais"; "PA"="Pará"; "PB"="Paraíba"; "PR"="Paraná"
    "PE"="Pernambuco"; "PI"="Piauí"; "RJ"="Rio de Janeiro"; "RN"="Rio Grande do Norte"
    "RS"="Rio Grande do Sul"; "RO"="Rondônia"; "RR"="Roraima"; "SC"="Santa Catarina"
    "SP"="São Paulo"; "SE"="Sergipe"; "TO"="Tocantins"
}

function Test-ProxyAtivo {
    # Confere se o proxy já autentica e devolve IP via ipinfo, pelo PROPRIO proxy.
    # Enquanto a lista está propagando, o gateway devolve 407 (nao "pronto").
    param([string]$login, [string]$pass, [int]$porta)
    try {
        $cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${login}:${pass}"))
        $headers = @{ "Proxy-Authorization" = "Basic $cred" }
        $proxyUri = "http://res.proxy-seller.com:$porta"
        $resp = Invoke-RestMethod -Uri "https://ipinfo.io/json" -Proxy $proxyUri -ProxyUseDefaultCredentials:$false -Headers $headers -TimeoutSec 15
        return $resp
    } catch {
        return $null
    }
}

function Get-ProxyList {
    param([string]$cidade, [string]$uf, [int]$porta)

    Write-Log "Buscando lista de proxy para '$cidade'..."

    # 1) Reusa lista ativa existente com o mesmo nome de cidade
    #    Endpoint correto: GET resident/lists (plural) — resident/list (singular) nao existe.
    try {
        $lists = Invoke-RestMethod -Uri "$BASE_URL/resident/lists" -TimeoutSec 30
        $cidadeNorm = $cidade.ToLower() -replace '[^a-z0-9]', ''

        foreach ($list in $lists.data) {
            $titleNorm = $list.title.ToLower() -replace '[^a-z0-9]', ''
            if ($titleNorm -like "*$cidadeNorm*") {
                Write-Log "Reusando lista existente: $($list.title) (id $($list.id))" "OK"
                $probe = Test-ProxyAtivo -login $list.login -pass $list.password -porta $porta
                if ($probe) {
                    Write-Log "Proxy ja ativo: IP $($probe.ip) ($($probe.city)/$($probe.region))" "OK"
                    return @{ Login = $list.login; Password = $list.password }
                }
                Write-Log "Lista existe mas proxy nao respondeu (pode estar propagando) — seguindo com ela mesmo assim" "WARN"
                return @{ Login = $list.login; Password = $list.password }
            }
        }
    } catch {
        Write-Log "Erro ao buscar listas (resident/lists): $_" "WARN"
    }

    # 2) Resolve nome da regiao (a API exige o nome completo com acento, nao a sigla UF)
    $regiaoCompleta = $uf
    if ($uf.Length -eq 2 -and $UF_TO_REGION.ContainsKey($uf.ToUpper())) {
        $regiaoCompleta = $UF_TO_REGION[$uf.ToUpper()]
    }

    # 3) Cria nova lista — endpoint CORRETO: POST resident/list/add, com "geo" ANINHADO
    #    (nao campos country/city soltos). rotation=-1 = IP sticky (fixo até o nó cair).
    #    whitelist="" = autentica por login/senha (sem travar por IP de origem).
    Write-Log "Criando nova lista para '$cidade' ($regiaoCompleta)..."

    $body = @{
        title = "$cidade-$(Get-Date -Format 'yyyyMMddHHmmss')"
        geo = @{
            country = "BR"
            region  = $regiaoCompleta
            city    = $cidade
            isp     = ""
        }
        export = @{ ports = 1; ext = "txt" }
        rotation = -1
        whitelist = ""
    } | ConvertTo-Json -Depth 5

    try {
        $createResponse = Invoke-RestMethod -Uri "$BASE_URL/resident/list/add" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30

        if ($createResponse.errors) {
            Write-Log "API devolveu erro: $($createResponse.errors | ConvertTo-Json -Compress)" "ERROR"
            Write-Log "Dica: erro 'IP not allowed' = o IP desta máquina precisa estar na whitelist da API (nao da lista). Cadastre em proxy-seller.com/personal/api/" "WARN"
            return $null
        }

        $login = $createResponse.data.login
        $pass  = $createResponse.data.password
        $listId = $createResponse.data.id

        if (-not $login -or -not $pass) {
            Write-Log "Resposta sem login/senha: $($createResponse | ConvertTo-Json -Compress)" "ERROR"
            return $null
        }

        Write-Log "Lista criada (id $listId) — aguardando propagacao (pode levar de 50s a 2min)..."

        # Ativação NÃO é um campo "status" pra consultar — tem que TESTAR o proxy direto.
        for ($i = 0; $i -lt 24; $i++) {
            Start-Sleep -Seconds 5
            $probe = Test-ProxyAtivo -login $login -pass $pass -porta $porta
            if ($probe) {
                Write-Log "Proxy ativo! IP $($probe.ip) — $($probe.city)/$($probe.region)" "OK"
                return @{ Login = $login; Password = $pass }
            }
            Write-Host "." -NoNewline
        }

        Write-Log "" "INFO"
        Write-Log "Lista criada mas nao propagou em 2min. Pode ainda ativar sozinha — tente abrir o Chrome mesmo assim." "WARN"
        return @{ Login = $login; Password = $pass }

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
$proxy = Get-ProxyList -cidade $Cidade -uf $Regiao -porta $Porta
if (-not $proxy) {
    Write-Log "Nao consegui obter proxy para '$Cidade'" "ERROR"
    exit 1
}

# Abre Chrome
Start-ChromeWithProxy -proxyHost "res.proxy-seller.com" -proxyPort $Porta -proxyUser $proxy.Login -proxyPass $proxy.Password -cidade $Cidade
