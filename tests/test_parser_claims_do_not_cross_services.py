#!/usr/bin/env python3
"""Seven export archives were claimed by a parser that could not read them.

MEASURED. An audit materialised export archives with the real member layouts
of each service and ran the SHIPPED dispatcher over them.
``IngestPipeline._get_parser`` returns the FIRST parser whose ``can_parse`` is
true, walking the registration order in ``pipeline.py``. Seven archives went to
the wrong parser, and every one of them yielded ZERO preferences:

    facebook-*.zip / instagram-*.zip -> Discord      0   (Meta would give 4)
    Basic_LinkedInDataExport.zip     -> Meta         0
    my_spotify_data.zip              -> Meta         0
    reddit_export/comments.csv       -> LinkedIn     0   (CSV would give 2)
    Retail.ProductReviews.csv        -> Apple        0   (CSV would give 2)
    TikTok "* History.json"          -> GoogleTakeout 0  (TikTok reads it)
    4sq-export.zip                   -> Netflix      0   (Foursquare reads it)

Building those layouts as fixtures found an EIGHTH, which the audit's archives
did not happen to contain. Twitter claimed ``"following.js" in <member>``, and
``following.js`` is a PREFIX of ``following.json``, which Instagram ships at
``connections/followers_and_following/following.json`` in every export. Twitter
is registered ahead of Meta, so an Instagram export that had escaped Discord
was taken by Twitter instead. It is in this file because a fixture with the
real member layout produced it, which is the argument for real layouts.

This is not eight bugs. It is one bug with eight faces: a ``can_parse`` written
as a SUBSTRING test over a path, when the thing being identified is a
STRUCTURE. ``activity/`` is a substring of ``your_facebook_activity/``, so the
Discord parser claimed every Facebook and Instagram export ever handed to the
product. ``comments`` is a substring of ``Comments.csv``, so Meta claimed
LinkedIn. ``music`` is a substring of ``StreamingHistory_music_0.json``, so
Meta claimed Spotify. ``ratings`` is a substring of ``venueRatings.json``, so
Netflix claimed Foursquare. ``History.json`` is a substring of
``Browsing History.json``, so Google Takeout claimed TikTok.

The customer-visible symptom is silence. A first parser that claims a file and
yields nothing is indistinguishable, from the outside, from an export that had
nothing in it. Nobody gets an error. The data is simply not there.

Two of the seven are the mirror image -- a claim WIDER than the handler behind
it. Apple claimed ``"reviews.csv" in name`` while its dispatcher compared with
``==``, so ``Retail.ProductReviews.csv`` was taken and then silently dropped
on the floor by an if/elif chain with no matching arm. Reddit does the same
with ``comments.csv`` and ``posts.csv``: claimed by ``can_parse``, unhandled by
``_parse_csv``. A claim a parser cannot honour is worse than no claim, because
it stops the parser that could.

And one is the mirror image of the mirror image -- a claim too NARROW to catch
its own files. Foursquare demanded the literal string "foursquare" in the path,
which its own real export, ``4sq-export.zip``, does not contain.

WHAT THIS PINS

  1. CONTESTED: for each archive above, the WINNER of the shipped dispatcher,
     resolved over the parser list read out of ``pipeline.py`` rather than
     restated here, so a future reorder changes what this test measures.

  2. POSITIVE CONTROLS: every parser in the registration list must still claim
     an archive of its own. This is the limb that matters. The failure mode
     this whole class of fix produces is a guard narrowed until it refuses
     everything, which passes every "must not claim" assertion in the file and
     silently ends ingest for that service. A parser that claims nothing must
     fail here.

  3. STRUCTURAL, NOT NOMINAL: Meta and Discord are each also asked to identify
     an archive whose FILENAME carries no brand at all, so the fix cannot be
     satisfied by matching "facebook" or "discord" in the archive name.

DENOMINATOR. Printed on every run: how many parsers were read out of the
registration list, how many contested archives were resolved, and how many
positive controls were checked. A claim-separation test that examined three
parsers and a claim-separation test that examined twenty-two print the same
word "PASS" otherwise.

BOUND, stated rather than implied. This measures the CLAIM and the ROUTING. It
does not measure yield. An archive routed to the right parser that then parses
it badly passes this test; that is a different instrument.

Every fixture is SYNTHETIC, built on disk in a temporary directory. No customer
data, no real names, no real addresses. See PRODUCTISATION_CHECKLIST.md
Rule zero.

Exit: 0 all pass, 1 a real failure, 2 cannot-run (never a silent pass).
"""

import json
import re
import sys
import tempfile
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INGEST = REPO / "vendor" / "cm019_preferences" / "services" / "ingest"
PIPELINE_PY = INGEST / "src" / "pipeline.py"

PASS = 0
FAIL = 0


def ok(msg: str) -> None:
    global PASS
    print(f"  PASS  {msg}")
    PASS += 1


def no(msg: str) -> None:
    global FAIL
    print(f"  FAIL  {msg}")
    FAIL += 1


def cannot_run(msg: str) -> None:
    print(f"CANNOT RUN: {msg}", file=sys.stderr)
    sys.exit(2)


if not INGEST.is_dir():
    cannot_run(f"vendored ingest service missing at {INGEST}")
sys.path.insert(0, str(INGEST))

try:
    from src import parsers as parsers_module
except Exception as exc:  # noqa: BLE001
    cannot_run(f"could not import the shipped parsers: {type(exc).__name__}: {exc}")


# ---------------------------------------------------------------------------
# The registration list, read out of the shipped source.
# ---------------------------------------------------------------------------

def shipped_registration_order():
    """Return [(name, instance)] in the order pipeline.py registers them.

    Restating the order here would make the routing limbs agree with
    themselves. It is extracted from the product source so that a reorder in
    the product changes what this test measures -- which is the point, because
    reordering the list is the tempting wrong fix for this defect.
    """
    if not PIPELINE_PY.is_file():
        cannot_run(f"pipeline.py missing at {PIPELINE_PY}")
    src = PIPELINE_PY.read_text(encoding="utf-8")
    block = re.search(
        r"self\.parsers:\s*List\[BaseParser\]\s*=\s*\[(.*?)\n\s*\]", src, re.S
    )
    if not block:
        cannot_run(
            "could not find the parser registration list in pipeline.py; a "
            "routing verdict from an unread list would be meaningless"
        )
    names = re.findall(r"^\s*(\w+)\(\)", block.group(1), re.M)
    if len(names) < 20:
        cannot_run(
            f"extracted only {len(names)} parsers from the registration list; "
            "the extractor is not matching and the denominator would be a lie"
        )
    ordered = []
    for name in names:
        cls = getattr(parsers_module, name, None)
        if cls is None:
            cannot_run(f"{name} is registered in pipeline.py but not importable")
        try:
            ordered.append((name, cls()))
        except Exception as exc:  # noqa: BLE001
            cannot_run(f"could not instantiate {name}: {type(exc).__name__}: {exc}")
    return ordered


def first_claimer(ordered, path: Path):
    for name, parser in ordered:
        try:
            if parser.can_parse(path):
                return name
        except Exception as exc:  # noqa: BLE001
            no(f"{name}.can_parse raised on {path.name}: {type(exc).__name__}: {exc}")
    return "nobody"


# ---------------------------------------------------------------------------
# Synthetic fixtures, with the REAL member layouts of each service.
# ---------------------------------------------------------------------------

# Facebook data exports: a "your_facebook_activity" tree plus sibling
# top-level category folders. Note "messages" lives INSIDE the activity tree,
# which is what a top-level-directory test for Discord has to survive.
FACEBOOK_MEMBERS = [
    "your_facebook_activity/comments_and_reactions/comments.json",
    "your_facebook_activity/comments_and_reactions/likes_and_reactions_1.json",
    "your_facebook_activity/groups/your_comments_in_groups.json",
    "your_facebook_activity/groups/group_posts_and_comments.json",
    "your_facebook_activity/posts/your_posts__check_ins__photos_and_videos_1.json",
    "your_facebook_activity/messages/inbox/synthetic_thread_1/message_1.json",
    "personal_information/profile_information/profile_information.json",
    "preferences/your_topics/your_topics.json",
    "logged_information/your_search_history/your_search_history.json",
    "security_and_login_information/account_activity.json",
    "ads_information/ad_preferences.json",
]

INSTAGRAM_MEMBERS = [
    "your_instagram_activity/likes/liked_posts.json",
    "your_instagram_activity/saved/saved_posts.json",
    "your_instagram_activity/comments/post_comments_1.json",
    "your_instagram_activity/media/posts_1.json",
    "your_instagram_activity/messages/inbox/synthetic_thread_1/message_1.json",
    "personal_information/personal_information/personal_information.json",
    "preferences/your_topics/your_topics.json",
    "ads_information/ads_and_topics/ads_viewed.json",
    "connections/followers_and_following/following.json",
]

# A real Discord data package: four top-level directories, all four present.
DISCORD_MEMBERS = [
    "README.txt",
    "account/user.json",
    "account/avatar.png",
    "activity/analytics/events-2026-00000-of-00001.json",
    "activity/reporting/events-2026-00000-of-00001.json",
    "messages/index.json",
    "messages/c100000000000000001/channel.json",
    "messages/c100000000000000001/messages.csv",
    "servers/index.json",
    "servers/s200000000000000002/guild.json",
]

# Discord also ships packages wrapped in a single folder.
DISCORD_WRAPPED_MEMBERS = ["package/" + m for m in DISCORD_MEMBERS]

# LinkedIn "Basic" export: a flat pile of CSVs. "Comments.csv" is the member
# that Meta's bare "comments" pattern took.
LINKEDIN_MEMBERS = {
    "Comments.csv": "Date,Link,Message\n"
                    "2026-01-01 10:00:00,https://example.invalid/p/1,Synthetic comment one\n"
                    "2026-01-02 10:00:00,https://example.invalid/p/2,Synthetic comment two\n",
    "Reactions.csv": "Date,Link,Type\n"
                     "2026-01-01 11:00:00,https://example.invalid/p/3,LIKE\n",
    "Skills.csv": "Name\nSynthetic Skill Alpha\n",
    "Company Follows.csv": "Organization,Followed On\n"
                           "Synthetic Holdings Ltd,2026-01-01 12:00:00\n",
    "Connections.csv": "First Name,Last Name,Company,Position\n"
                       "Fictional,Placeholder,Synthetic Holdings Ltd,Widget Tester\n",
    "Profile.csv": "First Name,Last Name,Headline\n"
                   "Fictional,Placeholder,Synthetic profile headline\n",
    "Ad_Targeting.csv": "Member Age,Company Names\n25-34,\n",
    "Rich_Media.csv": "Media Link\nhttps://example.invalid/m/1\n",
}

# Spotify "my_spotify_data.zip": a MyData/ folder. The member that Meta's bare
# "music" pattern took is StreamingHistory_music_0.json.
SPOTIFY_MEMBERS = {
    "MyData/StreamingHistory_music_0.json": json.dumps(
        [{"endTime": "2026-01-01 10:00", "artistName": "Synthetic Artist",
          "trackName": "Synthetic Track", "msPlayed": 210000}]
    ),
    "MyData/StreamingHistory_podcast_0.json": json.dumps(
        [{"endTime": "2026-01-01 11:00", "podcastName": "Synthetic Show",
          "episodeName": "Synthetic Episode", "msPlayed": 900000}]
    ),
    "MyData/YourLibrary.json": json.dumps(
        {"tracks": [{"artist": "Synthetic Artist", "track": "Synthetic Track"}]}
    ),
    "MyData/Playlist1.json": json.dumps({"playlists": []}),
    "MyData/Follow.json": json.dumps({"followerCount": 0, "followingUsersCount": 0}),
    "MyData/SearchQueries.json": json.dumps([]),
    "MyData/Marquee.json": json.dumps([]),
    "MyData/Inferences.json": json.dumps({"inferences": []}),
}

# Foursquare/Swarm export. The archive is named 4sq-export.zip; the string
# "foursquare" appears nowhere in it, which is exactly why the parser that
# demanded that string could not find its own data.
FOURSQUARE_MEMBERS = {
    "checkins1.json": json.dumps(
        [{"createdAt": 1767225600, "venue": {"name": "Synthetic Coffee Bar"}}]
    ),
    "venueRatings.json": json.dumps(
        [{"venue": {"name": "Synthetic Coffee Bar"}, "rating": "like"}]
    ),
    "tips.json": json.dumps([]),
    "expertise.json": json.dumps([]),
    "lists.json": json.dumps([]),
    "friends.json": json.dumps([]),
}

NETFLIX_MEMBERS = {
    "CONTENT_INTERACTION/ViewingActivity.csv":
        "Profile Name,Start Time,Duration,Title\n"
        "SyntheticProfile,2026-01-01 20:00:00,00:45:00,Synthetic Series: Season 1: Pilot\n",
    "CONTENT_INTERACTION/Ratings.csv":
        "Profile Name,Title Name,Thumbs Value,Event Utc Ts\n"
        "SyntheticProfile,Synthetic Series,2,2026-01-01 21:00:00\n",
    "CONTENT_INTERACTION/SearchHistory.csv":
        "Profile Name,Query Typed,Utc Timestamp\nSyntheticProfile,synthetic,2026-01-01\n",
    "CONTENT_INTERACTION/MyList.csv":
        "Profile Name,Title Name,Utc Timestamp\nSyntheticProfile,Synthetic Film,2026-01-01\n",
    "ACCOUNT/AccountDetails.csv": "Customer Creation Date\n2020-01-01\n",
}

# Reddit export directory. The header is Reddit's real comments.csv header.
REDDIT_COMMENTS_CSV = (
    "id,permalink,date,ip,subreddit,gildings,link,parent,body,media\n"
    "aaaaaa1,https://example.invalid/r/syntheticsubone/comments/aaaaaa1/,"
    "2026-01-01 10:00:00 UTC,,syntheticsubone,0,,,Synthetic comment body one,\n"
    "aaaaaa2,https://example.invalid/r/syntheticsubtwo/comments/aaaaaa2/,"
    "2026-01-02 10:00:00 UTC,,syntheticsubtwo,0,,,Synthetic comment body two,\n"
)
REDDIT_POST_VOTES_CSV = (
    "id,permalink,direction\n"
    "bbbbbb1,https://example.invalid/r/syntheticsubone/comments/bbbbbb1/,up\n"
)
REDDIT_SUBSCRIBED_CSV = "subreddit\nsyntheticsubone\nsyntheticsubtwo\n"

# Apple Retail product reviews. Apple's dispatcher has no arm for this file;
# the generic CSV parser reads it through the "Product" column.
APPLE_RETAIL_REVIEWS_CSV = (
    "Review ID,Product,Rating,Review Title,Review Text,Submission Date\n"
    "1000001,Synthetic Widget Stand,5,Excellent,Synthetic review text one,2026-01-01\n"
    "1000002,Synthetic Widget Cable,4,Good,Synthetic review text two,2026-01-02\n"
)

# Apple Media Services Reviews.csv: the file Apple's dispatcher DOES handle,
# and the one the over-wide claim was presumably written for.
APPLE_MEDIA_REVIEWS_CSV = (
    "Review Date,Item Description,Review Title,Review,Rating\n"
    "2026-01-01,Synthetic App,Nice,Synthetic review body,5\n"
)

TIKTOK_BROWSING_HISTORY = json.dumps(
    {"Activity": {"Video Browsing History": {"VideoList": [
        {"Date": "2026-01-01 10:00:00", "Link": "https://example.invalid/v/1"}
    ]}}}
)
TIKTOK_LIKE_LIST = json.dumps(
    {"Activity": {"Like List": {"ItemFavoriteList": [
        {"Date": "2026-01-01 10:05:00", "Link": "https://example.invalid/v/2"}
    ]}}}
)

TAKEOUT_CHROME_HISTORY = json.dumps(
    {"Browser History": [
        {"title": "Synthetic Page", "url": "https://example.invalid/a",
         "time_usec": 1767225600000000}
    ]}
)
TAKEOUT_WATCH_HISTORY = json.dumps(
    [{"header": "YouTube", "title": "Watched Synthetic Clip",
      "titleUrl": "https://example.invalid/watch?v=synthetic",
      "time": "2026-01-01T00:00:00Z"}]
)
YOUTUBE_COMMENTS_JSON = json.dumps(
    [{"snippet": {"videoId": "synthetic_video_1"}}]
)


def write_file(root: Path, rel: str, text: str) -> Path:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def write_zip(root: Path, rel: str, members) -> Path:
    """members: a list of names (empty payloads) or a dict name -> text."""
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(members, dict):
        items = members.items()
    else:
        items = ((name, "{}") for name in members)
    with zipfile.ZipFile(path, "w") as zf:
        for name, text in items:
            zf.writestr(name, text)
    return path


def build_fixtures(root: Path) -> dict:
    """Materialise every archive. Returns a name -> Path map."""
    f = {}

    # -- the seven contested archives ------------------------------------
    f["facebook_zip"] = write_zip(
        root, "facebook-synthetic-user-2026-01-01.zip", FACEBOOK_MEMBERS)
    f["instagram_zip"] = write_zip(
        root, "instagram-synthetic-user-2026-01-01.zip", INSTAGRAM_MEMBERS)
    f["linkedin_zip"] = write_zip(
        root, "Basic_LinkedInDataExport_2026-01-01.zip", LINKEDIN_MEMBERS)
    f["spotify_zip"] = write_zip(root, "my_spotify_data.zip", SPOTIFY_MEMBERS)
    f["reddit_comments_csv"] = write_file(
        root, "reddit_export/comments.csv", REDDIT_COMMENTS_CSV)
    f["apple_retail_reviews_csv"] = write_file(
        root, "Apple Retail/Retail.ProductReviews.csv", APPLE_RETAIL_REVIEWS_CSV)
    f["tiktok_browsing_history"] = write_file(
        root, "TikTok_Data/Activity/Browsing History.json", TIKTOK_BROWSING_HISTORY)
    f["foursquare_zip"] = write_zip(root, "4sq-export.zip", FOURSQUARE_MEMBERS)

    # -- brand-free archives, so a nominal fix cannot pass ----------------
    f["facebook_zip_unbranded"] = write_zip(
        root, "export-archive-0001.zip", FACEBOOK_MEMBERS)
    f["discord_zip_unbranded"] = write_zip(
        root, "package-0002.zip", DISCORD_MEMBERS)
    f["discord_zip_wrapped"] = write_zip(
        root, "package-0003.zip", DISCORD_WRAPPED_MEMBERS)

    # -- positive controls, one archive per registered parser -------------
    f["EmailParser"] = write_file(
        root, "email_preferences.jsonl",
        json.dumps({"subject": "Synthetic Topic", "source": "email_signature",
                    "type": "Like", "strength": 0.7}) + "\n")
    f["GoogleTakeoutParser"] = write_file(
        root, "Takeout/Chrome/History.json", TAKEOUT_CHROME_HISTORY)
    f["GoogleTakeoutParser_watch"] = write_file(
        root, "Takeout/YouTube and YouTube Music/history/watch-history.json",
        TAKEOUT_WATCH_HISTORY)
    f["SpotifyParser"] = write_file(
        root, "my_spotify_data/MyData/StreamingHistory_music_0.json",
        SPOTIFY_MEMBERS["MyData/StreamingHistory_music_0.json"])
    f["AmazonParser"] = write_file(
        root, "Amazon/Retail.OrderHistory.1.csv",
        "Order Date,Product Name,Quantity\n2026-01-01,Synthetic Widget,1\n")
    f["LinkedInParser"] = write_file(
        root, "Basic_LinkedInDataExport_2026-01-01/Comments.csv",
        LINKEDIN_MEMBERS["Comments.csv"])
    f["LinkedInParser_reactions"] = write_file(
        root, "Basic_LinkedInDataExport_2026-01-01/Reactions.csv",
        LINKEDIN_MEMBERS["Reactions.csv"])
    f["LinkedInParser_follows"] = write_file(
        root, "Basic_LinkedInDataExport_2026-01-01/Company Follows.csv",
        LINKEDIN_MEMBERS["Company Follows.csv"])
    f["RedditParser"] = write_file(
        root, "reddit_export/post_votes.csv", REDDIT_POST_VOTES_CSV)
    f["RedditParser_zip"] = write_zip(
        root, "export_synthetic_reddit.zip",
        {"post_votes.csv": REDDIT_POST_VOTES_CSV,
         "comment_votes.csv": REDDIT_POST_VOTES_CSV,
         "subscribed_subreddits.csv": REDDIT_SUBSCRIBED_CSV,
         "comments.csv": REDDIT_COMMENTS_CSV})
    f["AppleParser"] = write_file(
        root, "Apple Media Services information/Apple Music - Favorites.csv",
        "Favorite Type,Item Description,Date\nSONG,Synthetic Track,2026-01-01\n")
    f["AppleParser_reviews"] = write_file(
        root, "Apple Media Services information/Other Activity/Reviews.csv",
        APPLE_MEDIA_REVIEWS_CSV)
    f["TwitterParser"] = write_file(
        root, "twitter-archive/data/like.js",
        'window.YTD.like.part0 = [{"like":{"tweetId":"1"}}]')
    f["YouTubeParser"] = write_file(
        root, "YouTube and YouTube Music/comments.json", YOUTUBE_COMMENTS_JSON)
    f["eBayParser"] = write_file(
        root, "ebay-export/PurchaseHistory.html",
        "<html><body><table></table></body></html>")
    f["TikTokParser"] = write_file(
        root, "TikTok_Data/Activity/Like List.json", TIKTOK_LIKE_LIST)
    f["PinterestParser"] = write_file(
        root, "pinterest-export/pinterest_pins.html",
        "<html><body></body></html>")
    f["UberParser"] = write_file(
        root, "uber-data/trips_data-0.csv",
        "City,Product Type,Trip or Order Status\nSynthetic City,UberX,COMPLETED\n")
    f["WhoopParser"] = write_zip(
        root, "whoop-export.zip",
        {"workouts.csv": "Activity name\nSynthetic Run\n"})
    f["FoursquareParser"] = write_file(
        root, "foursquare-export/venueRatings.json",
        FOURSQUARE_MEMBERS["venueRatings.json"])
    f["AppleTVParser"] = write_file(
        root, "Apple Media Services information/Apple TV Bookmarks.csv",
        "Title,Bookmark Position\nSynthetic Film,120\n")
    f["NetflixParser"] = write_zip(root, "netflix-report.zip", NETFLIX_MEMBERS)
    f["NetflixParser_ratings"] = write_file(
        root, "Netflix/CONTENT_INTERACTION/Ratings.csv",
        NETFLIX_MEMBERS["CONTENT_INTERACTION/Ratings.csv"])
    f["NetflixParser_viewing"] = write_file(
        root, "Netflix/CONTENT_INTERACTION/ViewingActivity.csv",
        NETFLIX_MEMBERS["CONTENT_INTERACTION/ViewingActivity.csv"])
    f["DisneyPlusParser"] = write_file(
        root, "disney-plus-export/watch_history.csv",
        "Title,Date\nSynthetic Feature,2026-01-01\n")
    f["WhatsAppParser"] = write_file(
        root, "whatsapp-account-info/whatsapp_connections/groups.json",
        json.dumps({"wa_groups": [{"subject": "Synthetic Group"}]}))
    f["DiscordParser"] = f["discord_zip_unbranded"]
    f["MetaParser"] = f["facebook_zip"]
    f["CSVParser"] = write_file(
        root, "my_preferences.csv",
        "subject,type,strength\nSynthetic Topic,Like,high\n")

    return f


# The seven measured mis-routings, plus the two brand-free structural cases.
#
# "nobody" is a deliberate verdict, not a gap. No parser in the shipped list
# has a LinkedIn or a Spotify ZIP branch, so the honest outcome for those two
# archives is that nothing claims them: an unclaimed archive is visible in the
# ingest log as unprocessed, where an archive claimed by a parser that yields
# zero is indistinguishable from an empty export. Adding those branches is a
# feature, not a claim fix, and inventing a claimant here would hide the gap.
CONTESTED = [
    ("facebook_zip", "MetaParser", "DiscordParser",
     "a Facebook export (Discord matched 'activity/' inside "
     "'your_facebook_activity/')"),
    ("instagram_zip", "MetaParser", "TwitterParser",
     "an Instagram export (Discord matched 'your_instagram_activity/', and "
     "Twitter matched 'following.js' as a prefix of the 'following.json' "
     "every Instagram export ships)"),
    ("facebook_zip_unbranded", "MetaParser", "DiscordParser",
     "a Facebook export whose FILENAME says nothing about Facebook"),
    ("discord_zip_unbranded", "DiscordParser", "DiscordParser",
     "a Discord package whose FILENAME says nothing about Discord"),
    ("discord_zip_wrapped", "DiscordParser", "DiscordParser",
     "a Discord package nested inside one wrapper folder"),
    ("linkedin_zip", "nobody", "MetaParser",
     "a LinkedIn export ZIP (Meta matched 'comments' inside 'Comments.csv')"),
    ("spotify_zip", "nobody", "MetaParser",
     "a Spotify export ZIP (Meta matched 'music' inside "
     "'StreamingHistory_music_0.json')"),
    ("reddit_comments_csv", "CSVParser", "LinkedInParser",
     "a Reddit comments.csv (LinkedIn claimed the bare filename; Reddit "
     "claimed it too and has no handler for it)"),
    ("apple_retail_reviews_csv", "CSVParser", "AppleParser",
     "Retail.ProductReviews.csv (Apple claimed a substring its own dispatcher "
     "compares with ==)"),
    ("tiktok_browsing_history", "TikTokParser", "GoogleTakeoutParser",
     "a TikTok Browsing History.json (Takeout matched the leaf 'History.json' "
     "as a substring)"),
    ("foursquare_zip", "FoursquareParser", "NetflixParser",
     "4sq-export.zip (Netflix matched 'ratings' inside 'venueRatings.json', "
     "and Foursquare's own guard demanded a word its export does not contain)"),
]

# One archive per registered parser. The KEY is the parser that must still
# claim it. Extra fixtures for the same parser are listed as suffixed entries.
POSITIVE_CONTROLS = [
    ("EmailParser", "EmailParser", "a CM021 email preference .jsonl"),
    ("GoogleTakeoutParser", "GoogleTakeoutParser", "Takeout/Chrome/History.json"),
    ("GoogleTakeoutParser", "GoogleTakeoutParser_watch",
     "Takeout YouTube watch-history.json"),
    ("SpotifyParser", "SpotifyParser", "an extracted StreamingHistory_music_0.json"),
    ("AmazonParser", "AmazonParser", "Retail.OrderHistory.1.csv"),
    ("LinkedInParser", "LinkedInParser", "LinkedIn Comments.csv"),
    ("LinkedInParser", "LinkedInParser_reactions", "LinkedIn Reactions.csv"),
    ("LinkedInParser", "LinkedInParser_follows", "LinkedIn Company Follows.csv"),
    ("RedditParser", "RedditParser", "Reddit post_votes.csv"),
    ("RedditParser", "RedditParser_zip", "a Reddit export ZIP"),
    ("AppleParser", "AppleParser", "Apple Music - Favorites.csv"),
    ("AppleParser", "AppleParser_reviews", "Apple Media Services Reviews.csv"),
    ("TwitterParser", "TwitterParser", "a Twitter like.js"),
    ("YouTubeParser", "YouTubeParser", "a YouTube comments.json"),
    ("eBayParser", "eBayParser", "an eBay PurchaseHistory.html"),
    ("TikTokParser", "TikTokParser", "a TikTok Like List.json"),
    ("TikTokParser", "tiktok_browsing_history", "a TikTok Browsing History.json"),
    ("PinterestParser", "PinterestParser", "a Pinterest HTML export"),
    ("UberParser", "UberParser", "an Uber trips_data csv"),
    ("WhoopParser", "WhoopParser", "a Whoop export ZIP"),
    ("FoursquareParser", "FoursquareParser", "a Foursquare venueRatings.json"),
    ("FoursquareParser", "foursquare_zip", "4sq-export.zip"),
    ("AppleTVParser", "AppleTVParser", "Apple TV Bookmarks.csv"),
    ("NetflixParser", "NetflixParser", "a Netflix report ZIP"),
    ("NetflixParser", "NetflixParser_ratings", "Netflix Ratings.csv"),
    ("NetflixParser", "NetflixParser_viewing", "Netflix ViewingActivity.csv"),
    ("DisneyPlusParser", "DisneyPlusParser", "a Disney+ watch_history.csv"),
    ("WhatsAppParser", "WhatsAppParser", "a WhatsApp connections groups.json"),
    ("DiscordParser", "DiscordParser", "a Discord data package ZIP"),
    ("MetaParser", "MetaParser", "a Facebook export ZIP"),
    ("MetaParser", "instagram_zip", "an Instagram export ZIP"),
    ("MetaParser", "facebook_zip_unbranded", "an unbranded Facebook export ZIP"),
    ("CSVParser", "CSVParser", "a generic preference CSV"),
]


def main() -> int:
    ordered = shipped_registration_order()
    by_name = dict(ordered)
    registered = [name for name, _ in ordered]

    print(f"  ..    registration list read from {PIPELINE_PY.name}: "
          f"{len(registered)} parsers")
    print(f"  ..    order: {' '.join(registered)}")
    print()

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        fixtures = build_fixtures(root)

        # -- limb 1: the contested archives, through the shipped order -----
        print("  --    CONTESTED ARCHIVES (dispatcher winner)")
        for key, expected, previously, what in CONTESTED:
            path = fixtures[key]
            winner = first_claimer(ordered, path)
            if winner == expected:
                ok(f"{path.name} -> {winner}  [{what}]")
            else:
                extra = ""
                if winner == previously and expected != previously:
                    extra = "  (unchanged: still the parser that yielded zero)"
                no(f"{path.name} -> {winner}, expected {expected}{extra}  "
                   f"[{what}]")

        # -- limb 2: every parser still claims its own archive -------------
        print()
        print("  --    POSITIVE CONTROLS (parser still claims its own data)")
        controlled = set()
        for parser_name, key, what in POSITIVE_CONTROLS:
            controlled.add(parser_name)
            parser = by_name.get(parser_name)
            if parser is None:
                no(f"{parser_name} is not in the registration list; the "
                   "positive-control table is out of date")
                continue
            path = fixtures[key]
            try:
                claimed = parser.can_parse(path)
            except Exception as exc:  # noqa: BLE001
                no(f"{parser_name}.can_parse raised on {what}: "
                   f"{type(exc).__name__}: {exc}")
                continue
            if claimed:
                ok(f"{parser_name} still claims {what}")
            else:
                no(f"{parser_name} NO LONGER claims {what}; the guard has been "
                   "narrowed past its own data and ingest for this service is "
                   "over")

        # -- limb 3: the denominator has no holes --------------------------
        print()
        uncontrolled = [n for n in registered if n not in controlled]
        if uncontrolled:
            no("no positive control for: " + ", ".join(uncontrolled) +
               " -- a parser with no control can be narrowed to nothing and "
               "this test would still pass")
        else:
            ok(f"every one of the {len(registered)} registered parsers has a "
               "positive control")

    print()
    print(f"  DENOMINATOR: {len(registered)} parsers read out of pipeline.py, "
          f"{len(CONTESTED)} contested archives resolved, "
          f"{len(POSITIVE_CONTROLS)} positive controls checked")
    print(f"  {PASS} passed, {FAIL} failed")
    if FAIL:
        return 1
    print("PARSER CLAIMS DO NOT CROSS SERVICES")
    return 0


if __name__ == "__main__":
    sys.exit(main())
