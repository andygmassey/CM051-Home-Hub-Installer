import json, urllib.request, collections

def post(u, d):
    r = urllib.request.Request(u, data=json.dumps(d).encode(),
                               headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=30))

URL = "http://localhost:6333/collections/preferences/points/scroll"
cats = collections.Counter()
nxt = None
seen = 0
for _ in range(40):
    body = {"limit": 500, "with_payload": ["category"], "with_vector": False}
    if nxt:
        body["offset"] = nxt
    d = post(URL, body)["result"]
    for p in d["points"]:
        cats[(p.get("payload") or {}).get("category") or "<none>"] += 1
        seen += 1
    nxt = d.get("next_page_offset")
    if not nxt:
        break

# The dispatch table from enricher.py CATEGORY_CLIENTS, transcribed.
WIRED = {
    "book": "openlibrary", "books": "openlibrary",
    "movie": "tmdb", "movies": "tmdb", "tv": "tmdb", "tv_show": "tmdb", "movie_tv": "tmdb",
    "video": "youtube", "youtube_video": "youtube",
    "music": "musicbrainz", "artist": "musicbrainz", "track": "musicbrainz",
    "podcast": "podcast_index", "podcasts": "podcast_index",
    "bookmark": "url_fetcher", "bookmarks": "url_fetcher",
    "website": "url_fetcher", "page": "url_fetcher",
    "brand": "wikidata_brand",
    "interest": "wikidata", "topic": "wikidata",
    "search_interest": "wikidata", "instagram_creator": "wikidata",
    "place": "google_places", "venue": "google_places", "restaurant": "google_places",
    "event": "events", "ticket": "events", "concert": "events",
}
KEYED = {"tmdb", "youtube", "google_places", "podcast_index", "events"}

print("sampled %d preference points on the box" % seen)
print()
print("%-26s %8s  %s" % ("CATEGORY", "COUNT", "ENRICHMENT"))
print("%-26s %8s  %s" % ("-" * 26, "-" * 8, "-" * 34))
tot_none = tot_keyed = tot_live = 0
for c, n in cats.most_common(40):
    client = WIRED.get(c)
    if client is None:
        state = "NO CLIENT: never enriched"
        tot_none += n
    elif client in KEYED:
        state = "wired -> %s (NEEDS API KEY)" % client
        tot_keyed += n
    else:
        state = "wired -> %s (live)" % client
        tot_live += n
    print("%-26s %8d  %s" % (c, n, state))
print()
print("live now                    %8d" % tot_live)
print("wired but key-gated         %8d" % tot_keyed)
print("no client at all            %8d" % tot_none)
