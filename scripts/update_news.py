#!/usr/bin/env python3
"""Yangiliklar bo'limi uchun news.json faylini yangilaydi.

O'zbek tilidagi (lotin yozuvi) RSS lentalardan so'nggi xabarlarni olib,
kalit so'zlar bo'yicha soliq / buxgalteriya / iqtisod toifalariga ajratadi.
GitHub Actions orqali har bir necha soatda ishga tushadi
(.github/workflows/update-news.yml). Faqat standart kutubxona ishlatiladi.
"""
import email.utils
import html
import json
import re
import sys
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

FEEDS = [
    ("Spot.uz", "https://www.spot.uz/oz/rss/"),
    ("Review.uz", "https://review.uz/uz/rss"),
    ("Gazeta.uz", "https://www.gazeta.uz/oz/rss/"),
    ("Daryo.uz", "https://daryo.uz/feed"),
    ("UzA", "https://uza.uz/oz/rss"),
]

# Toifalar tartibi muhim: xabar birinchi mos kelgan toifaga tushadi
CATEGORIES = [
    ("soliq", [
        r"soliq", r"qqs\b", r"qo'shilgan qiymat solig", r"aksiz", r"bojxona", r"boj\b",
        r"soliq deklaratsiya", r"daromad solig", r"mol-mulk solig",
    ]),
    ("buxgalteriya", [
        r"buxgalter", r"hisob-faktura", r"moliyaviy hisobot", r"\baudit", r"mhxs",
        r"ish haqi", r"eng kam ish haqi", r"pensiya", r"inps", r"ijtimoiy soliq",
        r"to'lov intizomi", r"elektron hisobot",
    ]),
    ("iqtisod", [
        r"iqtisod", r"inflyatsiya", r"yaim\b", r"valyuta", r"dollar", r"markaziy bank",
        r"investitsiya", r"eksport", r"import", r"byudjet", r"kredit", r"bank",
        r"tadbirkor", r"biznes", r"narx", r"birja", r"obligatsiya", r"aksiya",
        r"tashqi savdo", r"savdo aylanma", r"tashqi qarz", r"foiz stavka",
    ]),
]

PER_CATEGORY = 4
MAX_AGE_DAYS = 21
MIN_ITEMS = 3
TASHKENT = timezone(timedelta(hours=5))
OUT = Path(__file__).resolve().parent.parent / "news.json"

APOSTROPHES = re.compile(r"[‘’ʻʼ`´]")
TAGS = re.compile(r"<[^>]+>")
SPACES = re.compile(r"\s+")


def clean(text):
    text = html.unescape(TAGS.sub(" ", text or ""))
    return SPACES.sub(" ", text).strip()


def normalize(text):
    return APOSTROPHES.sub("'", text).lower()


def shorten(text, limit=170):
    if len(text) <= limit:
        return text
    cut = text[:limit].rsplit(" ", 1)[0]
    return cut.rstrip(",.;:—-") + "…"


def tag_text(block, tag):
    m = re.search(r"<%s[^>]*>(.*?)</%s>" % (tag, tag), block, re.S)
    if not m:
        return ""
    value = m.group(1).strip()
    cdata = re.fullmatch(r"<!\[CDATA\[(.*)\]\]>", value, re.S)
    return cdata.group(1) if cdata else value


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (mmoliya.uz news bot)"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return resp.read().decode("utf-8", errors="replace")


def classify(title, summary):
    # Sarlavhada bitta kalit so'z yetarli; faqat matnda bo'lsa, kamida ikkita
    # turli kalit so'z kerak — tasodifiy moslik (masalan, jinoyat xabaridagi
    # "savdo shoxobchasi") yangiliklarga tushib qolmasin.
    title, summary = normalize(title), normalize(summary)
    for cat, patterns in CATEGORIES:
        if any(re.search(p, title) for p in patterns):
            return cat
        if sum(1 for p in patterns if re.search(p, summary)) >= 2:
            return cat
    return None


def parse_feed(source, xml):
    items = []
    for block in re.findall(r"<item\b.*?</item>", xml, re.S):
        title = clean(tag_text(block, "title"))
        link = clean(tag_text(block, "link"))
        summary = clean(tag_text(block, "description"))
        if not title or not link.startswith("https://"):
            continue
        try:
            published = email.utils.parsedate_to_datetime(tag_text(block, "pubDate"))
        except (TypeError, ValueError):
            continue
        if published.tzinfo is None:
            published = published.replace(tzinfo=timezone.utc)
        cat = classify(title, summary)
        if not cat:
            continue
        items.append({
            "cat": cat,
            "title": title,
            "excerpt": shorten(summary or title),
            "url": link,
            "source": source,
            "published": published.astimezone(TASHKENT),
        })
    return items


def main():
    collected = []
    for source, url in FEEDS:
        try:
            collected.extend(parse_feed(source, fetch(url)))
        except Exception as exc:  # bitta manba ishlamasa, qolganlari bilan davom etamiz
            print("Ogohlantirish: %s o'qilmadi: %s" % (source, exc), file=sys.stderr)

    cutoff = datetime.now(TASHKENT) - timedelta(days=MAX_AGE_DAYS)
    seen_urls = set()
    seen_words = []
    fresh = []
    for item in sorted(collected, key=lambda i: i["published"], reverse=True):
        if item["published"] < cutoff or item["url"] in seen_urls:
            continue
        # Bir xil voqea turli saytlarda biroz boshqacha sarlavha bilan chiqadi
        # (qo'shimchalar farq qilmasligi uchun so'zlarning boshidagi 4 harf solishtiriladi)
        words = {w[:4] for w in re.findall(r"\w+", normalize(item["title"])) if len(w) > 3}
        if any(len(words & prev) >= 0.5 * min(len(words), len(prev)) for prev in seen_words if prev):
            continue
        seen_urls.add(item["url"])
        seen_words.append(words)
        fresh.append(item)

    chosen = []
    for cat, _ in CATEGORIES:
        chosen.extend([i for i in fresh if i["cat"] == cat][:PER_CATEGORY])
    chosen.sort(key=lambda i: i["published"], reverse=True)

    if len(chosen) < MIN_ITEMS:
        print("Yangiliklar juda kam (%d ta), news.json o'zgartirilmadi." % len(chosen))
        return

    items = [{
        "cat": i["cat"],
        "date": i["published"].strftime("%d.%m.%Y"),
        "title": i["title"],
        "excerpt": i["excerpt"],
        "url": i["url"],
        "source": i["source"],
    } for i in chosen]

    if OUT.exists():
        try:
            if json.loads(OUT.read_text(encoding="utf-8")).get("items") == items:
                print("Yangi xabar yo'q, news.json o'zgarmadi.")
                return
        except ValueError:
            pass

    data = {"updated": datetime.now(TASHKENT).strftime("%d.%m.%Y %H:%M"), "items": items}
    OUT.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    counts = {cat: sum(1 for i in items if i["cat"] == cat) for cat, _ in CATEGORIES}
    print("news.json yangilandi: %d ta xabar %s" % (len(items), counts))


if __name__ == "__main__":
    main()
