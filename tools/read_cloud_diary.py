#!/usr/bin/env python3
"""Чтение облачной копии Nial Diary помощником Computer (только чтение).

Шаг 1 — вход (пароль подставляет защищённое хранилище, в коде его нет):
    pplx credentials run <handle для identitytoolkit.googleapis.com> -- \
        python3 tools/read_cloud_diary.py login
Шаг 2 — загрузка записей (обычный запуск, без обёртки):
    python3 tools/read_cloud_diary.py fetch --out /tmp/nial_diary_entries.json

Учётная запись читателя может только читать: менять и удалять записи
ей запрещено правилами безопасности Firestore.
"""
import argparse
import json
import os
import sys
import urllib.parse

API_KEY = "AIzaSyCH59yPHh2TBzeyoZX89hRIa2RWA8--9sA"
PROJECT = "nial-diary-43dfa"
READER_EMAIL = "computer-reader@nial-diary.invalid"
TOKEN_FILE = "/tmp/.nial_diary_reader_token"
BASE = (
    "https://firestore.googleapis.com/v1/projects/"
    f"{PROJECT}/databases/(default)/documents"
)


def _request(url, data=None, token=None):
    # requests корректно работает через защищённый прокси Computer.
    import requests

    headers = {"Authorization": f"Bearer {token}"} if token else {}
    if data is None:
        response = requests.get(url, headers=headers, timeout=30)
    else:
        response = requests.post(url, json=data, headers=headers, timeout=30)
    if response.status_code != 200:
        sys.exit(f"HTTP {response.status_code}: {response.text[:300]}")
    return response.json()


def login():
    url = (
        "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword"
        f"?key={API_KEY}"
    )
    data = _request(url, {"email": READER_EMAIL, "returnSecureToken": True})
    descriptor = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        handle.write(data["idToken"])
    print("Вход выполнен. Токен действует около часа.")


def _value(field):
    for kind, value in field.items():
        if kind == "integerValue":
            return int(value)
        return value
    return None


def _list(path, token):
    documents, page = [], None
    while True:
        query = {"pageSize": "300"}
        if page:
            query["pageToken"] = page
        data = _request(f"{BASE}/{path}?{urllib.parse.urlencode(query)}", token=token)
        documents += data.get("documents", [])
        page = data.get("nextPageToken")
        if not page:
            return documents


def fetch(out):
    if not os.path.exists(TOKEN_FILE):
        sys.exit("Сначала выполни шаг login.")
    token = open(TOKEN_FILE).read().strip()
    result = []
    for user in _list("users", token):
        uid = user["name"].rsplit("/", 1)[-1]
        meta = {k: _value(v) for k, v in user.get("fields", {}).items()}
        entries = []
        for document in _list(f"users/{uid}/entries", token):
            entry = {k: _value(v) for k, v in document.get("fields", {}).items()}
            entry["id"] = document["name"].rsplit("/", 1)[-1]
            entries.append(entry)
        entries.sort(key=lambda item: item.get("date", ""), reverse=True)
        result.append({"uid": uid, "meta": meta, "entries": entries})
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(result, handle, ensure_ascii=False, indent=1)
    for copy in result:
        print(
            f"Копия {copy['uid']}: записей {len(copy['entries'])}, "
            f"обновлена {copy['meta'].get('updatedAt', 'неизвестно')}"
        )
    print(f"Сохранено в {out}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("login")
    fetcher = commands.add_parser("fetch")
    fetcher.add_argument("--out", default="/tmp/nial_diary_entries.json")
    arguments = parser.parse_args()
    login() if arguments.command == "login" else fetch(arguments.out)
