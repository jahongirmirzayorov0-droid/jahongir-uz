#!/usr/bin/env python3
"""Milliy bank (NBU) valyuta ayirboshlash kurslarini nbu_rates.json ga yozadi.

nbu.uz'ning ochiq API'si yo'q, shuning uchun kurslar bank.uz'dagi NBU
sahifasidan olinadi. GitHub Actions orqali har soatda ishga tushadi
(.github/workflows/update-rates.yml). Faqat standart kutubxona ishlatiladi.
Sahifa tuzilishi o'zgarib, kurs topilmasa, eski fayl o'zgarmay qoladi.
"""
import json
import re
import sys
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

SOURCE_URL = "https://bank.uz/uz/currency/bank/nbu"
CODES = ["USD", "EUR", "RUB", "GBP"]
TASHKENT = timezone(timedelta(hours=5))
OUT = Path(__file__).resolve().parent.parent / "nbu_rates.json"

CODE = re.compile(r'country-flag[^>]*></span>\s*([A-Z]{3})\s*<')
BUY = re.compile(r'Sotib olish</span>\s*<span class="medium-text">\s*([\d\s]+?)\s*</span>')
SELL = re.compile(r'Sotish</span>\s*<span class="medium-text">\s*([\d\s]+?)\s*</span>')
TIME = re.compile(r'green-date">\s*(\d{2}\.\d{2}\.\d{4}\s+\d{2}:\d{2})\s*<')


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "mmoliya.uz-rates-bot/1.0 (+https://mmoliya.uz)"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8", errors="replace")


def to_number(text):
    return int(re.sub(r"\s+", "", text))


def parse(page):
    # Kurslar jadvali "Yangilanish vaqti" sarlavhasidan keyin keladi
    start = page.find("table-kurs")
    if start < 0:
        return {}
    rates = {}
    for block in page[start:].split('<div class="row">')[1:]:
        code, buy, sell, time = CODE.search(block), BUY.search(block), SELL.search(block), TIME.search(block)
        if not (code and buy and sell):
            continue
        if code.group(1) in CODES and code.group(1) not in rates:
            rates[code.group(1)] = {
                "buy": to_number(buy.group(1)),
                "sell": to_number(sell.group(1)),
                "time": re.sub(r"\s+", " ", time.group(1)) if time else "",
            }
    return rates


def main():
    try:
        rates = parse(fetch(SOURCE_URL))
    except Exception as exc:
        print("Ogohlantirish: bank.uz o'qilmadi: %s" % exc, file=sys.stderr)
        return

    missing = [c for c in CODES if c not in rates]
    if missing or any(r["buy"] <= 0 or r["sell"] <= 0 for r in rates.values()):
        print("Kurslar to'liq topilmadi (%s), nbu_rates.json o'zgartirilmadi." % ", ".join(missing))
        return

    ordered = {c: rates[c] for c in CODES}
    if OUT.exists():
        try:
            if json.loads(OUT.read_text(encoding="utf-8")).get("rates") == ordered:
                print("Kurslar o'zgarmagan.")
                return
        except ValueError:
            pass

    data = {
        "bank": "NBU",
        "source": SOURCE_URL,
        "checked": datetime.now(TASHKENT).strftime("%d.%m.%Y %H:%M"),
        "rates": ordered,
    }
    OUT.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("nbu_rates.json yangilandi: " + ", ".join("%s %d/%d" % (c, r["buy"], r["sell"]) for c, r in ordered.items()))


if __name__ == "__main__":
    main()
