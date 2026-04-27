# PVE SaaS — Painel de Eventos Proxmox

Painel multi-tenant para receber e monitorar eventos de ambientes Proxmox via webhook, com notificações por Telegram.

---

## Estrutura

```
bkpproxmox/
├── install-saas.sh
└── panel/
    ├── main.py
    ├── requirements.txt
    └── templates/
        └── index.html
```

---

## Instalação

```bash
curl -fsSL https://raw.githubusercontent.com/redsolucoesti-boop/bkpproxmox/main/install-saas.sh | sudo bash
```

**Credenciais padrão:**
- Usuário: `admin`
- Senha: `ChangeMe123!`

> ⚠️ Troque a senha imediatamente após o primeiro login criando um novo usuário admin e excluindo o padrão.

---

## Segurança implementada

| Antes | Depois |
|---|---|
| SHA-256 sem salt | bcrypt com salt automático |
| Sessões em dict na memória | JWT com expiração (8h) |
| API sem autenticação | Bearer token obrigatório em todas as rotas |
| Webhook sem validação | Secret por cliente via `X-Webhook-Secret` |
| Admin/admin hardcoded | Senha forte padrão + aviso para trocar |
| `requests` bloqueante | `httpx` assíncrono |
| Sem paginação | Paginação com `limit` e `offset` |
| SQLite com connection leak | Context manager `with sqlite3.connect()` |
| Uvicorn exposto na internet | Bind em 127.0.0.1 + Nginx como proxy |
| Processo rodando como root | Usuário `www-data` com hardening systemd |

---

## Uso do Webhook

Ao criar um cliente, você recebe um **webhook_secret**. Use-o assim:

```bash
curl -X POST https://SEU_SERVIDOR/webhook/1 \
  -H "Content-Type: application/json" \
  -H "X-Webhook-Secret: SEU_SECRET_AQUI" \
  -d '{"hostname": "pve-node1", "msg": "Backup concluído"}'
```

O sistema detecta automaticamente eventos de erro se o payload contiver palavras como `error`, `failed`, `falhou` ou `critical`.

---

## Roles

| Role | Permissões |
|---|---|
| `admin` | CRUD de clientes, usuários e leitura de eventos |
| `viewer` | Apenas leitura de eventos |

---

## Variáveis de ambiente recomendadas (produção)

Para não gerar um `SECRET_KEY` novo a cada restart (que invalida todos os tokens), exporte:

```bash
# /etc/systemd/system/pve-saas.service
[Service]
Environment="JWT_SECRET=sua_chave_aleatoria_aqui_32_chars"
```

E em `main.py`, troque:
```python
SECRET_KEY = secrets.token_hex(32)
# por:
SECRET_KEY = os.environ.get("JWT_SECRET", secrets.token_hex(32))
```
