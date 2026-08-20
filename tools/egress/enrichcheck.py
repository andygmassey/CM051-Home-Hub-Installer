import json, urllib.request, collections

def post(u, d):
    r = urllib.request.Request(u, data=json.dumps(d).encode(),
                               headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=30))

URL = "http://localhost:6333/collections/preferences/points/scroll"

def sample(cat, limit=400):
    body = {"limit": limit, "with_payload": True, "with_vector": False,
            "filter": {"must": [{"key": "category", "match": {"value": cat}}]}}
    return post(URL, body)["result"]["points"]

for cat in ("movie_tv", "movie", "place", "music", "interest", "book"):
    pts = sample(cat)
    if not pts:
        print("%-12s NO POINTS" % cat)
        continue
    keys = collections.Counter()
    enriched = 0
    for p in pts:
        pl = p.get("payload") or {}
        for k in pl:
            keys[k] += 1
        # any field that looks like enrichment output
        if any(k in pl and pl[k] for k in
               ("enrichment", "enriched", "enriched_at", "metadata",
                "genres", "director", "cast", "wikidata_id", "external_ids")):
            enriched += 1
    print("%-12s %4d sampled, %4d carry an enrichment field" % (cat, len(pts), enriched))
    print("             payload keys: %s" % ", ".join(sorted(keys)[:18]))
    # show one example subject + whatever enrichment-ish content exists
    pl = pts[0].get("payload") or {}
    subj = pl.get("subject") or pl.get("value") or pl.get("name") or "<no subject key>"
    print("             example subject: %r" % (str(subj)[:60],))
    print()
