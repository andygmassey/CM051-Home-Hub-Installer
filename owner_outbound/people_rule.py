"""134 people rule: a service-sender-flagged person is kept only with a contact card
or a verified owner-outbound record (the boolean, 1:1 or email-To only)."""


def keep_service_sender(person_uri, has_contact_card, record):
    return bool(has_contact_card) or record.has_verified_owner_outbound(person_uri)
