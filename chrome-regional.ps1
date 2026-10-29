<#
.SYNOPSIS
    Abre Chrome com proxy residencial de uma cidade brasileira, validado por 4 gates
    (TCP/OS real, fraude/reputacao, AbuseIPDB, geo) antes de abrir o navegador.

.PARAMETER Cidade
    Nome da cidade (ex: "Sao Paulo", "Rio de Janeiro").

.PARAMETER CEP
    CEP de 8 digitos (pega cidade automaticamente).

.PARAMETER Porta
    Porta inicial do proxy (default: 10000). Cada porta = 1 IP sticky diferente.

.PARAMETER Regiao
    UF/regiao se a cidade existir em mais de um estado.

.PARAMETER MaxTentativas
    Quantas portas tentar antes de desistir (default: 5).

.EXAMPLE
    .\chrome-regional.ps1 -Cidade "Sao Paulo"

.EXAMPLE
    .\chrome-regional.ps1 -CEP "01310100"

.NOTES
    Antes de rodar, defina a variavel de ambiente ABUSEIPDB_API_KEY:
      $env:ABUSEIPDB_API_KEY = "sua-chave-aqui"
#>

param(
    [string]$Cidade = "",
    [string]$CEP = "",
    [int]$Porta = 10000,
    [string]$Regiao = "",
    [int]$MaxTentativas = 5
)

$ErrorActionPreference = "Stop"

# API Key do proxy-seller
$API_KEY = "qMRJxRPq5HuN"
$BASE_URL = "https://proxy-seller.com/personal/api/v1/$API_KEY"

# Chave do AbuseIPDB - NAO fixa no script. Defina antes de rodar:
#   $env:ABUSEIPDB_API_KEY = "..."
$ABUSEIPDB_KEY = $env:ABUSEIPDB_API_KEY

# Endpoint p0f proprio (le a assinatura TCP real do no, atraves do proxy).
$TCPOS_ENDPOINT = "http://46.202.149.24:8444/?raw=1"

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

function Get-Norm {
    param([string]$texto)
    $texto = $texto.ToLower()
    $texto = $texto -replace '[áàâãä]', 'a' -replace '[éèêë]', 'e' -replace '[íìîï]', 'i' `
                    -replace '[óòôõö]', 'o' -replace '[úùûü]', 'u' -replace '[ç]', 'c'
    return ($texto -replace '[^a-z0-9]', '')
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

# Mapa UF -> nome de regiao EXATO do dataset do proxy-seller (geo.json).
# A API exige o nome por extenso com acento (DF e excecao: "Federal District" em ingles).
$UF_TO_REGION = @{
    "AC"="Acre"; "AL"="Alagoas"; "AP"="Amapá"; "AM"="Amazonas"; "BA"="Bahia"; "CE"="Ceará"
    "DF"="Federal District"; "ES"="Espírito Santo"; "GO"="Goiás"; "MA"="Maranhão"; "MT"="Mato Grosso"
    "MS"="Mato Grosso do Sul"; "MG"="Minas Gerais"; "PA"="Pará"; "PB"="Paraíba"; "PR"="Paraná"
    "PE"="Pernambuco"; "PI"="Piauí"; "RJ"="Rio de Janeiro"; "RN"="Rio Grande do Norte"
    "RS"="Rio Grande do Sul"; "RO"="Rondônia"; "RR"="Roraima"; "SC"="Santa Catarina"
    "SP"="São Paulo"; "SE"="Sergipe"; "TO"="Tocantins"
}

# Provedores de proxy/VPN conhecidos - reprova se o nome da empresa/ASN do IP contiver algum destes.
$PROXY_PROVIDER_BLOCKLIST = @(
    "webshare","brightdata","bright data","luminati","oxylabs","smartproxy","packetstream",
    "iproyal","soax","netnut","proxyrack","proxy-seller","pia s.p.a","datacamp","m247",
    "nordvpn","expressvpn","surfshark","mullvad","private internet access","vpn"
)

function Get-IpViaProxy {
    # Descobre IP/cidade/regiao de saida do proxy chamando ipinfo.io PELO PROXY, com curl.exe -4
    # (Invoke-RestMethod sai por IPv6 nesta classe de maquina e a API recusa).
    param([string]$login, [string]$pass, [string]$proxyHost, [int]$porta)
    try {
        $proxyArg = "http://${login}:${pass}@${proxyHost}:${porta}"
        $json = & curl.exe -4 -s -m 15 -x $proxyArg "https://ipinfo.io/json" 2>$null
        if (-not $json) { return $null }
        return $json | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Test-TcpSignature {
    # GATE 1 - le a assinatura TCP REAL do no (nao so o que ele diz que e) via endpoint p0f proprio,
    # passando PELO PROXY. Windows de verdade: TTL inicial 128, SEM timestamps TCP, MTU (mss+40) >= 1492.
    param([string]$login, [string]$pass, [string]$proxyHost, [int]$porta)

    $resultado = @{ Aprovado = $true; Motivo = "sem assinatura (fail-open)" }

    try {
        $proxyArg = "http://${login}:${pass}@${proxyHost}:${porta}"
        $raw = & curl.exe -4 -s -m 6 -x $proxyArg $TCPOS_ENDPOINT 2>$null
        if (-not $raw) {
            $resultado.Motivo = "endpoint p0f nao respondeu (fail-open)"
            return $resultado
        }
        $dados = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $dados) {
            $resultado.Motivo = "resposta invalida do p0f (fail-open)"
            return $resultado
        }

        $ttl = $dados.ttl_inicial
        $mss = $dados.mss
        $opts = [string]$dados.ordem_opcoes_tcp

        if ($ttl) {
            if ([int]$ttl -ne 128) {
                $resultado.Aprovado = $false
                $resultado.Motivo = "TTL inicial $ttl (esperado 128 = Windows; 64 = Linux disfarcado)"
                return $resultado
            }
        }
        if ($opts -match '(^|,)ts(,|$)') {
            $resultado.Aprovado = $false
            $resultado.Motivo = "tem timestamp TCP (Windows nao manda por padrao - no e Linux/outro disfarcado)"
            return $resultado
        }
        if ($mss) {
            $mtu = [int]$mss + 40
            if ($mtu -lt 1492) {
                $resultado.Aprovado = $false
                $resultado.Motivo = "MTU $mtu (<1492 = tunel/VPN por dentro)"
                return $resultado
            }
            $resultado.Motivo = "TTL $ttl, sem timestamp, MTU $mtu - OK"
        } else {
            $resultado.Motivo = "TTL $ttl, sem timestamp - OK (sem MSS pra checar MTU)"
        }
        return $resultado
    } catch {
        $resultado.Motivo = "erro ao consultar p0f (fail-open): $_"
        return $resultado
    }
}

function Test-FraudClean {
    # GATE 2 - reputacao/fraude do IP via ipapi.is. Reprova proxy/vpn/tor/datacenter/abuser/mobile,
    # provedor de proxy conhecido, pais != BR, ou fuso fora de America/*.
    param([string]$ip)

    $resultado = @{ Aprovado = $true; Motivo = "sem dado (fail-open)" }
    if (-not $ip) { return $resultado }

    try {
        $raw = & curl.exe -4 -s -m 10 "https://api.ipapi.is/?q=$ip" 2>$null
        if (-not $raw) { return $resultado }
        $d = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $d) { return $resultado }

        $motivos = @()
        foreach ($campo in @("is_proxy","is_vpn","is_tor","is_datacenter","is_abuser","is_mobile")) {
            if ($d.$campo -eq $true) { $motivos += $campo }
        }

        $empresa = ""
        if ($d.company) { $empresa += [string]$d.company }
        if ($d.asn) { $empresa += " " + [string]$d.asn }
        $empresaLower = $empresa.ToLower()
        foreach ($bloqueado in $PROXY_PROVIDER_BLOCKLIST) {
            if ($empresaLower -like "*$bloqueado*") { $motivos += "proxy_provider=$bloqueado"; break }
        }

        $cc = ""
        if ($d.location -and $d.location.country_code) { $cc = [string]$d.location.country_code }
        elseif ($d.country_code) { $cc = [string]$d.country_code }
        if ($cc -and $cc.ToUpper() -ne "BR") { $motivos += "geo_cc=$cc" }

        $tz = ""
        if ($d.location -and $d.location.timezone) { $tz = [string]$d.location.timezone }
        elseif ($d.timezone) { $tz = [string]$d.timezone }
        if ($tz -and -not $tz.StartsWith("America/")) { $motivos += "geo_tz=$tz" }

        if ($motivos.Count -gt 0) {
            $resultado.Aprovado = $false
            $resultado.Motivo = ($motivos -join "; ")
        } else {
            $resultado.Motivo = "limpo (pais=$cc fuso=$tz)"
        }
        return $resultado
    } catch {
        return $resultado
    }
}

function Test-AbuseIPDB {
    # GATE 3 - reputacao de abuso (AbuseIPDB). Reprova se score > 15.
    param([string]$ip)

    $resultado = @{ Aprovado = $true; Score = 0; Motivo = "sem chave configurada (pulado)" }
    if (-not $ABUSEIPDB_KEY) { return $resultado }
    if (-not $ip) { return $resultado }

    try {
        $raw = & curl.exe -4 -s -G "https://api.abuseipdb.com/api/v2/check" `
            --data-urlencode "ipAddress=$ip" -d "maxAgeInDays=90" `
            -H "Key: $ABUSEIPDB_KEY" -H "Accept: application/json" -m 12 2>$null
        if (-not $raw) { $resultado.Motivo = "sem resposta (fail-open)"; return $resultado }
        $d = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $d -or -not $d.data) { $resultado.Motivo = "resposta invalida (fail-open)"; return $resultado }

        $score = [int]$d.data.abuseConfidenceScore
        $resultado.Score = $score
        if ($score -gt 15) {
            $resultado.Aprovado = $false
            $resultado.Motivo = "score $score% (> 15)"
        } else {
            $resultado.Motivo = "score $score% (OK)"
        }
        return $resultado
    } catch {
        $resultado.Motivo = "erro ao consultar AbuseIPDB (fail-open): $_"
        return $resultado
    }
}

function Test-CidadeOk {
    # GATE 4 - confere se a cidade/regiao de saida bate com o pedido.
    param([object]$ipInfo, [string]$cidadeAlvo)
    if (-not $ipInfo -or -not $ipInfo.city) {
        return @{ Aprovado = $true; Motivo = "sem dado de cidade (fail-open)" }
    }
    $cidadeNormAlvo = Get-Norm $cidadeAlvo
    $cidadeNormReal = Get-Norm $ipInfo.city
    if ($cidadeNormReal -eq $cidadeNormAlvo -or $cidadeNormReal -like "*$cidadeNormAlvo*" -or $cidadeNormAlvo -like "*$cidadeNormReal*") {
        return @{ Aprovado = $true; Motivo = "cidade $($ipInfo.city)/$($ipInfo.region) - OK" }
    }
    return @{ Aprovado = $false; Motivo = "saiu em $($ipInfo.city)/$($ipInfo.region), esperava $cidadeAlvo" }
}

function Get-ProxyList {
    param([string]$cidade, [string]$uf, [int]$portaInicial, [int]$maxTentativas)

    Write-Log "Buscando lista de proxy para '$cidade'..."
    $cidadeNorm = Get-Norm $cidade
    $login = $null; $pass = $null

    # 1) Reusa lista ativa existente com o mesmo nome de cidade.
    try {
        $lists = Invoke-RestMethod -Uri "$BASE_URL/resident/lists" -TimeoutSec 30
        foreach ($list in $lists.data) {
            $titleNorm = Get-Norm $list.title
            if ($titleNorm -like "*$cidadeNorm*") {
                Write-Log "Reusando lista existente: $($list.title) (id $($list.id))" "OK"
                $login = $list.login; $pass = $list.password
                break
            }
        }
    } catch {
        Write-Log "Erro ao buscar listas (resident/lists): $_" "WARN"
    }

    # 2) Nao achou -> cria nova lista. Endpoint CORRETO: POST resident/list/add, "geo" ANINHADO.
    if (-not $login) {
        $regiaoCompleta = $uf
        if ($uf.Length -eq 2 -and $UF_TO_REGION.ContainsKey($uf.ToUpper())) {
            $regiaoCompleta = $UF_TO_REGION[$uf.ToUpper()]
        }
        Write-Log "Criando nova lista para '$cidade' ($regiaoCompleta)..."
        $body = @{
            title = "$cidade-$(Get-Date -Format 'yyyyMMddHHmmss')"
            geo = @{ country = "BR"; region = $regiaoCompleta; city = $cidade; isp = "" }
            export = @{ ports = 1; ext = "txt" }
            rotation = -1
            whitelist = ""
        } | ConvertTo-Json -Depth 5

        try {
            $createResponse = Invoke-RestMethod -Uri "$BASE_URL/resident/list/add" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30
            if ($createResponse.errors) {
                Write-Log "API devolveu erro: $($createResponse.errors | ConvertTo-Json -Compress)" "ERROR"
                Write-Log "Dica: erro 'IP not allowed' = o IP desta maquina precisa estar na whitelist da API (nao da lista). Cadastre em proxy-seller.com/personal/api/" "WARN"
                return $null
            }
            $login = $createResponse.data.login
            $pass  = $createResponse.data.password
            if (-not $login -or -not $pass) {
                Write-Log "Resposta sem login/senha: $($createResponse | ConvertTo-Json -Compress)" "ERROR"
                return $null
            }
            Write-Log "Lista criada (id $($createResponse.data.id)) - aguardando propagacao (pode levar de 50s a 2min)..."
            Start-Sleep -Seconds 50
        } catch {
            Write-Log "Erro ao criar lista: $_" "ERROR"
            return $null
        }
    }

    # 3) Varre portas aplicando os 4 gates, na ordem (mais barato primeiro).
    Write-Log "Validando nos (4 gates: TCP/OS, fraude, AbuseIPDB, cidade) a partir da porta $portaInicial..."
    for ($i = 0; $i -lt $maxTentativas; $i++) {
        $porta = $portaInicial + $i
        Write-Host ""
        Write-Log "--- Tentativa $($i+1)/$maxTentativas: porta $porta ---" "INFO"

        $ipInfo = Get-IpViaProxy -login $login -pass $pass -proxyHost "res.proxy-seller.com" -porta $porta
        if (-not $ipInfo) {
            Write-Log "Porta $porta: sem resposta do proxy (pode estar propagando ainda) - pulando" "WARN"
            continue
        }
        $ip = $ipInfo.ip
        Write-Log "Porta $porta: IP $ip ($($ipInfo.city)/$($ipInfo.region))" "INFO"

        $g1 = Test-TcpSignature -login $login -pass $pass -proxyHost "res.proxy-seller.com" -porta $porta
        Write-Log "  Gate 1 (TCP/OS real): $(if ($g1.Aprovado) {'APROVADO'} else {'REPROVADO'}) - $($g1.Motivo)" $(if ($g1.Aprovado) {"OK"} else {"WARN"})
        if (-not $g1.Aprovado) { continue }

        $g2 = Test-FraudClean -ip $ip
        Write-Log "  Gate 2 (fraude/ipapi.is): $(if ($g2.Aprovado) {'APROVADO'} else {'REPROVADO'}) - $($g2.Motivo)" $(if ($g2.Aprovado) {"OK"} else {"WARN"})
        if (-not $g2.Aprovado) { continue }

        $g3 = Test-AbuseIPDB -ip $ip
        Write-Log "  Gate 3 (AbuseIPDB): $(if ($g3.Aprovado) {'APROVADO'} else {'REPROVADO'}) - $($g3.Motivo)" $(if ($g3.Aprovado) {"OK"} else {"WARN"})
        if (-not $g3.Aprovado) { continue }

        $g4 = Test-CidadeOk -ipInfo $ipInfo -cidadeAlvo $cidade
        Write-Log "  Gate 4 (cidade/geo): $(if ($g4.Aprovado) {'APROVADO'} else {'REPROVADO'}) - $($g4.Motivo)" $(if ($g4.Aprovado) {"OK"} else {"WARN"})
        if (-not $g4.Aprovado) { continue }

        Write-Host ""
        Write-Log "NO APROVADO: porta $porta | IP $ip | TCP Windows confirmado | fraude limpa | AbuseIPDB $($g3.Score)% | cidade OK" "OK"
        return @{ Login = $login; Password = $pass; Porta = $porta; Ip = $ip }
    }

    Write-Host ""
    Write-Log "Nenhum no passou nos 4 gates em $maxTentativas tentativas (portas $portaInicial..$($portaInicial+$maxTentativas-1))." "ERROR"
    return $null
}

function Start-ChromeWithProxy {
    param(
        [string]$proxyHost,
        [int]$proxyPort,
        [string]$proxyUser,
        [string]$proxyPass,
        [string]$cidade
    )

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

    $profileDir = "$env:TEMP\chrome-regional-$cidade-$(Get-Date -Format 'HHmmss')"
    $proxyUrl = "http://${proxyUser}:${proxyPass}@${proxyHost}:${proxyPort}"

    Write-Log "Abrindo Chrome..."
    Write-Log "  Proxy: ${proxyHost}:${proxyPort}" "INFO"
    Write-Log "  Cidade: $cidade" "INFO"
    Write-Log "  Perfil: $profileDir" "INFO"

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
    Write-Host "Se o Chrome pedir usuario/senha do proxy:" -ForegroundColor Yellow
    Write-Host "  Usuario: $proxyUser"
    Write-Host "  Senha: $proxyPass"
    Write-Host ""
    Write-Host "Validacao final de coerencia (opcional): abra https://canvas.rafaeltondin.com.br/ nessa mesma janela." -ForegroundColor Cyan
    Write-Host ""

    Start-Process -FilePath $chromePath -ArgumentList $chromeArgs
}

# === MAIN ===

Write-Host ""
Write-Host "=== Chrome Regional (com validacao de 4 gates) ===" -ForegroundColor Cyan
Write-Host ""

if (-not $ABUSEIPDB_KEY) {
    Write-Log "ABUSEIPDB_API_KEY nao definida - o gate 3 (AbuseIPDB) vai ser pulado. Defina com: `$env:ABUSEIPDB_API_KEY = '...'" "WARN"
}

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

$proxy = Get-ProxyList -cidade $Cidade -uf $Regiao -portaInicial $Porta -maxTentativas $MaxTentativas
if (-not $proxy) {
    Write-Log "Nao consegui obter um nó aprovado para '$Cidade'" "ERROR"
    exit 1
}

Start-ChromeWithProxy -proxyHost "res.proxy-seller.com" -proxyPort $proxy.Porta -proxyUser $proxy.Login -proxyPass $proxy.Password -cidade $Cidade
