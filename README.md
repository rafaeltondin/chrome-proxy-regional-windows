# Chrome Regional — Proxy Residencial por Cidade (Windows)

Abre o Chrome saindo por IP residencial de uma cidade brasileira via proxy-seller.

## Configuração Rápida

### 1. API Key do proxy-seller

```
qMRJxRPq5HuN
```

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
```

---

## Como Funciona

1. O script consulta a API do proxy-seller (`resident/lists` / `resident/list/add`) e cria (ou reusa) uma lista residencial com geo travado na cidade
2. Aguarda a lista propagar (50s a 2min) testando o proxy de verdade, não só consultando "status"
3. Abre o Chrome com proxy configurado (cada porta = 1 IP sticky diferente)
4. O Chrome vai pedir usuário/senha do proxy na primeira aba — digite os dados que aparecem no terminal

## IMPORTANTE — Dois tipos de "whitelist" diferentes (não confundir)

1. **Whitelist da LISTA de proxy**: controla quem pode USAR aquele proxy. Por padrão o script deixa vazia (autentica por usuário/senha, por isso o Chrome pede login).
2. **Whitelist de acesso à API**: controla de quais IPs o SCRIPT pode chamar a API do proxy-seller. Se der erro `"IP not allowed"`, é esta que falta — cadastre o IP da máquina que roda o script em **proxy-seller.com/personal/api/** (botão Submit). Para saber o IP: https://whatismyipaddress.com

Se seu IP de internet mudar, pode voltar a dar esse erro — basta recadastrar o IP novo na mesma página.

## Parâmetros

| Parâmetro | Descrição |
|-----------|-----------|
| `-Cidade` | Nome da cidade (ex: "Rio de Janeiro") |
| `-CEP` | CEP de 8 dígitos (pega cidade automaticamente) |
| `-Porta` | Porta do proxy (default: 10000, cada porta = 1 IP) |
| `-Regiao` | UF/região se a cidade existir em mais de um estado |

## Verificar IP de Saída

Após abrir o Chrome, acesse:
- https://whatismyipaddress.com
- https://browserleaks.com/ip

O IP deve mostrar a cidade escolhida.

## Trocar de IP

Cada porta (10000, 10001, 10002...) é um IP sticky diferente da mesma cidade.
Para trocar: feche o Chrome e abra novamente com `-Porta 10001` (ou outro número).

## Requisitos

- Windows 10/11
- PowerShell 5.1+
- Google Chrome instalado
- Conta no proxy-seller.com (já configurada)

---

Desenvolvido para uso com Claude Code no Windows.
