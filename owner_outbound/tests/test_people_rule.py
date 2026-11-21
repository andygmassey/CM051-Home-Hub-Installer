"""134 people-rule boolean. RED: owner_outbound.people_rule does not exist."""
from owner_outbound.people_rule import keep_service_sender
from owner_outbound.record import OwnerOutboundRecord
from owner_outbound.tests.fakes import FakeStore, FakeGraph, FakeResolver, outbound

NOTIF = "person:notifications"
FIRST_LAST = "person:first.last"


def rec_with(sent_to):
    store = FakeStore()
    rec = OwnerOutboundRecord(store=store, graph=FakeGraph(), owner_aliases=set(),
                              resolver=FakeResolver({sent_to: FIRST_LAST}))
    return rec


def test_notification_sender_that_emailed_owner_stays_excluded():
    rec = rec_with("someone@other.test")
    # inbound only: nothing the owner sent to the notifier. No contact card.
    assert keep_service_sender(NOTIF, has_contact_card=False, record=rec) is False


def test_first_last_address_owner_messaged_is_kept():
    rec = rec_with("first.last@x.test")
    rec.ingest(outbound(channel="email", to=["first.last@x.test"]))
    assert keep_service_sender(FIRST_LAST, has_contact_card=False, record=rec) is True


def test_contact_card_keeps_without_outbound():
    rec = rec_with("first.last@x.test")
    assert keep_service_sender(FIRST_LAST, has_contact_card=True, record=rec) is True


def test_group_only_outbound_does_not_keep():
    rec = rec_with("first.last@x.test")
    rec.ingest(outbound(channel="imessage", to=["first.last@x.test"], is_group=True))
    assert keep_service_sender(FIRST_LAST, has_contact_card=False, record=rec) is False
