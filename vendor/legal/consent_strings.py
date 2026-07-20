"""Versioned consent-wording constants for v0.1.

Single source of truth for:

- ``article_9_special_category_consent`` (EU only, shown by the Hub
  installer before any Ostler files are written under ``~/.ostler/``)
- ``whatsapp_unofficial_risk`` (every region, shown when the user
  enables the WhatsApp connector)
- ``voice_speaker_id_eu`` (EU only, shown after Article 9 consent
  to gate WhisperKit / cm041 voice ingestion)

All three strings are reproduced verbatim from
``/tmp/ostler_legal_docs_drafts_2026-05-02.md``. The lawyer-friend
reviews wording before public launch; engineering ships placeholders
flagged ``[DRAFT – pending legal review]`` inline.

Each constant is a :class:`ConsentString` exposing:

- ``text``: full verbatim wording.
- ``version``: ``vMAJOR.MINOR-YYYY-MM-DD`` semver-ish.
- ``sha256()``: deterministic SHA-256 hex of ``text``, used to
  detect wording drift between what the user agreed to and what
  the Hub is currently bundling. Doctor flags amber on mismatch.

Hashes are computed lazily on first call; the function returns the
same value forever for a given module load.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass


@dataclass(frozen=True)
class ConsentString:
    """A versioned consent-wording string.

    Attributes:
        tickbox_id: Stable identifier persisted in
            ``consent.json`` records. NEVER change once shipped –
            renames break round-trip lookup for existing users.
        text: Full verbatim user-facing wording. Includes any
            ``[DRAFT – pending legal review]`` markers.
        version: ``vMAJOR.MINOR-YYYY-MM-DD``.
        scope: Optional sub-scope identifier for forward-compat
            (e.g. ``"speaker_identification_only"``). When the
            scope changes, a new tickbox is required, not silent
            reuse of this one. Critical for EU AI Act Annex III
            forward-compat (no emotion inference today; if added
            later, a new consent record + tickbox are mandatory).
    """

    tickbox_id: str
    text: str
    version: str
    scope: str | None = None

    def sha256(self) -> str:
        """Deterministic SHA-256 hex of ``text`` (UTF-8 encoded)."""
        return hashlib.sha256(self.text.encode("utf-8")).hexdigest()


# Article 9 explicit consent screen, EU-only branch of install.sh.
# Verbatim from /tmp/ostler_legal_docs_drafts_2026-05-02.md §5
# lines 509-544. The two-bracket "Your decision" block at the bottom
# is rendered by install.sh as two equally-weighted buttons; the
# wording here is the canonical text the SHA-256 is computed over.
ARTICLE_9_EU_CONSENT = ConsentString(
    tickbox_id="article_9_special_category_consent",
    version="v1.1-2026-07-15",
    text="""One last thing – what Ostler will look at on your Mac

Ostler is a personal assistant, so it works by looking at the parts of your life you keep on this Mac. Some of that is sensitive. UK and EU privacy law requires us to ask you, in clear words, before we touch any of it.

Where the data lives. Everything Ostler reads stays on this Mac, in encrypted folders only you can unlock. We never get a copy. There is no "cloud" version of your data.

What's in scope. Depending on which connectors you turn on, Ostler may process the following kinds of information that the law treats as "special category" data:

- Health information that you mention in emails, messages, calendar entries or recorded conversations
- Religious or philosophical beliefs mentioned in any of the above
- Sexual orientation mentioned in any of the above
- Trade union membership
- Voice - labelling *who* is speaking on calls (speaker identification). This is done only by the optional Ostler iPhone Companion app, on your iPhone, under a separate consent screen in that app - not on this Mac. This Mac never receives voice recordings or voice fingerprints. (We do not infer mood, emotion, sentiment, stress or deception from voice.)
- Mentions of criminal offences – your own or other people's – in any of the above

We do not perform emotion recognition. If that ever changes we will ask you again, separately, on a new consent screen.

The categories above are processed on this Mac and stay on it - the one exception is voice speaker-identification, which happens only on your iPhone (as noted above) and never reaches this Mac. None of it is sent to Creative Machines or to any third party, except in the specific cases listed in our Privacy Policy at ostler.ai/privacy (mainly: optional cloud routing for non-personal questions, software update checks, and a handful of public metadata services). If you want to read those exceptions before consenting, click "Read the Privacy Policy" below.

You can change your mind any time. You can:

- turn individual connectors (email, calendar, WhatsApp, etc.) off in Settings, which stops Ostler reading that source
- delete everything Ostler has stored using "Reset Ostler" in the menu
- completely uninstall Ostler using the uninstaller at ~/Documents/Ostler/Uninstall Ostler.app

Withdrawing consent stops processing from that point forward. It does not undo work Ostler already did with your earlier consent.

Your decision:

[ ] I consent to Ostler processing the categories of personal data above, locally on this Mac, for the purpose of running my personal assistant.
    (continues the install)

[ ] I do not consent.
    (cancels and removes the installer; nothing is stored on this Mac)

Legal note: You are the data controller for all special-category data Ostler processes on this Mac (UK GDPR Article 4(7)). Creative Machines never receives any of this data. Your explicit consent above (UK GDPR Article 9(2)(a)) is the lawful basis for processing. For personal and household use, Article 2(2)(c) further limits scope. This consent is revocable at any time without affecting processing that has already taken place.
""",
)


# WhatsApp connector tickbox, shown wherever the user enables the
# connector: install.sh channel wizard (option 5) AND the Rust
# `ostler-assistant setup channels --interactive` CLI. Verbatim from
# /tmp/ostler_legal_docs_drafts_2026-05-02.md §4 lines 467-495.
WHATSAPP_UNOFFICIAL_RISK_CONSENT = ConsentString(
    tickbox_id="whatsapp_unofficial_risk",
    version="v1.0-2026-05-12",
    text="""WhatsApp connector – please read carefully

Ostler can read the content of your recent WhatsApp messages locally on this Mac - not just who you messaged and when, but what was said - so you can search and reference them like any other part of your life. It reads recent WhatsApp conversations your Mac has synced - typically several months up to about a year. The messages stay on your Mac. Nothing is sent to us.

There is a risk you should understand before turning this on.

WhatsApp's own Terms of Service say their service can only be accessed using "official" WhatsApp software. Strictly speaking, the way Ostler reads your messages – by reading WhatsApp Web's storage on your Mac – is not what WhatsApp considers "official."

In practice, this kind of read access is widely used and we are not aware of any documented case of WhatsApp banning a user for it. But we cannot rule out the possibility that WhatsApp could:

- suspend your WhatsApp account, temporarily or permanently
- block the device from connecting
- require you to re-verify your number

If that happens, it happens to your WhatsApp account, not to Creative Machines. You – not us – are the person bound by WhatsApp's Terms of Service. We cannot get your account back for you, and we are not liable for any loss you suffer if WhatsApp takes action against your account.

By continuing, you confirm that:

1. You understand this risk.
2. You accept it on your own behalf.
3. You agree that Creative Machines is not responsible if WhatsApp suspends, restricts or terminates your WhatsApp account because of your use of the connector.
4. You have the right to disable the connector at any time from Ostler's settings, and you understand that disabling it does not undo any action WhatsApp may have already taken.

If you don't want to accept this risk, just leave this turned off – Ostler still works without the WhatsApp connector. You can turn it on later from Settings.

[ ] I understand the risk and I want to enable the WhatsApp connector.
[ ] No thanks, leave WhatsApp disabled. (default selection)

Legal note: Your relationship with WhatsApp (Meta Platforms Ireland Ltd) is contractual under their Terms of Service, to which you are the party. Creative Machines provides software that reads WhatsApp Web's storage on your Mac; we are not a party to your WhatsApp ToS and have no rights or duties under it. Compliance with WhatsApp's terms is your responsibility.
""",
)


# Third-party-data acknowledgement, shown to every user (region-agnostic)
# at install time, AFTER the per-region consent screens (Article 9 in EU,
# pass-through elsewhere) and BEFORE the FDA grant phase. Verbatim from
# /tmp/tnm_brief_three_caveats_2026-05-03.md § Caveat 1.1a; same legal-
# track review as the other three. Mitigates the "we have records of
# people who never consented" surface (inbox / contacts / messages /
# photos / calendar attendees) by capturing explicit user
# acknowledgement that they are processing this data as a private
# personal-records keeper. Decline path aborts install with
# rm -rf ~/.ostler/, mirroring Article 9 decline.
THIRD_PARTY_DATA_NOTICE = ConsentString(
    tickbox_id="third_party_data_personal_records",
    version="v1.0-2026-05-12",
    text="""About the data on your Mac that's not just yours

Ostler reads parts of your life that contain information about other people – emails they sent you, messages they wrote, faces in your photos, contact details, calendar attendees. This is normal. It's your inbox, your contacts, your life as it actually exists.

Everything stays on this Mac. Creative Machines never receives any of it. There is no cloud account holding it.

Before you continue, please understand:

- You are keeping these records for yourself, like a private address book, a personal diary, or a journal. Ostler is the tool that helps you organise and search what you already have. You decide what to keep and what to delete.
- Specific requests to be removed. If anyone you have records of asks you to be removed, you can delete that person from Ostler entirely (Settings → People → Delete a person). The deletion removes their data from your wiki, your graph, your search index, and your assistant's memory.
- Nothing leaves your Mac. Not to us, not to a cloud, not to a third party – except in the specific cases listed in our Privacy Policy at ostler.ai/privacy (mainly: optional cloud routing for non-personal questions, software update checks, public metadata enrichment).

[ ] I understand. Continue.
[ ] Read more.   (links to docs.ostler.ai/privacy/third-party-data)

Legal note: For records you keep on this Mac, you are the data controller under UK and EU law (UK GDPR Article 4(7)). Creative Machines never receives this data and is not the controller. Your processing for personal and household purposes falls within UK/EU GDPR Article 2(2)(c).
""",
)


# EU voice-gate, shown only to EU users after the Article 9 screen.
# Placeholder copy from /tmp/plan_legal_position_implementation_2026-05-02.md §8.
# v0.1 is speaker-identification ONLY; emotion recognition is
# explicitly excluded so EU AI Act Annex III is not engaged. Scope
# field locks this – adding emotion features in the future requires
# a brand-new tickbox + record, not silent expansion of this one.
EU_VOICE_SPEAKER_ID_CONSENT = ConsentString(
    tickbox_id="voice_speaker_id_eu",
    version="v1.1-2026-06-21",
    scope="speaker_identification_only",
    text="""Recognising voices on calls (in the Ostler iPhone app)

The Ostler iPhone Companion app can label transcripts with who is speaking - for example, "Sam", "Alex" - by storing a numeric fingerprint of each voice in an encrypted store on your iPhone. The fingerprints never leave your phone and are never sent to this Mac or to us; the Mac only ever receives the text label (the name), never the fingerprint. Under UK and EU privacy law a voice fingerprint is biometric data, so we ask before the Companion enrols any voices.

What we do. Identify *who* is speaking on a recording you make.
What we do not do. Detect mood, emotion, sentiment, stress or any other inferred psychological state from voice.

The fingerprints stay on your iPhone. We never receive them, and neither does this Mac. You can turn this off any time in the iPhone app under Settings -> Voice recognition; turning it off deletes any fingerprints already stored on the phone. If you never install the iPhone Companion, no voice fingerprint is ever created.

[ ] Yes, recognise voices and label my transcripts.
[ ] No thanks, leave voices unlabelled.

Legal note: Voice fingerprints stored on your iPhone by the Ostler Companion app are biometric data under UK GDPR Article 9(1). Your explicit consent above (Article 9(2)(a)) is the lawful basis for processing. You are the data controller (Article 4(7)); Creative Machines never receives the fingerprints, and they are never sent to this Mac. For personal and household use, Article 2(2)(c) further limits scope. Withdrawing consent in the iPhone app deletes stored fingerprints.
""",
)


# Spoken-capture recording-consent acknowledgement, shown to every user
# (region-agnostic) in the Phase-2 consent batch. This is DISTINCT from
# EU_VOICE_SPEAKER_ID_CONSENT above: that one covers the operator's own
# biometric (a voice fingerprint used to label who is speaking); THIS one
# covers the operator's obligation towards OTHER people they record —
# member-state recording-consent law (e.g. German StGB §201, French Penal
# Code Art. 226-1) that governs recording the spoken word and is not
# overridden by keeping everything local. Text/messaging is unaffected;
# only audio the operator records is in scope. Decline does NOT abort the
# install — it simply keeps spoken transcription off (mirrors the EU voice
# gate's non-aborting decline), so a normie who clicks through lands on the
# safe posture. Copy is deliberately plain and non-alarming: an
# acknowledgement of responsibility, not a scare screen.
SPOKEN_CAPTURE_RECORDING_CONSENT = ConsentString(
    tickbox_id="spoken_capture_recording_consent",
    version="v1.0-2026-07-20",
    scope="spoken_capture_recording_consent",
    text="""Recording spoken conversations

Ostler can turn spoken conversations you record – calls and meetings – into searchable text. Typing and messaging is not affected; this is only about audio you choose to record.

The law on recording people speaking is different from the law on written messages, and it varies by country. In some places – for example Germany and France – everyone taking part has to agree before a spoken conversation is recorded. Because you are the person doing the recording, meeting that obligation is your responsibility, not ours.

Keeping everything on your own Mac does not change this. Ostler never sends your recordings anywhere, but storing them locally does not remove your duty to obtain consent where your local law requires it.

What we ask of you:

- Obtain whatever consent your local law requires before you record a spoken conversation.
- Make it clear to the people you are with that recording is happening – for example, say so at the start, or keep a visible recording indicator on.
- If in doubt, leave spoken transcription off. Your text conversations work either way.

[ ] I understand, and I will obtain any consent my local law requires.
[ ] Not now – keep spoken transcription off. (You can turn it on later in Settings.)

Legal note: Recording the spoken word can be regulated by national law – for example section 201 of the German Criminal Code (Verletzung der Vertraulichkeit des Wortes) or Article 226-1 of the French Penal Code – independently of data-protection law. As the person making the recording on this Mac, you are responsible for compliance. Creative Machines never receives your recordings and is not a party to them.
""",
)


# Spoken-capture recording-consent acknowledgement, shown to every user
# (region-agnostic) in the Phase-2 consent batch. This is DISTINCT from
# EU_VOICE_SPEAKER_ID_CONSENT above: that one covers the operator's own
# biometric (a voice fingerprint used to label who is speaking); THIS one
# covers the operator's obligation towards OTHER people they record —
# member-state recording-consent law (e.g. German StGB §201, French Penal
# Code Art. 226-1) that governs recording the spoken word and is not
# overridden by keeping everything local. Text/messaging is unaffected;
# only audio the operator records is in scope. Decline does NOT abort the
# install — it simply keeps spoken transcription off (mirrors the EU voice
# gate's non-aborting decline), so a normie who clicks through lands on the
# safe posture. Copy is deliberately plain and non-alarming: an
# acknowledgement of responsibility, not a scare screen.
SPOKEN_CAPTURE_RECORDING_CONSENT = ConsentString(
    tickbox_id="spoken_capture_recording_consent",
    version="v1.0-2026-07-20",
    scope="spoken_capture_recording_consent",
    text="""Recording spoken conversations

Ostler can turn spoken conversations you record – calls and meetings – into searchable text. Typing and messaging is not affected; this is only about audio you choose to record.

The law on recording people speaking is different from the law on written messages, and it varies by country. In some places – for example Germany and France – everyone taking part has to agree before a spoken conversation is recorded. Because you are the person doing the recording, meeting that obligation is your responsibility, not ours.

Keeping everything on your own Mac does not change this. Ostler never sends your recordings anywhere, but storing them locally does not remove your duty to obtain consent where your local law requires it.

What we ask of you:

- Obtain whatever consent your local law requires before you record a spoken conversation.
- Make it clear to the people you are with that recording is happening – for example, say so at the start, or keep a visible recording indicator on.
- If in doubt, leave spoken transcription off. Your text conversations work either way.

[ ] I understand, and I will obtain any consent my local law requires.
[ ] Not now – keep spoken transcription off. (You can turn it on later in Settings.)

Legal note: Recording the spoken word can be regulated by national law – for example section 201 of the German Criminal Code (Verletzung der Vertraulichkeit des Wortes) or Article 226-1 of the French Penal Code – independently of data-protection law. As the person making the recording on this Mac, you are responsible for compliance. Creative Machines never receives your recordings and is not a party to them.
""",
)
