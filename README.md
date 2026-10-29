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

1. O script consulta a API do proxy-seller e cria uma lista residencial na cidade
2. Abre o Chrome com proxy configurado (cada porta = 1 IP sticky diferente)
3. O Chrome sai pela rede residencial daquela cidade

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
