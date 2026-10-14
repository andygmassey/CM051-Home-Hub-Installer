// ostler-music-library: read the owner's Music app library for the Hub.
//
// Why this exists (Andy, 2026-10-14, walk #27)
// --------------------------------------------
// vendor/ostler_fda/apple_music.py read ONLY
//     ~/Music/iTunes/iTunes Music Library.xml
// which the modern Music app writes only when the owner has ticked
// "Share Library XML with other applications" in Music > Settings >
// Advanced. Almost nobody has. The walk box held only
// ~/Music/Music/Music Library.musiclibrary, so the reader saw 0 tracks
// and the Hub's music taste came entirely from Spotify for an owner who
// mostly uses Apple Music.
//
// This helper reads the same library through Apple's public
// iTunesLibrary framework (ITLibrary), which needs no setting in the
// Music app. It is bundled INSIDE OstlerInstaller.app next to
// ostler-mecard and signed the same way (Developer ID, hardened runtime,
// the installer's existing entitlements file, nothing added), so when
// install.sh (a descendant of the app) runs it, the read is attributed
// to the installer as the TCC responsible process.
//
// Privacy permission: ITLibrary is gated by "Media & Apple Music"
// (TCC service kTCCServiceMediaLibrary). The usage string is embedded
// via `-sectcreate __TEXT __info_plist` (see Info.plist beside this file).
//
// FAIL-OPEN CONTRACT (reviewer condition 1)
// -----------------------------------------
// Every outcome prints exactly ONE JSON object on stdout and exits 0:
//     {"schema":1,"status":"ok",...}           library read
//     {"schema":1,"status":"empty",...}        framework answered, no songs
//     {"schema":1,"status":"unavailable",...}  framework refused (no
//                                              permission, no library, no
//                                              Music app); error domain and
//                                              code included, never a title
// A non-zero exit only means the process itself broke (bad arguments).
// The Python caller treats anything but "ok" as "fall back to the XML
// export, then to nothing", so a denied permission can never abort an
// install.
//
// Modes:
//     ostler-music-library            full read (tracks + playlists)
//     ostler-music-library --counts   counts only, no titles or names;
//                                     used by the walk probe and by
//                                     read-only box measurement

import Foundation
import iTunesLibrary

let SCHEMA = 1
let API_VERSION = "1.1"

// Candidate property keys for "loved" and "disliked". The public
// ITLibMediaItem header (macOS 26.5 SDK) has NO loved/disliked property
// and no ITLibMediaItemProperty constant for either. valueForProperty:
// accepts arbitrary keys and returns nil for unknown ones, so we ask for
// the names the Music app uses in its own XML export ("Loved",
// "Disliked", and the newer "Favorited") and record which ones answered.
// If none ever answers on a real library, loved stays null: that is an
// honest unknown, not a false.
let LOVED_KEYS = ["Loved", "Favorited"]
let DISLIKED_KEYS = ["Disliked"]

let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func emit(_ obj: [String: Any]) -> Never {
    var out = obj
    out["schema"] = SCHEMA
    if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    } else {
        print("{\"schema\":\(SCHEMA),\"status\":\"unavailable\",\"detail\":\"json_encode_failed\"}")
    }
    exit(0)
}

func boolProperty(_ item: ITLibMediaItem, _ keys: [String]) -> (Bool?, String?) {
    for k in keys {
        if let v = item.value(forProperty: k) {
            if let n = v as? NSNumber { return (n.boolValue, k) }
            if let b = v as? Bool { return (b, k) }
        }
    }
    return (nil, nil)
}

func mediaKindName(_ k: ITLibMediaItemMediaKind) -> String {
    switch k {
    case .kindSong: return "song"
    case .kindMusicVideo: return "music_video"
    case .kindPodcast: return "podcast"
    case .kindAudiobook: return "audiobook"
    case .kindMovie, .kindHomeVideo: return "movie"
    case .kindTVShow: return "tv"
    case .kindVoiceMemo: return "voice_memo"
    default: return "other"
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let countsOnly = args.contains("--counts")
if args.contains(where: { $0 != "--counts" }) {
    FileHandle.standardError.write("usage: ostler-music-library [--counts]\n".data(using: .utf8)!)
    exit(2)
}

let lib: ITLibrary
do {
    lib = try ITLibrary(apiVersion: API_VERSION)
} catch {
    let ns = error as NSError
    emit([
        "status": "unavailable",
        "detail": "itlibrary_init_failed",
        "error_domain": ns.domain,
        "error_code": ns.code,
    ])
}

let items = lib.allMediaItems
var songs: [ITLibMediaItem] = []
var kinds: [String: Int] = [:]
for it in items {
    let k = mediaKindName(it.mediaKind)
    kinds[k, default: 0] += 1
    // Songs and music videos are music; everything else (podcasts,
    // audiobooks, films, voice memos) is not music taste.
    if it.mediaKind == .kindSong || it.mediaKind == .kindMusicVideo {
        songs.append(it)
    }
}

let userPlaylists = lib.allPlaylists.filter { pl in
    // Keep playlists the owner made. Drop the primary "Library" list,
    // Apple's distinguished lists (Music, Purchased, Podcasts...) and
    // folders, so the signal is deliberate curation, not plumbing.
    !pl.isPrimary && pl.distinguishedKind == .kindNone && pl.kind != .folder
}

if countsOnly {
    var lovedAnswered: [String: Int] = [:]
    var lovedTrue = 0
    var dislikedTrue = 0
    var withPlays = 0
    var rated = 0
    for s in songs {
        for k in LOVED_KEYS + DISLIKED_KEYS where s.value(forProperty: k) != nil {
            lovedAnswered[k, default: 0] += 1
        }
        if boolProperty(s, LOVED_KEYS).0 == true { lovedTrue += 1 }
        if boolProperty(s, DISLIKED_KEYS).0 == true { dislikedTrue += 1 }
        if s.playCount > 0 { withPlays += 1 }
        if s.rating > 0 && !s.isRatingComputed { rated += 1 }
    }
    emit([
        "status": songs.isEmpty ? "empty" : "ok",
        "api_version": lib.apiMajorVersion.description + "." + lib.apiMinorVersion.description,
        "media_items": items.count,
        "media_kinds": kinds,
        "tracks": songs.count,
        "tracks_with_plays": withPlays,
        "tracks_rated": rated,
        "tracks_loved": lovedTrue,
        "tracks_disliked": dislikedTrue,
        "property_keys_answered": lovedAnswered,
        "user_playlists": userPlaylists.count,
    ])
}

var tracksOut: [[String: Any]] = []
tracksOut.reserveCapacity(songs.count)
for s in songs {
    var t: [String: Any] = [
        "id": s.persistentID.stringValue,
        "title": s.title,
        "play_count": s.playCount,
        "skip_count": s.skipCount,
        "rating": s.isRatingComputed ? 0 : s.rating,
        "kind": mediaKindName(s.mediaKind),
        "cloud": s.isCloud,
        "purchased": s.isPurchased,
    ]
    if let a = s.artist?.name, !a.isEmpty { t["artist"] = a }
    if let al = s.album.title, !al.isEmpty { t["album"] = al }
    if !s.genre.isEmpty { t["genre"] = s.genre }
    if let d = s.lastPlayedDate { t["last_played"] = iso.string(from: d) }
    if let d = s.addedDate { t["added"] = iso.string(from: d) }
    let (loved, _) = boolProperty(s, LOVED_KEYS)
    if let loved = loved { t["loved"] = loved }
    let (disliked, _) = boolProperty(s, DISLIKED_KEYS)
    if let disliked = disliked { t["disliked"] = disliked }
    tracksOut.append(t)
}

var playlistsOut: [[String: Any]] = []
for pl in userPlaylists {
    playlistsOut.append([
        "name": pl.name,
        "smart": pl.kind == .smart,
        "track_ids": pl.items.map { $0.persistentID.stringValue },
    ])
}

emit([
    "status": songs.isEmpty ? "empty" : "ok",
    "api_version": lib.apiMajorVersion.description + "." + lib.apiMinorVersion.description,
    "tracks": tracksOut,
    "playlists": playlistsOut,
])
