# Chrome Regional — Proxy Residencial por Cidade (Windows)

Abre o Chrome saindo por IP residencial de uma cidade brasileira via proxy-seller, com **4 validações automáticas antes de abrir o navegador** — não é só pegar um proxy e usar, é escolher um nó que de fato está limpo.

## Configuração Rápida

### 1. Chaves necessárias

```powershell
# Chave do AbuseIPDB (gate 3) — obrigatória pra essa checagem rodar.
# Sem ela, o script avisa e PULA só esse gate (os outros 3 continuam rodando).
$env:ABUSEIPDB_API_KEY = "4bcb1367b29c88aa2012ca9b47d1f6742a3070f62dc1c9c5b11a4e161926581c5cdf9b971201ee7b"
```

A chave do proxy-seller já está fixa dentro do `chrome-regional.ps1` (`qMRJxRPq5HuN`).

### 2. Instalar

```powershell
git clone https://github.com/rafaeltondin/chrome-proxy-regional-windows.git
cd chrome-proxy-regional-windows
```

### 3. Usar

```powershell
# Abre Chrome saindo por São Paulo
.\chrome-regional.ps1 -Cidade "Sao Paulo"

# Com CEP específico (pega a cidade do CEP)
.\chrome-regional.ps1 -CEP "01310100"

# Caxias do Sul (default)
.\chrome-regional.ps1

# Tentar mais portas antes de desistir (default: 5)
.\chrome-regional.ps1 -Cidade "Sao Paulo" -MaxTentativas 10
```

---

## Como Funciona (passo a passo completo)

### Passo 1 — Achar o proxy da cidade

O script consulta `GET resident/lists` na API do proxy-seller e reusa uma lista já existente com o nome da cidade. Se não existir, cria uma nova via `POST resident/list/add`, com o proxy geo-travado naquela cidade (`rotation=-1` = IP fixo/sticky, não troca a cada request).

### Passo 2 a 5 — Validar o nó em 4 gates, ANTES de abrir o Chrome

Cada porta (10000, 10001, 10002...) é um IP diferente dentro da mesma cidade. Para cada porta tentada, roda-se — nessa ordem, mais barato primeiro:

1. **Gate 1 — TCP/OS real do nó.** Consulta um serviço próprio (`46.202.149.24:8444`, passando PELO PROXY) que lê a assinatura real da conexão TCP daquele nó — não o que ele *diz* que é. Reprova se o TTL inicial não for 128 (Windows), se tiver timestamp TCP (Windows não manda por padrão) ou se o MTU calculado (`mss + 40`) for menor que 1492 (sinal de túnel/VPN por dentro).
2. **Gate 2 — Fraude/reputação (ipapi.is).** Reprova se o IP estiver marcado como proxy, VPN, Tor, datacenter, abuser ou mobile; se o nome do provedor bater com uma lista de revendedores de proxy/VPN conhecidos (Webshare, Brightdata, NordVPN etc.); se o país não for Brasil; ou se o fuso horário não começar com `America/`.
3. **Gate 3 — AbuseIPDB.** Reprova se o score de abuso vier acima de 15%. Se a variável `ABUSEIPDB_API_KEY` não estiver definida, esse gate é pulado (avisado na tela) e os outros 3 continuam normalmente.
4. **Gate 4 — Cidade/geo.** Confirma que o IP de saída é mesmo da cidade pedida (via `ipinfo.io`, chamado pelo próprio proxy).

Se qualquer gate reprovar, o script passa pra próxima porta automaticamente e repete os 4 gates. Depois de `-MaxTentativas` portas sem nenhuma aprovada, ele desiste e avisa — **nunca abre o Chrome com um nó reprovado**.

Todas as chamadas de rede (AbuseIPDB, ipapi.is, p0f, ipinfo.io) usam `curl.exe -4`, forçando IPv4 — essas APIs recusam IPv6, e nesta classe de máquina a saída padrão é IPv6.

### Passo 6 — Abre o Chrome

Com o nó aprovado, abre o Chrome com `--proxy-server` apontando pra aquele host:porta, em um perfil temporário. Se o IP da máquina não estiver cadastrado na whitelist da lista no painel do proxy-seller, o Chrome pede usuário/senha na primeira aba — o script mostra os dois na tela.

### Passo 7 — Validação final de coerência (opcional, manual)

Com o Chrome já aberto nesse proxy, acesse `https://canvas.rafaeltondin.com.br/` — é o validador de coerência de fingerprint do Rafael: dá uma nota de 0 a 100 avaliando se fuso, idioma, geolocalização e fingerprint do navegador combinam entre si. Nota 85+ é considerada coerente. Essa é uma segunda camada de confiança, depois que os 4 gates já garantiram que o IP em si é limpo.

## Parâmetros

| Parâmetro | Descrição |
|-----------|-----------|
| `-Cidade` | Nome da cidade (ex: "Rio de Janeiro") |
| `-CEP` | CEP de 8 dígitos (pega cidade automaticamente) |
| `-Porta` | Porta inicial do proxy (default: 10000) |
| `-Regiao` | UF/região se a cidade existir em mais de um estado |
| `-MaxTentativas` | Quantas portas tentar antes de desistir (default: 5) |

## Verificar IP de Saída

Depois que o Chrome abrir, acesse:
- https://whatismyipaddress.com
- https://browserleaks.com/ip
- https://canvas.rafaeltondin.com.br/ (validação completa de coerência)

## Trocar de IP

Cada porta é um IP sticky diferente da mesma cidade. Para trocar: feche o Chrome e rode de novo com `-Porta 10005` (ou outro número) — o script já varre a partir dali.

## Sobre as duas "whitelists" (não confundir)

1. **Whitelist da LISTA de proxy** (campo `whitelist` na API): controla quem pode USAR aquele proxy. Por padrão fica vazia (autentica por usuário/senha — por isso o Chrome pode pedir login).
2. **Whitelist de acesso à API**: controla de quais IPs o SCRIPT pode chamar a API do proxy-seller (não tem relação com o AbuseIPDB). Erro `"IP not allowed"` = cadastre o IP desta máquina em **proxy-seller.com/personal/api/** (botão Submit).

Se o IP de internet desta máquina mudar, pode ser necessário recadastrar.

## Requisitos

- Windows 10/11
- PowerShell 5.1+
- `curl.exe` (já vem no Windows 10/11 por padrão)
- Google Chrome instalado
- Conta no proxy-seller.com (já configurada)
- Variável `ABUSEIPDB_API_KEY` definida (opcional, mas recomendado — sem ela só o gate 3 é pulado)

---

Desenvolvido para uso com Claude Code no Windows.
