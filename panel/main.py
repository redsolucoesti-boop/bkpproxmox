import sqlite3
import datetime
import secrets
import httpx
import bcrypt

from fastapi import FastAPI, Request, Form, HTTPException, Depends, Header
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from jose import JWTError, jwt
from typing import Optional

app = FastAPI(title="PVE SaaS Panel")

DB = "/opt/pve-saas/db.sqlite"
SECRET_KEY = secrets.token_hex(32)   # gerado a cada restart; troque por variável de ambiente em produção
ALGORITHM = "HS256"
TOKEN_EXPIRE_HOURS = 8


# ───────── DATABASE ─────────

def get_db():
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


def init_db():
    with sqlite3.connect(DB) as conn:
        c = conn.cursor()
        c.executescript("""
        CREATE TABLE IF NOT EXISTS users (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            password TEXT NOT NULL,
            role     TEXT NOT NULL DEFAULT 'viewer'
        );
        CREATE TABLE IF NOT EXISTS clients (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            name             TEXT NOT NULL,
            webhook_secret   TEXT NOT NULL,
            telegram_token   TEXT,
            telegram_chat_id TEXT
        );
        CREATE TABLE IF NOT EXISTS events (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            client_id  INTEGER NOT NULL,
            hostname   TEXT,
            status     TEXT,
            message    TEXT,
            created_at TEXT NOT NULL,
            FOREIGN KEY (client_id) REFERENCES clients(id)
        );
        """)
        # Cria admin padrão apenas se não existir
        c.execute("SELECT id FROM users WHERE username='admin'")
        if not c.fetchone():
            hashed = bcrypt.hashpw(b"ChangeMe123!", bcrypt.gensalt()).decode()
            c.execute(
                "INSERT INTO users (username, password, role) VALUES (?, ?, ?)",
                ("admin", hashed, "admin"),
            )
        conn.commit()


init_db()


# ───────── AUTH HELPERS ─────────

def create_jwt(user_id: int, username: str, role: str) -> str:
    expire = datetime.datetime.utcnow() + datetime.timedelta(hours=TOKEN_EXPIRE_HOURS)
    return jwt.encode(
        {"sub": str(user_id), "username": username, "role": role, "exp": expire},
        SECRET_KEY,
        algorithm=ALGORITHM,
    )


def decode_jwt(token: str) -> dict:
    try:
        return jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
    except JWTError:
        raise HTTPException(status_code=401, detail="Token inválido ou expirado")


def get_current_user(authorization: Optional[str] = Header(None)) -> dict:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Token não fornecido")
    return decode_jwt(authorization.split(" ", 1)[1])


def require_admin(user: dict = Depends(get_current_user)) -> dict:
    if user.get("role") != "admin":
        raise HTTPException(status_code=403, detail="Acesso restrito a administradores")
    return user


# ───────── STATIC / FRONTEND ─────────

app.mount("/static", StaticFiles(directory="/opt/pve-saas/static"), name="static")


@app.get("/", response_class=HTMLResponse)
def home():
    return open("/opt/pve-saas/templates/index.html").read()


# ───────── LOGIN ─────────

@app.post("/login")
async def login(username: str = Form(...), password: str = Form(...)):
    with sqlite3.connect(DB) as conn:
        conn.row_factory = sqlite3.Row
        c = conn.cursor()
        c.execute("SELECT id, password, role FROM users WHERE username=?", (username,))
        row = c.fetchone()

    if not row or not bcrypt.checkpw(password.encode(), row["password"].encode()):
        raise HTTPException(status_code=401, detail="Credenciais inválidas")

    token = create_jwt(row["id"], username, row["role"])
    return {"token": token, "role": row["role"], "username": username}


# ───────── USUÁRIOS (admin only) ─────────

@app.get("/api/users")
def list_users(admin: dict = Depends(require_admin)):
    with sqlite3.connect(DB) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute("SELECT id, username, role FROM users").fetchall()
    return [dict(r) for r in rows]


@app.post("/api/users")
async def create_user(request: Request, admin: dict = Depends(require_admin)):
    data = await request.json()
    username = data.get("username", "").strip()
    password = data.get("password", "")
    role = data.get("role", "viewer")

    if not username or not password:
        raise HTTPException(status_code=400, detail="username e password são obrigatórios")
    if role not in ("admin", "viewer"):
        raise HTTPException(status_code=400, detail="role deve ser 'admin' ou 'viewer'")

    hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
    try:
        with sqlite3.connect(DB) as conn:
            conn.execute(
                "INSERT INTO users (username, password, role) VALUES (?, ?, ?)",
                (username, hashed, role),
            )
    except sqlite3.IntegrityError:
        raise HTTPException(status_code=409, detail="Usuário já existe")
    return {"ok": True}


@app.delete("/api/users/{user_id}")
def delete_user(user_id: int, admin: dict = Depends(require_admin)):
    if str(user_id) == admin["sub"]:
        raise HTTPException(status_code=400, detail="Não é possível deletar a si mesmo")
    with sqlite3.connect(DB) as conn:
        conn.execute("DELETE FROM users WHERE id=?", (user_id,))
    return {"ok": True}


# ───────── CLIENTES (admin only) ─────────

@app.get("/api/clients")
def list_clients(admin: dict = Depends(require_admin)):
    with sqlite3.connect(DB) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT id, name, webhook_secret, telegram_token, telegram_chat_id FROM clients"
        ).fetchall()
    return [dict(r) for r in rows]


@app.post("/api/clients")
async def create_client(request: Request, admin: dict = Depends(require_admin)):
    data = await request.json()
    name = data.get("name", "").strip()
    if not name:
        raise HTTPException(status_code=400, detail="name é obrigatório")

    webhook_secret = secrets.token_urlsafe(32)
    with sqlite3.connect(DB) as conn:
        cur = conn.execute(
            "INSERT INTO clients (name, webhook_secret, telegram_token, telegram_chat_id) VALUES (?, ?, ?, ?)",
            (name, webhook_secret, data.get("telegram_token"), data.get("telegram_chat_id")),
        )
        client_id = cur.lastrowid
    return {"id": client_id, "name": name, "webhook_secret": webhook_secret}


@app.delete("/api/clients/{client_id}")
def delete_client(client_id: int, admin: dict = Depends(require_admin)):
    with sqlite3.connect(DB) as conn:
        conn.execute("DELETE FROM events WHERE client_id=?", (client_id,))
        conn.execute("DELETE FROM clients WHERE id=?", (client_id,))
    return {"ok": True}


# ───────── EVENTOS (autenticado) ─────────

@app.get("/api/events/{client_id}")
def get_events(
    client_id: int,
    page: int = 1,
    limit: int = 50,
    user: dict = Depends(get_current_user),
):
    if limit > 200:
        limit = 200
    offset = (page - 1) * limit

    with sqlite3.connect(DB) as conn:
        conn.row_factory = sqlite3.Row
        # verifica se cliente existe
        client = conn.execute("SELECT id, name FROM clients WHERE id=?", (client_id,)).fetchone()
        if not client:
            raise HTTPException(status_code=404, detail="Cliente não encontrado")

        rows = conn.execute(
            """SELECT hostname, status, message, created_at
               FROM events WHERE client_id=?
               ORDER BY id DESC LIMIT ? OFFSET ?""",
            (client_id, limit, offset),
        ).fetchall()
        total = conn.execute(
            "SELECT COUNT(*) FROM events WHERE client_id=?", (client_id,)
        ).fetchone()[0]

    return {
        "client": dict(client),
        "total": total,
        "page": page,
        "limit": limit,
        "events": [
            {"host": r["hostname"], "status": r["status"], "msg": r["message"], "time": r["created_at"]}
            for r in rows
        ],
    }


# ───────── WEBHOOK (sem JWT — usa webhook_secret por cliente) ─────────

@app.post("/webhook/{client_id}")
async def webhook(client_id: int, request: Request):
    # Valida o secret enviado no header X-Webhook-Secret
    incoming_secret = request.headers.get("X-Webhook-Secret", "")

    with sqlite3.connect(DB) as conn:
        conn.row_factory = sqlite3.Row
        client = conn.execute(
            "SELECT webhook_secret, telegram_token, telegram_chat_id FROM clients WHERE id=?",
            (client_id,),
        ).fetchone()

    if not client:
        raise HTTPException(status_code=404, detail="Cliente não encontrado")

    if not secrets.compare_digest(incoming_secret, client["webhook_secret"]):
        raise HTTPException(status_code=403, detail="Secret inválido")

    try:
        data = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="JSON inválido")

    text = str(data)
    status = "error" if any(x in text.lower() for x in ["error", "falhou", "failed", "critical"]) else "ok"

    with sqlite3.connect(DB) as conn:
        conn.execute(
            """INSERT INTO events (client_id, hostname, status, message, created_at)
               VALUES (?, ?, ?, ?, ?)""",
            (client_id, data.get("hostname", ""), status, text, datetime.datetime.utcnow().isoformat()),
        )

    # Notifica Telegram de forma assíncrona (não bloqueia)
    if client["telegram_token"] and client["telegram_chat_id"]:
        try:
            async with httpx.AsyncClient(timeout=5) as http:
                await http.post(
                    f"https://api.telegram.org/bot{client['telegram_token']}/sendMessage",
                    json={"chat_id": client["telegram_chat_id"], "text": text[:4000]},
                )
        except Exception:
            pass  # notificação é best-effort

    return {"ok": True}


# ───────── HEALTH ─────────

@app.get("/health")
def health():
    return {"status": "ok", "ts": datetime.datetime.utcnow().isoformat()}
